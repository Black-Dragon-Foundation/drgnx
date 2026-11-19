//! Detail's Budget section and the start step of a plan (timeline and budget spec §7.2, §7.6; frontend flow plan Task
//! 22b). Pure: facts in (what `budget/get` says along the chain, what `forecast/get` or `forecast/plan` says), the lines
//! and the start fields out, so the sentences are tested without a hub.
//!
//! The Budget section has a line for each unit that has a limit or a spend, never summed across units; "Set to p90" is
//! offered only when the forecast's p90 is over the limit; "Counts toward" names each scope above the item with what it
//! has left and which one binds (the least). The start step prefills the plan's budget field with the p90 rounded up in
//! the plan's unit: `% wk` for subscription tasks, `usd` for gateway tasks, both fields for a mixed plan. A week that runs
//! out at p90 is a warning, never a block, and a prior basis is said.

use runstav::methods::forecast::{BasisLevel, Forecast, Range};
use runstav::methods::matrix::Unit;

/// One unit of an item's budget.
#[derive(Clone, Debug, PartialEq)]
pub struct UnitLine {
    pub unit: Unit,
    pub spent: f64,
    pub limit: Option<f64>,
    /// The forecast's total in this unit (p50 and p90), when there is one.
    pub forecast: Option<Range>,
}

/// One scope above the item and what it has left in a unit.
#[derive(Clone, Debug, PartialEq)]
pub struct Link {
    pub scope: &'static str,
    pub unit: Unit,
    pub remaining: f64,
}

/// An amount in UNIT as text: `$31`, `11 %` (a share of the week), `1.2M tok`, `3`.
pub fn amount_text(unit: Unit, v: f64) -> String {
    match unit {
        Unit::Usd | Unit::UsdEst => {
            if v.fract() == 0.0 {
                format!("${v:.0}")
            } else {
                format!("${v:.2}")
            }
        }
        Unit::LimitShare => format!("{:.0} %", v * 100.0),
        Unit::Tokens => {
            if v >= 1e6 {
                format!("{:.1}M tok", v / 1e6)
            } else if v >= 1e3 {
                format!("{:.0}k tok", v / 1e3)
            } else {
                format!("{v:.0} tok")
            }
        }
        Unit::Count => format!("{v:.0}"),
    }
}

fn unit_word(unit: Unit) -> &'static str {
    match unit {
        Unit::Usd => "usd",
        Unit::UsdEst => "usd (API prices)",
        Unit::LimitShare => "% wk",
        Unit::Tokens => "tokens",
        Unit::Count => "count",
    }
}

/// "Set to p90 ($46)": offered only when U's forecast p90 is over its limit.
pub fn set_to_p90(u: &UnitLine) -> Option<String> {
    let (limit, f) = (u.limit?, u.forecast?);
    (f.p90 > limit).then(|| format!("Set to p90 ({})", amount_text(u.unit, f.p90)))
}

/// The Budget section's lines: one for each unit, the unit's word first so no line mixes units.
pub fn budget_lines(units: &[UnitLine]) -> Vec<String> {
    units
        .iter()
        .map(|u| {
            let mut s = format!("{}  {}", unit_word(u.unit), amount_text(u.unit, u.spent));
            match u.limit {
                Some(l) => {
                    s.push_str(&format!(
                        " of {} · {:.0} %",
                        amount_text(u.unit, l),
                        if l > 0.0 { 100.0 * u.spent / l } else { 0.0 }
                    ));
                }
                None => s.push_str(" · no limit"),
            }
            if let Some(f) = u.forecast {
                s.push_str(&format!(
                    " · forecast {}–{} total",
                    amount_text(u.unit, f.p50),
                    amount_text(u.unit, f.p90)
                ));
            }
            if let Some(p) = set_to_p90(u) {
                s.push_str(&format!(" · {p}"));
            }
            s
        })
        .collect()
}

