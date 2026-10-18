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
