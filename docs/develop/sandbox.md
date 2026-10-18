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
