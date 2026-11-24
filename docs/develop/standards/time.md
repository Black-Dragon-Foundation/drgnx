# Time

**The rule.** Code reads time and waits through `stund`: `now()`, `sleep(d)`, `timeout(d, f)`. Never
`std::time::Instant::now`, `SystemTime::now`, `std::thread::sleep`, `tokio::time::sleep` or `tokio::time::Instant::now`.

**Doing it right.**

```rust
let start = stund::now();
match stund::timeout(Duration::from_secs(5), reply).await {
    Ok(r) => r,
    Err(stund::Elapsed) => return Err(villa::Error::timeout("The server did not answer.")),
}
```

- Code with no executor (a polling loop, a test's thread) uses `stund::Instant` (`now()`, `elapsed()`, `+`/`-` with a
  `Duration`, `checked_duration_since`) and `stund::sleep_blocking(d)`, which read and wait on the same installed
  clock, so no code names `std::time::Instant` or `std::thread::sleep`. A calloop or smithay API that wants a
  `std::time::Instant` is given a duration from `stund::Instant` instead (`Timer::from_duration`).
- With no clock installed these are tokio's. A test's `raun::Sandbox` installs a virtual clock; every timer then waits
  on virtual time that `sb.advance(d)` moves, so no test depends on how fast the machine is.
- Waiting for something outside the clock (a child's exit, a socket) is an event wait and stays real.
- `stund::real` is the system's clock whatever is installed (`instant()`, `wall()`, `sleep()`, `sleep_blocking()`): only
  for what must not follow a virtual clock, such as a virtual clock's own starting point or a wait on a process outside.
  `tokio_instant()` is tokio's own monotonic clock, which a test that pauses tokio's time moves by hand.

**Enforced by:** clippy's `disallowed-methods` on the calls above. Owner: `stund` (in `crates/hub/stund`;
its move into `crates/std` and its approved name, `stund`, come with the crate renames). Conformance:
`crates/hub/stund/tests/conformance.rs`.

**Why.** A timer on real time makes a test slow and flaky and lets it pass on a fast machine only. One time source
lets tests run timers to the instant.
