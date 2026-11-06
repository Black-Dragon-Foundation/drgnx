//! The permissions matrix in the hub (Task 12; `docs/guide/security.md`, "The permissions matrix"): every action an
//! agent takes is checked (`MatrixGate::check(who, action, ctx) -> Gate`) against `norn::matrix`'s effective cells
//! for its columns, with the `agents-matrix` setting, the project's and the plan's overrides and the away signal;
//! an Ask makes one `matrix` card from facts the hub derived; it is re-checked when it executes; a manager's grants
//! to its workers only narrow its own (`delegate`).  Methods `matrix/get`, `matrix/check`, `presence/set`.
//!
//! One limit per cell: the 30 % weekly share of a subscription is the budget gate's check ([`crate::budget`]), not the
//! cell's.  A project's and a plan's override is its entity's `matrix` data field and counts only when the user wrote
//! that field (its own writer, `field_tx["data.matrix"]`).
//!
//! What a session may do now is one function, [`MatrixGate::effective_for`] (the permission seam, the brief and the
//! launch all call it): its own cells from every layer, and for a worker a manager started, no more than what the
//! manager delegated and no more than the manager's own cells as they are at that moment.

use crate::backup_timer::local;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::settings::matrix as decode;
use gleipnir::net::host::Host;
use gleipnir::net::policy::PrivateTarget;
use norn::grants;
use norn::matrix::{
    Action, Cell, Column, Effective, Matrix, Preset, TimePreset, Verdict, Who, Widening, active,
    decide, effective, meet, narrow, preset,
};
use norn::store::{CoordError, WTx};
use norn::write::cards::{MatrixAsk, matrix_card, matrix_card_get};
use runstav::events::CardChoice;
use runstav::methods::matrix::{
    CellRow, CheckAnswer, CheckParams, EffectiveRow, Facts, GetParams, MatrixView, PresenceParams,
    WhoParam,
};
use runstav::types::Bounded;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, Mutex};

/// What the gate decides for one action: allowed, asked through a card (its id), or refused (why).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Gate {
    Allow,
    Ask(i64),
    Never(String),
}

/// What an action is about.  FACTS are the hub's own (never an agent's words); they are all a card shows.
#[derive(Clone, Debug, Default)]
pub struct ActionCtx {
    pub project: Option<String>,
    /// The plan entity's id (its `matrix` field is the plan's override).
    pub plan: Option<String>,
    /// The session acting (a worker a manager started: its delegation narrows its own cells).
    pub session: Option<String>,
    pub amount: Option<f64>,
    pub facts: Facts,
}

impl ActionCtx {
    /// What session SID acts in: the plan and the project of the run (or the task) it works for, from SCOPES.
    pub fn of_session(scopes: &crate::runner::Scopes, sid: &str) -> ActionCtx {
        let (plan, project) = scopes.get(sid).map_or((None, None), |(p, j)| (Some(p), j));
        ActionCtx {
            project,
            plan,
            session: Some(sid.to_owned()),
            ..ActionCtx::default()
        }
    }
}

/// A manager as the gate reads its own cells again at every check of its worker: its columns, its project and plan.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Manager {
    pub who: Who,
    pub project: Option<String>,
    pub plan: Option<String>,
}

/// What a manager handed a worker.  No manager: a delegation that was lost (an empty one is Never everywhere).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Delegation {
    pub cells: Effective,
    pub manager: Option<Manager>,
}

#[derive(Default)]
struct State {
    base: Option<Preset>,
    time: Vec<TimePreset>,
    away: bool,
    user: Matrix,
    /// Worker session → what its manager handed it.
    delegated: BTreeMap<String, Delegation>,
    /// Who hears of a new matrix card (none in unit tests).
    editors: Option<Arc<crate::settings::agents::Editors>>,
    /// `agents-browser-once-window` as last read (none: [`DEFAULT_ONCE_WINDOW`]).
    once_window: Option<u64>,
}

/// The gate's state: the setting as last read, the away flag, the managers' grants.
#[derive(Default, Clone)]
pub struct MatrixGate {
    st: Arc<Mutex<State>>,
}

