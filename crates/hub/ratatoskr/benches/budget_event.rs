//! The budget event's hub row (budget plan H4): 30 agents (workers under 3 runs under one plan, which sits under a
//! project) each spend ten times a second for 20 seconds; once a second the hub flushes the changed scopes into
//! `budget` events.  Two rows: a scope has at most one event a second (`events-per-scope-per-sec`, 1) and one flush
//! costs at most 4 ms at the 95th percentile (`budget-event-patch`).  Ignored in normal runs; the perf lane runs it:
//! `cargo test --release -p ratatoskr --bench budget_event -- --ignored --nocapture --test-threads 1`.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use ratatoskr::budget::Budgets;
use runstav::methods::matrix::Unit;
use runstav::methods::timeline::BudgetScope;

fn scope(kind: &str, id: &str) -> BudgetScope {
    serde_json::from_value(serde_json::json!({ kind: id })).unwrap()
}

#[test]
#[ignore = "perf lane"]
fn budget_event() {
    let b = Budgets::default();
    let plan = scope("plan", "plan:p");
    let runs: Vec<BudgetScope> = (0..3).map(|i| scope("run", &format!("job-{i}"))).collect();
    for r in &runs {
        b.link(r, &plan);
    }
    let workers: Vec<BudgetScope> = (0..30).map(|i| scope("worker", &format!("w{i}"))).collect();
    for (i, w) in workers.iter().enumerate() {
        b.link(w, &runs[i % 3]);
    }
    let mut per_flush = Vec::new();
    let mut worst_per_scope = 0usize;
    let mut now = 1_000.0;
    for _second in 0..20 {
        for _tick in 0..10 {
            for w in &workers {
                b.spend_at(w, Unit::UsdEst, 0.001, now);
            }
            now += 0.1;
        }
        let t = Instant::now();
        let changed = b.take_changed();
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        for s in &changed {
            let e = b.event_of(s, now);
            *seen
                .entry(serde_json::to_string(&e.scope).unwrap())
                .or_default() += 1;
        }
        per_flush.push(t.elapsed());
        worst_per_scope = worst_per_scope.max(seen.values().copied().max().unwrap_or(0));
    }
    per_flush.sort();
    let p95 = per_flush[(per_flush.len() * 95).div_ceil(100) - 1];
    println!(
        "budget-event: events-per-scope-per-sec {worst_per_scope}, flush p95 {:?} over {} scopes",
        p95,
        30 + 3 + 1
    );
    assert_eq!(worst_per_scope, 1, "coalescing: one event a scope a second");
    assert!(p95 < Duration::from_millis(4), "flush p95 {p95:?}");
}

/// The first page of `budget/tree` at 460 scopes: 1 project, 9 specs, 90 plans, 360 runs; the walk and the first 200
/// nodes built (what the handler does, less the graph's titles) within 20 ms.
#[test]
#[ignore = "perf lane"]
fn budget_tree() {
    let b = Budgets::default();
    let proj = scope("project", "proj");
    let mut runs = 0;
    for s in 0..9 {
        let spec = scope("spec", &format!("spec:{s}"));
        b.link(&spec, &proj);
        for p in 0..10 {
            let plan = scope("plan", &format!("plan:{s}-{p}"));
            b.link(&plan, &spec);
            for r in 0..4 {
                let run = scope("run", &format!("job-{s}-{p}-{r}"));
                b.link(&run, &plan);
                b.spend(&run, Unit::Usd, 0.01);
                runs += 1;
            }
        }
    }
    assert_eq!(runs, 360);
    let mut times = Vec::new();
    for _ in 0..50 {
        let t = Instant::now();
        let all = b.tree_scopes(None, None);
        let nodes: Vec<_> = all
            .iter()
            .take(200)
            .map(|(_, s, p)| b.node(s, p.as_ref(), String::new(), 1_000.0))
            .collect();
        assert_eq!(nodes.len(), 200);
        times.push(t.elapsed());
    }
    times.sort();
    let p95 = times[(times.len() * 95).div_ceil(100) - 1];
    println!(
        "budget-tree-open: first page p95 {p95:?} over {} scopes",
        1 + 9 + 90 + runs
    );
    assert!(p95 < Duration::from_millis(20), "first page p95 {p95:?}");
}
