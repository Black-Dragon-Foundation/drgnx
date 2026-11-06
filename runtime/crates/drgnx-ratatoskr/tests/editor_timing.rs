//! Timing rows for agents in the editor (`#[ignore]`: they run through `test/timing-rust.sh`, never in a plain `cargo
//! test`; docs/develop/hub.md, "The buffer view").

use drgnx_ratatoskr::editor::project::{Pos, project};
use std::time::Instant;

/// Five agents in other worktrees projected three-way onto one 5,000-line buffer the user has edited in 2 ms at the
/// 95th percentile (the budget of design §13: "hub projection of 5 agents onto 5,000 lines ≤ 2 ms").
#[test]
#[ignore = "timing: project_5_agents_5000_lines_within_2_ms"]
fn project_5_agents_5000_lines_within_2_ms() {
    let base: String = (1..=5000)
        .map(|n| format!("fn line_{n}() {{}}\n"))
        .collect();
    // the user typed at the top, changed a block in the middle and appended
    let user = format!(
        "// the user's note\n{}// the end\n",
        base.replace("fn line_2500() {}\n", "fn line_2500() { user(); }\n")
    );
    // each agent changed a few blocks of its own
    let agents: Vec<String> = (0..5)
        .map(|a| {
            let mut t = base.clone();
            for k in 0..4 {
                let n = 200 + a * 900 + k * 37;
                t = t.replace(
                    &format!("fn line_{n}() {{}}\n"),
                    &format!("fn line_{n}() {{ agent_{a}(); }}\nfn added_{a}_{k}() {{}}\n"),
                );
            }
            t
        })
        .collect();
    let round = || {
        for (a, t) in agents.iter().enumerate() {
            let cursor = Some(Pos {
                line: u32::try_from(210 + a * 900).unwrap_or(1),
            });
            std::hint::black_box(project(&base, t, &user, cursor));
        }
    };
    round();
    let mut times = Vec::new();
    for _ in 0..60 {
        let t = Instant::now();
        round();
        times.push(t.elapsed().as_micros());
    }
    times.sort_unstable();
    let p95 = times[times.len() * 95 / 100];
    // the reading, for the timing lane's report (the verdict is the assert)
    eprintln!(
        "5 agents onto 5,000 lines: p50 {} µs, p95 {p95} µs",
        times[times.len() / 2]
    );
    assert!(p95 <= 2_000, "5 agents onto 5,000 lines: p95 {p95} µs");
}
