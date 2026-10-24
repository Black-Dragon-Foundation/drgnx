use super::*;

fn sc(v: Value) -> BudgetScope {
    serde_json::from_value(v).unwrap()
}

fn lim(amount: f64, unit: Unit) -> Limit {
    Limit { amount, unit }
}

fn left(b: &Budgets, s: &BudgetScope, unit: Unit) -> Option<f64> {
    b.remaining(s)
        .into_iter()
        .find(|(u, _)| *u == unit)
        .map(|(_, a)| a)
}

#[test]
fn nested_minimum() {
    let b = Budgets::default();
    let (plan, mgr, w1, w2) = (
        sc(json!({"plan": "plan:p"})),
        sc(json!({"manager": "m1"})),
        sc(json!({"worker": "w1"})),
        sc(json!({"worker": "w2"})),
    );
    b.link(&mgr, &plan);
    b.link(&w1, &mgr);
    b.link(&w2, &mgr);
    b.set(&plan, vec![lim(10.0, Unit::Usd)]);
    b.set(&mgr, vec![lim(4.0, Unit::Usd)]);
    b.set(&w1, vec![lim(3.0, Unit::Usd)]);
    // the least over the chain: the worker's own 3
    assert_eq!(left(&b, &w1, Unit::Usd), Some(3.0));
    assert_eq!(left(&b, &w2, Unit::Usd), Some(4.0));
    // a sibling's spend shrinks the manager's, so w1 is now limited by it
    b.spend(&w2, Unit::Usd, 2.5);
    assert_eq!(left(&b, &w1, Unit::Usd), Some(1.5));
    assert_eq!(left(&b, &plan, Unit::Usd), Some(7.5));
    // over a limit: never below 0, and the manager's limit is reached once
    let hits = b.spend(&w2, Unit::Usd, 2.0);
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].scope, mgr);
    assert_eq!(left(&b, &w1, Unit::Usd), Some(0.0));
    assert!(b.spend(&w2, Unit::Usd, 1.0).is_empty(), "reported once");
    // the sessions below the manager are the ones to pause
    let mut below: Vec<_> = b
        .members(&mgr)
        .iter()
        .filter_map(|s| session_of(s).map(str::to_string))
        .collect();
    below.sort();
    assert_eq!(below, ["m1", "w1", "w2"]);
    assert_eq!(b.members(&w1), std::slice::from_ref(&w1));
    // setting the limit again reports again when it is still reached
    assert_eq!(b.set(&mgr, vec![lim(4.0, Unit::Usd)]).len(), 1);
    assert!(b.set(&mgr, vec![lim(40.0, Unit::Usd)]).is_empty());
}

#[test]
fn units_never_mix() {
    let b = Budgets::default();
    let w = sc(json!({"worker": "w1"}));
    b.set(
        &w,
        vec![
            lim(5.0, Unit::Usd),
            lim(100.0, Unit::Tokens),
            lim(1.0, Unit::UsdEst),
        ],
    );
    b.spend(&w, Unit::Tokens, 40.0);
    b.spend(&w, Unit::UsdEst, 0.25);
    assert_eq!(
        left(&b, &w, Unit::Usd),
        Some(5.0),
        "tokens and estimates do not spend dollars"
    );
    assert_eq!(left(&b, &w, Unit::Tokens), Some(60.0));
    assert_eq!(left(&b, &w, Unit::UsdEst), Some(0.75));
    // no limit in a unit: nothing remains to report
    assert_eq!(left(&b, &w, Unit::LimitShare), None);
    b.spend(&w, Unit::LimitShare, 0.5);
    assert_eq!(left(&b, &w, Unit::LimitShare), None);
    let v = b.view(&w);
    assert_eq!(v.spent.len(), 3);
    assert!(v.spent.iter().all(|l| l.unit != Unit::Usd));
}

