//! The attempt state machine (`runners::attempts`) in every order of what can happen to one attempt (skuld).
//!
//! Job j1's attempt 1 runs on runner `a` (linger: a 600 s grace). The sources are what the hub hears about it: the
//! link (lost, then a `hello` listing the attempt), a restart (the hub restarted, then a `hello` that doesn't list
//! it), the runner (a `finished` frame with a wrong nonce, then the real one), the grace timer and a preemption. The
//! test plays the shell: a requeue places attempt 2 on runner `b` at once (a re-entrant `Placed`). `random_orders`
//! adds the user's cancel. A second core holds two attempts' rows (`every_order_each_row_counted_once_latest_wins`).

use drgnx_ratatoskr::runners::attempts::{
    AttemptState, Core as Attempts, Effect, Event, Listed, ListedState, PREEMPTED, Rows,
    union_result,
};
use drgnx_ratatoskr::runners::health::{StrikeCtx, is_strike};
use serde_json::{Value, json};
use skuld::{Bound, Core, Partial, every_order, random_orders};
use sleipnir::proto::{JobRef, Nonce};

const NOW: u64 = 1000;
const N1: Nonce = Nonce([1; 16]);
const N2: Nonce = Nonce([2; 16]);
const BAD: Nonce = Nonce([9; 16]);

/// The events (`Placed` is the shell's own, raised by a requeue; `Cancel` only in the random runs).
#[derive(Clone, Debug, PartialEq)]
enum Ev {
    Finished,
    LinkLost,
    GraceEnded,
    HelloListed,
    HelloNotListed,
    HubRestarted,
    Preempting,
    WrongNonce,
    Placed,
}
skuld::events!(Ev {
    Finished,
    LinkLost,
    GraceEnded,
    HelloListed,
    HelloNotListed,
    HubRestarted,
    Preempting,
    WrongNonce,
    Placed
});

#[derive(Clone, Debug, PartialEq)]
enum EvC {
    E(Ev),
    Cancel,
}
skuld::events!(EvC { E, Cancel });

fn r(attempt: u32, nonce: Nonce) -> JobRef {
    JobRef {
        job: "j1".into(),
        attempt,
        nonce,
    }
}

fn pass() -> Value {
    json!({"verdict": "Pass"})
}

fn cancelled(v: &Value) -> bool {
    v["verdict"] == "Cancelled"
}

/// The core under test and what the shell saw of it.
struct Shell {
    core: Attempts,
    /// Every effect, with the kind of event that raised it.
    seen: Vec<(&'static str, Effect)>,
    /// Attempt numbers that were requeued or lost, in order.
    ended: Vec<u32>,
    cancelled: bool,
    broken: Option<String>,
}

impl Shell {
    fn new() -> Shell {
        let mut core = Attempts::default();
        core.step(
            NOW,
            Event::Placed {
                job: "j1".into(),
                attempt: 1,
                nonce: N1,
                runner: "a".into(),
                grace_s: 600,
                restartable: true,
            },
        );
        core.step(
            NOW,
            Event::Started {
                runner: "a".into(),
                r: r(1, N1),
            },
        );
        Shell {
            core,
            seen: vec![],
            ended: vec![],
            cancelled: false,
            broken: None,
        }
    }

    fn note(&mut self, what: String) {
        self.broken.get_or_insert(what);
    }

    fn event(ev: &Ev, core: &Attempts) -> Event {
        let a = || "a".to_string();
        match ev {
            Ev::Finished => Event::Finished {
                runner: a(),
                r: r(1, N1),
                result: pass(),
            },
            Ev::WrongNonce => Event::Finished {
                runner: a(),
                r: r(1, BAD),
                result: json!({"verdict": "Red"}),
            },
            Ev::LinkLost => Event::LinkLost { runner: a() },
            Ev::GraceEnded => Event::GraceEnded {
                job: "j1".into(),
                attempt: 1,
            },
            Ev::HelloListed => Event::Hello {
                runner: a(),
                listed: vec![Listed {
                    r: r(1, N1),
                    state: ListedState::Running,
                    log_offset: 12,
                }],
            },
            Ev::HelloNotListed => Event::Hello {
                runner: a(),
                listed: vec![],
            },
            Ev::HubRestarted => Event::HubRestarted,
            Ev::Preempting => Event::Preempting { runner: a() },
            Ev::Placed => {
                let next = core.current("j1").map_or(1, |(n, _)| n + 1);
                Event::Placed {
                    job: "j1".into(),
                    attempt: next,
                    nonce: N2,
                    runner: "b".into(),
                    grace_s: 600,
                    restartable: true,
                }
            }
        }
    }