pub(crate) fn who_json(w: &Who) -> Value {
    json!(WhoParam {
        role: w.role,
        agent: w.agent.clone().map(Bounded),
        provider: w.provider.clone().map(Bounded),
    })
}

/// The `Who` in V; unreadable: no columns at all (nothing matches it, so nothing is allowed).
pub(crate) fn who_of(v: &Value) -> Who {
    serde_json::from_value::<WhoParam>(v.clone())
        .map(|p| Who::from(&p))
        .unwrap_or_default()
}

/// The override of entity ID (a project or a plan) when the user wrote its `matrix` field.  The field's own writer
/// counts, not whoever wrote another `data` key last; any other author's override is ignored.
fn user_override(conn: &urdr::Connection, id: &str) -> Option<Matrix> {
    let ent = urdr::graph::entity::by_id(conn, id).ok()??;
    let field = ent.data.get("matrix")?;
    let tx = *ent.field_tx.get("data.matrix")?;
    let class: String = conn
        .query_row("select class from tx where id = ?1", [tx], |r| r.get(0))
        .ok()?;
    if class != "user" {
        return None;
    }
    decode::decode_cells(field).ok()
}

fn minute(now: f64) -> u16 {
    local(now.max(0.0) as u64).minute as u16
}

/// Whether the user's matrix grants cover A in CTX at NOW, so an Ask needs no card: for `browser` any grant of the
/// session or its plan; for `browser.web` one with no host or with the host of the facts; for `browser.private` one
/// whose target is exactly the facts' (the web proxy matches the wider ones itself).  No other row has grants.
fn granted(conn: &urdr::Connection, a: Action, ctx: &ActionCtx, now: f64) -> bool {
    if !matches!(
        a,
        Action::Browser | Action::BrowserWeb | Action::BrowserPrivate
    ) {
        return false;
    }
    let Ok(found) = grants::matrix_grants_for(
        conn,
        a.id(),
        ctx.session.as_deref(),
        ctx.plan.as_deref(),
        now,
    ) else {
        return false;
    };
    let facts = &ctx.facts;
    found.iter().any(|g| {
        let grants::What::Matrix { host, target, .. } = &g.what else {
            return false;
        };
        match a {
            Action::BrowserWeb => host
                .as_deref()
                .is_none_or(|h| facts.host.as_ref().is_some_and(|f| f.as_str() == h)),
            Action::BrowserPrivate => target.is_some() && *target == facts.target,
            _ => true,
        }
    })
}

/// Whether A is a browser row: its cards list their answers (scopes, and widths for a private literal) and settle
/// into grants (`crate::graph::settle_browser`).
pub(crate) fn is_browser(a: Action) -> bool {
    matches!(
        a,
        Action::Browser | Action::BrowserWeb | Action::BrowserPrivate
    )
}

/// How long a "once" lasts when the setting was never read (`agents-browser-once-window`'s default).
pub(crate) const DEFAULT_ONCE_WINDOW: u64 = 600;

const WEB_BODY: &str = "The agent's browser and its own tools could then reach any public site; pages can send what the \
                        agent gives them";
const PRIVATE_BODY: &str =
    "Any page the agent opens could then send requests to it, including ones that change things";

/// How a private address's class (the web policy's name) reads on a card.
fn class_label(class: &str) -> &str {
    match class {
        "lan" => "your LAN",
        "ula" => "your network (IPv6)",
        "link_local" => "link-local",
        "cgnat" => "your tailnet (CGNAT)",
        "loopback" | "host_own" => "this computer",
        other => other,
    }
}

