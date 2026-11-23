//! The measuring crate's conformance tests: PSS over a process tree, per-thread wakeups, JSON reports.
//!
//! `/proc` here is the container's (or host's) own: the tests measure their own process and a fake `/proc` tree
//! written under cargo's target tmp dir. Nothing reads the real home.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use vag::{Error, Report, pss_kib, pss_kib_at, wakeups};

fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("budget-{name}"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// One fake process: `<root>/<pid>/stat` (with an awkward comm) and `<root>/<pid>/smaps_rollup`.
fn fake_proc(root: &Path, pid: u32, ppid: u32, pss_kb: u64) {
    let dir = root.join(pid.to_string());
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("stat"),
        format!("{pid} (a) b c) S {ppid} {pid} {pid} 0 -1 4194560 100 0 0 0\n"),
    )
    .unwrap();
    fs::write(
        dir.join("smaps_rollup"),
        format!("00400000-7fff00000000 ---p 00000000 00:00 0   [rollup]\nRss:  9999 kB\nPss:  {pss_kb} kB\nPss_Anon:  7 kB\n"),
    )
    .unwrap();
}

fn tid_of(comm: &str) -> Option<u32> {
    for entry in fs::read_dir("/proc/self/task").unwrap().flatten() {
        let tid = entry.file_name().to_string_lossy().parse::<u32>().unwrap();
        if fs::read_to_string(entry.path().join("comm")).is_ok_and(|c| c.trim_end() == comm) {
            return Some(tid);
        }
    }
    None
}

fn thread_state(tid: u32) -> String {
    let status = fs::read_to_string(format!("/proc/self/task/{tid}/status")).unwrap_or_default();
    status
        .lines()
        .find_map(|l| l.strip_prefix("State:"))
        .unwrap_or("")
        .trim()
        .to_string()
}

fn entry(w: &vag::ThreadWakeups, comm: &str) -> u64 {
    w.per_thread
        .iter()
        .find(|(c, _)| c == comm)
        .unwrap_or_else(|| panic!("no thread {comm:?} in {:?}", w.per_thread))
        .1
}

#[test]
fn pss_of_self_is_nonzero() {
    assert!(pss_kib(std::process::id()).unwrap() > 0);
}

#[test]
fn pss_sums_process_tree() {
    let root = scratch("tree");
    fake_proc(&root, 100, 1, 1000);
    fake_proc(&root, 101, 100, 200); // child
    fake_proc(&root, 102, 101, 300); // grandchild
    fake_proc(&root, 103, 1, 5000); // unrelated
    fake_proc(&root, 104, 100, 40); // second child
    assert_eq!(pss_kib_at(&root, 100).unwrap(), 1540);
    assert_eq!(pss_kib_at(&root, 101).unwrap(), 500);
}

#[test]
fn pss_of_missing_pid_is_error() {
    let root = scratch("missing");
    assert!(matches!(pss_kib_at(&root, 4242), Err(Error::Io { .. })));
}

/// A parked thread must show exactly 0 switches over the window, so the window starts only once the kernel reports
/// the thread asleep (state `S`): before that its last switch into the futex wait may still be ahead of us.
#[test]
fn idle_thread_has_zero_wakeups() {
    let pair = Arc::new((Mutex::new((false, false)), Condvar::new())); // (ready, stop)
    let worker = {
        let pair = Arc::clone(&pair);
        thread::Builder::new()
            .name("idle-parked".into())
            .spawn(move || {
                let (lock, cv) = &*pair;
                let mut g = lock.lock().unwrap();
                g.0 = true;
                cv.notify_all();
                while !g.1 {
                    g = cv.wait(g).unwrap();
                }
            })
            .unwrap()
    };
    {
        let (lock, cv) = &*pair;
        let mut g = lock.lock().unwrap();
        while !g.0 {
            g = cv.wait(g).unwrap();
        }
    }
    let tid = tid_of("idle-parked").expect("the parked thread is listed");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !thread_state(tid).starts_with('S') {
        assert!(
            Instant::now() < deadline,
            "the parked thread never went to sleep"
        );
        thread::yield_now();
    }

    let w = wakeups(std::process::id(), Duration::from_secs(2)).unwrap();
    assert_eq!(entry(&w, "idle-parked"), 0, "{:?}", w.per_thread);

    let (lock, cv) = &*pair;
    lock.lock().unwrap().1 = true;
    cv.notify_all();
    worker.join().unwrap();
}

/// A thread that blocks again and again (a 200 us sleep always blocks, unlike `yield_now`, which switches
/// nothing when no other thread is runnable on its CPU) shows many switches over the window.
#[test]
fn busy_thread_counts() {
    let stop = Arc::new(AtomicBool::new(false));
    let worker = {
        let stop = Arc::clone(&stop);
        thread::Builder::new()
            .name("busy-sleeper".into())
            .spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_micros(200));
                }
            })
            .unwrap()
    };
    let w = wakeups(std::process::id(), Duration::from_millis(500)).unwrap();
    stop.store(true, Ordering::Relaxed);
    worker.join().unwrap();
    assert!(entry(&w, "busy-sleeper") >= 100, "{:?}", w.per_thread);
    assert_eq!(w.total, w.per_thread.iter().map(|(_, n)| n).sum::<u64>());
}

fn report(value: f64) -> Report {
    Report {
        name: "idle".into(),
        commit: "abc123".into(),
        machine: "test".into(),
        metrics: BTreeMap::from([("pss_kib".to_string(), value)]),
    }
}

#[test]
fn compare_flags_regression() {
    let r = report(106.0).compare(&report(100.0), 0.05);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].metric, "pss_kib");
    assert_eq!((r[0].base, r[0].new), (100.0, 106.0));
}

#[test]
fn compare_passes_within_tolerance_and_improvements() {
    assert!(report(104.0).compare(&report(100.0), 0.05).is_empty());
    assert!(report(50.0).compare(&report(100.0), 0.05).is_empty());
}

#[test]
fn compare_flags_growth_from_zero_and_skips_new_metrics() {
    assert_eq!(report(1.0).compare(&report(0.0), 0.05).len(), 1);
    assert!(report(0.0).compare(&report(0.0), 0.05).is_empty());
    let mut new = report(100.0);
    new.metrics.insert("brand_new".into(), 9e9);
    assert!(new.compare(&report(100.0), 0.05).is_empty());
}

#[test]
fn report_json_roundtrip() {
    let dir = scratch("json");
    let path = dir.join("r.json");
    let mut r = report(123.456);
    r.metrics.insert("wakeups_per_s".into(), 0.0);
    r.write_json(&path).unwrap();
    assert_eq!(Report::read_json(&path).unwrap(), r);
    fs::write(&path, "{ not json").unwrap();
    assert!(matches!(Report::read_json(&path), Err(Error::Json { .. })));
}
