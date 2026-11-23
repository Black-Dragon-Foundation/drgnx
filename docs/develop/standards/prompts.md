# Prompts

**The rule.** A question to the user goes through `spurn::Ask::choose`. It never blocks: it returns a task that
resolves to the answer. A headless or daemon context answers the question's default at once and logs it, so no prompt
ever blocks a daemon.

**Doing it right.**

```rust
let q = spurn::Question::new("Save?", "The buffer changed.",
    vec![spurn::Choice::new("save", "Save"), spurn::Choice::new("discard", "Discard")],
    "save", Some(Duration::from_secs(30)), spurn::Origin::User)?;
let answer = ask.choose(q).await?;      // spurn::Answer { choice, by: User | Default | Timeout }
```

- The default must be one of the choices.
- A timeout runs on the `stund` clock; when it runs out the default is the answer. Dropping the task withdraws the
  question.
- The UI shows a question through a `Presenter`; the presenter keeps the reply sender and sends the chosen id. An id
  that was not offered is not taken.

**Enforced by:** the conformance test. The layer rule that only `spurn` reaches the UI's modal API waits for that API,
which does not exist yet (B1). Owner: `spurn`. Conformance: `crates/std/spurn/tests/conformance.rs`.

**Why.** A hidden prompt in a daemon path freezes the editor; one ask API makes the default answer a rule, not a habit.
