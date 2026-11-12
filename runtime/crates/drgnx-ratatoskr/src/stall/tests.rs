use super::*;

#[test]
fn the_threshold_is_the_variable_else_on_in_test_builds_and_never_on_the_virtual_clock() {
    let ms = |v: u64| Some(Duration::from_millis(v));
    assert_eq!(threshold(Some("400"), false, false), ms(400));
    assert_eq!(threshold(None, true, false), ms(DEFAULT_MS));
    assert_eq!(threshold(Some(""), true, false), ms(DEFAULT_MS));
    assert_eq!(threshold(None, false, false), None);
    assert_eq!(threshold(Some("nope"), true, false), None);
    // at least two ticks, so a tick merely due is never a stall
    assert_eq!(threshold(Some("10"), false, false), ms(100));
    assert_eq!(threshold(Some("400"), true, true), None);
}

#[test]
fn a_late_beat_or_a_held_poll_is_a_stall() {
    let t = Duration::from_millis(250);
    assert_eq!(report(Duration::from_millis(60), t, &[]), None);
    assert!(
        report(Duration::from_millis(900), t, &[])
            .unwrap()
            .contains("no named task")
    );
    let held = vec![("w".to_owned(), 0, "session:turn".to_owned(), 300)];
    let line = report(Duration::from_millis(60), t, &held).unwrap();
    assert!(line.starts_with("w in session:turn for 300 ms"), "{line}");
}

#[test]
fn a_worker_held_in_sync_work_is_named_with_its_task() {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    rt.spawn(Named::new(Cow::Borrowed("test:holder"), async move {
        tx.send(()).unwrap();
        // sync work on the worker: what the watchdog is for
        std::thread::sleep(Duration::from_millis(600));
    }));
    rx.recv().unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let held: Vec<_> = holders(Duration::from_millis(150))
        .into_iter()
        .filter(|h| h.2 == "test:holder")
        .collect();
    assert_eq!(held.len(), 1, "{held:?}");
    assert!(held[0].3 >= 150, "{held:?}");
    let line = report(Duration::ZERO, Duration::from_millis(150), &held).unwrap();
    assert!(line.contains("in test:holder for"), "{line}");
    if cfg!(target_os = "linux") {
        // the kernel's view of the held thread: asleep in the sleep's syscall
        assert!(line.contains("state S"), "{line}");
    }
    rt.shutdown_timeout(Duration::from_secs(2));
}

#[test]
fn a_poll_that_ends_frees_its_slot() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(Named::new(Cow::Borrowed("test:quick"), async {
        tokio::task::yield_now().await;
    }));
    assert!(holders(Duration::ZERO).iter().all(|h| h.2 != "test:quick"));
}
