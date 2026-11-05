# The job sandbox

A job agent runs shell commands, hooks and MCP servers as the user's uid. No token or command check can stop such a
process from reaching what the user can reach: the hub's socket (and with it the cards), the user's home, other
repositories, the Emacs server, D-Bus. So each agent session's **whole process tree** runs inside a boundary the kernel
enforces: bubblewrap, Landlock and seccomp on Linux, Seatbelt on macOS. The agent's command line is wrapped; everything
it starts is inside.

The sandbox is Gleipnir, and it is the hub's: there is no sandbox code in Emacs Lisp any more (the Lisp libraries of
the old agent runtime, `drgnx-sandbox*.el`, were deleted with it, except the VC guard below).

| What | Where |
|---|---|
| The spec, what it refuses, the bubblewrap argv, Landlock, seccomp, Seatbelt, the relay, the proxy, the check, the escape rows | [gleipnir.md](gleipnir.md) |
| How the hub starts a session in it (the launch, the status pipe, the lock, the matrix) | [hub.md](hub.md#session-start-lock-sandbox-and-matrix) |
| The agent's MCP tools through a socket of its own, and the gateway socket | [hub.md](hub.md#per-session-sockets), [coordination.md](coordination.md#how-an-agent-reaches-the-tools) |
| The session's network: its provider proxy on `proxy.sock`, what it allows, denials as events | [hub.md](hub.md#the-sessions-provider-proxy-proxysock) |
| The git side: snapshot and worktree modes, the bundle, the merge gate | [coordination.md](coordination.md#plan-runs-git-the-merge-gate-trial-merges-drgnx-ratatoskrsrcrunnergitrs) |
| What the settings pin (`drgnx-sandbox-memory-max`, `-secret-files`, `-proxy-pinned-addresses`) | [settings.md](settings.md) |
| Whether it works on this machine | `drgnx doctor`, check `job-sandbox` ([install.md](../guide/install.md)); a host where it does not work starts no session |
| The files a shell step opens, seen and handed to the hub (Linux) | [below](#seeing-the-files-a-shell-step-opens) |

## Seeing the files a shell step opens

`gleipnir::trace` (`runtime/crates/gleipnir/src/trace.rs`): layer 2 of the Work space's "reads through shell
commands" (layer 1, the files a command names, is the hub's parser, [work-space.md](work-space.md#shell-reads)). It
only records and never decides: every notified call is answered "continue", and the kernel then applies Landlock and
the deny-list to it as it would untraced.

- **The filter** (`trace::install`): a seccomp filter on the calling thread with `SECCOMP_FILTER_FLAG_NEW_LISTENER`,
  after `no_new_privs`. `open`, `openat` and `openat2` (aarch64 has no `open`) of the native architecture go to the
  listener (`USER_NOTIF`); every other call, and every call of a foreign architecture, is allowed at BPF speed. It
  sits beside Gleipnir's deny-list, which stays a filter of its own: the kernel takes the highest-precedence answer,
  and `ERRNO` outranks `USER_NOTIF`, so a call the deny-list refuses is never notified. One listener per thread: a
  second fails with `EBUSY`.
- **The hand-off**, over a Unix socket the supervisor (the hub, outside the sandbox) listens on, inside the session's
  run dir (a `sockets` entry of the spec):
  1. the traced side connects and sends one JSON line, `{"v": 1, "scope": "step" | "tree", "command": …}` (at most
     256 KiB), and parks;
  2. the supervisor answers `skip` or `trace`;
  3. only on `trace` the traced side installs the filter and sends the listener fd by `SCM_RIGHTS` with `fd`, or
     `busy` (`EBUSY`: a listener is already above it), or `failed: …`.

  The listener is installed only after the answer, so a skipped command pays nothing. Either side waits at most 2 s
  (`HANDOFF_DEADLINE`). No supervisor, no answer or an EOF runs the command untraced; the hand-off never refuses a
  command. The one exception: a filter installed whose fd then did not reach the supervisor would fail every later
  open (`ENOSYS`), so the wrapper exits 125 and the inner helper fails its setup. The supervisor reads the traced
  side's pid with `SO_PEERCRED`, in its own pid namespace.
- **Two scopes** (`Spec::trace`):
  - **`per_step`** (Claude Code, whose `CLAUDE_CODE_SHELL_PREFIX` wraps each Bash call): the wrapper
    `gleipnir-trace CMD` offers CMD, then `exec bash -c CMD` whatever the answer. Inside bwrap it is
    `/run/gleipnir/gleipnir-trace`, a link to the inner helper, which runs as the wrapper when started by that name;
    Gleipnir adds `GLEIPNIR_TRACE_SOCK` (the socket) to the program's environment. The full tier only. The crate also
    builds a stand-alone `gleipnir-trace` binary (`src/bin/gleipnir-trace.rs`), which the tests run.
  - **`tree`** (an agent CLI with no such prefix): the inner helper installs the filter on itself after seccomp and
    after the relay (which it must not cover), offers the program's argv, and then execs it, so everything the program
    starts is traced. A filter cannot be removed, so this is opt-in.
- **The answering thread** (`trace::listen`): per notification it does only the receive, the path read from
  `/proc/<pid>/mem` (and, for a relative path, the link of `/proc/<pid>/cwd` or of the dirfd, read while the task is
  still blocked in the call) between two `SECCOMP_IOCTL_NOTIF_ID_VALID` checks, and the continue. What it read (`Open
  {pid, call, path, base, flags, at}`) goes to a channel, so resolving, existence checks and the rules run on the
  caller's thread (spike S4: bookkeeping on the answering thread doubled the per-open cost). `/proc/<pid>/mem` files
  stay open per pid (at most 256), and in tree mode each task's thread group is cached (opens by the CLI's own thread
  group are continued unread). `Listener::set_reading(false)` continues every later open without reading it: the
  over-budget answer, since the filter stays. The thread waits in `poll` on the listener and a stop pipe: it ends when
  every task the filter covers is gone (`POLLHUP`) or when asked; an `ENOENT` or `EINTR` from the receive goes back to
  `poll` (since Linux 6.6 the receive fails at once with `ENOENT` when no task is left, and a loop that retried it spun
  at 100 % CPU in the spike). The sync wake-up (`SECCOMP_USER_NOTIF_FD_SYNC_WAKE_UP`) is off unless asked; asked for,
  a kernel without it (`ENOSYS`) gets the plain mode.
- **What it is not.** A path read this way is an observation, not a check: a program can change it between the read
  and the kernel's open (seccomp_unotify(2)), so it is labelled "seen open" and never used to decide. An open the
  kernel then refuses (Landlock) is still seen. A program can read through calls the filter does not watch (an fd a
  forked helper inherited). macOS has no tracer.
- **Cost** (spike S4, desktop): about +8 µs p50 and +9 µs p95 per traced open, 2.7 µs untraced. Budgets: a notified
  open's round trip p95 ≤ 15 µs, 2,000 traced opens add ≤ 50 ms (gleipnir's `tests/timing.rs`, timing rows).
- **Tests:** `runtime/crates/gleipnir/tests/trace.rs`, real children under Landlock and the deny-list, in the sandbox
  container (`ctr.sh --sandbox`); the test binary is its own child (`tests/trace_support/`), and each traced child
  announces itself with its hello and parks on the answer (pattern C).

## The VC guard

`core/drgnx-sandbox-vc.el`. The `.git` of a job's task folder is the agent's. Its config can name a program
(`core.fsmonitor`, `core.pager`, `core.sshCommand`, a hook) that git runs the moment any git of the user's runs there:
visiting a file under VC is enough. So while a task's sandbox lives, nothing of drgnx's or the user's runs git in its
folder.

- **The list.** `(drgnx-sandbox-vc-register FOLDER)` and `(drgnx-sandbox-vc-unregister FOLDER)` keep the registered
  folders (true names, trailing slash) in `<state>/sandbox/folders.eld` (0600, written beside it and renamed over it).
  `(drgnx-sandbox-vc-folders)` re-reads the file when its stamp (time, size, inode) changes. Only absolute strings
  count; a damaged file guards nothing and breaks nothing. The Rust hub does not write this file (it keeps its own
  record of the folders a sandboxed agent worked in, [coordination.md](coordination.md#plan-runs-git-the-merge-gate-trial-merges-drgnx-ratatoskrsrcrunnergitrs)),
  and `legacy::migrate` moves the old `<state>/sandbox/` aside, so the list is empty unless something registers.
- **`drgnx-sandbox-vc-guarded-p DIR`** compares true names on directory boundaries: `7-1/` never matches `7-10/`, and
  a link into a folder is the folder.
- **`drgnx-sandbox-vc-mode`** (core, on in the editor) does two things:
  - `vc-ignore-dir-regexp` is extended with the registered folders, so VC does not look there. It is refreshed
    before each `find-file`.
  - An `:around` advice on `call-process`, `process-file`, `make-process` (`drgnx-sandbox-vc--refuse-git`) and
    `call-process-region` (`drgnx-sandbox-vc--refuse-git-region`: its program is the third argument; blame, the
    indexer and magit's hunk staging run git through it) signals `drgnx-sandbox-guarded` when the program is `git` (by name or any path ending in `/git`) and
    `default-directory` is guarded. Global options count: `-C DIR` (cumulative, relative to the directory so far),
    `--git-dir` and `--work-tree`, as `=` or a separate argument. Everything else costs one `string=` on the
    program's name, and a stat of the list file when the name is `git`. Measured: 1.2 µs per non-git `call-process`
    for the advice function; the whole call is lost in the noise of the fork (about 0.8 ms).
  - magit, project.el (`project-try-vc` ignores errors), VC and drgnx's own callers go through these primitives.
    Also covered because they end in these: `process-lines` (`call-process`), `vc-git--call` and `start-file-process`
    (`process-file`, `start-process` then `make-process`). `shell-command-to-string` runs `sh`, outside the reach.
    The work tracker's `drgnx-work--git` answers nil in a guarded folder instead of failing.
- **Trusted steps.** `drgnx-sandbox-vc-trusted` bound to non-nil around one call lets that call's git through. Bind it
  nowhere else, and never around a user-driven call.
- **What it does not cover.** A `git` started through a shell (`shell-command`, a terminal buffer, `sh -c`) or a
  wrapper program is outside its reach, and so is a `GIT_DIR` set in the environment. A call from natively compiled
  code reaches the advice only through Emacs's trampolines, which need a working native compiler.
- **Nested `.git`.** `(drgnx-sandbox-vc-nested-git FOLDER)` lists the `.git` entries under FOLDER other than
  `FOLDER/.git`: a directory, a gitfile or a link named `.git`. It never follows a link and never enters a `.git`
  directory.
- **The work tracker reads the main repository.** `drgnx-work-source-functions` (abnormal hook): each function gets
  an agent session and returns `(:repo REPO :ref REF)` or nil. When one answers, the session's folder is not read:
  `turn-end` and the session's exit collect nothing, and `(drgnx-work-collect-now SESSION)` records the commits of REF
  in REPO since the task began.
- Tests: `test/unit/sandbox-vc-test.el` (prefix `drgnx-sandbox-vc/`, including a `core.fsmonitor` canary through
  `find-file`, `project-current`, `vc-dir` and magit).
