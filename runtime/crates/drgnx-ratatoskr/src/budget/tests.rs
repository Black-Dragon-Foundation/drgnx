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

/// Pure (D): joint dollar limits count both units summed, survive a save, and a plain `set` makes them apart again.
#[test]
fn joint_dollar_limits_bind_the_sum_and_survive_a_save() {
    let b = Budgets::default();
    let p = sc(json!({"plan": "plan:p"}));
    b.set_joint(&p, vec![lim(10.0, Unit::Usd), lim(10.0, Unit::UsdEst)]);
    b.spend(&p, Unit::Usd, 4.0);
    b.spend(&p, Unit::UsdEst, 3.0);
    assert_eq!(left(&b, &p, Unit::Usd), Some(3.0));
    assert_eq!(left(&b, &p, Unit::Tokens), None);
    let c = Budgets::default();
    c.restore(serde_json::from_str(&serde_json::to_string(&b.saved()).unwrap()).unwrap());
    assert_eq!(left(&c, &p, Unit::UsdEst), Some(3.0));
    c.set(&p, vec![lim(10.0, Unit::Usd), lim(10.0, Unit::UsdEst)]);
    assert_eq!(left(&c, &p, Unit::Usd), Some(6.0));
}

/// Pure (D): a session's agent that starts a new conversation under the same session (a manager's rotation, a fresh
/// start after a restart) reports its cumulative cost from zero again; that is spent too.
#[test]
fn a_new_conversation_under_one_session_counts_its_cost_from_zero() {
    let b = Budgets::default();
    let s = sc(json!({"worker": "w1"}));
    b.spend_total_in(&s, "usd-est", "conv-1", Unit::UsdEst, 5.0);
    b.spend_total_in(&s, "usd-est", "conv-1", Unit::UsdEst, 7.0);
    b.spend_total_in(&s, "usd-est", "conv-2", Unit::UsdEst, 2.0);
    b.spend_total_in(&s, "usd-est", "conv-2", Unit::UsdEst, 3.0);
    let spent = b
        .view(&s)
        .spent
        .iter()
        .find(|l| l.unit == Unit::UsdEst)
        .map(|l| l.amount);
    assert_eq!(
        spent,
        Some(10.0),
        "7 in the first conversation, 3 in the second"
    );
}

/// Pure (D): a cumulative reading answers with what it booked, never negative.
#[test]
fn a_cumulative_reading_answers_with_the_delta_it_booked() {
    let b = Budgets::default();
    let s = sc(json!({"worker": "w1"}));
    let read = |conv: &str, total: f64| {
        b.spend_total_in(&s, "usd-est", conv, Unit::UsdEst, total)
            .delta
    };
    assert_eq!(read("c1", 5.0), 5.0);
    assert_eq!(read("c1", 7.0), 2.0);
    assert_eq!(read("c1", 6.0), 0.0, "a total that fell books nothing");
    assert_eq!(read("c2", 3.0), 3.0, "a new conversation counts from zero");
}

/// Pure (D): readings are read back from what was saved, and a row saved before the readings were kept still loads.
#[test]
fn readings_survive_a_save_and_load() {
    let b = Budgets::default();
    let w = sc(json!({"worker": "w1"}));
    b.reading(&w, "claude", 0.5, Some(9.0e9), 1000.0);
    b.reading(&w, "claude", 0.6, Some(9.0e9), 2000.0);
    let text = serde_json::to_string(&b.saved()).unwrap();
    let c = Budgets::default();
    c.restore(serde_json::from_str(&text).unwrap());
    assert_eq!(
        c.history("claude", 2000.0),
        vec![(1000.0, 0.5), (2000.0, 0.6)]
    );
    assert_eq!(c.pace(None, 2000.0), b.pace(None, 2000.0));
    assert!(!c.pace(None, 2000.0).is_empty());
    let old = r#"{"limits": [], "spent": [], "parents": []}"#;
    assert!(serde_json::from_str::<Saved>(old).is_ok());
}

/// Pure (D): one reading per quarter hour, none older than eight days, at most 768 a provider.
#[test]
fn the_history_keeps_one_reading_per_quarter_hour_for_eight_days() {
    let b = Budgets::default();
    let w = sc(json!({"worker": "w1"}));
    let nine_days = 9 * 24 * 3600;
    for t in (0..=nine_days).step_by(60) {
        b.reading(&w, "claude", 0.5, None, f64::from(t));
    }
    let now = f64::from(nine_days);
    let h = b.history("claude", now);
    assert!(h.len() <= 768, "{}", h.len());
    assert!(h.len() > 760, "{}", h.len());
    assert!(h.windows(2).all(|p| p[1].0 - p[0].0 >= 900.0));
    assert!(h.iter().all(|(t, _)| now - t < 8.0 * 24.0 * 3600.0));
}

