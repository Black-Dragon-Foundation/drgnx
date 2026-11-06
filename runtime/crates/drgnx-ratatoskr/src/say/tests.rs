use super::*;
use crate::settings::AgentProfile;
use runstav::methods::matrix::Role;
use serde_json::{Value, json};
use skuld::{Bound, Partial, every_order};
use std::collections::BTreeSet;

fn profile(name: &str, command: &str) -> AgentProfile {
    AgentProfile {
        name: name.into(),
        command: vec![command.into()],
        env: Vec::new(),
        mode: None,
        ai: None,
        model: None,
        tracker_tools: None,
        doc: None,
        provider: None,
        job_safe: false,
    }
}

/// The profiles the checks know: `opus` (Claude) and `codex` (whose lock a job may not run on yet).
fn known(name: &str) -> Option<AgentProfile> {
    match name {
        "opus" => Some(profile("opus", "claude-agent-acp")),
        "codex" => Some(profile("codex", "codex-acp")),
        _ => None,
    }
}

const GOOD: &str = r#"{"title": "Settings review", "tasks": [{"n": 1, "title": "Read", "role": "review", "profile": "opus", "deps": [], "body": "Read the settings code."}, {"n": 2, "title": "Fix", "role": "implement", "deps": [1], "body": "Fix what the review found."}], "budget": [{"amount": 20, "unit": "usd"}], "gate": "review"}"#;

fn good() -> Value {
    serde_json::from_str(GOOD).unwrap()
}

/// JSON in a proposal block among prose, as an agent ends its turn.
fn block(json: &str) -> String {
    format!("Here is the plan.\n```drgnx-proposal\n{json}\n```\nApprove it when it suits you.\n")
}

fn drawn(v: Value) -> Drawn {
    serde_json::from_value(v).unwrap()
}

fn problems(v: Value) -> Vec<String> {
    check_in(&drawn(v), known).unwrap_err()
}

/// Pure (D).
#[test]
fn a_block_parses() {
    let d = parse(&block(GOOD)).unwrap().unwrap();
    assert_eq!(d.title, "Settings review");
    assert_eq!(d.tasks.len(), 2);
    assert_eq!(d.tasks[0].profile.as_deref(), Some("opus"));
    assert_eq!(d.tasks[1].deps, [1]);
    assert_eq!(d.gate, Some(MergeGate::Review));
    assert_eq!(check_in(&d, known), Ok(()));
    // two blocks: which one the agent meant is not guessed
    let two = format!("{}{}", block(GOOD), block(GOOD));
    assert!(parse(&two).unwrap().is_err());
}

/// Pure (D): a question is not an error.
#[test]
fn no_block_is_none() {
    assert!(parse("Which settings do you mean: the hub's or the editor's?").is_none());
}

/// Pure (D): a key the format does not have is refused, at the top and in a task, so a block cannot carry grants,
/// an approval, an auto-start or a repository.
#[test]
fn an_extra_key_is_refused() {
    for (key, v) in [
        ("grants", json!(["code.edit"])),
        ("approved", json!(true)),
        ("auto", json!(true)),
        ("repo", json!("/elsewhere")),
    ] {
        let mut top = good();
        top[key] = v.clone();
        let e = parse(&block(&top.to_string())).unwrap().unwrap_err();
        assert!(e.contains(key), "{key}: {e}");
        let mut task = good();
        task["tasks"][0][key] = v;
        assert!(
            parse(&block(&task.to_string())).unwrap().is_err(),
            "{key} in a task"
        );
    }
}

/// Pure (D): a profile the settings do not have, or one no job may run on, is refused.
#[test]
fn check_refuses_an_unknown_profile() {
    let mut v = good();
    v["tasks"][0]["profile"] = json!("nope");
    let e = problems(v);
    assert!(
        e.iter().any(|m| m.contains("task 1") && m.contains("nope")),
        "{e:?}"
    );
    let mut v = good();
    v["tasks"][0]["profile"] = json!("codex");
    assert!(problems(v).iter().any(|m| m.contains("codex")));
}

