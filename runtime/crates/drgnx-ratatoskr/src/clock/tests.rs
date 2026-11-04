//! The virtual clock, each test on a runtime of its own whose threads carry their own clock.

use super::*;
use std::sync::{Arc, Mutex};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// F on a two-worker runtime whose threads (and this one) read a fresh virtual clock.
fn on_virtual<F: Future>(f: F) -> F::Output {
    let clock = Arc::new(virt::Virtual::new());
    let theirs = clock.clone();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .on_thread_start(move || virt::LOCAL.with(|l| *l.borrow_mut() = Some(theirs.clone())))
        .build()
        .unwrap();
    virt::LOCAL.with(|l| *l.borrow_mut() = Some(clock));
    let out = rt.block_on(f);
    virt::LOCAL.with(|l| *l.borrow_mut() = None);
    rt.shutdown_background();
    out
}

type Log = Arc<Mutex<Vec<&'static str>>>;

fn log() -> Log {
    Arc::new(Mutex::new(Vec::new()))
}

fn seen(l: &Log) -> Vec<&'static str> {
    l.lock().unwrap().clone()
}

#[test]
fn virtual_time_moves_only_on_advance() {
    on_virtual(async {
        let l = log();
        let mine = l.clone();
        spawn("t", async move {
            sleep(ms(50)).await;
            mine.lock().unwrap().push("woke");
        });
        // real time passes; the virtual clock stands still
        tokio::time::sleep(ms(200)).await;
        assert!(seen(&l).is_empty(), "woke without an advance");
        let a = advance(ms(49)).await;
        assert_eq!((a.now_ms, a.woken), (49, 0));
        assert!(seen(&l).is_empty());
        let a = advance(ms(1)).await;
        assert_eq!((a.now_ms, a.woken, a.unnamed), (50, 1, 0));
        assert!(a.busy.is_empty(), "{a:?}");
        assert_eq!(seen(&l), ["woke"]);
    });
}

#[test]
fn due_sleepers_wake_in_deadline_then_registration_order() {
    on_virtual(async {
        let l = log();
        for (name, after) in [("a", 20), ("c", 10), ("b", 10), ("d", 20)] {
            let mine = l.clone();
            spawn(name, async move {
                sleep(ms(after)).await;
                mine.lock().unwrap().push(name);
            });
            // each task has run (and registered) before the next is spawned
            advance(Duration::ZERO).await;
        }
        let a = advance(ms(30)).await;
        assert_eq!((a.now_ms, a.woken), (30, 4));
        assert_eq!(seen(&l), ["c", "b", "a", "d"]);
    });
}

#[test]
fn advance_returns_after_woken_tasks_park() {
    on_virtual(async {
        let l = log();
        let mine = l.clone();
        spawn("parent", async move {
            sleep(ms(10)).await;
            for _ in 0..20 {
                tokio::task::yield_now().await;
            }
            mine.lock().unwrap().push("woken");
            let child = mine.clone();
            spawn("child", async move {
                tokio::task::yield_now().await;
                child.lock().unwrap().push("child");
            });
            // parked again
            sleep(ms(1000)).await;
            mine.lock().unwrap().push("late");
        });
        let a = advance(ms(10)).await;
        assert_eq!((a.woken, a.busy.len()), (1, 0), "{a:?}");
        assert_eq!(seen(&l), ["woken", "child"]);
    });
}

#[test]
fn a_task_that_never_parks_is_named_busy() {
    on_virtual(async {
        let (_keep, rx) = tokio::sync::oneshot::channel::<()>();
        spawn("t", async move {
            sleep(ms(10)).await;
            // a channel, not the clock: it never parks
            let _ = rx.await;
        });
        let a = advance(ms(10)).await;
        assert_eq!((a.now_ms, a.woken), (10, 1));
        assert_eq!(a.busy, ["t"]);
    });
}

#[test]
fn wall_follows_virtual_time() {
    on_virtual(async {
        let (w0, n0, s0) = (wall(), now(), wall_secs());
        tokio::time::sleep(ms(50)).await;
        assert_eq!((wall(), now()), (w0, n0), "real time moved the clock");
        advance(ms(1500)).await;
        assert_eq!(wall().duration_since(w0).unwrap(), ms(1500));
        assert_eq!(now() - n0, ms(1500));
        // seconds as f64 since the epoch: exact to well under a microsecond
        assert!((wall_secs() - s0 - 1.5).abs() < 1e-6);
    });
}

#[test]
fn timeouts_and_intervals_follow_virtual_time() {
    on_virtual(async {
        let l = log();
        let mine = l.clone();
        spawn("timeout", async move {
            let never = std::future::pending::<()>();
            if timeout(ms(100), never).await == Err(Elapsed) {
                mine.lock().unwrap().push("elapsed");
            }
            // a ready future registers no sleeper and wins
            assert_eq!(timeout(ms(1), async { 7 }).await, Ok(7));
        });
        let mine = l.clone();
        spawn("interval", async move {
            let mut every = interval(ms(40));
            for _ in 0..3 {
                every.tick().await;
                mine.lock().unwrap().push("tick");
            }
        });
        advance(ms(99)).await;
        // the first tick at once, then at 40 and 80
        assert_eq!(seen(&l), ["tick", "tick", "tick"]);
        advance(ms(1)).await;
        assert_eq!(seen(&l), ["tick", "tick", "tick", "elapsed"]);
    });
}