/// Pure (D): the pace still reads the last day of readings; the longer history changes nothing there.
#[test]
fn the_rate_still_reads_the_last_day() {
    let b = Budgets::default();
    let w = sc(json!({"worker": "w1"}));
    let day = 24.0 * 3600.0;
    b.reading(&w, "claude", 0.1, None, 0.0);
    b.reading(&w, "claude", 0.5, None, 2.0 * day);
    b.reading(&w, "claude", 0.6, None, 2.0 * day + 3600.0);
    let p = &b.pace(None, 2.0 * day + 3600.0)[0];
    assert!((p.rate_per_hour - 0.1).abs() < 1e-9, "{}", p.rate_per_hour);
    assert_eq!(b.history("claude", 2.0 * day + 3600.0).len(), 3);
}

/// Pure (D): a meter that reset starts a segment; its fall is not a negative rise.
#[test]
fn a_meter_reset_is_a_segment_not_a_negative_rise() {
    let rises = rise_total(&[(0.0, 0.8), (900.0, 0.1), (1800.0, 0.3)]);
    assert!((rises - 0.2).abs() < 1e-9, "{rises}");
    assert_eq!(rise_total(&[]), 0.0);
}

/// Pure (D): every kind of scope has its own key, so a plan and a run (one job) with the same id never share a budget.
#[test]
fn scope_keys_are_distinct_per_kind() {
    let kinds = [
        "project", "spec", "plan", "run", "task", "manager", "worker",
    ];
    let keys: BTreeSet<Key> = kinds.iter().map(|k| key(&sc(json!({*k: "x"})))).collect();
    assert_eq!(keys.len(), kinds.len(), "{keys:?}");
    assert_ne!(
        key(&sc(json!({"plan": "x"}))),
        key(&sc(json!({"run": "x"})))
    );
}

/// Pure (D): a plan's limit spans its runs.  Run A spent 30 of the plan's 40, so run B starts with 10; B's worker
/// (moved to another session on the way, which keeps its links) spends 10 and the plan's limit is reached once; each
/// run's own spend is its share.
#[test]
fn a_second_run_spends_from_the_plans_limit() {
    let b = Budgets::default();
    let plan = sc(json!({"plan": "plan:p"}));
    let (run_a, run_b) = (sc(json!({"run": "A"})), sc(json!({"run": "B"})));
    let (task_a, task_b) = (
        sc(json!({"task": "task:A-1"})),
        sc(json!({"task": "task:B-1"})),
    );
    let (wa, wb, wb2) = (
        sc(json!({"worker": "wa"})),
        sc(json!({"worker": "wb"})),
        sc(json!({"worker": "wb2"})),
    );
    b.link_up(&[wa.clone(), task_a, run_a.clone(), plan.clone()]);
    b.set(&plan, vec![lim(40.0, Unit::Usd)]);
    assert!(b.spend(&wa, Unit::Usd, 30.0).is_empty());
    b.link_up(&[wb.clone(), task_b, run_b.clone(), plan.clone()]);
    assert_eq!(left(&b, &wb, Unit::Usd), Some(10.0));
    b.rekey(&wb, &wb2);
    assert_eq!(left(&b, &wb2, Unit::Usd), Some(10.0));
    let hits = b.spend(&wb2, Unit::Usd, 10.0);
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert_eq!(hits[0].scope, plan);
    let spent = |s: &BudgetScope| b.view(s).spent.iter().map(|l| l.amount).sum::<f64>();
    assert_eq!(spent(&run_a), 30.0);
    assert_eq!(spent(&run_b), 10.0);
    assert_eq!(spent(&plan), 40.0);
}

