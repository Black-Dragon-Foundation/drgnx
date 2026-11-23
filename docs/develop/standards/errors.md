# Errors

**The rule.** Every function that can fail returns `villa::Result<T>`, whose error is `villa::Error`: a kind, the
sentence the user reads, an optional detail and an optional source. No public function returns a string as its error,
and no result is dropped unread.

**Doing it right.**

```rust
fn open_project(path: &Path) -> villa::Result<Project> {
    let text = read(path).map_err(|e| villa::Error::from(e).with_detail(format!("reading {}", path.display())))?;
    parse(&text).ok_or_else(|| villa::Error::invalid("The project file is not valid."))
}
```

- Pick the kind a caller branches on: `not_found`, `conflict`, `unavailable`, `refused`, `io`, `timeout`, `invalid`,
  `cancelled`, `internal`. Their wire names (`not-found`, …) are what a client sees.
- The message is a sentence for the user. What only a log or a bug report needs goes in `with_detail`; the error
  underneath goes in `with_source`. `Display` prints the message only; `Debug` prints everything.
- `From<std::io::Error>`: `NotFound` → not-found, `PermissionDenied` → refused, `TimedOut` → timeout, the rest → io.
- A result you mean to ignore is handled anyway: log it (`annall::log_error`) or say why it cannot matter.

**Enforced by:** the scan rules `no-string-error` (a `pub fn` returning `Result<_, String>` or `&str`, also through a
`type` alias) and `no-let-underscore-result` (`let _ = …`), and clippy's `let_underscore_must_use` and
`unused_result_ok`. Owner: `villa`. Conformance: `crates/std/villa/tests/conformance.rs`.

**Why.** A string error can't be branched on, can't be told apart from a bug, and loses its cause; a dropped result
is a failure nobody hears about. One type with kinds gives the user one sentence and the log the whole story.