#[test]
fn subscription_share_is_labelled_estimate() {
    assert!(is_estimate(Unit::LimitShare) && is_estimate(Unit::UsdEst));
    assert!(!is_estimate(Unit::Usd) && !is_estimate(Unit::Tokens) && !is_estimate(Unit::Count));
    // the Claude and Codex readings
    let claude = json!({"sessionId": "s", "status": "allowed_warning", "rateLimitType": "five_hour",
        "utilization": 0.8, "resetsAt": 4_102_444_800u64});
    assert_eq!(
        meter_of("_claude/rateLimit", &claude),
        Some(("claude", 0.8, Some(4_102_444_800.0)))
    );
    let codex = json!({"primary": {"usedPercent": 42.0, "windowMinutes": 300, "resetsAt": 100},
        "secondary": {"usedPercent": 60.0, "windowMinutes": 10080, "resetsAt": 200}});
    assert_eq!(
        meter_of("_codex/rateLimits", &codex),
        Some(("codex", 0.6, Some(200.0)))
    );
    assert_eq!(
        parse_claude(&json!({"status": "rejected"})),
        Some((1.0, None))
    );
    assert_eq!(parse_claude(&json!({"status": "allowed"})), None);
    assert_eq!(meter_of("_other/x", &claude), None);
    // a session's share is its limit-share spend, and the meter's pace says it is an estimate
    let b = Budgets::default();
    let w = sc(json!({"worker": "w1"}));
    b.set(&w, vec![lim(0.2, Unit::LimitShare)]);
    assert!(
        b.reading(&w, "claude", 0.5, None, 1000.0).is_empty(),
        "the first reading is a baseline"
    );
    let hits = b.reading(&w, "claude", 0.75, None, 2000.0);
    assert_eq!(hits.len(), 1);
    assert!(hits[0].estimate());
    assert_eq!(hits[0].unit, Unit::LimitShare);
    let paces = b.pace(None, 2000.0);
    assert_eq!(paces.len(), 1);
    assert!(paces[0].estimate);
}

#[test]
fn pace_forecasts_exhaustion() {
    let b = Budgets::default();
    let w = sc(json!({"worker": "w1"}));
    // 0.1 at t=0, 0.2 an hour later: 0.1 an hour, so the remaining 0.8 lasts 8 hours
    b.reading(&w, "claude", 0.1, None, 0.0);
    b.reading(&w, "claude", 0.2, None, 3600.0);
    let p = &b.pace(Some("claude"), 3600.0)[0];
    assert!((p.used_share - 0.2).abs() < 1e-9);
    assert!((p.rate_per_hour - 0.1).abs() < 1e-9);
    assert!((p.exhausted_at.unwrap() - (3600.0 + 8.0 * 3600.0)).abs() < 1e-6);
    assert!(b.pace(Some("codex"), 3600.0).is_empty());
    // a window that resets before then is not forecast to run out
    b.reading(&w, "claude", 0.3, Some(3600.0 * 5.0), 7200.0);
    assert_eq!(b.pace(None, 7200.0)[0].exhausted_at, None);
    // a drop is a new window: the rate starts over
    b.reading(&w, "claude", 0.05, Some(1e9), 8000.0);
    let p = &b.pace(None, 8000.0)[0];
    assert_eq!(p.rate_per_hour, 0.0);
    assert_eq!(p.exhausted_at, None);
    // readings older than 24 h fall out of the window
    b.reading(&w, "claude", 0.06, None, 8000.0 + 25.0 * 3600.0);
    assert_eq!(b.pace(None, 8000.0 + 25.0 * 3600.0)[0].rate_per_hour, 0.0);
}

#[test]
fn state_survives_a_save() {
    let b = Budgets::default();
    let (m, w) = (sc(json!({"manager": "m1"})), sc(json!({"worker": "w1"})));
    b.link(&w, &m);
    b.set(&m, vec![lim(4.0, Unit::Usd)]);
    b.spend(&w, Unit::Usd, 1.0);
    let text = serde_json::to_string(&b.saved()).unwrap();
    let c = Budgets::default();
    c.restore(serde_json::from_str(&text).unwrap());
    assert_eq!(left(&c, &w, Unit::Usd), Some(3.0));
}