    fn feed(&mut self, ev: Ev) -> Vec<Ev> {
        let kind = skuld::Events::kind(&ev);
        let before = self.core.clone();
        let effects = self.core.step(NOW, Self::event(&ev, &self.core));
        let mut raised = vec![];
        for e in &effects {
            match e {
                Effect::Verdict {
                    attempt, result, ..
                } => {
                    // one_verdict_per_attempt
                    if self.seen.iter().any(
                        |(_, s)| matches!(s, Effect::Verdict { attempt: b, .. } if b == attempt),
                    ) {
                        self.note(format!("a second verdict for attempt {attempt}"));
                    }
                    // a_lost_link_is_never_a_verdict: a verdict comes from `finished`, or is a cancel's
                    let from_cancel = self.cancelled && cancelled(result);
                    if kind != "Finished" && !from_cancel {
                        self.note(format!("a verdict from {kind}: {result}"));
                    }
                    // a_late_attempt_never_overrides
                    if self.ended.contains(attempt) {
                        self.note(format!(
                            "attempt {attempt} was requeued, then got a verdict"
                        ));
                    }
                }
                Effect::Requeue { reason, .. } => {
                    // only_lost_attempts_requeue_after_a_restart: a restart, and a hello that lists it, never requeue
                    if matches!(kind, "HubRestarted" | "HelloListed") {
                        self.note(format!("{kind} requeued the job"));
                    }
                    // preemption_is_neither_strike_nor_eviction: its reason is the preemption's, which is no strike
                    if kind == "Preempting" && reason != PREEMPTED {
                        self.note(format!("a preemption requeued for {reason:?}"));
                    }
                    let why = reason.strip_prefix("infra: ").unwrap_or(reason);
                    if kind == "Preempting"
                        && is_strike(&forseti::Verdict::Infra(why.into()), &StrikeCtx::default())
                    {
                        self.note("a preemption counted as a strike".into());
                    }
                    let (n, _) = before.current("j1").expect("a current attempt");
                    self.ended.push(n);
                    raised.push(Ev::Placed);
                }
                Effect::Lost { .. } => self.note(format!("j1 is restartable, yet {kind} lost it")),
                _ => {}
            }
        }
        if kind == "Preempting"
            && effects.iter().any(
                |e| matches!(e, Effect::Verdict { result, .. } if result["verdict"] == "Evicted"),
            )
        {
            self.note("a preemption gave an eviction".into());
        }
        // a_wrong_nonce_changes_nothing
        if kind == "WrongNonce" {
            if self.core != before {
                self.note("a frame with a wrong nonce changed the attempts".into());
            }
            if !effects.iter().all(|e| matches!(e, Effect::Ignore { .. })) {
                self.note(format!("a frame with a wrong nonce did {effects:?}"));
            }
        }
        self.seen.extend(effects.into_iter().map(|e| (kind, e)));
        raised
    }
}

impl Core for Shell {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        self.feed(ev)
    }
}

struct ShellC(Shell);

impl Core for ShellC {
    type Event = EvC;
    fn step(&mut self, ev: EvC) -> Vec<EvC> {
        match ev {
            EvC::E(e) => self.0.feed(e).into_iter().map(EvC::E).collect(),
            EvC::Cancel => {
                self.0.cancelled = true;
                let effects = self.0.core.step(NOW, Event::Cancel { job: "j1".into() });
                for e in &effects {
                    match e {
                        Effect::Verdict {
                            attempt, result, ..
                        } => {
                            if !cancelled(result) {
                                self.0.note(format!("a cancel gave {result}"));
                            }
                            if self.0.ended.contains(attempt) {
                                self.0.note(format!(
                                    "attempt {attempt} was requeued, then cancelled"
                                ));
                            }
                        }
                        Effect::Requeue { .. } | Effect::Lost { .. } => {
                            self.0.note(format!("a cancel did {e:?}"))
                        }
                        _ => {}
                    }
                }
                self.0
                    .seen
                    .extend(effects.into_iter().map(|e| ("Cancel", e)));
                vec![]
            }
        }
    }
}

