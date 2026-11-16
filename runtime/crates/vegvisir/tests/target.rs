//! A spec's or plan's target date on the map item's fields (budget plan H3): set by a `Target` fact, cleared by a null
//! one, and never put on another kind of item.  Pure.

use vegvisir::{Core, Event, GraphFact, Instant, ItemId};

fn id(s: &str) -> ItemId {
    ItemId(s.to_string())
}

fn core_with_plan_and_spec() -> Core {
    let mut c = Core::new();
    for e in [
        Event::Graph(GraphFact::Plan {
            id: "p1".into(),
            title: "plan".into(),
            rank: 1,
            progress: None,
            updated: 0,
        }),
        Event::Graph(GraphFact::Spec {
            id: "s1".into(),
            title: "spec".into(),
            updated: 0,
        }),
        Event::Graph(GraphFact::Derives {
            plan: "p1".into(),
            spec: "s1".into(),
        }),
    ] {
        c.step(e);
    }
    c
}

fn target(item: &str, at: Option<f64>) -> Event {
    Event::Graph(GraphFact::Target {
        item: item.into(),
        at: at.map(Instant),
    })
}

#[test]
fn target_is_on_the_item_fields() {
    let mut c = core_with_plan_and_spec();
    c.step(target("plan:p1", Some(1_800_000_000.0)));
    c.step(target("spec:s1", Some(1_900_000_000.0)));
    let m = c.model();
    assert_eq!(
        m.item(&id("plan:p1")).unwrap().fields.target_at,
        Some(Instant(1_800_000_000.0))
    );
    assert_eq!(
        m.item(&id("spec:s1")).unwrap().fields.target_at,
        Some(Instant(1_900_000_000.0))
    );
}

#[test]
fn null_clears_the_target() {
    let mut c = core_with_plan_and_spec();
    c.step(target("plan:p1", Some(1_800_000_000.0)));
    c.step(target("plan:p1", None));
    assert_eq!(
        c.model().item(&id("plan:p1")).unwrap().fields.target_at,
        None
    );
}

#[test]
fn a_task_id_is_not_a_target_item() {
    let mut c = core_with_plan_and_spec();
    c.step(target("task:t1", Some(1.0)));
    assert!(
        c.model()
            .items()
            .values()
            .all(|i| i.fields.target_at.is_none())
    );
}
