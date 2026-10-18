# The job sandbox

A job agent runs shell commands, hooks and MCP servers as the user's uid. No token or command check can stop such a
process from reaching what the user can reach: the hub's socket (and with it the cards), the user's home, other
repositories, the Emacs server, D-Bus. So each job agent's **whole process tree** runs inside a boundary the kernel
enforces: bubblewrap on Linux, Seatbelt on macOS. The agent's command line is wrapped; everything it starts is inside.

This page describes `core/drgnx-sandbox.el`: the spec, what it refuses, and the bubblewrap command line it becomes;
then the check, the toolchain roots, the memory cap and the short sandboxed steps. The spec and the argv are pure
data: the tests assert the argv element by element, and three smoke tests run it under the real bwrap where bwrap can
run (`test/unit/sandbox-test.el`). The check and `drgnx-sandbox-run` start processes, never blocking.

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
trailing slash), so a link planted in the task folder cannot widen a bind. `:net` defaults to `shared`, and
`:memory-max` to `drgnx-sandbox-memory-max` (an explicit nil means no cap).

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
| `:memory-max` | a size (`4G`, `512M`, `50%`) or nil | the memory cap: a systemd scope in front (see below) |

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

Where there is a memory cap (below), its scope comes first: `systemd-run … -- bwrap … -- COMMAND`.

## The check

Before a job's first agent starts, the hub asks whether the sandbox works here. A missing or broken one stops the job
with a card that says why and how to fix it; the doctor shows the same answer.

- `(drgnx-sandbox-check-async DONE)` is the hub's: it never blocks and never prompts. Its probes run side by side as
  processes of their own, each for at most `drgnx-sandbox-check-timeout` seconds (5), and DONE gets the answer. With
  an answer kept, or when no probe can run (no program), DONE is called before it returns; a call while a check runs
  waits for that one. Any error, while the probes are built or their answer is made, ends the check with an answer
  that says so: every caller is always answered, and the check never stays "running".
- `(drgnx-sandbox-check)` is the same, synchronous, for the doctor and the CLI: it waits for the async one.
- The answer: `(:ok BOOL :backend SYM :version STRING :reason STRING :fix STRING :scope BOOL)`. `:fix` is nil where
  nothing can be done here; `:scope` says whether a systemd user manager answers (the memory cap).
- It is kept in `drgnx-sandbox--checked` until `drgnx-sandbox-check-reset`, which also forgets the programs found.
  A check that runs looks for its programs again (`drgnx-sandbox-program-reset`), so a bubblewrap installed while the
  hub runs is seen at the next check rather than never. A reset while a check runs lets that check answer its own
  callers, but its answer is not kept (a generation counter), and the next call starts a new check.

The probes (`drgnx-sandbox--probes`), all run by the hub:

| Probe | Linux | macOS |
|---|---|---|
| `:probe` | the argv every agent gets (`drgnx-sandbox-bwrap-argv` of an empty spec) around `/usr/bin/true` | `sandbox-exec -p '(version 1)(allow default)' /usr/bin/true` |
| `:version` | `bwrap --version` | — |
| `:scope` | `systemd-run --user --scope --quiet -p MemoryMax=64M -p MemorySwapMax=0 -- /usr/bin/true`, with the trusted systemd-run | — |

The probe is the real argv, not a smaller one, so whatever an agent's start would trip on (`--proc` without a pid
namespace, `--disable-userns` without a user namespace) fails the check first. Its spec is empty, though: it has no
`:home` and no `:run` bind, so a failure particular to those binds shows only when an agent starts.

`(drgnx-sandbox--explain STDERR)` turns a failure into `(REASON . FIX)`:

| When | Reason | Fix |
|---|---|---|
| `/run/.containerenv` or `/.dockerenv` exists | inside a container | none |
| no bwrap (STDERR nil) | bubblewrap is not installed, or not where only root can change it | by `/etc/os-release`'s ID, then ID_LIKE: `sudo dnf install bubblewrap`, `sudo apt install bubblewrap`, `sudo pacman -S bubblewrap`, `sudo zypper install bubblewrap`, else "with your package manager" |
| `setting up uid map: Permission denied` | AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later) | load Ubuntu's `bwrap-userns-restrict` profile |
| bwrap's "user namespaces" message | the kernel does not allow unprivileged user namespaces | the sysctl that allows them |
| anything else | its first line | run the probe by hand |

A probe that hangs is ended at the timeout, and the reason says so. The container case comes first: inside one, any
failure is "inside a container", and `bin/drgnx test --container` skips the real-bwrap tests with it.

## Toolchain roots

An agent needs the user's compilers, linters and test runners, many of which live under `~`. Binding `~` is refused,
so `(drgnx-sandbox-toolchain-roots PATH-DIRS HOME)` finds the read-only roots under HOME that the `PATH` entries
there need, as sorted true names: dirs, and single files. A known **toolchain layout**
(`drgnx-sandbox--toolchain-layouts`, matched on whole path components) gives its install root:

