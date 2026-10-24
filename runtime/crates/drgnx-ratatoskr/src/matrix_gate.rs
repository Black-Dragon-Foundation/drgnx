//! The permissions matrix in the hub (Task 12; `docs/guide/security.md`, "The permissions matrix"): every action an
//! agent takes is checked (`MatrixGate::check(who, action, ctx) -> Gate`) against `norn::matrix`'s effective cells
//! for its columns, with the `agents-matrix` setting, the project's and the plan's overrides and the away signal;
//! an Ask makes one `matrix` card from facts the hub derived; it is re-checked when it executes; a manager's grants
//! to its workers only narrow its own (`delegate`).  Methods `matrix/get`, `matrix/check`, `presence/set`.
//!
//! One limit per cell: the 30 % weekly share of a subscription is the budget gate's check ([`crate::budget`]), not the
//! cell's.  A plan's override is its entity's `matrix` data field and counts only when the user wrote it.

use crate::backup_timer::local;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::settings::matrix as decode;
use norn::matrix::{
    Action, Cell, Column, Effective, Matrix, Preset, TimePreset, Verdict, Who, Widening, active,
    decide, effective, narrow, preset,
};
use norn::store::{CoordError, WTx};
use norn::write::cards::{MatrixAsk, matrix_card, matrix_card_get};
use runstav::methods::matrix::{
    CellRow, CheckAnswer, CheckParams, EffectiveRow, Facts, GetParams, MatrixView, PresenceParams,
    WhoParam,
};
use runstav::types::Bounded;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::BTreeMap;
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
    /// The session acting (a manager's grants to it replace its columns' cells).
    pub session: Option<String>,
    pub amount: Option<f64>,
    pub facts: Facts,
}

#[derive(Default)]
struct State {
    base: Option<Preset>,
    time: Vec<TimePreset>,
    away: bool,
    user: Matrix,
    projects: BTreeMap<String, Matrix>,
    /// Worker session → what its manager handed it.
    delegated: BTreeMap<String, Effective>,
}

/// The gate's state: the setting as last read, the away flag, the managers' grants.
#[derive(Default, Clone)]
pub struct MatrixGate {
    st: Arc<Mutex<State>>,
}

fn who_json(w: &Who) -> Value {
    json!(WhoParam {
        role: w.role,
        agent: w.agent.clone().map(Bounded),
        provider: w.provider.clone().map(Bounded),
    })
}

fn who_of(v: &Value) -> Who {
    serde_json::from_value::<WhoParam>(v.clone())
        .map(|p| Who::from(&p))
        .unwrap_or_default()
}