/// "Counts toward": a line for each scope above, then which one binds (the least remaining, in one unit).
pub fn counts_toward(chain: &[Link]) -> Vec<String> {
    let mut out: Vec<String> = chain
        .iter()
        .map(|l| format!("{} · {} left", l.scope, amount_text(l.unit, l.remaining)))
        .collect();
    if let Some(b) = chain.iter().min_by(|a, b| {
        a.remaining
            .partial_cmp(&b.remaining)
            .unwrap_or(std::cmp::Ordering::Equal)
    }) {
        out.push(format!(
            "binding: {}, {} left",
            b.scope,
            amount_text(b.unit, b.remaining)
        ));
    }
    out
}

/// A field of the start step: the budget in UNIT, prefilled (none: empty, with the NOTE saying why).
#[derive(Clone, Debug, PartialEq)]
pub struct StartField {
    pub unit: Unit,
    pub prefill: Option<f64>,
    pub note: Option<String>,
}

/// What the start step shows besides the totals.
#[derive(Clone, Debug, PartialEq)]
pub struct Start {
    pub fields: Vec<StartField>,
    /// "⚠ at p90 the week runs out Thu 14:00": a warning only, nothing is blocked.
    pub week_warning: Option<String>,
    /// Some task was forecast from the prior: the chip "from the prior: no history".
    pub prior: bool,
}

/// P90 rounded up to a whole dollar, or to a whole percent of the week.
fn round_up(unit: Unit, p90: f64) -> f64 {
    match unit {
        Unit::LimitShare => (p90 * 100.0).ceil() / 100.0,
        _ => p90.ceil(),
    }
}

/// The wire form of S.
pub fn view_of(s: &Start) -> runstav::methods::forecast::StartView {
    runstav::methods::forecast::StartView {
        fields: s
            .fields
            .iter()
            .map(|f| runstav::methods::forecast::StartField {
                unit: f.unit,
                prefill: f.prefill,
                note: f.note.clone(),
            })
            .collect(),
        week_warning: s.week_warning.clone(),
        prior: s.prior,
    }
}

/// The weekday and time of EPOCH seconds in a zone OFFSET seconds east of UTC: `Thu 14:00`.
pub fn day_time(epoch: f64, offset: i64) -> String {
    let t = epoch as i64 + offset;
    let days = t.div_euclid(86_400);
    let secs = t.rem_euclid(86_400);
    // 1970-01-01 was a Thursday
    let day = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][days.rem_euclid(7) as usize];
    format!("{day} {:02}:{:02}", secs / 3600, secs % 3600 / 60)
}