/// The wider target a LAN or ULA literal may be granted as: its /24 (IPv4) or /64 (IPv6), on its own port.  None for
/// a name, the reserved name, or any other class (those are granted one host:port at a time).
pub(crate) fn cidr_of(f: &Facts) -> Option<PrivateTarget> {
    if !matches!(f.class.as_ref()?.as_str(), "lan" | "ula") {
        return None;
    }
    let PrivateTarget::HostPort(t) =
        serde_json::from_value::<PrivateTarget>(f.target.clone()?).ok()?
    else {
        return None;
    };
    let (net, prefix) = match t.host {
        Host::V4(a) => (IpAddr::V4(Ipv4Addr::from(u32::from(a) & 0xffff_ff00)), 24),
        Host::V6(a) => (
            IpAddr::V6(Ipv6Addr::from(u128::from(a) & !(u128::MAX >> 64))),
            64,
        ),
        Host::Name(_) => return None,
    };
    Some(PrivateTarget::Cidr {
        net,
        prefix,
        ports: (t.port, t.port),
    })
}

/// SECS as a card says it ("10 minutes").
fn span(secs: u64) -> String {
    match secs {
        60 => "1 minute".into(),
        s if s % 60 == 0 => format!("{} minutes", s / 60),
        1 => "1 second".into(),
        s => format!("{s} seconds"),
    }
}

/// The answers a browser row's card lists (call 5): once (ONCE seconds), this session, this plan (when the session
/// has one), the widths of a LAN or ULA literal, and refuse.
pub(crate) fn browser_choices(a: Action, ctx: &ActionCtx, once: u64) -> Vec<CardChoice> {
    let c = |id: &str, label: String| CardChoice {
        id: id.into(),
        label,
    };
    let host = ctx.facts.host.as_ref().map(|h| h.as_str());
    let mut out = vec![match (a, host) {
        (Action::BrowserWeb, Some(h)) => c("once", format!("Allow {h} only, for {}", span(once))),
        _ => c("once", format!("Allow once ({})", span(once))),
    }];
    out.push(c("session", "Allow for this session".into()));
    let plan = ctx.plan.is_some();
    if plan {
        out.push(c("plan", "Allow for this plan".into()));
    }
    if a == Action::BrowserPrivate
        && let Some(PrivateTarget::Cidr { net, prefix, ports }) = cidr_of(&ctx.facts)
    {
        let range = format!("{net}/{prefix} on port {}", ports.0);
        out.push(c("session/cidr", format!("Allow {range} for this session")));
        if plan {
            out.push(c("plan/cidr", format!("Allow {range} for this plan")));
        }
        let all = "Allow every LAN and IPv6 ULA address, any port";
        out.push(c("session/all-private", format!("{all}, for this session")));
        if plan {
            out.push(c("plan/all-private", format!("{all}, for this plan")));
        }
    }
    out.push(c("refuse", "Refuse".into()));
    out
}

/// What the user should know before answering a browser row's card.
pub(crate) fn card_body(a: Action) -> Option<&'static str> {
    match a {
        Action::BrowserWeb => Some(WEB_BODY),
        Action::BrowserPrivate => Some(PRIVATE_BODY),
        _ => None,
    }
}

/// A card's title, from the hub's facts only (never an agent's words).  A browser row's names the session.
fn card_title(a: Action, who: &Who, ctx: &ActionCtx) -> String {
    let f = &ctx.facts;
    let name = || {
        ctx.session
            .clone()
            .or_else(|| who.agent.clone())
            .unwrap_or_else(|| "an agent".into())
    };
    match a {
        Action::Browser => return format!("{} wants a browser in its sandbox", name()),
        Action::BrowserWeb => {
            return match &f.host {
                Some(h) => format!("{} wants to open web sites (first: {})", name(), h.as_str()),
                None => format!("{} wants to open web sites", name()),
            };
        }
        Action::BrowserPrivate => {
            let target = f
                .target
                .as_ref()
                .and_then(|t| t.get("host_port"))
                .and_then(Value::as_str)
                .unwrap_or("a private address");
            let mut t = format!("{} wants to open {target}", name());
            if let Some(addr) = &f.addr {
                t.push_str(&format!(" → {}", addr.as_str()));
            }
            if let Some(class) = &f.class {
                t.push_str(&format!(" ({})", class_label(class.as_str())));
            }
            return t;
        }
        _ => {}
    }
    let plain = |v: Value| v.as_str().unwrap_or_default().to_string();
    let what = match (&f.command, f.paths.0.first(), &f.diff_hash) {
        (Some(c), _, _) => plain(json!(c)),
        (None, Some(p), _) => plain(json!(p)),
        (None, None, Some(h)) => format!("diff {}", plain(json!(h))),
        _ => String::new(),
    };
    format!("{}: {}", a.id(), what)
}

