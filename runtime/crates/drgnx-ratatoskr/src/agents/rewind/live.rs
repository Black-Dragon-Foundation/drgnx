//! A rewind and a fork of a live session on the mock agent (`ratatoskr-mock acp --state`, real processes): each test
//! waits for what the hub announces (a turn's last step on the step bus) or for the mock's own log line, then
//! asserts.

use super::*;
use crate::agents::Hub;
use crate::agents::session::attach_tests::Fx;
use runstav::methods::agents::{SessionStatus, StartParams};
use runstav::methods::matrix::{Role, Unit};
use serde_json::json;
use std::path::PathBuf;
use std::time::Duration;

fn hub(fx: &Fx) -> &Hub {
    &fx.front.core.agents
}

async fn start(fx: &Fx, profile: &str) -> String {
    let p: StartParams =
        serde_json::from_value(json!({"profile": profile, "cwd": fx.work()})).unwrap();
    hub(fx)
        .start(&fx.front, p, &crate::runner::user())
        .await
        .expect("a session")
        .id
}

/// The next step of SID that ends a turn (it carries the turn id), from STEPS: its `seq`.
async fn turn_end(
    steps: &mut tokio::sync::broadcast::Receiver<crate::agents::StepEvent>,
    sid: &str,
) -> i64 {
    loop {
        let s = crate::clock::timeout(Duration::from_secs(60), steps.recv())
            .await
            .expect("a step in time")
            .expect("the step bus");
        if s.session == sid && s.step.turn_id.is_some() {
            return s.step.seq as i64;
        }
    }
}

/// One turn of TEXT in SID, to its end: the `seq` of its last step.
async fn turn(fx: &Fx, sid: &str, text: &str) -> i64 {
    let mut steps = hub(fx).subscribe_steps();
    hub(fx).send(sid, text.into()).unwrap();
    turn_end(&mut steps, sid).await
}

fn lines(path: &PathBuf, key: &str) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| v.get(key).cloned())
        .collect()
}

/// The mock's prompts in LOG once one says TEXT (the mock logs a prompt as its turn begins).
async fn prompted(fx: &Fx, log: &str, text: &'static str) -> Vec<Value> {
    let path = fx.dir.path().join(log);
    crate::clock::blocking(move || {
        skuld::wait_until(&format!("the mock is prompted {text:?}"), 60, || {
            let all = lines(&path, "prompt");
            all.iter()
                .any(|p| p["text"].as_str().is_some_and(|t| t.contains(text)))
                .then_some(all)
        })
    })
    .await
    .unwrap()
}

async fn row_acp(fx: &Fx, sid: &str) -> Option<String> {
    let s = sid.to_owned();
    fx.runtime
        .read(move |c| {
            Ok(
                c.query_row("select acp from asession where sid = ?1", [&s], |r| {
                    r.get(0)
                })
                .ok(),
            )
        })
        .await
        .unwrap()
}

async fn steps_of(fx: &Fx, sid: &str) -> Vec<norn::read::steps::Step> {
    let s = format!("session:{sid}");
    fx.front
        .writer
        .db
        .read(move |c| norn::read::steps::for_session(c, &s, 0))
        .await
        .unwrap()
}

fn target(sid: &str, seq: i64) -> Target {
    Target {
        sid: sid.into(),
        seq,
    }
}

fn of(prompts: &[Value], acp: &str) -> Vec<String> {
    prompts
        .iter()
        .filter(|p| p["sessionId"] == json!(acp))
        .filter_map(|p| p["text"].as_str().map(str::to_string))
        .collect()
}

#[tokio::test]
async fn keeps_the_sid_budget_task_and_queue() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let before = row_acp(&fx, &sid).await.unwrap();
    // a turn the rewind cuts off, and a message queued behind it
    hub(&fx).send(&sid, "silent 30".into()).unwrap();
    prompted(&fx, "a.log", "silent 30").await;
    hub(&fx).send(&sid, "later".into()).unwrap();
    let level = rewind_conversation(hub(&fx), &fx.front, &target(&sid, seq), None)
        .await
        .expect("the rewind");
    assert_eq!(level, RestoreLevel::Message);
    let after = row_acp(&fx, &sid).await.expect("the row stays");
    assert_ne!(after, before, "a new conversation under the same session");
    assert!(hub(&fx).find(&sid).is_ok());
    let prompts = prompted(&fx, "a.log", "later").await;
    assert_eq!(
        of(&prompts, &after),
        ["later"],
        "the queued message, once, in the new conversation"
    );
    assert!(!of(&prompts, &before).contains(&"later".to_string()));
}

#[tokio::test]
async fn seq_continues_after_rewind() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    turn(&fx, &sid, "two").await;
    let top = steps_of(&fx, &sid)
        .await
        .iter()
        .map(|s| s.seq)
        .max()
        .unwrap();
    let mut steps = hub(&fx).subscribe_steps();
    rewind_conversation(
        hub(&fx),
        &fx.front,
        &target(&sid, seq),
        Some("again".into()),
    )
    .await
    .unwrap();
    let end = turn_end(&mut steps, &sid).await;
    assert!(end > top, "{end} after {top}");
    let acp = row_acp(&fx, &sid).await;
    let all = steps_of(&fx, &sid).await;
    let last = all.iter().find(|s| s.seq == end).unwrap();
    assert_eq!(last.acp, acp, "the step names the new conversation");
}