/// The start step of the plan FORECAST describes, times in the zone OFFSET seconds east of UTC.
pub fn start_of(f: &Forecast, offset: i64) -> Start {
    let mut fields = Vec::new();
    // subscription tasks: their share of the week
    if !f.pace.is_empty() {
        let p90 = f
            .pace
            .iter()
            .filter_map(|p| p.added_share.map(|r| r.p90))
            .fold(None, |a: Option<f64>, v| Some(a.map_or(v, |a| a + v)));
        fields.push(match p90 {
            Some(p) => StartField {
                unit: Unit::LimitShare,
                prefill: Some(round_up(Unit::LimitShare, p)),
                note: None,
            },
            None => StartField {
                unit: Unit::LimitShare,
                prefill: None,
                note: Some("no pace yet: there is no share to forecast".into()),
            },
        });
    }
    // gateway tasks: dollars (an estimate at API prices counts as dollars the user would see)
    if let Some(c) = f.cost.iter().find(|c| matches!(c.unit, Unit::Usd)) {
        fields.push(StartField {
            unit: Unit::Usd,
            prefill: Some(round_up(Unit::Usd, c.p90)),
            note: None,
        });
    }
    let week_warning = f.pace.iter().find(|p| p.runs_out_p90).map(|p| {
        match p.exhausted_after.or(p.exhausted_at) {
            Some(at) => format!("\u{26a0} at p90 the week runs out {}", day_time(at, offset)),
            None => "\u{26a0} at p90 the week runs out".to_owned(),
        }
    });
    let prior = f.tasks.iter().any(|t| t.basis.level == BasisLevel::Prior);
    Start {
        fields,
        week_warning,
        prior,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn forecast(cost: serde_json::Value, pace: serde_json::Value, basis: &str) -> Forecast {
        serde_json::from_value(json!({
            "tasks": [{"n": 1, "role": "implement", "profile": "p", "basis": {"level": basis, "n": 0, "other_model": false,
                       "calibrated": false, "label": "x"}, "tokens": {"p50": 1.0, "p90": 2.0},
                       "active_secs": {"p50": 1.0, "p90": 2.0}, "cost": []}],
            "tokens": {"p50": 1.0, "p90": 2.0}, "active_secs": {"p50": 1.0, "p90": 2.0},
            "wall_secs": {"p50": 1.0, "p90": 2.0}, "cost": cost, "unpriced": [], "pace": pace, "warnings": [],
            "prices_as_of": "2026-11-01", "made_at": 0.0
        }))
        .expect("a forecast")
    }

    fn pace(added_p90: Option<f64>, runs_out: bool) -> serde_json::Value {
        json!([{"provider": "claude", "used_share": 0.4,
                "added_share": added_p90.map(|p| json!({"p50": p / 2.0, "p90": p})),
                "exhausted_after": 1_700_000_000.0 + 3.0 * 86_400.0, "window": "week", "estimate": true,
                "runs_out_p90": runs_out}])
    }

    #[test]
    fn detail_budget_lists_each_unit_never_summed() {
        let lines = budget_lines(&[
            UnitLine {
                unit: Unit::Usd,
                spent: 9.0,
                limit: Some(12.0),
                forecast: None,
            },
            UnitLine {
                unit: Unit::LimitShare,
                spent: 0.11,
                limit: Some(0.15),
                forecast: Some(Range {
                    p50: 0.13,
                    p90: 0.16,
                }),
            },
        ]);
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert!(
            lines[0].starts_with("usd")
                && lines[0].contains("$9 of $12")
                && lines[0].contains("75 %"),
            "{}",
            lines[0]
        );
        assert!(
            lines[1].starts_with("% wk") && lines[1].contains("11 % of 15 %"),
            "{}",
            lines[1]
        );
        assert!(
            lines[1].contains("forecast 13 %–16 % total"),
            "{}",
            lines[1]
        );
        assert!(
            !lines[0].contains('%') || !lines[0].contains("% wk"),
            "no line mixes units"
        );
    }

    #[test]
    fn counts_toward_names_the_binding_scope() {
        let lines = counts_toward(&[
            Link {
                scope: "task",
                unit: Unit::Usd,
                remaining: 20.0,
            },
            Link {
                scope: "plan",
                unit: Unit::Usd,
                remaining: 9.0,
            },
            Link {
                scope: "spec",
                unit: Unit::Usd,
                remaining: 50.0,
            },
        ]);
        assert_eq!(
            lines.last().map(String::as_str),
            Some("binding: plan, $9 left"),
            "{lines:?}"
        );
        assert_eq!(lines.len(), 4);
    }

    #[test]
    fn set_to_p90_only_when_p90_is_over() {
        let u = |limit, p90| UnitLine {
            unit: Unit::Usd,
            spent: 1.0,
            limit,
            forecast: Some(Range { p50: 30.0, p90 }),
        };
        assert_eq!(
            set_to_p90(&u(Some(40.0), 46.0)).as_deref(),
            Some("Set to p90 ($46)")
        );
        assert_eq!(set_to_p90(&u(Some(40.0), 38.0)), None);
        assert_eq!(
            set_to_p90(&u(None, 46.0)),
            None,
            "no limit, nothing to raise"
        );
    }

    #[test]
    fn start_prefills_p90_rounded_up_in_the_plans_unit() {
        let gateway = forecast(
            json!([{"unit": "usd", "p50": 20.0, "p90": 30.2, "estimate": false}]),
            json!([]),
            "profile",
        );
        let s = start_of(&gateway, 0);
        assert_eq!(
            s.fields,
            vec![StartField {
                unit: Unit::Usd,
                prefill: Some(31.0),
                note: None
            }]
        );
        let sub = forecast(json!([]), pace(Some(0.134), false), "profile");
        let s = start_of(&sub, 0);
        assert_eq!(
            s.fields,
            vec![StartField {
                unit: Unit::LimitShare,
                prefill: Some(0.14),
                note: None
            }]
        );
    }

    #[test]
    fn a_mixed_plan_gets_both_fields() {
        let f = forecast(
            json!([{"unit": "usd", "p50": 5.0, "p90": 8.1, "estimate": false}]),
            pace(Some(0.05), false),
            "profile",
        );
        let s = start_of(&f, 0);
        let units: Vec<Unit> = s.fields.iter().map(|f| f.unit).collect();
        assert_eq!(units, vec![Unit::LimitShare, Unit::Usd]);
    }

    #[test]
    fn no_pace_yet_leaves_the_week_field_empty_and_says_why() {
        let f = forecast(json!([]), pace(None, false), "profile");
        let s = start_of(&f, 0);
        assert_eq!(s.fields.len(), 1);
        assert_eq!(s.fields[0].prefill, None);
        assert!(
            s.fields[0]
                .note
                .as_deref()
                .is_some_and(|n| n.contains("no pace yet")),
            "{s:?}"
        );
    }

    #[test]
    fn the_week_warning_names_the_day_and_never_removes_a_field() {
        let f = forecast(json!([]), pace(Some(0.7), true), "profile");
        let s = start_of(&f, 0);
        let w = s.week_warning.expect("a warning");
        // 1_700_000_000 s is Tue 2023-11-14 22:13 UTC; three days on is Fri 22:13
        assert!(w.contains("the week runs out Fri 22:13"), "{w}");
        assert_eq!(s.fields.len(), 1, "a warning blocks nothing");
        assert_eq!(
            start_of(&forecast(json!([]), pace(Some(0.1), false), "profile"), 0).week_warning,
            None
        );
    }

    #[test]
    fn a_prior_basis_is_said() {
        assert!(start_of(&forecast(json!([]), pace(Some(0.1), false), "prior"), 0).prior);
        assert!(!start_of(&forecast(json!([]), pace(Some(0.1), false), "profile"), 0).prior);
    }
    // ---- round 3: every budget the plan names, the chain and the schedule ----

    fn view(scope: &str, limits: &[(&str, f64)], spent: &[(&str, f64)], remaining: &[(&str, f64)]) -> runstav::methods::timeline::BudgetView {
        let l = |xs: &[(&str, f64)]| -> serde_json::Value {
            json!(xs.iter().map(|(u, a)| json!({"unit": u, "amount": a})).collect::<Vec<_>>())
        };
        serde_json::from_value(json!({"scope": scope_json(scope), "limits": l(limits), "spent": l(spent), "remaining": l(remaining)}))
            .expect("a budget view")
    }

    fn scope_json(scope: &str) -> serde_json::Value {
        let (kind, id) = scope.split_once(':').unwrap_or((scope, ""));
        json!({ kind: id })
    }

    /// [D] The Detail reads every budget the item's scope names (`budget/get`), not only the binding one: a unit for each
    /// of its limits and its spends.
    #[test]
    fn facts_list_every_unit_the_scope_names_not_only_the_binding_one() {
        let own = view("plan:p1", &[("usd", 12.0), ("limit-share", 0.15)], &[("usd", 9.0), ("limit-share", 0.11)], &[("usd", 3.0)]);
        let f = facts_of(&[own], None);
        let units: Vec<Unit> = f.units.iter().map(|u| u.unit).collect();
        assert_eq!(units, vec![Unit::Usd, Unit::LimitShare], "{f:?}");
        assert_eq!(f.units[0].spent, 9.0);
        assert_eq!(f.units[1].limit, Some(0.15));
        // a unit with only a spend is listed too, with no limit
        let tokens = view("plan:p1", &[], &[("tokens", 2_000_000.0)], &[]);
        let f = facts_of(&[tokens], None);
        assert_eq!(f.units.len(), 1);
        assert_eq!(f.units[0].limit, None);
    }

    /// [D] "Counts toward": each ancestor with what it has left in the units it limits, the item's own scope not among them.
    #[test]
    fn facts_chain_names_each_ancestor_with_what_it_has_left() {
        let own = view("task:t1", &[("usd", 5.0)], &[("usd", 1.0)], &[("usd", 4.0)]);
        let plan = view("plan:p1", &[("usd", 40.0)], &[("usd", 31.0)], &[("usd", 9.0)]);
        let spec = view("spec:s1", &[("usd", 100.0)], &[("usd", 40.0)], &[("usd", 60.0)]);
        let f = facts_of(&[own, plan, spec], None);
        let chain: Vec<(&str, f64)> = f.chain.iter().map(|l| (l.scope, l.remaining)).collect();
        assert_eq!(chain, vec![("plan", 9.0), ("spec", 60.0)], "{f:?}");
        assert!(counts_toward(&f.chain).last().is_some_and(|l| l == "binding: plan, $9 left"));
    }

    /// [D] The forecast's totals land on the unit they are in: dollars from the cost ranges, the week's share from the
    /// pace effects.
    #[test]
    fn facts_carry_the_forecast_of_each_unit() {
        let own = view("plan:p1", &[("usd", 40.0), ("limit-share", 0.15)], &[("usd", 9.0), ("limit-share", 0.11)], &[]);
        let fc = forecast(json!([{"unit": "usd", "p50": 30.0, "p90": 46.0, "estimate": false}]), pace(Some(0.16), false), "profile");
        let f = facts_of(&[own], Some(&fc));
        assert_eq!(f.units[0].forecast, Some(Range { p50: 30.0, p90: 46.0 }));
        assert_eq!(f.units[1].forecast, Some(Range { p50: 0.08, p90: 0.16 }));
        // p90 over the limit in both: both offer "Set to p90"
        assert!(set_to_p90(&f.units[0]).is_some() && set_to_p90(&f.units[1]).is_some());
    }

    /// [D] Spec §7.2's Schedule section: started, the finish range, the baseline and the slip, active against wall time,
    /// the machine. Times are weekdays and hours in the zone given.
    #[test]
    fn schedule_lines_show_finish_range_baseline_slip_and_active_against_wall() {
        let t0 = 1_700_000_000.0; // Tue 22:13 UTC
        let s = ScheduleFacts {
            started: Some(t0),
            finish: Some(Range { p50: t0 + 3.0 * 3600.0, p90: t0 + 5.0 * 3600.0 }),
            baseline_finish: Some(t0 + 2.0 * 3600.0),
            active_secs: Some(3.0 * 3600.0),
            wall_secs: Some(5.0 * 3600.0),
            machine: Some("desktop".into()),
            target: None,
            basis: None,
        };
        let lines = schedule_lines(&s, "plan", 0);
        let all = lines.join("\n");
        assert!(all.contains("started Tue 22:13"), "{all}");
        assert!(all.contains("finish Wed 01:13–Wed 03:13"), "{all}");
        assert!(all.contains("baseline Wed 00:13 · slipped 1 h"), "{all}");
        assert!(all.contains("active 3 h of 5 h wall"), "{all}");
        assert!(all.contains("machine desktop"), "{all}");
    }

    /// [D] A spec's or plan's Schedule has the Target field and its state; a task has none but shows its basis label.
    #[test]
    fn a_plan_row_has_its_target_field_and_a_task_its_basis_label() {
        let t0 = 1_700_000_000.0;
        let mut s = ScheduleFacts { target: Some((t0 + 86_400.0, "at risk".into())), basis: Some("12 implement tasks on sonnet, this project".into()), ..ScheduleFacts::default() };
        let plan = schedule_lines(&s, "plan", 0).join("\n");
        assert!(plan.contains("Target Wed 22:13 · at risk"), "{plan}");
        assert!(!plan.contains("12 implement tasks"), "{plan}");
        let task = schedule_lines(&s, "task", 0).join("\n");
        assert!(task.contains("Basis: 12 implement tasks on sonnet, this project"), "{task}");
        assert!(!task.contains("Target"), "{task}");
        s.target = None;
        assert!(schedule_lines(&s, "spec", 0).join("\n").contains("Target: none"), "an unset target says so");
    }

}
