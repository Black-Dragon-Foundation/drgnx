# crates/std: the standards

This group will hold one crate per cross-cutting standard, written before any feature code: errors, processes,
logging and tracing, paths, files, settings, commands, keys, prompts, concurrency, lists and views, the UI kit,
notices, resource budgets, data hygiene, scale and zoom, accessibility, extension API versioning, and the test
harness.

Each standard is one owning crate with one API, a lint that rejects any other way (in CI and in the pre-commit hook,
with no allowlists), a documentation page, and a conformance test.

Here so far:

- `budget` (`drgnx-budget`): the resource budgets' measuring crate. PSS over a process tree, per-thread wakeups
  (context-switch deltas from `/proc/PID/task/*/status`), and JSON reports that compare to an earlier build. Its front
  end is `cargo xtask measure` (`xtask/README.md`). Linux only.
