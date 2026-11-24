# Logging

**The rule.** Code reports through `tracing`, which `annall::init` sends to a JSON file under the state directory. A
command line prints only through `annall::cli_out` and `annall::cli_err`. Nothing else writes to stdout or stderr.

**Doing it right.**

```rust
let _log = annall::init(annall::LogConfig::default())?;   // once, in main; keep the guard
tracing::info!(files = n, "project indexed");
annall::log_error(&err);                                   // kind, sentence, detail and source chain
tracing::info!(token = annall::redact(&secret), "signed in");
annall::cli_out("3 files changed")?;                       // a command's output
annall::raw_out().write_all(&frame)?;                      // a command's output that is bytes, not lines
```

- The log is `<stig::state()>/log/drgnx.log`, one JSON object per line. Dropping the guard flushes it.
- A child whose stderr the hub keeps in a log of its own (the terminal worker) logs with `LogConfig { sink: Sink::Stderr, .. }`:
  the same JSON lines, on stderr instead of the state log.
- Fields are structured (`files = n`), not formatted into the message.
- A value that holds a secret goes through `annall::redact` (data-hygiene).

**Enforced by:** clippy's `print_stdout`, `print_stderr` and `dbg_macro` (denied for every clean crate), clippy's
`disallowed-methods` on `std::io::stdout` and `std::io::stderr`, and the scan rule `no-print` (`println!`, `print!`,
`eprintln!`, `eprint!`, `dbg!`). Owner: `annall`. Conformance: `crates/std/annall/tests/conformance.rs`; xtask's test
`cli_out_is_the_only_printer` shows a `println!` rejected.

**Why.** A print goes nowhere in a GUI process and into the middle of a protocol in a server one; an unstructured line
can't be searched. One sink, one format, and secrets redacted on the way.
