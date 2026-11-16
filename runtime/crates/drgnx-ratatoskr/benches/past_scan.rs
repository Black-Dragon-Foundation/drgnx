//! Past sessions' warm scan (design §7, the manager's bound on the 2 s poll): 5,000 Claude session files over 100
//! project folders in a temp home, one full scan, then 200 scans with nothing changed.  Each scan's thread CPU time
//! is measured (`getrusage(RUSAGE_THREAD)`); the 95th percentile must stay under 4 ms.  Ignored in normal runs; the
//! perf lane runs it pinned:
//! `perf-exclusive.sh env DRGNX_PERF_CPUS=4 cargo test --release -p drgnx-ratatoskr --bench past_scan -- --ignored
//! --nocapture --test-threads 1`.  The files are made here from fixed arithmetic.

use std::path::Path;
use std::time::Duration;

use drgnx_ratatoskr::agents::past::{History, Roots};

fn thread_cpu() -> Duration {
    let mut u = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage fills the struct it is given.
    let u = unsafe {
        assert_eq!(libc::getrusage(libc::RUSAGE_THREAD, u.as_mut_ptr()), 0);
        u.assume_init()
    };
    let t = |v: libc::timeval| Duration::new(v.tv_sec as u64, v.tv_usec as u32 * 1000);
    t(u.ru_utime) + t(u.ru_stime)
}

fn write_files(home: &Path) {
    for p in 0..100 {
        let dir = home
            .join(".claude")
            .join("projects")
            .join(format!("-w-proj{p}"));
        std::fs::create_dir_all(&dir).unwrap();
        for s in 0..50 {
            let id = format!("{p:03}{s:03}00-0000-4000-8000-000000000000");
            let text = format!(
                "{}\n{}\n",
                serde_json::json!({"type":"user","uuid":"u1","sessionId":id,"cwd":format!("/w/proj{p}"),
                    "timestamp":"2026-11-01T10:00:00Z","message":{"role":"user","content":format!("task {s}")}}),
                serde_json::json!({"type":"assistant","uuid":"u2","sessionId":id,"timestamp":"2026-11-01T10:00:05Z",
                    "message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}),
            );
            std::fs::write(dir.join(format!("{id}.jsonl")), text).unwrap();
        }
    }
}

#[test]
#[ignore]
fn past_scan() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    write_files(&home);
    let h = History::default();
    h.configure(
        tmp.path().join("state/history.db"),
        Roots::of(&home, |_| None),
    );
    let t0 = thread_cpu();
    let (n, _) = h.scan_changed().unwrap();
    println!(
        "past_scan: first scan of {n} sessions: {:?} cpu",
        thread_cpu() - t0
    );
    assert_eq!(n, 5000);
    let reads = h.reads();
    let mut v = Vec::new();
    for _ in 0..200 {
        let t = thread_cpu();
        let (_, changed) = h.scan_changed().unwrap();
        v.push(thread_cpu() - t);
        assert!(!changed);
    }
    assert_eq!(h.reads(), reads, "a warm scan opens no file");
    v.sort();
    let p95 = v[(v.len() * 95).div_ceil(100) - 1];
    println!(
        "past_scan: warm scans: p95 {p95:?}, max {:?}",
        v[v.len() - 1]
    );
    assert!(p95 < Duration::from_millis(4), "p95 {p95:?} over 4 ms");
}
