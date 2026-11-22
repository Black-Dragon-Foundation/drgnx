# crates/std: the standards

This group will hold one crate per cross-cutting standard, written before any feature code: errors, processes,
logging and tracing, paths, files, settings, commands, keys, prompts, concurrency, lists and views, the UI kit,
notices, resource budgets, data hygiene, scale and zoom, accessibility, extension API versioning, and the test
harness.

Each standard is one owning crate with one API, a lint that rejects any other way (in CI and in the pre-commit hook,
with no allowlists), a documentation page, and a conformance test.

Nothing lives here yet.
