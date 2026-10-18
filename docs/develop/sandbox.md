# The job sandbox

A job agent runs shell commands, hooks and MCP servers as the user's uid. No token or command check can stop such a
process from reaching what the user can reach: the hub's socket (and with it the cards), the user's home, other
repositories, the Emacs server, D-Bus. So each job agent's **whole process tree** runs inside a boundary the kernel
enforces: bubblewrap on Linux, Seatbelt on macOS. The agent's command line is wrapped; everything it starts is inside.

This page describes `core/drgnx-sandbox.el`: the spec, what it refuses, and the bubblewrap command line it becomes.
The code is pure. It builds data and an argv and runs nothing; the tests assert the argv element by element.

## What is inside, and what is not

Default deny. Inside the sandbox exist only:

- the system's read-only roots: `/usr`, `/etc`, and where they exist `/opt`, `/nix`, `/gnu`, `/var/lib/flatpak`;
  `/bin`, `/lib`, `/lib64` and `/sbin` as links into `/usr` where the host's are links (merged `/usr`), else bound
  read-only (`drgnx-sandbox-system-read`);
- a fresh `/dev` and `/proc`, and empty `/tmp`, `/run` and `/var/tmp`;
- a **private home** at the user's `$HOME` path, so tools with absolute paths still work, but holding nothing of
  the user's;
- what the spec binds: toolchain roots read-only, the task's folder read-write, the session's socket directory at
  `/run/drgnx`, and the git mode's pins.

Not inside, as absent paths: the rest of `/home`, `/run/user`, `$XDG_RUNTIME_DIR` (the hub's socket, the Emacs
server, D-Bus, ssh-agent, gpg-agent, podman, the keyring), `/mnt`, `/media`, other jobs' folders, drgnx's data
directory (`work.db`). The environment holds only the spec's variables.

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
| `:run` | `OUTSIDE` | the session's socket dir, `--bind` at `/run/drgnx` |
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

- **A path that is not usable as it is:** relative, holding a NUL or a newline, or not its own true name. The last
  catches a spec built by hand with a link in it, and a directory swapped for a link after `drgnx-sandbox-spec`
  resolved it. File name handlers are off throughout: a TRAMP-looking name is a local path, never a connection.
- **A bind that would expose the user's things.** From `:read`, `:write`, `:binds`, `:home`, `:run` or `:tmp`, never
  `$HOME`, `/run/user`, `$XDG_RUNTIME_DIR`, the hub's socket directory (all its possible places), drgnx's data,
  state and config directories, the drgnx checkout or `/tmp/.X11-unix`, **nor any directory that holds one of
  them** (`/`, `/home`, `/run`, `~/.config`, …). Read-only counts too: a read of `~` is every key in it.