/// Pure (D): a spec's limit reaches every session of every plan under it, and every run (job) under it, bound to the
/// gateway or not.
#[test]
fn a_spec_limit_reaches_every_plan_under_it() {
    let b = Budgets::default();
    let spec = sc(json!({"spec": "spec:s"}));
    let project = sc(json!({"project": "project:q"}));
    b.link_up(&[
        sc(json!({"worker": "w1"})),
        sc(json!({"task": "task:J1-1"})),
        sc(json!({"run": "J1"})),
        sc(json!({"plan": "plan:a"})),
        spec.clone(),
        project.clone(),
    ]);
    b.link_up(&[
        sc(json!({"manager": "m2"})),
        sc(json!({"run": "J2"})),
        sc(json!({"plan": "plan:b"})),
        spec.clone(),
    ]);
    // a plan of another spec in the same project is not under it
    b.link_up(&[
        sc(json!({"worker": "w3"})),
        sc(json!({"run": "J3"})),
        sc(json!({"plan": "plan:c"})),
        project.clone(),
    ]);
    let mut below: Vec<_> = b
        .members(&spec)
        .iter()
        .filter_map(|s| session_of(s).map(str::to_string))
        .collect();
    below.sort();
    assert_eq!(below, ["m2", "w1"]);
    let mut jobs = b.jobs_under(&spec);
    jobs.sort();
    assert_eq!(jobs, ["J1", "J2"]);
    b.set(&spec, vec![lim(5.0, Unit::UsdEst)]);
    let hits = b.spend(&sc(json!({"worker": "w1"})), Unit::UsdEst, 5.0);
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert_eq!(hits[0].scope, spec);
}

/// Pure (D): worker → task → run → plan → spec → project; what remains is the least of the six.
#[test]
fn the_chain_is_worker_task_run_plan_spec_project() {
    let b = Budgets::default();
    let chain = [
        sc(json!({"worker": "w"})),
        sc(json!({"task": "task:J-1"})),
        sc(json!({"run": "J"})),
        sc(json!({"plan": "plan:p"})),
        sc(json!({"spec": "spec:s"})),
        sc(json!({"project": "project:q"})),
    ];
    b.link_up(&chain);
    // each scope's limit is the least in turn: 6 on the worker … 1 on the project
    for (i, s) in chain.iter().enumerate() {
        b.set(s, vec![lim(6.0 - i as f64, Unit::Usd)]);
    }
    for (i, s) in chain.iter().enumerate().rev() {
        assert_eq!(
            left(&b, &chain[0], Unit::Usd),
            Some(6.0 - i as f64),
            "{s:?}"
        );
        b.set(s, Vec::new());
    }
    assert_eq!(left(&b, &chain[0], Unit::Usd), None);
    assert_eq!(b.members(&chain[5]), vec![chain[0].clone()]);
}

/// Pure (D): a task named as its entity (`task:J#5`) and as the session holds it (`J#5`) is one scope: the limit set
/// on one is reached by spend under the other.
#[test]
fn an_unprefixed_task_ref_joins_its_budget() {
    let b = Budgets::default();
    let (prefixed, bare) = (sc(json!({"task": "task:J#5"})), sc(json!({"task": "J#5"})));
    assert_eq!(key(&prefixed), key(&bare));
    assert_eq!(key(&bare), "task:J#5");
    let worker = sc(json!({"worker": "w"}));
    b.link_up(&[worker.clone(), bare]);
    b.set(&prefixed, vec![lim(1.0, Unit::Usd)]);
    let hits = b.spend(&worker, Unit::Usd, 1.0);
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert_eq!(key(&hits[0].scope), "task:J#5");
}

/// Pure (D): a state saved before the scopes were split (version 1, as the user's install may hold it) kept a job with
/// no plan under `plan:JOB`, and a plan file's runs under `plan:PATH`. On load the job's scope becomes its `run`, with
/// its limit, its spend, its joint dollars and its links; the plan file's keeps its meaning; each move is counted once.
#[test]
fn an_old_per_job_plan_scope_becomes_its_run() {
    let old = json!({
        "version": 1,
        "limits": [[{"plan": "plan:job-20261101-120000"}, [{"amount": 20.0, "unit": "usd"}]],
                   [{"plan": "plan:/p/x.md"}, [{"amount": 9.0, "unit": "usd"}]],
                   [{"worker": "w1"}, [{"amount": 3.0, "unit": "usd"}]]],
        "spent": [[{"plan": "plan:job-20261101-120000"}, [{"amount": 5.0, "unit": "usd"}]]],
        "parents": [[{"worker": "w1"}, {"plan": "plan:job-20261101-120000"}],
                    [{"plan": "plan:job-20261101-120000"}, {"project": "project:q"}]],
        "joint": [{"plan": "plan:job-20261101-120000"}],
    });
    let b = Budgets::default();
    assert_eq!(b.restore(serde_json::from_value(old).unwrap()), 5);
    let run = sc(json!({"run": "job-20261101-120000"}));
    let gone = sc(json!({"plan": "plan:job-20261101-120000"}));
    assert_eq!(b.limits(&run), vec![lim(20.0, Unit::Usd)]);
    assert_eq!(b.view(&run).spent, vec![lim(5.0, Unit::Usd)]);
    assert!(b.limits(&gone).is_empty());
    assert_eq!(
        b.limits(&sc(json!({"plan": "plan:/p/x.md"}))),
        vec![lim(9.0, Unit::Usd)]
    );
    // the worker still spends from the run's limit: 20 less the 5 spent, under its own 3
    let w1 = sc(json!({"worker": "w1"}));
    assert_eq!(left(&b, &w1, Unit::Usd), Some(3.0));
    b.set(&w1, Vec::new());
    assert_eq!(left(&b, &w1, Unit::Usd), Some(15.0));
    assert_eq!(
        b.members(&sc(json!({"project": "project:q"}))),
        vec![w1.clone()]
    );
    // what this build saves reads back whole, with nothing moved
    let c = Budgets::default();
    assert_eq!(
        c.restore(serde_json::from_str(&serde_json::to_string(&b.saved()).unwrap()).unwrap()),
        0
    );
    assert_eq!(c.limits(&run), vec![lim(20.0, Unit::Usd)]);
}