/// Pure (D): `plan::check`'s message.
#[test]
fn check_refuses_a_cycle() {
    let mut v = good();
    v["tasks"][0]["deps"] = json!([2]);
    let e = problems(v);
    assert!(e.iter().any(|m| m.contains("cycle")), "{e:?}");
}

/// Pure (D).
#[test]
fn check_refuses_more_than_thirty_two_tasks() {
    let tasks: Vec<Value> = (1..=33)
        .map(|n| json!({"n": n, "title": "t", "role": "implement", "deps": [], "body": "b"}))
        .collect();
    let mut v = good();
    v["tasks"] = json!(tasks);
    let e = problems(v.clone());
    assert!(e.iter().any(|m| m.contains("33 tasks")), "{e:?}");
    v["tasks"] = json!(tasks[..32]);
    assert_eq!(check_in(&drawn(v), known), Ok(()));
}

/// Pure (D): a body is a brief, at most 16 KiB.
#[test]
fn check_refuses_a_body_over_the_brief_cap() {
    let mut v = good();
    v["tasks"][1]["body"] = json!("x".repeat(16_385));
    let e = problems(v.clone());
    assert!(
        e.iter()
            .any(|m| m.contains("task 2") && m.contains("16384")),
        "{e:?}"
    );
    v["tasks"][1]["body"] = json!("x".repeat(16_384));
    assert_eq!(check_in(&drawn(v), known), Ok(()));
}

/// Pure (D): only the job roles; never a manager's or a chat's.
#[test]
fn check_refuses_an_unknown_role() {
    for role in ["manager", "chat", "admin", ""] {
        let mut v = good();
        v["tasks"][0]["role"] = json!(role);
        let e = problems(v);
        assert!(
            e.iter()
                .any(|m| m.contains("task 1") && m.contains(&format!("{role:?}"))),
            "{role}: {e:?}"
        );
    }
    for role in ROLES {
        let mut v = good();
        v["tasks"][0]["role"] = json!(role);
        assert_eq!(check_in(&drawn(v), known), Ok(()), "{role}");
    }
}

/// Pure (D): a budget is a positive amount in dollars, exact or estimated; one with no unit is no limit at all.
#[test]
fn check_refuses_a_negative_or_unitless_budget() {
    for amount in [json!(-1), json!(0)] {
        let mut v = good();
        v["budget"] = json!([{"amount": amount, "unit": "usd"}]);
        assert!(problems(v).iter().any(|m| m.contains("budget")));
    }
    let mut v = good();
    v["budget"] = json!([{"amount": 5, "unit": "tokens"}]);
    assert!(problems(v).iter().any(|m| m.contains("budget")));
    let mut v = good();
    v["budget"] = json!([{"amount": 20}]);
    assert!(parse(&block(&v.to_string())).unwrap().is_err());
    let mut v = good();
    v["budget"] = json!([{"amount": 20, "unit": "usd-est"}]);
    assert_eq!(check_in(&drawn(v), known), Ok(()));
}

/// Pure (D): the agent hears every problem in one answer.
#[test]
fn check_says_every_problem_at_once() {
    let mut v = good();
    v["tasks"][0]["profile"] = json!("nope");
    v["tasks"][1]["role"] = json!("manager");
    v["budget"] = json!([{"amount": -5, "unit": "usd"}]);
    let e = problems(v);
    assert_eq!(e.len(), 3, "{e:?}");
}

/// Pure (D): a temp store.  The planning session is told the profiles, routes, roles and the project's id, and
/// nothing of the graph: no plan's title, no task's text.
#[tokio::test(flavor = "multi_thread")]
async fn the_digest_holds_no_graph_text() {
    use crate::runner::graph_plan_tests::{front, set_profiles};
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    set_profiles(
        &f,
        json!({"opus": {"command": ["claude-agent-acp"], "model": "claude-opus-5-5"}}),
    )
    .await;
    crate::runner::effects::plans_write(
        &f,
        &crate::runner::user(),
        serde_json::from_value(json!({"title": "SECRET PLAN", "tasks": [
            {"number": "1", "title": "SECRET TASK", "body": "SECRET BODY"}]}))
        .unwrap(),
    )
    .await
    .unwrap();
    let d = digest(&f, Some("project:p1"));
    assert!(
        d.contains("opus") && d.contains("claude-opus-5-5") && d.contains("project:p1"),
        "{d}"
    );
    for role in ROLES {
        assert!(d.contains(&format!("- {role}: ")), "{d}");
    }
    assert!(!d.contains("SECRET"), "{d}");
}

