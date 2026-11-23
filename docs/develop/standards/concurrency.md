# Concurrency

**The rule.** Threads, tasks and locks go through `saman`: `saman::lock` for a `std::sync::Mutex`, one
`saman::Executor` for background work, `saman::Cancel` for cancellation, and `saman::ui::UiQueue::post` to get back to
the UI thread. UI code never blocks.

**Doing it right.**

```rust
let task = executor.spawn("index-project", async move { index(root, cancel.child()).await });
// dropping `task` cancels it; awaiting it gives its output or a villa error (cancelled, or internal on a panic)
ui.post(|cx| show_results(cx));          // from any task or thread
let mut guard = saman::lock(&state);     // also after a holder panicked
```

- A thread that must be an OS thread (a blocking read of a descriptor, a test's second thread) is started with
  `saman::spawn_thread(name, f)`, which names it and returns the `JoinHandle` (or an `unavailable` error).
- `Task` cancels on drop. `task.detach("why")` lets one run on, and must say why.
- `Cancel::child()` is cancelled with its parent; work checks `cancelled().await` at its awaits.
- The UI loop runs posted closures with `UiLoop::run_pending`, never waiting, each under the `Watchdog`: over 8 ms is
  a warning, over 100 ms an error event with the handler's name.
- `lock` recovers a poisoned mutex: the next caller sees what the panicking holder left, and the editor keeps going.

**Enforced by:** clippy's `disallowed-methods` on `std::thread::spawn`, `std::thread::Builder::spawn`, `tokio::spawn`,
`tokio::task::spawn`, `tokio::task::spawn_blocking`, `tokio::runtime::Builder::new_*` and `std::sync::Mutex::lock`, and
the scan rule `no-blocking-recv-on-ui` (`.recv()`, `.recv_timeout()` and `blocking_*` calls in crates marked `ui`; an
awaited `recv()` is fine). Owner: `saman`. Conformance: `crates/std/saman/tests/conformance.rs`.

**Why.** A poisoned lock unwrapped turns one bug into a panic on every later call; a task nobody owns runs on after its
reason is gone; a blocking call on the UI thread freezes the window.