/// Whether the grant card CARD wrote for A is live for CTX's session or plan at NOW (a once ends with its window).
fn card_granted(conn: &urdr::Connection, a: Action, ctx: &ActionCtx, card: i64, now: f64) -> bool {
    grants::matrix_grants_for(
        conn,
        a.id(),
        ctx.session.as_deref(),
        ctx.plan.as_deref(),
        now,
    )
    .is_ok_and(|gs| gs.iter().any(|g| g.card == Some(card)))
}

impl MatrixGate {
    /// Take the `agents-matrix` setting V (what `Settings::effective` gives).
    pub fn apply_setting(&self, v: &Value) -> Result<(), String> {
        let d = decode::decode(v)?;
        let mut st = self.st.lock().expect("matrix gate");
        st.base = d.preset;
        st.time = d.time_presets;
        st.user = d.overrides;
        Ok(())
    }

    /// `presence/set`: from the next action the time presets follow.
    pub fn set_away(&self, away: bool) {
        self.st.lock().expect("matrix gate").away = away;
    }

    /// Whether the setting has time presets, so the preset in force may change at a minute's turn with no write.
    pub fn has_time_presets(&self) -> bool {
        !self.st.lock().expect("matrix gate").time.is_empty()
    }

    /// How long a browser card's "once" lasts, in seconds (`agents-browser-once-window` as last read).
    pub fn once_window(&self) -> u64 {
        self.st
            .lock()
            .expect("matrix gate")
            .once_window
            .unwrap_or(DEFAULT_ONCE_WINDOW)
    }

    fn preset_now(&self, now: f64) -> (Preset, Preset, bool) {
        let st = self.st.lock().expect("matrix gate");
        let base = st.base.unwrap_or(Preset::Balanced);
        (base, active(base, &st.time, st.away, minute(now)), st.away)
    }

    /// The layers for CTX: the active preset, the user's cells, the project's and the plan's overrides.
    fn layers(&self, conn: &urdr::Connection, ctx: &ActionCtx, now: f64) -> Vec<Matrix> {
        let (_, act, _) = self.preset_now(now);
        let user = self.st.lock().expect("matrix gate").user.clone();
        let mut layers = vec![preset(act), user];
        layers.extend(ctx.project.as_deref().and_then(|p| user_override(conn, p)));
        layers.extend(ctx.plan.as_deref().and_then(|p| user_override(conn, p)));
        layers
    }

    /// WHO's own cells in CTX, from every layer.
    fn own(&self, conn: &urdr::Connection, who: &Who, ctx: &ActionCtx, now: f64) -> Effective {
        let layers = self.layers(conn, ctx, now);
        effective(&layers.iter().collect::<Vec<_>>(), who)
    }

    /// What WHO (session `ctx.session`) may do now: its own cells from every layer (preset, away and time presets,
    /// the user's, the project's, the plan's).  A worker a manager started gets the tighter of those, what the
    /// manager delegated, and the manager's own cells as they are now: a delegation only narrows, and tightening the
    /// manager reaches its workers at their next action.
    pub fn effective_for(
        &self,
        conn: &urdr::Connection,
        who: &Who,
        ctx: &ActionCtx,
        now: f64,
    ) -> Effective {
        let own = self.own(conn, who, ctx, now);
        let delegated = ctx.session.as_ref().and_then(|s| self.delegated_to(s));
        let Some(d) = delegated else {
            return own;
        };
        let narrowed = meet(&own, &d.cells);
        match &d.manager {
            Some(m) => {
                let mctx = ActionCtx {
                    project: m.project.clone(),
                    plan: m.plan.clone(),
                    ..ActionCtx::default()
                };
                meet(&narrowed, &self.own(conn, &m.who, &mctx, now))
            }
            None => narrowed,
        }
    }

