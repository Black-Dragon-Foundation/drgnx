use super::*;

fn at(s: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(s)
}

fn seen(s: u64, text: &str) -> Seen {
    Some((at(s), text.as_bytes().to_vec()))
}

/// A job's steps reach the editor as events, never as a file it reads: each step the job wrote is one `step` event,
/// a look that finds the same file sends nothing, a file that is not a JSON object yet sends nothing, the plan goes
/// once per swap and before the step of that look; the file is named by the command's `--progress`.
#[test]
fn job_steps_are_events_not_files() {
    let argv: Vec<String> = [
        "drgnx",
        "sync",
        "--pending",
        "--wait",
        "--progress",
        "/p/t1.json",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    assert_eq!(file_of(&argv), Some(PathBuf::from("/p/t1.json")));
    assert_eq!(
        plan_of(Path::new("/p/t1.json")),
        PathBuf::from("/p/t1.json.plan.json")
    );
    assert_eq!(file_of(&argv[..5]), None);
    let mut w = Watch::default();
    assert!(w.look("j1", None, None).is_empty(), "nothing written yet");
    let e = w.look("j1", seen(1, r#"{"step":"start","tickets":[1]}"#), None);
    assert_eq!(
        e,
        [json!({"id": "j1", "step": {"step": "start", "tickets": [1]}})]
    );
    assert!(
        w.look("j1", seen(1, r#"{"step":"start","tickets":[1]}"#), None)
            .is_empty()
    );
    assert!(
        w.look("j1", seen(2, "{\"step\":\"dow"), None).is_empty(),
        "not an object yet"
    );
    let e = w.look(
        "j1",
        seen(3, r#"{"step":"swap","seq":1}"#),
        seen(3, r#"{"seq":1,"generation":4}"#),
    );
    assert_eq!(
        e,
        [
            json!({"id": "j1", "plan": {"seq": 1, "generation": 4}}),
            json!({"id": "j1", "step": {"step": "swap", "seq": 1}})
        ]
    );
    let e = w.look(
        "j1",
        seen(4, r#"{"step":"done"}"#),
        seen(3, r#"{"seq":1,"generation":4}"#),
    );
    assert_eq!(
        e,
        [json!({"id": "j1", "step": {"step": "done"}})],
        "the plan once"
    );
}
