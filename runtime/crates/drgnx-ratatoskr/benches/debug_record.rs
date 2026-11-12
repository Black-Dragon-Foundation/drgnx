//! Recorded runs' hub rows (spec §19.9): `debug-launch-snapshot`, the launch snapshot of a 5,000-file project with
//! nothing changed since the last (content-addressed: at most 150 ms at the 95th percentile), and `debug-capture`, a
//! stop kept in the run file (the capture cut to 64 KB, its frame appended and the block flushed: at most 1 ms at the
//! 95th percentile).  Ignored in normal runs; the combined gate pass runs it under the perf lock:
//! `cargo test --release -p drgnx-ratatoskr --bench debug_record -- --ignored --nocapture --test-threads 1`.  It
//! measures and prints; the pass judges.  The project and the stop are made here from fixed arithmetic.

use std::time::{Duration, Instant};

use drgnx_ratatoskr::debug::record::capture;
use drgnx_ratatoskr::debug::runfile::{CAP, Frame, RunFile, RunStop};
use drgnx_ratatoskr::debug::session::{ScopeVars, Stop};
use drgnx_ratatoskr::timeline::snapshot::take_kept;
use serde_json::json;

fn p95(mut v: Vec<Duration>) -> Duration {
    v.sort();
    v[(v.len() * 95).div_ceil(100) - 1]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

#[test]
#[ignore]
fn debug_launch_snapshot() {
    let d = tempfile::tempdir().unwrap();
    let project = d.path().join("project");
    for i in 0..5000 {
        let dir = project.join(format!("pkg{}", i / 100));
        std::fs::create_dir_all(&dir).unwrap();
        let body: String = (0..40)
            .map(|l| format!("def f_{i}_{l}(x):\n    return x * {l} + {i}\n"))
            .collect();
        std::fs::write(dir.join(format!("m{i}.py")), body).unwrap();
    }
    let state = d.path().join("checkpoints");
    let first = Instant::now();
    take_kept(&state, &project, "bench", "refs/drgnx/debug/r0").unwrap();
    let cold = first.elapsed();
    let runs: Vec<Duration> = (1..=20)
        .map(|n| {
            let t = Instant::now();
            take_kept(&state, &project, "bench", &format!("refs/drgnx/debug/r{n}")).unwrap();
            t.elapsed()
        })
        .collect();
    println!(
        "debug-launch-snapshot: 5000 files, first {:.1} ms, unchanged p95 {:.1} ms (budget 150)",
        ms(cold),
        ms(p95(runs))
    );
}

fn a_stop(epoch: u64) -> Stop {
    let var = |i: usize| json!({"name": format!("v{i}"), "value": format!("{}", i * 7), "type": "int", "variablesReference": 0});
    Stop {
        epoch,
        thread: 1,
        reason: "breakpoint".into(),
        description: None,
        all_threads: true,
        threads: (1..=8).map(|t| json!({"id": t, "name": format!("Thread-{t}")})).collect(),
        frames: (0..20)
            .map(|f| json!({"id": 1000 + f, "name": format!("fn_{f}"), "line": 10 + f, "column": 1, "source": {"path": "/p/app/m.py"}}))
            .collect(),
        total_frames: Some(20),
        exception: None,
        hit: vec![],
        frame: 1000,
        scopes: vec![
            ScopeVars {
                scope: json!({"name": "Locals", "variablesReference": 1}),
                variables: Some((0..40).map(var).collect()),
            },
            ScopeVars {
                scope: json!({"name": "Globals", "variablesReference": 2}),
                variables: Some((0..200).map(var).collect()),
            },
        ],
    }
}

#[test]
#[ignore]
fn debug_capture() {
    let d = tempfile::tempdir().unwrap();
    // sealed as the hub writes it (the capture's budget includes the encryption)
    let key = drgnx_ratatoskr::debug::runkey::random_key();
    let mut file = RunFile::create(&d.path().join("r.drun"), CAP, &key).unwrap();
    let stops: Vec<Stop> = (0..200).map(a_stop).collect();
    let runs: Vec<Duration> = stops
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let t = Instant::now();
            let c = capture(s);
            file.append(Frame::Stop {
                stop: RunStop {
                    index: i as u64,
                    t_ms: i as u64,
                    reason: s.reason.clone(),
                    thread: s.thread,
                    path: "/p/app/m.py".into(),
                    line: 10,
                    bp_hit: Some(i as u32 + 1),
                    steps: Vec::new(),
                    session: "s1".into(),
                },
                capture: c,
            });
            file.flush();
            t.elapsed()
        })
        .collect();
    println!(
        "debug-capture: 200 stops (8 threads, 20 frames, 240 variables), p95 {:.3} ms (budget 1), file {} kB",
        ms(p95(runs)),
        file.size() / 1024
    );
}