    fn verdict(
        &self,
        conn: &urdr::Connection,
        who: &Who,
        a: Action,
        ctx: &ActionCtx,
        now: f64,
    ) -> (Verdict, String) {
        let e = self.effective_for(conn, who, ctx, now);
        let v = decide(&e, a, ctx.amount);
        let why = match v {
            Verdict::Allow => String::new(),
            Verdict::Ask => format!("{} needs the user's yes", a.id()),
            Verdict::Never => match (e.cell(a).verdict, e.cell(a).limit) {
                (Verdict::Never, _) => format!("{} is never allowed here", a.id()),
                _ => format!("{} is over its limit and going over is not allowed", a.id()),
            },
        };
        (v, why)
    }

    /// What the matrix decides for WHO doing A, with no card (`matrix/check`).
    pub fn dry(
        &self,
        conn: &urdr::Connection,
        who: &Who,
        a: Action,
        ctx: &ActionCtx,
        now: f64,
    ) -> CheckAnswer {
        let (verdict, why) = self.verdict(conn, who, a, ctx, now);
        CheckAnswer {
            verdict,
            why: (verdict != Verdict::Allow).then_some(why),
        }
    }

    /// The gate for WHO doing A: an Ask makes (or finds) the one open card for this question.  (Deviation from the
    /// plan's signature: the card is written in TX.)
    pub fn check(
        &self,
        tx: &mut WTx<'_>,
        who: &Who,
        a: Action,
        ctx: &ActionCtx,
        now: f64,
    ) -> Result<Gate, CoordError> {
        let (v, why) = self.verdict(tx.sql(), who, a, ctx, now);
        Ok(match v {
            Verdict::Allow => Gate::Allow,
            Verdict::Never => Gate::Never(why),
            Verdict::Ask if granted(tx.sql(), a, ctx, now) => Gate::Allow,
            Verdict::Ask => {
                let mut data = json!({
                    "action": a.id(),
                    "who": who_json(who),
                    "session": ctx.session,
                    "project": ctx.project,
                    "plan": ctx.plan,
                    "amount": ctx.amount,
                    "facts": ctx.facts,
                });
                if is_browser(a) {
                    // what the card offers, and how long its once lasts (the settle reads both back)
                    let once = self.once_window();
                    data["choices"] = json!(browser_choices(a, ctx, once));
                    data["once_window"] = json!(once);
                    if let Some(b) = card_body(a) {
                        data["body"] = json!(b);
                    }
                }
                let ask = MatrixAsk {
                    title: card_title(a, who, ctx),
                    data,
                    job: None,
                };
                Gate::Ask(matrix_card(tx, ask, now)?)
            }
        })
    }

    /// At execution: the card's answer under the matrix as it is now.  A switch that made the action Never refuses
    /// it whatever the user said; a grant that covers the card's facts allows it; an open card is still a question;
    /// a declined one is a refusal.  A browser card's yes (once, session, plan, a width) holds while the grant it
    /// wrote is live.
    pub fn recheck(&self, conn: &urdr::Connection, card: i64, now: f64) -> Gate {
        let Ok(Some(c)) = matrix_card_get(conn, card) else {
            return Gate::Never("no such matrix card".into());
        };
        let Some(a) = c
            .data
            .get("action")
            .and_then(Value::as_str)
            .and_then(Action::from_id)
        else {
            return Gate::Never("the card names no action".into());
        };
        let str_of = |k: &str| c.data.get(k).and_then(Value::as_str).map(str::to_owned);
        let ctx = ActionCtx {
            project: str_of("project"),
            plan: str_of("plan"),
            session: str_of("session"),
            amount: c.data.get("amount").and_then(Value::as_f64),
            facts: c
                .data
                .get("facts")
                .and_then(|f| serde_json::from_value(f.clone()).ok())
                .unwrap_or_default(),
        };
        let who = who_of(c.data.get("who").unwrap_or(&Value::Null));
        let (v, why) = self.verdict(conn, &who, a, &ctx, now);
        if v == Verdict::Never {
            return Gate::Never(why);
        }
        if v == Verdict::Ask && granted(conn, a, &ctx, now) {
            return Gate::Allow;
        }
        match (c.state.as_str(), c.choice.as_deref()) {
            ("settled", Some("allow")) => Gate::Allow,
            ("settled", Some(ch)) if is_browser(a) && ch != "refuse" => {
                if card_granted(conn, a, &ctx, card, now) {
                    Gate::Allow
                } else {
                    Gate::Never("the user's yes on this card has ended".into())
                }
            }
            ("settled", _) => Gate::Never("the user declined".into()),
            _ if v == Verdict::Allow => Gate::Allow,
            _ => Gate::Ask(card),
        }
    }