| Layout | Root |
|---|---|
| `~/.local/share/mise/installs/TOOL/VER/…`, or in the data dir `$MISE_DATA_DIR` (else `$XDG_DATA_HOME/mise`) names, where that is under `~` | `…/mise/installs/TOOL/VER` |
| `~/.cargo/bin` | `~/.cargo/bin`, and `~/.rustup/toolchains` where it exists (cargo's proxies run them) |
| `~/.rustup/toolchains/…` | `~/.rustup/toolchains` |
| `~/go/bin` | `~/go/bin` |
| `~/.nvm/versions/node/V/…` | `~/.nvm/versions/node/V` |
| npm's prefix: `~/.npm-global/…`, or `~/.local/lib/node_modules/PKG/…` | `~/.npm-global`, or that package |
| pipx: `~/.local/share/pipx/venvs/APP/…` (older: `~/.local/pipx/venvs/APP`) | the venv |
| uv: `~/.local/share/uv/tools/APP/…`, `~/.local/share/uv/python/V/…` | the tool's venv, the Python |
| Claude Code: `~/.local/share/claude/versions/…` | `~/.local/share/claude/versions` |

- **Each `PATH` dir inside HOME**, its links resolved (`~/bin` → `~/tools/bin`), gives the root of its layout, else
  the dir itself (`~/.local/bin`, `~/.bun/bin`).
- **Each link inside such a dir** gives the root of the layout it leads into (`~/.local/bin/python` → mise's python).
  A link into no layout gives **its target file alone**, read-only: `~/.local/bin/sync` → `~/dotfiles/sync.sh` binds
  that script, never `~/dotfiles` with the key beside it. The file must be a program: a regular file with an execute
  bit, not directly in `~` (`~/.netrc`, `~/.npmrc`), its name none of `drgnx-sandbox-secret-files`; so a link to
  `~/.netrc` or to `~/dotfiles/id_ed25519` gives nothing. A link to a dir in no layout gives nothing.
- **A link into drgnx's own data dir or checkout gives nothing** (install.sh's `~/.local/bin/drgnx` →
  `~/.local/share/drgnx/drgnx/bin/drgnx`). drgnx's files reach a sandbox only through the explicit bind the hub
  makes for what needs them (the MCP bridge), never through `PATH`.

Never a root: HOME or a parent of it; `~/.local` itself; anything in `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`,
`~/.docker` or `~/.password-store`; anything in `~/.config`, `~/.local/share`, `~/.local/state` or `~/.cache` but a
known layout's root (`~/.config/gh`, `~/.local/share/keyrings` never). A `PATH` dir that would be one of these is
skipped with its links. Last, every root goes through validation's `:read` rules, and what they refuse is dropped. A
root inside another is left to the outer one; dirs outside HOME are the system's reads already. Broader reads are the
user's to give, through `:sandbox-read` in `agents.eld`.

Bin dirs rather than whole tool homes keep the credentials beside them out: `~/.cargo/credentials.toml` is not
inside `~/.cargo/bin`. Those inside a root are hidden: `(drgnx-sandbox-toolchain-hide ROOTS)` is the `:hide` list,
each name of `drgnx-sandbox-secret-files` (`.npmrc`, npm's global `etc/npmrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`,
`.git-credentials`, `.env`, `credentials*`, `auth.json`) relative to each root, where it exists, as its true name.

## The memory cap

The whole command can run in a systemd scope, so that one agent's build cannot run the session out of memory. This
is an operational guard, not a security boundary.

- `drgnx-sandbox-memory-max` (default `"4G"`; nil for none) is a spec's `:memory-max` unless the spec gives one.
  Validation takes only a size: digits with `K`, `M`, `G` or `T`, or a percentage. `drgnx-sandbox-memory-prefix`
  checks it too, so a caller that builds its own argv cannot pass anything else.
- `(drgnx-sandbox-memory-prefix SPEC)` is `(SYSTEMD-RUN "--user" "--scope" "--quiet" "-p" "MemoryMax=M" "-p"
  "MemorySwapMax=0" "--")`, with the trusted systemd-run (`drgnx-sandbox-program`, never one found on `PATH`
  first). It is nil when `:memory-max` is nil, or when the last check found no user manager that answers (`:scope`),
  or has not run: it never starts a process itself.
- `drgnx-sandbox-wrap` puts it first. A scope keeps stdin, stdout and stderr; systemd-run execs the command, so
  ending the process ends the agent.

## Short sandboxed steps

`(drgnx-sandbox-run SPEC ARGV DONE &optional TIMEOUT)` runs ARGV inside SPEC (through `drgnx-sandbox-wrap`, so under
the memory cap) as a process of its own, started in `/` with stdin closed, and returns the process. It is for the
hub's short steps (a checkout, a bundle) and never blocks. DONE gets `(EXIT . OUTPUT)`, stdout and stderr together
and trimmed, or `(:timeout . MSG)` when it ran past TIMEOUT seconds (default `drgnx-job-git-timeout`) and was ended.
A refused spec signals `drgnx-sandbox-refused`, and nothing runs.

## Cost

Measured on Fedora 44 (bubblewrap 0.12.0, systemd 259), 20 runs of `/usr/bin/true` each, from a batch Emacs:

| Command | Median | Range |
|---|---|---|
| the generated bwrap argv | 7.0 ms | 6.5–7.9 ms |
| the memory cap's scope, then the argv | 23.3 ms | 14.9–30.3 ms |

The check runs its probes side by side once per hub start, so it costs about as much as the scope.

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
- **The program is found once per check.** A bubblewrap installed while the hub runs is seen at the next check that
  runs: after `drgnx-sandbox-check-reset`, or when the hub checks again.
- **Toolchains that write under `~`** (mise's shims and state, rustup updating, go's module cache) fail read-only.
  Their caches belong in the private home (`CARGO_HOME`, `GOMODCACHE` pointing there). rustup's proxies in
  `~/.cargo/bin` read `~/.rustup/settings.toml`, which is not bound: the agent's environment needs
  `RUSTUP_TOOLCHAIN`. mise's shims (`…/mise/shims`) run mise itself, which reads its config: put mise's
  `installs/…/bin` on `PATH` (mise's activation does) rather than the shims (they are in `~/.local/share`, so no
  root anyway).
- **A script linked from `PATH` gets only itself.** A link into no layout binds the target file alone, so a script
  that loads files beside it, or a tool installed in a layout drgnx does not know, fails inside. A pipx or uv venv's
  `python` is a link to the interpreter it was made from: that interpreter must be a root too (a system one, or one
  of mise's or uv's on `PATH`). The fix is a layout entry, or `:sandbox-read` for that profile. A linked file that is
  not executable, or sits directly in `~`, is never bound.
- **`PATH` dirs under `~/.config`, `~/.local/share` or `~/.cache` are dropped** unless they are a known layout:
  Doom Emacs's `~/.config/emacs/bin`, composer's `~/.config/composer/vendor/bin`, mise's shims. Those dirs sit beside
  config and tokens, so drgnx does not guess. Add one with `:sandbox-read` in that profile (`agents.eld`) to have it
  inside.
- **Secret files are looked for at fixed places** in each root (`drgnx-sandbox-secret-files`), not throughout a
  toolchain's tree. The layout roots are install dirs, where that is enough.


## macOS: Seatbelt

`core/drgnx-sandbox-macos.el`. `(drgnx-sandbox-sbpl SPEC)` turns the same spec into a Seatbelt profile (SBPL, the
policy language of `sandbox-exec`); `drgnx-sandbox-wrap` writes it to `:profile-file` and runs
`/usr/bin/sandbox-exec -f FILE COMMAND…`. The code is pure: it validates the spec (`drgnx-sandbox-validate`, the same
refusals as on Linux) and builds text. The tests (`test/unit/sandbox-macos-test.el`) run everywhere: they read the
profile back as data and ask a small evaluator, which applies SBPL's rule order, what it allows. The profile itself is
verified on a Mac only (the MAC-SB rows of the Mac checklist).

### What differs from Linux

macOS has no mount namespace. Nothing is bound anywhere: every path is seen at its own place, and what the agent may
touch is the profile's allow list.

- **`:home`**: the private home, readable and writable at its own path. It must be `(OUTSIDE . OUTSIDE)`, and the
  session's `HOME` names it. A `:home` whose INSIDE is not its OUTSIDE is refused, so the real `$HOME` is never
  passed by habit.
- **`:binds`**: each is at its own path. One whose INSIDE is not its OUTSIDE is refused.
- **`:run`**: readable at its own path (there is no `/run/drgnx`), never writable.
- **`:sockets`**: the only Unix sockets the agent may connect to, one by one.
- **`:env`, `:chdir`, `:memory-max`**: not in the profile. The caller sets the environment and the directory.

### The profile, in order

SBPL decides by the **last rule that matches**, so the order is the policy:

```
(version 1) (deny default) …                    ; the base: drgnx-sandbox-macos-base (Codex's, see below)
(allow system-socket (socket-domain AF_UNIX))   ; pipes to child processes; connecting is decided at the end
(deny file-read* (subpath "/Users"))            ; before every allow: only what is allowed below is readable there
(allow file-read* (literal "/"))
(allow file-read-metadata (literal …))          ; /tmp, /var, /etc, and every directory above an allowed path
(allow file-read* (subpath …))                  ; the system's roots, :read, :write, :home, :run, :tmp
(allow file-read* (literal "/dev/null") …)      ; the devices, each by name
(deny file-read* (subpath "/opt/homebrew/var") (regex …) …)          ; Homebrew's data
(allow file-write* (subpath …))                 ; :write, :home, :tmp
(allow file-read* (subpath B)) (allow file-write* (subpath B))       ; each of :binds, in order: rw…
                               (deny file-write* (subpath B) (regex …))   ; …or ro (the pins)
(deny file-read* file-write* (subpath H) (regex …) …)                ; :hide
(deny file-write-unlink (literal D) (regex …) …)                     ; no rename of a root or a pin's parents
(allow network-outbound (remote ip "*:*"))      ; :net shared, with the services a networked CLI needs:
  (allow system-socket … AF_SYSTEM …) (allow mach-lookup …)          ; TLS trust, the network's configuration
  — or, :net isolated: (deny network*) (allow network-outbound (remote ip "localhost:PORT"))   ; :proxy, :gateway
(deny network-outbound (remote unix-socket))    ; every Unix socket…
(allow network-outbound (remote unix-socket (path-literal S)))   ; …but each of :sockets (and, shared, the resolver's)
```

- **The system's roots** (`drgnx-sandbox-macos-system-read`): `/usr`, `/bin`, `/sbin`, `/System`, `/Library`,
  `/opt/homebrew`, `/private/etc`; `/dev/fd` (the process's own descriptors); `/private/var/select` (the link
  `/bin/sh` and `xcrun` follow), the time zones and the selected developer directory (the git of the Command Line
  Tools). Homebrew's data (`/opt/homebrew/var`, `/usr/local/var`: the databases of Postgres, MySQL, Redis) is
  denied after every read, so a spec that reads `/opt/homebrew` does not reach it.
- **Devices, each by name** (`drgnx-sandbox-macos-devices`): `/dev/null`, `/dev/zero`, `/dev/random`,
  `/dev/urandom`, `/dev/tty` (the controlling terminal) and `/dev/dtracehelper`. Never all of `/dev`: the user's
  other terminals (`/dev/ttysN`) belong to the same user, and a process that reads one races the shell for its
  keystrokes, `sudo` passwords included. The base allows only the ptys the sandbox opened itself.
- **`subpath` or `literal`**: every allowed or hidden path is a `subpath`, which covers a file itself and a whole
  directory, component by component (`/a/b` covers `/a/b/c`, not `/a/bc`). A `literal` would hide a directory but
  not its contents. `literal` is used only for `/` and for the metadata of the directories above an allowed path:
  `realpath()` needs to stat each of them, but none of them can be listed. Sockets are `path-literal`.
- **One kind of operation per path.** Seatbelt lets a deny of a specific operation win over a later allow of a
  wildcard (sandbox-runtime found this for `file-write-unlink`). So the allows and denies on a path use the same
  wildcards (`file-read*`, `file-write*`), and the later rule wins. The one specific deny is the rename block below,
  which is meant to win.
- **No rename past a deny.** Seatbelt's rules match paths, not files. Renaming a directory above a pin or a hidden
  path would carry it to a name no deny covers: `mv conf c2; cat c2/.env`, or moving the whole task folder out,
  editing its `.git` pointer and moving it back, which a bind mount (EBUSY) prevents on Linux. So
  `(deny file-write-unlink (literal D))` (a rename's source is an unlink) covers every writable root (`:write`,
  `:home`, `:tmp`, the rw `:binds`) and every directory from such a root down to the parent of each ro pin and
  `:hide` path (`drgnx-sandbox-macos--move-blocks`). The pins and hidden paths themselves are covered by their own
  `file-write*` denies. A `literal` touches the directory alone: files in it can still be removed and renamed, and
  other directories moved. This is sandbox-runtime's move-blocking deny (`generateMoveBlockingRules` and
  `generateReadDenyUnlinkRules` in `src/sandbox/macos-sandbox-utils.ts`, anthropics/sandbox-runtime at
  `626a596`, Apache-2.0), cut to what drgnx's spec needs: drgnx denies unlink only, not create: the roots and pins
  exist when the profile is made, and a hidden path that does not exist yet holds nothing to read.
