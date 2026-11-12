// drgnx: the stdio shim of a sealed debug fork's js-debug (docs/develop/debugging.md, "What-if forks").
//
// A fork's adapter runs inside Gleipnir with the program, and on Linux the sandbox has a network namespace of its
// own, so no TCP port reaches the hub: the hub speaks to this shim on stdio instead. js-debug's server listens on TCP
// only (a port in the sandbox's own loopback), and each of its child sessions (`startDebugging`) is one more
// connection, so the shim multiplexes: every message on stdio carries a `Drgnx-Conn: N` header beside its
// `Content-Length`; connection N is opened on its first message, and when js-debug closes it the shim sends
// `Drgnx-Close: N` with an empty body. The shim ends when stdin does.
//
//   node debug-fork-shim.js DAP-DEBUG-SERVER.js
// JavaScript because it runs in the sandbox, where js-debug's Node is the only runtime there is.
'use strict';
const net = require('net');
const cp = require('child_process');

const server = process.argv[2];
const conns = new Map();
let port = 0;
let ready = null;

function frames(onFrame) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const end = buf.indexOf('\r\n\r\n');
      if (end < 0) return;
      const head = {};
      for (const line of buf.subarray(0, end).toString('latin1').split('\r\n')) {
        const i = line.indexOf(':');
        if (i > 0) head[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
      }
      const len = parseInt(head['content-length'] || '0', 10);
      if (buf.length < end + 4 + len) return;
      const body = buf.subarray(end + 4, end + 4 + len);
      buf = buf.subarray(end + 4 + len);
      onFrame(head, body);
    }
  };
}

function toHub(id, body, extra) {
  process.stdout.write(`Drgnx-Conn: ${id}\r\n${extra || ''}Content-Length: ${body.length}\r\n\r\n`);
  if (body.length) process.stdout.write(body);
}

function start() {
  // a free port of the sandbox's own loopback for js-debug's server
  ready = new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.listen(0, '127.0.0.1', () => {
      port = probe.address().port;
      probe.close(() => {
        const child = cp.spawn(process.execPath, [server, String(port), '127.0.0.1'], { stdio: ['ignore', 'ignore', 'inherit'] });
        child.on('exit', () => process.exit(0));
        process.on('exit', () => child.kill('SIGKILL'));
        resolve();
      });
    });
    probe.on('error', reject);
  });
}

function open(id) {
  const pending = [];
  const c = { sock: null, pending };
  conns.set(id, c);
  const attempt = (left) => {
    const s = net.connect(port, '127.0.0.1');
    s.once('connect', () => {
      c.sock = s;
      for (const b of pending) s.write(b);
      pending.length = 0;
      s.on('data', frames((head, body) => toHub(id, body)));
      s.on('close', () => { conns.delete(id); toHub(id, Buffer.alloc(0), `Drgnx-Close: ${id}\r\n`); });
    });
    s.once('error', () => {
      if (c.sock) return;
      if (left > 0) setTimeout(() => attempt(left - 1), 50);
      else { conns.delete(id); toHub(id, Buffer.alloc(0), `Drgnx-Close: ${id}\r\n`); }
    });
  };
  ready.then(() => attempt(200));
  return c;
}

start();
process.stdin.on('data', frames((head, body) => {
  const id = head['drgnx-conn'] || '0';
  const c = conns.get(id) || open(id);
  const msg = Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
  if (c.sock) c.sock.write(msg); else c.pending.push(msg);
}));
process.stdin.on('end', () => process.exit(0));
