# Gleipnir: the sandbox

Gleipnir is the Rust sandbox in `runtime/crates/gleipnir` ([runtime.md](runtime.md#crate-names)). It runs a program
inside a boundary the kernel enforces: bubblewrap with Landlock and seccomp on Linux (the full tier), Landlock and
seccomp alone (the reduced tier), or Seatbelt on macOS. It is self-contained: the caller passes every path, name and
port, and nothing in gleipnir names a drgnx directory or reads a drgnx variable. Nothing in drgnx uses it yet; job
agents run as before until phase 6. The Lisp libraries on main are described in [sandbox.md](sandbox.md).

Each section below is written by the task named in it.

## Using it (Task 13)

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
| `extra_tcp_ports` | ports | TCP ports besides the relay's (Landlock's port rule, never counted as isolation) |

`gleipnir::validate::validate(spec, &ctx, target)` checks a spec for one `Target` (`LinuxBwrap`, `LinuxReduced`,
`Macos`) against a `Context` and returns a `ValidSpec` or a `Refusal { rule, path, message }`. Only a `ValidSpec`
reaches a backend: it is not `Deserialize`, has no mutable access, and only `validate.rs` can make one (its
constructor takes a token whose field is private to that file). The `Context` holds the caller's facts, all true
names: `home`, `closed` and `open_inside_closed`, `user_sockets`, `run_parents` (where session dirs are made),
`program_dirs` (the caller's `PATH`) and `env_deny`. Gleipnir names none of them itself; a context path that is not
absolute and canonical refuses the spec (`Malformed`), so a sloppy context never weakens a check.

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
modules. `BackendKind` is `Bwrap`, `Reduced`, `Seatbelt` or `None`; Task 13 detects which one a host gets.

| What | Where | Gate | Android |
|---|---|---|---|
| spec, validation, bwrap argv, SBPL text, hosts, relay, proxy | `spec`, `validate`, `bwrap`, `sbpl`, `net` | none: pure, built and tested on every target (the goldens run on Linux) | builds; nothing runs it |
| bwrap, the reduced tier | `backend::linux` | `target_os = "linux"` | no backend; apps get no user namespaces; fails closed |
| inner helper, Landlock, seccomp | `inner`, `landlock`, `seccomp` | body `target_os = "linux"`, an `Unsupported` stub elsewhere | the stub |
| Seatbelt | `backend::macos` | `target_os = "macos"` | not applicable |
| anything else | `backend::none` | always | a refusal |

`landlock` and `seccompiler` are Linux-only dependencies. Every `cfg(target_os)` names its Android stance in a
comment, and every chain ends in `BackendKind::None` or an `Unsupported` refusal, never an unconfined run. The rules
in `validate` follow the spec's `Target`, not the host, so the macOS rules are tested on Linux.

## Toolchain roots (Task 3)

## The bubblewrap argv (Task 7)

## The inner helper (Task 8)

## Landlock (Task 5)

## seccomp (Task 4)

## macOS: Seatbelt (Task 9)

## The relay (Task 11)

## The proxy (Task 10)

## The check (Task 12)

## Proving it (Tasks 14 and 15)

## What this does not claim yet (Task 19)