#[tokio::test]
async fn second_rewind_earlier_uses_the_steps_own_conversation() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let first = turn(&fx, &sid, "one").await;
    let second = turn(&fx, &sid, "two").await;
    let a = row_acp(&fx, &sid).await.unwrap();
    rewind_conversation(hub(&fx), &fx.front, &target(&sid, second), None)
        .await
        .unwrap();
    let b = row_acp(&fx, &sid).await.unwrap();
    turn(&fx, &sid, "three").await;
    rewind_conversation(hub(&fx), &fx.front, &target(&sid, first), None)
        .await
        .unwrap();
    let forks = lines(&fx.dir.path().join("a.log"), "session/fork");
    assert_eq!(forks.len(), 2, "{forks:?}");
    assert_eq!(forks[0]["from"], json!(a));
    assert_eq!(
        forks[1]["from"],
        json!(a),
        "the earlier step ran in {a}, not in {b}"
    );
    let at = steps_of(&fx, &sid)
        .await
        .into_iter()
        .find(|s| s.seq == first)
        .and_then(|s| s.message_id);
    assert_eq!(forks[1]["messageId"], json!(at));
}

#[tokio::test]
async fn failed_launch_leaves_the_row_resumable() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let a = row_acp(&fx, &sid).await.unwrap();
    // its profile is gone: the rewind plans a summary (so it takes a message), and the launch after the close cannot
    // land
    fx.write_settings(Some("mock-claude"));
    fx.front.refresh_settings().await;
    let r = rewind_conversation(
        hub(&fx),
        &fx.front,
        &target(&sid, seq),
        Some("again".into()),
    )
    .await;
    assert!(r.is_err(), "{r:?}");
    assert_eq!(row_acp(&fx, &sid).await.as_deref(), Some(a.as_str()));
    fx.write_settings(None);
    fx.front.refresh_settings().await;
    crate::agents::session::resume_closed(hub(&fx), &fx.front, &sid)
        .await
        .expect("the session resumes on its recorded conversation");
    let resumed = lines(&fx.dir.path().join("a.log"), "session/resume");
    assert_eq!(
        resumed.last().map(|r| r["sessionId"].clone()),
        Some(json!(a))
    );
}

#[tokio::test]
async fn summary_without_a_message_is_refused() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-gemini").await;
    let seq = turn(&fx, &sid, "one").await;
    let a = row_acp(&fx, &sid).await;
    let r = rewind_conversation(hub(&fx), &fx.front, &target(&sid, seq), None).await;
    let Err(e) = r else {
        panic!("a summary rewind without a message ran")
    };
    assert!(e.message.contains("needs-message"), "{}", e.message);
    // refused before anything changed
    let s = hub(&fx).find(&sid).unwrap();
    assert!(!s.is_closed() && s.status() != SessionStatus::Exited);
    assert_eq!(row_acp(&fx, &sid).await, a);
}

#[tokio::test]
async fn runs_with_no_live_session() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let a = row_acp(&fx, &sid).await.unwrap();
    hub(&fx).find(&sid).unwrap().close_now().await;
    // as at start-up: a hub that holds no session yet, on the same runtime.db
    let fresh = Hub::default();
    fresh.open_store(fx.runtime.clone());
    let level = rewind_conversation(&fresh, &fx.front, &target(&sid, seq), None)
        .await
        .expect("a rewind from the row alone");
    assert_eq!(level, RestoreLevel::Message);
    assert!(fresh.find(&sid).is_ok());
    assert_ne!(row_acp(&fx, &sid).await.unwrap(), a);
}

#[tokio::test]
async fn a_gone_session_is_session_gone() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    hub(&fx).kill(&sid).await.unwrap();
    let r = rewind_conversation(hub(&fx), &fx.front, &target(&sid, seq), Some("x".into())).await;
    let Err(e) = r else {
        panic!("a rewind of a finished session ran")
    };
    assert!(e.message.contains(SESSION_GONE), "{}", e.message);
}

#[tokio::test]
async fn first_prompt_reaches_the_agent() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    hub(&fx).send(&sid, "silent 30".into()).unwrap();
    prompted(&fx, "a.log", "silent 30").await;
    hub(&fx).send(&sid, "later".into()).unwrap();
    rewind_conversation(
        hub(&fx),
        &fx.front,
        &target(&sid, seq),
        Some("again".into()),
    )
    .await
    .unwrap();
    let after = row_acp(&fx, &sid).await.unwrap();
    let prompts = prompted(&fx, "a.log", "later").await;
    assert_eq!(
        of(&prompts, &after),
        ["again", "later"],
        "the first prompt, then the queue saved behind it"
    );
}