/// The end of an order: the steps' notes, then at most one ending for attempt 1, and attempt 1 never open after one.
fn check(s: &Shell) -> Result<(), String> {
    if let Some(b) = &s.broken {
        return Err(b.clone());
    }
    let endings = s
        .seen
        .iter()
        .filter(|(_, e)| {
            matches!(e, Effect::Verdict { attempt: 1, .. } | Effect::Lost { .. })
                || matches!(e, Effect::Requeue { .. })
        })
        .count();
    if endings > 1 {
        return Err(format!("attempt 1 ended {endings} times: {:?}", s.seen));
    }
    let a1 = s.core.attempt("j1", 1).expect("attempt 1").state;
    if endings == 1 && a1.open() {
        return Err(format!("attempt 1 ended, yet it is {a1:?}"));
    }
    if s.ended.contains(&1) && a1 == AttemptState::Finished {
        // fine: a late result kept
        if !s
            .seen
            .iter()
            .any(|(_, e)| matches!(e, Effect::KeepLate { attempt: 1, .. }))
        {
            return Err("attempt 1 was requeued and is finished, but not as late".into());
        }
    }
    Ok(())
}

fn sources() -> Partial<Ev> {
    let mut p = Partial::new();
    p.source("link", vec![Ev::LinkLost, Ev::HelloListed]);
    p.source("restart", vec![Ev::HubRestarted, Ev::HelloNotListed]);
    p.source("runner", vec![Ev::WrongNonce, Ev::Finished]);
    p.source("timer", vec![Ev::GraceEnded]);
    p.source("cloud", vec![Ev::Preempting]);
    p
}

// [A] every order
#[test]
fn every_order_one_attempt_one_ending() {
    let r = every_order(&sources(), Bound::default(), Shell::new, |s, _| check(s));
    assert_eq!(r.mode, skuld::Mode::Exhaustive);
    assert_eq!(r.orders, 5040);
}

/// Rows from two attempts. j1's attempt 1 ran on runner `a` with no grace, and its link was lost after rows r1 and r2:
/// the hub took those two from its copy of the log and requeued the job, and attempt 2 runs the rest (r3, r4) on `b`.
/// Then `a` comes back: its late attempt 1 sends its rows (r3 failed there) and its `finished`. A row with a wrong
/// nonce comes too.
#[derive(Clone, Debug, PartialEq)]
enum RowEv {
    RowA1,
    RowA2,
    RowA3,
    FinishedA,
    RowB3,
    RowB4,
    FinishedB,
    RowBad,
}
skuld::events!(RowEv {
    RowA1,
    RowA2,
    RowA3,
    FinishedA,
    RowB3,
    RowB4,
    FinishedB,
    RowBad
});

/// The hub's side of rows: the attempts, the rows they gave, and the result its verdict recorded.
struct RowShell {
    core: Attempts,
    rows: Rows,
    recorded: Option<Value>,
}

impl RowShell {
    fn new() -> RowShell {
        let mut core = Attempts::default();
        let placed = |attempt, nonce, runner: &str, grace_s| Event::Placed {
            job: "j1".into(),
            attempt,
            nonce,
            runner: runner.into(),
            grace_s,
            restartable: true,
        };
        core.step(NOW, placed(1, N1, "a", 0));
        core.step(
            NOW,
            Event::Started {
                runner: "a".into(),
                r: r(1, N1),
            },
        );
        let requeued = core.step(NOW, Event::LinkLost { runner: "a".into() });
        assert!(
            matches!(requeued[..], [Effect::Requeue { .. }]),
            "{requeued:?}"
        );
        let mut rows = Rows::default();
        rows.record(1, "r1", "pass", "a");
        rows.record(1, "r2", "pass", "a");
        core.step(NOW, placed(2, N2, "b", 600));
        core.step(
            NOW,
            Event::Started {
                runner: "b".into(),
                r: r(2, N2),
            },
        );
        RowShell {
            core,
            rows,
            recorded: None,
        }
    }
}

