# Time

**The rule.** Code reads time and waits through `drgnx_clock`: `now()`, `sleep(d)`, `timeout(d, f)`. Never
`std::time::Instant::now`, `SystemTime::now`, `std::thread::sleep`, `tokio::time::sleep` or `tokio::time::Instant::now`.

**Doing it right.**

```rust
let start = drgnx_clock::now();
match drgnx_clock::timeout(Duration::from_secs(5), reply).await {
    Ok(r) => r,
    Err(drgnx_clock::Elapsed) => return Err(villa::Error::timeout("The server did not answer.")),
}
```

- With no clock installed these are tokio's. A test's `raun::Sandbox` installs a virtual clock; every timer then waits
  on virtual time that `sb.advance(d)` moves, so no test depends on how fast the machine is.
- Waiting for something outside the clock (a child's exit, a socket) is an event wait and stays real.

**Enforced by:** clippy's `disallowed-methods` on the calls above. Owner: `drgnx-clock` (in `crates/hub/drgnx-clock`;
its move into `crates/std` and its approved name, `stund`, come with the crate renames). Conformance:
`crates/hub/drgnx-clock/tests/conformance.rs`.

**Why.** A timer on real time makes a test slow and flaky and lets it pass on a fast machine only. One time source
lets tests run timers to the instant.
