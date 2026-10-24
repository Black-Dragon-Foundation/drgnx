# The hub and the gateway

User docs: [Agents → The hub and the gateway](../guide/agents.md#the-hub-and-the-gateway).

## Processes

- **The client** (`core/drgnx-hub-client.el`, feature `drgnx-hub-client`): everything an editor, the CLI or the
  sandbox needs to talk to a hub, and nothing of the hub's runtime — the socket path and its trust check, the line
  protocol, `drgnx-hub-call` / `-call-sync`, the event subscription, `drgnx-hub-ensure` (which starts Ratatoskr),
  `drgnx-hub-restart-now` and the write queue (`drgnx hub start|stop|status` is `bin/drgnx` calling the binary: no Emacs). It requires only `cl-lib`, `subr-x`, `drgnx-paths`, `drgnx-jobs`
  and `drgnx-guard` (the AI provider list comes from `drgnx-ai`, which the caller has loaded). Editor files require
  this and never `drgnx-hub`; `drgnx-agents.el` calls the server's `drgnx-hub-serving-p` and `drgnx-hub-register` only
  when `(featurep 'drgnx-hub)`. The message prompt both the cockpit preview and the hub's delivery use is
  `drgnx-coord-message-prompt` (`core/drgnx-coord.el`). A `declare-function` of a client function names
  `"drgnx-hub-client"`.
- **The hub** (`core/drgnx-hub.el`, the server half; it requires the client): a batch Emacs started as a durable job (`drgnx-jobs-start "drgnx-hub" …`), one
  per drgnx data directory. Without a systemd user manager (always on macOS) the job is detached by
  `drgnx-jobs--detach`: `setsid -f`, or where there is no `setsid` (macOS) perl, which forks and calls setsid(2)
  itself — Emacs's child already leads its own process group, and setsid(2) refuses a group leader. Either way the
  hub leads its own session and process group and outlives the Emacs that started it. A job's pid is checked
  against the boot it was started in: Linux's `boot_id`, macOS's `sysctl -n kern.bootsessionuuid` (not
  `kern.boottime`, which moves when the clock is set). It gets the starting Emacs's drgnx and XDG directories as its
  environment (under systemd only named variables pass, `--setenv=NAME`, so no value is in a command line) and never
  a provider key: a systemd unit keeps its environment where `systemctl --user show` prints it, and the detached
  launcher passes the starting Emacs's environment on, so `drgnx-hub-ensure` unsets every provider's `:key-env` for
  it. Keys come over the socket instead (`gateway/keys`, below). Its `PATH` is the starting Emacs's, until an Emacs
  that read the user's login shell (`core/drgnx-shell-env.el`, at start and Shell: Reload Environment) finds `PATH`
  changed and sends `env/set`: the hub applies it to its own `process-environment` and `exec-path`, so the agents and
  jobs it starts next (`drgnx-jobs` passes `PATH` on to systemd-run) get it. It is never restarted for that: a
  restart would end its durable sessions.
  Its main loop is `accept-process-output` plus the event drain batch Emacs needs (queued events hold back
  sentinels). SIGTERM or `shutdown` removes its socket. It starts with SIGPIPE ignored (`trap '' PIPE`): the
  editing Emacs that launches it does not ignore it, and a write to a connection an agent closed must be an error,
  never the hub's end. The ACP agents it runs and their MCP servers (coordination, search) start the same way —
  `drgnx-command-ignoring-sigpipe`, `sh -c "trap '' PIPE; exec …"`, off Windows — because libuv resets SIGPIPE in an
  agent's children, and a write to a pipe whose reader left would otherwise end the server.
- **Ratatoskr** (`runtime/crates/drgnx-ratatoskr`, binary `ratatoskr`; [runtime.md](runtime.md)), the Rust hub that
  replaces the Lisp server half. `ratatoskr serve [--foreground] [--parent-pid PID] [--supervisor none|self|launchd]`,
  `ensure`, `stop`, `status`, `doctor --json`, `restart` ([below](#starting-stopping-and-restarting-ratatoskr)) and
  `ratatoskr version [--json]`
  (`{version, commit, proto: 1, records: 2, sqlite, test_hooks}`; the commit is `DRGNX_BUILD_COMMIT` at build time,
  else `unknown`). The binary answers to any name (`rtsk` is a symlink to it): argv[0] is never consulted. Exit codes:
  **0** asked to stop, **1** cannot start, **2** usage, **3** another hub serves, **75** restart requested.
  `main` builds the tokio runtime by hand (multi-thread, 2 workers), after the command line is
  read and before anything else (the commands that only talk to a hub never build one). Start order:
  1. The SQLite floor: below 3.51.3 it exits 1.
  2. The socket's directory, `<state>/hub` and `<state>/hub/log` are made private (`private_dir`), then logging
     starts.
  3. The lock (below).
  4. Only while holding the lock: a stale socket is removed, the cap is written (0600, a temporary file and a
     rename), and the socket is bound and made 0600.
  5. `<state>/hub/runtime.db` is opened through urdr (0600, WAL, `synchronous=FULL`; schema 2: the `proc` table the
     orphan reaper fills, and `msession`, the session sockets of
     [Sessions and their sockets](#sessions-and-their-sockets)). A newer schema (after `update --back`) is moved aside
     with its `-wal` and `-shm` as `runtime.db.newer-N-UNIXTIME` and a new file is made: the sessions it kept are lost
     (their bridges fail and their editors open them again), which is accepted because installs are disposable.
  6. The processes `runtime.db` recorded (a crashed run's backend) are reaped, then the Lisp backend is started
     ([Ratatoskr and the Lisp backend](#ratatoskr-and-the-lisp-backend)), then the session sockets whose owners
     still run are bound again.

  It stops on SIGTERM, on SIGINT, or one second after the `--parent-pid` process is gone (`kill(pid, 0)`; the last
  `--parent-pid` counts). It stops accepting, stops the Lisp backend (its group: SIGTERM, SIGKILL after 2 s; at most
  10 s), then removes the socket and the cap while the lock is still held, and exits 0. The log is tracing JSON, one object per line, in `<state>/hub/log/hub-YYYY-MM-DD.jsonl` (UTC days, 0600,
  the newest 7 kept, written by tracing-appender's non-blocking worker). Warnings and errors also go to stderr, behind
  `<4>` / `<3>` when `JOURNAL_STREAM` is set (the journal under systemd). `DRGNX_RATATOSKR_LOG` takes a `Targets`
  string (`info`, the default; `warn,drgnx_ratatoskr::conn=debug`). The cap, keys and params are never logged. The
  cargo feature `test-hooks` (off in the binary install.sh builds) holds the test-only surfaces: the `__test_flood`
  method, `--idle-tick-ms N` (the restart-when-idle tick), and `--agent-socket SID[:JOB]`, which is refused without
  `--foreground`. `DRGNX_HUB_PARENT_PID` does what `--parent-pid` does when the flag is absent (the Lisp hub's name
  for it), so a hub a test starts through `ensure` ends with the test.
- **The gateway** (`core/drgnx-gateway.el`) runs inside the hub: never in the editing Emacs, so streaming cannot
  touch the keystroke budget.
  Besides the 127.0.0.1 port it can listen on **per-session Unix sockets** (`drgnx-gateway-listen-socket PATH`, for
  agents in a sandbox without the host's loopback; the caller picks PATH, `gateway.sock` in the session's private
  directory beside `mcp.sock` and `hub.sock`). Same filter, path allowlist and token check as the port; the socket
  is mode 0600 and a stale file at PATH is replaced. `drgnx-gateway-close-socket PATH` (and `drgnx-gateway-stop`)
  cuts the connections on it, with their upstream requests, and removes the file.
- **curl**, one per forwarded request, reads its config on stdin (`-K -`): the URL, the provider's key header and the
  request body never appear in its argv.
  The config has `suppress-connect-headers`: behind an HTTPS proxy curl's `include` would otherwise print the
  proxy's CONNECT head first, and the gateway would take it for the provider's answer.

### Starting, stopping and restarting Ratatoskr

`ratatoskr ensure [--timeout SECS]` (default 5) pings; when nothing answers it starts a hub and waits up to the timeout
for `ping`. It prints the socket path and exits **0**; **1** when it could not start one (the reason, from the hub's
log when the wait timed out, and the log's directory); **3** when a Lisp hub from before Ratatoskr holds the lock
(checked first, before the ping: such a hub answers one, and `ensure` still says it as `serve` does). How the hub is started:

| Where | How | Restarted |
|---|---|---|
| Linux with a user systemd (the manager's `systemd` directory in `XDG_RUNTIME_DIR`) | `systemd-run --user --unit=ratatoskr-HASH --collect -p Restart=on-failure -p RestartForceExitStatus=75 -p "RestartPreventExitStatus=1 2 3" -p KillMode=mixed --setenv=NAME… ratatoskr serve`; "unit already exists" counts as success (two `ensure`s racing both then ping) | on a crash and on 75; never on 1, 2, 3 (`Restart=on-failure` alone restarts every non-zero exit until the start limit) |
| macOS with a `gui/UID` domain | `<state>/hub/launchd.plist` (0600; label `org.blackdragonfoundation.ratatoskr.HASH`; `KeepAlive {SuccessfulExit: false}`, `ProcessType Background`; `serve --supervisor launchd`), then `launchctl bootstrap gui/UID <plist>`, or `kickstart` when `launchctl print gui/UID/LABEL` finds it loaded (a second `bootstrap` fails); a loaded label whose plist text changed (a new `DRGNX_EMACS`, a new `SSH_AUTH_SOCK`) gets `bootout`, then `bootstrap`, since `kickstart` would keep the old arguments and environment until logout. No domain (an SSH session): the self-detach row, with a line on stderr saying why | on a crash and on 75; `serve --supervisor launchd` maps exits 1, 2 and 3 to 0 after logging the real code, because launchd restarts on every non-zero exit |
| none (`RATATOSKR_SUPERVISOR=none`, containers, no user manager) | the binary starts itself: `serve --supervisor self` in a session of its own (`setsid`), stdio on `/dev/null`; every descriptor is close-on-exec | no: a `restart` re-executes the binary instead |

Only variable *names* go to a supervisor (`--setenv=NAME`, the plist's environment from the same names), each only
when set: `DRGNX_DATA_DIR DRGNX_CONFIG_DIR XDG_RUNTIME_DIR XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
HOME TMPDIR TMP TEMP DRGNX_EMACS DRGNX_DIR DRGNX_RATATOSKR_LOG` and the backend's agent names (`SSH_AUTH_SOCK`, the proxy
and CA variables, `CLAUDE_CONFIG_DIR`, `TERM COLORTERM DISPLAY WAYLAND_DISPLAY`). Without `TMPDIR` and `HOME` a long
socket path would resolve differently under systemd or launchd than in the editor. No value, and no provider key, is ever
in a command line. `systemd-run` and `launchctl` are the root-owned programs at fixed paths, never found through
`PATH`.

### Stopping a hub

`ratatoskr stop [--timeout SECS]` (default 15: the hub stops its backend first) signals nothing unless the lock is
really held:

- **Ratatoskr's lock** (a file): `flock(LOCK_EX|LOCK_NB)` is tried first. If it succeeds nobody holds the lock (a stale
  file naming a live, reused pid, say): it prints `not running` and exits 0 without a signal. If it fails the hub is
  asked to `shutdown` as a user client, and `stop` waits for the lock to be released and prints `stopped Ratatoskr (pid
  N)`. Only when it is not released does it signal, and then only **the process listening on the hub's socket**,
  never one a lock's text or a command line names (`peer.rs`, `lock::signal_target`): it connects to the socket
  through the checked directory and asks the system who accepted. On Linux that is a pidfd (`SO_PEERPIDFD`, else
  `pidfd_open` of the `SO_PEERCRED` pid), so the SIGTERM (`pidfd_send_signal`) reaches that process even if its pid is
  reused meanwhile; on macOS `LOCAL_PEERPID` and `kill`. The listener's uid must be the user's, its pid the one the lock
  names and its start time the recorded one; else `stop` prints "the hub did not stop and WHY; signal it yourself: pid
  N" and exits 1 having signalled nothing. Then it waits again and prints `stopped Ratatoskr (pid N, by SIGTERM)`. A
  process that forges its `argv[0]` (or a lock rewritten to name it) is never signalled. Nothing here reads
  `/proc/PID/exe` or `/proc/PID/cmdline`: the hub is not dumpable (below), so those are not readable without
  `CAP_SYS_PTRACE` anyway. Other systems (Android included, where no hub runs) refuse to signal.
- **Before any of it**, the socket's directory must pass the client check below (a real directory of the user's,
  not a link, no access for others), and the lock and the cap are read through that checked directory, without
  following a link, only when they are the user's. Else `stop`, `ensure` and `status` print the refusal (`… belongs to
  another user`, `… is open to other users (mode 755; it must be 700)`) and exit 1, having read and signalled
  nothing. A directory that is not there is no hub.
- **A Lisp hub's lock** (a directory): a v0 `shutdown` goes to the socket (a Lisp hub serves it without a hello) and
  `stop` waits for the directory to go (`stopped the Lisp hub (pid N)`). If it stays, `lock/pid` gets SIGTERM only
  when it is alive and its command line names `drgnx-hub-main`; else it prints `the lock names pid N, which is not a
  drgnx hub: remove LOCKDIR` and exits 1.

**The hub is not dumpable** (`server::harden`, before it binds or reads a key): `PR_SET_DUMPABLE 0` on Linux and
Android, `PT_DENY_ATTACH` on macOS. Keys live in its memory (next sections), and this keeps another process of the
user's (an agent outside a sandbox, a debugger it starts) from reading that memory with `ptrace` or
`/proc/PID/mem`, and keeps the hub from writing a core file. It does not stop root or a process with
`CAP_SYS_PTRACE`. Its children start dumpable again (an exec resets it); the hub's listening sockets are never passed
to one (close-on-exec, and `draugr::spawn` checks in debug builds that none of them is among a child's descriptors).
It fails closed (design §6.2): when hardening fails — on macOS a hub started under a debugger or tracer, whose
`PT_DENY_ATTACH` is refused; on another platform always — the hub still serves, but takes no key. `gateway/keys` and a
`gateway/register` that carries keys are `not-allowed` at `keys` ("this hub cannot protect keys: WHY") and nothing is
taken; `status`'s `gateway.keys_refused` says WHY, and so do `ratatoskr doctor --json` (`gateway.keys_refused`) and
the text of `ratatoskr status` and `ratatoskr doctor` (a line "keys: refused, this hub cannot protect keys: WHY"). The
editor keeps its keys for the next hand-over; start the hub outside the debugger (`drgnx hub restart`).

### Status, doctor and restart

`ratatoskr status [--json]` is `status` as a user client (with `"running": true` added with `--json`); with no hub it
prints `{"running": false}` and exits 1. `ratatoskr doctor --json` prints `{binary: {path, commit, test_hooks},
running: {commit, pid}?, gateway: {port, registrations, providers, keys_held, warnings, keys_refused?}?, socket_dir:
{path, mode, ok}, sqlite, job_agents}` (`gateway` is the running hub's: the providers named in `keys_held`, never a key;
`keys_refused` only from a hub that could not be hardened, above). `ratatoskr restart` calls `restart`.

**`restart`** (user class) answers `true`, then the hub stops as for `shutdown` (its backend first; in phase 1 there
are no turns to cancel) and exits **75**. Under `--supervisor self`, where nothing would start it again, it releases
its socket and cap and executes the binary again with the same arguments instead (the pid stays; the lock descriptor is
close-on-exec, so the new image takes the lock at the exec).

**Restart-when-idle.** At start the hub resolves its executable's path once (Linux `readlink /proc/self/exe`, which
at start names the file on disk; macOS `_NSGetExecutablePath` and `realpath`) and records that path's device, inode
and mtime. Every 2 s it `stat`s **that path**, never `/proc/self/exe`: the link follows the running inode, which a
rename-replace (an update) leaves alone, so it would never change. A changed stamp runs `<path> version --json` with a
5 s deadline; only an answer with another `commit` counts, and a missing, half-written or failing file is logged and
looked at again at the next tick (the same commit under a new stamp becomes the baseline, so a rebuild that says the
same commit — `unknown`, a build without `DRGNX_BUILD_COMMIT`, the same `HEAD-dirty` while developing — is never
picked up: `drgnx hub stop` by hand, and the next start runs the new build). Once another build is confirmed, the `notice` event
`{source: "hub", severity: "warn", id: "restart-when-idle", life: "condition", text: "drgnx was updated; the hub
restarts when its N running turns finish", command: "hub-restart-now"}` is sent (again when N changes), and the hub
exits 75 the first time nothing is busy. **Idle in phase 1** is the backend's `agents/list` having no session with
status `busy` or `starting` (one being started or resumed) and `job/status` no job `running` (each asked through the private socket within 2 s). An answer that does
not come or does not fit is not idle, so a busy hub is never restarted; a hub whose backend cannot exist (`missing`)
has nothing running. Phase 5 replaces this with the hub's own turn state.

### Ratatoskr's children (`draugr`)

`runtime/crates/draugr` is how the Rust runtime starts and ends processes.

- **Environment:** `env::build(allow, allow_prefixes, set)` copies only the allowed names (and names starting with
  an allowed prefix) from the runtime's environment, then applies `set`. The child starts from an empty environment
  plus that list, so a provider key the runtime holds never reaches it unless a caller names it.
- **Spawning:** every child leads its own process group, gets SIGPIPE back to ignored before `exec` (std resets it
  to the default; a write to a pipe whose reader left must be an error, as for the Lisp hub's children), has stdin
  `/dev/null` unless the caller wants a pipe, and stdout and stderr piped. The last 8000 characters of stderr are
  kept (`Child::stderr_tail`). `Child::wait` reports the exit status once; later calls return nothing. There is no
  `PR_SET_PDEATHSIG`: it fires when the forking *thread* exits, and tokio's threads come and go.
- **Start times:** `start_time(pid)` is field 22 of `/proc/PID/stat` on Linux (clock ticks since boot, read after
  the last `)` of the command name) and `proc_pidinfo`'s start in microseconds on macOS. `boot_id()` is Linux's
  `/proc/sys/kernel/random/boot_id` and macOS's `kern.bootsessionuuid`, as for the Lisp hub's jobs.
- **The orphan reaper:** at start Ratatoskr reaps the process rows (pid, start time, pgid, boot id) a crashed run
  left in `runtime.db`. For each row, in this order:
  1. any of the four is NULL → skipped, nothing signalled (a crash between a row's insert and its update leaves
     one, and `kill(-0)` would be our own group);
  2. pgid ≤ 1, our own group, our session leader's group, or our own pid → refused;
  3. another boot → skipped;
  4. the leader is alive, not a zombie, and has the recorded start time → the group is killed;
  5. the leader is alive with another start time → left alone (the pid was reused, and so may the group id be);
  6. the leader is gone but `kill(-pgid, 0)` still finds the group → the group is killed: POSIX does not reuse a
     process-group id while the group exists, so it is still the one recorded (the orphan case the reaper is for);
  7. otherwise gone.

  Killing a group is SIGTERM, SIGKILL after 2 s, then a wait for `kill(-pgid, 0)` to fail with ESRCH (at most 5 s
  more; a group that outlives that is reported as failed). `kill_group` stops one group the same way, with rule 2's
  refusals. Every signal, the `0` probes included, goes through a `Signaller`; the tests of the guards use a spy
  that sends nothing, so a broken guard turns a test red instead of signalling `-1`.

  **The window left open:** the recorded group died, the leader's pid was then reused by a process that made its
  own group (pgid = that pid) and exited while members of its group lived on, all between the crash and the next
  start. Rule 6 would then kill that unrelated group. It needs a pid reuse plus a leader that exits before its
  children within that interval; a start-time check cannot catch it, because the group's leader is gone.

## The control socket

`drgnx-hub-socket`: `$XDG_RUNTIME_DIR/drgnx/hub-HASH.sock` (HASH: the first 8 hex digits of the SHA-1 of the data
dir), else `<state>/hub/hub-HASH.sock`; a path over 103 bytes (macOS's limit, the closing NUL included in 104; Linux
allows 107) — a deep state dir — moves to `drgnx-hub-UID/` in the first of `$TMPDIR`, `$TMP`, `$TEMP`, else `/tmp`
(the environment's, never `temporary-file-directory`: the Rust side computes the same path, docs/develop/runtime.md). The bytes are counted as the
system sees the name, encoded (`file-name-coding-system`: macOS decomposes "é" into 3 bytes).
Its directory is mode 0700 (made so from the start, with any parents it needs) and must be the user's own directory
— never a link, which would be followed (`drgnx-hub--private-dir`). A client checks the same before it pings, connects or sends
anything (`drgnx-hub--untrusted`): the directory a real directory (not a link) of the user's with no access for
others, and the socket the user's; a directory that is missing is refused too (what is checked is then connected to
by path, and a missing one could be another user's by then). Otherwise it refuses ("Not connecting to the drgnx hub: … is open to other users")
and never hands over keys — on the `/tmp` fallback another local user could have made the directory first. The
coordination server's `coord/notify` checks the same, and so does every path of Ratatoskr's command-line client
(`runstav::paths::trusted_dir`: `ping`, the v0 calls, user connections and the lock's holder, so `ensure`, `stop`,
`status`, `doctor` and `restart`); it opens the directory without following a link and reads the cap and the lock
through it. Unlike the Lisp client it takes a missing directory as no hub (`ensure` then starts one, which makes the
directory private itself). One JSON object per line: requests `{"id", "method",
"params"}`, answers and events. Every method, its classes, its params and its result are in [The
registry](#the-registry-protocol-v1), generated from the Rust definitions.

Errors: `{"id", "error": {"message"}}`. A line that is not JSON is answered with an error too when its `"id"` can be
read (otherwise it is dropped); a line over 1 MiB closes its connection. A client that reads slowly is never dropped for it: once its
socket's buffer is full, `process-send-string` waits and runs timers and filters meanwhile, and what comes for that
client then is queued and written in order after the write (`drgnx-hub--enqueue`, `drgnx-hub--drain`; a broadcast
queues its event for every subscriber before it writes to any, so a newer event never reaches one before an older; never a write one level deeper, which
would nest until `excessive-lisp-nesting` lands anywhere in the hub). A client that stopped reading (a suspended
Emacs) is dropped (logged) when its queue passes `drgnx-hub-client-max-queued` (16 MiB), wherever its write is, or a
write to it makes no progress for longer than `drgnx-hub-client-stuck-after` (10 s; checked also on the hub's tick,
when nothing more comes for it). A line goes out 8 KB at a time (`drgnx-hub--piece`), each piece progress: a write that fills the client's
socket waits 20 ms before Emacs tries again, and macOS's local sockets hold 8 KB (Linux's ~200 KB), so a snapshot of a
few MB takes seconds there (the hub writes ~400 KB/s to a client on macOS) and must not count as a stopped client. Only
the innermost write in progress is judged by time (`drgnx-hub--writing`): one beneath it cannot go on meanwhile, so it gets
back the time each write above it took (only that: a stopped client beneath writes to others is still dropped); its Emacs
connects again (the Agents module's idle timer, the Work cockpit's What needs you refresh) — meanwhile it shows the hub's sessions as
ended.
Snapshots and transcript entries travel as **JSON objects** ("Records 2" below). Events: from the gateway `request` (job, task, agent, provider, model, status, input, output, cost), `fallback`
(agent, from, to, why), `budget` (job, spent, budget); from jobs `card` (id, job, task, kind, title), `job` (id: its status, tasks or open cards changed) and `fallback` (job, task,
agent, from, to, why); from sessions `agent` (id, seq, session — the snapshot) and
`agent-entries` (id, seq, entries: [[index, Entry]…], the entries new or changed since the last time — entries change
in place: chunks appended, tool calls updated), at most one of each per session per 50 ms; `lease-released` (task,
agent, job); `events` (below).

**Mirrors** (`core/drgnx-agents-mirror.el`): the editing Emacs keeps a `drgnx-agent-session` per hub session (`remote`
= its id) filled from these events; an action on a mirror goes to the hub (`drgnx-agents--remote`, never waiting).
A new Emacs fetches each transcript once (`agents/get`, which answers the session's change number `seq`) and keeps
the events that arrive meanwhile, then applies only those numbered after it — events and answers come on different
connections, so their order is not given; a snapshot (`agent`) or entries numbered at or before what a mirror has are
skipped, so an older snapshot never overwrites a newer one. A record that cannot be read (a session snapshot, a
transcript entry), or that is not a list (a number, a string), is skipped with a message; it never stops the records
after it.

One hub per socket: a second finds the first answering `ping`, or holding the lock — `SOCKET.lock/`, a directory
made atomically with the hub's pid — and exits with status 3 (a hub too busy to answer a ping keeps its socket); a hub that cannot start for any other
reason exits with status 1. A
lock whose process is gone (or a zombie) is taken over. A hub removes its socket and lock when it stops, and only if
the lock is still its own. Client side ([The client](#the-client)): `drgnx-hub-ensure` (start if needed; commands and
the CLI only — it waits), `drgnx-hub-call` (asynchronous, with a deadline), `drgnx-hub-call-sync`, `drgnx-hub-connect` (one subscription, even when called
again before the hub answers — up to `drgnx-hub-subscribe-deadline`, 5 s, after which an unanswered one is given up
and the next call subscribes again; each new one hands over the keys this Emacs holds) + `drgnx-hub-event-functions`. The unit
runner sets `DRGNX_NO_HUB_START=1`: a test never starts a hub that would outlive the suite unless it unsets it (the
hub's own tests do, and stop what they start). It also sets `DRGNX_HUB_PARENT_PID` to its own pid, which a hub
inherits: a hub whose parent is gone exits (checked each second), so an interrupted run leaves none behind.

**Ratatoskr's socket** (`runtime/crates/drgnx-ratatoskr`: `lock.rs`, `conn.rs`, `server.rs`) keeps the same path,
lines and limits, with these differences:
- **The lock is a file**, `hub-HASH.sock.lock`, under an exclusive `flock` held for the hub's life. The kernel drops
  the lock with the process, so a crashed Ratatoskr leaves no stale lock. The file holds `"PID START_TIME\n"` for
  display (Linux `/proc/PID/stat` field 22; macOS `proc_pidinfo`, microseconds) and stays after a stop. A lock that is
  held makes `serve` exit 3 ("another hub serves here").
- **A Lisp hub's lock directory** (`SOCKET.lock/` with `pid`, from before Ratatoskr) is judged from its `pid`, never
  from a ping. Ratatoskr exits 3 ("a Lisp hub from before Ratatoskr serves here: drgnx hub stop") and touches nothing
  in two cases:
  - the pid is alive (`kill(pid, 0)` succeeds or fails with EPERM) and its command line has `drgnx-hub-main` (Linux
    `/proc/PID/cmdline`, macOS `sysctl KERN_PROCARGS2`), whether the hub answers a ping or not;
  - `pid` does not read and the directory is younger than 10 s (a Lisp hub between its `mkdir` and its pid write).

  In every other case the directory is removed and the takeover is logged with the pid: the pid is gone, it names
  another program, or `pid` does not read in an older directory.
- **Peer credentials:** on accept, before any line, the peer's uid is read (`SO_PEERCRED` on Linux, `getpeereid` on
  macOS, through tokio's `peer_cred`). A peer of another uid (root included) is closed at once and logged with its
  pid and uid (`conn::peer_allowed`).
- **The first line on a connection is the hub's challenge** `{"event":"challenge","data":{"nonce"}}`, on the main
  socket and on every agent socket ([hello and versions](#hello-and-versions)). Every line then goes through the
  dispatcher ([Errors](#errors)).
- **Lines in:** the 1 MiB codec (`runstav::line::codec`). A codec error (a line too long, not UTF-8) closes the
  connection. A line that fails `parse_strict` is answered `invalid-params` (with its `path`) when its id reads, and
  is otherwise dropped and logged. On EOF a partial line is dropped and what is queued is still written, then the
  connection closes. Other connections are not touched.
- **Lines out** go through a writer task per connection with its own queue. Queueing never waits. A client is dropped
  (logged) when more than 16 MiB is queued for it (the line being written included), or when one write makes no
  progress for 10 s, so a stopped reader never stalls another client. An answer over 16 MiB is replaced by `internal`
  "answer over 16 MiB", and an event over 16 MiB is not sent (logged).

### hello and versions

Ratatoskr's `hello` (protocol v1, `runtime/crates/drgnx-ratatoskr/src/hello.rs`) closes SB-T12-6: a hello line is
worth nothing on another connection, because each connection's challenge differs.

1. On accept the hub sends `{"event":"challenge","data":{"nonce":HUB_NONCE}}`, 32 lowercase hex from 16 random bytes.
2. The client sends `hello` `{proto, nonce, drgnx_version?, schema?, records?, client?, proof?}`. `proof` is
   `HMAC-SHA256(cap, "drgnx-hub client " + HUB_NONCE + " " + nonce)` as 64 lowercase hex, keyed with the cap file's 64
   hex characters.
3. The hub compares the decoded digests in constant time:
   - a valid proof makes a main-socket connection `user`; an agent socket's connection stays `agent`;
   - a wrong proof is `not-allowed` ("refused a hello with a wrong proof" in the log, counted with the refusals), and
     the class does not change;
   - no proof leaves the class as it is (`service` on the main socket).
4. The reply is `{proto: 1, proto_min: 1, drgnx_version, schema, records: 2, class, methods, runtime: {version,
   commit}, proof?}`. `drgnx_version` is the build commit, `schema` is work.db's `meta.schema` (Ratatoskr makes
   or migrates the file before it serves, so 7 unless the file is newer, or older and its migration failed; the Lisp hub says 0
   when there is no work.db yet), and `methods` names every method of the registry. `proof` is the hub's own, `HMAC-SHA256(cap,
   "drgnx-hub hub " + nonce + " " + HUB_NONCE)`. It is sent only after a valid client proof.

A connection answers one `hello`: a second one is `proto` "hello was already answered on this connection", whatever
it holds, and changes nothing. A hello refused for its params (`invalid-params`) does not count as that one. A wrong
proof does. The protocol a user connection's hello said is kept: when it is newer than the hub's, every call on it but
`hello` is `proto` ("this hub speaks protocol 1, the connection's hello said N: restart the hub (drgnx hub stop)").

**Agent sockets.** With the `test-hooks` feature, `serve --foreground --agent-socket SID[:JOB]` binds `hub.sock` in
the session's own directory, `<socket dir>/s/SID/` (`runstav::paths::session_dir`; `<tmp>/drgnx-hub-UID/s/SID/` when
its longest socket, `gateway.sock`, would be over 103 bytes). `s/` and `s/SID/` are made private (0700, the user's,
never a link) and checked with `trusted_dir`, the socket is 0600, and the session dir goes at the stop. A connection
there is `agent` class, bound to SID and JOB: the forwarded calls carry them (`Caller {class, sid, job, conn_id}`). A
session dir is never the backend's `hub-HASH.d/` (review M10): a sandbox is given `s/SID` alone, so nothing bound into
it reaches `backend.sock`. The per-session sockets of later phases (`mcp.sock`, `search.sock`, `gateway.sock`) go in
the same directory.

**The store at start.** Before it serves anything the hub opens `<data>/work.db` with the graph writer and
`norn::migrate7`'s opening rule ([store.md](store.md#migration-from-schema-6-task-11)), and waits for its answer: a
missing file is made at schema 7, a schema-6 one is copied to `<data>/backup/work-pre7-<unix>.db`, checked, and
migrated in one transaction, so the first request sees schema 7. A newer file (above 7) makes the hub read-only; a
file below 6, or a migration that failed, leaves the writer not ready (writes answer its text) and the hub serves
the rest. A failed migration is not tried again until the hub restarts. The coordination writer
(`norn::store::CoordDb`) and the coordination tools' graph store run on the same file.

**`work.db` read-only.** The front reads work.db through `urdr::open_readonly` on a thread of its own (`store.rs`).
It reads `meta.schema` (schema 7's `meta` view over `kv`) at the start and every 2 s. While it is above this hub's 7,
the hub is read-only: a method that writes is `schema`, and `status.read_only` is the schema.

**Rolling back.** The way back from schema 7 is `drgnx hub stop`, then `ratatoskr store restore-pre7 --yes`: the
newest pre-migration copy that checks is put back as `work.db`, and the schema-7 file is kept aside with its `-wal`
and `-shm` as `work.db.schema7-<unix>`. Then install the drgnx from before the move to schema 7: its hub opens
schema 6. `ratatoskr store migrate-check --db FILE --scratch DIR [--json]` migrates a copy and prints only counts
(the dry run before a rollout).

**`ratatoskr methods --json|--markdown`** prints the registry: `runtime/protocol/methods.json`'s content, or the table
in [The registry](#the-registry-protocol-v1).

### Errors

An error is `{"id", "error": {"code", "message", "path"?}}`. Every line goes through the dispatcher
(`dispatch::prelude_as`) before any method runs, in the contract's order:

| Step | Refusal | When |
|---|---|---|
| (line) | `invalid-params` (with `path` when it is known) | not a JSON object, a duplicate key at any depth, nesting deeper than 64, no `method`. Answered when the line's `id` reads, else dropped and logged |
| 1 | `no-method` | the method is not in the registry |
| 2 | `not-allowed` | the connection's class may not call it. A `service` connection calling a `user` method gets "METHOD needs the user's capability (an editor or CLI of an older drgnx: update it)" |
| 2b | `not-allowed` | the Lisp backend's own connection calls a method the front does not serve, or `subscribe` (the seam rule, next section) |
| 3 | `proto` | a call (not `hello`) on a user connection whose hello said a newer protocol |
| 4 | `invalid-params` with `path` | the typed decode failed. Keys the method does not know are dropped and listed in the answer's `ignored` |
| 5 | `schema` | the method writes while the hub is read-only: "work.db is schema N, newer than this hub's 7: update drgnx" |
| 6 | `internal` | the handler failed |

A notification (no `id`) is dispatched the same way and never answered. Every refusal (steps 1–5, and a handler's own,
such as a wrong proof or a second hello) is logged at info ("refused a call") and counted. `status.refusals` is
`{count, last}`, the last 20 newest first, each `{at, method, code, class, path?}`. The log line and the entry carry
only those: never the params or the message, since a decode error's message can quote a value (a key, a prompt).

**Served by the front:** `hello`, `ping` `{pid}`, `status`, `subscribe` (the connection gets the broadcast events
from now on), `shutdown` (answers `true`, then the hub stops as on SIGTERM), `restart`, `events/since`,
`coord/notify` and the front's writes (next section). `status` is `{pid, socket, started, proto, proto_min, records,
drgnx_version, schema, read_only?, store, runtime, refusals, job_agents: "unsandboxed (as on main; the sandbox comes
with phase 6)"}`. `events/since` reads work.db's `event` table: `{since,
last, events: [{id, at, agent, job, task, kind, summary, data?}]}`, after `since` (0), at most `limit` (200, at most
1000), `data` the parsed JSON object. `last` is the newest id answered, or `since` when there is none. `status` also
says `backend: {state: running|starting|missing|failed, pid?}` and `gateway: {port?, registrations, requests,
errors, fallbacks, bytes_in, bytes_out, providers, keys_held, keys_refused?, warnings}`, the front's own gateway
([Registrations](#registrations)): `providers` is how many the table has, `keys_held` the providers whose key the hub
holds (never a key), `keys_refused` why it takes none (only when it could not be hardened), `errors` the requests answered with no status or one of 400 and up. The front also serves the
gateway's methods, `gateway/{register,unregister,keys,set-budget}` and `spend`, and the settings' (`config/settings`, `config/changed`). Every other method
goes to the Lisp backend (next section).

## Ratatoskr and the Lisp backend

Until each part moves to Rust, Ratatoskr runs the Lisp hub as its child, the **backend**, and forwards to it every
method the front does not serve (`runtime/crates/drgnx-ratatoskr/src/{backend,forward,relay,shape}.rs`).

**The command.** `DRGNX_RATATOSKR_BACKEND` when set (an absolute executable, no arguments: the tests' fake backend or
`test/conformance/lisp-hub.sh`), else `EMACS --batch -Q --eval "(setq load-prefer-newer t)" -L DRGNX/core -l
drgnx-hub -f drgnx-hub-main` with HOME as its directory. EMACS is `DRGNX_EMACS` (absolute), else the first line of
`emacs` in the data dir or the config dir when it names an executable file (`drgnx-paths-recorded-emacs`'s rule).
DRGNX is `DRGNX_DIR`, else the checkout the binary was built from (`DRGNX_CHECKOUT`, which install.sh and `drgnx
update` set). With neither, the backend is `missing`: the hub still starts and serves what the front serves, and every
forwarded call is `internal` "the Lisp backend cannot start: …".

**Its environment** is built from an allowlist, so a provider key in Ratatoskr's environment never reaches the
backend or the agents it starts (keys come over the socket, `gateway/keys`): `PATH HOME USER LOGNAME SHELL LANG
LANGUAGE TZ TMPDIR TMP TEMP XDG_RUNTIME_DIR XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME`, `LC_*`,
`DRGNX_DATA_DIR DRGNX_CONFIG_DIR DRGNX_EMACS DRGNX_DIR DRGNX_JOBS_LAUNCHER DRGNX_NO_LANGUAGE_SERVERS`, and what agents
and git use on main: `SSH_AUTH_SOCK`, `HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY` in both cases, `SSL_CERT_FILE
SSL_CERT_DIR NODE_EXTRA_CA_CERTS`, `CLAUDE_CONFIG_DIR`, `TERM COLORTERM`, `DISPLAY WAYLAND_DISPLAY`, each when set.
A `DRGNX_RATATOSKR_BACKEND` child also gets `DRGNX_FAKE_BACKEND_*`. Ratatoskr sets `DRGNX_HUB_SERVE_SOCKET`,
`DRGNX_HUB_PARENT_PID` (its own pid: the backend ends when Ratatoskr is gone) and `DRGNX_HUB_SERVE_SECRET`.

**Only Ratatoskr reaches the backend** (review M10). Each start of the backend gets a new secret, 32 random bytes as
64 hex, in `DRGNX_HUB_SERVE_SECRET`: never in its argv, a file or a log. The first line Ratatoskr sends on its
connection, after the peer check, is `{"auth": SECRET}`. The backend closes any connection whose first line is
anything else (another key, a wrong secret, a line that is not JSON) before a method runs, answers nothing and logs
"refused a connection without the backend secret" to its stderr. It compares the SHA-256 digests, not the strings.
`drgnx-hub-main` refuses to serve a `DRGNX_HUB_SERVE_SOCKET` without a secret (exit 1). A Lisp hub serving on its
own socket (the v0 hub) has no secret and no such check. A same-uid process outside a sandbox can still read the
backend's `/proc/PID/environ`; it can read the cap too, so this guards against sandboxed agents (no access to the
backend's `/proc` entry or its directory), not against unsandboxed code.

**The serve socket.** The backend serves on `<socket dir>/hub-HASH.d/backend.sock` (`<tmp>/drgnx-hub-UID/` when that
is over 103 bytes), in a directory made private (and checked with `trusted_dir`) under Ratatoskr's lock, apart from
every agent session's directory. `drgnx-hub-main` reads `DRGNX_HUB_SERVE_SOCKET`, `DRGNX_HUB_PARENT_PID` and
`DRGNX_HUB_SERVE_SECRET` and unsets all three before it starts anything
(`drgnx-hub--take-serve-env`), so its agents, their coordination servers, an agent's `drgnx job …` and a test inside
a job find the hub through `drgnx-hub-socket`, which is the front's socket: they never reach the backend past the
front's checks. `drgnx-hub-socket` itself never reads a socket from the environment, for the same reason. A
`DRGNX_HUB_SERVE_SOCKET` that is set but not an absolute name ends the backend with exit 1 rather than falling back
to the front's socket. Ratatoskr connects to the backend socket only after checking its peer: our uid, and the pid it
spawned (`lisp-hub.sh` `exec`s Emacs, so the pid is the same). Before each start it removes the backend socket's
`backend.sock.lock` directory: one a killed backend left would name a pid that may be another process's by then (a
reboot), and the backend would take it for a live hub and exit 3 at every start. Its stderr, when it ends before it
serves, is logged as a warning.

**Forwarding.** The front sends `{id, method, params, caller: {class, sid?, job?}}`: the params re-encoded from their
typed decode (a key the method does not know was dropped and listed in the client's `ignored`; a duplicate key was
refused), never the client's line, and the caller as the front established it. The backend never trusts a class from
anywhere else (the v0 backend ignores `caller`). Provider keys never go to the backend (the gateway's methods are the
front's: [Keys](#keys)), are never logged and never serialised. They are not wiped from memory: on their way in they
pass through the request line, its parsed JSON and a plain string before the secret type holds them (review M12), so
this is no claim of zeroisation.
- A line over 1 MiB (the Lisp hub's `drgnx-hub--max-line`) is `invalid-params` "the request is too large for the Lisp
  backend" and never sent: the backend would drop the front's whole connection.
- At most 64 calls per client connection are in flight; past that the front reads no more of that connection until
  one ends. A connection that sends EOF still gets the answers of its calls in flight.
- The front reads the backend with lines of up to 16 MiB (an `agents/get` of 4 MB arrives).
- Each call has 30 s: then `internal` "the Lisp backend did not answer METHOD".
- The backend's `{error: {message}}` is `internal` with that message (job-ui's "No job " prefix still matches). A
  `result` goes through the method's `check_result`; one that does not fit is `internal` "the backend's answer to
  METHOD does not match its schema: PATH", logged with the path (never the data). A `null` list comes out `[]`.
- By class (`shape.rs`): `agents/list` for a `service` connection is `{sessions: [{id, name, job, task}]}`, for an
  `agent` the same for its own job's sessions (and its own); an agent's `spend` reads its own job (`job` defaults to
  it, another is `not-allowed`). `gateway/keys` and `gateway/register`'s keys come from user connections only (the
  class check). `spend` itself is the front's now: summed from work.db's `spend` rows (`norn::read::spend`), all zero
  while there is no work.db.

**Events.** The front subscribes to the backend once per backend start and relays its events to the front's
subscribers. Six kinds main broadcasts are relayed (`agent`, `agent-entries`, `lease-released`, `fallback` with its
`job` — the job runner's —, `card`, `job`); the gateway's `request`, `budget` and a `fallback` without a `job` are the
front's own since the gateway runs in it, so a backend's are dropped and logged ("the gateway's events are the
front's"). Each is decoded against its registry type first; an event of another
name, or one whose data does not decode, is dropped and logged ("dropped a backend event", its name and the path).
The backend's `events` is dropped before the relay (logged once per backend start): the front broadcasts the event
log itself ([Events](#events)). Behind the front the backend sends none: `drgnx-hub-main` with a serve socket never
runs `drgnx-hub--events-check`, so that log line is a sign of an older backend.

**The front's writes.** The front writes work.db's coordination and job tables itself, through norn's writer
(`runtime/crates/drgnx-ratatoskr/src/coord.rs`; [coordination.md](coordination.md#who-writes-what)): the editor's
`cards/settle`, `messages/send`, `messages/mark`, `events/add` and `review/mark`, and the seam's `coord/*` methods,
which the Lisp job runner calls until it moves (phase 6). Each is decoded by the registry, written in one transaction
and answered typed. A work.db that is not ready (below schema 6, or a migration that failed) is `internal` with the
opening rule's text (the writer looks at the file once more first); a newer one is `schema`; a busy one `internal` "work.db is busy; retry" (a
`best_effort` event and `coord/agent`'s `seen` answer `{}`); a writer's refusal (a `seen` from the future, a review
state) `invalid-params` with its text. `coord/prune` never fails (`{pruned: false}`). `coord/notify` is the front's
too: its writes and every `coord/notify`, from any class, feed one coalescer that sends the backend at most one
`coord/notify` notification (no id, never awaited) each 0.25 s, waiting up to 10 s for a backend that is starting;
the backend runs delivery and the clash scan as before. `status` says `store: {schema, writer: ready | not-ready |
read-only, writes, migrated_at?, failed?, wal_bytes?, last_backup?, backup_ok?, denied_in?}`: the writer's state
from its opening rule's last answer, the transactions the front's methods committed since start, when the move from
schema 6 committed, why a migration failed, the WAL's size, and the copies that still hold what the deny-list kept
out of the migration (`last_backup` and `backup_ok` come with the daily backups).

**The backend writes through the front.** `drgnx-hub-main` with a serve socket sets `drgnx-hub--behind-front` and
`drgnx-coord-writer` to `front`; without one (the v0 hub, `lisp-hub.sh`) the writer is `local`. Behind the front
every coordination and job-table write of `core/drgnx-coord.el` is a call to the front's method for it
([coordination.md](coordination.md#who-writes-what)); its reads stay on the backend's own connection to work.db,
which sees each write, since the front commits before it answers. The call is `(drgnx-hub-call-front METHOD
PARAMS &optional DEADLINE)` (`core/drgnx-hub-client.el`), the one place Lisp waits for an answer:
- it runs only where `drgnx-hub--behind-front` is set; anywhere else it signals "only the Lisp backend calls the
  front and waits" (editors use the asynchronous `drgnx-hub-call`);
- one connection, `drgnx-hub--front-conn`, proven like an editor's (the challenge, then a hello with the cap's proof:
  user class, the front's proof checked) and kept; it never subscribes, so only answers arrive on it, and it never
  carries `gateway/keys`, `gateway/register` or `subscribe` (refused before anything is sent);
- it waits with `(accept-process-output CONN 0.05 nil 1)` until the answer or DEADLINE (`drgnx-hub-front-deadline`,
  10 s). The integer JUST-THIS-ONE reads no other process's output and runs no timer meanwhile, so no filter, timer
  or handler of the backend runs inside a write; the seam rule below means the front never waits on the backend
  while it serves the call. The argument must stay an integer: `t` would run timers;
- a second call while one waits (from a sentinel, which may still run) is refused at once with "a front call is
  already waiting", with nothing sent;
- it fails once, never retrying, with `drgnx-hub-front-error` and the data `(:code :message :path)`: the front's
  error code and path, or code nil for this side's failure (no answer by the deadline, a closed connection, a hub
  that did not prove itself), which also drops the connection: the next call connects again. Each call's time goes
  to the backend's log ("drgnx hub: front call METHOD: N ms").

**The seam rule** (call 2). A connection whose peer pid (`SO_PEERCRED`) is the backend's, starting or running, is the
backend's (`Caller.backend`). The dispatcher's step 2b holds it to what the front serves (`home: front` in the table
below): any other method is `not-allowed` "the backend may call only what the front serves", so a call the backend
makes never waits on the backend itself and cannot deadlock; its `subscribe` is `not-allowed` "the backend hears the
front through notifications"; its `status` is the front's alone (no backend query). Only the backend names a
`messages/send` `sender` (an agent's message); from anyone else it is `not-allowed` at `sender`. Any relaxation of the
peer-pid rule (R-FIX-M9) must keep marking the backend's connections.

**Its life.** The backend must answer a `ping` on its socket within 10 s of its start. When it exits, or its
connection ends, the calls in flight fail once (`internal` "the Lisp backend restarted"), calls sent meanwhile wait
for the next one, and it starts again after 1 s, doubling to 30 s (back to 1 s after a run of 30 s or more). A line the backend does not take whole within its call's
deadline ends that connection too (its writer is shut, the backend stopped and started again): part of the line may
be in the socket, and the next line would be appended to it. When Ratatoskr stops, the backend's group gets SIGTERM,
SIGKILL 2 s later.

**Its record and the reaper.** Before the spawn a `proc` row (purpose `backend`, boot id) goes into `runtime.db`;
right after it, the row gets the pid, start time and group (the pid: every child leads its own group), and it goes
when the exit is seen. At start, before the backend is spawned, Ratatoskr reaps every recorded row with
`draugr`'s rules (above: a row with a NULL pid, group, start time or boot id is skipped and never signalled) and
then deletes them all, so a backend a crashed (SIGKILLed) Ratatoskr left is killed with its group. Two windows stay
open:
- **the unrecorded spawn:** between the spawn and the row's update the child is not recorded (unavoidable without a
  stopped child); a crash there leaves a backend the reaper does not know, which ends on its own within a second,
  since it watches its parent pid (`DRGNX_HUB_PARENT_PID`);
- **the reused leader** ("The window left open", above): the recorded group died and its leader's pid went to another
  process's group before the next start.

Phase 1 reaps only the backend's group. An agent of a SIGKILLed backend that is not in that group survives outside
systemd until phases 5 and 6 move agents into Ratatoskr (review I15).

## The client

`core/drgnx-hub-client.el` is what editors, the CLI and the coordination servers load to talk to the hub; it speaks
protocol v1 to Ratatoskr ([hello and versions](#hello-and-versions)) and protocol 0 to a Lisp hub of before it.

**`(drgnx-hub-call METHOD PARAMS CALLBACK &key DEADLINE FULL)`** returns the call's id. CALLBACK gets `(RESULT
ERROR)` **exactly once**: the answer, or `(nil "…")` when DEADLINE passes (`drgnx-hub-call-deadline`, 30 s; a layer
timer `(hub-call . ID)`) or the connection goes first. ERROR is the hub's message; with FULL it is the error object
`(:code :message :path)`. A call answered after its deadline, or one failed by a closed connection, is never called
back again. `drgnx-hub-call-sync` (commands and the CLI only) waits for the same callback, its TIMEOUT the deadline.

**A new connection** proves itself before any call goes:
1. **This Emacs serves the socket** (`drgnx-hub--server` is live on the same path: the Lisp hub's own tests, where
   keys never leave the process): the connection is proven at once. Nothing is sent first and nothing is waited for.
2. Otherwise it **waits for the hub's challenge**, at most 2 s (a layer timer `(hub-challenge . CONNECTION)`), and
   sends a `ping` at once. Ratatoskr's challenge is always its first line, so a ping answered first means a hub of
   before protocol 1: that one is `legacy` at once, without the 2 s wait. Only that makes a hub `legacy`. When the
   2 s pass, what already arrived is read first (an Emacs busy past the wait runs the timer before it reads a
   challenge waiting in the socket); still no line, and the connection is closed and its calls fail (the next call
   connects again). A challenge that comes on a connection taken for `legacy` closes it the same way.
3. On the challenge it sends **`hello`**: `proto` 1, a fresh `nonce`, `drgnx_version` (the commit of the binary on
   disk, `drgnx-hub-client-binary-version`, when it is known), `schema` (`drgnx-work-db-schema-version`), `records` 2,
   `client` (`"cli"` in a batch Emacs, else `"editor"`) and `proof`: `HMAC-SHA256(cap, "drgnx-hub client " +
   HUB_NONCE + " " + nonce)`, the cap read from `hub-HASH.cap` beside the socket with `drgnx-file-read-bounded` (256
   bytes). Calls made meanwhile wait in the connection's queue, in order.
4. **The answer:** the hub's `proof` must be `HMAC-SHA256(cap, "drgnx-hub hub " + nonce + " " + HUB_NONCE)`
   (compared as SHA-256 digests). Then the connection is **proven** and the queued calls go out. A missing or wrong
   proof closes the connection, fails the queued calls once with "the hub at SOCKET did not prove it read CAP-FILE",
   and tells the user (a `fail` notice of source `hub`, id `unproven`). A refused hello, or a cap this Emacs cannot
   read, closes it the same way (without the notice). A hello answered `no method hello` is `legacy`.

**Keys go only to a hub that proved itself** (or this Emacs's own): on any other connection, a `legacy` one or a
service one, `gateway/keys` is never written (its callback gets "keys go only to a hub that proved itself") and
`gateway/register` goes without its `keys`. A legacy hub otherwise gets every call as before.

**`drgnx-hub-client-proves`** (default t): nil sends the hello without a proof and never reads the cap, so the
connection stays `service`. `drgnx-coord-mcp-main` binds it to nil: a coordination server an agent started must never
become `user` class by reading the cap file. Its other hub client, `drgnx-coord-mcp--notify-hub`, writes a raw
`coord/notify` notification and reads nothing; a service connection may send it.

**Skew.** `drgnx-hub--last-hello` keeps the last answer (a plist, or `:legacy`); `(drgnx-hub-has-method-p NAME)`
reads its `methods`. `(drgnx-hub-skew REPLY)` is:

| Reply | Skew |
|---|---|
| `:legacy` (no challenge, or `no method hello`) | `restart-when-idle` |
| `proto` missing or below `drgnx-hub-proto-min`, or `proto_min` above `drgnx-hub-proto` | `incompatible`: the connection is closed, its calls fail, an editor tells the user |
| `records` other than 2; `drgnx_version` other than the binary on disk's commit (when that is known); `schema` other than `drgnx-work-db-schema-version` (0, no work.db yet, counts as the same) | `restart-when-idle` |
| anything else | `ok` |

`drgnx-hub-skew-functions` gets `(SKEW REPLY)` after each hello, inside the guard. The agents mirror pauses while
`records` differs (`drgnx-agents-mirror--paused`): it reads no session or entry it could misread. What an editor does
about `restart-when-idle` is in "Starting the hub, and Hub: Restart Now" below; the client restarts nothing by itself.

**`(drgnx-hub-client-binary)`**: `DRGNX_RATATOSKR_BIN` when it is an absolute name of an executable file, else
`<data>/bin/ratatoskr` when it is one, else nil. **`(drgnx-hub-client-binary-version &optional CACHED-ONLY)`**: its
`version --json` `commit`, read by an asynchronous process bounded at 2 s and cached by the file's name and
modification time. CACHED-ONLY (the skew runs in a filter: a daemon path) never waits: the cached value,
or nil while a read started then runs. The hello does not send without it: on the challenge the connection is in
state `version` (queueing calls) until the read ends (`drgnx-hub--with-binary-version`; a timer ends a read at 2 s and
the hello goes without a version), so the first hello of an Emacs carries `drgnx_version` too.

### Starting the hub, and Hub: Restart Now

`drgnx-hub--ensure-running CALLBACK` starts **one asynchronous `ratatoskr ensure --timeout 5`** (no batch Emacs;
`DRGNX_EMACS` and `DRGNX_DIR` from `(drgnx-emacs-program)` and `drgnx-dir`; provider-key variable names unset). It
never waits: CALLBACK gets nil when a hub answers, or the reason (the process's output) when `ensure` fails or passes
`drgnx-hub-ensure-deadline` (10 s, a layer timer `hub-ensure`). A second call while it runs joins it. `drgnx-hub-ensure`
(commands, the CLI) waits for that and then hands over the provider table and the keys ([Keys](#keys)); in a daemon
path (`inhibit-interaction`) it returns at once and they go, or a `hub` notice `start` is posted, when the start ends. `DRGNX_NO_HUB_START` is honoured; with
no binary every caller says "Ratatoskr is not built: run `drgnx runtime build`".

The hub's `notice` event (sent when the binary on disk changed) is posted by `drgnx-hub--note-notice` (an editor's
subscription) as a notice of source `hub`, a condition with command `hub-restart-now`. A hello that finds the hub
current (`ok`) clears it. A `legacy` hub (the Lisp hub of an install updated while it ran) gets the same notice with
its own text, from the hello, in an editor only. **`hub-restart-now`** ("Hub: Restart Now", category Agents, no key in
any profile; `drgnx-hub-restart-now`) asks no one: on Ratatoskr it calls `restart` (its supervisor, or its own
re-execution, brings it back); on a legacy hub it calls `shutdown` (protocol 0 has no `restart`), waits up to 5 s for
`<socket>.lock` to go, and runs `ratatoskr ensure`; with no hub it just starts one. Agent sessions end. The Lisp hub's
own tests start a Lisp hub with `test/fixtures/lisp-hub-fixture.el`, since `drgnx-hub-ensure` no longer does.

**Probes.** `drgnx-hub--ping-socket` (`drgnx-hub-running-p`) sends a raw `ping` and reads lines until one is not an
event, so Ratatoskr's challenge is skipped. It sends no hello: a probe is `service` class, which `ping` allows.

**The line reader** (`drgnx-hub--lines`, client and Lisp hub alike) searches only the chunk that came for a newline.
The start of a line still open waits in a list of pieces, joined once its newline comes, so a 16 MiB snapshot in 8 KB
chunks costs its length, not its length times its chunks (HUB-LINES-1, PERF-M3).

**Tests:** `test/unit/hub-client-test.el` (prefix `drgnx-hub-client/`). Fake hubs that lie (a wrong proof, no proof,
protocol 0, a held hello) are in `test/fixtures/fake-hub.el`. The tests marked "binary" run against Ratatoskr:
`DRGNX_RATATOSKR_BIN` names it (`bin/drgnx test --container` passes it into the container), they skip without it,
and `test/no-skip.eld` makes CI fail when they skip. Among them, `editor-traffic-over-ratatoskr` replays what the
cockpit, the job UI, the agents mirror and `drgnx job` send, with the params their own code builds, over a populated
store, and fails on any `invalid-params` or `internal`.

## Events

The hub's own timers are layer timers keyed `hub-tick`, `hub-deliver`, `(hub-flush . ID)`, `hub-events` and `hub-exit` ([core.md](core.md#the-acp-watchdog-and-the-hubs-timers)): a burst of session changes delivers once, and `events` go at most every `drgnx-hub-events-interval`.

The hub turns what happens into events in the store's event log ([coordination.md](coordination.md), `event`):

- **Native sessions** (`drgnx-hub--session-events`, on each change of a session):
  - **its life:** `start` when the hub first sees it (data `:head`, the commit its folder is at, read from the
    repository's files by `drgnx-job-git-head`, never a git process), `stop` when it exits;
  - **its turns:** `start` and `stop` with data `(:turn t …)` — `:turn` first, so readers tell them from a life's
    with a prefix test; the cockpit's life, `:stopped` and timeline leave them out;
  - **edits:** an edit tool call it completed (`edit`: kind edit, delete or move, with the paths of its diffs, at most
    100 then `:more N`), once per call, before the turn's `stop`. A write request is the edit when there is one — the
    user accepts it (`agents/do` `review`; a rejected one is none) or a job's policy writes it — and the tool call an
    adapter reports for the same write (claude-agent-acp's Write and Edit do) leaves out the paths this turn recorded
    already: one `edit` per write. The scan starts at the first tool call that may still change, so a streamed turn
    is not walked again on each chunk;
  - **permissions:** a permission it asks (`question`, `:permission ID`) and its answer (`answer`, `:question EVENT-ID
    :permission ID :by BY :option OPTION`): by `user` (the `agents/permission` request, a job's card:
    `drgnx-hub-note-permission-answer`; the event's agent is then `user`), else by `drgnx` with no option — cancelled
    (Stop) or dropped when the agent ended.
- **Jobs** (`core/drgnx-job.el`): a reviewer's verdict (`review`, `:verdict pass` or `fail`, the reasons in the
  summary; no data without a verdict); a merge into the job's branch (`status`, `:status "merged" :into job/ID`); a
  write a job agent's policy allows (`edit`). A task's agent is registered (`drgnx-coord-agent-register`, kind `job`)
  with its worktree, branch and `base`, the commit the worktree is at when it starts: the cockpit diffs its edits
  against it (an agent that retries a task after a failed review starts from the earlier attempt's commits, so its
  diff is the retry's own), and shows it as its job's agent only while the job is shown.
- **Retention:** the hub's housekeeping (every 30 ticks, a minute) calls `drgnx-coord-events-prune-daily`: by age once
  a day, and on every call the row cap (`drgnx-coord-event-max-rows`).

Subscribers get them as `events` (`:since ID :last ID :events [{id, at, agent, job, task, kind, summary, data}…]`,
`data` a JSON object parsed from the store's column, absent when there is none), at
most one every `drgnx-hub-events-interval` (0.25 s) and 200 a time. The hub's session events and `coord/notify`
schedule a broadcast at once; its tick (2 s) catches what other processes wrote and the job events above, which go out
within those 2 s. Event ids are never reused (`autoincrement`), so a pruned log never sends an id twice. A new hub
starts after the last event there is; a client catching up asks `events/since`. Under Ratatoskr the front sends
`events` (`coord.rs`, `broadcast_events`): from the newest row at its start, woken by each transaction its writer
commits, by each forwarded call that writes (the Lisp backend still writes the rest), by `coord/notify` and by its 2 s
schema tick; at most 200 rows an event and one event each 0.25 s, as above. In an editor, the `test` events with
counts reach the status bar (`drgnx-statusbar-note-tests`) through `drgnx-statusbar--hub-tests`, which
`drgnx-statusbar-mode` adds to `drgnx-hub-event-functions` and removes when it is off; the hub client knows nothing of
the status bar.

## Sessions across a restart

On each change to a session the hub keeps `<state>/hub/sessions.eld` (mode 0600, written like registrations.eld,
only when it differs): `(:id :name :profile :cwd :acp-id :task)` of each live session the agent made, oldest first —
not a job's (a job frees the task of an agent the hub took with it and starts it again). A hub that starts, once it
serves, resumes each with `drgnx-agents-take-over` (ACP `session/load`) under its own id and name (messages and
spend follow them); a file that cannot be read, or is not a list of sessions, is copied aside
(`sessions.eld.bak-…`, `drgnx-file-backup`), logged in one line and resumes none (the next save replaces it, the
backup keeps the bytes): the agent replays the
history into the transcript and the session is idle; an editor that reconnects fetches it again (`agents/get`). A
session whose agent cannot load sessions (no `loadSession`, or an error) ends and says why, and so leaves the file.
What was in flight is gone: a turn that was running, the queue, a pending permission or edit.

## The store

The front serves the store (`work.db`, schema 7) itself: `graph/*` (reads and walks, history, revert, excise, grants,
proposed txs, read-only SQL, export, import, backup, settings, the personal-notes opt-ins) and `tasks/*` (the tracker
for the editor), all class `user`, never forwarded to the backend. A write the backend's connection asks for among
them (grants, settings, excise, import, revert, proposed txs, scrub, compact, `tasks/write`) is `not-allowed`. `cards/settle` of an `access` card makes a
grant (or refuses) and of a `close` card closes the task (or rejects), in the settle's tx; the backend's connection
can only refuse and reject. `mcp/session` takes the session's `profile` and its tool sets (`tools: {tracker}`), and
the session socket lists 21 tools, or 16 without the tracker tools (the task's setting first, then the profile's, else
on). Each method's shape: [store.md](store.md#the-stores-methods-task-15b).

## Settings history

The front also records the history of your settings (unified settings design §12; the code is
`runtime/crates/norn/src/write/options.rs`, served from `drgnx-ratatoskr/src/graph.rs`). The settings files stay the
truth: the hub never writes one, and nothing it records applies a value.

- **`settings/record {changes: [{id, value, file, line?}], tool, req, reverts?}` → `{tx}`** (user class; the
  backend's connection is `not-allowed`). The editor sends it after each write of a settings file, and after it reads
  a file another program changed. One call is one transaction of the editor's (`user`), whatever it holds:
  - `id` is an option id (`option:global:<var>`, `option:private/<project>:…`, `option:shared/<project>:…`;
    [store.md](store.md#settings-history-and-grants-urdr-task-10b)); a malformed one is `invalid-params` at
    `changes[N].id`;
  - `value` is the printed Lisp, or `null` when the setting was removed (its entity's `data` then has no `value`);
    `file` and `line` say where it is. A value that looks like a secret (`runstav::secrets::looks_like_secret`, the
    rules of `test/fixtures/secret-cases.json`) is never stored: its version has no `value` and `redacted: true`, so
    the history shows that the setting changed, never the secret;
  - `tool` is the tx's tool and tells the doors apart: `ui:settings` (Settings), `migrate:settings` (the move from the old files), `default:settings` (a shipped default saved), `file:<name>` (a change drgnx did
    not make: a hand edit, a pull, another program) or `lisp:<file>` (your Lisp's effect); anything else is
    `invalid-params`;
  - `req` keys the call (a hash of the file's stamp): a repeat answers the first `{tx}` and writes nothing. It is
    kept as `settings <req>`, apart from the user's other keyed writes;
  - `reverts` names the tx an undo takes back (it must exist);
  - the tx's `project` is the ids' project: every id of one call names the same project (global ids and `root-`
    folders: none), which the store must know; otherwise the call is `invalid-params` and writes nothing.
- **A repository's `.drgnx/settings.el`** comes in through `graph/put-parsed` instead, as a `file` source of the
  scan (`scan:<root>`, class `system`, tool `scan`): its shared settings become parsed entities of the repository's
  project. A global or private id there, an option of any other file, or `data` beyond `value`, `file` and `line`
  refuses the source. Workspace trust still decides what the file's values do.

### Agents change settings

The tools `settings_get` and `settings_change` (`runtime/crates/norn/src/tools/settings.rs`; design §13) are every
agent's. The hub never writes a settings file: it asks the editor, through two events to the subscribers (every
subscriber is a user's connection; none is no editor; `drgnx-ratatoskr/src/settings/agents.rs`), and the editor
answers with two methods.

- **`settings_change {scope, name, value, reason}`**: `scope` is `global`, `private` or `shared`; the id is
  `option:global:<name>` or the session's project's `option:private/<project>:<name>` / `option:shared/…`
  (`norn::options::option_id`: a plain variable, never a dir or mode section). The checks, in order: `value` read by
  `huginn` as one datum of data (a refusal names `value`), a secret in the value or the reason refused, the tool's own
  deny-list check (`norn::options::deny`), then the store's rule for kind `option` (`norn::options::may_write`:
  outside agents never; an active `options` grant of the scope whose `names` match; the deny-list again). Under a
  grant the change is a **proposed** tx of the agent's (tool `mcp:settings_change`, the reason as its `note`), the
  store's guard checking it once more, then the event (to one editor, the first subscribed) **`settings/proposed {tx, scope, name, value, root, agent,
  reason}`** (`root`: the session's folder); the tool waits up to 5 s for **`settings/confirm {tx, ok, error?}`** →
  `{state: accepted | reverted | blocked}` (user class; only a proposed tx of `mcp:settings_change`): `ok` accepts
  the tx, else it is reverted (`blocked`, nothing written, when a later change of the setting came first). The agent
  gets a message either way and its answer is `{changed: TX}`, `{refused: TX, error}`, or `{pending: TX}` (no editor,
  or no answer in time). Without a grant: an `access` card whose `data.setting` holds the request and whose choices
  are `once`, `session` and `refuse` (an open card of the same session and change is the same card); the tool answers
  `{card: N}`.
- **The card** (`cards/settle`, `drgnx-ratatoskr/src/graph.rs`): `once` and `session` (the user's only: the backend's
  connection only refuses) check the request again and make, in the settle's tx, an `options` grant of the card's one
  setting for its session (`session`: a day; `once`: 60 s, revoked as soon as the change is proposed, and bound to the
  card: it covers only the tx whose request key is `settings-card:CARD`, the hub's proposal of the card's value, so
  the agent's own next `settings_change` gets a card of its own); then the change is proposed as above without
  waiting (the editor that settled the card answers it). A name holding `*` is refused
  (a grant would read it as a glob).
- **`settings_get {scope, names?}`**: an `options` grant of the scope or a `read` grant covering it (`*`; its own
  project for `private` and `shared`; `norn::options::may_read`). The event **`settings/explain {req, scope, names?,
  root?}`**, and the editor's **`settings/explained {req, settings: [object]}`** → `true` when the tool still waits
  (2 s). Without an editor the hub's own runtime settings (`settings.el`, the shipped defaults, the global overrides)
  with `complete: false` and `note`. A string that looks like a secret is `[redacted]` in either answer.
- `graph/grants` makes options grants: `access: "options"`, `what` `options:global` or `options:project`, `names?`
  (1 to 64 globs, `*` only); a grant's view carries its `names`.

## Records 2

What crosses the socket is JSON shaped by the record schemas of `core/drgnx-records.el` (docs/develop/core.md,
"Records"); the Lisp side never prints Lisp to a peer and never calls `read` on what a peer sent.

- A `Snapshot` is `drgnx-records-session` (`status`, `via`, `mode` are strings of closed lists), an `Entry` is
  `drgnx-records-entry` (its `text` joined by the hub, `drgnx-agents-join-text`).
- `agents/list` answers `{sessions: [Snapshot]}`, `agents/get` `{session, entries, seq}`; the events `agent`
  `{id, seq, session}` and `agent-entries` `{id, seq, entries: [[index, Entry]]}`.
- `events` and `events/since` rows carry `data` as an object (the store's column, parsed), or no `data`.
- The editor's mirror (`drgnx-agents-mirror`) decodes with `drgnx-records-from-json`: status and entry types become
  symbols, and a record that does not decode (an unknown type, a wrong shape) is skipped with one message.
- `env/set` takes `{env: [{name, value}]}` only (see the method table).

## The registry (protocol v1)

Every method of the hub protocol is one Rust definition in `runtime/crates/runstav/src/methods/` (`hub.rs`,
`gateway.rs`, `agents.rs`, `jobs.rs`, `coord.rs`, `mcp.rs`): its name, the classes that may call it, its params type, its result
type, whether it writes work.db, its home (`front`: Ratatoskr serves it; `backend`: it goes on to the Lisp backend),
and a line of doc. `runstav::registry::registry()` lists them sorted by name and
`find(NAME)` looks one up. Each method's `decode` is the typed decode the dispatcher runs: a value that does not fit
is `invalid-params` with its `path` (a missing key is named too: `{}` for `job/stop` is refused at `id`), and unknown
keys are dropped and listed in `ignored`. Its `check_result` decodes a result into the result type and encodes it
again: strict, so a key the registry does not know is an error with its path, and a `null` where a list belongs comes
out `[]` (A-17). `PROTO` is 1, `PROTO_MIN` 1, `RECORDS` 2 and `SCHEMA` 6.

From the registry come `runtime/protocol/methods.json` (`{proto, proto_min, records, schema, methods: [{name, classes,
writes, home, doc, params, result}], events: [{name, from, doc, data}]}`, each schema JSON Schema 2020-12 with the named types
under `$defs`, keys sorted) and the table below (`registry::markdown_table()`). Tests fail when either is out of date;
`UPDATE_METHODS_JSON=1 cargo test -p runstav registry` (through the cargo wrapper) writes both again. In the table
`{a: T, b?: T}` is an object with `a` required and `b` optional (absent or `null`), `[T]` a list, `A | B` either, and
a capitalised name a named type (below) or, in results, a record (`JobSummary`, `Snapshot`, `Entry`, `EventRow`,
`HubStatus`, `HelloReply`: their fields are in `methods.json`). A params schema never holds an unconstrained value (`any`); a
result may (a transcript entry's ACP fields, a job's tasks).

<!-- hub-methods:begin -->
| Method | Class | Params | Result | Writes | Home |
|---|---|---|---|---|---|
| `agents/do` | user | `{id: Id, item?: RequestId, n?: natnum, op: "deliver-queue" \| "unqueue" \| "requeue" \| "review", reject?: boolean, text?: Prompt}` | `boolean` | yes | backend |
| `agents/get` | user | `{id: Id}` | `{entries?: [Entry], seq: natnum, session: Snapshot}` | no | backend |
| `agents/kill` | user | `{id: Id}` | `boolean` | yes | backend |
| `agents/list` | user, agent, service | `{}` | `{sessions?: [Snapshot]}` | no | backend |
| `agents/permission` | user | `{id: Id, option?: string, request: RequestId}` | `boolean` | yes | backend |
| `agents/send` | user | `{id: Id, text: Prompt}` | `boolean` | yes | backend |
| `agents/start` | user | `{cwd?: AbsPath, job?: Id, profile: string, task?: TaskRef}` | `{id: string, name: string}` | yes | backend |
| `agents/stop` | user | `{id: Id}` | `boolean` | yes | backend |
| `cards/settle` | user | `{card: natnum, choice: Text}` | `{settled: boolean}` | yes | front |
| `config/changed` | user | `{}` | `boolean` | no | front |
| `config/settings` | user | `{overrides: [{name: string, source: string, value: SettingValue}], project?: string}` | `{applied: natnum}` | no | front |
| `coord/agent` | user | `{register?: {base?: string, branch?: string, clear?: ["kind" \| "name" \| "cwd" \| "worktree" \| "branch" \| "base" \| "plan" \| "task" \| "pid"], cwd?: string, id: AgentName, kind?: string, name?: string, pid?: natnum, plan?: string, task?: TaskRef, worktree?: string}, seen?: AgentName}` | `{id?: string, seen?: number}` | yes | front |
| `coord/card-create` | user | `{data?: JsonObject, job?: Id, kind?: string, task?: TaskRef, title?: Text}` | `{id: natnum}` | yes | front |
| `coord/card-set` | user | `{data?: JsonObject, id: natnum, state?: Status, title?: Text}` | `boolean` | yes | front |
| `coord/decide` | user | `{author: AgentName, job?: Id, kind: string, paths?: Text, reason?: Text, replaces?: natnum, seen?: natnum, subject: Text, task?: TaskRef}` | `Decided` | yes | front |
| `coord/held` | user | `{agent: AgentName, held: boolean}` | `boolean` | yes | front |
| `coord/job-create` | user | `{data?: JsonObject, id: Id, plan?: string, repo?: string, tasks?: [{deps?: [natnum], n: natnum, role?: string, title: Text}], title: Text}` | `{id: string}` | yes | front |
| `coord/job-set` | user | `{data?: JsonObject, id: Id, status?: Status}` | `boolean` | yes | front |
| `coord/leases` | user | `{release_stale?: boolean, renew?: [AgentName]}` | `{released?: [Released]}` | yes | front |
| `coord/notify` | user, agent, service | `{}` | `boolean` | no | front |
| `coord/prune` | user | `{}` | `{pruned: boolean}` | yes | front |
| `coord/task-status` | user | `{agent?: AgentName, status: Status, task: TaskRef}` | `boolean` | yes | front |
| `env/set` | user | `{env: [{name: EnvName, value: string}]}` | `{applied?: [string]}` | no | backend |
| `events/add` | user | `{agent?: AgentName, best_effort?: boolean, data?: JsonObject, job?: Id, kind: "start" \| "stop" \| "claim" \| "release" \| "status" \| "decision" \| "edit" \| "test" \| "question" \| "answer" \| "review" \| "message" \| "card" \| "accept" \| "revert" \| "comment" \| "job", summary?: Text, task?: TaskRef}` | `{id?: natnum}` | yes | front |
| `events/since` | user | `{limit?: natnum, since?: natnum}` | `{events?: [EventRow], last: natnum, since: natnum}` | no | front |
| `gateway/editor-token` | user | `{}` | `{token: string, url: string}` | no | front |
| `gateway/keys` | user | `{keys: ProviderKeys}` | `boolean` | no | front |
| `gateway/keys-held` | user | `{}` | `{providers?: [Id]}` | no | front |
| `gateway/register` | user | `{agent?: AgentName, budget?: Usd, chain: [[string \| null]], job?: Id, keys?: ProviderKeys, openrouter?: {data-collection?: "deny" \| "allow", ignore?: [string], only?: [string], zdr?: boolean}, owner?: natnum, sid?: SessionId, task?: TaskRef}` | `{openrouter?: any, socket?: string, token: string, url?: string}` | no | front |
| `gateway/set-budget` | user | `{budget: Usd, job: Id}` | `boolean` | no | front |
| `gateway/unregister` | user | `{token: string}` | `boolean` | no | front |
| `graph/backup` | user | `{}` | `BackupAnswer` | no | front |
| `graph/compact` | user | `{dry_run?: boolean}` | `{dry_run: boolean, link_stats: natnum, versions: natnum}` | yes | front |
| `graph/entity` | user | `{as_of?: natnum, id: string, include?: ["links" \| "notes" \| "history"]}` | `EntityAnswer` | no | front |
| `graph/excise` | user | `{fields?: ["title" \| "status" \| "body" \| "assignee" \| "data"], reason: Text, rotate_backups?: boolean, target: ExciseTarget, transcripts?: boolean}` | `ExciseAnswer` | yes | front |
| `graph/export` | user | `{history?: boolean, out?: AbsPath, project?: string, since?: natnum, with_activity?: boolean}` | `PortAnswer` | no | front |
| `graph/grants` | user | `{grant?: {access: "read" \| "edit-user-tasks" \| "options", expires?: number, names?: [string], what: string, who: string}, list?: {active?: boolean, who?: string}, revoke?: string}` | `{grant?: GrantView, grants?: [GrantView], revoked?: boolean}` | yes | front |
| `graph/history` | user | `{id: string, since?: natnum}` | `{versions?: [any]}` | no | front |
| `graph/import` | user | `{dir: AbsPath}` | `PortAnswer` | yes | front |
| `graph/neighbors` | user | `{as_of?: natnum, depth?: natnum, direction?: "out" \| "in" \| "both", id: string, kinds?: [string]}` | `{hidden: natnum, links?: [any], nodes?: [any], truncated?: string}` | no | front |
| `graph/path` | user | `{as_of?: natnum, from: string, kinds?: [string], max_depth?: natnum, to: string}` | `{hidden: natnum, links?: [any], nodes?: [any], truncated?: string}` | no | front |
| `graph/privacy` | user | `{delete_copies?: [string], reload: boolean}` | `PrivacyAnswer` | yes | front |
| `graph/proposed` | user | `{accept?: [natnum], reject?: [natnum]}` | `{blocked?: [integer], listed?: boolean, reverted?: Reverted}` | yes | front |
| `graph/put-parsed` | user | `{collected?: [string], gone?: [{kind: "file" \| "spec" \| "commit" \| "branch", path?: AbsPath}], root?: AbsPath, sources?: [{entities?: [{data?: JsonObject, id: string, kind: string, status?: Status, title?: Text}], links?: [{dst: string, kind: string, origin?: "parsed" \| "inferred", src: string}], mtime?: number, source: {kind: "file" \| "spec" \| "commit" \| "branch", path?: AbsPath}}], updates?: [{data_patch?: JsonObject, id: string, status?: Status}]}` | `{changed: natnum, refused?: [Refusal], retired: natnum}` | yes | front |
| `graph/record` | user | `{collected?: string, commits: [{date: number, seq?: integer, sha: string, subject: Text}], repo: AbsPath, task: string}` | `{ids?: [string]}` | yes | front |
| `graph/revert` | user | `{cascade?: boolean, entity?: string, tx?: natnum, ver?: natnum}` | `{blocked?: [integer], listed?: boolean, reverted?: Reverted}` | yes | front |
| `graph/scrub` | user | `{}` | `{blocked_by?: string, vacuumed: boolean, wal_truncated: boolean}` | yes | front |
| `graph/settings` | user | `{get?: Empty, set?: {only_user_closes?: boolean}}` | `{only_user_closes: boolean}` | yes | front |
| `graph/sql` | user | `{deadline_ms?: natnum, params?: [SqlParam], rows?: natnum, sql: string}` | `{columns?: [string], rows?: [[any]], truncated: boolean}` | no | front |
| `hello` | user, agent, service | `{client?: string, cwd?: AbsPath, drgnx_version?: string, nonce: Nonce, proof?: Hex64, proto: natnum, records?: natnum, schema?: natnum}` | `HelloReply` | no | front |
| `job/approve` | user | `{budget?: Usd, id: Id}` | `JobSummary` | yes | backend |
| `job/block` | user | `{reason?: Text, task: TaskRef}` | `JobSummary` | yes | backend |
| `job/card` | user | `{action: CardAction, arg?: StringOrNumber, card: natnum}` | `JobSummary` | yes | backend |
| `job/dismiss` | user | `{message: natnum}` | `boolean` | yes | backend |
| `job/order` | user | `{delta: Delta, task: TaskRef}` | `JobSummary` | yes | backend |
| `job/propose` | user | `{auto?: boolean, budget?: Usd, gate?: "review" \| "review+accept", plan: AbsPath, repo?: AbsPath}` | `JobSummary` | yes | backend |
| `job/reassign` | user | `{profile: string, task: TaskRef}` | `JobSummary` | yes | backend |
| `job/reply` | user | `{message: natnum, text: Prompt}` | `boolean` | yes | backend |
| `job/resume` | user | `{budget?: Usd, id: Id}` | `JobSummary` | yes | backend |
| `job/start-task` | user | `{auto?: boolean, gate?: "review" \| "review+accept", n: natnum, plan: AbsPath}` | `JobSummary` | yes | backend |
| `job/status` | user | `{decisions?: boolean, id?: Id}` | `JobSummary \| {jobs?: [JobSummary]}` | no | backend |
| `job/stop` | user | `{id: Id}` | `JobSummary` | yes | backend |
| `job/unblock` | user | `{task: TaskRef}` | `JobSummary` | yes | backend |
| `mcp/attach` | service | `{kind: AgentKind}` | `{identity: string}` | no | front |
| `mcp/session` | user | `{agent: AgentName, cwd?: AbsPath, job?: Id, owner: natnum, profile?: Id, sid?: SessionId, task?: TaskRef, tools?: {tracker: boolean}}` | `{sid: string, socket: string}` | no | front |
| `mcp/session-close` | user | `{sid: SessionId}` | `boolean` | no | front |
| `messages/mark` | user | `{id: natnum, state: "delivered" \| "read" \| "acted"}` | `{changed: boolean}` | yes | front |
| `messages/send` | user | `{answers?: natnum, job?: Id, question?: boolean, recipient: AgentName, seen?: natnum, sender?: AgentName, text: Text}` | `SendResult` | yes | front |
| `ping` | user, agent, service | `{}` | `{pid: natnum}` | no | front |
| `restart` | user | `{}` | `boolean` | no | front |
| `review/mark` | user | `{agent: AgentName, event?: {data?: JsonObject, job?: Id, kind: "start" \| "stop" \| "claim" \| "release" \| "status" \| "decision" \| "edit" \| "test" \| "question" \| "answer" \| "review" \| "message" \| "card" \| "accept" \| "revert" \| "comment" \| "job", summary?: Text}, hash: string, path: string, state: "accepted" \| "pending"}` | `boolean` | yes | front |
| `settings/confirm` | user | `{error?: string, ok: boolean, tx: natnum}` | `{state: "accepted" \| "reverted" \| "blocked"}` | yes | front |
| `settings/explained` | user | `{req: natnum, settings: [JsonObject]}` | `boolean` | no | front |
| `settings/record` | user | `{changes: [{file: string, id: string, line?: natnum, value?: Text}], req: string, reverts?: natnum, tool: string}` | `{tx: integer}` | yes | front |
| `shutdown` | user | `{}` | `boolean` | no | front |
| `spend` | user, agent, service | `{agent?: AgentName, job?: Id, task?: TaskRef}` | `{cost: number, input: natnum, output: natnum, requests: natnum}` | no | front |
| `status` | user, agent, service | `{}` | `HubStatus` | no | front |
| `subscribe` | user | `{}` | `boolean` | no | front |
| `tasks/find` | user | `{assignee?: string, cursor?: natnum, labels?: [string], project?: string, query?: Text, status?: Status}` | `{cursor?: natnum, tasks?: [any]}` | no | front |
| `tasks/ready` | user | `{labels?: [string], limit?: natnum, project?: string}` | `{cursor?: natnum, tasks?: [any]}` | no | front |
| `tasks/write` | user | `{acceptance?: Text, add?: [string], body?: Text, cwd?: AbsPath, dst?: string, id?: string, kind?: string, labels?: [string], lease?: integer, mode?: "children" \| "replace", note?: Text, op: "create" \| "update" \| "claim" \| "heartbeat" \| "release" \| "handoff" \| "reassign" \| "split" \| "complete" \| "link" \| "unlink" \| "label" \| "tools", parent?: string, parts?: [Text], priority?: integer, project?: string, remove?: [string], src?: string, status?: Status, title?: Text, to?: string, tracker?: boolean, ver?: integer}` | `any` | yes | front |
<!-- hub-methods:end -->

### Classes

A connection's class is what it proved. `test/conformance/class-matrix.json` is a hand-written copy of every
method's classes (a test checks that it and the registry agree; the conformance row `class/matrix` calls every
method from every class).

| Class | Who | What proves it |
|---|---|---|
| `user` | the editor, the CLI, the Lisp backend hub during migration | a `hello` whose `proof` is HMAC-SHA256 with the cap of `"drgnx-hub client " + hub nonce + " " + nonce`: it read the cap file beside the socket |
| `agent` | a sandboxed job agent and the servers the hub starts for it | the socket it came in on (the session's own): its session is bound to the connection |
| `service` | outside agents' coordination bridges, probes, anything without a proof | nothing (the default) |

| Classes | Methods |
|---|---|
| user, agent, service | `hello`, `ping`, `status`, `coord/notify` (users too: SB-T12-4), `agents/list`, `spend` |
| user | `restart`, `shutdown`, `subscribe`, `events/since`, `env/set`, `config/settings`, `config/changed`, `gateway/register`, `gateway/unregister`, `gateway/keys`, `gateway/set-budget`, `gateway/editor-token`, `gateway/keys-held`, `agents/{start,get,send,stop,kill,permission,do}`, `job/{propose,start-task,reassign,block,unblock,order,approve,stop,resume,card,reply,dismiss,status}`, the editor's writes `cards/settle`, `messages/{send,mark}`, `events/add`, `review/mark`, the seam's `coord/{job-create,job-set,task-status,leases,decide,agent,card-create,card-set,held,prune}`, and `mcp/{session,session-close}` |
| service | `mcp/attach` (an outside agent's bridge: [Sessions and their sockets](#sessions-and-their-sockets)) |

Everything that answers, approves, starts, stops, configures or reads a transcript is `user` only. What the other
classes see of the shared methods: `agents/list` gives a `service` the `{id, name, job, task}` of every session and an
`agent` the same of its own job's; `spend` of an `agent` is its own job's. The methods that write work.db (`writes`,
refused with `schema` while the hub is read-only) are
`agents/{start,send,stop,kill,permission,do}`, every `job/…` but `job/status`, and the front's writes (the editor's
five and the seam's ten `coord/…`, all but `coord/notify`).

### Types

The named input types (`runtime/crates/runstav/src/types.rs`): each validates as it decodes, and a value that does
not fit is refused with its path, never rewritten. Lengths count characters, as JSON Schema's `maxLength` does; each
type's schema carries the same `pattern` and `maxLength`.

| Type | Rule |
|---|---|
| `Id` | `^[A-Za-z0-9][A-Za-z0-9._:+-]*$`, at most 128 |
| `AbsPath` | `^/[^/:\0]*(/[^\0]*)?$`, at most 4096: absolute, no NUL, and no `:` in the first component, so a TRAMP name (`/ssh:host:/x`) is refused |
| `EnvName` | `^[A-Za-z_][A-Za-z0-9_]*$`, at most 128 |
| `Prompt` | at most 1 MiB (1048576 characters) |
| `Text` | at most 64 KiB (65536 characters) |
| `Nonce` | `^[0-9a-f]{32}$` |
| `Hex64` | `^[0-9a-f]{64}$` |
| `TaskRef` | no control characters, 1 to 512 |
| `AgentName` | no control characters, at most 256 |
| `SessionId` | `^[A-Za-z0-9_-]+$`, at most 64: a session directory's name (`mcp/session`) |
| `AgentKind` | `^[a-z0-9][a-z0-9_-]*$`, at most 32: an outside agent's kind (`mcp/attach`) |
| `CardAction` | `^[a-z][a-z-]*$`, at most 32 |
| `RequestId` | a natural number, or a string of at most 128 |
| `Usd` | a number in 0..=1000000 |
| `Delta` | an integer in -1000..=1000 (`job/order`) |
| `StringOrNumber` | a string of at most 4096, or a number (`job/card`'s `arg`) |
| `Status` | a job's, task's or card's state: `^[a-z][a-z-]*$`, at most 32 |
| `JsonObject` | a JSON object of at most 64 KiB (65536 bytes as JSON): a stored `data` |
| `ProviderKeys` | an object `Id` → key, at most 32 keys of at most 4096 each; kept secret (no `Debug`), never serialised: it goes to the gateway's memory |
| `Bounded<T, MAX>` | a string or list of at most MAX: every bound of the contract (`env/set`'s list: 16, a value 32768; a chain: 16 steps of `[provider, model-or-null]`; a profile: 128) |

`env/set`'s value for `PATH`, `MANPATH` and `INFOPATH` must be a `:`-separated list of absolute directories (no
empty, relative, `~` or remote entry; SB-T12-7): another is refused at `env[N].value`. Whether each directory exists
is the backend's check.

### Event types

`runstav::events::events()` (`src/events.rs`), each with the type of its `data`, decoded and encoded again as a
result is (`event(NAME).check`):

| Event | From | Data |
|---|---|---|
| `agent` | sessions | `{id, seq, session: Snapshot}` |
| `agent-entries` | sessions | `{id, seq, entries: [[index, Entry]]}` |
| `events` | the event log (the front's writer: [Events](#events)) | `{since, last, events: [{id, at, agent, job, task, kind, summary, data?}]}` |
| `lease-released` | the hub's housekeeping | `{task, agent, job}` |
| `fallback` | the gateway (the front), jobs (the backend) | `{agent, from, to, why}`, from a job with `job` and `task` too |
| `card` | jobs | `{id, job, task, kind, title}` |
| `job` | jobs | `{id}`: its status, tasks or open cards changed |
| `budget` | the gateway | `{job, spent, budget}` |
| `request` | the gateway | `{job, task, agent, provider, model, status, input, output, cost}` |
| `gateway/need-keys` | the gateway | `{providers: [Id]}`: a request needed these providers' keys, which the hub does not hold (at most once a minute each; a subscriber that connects later gets the pending ones after its `subscribe` answer) |
| `gateway/keys-changed` | the gateway | `{providers: [Id]}`: the ids whose key the hub holds, sent when that set changes (`gateway/keys`, a registration's `keys`); never a key ([The editor's token](#the-editors-token)) |
| `challenge` | the front, on accept | `{nonce}` |
| `notice` | the front | `{source, severity, id, life, text, command?}` |
| `settings/proposed` | the front (`settings_change`) | `{tx, scope, name, value, root?, agent, reason}`: the editor checks it, writes the file, answers `settings/confirm` ([Agents change settings](#agents-change-settings)) |
| `settings/explain` | the front (`settings_get`) | `{req, scope, names?, root?}`: the editor answers `settings/explained` with the same `req` |

Each event type says which side sends it (`from`, in `methods.json`): `events`, `challenge` and `notice` the front,
the rest the backend. The first nine are what the Lisp backend broadcasts on main (its `events` is dropped under
Ratatoskr until it stops sending it); a test reads `core/*.el` for its `(drgnx-hub--broadcast
'NAME`, `(drgnx-job--broadcast 'NAME` and `drgnx-gateway--emit 'NAME` calls and fails when the two lists differ.

## Per-session sockets

A sandboxed session's agent reaches drgnx's MCP servers through a dir of its own, served by the hub
(`core/drgnx-sandbox-mcp.el`). The agent's side, the bridge, is in [sandbox.md](sandbox.md#mcp-through-a-socket).
For `mcp.sock` the hub's server per connection is `ratatoskr mcp-bridge --socket` to the session's own Rust socket (the
`mcp/session` the agent start made, `:mcp-socket`), so the tools are the Rust ones; a session without one refuses the
connection. `search.sock` is unchanged.

- **Where.** `(drgnx-sandbox-mcp-dir SID)` is `s/SID` beside the hub's socket: `$XDG_RUNTIME_DIR/drgnx/s/SID`, or
  `s/SID` beside the hub socket's fallback place. These are the dirs of `drgnx-sandbox-sessions-dirs`, so the sandbox
  may bind it as its `:run` (`/run/drgnx` inside on Linux, its own path on macOS). Each level is made by
  `drgnx-hub--private-dir`: mode 0700, this user's, never a link. SID is a name (letters, digits, `-`, `_`), never a
  path. A socket's path there must fit 103 bytes, or there is no dir.
- **Sockets.** `(drgnx-sandbox-mcp-open S &optional SEARCH)` listens on `mcp.sock` (coordination) and, when SEARCH
  is given, on `search.sock`. SEARCH is the job's project root, given by name and spelled as its index is: a value
  that is not a string, a root that is S's folder or lies inside it, or a folder the VC guard lists
  (`drgnx-sandbox-vc-guarded-p`, or inside one), is an error, because the search server runs
  git in its root and nothing outside the sandbox runs git in a task folder. The search server is **pinned** to that
  root (`DRGNX_SEARCH_PINNED=1`): a `path` argument outside it is refused, and one inside it searches the root, so
  no git runs where the agent points and no other project's index is read (`drgnx-search-mcp--pinned-root`). It sets
  S's `mcp-dir` and returns the dir. `hub.sock` is kept in the same dir for the hub protocol's agent class, which is
  not served yet.
- **One server per connection, outside the sandbox.** The hub starts the server of `drgnx-coord-mcp-server-spec`
  (or `drgnx-search-mcp-server-spec`) as a child of its own. Its environment is the hub's, with `DRGNX_AGENT` = S's
  id, `DRGNX_JOB` and `DRGNX_TASK` = S's, and the data-dir variables set from the spec. The hub's own
  `DRGNX_AGENT`, `DRGNX_AGENT_KIND`, `DRGNX_JOB` and `DRGNX_TASK` are unset. The server works in the session's dir,
  never in the task folder: the coordination server runs git where it starts. Its stdio is spliced to the
  connection. **The socket a connection comes in on is the identity.**
- **Every byte from the socket is hostile.** Lines are split linearly (`drgnx-mcp-bridge--feed`). A line over
  `drgnx-mcp-bridge-max-line` (16 MiB), or one that is not a JSON object, closes the connection and ends its server,
  unforwarded. Writes either way go through the hub clients' queue (`drgnx-hub--enqueue`): a side that stops reading
  for `drgnx-hub-client-stuck-after` seconds, or past `drgnx-hub-client-max-queued` bytes, is dropped. A socket
  serves at most `drgnx-sandbox-mcp-max-connections` (4) connections at once; more are closed as they come.
- **Ends.** A connection that closes ends its server; a server that ends closes its connection. The session's end
  (its agent exits, or `drgnx-agents-kill`) calls `(drgnx-sandbox-mcp-close S)`: every server and connection, the
  listeners and the dir go.
- **What the agent gets.** `(drgnx-sandbox-mcp-server-specs S INSIDE-DIR)` gives the `mcpServers` entries `drgnx`
  and, when `search.sock` listens, `drgnx-search`. Each runs `drgnx-mcp-bridge-command` on its socket in INSIDE-DIR,
  with an empty `env`. `drgnx-agents--mcp-servers` gives them instead of the stdio servers when S's `mcp-dir` is set.
  Every other session, interactive agents included, keeps the stdio servers.

Tests: `test/unit/sandbox-mcp-test.el` (`drgnx-sandbox-mcp/`).

## Sessions and their sockets

Under Ratatoskr the coordination tools (`norn::tools`, served by `mimir`) run in the hub itself, with no server
process per connection (`runtime/crates/drgnx-ratatoskr/src/sessions.rs`). Two doors lead to them, and neither takes
an identity from the agent: not from a tool's arguments, and never from `DRGNX_AGENT` (the hub's own is ignored).

- **A session's socket (`mcp/session`, user).** `{agent, sid?, job?, task?, cwd?, owner}` answers `{sid, socket}`.
  - Without `sid` the hub mints one (12 hex digits of `getrandom`) and makes its directory with
    `runstav::paths::make_session_dir` (Gleipnir's session directory: `s/SID` beside the main socket, or under
    `<tmp>/drgnx-hub-UID/` when the longest socket name, `gateway.sock`, would not fit 103 bytes; each level 0700, the
    user's). With `sid`, `mcp.sock` goes beside the session's agent `hub.sock`: one directory per session.
  - `agent` is an agent's id (letters, digits, `.`, `_`, `:`, `-`; never `user`: `invalid-params` at `agent`).
    `owner` is the pid of the process the session belongs to; it must be running (`invalid-params` at `owner`), and its
    start time is kept with it.
  - The row `msession(sid, agent, job, task, cwd, owner, owner_start, at)` is written to `runtime.db` **before**
    `mcp.sock` is bound (0600): a hub that dies in between leaves a row the next start binds. A bind that fails deletes
    the row again.
  - Whoever connects is that agent: the tools act as `agent` (with its `job` and `task`), their home is `cwd` (`/`
    without one). The peer's uid is checked as on every socket, there is no challenge (the first byte is MCP), and a
    socket serves at most 4 connections at once: a fifth is closed with nothing said and logged.
- **Closing.** `mcp/session-close {sid}` (user) answers `true` once (`false` for a session that is not open): the
  socket, the directory (unless the session's `hub.sock` is still in it) and the row go, then its connections are
  closed — a client that sees its connection close finds the rest gone. Each second the hub closes the sessions whose
  owner is gone: not running, a zombie, or a pid the system gave to a new process (another start time).
  `__test_owner_gone {owner}` (test hooks) closes an owner's sessions at once and answers `{closed: N}`.
- **Across a restart.** At the stop the sockets are unbound and their connections end; rows and directories stay. At
  the next start, after the reaper, each row whose owner runs with its recorded start time is bound again at the same
  path (a bridge redials it); the others are deleted with their directories. A newer-schema `runtime.db` that is moved
  aside loses them (step 5 of the start order).
- **An outside agent's bridge (`mcp/attach`, service).** The bridge of an agent drgnx did not start connects to the
  main socket, says `hello` without a proof but with its `cwd` (it stays `service`), then
  `mcp/attach {kind}` (`AgentKind`, e.g. `claude`). The hub reads the connection's peer (`SO_PEERCRED`;
  `LOCAL_PEERPID` on macOS), that process's parent and the parent's start time (`/proc/PID/stat`; `proc_pidinfo` on
  macOS; elsewhere unsupported), and answers `{identity: "ext:KIND:PID-HASH"}`: PID the parent's, HASH the first 6
  hex digits of the SHA-1 of its start time in whole seconds. A parent that is init (pid 1) is refused (`not-allowed`,
  "an outside agent needs a parent process"). After the answer line the same connection carries MCP, with
  `hello`'s `cwd` as the tools' home; whatever the bridge sent after `mcp/attach` is read as MCP. An outside identity
  is unverified: it may report, but a job's tools (`claim_task`, `update_task`, `complete_task`, `record_decision`)
  are a tool error for it.
- **What `status` says.** `mcp: {sessions, outside}`: the session sockets bound and the outside bridges attached.

Rows: `test/conformance/mcp/`.

## The MCP bridge

An agent speaks MCP over stdio; `ratatoskr mcp-bridge` is that stdio server, and it copies lines to the hub
(`runtime/crates/drgnx-ratatoskr/src/bridge.rs`; the state machine is `mimir::bridge`). Claude Code never respawns a
stdio server that died (anthropics/claude-code#82746), so the bridge outlives the hub instead (design §5.8).

- **Inside: `mcp-bridge --socket PATH`.** PATH is a session's `mcp.sock` (`mcp/session`). It must be a socket when
  the bridge starts (exit 1 otherwise); after that the bridge connects with no challenge and the first byte is MCP.
  The socket is the identity: nothing in the bridge's environment (`DRGNX_AGENT` included) is read.
- **Outside: `mcp-bridge --outside --kind KIND [--cwd DIR]`.** For an agent drgnx did not start. The bridge finds the
  main socket as every client does (its environment's data dir), checks the socket's directory first (the Lisp
  client's rule: the user's, 0700; otherwise it ends with exit 1 and the reason on stderr, never connecting), reads
  the challenge, says `hello {proto: 1, nonce, client: "mcp-bridge", cwd}` with no proof (the connection stays
  `service`) and `mcp/attach {kind}`; the next byte is MCP. `cwd` is `--cwd`, else the bridge's working directory.
  A refused `hello` or `mcp/attach` ends the bridge with exit 1; a hub that is not there yet is dialled again.
- **When the hub goes away.** The bridge dials again after 0.1 s, doubling to 5 s between dials, and gives up after
  10 min without a connection (exit 1, "giving up" on stderr). On each reconnect it replays the agent's cached
  `initialize` under an id of its own (the answer is dropped: the agent has one) and `notifications/initialized`,
  fetches `tools/list` once, and sends the agent `notifications/tools/list_changed` when the list differs. The
  stateless era (2026-07-28) has nothing to replay. An outside bridge says `hello` and `mcp/attach` again.
- **While it is away.** `tools/list` and `server/discover` are answered from the cache, `ping` with `{}`. Any other
  request waits up to 10 s for the socket (the bridge dials at once), then a `tools/call` gets the tool error
  `drgnx hub restarting; retry` and anything else `-32603`.
- **A call caught by the drop is never sent again.** A write has no request key before schema 7, so a resend could
  write twice: a `tools/call` in flight when the socket dropped gets a tool error that says the hub went away and the
  effect is unknown (check `read_inbox`, `task_status` or `read_decisions` before a retry); the agent decides. Any
  other request in flight gets `-32603`.
- **Lines.** An agent line over 1 MiB is answered `-32600` on its id (dropped without one) and the bridge goes on; a
  hub line over 16 MiB drops the connection (and the bridge redials).
- **The end.** The agent closing stdin ends the bridge at once with exit 0 (MCP stdio), as does a closed stdout.
  Warnings (the hub went away, came back) go to stderr.

Test hooks: `--bridge-backoff-ms N` and `--bridge-give-up-ms N` shorten the timings. Rows: `test/conformance/bridge/`.

## Registrations

The gateway runs in Ratatoskr (`runtime/crates/drgnx-ratatoskr/src/gateway.rs`, forwarding by
[`bifrost`](runtime.md#bifrost-the-gateway)): the front serves `gateway/register`, `gateway/unregister`,
`gateway/keys`, `gateway/set-budget`, `gateway/editor-token`, `gateway/keys-held` and `spend`
itself, and none of them reaches the Lisp backend.

`gateway/register {chain, job?, task?, agent?, budget?, openrouter?, keys?, owner?, sid?}` returns `{token, url?,
socket?, openrouter?}`: a token of 64 hex digits (32 random bytes) and, without `sid`, the loopback URL
`http://127.0.0.1:PORT`; with `sid`, the session's `gateway.sock` (`SDIR/gateway.sock`, 0600, bound once per session
and served until the session closes) instead, for an agent in a sandbox without the host's loopback.

- **The chain is judged first.** A step whose provider is not in the table ("not configured"), does not speak
  Messages ("the gateway cannot carry it") or has no key ("no key") cannot be used; with none usable the registration
  is refused, `invalid-params` at `chain` with every step's reason ("no step of the chain can be used: nowhere: not
  configured; embedder: the gateway cannot carry it"), or, when every step only lacks its key, "No key for P in the
  drgnx hub: an editor hands its keys over when it connects". Nothing is kept.
- **Only the hash is kept.** The registration lives in memory (what `bifrost` admits by) and in `runtime.db`'s
  `registration` table (`<state>/hub/runtime.db`, 0600; migration 3), keyed by the SHA-256 of its token: the token is
  answered once and is in no file, log or table. The row is written before the answer, so a token always has its
  row. `gateway/unregister {token}` removes both (true).
- **Owners.** A registration's owner is `owner` when given (a live pid, else `invalid-params` at `owner`), else the
  caller's pid as the system reports it (the peer's credentials), with that process's start time. At start and on
  each tick (1 s) the hub prunes a registration whose owner is gone or whose pid now names another process (another
  start time), and one bound to a session that closed (M9b1-10). One without an owner stays until it is
  unregistered. The Lisp backend registers the agents it starts with its own pid as `owner`: they are its children,
  so they end with it, and so do their tokens.
- **Across a restart** the rows are read back (a row that does not read is dropped and logged), owners checked again,
  the sessions' sockets bound again, and the gateway's port too: `runtime.db`'s `kv.gateway_port` is tried first,
  else a free one (logged), and the one used is kept.
- **Budget.** A registration's `budget` (USD), else its job's `data.budget` in work.db. `gateway/set-budget {job,
  budget}` sets it for every registration of the job, in memory and in `runtime.db` (the editor's `job resume
  --budget`).

**The provider table** is the settings' ([Settings](#settings)): the presets and the providers of `settings.el` and of
the editor's global `config/settings` override, replaced whole whenever either changes (there is no `config/providers`
any more). Each entry becomes `{id, kind, base, auth, messages, caps, price?}` (`kind` one of `openai ollama llamacpp
tei anthropic`, `auth` one of `bearer x-api-key none`). `base` follows the URL rule (`runstav::url::provider_base`):
`https`, or `http` for any host, never a user, password, fragment or control character; a provider with a bad one is
left out with a settings problem (a `notice`). A keyed provider over `http` off loopback is applied
with a warning, "ID's key travels in clear text over http://HOST; use https" (the user's answer 4): in
`status`'s and the doctor's `gateway.warnings`, and in the hub log once per provider per start. A keyless one there
has none. The last good table is the settings' (`settings-last-good` and `settings-override:*` in `runtime.db`'s
`kv`; it holds no key), in effect again at start.

## Forwarding

`bifrost` admits and forwards ([runtime.md](runtime.md#bifrost-the-gateway) has its rules): an agent's request on
127.0.0.1 (`Host` must be `127.0.0.1:PORT` or `localhost:PORT`) or on its session's socket shows its token as
`Authorization: Bearer` or `x-api-key`; only Anthropic Messages paths are forwarded (`/v1/messages`,
`/v1/messages/count_tokens`, `/v1/models[/ID]`), to the steps of its chain in turn, the provider's key added and the
agent's token never passed on. `status.gateway` counts requests, errors, fallbacks and the bytes each way.

Spend: each request's usage (the answer's `cost` when given, else the provider's `price`, USD per million tokens) is a
`spend` row in `work.db` (`norn::write::spend`), recorded before its `request` event. The budget is checked before
forwarding: a job whose spend reached its budget gets 429 `budget_exceeded` and a `budget` event, and the request
whose spend reaches the budget sends that event as soon as its row is written. The front sends each `budget` to its
subscribers and to the Lisp backend as a notification, `budget {job, spent, budget}` (fire and forget), so the job
pauses without waiting for the next request. `spend {job?, task?, agent?}` sums the rows (an agent: its own job's).

## Keys

Provider keys reach the hub from a user connection only: `gateway/keys {keys: {PROVIDER: KEY}}` (an editor hands its
keys over once each subscription is answered, `drgnx-hub-ensure` and so `drgnx hub start` too) and a registration's
`keys`. They are held in Ratatoskr's
memory only (`bifrost::keys::Keys`): never in `runtime.db`, a file, a log, an environment, a command line or the Lisp
backend; the last key handed over for a provider wins. An empty key is no key: it is skipped, so it never replaces a
held one or marks its provider held (the editor never sends one either). `status` and the doctor name the providers whose key is held
(`keys_held`), never a key. A restarted hub holds no key until an editor connects again; meanwhile a request that
needs one fails over or answers "no key", and the `gateway/need-keys {providers}` event (also sent to each new
subscriber for the providers kept registrations need) tells the editor to hand them over. The hub is not dumpable
([Stopping a hub](#stopping-a-hub)), so another process of the user's cannot read them from its memory.

The Lisp hub (v0, before Ratatoskr) still has its own gateway, `core/drgnx-gateway.el`: registrations in
`<state>/hub/registrations.eld` (hashes only), the port in `<state>/hub/port`, keys in its memory, curl per request.
Behind Ratatoskr (`drgnx-hub--behind-front`) the Lisp backend runs none of it — no listener, no registrations.eld, no
port file — and holds no key:
- `drgnx-hub-register` calls the front's `gateway/register` (`drgnx-hub-call-front`), with the backend's pid as
  `owner` and never `keys` (that connection refuses a `gateway/register` that carries them). The front judges the
  chain and its keys; a refusal fails the agent's start with the front's text, and there is no direct route.
- `drgnx-job-resume`'s budget goes to the front as `gateway/set-budget`.
- The front's `budget {job, spent, budget}` notification lands in `drgnx-hub--method` and goes to
  `drgnx-job--gateway-event`: the job pauses, its busy sessions stop, a "spent N of M USD: paused" card.

**The editor's side** (`core/drgnx-hub-client.el`):
- **The runtime settings** (`core/drgnx-settings-runtime.el`). Once a subscription is answered (`drgnx-hub--subscribed`),
  and from `drgnx-hub-ensure`, an editor sends `config/settings` (`drgnx-settings-runtime-send`) with the runtime
  settings whose value comes from your Lisp or Customize rather than settings.el (`drgnx-settings-runtime-overrides`,
  by `drgnx-settings-explain`'s winner); the hub reads settings.el itself, and the presets are its own. A provider goes
  in `ProviderEntry` form (`{kind, url, key_env, caps, price: [in, out], messages, auth, name}` per id), never a key.
  The set is sent again on `drgnx-settings-changed-functions`, per project (`:project`, once Urdr names it) for what a
  workspace file sets, and `config/changed` follows each write of settings.el (`drgnx-settings-file-written-functions`).
  An empty list clears the set. Only an editor subscribed to a hub that proved itself sends on a change; the next
  connection sends the set anyway.
- **`gateway/need-keys`** (`drgnx-hub--need-keys`, on the subscription) is answered only on a proven connection
  (`drgnx-hub--event-conn`'s `:drgnx-proven`). For each provider the key is looked for again as the hand-over does
  (`drgnx-ai-key` without INTERACTIVE: its `:key-env` variable, else auth-source's sources that never ask, read
  without keeping anything); found keys go with `gateway/keys` and are dropped once taken. It runs in a process
  filter, a daemon path, so nothing asks (no `.gpg` file, Keychain or keyring); a key not found is a `hub` notice
  "agents need your P key in the drgnx hub: run AI: Load Keys". The keys and the table go after the subscription's
  answer, so the need-keys a hub sends a new subscriber is about the keys it held before them.
- **The hand-over's keys** (`drgnx-hub--held-keys`, on every proven (re)connect) are, for each keyed provider of the
  effective table, the same quiet read: the environment, a key AI: Load Keys found that no hub took yet, else a plain
  `~/.authinfo`/`~/.netrc` entry. So a hub that restarted gets back the keys that live in a quiet file, and the editor
  keeps none of them afterwards.
- **A key the hub lost** (`drgnx-hub--keys-lost`). A hub's `need-keys` names only what agents need, never the
  editor's own providers, so the editor checks itself: when `gateway/keys-held` answers, a keyed provider whose key a
  hub held earlier in this Emacs session (`drgnx-hub--keys-had`, ids only), which this hub does not hold and which the
  quiet read cannot find (it lived in a store that asks), is a `hub` condition "the drgnx hub restarted without your P
  key: run AI: Load Keys". It goes when `keys-held` or `keys-changed` names the provider again. The editor decides
  this rather than the hub because only the editor knows which providers it used: the hub's table holds every keyed
  preset, and a hub-side list would warn about providers the user never set up.
- **The drop** (design §5.6). When a `gateway/keys` the editor sent is answered without an error
  (`drgnx-hub--keys-taken`), and after `drgnx-hub-give-key` or an agent's `gateway/register` that carried keys, the
  editor forgets them: `drgnx-hub--drop-keys` → `drgnx-ai-forget-keys` removes each from `drgnx-ai--keys` (unless a
  newer key for the provider replaced it meanwhile) and calls `auth-source-forget-all-cached`. `drgnx-hub--transmit` sends
  `gateway/keys` only on a proven connection, so a key goes only to a hub that proved itself. The environment is
  left as it is (`drgnx doctor`'s `ai-env-keys` names the variables set). An Emacs that serves the standalone Lisp hub
  skips the drop: there `drgnx-ai--keys` is the hub's own table. Only AI: Load Keys keeps a key it reads
  (`drgnx-ai-key`'s KEEP) until the hand-over takes it; every other read, and above all a usability check
  (`drgnx-ai-key-held-p`, `drgnx-ai-usable-p`: AI: Choose, onboarding), keeps nothing — not in `drgnx-ai--keys`, and
  auth-source's netrc file cache is bound for that read alone. AI: Load Keys (`drgnx-ai-load-keys`) reads the keys
  as a command and calls `drgnx-hub-hand-over-keys`: sent at once to a proven subscription, else the hub is started
  and connected and the hand-over that follows takes them. Keyed providers and agent profiles have no direct route
  (`drgnx-ai-route`, `drgnx-ai-agent-env`): without a hub a request skips the provider and an agent fails closed.

## The editor's token

The editor's own AI requests (chat, completion, embeddings of a provider with a key) go through the gateway too, with
a token of their own, so the editor need not hold the keys.

- **`gateway/editor-token {}`** (user) returns `{token, url}`: a registration of class `editor`, owned by the caller's
  process (its pid as the system reports it, with its start time; a caller whose process cannot be read is
  `not-allowed`), and `url` is `http://127.0.0.1:PORT`.
- **What it reaches.** Only `/p/PROVIDER/REST[?query]`, PROVIDER in the provider table and REST one of its kind's paths
  (`openai` `/chat/completions`, `/completions`, `/embeddings`; `ollama` `/api/chat`, `/api/generate`, `/api/embed`;
  `llamacpp` `/infill`, `/v1/chat/completions`, `/v1/embeddings`; `tei` `/embed`; `anthropic` none), forwarded to
  the provider's base + REST as they came: one provider, no chain or fallback, no model rewrite, no budget, no
  OpenRouter restrictions. A Messages path is 404 for it, and an agent's token never reaches `/p/…`
  ([runtime.md](runtime.md#bifrost-the-gateway)). Each request is a `spend` row with no job and agent `editor`.
- **Loopback only.** The token is good on the loopback listener and nowhere else: on a session's `gateway.sock` it is
  401. A `runtime.db` row of class `editor` that names another listener, or no owner, is dropped at start.
- **One per owner.** A second call from the same process deletes its earlier editor token first, so a reconnecting
  editor rotates; another process (a batch job such as the search indexer, the `drgnx` CLI) takes its own.
- **Kept across a restart.** It is a `registration` row like an agent's: read back at start, pruned with its owner,
  and good again as long as the port is the same (`kv.gateway_port`). The editor asks for its token again on every
  proven reconnect, so it learns a new port.

**Which keys the hub holds.** `gateway/keys-held {}` (user) answers `{providers: [Id]}`, the ids whose key is held, and
user subscribers get the event `gateway/keys-changed {providers}` whenever that set changes (`gateway/keys`, a
registration's `keys`; a key replaced for a provider already held changes nothing). Never a key. The editor judges a
provider usable from these, not from a key of its own. A restarted hub holds none: a reconnecting editor asks
`gateway/keys-held`, and hears `gateway/keys-changed` when its handover fills the set again.

## Settings

Ratatoskr reads `<config>/settings.el` itself, and the shipped `settings/runtime-defaults.el`, which it embeds at build
time (`include_str!`): the hub and the editor are built from one checkout, so with no editor connected the hub still
has every preset and built-in profile (unified settings design §11.1; amends runtime design §5.9). Both are read as
data with `huginn` ([settings.md](settings.md#the-data-subset)): never loaded, never written. The code is
`runtime/crates/drgnx-ratatoskr/src/settings/` (`mod.rs`: the runtime settings and `Settings`; `load.rs`: the checks,
reading and fallbacks; `profiles.rs`, `providers.rs`: the types).

- **Only the runtime settings.** `settings::RUNTIME` lists them with their Rust type and fallback: the
  `drgnx-agents-{profiles,default,mcp,routes,openrouter,allow-unsandboxed}` (`strict`) and `drgnx-ai-{providers,roles}`
  (last good). Each top-level entry of one of them is decoded through `huginn::de` into its type (`AgentProfile`,
  `AgentRoute`, `OpenRouterRestrictions`, `ProviderEntry`, `RoleChain`); every other entry, a `(:mode …)` section and
  an entry that is not even `(VAR VALUE)` are skipped, never an error, so a package's setting never stops the hub.
  `settings::conformance::runtime_names_equal_lisp_declarations` holds the list equal to the Lisp declarations'
  `:runtime` and `:on-error`.
- **The file.** Only `<config>/settings.el`: a repository's file is never read. A link there is followed (a stow link);
  what it reaches must be a regular file of at most 1 MiB, owned by the user and writable by nobody else. The checks are
  made on the opened file (opened without waiting, so a FIFO is refused, not waited on).
- **Fallbacks** (the user's rule, design §5.2). A file that is refused or does not read: the `strict` settings take
  their shipped defaults, `drgnx-ai-providers` and `drgnx-ai-roles` their last good values. An entry whose value does
  not fit falls back alone by the same rule; its problem names the line and the path inside the value
  (`settings.el line 4: drgnx-agents-profiles: review.mode: unknown variant …`). The last good values are kept in
  `runtime.db`'s `kv` under `settings-last-good` (a JSON object, setting → the Lisp text of the value that last
  decoded; no migration), so they survive a restart. An entry that is absent has its default, and no last good value.
- **The provider table** (design §11.1's mapping, as `drgnx-hub--provider-json` has it): the presets, each of the
  user's `drgnx-ai-providers` entries replacing the preset of its id and going first; `:url` → `base`, `:auth
  x-api-key` / `:key-env` / neither → `auth`, the known `:caps` once each, `:price (IN . OUT)` → `price`. A provider
  with no `:url` or `:kind` is left out silently, as the editor leaves it out; one the gateway would refuse (a URL
  that is not a provider's) is left out with a problem. `settings::conformance::providers_json_equals_lisp` compares
  the table with the editor's for `test/conformance/settings/providers-settings.el`. The gateway's table is this one
  (`Front::apply_settings`): `config/providers` is gone, folded into `config/settings`.
- **The editor's values** (`config/settings {project: null | NAME, overrides: [{name, value, source}]}` → `{applied: N}`,
  user class; `settings/overrides.rs`). The editor sends the values its Lisp and its workspaces hold: `name` is one of
  `RUNTIME_NAMES` and `value` JSON of the setting's runtime type (alists are objects, keys sorted; `drgnx-ai-roles` a
  list of `{role, chain: [{provider, model}]}`; at most 64 KiB). A call replaces the whole set of that project (none:
  global); an empty list clears it (the project still counts as having sent). A name that is not a runtime setting or a
  value that does not fit is `invalid-params` at `overrides[N].name` or `overrides[N].value[.PATH]`, and nothing
  changes. Each set is kept as last good in `kv` (`settings-override:global`, `settings-override:<project>`) and read
  again at start, so a hub with no editor connected still has them. In effect, for a setting and a project
  (`Settings::effective(name, project) -> (value, seen)`): the project's override, else the global one, else
  `settings.el`, else the shipped default; `seen` is false when the project never sent a set. The global overrides are
  also what `Settings::current()` (and so the gateway) reads. `config/changed {}` checks `settings.el`'s stamp now.
- **When.** At start, before anything is served, again when the file's stamp (device, inode, size, mtime, mode, owner)
  changed when a session starts (`mcp/session`), and on `config/changed`.
- **Problems.** Each is a `notice` event (`source` `hub`, `id` `settings-file` or `settings-<setting>`, `life`
  `event`): a read's new problems go to the subscribers, and a new subscriber hears the current ones after its
  `subscribe` answer. They are logged too.
- **`status.settings`** is `{file: "ok" | "failed", problems: N, presets: N, profiles: N}`: `ok` also when there is no
  file; `presets` is the provider table's size, `profiles` the profile names an agent may start on (the user's, then
  the built-in ones, each once).
- **The editor's side.** `test/conformance/settings/dump.el` (batch Nidhogg; its header gives the command) writes
  `lisp-dump.json`: what the editor reads of `runtime-defaults.el`, its provider table for the fixture, and its
  `:runtime` declarations. The Rust tests compare with it; `drgnx-settings-runtime-dump/committed-dump-is-current`
  (`test/unit/settings-runtime-dump-test.el`) runs the same command and compares, so neither side drifts. Rows
  `test/conformance/settings/*.jsonl` (`fake-backend`): `the-hub-reads-settings-el`,
  `no-editor-still-has-presets-and-profiles`, `a-package-entry-never-stops-the-hub`,
  `a-broken-file-gives-strict-agents-and-last-good-providers`.
