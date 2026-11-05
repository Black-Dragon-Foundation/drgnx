//! The attempt state machine (`runners::attempts`) in every order of what can happen to one attempt (skuld).
//!
//! Job j1's attempt 1 runs on runner `a` (linger: a 600 s grace). The sources are what the hub hears about it: the
//! link (lost, then a `hello` listing the attempt), a restart (the hub restarted, then a `hello` that doesn't list
//! it), the runner (a `finished` frame with a wrong nonce, then the real one), the grace timer and a preemption. The
//! test plays the shell: a requeue places attempt 2 on runner `b` at once (a re-entrant `Placed`). `random_orders`
//! adds the user's cancel.

use drgnx_ratatoskr::runners::attempts::{
    AttemptState, Core as Attempts, Effect, Event, Listed, ListedState, PREEMPTED,
};
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
                    // preemption_is_neither_strike_nor_eviction
                    if kind == "Preempting" && reason != PREEMPTED {
                        self.note(format!("a preemption requeued for {reason:?}"));
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
