//! List mode: the nested model and its navigation, pure scenarios [D].

use vegvisir::list::{self, ListChip};
use vegvisir::{
    Core, Event, GraphFact, Group, ItemId, MachineFact, MapMode, SessionFact, Show, State,
    TaskState, ViewState,
};

const DAY: u64 = 24 * 60;

fn sess(id: &str, task: &str, state: State, machine: Option<&str>, since: u64) -> SessionFact {
    SessionFact {
        id: id.into(),
        name: id.into(),
        model: String::new(),
        state,
        since,
        age: None,
        seq: 1,
        task: Some(task.into()),
        manager: None,
        branch: Some(format!("drgnx/{id}")),
        worktree: None,
        base: None,
        machine: machine.map(Into::into),
        slot: None,
        spend: None,
        context: None,
        progress: Some((1, 3)),
        job: None,
    }
}

fn spec(id: &str) -> Event {
    Event::Graph(GraphFact::Spec {
        id: id.into(),
        title: id.into(),
        updated: 0,
    })
}

fn plan(id: &str, rank: u64) -> Event {
    Event::Graph(GraphFact::Plan {
        id: id.into(),
        title: id.into(),
        rank,
        progress: None,
        updated: 0,
    })
}

fn derives(p: &str, s: &str) -> Event {
    Event::Graph(GraphFact::Derives {
        plan: p.into(),
        spec: s.into(),
    })
}

fn task(id: &str, plan: &str, done: bool, updated: u64) -> Event {
    Event::Graph(GraphFact::Task {
        id: id.into(),
        plan: plan.into(),
        title: id.into(),
        done,
        updated,
    })
}

fn core(now: u64, evs: Vec<Event>) -> Core {
    let mut c = Core::new();
    c.step(Event::Tick { minute: now });
    for e in evs {
        c.step(e);
    }
    c
}

fn ids(es: &[vegvisir::list::ListEntry]) -> Vec<(String, u8)> {
    es.iter().map(|e| (e.item.0.clone(), e.depth)).collect()
}

fn world(now: u64) -> Core {
    core(
        now,
        vec![
            spec("s1"),
            plan("p1", 1),
            plan("p2", 2),
            plan("loose", 3),
            derives("p1", "s1"),
            derives("p2", "s1"),
            task("t1", "p1", false, 0),
            task("t2", "p1", false, 0),
            task("t3", "p2", false, 0),
            task("t4", "loose", false, 0),
            Event::Machines(vec![MachineFact {
                name: "desktop".into(),
                slots: 4,
                used: 1,
                reported: false,
                runner: None,
            }]),
            Event::Session(sess("a1", "t2", State::Running, Some("desktop"), now)),
        ],
    )
}

#[test]
fn list_nests_spec_plan_task_in_order() {
    let now = 100 * DAY;
    let c = world(now);
    let v = ViewState {
        filters: vegvisir::Filters {
            show: Show::All,
            ..vegvisir::Filters::default()
        },
        ..ViewState::default()
    };
    let es = list::entries(c.model(), &v, now);
    assert_eq!(
        ids(&es),
        vec![
            ("spec:s1".to_owned(), 0),
            ("plan:p1".into(), 1),
            ("task:t1".into(), 2),
            ("task:t2".into(), 2),
            ("plan:p2".into(), 1),
            ("task:t3".into(), 2),
            ("spec:none".into(), 0),
            ("plan:loose".into(), 1),
            ("task:t4".into(), 2),
        ]
    );
    assert_eq!(
        ViewState::default().mode,
        MapMode::List,
        "List is the default"
    );
}

#[test]
fn a_task_row_carries_its_agent_and_machine() {
    let now = 100 * DAY;
    let c = world(now);
    let es = list::entries(c.model(), &ViewState::default(), now);
    let t2 = es.iter().find(|e| e.item.0 == "task:t2").expect("t2");
    assert_eq!(t2.agent, Some(ItemId("agent:a1".into())));
    assert_eq!(t2.machine.as_deref(), Some("desktop"));
    assert!(t2.chips.contains(&ListChip::State(TaskState::Running)));
    assert!(t2.chips.contains(&ListChip::Progress(1, 3)));
    assert!(
        t2.chips
            .iter()
            .any(|c| matches!(c, ListChip::Branch(b) if b == "a1"))
    );
    assert_eq!(t2.group, Some(Group::InProgress));
    let t1 = es.iter().find(|e| e.item.0 == "task:t1").expect("t1");
    assert_eq!(t1.agent, None);
    assert_eq!(t1.group, Some(Group::Ready));
}

