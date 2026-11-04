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
