# crates/std: the standards

This group holds one crate per cross-cutting standard, written before any feature code: errors, processes,
logging and tracing, paths, files, settings, commands, keys, prompts, concurrency, lists and views, the UI kit,
notices, resource budgets, data hygiene, scale and zoom, accessibility, extension API versioning, and the test
harness.

Each standard is one owning crate with one API, a lint that rejects any other way (in CI and in the pre-commit hook,
with no allowlists), a documentation page, and a conformance test. The table is `standards.toml`; the pages and
`cargo xtask standards` are in `docs/develop/standards/`.

Here so far (each name is Old Norse):

- `villa` (*villa*, error): the one error type, `villa::Error` with its kinds ([errors](../../docs/develop/standards/errors.md)).
- `annall` (*annáll*, annals): logging to a JSON file, and `cli_out` / `cli_err`, the only printers
  ([logging](../../docs/develop/standards/logging.md)).
- `stig` (*stígr*, a path): the editor's directories, XDG plus the profile ([paths](../../docs/develop/standards/paths.md)).
- `raun` (*raun*, a trial): the test sandbox, a temp HOME and a virtual clock
  ([test harness](../../docs/develop/standards/test-harness.md)).
- `saman` (*saman*, together): the lock that survives a panic, one executor, cancellation, the UI queue and its
  watchdog ([concurrency](../../docs/develop/standards/concurrency.md)).
- `hulda` (*hulða*, concealment): `Secret<T>` and `Redact` ([data hygiene](../../docs/develop/standards/data-hygiene.md)).
- `vag` (*vág*, the scales): the resource budgets' measuring crate. PSS over a process tree, per-thread wakeups
  (context-switch deltas from `/proc/PID/task/*/status`), and JSON reports that compare to an earlier build. Its front
  end is `cargo xtask measure` (`xtask/README.md`). Linux only.

The files, processes and time standards are owned by `eitri`, `draugr` and `drgnx-clock`, still in `crates/hub/`.
