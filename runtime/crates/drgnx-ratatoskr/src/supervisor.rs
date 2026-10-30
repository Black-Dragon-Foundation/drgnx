//! The supervisor (Task 23; `docs/guide/agents.md`): rules per session and job with thresholds per kind of work —
//! `silent`, `repeat`, `no-progress`, `dead-wait`, `lease`, `refusals`, `unrecorded`, `manager-context` — each
//! pausing the agent after its tool call and making a `supervisor` card with fixes (and the `supervisor` event).
//! No model call.  Not the hub's own `ensure`/`stop` ([`crate::supervise`]).
//!
//! [`judge`] is the rules as a pure function of what was observed, the thresholds and a clock; [`run`] ticks once a
//! second, reads the sessions ([`Obs`]) and the facts the graph and the jobs hold ([`Facts`]), and acts on a rule the
//! first time it holds (it fires again only after the condition cleared).

use crate::front::Front;
use runstav::methods::agents::SessionStatus;
use runstav::methods::matrix::Role;
use runstav::methods::timeline::SupervisorRule as Rule;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How often the rules are looked at.
const EVERY: Duration = Duration::from_secs(1);

/// What one session shows (read by `Session::observe`).
#[derive(Clone, Debug)]
pub struct Obs {
    pub sid: String,
    pub task: Option<String>,
    pub role: Role,
    pub cwd: PathBuf,
    pub status: SessionStatus,
    /// The agent's last update (or its turn's start), seconds since the epoch.
    pub last_update: f64,
    /// Waiting on the user or a machine slot: silence is not the agent's.
    pub busy_elsewhere: bool,
    /// The most a tool call (same title and input) was repeated in this turn.
    pub max_repeat: u32,
    /// Tokens the finished turns used.
    pub tokens: u64,
    /// Waits refused in this turn.
    pub refusals: u32,
    /// Share of the context window used.
    pub context: Option<f64>,
    /// The jobs this session started that run.
    pub jobs: Vec<String>,
}

/// What is read elsewhere (the graph, the job rows, the tree) for one session.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    /// Lines changed in the session's tree, read only when the tokens could trip `no-progress`.
    pub lines: Option<u64>,
    /// The task's lease runs out at this time.
    pub lease_until: Option<f64>,
    /// The session's report names things it did not record (Task 21).
    pub unrecorded: bool,
    /// Jobs the session waits for that are gone.
    pub dead_jobs: Vec<String>,
}

/// The thresholds (settings of Task 13).
#[derive(Clone, Debug)]
pub struct Thresholds {
    pub silent_task: u64,
    pub silent_brainstorm: u64,
    pub repeat: u32,
    pub tokens_per_line: u64,
    pub refusals: u32,
    pub manager_context: f64,
    /// One lease interval: a task not beating for two of them is lost.
    pub lease_secs: f64,
}

impl Default for Thresholds {
    fn default() -> Thresholds {
        Thresholds {
            silent_task: 600,
            silent_brainstorm: 1800,
            repeat: 3,
            tokens_per_line: 20_000,
            refusals: 3,
            manager_context: 0.7,
            lease_secs: norn::write::tasks::LEASE_SECS,
        }
    }
}

impl Thresholds {
    /// From the settings as the hub holds them.
    pub fn of(v: &crate::settings::RuntimeValues) -> Thresholds {
        let d = Thresholds::default();
        let silent = |kind: &str, default: u64| {
            v.agents_silent_after
                .iter()
                .find(|(k, _)| k == kind)
                .map_or(default, |(_, s)| *s)
        };
        Thresholds {
            silent_task: silent("task", d.silent_task),
            silent_brainstorm: silent("brainstorm", d.silent_brainstorm),
            repeat: v.agents_repeat_limit,
            tokens_per_line: v.agents_no_progress_tokens,
            refusals: v.agents_wait_refusals,
            manager_context: v.agents_manager_context,
            lease_secs: d.lease_secs,
        }
    }
}

/// A chat is brainstorming; every other session works on a task.
fn brainstorm(o: &Obs) -> bool {
    o.role == Role::Chat
}

/// Whether the tokens could trip `no-progress` (so the lines are worth reading).
pub fn may_stall_on_lines(o: &Obs, t: &Thresholds) -> bool {
    !brainstorm(o) && t.tokens_per_line > 0 && o.tokens > t.tokens_per_line
}

