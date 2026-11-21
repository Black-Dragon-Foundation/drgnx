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

/// One operation on a 5,000-line document's line authors (typing a character, an agent's three-line write) in 100 µs
/// at the 95th percentile (design §13: "per-branch range update ≤ 100 µs per op").
#[test]
#[ignore = "timing: range_update_per_op_within_100_us"]
fn range_update_per_op_within_100_us() {
    use drgnx_ratatoskr::editor::ranges::{AgentRanges, Op};
    let base: String = (1..=5000)
        .map(|n| format!("fn line_{n}() {{}}\n"))
        .collect();
    let mut g = AgentRanges::new(&base);
    let mut times = Vec::new();
    for k in 0..2_000usize {
        let at = (k * 7_919) % g.chars();
        let op = if k % 10 == 0 {
            Op {
                author: "agent:a",
                start: at,
                old_len: 0,
                inserted: "a();\nb();\nc();\n",
            }
        } else {
            Op {
                author: "user",
                start: at,
                old_len: 0,
                inserted: "x",
            }
        };
        let t = Instant::now();
        assert!(std::hint::black_box(g.apply_op(op)));
        times.push(t.elapsed().as_nanos());
    }
    times.sort_unstable();
    let p95 = times[times.len() * 95 / 100];
    eprintln!(
        "range update on 5,000 lines: p50 {} ns, p95 {p95} ns",
        times[times.len() / 2]
    );
    assert!(p95 <= 100_000, "range update: p95 {p95} ns");
}

/// Reported (off the tick): the line authors of a 5,000-line document made again from the history's blame, after a
/// restart.  An agent wrote every tenth line and the user typed on every seventh.
#[test]
#[ignore = "timing: blame_rebuild_5000_lines"]
fn blame_rebuild_5000_lines() {
    use drgnx_ratatoskr::editor::ranges::AgentRanges;
    use verdandi::{BranchKind, Cause, Change, History, Kind, Record};
    let dir = tempfile::tempdir().unwrap();
    let mut h = History::open(dir.path()).unwrap();
    let doc = h.doc_for("big.rs").unwrap();
    let br = h.branch("wt/t", BranchKind::Worktree, Some("c1")).unwrap();
    let base: String = (1..=5000)
        .map(|n| format!("fn line_{n}() {{}}\n"))
        .collect();
    h.activate(doc, br, || Ok(base.clone())).unwrap();
    let agent = h
        .peer(
            &serde_json::json!({"kind": "agent", "session": "a"}),
            Some(br),
        )
        .unwrap();
    let user = h
        .peer(&serde_json::json!({"kind": "user"}), Some(br))
        .unwrap();
    // one record per author, many lines each: line starts read from the text as it grows
    for (peer, every, ins) in [(agent, 10, "agent();"), (user, 7, "u")] {
        let mut spans = Vec::new();
        let text = h.text(doc, br).unwrap();
        let starts: Vec<usize> = std::iter::once(0)
            .chain(
                text.char_indices()
                    .filter(|(_, c)| *c == '\n')
                    .map(|(i, _)| i + 1),
            )
            .collect();
        // from the end, so the earlier offsets hold
        for (n, s) in starts.iter().enumerate().rev() {
            if n % every != 0 || *s >= text.len() {
                continue;
            }
            let mut ad = h.activate(doc, br, || unreachable!()).unwrap();
            let ch = Change {
                start: *s,
                old_len: 0,
                inserted: ins.into(),
            };
            spans.extend(ad.apply(peer, &ch).unwrap().into_iter().map(|sp| (doc, sp)));
        }
        h.record(Record {
            kind: Kind::Edits,
            author: peer,
            cause: Cause::default(),
            spans,
            parents: vec![],
            git: None,
            summary: String::new(),
            at: 0.0,
        })
        .unwrap();
    }
    let text = h.text(doc, br).unwrap();
    let n = text.chars().count();
    let t = Instant::now();
    let blame: Vec<(std::ops::Range<usize>, String)> = h
        .blame(doc, br, 0..n)
        .unwrap()
        .into_iter()
        .map(|b| {
            let who = if b.peer == agent { "agent:a" } else { "user" };
            (b.range, who.to_string())
        })
        .collect();
    let g = AgentRanges::rebuild(&text, &blame);
    let took = t.elapsed();
    // the agent's lines, less those the user typed on too
    assert_eq!(g.ranges("agent:a").len(), 500 - 72);
    eprintln!("blame rebuild of 5,000 lines: {} µs", took.as_micros());
}
