//! The Show filter (Active, Completed, All) and its groups: pure scenarios [D].

use vegvisir::{
    Core, Event, Filters, GraphFact, Group, ItemId, SessionFact, Show, State, Visibility, group,
    shown,
};

const DAY: u64 = 24 * 60;

fn sess(id: &str, task: &str, state: State, since: u64) -> SessionFact {
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
        branch: None,
        worktree: None,
        base: None,
        machine: None,
        slot: None,
        spend: None,
        context: None,
        progress: None,
        job: None,
    }
}

fn plan(id: &str) -> Event {
    Event::Graph(GraphFact::Plan {
        id: id.into(),
        title: id.into(),
        rank: 1,
        progress: None,
        updated: 0,
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

fn vis(c: &Core, id: &str, show: Show, days: u32) -> Visibility {
    let f = Filters {
        show,
        recent_days: days,
        ..Filters::default()
    };
    let it = c.model().item(&ItemId(id.into())).expect(id);
    shown(&it, &f, c.model().minute())
}

#[test]
fn active_hides_finished_and_old() {
    let now = 100 * DAY;
    let c = core(
        now,
        vec![
            plan("p"),
            task("old", "p", true, now - 30 * DAY),
            task("fresh", "p", true, now - DAY),
            task("run", "p", false, 0),
            Event::Session(sess("a", "run", State::Running, now - 5)),
        ],
    );
    assert_eq!(vis(&c, "task:old", Show::Active, 7), Visibility::Hidden);
    assert_eq!(vis(&c, "task:fresh", Show::Active, 7), Visibility::Normal);
    assert_eq!(vis(&c, "task:run", Show::Active, 7), Visibility::Normal);
}

/// Review Focus 2: ~300 finished records and no live agent: Active shows the Ready items, never an empty map and
/// never all 300.
#[test]
fn filter_active_on_a_quiet_project_keeps_ready() {
    let now = 400 * DAY;
    let mut evs = vec![plan("done-plan"), plan("next-plan")];
    for i in 0..300 {
        evs.push(task(&format!("d{i}"), "done-plan", true, DAY));
    }
    evs.push(task("todo", "next-plan", false, 0));
    let c = core(now, evs);
    let f = Filters::default();
    let items = c.model().items();
    let shown_ids: Vec<&ItemId> = items
        .iter()
        .filter(|(_, it)| shown(it, &f, now) != Visibility::Hidden)
        .map(|(id, _)| id)
        .collect();
    assert!(
        shown_ids.iter().any(|i| i.as_str() == "task:todo"),
        "{shown_ids:?}"
    );
    assert!(shown_ids.iter().any(|i| i.as_str() == "plan:next-plan"));
    assert!(shown_ids.len() < 10, "{}", shown_ids.len());
    let done = items
        .values()
        .filter(|it| it.done && it.kind == vegvisir::Kind::Task)
        .count();
    assert_eq!(done, 300, "the Completed row counts them");
}

#[test]
fn completed_shows_only_done_with_a_check() {
    let now = 100 * DAY;
    let c = core(
        now,
        vec![
            plan("p"),
            task("d", "p", true, 0),
            task("n", "p", false, 0),
            task("r", "p", false, 0),
            Event::Session(sess("a", "r", State::Running, now)),
        ],
    );
    assert_eq!(vis(&c, "task:d", Show::Completed, 7), Visibility::Normal);
    assert_eq!(vis(&c, "task:n", Show::Completed, 7), Visibility::Hidden);
    assert_eq!(vis(&c, "task:r", Show::Completed, 7), Visibility::Hidden);
    let it = c.model().item(&ItemId("task:d".into())).unwrap();
    assert_eq!(it.fields.task_state, Some(vegvisir::TaskState::Done));
    assert_eq!(vegvisir::TaskState::Done.glyph(), "✓");
}

#[test]
fn all_fades_completed() {
    let now = 100 * DAY;
    let c = core(
        now,
        vec![plan("p"), task("d", "p", true, 0), task("n", "p", false, 0)],
    );
    assert_eq!(vis(&c, "task:d", Show::All, 7), Visibility::Faded);
    assert_eq!(vis(&c, "task:n", Show::All, 7), Visibility::Normal);
}

#[test]
fn recent_days_moves_the_cutoff() {
    let now = 100 * DAY;
    let c = core(now, vec![plan("p"), task("t", "p", true, now - 8 * DAY)]);
    assert_eq!(vis(&c, "task:t", Show::Active, 10), Visibility::Normal);
    assert_eq!(vis(&c, "task:t", Show::Active, 7), Visibility::Hidden);
}

#[test]
fn active_groups_in_progress_then_ready() {
    let now = 100 * DAY;
    let c = core(
        now,
        vec![
            plan("p"),
            task("run", "p", false, 0),
            task("todo", "p", false, 0),
            task("ask", "p", false, 0),
            Event::Session(sess("a", "run", State::Running, now)),
            Event::Session(sess("b", "ask", State::NeedsYou, now)),
        ],
    );
    let f = Filters::default();
    let g = |id: &str| group(&c.model().item(&ItemId(id.into())).unwrap(), &f, now);
    assert_eq!(g("task:run"), Some(Group::InProgress));
    assert_eq!(g("task:ask"), Some(Group::InProgress));
    assert_eq!(g("task:todo"), Some(Group::Ready));
    let all = Filters {
        show: Show::All,
        ..Filters::default()
    };
    let it = c.model().item(&ItemId("task:run".into())).unwrap();
    assert_eq!(group(&it, &all, now), None);
}