impl Core for RowShell {
    type Event = RowEv;
    fn step(&mut self, ev: RowEv) -> Vec<RowEv> {
        let row = |runner: &str, x: JobRef, name: &str, verdict: &str| {
            (runner.to_string(), x, name.to_string(), verdict.to_string())
        };
        let (runner, x, name, verdict) = match ev {
            RowEv::RowA1 => row("a", r(1, N1), "r1", "pass"),
            RowEv::RowA2 => row("a", r(1, N1), "r2", "pass"),
            RowEv::RowA3 => row("a", r(1, N1), "r3", "fail"),
            RowEv::RowB3 => row("b", r(2, N2), "r3", "pass"),
            RowEv::RowB4 => row("b", r(2, N2), "r4", "pass"),
            RowEv::RowBad => row("a", r(2, BAD), "r4", "crash"),
            RowEv::FinishedA | RowEv::FinishedB => {
                let (runner, x) = if ev == RowEv::FinishedA {
                    ("a", r(1, N1))
                } else {
                    ("b", r(2, N2))
                };
                for e in self.core.step(
                    NOW,
                    Event::Finished {
                        runner: runner.into(),
                        r: x,
                        result: json!({"verdict": "Pass", "counts": {}, "rows": []}),
                    },
                ) {
                    if let Effect::Verdict { result, .. } = e {
                        self.recorded = Some(union_result(
                            &result,
                            &self.rows,
                            &forseti::Expect::default(),
                        ));
                    }
                }
                return vec![];
            }
        };
        // the queue's rule: a row counts for an attempt the hub placed on that runner with that nonce, late or not
        if self.core.frame_ok(&runner, &x).is_some() {
            self.rows.record(x.attempt, &name, &verdict, &runner);
        }
        vec![]
    }
}

// [A] every order: each row is counted once, from its latest attempt, whatever order the two attempts' rows and the
// late `finished` come in
#[test]
fn every_order_each_row_counted_once_latest_wins() {
    let mut p = Partial::new();
    p.source(
        "a",
        vec![RowEv::RowA1, RowEv::RowA2, RowEv::RowA3, RowEv::FinishedA],
    );
    p.source("b", vec![RowEv::RowB3, RowEv::RowB4, RowEv::FinishedB]);
    p.source("stray", vec![RowEv::RowBad]);
    let r = every_order(&p, Bound::default(), RowShell::new, |s, _| {
        let Some(v) = &s.recorded else {
            return Err("attempt 2 got no verdict".into());
        };
        let rows: Vec<(String, u64)> = v["rows"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|x| {
                (
                    x["name"].as_str().unwrap_or_default().to_string(),
                    x["attempt"].as_u64().unwrap_or(0),
                )
            })
            .collect();
        let want: Vec<(String, u64)> = [("r1", 1), ("r2", 1), ("r3", 2), ("r4", 2)]
            .iter()
            .map(|(n, a)| (n.to_string(), *a))
            .collect();
        if rows != want {
            return Err(format!("each_row_counted_once_latest_wins: {rows:?}"));
        }
        if v["counts"] != json!({"ran": 4, "passed": 4, "failed": 0, "skipped": 0, "crashed": 0})
            || v["verdict"] != "Pass"
        {
            return Err(format!("the union's counts and verdict: {v}"));
        }
        // the late rows that came after the verdict change no row's winner
        let after: Vec<(String, u32)> = s
            .rows
            .union()
            .into_iter()
            .map(|(n, x)| (n, x.attempt))
            .collect();
        if after
            .iter()
            .map(|(n, a)| (n.clone(), u64::from(*a)))
            .collect::<Vec<_>>()
            != want
        {
            return Err(format!("after every frame: {after:?}"));
        }
        Ok(())
    });
    assert_eq!(r.mode, skuld::Mode::Exhaustive);
    assert_eq!(r.orders, 280);
}

// [A] every order, drawn: the same with the user's cancel anywhere
#[test]
fn random_orders_with_a_cancel() {
    let mut p = Partial::new();
    p.source("link", vec![EvC::E(Ev::LinkLost), EvC::E(Ev::HelloListed)]);
    p.source(
        "restart",
        vec![EvC::E(Ev::HubRestarted), EvC::E(Ev::HelloNotListed)],
    );
    p.source("runner", vec![EvC::E(Ev::WrongNonce), EvC::E(Ev::Finished)]);
    p.source("timer", vec![EvC::E(Ev::GraceEnded)]);
    p.source("cloud", vec![EvC::E(Ev::Preempting)]);
    p.source("user", vec![EvC::Cancel]);
    let r = random_orders(&p, 0..2000, || ShellC(Shell::new()), |s, _| check(&s.0));
    assert_eq!(r.orders, 2000);
}