#[tokio::test]
async fn no_first_prompt_at_message_level_means_no_turn() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    rewind_conversation(hub(&fx), &fx.front, &target(&sid, seq), None)
        .await
        .unwrap();
    let after = row_acp(&fx, &sid).await.unwrap();
    // the first prompt the new conversation gets is the user's next one
    hub(&fx).send(&sid, "probe".into()).unwrap();
    let prompts = prompted(&fx, "a.log", "probe").await;
    assert_eq!(of(&prompts, &after), ["probe"]);
}

#[tokio::test]
async fn spend_after_a_rewind_is_counted() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let scope = crate::agents::session::scope_of(Role::Chat, &sid);
    let spent = || {
        fx.front
            .core
            .budgets
            .view(&scope)
            .spent
            .into_iter()
            .find(|l| l.unit == Unit::UsdEst)
            .map_or(0.0, |l| l.amount)
    };
    // the mock's Claude reports its conversation's running cost: 0.01 a turn so far
    assert!((spent() - 0.01).abs() < 1e-9, "{}", spent());
    let mut steps = hub(&fx).subscribe_steps();
    rewind_conversation(
        hub(&fx),
        &fx.front,
        &target(&sid, seq),
        Some("again".into()),
    )
    .await
    .unwrap();
    turn_end(&mut steps, &sid).await;
    // the fork's first reading (0.02, its second turn) counts from zero in the new conversation
    assert!((spent() - 0.03).abs() < 1e-9, "{}", spent());
}

#[tokio::test]
async fn fork_keeps_the_source_running() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let a = row_acp(&fx, &sid).await.unwrap();
    let cwd = fx.dir.path().join("fork");
    std::fs::create_dir_all(&cwd).unwrap();
    let (started, level) = fork_conversation(
        hub(&fx),
        &fx.front,
        &crate::runner::user(),
        &target(&sid, seq),
        &cwd,
        None,
        "go on".into(),
    )
    .await
    .expect("a fork");
    assert_eq!(level, RestoreLevel::Message);
    assert_ne!(started.id, sid);
    let s = hub(&fx).find(&sid).unwrap();
    assert!(!s.is_closed() && s.status() != SessionStatus::Exited);
    assert_eq!(row_acp(&fx, &sid).await.as_deref(), Some(a.as_str()));
    let b = row_acp(&fx, &started.id).await.unwrap();
    let prompts = prompted(&fx, "a.log", "go on").await;
    assert_eq!(of(&prompts, &b), ["go on"]);
    let forks = lines(&fx.dir.path().join("a.log"), "session/fork");
    assert_eq!((forks.len(), &forks[0]["from"]), (1, &json!(a)));
    let (new, src) = (format!("session:{}", started.id), format!("session:{sid}"));
    let link: Option<String> = fx
        .front
        .writer
        .db
        .read(move |c| {
            Ok(c.query_row(
                "select l.data from link l join entity s on s.n = l.src join entity d on d.n = l.dst \
                 where l.kind = 'forked_from' and s.id = ?1 and d.id = ?2",
                [&new, &src],
                |r| r.get(0),
            )
            .ok())
        })
        .await
        .unwrap();
    let data: Value = serde_json::from_str(&link.expect("forked_from")).unwrap();
    assert_eq!(
        (data["seq"].as_i64(), data["level"].as_str()),
        (Some(seq), Some("message"))
    );
}

#[tokio::test]
async fn fork_cross_provider_is_a_labelled_summary() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let (_, level) = fork_conversation(
        hub(&fx),
        &fx.front,
        &crate::runner::user(),
        &target(&sid, seq),
        &fx.work(),
        Some("mock-gemini"),
        "go on".into(),
    )
    .await
    .unwrap();
    assert_eq!(level, RestoreLevel::Summary);
    let prompts = prompted(&fx, "g.log", "go on").await;
    let text = prompts[0]["text"].as_str().unwrap();
    assert!(
        text.contains("[Handoff") && text.ends_with("go on"),
        "{text}"
    );
    assert!(lines(&fx.dir.path().join("a.log"), "session/fork").is_empty());
}

#[tokio::test]
async fn fork_of_a_finished_session_reads_its_entity() {
    let fx = Fx::new();
    let sid = start(&fx, "mock-claude").await;
    let seq = turn(&fx, &sid, "one").await;
    let a = row_acp(&fx, &sid).await.unwrap();
    hub(&fx).kill(&sid).await.unwrap();
    assert_eq!(
        row_acp(&fx, &sid).await,
        None,
        "a finished session has no row"
    );
    let (started, level) = fork_conversation(
        hub(&fx),
        &fx.front,
        &crate::runner::user(),
        &target(&sid, seq),
        &fx.work(),
        None,
        "go on".into(),
    )
    .await
    .expect("a fork of what the session left");
    assert_eq!(level, RestoreLevel::Message);
    let forks = lines(&fx.dir.path().join("a.log"), "session/fork");
    assert_eq!(forks[0]["from"], json!(a));
    let b = row_acp(&fx, &started.id).await.unwrap();
    let prompts = prompted(&fx, "a.log", "go on").await;
    assert_eq!(of(&prompts, &b), ["go on"]);
}
