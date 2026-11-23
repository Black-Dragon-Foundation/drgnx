# The standards

Every cross-cutting concern of the editor (errors, logging, paths, files, processes, time, concurrency, secrets, the
test harness, and more to come) is a **standard**: one owning crate with one API, lints that reject any other way, a
page here, and a conformance test that drives the API. They are written before feature code, so code starts out
right instead of being migrated later.

## The table

`standards.toml` at the repository root holds one row per standard:

| Field | Meaning |
|---|---|
| `id` | the standard; its page is `docs/develop/standards/<id>.md` |
| `owner` | the one crate that may silence the standard's lints (and that the scanner's rules for it skip) |
| `clippy`, `clippy_types` | paths clippy's `disallowed-methods` / `disallowed-types` reject outside the owner |
| `lints` | clippy lints denied in `[workspace.lints.clippy]` |
| `scan` | the scanner's rule ids |
| `conformance` | the test that drives the API |

`[crates]` marks crates `clean` (no finding; everything enforced) and `ui` (code on the UI thread). `[[layer]]` rows say
what a crate may not depend on, directly or through other workspace crates.

## `cargo xtask standards`

- `cargo xtask standards` runs every check and prints one line per finding:
  `file:line: [<id>/<rule>] <message> (docs/develop/standards/<id>.md)`. It exits 1 on a finding in the table or in a
  clean crate. Findings in a crate that is not clean yet are listed with a count; its migration owns them.
- `cargo xtask standards --write` writes the `clippy.toml` files from the table: one in each clean crate (every row's
  paths except the rows it owns), and the root's, which takes the lists once every crate is clean. Never edit them by
  hand; a stale one is a finding.
- `--changed FILE…` (the pre-commit hook) checks the table and those files. `--commit-msg MSG FILE…` (the commit-msg
  hook) refuses a commit that touches a crate not clean yet unless its subject starts with `migrate`: such a crate
  takes migration commits only.

The checks: the table's rows (owner, page and conformance file exist; scan rules exist; every lint denied; a clean crate
has `[lints] workspace = true`); the generated files; the layers; and, over every `.rs` of every member, the scanner
and the ownership check. The scanner resolves `use … as`, `type` aliases and glob imports within a file and reads
macro arguments; clippy, which resolves paths across files, covers the rest.

## No allowlist

`#[allow(...)]` or `#[expect(...)]` of a standard's lint, of a lint group that holds one (`clippy::all`, `style`,
`restriction`) or of `warnings` is a finding anywhere but in that standard's owner. No row of the table ever names a
site outside its owner. Code that cannot meet a standard yet sits in a crate that is not clean, and is migrated.

## The pages

[errors](errors.md) · [logging](logging.md) · [paths](paths.md) · [files](files.md) · [processes](processes.md) ·
[time](time.md) · [concurrency](concurrency.md) · [data-hygiene](data-hygiene.md) · [test-harness](test-harness.md)