#[test]
fn collapse_hides_children() {
    let now = 100 * DAY;
    let c = world(now);
    let mut v = ViewState::default();
    v.list_collapsed.insert(ItemId("plan:p1".into()));
    let es = list::entries(c.model(), &v, now);
    let got = ids(&es);
    assert!(got.contains(&("plan:p1".to_owned(), 1)));
    assert!(!got.iter().any(|(i, _)| i == "task:t1" || i == "task:t2"));
    assert!(got.contains(&("task:t3".to_owned(), 2)));
    v.list_collapsed.insert(ItemId("spec:s1".into()));
    let got = ids(&list::entries(c.model(), &v, now));
    assert!(!got.iter().any(|(i, _)| i == "plan:p2" || i == "task:t3"));
}

#[test]
fn chain_gutter_joins_only_the_selected_chain() {
    let now = 100 * DAY;
    let c = world(now);
    let es = list::entries(c.model(), &ViewState::default(), now);
    let pos = |id: &str| es.iter().position(|e| e.item.0 == id).unwrap();
    let g = list::chain_gutter(&es, c.model(), &ItemId("task:t2".into()));
    // spec -> plan -> task on t2's chain, and nothing of p2 or the loose plan
    assert!(g.contains(&(pos("spec:s1"), pos("plan:p1"))), "{g:?}");
    assert!(g.contains(&(pos("plan:p1"), pos("task:t2"))), "{g:?}");
    assert!(
        !g.iter()
            .any(|&(a, b)| a == pos("plan:p2") || b == pos("plan:p2"))
    );
    assert!(
        !g.iter()
            .any(|&(a, b)| a == pos("task:t4") || b == pos("task:t4"))
    );
}

#[test]
fn active_list_ends_with_completed_count() {
    let now = 100 * DAY;
    let c = core(
        now,
        vec![
            plan("p", 1),
            task("live", "p", false, 0),
            task("d1", "p", true, now - 30 * DAY),
            task("d2", "p", true, now - 40 * DAY),
            Event::Session(sess("a", "live", State::Running, None, now)),
        ],
    );
    let es = list::entries(c.model(), &ViewState::default(), now);
    let last = es.last().expect("entries");
    assert_eq!(last.item.0, "completed:more");
    assert_eq!(last.count, Some(2));
    assert!(!es.iter().any(|e| e.item.0 == "task:d1"));
}

#[test]
fn list_navigation_walks_rows_and_parents() {
    let now = 100 * DAY;
    let c = world(now);
    let es = list::entries(c.model(), &ViewState::default(), now);
    let id = |s: &str| ItemId(s.into());
    assert_eq!(list::list_next(&es, &id("plan:p1")), Some(id("task:t1")));
    assert_eq!(list::list_prev(&es, &id("task:t1")), Some(id("plan:p1")));
    assert_eq!(list::list_parent(&es, &id("task:t2")), Some(id("plan:p1")));
    assert_eq!(list::list_parent(&es, &id("plan:p1")), Some(id("spec:s1")));
    assert_eq!(list::list_parent(&es, &id("spec:s1")), None);
}

#[test]
fn an_empty_workspace_draws_a_line_that_says_so() {
    // the Work map of a project with nothing in it still draws: one row that is no item (no `list:N` key, no id)
    let rows = vegvisir::render::list_rows(&[], None);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].key, "empty:list");
    assert!(
        rows[0].text.contains("Nothing here yet"),
        "{:?}",
        rows[0].text
    );
    assert!(
        !rows[0].props.iter().any(|p| p.2 == "drgnx-work-id"),
        "the line is no item"
    );
}
