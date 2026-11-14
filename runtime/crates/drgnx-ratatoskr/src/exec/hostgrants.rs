//! A networked container job's ports of the user's computer (docs/develop/hub.md, "A job asks for a host port"): the
//! job's proxy refuses `host.drgnx.internal:PORT` that no grant opens and says so ([`ProxyEvent::Private`]); this loop
//! asks the user on a `browser.private` card, and applies the session's grants to the job's proxy live.
//!
//! - **One card per port per job**, whatever the user answers: a refused port, or one whose grant is revoked later, is
//!   not asked again while the job runs.  None once the job ended, none for a job no session started.
//! - **The grant is the session's** (the browser's scopes: once, this session, its plan; never a CIDR or "all
//!   private"): it opens the port for the session's browser and its other jobs too, and the card says so.
//! - **A revoke refuses the next request**: the grants are read again on every change to an answer; connections
//!   already open stay until they end (as in the browser), and the card says that too.
//!
//! [`Core`] is the pure part (events in, effects out); [`start`] runs it against the store.

use crate::coord::Writer;
use crate::matrix_gate::{ActionCtx, Gate, MatrixGate};
use crate::settings::Settings;
use gleipnir::net::host::{Host, Target};
use gleipnir::net::policy::{PrivateGrant, PrivateTarget, RESERVED_HOST};
use gleipnir::net::proxy::{ProxyEvent, WebState};
use norn::grants;
use norn::matrix::{Action, Who};
use norn::write::cards::matrix_card_get;
use serde_json::json;
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

/// What the loop hears.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Ev {
    /// The job's proxy refused TARGET: a private target no grant opens.
    Private { target: Target },
    /// The card asked for TARGET settled; ALLOW: the user's answer was a yes.
    Settled { target: Target, allow: bool },
    /// The session's `browser.private` grants as they are now (the cell applied).
    GrantsRead(Vec<PrivateGrant>),
    /// The job ended.
    JobEnded,
}

/// What the loop does.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Effect {
    /// Ask the user for TARGET (`host.drgnx.internal:PORT`) on a card.
    AskCard { target: Target },
    /// The job's proxy's grants from now on: the session's host ports only.
    SetGrants(Vec<PrivateGrant>),
}

/// The loop's state: which ports were asked, and the grants last set.
#[derive(Debug, Default)]
pub(crate) struct Core {
    session: bool,
    asked: HashSet<Target>,
    grants: Option<Vec<PrivateGrant>>,
    ended: bool,
}

impl Core {
    /// SESSION: a session started the job (a user's job asks nothing).
    pub(crate) fn new(session: bool) -> Core {
        Core {
            session,
            ..Core::default()
        }
    }

    pub(crate) fn step(&mut self, ev: Ev) -> Vec<Effect> {
        if self.ended {
            return Vec::new();
        }
        match ev {
            Ev::Private { target } => {
                if !self.session || !host_port(&target) || !self.asked.insert(target.clone()) {
                    return Vec::new();
                }
                vec![Effect::AskCard { target }]
            }
            Ev::Settled { target, allow } => {
                tracing::debug!(%target, allow, "a job's host-port card settled");
                Vec::new()
            }
            Ev::GrantsRead(gs) => {
                let mine: Vec<PrivateGrant> = gs
                    .into_iter()
                    .filter(|g| matches!(&g.target, PrivateTarget::HostPort(t) if host_port(t)))
                    .collect();
                if self.grants.as_ref() == Some(&mine) {
                    return Vec::new();
                }
                self.grants = Some(mine.clone());
                vec![Effect::SetGrants(mine)]
            }
            Ev::JobEnded => {
                self.ended = true;
                Vec::new()
            }
        }
    }
}

/// Whether T is a port of the user's computer by its one name (`host.drgnx.internal:PORT`).
fn host_port(t: &Target) -> bool {
    matches!(&t.host, Host::Name(n) if n == RESERVED_HOST)
}

/// What the loop needs of the hub.
#[derive(Clone)]
pub struct Hub {
    pub settings: Arc<Settings>,
    pub writer: Writer,
    pub gate: MatrixGate,
    /// Who session SID is and what it acts in (its plan and project); none once the hub is going (its front gone).
    pub session: SessionOf,
}

/// [`Hub::session`]'s type.
pub type SessionOf = Arc<dyn Fn(&str) -> Option<(Who, ActionCtx)> + Send + Sync>;

/// Job JOB's loop for session SID: the session's grants are read and set on WEB before this returns (so a port the
/// session was granted is open from the job's first request), then EVENTS (the job's proxy's) become cards.  Answers
/// the loop's task (abort it when the job ends) and its step count (events and re-reads; the tests wait on it).  When
/// the session cannot be read (the hub is going) nothing is asked: its events are drained.
pub(crate) async fn start(
    hub: Hub,
    job: &str,
    sid: &str,
    web: Arc<WebState>,
    mut events: mpsc::Receiver<ProxyEvent>,
) -> (JoinHandle<()>, watch::Receiver<u64>) {
    let (steps_tx, steps) = watch::channel(0);
    let Some((who, mut ctx)) = (hub.session)(sid) else {
        let task = tokio::spawn(async move { while events.recv().await.is_some() {} });
        return (task, steps);
    };
    ctx.session = Some(sid.to_string());
    let answers = hub.writer.signals.answers.subscribe();
    let mut a = Asker {
        hub,
        job: job.to_string(),
        who,
        ctx,
        web,
        core: Core::new(true),
        cards: BTreeMap::new(),
        steps: steps_tx,
    };
    a.reload().await;
    let task = crate::clock::spawn("exec:host-grant-cards", run(a, events, answers));
    (task, steps)
}