/// Pure (D): the planning session is a chat in its own scratch folder: no repository, no task, no job.
#[test]
fn a_chat_session_gets_no_repo() {
    let p = start_params("opus");
    assert_eq!(p.profile.as_str(), "opus");
    assert_eq!(p.role, Some(Role::Chat));
    assert!(p.cwd.is_none(), "{p:?}");
    assert!(p.task.is_none() && p.job.is_none());
    assert!(p.about.is_none() && p.document.is_none());
}

/// Pure (D): a temp store.  The planning line holds numbers only, whatever the session's steps say.
#[tokio::test(flavor = "multi_thread")]
async fn the_planning_line_is_numbers_only() {
    let dir = tempfile::tempdir().unwrap();
    let f = crate::runner::graph_plan_tests::front(dir.path());
    f.writer
        .db
        .write(
            urdr::graph::TxMeta::new("t", urdr::graph::Class::System, "test"),
            |tx| {
                tx.sql().execute_batch(
                    "insert into step (session, seq, class, start, end, tool, tokens_in, tokens_out, cache_read, \
                     cache_write, cost, cost_unit) values \
                     ('session:s1', 1, 'think', 1.0, 2.0, 'SECRET TOOL', 10, 5, 100, 20, 0.5, 'usd-est'), \
                     ('session:s1', 2, 'tool', 2.0, 3.0, 'SECRET', 1, 1, 0, 0, null, null), \
                     ('session:s2', 1, 'think', 1.0, 2.0, null, 999, 999, 0, 0, 9.0, 'usd-est')",
                )?;
                Ok(())
            },
        )
        .await
        .unwrap();
    let line = f.writer.db.read(|c| planning_of(c, "s1")).await.unwrap();
    let Value::Object(m) = &line else {
        panic!("{line}")
    };
    assert!(!m.is_empty());
    assert!(m.values().all(Value::is_number), "{line}");
    assert_eq!(line["tokens"], 137);
    assert_eq!(line["usd_est"], 0.5);
    assert!(!line.to_string().contains("SECRET"));
}

// ---- the order of one planning session, in every order (A) -----------------------------------------------------

/// What the outside raises: the agent's turn end and the shell's answers to its effects, the user's revision, a
/// stop and an end.
#[derive(Clone, Debug)]
enum Ev {
    TurnEnded,
    Checked(bool),
    Proposed(&'static str),
    Revise,
    Stop,
    End,
}
skuld::events!(Ev {
    TurnEnded,
    Checked,
    Proposed,
    Revise,
    Stop,
    End
});

/// The core, and what the shell saw of it: the prompts in flight, the jobs proposed and not stopped, the forgets, and
/// anything done after a stop or a forget.
#[derive(Default)]
struct Shell {
    core: SayCore,
    flight: u32,
    two_in_flight: bool,
    proposing: u32,
    jobs: BTreeSet<&'static str>,
    stopped: bool,
    after_stop: Vec<String>,
    forgets: u32,
    after_forget: Vec<String>,
}

impl Shell {
    fn new() -> Shell {
        let (core, fx) = SayCore::start("plan it".into());
        assert!(matches!(fx[..], [SayEffect::Prompt(_)]), "{fx:?}");
        Shell {
            core,
            flight: 1,
            ..Shell::default()
        }
    }
}

impl skuld::Core for Shell {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let ev = match ev {
            Ev::TurnEnded => {
                self.flight = self.flight.saturating_sub(1);
                SayEvent::TurnEnded {
                    message: "done".into(),
                }
            }
            Ev::Checked(true) => SayEvent::Checked(Checked::Good),
            Ev::Checked(false) => SayEvent::Checked(Checked::Bad(vec!["no".into()])),
            Ev::Proposed(job) => {
                // the shell answers a proposal it was asked for
                if self.proposing > 0 {
                    self.proposing -= 1;
                    self.jobs.insert(job);
                }
                SayEvent::Proposed {
                    job: Ok(job.into()),
                }
            }
            Ev::Revise => SayEvent::Revise {
                text: "also the docs".into(),
            },
            Ev::Stop => {
                self.stopped = !self.core.ended();
                SayEvent::Stop
            }
            Ev::End => SayEvent::End,
        };
        for fx in self.core.step(ev) {
            if self.forgets > 0 {
                self.after_forget.push(format!("{fx:?}"));
            }
            match &fx {
                SayEffect::Prompt(_) => {
                    self.two_in_flight |= self.flight > 0;
                    self.flight += 1;
                }
                SayEffect::Propose => self.proposing += 1,
                SayEffect::StopJob(j) => {
                    self.jobs.retain(|k| *k != j.as_str());
                }
                SayEffect::Forget => self.forgets += 1,
                _ => {}
            }
            if self.stopped && matches!(fx, SayEffect::Prompt(_) | SayEffect::Propose) {
                self.after_stop.push(format!("{fx:?}"));
            }
        }
        Vec::new()
    }
}

