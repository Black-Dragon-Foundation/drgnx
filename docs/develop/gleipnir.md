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

## The proxy (Task 10)

## The check (Task 12)

## Proving it (Tasks 14 and 15)

## What this does not claim yet (Task 19)
