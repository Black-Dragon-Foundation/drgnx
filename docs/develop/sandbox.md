# The job sandbox

A job agent runs shell commands, hooks and MCP servers as the user's uid. No token or command check can stop such a
process from reaching what the user can reach: the hub's socket (and with it the cards), the user's home, other
repositories, the Emacs server, D-Bus. So each job agent's **whole process tree** runs inside a boundary the kernel
enforces: bubblewrap on Linux, Seatbelt on macOS. The agent's command line is wrapped; everything it starts is inside.

This page describes `core/drgnx-sandbox.el`: the spec, what it refuses, and the bubblewrap command line it becomes.
The code is pure. It builds data and an argv and runs nothing; the tests assert the argv element by element, and two
smoke tests run it under the real bwrap where bwrap can run (`test/unit/sandbox-test.el`).

## What is inside, and what is not

Default deny. Inside the sandbox exist only:

- the system's read-only roots: `/usr`, `/etc`, and where they exist `/opt`, `/nix`, `/gnu`, `/var/lib/flatpak`;
  `/bin`, `/lib`, `/lib64` and `/sbin` as links into `/usr` where the host's are links (merged `/usr`), else bound
  read-only (`drgnx-sandbox-system-read`);
- a fresh `/dev` and `/proc` (the sandbox's own processes only), and empty `/tmp`, `/run` and `/var/tmp`;
- the resolver's file, where `/etc/resolv.conf` leads under `/run` (systemd-resolved's
  `/run/systemd/resolve/stub-resolv.conf`): that file alone, read-only, so names resolve. Never its directory,
  which holds resolved's socket;
- a **private home** at the user's `$HOME` path, so tools with absolute paths still work, but holding nothing of
  the user's;
- what the spec binds: toolchain roots read-only, the task's folder read-write, the session's socket directory
  read-only at `/run/drgnx`, and the git mode's pins.

Not inside, as absent paths: the rest of `/home`, `/run/user`, `$XDG_RUNTIME_DIR` (the hub's socket, the Emacs
server, D-Bus, ssh-agent, gpg-agent, podman, the keyring), `/sys`, `/mnt`, `/media`, other jobs' folders and private
homes, other sessions' socket directories, drgnx's data directory (`work.db`) and configuration. The environment
holds only the spec's variables.

## The spec

`(drgnx-sandbox-spec &rest PROPS)` returns a plist. Every path goes through `file-truename` (links resolved, no
trailing slash), so a link planted in the task folder cannot widen a bind. `:net` defaults to `shared`.

| Key | Value | Linux |
|---|---|---|
| `:backend` | `bwrap` or `seatbelt` | default `drgnx-sandbox-backend` |
| `:read` | `(PATH…)` | `--ro-bind-try` at its own path, where it exists |
| `:write` | `(PATH…)` | `--bind` at its own path |
| `:hide` | `(PATH…)` | a file under `/dev/null`, a directory under an empty tmpfs; skipped where absent |
| `:binds` | `((ro\|rw OUTSIDE INSIDE)…)` | applied last, in order: the git modes' pins |
| `:home` | `(OUTSIDE . INSIDE)` | `--bind`: the private home at `$HOME`'s path |
| `:run` | `OUTSIDE` | the session's socket dir, `--ro-bind` at `/run/drgnx` |
| `:sockets` | `(PATH…)` | the Unix sockets the agent may connect to (Seatbelt); on Linux they are in `:run` |
| `:env` | `((NAME . VALUE)…)` | the whole environment |
| `:chdir` | `DIR` | `--chdir` |
| `:net` | `shared` or `isolated` | `--share-net` only for `shared` |
| `:proxy`, `:gateway` | ports | macOS, phase 2 |
| `:tmp`, `:profile-file` | paths | macOS: the session's `TMPDIR`, where the profile is written |
| `:memory-max` | string | the memory cap |

## What is refused

`(drgnx-sandbox-validate SPEC)` returns nil or the reason. The back ends call it and signal
`drgnx-sandbox-refused` with that reason; nothing runs.

