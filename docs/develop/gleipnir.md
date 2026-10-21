# Gleipnir: the sandbox

Gleipnir is the Rust sandbox in `runtime/crates/gleipnir` ([runtime.md](runtime.md#crate-names)). It runs a program
inside a boundary the kernel enforces: bubblewrap with Landlock and seccomp on Linux (the full tier), Landlock and
seccomp alone (the reduced tier), or Seatbelt on macOS. It is self-contained: the caller passes every path, name and
port, and nothing in gleipnir names a drgnx directory or reads a drgnx variable. Nothing in drgnx uses it yet; job
agents run as before until phase 6. The Lisp libraries on main are described in [sandbox.md](sandbox.md).

Each section below is written by the task named in it.

## Using it (Task 13)

## The spec (Task 2)

## What is refused (Task 2)

## Platforms (Task 2)

## Toolchain roots (Task 3)

## The bubblewrap argv (Task 7)

## The inner helper (Task 8)

## Landlock (Task 5)

## seccomp (Task 4)

## macOS: Seatbelt (Task 9)

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
- **Interface:** `RelayPair`, `parse_pair` (port 1-65535, absolute path), `run(pairs, ready)` and
  `main(args)` (`--ready-fd N PAIR...`; exit 0 normal, 1 failed to bind, 2 bad arguments). It builds on every target;
  nothing starts it on Android, which has no sandbox backend.

## The proxy (Task 10)

## The check (Task 12)

## Proving it (Tasks 14 and 15)

## What this does not claim yet (Task 19)