/// The rules that hold for O now, each with the words of its card.  Pure: NOW and the thresholds are arguments.
pub fn judge(o: &Obs, f: &Facts, t: &Thresholds, now: f64) -> Vec<(Rule, String)> {
    let mut out = Vec::new();
    if o.status == SessionStatus::Exited {
        return out;
    }
    let after = if brainstorm(o) {
        t.silent_brainstorm
    } else {
        t.silent_task
    };
    if o.status == SessionStatus::Busy
        && !o.busy_elsewhere
        && after > 0
        && now - o.last_update >= after as f64
    {
        out.push((
            Rule::Silent,
            format!(
                "no update for {} s (limit {after} s)",
                (now - o.last_update) as u64
            ),
        ));
    }
    if t.repeat > 0 && o.max_repeat >= t.repeat {
        out.push((
            Rule::Repeat,
            format!("the same command {} times in one turn", o.max_repeat),
        ));
    }
    if may_stall_on_lines(o, t)
        && let Some(lines) = f.lines
        && o.tokens / lines.max(1) > t.tokens_per_line
    {
        out.push((
            Rule::NoProgress,
            format!("{} tokens for {lines} changed lines", o.tokens),
        ));
    }
    if o.status == SessionStatus::Waiting && !f.dead_jobs.is_empty() {
        out.push((
            Rule::DeadWait,
            format!("waits for {}, which is gone", f.dead_jobs.join(", ")),
        ));
    }
    if let Some(until) = f.lease_until
        && now >= until + t.lease_secs
    {
        out.push((
            Rule::Lease,
            format!("its task lease ran out {} s ago", (now - until) as u64),
        ));
    }
    if t.refusals > 0 && o.refusals >= t.refusals {
        out.push((
            Rule::Refusals,
            format!("{} refused waits in one turn", o.refusals),
        ));
    }
    if f.unrecorded {
        out.push((
            Rule::Unrecorded,
            "its report names work it did not record".into(),
        ));
    }
    if o.role == Role::Manager
        && let Some(c) = o.context
        && c >= t.manager_context
    {
        out.push((
            Rule::ManagerContext,
            format!("{:.0} % of its context window is used", c * 100.0),
        ));
    }
    out
}

/// The fixes a card offers for RULE.
pub fn fixes(rule: Rule) -> Vec<&'static str> {
    match rule {
        Rule::Silent | Rule::NoProgress => vec!["restart", "raise-time-box", "move-model"],
        Rule::Repeat | Rule::Refusals => vec!["restart", "move-model"],
        Rule::DeadWait | Rule::Lease => vec!["restart", "kill-process"],
        Rule::Unrecorded => vec!["restart"],
        Rule::ManagerContext => vec!["rotate"],
    }
}

/// The rules' state: which rule holds for which session, so a card is made once until the condition clears.
#[derive(Default)]
pub struct Supervisor {
    held: Mutex<HashSet<(String, String)>>,
}

fn name(rule: Rule) -> String {
    serde_json::to_value(rule)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default()
}

impl Supervisor {
    /// The rules of FOUND (for session SID) that did not hold at the last look; the others are remembered.
    fn fresh(&self, sid: &str, found: Vec<(Rule, String)>) -> Vec<(Rule, String)> {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|(s, r)| s != sid || found.iter().any(|(f, _)| &name(*f) == r));
        found
            .into_iter()
            .filter(|(r, _)| held.insert((sid.to_string(), name(*r))))
            .collect()
    }

    /// Sessions the hub no longer holds are forgotten.
    fn only(&self, sids: &HashSet<&str>) {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|(s, _)| sids.contains(s.as_str()));
    }

    /// One look at every session at NOW: new findings pause their agent and make a card.
    pub async fn tick(&self, f: &Front, now: f64) {
        let obs = f.core.agents.observations();
        self.only(&obs.iter().map(|o| o.sid.as_str()).collect());
        let t = Thresholds::of(&f.settings.current().loaded.values);
        for o in obs {
            let facts = facts_of(f, &o, &t).await;
            for (rule, text) in self.fresh(&o.sid, judge(&o, &facts, &t, now)) {
                act(f, &o, rule, &text).await;
            }
        }
    }
}

