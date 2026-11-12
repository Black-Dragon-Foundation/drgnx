//! Inline values' hub row (spec §12, §8): `debug-inline`, a stop's values for a 2,000-line Python file stopped in a
//! 200-line function with 40 locals, the parse cached (at most 8 ms at the 95th percentile; the first parse is
//! printed). Ignored in normal runs; the combined gate pass runs it under the perf lock:
//! `cargo test --release -p drgnx-ratatoskr --bench debug_inline -- --ignored --nocapture --test-threads 1`.  It measures
//! and prints; the pass judges.  The file and the variables are made here from fixed arithmetic.

use std::time::{Duration, Instant};

use drgnx_ratatoskr::debug::inline::{Inline, Var};

fn p95(mut v: Vec<Duration>) -> Duration {
    v.sort();
    v[(v.len() * 95).div_ceil(100) - 1]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

#[test]
#[ignore]
fn debug_inline() {
    // 900 lines of small functions, the 200-line function, 900 lines more
    let mut text = String::new();
    for i in 0..300 {
        text.push_str(&format!(
            "def before_{i}(x):\n    y = x + {i}\n    return y\n"
        ));
    }
    text.push_str("def big(a0, a1):\n");
    for l in 0..199 {
        let v = l % 40;
        let w = (l * 7) % 40;
        text.push_str(&format!("    v{v} = v{w} + a0 * {l} if {l} > 0 else a1\n"));
    }
    for i in 0..300 {
        text.push_str(&format!(
            "def after_{i}(x):\n    y = x * {i}\n    return y\n"
        ));
    }
    assert!(text.lines().count() >= 2000);
    let vars: Vec<Var> = (0..40)
        .map(|v| Var {
            name: format!("v{v}"),
            value: format!("{}", v * 1000 + 7),
            global: false,
        })
        .chain((0..2).map(|a| Var {
            name: format!("a{a}"),
            value: "[1, 2, 3]".into(),
            global: false,
        }))
        .collect();
    let stop = 900 + 190;
    let inline = Inline::new();
    let first = Instant::now();
    let shown = inline.lines("bench.py", &text, stop, &vars, None);
    let first = first.elapsed();
    assert!(shown.len() >= 20, "{} lines shown", shown.len());
    let mut times = vec![];
    for i in 0..200u32 {
        let t = Instant::now();
        let s = inline.lines("bench.py", &text, stop - (i % 20), &vars, None);
        times.push(t.elapsed());
        std::hint::black_box(s);
    }
    assert_eq!(inline.parses(), 1);
    println!(
        "debug-inline first_ms {:.3} p95_ms {:.3} (budget 8)",
        ms(first),
        ms(p95(times))
    );
}
