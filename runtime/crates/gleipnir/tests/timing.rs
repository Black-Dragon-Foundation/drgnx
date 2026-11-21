//! The tracer's budgets (design §13, as spike S4 moved them): a notified open's round trip p95 ≤ 15 µs, and 2,000
//! traced opens add ≤ 50 ms. Measured in the opening process, traced against untraced, both under Gleipnir's
//! deny-list and behind one `bash -c`, five runs each, alternating; medians compared. Timing rows: run alone, on the
//! desktop's pinned island (`test/timing-rust.txt`), in the sandbox container.
//!
//! Pattern C (handshake) for the traced arm: the wrapper announces and parks on the reply (`trace_support`). The
//! child's timed opens are here, not in `trace_support`: this file is the crate's timing file, the only test code
//! that reads the clock.
// Linux only: the tracer is seccomp's (Android: no backend; fails closed).
#![cfg(target_os = "linux")]

mod trace_support;

use gleipnir::trace::{self as gt, ListenOptions};
use std::io::Write;
use trace_support::{
    CHILD_ENV, Kid, Sup, WRAPPER, child_command, child_line, marker_value, run, spawn,
};

/// The child's entry: does nothing unless this binary was run as a child.
#[test]
fn child() {
    if let Ok(json) = std::env::var(CHILD_ENV) {
        let c: Kid = serde_json::from_str(&json).expect("the child's description");
        if c.mode == "opens" {
            opens(&c);
            std::process::exit(0);
        }
        trace_support::child_main(&json);
    }
}

/// N timed opens of the files listed in `file`, round robin; one JSON marker with the loop's time and the per-open
/// p50 and p95 in ns.
fn opens(c: &Kid) {
    let list: Vec<std::ffi::CString> = std::fs::read_to_string(c.file.as_ref().unwrap())
        .unwrap()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| std::ffi::CString::new(l).unwrap())
        .collect();
    let mut lat = Vec::with_capacity(c.n as usize);
    let start = std::time::Instant::now();
    for i in 0..c.n as usize {
        let p = &list[i % list.len()];
        let t = std::time::Instant::now();
        // SAFETY: a NUL-terminated path; the fd is closed at once.
        let fd = unsafe { libc::open(p.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
        lat.push(t.elapsed().as_nanos() as u64);
        assert!(fd >= 0);
        // SAFETY: our own fd.
        unsafe { libc::close(fd) };
    }
    let loop_ns = start.elapsed().as_nanos();
    lat.sort_unstable();
    let pct = |p: f64| lat[((lat.len() - 1) as f64 * p).round() as usize];
    // straight to fd 1, as the support's markers go (the harness captures only `print!`)
    let mut out = std::io::stdout().lock();
    writeln!(
        out,
        "opens: {{\"loop_ns\":{loop_ns},\"p50_ns\":{},\"p95_ns\":{}}}",
        pct(0.5),
        pct(0.95)
    )
    .unwrap();
    out.flush().unwrap();
}

const OPENS: u64 = 2000;
const REPS: usize = 5;

/// One run of 2,000 timed opens: (loop ns, open p95 ns).
fn one(s: &Sup, list: &std::path::Path, traced: bool) -> (u64, u64) {
    let line = child_line(&Kid {
        mode: "opens".into(),
        n: OPENS,
        file: Some(list.to_path_buf()),
        ..Kid::default()
    });
    let exec = if traced {
        vec![WRAPPER.to_string(), line]
    } else {
        vec!["bash".into(), "-c".into(), line]
    };
    let jail = Kid {
        mode: "jail".into(),
        deny: true,
        exec,
        ..Kid::default()
    };
    let mut cmd = child_command(&jail);
    cmd.current_dir(&s.root).env(gt::SOCK_ENV, &s.sock);
    let mut child = spawn(cmd);
    let t = traced.then(|| s.trace(&mut child, ListenOptions::default()));
    let out = run(child);
    if let Some(t) = t {
        assert!(t.finish().notifications >= OPENS, "every open was notified");
    }
    let v: serde_json::Value = serde_json::from_str(
        &marker_value(&out.stdout, "opens: ")
            .unwrap_or_else(|| panic!("no result: {}", String::from_utf8_lossy(&out.stderr))),
    )
    .unwrap();
    (
        v["loop_ns"].as_u64().unwrap(),
        v["p95_ns"].as_u64().unwrap(),
    )
}

fn median(mut v: Vec<u64>) -> u64 {
    v.sort_unstable();
    v[v.len() / 2]
}

/// Untraced and traced runs, alternating: the medians of (loop, p95) for each arm.
fn measure() -> ((u64, u64), (u64, u64)) {
    let s = Sup::new();
    let paths: Vec<String> = (0..50)
        .map(|i| {
            s.file(&format!("src/f{i}.rs"), "x\n")
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    let list = s.file("list.txt", &(paths.join("\n") + "\n"));
    let (mut off, mut on) = (Vec::new(), Vec::new());
    for _ in 0..REPS {
        off.push(one(&s, &list, false));
        on.push(one(&s, &list, true));
    }
    let arm = |v: &[(u64, u64)]| {
        (
            median(v.iter().map(|x| x.0).collect()),
            median(v.iter().map(|x| x.1).collect()),
        )
    };
    (arm(&off), arm(&on))
}

#[test]
#[ignore = "timing: traced minus untraced open p95, on the pinned island"]
fn notify_round_trip_p95_within_15_us() {
    let ((_, off), (_, on)) = measure();
    let added = on.saturating_sub(off);
    eprintln!("open p95: untraced {off} ns, traced {on} ns, added {added} ns");
    assert!(
        added <= 15_000,
        "a notified open adds {added} ns at p95, over 15 µs"
    );
}

#[test]
#[ignore = "timing: 2,000 traced opens against untraced, on the pinned island"]
fn traced_2000_opens_within_budget() {
    let ((off, _), (on, _)) = measure();
    let added = on.saturating_sub(off);
    eprintln!("2,000 opens: untraced {off} ns, traced {on} ns, added {added} ns");
    assert!(
        added <= 50_000_000,
        "2,000 traced opens add {added} ns, over 50 ms"
    );
}