/// Read what [`judge`] needs beyond the observation.
async fn facts_of(f: &Front, o: &Obs, t: &Thresholds) -> Facts {
    let mut facts = Facts::default();
    if o.status == SessionStatus::Waiting {
        for j in &o.jobs {
            let gone = match f.core.exec.get(j) {
                Some(r) => {
                    !matches!(
                        r.status,
                        runstav::methods::exec::ExecStatus::Running
                            | runstav::methods::exec::ExecStatus::Queued
                    ) || f.core.exec.process_gone(j)
                }
                None => true,
            };
            if gone {
                facts.dead_jobs.push(j.clone());
            }
        }
    }
    if may_stall_on_lines(o, t) {
        facts.lines = changed_lines(&o.cwd).await;
    }
    if let Some(task) = o.task.clone() {
        let (sid, task_id) = (o.sid.clone(), task.clone());
        let read = f
            .writer
            .db
            .read(move |c| {
                let lease = norn::read::tasks::task_row(c, &task_id)?
                    .filter(|r| matches!(r.status.as_deref(), Some("claimed" | "running")))
                    .and_then(|r| r.lease_until);
                let mut st = c.prepare(
                    "select data from entity where kind = 'report' and retired_tx is null \
                     and json_extract(data, '$.session') = ?1",
                )?;
                let rows = st.query_map([&sid], |r| r.get::<_, String>(0))?;
                let mut unrecorded = false;
                for data in rows.flatten() {
                    let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
                    unrecorded |= d["unrecorded"].as_array().is_some_and(|a| !a.is_empty());
                }
                Ok((lease, unrecorded))
            })
            .await;
        if let Ok((lease, unrecorded)) = read {
            facts.lease_until = lease;
            facts.unrecorded = unrecorded;
        }
    }
    facts
}

/// Added plus deleted lines of the tree against HEAD (none when it is no repository).
async fn changed_lines(cwd: &std::path::Path) -> Option<u64> {
    let cwd = cwd.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let out = std::process::Command::new("git")
            .args(["diff", "--numstat", "HEAD"])
            .current_dir(cwd)
            .output()
            .ok()
            .filter(|o| o.status.success())?;
        Some(
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|l| {
                    let mut p = l.split_whitespace();
                    Some(p.next()?.parse::<u64>().ok()? + p.next()?.parse::<u64>().ok()?)
                })
                .sum(),
        )
    })
    .await
    .ok()
    .flatten()
}

/// Pause the agent (not for `manager-context`: that one is rotated first, one path, and the card says it was), make
/// the card, announce it.
async fn act(f: &Front, o: &Obs, rule: Rule, text: &str) {
    let mut text = text.to_string();
    let mut deferred = false;
    if rule == Rule::ManagerContext {
        use crate::manager::Rotation;
        let said = match crate::manager::rotate_for_context(f, &o.sid).await {
            Rotation::Done => {
                "rotated: a fresh session was started with its digest and open decisions"
            }
            Rotation::Deferred => {
                deferred = true;
                "its turn is running: it is rotated when the turn ends"
            }
            Rotation::Failed => "could not be rotated",
        };
        text = format!("{text}; {said}");
    } else {
        let _ = f.core.agents.cancel_after_tool(&o.sid);
    }
    let text = text.as_str();
    if rule == Rule::Silent {
        f.core.agents.mark_stalled(&o.sid);
    }
    let rule_name = name(rule);
    let data = json!({
        "session": o.sid, "rule": rule_name, "text": text, "fixes": fixes(rule), "choices": fixes(rule),
    });
    let card = norn::write::cards::NewCard {
        job: None,
        task: o.task.clone(),
        kind: Some("supervisor".into()),
        title: Some(format!("{rule_name}: {text}")),
        data: Some(data),
    };
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    let made = f
        .writer
        .db
        .write(
            urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "supervisor"),
            move |tx| norn::write::cards::card_create(tx, card, at),
        )
        .await;
    match made {
        Ok(id) => {
            if deferred {
                crate::manager::note_card(f, &o.sid, id).await;
            }
            f.writer.signals.wrote();
            f.broadcast(
                "supervisor",
                json!({
                    "rule": rule_name, "session": o.sid, "task": o.task, "card": id, "text": text,
                }),
            );
        }
        Err(e) => tracing::warn!("a supervisor card was not made: {e}"),
    }
}