- **Every deny holds in every case.** APFS is case-insensitive by default, so `.GIT/config` is `.git/config`. Whether
  Seatbelt compares paths that way is not known, so each deny (the pins, `:hide`, the rename blocks, Homebrew's data)
  also carries a `regex` built from character classes (`drgnx-sandbox-macos--case-regex`: `\.[Gg][Ii][Tt](/.*)?$`;
  a non-ASCII letter as `(é|É)`; no `(?i)`). Allows stay exact: a path spelled otherwise is simply not allowed. The
  regex is about four times the path's length, so a deny path of more than about 250 characters makes the profile
  refused (1024 bytes, below).
- **`/tmp`, `/var` and `/etc` are links into `/private`.** Seatbelt matches the resolved path, so every rule names
  `/private/…`. A spec's paths are true names (`file-truename` gives `/private/tmp/…` on a Mac), and the constants
  are spelled that way. The links themselves get their metadata only, so a path through one still resolves.
- **No `~` read.** `/Users` is denied before every allow. Validation refuses `~` and its parents in any key, as on
  Linux. The home appears only as the parent of an allowed path, with its metadata: it can be stat'ed but not
  listed, and nothing in it but what the spec allows can be read.
- **The session's sockets only.** The hub's socket, the Emacs server's, `SSH_AUTH_SOCK` and every other Unix socket
  are refused by path. With `:net shared` the system resolver's socket (`/private/var/run/mDNSResponder`) is allowed
  too: every host name lookup on macOS goes through it, so without it nothing resolves (Chromium's network policy
  allows it for the same reason). So is `/private/var/run/resolv.conf`, for resolvers that read it (Go's).
- **Network.** Phase 1 (`:net shared`) allows outbound IP anywhere, like Linux's shared network, and nothing
  inbound. `:net isolated` denies all network, then allows outbound to localhost's `:proxy` and `:gateway` ports
  only. macOS has no network namespace, so the ports are what isolates. A port outside 1–65535 is refused. The
  network mach services (TLS trust, the network's configuration) and the AF_SYSTEM socket come with `:net shared`
  only, as in Codex: `trustd` and `ocspd` fetch a certificate's AIA, OCSP and CRL URLs outside the sandbox, a way
  past `(deny network*)`. The trade-off, for phase 2: tools that verify TLS through Apple's frameworks (`curl` and
  `git` from the Command Line Tools) may fail in isolated mode even through the proxy; Node's own TLS does not ask
  `trustd`.
- **No escape through other processes.** No `appleevent-send` (an AppleEvent to Terminal runs anything), no
  `lsopen` (LaunchServices starts apps outside the sandbox), no mach-lookup of `com.apple.coreservices.launchservicesd`.
  No Keychain either (`com.apple.SecurityServer`): job agents on macOS use the gateway profiles.

### Quoting

Every path is an SBPL string, made by `drgnx-sandbox-macos--quote`: in double quotes, with `"` and `\` escaped by a
backslash. A path with a control character (a newline, a tab, NUL, DEL) is refused: SBPL's reader would take some
of them as escapes, and validation already refuses newlines and NULs. So is a literal over 1024 bytes, which
`sandbox-exec` refuses ("Error reading string"). A folder named `x") (allow default) ("` stays one path in one rule.

### The session's TMPDIR

`(drgnx-sandbox-macos-tmpdir SID)` makes a new directory, mode 0700, under `temporary-file-directory` (on macOS the
user's own `/private/var/folders/…/T/`), with a random suffix, so nothing planted before is used. It returns the true
name, for the spec's `:tmp` and the session's `TMPDIR`. `SID` must be a plain name. Removing it is the session's job.

### The base policy

`drgnx-sandbox-macos-base` is the Seatbelt base policy of OpenAI's Codex, unchanged:
[`codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/sandboxing/src/seatbelt_base_policy.sbpl)
at commit `8c07694`, Copyright 2025 OpenAI, under the
[Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0), whose text is
`LICENSES/Apache-2.0.txt`. The list of network mach services
(`drgnx-sandbox-macos-net-services`) is Codex's `seatbelt_network_policy.sbpl` at the same commit, without
`com.apple.SecurityServer`. The Apache License 2.0 is compatible with drgnx's GPL-3.0-or-later. Codex's base was
chosen over Anthropic's sandbox-runtime (also Apache-2.0) because it is a published policy file of its own and
holds no LaunchServices or Keychain service, which drgnx must leave out. drgnx's rules come after it.

### Limits (macOS)

- **Unverified on a Mac until the MAC-SB rows pass.** The mach services, the system's roots and the resolver
  allowance are from Codex and Chromium. The deny log on a real job (`log show --predicate 'sender == "Sandbox"'`)
  settles them.
- **Case** is handled on the deny side only (above), and unverified on a Mac. So are hard links and clones of a
  hidden file (`ln`, `cp -c`): whether `file-link` and `file-clone` fall under `file-write*` or under
  `(deny default)` is a Mac row. Worktree mode stays off on macOS until those rows pass.
- **Existence.** A denied path probably fails with EPERM and a missing one with ENOENT, so names in `~` can be
  probed one by one, never listed. Linux gives ENOENT for both.
- **Tools' own Unix sockets** (a language server's socket in `TMPDIR`) cannot be connected to, and nothing can listen
  on a port in phase 1. Only `:sockets`, the resolver's socket and outbound IP are allowed.
