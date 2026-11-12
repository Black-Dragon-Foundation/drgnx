// drgnx's debug preload (docs/develop/debugging.md, "Sessions inside a port block"), loaded first through
// NODE_OPTIONS=--require into a program debugged inside its session's block of loopback ports (macOS's sandbox lets
// it use no other port). A child's inspector.open(0) takes the block's next free port instead of an ephemeral one.
//
// DRGNX_DEBUG_PORTS: the block's ports for children, comma-separated. DRGNX_DEBUG_CLAIMS: a directory in the
// session's tmp where each port is claimed by an O_EXCL file, so two children never take the same one.
// DRGNX_DEBUG_WAIT_BOOTLOADER: when set, starting a child first waits for js-debug's bootloader (below).
// DRGNX_DEBUG_TRACE: when set, each step is written to stderr.
"use strict";
const fs = require("fs");
const path = require("path");
const inspector = require("inspector");
const ports = (process.env.DRGNX_DEBUG_PORTS || "").split(",").map(Number).filter(Boolean);
const dir = process.env.DRGNX_DEBUG_CLAIMS;
const trace = (m) => process.env.DRGNX_DEBUG_TRACE && fs.writeSync(2, `drgnx-preload pid=${process.pid} ${m}\n`);
// A forked child inherits its parent's --inspect-brk=HOST:PORT through execArgv and would fight for that port: the
// child gets its inspector from js-debug's bootloader instead, on a block port (below).
process.execArgv = process.execArgv.filter((a) => !/^--inspect(-brk|-port|-wait)?(=|$)/.test(a));
function claim() {
  fs.mkdirSync(dir, { recursive: true });
  for (const p of ports) {
    try {
      fs.closeSync(fs.openSync(path.join(dir, "port-" + p), "wx"));
      return p;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
  }
  return 0;
}
// A child that gets no port of the block (a seventh child: the block has six for children; or its port held by
// another process) runs without the debugger: it says so on stderr and in the claims directory (`refused-PID`), and
// its inspector stays closed (the sandbox would refuse any other port).
function refuse(why) {
  fs.writeSync(2, `drgnx: process ${process.pid} runs without the debugger: ${why}\n`);
  try {
    fs.writeFileSync(path.join(dir, "refused-" + process.pid), why + "\n");
  } catch (e) {}
}
if (dir && ports.length) {
  const open = inspector.open;
  inspector.open = function (port, host, wait) {
    if (!port) {
      port = claim();
      if (!port) {
        refuse(`the session's ${ports.length} debug ports for child processes are all in use`);
        return undefined;
      }
      host = "127.0.0.1";
      trace(`inspector.open(0) -> ${port}`);
      try {
        return open.call(this, port, host, wait);
      } catch (e) {
        refuse(`port ${port} of the session's block is held by another process (${e.code || e.message})`);
        return undefined;
      }
    }
    return open.call(this, port, host, wait);
  };
}
// js-debug writes its bootloader into this process's NODE_OPTIONS only once it has attached (100-200 ms in, while
// the program already runs, since js-debug answers the attach only after configurationDone); a child started before
// that would run without a debugger. So starting a child first waits for the bootloader, in 5 ms sleeps: between
// them V8 runs the inspector's pending messages (interrupts), js-debug's evaluate among them. At most 5 s: the wait
// took 128-165 ms on the macOS runner and at most 52 ms on a desktop under full CPU load; past it the child starts
// without the debugger and that is said.
if (process.env.DRGNX_DEBUG_WAIT_BOOTLOADER) {
  const cp = require("child_process");
  const ready = () => /bootloader/.test(process.env.NODE_OPTIONS || "");
  const cell = new Int32Array(new SharedArrayBuffer(4));
  const wait = () => {
    if (ready()) return;
    const t0 = Date.now();
    while (!ready() && Date.now() - t0 < 5000) Atomics.wait(cell, 0, 0, 5);
    trace(`waited ${Date.now() - t0} ms for the bootloader: ${ready() ? "there" : "not there"}`);
    if (!ready()) {
      fs.writeSync(2, `drgnx: process ${process.pid} starts a child without the debugger: js-debug's bootloader did not arrive within 5 s\n`);
    }
  };
  for (const name of ["spawn", "spawnSync", "fork", "exec", "execSync", "execFile", "execFileSync"]) {
    const orig = cp[name];
    cp[name] = function (...args) {
      wait();
      return orig.apply(this, args);
    };
  }
}
