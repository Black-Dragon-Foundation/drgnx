//! Reading 64 KiB of settings-shaped data takes at most 1 ms (design §16, "Ratatoskr"). A timing test, so it is
//! `#[ignore]`: run it once, alone and optimized, on the perf island:
//! `DRGNX_PERF_CPUS=2 perf-exclusive.sh … cargo test --release -p huginn --test timing -- --ignored --nocapture`.
//! Prints the median and the slowest of 200 reads.

use huginn::read::{Limits, read_all};
use std::time::Instant;

/// About 64 KiB of entries shaped like `settings.el`'s: a key, a value, comments between.
fn fixture() -> String {
    let mut s = String::from(";; settings.el\n(\n");
    let mut i = 0;
    while s.len() < 64 * 1024 {
        s.push_str(&format!(
            "  ;; entry {i}\n  (my-package-option-{i} :value (\"text {i}\" 42 -1.5 t nil 'sym [1 2 3]) :scope user :note \"a longer string, with \\\"quotes\\\"\")\n"
        ));
        i += 1;
    }
    s.push_str(")\n");
    s
}

#[test]
#[ignore = "timing: run alone and optimized (docs/develop/perf.md)"]
fn read_64_kib_within_1_ms() {
    let text = fixture();
    let bytes = text.as_bytes();
    assert!(bytes.len() >= 64 * 1024);
    read_all(bytes, Limits::default()).expect("fixture reads");
    let mut times: Vec<f64> = (0..200)
        .map(|_| {
            let t = Instant::now();
            let r = read_all(std::hint::black_box(bytes), Limits::default());
            let d = t.elapsed().as_secs_f64() * 1e3;
            drop(std::hint::black_box(r));
            d
        })
        .collect();
    times.sort_by(f64::total_cmp);
    let median = times[times.len() / 2];
    println!(
        "huginn read of {} bytes: median {median:.3} ms, max {:.3} ms",
        bytes.len(),
        times[times.len() - 1]
    );
    assert!(median <= 1.0, "median {median:.3} ms exceeds 1 ms");
}
