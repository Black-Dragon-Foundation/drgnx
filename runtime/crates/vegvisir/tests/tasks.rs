//! The Tasks layer (4) between Plans and Agents, and Runs on (8): pure scenarios [D].

use vegvisir::render::LAYER_NAMES;
use vegvisir::{
    Core, EdgeKind, Event, GraphFact, ItemId, JobFact, Kind, MachineFact, SessionFact, State,
    TaskState,
};

fn sess(id: &str, task: Option<&str>, state: State) -> SessionFact {
    SessionFact {
        id: id.into(),
        name: id.into(),
        model: String::new(),
        state,
        since: 0,
        age: None,
        seq: 1,
        task: task.map(Into::into),
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

fn task(id: &str, plan: &str, done: bool) -> Event {
    Event::Graph(GraphFact::Task {
        id: id.into(),
        plan: plan.into(),
        title: format!("title {id}"),
        done,
        updated: 0,
    })
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

fn core(evs: Vec<Event>) -> Core {
    let mut c = Core::new();
    for e in evs {
        c.step(e);
    }
    c
}

#[test]
fn tasks_sit_between_plans_and_agents() {
    let c = core(vec![
        plan("p1"),
        task("t1", "p1", false),
        task("t2", "p1", false),
        Event::Session(sess("a1", Some("t2"), State::Running)),
    ]);
    let m = c.model();
    let items = m.items();
    let tasks: Vec<_> = items.values().filter(|i| i.kind == Kind::Task).collect();
    assert_eq!(tasks.len(), 2);
    assert!(tasks.iter().all(|i| i.kind.layer() == 4));
    let has = |a: &str, b: &str| {
        m.edges()
            .iter()
            .any(|e| e.from.as_str() == a && e.to.as_str() == b && e.kind == EdgeKind::CameFrom)
    };
    assert!(has("plan:p1", "task:t1"));
    assert!(has("plan:p1", "task:t2"));
    assert!(has("task:t2", "agent:a1"));
    assert!(!has("plan:p1", "agent:a1"));
    assert_eq!(Kind::Agent.layer(), 5);
}

#[test]
fn task_state_follows_its_sessions() {
    let id = |t: &str| ItemId(format!("task:{t}"));
    let c = core(vec![
        plan("p"),
        task("n", "p", false),
        task("d", "p", true),
        task("r", "p", false),
        task("y", "p", false),
        Event::Session(sess("ar", Some("r"), State::Running)),
        Event::Session(sess("ay", Some("y"), State::Running)),
        Event::Session(sess("ay2", Some("y"), State::NeedsYou)),
    ]);
    let m = c.model();
    assert_eq!(m.task_state(&id("n")), TaskState::NotStarted);
    assert_eq!(m.task_state(&id("d")), TaskState::Done);
    assert_eq!(m.task_state(&id("r")), TaskState::Running);
    assert_eq!(m.task_state(&id("y")), TaskState::NeedsYou);
    assert_eq!(TaskState::NeedsYou.glyph(), "●");
    assert_eq!(TaskState::NotStarted.word(), "not started");
    assert_eq!(TaskState::Done.glyph(), "✓");
    assert_eq!(TaskState::Running.glyph(), "▶");
}

#[test]
fn machines_are_layer_8_and_files_layer_7() {
    assert_eq!(Kind::Machine.layer(), 8);
    assert_eq!(Kind::File.layer(), 7);
    assert_eq!(Kind::Branch.layer(), 6);
    assert_eq!(LAYER_NAMES.len(), 8);
    assert_eq!(LAYER_NAMES[3], "Tasks");
    assert_eq!(LAYER_NAMES[7], "Runs on");
}

#[test]
fn a_job_chip_links_to_its_agent() {
    let mut s = sess("a1", None, State::Running);
    s.machine = Some("desk".into());
    s.job = Some(JobFact {
        id: "j1".into(),
        name: "tests".into(),
        runner: Some("desk".into()),
        state: "running".into(),
        started: 0,
        limit_min: None,
        keys: vec![],
    });
    let c = core(vec![
        Event::Machines(vec![MachineFact {
            name: "desk".into(),
            slots: 4,
            used: 1,
            reported: false,
            runner: None,
        }]),
        Event::Session(s),
    ]);
    let m = c.model();
    let machine = m
        .item(&ItemId("machine:desk".into()))
        .expect("machine item");
    assert_eq!(machine.chips.len(), 1);
    assert_eq!(machine.chips[0].links_to, Some(ItemId("agent:a1".into())));
    assert_eq!(machine.chips[0].name, "tests");
}

#[test]
fn a_session_changing_state_changes_its_tasks_row() {
    use vegvisir::{Effect, ViewKey, ViewOp, ViewState};
    let mut c = core(vec![
        plan("p"),
        task("t", "p", false),
        Event::Session(sess("a1", Some("t"), State::Running)),
    ]);
    let key = ViewKey {
        conn: 1,
        view: "v".into(),
    };
    c.step(Event::View(ViewOp::Open {
        view: key,
        state: ViewState::default(),
        shown: true,
    }));
    // the agent waits on you: the task's row says so, so the task is among what changed
    let effects = c.step(Event::Session(sess("a1", Some("t"), State::NeedsYou)));
    let changed: Vec<String> = effects
        .iter()
        .filter_map(|e| match e {
            Effect::Delta { delta, .. } => Some(delta.changed.iter().map(|i| i.0.clone())),
            Effect::Relayout { .. } => None,
        })
        .flatten()
        .collect();
    assert!(changed.contains(&"agent:a1".to_owned()), "{changed:?}");
    assert!(changed.contains(&"task:t".to_owned()), "{changed:?}");
}