- **Anything inside a socket directory** (`/run/user`, the runtime dir, the hub's dir) except inside one session's
  own directory, `$XDG_RUNTIME_DIR/drgnx/s/SID/` (or `s/SID/` beside the hub's socket where there is no runtime
  dir: `drgnx-sandbox-sessions-dirs`). The sessions' directory itself is refused, since it holds every session.
- **A `:run`** that is not such a session directory; a `:sockets` entry outside `:run`; a `:profile-file` outside a
  session directory.
- **A source that does not exist** for `:write`, `:binds`, `:home` and `:run`. (`:read` and `:hide` entries that do
  not exist are left out of the argv.)
- **A malformed spec:** an unknown key (a typo would otherwise drop a rule silently), a value of the wrong shape, a
  `:net` other than `shared` or `isolated`, an `:env` name that is not a variable name, or one of
  `drgnx-sandbox-env-deny` (`SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, `DISPLAY`,
  `WAYLAND_DISPLAY`, `DRGNX_DATA_DIR`).

Inside the home is fine: a task folder in a repository under `~`, a toolchain root such as
`~/.local/share/mise/installs/node/20`, a private home under the state directory.

## The bubblewrap argv

`(drgnx-sandbox-bwrap-argv SPEC COMMAND)`. Every path is one argv element; nothing goes through a shell, so nothing
is quoted. All paths are absolute, so none can be read as an option.

```
bwrap --unshare-all [--share-net] --disable-userns --die-with-parent --new-session --clearenv
      --setenv NAME VALUE …                                  # the spec's :env, nothing else
      --ro-bind-try /usr /usr  --ro-bind-try /etc /etc  …   # the system's reads
      --symlink usr/bin /bin  …                              # where the host's /bin is a link
      --dev /dev --proc /proc --tmpfs /tmp --tmpfs /run --tmpfs /var/tmp
      --bind PRIVATE-HOME $HOME                              # :home
      --ro-bind-try TOOL TOOL …                              # :read
      --bind FOLDER FOLDER …                                 # :write
      --bind SESSION-DIR /run/drgnx                          # :run
      --ro-bind PIN PIN  --bind PIN PIN …                    # :binds, in order
      --ro-bind /dev/null SECRET-FILE  --tmpfs SECRET-DIR    # :hide
      --chdir FOLDER
      -- COMMAND…
```

Why each flag:

- **`--unshare-all`**: new user, pid, ipc, uts, cgroup, network and mount namespaces. The pid namespace hides the
  user's other processes (no `/proc/PID/environ` of the hub); the mount namespace is what makes paths absent.
- **`--share-net`** (phase 1, `:net shared`): the agent needs its model API and the gateway on the host's
  `127.0.0.1`. The known gap: abstract Unix sockets (X11's `@/tmp/.X11-unix/X0`) and services on the host's loopback
  stay reachable. Phase 2 (`:net isolated`) drops it and gives the agent a proxy instead.
- **`--disable-userns`**: nothing inside can build nested namespaces (a nested bwrap, rootless podman), so the outer
  sandbox stays the boundary.
- **`--die-with-parent`**: the sandbox ends with the hub's process; no orphaned agent keeps running.
- **`--new-session`**: a new session id, so the agent cannot push input into a terminal with `TIOCSTI`.
- **`--clearenv`**: the environment is empty, then the spec's `:env` is set. Nothing of the hub's environment
  passes: no `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, display or provider key.
- **`--tmpfs /run`**: `/run/user` (the user's runtime directory) is absent, even if a later rule binds something
  under `/run`. The session's own directory is bound at `/run/drgnx`, a path of its own.
- **The order**: the private home first, then reads and writes on top of it (a toolchain or a task folder under `~`
  shows at its path inside the private home), then the session dir, then the git pins, which must cover the
  folder's `.git`, then `:hide`, which must cover files inside the roots bound before it.

`(drgnx-sandbox-base-env)` is where a session's `:env` starts: `PATH`, `HOME`, `USER`, `LANG` and every `LC_*`
where set, `TERM=dumb`, `SHELL`, and `TMPDIR=/tmp`, from the calling Emacs. Nothing else, ever.

## The back ends

`(drgnx-sandbox-backend)` is `bwrap` on Linux when bubblewrap is on `exec-path`, `seatbelt` on macOS when
`sandbox-exec` is, else nil. `(drgnx-sandbox-wrap SPEC COMMAND)` picks the spec's `:backend` or that one:

- **Linux**: `drgnx-sandbox-bwrap-argv`.
- **macOS**: the SBPL profile (`drgnx-sandbox-sbpl`, `core/drgnx-sandbox-macos.el`) is written to `:profile-file`,
  mode 0600, as a new file, and the command line is `sandbox-exec -f FILE COMMAND…`.
- **Neither**: `drgnx-sandbox-refused`. A missing sandbox is never a silent fallback to the bare command.

## Limits

- **Resolution and mounting are two steps.** The spec's paths are resolved and checked when the argv is built;
  bubblewrap resolves them again when it mounts, a few milliseconds later, and follows links. A link swapped in
  between, at a path a running agent can write, would be followed. So a bind source must never be a path inside
  something a live agent can write (its task folder, its session directory) while a new sandbox is being started;
  sources the hub made itself, in directories only the hub writes, are safe.
- **Toolchains under `/run`** (NixOS's and Guix's `/run/current-system`) are hidden by `--tmpfs /run`. Their `PATH`
  entries do not resolve inside yet.
- The session's directory at `/run/drgnx` is writable from inside: the agent may remove its own sockets. That only
  cuts its own tools off.