- **A path that is not usable as it is:** relative, holding a NUL or a newline, not in canonical form (a `//`
  anywhere, a `.` or `..` component, a trailing slash), or not its own true name. Emacs keeps a leading `//`
  (`(file-truename "//usr")` is `"//usr"`) where the kernel reads `/`, so `//` would slip past every prefix check
  below: `drgnx-sandbox-spec` turns it into `/`, and a hand-made spec that holds one is refused. Not its own true
  name catches a spec built by hand with a link in it, and a directory swapped for a link after
  `drgnx-sandbox-spec` resolved it. File name handlers are off throughout: a TRAMP-looking name is a local path,
  never a connection.
- **A bind that would expose the user's things.** From `:read`, `:write`, `:binds`, `:home`, `:run` or `:tmp`, never
  `$HOME`, the drgnx checkout, the ssh agent's socket (`SSH_AUTH_SOCK`) or the D-Bus socket (a `unix:path=` in
  `DBUS_SESSION_BUS_ADDRESS`), **nor any directory that holds one of them** (`/`, `/home`, `/tmp` when the agent's
  socket is in it, …). Read-only counts too: a read of `~` is every key in it.
- **Anything in or above a closed directory:** `/run/user`, `$XDG_RUNTIME_DIR`, the hub's socket directory (all its
  possible places), drgnx's data directory (`work.db`), configuration and state directories, `/proc`, `/sys`, `/dev`,
  `/tmp/.X11-unix`, `/tmp/.ICE-unix` and the Emacs server's `/tmp/emacsUID`. Inside the state directory only what
  is inside a job's own directory, `<state>/sandbox/ID/…` (the private homes `ID/home-N`), may be bound. Never
  `<state>/sandbox/` itself nor a file directly in it, such as `folders.eld`, the registry that keeps the user's git
  tools out of agent-owned folders; never other durable jobs (`<state>/jobs`).
- **Session directories:** `:run` alone may be one, and only one session's: a directory directly in
  `$XDG_RUNTIME_DIR/drgnx/s/` (or in `s/` beside the hub's socket where there is no runtime dir:
  `drgnx-sandbox-sessions-dirs`). Nothing else may bind from any session's directory, its own included: not
  another session's (its sockets would replace the agent's own), and not a sub-path such as `s/SID/out` (a live
  agent could swap it for a link; see Limits). `:sockets` entries must be in `:run`; `:profile-file` must be in a
  session directory.
