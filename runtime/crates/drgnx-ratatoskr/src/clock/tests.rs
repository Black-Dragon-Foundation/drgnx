//! The virtual clock, each test on a runtime of its own whose threads carry their own clock.

use super::*;
use std::sync::{Arc, Mutex};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
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
        spawn("t", async move {
            sleep(ms(10)).await;
            // woken again and again, never by the clock: it never parks
            loop {
                tokio::task::yield_now().await;
            }
        });
        let a = advance(ms(10)).await;
        assert_eq!((a.now_ms, a.woken), (10, 1));
        assert_eq!(a.busy, ["t"]);
    });
}

#[test]
fn a_task_idle_on_a_channel_after_its_wake_is_parked() {
    // Pattern B: a loop that sleeps, then waits for its next signal on a channel nothing fills (a hub loop between
    // signals) runs nothing and has no wake pending, so the advance goes on at once
    on_virtual(async {
        let l = log();
        let mine = l.clone();
        let (_keep, rx) = tokio::sync::oneshot::channel::<()>();
        spawn("t", async move {
            sleep(ms(10)).await;
            mine.lock().unwrap().push("woke");
            let _ = rx.await;
        });
        let a = advance(ms(10)).await;
        assert_eq!((a.now_ms, a.woken, a.busy.len()), (10, 1, 0), "{a:?}");
        assert_eq!(seen(&l), ["woke"]);
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

#[test]
fn a_real_wait_is_waited_for_and_one_that_lasts_is_named() {
    on_virtual(async {
        let l = log();
        let (go, rx) = tokio::sync::oneshot::channel::<()>();
        let mine = l.clone();
        // a job's watcher: the child's end, under the clock's time box
        spawn("job:watch", async move {
            let _ = timeout(ms(5000), real_long(rx)).await;
            mine.lock().unwrap().push("after");
        });
        // an advance counts it parked: the advance may be what ends it
        let a = advance(Duration::ZERO).await;
        assert!(a.busy.is_empty(), "{a:?}");
        assert_eq!(waiting(ms(100), &[]).await, ["job:watch"]);
        // an allowed origin is not waited for (the bound would fail the test's own), and is still named
        let allowed = tokio::time::timeout(
            Duration::from_secs(10),
            waiting(Duration::from_secs(60), &["job:watch".into()]),
        )
        .await;
        assert_eq!(allowed.as_deref(), Ok(&["job:watch".to_string()][..]));
        // the wait ends: the settle returns once the poll that left it is done
        go.send(()).unwrap();
        assert!(waiting(Duration::from_secs(30), &[]).await.is_empty());
        assert_eq!(seen(&l), ["after"]);
    });
}

/// What a barrier's settle names `waiting`.
async fn waiting(within: Duration, ok: &[String]) -> Vec<String> {
    settle_real(within, ok).await.waiting
}

#[test]
fn a_blocking_call_is_a_real_wait() {
    // Pattern C: the blocking thread is held by the test: the task that awaits it is inside a real wait from the call
    // on; once the thread returns, the settle returns after what the task did with it
    on_virtual(async {
        let (hold, held) = std::sync::mpsc::channel::<()>();
        let l = log();
        let mine = l.clone();
        spawn("work:edits", async move {
            let _ = blocking(move || held.recv()).await;
            mine.lock().unwrap().push("done");
        });
        advance(Duration::ZERO).await;
        assert_eq!(waiting(ms(100), &[]).await, ["work:edits"]);
        hold.send(()).unwrap();
        assert!(waiting(Duration::from_secs(30), &[]).await.is_empty());
        assert_eq!(seen(&l), ["done"]);
    });
}

#[test]
fn what_is_in_flight_outside_is_waited_for() {
    // Pattern C: something outside the tasks (the gateway's answered requests) counts one in flight: a settle names
    // it after its limit; at zero it returns at once
    on_virtual(async {
        let n = Arc::new(std::sync::atomic::AtomicUsize::new(1));
        let probe = n.clone();
        outside("gateway:requests", move || {
            probe.load(std::sync::atomic::Ordering::SeqCst)
        });
        assert_eq!(
            settle_real(ms(50), &[]).await,
            Settled {
                waiting: vec!["gateway:requests".into()],
                busy: vec![]
            }
        );
        n.store(0, std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            tokio::time::timeout(
                Duration::from_secs(10),
                settle_real(Duration::from_secs(60), &[])
            )
            .await,
            Ok(Settled::default())
        );
    });
}

#[test]
fn a_task_still_running_after_the_settle_is_named_busy() {
    on_virtual(async {
        spawn("t", async move {
            loop {
                tokio::task::yield_now().await;
            }
        });
        assert_eq!(
            settle_real(ms(100), &[]).await,
            Settled {
                waiting: vec![],
                busy: vec!["t".into()]
            }
        );
    });
}

#[test]
fn a_task_woken_by_another_tasks_real_wait_is_waited_for() {
    // Pattern B: a job's watcher leaves its real wait and tells a subscriber over a channel (a job's end waking its
    // session); the settle returns only once the subscriber has run too, every one of 100 runs
    on_virtual(async {
        let mut missed = 0;
        for _ in 0..100 {
            let l = log();
            let (go, rx) = tokio::sync::oneshot::channel::<()>();
            let (tell, heard) = tokio::sync::oneshot::channel::<()>();
            spawn("job:watch", async move {
                let _ = real(rx).await;
                let _ = tell.send(());
            });
            let mine = l.clone();
            spawn("wake:run", async move {
                let _ = heard.await;
                for _ in 0..20 {
                    tokio::task::yield_now().await;
                }
                mine.lock().unwrap().push("woke");
            });
            advance(Duration::ZERO).await;
            go.send(()).unwrap();
            assert!(waiting(Duration::from_secs(30), &[]).await.is_empty());
            if seen(&l) != ["woke"] {
                missed += 1;
            }
        }
        assert_eq!(
            missed, 0,
            "{missed} of 100 settles returned before the woken task ran"
        );
    });
}

#[test]
fn a_store_threads_answer_is_a_real_wait() {
    // Pattern C: a task waits on the store thread, which the test holds: the task is inside a real wait (named after
    // the settle's limit); once the thread answers, the settle returns after what the task did with it
    on_virtual(async {
        let dir = tempfile::tempdir().unwrap();
        let (_store, db) = urdr::Store::spawn(urdr::StoreSpec {
            path: dir.path().join("a.db"),
            mode: urdr::Mode::ReadWrite {
                file_mode: 0o600,
                synchronous_full: false,
            },
            migrations: &[(1, "create table t(x);")],
        })
        .unwrap();
        let (hold, held) = std::sync::mpsc::channel::<()>();
        let l = log();
        let mine = l.clone();
        spawn("records:follow", async move {
            let _ = db
                .read(move |_| {
                    let _ = held.recv();
                    Ok(())
                })
                .await;
            mine.lock().unwrap().push("read");
        });
        advance(Duration::ZERO).await;
        assert_eq!(waiting(ms(100), &[]).await, ["records:follow"]);
        hold.send(()).unwrap();
        assert!(waiting(Duration::from_secs(30), &[]).await.is_empty());
        assert_eq!(seen(&l), ["read"]);
    });
}

#[test]
fn an_advance_waits_for_a_real_wait_inside_a_clock_timeout() {
    // Pattern B: a task an advance woke goes into a real wait under the clock's timeout (a download under its stall
    // limit); its end comes from outside a little later, and the advance answers only after it, every one of 100 runs
    on_virtual(async {
        let mut missed = 0;
        for _ in 0..100 {
            let l = log();
            let mine = l.clone();
            let (go, rx) = tokio::sync::oneshot::channel::<()>();
            spawn("search:download", async move {
                sleep(ms(10)).await;
                let _ = timeout(ms(5000), real(rx)).await;
                mine.lock().unwrap().push("after");
            });
            advance(Duration::ZERO).await;
            tokio::spawn(async move {
                for _ in 0..20 {
                    tokio::task::yield_now().await;
                }
                let _ = go.send(());
            });
            let a = advance(ms(10)).await;
            assert!(a.busy.is_empty(), "{a:?}");
            if seen(&l) != ["after"] {
                missed += 1;
            }
        }
        assert_eq!(
            missed, 0,
            "{missed} of 100 advances answered inside the real wait"
        );
    });
}
