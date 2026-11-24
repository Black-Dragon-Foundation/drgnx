# Job packs

A job pack says how a project builds and tests: `.drgnx/jobs.toml` in the repo. It names no language, tool or
project; everything it runs is a command you wrote.

```toml
jobs = 1
project = "hello-c"

[toolchains.gcc]
image = "registry.example/fedora:45@sha256:0123…"      # a digest, never a bare tag

[[artifact]]                                              # built once, used by stages
name = "build"
kind = "command"
toolchain = "gcc"
inputs = ["src/**", "Makefile"]                           # the files the artifact's key covers
steps = [["make", "-C", "{src}", "O={build}"]]
keep = { from = "{build}", paths = ["test-runner"] }

[[stage]]
name = "unit"
uses = [{ artifact = "build", use = "ro" }]
toolchain = "gcc"
run = ["{art:build}/test-runner"]
parser = "tap"                                            # how its rows are read
expect = { min-ran = 1 }

[pipelines]
check = ["unit"]
```

## Rows and parsers

A stage's `parser` is one of `exit`, `regex:PATTERN` (named groups `name` and `verdict`), `tap`, `junit`, `libtest`,
`libtest-json`. Without one the exit code decides. To run only some rows (a requeue after a lost machine), the stage
names a `select` dialect (`libtest-exact`, `nextest`, or `args:TEMPLATE`) and has one argv item `{rows}`.

## Limits need a reason

`timebox`, `stall` and `silent` each need a `why`: a limit nobody explains becomes a mystery.

## Your own overlay

The project setting `jobs-overlay` names a folder on your machine with its own `jobs.toml`. Its entries are added to the
repo's pack, and one of the same name replaces it. A job from the overlay runs only on your own runners: the overlay's
files never go to a cloud or shared machine.

## Gates read the base

An author's run reads the pack from your tree as it is. A gate reads it from the base commit, so a branch cannot loosen
its own gate.

## Not built yet

Matrices, sync, sparse checkouts, shards, bisect, fetch artifacts, the `ktap` parser, macOS stages and git-URL inputs are
reserved: a pack that uses one is refused with "not built yet (after launch)" and its line.