- **A read-write bind of a program directory:** `:write`, `:binds rw`, `:home` or `:tmp` that is a directory of
  `exec-path`, or holds one (`~/go` when `~/go/bin` is on the hub's `PATH`). The agent could plant a `bwrap` or a
  `git` there, and the hub would run it outside any sandbox.
- **A source that does not exist** for `:write`, `:binds`, `:home` and `:run`. (`:read` and `:hide` entries that do
  not exist are left out of the argv.)
- **A malformed spec:** an unknown key (a typo would otherwise drop a rule silently), a value of the wrong shape, a
  `:net` other than `shared` or `isolated`, an `:env` name that is not a variable name, or one of
  `drgnx-sandbox-env-deny` (`SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, `DISPLAY`,
  `WAYLAND_DISPLAY`, `XAUTHORITY`, `GPG_AGENT_INFO`, `DRGNX_DATA_DIR`, and `DRGNX_AGENT`: an agent's identity comes
  from the socket it connects on, never from anything inside).

Inside the home is fine: a task folder in a repository under `~`, a toolchain root such as
`~/.local/share/mise/installs/node/20`, a private home under the state directory. Toolchain and Emacs roots must be
those specific directories, never `~/.local`, `~/.config` or `~/.local/share`, which hold drgnx's own.

A `:binds` INSIDE (a destination) may be any absolute path, even `/run/user/…`: what a bind exposes is its source,
and only sources are checked.

## The bubblewrap argv

`(drgnx-sandbox-bwrap-argv SPEC COMMAND)`. Every path is one argv element; nothing goes through a shell, so nothing
is quoted. All paths are absolute, so none can be read as an option.

```
/usr/bin/bwrap --unshare-all --unshare-user [--share-net] --disable-userns --die-with-parent --new-session
      --clearenv
      --setenv NAME VALUE …                                  # the spec's :env, nothing else
      --ro-bind-try /usr /usr  --ro-bind-try /etc /etc  …   # the system's reads
      --symlink usr/bin /bin  …                              # where the host's /bin is a link
      --dev /dev --proc /proc --tmpfs /tmp --tmpfs /run --tmpfs /var/tmp
      --ro-bind-try /run/systemd/resolve/stub-resolv.conf …  # the resolver's file, where resolv.conf leads under /run
      --bind PRIVATE-HOME $HOME                              # :home
      --ro-bind-try TOOL TOOL …                              # :read
      --bind FOLDER FOLDER …                                 # :write
      --ro-bind SESSION-DIR /run/drgnx                       # :run, read-only
      --ro-bind PIN PIN  --bind PIN PIN …                    # :binds, in order
      --ro-bind /dev/null SECRET-FILE  --tmpfs SECRET-DIR    # :hide
      --chdir FOLDER
      -- COMMAND…
```

Why each flag:

- **The program**: bwrap's absolute true name, found once (`drgnx-sandbox-program`, cached until
  `drgnx-sandbox-program-reset`): `/usr/bin/bwrap` first, then `exec-path`, and only a file root owns, in a
  directory root owns, neither writable by anyone else. A `bwrap` a sandbox planted on the hub's `PATH` is never
  run. (macOS: `/usr/bin/sandbox-exec`, the same way.)
- **`--unshare-all`**: new pid, ipc, uts, cgroup, network and mount namespaces, and a user namespace *if it can*
  (bwrap's `--unshare-user-try`). The pid namespace hides the user's other processes (no `/proc/PID/environ` of the
  hub); the mount namespace is what makes paths absent.
- **`--unshare-user`**: the user namespace for certain. `--disable-userns` needs it: without it bwrap 0.12 refuses
  to start (`--disable-userns requires --unshare-user`).
- **`--share-net`** (phase 1, `:net shared`): the agent needs its model API and the gateway on the host's
  `127.0.0.1`. The known gap: abstract Unix sockets (X11's `@/tmp/.X11-unix/X0`) and services on the host's loopback
  stay reachable. Phase 2 (`:net isolated`) drops it and gives the agent a proxy instead.
- **`--disable-userns`**: nothing inside can build nested namespaces (a nested bwrap, rootless podman), so the outer
  sandbox stays the boundary.
- **`--die-with-parent`**: the sandbox ends with the hub's process; no orphaned agent keeps running.
- **`--new-session`**: a new session id, so the agent cannot push input into a terminal with `TIOCSTI`.
- **`--clearenv`**: the environment is empty, then the spec's `:env` is set. Nothing of the hub's environment
  passes: no `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, display or provider key.
- **No `--cap-drop ALL`**: it would be redundant. In an unprivileged user namespace the sandboxed process has no
  capabilities (CapEff and CapBnd are 0) and `no_new_privs` is set; bwrap drops capabilities itself only when it
  runs privileged.
- **`--tmpfs /run`**: `/run/user` (the user's runtime directory) is absent, even if a later rule binds something
  under `/run`. The session's own directory is bound at `/run/drgnx`, a path of its own. The resolver's file is
  bound back on top of the empty `/run`: without it `/etc/resolv.conf` (a link to systemd-resolved's stub on
  Fedora and Ubuntu) dangles and no host name resolves, so a `:net shared` agent cannot reach its provider.
- **`:run` read-only**: connecting to a Unix socket needs no write access to its directory, so the agent still
  reaches the sockets the hub listens on there. But it can create, remove or replace nothing in the directory: no
  link planted where the hub looks later.
- **The order**: the private home first, then reads and writes on top of it (a toolchain or a task folder under `~`
  shows at its path inside the private home), then the session dir, then the git pins, which must cover the
  folder's `.git`, then `:hide`, which must cover files inside the roots bound before it.

`(drgnx-sandbox-base-env)` is where a session's `:env` starts: `PATH`, `HOME`, `USER`, `LANG` and every `LC_*`
where set, `TERM=dumb`, `SHELL`, and `TMPDIR=/tmp`, from the calling Emacs. Nothing else, ever.

## The back ends

`(drgnx-sandbox-backend)` is `bwrap` on Linux and `seatbelt` on macOS when `drgnx-sandbox-program` finds bubblewrap
or `sandbox-exec` (root's only, see above), else nil. `(drgnx-sandbox-wrap SPEC COMMAND)` picks the spec's
`:backend` or that one:

- **Linux**: `drgnx-sandbox-bwrap-argv`.
- **macOS**: the SBPL profile (`drgnx-sandbox-sbpl`, `core/drgnx-sandbox-macos.el`) is written to `:profile-file`,
  mode 0600, as a new file, and the command line is `/usr/bin/sandbox-exec -f FILE COMMAND…`.
- **Neither**: `drgnx-sandbox-refused`. A missing sandbox is never a silent fallback to the bare command.

## Limits

- **Resolution and mounting are two steps.** The spec's paths are resolved and checked when the argv is built;
  bubblewrap resolves them again when it mounts, a few milliseconds later, and follows links. A link swapped in
  between, at a path a running agent can write, would be followed. bwrap's `--bind-fd` would close the gap, but
  Emacs cannot hand a child extra file descriptors, and a shell opener resolves by path again. So the rules are:
  - session directories are read-only inside, and no bind may come from inside one but `:run` itself (enforced);
  - a later sandbox binds a live agent's tree only as a whole directory whose parent no sandbox can write, never a
    sub-path such as `<folder>/.git`;
  - sources the hub made itself, in directories only the hub writes, are safe.
- **Toolchains under `/run`** (NixOS's and Guix's `/run/current-system`) are hidden by `--tmpfs /run`. Their `PATH`
  entries do not resolve inside yet.
- **The program is found once.** A bubblewrap installed while the hub runs is seen after
  `drgnx-sandbox-program-reset`.


## MCP through a socket

A sandboxed agent has no `work.db`, no hub socket and no keys, so drgnx's MCP servers (coordination, search) run
outside the sandbox, one per connection, started by the hub. Inside, the agent's `drgnx` MCP entry starts a
**bridge** (`core/drgnx-mcp-bridge.el`) that copies the agent's stdio to the session's own socket:

```
emacs --batch -Q --eval "(setq load-prefer-newer t)" -L CORE -l drgnx-mcp-bridge -f drgnx-mcp-bridge-main /run/drgnx/mcp.sock
```

`drgnx-mcp-bridge-command SOCKET` builds that argv (through `drgnx-command-ignoring-sigpipe`, like the other MCP
servers). The socket a connection comes in on tells the hub which session it is: nothing inside the sandbox names the
agent, so nothing there can claim to be another.

What the bridge does, and nothing more:

- It connects to the one socket named by its argument (`make-network-process :family 'local`). Its code opens no
  file, starts no process and reads no environment variable; with `-Q` Emacs loads no init file.
- One JSON-RPC message per line, both ways. Each line must be a single JSON object of at most
  `drgnx-mcp-bridge-max-line` bytes (16 MiB); anything else ends the bridge with status 1 and a line on stderr
  (`drgnx-mcp-bridge: from the agent: message too large`, `… malformed message`), and the message is not forwarded.
  JSON-RPC batches (a top-level array) count as malformed: MCP 2025-06-18 removed batching. The same holds for lines
  from the server, whose pieces are kept as a list and joined once at the newline, so a long line costs linear time
  however it is chunked. The bridge forwards each line as it came, never re-serialized.
- It exits 0 when stdin ends or the server closes the connection, and 1 with
  `drgnx-mcp-bridge: cannot connect to SOCKET: …` when the socket is not there.

**The bridge is not a security boundary.** Any process inside the sandbox can connect to `/run/drgnx/mcp.sock`
directly, with its own code. The bridge's size limit, frame checks and stepping protect nothing; they keep an honest
agent's traffic well formed. The hub side owns the size limits, the malformed-frame handling and the recovery from a
wedged server, and treats every byte on the socket as hostile. The hub must close the connection when its
per-connection server exits and when the session ends: while a request is pending the bridge does not read stdin, so
if the agent dies then, the bridge outlives it. On Linux bwrap's pid namespace and `--die-with-parent` reap it; on
macOS (Seatbelt, no pid namespace) only the hub's close ends it.

**Why it runs in step.** A batch Emacs cannot wait on stdin and a socket at once: `read-from-minibuffer` blocks in
`getchar`, and no process output is read meanwhile. A bridge that only copied lines would deadlock on the first
request: the answer would sit unread while the bridge waits for the agent's next line. So after forwarding a request
(a message with an `id` and a `method`) the bridge reads the socket until that id's answer has come back, writing
whatever the server sends meanwhile, and only then reads stdin again. Notifications are forwarded without waiting.
A server request (an `id` and a `method`) during a call is written at once and does not end the wait. drgnx's servers
(`drgnx-mcp-serve`) answer each request in turn, send nothing unasked and make no requests of the client, so with them
this behaves exactly like today's direct stdio server. The bridge has no timeout: a slow search is legitimate, and a
wedged server is the hub's to end. The limits, for any server that did more:

- **A server-to-client request during a call deadlocks.** If the server sends `elicitation/create`,
  `sampling/createMessage`, `roots/list` or `ping` while a `tools/call` is pending and then waits for the client's
  reply, the bridge writes the request to stdout but does not read the reply from stdin until the call's answer
  comes, which never does. Both sides wait for ever (until the hub closes the connection).
- A message the server sends while no request is pending reaches the agent only when the agent next writes.
- A `notifications/cancelled` from the agent is forwarded only after the answer it meant to cancel.
- A server close while the bridge waits for input is noticed at the agent's next line (or at the end of stdin).

A full-duplex bridge, probed on Linux and not built: the launcher hands the agent's stdin to Emacs as fd 3
(`exec emacs … 3<&0 </dev/null`) and the bridge reads it through a child `sh -c "exec cat <&3"`, which inherits the
fd (reopening `/dev/stdin` fails: under libuv it is a socketpair). The bridge then copies bytes with no parsing and
none of these limits, at the cost of `sh` and `cat` in the sandbox and one more process; it relies on Emacs leaving
inherited fds open in its children, unverified on macOS. It is the upgrade path once a drgnx server first sends
anything unasked or makes a server request.

**Cost** (Emacs 30.2, Linux, one bridge, measured with a local fake server): start to connected 60 ms (median of 10),
and a round trip through the bridge 0.10 ms against 0.07 ms straight to the socket.

Tests: `test/unit/mcp-bridge-test.el` (`drgnx-mcp-bridge/`) runs the bridge as a child Emacs against a fake server on
a socket in the test's temporary directory.

## Git: snapshot mode

In snapshot mode, the default, each task of a job gets a `.git` of its own in its folder
`<repo>/.claude/worktrees/ID-N/`. `core/drgnx-job-snapshot.el` makes it. It is **never a copy of the user's
`.git`**. The user's `.git` holds what an agent must not read, and `git cat-file --batch-all-objects` or
`fsck --lost-found` lists all of it without knowing any object id:
- unreachable objects: a file staged and then unstaged, a dropped stash, a commit amended away;
- the other branches, tags, reflogs and the index;
- config that may carry tokens.

Git's own security guidance sets the second rule: a `.git` an agent can write is untrusted, and running git in it runs
that agent's config and hooks. So the hub runs git in a task's `.git` only **before** any agent has it. From then
on, git runs there only inside the sandbox.

### What the agent can see

In a task's `.git`, and nothing more:
- **The branch BASE** (`refs/heads/job/ID`) and every object reachable from it: the whole history of that branch,
  including anything ever committed to it. `HEAD` names BASE.
- **The objects of earlier BASE tips.** The job's store keeps them: BASE moves forward as tasks merge, and a
  force-moved BASE leaves its old tip's objects, which were the job's own.
- **A whitelist config** that the hub wrote (below).
- **A shared clone** (no copy-on-write) also has:
  - `refs/remotes/origin/job/ID`, at the same commit;
  - the clone's own reflog entry, which names the store's path;
  - read access to the store's objects, the same set as above.

Everything else stays out:
- the user's other branches, tags, stash, reflogs and index;
- unreachable objects;
- uncommitted changes and untracked files (`.env`, local keys);
- the user's hooks, remotes, credentials and other config;
- the user's linked worktrees.

The user's `.git` is never copied or mounted.

### The job's store

Once per job, the hub makes a **clean store** at `<repo>/.claude/worktrees/<BASE>.base.git`, where the `/` of BASE
becomes `~` (`job~ID.base.git`; `~` never appears in a branch name). It is made with:

```
git -c core.hooksPath=/dev/null -c core.fsmonitor=false clone -q --no-local --bare --single-branch --no-tags \
    --template= --branch BASE -- REPO STORE
```

- `--no-local` makes git transfer a pack through upload-pack, as from a server. Only objects reachable from BASE come
  through, so none of the user's unreachable objects, other branches or tags.
- `--template=` installs no hooks.
- The clone's config is then **replaced** with the whitelist.
- A bare clone writes no reflog.

The clone goes to `STORE.part`, which is renamed to `STORE` only once its config is written. A store that a stopped
job or a crash left half-made therefore never has the final name, and its `.part` leftover is removed before the next
build.

The store is hub-only. No agent mounts it writable, and nothing of an agent's reaches it. When BASE moves (a task
merged), the next task's snapshot first runs
`git --git-dir=STORE fetch -q --no-tags --no-write-fetch-head REPO +refs/heads/BASE:refs/heads/BASE`.
- The store is always named with `--git-dir` (or `config --file STORE/config`), never found by discovery.
  `safe.bareRepository=explicit`, git's hardening against embedded bare repositories, refuses discovery.
  Discovery from a wrong directory would also find the user's repository instead.
- The store's steps run one at a time: a fetch while a copy reads the store could give the copy a ref without its
  objects.
- Each turn is guarded. An error in any step, even a synchronous one (`.claude/worktrees` is not a directory), ends
  it with `(:error MSG)` and frees the store for the next turn.

### The task's copy

`drgnx-job-snapshot-make REPO FOLDER BASE DONE` makes the store, or fetches into it, and then the task's `.git`. It is
asynchronous, like every step here (separate processes with a deadline, so the hub never waits). DONE gets one of:

- `(:mode snapshot :read nil)`: a copy-on-write copy of the store. On Linux it uses `cp -a --reflink=always` (btrfs,
  XFS). On macOS it uses `cp -c -a` (clonefile, APFS). The store is inside the repository, so the copy is on the same
  filesystem.
- `(:mode clone :read DIRS)`: the fallback without copy-on-write (tmpfs, ext4, network filesystems, HFS+). It runs
  `git clone -q --shared --no-checkout --single-branch --no-tags --template= --branch BASE STORE FOLDER`. DIRS is the
  store's `objects`, which the sandbox mounts read-only. Never the user's.
- `(:error MSG)`: BASE is not a branch name, REPO is not a repository, FOLDER exists and is not empty, or the store
  failed twice.

In both modes, the task's config is the store's whitelist again, with `core.bare false`. Then
`cat-file -e refs/heads/BASE^{commit}` checks the copy. Nothing is checked out: the sandbox's first step checks out
`job/ID-N` at BASE in the empty folder.

The caller keeps DIRS with the task, in the hub's state, never in the folder. At bind time it checks them against
`drgnx-job-snapshot-read-dirs REPO BASE`, which is derived from the repository. Once an agent has had a folder, its
alternates file is the agent's, so nothing is ever derived from it.

**Copy-on-write is probed, not assumed.** `drgnx-job-snapshot-cow-p REPO` copies one small file under
`<repo>/.claude/worktrees/` (never in `.git`) with the copy command, and caches the answer per filesystem (the
device number). In the hub, the first probe on a filesystem is a process of its own. Setting
`drgnx-job-snapshot-copy-on-write` to nil always makes the clone.

**A `.git` the user's git is writing.** The store comes from git's own transfer, which reads refs and objects
consistently and ignores the user's lock files. When the clone or fetch fails, for example because BASE is not there
yet, a store made by that try is removed and the step runs once more.

### The config: a whitelist the hub writes

The hub writes the store's config itself, and each task's config is the same list. A key no one has thought of yet
stays out.

| From | Keys | Why |
|---|---|---|
| the store's fresh clone | `core.repositoryformatversion`, `core.filemode`, `core.ignorecase`, `core.symlinks`, `core.precomposeunicode`, `extensions.*` | What git needs to read the repository (the object format). |
| the user's repository (`--no-includes`) | `core.autocrlf`, `core.eol`, `core.safecrlf` | Line endings, as the user checks out. |
| the user's repository | `core.hooksPath`, only if relative and without `..` | The project's own hooks (drgnx's `.githooks`) run inside the sandbox, from the checkout. |
| the user's repository | `filter.lfs.clean`, `smudge`, `process`, `required` | Git LFS checkouts. |
| the hub | `core.bare` (true in the store, false in a task), `gc.auto 0` | A repack would un-share copied blocks, or drop objects a clone borrows. |

A carried value that holds a URL with credentials (`://user:secret@`) is dropped too.

Nothing else is carried:
- remotes, `credential.*`, `url.*`, `http.*` (including `http.<url>.*` subsections with credentials in the URL);
- `submodule.*.url`, `branch.*.remote` and `pushRemote`;
- `lfs.url` and `lfs.pushurl`;
- `include*`;
- `core.fsmonitor`, `core.worktree`, `core.sshCommand` and the other program keys.

**Overrides on every git the hub runs here:**

| Override | Why |
|---|---|
| `core.hooksPath=/dev/null`, `--template=` | No hook runs in the hub, and none is installed in the store or a clone. |
| `core.fsmonitor=false` | An fsmonitor is a program git runs whenever it reads the index. |
| env: `GIT_TERMINAL_PROMPT=0` | Never a prompt. |
| env: `GIT_ALLOW_PROTOCOL=file` | Only local transfers. |
| env: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY` and `GIT_ALTERNATE_OBJECT_DIRECTORIES` unset | No inherited variable points git at another repository. |

The clone's local upload-pack reads the user's own repository config, which is trusted.

**Inside the sandbox**, git runs what the task's config and checkout name:
- checkout runs `filter.lfs.*` and the hooks under a relative `core.hooksPath` (`post-checkout`);
- `bundle create` runs none.

drgnx's own sandboxed steps should still pass `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.pager=cat
-c core.editor=false`, with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`. Then an agent's config only
ever runs with the agent's own power.

After DONE, nothing outside the sandbox runs git in the folder again (the VC guard enforces it).

**Limits:**
- **Git LFS repositories do not check out yet.** LFS content (`.git/lfs/objects`) is not in the store.
  - The task's config has the LFS filter (with `filter.lfs.required`) but no remote and no `lfs.url`, so
    `git-lfs smudge` has no endpoint even with network. The checkout likely aborts.
  - A checkout with `GIT_LFS_SKIP_SMUDGE=1` would leave pointer files instead.
- Submodules' git directories are not copied. A task gets empty submodule directories.
- On macOS, `cp -c` may fall back to a full copy without failing on a filesystem without clonefile. The probe then
  answers yes. For a store this costs little (it holds BASE alone).
- The store's time and disk grow with BASE's reachable history. A very large repository pays seconds once per job,
  not per task.

### Bounded

The store and each copy live under `.claude/worktrees/` and nowhere else. `drgnx-job-snapshot-remove DIR DONE`
removes them with `rm -rf`, which never follows a link an agent left. It takes only its own folders:
- a task folder `ID-N` (or `ID-N-review`) with a `.git` directory;
- a store `NAME.base.git`.

It refuses a path with a link anywhere from the repository down: `.claude`, `worktrees` or the folder itself. The
repository's own path is the user's, and may go through a link. Remove a store only after the last task that borrows
from it (shared clones).
`drgnx-job-snapshot-disk-usage DIR DONE` reports `(:bytes N :exclusive M)`:
- N comes from `du`, which counts shared blocks in full;
- M is what is not shared, from `btrfs filesystem du` on btrfs, and nil elsewhere.

Measured on drgnx's own repository on btrfs (base `main`, 7572 objects reachable; three runs each):

| What | Time | Disk |
|---|---|---|
| the job's store, made | 0.16–0.18 s | 2.4 MB |
| the job's store, fetched (BASE unchanged) | 11–12 ms | |
| a task's copy-on-write copy | 11 ms | 2.4 MB by `du`, exclusive 0 |
| a task's shared clone | 21–22 ms | 28 KB |
