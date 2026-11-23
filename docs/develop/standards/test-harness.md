# The test harness

**The rule.** A test that touches paths or time runs inside a `raun::Sandbox`. No test reads or writes the real home,
the user's install, or real time.

**Doing it right.**

```rust
#[test]
fn saves_the_session() {
    let sb = raun::Sandbox::new();
    save_session(&state)?;                                   // lands under sb.home()
    sb.advance(Duration::from_secs(30));                     // the autosave timer fires, with no real wait
}
```

- `Sandbox::new` makes a temp HOME, points every `stig` directory under it with the `test` profile, and installs a
  virtual clock (`sb.clock()`, `sb.advance(d)`). Dropping it removes the HOME and puts things back.
- A test's child process (a compositor to talk to) is started with `raun::proc::TestChild::start(program, args, env)`:
  through `draugr`, with exactly the environment the test gives, its stdout read by `read_line()`, and its whole group
  ended and reaped when the value drops.
- Sandboxes of one process take turns; under nextest each test is its own process anyway.

**Enforced by:** the sentinel-HOME run, `cargo xtask test-sandbox`: it runs the tests with HOME set to a fresh, empty,
read-only directory and the XDG variables unset, and fails if the tests fail or anything appears in that directory.
With no arguments it runs the clean crates' tests; `--workspace` (or any nextest filter) widens it. Owner: `raun`.
Conformance: `crates/std/raun/tests/conformance.rs`.

**Why.** A unit test once overwrote the user's real board file through a path that fell back to `~`. A test that
can't see the real home can't do that, and a run that watches the home proves none tried.
