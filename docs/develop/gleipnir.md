# Gleipnir: the sandbox

Gleipnir is the Rust sandbox in `runtime/crates/gleipnir` ([runtime.md](runtime.md#crate-names)). It runs a program
inside a boundary the kernel enforces: bubblewrap with Landlock and seccomp on Linux (the full tier), Landlock and
seccomp alone (the reduced tier), or Seatbelt on macOS. It is self-contained: the caller passes every path, name and
port, and nothing in gleipnir names a drgnx directory or reads a drgnx variable. Nothing in drgnx uses it yet; job
agents run as before until phase 6. The Lisp libraries on main are described in [sandbox.md](sandbox.md).

Each section below is written by the task named in it.

## Using it

One API runs a command in every backend (`gleipnir::backend`, re-exported at the crate root):

1. `Sandbox::detect(tier, helper, bwrap_override)` picks the backend for a `Tier` (`Full` or `Reduced`):
   - Linux, full: bwrap ≥ 0.12.0 from a root-owned path ([The bubblewrap argv](#the-bubblewrap-argv)). Without one
     the full tier is **refused; it never falls back to the reduced tier**, which only the caller chooses (phase 6:
     a job's opt-in). `bwrap_override` is passed only by Ratatoskr's `test-hooks` code and is held to the same
     root-owned rule.
   - Linux, reduced: the inner helper alone. Both Linux tiers also need a seccomp filter for this architecture.
   - macOS: Seatbelt (a root-owned `/usr/bin/sandbox-exec`), whatever the tier. `Sandbox::with_mac(MacContext)`
     gives it the developer dir; gleipnir reads none itself.
   - Anything else (Android among them): refused (`BackendKind::None`).

   `helper` is an `InnerCommand`: the helper binary's path outside, its `inner_args` (`sandbox-inner`) and its
   `relay_args` (`relay`).
2. `gleipnir::validate(spec, &ctx, sandbox.target()?)` checks the spec for that backend's `Target`.
3. `sandbox.prepare(valid, command)` returns a `Prepared { invocation, status, layers }`. Nothing is spawned; the
   full tier's sources are opened here, so what was checked is what gets mounted. `Invocation` is the program, its
   args, its exact environment, its cwd, the fds to pass at fixed numbers, and `new_session`:

   | Backend | Program and args | Env | fds | `new_session` |
   |---|---|---|---|---|
   | bwrap | bwrap's argv, ending `-- /run/gleipnir/helper sandbox-inner --spec-fd 3 -- CMD…` | none | 3 the inner spec (sealed memfd), 4 the status pipe's write end, 5… the binds | no (bwrap's `--new-session`) |
   | reduced | `HELPER sandbox-inner --spec-fd 3 -- CMD…` | none | 3, 4 | **yes**: the helper calls `setsid()` itself, which a process-group leader cannot |
   | Seatbelt | `sandbox-exec -f PROFILE CMD…` or `-p TEXT CMD…` | the spec's | none | no |

   The program's environment travels in the inner spec, never in argv. The relay is `/run/gleipnir/helper relay …`
   under bwrap and the helper's own path in the reduced tier. `status` is the read end of the status pipe; its only
   write end is in `invocation.fds`, so it moves into the spawn and is gone once the spawn returns, and EOF means the
   helper (or bwrap before it) failed (review S6). Seatbelt has no status line: `layers` is
   `LayersReport::seatbelt()` at once.
4. The caller spawns the invocation from one long-lived thread (Ratatoskr: `draugr::spawn_pinned`, with `pass_fds`
   and, for `new_session`, `setsid` before exec instead of a process group of its own) and reads
   `gleipnir::read_status(status, stderr_tail, deadline)`. On a refusal or a timeout it kills the process group.

With the `test-hooks` feature, `prepare` takes a third argument, `TestHooks { landlock_omit, abi_cap }`, which goes
into the inner spec (Task 15's rows `landlock-layer-2` and `landlock-below-required-refused`). A release build has
neither the type nor the parameter.

**What the reduced tier refuses besides.** Without a mount namespace nothing can be laid over a file, and Landlock
only ever adds rights, so a `hide` entry inside a root the reduced tier grants (a read, write or session root, a
system root, the helper) is refused (`Malformed`), never left readable. A hide outside every granted root is
unreachable anyway and passes.

**Relay ports.** `backend::relay_ports(tier, wanted)` gives one session's ports. The full tier's network namespace
is the session's own, so `wanted` (3128, 3129) is used as given. The reduced tier's relay binds on the host's
loopback, where another session's relay may hold the same port, so it gets free ports from the kernel, held all at
once so they differ from each other and from every port bound now (GL-T8-3). A port taken by someone else between
the call and the relay's bind fails that run; it is never shared. The program's `HTTPS_PROXY` must name the ports
this returns.

### Ratatoskr's side

`drgnx-ratatoskr/src/sandbox.rs`:

- `context(env)` is the `Context`, every path taken to its true name on disk (a link resolved; a path that does
  not exist keeps the true name of its deepest existing ancestor):
  - `closed`: drgnx's data, config and state dirs; every socket dir a hub may use (`<runtime>/drgnx`,
    `<state>/hub`, `<tmp>/drgnx-hub-UID`); `DRGNX_DIR`; Emacs's server dirs (`<tmp>/emacsUID`, `/tmp/emacsUID`,
    `<runtime>/emacs`); and the helper binary's own dir (review M12), so no write bind can replace the helper;
  - `user_sockets`: `SSH_AUTH_SOCK` and the D-Bus session bus's `unix:path=` (and `runtime=yes`);
  - `run_parents`: `runstav::paths::session_parents`, `<socket dir>/s` and the fallback `<tmp>/drgnx-hub-UID/s`
    (a session's dir is `s/SID/`, never the backend's `hub-HASH.d/`); `program_dirs`: the absolute `PATH` entries;
    `env_deny`: `DRGNX_DATA_DIR DRGNX_CONFIG_DIR DRGNX_AGENT DRGNX_HUB_SERVE_SOCKET DRGNX_HUB_PARENT_PID
    DRGNX_HUB_SERVE_SECRET`.
- `helper()` is this binary (its path resolved at start) with `sandbox-inner` and `relay`.
- `to_draugr(invocation)` is the `draugr::Spec` (stdin `/dev/null`, the fds as `PassFd`s, `new_session`).
- `ratatoskr relay --parent-pid PID [--ready-fd N] PORT=SOCKET…` runs [the relay](#the-relay-task-11).
- `ratatoskr sandbox check` and the doctor's `sandbox` section run [the check](#the-check); `sandbox::run_probe`
  spawns its probe, and `sandbox::check_blocking` gives it a runtime of its own.
- `ratatoskr sandbox run --spec FILE --result FILE [--tier full|reduced] [--bwrap PATH] [--pause-before-spawn FIFO]
  [--landlock-omit PATH]… [--landlock-abi-cap N] -- CMD…` exists only with `test-hooks`, for the escape rows. It
  detects, validates the spec against `context`, prepares, and with `--pause-before-spawn` writes `opened` to the
  FIFO once the sources are open and waits for a line back. It spawns through `draugr::spawn_pinned` (stdin
  `/dev/null`, the child's stdout passed through, its stderr's tail written once it has exited), reads the status
  line within its deadline, waits, and writes `{"refused": null|{rule, path, message}, "layers": …, "exit": N}` to
  `--result`. A refusal exits 3, otherwise the child's code; rows judge by the result file alone, since a child may
  exit 3 itself.

## The spec

`gleipnir::Spec` (`src/spec.rs`) says what a sandboxed program may see, as plain data. Its JSON form refuses unknown
keys at every level (a misspelt `hide` is an error, never "nothing hidden"); a missing list is empty; `chdir`, `net`
and `layers` are required. A *source* is a path on the host, given as its true name; a *dest* is where a bind is
seen inside.

| Field | Type | What |
|---|---|---|
| `read` | paths | read-only at the same path inside; one that does not exist is dropped after validation |
| `write` | paths | read-write at the same path inside; must exist |
| `hide` | paths | hidden inside (a file reads empty, a directory is empty); one that does not exist is dropped |
| `sockets` | paths | the Unix sockets the program may connect to; each lies inside `run`'s source |
| `binds` | `{mode, source, dest}` | `mode` is `"ro"` or `"rw"`; the dest may differ from the source only under bwrap |
| `home` | bind or absent | the program's home, bound with its own mode (a home asked `ro` stays read-only) |
| `run` | bind or absent | the session's dir: one session's socket dir, always `ro` |
| `env` | `[[name, value], …]` | the program's whole environment; it travels in the inner spec over a sealed memfd, never in argv |
| `chdir` | path | the working directory, as a path inside |
| `net` | `"shared"` or `{"isolated": {"relay": [{port, socket}], "mac_tcp_ports": [port]}}` | Linux isolation is a new network namespace plus the relay (loopback port inside → Unix socket); macOS allows only `localhost` on `mac_tcp_ports` |
| `tmp` | path or absent | the temporary directory; required by the reduced tier, which has no private `/tmp` |
| `layers` | `{landlock_min_abi}` | the lowest Landlock ABI the run accepts; seccomp is not a field (always on) |
| `extra_tcp_ports` | ports | TCP ports besides the relay's (Landlock's port rule, never counted as isolation); the full tier only, the reduced tier grants none |

`gleipnir::validate::validate(spec, &ctx, target)` checks a spec for one `Target` (`LinuxBwrap`, `LinuxReduced`,
`Macos`) against a `Context` and returns a `ValidSpec` or a `Refusal { rule, path, message }`. Only a `ValidSpec`
reaches a backend: it is not `Deserialize`, has no mutable access, and only `validate.rs` can make one (its
constructor takes a token whose field is private to that file). The `Context` holds the caller's facts, all true
names: `home`, `closed` and `open_inside_closed`, `user_sockets`, `run_parents` (where session dirs are made),
`program_dirs` (the caller's `PATH`) and `env_deny`. Gleipnir names none of them itself; a context path that is not
absolute and canonical refuses the spec (`Malformed`), so a sloppy context never weakens a check. Context paths are
looked up too (GL-T2-2): one that exists must be its own true name, and one that does not must have a true-named
deepest existing ancestor, as a spec's own paths must; a home given through a link is `Malformed`.

## What is refused

The rules apply in this order, each over the whole spec, and the first that applies wins (`validate::Rule`). They
port the parked Lisp rules (`drgnx-sandbox-validate`). On macOS, path comparisons ignore case (APFS does), which can
only refuse more.

1. **`NotUtf8`, `NotCanonical`.** Every path is UTF-8, absolute, free of NUL and newline, and has no `//`, no `.` or
   `..` component and no trailing slash: otherwise a prefix check can be talked past. Every host path (the sources,
   `hide`, `sockets`, and on the targets without a mount namespace also `chdir`, the dests and the relay sockets)
   equals its `canonicalize`, so a link anywhere in it is refused (Silverblue's `/home` → `/var/home` included: the
   caller passes the true name). For a path that does not exist, its deepest existing ancestor must be its own true
   name, since a link above a missing tail would widen every check below. A dest under bwrap is a place in bwrap's
   new root, not the host's, so only its form is checked here; links on the dest side are the argv's concern.
2. **`ExposesUser`.** No source (`read`, `write`, `binds`, `home`, `run`, `tmp`) is or holds the home, a user's
   socket, a `closed` entry or a system one (`/proc`, `/sys`, `/dev`, `/run/user`, `/tmp/.X11-unix`,
   `/tmp/.ICE-unix`). Read-only counts: a read of `~` is every key in it.
3. **`Closed`.** No source lies inside a closed entry, unless it lies strictly inside an `open_inside_closed` entry
   that is itself inside that closed entry: only this job's dir opens the state dir, never the dir itself, its
   neighbours or another job's (SB-T3-6). The system dirs open for nothing. `run`, when it is one session's dir, is
   left to rule 5.
4. **`SecretDir`.** No source is, holds or lies inside a credential dir of the home (`.ssh`, `.gnupg`, `.aws`,
   `.config/gh`, `.netrc`, browser profiles, …; macOS adds `Library/Keychains`, `Library/Cookies`, `Library/Mail`
   and the rest; SB-T4-2). A read of `~/.config` is refused, because it holds `~/.config/gh`.
5. **`SessionDir`.** `run`'s source is a direct child of a run parent: one session's dir. No other source is, holds
   or lies inside a run parent, not even a sub-path of `run` (a live agent could swap it for a link). Every
   `sockets` entry lies inside `run`'s source.
6. **`ProgramDir`.** No writable source (`write`, `rw` binds, `home`, `tmp`) is or holds a dir of the caller's
   `PATH`: the agent could plant a `bwrap` or a `git` there, and the caller would run it unconfined.
7. **`Missing`.** `write`, `binds`, `home` and `run` sources exist. (`read` and `hide` entries that do not exist pass
   the rules like the others and are then dropped; `tmp` may be made later.)
8. **`Malformed`.** An env name that is not `[A-Za-z_][A-Za-z0-9_]*`, or a value with a NUL; a port that is 0;
   `landlock_min_abi` above 9; **the floors**: `LinuxBwrap` below 1, `LinuxReduced` below 9 (only ABI 9 controls
   connecting to pathname Unix sockets, and without a mount namespace ABI 6–8 would leave the hub socket, D-Bus,
   ssh-agent and the Emacs server reachable), and `Macos` asking for any Landlock ABI; `isolated` without a relay on
   Linux; `mac_tcp_ports` on Linux; a `LinuxReduced` spec without `tmp`; a `run` asked read-write.
9. **`EnvDenied`.** An env name in `BASE_ENV_DENY` (`SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`,
   `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `GPG_AGENT_INFO`) or in the context's `env_deny`.
10. **`DestDiffers`.** For `LinuxReduced` and `Macos` (no mount namespace) every bind's, the home's and `run`'s dest
    equals its source: a path is seen where it is.
11. **`ReservedDest`.** Nothing is mounted at, above or under `/run/gleipnir/helper`, a `RESERVED_DESTS` entry
    (`/run/gleipnir`) or `run`'s dest: not a bind's or the home's dest, not a `read`, `write`, `hide` or `tmp` path
    (those are mounted at their own path), and `run`'s dest not over the helper either. A bind over the helper would
    make bwrap exec a program that applies neither Landlock nor seccomp.

Apart from rule 11, a dest may be any canonical absolute path: only sources expose anything.

## Platforms

The platform boundary is `gleipnir::backend` (`src/backend/mod.rs` holds the table) plus the three Linux layer
modules. `BackendKind` is `Bwrap`, `Reduced`, `Seatbelt` or `None`; `Sandbox::detect` picks one
([Using it](#using-it)).

| What | Where | Gate | Android |
|---|---|---|---|
| spec, validation, bwrap argv, SBPL text, hosts, relay, proxy | `spec`, `validate`, `bwrap`, `sbpl`, `net` | none: pure, built and tested on every target (the goldens run on Linux) | builds; nothing runs it |
| bwrap, the reduced tier | `backend::linux` | `target_os = "linux"` | no backend; apps get no user namespaces; fails closed |
| inner helper, Landlock, seccomp | `inner`, `landlock`, `seccomp` | body `target_os = "linux"`, an `Unsupported` stub elsewhere | the stub |
| Seatbelt | `backend::macos` | `target_os = "macos"` (and `test`, so its tests run on Linux) | not applicable |
| anything else | `backend::none` | always | a refusal |

`landlock` and `seccompiler` are Linux-only dependencies. Every `cfg(target_os)` names its Android stance in a
comment, and every chain ends in `BackendKind::None` or an `Unsupported` refusal, never an unconfined run. The rules
in `validate` follow the spec's `Target`, not the host, so the macOS rules are tested on Linux.

## Toolchain roots

`gleipnir::toolchain` finds the read-only roots under the home that the `PATH` entries need, so an agent can run
the user's compilers without binding `~`. `roots(path_dirs, home, mise_data_dir, exclude)` returns `Roots { dirs,
files }`, sorted true names. `path_dirs` must be absolute (a relative entry is skipped, and the spec validator
refuses relative paths anyway), as must the home and the exclude entries (drgnx's checkout and data dir).

A known layout gives its install root, matched on whole path components:

| Layout | Root |
|---|---|
| mise `DATA/installs/TOOL/VER/…` (`DATA` is `mise_data_dir`, else `~/.local/share/mise`) | `…/installs/TOOL/VER` |
| `~/.cargo/bin` | itself, and `~/.rustup/toolchains` where it exists (cargo's proxies run them) |
| `~/.rustup/toolchains/…` | `~/.rustup/toolchains` |
| `~/go/bin` | itself |
| `~/.nvm/versions/node/V/…` | `…/node/V` |
| npm's prefix `~/.npm-global/…`; `~/.local/lib/node_modules/PKG/…` | the prefix; that package |
| pipx `~/.local/share/pipx/venvs/APP/…`, `~/.local/pipx/venvs/APP/…` | the venv |
| uv `~/.local/share/uv/tools/APP/…`, `~/.local/share/uv/python/V/…` | the tool's venv, the Python |
| `~/.local/share/claude/versions/…` | `~/.local/share/claude/versions` |

- Each `PATH` dir inside the home, links resolved, gives its layout's root, else the dir itself.
- Each link inside it gives the root of the layout it leads into. A link into no layout gives its **target file
  alone**, when that is an executable regular file, not directly in `~`, outside the config areas, with a name that
  is not a `SECRET_FILES` entry. A link to a directory in no layout gives nothing.
- A link (or a `PATH` dir) into `exclude` gives nothing.
- Never a root: the home or a parent of it, `~/.local` itself, anything inside `SECRET_DIRS`; a plain dir that is
  or lies in `~/.config`, `~/.local/share`, `~/.local/state` or `~/.cache` (only a layout root may).
- A root inside another is left to the outer one; dirs outside the home are the system's reads already.

Bin dirs rather than whole tool homes keep the credentials beside them out (`~/.cargo/credentials.toml` is not in
`~/.cargo/bin`). `hide_list(&roots)` is the `hide` list for the ones inside a root, as true names:

- each existing `root/<name>` for `SECRET_FILES` (`.npmrc`, `etc/npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`,
  `.netrc`, `.git-credentials`, `.env`, `credentials`, `credentials.toml`, `credentials.json`, `auth.json`);
- every file or link named like one of the dot-names among them (`.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`,
  `.netrc`, `.git-credentials`, `.env`) down to `SCAN_DEPTH` = 3 below the root (`root/x`, `root/a/x`,
  `root/a/b/x`), walking no link (GL-T3-3). The scan reads each directory down to `root/a/b` once: measured on a
  developer machine, 19 directories and 78 entries for `~/.rustup/toolchains`, and 86 and 534 for the largest mise
  install there (a JDK); three walks of the Rust root took 10 ms in all, with the cache warm. The plain
  names count only at their fixed place: `auth.json` or `credentials` deep in a package is that package's data,
  and hiding it would break the package. Deeper than 3 lies package content (`lib/node_modules/PKG/…`), whose
  dotfiles are the package author's, not the user's; the places a user's own credentials go in a toolchain root
  (`etc/npmrc`, a root-level `.npmrc`) are fixed and shallow.

The module reads paths and metadata only and has no `cfg` gate: it builds the same on every unix target, Android
included (which has no backend to use it). `readable(roots, &ctx, target)` runs every root through `validate`'s
`read` rules, as a spec's lone `read` entry, and drops each one refused or gone (GL-T3-1); the caller passes the
roots it returns. In the reduced tier a hide cannot be honoured inside a granted root ([Using it](#using-it)), so
there a root holding a credential file is refused at `prepare`; phase 6 leaves such a root out of a reduced-tier
spec.

## The bubblewrap argv

The full tier runs bubblewrap, which builds the namespaces and the new root, then starts the inner helper (the
`ratatoskr` binary, bound at `/run/gleipnir/helper`), which applies Landlock and seccomp and execs the program. Three
steps (Task 7):

- `backend::linux::bwrap::find()` picks bwrap from `/usr/bin/bwrap`, `/bin/bwrap` and `/usr/local/bin/bwrap`
  (`find_in` takes the list), never through `PATH`. The first one only root can change (`eitri::trusted_program`:
  root-owned, not group- or world-writable, in root-owned directories, no link in its path) is run as `--version`,
  with an empty environment and a 2 s deadline. Its answer must be exactly `bubblewrap X.Y.Z`, at or above
  `bwrap::FLOOR` (0.12.0); anything else, a failing exit or no answer in time is refused (`Malformed`).
- `backend::linux::bwrap::open_sources(spec, helper)` opens every source of a spec validated for `LinuxBwrap`, and
  the helper, with `eitri::open_path`: no link is followed in any component, and the fd that was checked is the one
  that gets mounted. The home and `run` must be directories and the helper a regular file; `read`, `write` and
  `binds` may be either. A link met here (swapped in after validation) is `NotCanonical`, a missing source
  `Missing`, a kind mismatch `Malformed`. Each `hide` entry is lstat'ed the same way, for its kind. It also records
  the host's layout: which of `/bin /lib /lib64 /sbin` are links, and where `/etc/resolv.conf` leads.
- `bwrap::argv(spec, opened, command)` is pure (built and tested on every target). It returns bwrap's arguments and
  the fds to pass, each with its number inside: 3 is the inner spec (a sealed memfd), 4 the status pipe (both the
  caller's, Task 8), and the binds from 5 upward in argv order, the helper's last.

The argv, in this order (`argv_golden_shared` and `argv_golden_isolated` pin it):

```
--unshare-all --unshare-user [--share-net] --disable-userns --die-with-parent --new-session --clearenv
--ro-bind /usr /usr
--ro-bind-try /etc /etc  (and /opt /nix /gnu /var/lib/flatpak)
--symlink usr/bin /bin   (where the host's /bin is a link; else --ro-bind-try /bin /bin; also lib lib64 sbin)
--dev /dev --proc /proc --tmpfs /tmp --tmpfs /run --tmpfs /var/tmp
--ro-bind-try RESOLVER RESOLVER                  where /etc/resolv.conf leads under /run
--bind-fd 5 HOME-DEST                            the home (--ro-bind-fd when its mode is ro)
--ro-bind-fd N READ   --bind-fd N WRITE          at their own paths
--ro-bind-fd N RUN-DEST                          the session dir, always read-only
--ro-bind-fd N DEST  /  --bind-fd N DEST         binds, in order, each with its mode
--ro-bind /dev/null FILE  /  --tmpfs DIR         hide
--ro-bind-fd N /run/gleipnir/helper              the helper, last
--chdir DIR -- /run/gleipnir/helper INNER-ARGS --spec-fd 3 -- COMMAND…
```

Why each part:

- **`--unshare-all`**: new pid, ipc, uts, cgroup, network and mount namespaces. The pid namespace hides the user's
  other processes (no `/proc/PID/environ` of the hub); the mount namespace is what makes paths absent.
- **`--unshare-user`**: the user namespace for certain (`--unshare-all` only tries). `--disable-userns` needs it.
- **`--share-net`**, only for `Net::Shared`. Under `Net::Isolated` the program has its own empty network namespace and
  reaches the outside only through the relay (loopback ports inside → Unix sockets in `run`).
- **`--disable-userns`**: nothing inside can make nested namespaces (a nested bwrap, rootless podman), so this
  sandbox stays the boundary.
- **`--die-with-parent`**: the sandbox ends when the process that started it ends. That is the forking thread, so
  sandboxed spawns go through draugr's pinned spawner thread (Task 6).
- **`--new-session`**: a new session id, so no `TIOCSTI` into the caller's terminal (seccomp refuses `TIOCSTI` too).
- **`--clearenv` and never `--setenv`**: the environment starts empty, and the program's environment travels in the
  inner spec over fd 3, so no secret is ever in argv (where `/proc/PID/cmdline` would show it).
- **No `--cap-drop ALL`**: in an unprivileged user namespace the process has no capabilities, and the helper sets
  `no_new_privs`.
- **The system's reads by path**: `/usr` and the rest are root-owned, so a path cannot be redirected by the agent.
  On a merged-/usr host `/bin` and friends are links into `/usr`, recreated as the same links inside.
- **`--tmpfs /run`**: `/run/user` (the user's runtime dir: D-Bus, the ssh agent, the hub's sockets) is absent. The
  resolver's file is bound back on top of it alone, or `/etc/resolv.conf` (a link to systemd-resolved's stub on
  Fedora and Ubuntu) would dangle. Only a file under `/run` outside `/run/user` and `/run/gleipnir` is bound.
- **Every source of the spec by fd** (`--bind-fd`, `--ro-bind-fd`; bwrap ≥ 0.10). A source given by path is resolved
  by bwrap later, when an agent may have swapped a link into it; an fd is what was checked. This is Flatpak's
  CVE-2024-42472 pattern, whose full fix needed exactly these flags.
- **Each bind keeps its mode, and none is widened**: a home asked `ro` is bound read-only, `run` is read-only even if a
  spec that skipped validation says `rw`, and reads are read-only.
- **The order of the spec's binds**: the home first, then reads and writes on top of it (a task folder under the home
  shows at its path), then the session dir, then the binds, which must cover what came before (a git pin over a
  folder's `.git`), then the hides, which must cover files inside everything bound before them. A `read` inside a
  `write` is seen read-write, as the write grants (Landlock agrees: the write is a write root).
- **Hides follow the binds**: a hide is covered at its own path (where a read, a write or a system tree shows it) and,
  for every bind or home whose dest differs from its source and that holds it, at the same place under that dest. A
  directory gets an empty tmpfs (Landlock does not let the program write to it), anything else `/dev/null`.
- **The helper last** (review S1): no later mount can cover it, and validation's rule 11 also keeps every dest off
  `/run/gleipnir` and `run`'s dest. A bind over the helper would make bwrap exec a program that applies neither
  Landlock nor seccomp.
- **The spec's `tmp` is not bound**: under bwrap `/tmp` is a private tmpfs (and a Landlock write root). `tmp` is the
  reduced tier's temporary directory.

**The floor: bubblewrap ≥ 0.12.0.** 0.12.0 fixes CVE-2026-87766 (GHSA-pxhw-h44j-8pfx, high): a link met through
`/oldroot` while bwrap sets up its mounts let a sandbox write files outside it. Its own example is this sandbox's case:
binding an agent-written folder and making mount points under it. Fedora 44 ships 0.12.0; Ubuntu 26.04's 0.11.1
dropped the backported fix again (2026-09-17), so it is refused there, with the fix text of the check (Task 12).
Fd binds do not replace the floor: the dest side of a mount (a link inside a bound folder) is bwrap's to resolve, and
0.12.0 does it with `openat2(RESOLVE_IN_ROOT)`.

There is no unit test that runs a real bwrap (review S15): containers skip it. The escape rows `any/works`,
`bind-fd-link-swap` and `dest-link-stays-inside` (Task 15) run the argv on a real bwrap on the VM.

## The inner helper

`gleipnir::inner` (Task 8). The helper is the `ratatoskr` binary itself: `ratatoskr sandbox-inner --spec-fd 3 --
CMD…`. bwrap runs it as `/run/gleipnir/helper` (the full tier); the reduced tier runs it directly. It runs between
the namespace setup and the program, and it is the only code that applies Landlock and seccomp. `main` dispatches it
before any thread or tokio runtime exists.

**Its input.** An `InnerSpec` (JSON, `deny_unknown_fields`) on a memfd at fd 3, made by `spec_memfd` and sealed
against every change (`F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL`), at most 1 MiB. The helper refuses
an fd that is not sealed so. The program's environment travels here, never in argv.

| Field | What |
|---|---|
| `version` | 1 |
| `env` | the program's whole environment, exactly |
| `chdir` | where the program starts |
| `landlock` | the `LandlockPlan`; never optional (the floors are ABI ≥ 1 and ≥ 9). seccomp has no field: it is always on |
| `new_session` | `setsid()` before Landlock; true for the reduced tier (no bwrap `--new-session` there), whose spec is refused without it |
| `relay` | `{argv, ready_timeout_ms}` (5000), or absent |
| `landlock_omit`, `abi_cap` | only with gleipnir's `test-hooks` feature (the escape rows); a release build refuses them as unknown fields |

**The order** (pinned):

- **1.** Read the spec from fd 3 and close it.
- **2.** Assert one thread (`/proc/self/status`), else fail. Landlock restricts the calling thread only.
- **3.** `PR_SET_NO_NEW_PRIVS`; `PR_SET_PDEATHSIG` SIGKILL, then fail if the parent changed since the helper started.
  The parent is bwrap, or draugr's pinned spawner thread: the death signal fires when the *forking thread* exits.
  Grandchildren do not inherit it, so the reduced tier is ended by killing its process group.
- **3a.** `setsid()` when `new_session`. A helper its spawner already made a session leader is accepted; one that
  leads only a process group (`setpgid`) cannot start a session and is refused. **The reduced tier must be spawned
  with `setsid` before exec**, which also makes its pid the group's, for the kill.
- **4.** Landlock `restrict(plan, abi_cap)`.
- **5.** seccomp: `install(compile_for(native(), plan.tier))`; the reduced tier's filter adds its socket rules.
- **6.** The relay, if any: forked under both layers, exec'd with an empty environment, stdin and stdout on
  `/dev/null`, its ready pipe at fd 3 and no other fd above 2. The helper waits for exactly `ready\n` within the
  timeout; a relay that exits first, says something else or is late fails the run (and is killed). The relay's parent
  is the helper, which appends `--parent-pid` and its own pid to the relay's argv: the relay refuses to start under
  any other parent ([The relay](#the-relay-task-11)).
  Then, when the plan has `tcp_bind_ports` (the reduced tier), one more Landlock layer refuses every TCP bind: the
  relay bound its ports under the first layer, and the program gets none.
- **7.** One status line on fd 4, then fd 4 is closed.
- **8.** Close every fd ≥ 3 (`close_range`).
- **9.** `chdir`; `execve` of `CMD[0]` with exactly the spec's environment. A program with a `/` runs as given; a bare
  name is searched in the spec environment's `PATH` (absolute entries only).

A failure in steps 1–7 writes `{"ok":false,"error":"…"}` to fd 4 and exits 125, and nothing is exec'd. Not found
exits 127, found but not runnable 126; a `chdir` that fails after the status line exits 125 with a stderr line
only. The status line of a run is
`{"ok":true,"landlock_abi":N,"landlock":"enforced","seccomp":true,"no_new_privs":true,"new_session":B,"relay":B,"seatbelt":false}`
(`seatbelt` is true only in `LayersReport::seatbelt()`, the macOS report, which no helper sends).
On other systems `sandbox-inner` exits 125 with "the inner helper is Linux only".

**Reading the status.** `status_pipe()` gives the parent's read end and the write end the spawn moves to fd 4.
`read_status(read_end, stderr_tail, deadline)` returns the `LayersReport`, or a `Refusal` with `Rule::Setup`:
- `ok: false` → "sandbox setup failed: " and the helper's error;
- EOF with no line (the helper, or bwrap before it, failed) → "sandbox setup failed: " and the first stderr line;
- a line that claims less than Landlock enforced, seccomp and `no_new_privs` → refused;
- past the deadline (`status_deadline`: 5 s plus the relay's ready timeout) → "sandbox setup timed out", and the
  caller kills the process group.

EOF needs every write end closed: bwrap's monitor closes its copy, and draugr's `spawn` drops the hub's.

**The reduced run path** (`backend::linux::reduced`). `inner_spec(spec, helper, relay_args)` takes a `LinuxReduced`
`ValidSpec`: the reduced plan, the spec's environment and `chdir`, a new session, and under `Net::Isolated` the relay
`helper relay_args… --ready-fd 3 PORT=SOCK…`. The relay is exec'd under Landlock, so the helper file joins the read
roots then. `prepare(inner, helper, inner_args, command)` gives the program (the helper), its argv (`inner_args…
--spec-fd 3 -- command…`), the fds (the spec at 3, the status write end at 4) and the status read end.
`Sandbox::prepare` turns it into an `Invocation` with an empty environment and `new_session` set.

Tests: `inner::tests` (the arguments, the thread check in a threaded process, the status lines, the sealed memfd,
`read_status` on EOF, in pieces and at its deadline, the test-hook fields), `backend::linux::reduced::tests`, and
`runtime/crates/drgnx-ratatoskr/tests/sandbox_inner.rs`, which runs the built `ratatoskr` as the helper without
bwrap: the layers reported, exactly the spec's environment, no fd above 2, `NoNewPrivs` and one more seccomp filter,
a floor refusal, the relay ready before the program (and three relay failures), an unsealed spec, the new session,
a seccomp or Landlock install that an outer filter makes fail, and the reduced run end to end (ABI 9).

## Landlock

`gleipnir::landlock` (Task 5). Landlock is the second layer, after the mount namespace (full tier) or in its place
(reduced tier). It works in three pure steps and one Linux-only one:

- `plan_for(spec, tier)` gives a `LandlockPlan`: the read roots, write roots, device files that may be written, the
  roots under which pathname Unix sockets may be connected to, and the TCP ports (or none). Its `min_abi` is the
  spec's `layers.landlock_min_abi`, raised to the tier's floor. The plan travels in the inner spec.
- `rules_for_abi(plan, abi)` gives the `RulesetDesc` for one ABI: what is handled (denied unless allowed) and what is
  allowed where. It asks only for rights that ABI has. An ABI above 9 gets the ABI-9 set.
- `gate(plan, kernel, cap)` is the floor. The effective ABI is `min(kernel_abi(), abi_cap, 9)`. It is refused when
  it is below the plan's `min_abi` or below the tier's floor, whatever the plan says.
- `restrict(plan, abi_cap)` runs the gate first, so a refusal restricts nothing. Then it applies the description in
  `CompatLevel::HardRequirement` mode, never `BestEffort`, and returns `Applied { abi }`. Because the description
  asks only for what the ABI has, the hard requirement decides nothing on a correct kernel; it is a backstop. A
  rule set that is not fully enforced is refused too. `abi_cap` exists for the escape rows (the `test-hooks`
  feature) and is `None` otherwise.

**The two tiers.**

| | Full (under bwrap) | Reduced (no namespaces) |
|---|---|---|
| Paths | inside paths (bind dests) | the host's own (sources) |
| Floor | ABI ≥ 1 | ABI ≥ 9, plus seccomp |
| Read and execute | `/` | `/usr /etc /opt /nix /gnu /bin /lib /lib64 /sbin /proc`, `/dev/{null,zero,full,random,urandom,tty}`, and the spec's read, write, bind, home, run and tmp sources |
| Write | `write` entries, rw binds, an rw home, `/tmp`, `/var/tmp`, `/dev/shm`, `/dev/pts` (bwrap's private mounts) | `write` entries, rw binds, an rw home, the spec's `tmp`. Never the host's `/tmp`, `/var/tmp` or `/dev/shm`: without a mount namespace they are the user's own |
| Device files written | `/dev/{null,zero,full,tty,ptmx}` | `/dev/{null,zero,full}` |
| Unix connect (ABI 9) | the `run` dest | the `run` source |
| TCP connect (ABI 4) | relay ports and `extra_tcp_ports` under `Net::Isolated`; not handled under `Net::Shared` | handled: only the relay ports (`Net::Isolated`); none under `Net::Shared`. Never `extra_tcp_ports` |
| TCP bind (ABI 4) | not handled: the network namespace isolates a server inside | handled: only the relay ports, for the relay; the helper then adds a layer that refuses every bind (`forbid_tcp_bind`) |

**Per ABI.**

| ABI | Adds | How it is used |
|---|---|---|
| 1 | the first fs rights | all handled. Read and execute on the read roots. Every write right on the write roots except `make_char` and `make_block`: those are handled and never granted, since an agent has no use for device nodes. `write_file` on the device files |
| 2 | `refer` | handled; granted on the write roots |
| 3 | `truncate` | the same. `O_TRUNC` on a device ignores it, so `> /dev/null` works |
| 4 | TCP bind and connect | each handled only when the plan has ports for it: `connect_tcp` in the full tier under `Net::Isolated`, both in the reduced tier. The full tier never handles `bind_tcp`, since servers inside its network namespace must work |
| 5 | `ioctl_dev` | never handled: ioctls on ttys and pipes must work, and seccomp blocks TIOCSTI and TIOCLINUX |
| 6 | scopes | abstract Unix sockets and signals scoped: nothing made outside the sandbox can be reached or signalled |
| 7, 8 | logging, thread sync | nothing used here |
| 9 | `resolve_unix` | handled; granted only on the connect roots. A server the sandboxed program makes itself stays reachable (the kernel's same-domain rule) |
| 10, 11 | UDP rules, a restrict flag | the `landlock` crate stops at 9, so a newer kernel runs the ABI-9 set |

**Opening the rule paths.** Each path is opened `O_PATH` with `openat2(RESOLVE_NO_SYMLINKS)`, so no link anywhere
in it is followed. A missing path or a link is skipped. That only narrows what is allowed: `/bin` → `usr/bin` is
covered by `/usr`, and bwrap's `/dev/ptmx` → `pts/ptmx` by `/dev/pts`. Any other open error refuses. A path that is
not a directory gets only the rights that apply to files.

**What Landlock adds under bwrap.** Under bwrap it is defence in depth only. The mount namespace already decides
what exists. Landlock also holds if a bind turns out wider than meant, and its scopes stop abstract sockets and
signals that the namespaces do not cover.

**Landlock's TCP rule is never network isolation.** A TCP Fast Open `sendto(MSG_FASTOPEN)` bypassed `connect_tcp`
on every kernel with ABI ≥ 4. The fix (mainline 33cb713db016, 7.2-rc4) came with no ABI bump, so a process cannot
tell a fixed kernel from an unfixed one. Landlock has no UDP rules before ABI 10 either. Isolation is
`--unshare-net` plus the relay and the proxy; the TCP rule stays inside that namespace as a second layer.

**The reduced tier's network is narrowed, not isolated.** It has no network namespace, so Landlock's TCP rules are
all it has (2026-10-21, the manager's call on Task 5). A connect is allowed only to the relay's ports, which forward
to the session's proxy, so DNS and HTTPS go through the proxy too. A bind is allowed only on those ports, under the
first layer, for the relay; the inner helper then adds a second layer that refuses every bind before the program
runs. `extra_tcp_ports` are not granted: a port rule has no address, so it would reach that port on every host. What
stays open, and why this is not isolation: a connect to a relay port on *any* host (the rule names a port, not an
address), UDP (no Landlock rule before ABI 10, and the crate stops at 9), and the TCP Fast Open bypass on unfixed
kernels. The reduced badge (phase 6) keeps saying the network is not isolated.

**The reduced tier's floor is ABI 9.** This is the user's ruling on review B1, stricter than the design's 6. Only
ABI 9 controls connecting to pathname Unix sockets. Without a mount namespace, ABI 6–8 would leave the hub socket,
D-Bus, ssh-agent and the Emacs server reachable. Validation refuses a reduced spec with a lower `landlock_min_abi`,
`plan_for` raises it to 9, and `gate` refuses an effective ABI below 9 (for example a kernel at 8, or the test
hook's cap of 8).

**The reduced tier and `/proc`.** There is no pid namespace, so `/proc` shows the host's processes. Landlock's
ptrace scoping denies other processes' `environ`, `mem` and `fd` (EACCES). It does not deny their `cmdline` or
`stat`: a sandboxed program can read the command lines of the user's processes. The user accepted this gap
(2026-10-21). It is recorded by the test `reduced_proc_other_cmdline_is_the_gap` and the escape row
`reduced-proc-cmdline-the-gap`, and phase 6 names it in the reduced badge's text.

Tests: `landlock::tests`. The pure ones include the goldens `rules_per_abi_golden` (ABI 1–9 × full shared, full
isolated, reduced), the floor table, and the check that the handled set equals the crate's own set for each ABI. The
real ones each run in a re-exec'd child of the test binary, because a restriction cannot be undone. They skip with
the reason when the kernel's ABI is too low.

## seccomp

`gleipnir::seccomp` holds one fixed filter. It is on in both Linux tiers, and no spec can turn it off or change it.
The filter allows every call by default and refuses this list (`seccomp::rules()`):

| Refused | Result | Why |
|---|---|---|
| `ptrace` | EPERM | Without a pid namespace (the reduced tier), it would read and write other processes of the same user. |
| `keyctl`, `add_key`, `request_key` | EPERM | Kernel keyrings are not namespaced. The user's session and user keyrings hold credentials. |
| `perf_event_open` | EPERM | Watches other processes, and is a large kernel attack surface. |
| `bpf` | EPERM | Kernel attack surface. |
| `userfaultfd` | EPERM | A common primitive for exploiting kernel races. |
| `io_uring_setup`, `io_uring_enter`, `io_uring_register` | EPERM | io_uring operations are not system calls, so seccomp never sees them. It is also a frequent source of CVEs. |
| `unshare`, `setns` | EPERM | A new namespace gives a namespaced root, kernel attack surface, and a way around the mount layout. |
| `clone` with any `CLONE_NEW*` bit in its flags | EPERM | The same, through `clone`. These are seven rules, one per bit of `0x7E020000`, because seccompiler cannot express "masked value is not zero". |
| `mount`, `umount2`, `pivot_root` | EPERM | The sandbox's view of the file system stays as bwrap built it. |
| `open_tree`, `move_mount`, `fsopen`, `fsconfig`, `fsmount`, `fspick`, `mount_setattr` | EPERM | The same, for the new mount API. |
| `ioctl` with `TIOCSTI` (`0x5412`) or `TIOCLINUX` (`0x541C`) | EPERM | Both push input into a terminal (CVE-2017-5226), and `TIOCLINUX` also reads the console selection. |
| `socket(AF_VSOCK)` | EPERM | vsock reaches the host or the hypervisor, past the network namespace. |
| `clone3` | ENOSYS | Its flags sit in a struct that seccomp cannot read. On ENOSYS, libc falls back to `clone`, which the rules above check. EPERM would break thread creation instead. |

**The reduced tier adds socket rules** (`seccomp::reduced_rules()`; `rules_for(tier)` is the whole list). It has no
network namespace, and Landlock's network rules cover TCP only, so the only sockets it may make that reach past the
host are TCP ones, which Landlock holds to the relay's ports:

| Refused (reduced tier) | Result | Why |
|---|---|---|
| `socket(domain)` for every domain but `AF_UNIX`, `AF_INET`, `AF_INET6`, `AF_NETLINK` | EPERM | Families whose connects Landlock does not see (SMC, which talks TCP from inside the kernel; RDS; TIPC; packet; vsock). One rule of four "not equal" conditions. |
| `socket(AF_INET or AF_INET6, type)` unless `type & 0xf` is `SOCK_STREAM` | EPERM | No UDP (so no DNS past the proxy) and no raw sockets. `0xf` is `SOCK_TYPE_MASK`: `SOCK_NONBLOCK` and `SOCK_CLOEXEC` sit above it and are allowed. seccompiler has no masked "not equal", so it is one rule per other type value (15 per family). |
| `socket(AF_INET or AF_INET6, SOCK_STREAM, protocol)` unless the protocol is 0 or `IPPROTO_TCP` | EPERM | SCTP and MPTCP stream sockets are not TCP to Landlock, which then leaves their connects alone. |

Argument checks compare only the **low 32 bits** of the argument. The kernel reads an `ioctl` request and a `socket`
domain, type and protocol as 32-bit ints, so `TIOCSTI | 1 << 32` is TIOCSTI to the kernel, and the filter must see it
that way too. The `CLONE_NEW*` bits all sit in the low half, and legacy `clone` ignores the high half.

`seccomp::compile_for(arch, tier)` builds the BPF for `X86_64` or `Aarch64` on any Linux host (`compile(arch)` is
the full tier's); the inner helper compiles its plan's tier. The call numbers come from a table
in the module, so neither filter depends on the host's libc. seccompiler `=0.5.0` compiles the EPERM rules. Its
architecture check kills a call that comes from any other audit arch. Before seccompiler's code there is a short
hand-written prologue. None of its jumps leave it, and none of seccompiler's jumps enter it:
- **x86_64:** `ld arch; jeq AUDIT_ARCH_X86_64 (else skip two); ld nr; jset 0x40000000 (else skip one); ret
  KILL_PROCESS`. A foreign arch and an **x32** call both land on the kill. x32 calls carry `AUDIT_ARCH_X86_64` with bit
  30 set in the number, so a list keyed on x86_64 numbers would miss them. Debian can turn x32 on at boot
  (`syscall.x32=y`). The filter sees the number before the kernel checks whether x32 is enabled, so the kill happens
  either way.
- **aarch64:** `ld arch; jeq AUDIT_ARCH_AARCH64 (then skip one); ret KILL_PROCESS; ld nr`.
- **Then, for both:** `jeq clone3; ret ERRNO(ENOSYS)`. seccompiler gives one errno to every rule in a filter, so a
  rule with a different errno goes here.

`seccomp::install(prog)` sets `PR_SET_NO_NEW_PRIVS`, then installs the filter on every thread
(`SECCOMP_FILTER_FLAG_TSYNC`). The inner helper (Task 8) compiles the filter for `seccomp::native()` and installs it
right after Landlock. A filter that does not compile or install stops the sandbox from starting (fail
closed). Off Linux, `compile` and `install` return `Unsupported`. That includes Android, which has no backend.

Tests (`seccomp::tests`):
- `bpf_golden_x86_64` and `bpf_golden_aarch64`: insta snapshots of each whole program in `src/snapshots/`, one line
  per instruction. A new seccompiler is checked against these.
- `bpf_interpreter_table`: a classic-BPF interpreter in the test runs both programs over synthetic `seccomp_data`
  (3232 cases):
  - every call number 0–1023;
  - each `CLONE_NEW*` bit alone, all seven together, and with thread flags, plus 0, fork and thread flags alone;
  - TIOCSTI and TIOCLINUX with and without high bits;
  - vsock and other socket domains;
  - every x32 number;
  - four foreign arches.

  This checks what the filter does, not just which bytes it has.
- `installed_filter_denies`: the real install. For each case, the test binary runs itself again in a child process.
  That child forks once without the filter (the control) and once with it. Only calls whose unfiltered result
  differs from the filtered one are used:
  - `unshare(CLONE_NEWUSER)`, `io_uring_setup`, `keyctl`, `add_key`, `socket(AF_VSOCK)`, and `ptrace` attach to the
    child's own child: EPERM;
  - `clone3(NULL, 0)`: EINVAL unfiltered, ENOSYS filtered;
  - `mount` on a missing target: ENOENT unfiltered, EPERM filtered;
  - `TIOCSTI | 1 << 32` on a pty the child makes its controlling terminal: EIO or success unfiltered, EPERM filtered;
  - x32 `getpid`: killed;
  - `getpid` and `socket(AF_UNIX)` still work;
  - under the reduced tier's filter, a UDP socket and an MPTCP stream socket: EPERM; a TCP one (with
    `SOCK_CLOEXEC | SOCK_NONBLOCK`) still works; under the full tier's, the UDP socket works.
- `bpf_golden_{x86_64,aarch64}_reduced`, `reduced_rules_are_the_socket_set`, `reduced_socket_table` (every domain,
  type value with and without flags and high bits, and protocol, through both programs) and
  `reduced_differs_from_full_only_on_socket` (every other number, both argument extremes, the foreign-arch kill).

  A case is skipped, with the reason printed, when its control does not give the unfiltered result. Inside a podman
  container, the container's own filter already refuses `io_uring_setup`, `add_key` and vsock, so those three skip
  there. They run wherever no container filter is in the way. The calls the kernel already refuses to an unprivileged process (`setns`, `pivot_root`,
  the new mount API, `bpf`, `userfaultfd`) are covered by the interpreter only.

## macOS: Seatbelt

`gleipnir::sbpl` turns a spec validated for `Target::Macos` into a Seatbelt profile (SBPL, the policy language of
`sandbox-exec`); `gleipnir::backend::macos` runs it. `sbpl::profile(&spec, &MacContext)` is pure text, so its goldens
and order checks run on Linux (`sbpl::tests`, snapshots in `src/snapshots/gleipnir__sbpl__*`). It is unverified on a
Mac until the MAC-SB rows pass (Task 16 on macOS CI, MAC-SB-11/12 on the user's Mac).

### What differs from Linux

macOS has no mount namespace and no Landlock. Nothing is bound anywhere: every path is seen at its own place, and what
the program may touch is the profile's allow list.

- **Validation** (`What is refused`): a `Macos` spec has `landlock_min_abi` 0, every bind's, the home's and `run`'s
  dest equals its source (the session's `HOME` names the home), and paths compare without case.
- **`home`**: readable, and writable only when its mode is `rw`. **`run`**: readable at its own path, never
  writable. **`sockets`**: the only Unix sockets the program may connect to.
- **`env`, `chdir`**: not in the profile; `backend::macos::prepare` sets them on the invocation.
- **`MacContext`** carries the caller's facts: `users_dir` (`/Users`) and `developer_dir`, the true name of the dir
  xcode-select's link selects. `/usr/bin/git` is xcrun's shim and runs the git there (the Command Line Tools under
  `/Library`, or Xcode's under `/Applications`, which nothing else reads), so the profile reads it. Both must be
  absolute and in canonical form; a developer dir that is `/` or holds `users_dir` is refused.

### The profile, in order

SBPL decides by the **last rule that matches** (sandbox-runtime: "Seatbelt is last-match-wins"), so the order is the
policy:

```
(version 1) (deny default) …                    ; 1. the base: sbpl/base.sbpl (Codex's, below)
(allow system-socket (socket-domain AF_UNIX))   ; 2. pipes to children; connecting is decided at 13
(deny file-read* (subpath "/Users") (regex …))  ; 3. before every allow: only what is allowed below is readable there
(allow file-read* (literal "/"))                ; 4. / itself, and the metadata of /tmp, /var, /etc and of every
(allow file-read-metadata (literal …))          ;    directory above an allowed path (stat, never list)
(allow file-read* (subpath …))                  ; 5. system roots, developer dir, read, write, home, run, tmp
(allow file-read* (literal "/dev/null") …)      ; 6. the devices, each by name
(deny file-read* (subpath "/opt/homebrew/var") (regex …) …)          ; 7. Homebrew's data
(allow file-write* (subpath …))                 ; 8. write, home (rw), tmp
(allow file-read* (subpath B)) (allow file-write* (subpath B))       ; 9. each bind, in order: rw…
                               (deny file-write* (subpath B) (regex …))   ; …or ro (the pins)
(deny file-read* file-write* (subpath H) (regex …) …)                ; 10. hide
(deny file-write-unlink (literal D) (regex …) …)                     ; 11. no rename of a root or a pin's parents
(allow network-outbound (remote ip "*:*"))      ; 12. shared, with AF_SYSTEM and the network mach services
  — or, isolated: (deny network*) (allow network-outbound (remote ip "localhost:PORT")) per mac_tcp_ports
(deny network-outbound (remote unix-socket))    ; 13. every Unix socket…
(allow network-outbound (remote unix-socket (path-literal S)))   ; …but each of sockets (and, shared, the resolver's)
```

- **The system's roots** (`sbpl::SYSTEM_READ`): `/usr`, `/bin`, `/sbin`, `/System`, `/Library`, `/opt/homebrew`,
  `/private/etc`, `/dev/fd` (the process's own descriptors), `/private/var/select` (the link `/bin/sh` and xcrun
  follow), the time zones and xcode-select's link. Homebrew's data (`/opt/homebrew/var`, `/usr/local/var`: the
  databases of Postgres, MySQL, Redis) is denied after every read.
- **Devices by name** (`sbpl::DEVICES`): `/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom`, `/dev/tty` (the
  controlling terminal) and `/dev/dtracehelper`. Never all of `/dev`: the user's other terminals (`/dev/ttysN`)
  belong to the same user, and a process that reads one races the shell for its keystrokes. The base allows only the
  ptys the sandbox opened itself.
- **`subpath` or `literal`**: every allowed or hidden path is a `subpath` (a file, or a whole directory component by
  component). `literal` is only for `/`, the metadata of ancestors (`realpath()` stats each; none can be listed) and
  the unlink denies. Sockets are `path-literal`.
- **One kind of operation per path.** A deny of a specific operation can win over a later allow of a wildcard, so
  allows and denies on a path use the same wildcards (`file-read*`, `file-write*`) and the later one wins. The one
  specific deny is the rename block, which is meant to win.
- **No rename past a deny.** Seatbelt matches paths, not files: renaming a directory above a pin or a hidden path would
  carry it to a name no deny covers (`mv conf c2; cat c2/.env`). So `(deny file-write-unlink (literal D))` (a rename's
  source is an unlink) covers every writable root (`write`, a `rw` home, `tmp`, the `rw` binds) and every directory
  from such a root down to the parent of each `ro` bind and `hide` path. Files in those directories can still be
  removed and renamed. This is sandbox-runtime's move-blocking deny (anthropics/sandbox-runtime,
  `src/sandbox/macos-sandbox-utils.ts`, Apache-2.0), cut to what the spec needs.
- **Every deny holds in every case.** APFS is case-insensitive by default, so `.GIT/config` is `.git/config`. Reports
  disagree on whether Seatbelt compares paths that way, so each deny (`/Users`, the pins, `hide`, the rename blocks,
  Homebrew's data) also carries a `regex` of character classes (`\.[Gg][Ii][Tt](/.*)?$`; a non-ASCII letter as
  `(é|É)`; no `(?i)`). Allows stay exact: a path spelled otherwise is simply not allowed, which fails closed. The regex
  is about four times its path, so a deny path of more than about 250 bytes refuses the profile (1024 bytes, below).
- **`/tmp`, `/var` and `/etc` are links into `/private`.** Seatbelt matches the resolved path, so every rule names
  `/private/…`. Spec paths are true names already (validation), and the links themselves get their metadata only.
- **No escape through other processes.** No `appleevent-send` (an AppleEvent to Terminal runs anything), no `lsopen`
  (LaunchServices starts apps outside the sandbox), no mach-lookup of `com.apple.coreservices.launchservicesd`, and no
  Keychain (`com.apple.SecurityServer`).
- **Network.** Shared allows outbound IP anywhere and nothing inbound, plus the AF_SYSTEM socket and the network mach
  services (`sbpl::NET_SERVICES`: TLS trust, the network's configuration, user dirs), the resolver's socket
  (`/private/var/run/mDNSResponder`: every lookup on macOS goes through it) and `/private/var/run/resolv.conf` (Go's
  resolver). Isolated denies all network, then allows outbound to `localhost` on `mac_tcp_ports` only: macOS has no
  network namespace, so the ports are what isolates, and there is no relay. The mach services and the resolver come
  with shared only, as in Codex: `trustd` and `ocspd` fetch a certificate's AIA, OCSP and CRL URLs outside the sandbox,
  a way past `(deny network*)`. So tools that verify TLS through Apple's frameworks (`curl` and `git` from the Command
  Line Tools) may fail when isolated, even through the proxy (SB-T4-3, a Mac row).

### Quoting

Every path is one SBPL string made by `sbpl::quote`: in double quotes, with `"` and `\` escaped by a backslash (the
escaping Zed and sandbox-runtime use too). A control character (newline, tab, NUL, DEL, C1) is refused: SBPL's reader
would take some as escapes, and validation already refuses newlines and NULs. So is a string of more than 1024 bytes
between its quotes, escapes counted: `sandbox-exec` refuses a longer literal ("Error reading string"; sandbox-runtime
measured the limit at 1025). A folder named `x") (allow default) ("` stays one path in one rule
(`golden_hostile_names`). `sbpl::sexp` (tests and the `fuzzing` feature) reads a profile back as data for the order
checks and the `sbpl_quote` fuzz target.

### Where the profile goes, and the run

`backend::macos::prepare(&spec, &mac, &sandbox_exec, command)` (review S8). The profile is never written where the
program can write, and never into `tmp`:

- with a `run` (a session dir: readable inside, not writable), it goes to `<run.source>/profile.sb`, 0600, made with
  `O_EXCL` and `O_NOFOLLOW` after a stale file (or link) there is removed; a session dir that lies under a writable
  root or `tmp` is refused (validation already refuses it);
- without a `run` (the check, short steps), it travels in argv: `-p PROFILE` (CI3-SB-1). argv and the environment
  share `ARG_MAX` (1 MiB on macOS), so a profile over 256 KiB is refused with the reason instead of an `E2BIG`.

The invocation is `/usr/bin/sandbox-exec -f FILE CMD…` or `-p TEXT CMD…`, with exactly the spec's environment and
`chdir` as its directory. `sandbox-exec` comes from `backend::macos::find()`, which accepts only
`/usr/bin/sandbox-exec` when only root can change it (`eitri::trusted_program`), never one on `PATH`. A command whose
program is empty or starts with `-` is refused (`sandbox-exec` would read it as an option). There is no inner helper
and no status fd on macOS: `Sandbox::prepare` reports the layers as `LayersReport::seatbelt()`, and draugr's
close-on-exec loop is what keeps inherited fds out (review S7). `sandbox-exec` is deprecated but still works on macOS
15 and 26; Apple does not document SBPL as an API, so the macOS CI rows are the check on every runner image.

### The session's TMPDIR

`sbpl::session_tmpdir(parent, sid)` makes `parent/gleipnir-SID-RANDOM` (16 hex digits from `/dev/urandom`) with
`mkdir`, so nothing planted before is used, sets it to 0700 through a no-follow fd, and returns its true name, for
the spec's `tmp` and the session's `TMPDIR`. On macOS `parent` is the user's own `/private/var/folders/…/T`. `sid` must
be a plain name. Removing it is the caller's job.

### The base policy

`src/sbpl/base.sbpl` is the Seatbelt base policy of OpenAI's Codex, unchanged below its attribution header:
[`codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/sandboxing/src/seatbelt_base_policy.sbpl)
at commit `8c07694`, Copyright 2025 OpenAI, under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0),
whose text is `LICENSES/Apache-2.0.txt`. It holds `(deny default)`, process exec and fork, the `hw.*`/`kern.*` sysctl
allowlist (zsh exits silently without it on macOS 26.5), user lookup, POSIX IPC and pseudo-terminals. The network mach
services are Codex's `seatbelt_network_policy.sbpl` at the same commit, without `com.apple.SecurityServer`. Apache-2.0
is compatible with GPL-3.0-or-later. Codex's base was chosen over sandbox-runtime's (also Apache-2.0) because it is a
published policy file of its own and holds no LaunchServices or Keychain service.

### Limits (macOS)

- **Unverified on a Mac** until the MAC-SB rows pass. There is no SBPL evaluator here (review M6): it would have to
  model Seatbelt's regex and last-match rules without being checked against them. The goldens pin the text, the order
  checks pin the rule order, and the macOS rows run the real `sandbox-exec`.
- **Case** is handled on the deny side only, and Unicode normalization not at all (APFS is normalization-insensitive;
  GL-T2-1).
- **Links and clones.** Whether `file-link` and `file-clone` of a hidden file fall under `file-write*` or under
  `(deny default)` is a Mac row (`mac-renames-links-clones`).
- **Existence.** A denied path probably fails with EPERM and a missing one with ENOENT, so names in `~` can be probed
  one by one, never listed. Linux gives ENOENT for both.
- **Tools' own Unix sockets** (a language server's socket in `TMPDIR`) cannot be connected to, and nothing can listen
  on a port. Only `sockets`, the resolver's socket and outbound IP are allowed.
- **No nesting.** A `sandbox-exec` inside the sandbox is believed to fail.

## The relay (Task 11)

With the network isolated, a program inside the sandbox still reaches the session's proxy through loopback ports.
The relay (`gleipnir::net::relay`) is the process that makes those ports: for each `PORT=SOCKET` pair it listens on
`127.0.0.1:PORT` and forwards every connection to the Unix socket the session mounted in, with
`tokio::io::copy_bidirectional`, so a half-close (a client that finishes sending and still reads) is kept.

- **Ready before the program starts.** Every port is bound first; then `ready\n` is written to the `--ready-fd` and
  the fd is closed. A port that cannot be bound makes the relay exit 1 with the fd closed and nothing written, so the
  caller sees a failed start and not a half-working sandbox.
- **One bad connection is only that connection.** A socket that cannot be reached closes that connection and prints
  one line on stderr; the listener and the other pairs carry on.
- **The backlog is tokio's default (1024)**, which closes CI3-SB-3 (a burst of connections used to overflow the
  small default).
- **It ends with its parent.** It runs on a `current_thread` runtime, polls `getppid` each second and exits 0 when it
  changes (the sandbox's init is gone), and exits 0 on SIGTERM.
- **It starts only under the parent it was given** (Gleipnir T11-1). `--parent-pid PID` is required: the relay asks
  for SIGTERM when its parent exits (`PR_SET_PDEATHSIG`, Linux), then checks that `getppid` is `PID`, and exits 1
  otherwise. In that order a parent that dies after the check is caught by the signal, and one that died before it
  (the relay was reparented before it ran) by the check. The inner helper appends `--parent-pid` and its own pid to
  the relay's argv; under the reduced tier the signal also ends the relay when the program exits.
- **Interface:** `RelayPair`, `parse_pair` (port 1-65535, absolute path), `run(pairs, ready)` and
  `main(args)` (`--parent-pid PID [--ready-fd N] PAIR...`, the options anywhere; exit 0 normal, 1 failed to bind or
  not under `PID`, 2 bad arguments). Ratatoskr runs it as `ratatoskr relay`. It builds on every target; nothing
  starts it on Android, which has no sandbox backend.

## The proxy (Task 10)

An isolated sandbox has no network, only its own loopback. Its programs reach the outside through `HTTPS_PROXY`,
which the relay forwards to a CONNECT proxy outside the sandbox (`net::proxy`). One proxy serves one job: the caller
starts it with `proxy::start(config, resolver, events)` and hands it each session's listener with
`listen(listener, tag)` (a Unix socket on Linux, a `127.0.0.1:0` TCP listener on macOS). Every listener shares the
one allowlist, changed at run time with `allow(target)` and `deny(&target)`. `close(tag)` drops a session's listener
and every connection it accepted; `shutdown()` (or dropping the handle) ends them all.

**The answers.** The proxy reads the request head (the line and headers up to the blank line) and looks only at the
request line, never at `Host:`:

| Request | Answer | Event |
|---|---|---|
| `CONNECT host:port HTTP/1.1` (or `1.0`) to a listed target | `200 Connection established`, then the bytes are spliced both ways | — |
| a well-formed public target that is not listed | 403 | `Denied` |
| a target with `*` | 403 | `Refused { Wildcard }` |
| an address literal that is not public, listed or not | 403 | `Refused { Private }` |
| a name whose DNS answer has no public address (and no pin) | 403 | `Refused { Private }` |
| a target with a byte outside printable ASCII (a NUL, a U-label) | 400 | `Refused { NotAscii }` |
| another method, a malformed line or target, a head over `max_head` (8192) or slower than `head_timeout` (10 s) | 400 | `Refused { BadRequest }` |
| a first byte of `0x04` or `0x05` (a SOCKS greeting) | closed, no answer | — |
| a connection over `max_conns` (64, across all listeners) | 403 | — |
| listed, but it does not resolve or no address connects | 502 | — |

Each event is sent once per target per tag, before the client is answered; the tag tells the caller which session
asked. Only `Denied` may become a question to the user: a private address, a wildcard or a malformed request is never
offered. A refused request's `target` is shown with every byte outside printable ASCII escaped.

**The matching.** A target is parsed strictly (`net::host::parse_target`), with no `idna` stack:
- a name is ASCII letters, digits and inner hyphens, labels of 1–63 characters, at most 253 in all, lower-cased, one
  trailing dot dropped, and its last label starts with a letter. A-labels (`xn--…`) are names like any other; a
  U-label, `_` and `*` are refused;
- an IPv4 address is exactly four decimal octets with no leading zeros (no `127.1`, `2130706433`, `0x7f.0.0.1` or
  `010.0.0.1`); an IPv6 address is written in brackets, with no zone;
- the port is decimal, 1–65535, with no leading zero.

Allowlist entries are exact `host:port` targets: `example.com:443` allows neither `www.example.com:443` nor
`example.com:80`. There are no wildcard entries (the parked Lisp proxy had `*.name` entries; the design allows exact
`host:port` only).

**The addresses.** `net::host::is_public` decides what is public. Not public: IPv4 0/8, 10/8, 100.64/10, 127/8,
169.254/16 (with the cloud metadata address), 172.16/12, 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15,
198.51.100/24, 203.0.113/24, 224/4 and 240/4; IPv6 `::`, `::1`, `fc00::/7`, `fe80::/10`, `fec0::/10`, `ff00::/8`,
`2001:db8::/32`, `2001::/32` (Teredo), `64:ff9b:1::/48` and `100::/64`. An IPv6 address that carries an IPv4 one is
judged by that IPv4 address: `::ffff:0:0/96`, `::/96`, `64:ff9b::/96` and `2002::/16`. Where the proxy connects is
decided once per request:
- an address literal is the address itself, and only a public one gets this far;
- a pinned name (`ProxyConfig::pinned`, name to address) uses its pin and asks no resolver. It must still be listed,
  and this is the only way to reach an address that is not public (a registry on the company network);
- any other name is resolved once. The answer is filtered to its public addresses, each taken on the target's port; an
  answer with none left is refused as `Private`.

The proxy then connects to those very addresses, the first that answers, and never resolves again, so a DNS answer
that changes after the check (rebinding) cannot lead it anywhere else.

**Limits.**
- Once a target is allowed, the bytes are not inspected: TLS stays end to end, and the proxy cannot tell what is
  sent to an allowed host. A broad entry (a code host) can carry data out; entries should be as narrow as the work.
- `deny` stops new connections only; a tunnel already spliced stays until either side closes.
- There is no idle timeout on a spliced connection, and connecting upstream waits as long as the system's TCP
  connect does. Both hold one of the `max_conns` places meanwhile.
- The proxy speaks HTTP CONNECT only: no plain HTTP forwarding and no SOCKS.

## The check

`gleipnir::check` (`src/check.rs`) says whether the sandbox starts on this host, and when it does not, why and what
to do. `ratatoskr sandbox check [--json] [--tier full|reduced]` runs it (exit 0 when it works, else 1; the text is
`backend bwrap 0.12.0: ok (Landlock ABI 10, seccomp)`, or `not available: REASON` and `fix: FIX`), and
`ratatoskr doctor` carries its answer as a `sandbox` section `{backend, version, ok, reason, fix, landlock_abi,
in_use}`. `in_use` is false until jobs run in the sandbox (phase 6), and nothing says a job is sandboxed.

**The probe is the real invocation.** `check(helper, tier, bwrap_override, timeout, run)` detects the backend, makes a
temp dir, and builds a spec as hard as a job's: the isolated network with one relay port to a real Unix socket in a
session dir (Linux), the tier's Landlock floor, seccomp. It validates the spec, prepares it, and `run` (Ratatoskr:
`sandbox::run_probe`, through `draugr::spawn_pinned`, the way jobs start) spawns it within 5 s (1.4 s in the doctor).
The command is `/bin/sh -c 'cat "$1" >/dev/null 2>&1 && exit 9; exit 0' sh CANARY`, where CANARY is a file the spec
does not grant. Exit 0 means the read was blocked. Exit 9 means "the sandbox ran but did not block a read", which
fails the check; this is what makes it prove the sandbox, and on macOS that the profile enforces something. A relay
that cannot start, a kernel below the tier's Landlock floor and Ubuntu 25.10's `RTM_NEWADDR` failure all fail the
check, not only a job. Gleipnir spawns nothing itself: `run` returns a `Ran { layers, exit, stderr }`.

**The reason and the fix** come from `explain(stderr, facts, tier, need_abi)`. `facts()` reads the machine once:
`/run/.containerenv` or `/.dockerenv`, `/etc/os-release` (`ID`, `ID_LIKE`, `VERSION_ID`), the AppArmor and user
namespace switches under `/proc/sys`, a root-owned bwrap and its version, the Landlock ABI, and on macOS a root-owned
`sandbox-exec`. The first row that matches wins:

| When | Reason | Fix |
|---|---|---|
| a container | inside a container: bubblewrap needs user namespaces the container does not give | none |
| macOS, no trusted `sandbox-exec` | sandbox-exec was not found where only root can change it | it ships with macOS at `/usr/bin/sandbox-exec` |
| full tier, no trusted bwrap | bubblewrap (bwrap) is not installed where only root can change it | the distribution's install command (`dnf`, `apt`, `pacman`, `zypper`; else "install bubblewrap 0.12.0 or newer with your package manager") |
| full tier, bwrap below 0.12.0 | bubblewrap X is older than 0.12.0, which fixes a sandbox escape (CVE-2026-87766) | install 0.12.0 or newer; no older version is accepted, even with a distribution's backport. On Ubuntu 26.04 it adds that the update removed the fix again (0.11.1-1ubuntu0.3) and 26.10 ships 0.12.0 |
| `setting up uid map: Permission denied`, or (full tier, bwrap's own failure) `apparmor_restrict_unprivileged_userns` | AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later) | load `bwrap-userns-restrict` (`sudo cp /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/ && sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict`). Never the global sysctl |
| bwrap's namespace message, or (full tier, bwrap's own failure) `max_user_namespaces == 0` or `unprivileged_userns_clone == 0` | the kernel does not allow unprivileged user namespaces | `sudo sysctl -w user.max_user_namespaces=15000` (Debian: `kernel.unprivileged_userns_clone=1`) |
| Landlock ABI below the tier's floor (1 full, 9 reduced) | Landlock is off or too old (ABI N; the sandbox needs ABI M) | boot with Landlock in the kernel's `lsm=` list, on a kernel with ABI M or newer |
| anything else | the sandbox cannot start here: the first stderr line | run `ratatoskr sandbox check --json` and see the stderr |

The bwrap and user-namespace rows apply to the full tier only: the reduced tier makes no namespaces. The kernel
switches count only when the failure was bwrap's (or there was no run), so a Landlock failure on a restricted Ubuntu
is not blamed on AppArmor.

## Proving it (Tasks 14, 15 and 16)

The escape suite is the crate `gleipnir-escape` (test tooling: never shipped, never installed, and it never turns on
gleipnir's `test-hooks`). It has two binaries and a directory of rows:

- `gleipnir-probe` tries one channel per probe from inside the sandbox;
- `gleipnir-escape` runs each row: it builds a fixture, runs `ratatoskr sandbox run` with the probe as the program,
  and compares what the probe saw with what the row expects;
- `rows/{any,linux,macos}/*.jsonl` are the rows, as data; `rows/container/` holds the rows that only hold inside a
  container (`check-in-a-container`), which only the container run passes (`--rows rows/container`).

Build both with `cargo build -p gleipnir-escape`, and `ratatoskr` with `--features test-hooks`. The probe uses `std`
and `libc` only and needs glibc 2.39 at most, so a binary built in the Fedora 45 dev container runs on the Fedora 44
VM; there is no toolchain on the VM.

```
gleipnir-escape --ratatoskr BIN --probe BIN --rows DIR… [--only GLOB] [--require-all] --report FILE
```

`--rows` takes a directory of `.jsonl` files, or a directory holding `any/`, `linux/` and `macos/`. `--only` is a
glob on row names (`*` and `?`). The report is `[{row, status: pass|fail|skip, reason}]`; the exit is 1 on a fail,
and with `--require-all` on a skip too. The VM script copies the three binaries and the rows over and runs this
there (`gleipnir-vm.sh run`).

### The probe

Probes are separated by `--and`. Each prints one JSON line `{"probe", "arg", "result": "reached"|"blocked",
"errno"?, "detail"?}` (`errno` is a name such as `ENOENT`). The probe never prints file contents: `read` reports the
size.

| Group | Probes |
|---|---|
| files | `read PATH` (size), `write PATH` (opens for writing, writes nothing), `create PATH`, `list DIR` (names, sorted), `stat PATH`, `rename A B`, `link A B` (hard link), `clone A B` (macOS `clonefile`, a directory too; elsewhere blocked `EOPNOTSUPP`), `mkdir PATH`, `unlink PATH`, `swap A B` (exchange two paths in one step: macOS `renamex_np(RENAME_SWAP)`, Linux `renameat2(RENAME_EXCHANGE)`) |
| sockets | `connect-unix PATH`, `connect-abstract NAME` (Linux), `connect-tcp HOST:PORT`, `tfo HOST:PORT` (`sendto(MSG_FASTOPEN)`, Linux), `udp HOST:PORT` (sends, waits 500 ms for the echo; no echo is blocked with no errno), `unix-self PATH` (listens there, then connects; the detail says which step failed), `bind-tcp HOST:PORT` (bind only), `socket DOMAIN TYPE [PROTO]` (Linux: `socket(2)` alone; DOMAIN `unix inet inet6 netlink packet vsock`, TYPE `stream dgram raw seqpacket`, PROTO a number or `tcp udp icmp icmpv6 sctp mptcp`) |
| environment | `env-has NAME…`: reached when any is set, the detail names which (never a value) |
| syscalls | `syscall NAME` for `unshare-user io-uring keyctl add-key vsock clone3 clone-newuser mount-missing tiocsti-own-pty tiocsti-high-own-pty ptrace-own-child x32-getpid i386-int80`. Each runs in a forked child, so a kill by the filter is a result: blocked, no errno, detail `killed by SIGSYS`. `x32-getpid` and `i386-int80` are x86_64 only (elsewhere ENOSYS) |
| process | `status-field NAME` (from `/proc/self/status`), `fds` (the open descriptors below 1024, `0,1,2`), `proc-read PID FILE` (size), `spawn-sleep N` (a child that sleeps N seconds without exec and without the probe's pipes; the detail is its pid), `kill PID SIG` |
| other | `run CMD…` (a child; reached when it exits 0, the detail is the exit code, `out_bytes` counts what it wrote and nothing is printed), `http-connect TARGET` (CONNECT through `$HTTPS_PROXY`; the detail is the status code, reached only for 200), `landlock-abi` (the detail is the version) |

Each `syscall` is chosen so that its unfiltered result differs from the filter's: `mount-missing` mounts on a path
that does not exist (ENOENT unfiltered, EPERM filtered), `clone3` gets a null argument block (EINVAL, ENOSYS),
`tiocsti-*` use a pty the probe opens itself (the unfiltered kernel says EIO or works; the filter says EPERM), and
`tiocsti-high-own-pty` sets bit 32 of the request register, which the kernel ignores and a 64-bit compare would not.

### Rows

One JSON object per line; unknown keys are a parse error.

| Key | Meaning |
|---|---|
| `row` | the name (unique across all files) |
| `needs` | `bwrap reduced landlock seccomp netns root macos linux x86_64 x32` |
| `tier` | `full` (default) or `reduced` |
| `spec` | the spec, with placeholders. The harness fills what is left out: `chdir` (`${W}`); `net` (Linux: isolated, with a relay from a free port to `${RUN}/proxy.sock`, and then `run`, `sockets` and an `HTTPS_PROXY` in the default `env` to match; macOS: isolated with `mac_tcp_ports` the proxy's TCP port, and the same `HTTPS_PROXY`); `env` (a `PATH`); `layers` (the tier's floor; on macOS 0, since a macOS spec may not ask for Landlock); `tmp` (reduced: `${TMP}`). The probe's directory is added to `read` |
| `setup` | steps: `fake-bwrap {version}`, `path-bwrap {name?}`, `swap-to-link {path, target}` (done while `ratatoskr` waits at `--pause-before-spawn`), `plant-link {path, target}`, `canary-fd {n}`, `start-sleep`, `make-dir {path}`, `make-file {path, text?}` (the last two, like `plant-link`, run in the control run's fixture too) |
| `probes`, `expect` | one argument list per probe; one `{result, errno?: [names], detail?}` per probe. `errno` is a list so the layer that blocked is visible |
| `control`, `control_expect` | see below |
| `listeners_silent` | listeners that must have seen no connection: `hub backend session2 emacs bus ssh-agent abstract tcp-lo tcp-nl udp-lo udp-nl upstream gateway` |
| `result` | a subset of the result file `{refused, layers, exit}` (`NAME_contains` asks for a part of a string). Without it the run itself is asserted: not refused, exit 0, one line per probe |
| `unsandboxed` | run the probes with no sandbox and judge `expect` on them: the probes are real |
| `bwrap`, `landlock_omit`, `landlock_abi_cap` | `--bwrap`, `--landlock-omit`, `--landlock-abi-cap` |
| `files_absent` | paths that must not exist after the run (a marker a refused run must not write) |
| `proxy_events` | the proxy's events, exactly (placeholders filled): `Denied host:port`, `Refused <Why> target` |
| `after` | `{after_lines, kill: run\|group, signal?, gone?: {match, within_ms}}`: once N lines are read, kill the `sandbox run` process or the sandbox's process group, and require that no process whose command line contains `match` is left within the time. A killed `sandbox run` writes no result file, so `kill: run` judges the lines and `gone` alone |
| `raw` | `{args, exit?, json?, stdout_contains?}`: run `ratatoskr` with these arguments and no probe (`sandbox check`) |

**Placeholders** are a closed list; an undefined one fails the parse. Paths: `${HOME} ${RUNTIME} ${RUN} ${TASK}
${TASK2} ${W} ${DATA} ${CANARY_DIR} ${FIXTURE} ${TMP} ${MARKER}`, and on macOS `${USERS_SHARED}`. Addresses:
`${ABSTRACT}` (`@glp-…`), `${TCP_LO} ${TCP_NL} ${UDP_LO} ${UDP_NL}` (`host:port`; the `_NL` ones are the first
non-loopback address), `${UPSTREAM}` (`upstream.test:PORT`, pinned in the proxy), `${PROXY_TCP}`. Others:
`${HARNESS_PID}`, `${SLEEP_PID}` (the `start-sleep` step), `${FAKE_BWRAP}` (the `fake-bwrap` step), `${GIT}` (the
git draugr runs: `draugr::git::git_program()`, so on macOS the developer dir's, not the `/usr/bin/git` shim).

**`control: true` is mandatory for every expectation that says `blocked`** (the parse fails otherwise). The control
run executes the same probes with no sandbox, in a fixture of its own, and each must give its unfiltered result:
`reached`, or what `control_expect` says (`mount-missing` gives ENOENT). So a typo or a wrong path can never pass as
ENOENT. Steps that belong to the sandboxed run (`swap-to-link`, `canary-fd`, the bwrap fakes) are not run in it.

**Skips.** Only these reasons skip a row: "inside a container" (`/run/.containerenv`; for `bwrap` and `netns`),
"needs macos", "needs linux", "needs x86_64", "x32 is off", "needs root" (uid 0 or `sudo -n true`), and "Landlock ABI
N below M" (from the probe's `landlock-abi`). Any other cause is a **fail**, a sandbox refusal among them, so a
regression that refuses every spec cannot look green.

**What a run checks, in order:** no canary text in stdout, stderr or the result file; the sandbox's outcome from the
`--result` file (never from the exit code, since a child may exit 3 itself); the probe lines against `expect`;
`listeners_silent`; `proxy_events`; `files_absent`; and `after`'s `gone`.

### The fixture

Each run gets a fixture under `/tmp/glp-XXXXXX/`; the control run and the sandboxed run get one each, so a probe
that moves or creates things in one cannot disturb the other. `ratatoskr` runs with an empty environment plus
`HOME`, `XDG_RUNTIME_DIR`, `DRGNX_DATA_DIR`, `DRGNX_CONFIG_DIR`, `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`,
`DISPLAY`, `WAYLAND_DISPLAY`, `OPENROUTER_API_KEY` (a canary) and `PATH`, all pointing into the fixture: nothing
reaches the real home, the user's sockets, D-Bus or a display.

| Path | Holds |
|---|---|
| `home/` | `.ssh/id_canary`, `other-repo/secret`, `canary-dir/canary.txt`, each random text |
| `run/` | listeners that count connections: `drgnx/hub-0000.sock`, the backend's `drgnx/hub-0000.d/backend.sock`, `emacs/server`, `bus`, `ssh-agent.sock`; `drgnx/s/S1` (`${RUN}`) with `proxy.sock` (served by `gleipnir::net::proxy`, allowing `upstream.test:PORT`) and `gateway.sock` (an echo); another session's `drgnx/s/S2/hub.sock` (the layout of [hub.md](hub.md)) |
| `data/` | `work.db` (a canary) |
| `tasks/t1`, `tasks/t2`, `w/`, `t/` | `${TASK}`, `${TASK2}` (holds a canary), `${W}`, `${TMP}` |
| `bin/` | a copy of the probe, bound read-only into the sandbox (the helper's own directory is closed, so the probe cannot run from beside `ratatoskr`) |

Besides the files: an abstract listener, TCP and UDP listeners on `127.0.0.1` and on the first non-loopback address,
and an upstream, all of which echo. Setup that needs root (`fake-bwrap`: a script in a root-owned `/var/lib/glp-…/`
that prints `bubblewrap VERSION` for `--version` and writes `${MARKER}` for any other argv) runs through `sudo -n`.

### The rows shipped with the harness

`any/probes-reach-without-sandbox` (and its `-non-loopback` and `-linux` companions) runs every fixture-facing probe
with no sandbox and requires `reached`: the probes are real. `any/works` runs `sh -c 'echo ok'` and `git --version`
under the full tier; it skips in a container.

### The Linux rows (Task 15)

`rows/linux/` holds the probe-level escape rows: every channel that needs no agent, in both tiers. Full-tier rows
need `bwrap` and skip inside a container; reduced-tier rows need `reduced` (Landlock ABI 9) and run in a container
too when its kernel has it. Two places run them:

- the container (`ctr.sh`, as its root): `--rows rows --rows rows/container`. The reduced rows, the bwrap floor and
  PATH rows, `fail-closed-no-bwrap`, `helper-cannot-be-shadowed` and `check-in-a-container` run; the full-tier rows
  skip with "inside a container";
- the Fedora VM (`gleipnir-vm.sh run`): `--rows rows/linux --rows rows/any --require-all`. Every row runs; none may
  skip;
- GitHub CI (`runtime.yml`, [ci.md](ci.md)): the container run above in the Fedora job, the 25 macOS rows plus
  `rows/any` with `--require-all` on the macOS runner, and `rows/linux` + `rows/any` on the Ubuntu 24.04 runners
  (x86_64 and arm64) with a lifted AppArmor user-namespace restriction and bubblewrap 0.12.0 built from source.

Each blocked expectation names the errno of the layer that answered, so a row also says which layer holds: ENOENT is
the mount namespace (the path is not there), EACCES is Landlock, EPERM or ENOSYS is seccomp (EPERM is also Landlock's
scoping of abstract sockets and signals), ECONNREFUSED and ENETUNREACH are the network namespace. Rows that prove one
layer alone cap Landlock (`landlock_abi_cap: 3` takes its TCP rules away) or omit a path from it.

| Row | What it proves |
|---|---|
| `k1-hub-socket-absent`, `k1-reduced` | the hub's socket is not there (full) or not connectable (reduced, Landlock ABI 9); the listener sees nothing |
| `k1-backend-socket-absent`, `k1-backend-socket-reduced` | the Lisp backend's `hub-HASH.d/backend.sock` and another session's `s/S2/hub.sock` cannot be seen or connected to; `s/` lists only the session's own `S1` (full) or cannot be listed (reduced) |
| `k2-work-db-absent`, `k2-reduced` | drgnx's data (`work.db`) can be neither read nor opened for writing |
| `k5-user-sockets-absent`, `k5-reduced` | the Emacs server, the session bus and the ssh agent cannot be connected to |
| `k6-isolated-refused` | the network namespace alone (Landlock's TCP rules capped away): the host's abstract socket, its loopback and its non-loopback listeners are unreachable |
| `k6-isolated-landlock-tcp` | inside that namespace Landlock's TCP rule refuses every port but the relay's (EACCES) |
| `k6-shared-tcp-the-gap` | `Net::Shared` reaches the host's TCP listeners: recorded, and no phase uses it for jobs |
| `k6-shared-abstract-scoped`, `…-unscoped-at-abi-5` | with a shared network, Landlock's scoping (ABI 6) is what refuses the host's abstract socket |
| `k8-canaries-absent`, `k8-reduced` | `~/.ssh`, another repository, another task folder and the home itself are invisible (full) or unreadable (reduced) |
| `k10-env-clean`, `k10-env-clean-reduced` | none of the user's session variables, the API key or drgnx's dirs reach the program |
| `reduced-below-abi-9-refused` | the reduced tier refuses ABI 8 before anything runs, so the user's sockets stay unreached |
| `reduced-no-host-tmp-writes` | the reduced tier writes its own `tmp`, never the host's `/tmp` |
| `reduced-signals-scoped` | the reduced tier cannot signal a process outside it (Landlock ABI 6) |
| `reduced-group-killed`, `die-with-parent` | killing the sandbox's group (reduced) or `sandbox run` itself (full) ends a grandchild within 1.5 s |
| `reduced-proc-environ-denied`, `pid-namespace-hides-others` | another process's `/proc/PID/environ` (the backend's secret lives there) is unreadable (reduced: EACCES) or absent (full: the pid namespace) |
| `reduced-proc-cmdline-the-gap` | the accepted gap: the reduced tier reads other processes' command lines |
| `reduced-tcp-only-to-the-relay`, `reduced-bind-refused` | the reduced tier connects over TCP only to its relay (and through it to the proxy), and binds no TCP port |
| `reduced-udp-and-icmp-refused` | the reduced tier makes no UDP, ICMP or MPTCP socket (seccomp), so no DNS or datagram leaves past the proxy |
| `reduced-no-pty` | the reduced tier opens no pty at all (Landlock: `/dev/ptmx` is not granted), so TIOCSTI never gets that far there |
| `no-new-privs`, `no-new-privs-reduced` | `NoNewPrivs` 1 and seccomp mode 2 in the program |
| `seccomp-denies`, `seccomp-denies-reduced` | each refused call against its unfiltered result on the same kernel |
| `seccomp-kills-other-abis`, `…-reduced` | `int 0x80` and an x32 call kill the process (the prologue) |
| `landlock-layer-2` | a write the mount namespace allows is still refused by Landlock when Landlock is not told about it |
| `landlock-below-required-refused` | a spec's `landlock_min_abi` above the effective ABI refuses the run before the program |
| `fds-closed`, `fds-closed-reduced` | an fd the caller leaked does not reach the program |
| `tfo-blocked`, `udp-blocked` | TCP Fast Open and UDP leave the network namespace for neither the host's loopback nor its non-loopback address |
| `relay-reaches-the-proxy` | the relay reaches the session's proxy: a listed target connects, another is a `Denied` |
| `connect-wildcard-refused`, `connect-private-literal-refused` | `*` and private literals (the metadata address, loopback, `::1`, `0.0.0.0`) are `Refused`, never `Denied`, and reach nothing |
| `own-tmp-unix-socket` | a server the program makes itself in its `/tmp` is reachable (Landlock's same-domain rule, ABI 9), as design §5.11 needs |
| `bwrap-below-floor-run`, `bwrap-below-floor-check` | a root-owned bwrap 0.11.1 is refused for its version (the CVE named) and never run beyond `--version` |
| `path-bwrap-never-run`, `…-check` | a `bwrap` first on `PATH` is never run; the root-owned one is |
| `fail-closed-no-bwrap`, `…-check` | without a bwrap nothing runs; the check names the install command |
| `bind-fd-link-swap` | a task folder swapped for a link after the check is still the folder that gets mounted (the fd), and the link's target is untouched |
| `dest-link-stays-inside`, `…-plain`, `dest-link-inside-the-root-is-followed-there` | bwrap 0.12.0 refuses a bind whose dest runs through a link leading out of the new root (through `/oldroot`, or to a host path), and follows one that stays inside |
| `helper-cannot-be-shadowed` | a bind over `/run/gleipnir` is refused by validation, so nothing can take the helper's place |
| `check-in-a-container` (`rows/container/`) | `sandbox check` says why it cannot work in a container, with no fix |

**Mutations.** Each was built on a scratch copy of the tree and run on the VM (the plan's table, plus three for the
reduced tier's network); every one turned its row red, and no other row changed:

| Mutation | Row that turned red |
|---|---|
| the runtime dir bound read-only into the sandbox | `k1-hub-socket-absent`, `k1-backend-socket-absent`, `k5-user-sockets-absent` (EACCES, not ENOENT) |
| the Landlock floor check removed from `gate` | `landlock-below-required-refused`, `reduced-below-abi-9-refused` |
| the reduced floor 9 → 6 (harness built with it too) | `reduced-below-abi-9-refused`; at cap 8 the bus is reached |
| binds by path instead of by fd | `bind-fd-link-swap` (the canary dir was mounted) |
| no bwrap floor | `bwrap-below-floor-run`, `bwrap-below-floor-check` (the fake ran) |
| `--share-net` always, Landlock's TCP rule still on | `k6-isolated-refused`, `tfo-blocked`, `udp-blocked`; `k6-isolated-landlock-tcp` stays green: Landlock holds TCP, never UDP |
| `io_uring_*` dropped from seccomp | `seccomp-denies`, and `seccomp::tests::installed_filter_denies` on the VM |
| rule 11 dropped and the helper bound before the binds | `helper-cannot-be-shadowed` (the planted program ran as the helper) |
| the reduced tier's TCP connect rule dropped | `reduced-tcp-only-to-the-relay` |
| the reduced tier's seccomp socket rules dropped | `reduced-udp-and-icmp-refused` |

Not covered by a row: the reduced tier's second Landlock layer (`forbid_tcp_bind`) on the relay's own port, which no
placeholder names (the unit test `reduced_tcp_relay_ports_only_then_no_bind` holds it), and raw sockets, which an
unprivileged control cannot open either (the BPF interpreter's table holds them).

### The macOS rows (Task 16)

`rows/macos/*.jsonl` are the Mac checklist's MAC-SB-10 (a)-(j) and the K table as data. There is no Mac in the dev
loop, so they are checked in two places. On Linux, `parses_every_shipped_row` parses them, a test checks that each
skips with "needs macos", and another builds every row's spec the way macOS would (`build_spec_for(.., linux:
false)`), validates it for the macOS target and renders the Seatbelt profile, so a row that gleipnir would refuse, or
whose `regex` denies are missing, fails on Linux. On macOS CI (Task 18) they run for real; a failing row goes to the
fix round and the MAC-SB-10 item behind it stays open.

The layout every filesystem row shares (made by `setup`, so a row needs no edits to run): `${TASK}` is a write root,
holding a `.git` pin (a file, or a directory in `mac-case`) and a hidden `conf/.env`; `${W}` is an `rw` bind with an
`ro` pin `commondir`; the program's home is `${HOME}/agent-home` (`rw`), so `${HOME}` is only an ancestor
(`stat` works, `list` does not); `${TMP}` is the `tmp`; `${FIXTURE}/q"x\y` is a hostile write root. A refusing probe
expects `EPERM` or `EACCES`: Seatbelt denies with EPERM, and a row that gets another errno fails and shows it.

| Row | Checklist | Proves |
|---|---|---|
| `mac-profile-accepted` | (a) | `sandbox-exec` accepts the profile with `regex` filters, a name with `"` and `\`, a name that looks like SBPL (`x") (allow default) ("`) and isolated ports; none of those names opens anything |
| `mac-works`, `mac-works-git` | (b) | `/bin/ls /usr/bin`, `/bin/date`, `/dev/urandom` and `/dev/null` work; the trusted git (`${GIT}`) runs. Git is its own row: draugr refuses Xcode under `/Applications`, and a runner like that must fail one row, not all |
| `mac-devices`, `mac-tmp-metadata-only` | (b), (e) | a device outside the list (`/dev/ptmx`; `/dev/ttys000` is not on every runner), `list /dev` and `list /opt/homebrew/var` are closed; `/tmp` can be `stat`ed (a `cd` works) but not listed |
| `mac-home-closed`, `mac-users-shared-closed` | (c) | `~/.ssh`, `list ~` and listing another user's folder (the one every Mac has, `Shared`) are closed, `stat ~` works; a canary in `${USERS_SHARED}` (a `glp-*` folder there) is closed (only the users-folder deny does it, review S20) |
| `mac-fds-closed` | review S7 | a canary fd 7 is not in the child: no helper exists on macOS, so draugr's close-on-exec loop is the guard |
| `mac-writes` | (d) | writes work in the task folder, home, TMPDIR and `q"x\y`; they fail in a pinned `.git`, in `commondir`, outside every grant (`${FIXTURE}/outside`, under `/private/tmp`) and in `~`; the hidden `.env` is unreadable |
| `mac-case` | (h), GL-T9-1 | `.GIT/config`, `.Git/hooks/x`, `COMMONDIR`, `.ENV` and `CONF/.env` are closed. The control run must reach them too (APFS ignores case), so this row needs the default case-insensitive volume |
| `mac-rename-hidden-dir`, `-case`, `mac-rename-task-out`, `mac-rename-over-root`, `mac-rename-binds-out`, `mac-link-hidden-pinned` | (i) | `mv conf c2` and `mv CONF c2` (then the `.env` is still closed), the task folder moved out or replaced, `${W}` and the home moved, a hard link to the hidden `.env` and to the `.git` pin, and an APFS clone of the `.env` all fail. One row each for what changes the fixture, so the control run can do all of them |
| `mac-swap-and-dir-clone` | (j) | a swap-rename of the protected dir and a `clonefile` of it fail; writing `/dev/stderr` works |
| `mac-renames-still-work` | (i) | `mv a b`, `rm`, `mkdir d && mv d e` inside the task folder work |
| `mac-sockets` | (f), K1, K5 | the session's gateway socket connects; the hub, `SSH_AUTH_SOCK`, the Emacs server and the bus do not, and their listeners stay silent |
| `mac-net-shared`, `mac-net-isolated` | (g) | shared: TCP to the host's loopback and non-loopback listeners works, Unix sockets stay closed. Isolated: only the proxy's `localhost:PORT` connects (`http-connect` gets 200, an unlisted target 403 and one `Denied`); other loopback and non-loopback TCP and UDP are closed |
| `mac-env-clean`, `mac-k1`, `mac-k2`, `mac-k8` | K | as on Linux: none of the user's variables, the hub socket, `work.db` and the canaries |

Not in a row, so the Mac session keeps them (MAC-SB-12): `curl` through the proxy without `trustd` (needs TLS to a
real host; the proxy path itself is `mac-net-isolated`), and the `log show` look at every `deny` line.

## What this does not claim yet (Task 19)
