use super::*;

const PLAN: &str = "# Plan\n\n**Repo:** ../repo\n\n\
### Task 1: Add the note\n\n**Role:** implement\n\nAdd note.txt.\n\n\
### Task 2: Test the note\n\n**Role:** implement\n\nTest note.txt with three cases.\n\n\
### Task 3: Document the note\n\n**Role:** implement\n\nWrite the guide's section on notes.\n";

fn task(n: i64, state: TaskState) -> Live {
    Live {
        task: format!("J1#{n}"),
        n,
        title: format!("Task {n}"),
        plan: Some(PathBuf::from("/p.md")),
        state,
        session: Some(format!("s{n}")),
        agent: Some(format!("agent {n}")),
        edits: Vec::new(),
        reads: Vec::new(),
    }
}

fn effects_of(out: &[TaskEffect]) -> Vec<(String, Effect)> {
    out.iter().map(|e| (e.task.clone(), e.effect)).collect()
}

#[test]
fn removing_a_running_task_says_it_would_stop() {
    let new = PLAN.replace(
        "### Task 3: Document the note\n\n**Role:** implement\n\nWrite the guide's section on notes.\n",
        "",
    );
    let out = of_plan_edit(
        PLAN,
        Some(&new),
        &[task(1, TaskState::Running), task(3, TaskState::Running)],
    );
    assert_eq!(effects_of(&out), [("J1#3".to_owned(), Effect::Stops)]);
    assert_eq!(out[0].why, "Task 3 is running: it would stop.");
    assert_eq!(out[0].agent.as_deref(), Some("agent 3"));
}

#[test]
fn editing_a_running_tasks_text_says_brief_changes() {
    let new = PLAN.replace("three cases", "four cases");
    let out = of_plan_edit(
        PLAN,
        Some(&new),
        &[task(1, TaskState::Running), task(2, TaskState::Running)],
    );
    assert_eq!(
        effects_of(&out),
        [("J1#2".to_owned(), Effect::BriefChanges)]
    );
    assert_eq!(
        out[0].why,
        "Task 2 is running: its brief changes; the agent gets a steer."
    );
    // the plan's shared text reaches every running task
    let new = PLAN.replace("# Plan\n", "# Plan\n\nEvery task logs its steps.\n");
    let out = of_plan_edit(
        PLAN,
        Some(&new),
        &[task(1, TaskState::Running), task(2, TaskState::InReview)],
    );
    assert_eq!(
        effects_of(&out),
        [
            ("J1#1".to_owned(), Effect::BriefChanges),
            ("J1#2".to_owned(), Effect::BriefChanges)
        ]
    );
}

#[test]
fn editing_an_unstarted_task_has_no_effect() {
    let new = PLAN.replace("three cases", "four cases");
    // queued: its brief is read when it starts; not started or done: no row at all
    assert!(of_plan_edit(PLAN, Some(&new), &[task(2, TaskState::Queued)]).is_empty());
    assert_eq!(state_of("ready", "proposed"), None);
    assert_eq!(state_of("done", "running"), None);
    assert_eq!(state_of("pending", "running"), Some(TaskState::Queued));
    // a queued task that is removed would not start
    let gone = PLAN.replace(
        "### Task 2: Test the note\n\n**Role:** implement\n\nTest note.txt with three cases.\n\n",
        "",
    );
    let out = of_plan_edit(PLAN, Some(&gone), &[task(2, TaskState::Queued)]);
    assert_eq!(out[0].why, "Task 2 is queued: it would not start.");
}

#[test]
fn a_code_change_on_an_agents_file_overlaps() {
    let mut t5 = task(5, TaskState::Running);
    t5.edits = vec!["src/session.rs".into()];
    let mut t6 = task(6, TaskState::Running);
    t6.reads = vec!["src/front.rs".into()];
    let t7 = task(7, TaskState::Running);
    let paths = vec!["src/session.rs".to_owned(), "src/front.rs".to_owned()];
    let out = of_code(&paths, None, &[t5.clone(), t6, t7]);
    assert_eq!(
        effects_of(&out),
        [
            ("J1#5".to_owned(), Effect::Overlaps),
            ("J1#6".to_owned(), Effect::Overlaps)
        ]
    );
    assert_eq!(
        out[0].why,
        "Task 5 edits session.rs: it would need to rebase."
    );
    assert_eq!(
        out[1].why,
        "Task 6 reads front.rs: it would need to rebase."
    );
    // the change's own branch is the task's: no overlap with itself
    assert!(of_code(&paths, Some("job/J1-5"), &[t5]).is_empty());
}

#[test]
fn retiring_a_plan_stops_all_its_running_tasks() {
    let tasks = [task(1, TaskState::Running), task(2, TaskState::Queued)];
    let out = of_plan_edit(PLAN, None, &tasks);
    assert_eq!(
        effects_of(&out),
        [
            ("J1#1".to_owned(), Effect::Stops),
            ("J1#2".to_owned(), Effect::Stops)
        ]
    );
    let superseded = PLAN.replace(
        "# Plan\n",
        "# Plan\n\n**Status:** superseded by the new plan\n",
    );
    assert_eq!(of_plan_edit(PLAN, Some(&superseded), &tasks).len(), 2);
    assert!(retired(Some("# Spec\n\nStatus: Rejected\n")));
    assert!(!retired(Some("# Spec\n\n**Status:** approved\n")));
}

#[test]
fn renumbered_tasks_are_matched_not_stopped() {
    // a new Task 2 goes in: the old 2 and 3 are now 3 and 4, with their text unchanged
    let new = PLAN
        .replace("### Task 3: Document", "### Task 4: Document")
        .replace("### Task 2: Test", "### Task 2: Check the input\n\n**Role:** implement\n\nCheck the input.\n\n### Task 3: Test");
    let tasks = [
        task(1, TaskState::Running),
        task(2, TaskState::Running),
        task(3, TaskState::Running),
    ];
    assert!(
        of_plan_edit(PLAN, Some(&new), &tasks).is_empty(),
        "{:?}",
        of_plan_edit(PLAN, Some(&new), &tasks)
    );
    let (old, new) = (saga::plan::parse(PLAN), saga::plan::parse(&new));
    assert_eq!(align(&old.tasks, &new.tasks), [Some(0), Some(2), Some(3)]);
}
