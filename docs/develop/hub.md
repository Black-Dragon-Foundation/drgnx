# The hub and the gateway

User docs: [Agents → The hub and the gateway](../guide/agents.md#the-hub-and-the-gateway).

## Processes

- **The client** (`core/drgnx-hub-client.el`, feature `drgnx-hub-client`): everything an editor, the CLI or the
  sandbox needs to talk to a hub, and nothing of the hub's runtime — the socket path and its trust check, the line
  protocol, `drgnx-hub-call` / `-call-sync`, the event subscription, `drgnx-hub-ensure` (which starts Ratatoskr),
  `drgnx-hub-restart-now` and the write queue (`drgnx hub start|stop|status` is `bin/drgnx` calling the binary: no Emacs).
  It requires `cl-lib`, `subr-x`, `seq`, `drgnx-paths`, `drgnx-guard`, `drgnx-timer`, `drgnx-file`, `drgnx-notice`,
  `drgnx-agents-matrix` and `drgnx-work-db` (the AI provider list comes from `drgnx-ai`, which the caller has loaded).
  There is no server half in Emacs: the hub is the Rust binary. The message prompt the cockpit preview uses is
  `drgnx-coord-message-prompt` (`core/drgnx-coord-read.el`). A `declare-function` of a client function names
  `"drgnx-hub-client"`. The editor's jobs go through `core/drgnx-exec.el`, a cache fed by `exec/list` and the hub's
  `exec-done` events ([Jobs](#jobs-exec)).
- **The hub's environment.** One hub runs per drgnx data directory, started as
  [below](#starting-stopping-and-restarting-ratatoskr) (a user unit, a launchd job or a self-detached process), and
  it outlives the Emacs that started it. It gets the starting Emacs's drgnx and XDG directories as its environment
  and never a provider key (`drgnx-hub-ensure` unsets every provider's `:key-env` for the start). Keys come over the
  socket instead (`gateway/keys`, below). Its `PATH` is the starting Emacs's, until an Emacs that read the user's
  login shell (`core/drgnx-shell-env.el`, at start and Shell: Reload Environment) finds `PATH`
  changed and sends `env/set`. The front serves `env/set` itself (`drgnx-ratatoskr/src/shell_env.rs`): the variables
  are an overlay in the hub's memory (`ShellEnv`), and every process the hub starts next (agent sessions, jobs, podman,
  git for plan runs) takes its environment from the process's with the overlay applied, so `PATH` is the login
  shell's directories, then the hub's own that the shell's do not name. The hub's own environment is never changed.
  A name that looks like a secret (`KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSPHRASE`, `CREDENTIAL`), is a
  provider's key variable, or is one the hub's own path rules read (`PATH_RULE_NAMES`: `HOME`, `TMPDIR`, `TMP`,
  `TEMP`, `XDG_RUNTIME_DIR`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `DRGNX_DATA_DIR`,
  `DRGNX_CONFIG_DIR`, `DRGNX_DIR`, `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`; the sockets, scratch folders and
  sandbox context are computed from them, so a shell's value must not move them) is left out of the answer's `applied`
  list; it is not an error. The editor does not send them either (`drgnx-shell-env-refused-p`). The overlay is in memory only,
  so the editor sends it again at every connect (`drgnx-hub-connected-functions`, run once the subscription has
  proved itself), also to a hub that restarted. The hub is never restarted for that: a restart would end its durable
  sessions. Rust ignores SIGPIPE in its own processes, so a write to a connection an agent closed is an error and never
  the hub's end.
- **Ratatoskr** (`runtime/crates/drgnx-ratatoskr`, binary `ratatoskr`; [runtime.md](runtime.md)), the hub: the only
  server, the only writer of `work.db` and the owner of every agent session and job.
  `ratatoskr serve [--foreground] [--parent-pid PID] [--supervisor none|self|launchd]`,
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
  6. The process groups `runtime.db` recorded are reaped ([The reaper](#the-reaper): a crashed run's, or the Emacs
     child an older hub ran).
  7. What the Lisp hub left in `<state>` is moved aside, once (`legacy::migrate`, [below](#what-the-lisp-runtime-left)),
     then the session sockets whose owners still run are bound again. No child Emacs is
     started: the hub serves every method itself ([The registry](#the-registry-protocol-v1)).

  It stops on SIGTERM, on SIGINT, or one second after the `--parent-pid` process is gone (`kill(pid, 0)`; the last
  `--parent-pid` counts). It stops accepting, ends its own sessions, then removes the socket and the cap while the
  lock is still held. It then closes every connection, after what is queued for each is written (at most 1 s for all
  of them), and the outside bridges' connections `mcp/attach` handed to MCP, so its clients see the end before the hub
  waits on anything that can hang. Last, it stops its store
  threads (runtime.db's and work.db's writer). Each writes what is queued to it first: no queued write is dropped,
  and that wait has no limit. Every 5 s while a thread is still stopping, the log names it as an error, with how many
  requests it still has queued. A second SIGTERM or SIGINT during that wait ends the hub at once, and the log says
  which thread's queued writes were abandoned at the user's request; one that came before the wait began (while the
  hub ended its sessions or closed its connections) does not. Then the hub exits 0. The log is tracing JSON, one object per line, in `<state>/hub/log/hub-YYYY-MM-DD.jsonl` (UTC days, 0600,
  the newest 7 kept, written by tracing-appender's non-blocking worker). Warnings and errors also go to stderr, behind
  `<4>` / `<3>` when `JOURNAL_STREAM` is set (the journal under systemd). `DRGNX_RATATOSKR_LOG` takes a `Targets`
  string (`info`, the default; `warn,drgnx_ratatoskr::conn=debug`). The cap, keys and params are never logged. The
  cargo feature `test-hooks` (off in the binary install.sh builds) holds the test-only surfaces: the `__test_flood`
  method, `__test_matrix_ask {action, who, session?, plan?, facts?}` (the matrix gate asked as the hub's own callers
  ask it, answered `{gate, card?, why?}`: the browser card rows raise their cards with it), `--idle-tick-ms N` (the
  restart-when-idle tick), `--test-clock`, `__test_advance`, `--test-sequencer` and
  `__test_barrier` ([Test hooks](#test-hooks)), `--test-hold-store` (at the hub's end runtime.db's thread is held by a
  job until the hub gets SIGUSR1, with one write queued behind it, so a test sees the end close its connections first
  and then write that queue, or a second SIGTERM abandon it; only SIGUSR1 releases the job, never the runtime's end),
  and `--agent-socket SID[:JOB]`, which is refused without `--foreground`. `DRGNX_HUB_PARENT_PID` does what `--parent-pid` does when the flag is absent, so a hub a test starts through `ensure` ends with the test.
- **The gateway** (`drgnx-ratatoskr/src/gateway.rs`, forwarding by `bifrost`) runs inside the hub: never in the
  editing Emacs, so streaming cannot touch the keystroke budget. Besides the 127.0.0.1 port it listens on **per-session
  Unix sockets** (`gateway.sock` in the session's private directory beside `mcp.sock` and `hub.sock`, for agents in a
  sandbox without the host's loopback). Same path allowlist and token check as the port; the socket is mode 0600 and a
  stale file at its path is replaced. Closing a session's socket cuts the connections on it, with their upstream
  requests, and removes the file. Upstream requests are made by the hub's own HTTP client over rustls, so the provider's
  key and the request body are in no process's argv ([Forwarding](#forwarding)).

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
HOME TMPDIR TMP TEMP DRGNX_DIR DRGNX_RATATOSKR_LOG` (`DRGNX_DIR`, the checkout, is a path the sandbox closes to agents)
and the names the hub's agents use (`SSH_AUTH_SOCK`, the proxy and CA variables, `CLAUDE_CONFIG_DIR`, `TERM COLORTERM
DISPLAY WAYLAND_DISPLAY`). Without `TMPDIR` and `HOME` a long
socket path would resolve differently under systemd or launchd than in the editor. No value, and no provider key, is ever
in a command line. `systemd-run` and `launchctl` are the root-owned programs at fixed paths, never found through
`PATH`.

### Stopping a hub

`ratatoskr stop [--timeout SECS]` (default 15) signals nothing unless the lock is
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
- **A lock directory left by the Lisp runtime** (a hub started before it was removed and still running after an
  update): a v0 `shutdown` goes to the socket (that hub serves it without a hello) and `stop` waits for the directory
  to go (`stopped the Lisp hub (pid N)`). If it stays, `lock/pid` gets SIGTERM only when it is alive and its command
  line has the Lisp hub's entry function (`lock.rs`); else it prints `the lock names pid N, which is not a drgnx hub:
  remove LOCKDIR` and exits 1. Nothing starts such a hub any more.

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

**`restart`** (user class) answers `true`, then the hub stops as for `shutdown` and exits **75**. Under `--supervisor self`, where nothing would start it again, it releases
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
exits 75 the first time nothing is busy: **idle** is none of the hub's own sessions running a turn (an idle chat does
not count), so a busy hub is never restarted.

### Ratatoskr's children (`draugr`)

`runtime/crates/draugr` is how the Rust runtime starts and ends processes.

- **Environment:** `env::build(allow, allow_prefixes, set)` copies only the allowed names (and names starting with
  an allowed prefix) from the runtime's environment, then applies `set`. The child starts from an empty environment
  plus that list, so a provider key the runtime holds never reaches it unless a caller names it.
- **Spawning:** every child leads its own process group, gets SIGPIPE back to ignored before `exec` (std resets it
  to the default; a write to a pipe whose reader left must be an error), has stdin
  `/dev/null` unless the caller wants a pipe, and stdout and stderr piped. The last 8000 characters of stderr are
  kept (`Child::stderr_tail`; `Child::stderr` is a `StderrTail` handle to the same text that outlives a move of the
  child, so a caller can read it from another thread while a task waits for the exit). `Child::wait` reports the exit
  status once; later calls return nothing. There is no `PR_SET_PDEATHSIG`: it fires when the forking *thread* exits,
  and tokio's threads come and go. Sandboxed children start from one long-lived thread instead (`spawn_pinned`):
  bwrap's `--die-with-parent` and the inner helper's parent-death signal would otherwise fire when a pool thread
  retires. hermod's `Conn::spawn` (every agent session and `agents/probe`) always uses it, and `Conn::stderr` gives the
  hub the agent's stderr before the agent speaks, for `gleipnir::read_status`.
- **Start times:** `start_time(pid)` is field 22 of `/proc/PID/stat` on Linux (clock ticks since boot, read after
  the last `)` of the command name) and `proc_pidinfo`'s start in microseconds on macOS (asked with arg 1, so a zombie
  is found and reads as one, as `/proc` shows it on Linux; with 0 it is ESRCH). `boot_id()` is Linux's
  `/proc/sys/kernel/random/boot_id` and macOS's `kern.bootsessionuuid` (the pid of a job is checked against the boot it started in).
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

## Test hooks

Built only with the `test-hooks` feature; a release build has none of them.

### The hub clock

Every timer of the hub and every reading of its time go through `drgnx-ratatoskr/src/clock.rs`: `clock::now()` (a
`tokio::time::Instant`), `wall()` and `wall_secs()` (the time of day), `sleep`, `timeout`, `interval` (a late tick
moves the next ones), and `spawn(origin, future)`, which names a task (`"module:what"`). In a release build each is
tokio's or std's, inlined. `real_now()` is real time on every clock, for a blocking thread's limit on something outside
the hub (a podman pull). The session's update throttle (`EMIT_EVERY`, 50 ms), its Stop timers (`STOP_ANSWER`, the
close when idle), a move's wait, a connection's `STUCK_AFTER` and flush, and a job's time box and stop all read it,
and so does every other timer: the hub's tick loops (sessions, delivery, schema, runner, supervisor, manager, idle),
the debounces, the paced reads, the accept back-off, the sandbox probe's limits and the stored timestamps. A `Delay`
interval is the only kind (a late tick moves the next ones). A wait for something another of the hub's tasks reports
waits for that report, never polls the clock: `exec/stop` waits for the job's end event (at most 5 s on the clock), so
on the test clock it answers once the end is recorded, with no advance. A task that sleeps on the clock, or writes to a client
(the gateway's events, `request` and `gateway/need-keys`, for one), is started with `clock::spawn`, so its origin is
named.

The test `tests/hub_reads_its_clock.rs` (`no_raw_time_outside_the_clock`) keeps it so: it scans `src/` for a raw
`Instant::now`, `SystemTime::now`, `tokio::time::{sleep,timeout,interval}`, `MissedTickBehavior` or
`set_missed_tick_behavior` outside `clock.rs` (inline `#[cfg(test)]` code and `tests.rs` files excluded) and names each
file:line. Its `no_raw_spawn_outside_the_clock` counts each file's raw `tokio::spawn` against a list, `RAW_SPAWNS`,
with a reason per entry: the tasks that never write to a client (the gateway's listeners, the accept loops and the
connections, whose writes are serving steps), and those that do and are not on the clock yet (a session's run and
turns, a job's start and wake, a plan task's start). A new raw spawn, or one that goes, changes the count and fails
it. Its `no_raw_blocking_outside_the_clock` does the same for `spawn_blocking` against `RAW_BLOCKINGS`: a hub task's
blocking call is `clock::blocking`, a real wait a test's barrier sees. The blocking command-line code (`client`, `supervise`, `doctor`) has no virtual clock; its deadlines read
`clock::real_now()`.

**`serve --test-clock`** installs a virtual clock before any task starts. It stands still, whatever real time passes,
until a client sends **`__test_advance {"ms": N}`**, answered with `{"now_ms", "woken", "busy", "unnamed"}`; a hub on
the real clock refuses it (`not-allowed`, "the hub runs on the real clock"). tokio's own clock is never paused: the
runtime stays multi-thread, and a paused tokio clock jumps ahead whenever the runtime is idle.

An advance moves the clock to each due deadline in order. Sleepers due at one instant wake in the order they began to
wait, one at a time. After each wake it waits until the woken task, and every task that one spawned, is parked or has
ended. A task is parked between polls with no wake pending: every wake it was given, by the clock or by anything else
(a channel, a socket), seen by a poll that began after it. What it then waits on does not matter, so a loop that sleeps
and then waits for its next signal on a channel is parked once its poll ends. A wake tokio holds back (a `yield_now`'s,
a spent budget's: deferred until the worker runs out of work) is not seen on the task, so the advance also waits until
no clock task runs and every runtime worker is parked (`clock::worker_parks`, the runtime's park hook): a worker parks
only once it holds no deferred wake. Before moving the clock it waits until
every task spawned since has run once, so a timer it started is in the queue. It then answers:

- `woken`: the sleepers it woke.
- `busy`: the origins of tasks still running after 5 s of real time: still polled, or woken again and again. The
  advance names them and goes on, never hangs.
- `unnamed`: woken sleepers in a task not started by `clock::spawn`. The advance cannot wait for those, so a test
  that sees `unnamed > 0` is not deterministic there.

**Its limit:** the clock covers this crate only. The timers inside `draugr` (a kill's grace, `STOP_GRACE`), `hermod`
(the ACP timeouts), `bifrost` and `urdr` run on real time. A path through one of them (a Stop that ends the agent's
process, for one) is not decided by the test's advances: it needs a pure core tested in every order, or a test that
waits for the child's own announcement.

### The sequencer and the barrier

**`serve --test-sequencer`** (it means `--test-clock` too) serves requests from every connection one at a time, in
the order of the top-level **`"__seq": N`** the client stamped on each line (the delivery gate stamps every line it
sends, counting across its connections in the order it wrote them). The stamp is taken off before the line is served.

- Before it serves, the sequencer reads every connection's socket to `WouldBlock`. A Unix-socket write is in the
  peer's queue when it returns, so a lower N the client wrote earlier has been read by then. The read is read(2)
  itself: tokio's `try_read` answers `WouldBlock` without reading until its reactor has seen the socket readable, which
  let a line above a gap go out before the lower N already waiting in another socket (macOS CI). A connection is known to
  the sequencer before its challenge is written, so no line can come from one it does not know.
- The lowest N is served when it follows the last N served. Above a gap it waits while some connection holds part of
  a line, where the missing N may be, and until one more full drain, begun after it was read, has ended: the sockets
  are read one after another, so a lower N the client wrote just before it may sit in a socket read earlier in the
  same drain. The sequencer drains again at once for that. Once neither holds (the missing N went to a connection
  that read EOF or failed), it is served: a lost N never stalls the others.
- Lines without `__seq` (another process's) are served after the stamped ones, in the order they were read.
- A connection's own task serves its lines when the sequencer hands them over, so its session stays its own. Its
  writes are serving steps: its challenge, its answers and what its requests broadcast go out at once.
- **Every other write is held:** a turn's events, a timer's, a background loop's. It is keyed by (virtual ms, the
  task's origin from `clock::spawn`, the task's spawn ordinal, the task's own count), so two tasks of one origin (two
  jobs' watchers) release in the order they were spawned, and released in key order at `__test_advance` (once the
  woken tasks have parked, before its answer) and at `__test_barrier`. A write from a task without an origin is held
  too, and counted.
- `mcp/attach` works: nothing after it is read as lines until it is served.
- **The hub's end never drops a held write.** When the hub ends (`shutdown`, `restart`, restart-when-idle, a signal,
  its parent gone), the step being served finishes and nothing more is served. What is still held is released in key
  order, and every connection's queue is written before the connections close. Restart-when-idle needs this: one idle
  tick sends the update notice (held) and, with nothing busy, ends the hub. The client's delivery gate still holds the
  lines and the end behind them, so the test still decides when its client sees them. Each of these waits is bounded
  by 5 s of real time, since the virtual clock stands still; one that runs out is logged.
- **A stop whose end never comes fails loudly.** `exec/stop` waits up to 5 s on the hub's clock for the job's end to
  be recorded. On the virtual clock that wait could never end (the clock stands still while the stop is served, and the
  advance that would move it is queued behind it), so it is bounded by 5 s of real time as well, and one that runs out
  answers `internal` "job ID: its end did not come within 5 s of real time of the stop".

**`__test_barrier {"waiting_ok": [origins]}`** (the list is optional), which the sequencer serves itself when it is the
lowest pending line:

1. Every connection's socket is read to `WouldBlock` or EOF, and every line read is served.
2. The hub settles, up to 5 s of real time: every task started by `clock::spawn` is parked (no wake pending, not in a
   poll, the workers parked as for an advance) and outside any **real wait**, and nothing outside the tasks is in
   flight. Tasks whose origin `waiting_ok`
   lists are not waited for. So a task another task wakes through a channel (a job's end waking its session, an event
   bifrost put on `gateway:events`) has run before the barrier goes on. A real wait is a wait on something outside the
   clock that ends by itself:
   - `clock::real(f)`: a DNS lookup or connect, a download, the embed worker's answer, and every blocking call of the
     hub's tasks (`clock::blocking`, the one door to `spawn_blocking`; `tests/hub_reads_its_clock.rs` counts the raw
     ones against a list).
   - a store thread's answer (runtime.db, work.db's writer and read pools): urdr marks the waiting task itself
     (`urdr::wait`, with its `test-hooks`).
   - `clock::real_long(f)`: a job's watcher (`exec:watch`), from the child's start to its recorded end.
   - outside the tasks, `gateway:requests`: the gateway's requests from their send until their `request` (and
     `budget`) event is on the channel, so a client that read its whole answer sees the event before the marker.
3. The tasks spawned since then are run once (an advance of 0 ms), and the held writes are released.
4. `{"event": "__test_marker", "data": {"marker": M}}` is written on every live connection. M counts from 1 per hub.
5. The answer: `{"marker": M, "unnamed": n, "busy": [origins], "waiting": [origins]}`. `n` counts the writes from
   tasks without an origin since the last barrier. The gate fails a test when n > 0, since such writes are released
   here and not by the test's own advance. `busy` names tasks still running after 5 s. `waiting` names the tasks
   still inside a real wait (and `gateway:requests` while requests are in flight): the allowed ones, and those still
   inside after the 5 s. The gate fails a test on any its `drgnx-test-gate-waiting-ok` does not list, since what they
   write later is not ordered by the test.

An advance waits for a woken task's `clock::real` waits too (it is not parked inside one, whatever clock timer it also
holds), but not for a `clock::real_long` one: the advance may be what ends it (a job's time box). A job's kill after
its time box is a `clock::real` wait, so an advance past the time box answers after the job's end. A wait the code does
not mark, on something outside the hub that has not answered yet (a raw thread, a raw-spawned task's work), is still
not seen: a barrier there answers as if the task were parked.

A hub without the sequencer refuses `__test_barrier` (`not-allowed`). A release build has none of these: `__test_advance`
and `__test_barrier` are unknown methods (`no-method`), `__seq` is dropped and listed in the answer's `ignored`, and
`serve --test-clock` or `--test-sequencer` is a usage error (exit 2).

**Its limit:** a run is deterministic only where the hub's output follows from the order of its input and its clock.
Two tasks racing inside one handler, or a turn driven by an agent's real I/O, are not ordered by it. Those need a
pure core tested in every order.

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
through it. Unlike the editor's client it takes a missing directory as no hub (`ensure` then starts one, which makes the
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

**Who gets what.** `agent` goes to every subscribed connection, and carries no tool call's `rawInput` (a permission
request's tool call included). A connection gets a session's snapshots at once (at most one per 50 ms) only while it
shows the session (it subscribed to its entries); for every other session it gets at most 30 snapshots a second on the
hub's clock, and when that is reached only the latest state of each session waits for the next second. The snapshot's
`turns` counts the turns the hub process started for the session, so an editor that saw it rise with no `busy` in
between knows whole turns went by (a turn can be shorter than the update throttle). `agent-entries` goes only to the connections that called `agents/entries/subscribe`
for that session (the answer is the change number to continue from; the connection's subscriptions end with it, and
`agents/entries/unsubscribe` ends one), and its tool entries have no `rawInput` either (a string `url` of the input
stays as `url`). An editor that needs a tool call's input asks `agents/tool-input` (at most 256 KiB of its JSON text;
a larger one comes back cut, as a string, with `truncated`). The hub keeps the whole input. `agents/pause` cancels a
busy session's turn once the tool call running now completes, and holds its queue. A mirror (below) subscribes while a
transcript of its session is shown (`drgnx-agents-mirror-show` and `-hide`, run from `window-buffer-change-functions`
for transcript buffers only) and fetches the transcript then; a session nobody shows has its turns told by the
snapshots' `status` and `turns`. `agents/get` still returns whole entries, `rawInput` included: it is one editor
asking for one session on demand, not a broadcast.

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
  held makes `serve` exit 3 ("another hub serves here"). Dropping the lock, and a probe that took it, unlock with
  `LOCK_UN` before the close: a child another thread forked shares the open file until its exec, and a close alone
  would leave the lock held through that copy.
- **A lock directory from the Lisp runtime** (`SOCKET.lock/` with `pid`, left by a hub that outlived the update) is
  judged from its `pid`, never from a ping. Ratatoskr exits 3 ("a Lisp hub from before Ratatoskr serves here: drgnx
  hub stop") and touches nothing in two cases:
  - the pid is alive (`kill(pid, 0)` succeeds or fails with EPERM) and its command line has the Lisp hub's entry
    function (the marker is in `lock.rs`; Linux `/proc/PID/cmdline`, macOS `sysctl KERN_PROCARGS2`), whether the hub
    answers a ping or not;
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
  "answer over 16 MiB", and an event over 16 MiB is not sent (logged). A client that left (its socket refuses a write)
  gets nothing more written, but the lines it sent before it left are still read and served, up to its end of file: a
  CLI that sends `exec/stop` as it exits, behind calls whose answers it no longer reads, still has its job stopped.

### One connection

The queue and the choice between reading and stopping are a pure core, `conn/pure.rs` (`ConnCore`). It has no I/O,
clock or threads. The shell (`conn.rs`: `Outbox`, the writer task, the reader, the sequencer's path) does the I/O and
feeds every event through `ConnCore::step`:

- `Push {len}`, `Close`, `ClientEof`, `ReadError`, `LineRead`, `Written {len}`, `WriteRefused`, `WriteStuck`,
  `Attach`.
- The core answers with effects: queue or refuse the line, drop the queue, log the first close, serve or skip the
  line read, pop the line written.
- The shell asks it `reading()` (read the socket, or stop: the reader's `select!` is this choice), `closed()`,
  `writing()` (the writer goes on, or ends), `queued_bytes()` and `whole()` (the write half is handed on to
  `mcp/attach`).

A refused write (the client left) drops the queue, but reading goes on to the client's end of file. A close, a read
error, a malformed line, a stuck write or a queue over 16 MiB stops both.

`conn/pure/tests.rs` runs the core in every order of the hub `[Push×3, Close]`, the writer `[Written×2,
WriteRefused]` and a client `[LineRead×3, ClientEof]` (skuld, exhaustive: 5,280 orders). The third push leaves a line
for the refused write to be writing. It also runs the over-limit close in every order, and 500 random orders of four
sources of six. The edges those orders take as given are the shell's, each
tested over a socket pair in `conn/tests.rs`:

- a line is reported written only after its push, in order;
- the client's EOF is the last read event;
- the writer reports at most one of a refused and a stuck write, then ends.

The client in these tests leaves with a `shutdown`, never by closing its end alone: a child another test of the same
binary is spawning holds a copy of every descriptor from its fork to its exec, so a close ends the stream only once
that copy is gone too. `a_drain_reads_what_the_socket_holds_before_the_reactor_saw_it` holds such a copy throughout.

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
   or migrates the file before it serves, so 7 unless the file is newer, or older and its migration failed), and `methods` names every method of the registry. `proof` is the hub's own, `HMAC-SHA256(cap,
   "drgnx-hub hub " + nonce + " " + HUB_NONCE)`. It is sent only after a valid client proof.

A connection answers one `hello`: a second one is `proto` "hello was already answered on this connection", whatever
it holds, and changes nothing. A hello refused for its params (`invalid-params`) does not count as that one. A wrong
proof does. The protocol a user connection's hello said is kept: when it is newer than the hub's, every call on it but
`hello` is `proto` ("this hub speaks protocol 1, the connection's hello said N: restart the hub (drgnx hub stop)").

**Agent sockets.** With the `test-hooks` feature, `serve --foreground --agent-socket SID[:JOB]` binds `hub.sock` in
the session's own directory, `<socket dir>/s/SID/` (`runstav::paths::session_dir`; `<tmp>/drgnx-hub-UID/s/SID/` when
its longest socket, `gateway.sock`, would be over 103 bytes). `s/` and `s/SID/` are made private (0700, the user's,
never a link) and checked with `trusted_dir`, the socket is 0600, and the session dir goes at the stop. A connection
there is `agent` class, bound to SID and JOB: its calls carry them (`Caller {class, sid, job, conn_id}`). A sandbox
is given `s/SID` alone. The per-session sockets of later phases (`mcp.sock`, `search.sock`, `gateway.sock`) go in
the same directory.

**The store at start.** Before it serves anything the hub opens `<data>/work.db` with the graph writer and
`norn::migrate7`'s opening rule ([store.md](store.md#migration-from-schema-6-task-11)), and waits for its answer: a
missing file is made at schema 11, a schema-6 one is copied to `<data>/backup/work-pre7-<unix>.db`, checked, and
migrated in one transaction, so the first request sees schema 11. A newer file (above 11) makes the hub read-only; a
file below 6, or a migration that failed, leaves the writer not ready (writes answer its text) and the hub serves
the rest. A failed migration is not tried again until the hub restarts. The coordination writer
(`norn::store::CoordDb`) and the coordination tools' graph store run on the same file.

**`work.db` read-only.** The front reads work.db through `urdr::open_readonly` on a thread of its own (`store.rs`).
It reads `meta.schema` (schema 7's `meta` view over `kv`) at the start and every 2 s. While it is above this hub's 11,
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
(`dispatch::prelude`) before any method runs, in the contract's order:

| Step | Refusal | When |
|---|---|---|
| (line) | `invalid-params` (with `path` when it is known) | not a JSON object, a duplicate key at any depth, nesting deeper than 64, no `method`. Answered when the line's `id` reads, else dropped and logged |
| 1 | `no-method` | the method is not in the registry |
| 2 | `not-allowed` | the connection's class may not call it. A `service` connection calling a `user` method gets "METHOD needs the user's capability (an editor or CLI of an older drgnx: update it)" |
| 3 | `proto` | a call (not `hello`) on a user connection whose hello said a newer protocol |
| 4 | `invalid-params` with `path` | the typed decode failed. Keys the method does not know are dropped and listed in the answer's `ignored`, and so is a top-level key besides `id`, `method` and `params` (by its name) |
| 5 | `schema` | the method writes while the hub is read-only: "work.db is schema N, newer than this hub's 7: update drgnx" |
| 6 | `internal` | the handler failed |

A notification (no `id`) is dispatched the same way and never answered. Every refusal (steps 1–5, and a handler's own,
such as a wrong proof or a second hello) is logged at info ("refused a call") and counted. `status.refusals` is
`{count, last}`, the last 20 newest first, each `{at, method, code, class, path?}`. The log line and the entry carry
only those: never the params or the message, since a decode error's message can quote a value (a key, a prompt).

**Served by the front:** `hello`, `ping` `{pid}`, `status`, `subscribe` (the connection gets the broadcast events
from now on), `shutdown` (answers `true`, then the hub stops as on SIGTERM), `restart`, `events/since`,
`coord/notify` and the front's writes (next section). `status` is `{pid, socket, started, proto, proto_min, records,
drgnx_version, schema, read_only?, store, runtime, refusals, job_agents: "every session runs in the job sandbox; where
it cannot, none starts"}`. `events/since` reads work.db's `event` table: `{since,
last, events: [{id, at, agent, job, task, kind, summary, data?}]}`, after `since` (0), at most `limit` (200, at most
1000), `data` the parsed JSON object. `last` is the newest id answered, or `since` when there is none. `status` also
says `gateway: {port?, registrations, requests,
errors, fallbacks, bytes_in, bytes_out, providers, keys_held, keys_refused?, warnings}`, the front's own gateway
([Registrations](#registrations)): `providers` is how many the table has, `keys_held` the providers whose key the hub
holds (never a key), `keys_refused` why it takes none (only when it could not be hardened), `errors` the requests answered with no status or one of 400 and up. The front also serves the
gateway's methods, `gateway/{register,unregister,keys,set-budget}` and `spend`, the settings' (`config/settings`,
`config/changed`) and `env/set`; the rest, next section.

## Every method is the hub's

Ratatoskr serves every method of the registry itself: there is no second process behind it, so nothing is
forwarded and no child Emacs is started. `Front::line` (`runtime/crates/drgnx-ratatoskr/src/front.rs`) routes the
decoded params with one `match` over `Params` that has no catch-all arm: the front's own methods (above), then the
agent core's, the store's and the coordination writes, each listed by name. A method added to the registry without a
handler does not compile, and `runstav::registry::tests::every_method_is_served` checks that every method has a
`Params` variant of its own and every variant a method. A part that is handed params it does not serve answers
`internal` "METHOD reached no handler" (a routing mistake, logged as an error; `front::tests::every_method_reaches_its_handler`
calls every method that takes empty params).

**The agent core** (agent system part 1): `agents/*` and `job/*`, and every method the agent core adds (`exec/*`,
`matrix/*`, `presence/set`, `messages/retract`, `plans/*`, `brief/*`, `reports/get`, `decisions/effects`,
`timeline/get`, `budget/*`, `pace/get`, `records/*`), go to `src/agent_core.rs`, which calls the module that serves
each.

**By class** (`shape.rs`): `agents/list` for a `service` connection is `{sessions: [{id, name, job, task}]}`, for an
`agent` the same for its own job's sessions (and its own); an agent's `spend` reads its own job (`job` defaults to it,
another is `not-allowed`). `gateway/keys` and `gateway/register`'s keys come from user connections only (the class
check). `spend` is summed from work.db's `spend` rows (`norn::read::spend`), all zero while there is no work.db.
Provider keys are never logged and never serialised. They are not wiped from memory: on their way in they pass
through the request line, its parsed JSON and a plain string before the secret type holds them (review M12), so this
is no claim of zeroisation.

**The front's writes.** The front writes work.db's coordination and job tables itself, through norn's writer
(`runtime/crates/drgnx-ratatoskr/src/coord.rs`; [coordination.md](coordination.md#who-writes-what)): the editor's
`cards/settle`, `messages/send`, `messages/mark`, `events/add` and `review/mark`, and the `coord/*` methods. Each is
decoded by the registry, written in one transaction and answered typed. A work.db that is not ready (below schema 6, or a migration that failed) is `internal` with the
opening rule's text (the writer looks at the file once more first); a newer one is `schema`; a busy one `internal` "work.db is busy; retry" (a
`best_effort` event and `coord/agent`'s `seen` answer `{}`); a writer's refusal (a `seen` from the future, a review
state) `invalid-params` with its text. `coord/prune` never fails (`{pruned: false}`). `coord/notify`, from any
class, wakes the `events` broadcast. `status` says `store: {schema, writer: ready | not-ready |
read-only, writes, migrated_at?, failed?, wal_bytes?, last_backup?, backup_ok?, denied_in?}`: the writer's state
from its opening rule's last answer, the transactions the front's methods committed since start, when the move from
schema 6 committed, why a migration failed, the WAL's size, and the copies that still hold what the deny-list kept
out of the migration (`last_backup` and `backup_ok` come with the daily backups).

`messages/send`'s `sender` is refused from every connection (`invalid-params` at `sender`): a message's sender is
its connection's, and the hub is work.db's one writer (coordination.md, "Who writes what").

### The reaper

`runtime.db`'s `proc` table records process groups by pid, start time, group and boot id. The hubs before phase 7
wrote a row (purpose `backend`) for the Emacs child they ran; this hub writes none. At start, before
anything is served, Ratatoskr reaps every recorded row with `draugr`'s rules (above: a row with a NULL pid, group,
start time or boot id is skipped and never signalled; a pid whose start time or boot differs is left alone) and then
deletes them all, so the Emacs child an older or crashed hub left is killed with its group when the new binary starts.
The window left open is the reused leader ("The window left open", above): the recorded group died and its leader's
pid went to another process's group before the next start.

### What the Lisp runtime left

`legacy::migrate` (`src/legacy.rs`) runs once per start, after the reaper and before anything is served. It moves, each
only when present, into `<state>/hub/migrated-p7/` (0700, original names): from `<state>/hub/` the files
`registrations.eld`, `sessions.eld`, `port` and `hub-timers-report.eld`, the folder `bodies/` and every `hub-*.d/` that
holds only `backend.sock`; then each entry of `<state>/sandbox/` except `folders.eld` (the editor's VC guard,
`core/drgnx-sandbox-vc.el`, still reads that list, so it stays; it is written by nothing now); and each `<state>/jobs/<id>/` of the editor's old command jobs
(the Lisp runtime's, before the hub ran them as `exec/*`) that has ended (an `exit` file, or a `pid` file naming a process that is gone; a job with neither
counts as ended once its folder has been quiet for a minute). A live job's folder stays and is listed in `left`.

A move is a `rename`; across filesystems (`EXDEV`) it copies into a temporary name beside the target, syncs every file
and folder, renames it into place and only then removes the source. A copy that fails (a socket in the tree cannot be
copied) leaves the source untouched and the name in `left`. Once the copy is in place the name is `moved`: if syncing
its folder or removing the source then fails, the name also goes in `source_left`, and the next start removes the
source, but only while the copy is there and holds all of it (a source that changed since stays). Nothing is deleted
otherwise. `migrated-p7/done` is the JSON `Moved` `{at, moved, left, source_left}` (names relative to `<state>`;
`source_left` is absent when empty); once it exists later starts skip the `hub/` and
`sandbox/` items and only move the jobs that have ended since, shrinking `left`. A fresh install (nothing to move,
nothing left) writes nothing.

`doctor --json` has `legacy: {moved, left, at, lisp_processes: [{pid, what}]}`: `moved` and `at` from `done`, `left`
read afresh (a job may have ended since), and the user's Emacs processes started with the Lisp hub's or the Lisp
coordination server's entry function (`MARKERS` in `legacy.rs`: `drgnx-hub-main`, `drgnx-coord-mcp-main`) as an
`-f`/`--funcall`, `-l`/`--load` or `--eval` argument (a command that only names them, such as `rg drgnx-hub-main`, does
not count; from `/proc/*/cmdline` on Linux; `ps -x -o pid=,command=` with a 2 s deadline on macOS).
Rows: `lifecycle/{an-old-backend-is-reaped-at-start,lisp-state-is-moved-once,a-second-start-moves-nothing,a-running-lisp-job-is-left-in-place}`.

## The client

`core/drgnx-hub-client.el` is what the editor and the CLI load to talk to the hub; it speaks protocol v1 to Ratatoskr
([hello and versions](#hello-and-versions)) and protocol 0 to a Lisp hub that outlived an update (`legacy`).

**`(drgnx-hub-call METHOD PARAMS CALLBACK &key DEADLINE FULL)`** returns the call's id. CALLBACK gets `(RESULT
ERROR)` **exactly once**: the answer, or `(nil "…")` when DEADLINE passes (`drgnx-hub-call-deadline`, 30 s; a layer
timer `(hub-call . ID)`) or the connection goes first. ERROR is the hub's message; with FULL it is the error object
`(:code :message :path)`. A call answered after its deadline, or one failed by a closed connection, is never called
back again. `drgnx-hub-call-sync` (commands and the CLI only) waits for the same callback, its TIMEOUT the deadline.

**A new connection** proves itself before any call goes:
1. It **waits for the hub's challenge**, at most 2 s (a layer timer `(hub-challenge . CONNECTION)`), and
   sends a `ping` at once. Ratatoskr's challenge is always its first line, so a ping answered first means a hub of
   before protocol 1: that one is `legacy` at once, without the 2 s wait. Only that makes a hub `legacy`. When the
   2 s pass, what already arrived is read first (an Emacs busy past the wait runs the timer before it reads a
   challenge waiting in the socket); still no line, and the connection is closed and its calls fail (the next call
   connects again). A challenge that comes on a connection taken for `legacy` closes it the same way.
2. On the challenge it sends **`hello`**: `proto` 1, a fresh `nonce`, `drgnx_version` (the commit of the binary on
   disk, `drgnx-hub-client-binary-version`, when it is known), `schema` (`drgnx-work-db-schema-version`), `records` 2,
   `client` (`"cli"` in a batch Emacs, else `"editor"`) and `proof`: `HMAC-SHA256(cap, "drgnx-hub client " +
   HUB_NONCE + " " + nonce)`, the cap read from `hub-HASH.cap` beside the socket with `drgnx-file-read-bounded` (256
   bytes). Calls made meanwhile wait in the connection's queue, in order.
3. **The answer:** the hub's `proof` must be `HMAC-SHA256(cap, "drgnx-hub hub " + nonce + " " + HUB_NONCE)`
   (compared as SHA-256 digests). Then the connection is **proven** and the queued calls go out. A missing or wrong
   proof closes the connection, fails the queued calls once with "the hub at SOCKET did not prove it read CAP-FILE",
   and tells the user (a `fail` notice of source `hub`, id `unproven`). A refused hello, or a cap this Emacs cannot
   read, closes it the same way (without the notice). A hello answered `no method hello` is `legacy`.

**The subscription is redialled (HUB-RESUBSCRIBE-1).** When the subscribed connection closes and the editor did not
ask for it, the sentinel forgets the editor token (`drgnx-hub--editor` nil) and the held keys (`drgnx-hub--keys-held`
`:unknown`), says so to `drgnx-hub-disconnect-functions`, and `drgnx-hub--resubscribe-schedule` arms the layer timer
`hub-resubscribe`: `drgnx-hub-connect` after 1 s, then 2, 4 … up to 30 s between tries (a dial that fails at once, a
socket that is gone, arms the next one). The hand-over (settings, keys, token) runs on the new subscription as on
any other. An answer to the hand-over's `gateway/editor-token` or `gateway/keys-held` read after the subscription it
was asked under ended is dropped (`drgnx-hub-core--answered-under`): Ratatoskr ends its connections in any order, so the call
connection's answers can come after the subscription's end, and they would undo the forget. After `drgnx-hub-resubscribe-give-up` (600 s) from the first loss it stops and posts one notice (id
`resubscribe-gave-up`) naming Hub: Restart Now. It **never runs `ensure`**: a hub the user stopped stays stopped.
Asked ends do not redial: `drgnx-hub-disconnect` and a `shutdown` call this editor sent set
`drgnx-hub--asked-disconnect` (cleared by the next `drgnx-hub-connect`) and cancel the timer.

**Keys go only to a hub that proved itself**: on any other connection, a `legacy` one or a
service one, `gateway/keys` is never written (its callback gets "keys go only to a hub that proved itself") and
`gateway/register` goes without its `keys`. A legacy hub otherwise gets every call as before.

**`drgnx-hub-client-proves`** (default t): nil sends the hello without a proof and never reads the cap, so the
connection stays `service`: a client that must never become `user` class by reading the cap file binds it to nil.
The coordination tools no longer run in Emacs, so nothing in drgnx does.

**Skew.** `drgnx-hub--last-hello` keeps the last answer (a plist, or `:legacy`); `(drgnx-hub-has-method-p NAME)`
reads its `methods`. `(drgnx-hub-skew REPLY)` is:

| Reply | Skew |
|---|---|
| `:legacy` (no challenge, or `no method hello`) | `restart-when-idle` |
| `proto` missing or below `drgnx-hub-proto-min`, or `proto_min` above `drgnx-hub-proto` | `incompatible`: the connection is closed, its calls fail, an editor tells the user |
| `records` other than 2; `drgnx_version` other than the binary on disk's commit (when that is known); `schema` below `drgnx-work-db-schema-version` or above `drgnx-hub-schema-readable-max` (10: schemas 8 to 10 keep schema 7's compatibility views; 0, no work.db yet, counts as readable) | `restart-when-idle` |
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

### The client's core

Every ordering decision above is made by a pure core, `core/drgnx-hub-core.el`: which connection a call waits on and
when it goes, the challenge, the probe, the hello and its proof, deadlines, the one subscription, its end, its redial,
and which answers still count. `(drgnx-hub-core-step STATE EVENT)` returns `(STATE . EFFECTS)` and calls no process,
timer, file or hook. `test/unit/hub-core-test.el` runs it in every order of its inputs (`drgnx-test-every-order`,
[harness.md](harness.md#every-order)).

**The shell** (`core/drgnx-hub-client.el`) is the rest. `drgnx-hub--step` snapshots the globals
(`drgnx-hub--client`, `--events`, `--subscribing`, `--pending`, `--next-id`, `--editor`, `--keys-held`,
`--asked-disconnect`, `--resubscribe-since`, `--resubscribe-delay`, `--last-hello`) and the connections' properties
(`:drgnx-state`, `-queue`, `-proven`, `-asked`, `-events`, `:since`, and whether each is live) into a state. It calls
the core, writes the new state back, and only then runs the effects, so an effect that comes back (a sentinel
`delete-process` runs at once, a callback that calls the hub) steps from the new state. The globals stay the truth
between steps: a test may let-bind them or set a connection's property. Its two I/O points stay
`drgnx-hub--open` (returns the process) and `drgnx-hub--send-line`.

**Events** (`drgnx-hub-core-event-kinds`), each fed by one shell entry point:

| Kind | Fed by |
|---|---|
| `open` | `drgnx-hub--open`, once it connected: the challenge timer and the probe |
| `connect` | `drgnx-hub-connect`; its dial (`:opened`); a redial that failed at once (`drgnx-hub--resubscribe-schedule`, `:redial-failed`) |
| `call` | `drgnx-hub--call-on` (`drgnx-hub-call`, the hello, the subscribe, the hand-over's questions) |
| `challenge`, `answer`, `event` | the filter, one line at a time (`drgnx-hub--client-line`); `drgnx-hub--settle` is an `answer` |
| `closed` | the sentinel, once per connection |
| `timer` | the layer timers `(hub-call . ID)`, `(hub-challenge . CONN)` (and its read of what had arrived), `hub-resubscribe` |
| `disconnect` | `drgnx-hub-disconnect` |
| `version-known` | the binary's version read ending, which the hello waits for |

**Effects** (`drgnx-hub-core-effect-kinds`): `send`, `delete`, `timer-start`, `timer-cancel`, `callback` (a caller's
callback, inside the guard), `notify` and `hook`. A hook is what only the shell does: read the version, compute the
hello (the cap is read there; the core gets the proof the hub must give back, never the cap), read what arrived
before giving up on a challenge, run the event, skew, disconnect and connected hooks, the hand-over, presence, the
jobs' cache, and dial.

**Who splits the lines.** The shell does, in one of two ways, and the core gets the same events from both. By default
the connection's filter (`drgnx-hub--client-filter`, through `drgnx-hub--lines`) cuts the chunks into lines and parses
them. With Nidhogg's `nidhogg-workers-framing` on, `drgnx-hub--open` hands the connection to Nidhogg's reader
(`drgnx-hub--frame`: `lines` framing, parsed there, no line limit, as the client has none today), and the main thread
gets batches (`drgnx-hub--client-batch`) of parsed messages; a line that is not JSON, or is `null`, is dropped on both
paths. The connection is `(binary . utf-8-unix)`: bytes in, which framing needs, UTF-8 out. One difference: a last line
with no newline before the end of the stream is a message when framed, and dropped by the filter. Without the feature
or the switch, or when the framing is refused, the filter reads. The probe (`drgnx-hub--ping-socket`) is never framed.
`test/unit/hub-client-frame-test.el` checks that both paths give the same events, over Nidhogg's own framer.

**The shell's edges**, which the every-order tests assume and `test/unit/hub-client-shell-test.el` checks with
scripted peers: a connection's lines reach the core in the order they were written (so the challenge, Ratatoskr's
first line, comes first), whatever the chunks; its `closed` comes once, after everything read before the end, and
nothing of it comes after. A `subscribe` answer precedes that connection's events, and an answer its call: both are
the hub's order on one connection.

`drgnx-hub-settled-p` (`drgnx-hub-core-settled-p`) says the editor is subscribed and no call waits: no hand-over
answer can still change the editor token or the held keys. A test that changes them waits for it first. A token and
held keys alone are not that: a command's `drgnx-hub-ensure` hands over on the call connection, and when the hub
answers it before the `subscribe`, both are set while the subscription's own hand-over, which rotates the token, is
still to come (`test/unit/ai-gateway-test.el`'s `:ensure` fixture gives the gate that order).

### Starting the hub, and Hub: Restart Now

`drgnx-hub--ensure-running CALLBACK` starts **one asynchronous `ratatoskr ensure --timeout 5`** (no batch Emacs;
`DRGNX_EMACS` and `DRGNX_DIR` from `(drgnx-emacs-program)` and `drgnx-dir`; provider-key variable names unset). It
never waits: CALLBACK gets nil when a hub answers, or the reason (the process's output) when `ensure` fails or passes
`drgnx-hub-ensure-deadline` (10 s, a layer timer `hub-ensure`). A second call while it runs joins it. `drgnx-hub-ensure`
(commands, the CLI) waits for that and then hands over the provider table and the keys ([Keys](#keys)); in a daemon
path (`inhibit-interaction`) it returns at once and they go, or a `hub` notice `start` is posted, when the start ends. `DRGNX_NO_HUB_START` is honoured; with
no binary every caller says "Ratatoskr is not built: run `drgnx runtime build`".

**At daemon start.** The nightly graph backup (`backup_timer.rs`) runs inside the hub, so a daemon must not wait for AI
to start one. `drgnx-hub-ask-at-daemon-start` (core, on `emacs-startup-hook`) schedules the layer timer
`hub-daemon-start` (2 s, owner `:core`) in a daemon only: not in batch, not in a plain Emacs, not with
`DRGNX_NO_HUB_START`. The timer calls `drgnx-hub--ensure-running` without waiting; a missing binary is silent, a failed
start is a `hub` warning notice. It does not connect and hands over no keys or settings: a key-less hub starts no
provider; keys arrive with the first AI use (`drgnx-hub-hand-over-keys`) or when the hub asks (`gateway/need-keys`).
`drgnx doctor` (the `store` check) says the hub is down, and the nightly cannot run, when the last backup is old and no
hub runs. The copy runs on its own task through `backup_timer::guarded`, which clears the running flag on every way
out, a panic included, so one failed night never stops the next. `test/live/hub-daemon-start-test.el` starts a real daemon
session with a real hub (`DRGNX_RATATOSKR_BIN`), sees the hub come up and the nightly copy appear, and reads the idle
hub's CPU and resident memory from `/proc` (about 0.1 % CPU and 63 MB for a debug build).

The hub's `notice` event (sent when the binary on disk changed) is posted by `drgnx-hub--note-notice` (an editor's
subscription) as a notice of source `hub`, a condition with command `hub-restart-now`. A hello that finds the hub
current (`ok`) clears it. A `legacy` hub (the Lisp hub of an install updated while it ran) gets the same notice with
its own text, from the hello, in an editor only. **`hub-restart-now`** ("Hub: Restart Now", category Agents, no key in
any profile; `drgnx-hub-restart-now`) asks no one: on Ratatoskr it calls `restart` (its supervisor, or its own
re-execution, brings it back); on a legacy hub it calls `shutdown` (protocol 0 has no `restart`), waits up to 5 s for
`<socket>.lock` to go, and runs `ratatoskr ensure`; with no hub it just starts one. Agent sessions end.

**Probes.** `drgnx-hub--ping-socket` (`drgnx-hub-running-p`) sends a raw `ping` and reads lines until one is not an
event, so Ratatoskr's challenge is skipped. It sends no hello: a probe is `service` class, which `ping` allows.

**The line reader** (`drgnx-hub--lines`) searches only the chunk that came for a newline.
The start of a line still open waits in a list of pieces, joined once its newline comes, so a 16 MiB snapshot in 8 KB
chunks costs its length, not its length times its chunks (HUB-LINES-1, PERF-M3).

**Tests:** `test/unit/hub-client-test.el` (prefix `drgnx-hub-client/`). Fake hubs that lie (a wrong proof, no proof,
protocol 0, a held hello) are in `test/fixtures/fake-hub.el`. The tests marked "binary" run against Ratatoskr:
`DRGNX_RATATOSKR_BIN` names it (`bin/drgnx test --container` passes it into the container), they skip without it,
and `test/no-skip.eld` makes CI fail when they skip. Among them, `editor-traffic-over-ratatoskr` replays what the
cockpit, the job UI, the agents mirror and `drgnx job` send, with the params their own code builds, over a populated
store, and fails on any `invalid-params` or `internal`.

## Events

The hub turns what happens into rows of the store's event log ([coordination.md](coordination.md), `event`), written
in the same transaction as the change they record:

- **Sessions** (`agents/session.rs`): `start` when the hub starts one (`started NAME`, in the `agents/start`
  transaction); the agent's own reports through the coordination tools (`start`, `edit` with its paths, `test` with
  counts: `norn::tools::report`); a permission it asks (`question`) and its answer (`answer`, by `user` or, when the
  turn was cancelled or the agent ended, by `drgnx`).
- **Jobs** (the plan runner, `runner/review.rs`): a reviewer's verdict (`review`, `pass` or `fail`, the reasons in the
  summary) and a merge into the job's branch (`status`).
- **Cards, decisions and tasks** (`norn::write::{cards,decisions}`, `norn::tracker`): `card`, `question`, `answer`,
  `decision` and `task` rows.
- **Retention:** the hub's housekeeping runs the daily prune (`coord/prune`, `norn::write::prune`): by age once a
  day, and on every call the row cap.

Subscribers get them as `events` (`:since ID :last ID :events [{id, at, agent, job, task, kind, summary, data}…]`,
`data` a JSON object parsed from the store's column, absent when there is none). Event ids are never reused
(`autoincrement`), so a pruned log never sends an id twice. A new hub starts after the last event there is; a client
catching up asks `events/since`. The front sends `events` (`coord.rs`, `broadcast_events`): from the newest row at
its start, woken by each transaction its writer commits, by `coord/notify` and by its 2 s schema tick; at most 200
rows an event and one event each 0.25 s. In an editor, the `test` events with
counts reach the status bar (`drgnx-statusbar-note-tests`) through `drgnx-statusbar--hub-tests`, which
`drgnx-statusbar-mode` adds to `drgnx-hub-event-functions` and removes when it is off; the hub client knows nothing of
the status bar.

## Session start: lock, sandbox and matrix

A session starts in this order (`agents/session.rs`): the matrix's cells for the session's columns, `lock::plan` (Claude's
managed settings plus the deny/ask rules of the user's and the worktree's settings, Codex's `-c` overrides plus
`projects."<cwd>".trust_level="untrusted"`, Gemini's `--approval-mode default`), a refusal of a worker or manager whose
lock is not enforced unless the preset is autonomous, a refusal of a chat in a project whose `chat.project-read`
cell is never (the message names the row; it is not started without the project instead), `launch::spawn` (`spawn_plain` for a chat in its own scratch
directory, `spawn_chat` for a chat in a project: the project read-only, its scratch directory the only writable path;
test builds spawn the mock unsandboxed), the sandbox status pipe read (`gleipnir::read_status`), the ACP
handshake, `lock::verify` (a lock that does not hold kills the session). Every permission request then goes through
`MatrixGate::check` with the session's id (so a manager's delegation applies): allowed answers at once, never
refuses at once, an ask waits for the user; a session's `exec/start` is checked as `code.edit` the same way. For the
browser rows an ask that the user's matrix grant for the session or its plan already covers is allowed with no card
([coordination.md](coordination.md), "Grant records").

## Sessions across a restart

The hub keeps each live session as a row of `runtime.db`'s `asession` table ([Sessions](#sessions)). A hub that
starts, once it serves, resumes each (`Hub::resume_all`: ACP `session/resume`, else `session/load`) under its own id
and name (messages and spend follow them): the agent replays the history into the transcript and the session is idle;
an editor that reconnects fetches it again (`agents/get`). A session whose agent cannot resume or load it is restarted
as described below, or ends and says why. What was in flight is gone: a turn that was running, a pending permission or
edit.

**Everything kept across a restart (Task 24).** The hub starts in this order: the jobs a hub before this one left running
are watched again (`exec::ensure_open`; a session's wake would otherwise wait for its first `exec/*` call), the plan
runner's tick pauses (`Runs::set_recovering`: a task whose worker is not back yet is not a dead one), the sessions
resume, the tick goes on from the store with the same workers, and the wakes still on file are delivered.

- **A resumed session is launched exactly as a new one**: `session/resume` and `session/load` carry the same
  `_meta` options (`hermod::Conn::resume_session`/`load_session` take `meta`), so a resumed Claude session has its lock
  (`managedSettings`) as before. `restart/resumed-session-gets-the-options`.
- **A session that waited on a job still waits** (status `waiting`, the `job-wait` step, idle close as before) when
  its job is still running.
- **If the agent can neither resume nor load**: a fresh session on the same transcript, told so by a hub prompt (`RESTART_NOTICE`, followed by the
  summary handoff when there is one). A manager is restarted from the graph (`restart_manager_from_graph`): a new
  session told its digest and open decisions, its conversation not restored. What it is told goes at the front of the
  queue kept on disk (`TurnCore::resume`), which stays as it was, so the agent reads it first and then the prompts
  that waited (a rotated manager's brief included). Its cost, `usd-est`, counts from zero in the new conversation.
- **A job's end wakes once.** `runtime.db` table `wake` (migration 7): a row `pending` when the end is announced,
  `sending` while it is delivered, `done` once the session has the prompt (the mark; pruned with the job). After the
  sessions are back (`agents::wake::recover`) a `pending` row is delivered, a `sending` one only when the session's
  queue and transcript do not hold the `[job ID finished` prompt, one of a job that is gone is dropped, and a finished
  job of a live session with no row and no such prompt (the hub died between its result and the row) is woken.
- **A message is `sending` before its prompt is queued**; at the next start (`deliver::recover`) a `sending` one whose
  prompt the session holds is marked `read`, else it is `queued` again: delivered once across a crash. The delivery
  marks it `delivered` and `read` only while it is still `sending`; a message whose prompt was queued behind a turn
  and discarded by the user's kill (`agents/kill`, or `agents/stop` with no turn running) goes back to `queued`
  (`deliver::put_back`), so its recipient's next session gets it.
- **A queued message stays in the store** and is delivered after the sessions are back
  ([coordination.md](coordination.md#delivery-the-hub)); a prompt queued in a session is read back from its
  `<sid>.queue.json`.

## The store

The front serves the store (`work.db`, schema 11) itself: `graph/*` (reads and walks, history, revert, excise, grants,
proposed txs, read-only SQL, export, import, backup, settings, the personal-notes opt-ins) and `tasks/*` (the tracker
for the editor), all class `user`. `cards/settle` of an `access` card makes a grant (or refuses) and of a `close`
card closes the task (or rejects), in the settle's tx. `mcp/session` takes the session's `profile` and its tool sets (`tools: {tracker}`), and
the session socket lists 21 tools, or 16 without the tracker tools (the task's setting first, then the profile's, else
on). Each method's shape: [store.md](store.md#the-stores-methods-task-15b).

## Settings history

The front also records the history of your settings (unified settings design §12; the code is
`runtime/crates/norn/src/write/options.rs`, served from `drgnx-ratatoskr/src/graph.rs`). The settings files stay the
truth: the hub never writes one, and nothing it records applies a value.

- **`settings/record {changes: [{id, value, file, line?}], tool, req, reverts?}` → `{tx}`** (user class). The editor sends it after each write of a settings file, and after it reads
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
type, whether it writes work.db, the `Params` variant its params decode to (`variant`; one per method, and every
method's is served: [Every method is the hub's](#every-method-is-the-hubs)), and a line of doc. `runstav::registry::registry()` lists them sorted by name and
`find(NAME)` looks one up. Each method's `decode` is the typed decode the dispatcher runs: a value that does not fit
is `invalid-params` with its `path` (a missing key is named too: `{}` for `job/stop` is refused at `id`), and unknown
keys are dropped and listed in `ignored`. Its `check_result` decodes a result into the result type and encodes it
again: strict, so a key the registry does not know is an error with its path, and a `null` where a list belongs comes
out `[]` (A-17). `PROTO` is 1, `PROTO_MIN` 1, `RECORDS` 2 and `SCHEMA` 6.

From the registry come `runtime/protocol/methods.json` (`{proto, proto_min, records, schema, methods: [{name, classes,
writes, doc, params, result}], events: [{name, doc, data}]}`, each schema JSON Schema 2020-12 with the named types
under `$defs`, keys sorted) and the table below (`registry::markdown_table()`). Tests fail when either is out of date;
`UPDATE_METHODS_JSON=1 cargo test -p runstav registry` (through the cargo wrapper) writes both again. In the table
`{a: T, b?: T}` is an object with `a` required and `b` optional (absent or `null`), `[T]` a list, `A | B` either, and
a capitalised name a named type (below) or, in results, a record (`JobSummary`, `Snapshot`, `Entry`, `EventRow`,
`HubStatus`, `HelloReply`: their fields are in `methods.json`). A params schema never holds an unconstrained value (`any`); a
result may (a transcript entry's ACP fields, a job's tasks).

<!-- hub-methods:begin -->
| Method | Class | Params | Result | Writes |
|---|---|---|---|---|
| `agents/do` | user | `{id: Id, item?: RequestId, n?: natnum, op: "deliver-queue" \| "unqueue" \| "requeue" \| "review", reject?: boolean, text?: Prompt}` | `boolean` | yes |
| `agents/entries/subscribe` | user | `{session: Id}` | `{seq: natnum}` | no |
| `agents/entries/unsubscribe` | user | `{session: Id}` | `boolean` | no |
| `agents/get` | user | `{id: Id}` | `{entries?: [Entry], seq: natnum, session: Snapshot}` | no |
| `agents/kill` | user | `{id: Id}` | `boolean` | yes |
| `agents/list` | user, agent, service | `{}` | `{sessions?: [Snapshot]}` | no |
| `agents/move` | user | `{id: Id, profile: string}` | `{id: string, name: string}` | yes |
| `agents/pause` | user | `{id: Id}` | `boolean` | yes |
| `agents/permission` | user | `{id: Id, option?: string, request: RequestId}` | `boolean` | yes |
| `agents/presence/get` | user | `{file: string}` | `{entries?: [PresenceEntry], file: string}` | no |
| `agents/presence/subscribe` | user | `{file?: string, workspace?: {id: string, roots?: [string]}}` | `{files?: [FilePresence]}` | no |
| `agents/probe` | user | `{profile: string, wait_s?: natnum}` | `{agent?: AgentInfo, ok: boolean, stderr_tail?: string, why?: string}` | no |
| `agents/role` | user | `{id: Id, role: "manager" \| "worker" \| "chat"}` | `boolean` | yes |
| `agents/send` | user | `{id: Id, if_free?: boolean, text: Prompt}` | `boolean` | yes |
| `agents/slice` | user | `{from_step: natnum, id: Id, n?: natnum}` | `{entries?: [[natnum, Entry]], id: string, next?: natnum, steps?: [Step]}` | no |
| `agents/start` | user | `{about?: string, cwd?: AbsPath, document?: AbsPath, env?: [{name: EnvName, value: string}], job?: Id, profile: string, role?: "manager" \| "worker" \| "chat", task?: TaskRef}` | `{id: string, name: string}` | yes |
| `agents/stop` | user | `{id: Id}` | `boolean` | yes |
| `agents/tool-input` | user | `{session: Id, tool_call: string}` | `{raw_input: any, truncated: boolean}` | no |
| `brief/build` | user | `{task: string}` | `{cut: boolean, edited: boolean, parts?: [BriefPartText], task: string, text: string}` | no |
| `brief/set` | user | `{task: string, text: string}` | `{note: string}` | yes |
| `browser/check` | user | `{}` | `BrowserCheckResult` | no |
| `budget/get` | user | `{scope: {project: string} \| {plan: string} \| {manager: Id} \| {worker: Id}}` | `{limits?: [Limit], remaining?: [Limit], scope: {project: string} \| {plan: string} \| {manager: Id} \| {worker: Id}, spent?: [Limit]}` | no |
| `budget/set` | user | `{limits?: [{amount: number, unit: "tokens" \| "count" \| "usd" \| "usd-est" \| "limit-share"}], scope: {project: string} \| {plan: string} \| {manager: Id} \| {worker: Id}}` | `{limits?: [Limit], remaining?: [Limit], scope: {project: string} \| {plan: string} \| {manager: Id} \| {worker: Id}, spent?: [Limit]}` | yes |
| `cards/settle` | user | `{card: natnum, choice: Text}` | `{settled: boolean}` | yes |
| `config/changed` | user | `{}` | `boolean` | no |
| `config/settings` | user | `{overrides: [{name: string, source: string, value: SettingValue}], project?: string}` | `{applied: natnum}` | no |
| `coord/agent` | user | `{register?: {base?: string, branch?: string, clear?: ["kind" \| "name" \| "cwd" \| "worktree" \| "branch" \| "base" \| "plan" \| "task" \| "pid"], cwd?: string, id: AgentName, kind?: string, name?: string, pid?: natnum, plan?: string, task?: TaskRef, worktree?: string}, seen?: AgentName}` | `{id?: string, seen?: number}` | yes |
| `coord/card-create` | user | `{data?: JsonObject, job?: Id, kind?: string, task?: TaskRef, title?: Text}` | `{id: natnum}` | yes |
| `coord/card-set` | user | `{data?: JsonObject, id: natnum, state?: Status, title?: Text}` | `boolean` | yes |
| `coord/decide` | user | `{author: AgentName, job?: Id, kind: string, paths?: Text, reason?: Text, replaces?: natnum, seen?: natnum, subject: Text, task?: TaskRef}` | `Decided` | yes |
| `coord/held` | user | `{agent: AgentName, held: boolean}` | `boolean` | yes |
| `coord/job-create` | user | `{data?: JsonObject, id: Id, plan?: string, repo?: string, tasks?: [{deps?: [natnum], n: natnum, role?: string, title: Text}], title: Text}` | `{id: string}` | yes |
| `coord/job-set` | user | `{data?: JsonObject, id: Id, status?: Status}` | `boolean` | yes |
| `coord/leases` | user | `{release_stale?: boolean, renew?: [AgentName]}` | `{released?: [Released]}` | yes |
| `coord/notify` | user, agent, service | `{}` | `boolean` | no |
| `coord/prune` | user | `{}` | `{pruned: boolean}` | yes |
| `coord/task-status` | user | `{agent?: AgentName, status: Status, task: TaskRef}` | `boolean` | yes |
| `decisions/effects` | user | `{decision: string}` | `{commits?: [string], decision: string, label: string, later_hunks?: [Hunk]}` | no |
| `env/set` | user | `{env: [{name: EnvName, value: string}]}` | `{applied?: [string]}` | no |
| `events/add` | user | `{agent?: AgentName, best_effort?: boolean, data?: JsonObject, job?: Id, kind: "start" \| "stop" \| "claim" \| "release" \| "status" \| "decision" \| "edit" \| "test" \| "question" \| "answer" \| "review" \| "message" \| "card" \| "accept" \| "revert" \| "comment" \| "job", summary?: Text, task?: TaskRef}` | `{id?: natnum}` | yes |
| `events/since` | user | `{limit?: natnum, since?: natnum}` | `{events?: [EventRow], last: natnum, since: natnum}` | no |
| `exec/bump` | user | `{id: Id}` | `ExecRow` | yes |
| `exec/get` | user | `{id: Id}` | `ExecRow` | no |
| `exec/list` | user | `{running?: boolean, session?: Id}` | `{jobs?: [ExecRow]}` | no |
| `exec/log` | user | `{from?: natnum, id: Id, n?: natnum, tail_bytes?: natnum}` | `{from?: natnum, id: string, lines?: [string], next?: natnum, running: boolean}` | no |
| `exec/start` | user | `{argv: [string], background?: boolean, cwd?: AbsPath, env?: [{name: EnvName, value: string}], heavy?: boolean, image?: string, keys?: [string], kind?: "cargo" \| "ert" \| "domr" \| "other" \| "container", local_only?: boolean, machine?: Id, memory_max?: string, name?: string, network?: boolean, nice?: integer, no_timebox?: boolean, priority?: natnum, timebox_s?: natnum, writes?: [string]}` | `{id: string, text: string}` | yes |
| `exec/stop` | user | `{id: Id}` | `ExecRow` | yes |
| `forecast/accuracy` | user | `{profile?: Text, role?: Text}` | `{rows?: [AccuracyRow]}` | no |
| `forecast/get` | user | `{job: Id}` | `Forecast` | no |
| `forecast/session` | user | `{profile?: string, session: Id}` | `Forecast` | no |
| `gateway/editor-token` | user | `{}` | `{token: string, url: string}` | no |
| `gateway/keys` | user | `{keys: ProviderKeys}` | `boolean` | no |
| `gateway/keys-held` | user | `{}` | `{providers?: [Id]}` | no |
| `gateway/register` | user | `{agent?: AgentName, budget?: Usd, chain: [[string \| null]], job?: Id, keys?: ProviderKeys, openrouter?: {data-collection?: "deny" \| "allow", ignore?: [string], only?: [string], zdr?: boolean}, owner?: natnum, sid?: SessionId, task?: TaskRef}` | `{openrouter?: any, socket?: string, token: string, url?: string}` | no |
| `gateway/set-budget` | user | `{budget: Usd, job: Id}` | `boolean` | no |
| `gateway/unregister` | user | `{token: string}` | `boolean` | no |
| `graph/backup` | user | `{}` | `BackupAnswer` | no |
| `graph/compact` | user | `{dry_run?: boolean}` | `{dry_run: boolean, link_stats: natnum, versions: natnum}` | yes |
| `graph/entity` | user | `{as_of?: natnum, id: string, include?: ["links" \| "notes" \| "history"]}` | `EntityAnswer` | no |
| `graph/excise` | user | `{fields?: ["title" \| "status" \| "body" \| "assignee" \| "data"], reason: Text, rotate_backups?: boolean, target: ExciseTarget, transcripts?: boolean}` | `ExciseAnswer` | yes |
| `graph/export` | user | `{history?: boolean, out?: AbsPath, project?: string, since?: natnum, with_activity?: boolean}` | `PortAnswer` | no |
| `graph/grants` | user | `{grant?: {access: "read" \| "edit-user-tasks" \| "options", expires?: number, names?: [string], what: string, who: string}, list?: {active?: boolean, who?: string}, revoke?: string}` | `{grant?: GrantView, grants?: [GrantView], revoked?: boolean}` | yes |
| `graph/history` | user | `{id: string, since?: natnum}` | `{versions?: [any]}` | no |
| `graph/import` | user | `{dir: AbsPath}` | `PortAnswer` | yes |
| `graph/neighbors` | user | `{as_of?: natnum, depth?: natnum, direction?: "out" \| "in" \| "both", id: string, kinds?: [string]}` | `{hidden: natnum, links?: [any], nodes?: [any], truncated?: string}` | no |
| `graph/path` | user | `{as_of?: natnum, from: string, kinds?: [string], max_depth?: natnum, to: string}` | `{hidden: natnum, links?: [any], nodes?: [any], truncated?: string}` | no |
| `graph/privacy` | user | `{delete_copies?: [string], reload: boolean}` | `PrivacyAnswer` | yes |
| `graph/proposed` | user | `{accept?: [natnum], reject?: [natnum]}` | `{blocked?: [integer], listed?: boolean, reverted?: Reverted}` | yes |
| `graph/put-parsed` | user | `{collected?: [string], gone?: [{kind: "file" \| "spec" \| "commit" \| "branch", path?: AbsPath}], root?: AbsPath, sources?: [{entities?: [{data?: JsonObject, id: string, kind: string, status?: Status, title?: Text}], links?: [{dst: string, kind: string, origin?: "parsed" \| "inferred", src: string}], mtime?: number, source: {kind: "file" \| "spec" \| "commit" \| "branch", path?: AbsPath}}], updates?: [{data_patch?: JsonObject, id: string, status?: Status}]}` | `{changed: natnum, refused?: [Refusal], retired: natnum}` | yes |
| `graph/record` | user | `{collected?: string, commits: [{date: number, seq?: integer, sha: string, subject: Text}], repo: AbsPath, task: string}` | `{ids?: [string]}` | yes |
| `graph/revert` | user | `{cascade?: boolean, entity?: string, tx?: natnum, ver?: natnum}` | `{blocked?: [integer], listed?: boolean, reverted?: Reverted}` | yes |
| `graph/scrub` | user | `{}` | `{blocked_by?: string, vacuumed: boolean, wal_truncated: boolean}` | yes |
| `graph/settings` | user | `{get?: Empty, set?: {only_user_closes?: boolean}}` | `{only_user_closes: boolean}` | yes |
| `graph/sql` | user | `{deadline_ms?: natnum, params?: [SqlParam], rows?: natnum, sql: string}` | `{columns?: [string], rows?: [[any]], truncated: boolean}` | no |
| `hello` | user, agent, service | `{client?: string, cwd?: AbsPath, drgnx_version?: string, nonce: Nonce, proof?: Hex64, proto: natnum, records?: natnum, schema?: natnum}` | `HelloReply` | no |
| `job/approve` | user | `{budget?: Usd, id: Id}` | `JobSummary` | yes |
| `job/block` | user | `{reason?: Text, task: TaskRef}` | `JobSummary` | yes |
| `job/card` | user | `{action: CardAction, arg?: StringOrNumber, card: natnum}` | `JobSummary` | yes |
| `job/dismiss` | user | `{message: natnum}` | `boolean` | yes |
| `job/order` | user | `{delta: Delta, task: TaskRef}` | `JobSummary` | yes |
| `job/propose` | user | `{auto?: boolean, budget?: Usd, gate?: "review" \| "review+accept", plan: PlanRef, repo?: AbsPath}` | `JobSummary` | yes |
| `job/reassign` | user | `{profile: string, task: TaskRef}` | `JobSummary` | yes |
| `job/reply` | user | `{message: natnum, text: Prompt}` | `boolean` | yes |
| `job/resume` | user | `{budget?: Usd, id: Id}` | `JobSummary` | yes |
| `job/start-task` | user | `{auto?: boolean, gate?: "review" \| "review+accept", n: TaskNo, plan: PlanRef}` | `JobSummary` | yes |
| `job/status` | user | `{decisions?: boolean, id?: Id}` | `JobSummary \| {jobs?: [JobSummary]}` | no |
| `job/stop` | user | `{id: Id}` | `JobSummary` | yes |
| `job/unblock` | user | `{task: TaskRef}` | `JobSummary` | yes |
| `machines/list` | user | `{}` | `{machines?: [Machine]}` | no |
| `machines/report` | user | `{machine: string, slots?: [{holder?: string, id: string, kind: string}], ttl: number}` | `{local: boolean, machine: string, slots?: [Slot]}` | no |
| `matrix/check` | user | `{action: "agents.start" \| "agents.model" \| "agents.control" \| "graph.change" \| "task.done" \| "spend" \| "spend.over" \| "code.read" \| "code.edit" \| "commit" \| "merge.integration" \| "push.ci" \| "push.main" \| "code.ci-config" \| "machines" \| "job.container" \| "job.keys" \| "network" \| "browser" \| "browser.web" \| "browser.private" \| "unsandboxed" \| "settings.change" \| "user.private" \| "user.emacs" \| "chat.project-read", amount?: number, plan?: string, project?: string, who: {agent?: string, provider?: string, role?: "manager" \| "worker" \| "chat"}}` | `{verdict: "allow" \| "ask" \| "never", why?: string}` | no |
| `matrix/get` | user | `{plan?: string, project?: string, who?: {agent?: string, provider?: string, role?: "manager" \| "worker" \| "chat"}}` | `MatrixView` | no |
| `mcp/attach` | service | `{kind: AgentKind}` | `{identity: string}` | no |
| `mcp/session` | user | `{agent: AgentName, cwd?: AbsPath, job?: Id, owner: natnum, profile?: Id, sid?: SessionId, task?: TaskRef, tools?: {tracker: boolean}}` | `{sid: string, socket: string}` | no |
| `mcp/session-close` | user | `{sid: SessionId}` | `boolean` | no |
| `messages/mark` | user | `{id: natnum, state: "delivered" \| "read" \| "acted"}` | `{changed: boolean}` | yes |
| `messages/retract` | user | `{id: natnum}` | `{retracted: boolean, status: string}` | yes |
| `messages/send` | user | `{answers?: natnum, job?: Id, question?: boolean, recipient: AgentName, seen?: natnum, sender?: AgentName, text: Text}` | `SendResult` | yes |
| `pace/get` | user | `{provider?: string}` | `{meters?: [Pace]}` | no |
| `ping` | user, agent, service | `{}` | `{pid: natnum}` | no |
| `plans/get` | user | `{plan: string}` | `PlanView` | no |
| `plans/write` | user | `{base_version?: natnum, plan?: string, project?: string, tasks?: [{blocks?: [string], body?: Text, interfaces?: Text, model?: string, number: string, profile?: string, role?: string, status?: Status, steps?: [{done: boolean, text: string}], title?: string}], title?: string}` | `{plan: string, tasks?: [TaskId], tx: natnum}` | yes |
| `presence/set` | user | `{away: boolean}` | `boolean` | no |
| `records/decide` | user | `{accept: boolean, id: Id}` | `{backup?: string, id: string, note?: string, status: "open" \| "accepted" \| "rejected" \| "stale"}` | yes |
| `records/import` | user | `{dry_run?: boolean, only?: "plans" \| "ledgers" \| "deferred" \| "build-board" \| "board", root: AbsPath}` | `{backup?: string, dry_run: boolean, files?: [ImportedFile]}` | yes |
| `records/proposals` | user | `{path?: AbsPath}` | `{proposals?: [Proposal]}` | no |
| `records/status` | user | `{path?: AbsPath}` | `{views?: [ViewStatus]}` | no |
| `reports/get` | user | `{id?: string, task?: string}` | `{reports?: [Report]}` | no |
| `restart` | user | `{}` | `boolean` | no |
| `review/mark` | user | `{agent: AgentName, event?: {data?: JsonObject, job?: Id, kind: "start" \| "stop" \| "claim" \| "release" \| "status" \| "decision" \| "edit" \| "test" \| "question" \| "answer" \| "review" \| "message" \| "card" \| "accept" \| "revert" \| "comment" \| "job", summary?: Text}, hash: string, path: string, state: "accepted" \| "pending"}` | `boolean` | yes |
| `runners/add` | user | `{accept?: "all" \| "heavy", host: string, name?: Id, prefix?: string, profile?: "dedicated" \| "workstation", root?: AbsPath, trust: "mine" \| "my-cloud" \| "shared"}` | `Runner` | yes |
| `runners/audit` | user | `{job?: Id, key?: KeyName}` | `{rows?: [AuditRow]}` | no |
| `runners/bench` | user | `{name: Id}` | `Runner` | yes |
| `runners/check` | user | `{name: Id}` | `Runner` | yes |
| `runners/keys` | user | `{keys: RunnerKeys}` | `boolean` | no |
| `runners/keys-held` | user | `{}` | `{names?: [KeyName]}` | no |
| `runners/list` | user | `{}` | `{runners?: [Runner]}` | no |
| `runners/probe-host` | user | `{host: string}` | `{effective: Effective, facts?: HostFacts, missing?: [Missing]}` | no |
| `runners/remove` | user | `{confirm: boolean, name: Id}` | `{name: string}` | yes |
| `runners/set` | user | `{accept?: "all" \| "heavy", name: Id, profile?: "dedicated" \| "workstation", trust?: "mine" \| "my-cloud" \| "shared"}` | `Runner` | yes |
| `runners/unbench` | user | `{name: Id}` | `Runner` | yes |
| `say/end` | user | `{id: Id}` | `boolean` | yes |
| `say/revise` | user | `{id: Id, text: Text}` | `boolean` | yes |
| `say/start` | user | `{profile?: string, project?: Id, repo: AbsPath, text: Text}` | `{id: string}` | yes |
| `search/embedders` | user | `{}` | `{builtin: BuiltinInfo, prefer?: string, servers: [ServerInfo]}` | no |
| `search/index` | user | `{now?: boolean, rebuild?: boolean, root: AbsPath}` | `{started: boolean}` | yes |
| `search/model-download` | user | `{consent: {bytes: natnum}, model: Id}` | `{started: boolean}` | yes |
| `search/query` | user | `{k?: natnum, root: AbsPath, scope?: "tests" \| "docs" \| "all" \| "code", text: Prompt}` | `{hits: [Hit], lag: Lag, lag_line: string, model?: string, notice?: string}` | no |
| `search/server-plan` | user | `{kind: "tei" \| "ollama"}` | `ServerPlan` | no |
| `search/server-start` | user | `{confirm: boolean, kind: "tei" \| "ollama"}` | `{provider: ProviderEntry, started: boolean, unit: string}` | no |
| `search/server-stop` | user | `{kind: "tei" \| "ollama"}` | `{stopped: boolean}` | no |
| `search/status` | user | `{root: AbsPath}` | `StatusAnswer` | no |
| `search/typing` | user | `{}` | `{}` | no |
| `settings/confirm` | user | `{error?: string, ok: boolean, tx: natnum}` | `{state: "accepted" \| "reverted" \| "blocked"}` | yes |
| `settings/explained` | user | `{req: natnum, settings: [JsonObject]}` | `boolean` | no |
| `settings/record` | user | `{changes: [{file: string, id: string, line?: natnum, value?: Text}], req: string, reverts?: natnum, tool: string}` | `{tx: integer}` | yes |
| `shutdown` | user | `{}` | `boolean` | no |
| `spend` | user, agent, service | `{agent?: AgentName, job?: Id, task?: TaskRef}` | `{cost: number, input: natnum, output: natnum, requests: natnum}` | no |
| `status` | user, agent, service | `{}` | `HubStatus` | no |
| `subscribe` | user | `{}` | `boolean` | no |
| `tasks/find` | user | `{assignee?: string, cursor?: natnum, labels?: [string], project?: string, query?: Text, status?: Status}` | `{cursor?: natnum, tasks?: [any]}` | no |
| `tasks/ready` | user | `{labels?: [string], limit?: natnum, project?: string}` | `{cursor?: natnum, tasks?: [any]}` | no |
| `tasks/write` | user | `{acceptance?: Text, add?: [string], body?: Text, cwd?: AbsPath, dst?: string, id?: string, kind?: string, labels?: [string], lease?: integer, mode?: "children" \| "replace", note?: Text, op: "create" \| "update" \| "claim" \| "heartbeat" \| "release" \| "handoff" \| "reassign" \| "split" \| "complete" \| "link" \| "unlink" \| "label" \| "tools", parent?: string, parts?: [Text], priority?: integer, project?: string, remove?: [string], src?: string, status?: Status, title?: Text, to?: string, tracker?: boolean, ver?: integer}` | `any` | yes |
| `timeline/get` | user | `{before?: natnum, id: string, limit?: natnum, rollup?: boolean, scope: "session" \| "task" \| "plan" \| "project", since?: natnum}` | `{next?: natnum, rollup?: Rollup, steps?: [Step]}` | no |
| `work/conclusions` | user | `{session: string}` | `{conclusions?: [Conclusion]}` | no |
| `work/file-at` | user | `{path: string, seq: natnum, session: Id}` | `{bytes: string, seq: natnum}` | no |
| `work/files` | user | `{session: Id}` | `{files: [EditedFile]}` | no |
| `work/hunks` | user | `{path: string, session: Id}` | `{diff: string}` | no |
| `work/map/close` | user | `{view: string}` | `boolean` | no |
| `work/map/set` | user | `{collapsed?: [natnum], density?: "compact" \| "comfortable" \| "roomy", filters?: {finished?: boolean, focus?: string, overlaps?: boolean}, selected?: string, shown?: boolean, view: string, width_units?: natnum}` | `{version: natnum}` | no |
| `work/map/subscribe` | user | `{collapsed?: [natnum], density?: "compact" \| "comfortable" \| "roomy", filters?: {finished?: boolean, focus?: string, overlaps?: boolean}, selected?: string, view: string, width_units: natnum, workspace: {id: string, roots?: [string]}}` | `MapFrame` | no |
<!-- hub-methods:end -->

### Classes

A connection's class is what it proved. `test/conformance/class-matrix.json` is a hand-written copy of every
method's classes (a test checks that it and the registry agree; the conformance row `class/matrix` calls every
method from every class).

| Class | Who | What proves it |
|---|---|---|
| `user` | the editor, the CLI | a `hello` whose `proof` is HMAC-SHA256 with the cap of `"drgnx-hub client " + hub nonce + " " + nonce`: it read the cap file beside the socket |
| `agent` | a sandboxed job agent and the servers the hub starts for it | the socket it came in on (the session's own): its session is bound to the connection |
| `service` | outside agents' coordination bridges, probes, anything without a proof | nothing (the default) |

| Classes | Methods |
|---|---|
| user, agent, service | `hello`, `ping`, `status`, `coord/notify` (users too: SB-T12-4), `agents/list`, `spend` |
| user | `browser/check`, `restart`, `shutdown`, `subscribe`, `events/since`, `env/set`, `config/settings`, `config/changed`, `gateway/register`, `gateway/unregister`, `gateway/keys`, `gateway/set-budget`, `gateway/editor-token`, `gateway/keys-held`, `agents/{start,get,send,stop,kill,permission,do}`, `job/{propose,start-task,reassign,block,unblock,order,approve,stop,resume,card,reply,dismiss,status}`, the editor's writes `cards/settle`, `messages/{send,mark}`, `events/add`, `review/mark`, the seam's `coord/{job-create,job-set,task-status,leases,decide,agent,card-create,card-set,held,prune}`, and `mcp/{session,session-close}` |
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
| `PlanId` | `plan:` and a name, no control characters, at most 4352 (the scan's plan entity id) |
| `PlanRef` | an `AbsPath` (the plan's file, imported first) or a `PlanId`: anything else, a TRAMP name included, is refused |
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
| `agent-step` | sessions (the front) | `{session, step: Step}`: a step opened or closed, with its class, the hub's stamps and its anchors |
| `exec-done` | jobs (the front) | `{id, session?, status, exit?, summary: {exit?, failing, lines, log}}` |
| `machines-changed` | machines (the front) | `{machines: [{machine, slots: [{id, holder?, kind}], local}]}`: the whole list, sent when a report, an expiry or the local slots changed it |
| `agent-presence` | the presence model (to the connections that asked) | `{file, entries: [{session, file, mode, line?, source, step, at}]}`: who is in the file now, at most once per file per 100 ms ("The presence model") |
| `work-map` | the Work map (to the view's connection only) | `{view, version, base, full?, changed: [Item], removed: [Id], entered: [Id], places?, edges?, layout?, needs_you?, chips?, stale?}`: what changed in one map view since version `base` ("The Work map") |
| `supervisor` | the supervisor | `{rule, session?, exec?, task?, card?, text}` |
| `view-written` | records | `{path, kind, hash}`: a view file written (never committed) |
| `view-proposal` | records | `{id, path, by?}`: a hand edit to a view became a proposal |

The hub sends every event it lists; `card` and `lease-released` are in the registry for the clients that read them,
and nothing sends them now (`runstav/src/events.rs`).

## Per-session sockets

A sandboxed session's agent reaches drgnx's MCP tools through a directory of its own, `s/SID` beside the hub's socket
(`$XDG_RUNTIME_DIR/drgnx/s/SID`, or the fallback place beside it), which the sandbox may bind as its `:run`
(`/run/drgnx` inside on Linux, its own path on macOS). The hub serves it: `hub.sock` (the hub protocol's agent class),
`mcp.sock` (the coordination tools, hosted in the hub: [Sessions and their sockets](#sessions-and-their-sockets)) and
`gateway.sock` ([Registrations](#registrations)). Each level is private (mode 0700, this user's, never a link), and a
socket's path there must fit 103 bytes. The agent's side, the bridge, is in
[coordination.md](coordination.md#how-an-agent-reaches-the-tools).

## Sessions

The hub holds agent sessions itself (`drgnx-ratatoskr/src/agents/`; agent system part 1, Task 8a). It is each
session's ACP client (`hermod`): `agents/start` takes a profile (settings: `drgnx-agents-profiles`), starts the
agent, runs `initialize` (with `fs` read and write offered, never `terminal`) and `session/new`, and answers the id
and name. The session is recorded in `runtime.db` (`asession`, migration 5) and in the graph as a `session` entity
(`run_by` its agent, `works_on` its task; a brainstorm's topic note and design document are in its `data`).

- **Module env.** `agents/start` takes `env` (at most 8 `{name, value}`): what the editor's modules add through
  `drgnx-agents-env-functions` (no module adds one by default). Each name must be on the runtime
  setting `drgnx-agents-start-env-names` and must not be `refused_env_name` (a name with KEY, TOKEN, SECRET, PASSWORD,
  PASSPHRASE or CREDENTIAL in it) nor a provider's `key_env` (as `env/set`), else `invalid-params` at `env[i].name`; the values are added to the launch plan's
  environment last, so they win over the profile's and the lock's. The hub keeps them in the session's notes
  (`meta.json`, 0600 in its own folder): a session it restarts or resumes gets them again, checked against the settings
  as they are then (a name taken off the list since, or now a provider's `key_env`, is left out and logged). The mirror (`drgnx-agents-mirror-start`) fills `env` from the hook and
  drops, with one notice, the names the hub would refuse. The mirror also runs `drgnx-agents-task-functions` for hub
  sessions that have a task: `start` when a session is first seen, `turn-start` when a turn begins and `turn-end` when
  it ends. A turn begins when the status becomes `busy` and ends when it stops being busy or when its `stop` entry
  arrives, whichever the mirror sees first: the hub sends a session's state at most every 50 ms, so a short turn can
  go by with no `busy` snapshot. Each turn runs its hooks once (the mirror counts turns per session), a snapshot or
  entries sent again run nothing, and a fetched transcript's turns that had ended when the editor last heard of the
  session (within the `entries_count` of the last snapshot it applied) run none. A turn that ended after that runs
  its hooks once, even when it ended before the fetch's answer and its own events were dropped as older than it. The
  work tracker records a task's commits from `turn-end`.

- **Shapes.** Snapshots and entries are records 2 (`runstav::methods::agents::{Snapshot, Entry}`), unchanged for the
  mirror and the cockpit. Message chunks of one message join into one entry (`text`, `length`); a tool call and its
  updates are one `tool` entry; a plan is replaced, not repeated. `agent` and `agent-entries` events come at most
  once per session per 50 ms. `agents/list` for an `agent` or `service` caller is shaped by `shape::result`.
- **Permissions.** A permission request of the agent waits in the snapshot's `permissions` until the user answers it
  with `agents/permission` (an option the agent offered, or none to reject). Only the user's connection answers: no
  peer's or manager's message is approval. The matrix (Task 12) is asked first; a `Never` rejects at once. A request
  the matrix asks about carries its `matrix` card's id: the answer settles the card, settling the card
  (`cards/settle`) answers the request, and the matrix is checked again before the agent goes on. A request without a
  card (the store made none) has the id `r<n>`.
- **Files.** `fs/read_text_file` and `fs/write_text_file` are served inside the session's directory only (symlinks
  resolved first). A brainstorm session may read the project and write only its design document.
- **Launch.** A session starts inside Gleipnir (`agents/launch.rs`); only test builds (`test-hooks`) can start one
  unsandboxed.
- **Stop and kill.** `agents/stop` on a running turn cancels it (`session/cancel`), answers the pending permission
  requests cancelled and holds the queue (`paused`); an agent that has not ended the turn after 2 s loses its process
  group. A second Stop of the same turn changes nothing. A Stop that comes before the turn's prompt has reached the
  agent wins: the prompt is not sent, no `session/cancel` goes, and it waits at the front of the held queue. On a
  session with no turn running it ends the session
  (SIGTERM, SIGKILL after 3 s). `agents/kill` ends it at once. The pause after a tool call and the turn's end answer
  the requests still waiting cancelled too.

### Prompts, queue and steer (Task 8b)

`Hub::prompt(sid, text, Origin::{User, Peer(name), Hub})` (`Hub::send` is the user's). Idle, the prompt goes behind
whatever a Stop held back and the queue is delivered; during a turn it is queued, and nothing but Stop cancels:
`:mode interrupt` is `queue`, and `:mode steer` puts the prompt ahead of the ordinary queued ones (a steer into the
running turn needs an adapter request `hermod` does not send yet). A peer's prompt is quoted under a header naming the
peer; its entry carries `origin: "peer:NAME"`. `agents/do`: `deliver-queue` releases the hold and sends the next
prompt; `unqueue` (`n`) removes the Nth waiting prompt; `requeue` (`n`, `text`) replaces it (empty removes it). The
snapshot's `queue` lists the waiting texts and `paused` is true while they are held. `Hub::cancel_after_tool(sid)` is
the pause: the running tool call completes, then the turn is cancelled and the queue held.

A turn ending as cancelled holds the queue, an error does too; an end-of-turn stop delivers the next prompt at once.

### A session's turn

The choices about a session's turn are a pure core, `agents/session/turn_core.rs` (`TurnCore`). It has no I/O, clock
or threads, and lives in the session's state under the same lock. The shell (`agents/session.rs`) feeds it every
event and performs what it answers; the entries, steps and transcript stay with `State::apply` and the shell.

- Events: `Send` (a prompt, with the profile's steer mode and `if_free`), `PromptDone` (cancelled or not),
  `PromptFailed` (closed or not), `Stop` (or the pause after a tool call), `Kill` (`agents/kill`, the hub ending, or
  a Stop's deadline for its turn), `PermissionAsked` (with the turn it came in), `PermissionAnswered`,
  `ToolCompleted`, `EmitTick`, `QueueEdited` (deliver, unqueue, requeue, the freshness gate's notice), `Changed`,
  `Exited`, and `Sending` (the turn's task is about to hand its prompt to the agent).
- Effects: start a turn with the next prompt, send its prompt now (`Prompt`) or put it back (`PutBack`, the hub's
  end), name what a user's kill drops (`Discard`), end it (waiting on a job, or held), tell the agent to cancel, arm a
  Stop's deadline, end the process group, hold a permission request for the user, answer it or answer it cancelled,
  keep the queue on disk, announce a change, arm and send the event pair; and the refusals (exited, not free, no
  turn running, no such queued prompt, no such request).
- The shell asks it `status()`, `queue()`, `kept()` (what the queue on disk holds), `paused()`, `turn()`, `ending()`
  and `is_free()`.

What the core keeps:

- A turn starts only when none runs, with the queue's next prompt, and only when the queue is not held, no kill is
  under way and the hub is not ending.
- A prompt sent while the process is being ended for good (`agents/kill`, `agents/stop` with no turn running, a
  Stop's deadline) is refused as exited, and the session is not free then: the sender keeps it (a peer's message goes
  back to `queued`, a wake stays pending). A prompt sent while the hub ends waits on disk for the next start.
- A turn's prompt reaches the agent only through its `Sending` step. Until then the queue on disk holds it at its
  front (`kept()`: the waiting prompts behind the prompt not yet sent), so a hub that dies in between, with no end
  step, runs it at the next start; the shell writes the turn's entries to the transcript file first and then the
  queue without it (a hub that dies between the two runs the prompt again rather than losing it). When the hub ends,
  a Stop comes or the agent's process exits between a turn's start and that step, the turn is put back: its prompt
  goes back to the front of the queue, on disk too (held, after a Stop; for the next start or resume, after an exit),
  and the shell drops the turn's entries (the transcript file holds a turn's entries
  only once its prompt was sent). When the
  user's kill comes there instead, the prompt is dropped with the queue, and `Discard` names both, so a peer's
  message among them goes back to `queued` in the store.
- A turn ends once, at its agent's answer. A second Stop of a stopped turn changes nothing; a Stop's deadline ends
  the process only if the turn it stopped still runs.
- Each permission request is answered or answered cancelled once. A Stop, the pause after a tool call, the turn's end,
  a kill and the agent's exit cancel what is held; a kill's cancels change the snapshot at once, so the editors drop
  the card before the exit. A request the matrix decides on after its turn was cancelled or ended is answered
  cancelled at once: the agent no longer waits on it. A matrix card that no request waits on any more after such a
  cancel is withdrawn (`Withdraw`: `norn::write::cards::card_withdraw`, state `withdrawn` with a `card` event), so it
  leaves the open cards and the needs-you lists; a card the user settled first stays settled.
- One event pair is armed at a time; the timer's tick sends it. While the hub ends none is armed or sent: the shell
  reads the snapshot when it sends a pair, so one sent then could show the session's own exit, and an editor that read
  it before its connection's end of file would keep that reason instead of the hub's.

The shell acts on a turn's end as the step decided it: whether the hub is ending is read under the step's lock, never
again after it.

`agents/session/turn_core/tests.rs` runs the core in every order (skuld, exhaustive) of:

- a user who sends, stops and delivers, a second Stop (the refused waits), an agent that answers what it works on, and
  the stops' deadlines (a deadline's kill leaves the process alive until the agent's next answer);
- four senders, an editor that removes and delivers, an agent, and a pause after the tool call;
- two senders, the hub's delivery (`sending`, then the prompt), an editor that delivers, an agent, and the user's kill
  or the hub's end, then the exit;
- a sender, an agent, the event pair's timer, and the hub's end, then the exit (no pair goes out while the hub ends);
- a user who answers and stops, an agent that asks twice, completes a tool call and answers, a pause after the tool
  call, and the cockpit settling a card;
- two senders, an agent that asks in each turn, the matrix deciding late, and the user's kill, the hub's end or a
  crash;
- a user who sends and stops, an agent that asks the same question twice and answers, the matrix deciding late
  through the question's open card or a new one, and the cockpit settling the open card (no card stays open that no
  request waits on, and none is withdrawn while one does);
- two senders, the turn's task that sends each prompt in a step of its own, an agent, and the hub's end, then the exit
  (every prompt reached the agent or waits in the queue on disk);
- the same, but the hub dies with no end step and nothing of it runs after (every prompt reached the agent or is in
  the queue on disk);
- a sender, the turn's task that sends in a step of its own, the freshness gate's notice (a queue write), and the
  agent's exit, then a resume from the queue on disk (every prompt reaches an agent once);
- a user who sends, stops and delivers, the turn's task that sends each prompt in a step of its own, an agent, and
  the stop's deadline (no prompt goes after its turn was told to cancel);
- a sender, the hub's delivery (`sending`, the prompt, the mark), an agent, and the user's kill, then the exit (a
  message marked delivered ran; one the kill discarded is `queued` again).

After every step the tests check that a turn starts only when none runs, once per prompt, never while the queue is
held or on a process being ended; that a turn ends at its agent's answer; that a request waits only while its turn
runs and never once the process is being ended; that what is on disk (each `Persist`, and a turn's start) is what the
core holds; and that a free session starts a turn with the next prompt. Each source was shown to fail on a bug it
exists for. The edges those orders take as given are the shell's:

- a turn's answer follows its start, and every update the agent sent in that turn (the reader drains them first);
- a permission request names the turn that ran when the reader received it;
- a Stop's deadline names the turn that Stop stopped.

### Transcripts

`<state>/hub/transcripts/<sid>.jsonl` (0600; the folder 0700): one line `{"n": INDEX, "entry": ENTRY}` per entry,
written when a turn starts and ends and when the agent exits; a later line for an index replaces the earlier one.
Every string goes through `runstav::secrets::looks_like_secret` first: a private key replaces the whole text, any
other hit the word (or the line) with `[redacted: KIND]`. Beside it: `<sid>.queue.json` (the held queue and the
pause, unredacted because the prompts are still to be sent; removed when empty) and `<sid>.meta.json` (a brainstorm's
topic note and design document, so that a resumed brainstorm keeps its write fence).

### Steps

The hub cuts each turn into steps from its own clock (`think` between tool calls, `tool` from the tool call to its
`completed`/`failed` with the title and ACP kind, `user-wait` while a permission request waits, `paused` while the
queue is held) and writes each closed step to schema 8's `step` table (`norn::write::steps`), in order, from one
writer task per session; the last step of a turn carries its tokens and `turn_id` (`_meta.turnId`). Each write is
announced as an `agent-step` event (`{session, step}`) and on `Hub::subscribe_steps()`. A store that is not ready
loses the row (logged), not the event.

**Step detail** (`work::detail::of`, schema 9's `step_detail`): a tool step also records what it read, searched or
fetched, in the same transaction as the step, taken when the call completes because `rawInput` is refined while it
streams. The hub keeps `_meta.claudeCode.toolName` and `.parentToolUseId` of each tool call beside the entries (the
entries' wire shape is unchanged) and classifies by tool name, never by ACP kind alone: Claude's `WebSearch` is kind
`fetch`, like `WebFetch`. A provider that sends no name (Codex's parsed calls, Gemini) is classified by kind; Gemini's
query or URL, which is only in the title, is labelled `acp-title`. A `Read` has `line_end` only from `rawInput.limit`.
Content is never kept and no text field is longer than 4 KiB. A shell call has no detail yet (the shell-read layers
write `command` and `opened` details). The detail is the step's `detail` on `agent-step` and `timeline/get`
(`runstav::methods::timeline::StepDetail`). The mock agent's `provider:read|grep|web-search|web-fetch|write` words
send each personality's real shapes. A Claude Code subagent's steps (the `Task` tool's nested calls) keep the
`Task` call's id as `detail.parent_tool` (`work::subagents`); the mock's `provider:task DESCRIPTION` sends one.

### The presence model

Who is in which file, at which line, now (`work::presence`; agent system part 2 builds it, part 3's cursors, gutter
and badges build on it). This is its contract.

- **An entry** is one session's latest `{session, file, mode, line?, source, step, at}` in one file
  (`runstav::methods::work::PresenceEntry`). `file` is an absolute path (links followed when the file exists); `mode`
  is `read`, `edit`, `listed` (a listing, a recursive search) or `write` (a shell command's); `line` is the last line
  known, or absent ("file only"); `source` is `acp` (a read or search step's fields), `edit` (an edit step), `command`
  (a file a shell step's command names, from `work::shell_read`, only inside the session's folder) or `opened` (a file
  its processes opened; Gleipnir's tracer, not yet); `step` is the timeline step it came from, `at` the hub's time.
  Of one session's entries in one file the later step wins, then the stronger mode (`edit` > `write` > `read` >
  `listed`).
- **Now:** an entry is now while its session is live and it is younger than 120 s (`presence-stale-after`) or it is
  its session's latest entry. Older entries stay as history. A session ended with `agents/stop` or `agents/kill` is in
  no file.
- **Methods** (user connections): `agents/presence/subscribe {workspace: {id, roots}} | {file}` makes the connection
  get `agent-presence` for the files under the roots (or that file) from then on, and answers `{files: [{file,
  entries}]}`, who is in them now; `agents/presence/get {file} -> {file, entries}`. The names keep clear of
  `presence/set`, the user's away state. A connection's subscriptions end with it.
- **The event** `agent-presence {file, entries}` goes only to the connections that asked (`Front::send_to`), at most
  once per file per 100 ms of the hub's clock: a change arms one flush 100 ms later (task `presence:flush`), and every
  file changed meanwhile goes out once, with its entries then.
- **Durability:** none of its own. At start, before the recorded sessions resume, it is rebuilt from their steps'
  details (reads, searches, edits); a shell step's command is not stored, so its files come back with its next step.
- New sources (Gleipnir's opens, part 3's own refinements) add a `source` value without changing this contract.

### The Work map

The Work space's map (`work::map`): the hub feeds the pure map core `vegvisir` from its sources and sends each map
view only what changed, to the connection that shows it.

- **Methods** (user connections). `work/map/subscribe {view, workspace: {id, roots}, width_units, density?, filters?,
  collapsed?, selected?}` opens one view of the connection (again, if it is open) and answers its full frame `{version,
  items, edges, layout, needs_you, chips}`. `view` is the editor's id for it: one editor can show two workspaces, or one
  at two widths, so the hub keeps state per (connection, view). `work/map/set {view, filters? | collapsed? |
  width_units? | density? | shown? | selected?}` answers `{version}`; an unknown view is `invalid-params`.
  `work/map/close {view}` ends one; a connection's views end with it. A workspace no view shows is dropped.
- **The event** `work-map` goes by `Front::send_to` to the view's connection only. `version` counts the view's events
  from the frame's 1, and `base` names the version it applies to: an editor drops an older one and subscribes again on
  a gap. A full frame (`full`) carries every item shown in `changed` and the new `layout`; a delta carries the items
  new or changed (whole), `removed` ids, and `edges` (all, among the items shown) when the edge set changed.
- **Coalescing** (design §11.3 step 5; `work::map::Coalescer`, pure, tested in every order). Field changes go out at
  most once per 100 ms per view: the first change arms a flush 100 ms later on the hub's clock. A live arrival takes a
  free place at the end of its layer's last row (or a row of its own at the bottom) and fades in (`entered`, with its
  rectangle and form in `places`); a departure fades out and leaves its place empty; nothing else moves
  (`vegvisir::layout::place_live`). What arrived and went reflows after a quiet second (no change and no
  `work/map/set` with `selected` for 1 s) as one full frame, unless that would move an item of the selection's chain:
  then it waits for the user. The user's own change (filters, collapsed layers, width, density, shown again)
  relayouts at once. The clock's minute is one delta (time fields are minutes).
- **Hidden:** `shown: false` gets no deltas: one `work-map` with `stale: true` at the next change, then nothing;
  `shown: true` sends one full frame.
- **Sources.** Each session's snapshot and subagents at its `agent` emit (state, spend, context; its branch and tree
  read from its folder's `.git` at first sight: `branch:REPO/NAME`, REPO being the main tree's folder name, so a linked
  worktree is a branch of its repository); each closed step (the card's activity); the presence model's changed files
  (edits in flight and reads, keyed `file:REPO/PATH` through the session's tree or a workspace root); after each step
  that took a snapshot (an edit, or a turn's first step), the worktree's changed files against its base
  (`work::edits::changed`, the interim before the edit history) as its changed set; the machine registry; and, re-read after each write while a map is open (task `map:run`), the store's asks, specs, plans,
  tasks, `asked` and `derives` links, open cards and the worktree bases' "based on" pairs. A session belongs to a
  workspace when its folder, its tree or its repository is under one of the roots. Overlaps are the core's: two live
  agents on two branches changing one file, from their edits in flight and from their worktrees' changed sets, so a
  finished edit still overlaps.
- **Restart:** nothing is kept. The editor's re-subscription after a restart gets a full frame from the new hub's
  sessions and store.

### After a restart

`Hub::shutdown` (server end) ends every session's process group and leaves the rows, transcripts and queues.
`Hub::resume_all` (a background task after the settings are read) reads `asession`, starts each profile's agent and
brings the session back: `session/resume` when the agent advertises it, else `session/load` (the agent replays its
history, and the transcript is not used), else the row stays for the next start. The transcript and the queue are
read back, and the first queued prompt is delivered. `restart-when-idle` counts the hub's busy sessions: a running
turn delays the restart, an idle session does not.

## Sessions and their sockets

Under Ratatoskr the coordination tools (`norn::tools`, served by `mimir`) run in the hub itself, with no server
process per connection (`runtime/crates/drgnx-ratatoskr/src/sessions.rs`). Two doors lead to them, and neither takes
an identity from the agent: not from a tool's arguments, and never from `DRGNX_AGENT` (the hub's own is ignored).

- **A session's socket (`mcp/session`, user).** `{agent, sid?, job?, task?, cwd?, owner}` answers `{sid, socket}`.
  One that takes longer than 1 s (real time) logs a warning with each stage's time (the owner's check, the serial
  lock, the directory, the runtime.db row, the bind, the tools, the listener), and the settings' refresh before it
  one of its own when that alone took longer.
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

### The session's provider proxy (`proxy.sock`)

A sandboxed session whose network cell is provider-only or provider-and-packages (every session `agents/start`
makes: the hub never grants `Open`) has no network but its sandbox's relay port, 3128, whose other end is
`proxy.sock` in its session directory (`runstav::paths::SESSION_PROXY_SOCKET`; the spec sets
`HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` to it, [gleipnir.md](gleipnir.md)). The hub serves that socket
(`runtime/crates/drgnx-ratatoskr/src/agents/net.rs`):

- **One proxy per session**, Gleipnir's CONNECT-only allowlist proxy (`gleipnir::net::proxy`, as a container job's),
  held in `agents::net::SessionNet`. `launch()` binds it after the session's MCP bridge and the prepared sandbox spec
  (either makes the session directory), and before the spawn: a stale file at the path is replaced, the socket is
  0600 (`sessions::bind_socket`).
- **What it allows** (`net::provider_hosts`), each an exact `host:port`, in this order:
  - the base host and port of each provider the profile's gateway chain names in the provider table in effect (none
    for a profile without `:ai`);
  - the hosts of the CLI it starts (`net::CLI_HOSTS`): claude → `api.anthropic.com:443`, `platform.claude.com:443`
    (the OAuth token refresh); codex → `api.openai.com:443`, `chatgpt.com:443`, `auth.openai.com:443` (the ChatGPT
    login's token refresh); gemini → `generativelanguage.googleapis.com:443`, `oauth2.googleapis.com:443`,
    `cloudcode-pa.googleapis.com:443` (the Code Assist API of a Google login);
  - the `agents-net-hosts` tier of the cell (`provider-only`, or `packages` for provider-and-packages).
- **A denied host is an event, never a card.** The proxy says each denied `host:port` once per session; the hub writes
  it to work.db's `event` table: kind `status`, the session as `agent`, data
  `{"proxy-denied": true, "session": SID, "host": "HOST:PORT"}`. A refusal (a private address, a wildcard, a malformed
  request) is only logged. Claude's lock sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (`agents::lock::plan`), so
  its telemetry, error reports and update checks are not even tried (code.claude.com/docs/en/env-vars).
- **It goes with the session.** When the agent's process ends (a stop, a kill, a crash, a close while it waits on a
  job) the proxy closes its listener and every tunnel and removes the socket; a resume binds a new one. A start that
  fails after the bind drops it the same way. The removal checks the socket's inode, so an old session's end never
  removes a newer socket at the same path.
- **Pinned names.** The proxy resolves the names of `drgnx-sandbox-proxy-pinned-addresses` (a runtime setting,
  `ProxyPins`, from `settings.el` or the editor's `config/settings`; `agents::net::pins`) to their address instead of
  asking DNS; a pinned name may lead to a private address and must still be on the allowlist. A container job's
  proxy pins the same names (`Caps.pins`, from `settings::containers::caps`; the runner protocol's `start` frame has
  room for them, [sleipnir.md](sleipnir.md), for the hub's runner client to fill). A `test-hooks` build adds
  `DRGNX_TEST_PROXY_PINS` (`NAME=ADDR,…`), so a row reaches the mock LLM on loopback under a name.

Rows: `test/conformance/sandbox-net/`. The real launch: `tests/launch_sandboxed.rs`
(`a_session_reaches_its_provider_through_the_proxy`, the sandbox lane).

### The web proxy (`web.sock`)

A session with the agent browser reaches the web only through its web relay port, 3130, whose other end is `web.sock`
in its session directory (`runstav::paths::SESSION_WEB_SOCKET`). The hub serves it with **a web proxy of its own per
session** (`runtime/crates/drgnx-ratatoskr/src/browser/web.rs`): a `gleipnir::net::proxy` under the web policy
(`Policy::Web`, [gleipnir.md](gleipnir.md), "The web policy"), separate from the session's provider proxy, with its own
connection cap (64), so one session's flood never takes another's places. `browser::web::start_web(sid, dir, ctx, who,
front)` binds it (a stale file replaced, 0600), reads the state below, and only then listens; the
`agents::net::SessionNet` it is given (`set_web`) drops it with the session, removing the socket when it is still its
own.

- **The state, read at the start and again at each change:**
  - `browser.web` is on when the session's cell for it is Allow, or a grant with no host covers the session (a
    `session` or `plan` answer); a grant that names a `host:port` (an `once` answer, until it expires) opens that one
    target alone (`WebState::set_web_hosts`);
  - the `browser.private` grants of the session and its plan (`norn::grants::matrix_grants_for`), each target in its
    wire form, go to the proxy, which matches them against what was asked and where it leads;
  - a Never cell ignores every grant;
  - the deny list is the `agents-browser-deny-hosts` setting.
- **What the proxy refuses becomes a card, at most:**
  - **`WebOff`**, a public target while the web is off: `MatrixGate::decide(browser.web)` with the facts
    `{host: "H:P"}`, the first host refused, so a page of thirty hosts makes one card. A session has at most one open
    `browser.web` card; the targets refused while it is open make none. An Allow (the cell, or a grant that covers the
    session) turns the web on without a card. Once the user refused one (a settled matrix card of the session with the
    choice `refuse` or `deny`, or one marked `refused`), the session gets no more `browser.web` cards, after a hub
    restart too.
  - **`Private`**, a private target no grant opens: `decide(browser.private)` with the facts `{target, addr, class}`:
    `target` the target as a grant names it, `{"host_port": "H:P"}` (the name, the literal or the
    `host.drgnx.internal` port that was asked), `addr` the address and port it led to, `class` its class (`lan`,
    `ula`, `link_local`, `cgnat`, `loopback`, `host_own`). One card per target; none for a refused target.
    `browser.private` is capped at Ask, so every new target asks.
  - **`Refused`** (a hard never, a port, a rebinding, a malformed request) is logged only; **`Reached`** is a store
    event, once per host per session: kind `status`, the session as `agent`, data
    `{"browser-host": true, "session": SID, "host": HOST}`.
- **Changes reach it at once.** `coord::Signals::answers_changed` is called for every write of the user's (a settled
  card, `graph/grants`, a plan's or a project's matrix override), every `config/settings`, every settings refresh that
  changed what is in effect, and `presence/set`. Every web proxy then reads its cells, grants and cards again, so a
  narrowed `browser.web` cell refuses the very next request. The proxy also reads again when the earliest grant in
  force expires and, while the matrix setting has time presets, at each minute's turn.
  - When what the session's browser may reach changed (the start included, when it is not nothing), a store event
    says so: kind `status`, the session as `agent`, data `{"browser-net": true, "session": SID, "web": BOOL,
    "hosts": ["H:P", …], "private": [TARGET, …]}` (the once-opened hosts, the private grants' targets in their wire
    form). Rows wait on it after a settle.
  - When the state changed or a card it asked settled, the proxy may ask its questions anew
    (`ProxyHandle::forget_questions`), so the target refused while another card was open asks on its retry.
- **What no grant opens** (`browser/nevers.rs`, shared by every session's proxy, started with the hub):
  - `HostAddrsWatch`: every interface address of the host (`getifaddrs`, every 5 s), which the policy treats as
    loopback;
  - `NeverSetWatch`: the hub's own TCP ports on the host's loopback: the gateway's (registered once it listens), every
    listener the hub registers (`hold`, `release`), and an Emacs TCP server's port, read every 30 s from the first line
    (`HOST:PORT PID`) of each server file in `~/.emacs.d/server/` and `$XDG_CONFIG_HOME/emacs/server/` (the hub's
    HOME; the line with the key is never read).
- **Test hooks.** A test launch is unsandboxed and has no browser host. With `DRGNX_TEST_BROWSER` set, a session
  whose `browser` cell is not Never still gets the hub's side of its browser at its start (the web proxy, and the
  broker with the far end of its socketpair held); `DRGNX_TEST_WEB_REDIRECT=ADDR:PORT` sends every upstream but the
  host's loopback there (the mock LLM stands for the site), and `DRGNX_TEST_PROXY_PINS` pins names for it as for the
  provider proxy.

Rows: `test/conformance/browser/web-*.jsonl`, `browser/private-*.jsonl`.

### A session with the browser

At `prepare`, the session's `browser` cell decides (`agents/session.rs`, `sandbox::browser_for`):

- **Never:** today's spec, no browser.
- **Allow or Ask:** the browser, when the sandbox is bubblewrap's full tier, the kernel's Landlock ABI is at least 9
  and `browser::resolve` finds a program. Ask comes at first use: the broker asks the cell at each websocket upgrade.
  Otherwise (OD1 (b)) the session starts without it: `agents/get` says why in `browser_why`, with the fix, and the hub
  raises one `notice` per reason per hub run (`id` `browser-tier`, `browser-landlock` or `browser-program`).
- **The spec** ([gleipnir.md](gleipnir.md), "Ratatoskr's side"): the relays 3128 → `proxy.sock`, 9222 → `cdp.sock`,
  3130 → `web.sock`; the local ports (`agents-browser-local-ports`) in `extra_tcp_ports`; the program's folder and
  `/var/cache/fontconfig` read-only; `PLAYWRIGHT_MCP_CDP_ENDPOINT` and `DRGNX_BROWSER_CDP` set to
  `ws://127.0.0.1:9222/devtools/browser/SECRET` (a fresh 32-byte secret per session, in hex, in the environment
  only: never in an argv or a log); no display, no runtime dir; `Spec.browser` with `--headless-shell` or `--full`
  and `--max-message N`. An editor's value for either endpoint name is dropped for every session (`module_env`).
- **The launch** makes the browser host's socketpair (`agents::launch::launch_on`): the host's end goes into the
  sandbox, the hub's end to the broker. The status line must say the browser host is layered and ready
  (`gleipnir::inner::read_status_for`). Where a user systemd answers, the sandbox runs in a scope of its own,
  `drgnx-session-SID`, with `MemoryMax` = `agents-session-memory` and `TasksMax=4096` (`exec::unit::session_scope`).
- **Before the spawn** `agents::net::start_browser` starts the web proxy (above) and the CDP broker on `cdp.sock`
  (0600): its gate is the `browser` cell, its limits `agents-browser-max-message` and `agents-browser-idle`.
- **The memory watch** (a scope only): it reads the scope's cgroup once (`systemctl --user show -P ControlGroup`),
  then `memory.current` every second, and stops the browser (`stop("memory")`) each time it rises above
  `agents-browser-memory-high` percent of `agents-session-memory`.
- **At the end** of the agent's process the broker, the web proxy, the provider proxy and the socketpair close (the
  browser host stops Chromium and exits), their sockets go, and the scope ends with its process. A resumed session
  is launched again, with a fresh browser.

## The MCP bridge

An agent speaks MCP over stdio; `ratatoskr mcp-bridge` is that stdio server, and it copies lines to the hub
(`runtime/crates/drgnx-ratatoskr/src/bridge.rs`; the state machine is `mimir::bridge`). Claude Code never respawns a
stdio server that died (anthropics/claude-code#82746), so the bridge outlives the hub instead (design §5.8).

- **Inside: `mcp-bridge --socket PATH`.** PATH is a session's `mcp.sock` (`mcp/session`). It must be a socket when
  the bridge starts (exit 1 otherwise); after that the bridge connects with no challenge and the first byte is MCP.
  The socket is the identity: nothing in the bridge's environment (`DRGNX_AGENT` included) is read.
- **Outside: `mcp-bridge --outside --kind KIND [--cwd DIR]`.** For an agent drgnx did not start. The bridge finds the
  main socket as every client does (its environment's data dir), checks the socket's directory first (the client's
  rule: the user's, 0700; otherwise it ends with exit 1 and the reason on stderr, never connecting), reads
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
itself; nothing is forwarded.

`gateway/register {chain, job?, task?, agent?, budget?, openrouter?, keys?, owner?, sid?}` returns `{token, url?,
socket?, openrouter?}`: a token of 64 hex digits (32 random bytes) and, without `sid`, the loopback URL
`http://127.0.0.1:PORT`; with `sid`, the session's `gateway.sock` (`SDIR/gateway.sock`, 0600, bound once per session
and served until the session closes) instead, for an agent in a sandbox without the host's loopback.

A session `agents/start` makes on a gateway profile is registered by the hub itself (`Gate::register_session`). Its
launch is sandboxed, so the token is registered with the session's `sid`, on its `gateway.sock`: the hub opens the
session's MCP session (which `gateway.sock` needs) before it prepares the launch, and closes it again when the launch
is refused before the spawn. The spec relays a second port, 3129 on the full tier (`sandbox::GATEWAY_PORT`; any free
one on the reduced tier), to that socket and sets `ANTHROPIC_BASE_URL=http://127.0.0.1:PORT` and
`NO_PROXY=127.0.0.1,localhost` (and `no_proxy`), so the agent's requests go to the gateway straight, never through
its provider proxy; the Claude options carry no base URL, so the process's is the one Claude uses. A session on any
other profile gets no gateway relay. A test build's launch is the unsandboxed test one and keeps the loopback URL.

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
  unregistered.
- **Across a restart** the rows are read back (a row that does not read is dropped and logged), owners checked again,
  the sessions' sockets bound again, and the gateway's port too: `runtime.db`'s `kv.gateway_port` is tried first,
  else a free one, and the one used is kept. When the kept port is taken, the hub logs a warning and drops every
  loopback registration at start (the editor's tokens and agents' on 127.0.0.1; a session's `gateway.sock` ones
  stay): their holders still know the old port, so a process squatting it would collect live tokens. Each holder asks
  again: the editor does on its next proven connect and learns the new port.
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
whose spend reaches the budget sends that event as soon as its row is written. The front sends each `budget {job,
spent, budget}` to its subscribers. `spend {job?, task?, agent?}` sums the rows (an agent: its own job's).

## Keys

Provider keys reach the hub from a user connection only: `gateway/keys {keys: {PROVIDER: KEY}}` (an editor hands its
keys over once each subscription is answered, `drgnx-hub-ensure` and so `drgnx hub start` too) and a registration's
`keys`. They are held in Ratatoskr's
memory only (`bifrost::keys::Keys`): never in `runtime.db`, a file, a log, an environment, or a command line; the last key handed over for a provider wins. An empty key is no key: it is skipped, so it never replaces a
held one or marks its provider held (the editor never sends one either). `status` and the doctor name the providers whose key is held
(`keys_held`), never a key. A restarted hub holds no key until an editor connects again; meanwhile a request that
needs one fails over or answers "no key", and the `gateway/need-keys {providers}` event (also sent to each new
subscriber for the providers kept registrations need) tells the editor to hand them over. The hub is not dumpable
([Stopping a hub](#stopping-a-hub)), so another process of the user's cannot read them from its memory.

The registrations, the port and the keys of the Lisp runtime's gateway (`registrations.eld`, `port`) are among what
[`legacy::migrate`](#what-the-lisp-runtime-left) moves aside; nothing reads them.

**The editor's side** (`core/drgnx-hub-client.el`):
- **The runtime settings** (`core/drgnx-settings-runtime.el`). Once a subscription is answered (`drgnx-hub-core--subscribed`),
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
  newer key for the provider replaced it meanwhile) and calls `auth-source-forget-all-cached`. `drgnx-hub-core--transmit` sends
  `gateway/keys` only on a proven connection, so a key goes only to a hub that proved itself. The environment is
  left as it is (`drgnx doctor`'s `ai-env-keys` names the variables set). Only AI: Load Keys keeps a key it reads
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
  editor rotates; another process (a batch job, the `drgnx` CLI) takes its own.
- **Kept across a restart.** It is a `registration` row like an agent's: read back at start, pruned with its owner,
  and good again only while the port is the same (`kv.gateway_port`): a moved port drops it. The editor asks for its
  token again on every proven reconnect, so it learns a new port.

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
  global); an empty list clears it (the project still counts as having sent). A project's set holds only the settings
  the Lisp declares `:scope project` (`overrides::PER_PROJECT`: `drgnx-ai-roles`, `drgnx-search-include`, `drgnx-search-exclude`, `drgnx-search-off`); every other runtime setting is
  global and security-bearing (profiles and their commands, providers and their URLs,
  `drgnx-agents-allow-unsandboxed`), so a project never changes it. A name that is not a runtime setting, a global one
  in a project's set, or a value that does not fit is `invalid-params` at `overrides[N].name` or
  `overrides[N].value[.PATH]`, and nothing changes. Each set is kept as last good in `kv` (`settings-override:global`, `settings-override:<project>`) and read
  again at start, so a hub with no editor connected still has them. In effect, for a setting and a project
  (`Settings::effective(name, project) -> (value, seen)`): the project's override, else the global one, else
  `settings.el`, else the shipped default; `seen` is false when the project never sent a set. The global overrides are
  also what `Settings::current()` (and so the gateway) reads. `config/changed {}` checks `settings.el`'s stamp now.
- **When.** At start, before anything is served, again when the file's stamp (device, inode, size, mtime, mode, owner)
  changed when a session starts (`mcp/session`, and `agents/start` before it looks up the profile), and on
  `config/changed`.
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
  `test/conformance/settings/*.jsonl`: `the-hub-reads-settings-el`,
  `no-editor-still-has-presets-and-profiles`, `a-package-entry-never-stops-the-hub`,
  `a-broken-file-gives-strict-agents-and-last-good-providers`.

## Jobs (`exec/*`)

`drgnx-ratatoskr/src/exec/` (Task 11): `Runner::{start, get, list, stop, log_slice, log_tail}` (`exec/log`'s slice
reads lines only up to the last it answers; its `tail_bytes` form seeks to the file's end; both replace bytes that are
not UTF-8). A job's folder
`<state>/hub/exec/<id>/` holds `meta.json`, `log`, `exit` (written by the wrapper shell through a rename), `why`
(`stopped` or `timed-out`, written before the hub kills the group) and, once ended, `result.json`; a folder without
`result.json` is running. A session's job is launched with `launch::launch` (its sandbox spec) and the status pipe is
read with `gleipnir::read_status`; the user's runs with the user's rights. The command is wrapped by a shell that logs
and records the exit, and (Linux with a user systemd) by `systemd-run --user --scope -p MemoryMax=…`, a scope so the
command stays the hub's child. `Runner::open` re-attaches every folder without a result. Every job but the editor's
servers (a user's `no_timebox` job, up for days, started at once) goes through the queue ("Runners: the queue"), whose
local runner admits it here (`Hooks::admission`). `exec/get`, `exec/log` and
`exec/stop` answer an agent caller (`Class::Agent`, the job tools through `Coord::exec`) only for its own session's
jobs (`exec::visible`: "not yours", `not-allowed`); the norn tools refuse the same (row
`exec/an-agent-cannot-read-another-callers-job`). The graph record is
`norn::write::exec`. The `exec/runs-in-the-starters-sandbox` row (`exec::tests::exec_runs_in_the_starters_sandbox`) is
`#[ignore]`d where bwrap is missing (build containers): run it on a host with bwrap or in CI with `-- --ignored`. So are
the `launch-sandboxed/*` rows (`tests/launch_sandboxed.rs`, a session's launch spec run in a real sandbox): a
container has no user namespaces for bwrap, so CI runs them in `escape-host`'s sandbox lane; the rows of the reduced
tier run on it where the kernel has Landlock ABI 9 and on the full tier elsewhere (no runner has ABI 9 yet).

The editor's own jobs are the user's `exec/start` with four more fields (`StartParams`: `name`, `env`, `memory_max`,
`nice`; `StartParams::user_only_field` names the first one a request sets). `exec::start` refuses them from a session
(`user_job`: `invalid-params`), `env` and `memory_max` from a container job, and `memory_max` on macOS; the decode check
(`check_start`) refuses a malformed size, a `nice` outside 0 to 19 and a key-like variable name
(`runstav::methods::hub::refused_env_name`, `env/set`'s check), and `exec::start` a provider's `key_env`. The job's base
environment is the hub's whole environment with `env/set`'s overlay (`ShellEnv::vars_os`) less every key-like name and
every provider's `key_env` (`user_env`; `Hooks::key_envs` reads the providers from the settings at each start); a
session's job run unsandboxed (the conformance lane) keeps a short list (`agent_plain_env`), and a sandboxed one the
tool paths (`tool_env`). `unit::wrap` hands the spec's environment to `systemd-run --scope` (the scope's command gets
the caller's environment) or to the plain shell (macOS, no user systemd). They travel in `ExecSpec.user` (`UserJob`, also in a queued job's
`Pending`, kept in `rq_job`); the name is in `meta.json` and on the `ExecRow`. The unit takes `memory_max` as its `MemoryMax=`;
`nice` is `nice -n N` in front of the command inside the logging shell (a scope takes no `Nice=`), the same line with
and without a unit, and the form BSD's `nice` (macOS) takes too.

A fifth user-only field, `no_timebox: true`, runs the job with no time box (the editor's servers stay up for days, and
`timebox_s` stops at 86400): `user_only_field` names it for a session (refused like the others), `check_start` refuses it
together with `timebox_s` (`invalid-params`, path `no_timebox`), and a missing `timebox_s` still means 3600. The flag is
`UserJob.no_timebox`; `ExecSpec::time_box` is then none, `meta.json` has no `timebox_s` and no `deadline` (both
optional; an older file with numbers reads as before), the `ExecRow` has no `timebox_s`, and `watch` has no timer arm
(`Meta::time_left` is none), so only the process's end, `exec/stop` or the hub's stop ends the job. The graph row records
a time box of 0. The editor side is `core/drgnx-exec.el` (a cache fed by `exec/list` and `exec-done`; see
`docs/guide/jobs.md`, "The editor's jobs").

## Runners: the transport

`drgnx-ratatoskr/src/runners/` reaches the user's other machines (runners) over the user's own OpenSSH
(`docs/guide/runners.md`, "How drgnx reaches your machines"). A runner is a `RunnerCfg {name, host, linger, cloud,
remote}`: the registry's name (letters, digits, `_`, `-`, at most 32 bytes), the host as the user's ssh knows it, a
cloud machine's agent, certificate and pinned host key (`CloudSsh`), and the argv of its three sessions (`Remote`).
`RunnerCfg::check` refuses a host or name that would read as an ssh option or holds a space, a path in the config
that ssh would expand (`%`) or that would break its line, and an empty argv; `grace()` is an attempt's grace there
(600 s with linger, 0 without).

**The generated config** (`ssh_config.rs`). `render` writes the forced options first, because ssh keeps the first value
it reads for an option: `ForwardAgent no`, `ForwardX11 no`, `ClearAllForwardings yes`, `PermitLocalCommand no`,
`BatchMode yes`, `StrictHostKeyChecking yes`, `UpdateHostKeys no`, `ServerAliveInterval 15`, `ServerAliveCountMax 4`,
`Compression yes`, `ControlPersist 10m`, `RemoteCommand none` and `RequestTTY no` (`FORCED`). A cloud runner adds
`IdentityAgent`, `CertificateFile`, `IdentitiesOnly yes` and `UserKnownHostsFile` (paths quoted) and reads no user
config; an SSH runner ends with `Include ~/.ssh/config`, so its host name, user, port, keys and `ProxyJump` /
`ProxyCommand` stay the user's. `write` puts it at `$XDG_RUNTIME_DIR/drgnx-runners/<name>/ssh_config`, mode 0600, its
folders 0700 (made, or narrowed), replaced in one rename; a runner folder that is a link or someone else's is refused.
ssh expands `~` from the password database, not `$HOME`, so a test's `Include` reaches its own home only in a
container.

**The transport** (`transport.rs`). `trait Transport` (methods return `BoxFuture`, so a link can hold a `dyn
Transport`):

- `open(r) -> Channels`: R's master (the one it has if its socket answers, else one a previous hub left in the runner's
  folder, resumed with `Session::resume_mux`, else a new one through `connect_mux`), then `true` on it, so a dead link
  or a login banner shows before any session of ours starts, then three sessions: control, bulk in, bulk out. Each
  `Channel` has `tx`, `rx` and `err`; `Channel::new(tx, rx)` makes one over any pipe, for a link's tests. At most
  `SESSIONS` (3) per runner, kept by a semaphore: a second `open` while they are open is refused.
- `round_trip(r) -> Duration`, within `ROUND_TRIP_DEADLINE` (60 s, the keep-alive's 15 s × 4): `true` while a session
  is free, else the next bytes on the control channel (both ends ping every 10 s), so the check never needs a fourth
  session. `-O check` only asks the master's local socket, which still answers after its link died: it is
  `OpensshTransport::check_master`, never health.
- `replace_master(r)` stops the master listening (the crate's `close`, which is `-O stop`) and dials a new one;
  sessions on the old master finish or end through the keep-alive. `stop(r)` stops it the same way and forgets R.
  **The hub never sends `-O exit`**, and dropping an `OpensshTransport` detaches its masters, which stay up for
  `ControlPersist 10m` so the next hub resumes them. Sessions are opened from a handle that owns nothing (dropping it
  never touches the master); one owner per master stops or detaches it.

`OpensshTransport` and `effective` are `cfg(all(unix, not(target_os = "android")))`: the `openssh` crate (native mux
only, no process mux) with `config_file`, `KnownHosts::Strict` and `ControlPersist::IdleFor(600)` on the master's
command line too (the crate's defaults, `accept-new` and `yes`, would win over the file there), the control folder in
the runner's folder. `LinkError {Lost, NeedsLogin(Login), HostKeyChanged, Refused(String)}` is never a job's result.
`classify_stderr` reads ssh's error output: Tailscale's "requires an additional check" (its URL kept for the card,
never opened), a passphrase, a host key not known yet (`Login`), a changed host key (`HostKeyChanged`, never
accepted); `link_error` makes the machine down or out of reach `Lost` and the rest `Refused` in ssh's words.
`Redial::delay(n)` is 5, 15, 45, then 120 s. `effective(config, host)` runs `ssh -G -F <generated> host` and reads
`forwardagent`, the forwards and the proxy (`Effective`), for the onboarding probe and the runner list.

Tests: unit rows `runners::` [D]; the fleet rows `tests/fleet_link.rs` [C] (`#[ignore = "fleet"]`) run in a fleet's
harness against real sshd (its header has the commands). The target builds only with `--features fleet`, so the
escape lane's `--ignored` run never picks it up. They need sshd set two ways, through
`DRGNX_FLEET_RUNNER_OPTS` mounting `test/runners/link/*.conf` as `05-link.conf` (read before the image's
`10-fleet.conf`): agent forwarding allowed with `--max-sessions 3`, and a `ForceCommand` that prints Tailscale's
banner. Each row first shows the user's own ssh doing what the hub must not (forwarding the agent, running the user's
`RemoteCommand` on a terminal and their `LocalCommand`, opening their `LocalForward`). The dead-link row stops the
runner's sshd for the master's connection (`kill -STOP` over a second connection), which a network cut would do too.

## Runners: attempts

Every placement of a job on a runner is an **attempt** with a nonce the hub made (`sleipnir::proto::JobRef {job,
attempt, nonce}`), and every frame about it carries all three.

**The attempt state machine** (`runners/attempts.rs`) is pure: `Core::step(now, Event) -> Vec<Effect>`, no I/O and no
clock, so `tests/runners_orders.rs` runs it in every order of what can happen to an attempt. Events: `Placed {job,
attempt, nonce, runner, grace_s, restartable}`, `Started`, `Finished {runner, r, result}`, `FrameFrom {runner, r}`,
`Refused {runner, r}` (an offer the runner refused: back to the queue, never lost), `LinkLost {runner}`, `Hello
{runner, listed}`, `GraceEnded {job, attempt}`, `CloudGone {runner}`, `Preempting {runner}`, `HubRestarted`, `Cancel
{job}`. Effects: `Verdict {job, attempt, result}`, `Requeue {job, reason}`, `Lost
{job}`, `Ignore {notice}`, `ResumeLog {job, attempt, offset}` (send `attach`), `KeepLate {job, attempt}` and
`SendCancel {runner, r}`. States: `offered`, `running`, `detached {since, grace_until}`, `finished`, `requeued`,
`lost`.

- A frame counts only from the runner the attempt was placed on and with its nonce (`frame_ok`); anything else is an
  `Ignore` with a notice and changes nothing.
- **`detached`** is exactly the design's (§6.9): no verdict, and the runner's control link is down (`LinkLost`), or the
  hub restarted (`HubRestarted`) and the runner's `hello` hasn't listed it yet. It is a state, never a verdict. It ends
  `running` when the `hello` lists it running or finished (the log resumes from the hub's offset, and a finished one
  then sends its `finished`); requeued (`infra: runner lost`) when the `hello` doesn't list it or lists it lost, when
  the grace ends (`graces_due(now)`, read at each tick), or when the cloud says the machine is gone; `lost` instead
  when the job isn't restartable.
- **The grace** is the runner's, `RunnerCfg::grace()`, passed in at `Placed`: 600 s with linger, 0 without, where a lost
  link ends the attempt at once (the runner's jobs die with the login).
- **Only `finished` gives a verdict.** A preemption requeues at once (`infra: preempted`), never a verdict and never an
  eviction. A cancel sends `cancel` to a running attempt and waits for its `finished`; an attempt whose runner can't be
  told (offered, detached) ends `cancelled` at once, and its runner is told when it lists the attempt again.
- **Late results** (L8): an attempt whose job was requeued that still finishes is `KeepLate`: its log, patch, outputs
  and rows are kept as that attempt's, never applied, and never replace the current attempt's verdict.
- `restore` puts the database's attempts back after a restart, before `HubRestarted` detaches the open ones; `forget`
  drops a job once its verdict is recorded and no late attempt is open.

**The link session** (`runners/link.rs`). `Session::start(runner, Channels, route, events)` reads and writes the control
channel with the protocol's codec (a frame's line, then the chunk its `len` announces), pings every 10 s
(`PING_EVERY`), answers the runner's pings, and reports the link lost (`LinkEvent::Lost`) after 45 s without a frame
(`LOST_AFTER`), at an EOF without `bye`, or at a channel error; a `bye` is `LinkEvent::Bye`. A `log` frame is appended
to the file `Route::log_path(runner, r)` names, only for an attempt the route accepts (placed there, with its nonce),
through `append_at(path, offset, bytes)`: only the bytes the hub's copy lacks, so a chunk sent again after a
reconnect is never doubled and a gap is refused; `LinkEvent::Logged {r, upto}` says where the copy ends, which the
next `attach` sends as its `log_offset`. Every other frame is a `LinkEvent::Frame`. A `key` frame's encoded bytes are
zeroed once written. Dropping the session ends it; the runner's attempts run on.

Tests: `runners::attempts::` and `runners::link::` [D]; `tests/runners_orders.rs` [A] (every order of a lost link, a
reattaching and a non-listing `hello`, a restart, the grace, a preemption and a wrong nonce around a `finished`,
exhaustively, then 2000 drawn orders with a cancel); `tests/fleet_runners.rs` [C] (`#[ignore = "fleet"]`, its header
has the commands; like `fleet_link` it builds only with `--features fleet`, out of the escape lane's `--ignored`): a
job's log cut mid-stream and reattached equals the runner's file byte for byte.

## Runners: the queue

One queue holds every job but the user's servers (`runners/queue.rs`), for this machine and the runners alike. The
job layer (`exec/`) records a job's folder and meta as before, then `Queue::submit`s it: its forseti `JobSpec`, its
`Placement {machine (auto | local | runner), heavy, keys, local_only, background, writes, priority, send, machines_cell,
image, weight, visibility, shared_overlay}`, its frozen inputs (below) and what to start it from (`Pending`). `exec/start` lost `check_machine` and the agents' semaphore:
`machine` names `auto` (the default), `local` or a runner the queue knows (else `invalid-params`); `priority` (1–5) is
honoured on the user's connections only (a session's is `invalid-params`); `job_start` takes `JobStartParams`,
`exec/start`'s fields without `priority`, so an agent's request that names one is refused as an unknown field.
`exec/bump {id}` (classes `[User]`) sets a queued job's priority to 1. `ExecRow` gained `machine`, `attempt`,
`waiting` and `priority`.

**Priority** (`priority_of(starter, background, from: Origin)`, design §6.8.1): 1 for the user's request, 2 for the
splitter's (`Origin::Splitter`), 3 for an agent's `job_start`, 4 for a plan's or gate's bulk (`Origin::Bulk`), 5 for
`background` and the hub's upkeep (`Origin::Upkeep`); `background` only lowers.

**A tick** (`Queue::tick(now)`, every 2 s on the hub's clock, at every start and on every link event): the detached
attempts whose grace ended; then the queued jobs in `forseti`'s order (`effective_priorities`, `queue_order`, then
`Drr::order` by project, weighted by `drgnx-runners-weight`); each placed by `forseti::pick` over this machine and every
runner (trust, pin, features, state, the project's send mode, the `machines` cell). `Pick::Local` asks the local
runner's admission: admitted, the job starts (`Ticked.starts`; the job layer holds a `Slot` until it ends, and dropping
it frees the room); refused, the pick is made again without this machine, so the job may still go to a runner.
`Pick::Runner` offers it there (a new attempt, a random nonce, `Placed` into the attempt state machine, an `offer`
frame); `Pick::Wait` writes the reason's words (`wait_text`) on the job's row. A runner's `admit` is answered with
`start`; a `refuse` puts the job back with the runner's reason; `finished`, a lost link, a `hello` and a preemption go
through the attempt state machine, whose verdicts, losses and late results become `Outcome`s: the job layer writes the
verdict as the job's `exit` (or `why`) and ends it as a job here ends. The session's `Route` writes a runner's log
frames to `<id>/log` for the current attempt and `<id>/log.<n>` for a late one; a requeue moves the log aside as
`log.<n>`.

**The local runner** (`runners/local.rs`, Calls 6 and 7): `Admission::Live` on Linux, `forseti::admit` over
`sleipnir::linux::probe` under the `workstation` profile, with a reservation per admitted job in the reservation
protocol (scheduler `drgnx-hub`, under the admission lock, removed when it ends); `Admission::Fixed(n)` admits by count,
a macOS hub's `Limits::fixed_slots(4)`, and what a probe that can't read the machine falls back to (one warning). The
user's servers (`no_timebox`) bypass the queue and count in the memory the probe reads. Tests and `test-hooks` builds
admit by count (4; `DRGNX_TEST_JOB_SLOTS=N`), so no row depends on the machine it runs on.

**`runtime.db`** (migration 9): `rq_job` (the spec column holds the forseti spec, the placement, the session and the
`Pending`), `rq_attempt`, `rq_offer`, `rq_admission`, `rq_detached` (an attempt's grace while it is detached),
`rq_input`, `rq_history` and `rq_rows` (§7.4's columns; `rq_input.commit_sha` is §7.4's `commit`). The queue writes
them in order on a task of its own (`Queue::flush` waits for what is queued); a restart reads them back
(`queue::stored`, `Queue::restore`): queued jobs wait again, jobs on runners keep their attempts, detached until the
runner's `hello` lists them, and jobs running here are adopted by the job layer, holding their room. A queued
`pending.json` an older hub left is read into `rq_job` once, and the file removed.

Tests: `runners::queue::`, `runners::local::`, `runtime_db::`, `exec::tests::a_queued_pending_json_is_read_once` [D];
`test/conformance/runners/*.jsonl` [B]; `tests/fleet_runners.rs` `queue::` [C] (a heavy job goes to the runner under
`send heavy` while the light one waits here).

## Runners: sync and job trust

`runners/sync.rs` (design §6.2, §6.6). **Inputs are frozen at submit**: when the queue knows a runner and the job may
leave this machine (`Placement::may_leave`), `submit_of` calls `sync::freeze(tree, extras, visibility, shared_overlay,
store)`: sleipnir's `capture` (the commit, its tree, the overlay against it, the input key), the origin's URL and the
commits its `refs/remotes/origin/*` reach, how many commits of the job's are on none of them (`not_on`), and each
overlay file's bytes copied into the hub's blob store (`<state>/runner-store/blobs/<sha256>`, sleipnir's `Store`). A file
that changes while it is read refuses the freeze; a worktree that can't be frozen (not git, a submodule's change)
makes the job `local_only`, logged. The frozen inputs (`Frozen`) go in the `rq_job` spec as `inputs`, and `rq_input`
gets the manifest by input key (`rq_job.input_key`). No new migration: both came with runtime.db 9.

**Job trust** (`job_trust(visibility, not_on_origin, keys)`): `private+keys` when the job names keys, `public` when
`drgnx-runners-project-visibility` is `public` and every commit is on the origin, `private` otherwise. Placement gets
`commits_not_on_origin` for a public project, so `forseti::why_here` says "runs here: N commits not on origin".

**The overlay** (`overlay_for(job, runner trust)`): the lock's protected files (`agents::lock::PROTECTED_RO`) are left
out for every runner: worktrees carry stub `.envrc` and `mise.toml` routinely, and the runner gets their committed
versions. A shared runner gets an overlay only with `drgnx-runners-shared-overlay` on and every file passing
`runstav::secrets::looks_like_secret`; otherwise the queue keeps the job off shared runners and says why
(`QJob::shared_why`).

**The sync** (`Queue::sync_have`, `sync_need`): an `admit` of an attempt with inputs is answered with `sync-have`
(the repository's mirror id, `repo_id`; the commit, the tree, the overlay for that runner's trust) instead of `start`.
The runner's `sync-need` gets, for the commit, `sync::plan(job, trust, missing, origin key)`:

| Case | What the hub does |
|---|---|
| public, the commit on the origin, any runner | `origin-fetch` with the origin's URL |
| a private origin, a deploy key named, the commit on it (`mine`, `my-cloud`) | the key in a `key` frame (recorded as `key_sent`), then `origin-fetch` naming it (`cred`); the key is `drgnx-runners-origin-key`, taken only while the hub holds it (else asked for, and the commit goes another way) |
| over 8 MiB missing (`missing_bytes`: `rev-list --objects --disk-usage` past the runner's ref tips) | one bundle (`make_bundle`: a temporary bare repository borrowing the objects, `refs/hub/job`, the runner's tips left out), in 1 MiB chunks |
| a small gap | a push; for now a bundle too |
| a shared runner and anything not on the public origin | never: the attempt is cancelled with the reason |

then the blobs it lacks (only those of its own overlay, `send_blob` in 1 MiB chunks), and asks again; an empty answer
starts the attempt. Past 6 rounds, or when a step fails, the attempt is cancelled with why logged (`give_up`). A
verdict, requeue or loss drops the attempt's sync and its bundle file.

Tests: `runners::sync::` [D] (trust from visibility and reachability; the four cases; no lock file in any overlay; a
bundle sent in chunks from an offset); `tests/fleet_sync.rs` [C] (one unpushed commit keeps a public job off the
shared runner; the shared runner fetches from origin; the shared overlay off by default, and scanned when on).

## Runners: keys

`runners/keys.rs` and `runners/redact.rs` (design §6.3, §6.6; the user's side is docs/guide/runners.md, "Keys").

**Naming a key.** `exec/start`'s `keys` (names) must each be on the project's `drgnx-runners-job-keys`
(`keys::on_the_project_list`, else invalid-params naming the key and the setting); a session's start also passes the
matrix's `job.keys` (`gate_session_job`; Cautious and Balanced ask, Autonomous allows the manager and workers, chat
never). The names go to `Placement::keys` and the spec; the job is `private+keys`. A keyed job has no local candidate
in `Queue::place` (it waits for a runner, saying so): a keyed job on this machine is not wired yet.

**The handover.** `runners/keys {keys: {NAME: value}}` (user only; refused while `Gate::protects_keys` fails, as
`gateway/keys` is) puts the values in `Keys` (`SecretString`s in memory; `RunnerKeys` refuses a NUL, an over-64-KiB
value and more than 32 keys, naming the key, never the value). `runners/keys-held` answers the names. When an attempt
needs a key the hub doesn't hold, `runners/need-keys {names}` goes to the user's connections; nothing answers it but a
command the user runs.

**Sending.** On a keyed attempt's `started` (never before), `Queue::send_keys` sends each held key it hasn't sent yet in
its own `key` frame, only where `keys::trust_ok` (never `shared`; `my-cloud` only its list, empty until cloud runners
come); each is a `key_sent` row. Keys taken later go to the started attempts still missing them. A `key-use` frame
from an attempt the hub placed there becomes a `key_use` row, `runner_reported: true`. Rows go to memory (the last
10 000) and to the graph (norn kind `key_sent` / `key_use`, written as `("hub", System)`); `runners/audit {job?, key?}`
reads the graph, or memory when the graph can't be read.

**Redaction.** `QRoute::write_log` (the link's `Route` hook for `log` frames) runs a keyed attempt's chunks through its
`Redactor` before they reach the hub's copy: every value sent masked in its raw, base64 (both alphabets, padded or not)
and percent forms, at its own length, so the copy keeps the runner's offsets; the end of a chunk that could begin a
form is held back until the next one (`Redacting::consumed` is the runner's offset taken in). A redactor exists from
`start`; a key is added to it before its frame goes. After a hub restart a keyed attempt's log isn't taken in until all
its keys are held again (`runners/keys`), then it is attached from the copy's end; its runner's `hello` that lists it
asks for the missing ones (`runners/need-keys`). At `finished` the held tail is
written and `redact::notices` (the `looks_like_secret` heuristic) sends one `notice` per log that may hold some other
secret, never masking it.

Tests: `runners::keys::` and `runners::redact::` [D]; `runners/keys-never-in-the-log-or-any-reply` [B] (conformance);
`tests/fleet_keys.rs` [C] (one frame and one `key_sent` per key and one `key_use` per read, no key bytes on the runner;
the returned log redacted; a shared runner never gets a key; a key that never arrives is infra; `podman inspect` names
only and `memory.swap.max` 0).

## Runners: returned data

`runners/returned.rs` (design §6.3; the user's side is docs/guide/runners.md, "What comes back"): what a runner
returns is checked before it reaches anyone. Runners return only the log and `result.json` today, so the checks below
wait for their callers (reports, outputs, `changes.patch`, `exec/fetch`); the `shared` rules are wired.

- `path_ok(rel)`: relative and normalised (`.` and empty segments dropped), refused for `..`, an absolute name, a NUL
  or nothing left. `never_returned(path)`: a `target` component, a build tree (`CMakeFiles`, `CMakeCache.txt`,
  `build.ninja`, `.ninja_log`, `.ninja_deps`, `config.status`) or an image (`oci-layout`; `.oci`, `.qcow2`, `.vmdk`,
  `.vdi`, `.iso`, `.img`), by name, whatever a job declared.
- `write(job_dir_fd, rel, bytes)`: both checks, then each folder on the way opened with `eitri::open_beneath` (a link
  is refused) or made with `mkdirat` beneath the last one, then `eitri::write_regular` (0644; a link at the name is
  replaced, never followed).
- `archive_ok(tar)`: ustar (checksums checked; a ustar prefix, a GNU long name and a pax `path` taken; a global pax
  `path` refused) holding only regular files and folders, every name through both checks; a link, device, FIFO,
  any other type, a truncated entry or a missing end is refused.
- `Patch::parse(from, bytes)` reads `git diff --full-index --binary` output: per file the paths before and after
  (none: created or deleted), the modes and the blob before. A quoted path, a copy, a binary change without its data,
  text before the first `diff --git` or an unknown header line can't be read: the patch is kept. `patch_ok(patch, spec,
  attempt, submit, runner_trust)` lists every reason not to apply it: a path outside `spec.writes` (`*`/`?` within a
  segment, `**` any segments, `dir/` the folder), a protected name (`PROTECTED`) or `.git` at any depth, a bad path,
  a symlink or submodule mode, a changed mode or a new executable file, a blob before that isn't the file's `submit`
  hash (or a created file that had one), another job, attempt number or nonce than `attempt`, a `shared` runner, more
  than `PATCH_MAX`. A refused patch is kept with `review_card(runner, n)`.
- **`shared`:** `Queue::apply` gives `Outcome::Done` the runner's name when its trust is `shared`; the job layer writes
  it to the job's `shared` file, `finish` starts the summary with `shared_label` ("output from runner NAME (shared)"),
  so `exec-done` and the starter's wake carry it, and `Runner::counts_for_gates(id)` is false for it
  (`counts_for_gates(trust)`): what a gate or `needs` reads once the hub has one.

Tests: `runners::returned::` [D] (the returned-data rules: paths, archive links, a planted link, writes globs, protected files and
`.git`, exec bits, an old attempt, `shared`, `target/`); `exec::tests::a_shared_runners_result_is_labelled_and_never_counts_for_a_gate` [D].

## Runners: health

`runners/health.rs` (design §6.9). `is_strike(verdict, StrikeCtx {link_lost_today, link_stayed_up})` is the strike
table: `infra: setup`, `sync`, `image`, `disk`, `killed` and `health check` always; `runner lost` the second time in a day
(`Strikes::lost_link`); `key not delivered` only on a link that stayed up; nothing else (reds, crashes, `oom`, `oomd/killed`,
timeouts, `preempted`, evictions, cancels). `Strikes` keeps a runner's strikes since its last passing check: `record(now,
verdict, ctx)` (a job that ran ends a run of strikes, a non-strike infra end doesn't), `strike(now, reason)`; two in a row
or two within 3600 s (`BENCH_WINDOW_S`) bench it; `clear` (a pass, the user's `unbench`), `text` for the runner list
(`benched: REASON (HH:MM, HH:MM)`, UTC).

The queue counts a strike at each runner verdict (`Queue::strike_of`) and at a link lost with attempts open, and holds a
benched runner as `RunnerState::Benched`, which `forseti`'s filter keeps every job off; its `hello` doesn't put it back.
**The check** runs every 300 s per runner (`CHECK_EVERY_S`; `Queue::check_now` makes it due), on a ready or benched one:
a `probe` frame (its `probe-result`: the contract's missing items, `check_limits`, the free disk), a canary attempt
offered straight to the runner (job `health<runner><at>`, letters and digits as a runner takes a job id, `true` in
`RemoteRunner.image`, priority 1, no grace;
offered again 2 s after a refusal; its verdict never reaches the job layer), and the runner's clock from its last `ping`
(`LinkEvent::Clock`, the runner's `at` against the hub's time). `judge(Facts)` passes only when all hold: the probe
answered with nothing missing and no `check_limits` failure, 20 GB free (and 10 % where the size is known), the canary
`Pass`, the clock within 2 s (`CLOCK_SKEW_S`); else it names every part that failed. It judges once every answer is in,
or after 120 s (`CHECK_WAIT_S`) with what it has. A pass clears the strikes and returns a benched runner to rotation; a
failure is a strike (`health check: …`). `Queue::runner(name)` gives the row (`state`, `strikes`, `last`) and
`Queue::unbench(name)` is the user's override (the `runners/unbench` method is the registry's).

Tests: `runners::health::` [D] (the strike table, two in an hour, the check's parts); `tests/fleet_runners.rs` `health::`
[C]: two jobs a runner can't start bench it and the next job runs here; a passing check returns a benched runner with no
strikes; a hub clock 5 s off the runner's fails the check, saying so.

## Runners: the registry

`runners/registry.rs`, `runners/methods.rs`, `runner_cli.rs` (design §6.10, §7.2). A runner is a `Record` (name, host,
trust, profile, accept, root, prefix, the bundle's folder, the probe's facts, speed, image) and a link in the queue.
Records are entities of kind `runner` in the graph (`norn::write::runners`, id `runner:<name>`); only
`("hub", Class::System)` writes them (also kinds `cloud_spend`, `key_sent`, `key_use`, which later tasks fill), and the
graph's own door is shut to every other class (`write::runners::an_agent_write_of_runner_is_refused`). `Store` is the
seam: `UrdrStore` in the hub, `MemStore` in tests.

`Registry::add(host, trust, …)`, in order, each step a `sh -c` on the runner over the user's own ssh (the generated
config, no terminal): `uname -m`, `uname -s` and `$HOME` (not Linux: refused); the bundle for that architecture from
`DRGNX_RUNNER_BUNDLES` (default `runtime/target/bundle` beside the hub's build folder, where `drgnx build runner-bundle`
puts `<arch>/sleipnir`, `drgnx-key`, `drgnx-fwd`) copied to `<root>/bin/<hash>/` (written as `.part`, hash checked, moved
into place; refused with the build command when there is none); `sleipnir serve` asked for `hello-ok` and `probe` over
one set of sessions that end after. A `boot_id` equal to the hub's is refused (`this is the hub's own machine; it
already runs jobs as `local``), then anything the contract finds missing (`Probe`'s missing items and `check_limits`)
is refused with all of it, each with its fix. Then `podman pull --policy=missing` of each image in
`drgnx-runners-image` (it must be pinned by digest), `sleipnir bench` in the first, the record, and the link:
`Session::start` over the queue's route and events, `Queue::add_runner`. A root must be absolute, plain, and never the
home or a top-level folder. `remove` refuses while a job is on the runner (`Queue::remove_runner`), stops our containers
(label `drgnx.runner=<hub>` and our prefix), units (`<prefix>*`) and slices (`drgnx-runner*`), then deletes the root.

`check` links a runner whose link is gone again (`Registry::connect`: the old session ended with `Session::close`, so the
transport's three sessions are free) and makes its health check due; `set` changes trust and accept at once, a new
profile starts `serve` again; `unbench` is `Queue::unbench`; `bench` ends the link, runs the bench, links again. At the
hub's start every record is linked in the background (`runners::methods::start`); one that can't be reached stays
recorded and shows `not connected`. **Nothing redials a lost link by itself yet**: `runners/check` does it.

`runners/list` and the others are the user's alone (`runstav::methods::runners`); each change sends `runners-changed`
with the whole list and gives the runner names to the machine registry (`work::machines::set_runners`), which lists them
after `local`. The CLI (`ratatoskr runner …`, `drgnx runner …`) prints the list in plain text of at most 60 columns:
per runner, its state dot, name, trust, profile and accept; its cores, memory, jobs, free disk and last check; and, out
of rotation, its reason on a line of its own. `runner remove` without `--yes` only says what it would do.

Tests: `norn::write::runners::` [D]; `runners::registry::` and `runner_cli::` [D]; `work::machines::` [D]; conformance
`runners/methods-are-user-only` [B]; `tests/fleet_registry.rs` [C]: add (probe, copy, pull, bench, link), the contract's
refusal with its list, the hub's own machine, a removal that leaves nothing of ours.

## The timeline

Every step of an agent's work is a row of the `step` table (`norn::write::steps`), written when it closes by the
session's step writer (`agents/session.rs`) and announced as `agent-step`. The classifier sees the updates as they
arrive: text between tool calls is `think`; a tool call is `tool` from `in_progress` to `completed`; a permission
request is `user-wait` (the hub answers it, so it is the user's time, not the tool's); a paused session is `paused`.
`job-wait`, `machine-queue` and `stalled` are written by the tasks that own those events (exec, the supervisor).
A step's `provider` is the profile's gateway provider environment (`:ai`) when it has one, else whose CLI it starts
(`claude`, `codex`, `gemini`), so a subscription session's steps say where they ran (the matrix's `(:provider NAME)`
column still matches `:ai` only).

Anchors of a step (part 4's rewind): `message_id` (the last message id seen, so tool calls carry their turn's
message), `turn_id` (it arrives with the turn's last step; the turn's earlier rows get it then), `log_version` (the
decision log's version when the step closed) and `snapshot`.

A **step snapshot** is a tree of the session's worktree, written at the first step of each turn and after each completed edit (`edit`, `delete`, `move`
tool kinds) into a shadow repository `<state>/hub/checkpoints/<hash>.git` and kept as `refs/drgnx/s/<sid>/<seq>`. Each
session has its own persistent index file in the shadow repository, so a snapshot only hashes what changed. The
sandbox's secret file names (`.env`, `.npmrc`, `credentials*`, keys, …) are never in a tree. Over
`drgnx-agents-checkpoint-cap` (summed over the shadow repositories), the refs of finished sessions go oldest first and
the repositories are collected (`git gc --prune=now`); with nothing finished left, snapshots stop and the editors get
one `notice` (a running task's refs are never removed). Restore and fork are part 4's.

`timeline/get {scope, id, since?, rollup?}` answers the steps of a session, task, plan or project (500 a page, `next`
continues) and their rollup: seconds by class (closed steps), cost by unit (never summed across units) and tokens.

A step's `cost` is what the budget booked from the agent's cost readings (ACP's `usage_update`) during the turn the
step closes, on the turn's last step, with the unit `usd-est`: an estimate, since a subscription agent reports an
API-equivalent price. Both the step and the budget book the same delta, keyed by the agent's conversation, so a new
conversation (a rotation, a fresh start, a rewind or fork) counts from its first reading in both and `budget/get`
never disagrees with the steps. An agent that reports no cost leaves `cost` empty (never `0`). The rollup of a task
or plan adds a `usd` line with what the gateway charged (the `spend` table), next to the estimate. A plan scope is
`plan:<id>` for a graph plan, `plan:<path>` for a plan file and `plan:<job>` for a job with none; steps and budget of
a job use the same key. Rows written before this keep their old key.

**Forecast samples.** Every task that finished (`done` or `dropped`) and ran a turn becomes one `forecast_sample` row
(`forecast.rs`, `norn::forecast::sample`), and so does a finished job's manager (`JOB#manager`). The sweep runs once
at hub start, which backfills the history of earlier runs, and at the end of each runner tick; it takes what is due in
pages of 100. A task is due when every step of it has closed and no sample covers its newest step, so a restart, a
second sweep and a task reopened after review are all the same query and leave one row per task. Because it runs
every tick, the query reads no whole table of the graph: a finished job's manager sessions are found through the
partial expression index `entity_manager_job` (work.db migration 11: live sessions whose `data.role` is `manager`, by
`data.job`), compared as `+j.id` so the index is searched, and their steps through `step_session`. Every step with the
task counts, whichever session wrote it (a fallback, a move, a reviewer) and whatever a rewind marked: spent is spent.
A session with no task (a chat, a fork) makes no sample. The row's profile and provider are those of the last session
that is no review: the runner marks a task's reviewer session (`review` in its record), whose steps count on the task
but whose profile is not the task's class (else the next proposal would find the worker's class empty and fall to
the role). Its model comes
from the profile's setting, a wake is a job wait and a cold one is longer than the cache TTL (assumed 300 s).

## The CDP broker

A session with the browser drives a Chromium inside its own sandbox over CDP. The hub is the broker between the
agent's websocket and the browser's pipe. Its routing is the crate `heimdall`: pure, with no I/O and no async runtime,
std and serde only, built for every target (Android included). The hub's websocket server and the browser host wrap
it.

**Envelopes** (`heimdall::envelope`). `parse(msg, max)` reads `id`, `method` and `sessionId`, and for `Target.*` the
`targetId` and `sessionId` params. `params`, `result` and `error` stay `serde_json` `RawValue`s borrowed from the
message, so a 20 MiB screenshot passes byte for byte and is never re-encoded. The parse is strict, so the broker and
Chromium never read one message two ways:
- one JSON object (serde would read an array as a struct);
- a key the broker reads appears once;
- the strings it routes by are plain (an escape is an error, not decoded);
- `id` is a whole number;
- a message has a method or a reply, not both;
- over `max` (`agents-browser-max-message`) is `TooLarge`.

The router itself takes no limit: the pipe's codec and the websocket enforce it before a message reaches the router.
What the router sends is rebuilt from what it parsed, so only `id`, `method`, `sessionId` and `params` reach the
browser, and a key CDP does not have is dropped.

**Routing** (`heimdall::route::Router`). One router per browser start. `Router::new()` returns the hub's first command,
`Target.attachToBrowserTarget` on the root session. The agent gets that browser session, so it sees what looks like a
root connection:
- every agent message without a `sessionId` gets the browser session, and replies and events on it lose it again;
- the hub's own commands use ids from `HUB_ID_BASE` (2^30) to `i32::MAX`, because Chromium reads an id as a 32-bit
  integer; an agent id at or above it is refused (`-32600`), and a reply with a hub id is the hub's whatever its session;
- a child session belongs to the owner of the session its `Target.attachedToTarget` arrived on, and an attach event
  never changes the owner of a session that exists;
- an agent command on a session it does not own (the hub's, a closed one, an unknown one), or naming one or the browser
  target in `Target.*` params, gets `-32000` "not yours";
- `REFUSED_ALWAYS` gets `-32601` "refused by drgnx": `Target.exposeDevToolsProtocol`, `Target.setRemoteLocations`,
  `Target.sendMessageToTarget` (a whole message for a non-flat session that would pass unread), `Tethering.*`,
  `Extensions.*`, `Browser.close`, `Browser.crash` and `Browser.crashGpuProcess`;
- messages to or from the hub's sessions never reach the agent.

Until the attach is answered the router is not `ready()`: the broker holds the agent's messages until it is, and a
message passed anyway gets `-32000` "the browser is starting". If the attach fails, the agent gets the root session as it
is, the router reports `BrokerEvent::NoBrowserSession`, and the hub cannot watch that browser.

**Downloads.** Playwright sets `Browser.setDownloadBehavior` with a path in its own artifacts dir, which the browser
layer cannot write. The router answers the agent `{}` and sends its own on the root: `allowAndName` into
`/tmp/drgnx-browser/downloads` (`DOWNLOAD_DIR`), with events and the agent's `browserContextId`. The download events
then arrive on the root session. They go to the agent, and a `downloadProgress` with `state: "completed"` and a plain
guid is also `BrokerEvent::Download { guid, path }` (`Step::ToAgentAndEvent`). Playwright's `download.path()` does not
find the file; the agent reads it from that dir.

**The agent goes** (`agent_closed`). The router:
1. resumes every agent session still paused by auto-attach (`waitingForDebugger`, not yet resumed by the agent) that no
   hub session holds, with `Runtime.runIfWaitingForDebugger`;
2. detaches every agent session on its parent, children first;
3. marks them closing (what they still send is dropped until Chromium reports them detached);
4. attaches to the browser target again for the next agent, and is not ready until that is answered.

In the fallback it instead turns the root's auto-attach and target discovery off.

**Codecs** (`heimdall::codec`):
- `Nul` splits Chromium's NUL-delimited pipe messages under a limit. An overlong message is one `Overlong` error, and
  the next message after its NUL reads as usual. `Nul::encode` refuses a message with a NUL inside.
- `Frame::encode(kind, payload)` and `FrameDecoder` carry the socketpair between the hub and the browser host,
  `[kind u8][len u32 BE][payload]`: kind 1 (`KIND_CDP`) is one CDP message, kind 2 (`KIND_CONTROL`) control JSON. A header
  over the decoder's limit fails it for good, since the stream cannot resync.

Tests: unit tests in each module. `route`'s tests play transcripts written by hand from the protocol JSON
(`crates/heimdall/tests/data/*.jsonl`: an input line, then what it must give), and the fuzz target `cdp_envelope`
([runtime.md](runtime.md#fuzzing)) seeds from them. `real-full.jsonl` and `real-headless-shell.jsonl` are recorded
from real runs (the browser side only, long strings as their length; [runtime.md](runtime.md)'s `browser_real`):
a test checks that the router's first command is the one sent there and that everything the browser said goes
through a router as well-formed output.

**The fallback's late replies.** In the fallback the agent owns the root session, so a reply there could outlive its
agent and reach the next one. The router remembers the root commands an agent left unanswered when it went, and drops
the first reply with each such id: Chromium answers one session's commands in order, so that reply is the old agent's,
even when the next agent reused the id. At most 4096 ids are kept (the oldest go first).

### The websocket server (`browser::broker`)

The hub serves each browser session's `cdp.sock` with `broker::start(cfg, listener, host) -> BrokerHandle`, where `host`
is the hub's end of the socketpair to the browser host ([The browser host](#the-browser-host)). `BrokerCfg` holds:
- `sid` (logs say `cdp://SID`, never the path);
- `secret` (32 bytes);
- `max_message` (`agents-browser-max-message`);
- `idle` (`agents-browser-idle`);
- `gate`, an async closure that returns the session's `browser` cell as a `Gate`;
- `events`, a channel of `BrokerEvent`s: downloads, `NoBrowserSession` and `Stopped { why }`. A full channel loses the
  event, which is logged.

The handle's `stop(why)`, `close()` and `connected()` do what their names say, and dropping the handle closes it.

**The upgrade.** A connection from another uid is closed at once (`conn::peer_allowed`). HTTP/1.1 (hyper, a 10 s head
timeout) then serves one path, `GET /devtools/browser/<the secret's 64 hex>` with a websocket upgrade (fastwebsockets).
The secret is compared in constant time (`subtle`). Anything else (a wrong secret, no upgrade, a query) is 404 with no
body. With the right secret:
1. a broker whose host has ended answers 503;
2. while an agent websocket is open, a second gets 409 "the agent's browser is already connected";
3. `gate()` is asked: `Allow` goes on, `Ask(n)` is 403 "waiting for the user's yes: card N", and `Never(why)` is 403 with
   WHY. So a cell narrowed to Never refuses the next connection, though not the open one;
4. then 101.

**The browser's life.** The first upgrade while the browser is stopped sends `{"op":"start"}` to the host. The agent's
messages are held, in order, until `started` has come and the router is ready (its attach answered). More than twice
the message limit held closes the agent with 1008. A message over the limit closes it with 1009.
- **The agent goes:** the router's `agent_closed` commands go to the browser (resume, detach, attach afresh). A new
  agent's messages wait for that attach.
- **Idle:** with no agent websocket for `idle`, the broker sends `stop` with `idle` and reports `Stopped { why: "idle" }`.
- **`stop(why)`:** an open websocket is closed with 1001. For `memory` the reason is "the browser was stopped: the
  session is near its memory cap", and otherwise "the browser was stopped (WHY)". The broker then sends `{"op":"stop",
  "why":WHY}` and reports `Stopped { why }`.
- **`exited` while the browser ran** (a crash, or Chromium's own end): an open websocket is closed with 1011 "the browser
  exited (signal N)" (or "(code N)", or the host's error text).
- **After any stop or exit:** the next upgrade starts a fresh Chromium through the same host. An agent that connected
  while a stop was under way gets the fresh one when `exited` comes.
- **The host's end** (EOF on the socketpair): an open websocket is closed with 1011, and every later upgrade with the
  right secret is 503 "the browser's host ended; restart the session to get it back".
- **The hub restarted:** a resumed session has no host, since the socketpair died with the old hub.
  `broker::start_after_restart(cfg, listener)` serves its endpoint with 503 "the browser ended with the hub's restart;
  restart the session to get it back".
- **`close()`:** the broker sends `stop` with `hub`, closes the agent with 1001, and closes the socketpair, so the
  host exits.

One task, the actor, owns the router and the state. The accept loop, each connection's reader and writer (the
websocket split in two, fastwebsockets' `unstable-split`), and the host's reader and writer are tasks that talk to it
over channels.

Tests: `browser::broker` tests run a broker over the real browser host (`host::serve` on a thread with the stand-in
Chromium), with a websocket client of their own: the 404s, 403s, 409, 503, the relay both ways, idle, the memory stop, a
crash (Review Focus 3), a reconnect while the router detaches, and a log with no secret in it. The row
`browser/the-endpoint-refuses-a-wrong-secret` (test-hooks) checks the endpoint through a hub: `__test_browser_endpoint
{socket}` starts a broker with no browser behind it and answers its secret.

## The browser check

`browser/check` (user class, `writes: false`) is the doctor's smoke run (`browser::check`). `ratatoskr doctor --json`
has two seconds, so the doctor only reads `<state>/hub/browser-check.json`, which this method writes. The method runs a
throwaway session of the real shape: sid `check-<8 hex>`, command `sleep 60`, the browser on, made by
`sandbox::browser_for` (so the reasons are a session's: `tier`, `landlock`, `program`), launched by `launch::spawn_plain`
and, where a user systemd answers, in a scope. Its broker is `start_browser_with` with two hooks (`CheckHooks`): a gate
that allows, so no card is raised, and a channel for the host's `stderr` events (`BrokerCfg::stderr`; only the check
sets it). The hub then connects to its own `cdp.sock` with the secret as a websocket client, sends
`Target.createTarget data:text/html,<p>drgnx`, `Target.attachToTarget` (flat) and `Page.captureScreenshot`, and tears
the session down. The whole run has a 45 s deadline; the sandbox's process group is killed after it, and the session
dir and scratch dir are removed.

The answer is `{ok, browser, start_ms, peak_bytes, sys_missed, screenshot_bytes, why, at}`: `start_ms` runs from the
connect to the page's target, `peak_bytes` is the scope's `MemoryPeak`, and `sys_missed` is true when a stderr line
names `/sys/`. A check that could not run is `ok: false` with `why`. Under `test-hooks`,
`DRGNX_TEST_BROWSER_CHECK_ABI=N` replaces the kernel's Landlock ABI, so the `landlock` reason can be tested on any host.

The doctor's `browser` section (`doctor::browser_section`) is
`{found, fix, tier, landlock_abi, verdict, modes, cap, proxy_refusals, last_check, age_warning}`. `proxy_refusals` are
four `gleipnir::net::policy` judgements made in the doctor, no I/O: each must not be `Connect`.

Tests: `browser::check` (the file round trip, the PNG size, the `/sys/` test), `doctor::tests::browser_section_shape`
and `proxy_refusals_all_hold`, and the `#[ignore]` `browser_sandboxed::the_check_takes_a_screenshot` (a hub, the stand-in
`tests/data/fake-chromium-png.sh` as the browser program, the real sandbox).

## The browser host

`ratatoskr browser-host` (`browser::host`, Linux only) runs Chromium inside a session's sandbox for the hub. The inner
helper forks it under the browser layer, its own Landlock domain and seccomp filter ([gleipnir.md](gleipnir.md), "The
inner helper", step 6b), with the hub's end of a socketpair at fd 3 and a ready pipe at fd 4:

```
browser-host --hub-fd 3 --ready-fd 4 --program P --dir D --web-port N [--max-message B] [--headless-shell|--full]
```

**The layer check.** Before it touches a descriptor or makes a dir, the host checks that it runs under the browser
layer: `NoNewPrivs: 1` in `/proc/self/status`, and a TCP bind on loopback refused (`EACCES`). The browser layer binds no
port at all, while the agent's own layer and an unsandboxed process may, so the bind tells the layers apart without a
path. Otherwise it exits 1. Only a `test-hooks` build has `--unconfined`, which skips the check for the container tests
that run it with a real Chromium and no sandbox ([the real browser tests](runtime.md#the-real-browser-tests)); the
sandboxed path with a real Chromium is the `real-start/the-agent-drives-its-browser` row
([the real-start rows](runtime.md#the-real-start-rows)).

**Start.** The host makes `D/profile` and `D/downloads` (0700), writes `ready\n` on fd 4, closes it, and reads frames
from fd 3 (`heimdall::codec`, `[kind u8][len u32 BE][payload]`; the largest is the message limit plus 64 bytes). A
`{"op":"start"}` forks Chromium:
- in its own process group, with `PR_SET_PDEATHSIG(SIGKILL)`;
- stdin and stdout on `/dev/null`, stderr on a pipe, the CDP pipe at fds 3 (in) and 4 (out), every other fd closed at
  the exec;
- exactly the flags of the design (`--remote-debugging-pipe --user-data-dir=D/profile --no-sandbox --disable-gpu
  --proxy-server=http://127.0.0.1:N …  about:blank`), and `--headless` unless `--headless-shell`;
- an environment of `HOME`, `XDG_CACHE_HOME` and `TMPDIR`, all `D`, and nothing else.

It answers `{"ev":"started","pid":N}`. A program that cannot be exec'd gets `{"ev":"exited","code":127|126,
"signal":null,"error":"cannot start P: …"}` instead. A start while one runs answers `started` for the running one.

**The relay.** A CDP frame from the hub goes to the pipe with its NUL. Each NUL-ended message from the pipe goes back as
one CDP frame; one over the limit is dropped up to its NUL. A CDP frame while no browser runs is dropped.

**Stop and exit.** `{"op":"stop","why":W}` closes the pipe, sends SIGTERM to Chromium's process group, and SIGKILL after
2 s. However Chromium ends (stopped, crashed, or on its own), the host waits for the main process without reaping it,
kills what is left of its group (the group's id is still held by the unreaped leader), reaps it, lets the pipe's last
messages through for up to 1 s, and sends `{"ev":"exited","code":N|null,"signal":N|null}`. The next `start` is a fresh
Chromium through the same host.

**The hub goes.** EOF on fd 3 (the hub ended, or restarted: an inherited fd cannot be handed over again), or a reset
(the hub closed its end with the host's last lines unread), stops Chromium as
`stop` does, and the host exits 0, so no Chromium is left behind.

**Stderr.** Chromium's stderr lines go out as `{"ev":"stderr","line":S}`, at most one a second (the others are only in the
tail), and the last 16 KiB are kept in `D/stderr.tail` across starts.

There is no async runtime: the main thread reads the hub, and each start has a writer, a reader, a stderr reader and a
waiter thread. The main thread is the one that forks, so Chromium's death signal fires when the host ends.

Tests: `browser::host` unit tests run the host on a thread against `tests/data/fake-chromium.sh`, a stand-in that
speaks the pipe and echoes every command as its reply. It records its argv, its environment and every call in its
dir, and answers `Target.attachToBrowserTarget` and `Target.detachFromTarget` as Chromium would. On `Fake.attach` it
sends a paused child target, on `Fake.crash` it dies by SIGKILL, and on `Fake.stubborn` it ignores SIGTERM and the
pipe's end. `tests/browser_sandboxed.rs` (`#[ignore]`, the
VM) starts the host under a real bwrap launch with the stand-in.

## Forecasts

A forecast comes from the history of similar finished tasks, never from a model's own guess. `norn::forecast` is pure:
no store and no clock, so the same history and the same seed give the same numbers.

**The reference class** (`model::reference_class`). A task is compared with finished tasks at each level in turn, and
the first level with at least 5 observations (`MIN_CLASS`) wins:

| Level | Same | |
|---|---|---|
| `Project` | role, profile, model and project | a task with no project skips this level |
| `Profile` | role, profile and model | |
| `Role` | role | `other_model` says when some ran on another model: their tokens are carried and priced at the task's rates |
| `Any` | nothing | |
| `Prior` | | `n` is 0, and the answer says it has no history |

`other_model` compares models: another profile on the same model is the same model. A profile with no model set is
the CLI's choice, so across profiles it counts as another model.

Within a class an observation weighs `exp(-(ln b - ln b0)² / (2 · 0.7²))`, where `b` and `b0` are the two briefs'
bytes, floored at 1 KiB: a brief twice the size weighs 0.61, four times 0.14. The prior is unweighted.

**The prior** (`model::prior`) is one base task at ×⅓, ×½, ×1, ×2 and ×3: 19M cache reads, 600k cache writes, 60k input,
90k output, 40 minutes active, 60 minutes of wall time. The cache reads and the output's share (under 0.5 %) are
measured on this project's agents; the other figures are judgement. Its 2 wakes (1 cold) and 300k context are not
scaled: the first is an assumed count, the second a level a task reaches.

**Rates** (`model::usd`) are USD per million tokens, per token class. A cache write pays the 5 minute rate at a TTL of
300 s or less, else the 1 hour rate. Every token class counts towards a forecast's tokens (`Usage::total`).

**A wake** (`model::wake_usd`) costs the session's context × the cache read rate if the job ended within the TTL,
and × the write rate after it, because the whole context is written again. At Opus 5.5's rates, 300k of context costs
$0.06 within the TTL, $1.50 after a 5 minute TTL and $2.40 after an hour's. History already contains its wakes, so a
forecast shows the wake as a part of the total, never added to it.

**The simulation** (`sim::simulate`) runs the plan 2000 times (`DRAWS`). Each draw takes one whole observation per task,
by weight, so one run's tokens, time and cost stay together. Time is a list schedule of each observation's wall time:
whenever one of the slots is free it takes the ready task with the lowest `n`, as the runner does, and a task starts
once its parents have finished. So wall time shows merge bias: three parallel tasks together end later than the p50 of
any of them. Each range comes from the plan's own draws, because p90s do not add up.

The stream is SplitMix64, and `seed_of` is FNV-1a over the inputs: both are written here so that the numbers do not move
with a library or a compiler. Quantiles are nearest-rank (`quantile`).

`price` answers a task's unit and amount for an observation, or nothing. Units are never summed. A pick with no price is
not a zero: the task's cost comes from its priced picks, and a task with none is in no unit. Run again with the same
seed and a `price` of a wake's cost, and the draws are the same, which gives the plan's wake cost.

The class's picks count into the history, and a prior's count on past its end, so `simulate` takes the history followed
by the prior. A prior serves only when the whole history is under 5 rows, because the `Any` level takes the rest.

**The small-class floor** (`sim::widen`): below 20 observations a p90 is at least 1.5 × p50, whatever the draws say, so
a class of five near-identical runs cannot print a tight range.

**Calibration** (`sim::conformal`) is split conformal scaling. Past pairs of (p90, actual), per role, profile and model,
give the actual/p90 ratios, and the factor is the ratio at rank ⌈(n+1)·0.9⌉, so it needs 9 pairs. `p90 × factor` then
covers the next run at least 9 times in 10, provided past and future runs are exchangeable, which a change of model
breaks; hence the model in the key and a recent window. Keep the p90 of each pair as it stood before calibration:
ratios against a calibrated p90 say only how the last factor did, and the factor would swing. The factor can be below
1, so the caller holds a scaled p90 at its p50 or above.

**Prices and the hub's side** (`drgnx_ratatoskr::forecast`). Tokens are priced at today's rates, not at the sample's own
cost. `rates_for` takes the rates of a profile from the setting `drgnx-agents-model-prices` (US dollars per million
tokens, shipped dated `2026-11-01`; a cache price left out is the input price): the row with the longest key that is a
prefix of the profile's model id; else, for a gateway profile, the provider's `:price (IN . OUT)` with every cache token
at the input rate; else the row named for the profile's CLI (`claude`, for a Claude profile with no model set). No
rate: the task is unpriced, and its cost is empty, never zero; a sample's own recorded cost serves only on the same
profile. `prices_as_of` is the oldest date of a row. The cost unit is `usd` for a gateway profile and `usd-est` for a
subscription's, which is an estimate.

`ttl_of` is the prompt cache time to live of a profile in a role: 3600 s for a Claude subscription in any role and for a
gateway Claude worker or manager (the lock asks for `LONG_CACHE_TTL`, `agents/lock.rs`), 300 s for everything else. The
sweep passes it to `gather`, so a sample's cold wakes use the TTL its session had.

`for_tasks` reads the newest 5000 samples, forms each task's class, simulates on `runner::agent_slots` slots (the number
the tick starts at once) with a seed from the job key and every want's fields, widens each task by its class's size and
the plan's totals by the smallest class's, and scales a task's p90 by its class's calibration factor when it has one.
The plan's total has its own factor (a task's holds for that task alone and says nothing of a sum's p90): split
conformal over whole plans, from `sample::plan_pairs`, the job's own `forecast_made` row (its total's tokens p90 before
calibration) against what its tasks used, summed, managers apart, for `done` jobs whose every task that ran has its
sample; the latest 200, at least 9. It scales the total's p90 of tokens, time and every cost unit, and the pace's
added share, so the Autonomous rule's spend and week checks read the calibrated total; a session's forecast
(`forecast/session`) has none. `forecast_made` keeps the p90 as it stood before calibration (`for_job` returns the rows
to keep). The wake line is a
second simulation with the same seed and a price of each drawn observation's cold wakes × its context at the cache
write rate. A manager's own spend comes from the `manager` samples, per task, beside the total.

**The week's pace** (`Forecast.pace`, one `PaceEffect` for each subscription meter a task of the plan runs on). A
meter's readings are kept in a thinned history (`Budgets::history`): one for each quarter hour, none older than 8 days,
at most 768 a provider, saved with the budgets in `runtime.db` (the `meters` field of the `budgets` row; a row saved
before has none) and replayed when the hub starts, so a restart keeps the pace. `pace/get`'s rate still reads only the
last 24 hours. A fall in the meter is a reset, a new segment: only rises count (`budget::rise_total`).
`share_per_usd` is the rises over the `usd-est` that the provider's steps booked since the first kept reading; the
account's meter includes use outside drgnx, so it is an estimate, high if anything. The plan's `added_share` is the
plan's own `usd-est` draws on that provider (a second simulation with the same seed) times that ratio. `runs_out_p90`
is true when the used share, the plan's p90 share and what the current rate adds before the reset reach 1; the
forecast then warns, and the Autonomous preset's auto-start waits. `window` is `week` when the reset is more than a
day off, else `short` ("this window"). No spend or no rise: no `added_share`, and the view says "no pace yet".

| Method | Class | Answer |
|---|---|---|
| `forecast/get` | user | the forecast of a job, from its data as proposed |
| `forecast/session` | user | one more run like a session: one task of its role and profile, nothing recorded |
| `forecast/accuracy` | user | per role and profile, the share of finished tasks that took no more than their p90, and the median of actual over p50 |

End to end, on mocks: `system/a-forecast-before-dispatch` proposes a plan on a subscription Claude mock and a gateway
profile with a provider price, checks the card's range and the prior's basis before any worker exists, runs it to the
end, and checks that each task's and the plan's rollup equal the step table summed in SQL, that the plan's `usd-est`
equals what `budget/get` booked, that the gateway task's `usd` equals its spend rows, that `forecast/accuracy` has a
row per role, and that the next proposal's implement task is forecast from its class of five. The rows wait on a
condition with a deadline (`poll`), never a quiet period. `system/say-it-survives-a-restart` keeps a Say proposal,
its card and its forecast across a second hub on the same root, where `say/revise` on the old planning session says
the planning stopped. `system/mixed-providers-lease-clash-review-spend` checks cost per session, task and plan.

## Say it

One prompt becomes a proposed plan (`say.rs`). `say/start {text, repo, project?, profile?}` starts a planning session:
a chat on `profile`, else the `say` route's first profile, which is the first `implement` route's when `say` has none
(`runner::route`). It runs in a scratch folder of its own (no `cwd`: `spawn_plain`), with no repository, no task and
no graph, so repository and graph text, the injection surface, never reach the session that shapes the plan. Its
first prompt (origin `hub`) is the fixed instructions with the one block form, a digest of the profiles a task may
name (those a job may run on), each role's route, the roles and the project's id (`say::digest`: settings only), and
the user's words.

The session's turn ends at the shell's `PromptDone` handling (`agents/session.rs`, where the last message is already
read for `drgnx-report`): when its id is a planning session's (one set lookup), `(sid, message)` goes to `say::run`.
A message with no `drgnx-proposal` block is a question: `say-message {id, text}` carries it to the editor. A block
ends at the first line that is only "```" (a JSON string holds no raw line break, so a fenced command inside a task's
body is never that line), and is parsed with every unknown key refused (`grants`, `approved`, `auto`, `repo` and the like: the format has `title`,
`tasks` of `{n, title, role, profile?, deps, body}`, `budget` and `gate` only), and more than one block is refused.
`say::check` then refuses, all at once: no title, no tasks or more than 32, a role other than `implement`, `test`,
`docs`, `review` and `review-long`, a profile the settings do not have or a job may not run on
(`runner::review::profile_refusal`), a body over 16 KiB, a dependency that is not there or goes round
(`plan::check`), and a budget that is not a positive amount in `usd` or `usd-est`. A block that does not hold is
answered with the reasons, twice at most; the third is `say-failed {id, why}` and the session is stopped. A block
that holds is written as a graph plan as the user would (`plans/write`: each task's `role`, `profile` and `body`)
and proposed with the repository `say/start` named, the smallest dollar budget of the block and its gate
(`runner::propose_graph`): the job is `proposed` with its proposal card, whose title is the hub's (`card_title`),
never the block's, and `say-proposal {id, job, started}` names it (`started`: the Autonomous preset started it at
once, so nothing waits for an OK and the editor says so). The planning session's own use is the job's
`data.planning` (`tokens`, `usd_est`, `usd`: numbers only), shown and not budgeted.

A Say proposal waits for the user's OK (`job/approve`, a user-class method: an agent's connection is refused, and
no word of the user's prompt or of the block is read for an OK) unless the Autonomous rule holds
(`say::rule`, called from `runner::propose_job` before the job is written). All of these must hold, read with the
manager's column (`MatrixGate::dry`, the project's and the plan's layers applied); the first that fails is why it
waits, kept in the job's `data.waits`:

1. the active preset is Autonomous (time presets and the away flag applied);
2. `agents.start` with the number of tasks is Allow (Autonomous: up to 8);
3. `spend` with the plan's p90 in `usd` plus its p90 in `usd-est`, the estimate counted as dollars, is Allow
   (Autonomous: up to $150);
4. nothing is unpriced;
5. no meter would run out at the plan's p90 before it resets (`runs_out_p90`), whatever its `window`: Claude's one
   meter blends the week with its 5 h window, the week's last day reads as `short`, and a meter with no reset known
   is `short` too, so every window is checked and the reason names the one that would run out; and every
   subscription a task runs on (a profile with no API key) has a pace with the plan's share known: a subscription
   with no meter reading yet never starts alone.

When it holds, the job is approved as the user's preset decided (`approve_job`, no proposal card) and a decision
records it: kind `build`, author `user`, reason "started by the Autonomous preset within its cells".

The order of one planning session is a pure core (`say::SayCore`, every order tested with skuld): at most one prompt
is in flight; a revision (`say/revise {id, text}`) that comes while a prompt, a check or a proposal is under way
waits for it and replaces what it would have done; a revision of a standing proposal withdraws it first and prompts
again only when it was withdrawn (or the user had rejected it). The withdrawal and `job/approve` each decide in their
own store write whether the job is still `proposed` (`norn::write::jobs::withdraw_proposal`, `approve_proposal`), and
the store's writes are one at a time, so of the two exactly one holds: an approval that lands between a status read
and the withdrawal runs on, never stopped (every order tested). `job/stop` (the editor's and the card's reject)
decides in its write the same way (`stop_job`): a proposal is withdrawn and marked never approved, any other job is
stopped unmarked, so an approval that landed first can still be resumed; the budget pause (`pause_running`) and
`job/resume` (`resume_job`) read the status in their own write too (every order tested). A say has at
most one live job: when its proposal starts (the Autonomous preset at once, or the user's `job/approve`, which the
withdrawal finds), the planning is done: the session is stopped and forgotten, the latest 64 such sessions remember
their job, `say/revise` on one answers `invalid` "JOB has started: stop it, then say it again", and a revision that
was waiting is answered `say-failed` with that reason. A revision never stops a running job. The job's start is
recorded before `say-proposal` goes out, so a revision the event prompts is refused at once. `agents/stop` or
`agents/kill` of a planning session stops its planning: nothing
more is prompted or proposed, and a proposal of it still proposed is stopped. `say/end {id}` stops the session and
forgets it; its proposal is a job and stays. Say's state is memory only: after a restart `say/revise` answers "the
planning stopped: say it again", and a proposal it made stays a job with its card.

| Method | Class | Answer |
|---|---|---|
| `say/start` | user | the planning session's id |
| `say/revise` | user | true (refused for a planning session the hub no longer holds, or whose job has started) |
| `say/end` | user | true, or false for a session that is not a planning session |

Events: `say-proposal {id, job, started}`, `say-message {id, text}` (agent-written), `say-failed {id, why}`.