/// A (every order): a turn's end and a revision, in any order with a stop and an end, never put two prompts in
/// flight.  The shell keeps one edge: a check's answer follows its turn's end, a proposal's its check.
#[test]
fn every_order_a_turn_end_and_a_revise_give_one_prompt() {
    let mut p = Partial::new();
    p.source(
        "agent",
        vec![Ev::TurnEnded, Ev::Checked(true), Ev::Proposed("J1")],
    );
    p.source("user", vec![Ev::Revise]);
    p.source("other", vec![Ev::Stop, Ev::End]);
    let r = every_order(&p, Bound::default(), Shell::new, |s, order| {
        if s.two_in_flight {
            return Err(format!("two prompts in flight: {order:?}"));
        }
        Ok(())
    });
    assert!(r.orders > 1, "{r:?}");
}

/// A (every order): after a stop nothing is prompted or proposed, and no proposal stands.
#[test]
fn every_order_a_stop_leaves_no_prompt_and_no_job() {
    let mut p = Partial::new();
    p.source(
        "agent",
        vec![
            Ev::TurnEnded,
            Ev::Checked(true),
            Ev::Proposed("J1"),
            Ev::TurnEnded,
            Ev::Checked(true),
            Ev::Proposed("J2"),
        ],
    );
    p.source("user", vec![Ev::Revise]);
    p.source("other", vec![Ev::Stop, Ev::End]);
    let r = every_order(&p, Bound::default(), Shell::new, |s, order| {
        if !s.after_stop.is_empty() {
            return Err(format!("after the stop: {:?} in {order:?}", s.after_stop));
        }
        if s.stopped && !s.jobs.is_empty() {
            return Err(format!("{:?} still stand in {order:?}", s.jobs));
        }
        Ok(())
    });
    assert!(r.orders > 1, "{r:?}");
}

/// A (every order): two ends, a stop and a failure after three bad blocks forget the session once, and nothing
/// happens after it is forgotten.
#[test]
fn every_order_end_forgets_once() {
    let mut p = Partial::new();
    p.source(
        "agent",
        vec![
            Ev::TurnEnded,
            Ev::Checked(false),
            Ev::TurnEnded,
            Ev::Checked(false),
            Ev::TurnEnded,
            Ev::Checked(false),
            Ev::Proposed("J1"),
        ],
    );
    p.source("user", vec![Ev::Revise, Ev::End]);
    p.source("other", vec![Ev::Stop, Ev::End]);
    let r = every_order(&p, Bound::default(), Shell::new, |s, order| {
        if s.forgets != 1 {
            return Err(format!("forgotten {} times in {order:?}", s.forgets));
        }
        if !s.after_forget.is_empty() {
            return Err(format!(
                "after the forget: {:?} in {order:?}",
                s.after_forget
            ));
        }
        Ok(())
    });
    assert!(r.orders > 1, "{r:?}");
}
