//! Timing rows for pair mode's hub side (`#[ignore]`: they run through `test/timing-rust.sh`, never in a plain
//! `cargo test`; docs/develop/hub.md, "Pair mode").

use drgnx_ratatoskr::pair::writes::hunks;
use std::time::Instant;

/// A 5,000-line file and a whole-file write of it with 20 lines changed in 5 places, one line added and one gone.
fn texts() -> (String, String) {
    let old: Vec<String> = (0..5000)
        .map(|i| format!("    let value_{i} = compute({i}, \"line {i}\");\n"))
        .collect();
    let mut new = old.clone();
    for at in [100, 1200, 2500, 3700, 4900] {
        for l in &mut new[at..at + 4] {
            *l = l.replace("compute", "recompute");
        }
    }
    new.insert(2000, "    // added by the agent\n".to_string());
    new.remove(4000);
    (old.concat(), new.concat())
}

/// A whole-file `write_file` of a 5,000-line file is diffed into hunks in 2 ms at the 95th percentile.
#[test]
#[ignore = "timing: whole_file_5000_lines_within_2_ms"]
fn whole_file_5000_lines_within_2_ms() {
    let (old, new) = texts();
    assert_eq!(hunks(&old, &new).len(), 7);
    let mut times = Vec::new();
    for _ in 0..100 {
        let t = Instant::now();
        std::hint::black_box(hunks(
            std::hint::black_box(&old),
            std::hint::black_box(&new),
        ));
        times.push(t.elapsed().as_nanos());
    }
    times.sort_unstable();
    let p95 = times[times.len() * 95 / 100];
    // the reading, for the timing lane's report (the verdict is the assert)
    eprintln!(
        "whole-file diff of 5,000 lines: p50 {} ns, p95 {p95} ns",
        times[times.len() / 2]
    );
    assert!(p95 <= 2_000_000, "whole-file diff p95 {p95} ns");
}