struct Asker {
    hub: Hub,
    job: String,
    who: Who,
    ctx: ActionCtx,
    web: Arc<WebState>,
    core: Core,
    /// The open cards, each with the port it asks for.
    cards: BTreeMap<i64, Target>,
    steps: watch::Sender<u64>,
}

async fn run(mut a: Asker, mut rx: mpsc::Receiver<ProxyEvent>, mut answers: watch::Receiver<u64>) {
    loop {
        tokio::select! {
            ev = rx.recv() => match ev {
                Some(ProxyEvent::Private { asked, .. }) => {
                    let effects = a.core.step(Ev::Private { target: asked });
                    a.apply(effects).await;
                }
                Some(_) => {}
                None => {
                    a.core.step(Ev::JobEnded);
                    return;
                }
            },
            changed = answers.changed() => {
                if changed.is_err() {
                    return;
                }
                a.reload().await;
            }
        }
        a.steps.send_modify(|n| *n += 1);
    }
}

impl Asker {
    /// Carries out EFFECTS; an ask the gate allowed without a card reads the grants again (until none does).
    async fn apply(&mut self, mut effects: Vec<Effect>) {
        loop {
            let mut again = false;
            for e in effects {
                match e {
                    Effect::AskCard { target } => again |= self.ask(target).await,
                    Effect::SetGrants(gs) => self.web.set_grants(gs),
                }
            }
            if !again {
                return;
            }
            effects = self.read().await;
        }
    }

    /// The card for TARGET: its facts are the hub's (the job and the port as the grant names it), never the job's.
    /// True when the gate allowed it without a card (a grant came meanwhile): the grants are to be read again.
    async fn ask(&mut self, target: Target) -> bool {
        let wire = json!(PrivateTarget::HostPort(target.clone()));
        let ctx = ActionCtx {
            facts: crate::browser::web::facts(json!({"target": wire, "job": self.job})),
            ..self.ctx.clone()
        };
        let gate = self
            .hub
            .gate
            .decide(
                &self.hub.settings,
                &self.hub.writer,
                self.who.clone(),
                Action::BrowserPrivate,
                ctx,
            )
            .await;
        match gate {
            Gate::Allow => return true,
            Gate::Ask(id) if id > 0 => {
                self.cards.insert(id, target);
            }
            Gate::Ask(_) => {
                tracing::warn!(job = %self.job, "no browser.private card: the store did not take it");
            }
            Gate::Never(why) => tracing::info!(job = %self.job, %target, "browser.private: {why}"),
        }
        false
    }

    /// The session's grants and the open cards, read again: settled cards and the grants go through the core.  A
    /// store that cannot be read keeps the grants as they are.
    async fn reload(&mut self) {
        let effects = self.read().await;
        self.apply(effects).await;
    }

    /// What [`Asker::reload`] reads, as the core's effects.
    async fn read(&mut self) -> Vec<Effect> {
        self.hub.gate.refresh_from(&self.hub.settings);
        let (g, who, ctx, now) = (
            self.hub.gate.clone(),
            self.who.clone(),
            self.ctx.clone(),
            crate::clock::wall_secs(),
        );
        let open: Vec<i64> = self.cards.keys().copied().collect();
        let read = self
            .hub
            .writer
            .db
            .read(move |c| {
                let cell = g.dry(c, &who, Action::BrowserPrivate, &ctx, now).verdict;
                let gs = grants::matrix_grants_for(
                    c,
                    Action::BrowserPrivate.id(),
                    ctx.session.as_deref(),
                    ctx.plan.as_deref(),
                    now,
                )?;
                let mut settled = Vec::new();
                for id in open {
                    match matrix_card_get(c, id)? {
                        Some(card) if card.state == "open" => {}
                        card => {
                            let allow = card.is_some_and(|k| {
                                !matches!(k.choice.as_deref(), Some("refuse" | "deny") | None)
                                    && k.data["refused"] != json!(true)
                            });
                            settled.push((id, allow));
                        }
                    }
                }
                Ok((crate::browser::web::private_state(cell, &gs), settled))
            })
            .await;
        let (grants, settled) = match read {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(job = %self.job, "the job's host-port grants were not read: {e}");
                return Vec::new();
            }
        };
        let mut effects = Vec::new();
        for (id, allow) in settled {
            if let Some(target) = self.cards.remove(&id) {
                effects.extend(self.core.step(Ev::Settled { target, allow }));
            }
        }
        effects.extend(self.core.step(Ev::GrantsRead(grants)));
        effects
    }
}

#[cfg(test)]
mod tests;
