//! List entries carry the item's budget and target (budget plan Task 4a): a meter chip on spec, plan, task and agent
//! rows that have spend, a target only on spec and plan rows.  Pure.

use vegvisir::list::{self, ListChip};
use vegvisir::model::{ItemBudget, Num};
use vegvisir::{Core, Event, GraphFact, Instant, ViewState};

fn budget(item: &str, spent: f64, limit: Option<f64>, state: &str) -> Event {
    Event::Graph(GraphFact::Budget {
        item: item.into(),
        budget: Some(ItemBudget {
            spent: Num(spent),
            limit: limit.map(Num),
            unit: "usd".into(),
            state: state.into(),
        }),
    })
}

fn core() -> Core {
    let mut c = Core::new();
    for e in [
        Event::Graph(GraphFact::Spec {
            id: "s1".into(),
            title: "spec".into(),
            updated: 0,
        }),
        Event::Graph(GraphFact::Plan {
            id: "p1".into(),
            title: "plan".into(),
            rank: 1,
            progress: None,
            updated: 0,
        }),
        Event::Graph(GraphFact::Derives {
            plan: "p1".into(),
            spec: "s1".into(),
        }),
        Event::Graph(GraphFact::Task {
            id: "t1".into(),
            plan: "p1".into(),
            title: "t1".into(),
            done: false,
            updated: 0,
        }),
        Event::Graph(GraphFact::Task {
            id: "t2".into(),
            plan: "p1".into(),
            title: "t2".into(),
            done: false,
            updated: 0,
        }),
    ] {
        c.step(e);
    }
    c
}

fn entries(c: &Core) -> Vec<list::ListEntry> {
    let v = ViewState {
        filters: vegvisir::Filters {
            show: vegvisir::Show::All,
            ..vegvisir::Filters::default()
        },
        ..ViewState::default()
    };
    list::entries(c.model(), &v, 0)
}

fn of<'a>(es: &'a [list::ListEntry], item: &str) -> &'a list::ListEntry {
    es.iter().find(|e| e.item.0 == item).expect(item)
}

#[test]
fn a_plan_entry_carries_its_binding_budget() {
    let mut c = core();
    c.step(budget("plan:p1", 31.0, Some(40.0), "nearing"));
    let es = entries(&c);
    let e = of(&es, "plan:p1");
    let b = e.budget.clone().expect("the plan's budget");
    assert_eq!((b.spent, b.limit), (Num(31.0), Some(Num(40.0))));
    assert_eq!(
        e.chips.last(),
        Some(&ListChip::Meter(b)),
        "the meter is the last chip, right before the agent"
    );
}

#[test]
fn a_task_entry_with_no_limit_shows_spend_alone() {
    let mut c = core();
    c.step(budget("task:t1", 12.0, None, "none"));
    let es = entries(&c);
    let Some(ListChip::Meter(b)) = of(&es, "task:t1").chips.last().cloned() else {
        panic!("a task with spend has a meter");
    };
    assert_eq!(
        (b.spent, b.limit, b.state.as_str()),
        (Num(12.0), None, "none")
    );
    // the task with no spend and no limit has none
    let t2 = of(&es, "task:t2");
    assert!(t2.budget.is_none());
    assert!(!t2.chips.iter().any(|c| matches!(c, ListChip::Meter(_))));
}

#[test]
fn targets_only_on_spec_and_plan_entries() {
    let mut c = core();
    for item in ["spec:s1", "plan:p1", "task:t1"] {
        c.step(Event::Graph(GraphFact::Target {
            item: item.into(),
            at: Some(Instant(1_700_000_000.0)),
        }));
    }
    let es = entries(&c);
    assert_eq!(of(&es, "spec:s1").target_at, Some(Instant(1_700_000_000.0)));
    assert_eq!(of(&es, "plan:p1").target_at, Some(Instant(1_700_000_000.0)));
    assert_eq!(
        of(&es, "task:t1").target_at,
        None,
        "the model never puts a target on a task"
    );
}
