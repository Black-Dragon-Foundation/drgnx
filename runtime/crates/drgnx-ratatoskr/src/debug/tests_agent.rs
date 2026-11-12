//! The partner agent's rules (D4, `agent.rs`) that need no hub: which matrix row gates each tool, the user's step
//! winning, and what makes a fix pass.  The tools' wiring through the hub is the conformance scenario
//! `test/conformance/debug/partner-agent.jsonl` (a mock ACP agent and the mock adapter).

use super::agent::{Predicate, action_of, passes, predicate, still_at};
use super::fork::{RunEnd, Watch};
use runstav::methods::matrix::Action;
use serde_json::json;

#[test]
fn each_tool_is_gated_by_its_row() {
    let none = json!({});
    assert_eq!(action_of("debug_read", &none), Some(Action::DebugRead));
    assert_eq!(
        action_of("debug_hypothesis", &none),
        Some(Action::DebugRead)
    );
    assert_eq!(action_of("debug_probe", &none), Some(Action::DebugProbe));
    assert_eq!(action_of("debug_fork", &none), Some(Action::DebugFork));
    assert_eq!(action_of("debug_fix", &none), Some(Action::DebugFork));
    // in the user's live process: an evaluate is live-eval, a step is drive
    assert_eq!(
        action_of("debug_live", &json!({"op": "evaluate"})),
        Some(Action::DebugLiveEval)
    );
    for op in ["continue", "next", "step-in", "step-out"] {
        assert_eq!(
            action_of("debug_live", &json!({"op": op})),
            Some(Action::DebugDrive)
        );
    }
    assert_eq!(action_of("history_fork", &none), None);
}

#[test]
fn the_users_step_wins() {
    assert!(still_at("d1", 4, Some(4)).is_ok());
    let e = still_at("d1", 4, Some(5)).unwrap_err();
    assert!(
        e.contains("moved on since stop 4") && e.contains("the user's step wins"),
        "{e}"
    );
    let e = still_at("d1", 4, None).unwrap_err();
    assert!(e.contains("not stopped"), "{e}");
}

#[test]
fn a_fix_passes_only_a_clean_exit_without_the_failure() {
    let p = predicate(&json!({"exception": "stock.py:9"})).unwrap();
    assert_eq!(
        p,
        Predicate {
            watch: Watch::Exception {
                path: "stock.py".into(),
                line: 9
            },
            not: None
        }
    );
    let clean = RunEnd {
        exit: Some(0),
        ..RunEnd::default()
    };
    assert!(passes(&p, &clean).is_ok());
    let raised = RunEnd {
        exception_at: Some(("stock.py".into(), 9)),
        ..clean.clone()
    };
    assert!(
        passes(&p, &raised)
            .unwrap_err()
            .contains("still raised at stock.py:9")
    );
    let failed = RunEnd {
        exit: Some(1),
        ..RunEnd::default()
    };
    assert!(passes(&p, &failed).unwrap_err().contains("exited with 1"));
    let slow = RunEnd {
        timed_out: true,
        ..RunEnd::default()
    };
    assert!(passes(&p, &slow).unwrap_err().contains("time box"));
    let q = predicate(&json!({"probe": "stock.py:22", "expr": "reserve", "not": "-1"})).unwrap();
    let bad = RunEnd {
        exit: Some(0),
        probe_values: vec!["3".into(), "-1".into()],
        ..RunEnd::default()
    };
    assert!(passes(&q, &bad).unwrap_err().contains("still shows -1"));
    assert!(predicate(&json!({"probe": "stock.py:22"})).is_err());
    assert!(predicate(&json!({"exception": "stock.py"})).is_err());
}