    /// A manager's grant to its worker: ASKED, no wider than what MANAGER (in MANAGER_CTX) has itself.  From now on
    /// the worker may do no more than ASKED, its own cells and the manager's cells at the time of each action.
    /// (Kept in the hub, not as a `grant` entity: grants are the user's.)
    pub fn delegate(
        &self,
        conn: &urdr::Connection,
        manager: &Who,
        manager_ctx: &ActionCtx,
        worker_sid: &str,
        asked: Effective,
        now: f64,
    ) -> Result<(), Widening> {
        let parent = self.effective_for(conn, manager, manager_ctx, now);
        let granted = narrow(&parent, &asked)?;
        let d = Delegation {
            cells: granted,
            manager: Some(Manager {
                who: manager.clone(),
                project: manager_ctx.project.clone(),
                plan: manager_ctx.plan.clone(),
            }),
        };
        self.set_delegated(worker_sid, d);
        Ok(())
    }

    /// What a manager delegated to worker SID, if it did.
    pub fn delegated_to(&self, sid: &str) -> Option<Delegation> {
        self.st
            .lock()
            .expect("matrix gate")
            .delegated
            .get(sid)
            .cloned()
    }

    /// Worker SID's delegation as a restart or a move read it back (an empty one is Never everywhere).
    pub fn set_delegated(&self, sid: &str, d: Delegation) {
        self.st
            .lock()
            .expect("matrix gate")
            .delegated
            .insert(sid.to_string(), d);
    }

    /// Worker SID ended (or never started): its delegation goes.
    pub fn drop_delegation(&self, sid: &str) {
        self.st.lock().expect("matrix gate").delegated.remove(sid);
    }

    fn view(&self, conn: &urdr::Connection, p: &GetParams, now: f64) -> MatrixView {
        let (base, act, away) = self.preset_now(now);
        let ctx = ActionCtx {
            project: p.project.as_ref().map(|x| x.0.clone()),
            plan: p.plan.as_ref().map(|x| x.0.clone()),
            ..ActionCtx::default()
        };
        let time = self.st.lock().expect("matrix gate").time.clone();
        let owned = self.layers(conn, &ctx, now);
        let layers: Vec<&Matrix> = owned.iter().collect();
        let mut merged: BTreeMap<(Action, Column), Cell> = BTreeMap::new();
        for l in &layers {
            merged.extend(l.cells.iter().map(|(k, c)| (k.clone(), *c)));
        }
        let cells = merged
            .into_iter()
            .map(|((action, column), c)| CellRow {
                action,
                column,
                verdict: c.verdict,
                limit: c.limit,
            })
            .collect();
        let eff = p
            .who
            .as_ref()
            .map(|w| {
                let e = effective(&layers, &Who::from(w));
                Action::ALL
                    .into_iter()
                    .map(|action| EffectiveRow {
                        action,
                        verdict: e.cell(action).verdict,
                        limit: e.cell(action).limit,
                    })
                    .collect()
            })
            .unwrap_or_default();
        MatrixView {
            preset: base,
            active: act,
            away,
            time_presets: time,
            cells,
            effective: eff,
        }
    }

    /// Read the setting from the front's settings (none until the setting is declared: Balanced).
    pub(crate) fn refresh(&self, f: &Front) {
        self.refresh_from(&f.settings);
    }

