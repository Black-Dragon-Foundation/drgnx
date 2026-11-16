//! A spec's, plan's or task's budget on the map item's fields (budget plan H4): set by a `Budget` fact, cleared by a
//! null one, never put on another kind of item.  Pure.

use vegvisir::model::{ItemBudget, Num};
use vegvisir::{Core, Event, GraphFact, ItemId};

fn id(s: &str) -> ItemId {
    ItemId(s.to_string())
}

fn budget(item: &str, spent: f64, state: &str) -> Event {
    Event::Graph(GraphFact::Budget {
        item: item.into(),
        budget: Some(ItemBudget {
            spent: Num(spent),
            limit: Some(Num(10.0)),
            unit: "usd".into(),
            state: state.into(),
        }),
    })
}

fn core() -> Core {
    let mut c = Core::new();
    c.step(Event::Graph(GraphFact::Plan {
        id: "p1".into(),
        title: "plan".into(),
        rank: 1,
        progress: None,
        updated: 0,
    }));
    c.step(Event::Graph(GraphFact::Task {
        id: "t1".into(),
        plan: "p1".into(),
        title: "task".into(),
        done: false,
        updated: 0,
    }));
    c
}

#[test]
fn map_items_carry_their_budget() {
    let mut c = core();
    c.step(budget("plan:p1", 8.5, "nearing"));
    c.step(budget("task:t1", 1.0, "ok"));
    let m = c.model();
    let b = m
        .item(&id("plan:p1"))
        .unwrap()
        .fields
        .budget
        .clone()
        .unwrap();
    assert_eq!((b.spent, b.state.as_str()), (Num(8.5), "nearing"));
    assert_eq!(
        m.item(&id("task:t1"))
            .unwrap()
            .fields
            .budget
            .as_ref()
            .map(|b| b.spent),
        Some(Num(1.0))
    );
}

#[test]
fn null_clears_the_budget_and_a_repeat_changes_nothing() {
    let mut c = core();
    c.step(budget("plan:p1", 1.0, "ok"));
    c.step(Event::Graph(GraphFact::Budget {
        item: "plan:p1".into(),
        budget: None,
    }));
    assert!(
        c.model()
            .item(&id("plan:p1"))
            .unwrap()
            .fields
            .budget
            .is_none()
    );
}

#[test]
fn a_budget_of_an_unknown_kind_is_ignored() {
    let mut c = core();
    c.step(budget("branch:b", 1.0, "ok"));
    assert!(
        c.model()
            .item(&id("plan:p1"))
            .unwrap()
            .fields
            .budget
            .is_none()
    );
}
