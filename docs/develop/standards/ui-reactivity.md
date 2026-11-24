# UI reactivity

**The rule.** UI state lives in `tafl` cells, and nothing else reacts. A value the UI shows is a `tafl::State` (written
by a command, an input or a model patch) or a formula: a plain closure `move |r| …` that reads other cells through the
read context `&Rd`. The engine finds the dependencies from the reads, re-runs only what a write reached and what is
on screen, and stops where a value comes out equal. There are no observers, callbacks that push values, hooks,
dependency lists, memo wrappers, signals or effect managers.

**Doing it right.**

```rust
let query = e.state(s, String::new());                         // state: a handle, 8 bytes, Copy
let shown = files.filter(&mut e, move |f, r| f.name(r).contains(query.get(r).as_str()));
let status = e.formula(s, Stage::Items, move |r| format!("{} of {} files", shown.len(r), files.len(r)));
e.write(Origin::User, |w| query.set(w, "main".into()));       // an input writes; the next frame shows it
```

A read takes `&Rd`, which exists only while a formula runs, and a write takes `&mut Wr`, which exists only inside
`Engine::write`: a read outside a formula and a write inside one do not compile. Work that finishes elsewhere (a hub
reply, a pool job) comes back as a write: through `saman::ui::UiQueue::post`, or the engine's own pool jobs
(`List::filter_by`). Time is a clock cell (`Engine::clock`), which has a timer only while something reads it.

**Enforced by:** two scan rules in every `ui` crate and every file under `crates/ui/`, outside `tafl`:

- `no-ui-observer`: a closure given to a formula or a collection operator (`formula`, `filter`, `filter_by`, `sort_by`)
  or registered as a callback (a method named `on_*`) that captures a shared cell, a lock or a channel
  (`Rc<RefCell<…>>`, `Arc<Mutex<…>>` and their kin, a clone of one, either end of a channel); and a channel held as
  UI state (`State<Sender<…>>`, `State<Receiver<…>>`).
- `no-dependency-list-api`: a public hook-shaped function: `create_signal`; `use_*`, `*_effect` or `memo*` that takes or
  returns a closure; `signal*` that takes a closure or returns a pair; any function with a `deps` parameter.

Owner: `tafl`. Conformance: `crates/ui/tafl/tests/conformance.rs` (`tafl_is_the_only_reactive_mechanism` drives a state,
a formula, a model collection with a filter, a clock and a frame). The engine itself: [the engine](../engine.md).

**Why.** Every reactive toolkit that grew a second mechanism (an observer beside its signals, an effect beside its
memos) got updates nobody can trace and values that go stale off screen. One engine that records reads gives exact
updates, early cutoff, viewport demand and a "why is this here" answer from the same graph, and it asks nothing of the
author but a closure.