/// An agent's usage update carries its cost as a number or as `{"amount", "currency"}`: one reader takes both, and
/// nothing else.
#[test]
fn a_cost_is_a_number_or_an_object_with_an_amount() {
    use serde_json::json;
    assert_eq!(cost_amount(&json!(0.25)), Some(0.25));
    assert_eq!(
        cost_amount(&json!({"amount": 0.01, "currency": "USD"})),
        Some(0.01)
    );
    for bad in [
        json!(null),
        json!("0.5"),
        json!({"currency": "USD"}),
        json!({"amount": "x"}),
        json!([0.1]),
    ] {
        assert_eq!(cost_amount(&bad), None, "{bad}");
    }
}

fn run_scope(id: &str) -> BudgetScope {
    serde_json::from_value(json!({"run": id})).unwrap()
}

#[test]
fn burn_is_the_hourly_rate_after_ten_minutes_of_spend() {
    let b = Budgets::default();
    let s = run_scope("job-1");
    b.spend_at(&s, Unit::Usd, 1.0, 1000.0);
    // under ten minutes seen: nothing yet
    assert!(b.burn(&s, 1300.0).is_empty());
    b.spend_at(&s, Unit::Usd, 1.0, 1600.0);
    // 2 usd over 1200 s is 6 usd an hour
    let burn = b.burn(&s, 2200.0);
    assert_eq!(burn.len(), 1);
    assert_eq!(burn[0].unit, Unit::Usd);
    assert!((burn[0].amount - 6.0).abs() < 1e-9, "{burn:?}");
    // an hour on, the old readings left the ring
    assert!(b.burn(&s, 1000.0 + 3700.0 + 3600.0).is_empty());
}

#[test]
fn a_scope_nears_at_eighty_percent_of_its_binding_limit() {
    let b = Budgets::default();
    let s = run_scope("job-2");
    assert_eq!(b.state(&s), BudgetState::None);
    b.set(
        &s,
        vec![Limit {
            amount: 10.0,
            unit: Unit::Usd,
        }],
    );
    assert_eq!(b.state(&s), BudgetState::Ok);
    b.spend(&s, Unit::Usd, 7.9);
    assert_eq!(b.state(&s), BudgetState::Ok);
    b.spend(&s, Unit::Usd, 0.2);
    assert_eq!(b.state(&s), BudgetState::Nearing);
    b.spend(&s, Unit::Usd, 2.0);
    assert_eq!(b.state(&s), BudgetState::Reached);
}

#[test]
fn changes_are_taken_once_with_the_ancestors() {
    let b = Budgets::default();
    let (p, r) = (run_scope("p"), run_scope("r"));
    b.link(&r, &p);
    b.spend(&r, Unit::Usd, 1.0);
    b.spend(&r, Unit::Usd, 1.0);
    let got = b.take_changed();
    assert_eq!(got.len(), 1 + 1, "{got:?}");
    assert!(b.take_changed().is_empty());
}

#[test]
fn the_binding_unit_is_the_least_remaining_share() {
    let b = Budgets::default();
    let s = run_scope("job-3");
    b.set(
        &s,
        vec![
            Limit {
                amount: 100.0,
                unit: Unit::Tokens,
            },
            Limit {
                amount: 10.0,
                unit: Unit::Usd,
            },
        ],
    );
    b.spend(&s, Unit::Tokens, 50.0); // half left
    b.spend(&s, Unit::Usd, 9.0); // a tenth left
    assert_eq!(b.binding(&s), Some((Unit::Usd, 9.0, 10.0)));
    b.spend(&s, Unit::Tokens, 45.0); // a twentieth left
    assert_eq!(b.binding(&s).map(|(u, ..)| u), Some(Unit::Tokens));
}