/// The plan's override when the user wrote it (any other author's is ignored).
fn plan_override(conn: &urdr::Connection, plan: &str) -> Option<Matrix> {
    let ent = urdr::graph::entity::by_id(conn, plan).ok()??;
    let field = ent.data.get("matrix")?;
    let tx = *ent.field_tx.get("data")?;
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

fn card_title(a: Action, f: &Facts) -> String {
    let plain = |v: Value| v.as_str().unwrap_or_default().to_string();
    let what = match (&f.command, f.paths.0.first(), &f.diff_hash) {
        (Some(c), _, _) => plain(json!(c)),
        (None, Some(p), _) => plain(json!(p)),
        (None, None, Some(h)) => format!("diff {}", plain(json!(h))),
        _ => String::new(),
    };
    format!("{}: {}", a.id(), what)
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

    /// A project's override layer (its `agents-matrix` cells).
    pub fn set_project(&self, project: &str, m: Matrix) {
        self.st
            .lock()
            .expect("matrix gate")
            .projects
            .insert(project.to_string(), m);
    }

    /// `presence/set`: from the next action the time presets follow.
    pub fn set_away(&self, away: bool) {
        self.st.lock().expect("matrix gate").away = away;
    }

    fn preset_now(&self, now: f64) -> (Preset, Preset, bool) {
        let st = self.st.lock().expect("matrix gate");
        let base = st.base.unwrap_or(Preset::Balanced);
        (base, active(base, &st.time, st.away, minute(now)), st.away)
    }

    /// Who's effective cells: the active preset, the user's, the project's and the plan's layers; a manager's grant to
    /// a session replaces them.
    pub fn effective_for(
        &self,
        conn: &urdr::Connection,
        who: &Who,
        ctx: &ActionCtx,
        now: f64,
    ) -> Effective {
        let (_, act, _) = self.preset_now(now);
        let (user, project, delegated) = {
            let st = self.st.lock().expect("matrix gate");
            (
                st.user.clone(),
                ctx.project
                    .as_ref()
                    .and_then(|p| st.projects.get(p))
                    .cloned(),
                ctx.session
                    .as_ref()
                    .and_then(|s| st.delegated.get(s))
                    .cloned(),
            )
        };
        if let Some(d) = delegated {
            return d;
        }
        let plan = ctx.plan.as_deref().and_then(|p| plan_override(conn, p));
        let base = preset(act);
        let mut layers: Vec<&Matrix> = vec![&base, &user];
        layers.extend(project.as_ref());
        layers.extend(plan.as_ref());
        effective(&layers, who)
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
            Verdict::Ask => {
                let data = json!({
                    "action": a.id(),
                    "who": who_json(who),
                    "session": ctx.session,
                    "project": ctx.project,
                    "plan": ctx.plan,
                    "amount": ctx.amount,
                    "facts": ctx.facts,
                });
                let ask = MatrixAsk {
                    title: card_title(a, &ctx.facts),
                    data,
                    job: None,
                };
                Gate::Ask(matrix_card(tx, ask, now)?)
            }
        })
    }

    /// At execution: the card's answer under the matrix as it is now.  A switch that made the action Never refuses
    /// it whatever the user said; an open card is still a question; a declined one is a refusal.
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
            facts: Facts::default(),
        };
        let who = who_of(c.data.get("who").unwrap_or(&Value::Null));
        let (v, why) = self.verdict(conn, &who, a, &ctx, now);
        if v == Verdict::Never {
            return Gate::Never(why);
        }
        match (c.state.as_str(), c.choice.as_deref()) {
            ("settled", Some("allow")) => Gate::Allow,
            ("settled", _) => Gate::Never("the user declined".into()),
            _ if v == Verdict::Allow => Gate::Allow,
            _ => Gate::Ask(card),
        }
    }

    /// A manager's grant to its worker: ASKED, no wider than what MANAGER (session MANAGER_SID) has itself.  The
    /// worker's cells are ASKED from now on.  (Kept in the hub, not as a `grant` entity: grants are the user's.)
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
        self.st
            .lock()
            .expect("matrix gate")
            .delegated
            .insert(worker_sid.to_string(), granted);
        Ok(())
    }

    fn view(&self, conn: &urdr::Connection, p: &GetParams, now: f64) -> MatrixView {
        let (base, act, away) = self.preset_now(now);
        let plan_id = p.plan.as_ref().map(|x| x.0.clone());
        let project = p.project.as_ref().map(|x| x.0.clone());
        let (user, time, proj) = {
            let st = self.st.lock().expect("matrix gate");
            (
                st.user.clone(),
                st.time.clone(),
                project.as_ref().and_then(|x| st.projects.get(x)).cloned(),
            )
        };
        let plan = plan_id.as_deref().and_then(|x| plan_override(conn, x));
        let preset_m = preset(act);
        let mut layers: Vec<&Matrix> = vec![&preset_m, &user];
        layers.extend(proj.as_ref());
        layers.extend(plan.as_ref());
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
            backend: false,
        };
        writer
            .write(&system, "coord/matrix-check", move |tx| {
                g.check(tx, &who, a, &ctx, now)
            })
            .await
            .unwrap_or(Gate::Ask(0))
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
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
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
    Ok(p.away)
}

#[cfg(test)]
mod tests;
