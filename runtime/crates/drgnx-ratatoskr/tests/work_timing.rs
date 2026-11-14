//! Timing rows for the Work space's hub side (`#[ignore]`: they run through `test/timing-rust.sh`, never in a plain
//! `cargo test`; docs/develop/work-space.md).

use drgnx_ratatoskr::work::shell_read::parse;
use std::time::Instant;

const CORPUS: &str = include_str!("../src/work/shell_read/corpus.txt");

/// A shell step's command parses in 200 µs at the 95th percentile (globs are expanded by `resolve`, not here).
#[test]
#[ignore = "timing: shell_parse_within_200_us"]
fn shell_parse_within_200_us() {
    let lines: Vec<&str> = CORPUS
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .collect();
    assert!(lines.len() > 20);
    for l in &lines {
        std::hint::black_box(parse(l));
    }
    let mut times = Vec::new();
    for _ in 0..200 {
        for l in &lines {
            let t = Instant::now();
            std::hint::black_box(parse(std::hint::black_box(l)));
            times.push(t.elapsed().as_nanos());
        }
    }
    times.sort_unstable();
    let p95 = times[times.len() * 95 / 100];
    assert!(p95 <= 200_000, "shell parse p95 {p95} ns");
}