#[test]
fn events_coalesce_to_one_a_second_per_scope() {
    // ten spends inside one second: one event for the run and one for its plan, the last value; the next second,
    // with nothing spent, none
    let b = Budgets::default();
    let (p, r) = (run_scope("p2"), run_scope("r2"));
    b.link(&r, &p);
    for _ in 0..10 {
        b.spend(&r, Unit::Usd, 0.1);
    }
    let events = b.flush(0.0);
    assert_eq!(events.len(), 2, "{events:?}");
    let run = events.iter().find(|e| e.scope == r).unwrap();
    assert!((run.spent[0].amount - 1.0).abs() < 1e-9);
    assert!(b.flush(1.0).is_empty(), "nothing moved: no event");
    b.spend(&r, Unit::Usd, 0.1);
    assert_eq!(b.flush(2.0).len(), 2);
}

fn scope_of(kind: &str, id: &str) -> BudgetScope {
    serde_json::from_value(json!({ kind: id })).unwrap()
}

#[test]
fn tree_walks_project_to_worker() {
    let b = Budgets::default();
    let (proj, spec, plan) = (
        scope_of("project", "proj"),
        scope_of("spec", "spec:s"),
        scope_of("plan", "plan:p"),
    );
    let (run, worker) = (run_scope("job-1"), scope_of("worker", "w1"));
    b.link(&spec, &proj);
    b.link(&plan, &spec);
    b.link(&run, &plan);
    b.link(&worker, &run);
    let t = b.tree_scopes(None, None);
    let order: Vec<_> = t.iter().map(|(_, s, _)| s.clone()).collect();
    assert_eq!(
        order,
        vec![
            proj.clone(),
            spec.clone(),
            plan.clone(),
            run.clone(),
            worker.clone()
        ]
    );
    assert_eq!(t[0].2, None);
    assert_eq!(t[4].2.as_ref(), Some(&run));
    // a root and a depth cut the walk
    let sub: Vec<_> = b
        .tree_scopes(Some(&plan), Some(1))
        .into_iter()
        .map(|(_, s, _)| s)
        .collect();
    assert_eq!(sub, vec![plan, run]);
}

#[test]
fn a_run_carries_its_share_of_the_plan() {
    let b = Budgets::default();
    let plan = scope_of("plan", "plan:p");
    let (r1, r2) = (run_scope("job-1"), run_scope("job-2"));
    b.link(&r1, &plan);
    b.link(&r2, &plan);
    b.set(
        &plan,
        vec![Limit {
            amount: 100.0,
            unit: Unit::Usd,
        }],
    );
    b.spend(&r1, Unit::Usd, 6.0);
    b.spend(&r2, Unit::Usd, 4.0);
    // an unrelated unit must not dilute the share
    b.spend(&r1, Unit::Tokens, 1000.0);
    let n1 = b.node(&r1, Some(&plan), "run 1".into(), 0.0);
    let n2 = b.node(&r2, Some(&plan), "run 2".into(), 0.0);
    assert!((n1.share_of_parent.unwrap() - 0.6).abs() < 1e-9, "{n1:?}");
    assert!((n2.share_of_parent.unwrap() - 0.4).abs() < 1e-9);
    // a plan has none, and neither has a run with no plan above it
    assert_eq!(b.node(&plan, None, "p".into(), 0.0).share_of_parent, None);
    assert_eq!(b.node(&r1, None, "r".into(), 0.0).share_of_parent, None);
}

#[test]
fn tree_pages_with_after() {
    let keys: Vec<String> = (0..5).map(|i| format!("k{i}")).collect();
    let ks: Vec<&str> = keys.iter().map(String::as_str).collect();
    let (r, next) = page_of(&ks, None, 2);
    assert_eq!((r, next.as_deref()), (0..2, Some("k1")));
    let (r, next) = page_of(&ks, Some("k1"), 2);
    assert_eq!((r, next.as_deref()), (2..4, Some("k3")));
    let (r, next) = page_of(&ks, Some("k3"), 2);
    assert_eq!((r, next), (4..5, None));
    // an exact fit ends without a next
    let (r, next) = page_of(&ks, None, 5);
    assert_eq!((r, next), (0..5, None));
}
