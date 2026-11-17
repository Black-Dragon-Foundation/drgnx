//! The Schedule's bars and rows (`vegvisir::schedule`): the states of the timeline spec's §4, the target states on
//! specs and plans only, By machine, and the rows' parts.

use drgnx_rows::fit::Measure;
use drgnx_rows::svg::Palette;
use vegvisir::render::Env;
use vegvisir::schedule::{self, BarFacts, SchedRow, ScheduleState};
use vegvisir::trail::{Window, Zone};

struct Cols;

impl Measure for Cols {
    fn advance(&self, _role: &str, _ch: char) -> Option<f32> {
        Some(8.0)
    }
    fn fallback(&self, _role: &str) -> f32 {
        8.0
    }
}

fn env(p: &Palette) -> Env<'_> {
    Env {
        epoch: 1,
        scale: 1.0,
        tty: false,
        cell: (8, 16),
        width_px: 1000,
        palette: p,
        tty_widths: &[],
        line: (16, 80),
    }
}

/// A running task from 0 with its p50 at 100 and p90 at 200.
fn running() -> BarFacts {
    BarFacts {
        started: Some(0.0),
        start: Some(0.0),
        p50: Some(100.0),
        p90: Some(200.0),
        ..BarFacts::default()
    }
}

/// One case per state of §4's two tables.
#[test]
fn schedule_states_follow_spec_section_4() {
    let s = schedule::state_of;
    assert_eq!(s(&running(), 50.0), ScheduleState::OnTrack);
    assert_eq!(s(&running(), 150.0), ScheduleState::Behind);
    assert_eq!(s(&running(), 250.0), ScheduleState::Late);
    let waiting = BarFacts {
        waiting: true,
        ..running()
    };
    assert_eq!(s(&waiting, 250.0), ScheduleState::Waiting);
    let done = BarFacts {
        done: true,
        ended: Some(80.0),
        ..running()
    };
    assert_eq!(s(&done, 250.0), ScheduleState::Done);
    let not_started = BarFacts {
        started: None,
        start: Some(300.0),
        ..running()
    };
    assert_eq!(s(&not_started, 50.0), ScheduleState::Forecast);
    // a plan whose p50 is more than a quarter of its baseline's wall time past the baseline: slipped
    let plan = BarFacts {
        whole: true,
        baseline: Some(70.0),
        baseline_wall: Some(100.0),
        ..running()
    };
    assert_eq!(s(&plan, 50.0), ScheduleState::Slipped);
    let kept = BarFacts {
        baseline: Some(80.0),
        ..plan.clone()
    };
    assert_eq!(
        s(&kept, 50.0),
        ScheduleState::OnTrack,
        "20 % past is not slipped"
    );
    // against a target
    let target = |t: f64| BarFacts {
        target: Some(t),
        ..kept.clone()
    };
    assert_eq!(s(&target(250.0), 50.0), ScheduleState::OnTarget);
    assert_eq!(s(&target(150.0), 50.0), ScheduleState::AtRisk);
    assert_eq!(s(&target(90.0), 50.0), ScheduleState::LateVsTarget);
    assert_eq!(
        s(&target(40.0), 50.0),
        ScheduleState::LateVsTarget,
        "overdue"
    );
    let met = BarFacts {
        done: true,
        ended: Some(80.0),
        ..target(90.0)
    };
    assert_eq!(s(&met, 300.0), ScheduleState::Done);
}

/// A target belongs to a spec or a plan: a task's facts with one keep the forecast's state and draw no target.
#[test]
fn target_states_only_on_spec_and_plan_rows() {
    let task = BarFacts {
        target: Some(90.0),
        ..running()
    };
    assert_eq!(schedule::state_of(&task, 50.0), ScheduleState::OnTrack);
    let b = schedule::bar(&task, 50.0);
    assert_eq!(b.target, None);
    assert_eq!((b.started, b.done_to), (Some(0.0), Some(50.0)));
    let plan = BarFacts {
        whole: true,
        ..task
    };
    assert_eq!(schedule::state_of(&plan, 50.0), ScheduleState::LateVsTarget);
    assert_eq!(schedule::bar(&plan, 50.0).target, Some(90.0));
}

fn row(item: &str, depth: u8, machine: Option<&str>) -> SchedRow {
    SchedRow {
        item: item.into(),
        label: item.into(),
        depth,
        bar: Some(schedule::bar(
            &BarFacts {
                machine: machine.map(Into::into),
                ..running()
            },
            50.0,
        )),
    }
}

/// By machine: a heading per machine with its slots, its tasks under it in the List's order, then "Not placed yet";
/// specs and plans are left out.
#[test]
fn by_machine_puts_tasks_under_their_machine() {
    let rows = vec![
        row("spec:s", 0, None),
        row("plan:p", 1, None),
        row("task:a", 2, Some("desktop")),
        row("task:b", 2, None),
        row("task:c", 2, Some("laptop")),
        row("task:d", 2, Some("desktop")),
    ];
    let machines = vec![("desktop".to_owned(), 4, 6), ("laptop".to_owned(), 1, 2)];
    let by = schedule::by_machine(&rows, &machines);
    assert_eq!(
        by.iter()
            .map(|r| (r.item.as_str(), r.label.as_str(), r.depth))
            .collect::<Vec<_>>(),
        [
            ("machine:desktop", "desktop 4/6", 0),
            ("task:a", "task:a", 1),
            ("task:d", "task:d", 1),
            ("machine:laptop", "laptop 1/2", 0),
            ("task:c", "task:c", 1),
            ("machine:", "Not placed yet", 0),
            ("task:b", "task:b", 1),
        ]
    );
}

/// A running bar draws its done part to the now-line, its forecast to p50 and its tail to p90, each a run of its own
/// face; a late one its end cap; the row's right text names the state.
#[test]
fn a_bar_draws_its_parts_and_words() {
    let p = Palette::default();
    let e = env(&p);
    let win = Window {
        from: 0.0,
        to: 400.0,
    };
    let rows = schedule::schedule_rows(
        &[row("task:a", 2, Some("desktop"))],
        &e,
        &Cols,
        Zone(0),
        &win,
        400,
        Some(50.0),
        50.0,
    );
    assert_eq!(rows[0].key, "axis");
    assert_eq!(rows[1].key, "sched:task:a");
    let parts: Vec<&str> = rows[1]
        .props
        .iter()
        .filter(|(_, _, n, _)| n == "drgnx-work-part")
        .filter_map(|(_, _, _, v)| v.as_str())
        .collect();
    assert_eq!(parts, ["done", "p50", "p90"]);
    assert!(
        rows[1]
            .props
            .iter()
            .any(|(_, _, n, _)| n == "drgnx-work-now")
    );
    let late = SchedRow {
        bar: Some(schedule::bar(&running(), 260.0)),
        ..row("task:a", 2, None)
    };
    let rows = schedule::schedule_rows(&[late], &e, &Cols, Zone(0), &win, 400, Some(260.0), 260.0);
    assert!(
        rows[1].text.contains("late · past p90 by 0h01"),
        "{}",
        rows[1].text
    );
    assert!(
        rows[1]
            .props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-work-part" && v == "late")
    );
}
