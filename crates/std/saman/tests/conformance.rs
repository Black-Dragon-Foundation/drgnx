//! The concurrency standard (docs/develop/standards/concurrency.md). Review focus 3: a poisoned lock, a cancelled
//! task or a panicking one never stops the UI loop.

use std::io::Write;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use saman::ui::{UiCx, Watchdog};
use saman::{Cancel, Executor, lock};

const WAIT: Duration = Duration::from_secs(10);

#[test]
fn poisoned_lock_recovers() {
    let m = Arc::new(Mutex::new(vec![1]));
    let held = Arc::clone(&m);
    // saman owns the concurrency standard: its tests may start a thread and lock directly
    let joined = std::thread::spawn(move || {
        let mut g = lock(&held);
        g.push(2);
        panic!("a holder panics with the guard in hand");
    })
    .join();
    assert!(joined.is_err() && m.is_poisoned());
    lock(&m).push(3);
    assert_eq!(*lock(&m), vec![1, 2, 3]);
}

struct Flag(mpsc::Sender<()>);

impl Drop for Flag {
    fn drop(&mut self) {
        self.0.send(()).unwrap_or_default();
    }
}

#[test]
fn dropped_task_is_cancelled() {
    let ex = Executor::new(2).unwrap();
    let (tx, rx) = mpsc::channel();
    let flag = Flag(tx);
    let task = ex.spawn("parked", async move {
        let _flag = flag;
        std::future::pending::<()>().await;
    });
    drop(task);
    // dropping the task dropped its future (and the flag in it), without the runtime ending
    assert_eq!(rx.recv_timeout(WAIT), Ok(()));
}

#[test]
fn a_task_gives_its_output_and_a_detached_one_runs_on() {
    let ex = Executor::new(2).unwrap();
    assert_eq!(ex.block_on(ex.spawn("answer", async { 42 })).unwrap(), 42);
    let (tx, rx) = mpsc::channel();
    ex.spawn("detached", async move { tx.send(5).unwrap_or_default() })
        .detach("the test reads its result from a channel");
    assert_eq!(rx.recv_timeout(WAIT), Ok(5));
}

#[test]
fn cancel_mid_await_leaves_ui_loop_running() {
    let ex = Executor::new(2).unwrap();
    let (q, mut ui) = saman::ui::queue();
    let cancel = Cancel::new();
    let child = cancel.child();
    let (started_tx, started_rx) = mpsc::channel();
    let task = ex.spawn("waits-for-cancel", async move {
        started_tx.send(()).unwrap_or_default();
        child.cancelled().await;
        q.post(|cx: &mut UiCx| cx.frame += 1).unwrap();
        7
    });
    assert_eq!(started_rx.recv_timeout(WAIT), Ok(()));
    assert!(!cancel.is_cancelled());
    cancel.cancel();
    assert_eq!(ex.block_on(task).unwrap(), 7);
    let mut cx = UiCx::default();
    assert_eq!(ui.run_pending(&mut cx), 1);
    assert_eq!(cx.frame, 1, "the next frame ran the posted closure");
}

#[test]
fn panicking_task_leaves_ui_loop_running() {
    let ex = Executor::new(2).unwrap();
    let (q, mut ui) = saman::ui::queue();
    let shared = Arc::new(Mutex::new(0));
    let held = Arc::clone(&shared);
    let task = ex.spawn("panics-holding-a-lock", async move {
        let _g = lock(&held);
        panic!("a task panics with a lock held");
    });
    let err = ex.block_on(task).unwrap_err();
    assert_eq!(err.kind(), villa::Kind::Internal);
    *lock(&shared) += 1;
    q.post(|cx: &mut UiCx| cx.frame += 1).unwrap();
    let mut cx = UiCx::default();
    assert_eq!(ui.run_pending(&mut cx), 1);
    assert_eq!((*lock(&shared), cx.frame), (1, 1));
}

#[test]
fn an_unanswered_cancel_does_not_fire() {
    let ex = Executor::new(1).unwrap();
    let cancel = Cancel::new();
    let child = cancel.child();
    let (tx, rx) = mpsc::channel();
    let _task = ex.spawn("waits", async move {
        child.cancelled().await;
        tx.send(()).unwrap_or_default();
    });
    assert_eq!(
        rx.recv_timeout(Duration::from_millis(200)),
        Err(RecvTimeoutError::Timeout)
    );
    cancel.cancel();
    assert_eq!(rx.recv_timeout(WAIT), Ok(()));
}

#[derive(Clone, Default)]
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        lock(&self.0).extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn watchdog_reports_slow_handler() {
    let clock = stund::Manual::default();
    let _on = clock.on_this_thread();
    let out = Capture::default();
    let writer = out.clone();
    let sub = tracing_subscriber::fmt()
        .json()
        .with_writer(move || writer.clone())
        .finish();
    let dog = Watchdog::default();
    tracing::subscriber::with_default(sub, || {
        dog.run("quick", || clock.advance(Duration::from_millis(1)));
        dog.run("sluggish", || clock.advance(Duration::from_millis(10)));
        dog.run("slow-handler", || clock.advance(Duration::from_millis(120)));
    });
    let text = String::from_utf8(lock(&out.0).clone()).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(
        lines[0].contains("\"level\":\"WARN\"") && lines[0].contains("sluggish"),
        "{text}"
    );
    assert!(
        lines[1].contains("\"level\":\"ERROR\"") && lines[1].contains("slow-handler"),
        "{text}"
    );
}

#[test]
fn a_spawned_thread_has_its_name_and_gives_its_result() {
    let t = saman::spawn_thread("saman-test-thread", || {
        std::thread::current().name().map(str::to_owned)
    })
    .unwrap();
    assert_eq!(t.join().unwrap().as_deref(), Some("saman-test-thread"));
}

#[test]
fn an_ambient_task_runs_on_the_callers_runtime_and_is_cancelled_when_dropped() {
    let ex = Executor::new(2).unwrap();
    let (tx, rx) = mpsc::channel();
    let out = ex.block_on(async {
        let task = saman::spawn("ambient", async { 7 });
        assert_eq!(task.name(), "ambient");
        let blocking = saman::spawn_blocking("ambient-blocking", || 8);
        let flag = Flag(tx);
        let held = saman::spawn("held", async move {
            let _flag = flag;
            std::future::pending::<()>().await;
        });
        let sum = task.await.unwrap() + blocking.await.unwrap();
        assert!(!held.is_finished());
        drop(held);
        sum
    });
    assert_eq!(out, 15);
    rx.recv_timeout(WAIT)
        .expect("dropping the task cancelled it");
}

#[test]
fn a_tuned_pool_runs_the_tuning_and_a_finished_task_says_so() {
    let (tx, rx) = mpsc::channel();
    let ex = Executor::tuned(1, move |b| {
        b.on_thread_start(move || tx.send(()).unwrap_or_default());
    })
    .unwrap();
    let task = ex.spawn("done", async { 1 });
    assert_eq!(ex.block_on(async { task.await.unwrap() }), 1);
    rx.recv_timeout(WAIT)
        .expect("the tuning reached the builder");
    let detached = ex.spawn("detached", async {});
    detached.detach("a test");
}

#[test]
fn a_send_to_a_gone_receiver_is_reported_not_raised() {
    let (tx, rx) = mpsc::channel::<u8>();
    assert!(saman::delivered(tx.send(1), "a test channel"));
    drop(rx);
    assert!(!saman::delivered(tx.send(2), "a test channel"));
}