- **No nesting.** A `sandbox-exec` inside the sandbox is believed to fail: macOS is not known to nest Seatbelt
  profiles.

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

**Inside the sandbox**, the agent's own git runs what the task's config and checkout name: `filter.lfs.*`, and the
hooks under a relative `core.hooksPath`. drgnx's own steps there (below) run none of them.

After DONE, nothing outside the sandbox runs git in the folder again (the VC guard enforces it).

**Limits:**
- **Git LFS: a task gets pointer files.** LFS content (`.git/lfs/objects`) is not in the store, and the task's
  config has the LFS filter but no remote and no `lfs.url`, so `git-lfs smudge` would have no endpoint even with
  network. drgnx's steps therefore run with `GIT_LFS_SKIP_SMUDGE=1`: LFS files are left as their pointers. With
  `git-lfs` inside (a system path), an agent that leaves a pointer unchanged commits it as it was (the clean filter
  passes a pointer through), so the work comes back intact; an agent that needs the content cannot have it yet.
  Without `git-lfs` inside, `filter.lfs.required` makes the checkout fail, as it would for the user.
- Submodules' git directories are not copied. A task gets empty submodule directories.
- On macOS, `cp -c` may fall back to a full copy without failing on a filesystem without clonefile. The probe then
  answers yes. For a store this costs little (it holds BASE alone).