    /// [`Self::refresh`] from the settings alone (a session holds those, not the front).
    pub fn refresh_from(&self, settings: &crate::settings::Settings) {
        if let Some((v, _)) = settings.effective("drgnx-agents-matrix", None) {
            let _ = self.apply_setting(&v);
        }
        let once = settings.current().loaded.values.agents_browser_once_window;
        self.st.lock().expect("matrix gate").once_window = Some(once);
    }

    /// The preset in force now (the time presets and the away flag applied).
    pub fn active_preset(&self, now: f64) -> Preset {
        self.preset_now(now).1
    }

    /// WHO's effective cells for CTX now, read from the store.
    pub async fn effective_now(
        &self,
        settings: &crate::settings::Settings,
        writer: &crate::coord::Writer,
        who: Who,
        ctx: ActionCtx,
    ) -> Result<Effective, CoordError> {
        self.refresh_from(settings);
        let (g, now) = (self.clone(), now_secs());
        writer
            .db
            .read(move |c| Ok(g.effective_for(c, &who, &ctx, now)))
            .await
    }

    /// The gate for WHO doing A (the matrix as the settings say it now); an Ask makes the card.  A store that fails
    /// asks the user (`Ask(0)`, no card) rather than allow.
    pub async fn decide(
        &self,
        settings: &crate::settings::Settings,
        writer: &crate::coord::Writer,
        who: Who,
        a: Action,
        ctx: ActionCtx,
    ) -> Gate {
        self.refresh_from(settings);
        let (g, now) = (self.clone(), now_secs());
        let system = Caller {
            class: runstav::registry::Class::Agent,
            sid: None,
            job: None,
            conn_id: 0,
        };
        let title = card_title(a, &who, &ctx);
        let mut event = json!({"job": null, "task": null, "kind": "matrix", "title": title});
        if is_browser(a) {
            event["choices"] = json!(browser_choices(a, &ctx, self.once_window()));
            if let Some(b) = card_body(a) {
                event["body"] = json!(b);
            }
        }
        let gate = writer
            .write(&system, "coord/matrix-check", move |tx| {
                g.check(tx, &who, a, &ctx, now)
            })
            .await
            .unwrap_or(Gate::Ask(0));
        // the card is announced as every card is (the cockpit and the mirror wait on the event)
        let editors = self.st.lock().expect("matrix gate").editors.clone();
        if let Gate::Ask(id) = gate
            && id > 0
            && let Some(e) = editors
        {
            event["id"] = json!(id);
            e.broadcast("card", event);
        }
        gate
    }

    /// The `card` event of a matrix card goes to EDITORS' subscribers.
    pub fn announce_to(&self, editors: Arc<crate::settings::agents::Editors>) {
        self.st.lock().expect("matrix gate").editors = Some(editors);
    }
}

fn store_err(e: CoordError) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: format!("{e:?}"),
        path: None,
    }
}

fn now_secs() -> f64 {
    crate::clock::wall_secs()
}

pub async fn get(f: &Front, _: &Caller, p: GetParams) -> Result<MatrixView, Error> {
    f.core.matrix.refresh(f);
    let now = now_secs();
    let f2 = f.core.matrix.clone();
    f.writer
        .db
        .read(move |c| Ok(f2.view(c, &p, now)))
        .await
        .map_err(store_err)
}

pub async fn check_method(f: &Front, _: &Caller, p: CheckParams) -> Result<CheckAnswer, Error> {
    f.core.matrix.refresh(f);
    let now = now_secs();
    let g = f.core.matrix.clone();
    let who = Who::from(&p.who);
    let ctx = ActionCtx {
        project: p.project.map(|x| x.0),
        plan: p.plan.map(|x| x.0),
        session: None,
        amount: p.amount,
        facts: Facts::default(),
    };
    f.writer
        .db
        .read(move |c| Ok(g.dry(c, &who, p.action, &ctx, now)))
        .await
        .map_err(store_err)
}

pub async fn presence(f: &Front, _: &Caller, p: PresenceParams) -> Result<bool, Error> {
    f.core.matrix.set_away(p.away);
    // the away flag picks the time presets: the browser sessions' web proxies read their cells again
    f.writer.signals.answers_changed();
    Ok(p.away)
}

#[cfg(test)]
mod tests;