/// The hub's loop (spawned once by the server).
pub async fn run(f: Arc<Front>) {
    let mut every = tokio::time::interval(EVERY);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        every.tick().await;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        f.core.supervisor.tick(&f, now).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs() -> Obs {
        Obs {
            sid: "s1".into(),
            task: Some("t1".into()),
            role: Role::Worker,
            cwd: PathBuf::from("/tmp"),
            status: SessionStatus::Busy,
            last_update: 1000.0,
            busy_elsewhere: false,
            max_repeat: 0,
            tokens: 0,
            refusals: 0,
            context: None,
            jobs: vec![],
        }
    }

    fn rules(o: &Obs, f: &Facts, now: f64) -> Vec<Rule> {
        judge(o, f, &Thresholds::default(), now)
            .into_iter()
            .map(|(r, _)| r)
            .collect()
    }

    #[test]
    fn silent_fires_at_the_threshold_of_its_kind_of_work() {
        let (o, f) = (obs(), Facts::default());
        assert!(rules(&o, &f, 1599.0).is_empty());
        assert_eq!(rules(&o, &f, 1600.0), vec![Rule::Silent]);
        let chat = Obs {
            role: Role::Chat,
            ..obs()
        };
        assert!(rules(&chat, &f, 1600.0).is_empty());
        assert_eq!(rules(&chat, &f, 2800.0), vec![Rule::Silent]);
        let waiting = Obs {
            busy_elsewhere: true,
            ..obs()
        };
        assert!(rules(&waiting, &f, 9000.0).is_empty());
    }

    #[test]
    fn repeat_refusals_and_manager_context_hold_at_their_limits() {
        let f = Facts::default();
        let o = Obs {
            max_repeat: 3,
            refusals: 3,
            ..obs()
        };
        assert_eq!(rules(&o, &f, 1000.0), vec![Rule::Repeat, Rule::Refusals]);
        let o = Obs {
            max_repeat: 2,
            refusals: 2,
            ..obs()
        };
        assert!(rules(&o, &f, 1000.0).is_empty());
        let m = Obs {
            role: Role::Manager,
            context: Some(0.71),
            ..obs()
        };
        assert_eq!(rules(&m, &f, 1000.0), vec![Rule::ManagerContext]);
        let w = Obs {
            context: Some(0.99),
            ..obs()
        };
        assert!(rules(&w, &f, 1000.0).is_empty());
    }

    #[test]
    fn brainstorm_is_not_judged_by_lines() {
        let f = Facts {
            lines: Some(0),
            ..Facts::default()
        };
        let task = Obs {
            tokens: 50_000,
            ..obs()
        };
        assert_eq!(rules(&task, &f, 1000.0), vec![Rule::NoProgress]);
        let chat = Obs {
            role: Role::Chat,
            tokens: 50_000,
            ..obs()
        };
        assert!(!may_stall_on_lines(&chat, &Thresholds::default()));
        assert!(rules(&chat, &f, 1000.0).is_empty());
        // 50 000 tokens over 3 lines is 16 666 each: under the limit
        let f = Facts {
            lines: Some(3),
            ..Facts::default()
        };
        assert!(rules(&task, &f, 1000.0).is_empty());
    }

    #[test]
    fn dead_wait_lease_and_unrecorded_come_from_the_facts() {
        let waiting = Obs {
            status: SessionStatus::Waiting,
            ..obs()
        };
        let dead = Facts {
            dead_jobs: vec!["j1".into()],
            ..Facts::default()
        };
        assert_eq!(rules(&waiting, &dead, 1000.0), vec![Rule::DeadWait]);
        // a busy session with the same facts is not waiting
        assert!(rules(&obs(), &dead, 1000.0).is_empty());
        let lease = Facts {
            lease_until: Some(2000.0),
            ..Facts::default()
        };
        let beating = Obs {
            last_update: 2899.0,
            ..obs()
        };
        assert!(rules(&beating, &lease, 2899.0).is_empty());
        let beating = Obs {
            last_update: 2900.0,
            ..obs()
        };
        assert_eq!(rules(&beating, &lease, 2900.0), vec![Rule::Lease]);
        let un = Facts {
            unrecorded: true,
            ..Facts::default()
        };
        assert_eq!(rules(&obs(), &un, 1000.0), vec![Rule::Unrecorded]);
    }

    #[test]
    fn a_session_that_exited_is_not_judged() {
        let o = Obs {
            status: SessionStatus::Exited,
            max_repeat: 9,
            ..obs()
        };
        assert!(rules(&o, &Facts::default(), 9999.0).is_empty());
    }

    #[test]
    fn a_rule_fires_once_until_its_condition_clears() {
        let s = Supervisor::default();
        let one = || vec![(Rule::Silent, "x".to_string())];
        assert_eq!(s.fresh("a", one()).len(), 1);
        assert!(s.fresh("a", one()).is_empty());
        assert_eq!(s.fresh("b", one()).len(), 1);
        assert!(s.fresh("a", vec![]).is_empty());
        assert_eq!(s.fresh("a", one()).len(), 1);
        s.only(&HashSet::from(["b"]));
        assert_eq!(s.fresh("a", one()).len(), 1);
    }

    #[test]
    fn thresholds_come_from_the_settings() {
        let v = crate::settings::RuntimeValues {
            agents_silent_after: vec![("task".into(), 1), ("brainstorm".into(), 5)],
            agents_repeat_limit: 2,
            ..Default::default()
        };
        let t = Thresholds::of(&v);
        assert_eq!((t.silent_task, t.silent_brainstorm, t.repeat), (1, 5, 2));
        let t = Thresholds::of(&crate::settings::RuntimeValues {
            agents_silent_after: vec![],
            ..Default::default()
        });
        assert_eq!(t.silent_task, 600);
    }
}
