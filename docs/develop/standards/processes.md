# Processes

**The rule.** A child process is started by `draugr::spawn` (or `spawn_pinned` for a sandboxed one), never by
`std::process::Command` or `tokio::process::Command`.

**Doing it right.**

```rust
let mut child = draugr::spawn(draugr::Spec {
    program: "/usr/bin/git".into(),
    args: vec!["status".into()],
    env: draugr::env::build(&["PATH", "LANG"], &[], &[]),
    cwd: Some(repo.into()),
    stdin_null: true,
    pass_fds: vec![],
    new_session: false,
}).await?;
let status = child.wait_deadline(Duration::from_secs(30)).await?;
```

- The environment is explicit: the child gets exactly `env`, built from the names you allow.
- The child leads its own process group. `wait_deadline` kills the whole group (grandchildren too) once the deadline
  passes on the installed clock; `kill_group` and `reap` end a group by hand.
- Only descriptors 0–2 and the `pass_fds` reach the child; stderr is kept as a bounded tail.

**Enforced by:** clippy's `disallowed-methods` on `std::process::Command::new` and `tokio::process::Command::new`.
Owner: `draugr`, over `hlaup` (the fork lock and exec; its own tests start raw children to prove ETXTBSY), declared as `co_owners` in `standards.toml`. `draugr` lives in `crates/hub/draugr` until it moves into `crates/std`. Conformance:
`crates/hub/draugr/tests/conformance.rs`.

**Why.** A child that inherits the editor's environment leaks tokens; one without a group outlives its parent; one
with no deadline hangs the caller. One spawner gets all three right once.