- The store's time and disk grow with BASE's reachable history. A very large repository pays seconds once per job,
  not per task.

### Inside, and back out: the checkout and the bundle

Once the folder's `.git` is the agent's, the hub's git steps on it run **inside the sandbox**, as short steps of
`drgnx-sandbox-run` (so under the memory cap). Their spec is `(drgnx-job-snapshot-step-spec FOLDER &key writable out
read)`:
- the system's reads, FOLDER read-only, or read-write when WRITABLE;
- OUT, when given, read-write at `/run/drgnx/out` (at its own path on macOS, which has no mounts);
- READ read-only: the objects of the job's store, which a shared clone borrows. The hub derives them from the
  folder's name and the base (`drgnx-job-snapshot-read-dirs`), never from the folder's alternates file;
- no home, `:net isolated`, and only this environment: `PATH=/usr/local/bin:/usr/bin:/bin`, `HOME=/nonexistent`,
  `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `GIT_ALLOW_PROTOCOL=file`,
  `GIT_LFS_SKIP_SMUDGE=1`, `LC_ALL=C`.

Every step's git gets `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.pager=cat -c core.editor=false`.
The folder's config is the agent's: even inside, drgnx's steps run none of its programs, so an agent's config only
ever runs with the agent's own power, in the agent's own git.

Without a sandbox a step does not run: it ends with `(:error "… no sandbox …")`, never as a plain process. Only a job
the user let run unsandboxed passes UNSANDBOXED, and its steps then run plainly with the same overrides and
environment (but the hub's `PATH`).

| Function | What it runs | DONE gets |
|---|---|---|
| `drgnx-job-snapshot-checkout FOLDER BRANCH BASE DONE &optional UNSANDBOXED` | inside, FOLDER writable: `git checkout -q -f -B BRANCH refs/heads/BASE` | `t`, `(:error MSG)` |
| `drgnx-job-snapshot-bundle FOLDER BASE BRANCH OUT DONE &optional UNSANDBOXED` | inside, FOLDER read-only, only OUT writable: `git bundle create -q /run/drgnx/out/task.bundle refs/heads/BASE..refs/heads/BRANCH` | `(:bundle FILE)`, `(:empty)` (no commits), `(:error MSG)` |
| `drgnx-job-snapshot-fetch REPO BUNDLE BRANCH BASE DONE` | outside, in the trusted REPO only (below) | `(:fetched COMMIT)`, `(:error MSG)` |
| `drgnx-job-snapshot-review-folder REPO BRANCH FOLDER DONE &optional UNSANDBOXED JOB` | a fresh snapshot of BRANCH, then the checkout inside | `drgnx-job-snapshot-make`'s result, `(:error MSG)` |
| `drgnx-job-snapshot-refresh-base REPO FOLDER BASE DONE &optional UNSANDBOXED` | a bundle of BASE from REPO, fetched inside, FOLDER writable | `t`, `(:error MSG)` |

**OUT** is a directory the hub made, where no agent writes: never inside a session's directory (`s/SID/out` is
refused as a bind source, since a live agent could swap it for a link), but for example inside the job's own
directory under the state directory. An earlier `task.bundle` there is removed (a link is removed, never followed)
before each bundle step.

**The bundle is data.** A bundle is a pack and a list of refs. Reading one runs nothing of the agent's: no config, no
hooks. `drgnx-job-snapshot-fetch` treats it as hostile input and refuses, with the reason:
1. a BUNDLE that is not there, is a link, or is not a regular file (a FIFO would hang git);
2. heads (`git bundle list-heads`) that are anything but one line, `HEX refs/heads/BRANCH`: a second ref (an agent's
   `refs/heads/main`) would otherwise be written into the user's repository;
3. a bundle `git bundle verify` rejects (a prerequisite the repository does not have);
4. an object `fsckObjects` rejects: the fetch runs with `-c transfer.fsckObjects=true -c fetch.fsckObjects=true`
   (the user's own `fetch.fsckObjects=false` would otherwise win);
5. a BRANCH that does not descend from REPO's BASE (`merge-base --is-ancestor`): its earlier value is put back
   (`update-ref`), or it is deleted when it was new.

The fetch itself is `git -C REPO fetch -q --no-tags --no-write-fetch-head --no-recurse-submodules BUNDLE
+refs/heads/BRANCH:refs/heads/BRANCH`, with the hub's overrides. `refs/heads/job/ID-N` in the main repository is
written only by the hub, and the reviewer, the clash scan and the merge read it there.

**The reviewer** gets a fresh snapshot (`drgnx-job-snapshot-review-folder`): a store of `job/ID-N` made from the main
repository after the fetch (`job~ID-N.base.git`), a copy of it, and `job/ID-N` checked out inside. It holds only what
passed through the bundle, objects and one ref: none of the implementer's config or hooks, so an implementer's
`core.fsmonitor` can never run in the reviewer's sandbox.

**A merge-conflict retry** (`drgnx-job-snapshot-refresh-base`) gets the new `job/ID` the same way. The hub bundles
`refs/heads/job/ID` from the main repository into a private directory of its own,
`<repo>/.claude/worktrees/.drgnx-base-XXXX/`, and a step inside the sandbox fetches it into the folder's repository
(the directory read-only). The directory is removed afterwards. The bundle holds all of `job/ID`'s history: the same
objects as the job's store.

**Cost** (drgnx's own repository cloned on tmpfs, real bwrap and the memory cap's scope, load about 3; three runs
each):

| Commits | Create inside | Verify and fetch outside | Total |
|---|---|---|---|
| 1 | 38–43 ms | 22–27 ms | 60–66 ms |
| 5 | 33–44 ms | 24–34 ms | 57–78 ms |
| 50 | 44–49 ms | 33–34 ms | 76–82 ms |

Most of the step inside is the sandbox's start (the scope and bwrap, about 30 ms), not git.

**Limits:**
- macOS: a step needs the session's `:profile-file` for its Seatbelt profile, which the step spec does not give
  yet. On macOS the steps are refused until the job's session supplies one.
- Between the hub's check of `task.bundle` and git opening it, only something that can write OUT could swap it.
  No sandbox has OUT once the bundle step has ended.

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

## Git: worktree mode

Snapshot mode is the default. Worktree mode is opt-in: a profile's `:git worktree`, `drgnx job propose --git
worktree`, or the plan's `**Git:** worktree` line. One job uses one mode for all its tasks. `core/drgnx-job-worktree.el`
builds it: it makes the worktree, returns the binds as data, checks the branch and scrubs the worktree's git state.
The sandbox applies the binds.

Each task gets a classic linked worktree that shares the repository's `.git`:

```
git worktree add -q -b job/ID-N/work <repo>/.claude/worktrees/ID-N refs/heads/job/ID
```

Why someone picks it:
- The task's branch is in the main repository the moment the agent commits. There is no bundle step.
- `git worktree list` shows every task.
- The user's own tools work in the folder (magit, `git log`, a shell prompt) **once the task's agent has stopped** and
  the hub has scrubbed its git state (below). While it runs, VC stays out of the folder, as in snapshot mode.
- There is no copy, even on ext4.

Git's security guidance is the rule here too: a `.git` an agent can write is untrusted, and git run in it runs that
agent's config and hooks. So the sandbox mounts the main `.git` **read-only**, except for what one worktree's commits
must write.

### The binds

`(drgnx-job-worktree-binds REPO FOLDER NAME ID N)` returns them in the order bubblewrap applies them. A later bind
covers an earlier one, so each pin comes after the writable directory it sits in. `GIT` is the repository's common
git directory; NAME is the worktree's directory in it (git names it after the folder, `ID-N`).

| # | Mode | Path | Why |
|---|---|---|---|
| 1 | ro | `GIT` | config, `hooks/`, `info/`, `packed-refs`, other refs, other worktrees |
| 2 | rw | `GIT/objects` | new objects: commits need it |
| 3 | rw | `GIT/refs/heads/job/ID-N` | its own branch `job/ID-N/work`, and no other ref |
| 4 | rw | `GIT/logs/refs/heads/job/ID-N` | that branch's reflog |
| 5 | rw | `GIT/worktrees/NAME` | its `HEAD`, `index`, `logs/HEAD` |
| 6 | ro | `GIT/worktrees/NAME/commondir` | pinned: where its repository is |
| 7 | ro | `GIT/worktrees/NAME/gitdir` | pinned |
| 8 | ro | `GIT/worktrees/NAME/config.worktree` | pinned; the hub makes it empty first |
| 9 | rw | `FOLDER` | the working tree |
| 10 | ro | `FOLDER/.git` | pinned: the `gitdir:` pointer |

- The branch is `job/ID-N/work`, so it is a file inside its own directory `refs/heads/job/ID-N/`. That directory is
  the only writable one among the refs. Every other branch, `job/ID` and `main` stay read-only. That includes the
  trick of writing a loose `refs/heads/main` that shadows a packed one.
- A bind mount point cannot be renamed or removed (EBUSY), so the pinned files stay.
- The main checkout is not mounted. Its untracked and uncommitted files (a `.env`) are not inside.
- The paths are true names. ID, N and NAME are checked first: an id like `../x` would widen the ref directory, so it is
  an error.
- `(drgnx-job-worktree-binds … t)` gives the same binds, every one read-only, for a reviewer's worktree.

The tests in `test/unit/job-worktree-test.el` assert this data: the order, which paths end up writable, and the
read-only variant. The escape tests prove under the real bwrap that each pinned path gives EROFS or EBUSY.

What fails inside, because the shared state is read-only:
- `git stash` ("Cannot save the current status"): `refs/stash` is shared.
- `git rerere`: its `rr-cache/` is read-only.
- With git 2.56, a commit prints `error: Unable to create '…/packed-refs.lock': Read-only file system` and still
  succeeds.

### Making the worktree

`(drgnx-job-worktree-add REPO FOLDER ID N BASE DONE)` runs `git worktree add` as a process of its own: the hub never
waits. Git runs in the main repository, with `core.hooksPath=/dev/null` and `core.fsmonitor=false`, as snapshot mode
does. Then, before any agent, it reads the worktree's NAME from `FOLDER/.git`, and keeps it only when that worktree's
`gitdir` leads back. It then calls `drgnx-job-worktree-prepare`. DONE gets `(:name NAME)` or `(:error MSG)`. A bad id
or base, a folder that is there already, and a reftable repository are refused before git runs.

Call `(drgnx-job-worktree-prepare REPO NAME ID N)` before each start of the task's agent. It makes what the binds
need, where it is missing:
- the two ref directories. `git pack-refs`, which `git gc` runs, packs the branch and removes its now empty
  `refs/heads/job/` directories, and bubblewrap cannot bind a directory that is not there;
- an empty `GIT/worktrees/NAME/config.worktree`, so that it can be pinned. A job stopped between `git worktree add` and
  this step never made it. A file that is there (git copies the user's own) is kept.

### A reftable repository is refused

A repository on the reftable backend keeps every ref in one `reftable/` directory. It cannot be split into the
task's own branch and the rest. `(drgnx-job-worktree-refusal REPO)` returns the reason, from `git rev-parse
--show-ref-format` (git 2.45 or later) or else `extensions.refStorage`:

> this repository keeps its refs in reftable: worktree mode cannot limit the agent to its own branch; use snapshot mode

`drgnx-job-worktree-add` asks it before git runs.

### The worktree's git state: scrubbed

`worktrees/NAME/` must be writable: git replaces `HEAD`, `index` and `logs/HEAD` there by rename. **Per-worktree state
is the agent's, and the user's git trusts it.** The agent can leave in it:
- an operation in progress (`rebase-merge/`, `rebase-apply/`, `sequencer/`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, …).
  `git rebase --continue` runs its todo's `exec` lines as the user. `--continue` or `--abort` moves the branch its
  `head-name` names (`main`) to a commit of the agent's;
- links in place of files git writes by opening them (`COMMIT_EDITMSG`, `MERGE_MSG`, `FETCH_HEAD`, `logs/HEAD`, and
  the branch's reflog in `logs/refs/heads/job/ID-N/`). An amend in the folder writes the agent's commit message
  through the link: to `~/.bashrc`, or to the main `.git/config` with a `core.fsmonitor` of its own;
- a `HEAD` naming another branch, so that a commit in the folder moves it.

Read-only binds cannot prevent this. `(drgnx-job-worktree-scrub REPO NAME ID N)` removes it, and returns the names
(relative to `GIT`) it removed or rewrote, or nil:
- In `worktrees/NAME/` it keeps only `HEAD`, `index`, `ORIG_HEAD`, `COMMIT_EDITMSG`, `logs/HEAD` and the three pins,
  each a regular file, and `refs/` as the empty directory `git worktree add` makes. `COMMIT_EDITMSG` is written by
  every commit; only a link there is dangerous.
- `HEAD` must be `ref: refs/heads/job/ID-N/work` or an object name. Otherwise it is rewritten to the first.
- In `refs/heads/job/ID-N/` and `logs/refs/heads/job/ID-N/` it keeps only `work`, a regular file.

It runs no git and follows no link:
- It takes types from lstat. What goes is renamed (a link itself) into `GIT/.drgnx-scrub-*`, a directory the agent
  cannot write. `rm -rf`, which never follows a link, then removes it in a process of its own.
- It never descends into a directory the agent can write. `logs/` is moved out whole, and `logs/HEAD` comes back
  only if it is a regular file.
- It reads `HEAD` only after moving it out, and only when it is a regular file, so a FIFO in its place never blocks
  the hub.
- It never renames across devices. An entry whose own device or whose directory's device differs from the trash's
  (a btrfs subvolume the agent made) would make `rename-file` copy and delete it, opening its files. Such an entry is
  left in place. After the rest is done, the scrub signals `drgnx-job-worktree-scrub-failed` with the names left and
  those removed.
- The trash is removed even when the scrub fails (`unwind-protect`).

Call it at each turn end, before a review, and once more after the agent's sandbox has exited. Only then can the
agent not plant again. While the sandbox lives, the folder belongs with the VC guard, as in snapshot mode. The user's
tools are safe in the folder only after the agent has stopped and the hub has scrubbed. A shell `git` in the folder
while the agent runs is outside drgnx's reach, as in snapshot mode. `objects/` is not scrubbed: git writes there by
temporary file and rename, and its gap is below.

### After each turn

`(drgnx-job-worktree-check REPO ID N BASE DONE)` asks whether `job/ID-N/work` still descends from BASE. It runs two
gits in the main repository, whose config the agent cannot write, each as a process of its own with the deadline
`drgnx-job-worktree-timeout`:
1. `for-each-ref` reads the branch. Its `%(symref)` must be empty and its object name 40 or 64 hex digits. A link in
   the ref directory (lstat) counts as no branch.
2. `merge-base --is-ancestor`.

DONE gets `t` and the commit checked (merge that commit, never the branch's name), `nil` (rewound, replaced, a
symbolic ref or a link, junk, no branch), or `(:error MSG)`. A timeout is a failure, never a pass. The ref file and
the objects are the agent's: a FIFO planted as one blocks git, never the hub. The check catches a rewound or replaced
branch. It is not a guard against a hostile agent: the objects it reads are writable.

### What it protects

- The main `.git/config`, `hooks/` and `info/` are read-only inside the sandbox. Through the worktree's own state
  (links, an operation in progress) the user's git outside could still write or run them. The scrub removes that
  state; see above for when.
- Every ref but its own branch.
- The hub's socket, `~`, the user's sockets, `work.db` and the environment, as in snapshot mode.
- The main checkout's untracked and uncommitted files: they are not mounted.

### What it cannot protect

- **The repository's objects.** `objects/` must be writable for commits. A writable directory lets the agent delete or
  overwrite existing object files and packs. That means **data loss for anything not pushed elsewhere**, or a corrupt
  repository. The agent can also add `objects/info/alternates` entries, or a `commit-graph`. They inject objects or
  ancestry, but run no code.
- **Reading the whole repository.** The agent sees all history, all branches, unreachable objects (a file staged then
  unstaged, a dropped stash) and the main `config`, including remote URLs. A token in a remote URL is visible to the
  model.
- **The worktree's git state while the agent lives.** A scrub at turn end can be followed by a new plant. Only the
  scrub after the sandbox has exited leaves the state clean.
- **A nested `.git`** the agent creates in a subdirectory of the folder is a repository with the agent's config. A
  gitlink in the agent's index at that path makes a plain `git status` at the folder's root run the nested
  repository's `core.fsmonitor`. The hub checks for one after each turn, as in snapshot mode.
- `git gc` of the user's while an agent runs can remove the branch's ref directory under it. The agent's next commit
  then fails to update its branch. `drgnx-job-worktree-prepare` makes the directory again at the next start.
- Objects of an `objects/info/alternates` outside `.git` are not mounted. Git inside cannot read them.

### Risks, row by row

Snapshot mode against worktree mode (spec §4b):

| Risk | Snapshot (default) | Worktree (opt-in) |
|---|---|---|
| Agent-written config or hooks run outside the sandbox | no: git never runs in the copy outside the sandbox | no once scrubbed: main config and hooks read-only, pointers pinned, the worktree's state scrubbed |
| Agent-planted git state (a rebase todo, links in the git dir) used by the user's git | n/a: no git runs in the copy outside | scrubbed at each turn end and after exit; VC kept out while the agent runs |
| Other branches, `job/ID`, `main` moved | no | no: only its own `job/ID-N/` ref directory is writable, and the scrub removes a `head-name` or `HEAD` naming another |
| Repository objects deleted or corrupted | no: its own copy | **yes**: data loss for anything unpushed |
| User's uncommitted or untracked files (`.env`) seen | no | no |
| Remote URLs and their tokens seen | no: not in the store | yes: the main config is readable |
| The reviewer influenced by the implementer's git config | no: a fresh snapshot | no: a fresh worktree of the tip, read-only; the shared config is read-only |
| User's own tools (magit, `git` in a shell) in the folder | unsafe: the folder's `.git` is the agent's; drgnx keeps VC out | safe once the task's agent has stopped and the hub has scrubbed its git state; while it runs, drgnx keeps VC out |
| Nested `.git` in a subdirectory | hub check and a card | hub check and a card |
| Branch visible in the main repository | after the bundle fetch | at once |
| `git worktree list` shows the task | no | yes |
| Disk and time to start | ≈ 0 extra disk with copy-on-write | ≈ 0: today's `worktree add` |
| Works on | btrfs, XFS, APFS (a shared clone elsewhere) | any filesystem; not reftable repositories |
