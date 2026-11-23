# xtask: repository tasks

Scripts and Rust tasks that build, package or measure the workspace, run from the repository root.

- `runner-bundle.sh [--arch x86_64|aarch64]`: the runner bundle (sleipnir, drgnx-key, drgnx-px) as static musl
  binaries in `target/bundle/<arch>/`.
- `cargo xtask measure <scenario> --out FILE [--base FILE] (--pid PID | --spawn CMD [ARGS])`: the PSS (summed over
  the process tree) and the idle wakeups per second of a running process, or of a command it starts and lets settle
  for a second, as a JSON report (`drgnx-budget`'s `Report`). With `--base`, a metric more than 5 % above the earlier
  report is a regression and the exit code is 1. `--spawn` takes the rest of the line, so it goes last. Linux only
  (it reads `/proc`).
