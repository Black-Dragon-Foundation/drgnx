//! The machines the Work space shows (docs/develop/work-space.md, "Machines"): `local`, always, and those a user
//! connection reported (`machines/report`, from jobq) that have not yet expired.
//!
//! [`Registry`] is pure: it takes the time as an argument. [`Machines`] holds one behind the hub's lock, and the
//! handlers and [`run`] keep it current and send `machines-changed` when the list changed.
//!
//! Also `machines/move` ([`move_to`]): the user moves a job, or a session's next jobs, to another machine; a job that
//! runs is never stopped here, a card asks first and only its Restart moves it ([`card_settled`]).

use crate::agents::session::invalid;
use crate::clock;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Empty;
use runstav::methods::work::{Machine, MachineReport, MachinesList, MoveParams, MoveResult, Slot};
use runstav::wire::Error;
use serde_json::json;
use vegvisir::{MachineFact, RunnerFact};

use super::map::machine_fact;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How often an expired report is looked for when nothing else wakes the hub's sweeper.
const SWEEP: Duration = Duration::from_secs(2);

/// The machine every hub has.
pub const LOCAL: &str = "local";

/// Reports and the local slots; no clock, no I/O.
#[derive(Debug, Default)]
pub struct Registry {
    remote: BTreeMap<String, Reported>,
    local: Vec<Slot>,
    /// The runners the hub keeps (`runners/registry`): listed after `local`, never expiring.
    runners: Vec<String>,
    /// What the map shows of each runner: its fact and its cores (the load's total).
    facts: BTreeMap<String, (RunnerFact, u32)>,
}

#[derive(Debug)]
struct Reported {
    slots: Vec<Slot>,
    expires: f64,
}

impl Registry {
    /// R stands from NOW for its ttl; a second report for the machine replaces the first.
    pub fn report(&mut self, r: MachineReport, now: f64) {
        self.remote.insert(
            r.machine,
            Reported {
                slots: r.slots,
                expires: now + r.ttl,
            },
        );
    }

    /// Drop the reports that stood until NOW or earlier; their machines' names, sorted. `local` never expires.
    pub fn expire(&mut self, now: f64) -> Vec<String> {
        let gone: Vec<String> = self
            .remote
            .iter()
            .filter(|(_, r)| r.expires <= now)
            .map(|(m, _)| m.clone())
            .collect();
        for m in &gone {
            self.remote.remove(m);
        }
        gone
    }

    /// The local machine's slots as the job pool has them now. True when that changed the list.
    pub fn set_local(&mut self, slots: Vec<Slot>) -> bool {
        let changed = self.local != slots;
        self.local = slots;
        changed
    }

    /// The hub's runners, by name. True when that changed the list.
    pub fn set_runners(&mut self, mut names: Vec<String>) -> bool {
        names.sort();
        names.dedup();
        let changed = self.runners != names;
        self.runners = names;
        changed
    }

    /// What the map shows of the runners. True when that changed it.
    pub fn set_facts(&mut self, facts: BTreeMap<String, (RunnerFact, u32)>) -> bool {
        let changed = self.facts != facts;
        self.facts = facts;
        changed
    }

    /// The list as the map holds it: a runner's entry with its fact.
    pub fn map_facts(&self) -> Vec<MachineFact> {
        self.list()
            .iter()
            .map(|m| {
                let r = self.facts.get(&m.machine).map(|(r, c)| (r, *c));
                machine_fact(m, r.filter(|_| !m.local))
            })
            .collect()
    }

    /// `local` first, then the runners by name, then the reported machines by name (a report under a runner's name
    /// is the runner's own and is not listed twice).
    pub fn list(&self) -> Vec<Machine> {
        let mut v = vec![Machine {
            machine: LOCAL.to_string(),
            slots: self.local.clone(),
            local: true,
        }];
        v.extend(self.runners.iter().map(|m| Machine {
            machine: m.clone(),
            slots: Vec::new(),
            local: false,
        }));
        v.extend(
            self.remote
                .iter()
                .filter(|(m, _)| !self.runners.contains(m))
                .map(|(m, r)| Machine {
                    machine: m.clone(),
                    slots: r.slots.clone(),
                    local: false,
                }),
        );
        v
    }
}

/// The hub's registry.
#[derive(Default)]
pub struct Machines {
    reg: Mutex<Registry>,
}

impl Machines {
    fn lock(&self) -> std::sync::MutexGuard<'_, Registry> {
        saman::lock(&self.reg)
    }
}

/// The local pool as slots: one per agent-job slot, the busy ones held by "a job" (the pool does not say which).
fn local_slots(f: &Front) -> Vec<Slot> {
    let Some((total, free)) = f.core.exec.slot_counts() else {
        return Vec::new();
    };
    (0..total)
        .map(|i| Slot {
            id: format!("{LOCAL}-{}", i + 1),
            holder: (i < total.saturating_sub(free)).then(|| "job".to_string()),
            kind: "agent-job".to_string(),
        })
        .collect()
}

/// Bring the registry up to date (the local pool, expiries) and tell the subscribers when the list changed.
fn refresh(f: &Front) -> Vec<Machine> {
    let local = local_slots(f);
    let (list, changed) = {
        let mut g = f.core.machines.lock();
        let before = g.list();
        g.expire(clock::wall_secs());
        g.set_local(local);
        let after = g.list();
        let changed = before != after;
        (after, changed)
    };
    if changed {
        f.broadcast(
            "machines-changed",
            json!(MachinesList {
                machines: list.clone()
            }),
        );
    }
    feed_map(f);
    list
}

/// The map hears the machines as they stand, with each runner's fact (it holds only what differs), and the jobs the
/// sessions run (a running one on its runner), so a card's job and its "runs on" edge follow the job.
fn feed_map(f: &Front) {
    let queue = f.core.exec.queue();
    let mut facts = f.core.machines.lock().map_facts();
    // a runner's state and jobs are the queue's now, not those of the last `runners-changed`
    for m in &mut facts {
        if let (Some(r), Some(q)) = (m.runner.as_mut(), queue.as_ref()) {
            r.jobs = q.runner_jobs(&m.name);
            m.used = r.jobs;
            if let Some(row) = q.runner(&m.name) {
                r.state = row.state;
            }
        }
    }
    f.core.map.machines(facts);
    let live = f.core.exec.live();
    let keys = queue.map(|q| q.keys().clone());
    f.core.map.jobs(&|session| {
        let id = live.ids(session).into_iter().next()?;
        let row = f.core.exec.get(&id)?;
        let sent = keys
            .as_ref()
            .map(|k| {
                k.audit(Some(&id), None)
                    .into_iter()
                    .filter(|r| r.kind == runstav::methods::runners::AuditKind::Sent)
                    .map(|r| r.key.as_str().to_string())
                    .collect()
            })
            .unwrap_or_default();
        Some(super::map::job_fact(&row, sent))
    });
}

/// The map's machines now (the registry brought up to date first): the Work map's seed.
pub(crate) fn facts_now(f: &Front) -> Vec<MachineFact> {
    refresh(f);
    f.core.machines.lock().map_facts()
}

/// The local slots the hub starts with, read once the job pool is open and before anything is served: they are the
/// list's first state, not a change, so the first sweep sends no `machines-changed`.
pub fn seed(f: &Front) {
    f.core.machines.lock().set_local(local_slots(f));
}

/// The hub's runners are these (`runners/*`): they join the list after `local`, and the subscribers hear of a change.
pub fn set_runners(f: &Front, runners: Vec<(String, RunnerFact, u32)>) {
    let names: Vec<String> = runners.iter().map(|r| r.0.clone()).collect();
    let facts: BTreeMap<String, (RunnerFact, u32)> = runners
        .into_iter()
        .map(|(n, r, cores)| (n, (r, cores)))
        .collect();
    let (list, changed) = {
        let mut g = f.core.machines.lock();
        let before = g.list();
        g.set_runners(names);
        g.set_facts(facts);
        let after = g.list();
        let changed = before != after;
        (after, changed)
    };
    if changed {
        f.broadcast("machines-changed", json!(MachinesList { machines: list }));
    }
    feed_map(f);
}

/// `machines/report`. The caller is a user connection (the registry's class table).
pub async fn report(f: &Front, _: &Caller, p: MachineReport) -> Result<Machine, Error> {
    let name = p.machine.clone();
    refresh(f);
    let (list, changed) = {
        let mut g = f.core.machines.lock();
        let before = g.list();
        g.report(p, clock::wall_secs());
        let after = g.list();
        let changed = before != after;
        (after, changed)
    };
    if changed {
        f.broadcast(
            "machines-changed",
            json!(MachinesList {
                machines: list.clone()
            }),
        );
    }
    feed_map(f);
    Ok(list
        .into_iter()
        .find(|m| m.machine == name)
        .expect("the machine just reported"))
}

/// `machines/list`.
pub async fn list(f: &Front, _: &Caller, _: Empty) -> Result<MachinesList, Error> {
    Ok(MachinesList {
        machines: refresh(f),
    })
}

/// The sweeper: expired reports leave the list, and a job starting or ending is seen in the local slots, even when
/// nobody asks. Runs for the life of the hub. It waits on the clock only (an advance waits for a woken task to wait
/// on the clock again, and a task parked on a channel would be named busy).
pub async fn run(f: Arc<Front>) {
    loop {
        clock::sleep(SWEEP).await;
        refresh(&f);
    }
}

/// The kind of the card that asks whether to restart a running job on another machine.
const MOVE_CARD: &str = "machine-move";

/// The card that asks whether to restart job JOB (named NAME), which runs on ON, on TO: Restart or Keep.
pub fn move_card(job: &str, name: &str, to: &str, on: &str) -> norn::write::cards::NewCard {
    norn::write::cards::NewCard {
        job: None,
        task: None,
        kind: Some(MOVE_CARD.into()),
        title: Some(format!("Restart {name} on {to}? It stops the run on {on}")),
        data: Some(json!({"job": job, "machine": to, "choices": ["restart", "keep"]})),
    }
}

/// `machines/move`: a session's next jobs go to the machine; a waiting job is placed there; a running one is asked
/// about on a card (nothing stops). A machine that can't take it, or a target the hub doesn't hold, is refused.
pub async fn move_to(f: &Front, _: &Caller, p: MoveParams) -> Result<MoveResult, Error> {
    use crate::runners::queue::{Machine as To, Moved};
    let to = To::parse(Some(p.machine.as_str()));
    let exec = &f.core.exec;
    if let Some(sid) = p.target.strip_prefix("session:") {
        f.core
            .agents
            .find(sid)
            .map_err(|_| invalid("target", format!("no session {sid}")))?;
        exec.prefer(sid, to).map_err(|e| invalid("machine", e))?;
        return Ok(MoveResult {
            moved: true,
            card: None,
            said: format!("its next jobs go to {}", p.machine),
        });
    }
    let id = p.target.strip_prefix("job:").unwrap_or(&p.target);
    let row = exec
        .get(id)
        .ok_or_else(|| invalid("target", format!("no job {id}")))?;
    let moved = exec.move_job(id, to).map_err(|e| {
        let at = if e.message().starts_with("no job") {
            "target"
        } else {
            "machine"
        };
        invalid(at, e)
    })?;
    let to = p.machine;
    Ok(match moved {
        Moved::Requeued => MoveResult {
            moved: true,
            card: None,
            said: format!("job {id} waits for {to}"),
        },
        Moved::Same => MoveResult {
            moved: false,
            card: None,
            said: format!("job {id} is on {to} already"),
        },
        Moved::Running(on) => {
            let name = row.name.clone().unwrap_or_else(|| row.argv.join(" "));
            let card = move_card(id, &name, &to, &on);
            let at = clock::wall_secs();
            let made = f
                .writer
                .db
                .write(
                    urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "machines/move"),
                    move |tx| norn::write::cards::card_create(tx, card, at),
                )
                .await
                .map_err(|e| crate::agents::session::internal(e.to_string()))?;
            f.writer.signals.wrote();
            MoveResult {
                moved: false,
                card: Some(made.to_string()),
                said: format!("{name} runs on {on}: the card asks whether to restart it on {to}"),
            }
        }
    })
}

/// Card CARD was settled: a move card's Restart restarts its job on its machine (Keep leaves it running). What went
/// wrong is the log's; the card is answered either way.
pub async fn card_settled(f: &Front, card: i64) {
    let Ok(Some(c)) = f
        .writer
        .db
        .read(move |c| norn::read::cards::card(c, card))
        .await
    else {
        return;
    };
    if c.kind.as_deref() != Some(MOVE_CARD) || c.choice.as_deref() != Some("restart") {
        return;
    }
    let data = c.data.unwrap_or_default();
    let (Some(job), Some(to)) = (data["job"].as_str(), data["machine"].as_str()) else {
        return;
    };
    let to_m = crate::runners::queue::Machine::parse(Some(to));
    match f.core.exec.restart_on(job, to_m).await {
        Ok(now) => tracing::info!("job {job}: restarted on {to} as job {now}"),
        Err(e) => tracing::warn!("job {job}: not restarted on {to}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(machine: &str, ttl: f64) -> MachineReport {
        MachineReport {
            machine: machine.into(),
            slots: vec![Slot {
                id: "s1".into(),
                holder: None,
                kind: "build".into(),
            }],
            ttl,
        }
    }

    /// Pattern D: pure, the time is an argument.
    #[test]
    fn report_then_expire_after_ttl() {
        let mut reg = Registry::default();
        reg.report(r("desktop", 30.0), 100.0);
        assert_eq!(reg.list().len(), 2);
        assert!(reg.expire(129.9).is_empty());
        assert_eq!(reg.expire(130.0), ["desktop"]);
        assert_eq!(reg.list().len(), 1);
        // a second report replaces the first and moves the expiry
        reg.report(r("laptop", 10.0), 0.0);
        reg.report(r("laptop", 100.0), 5.0);
        assert!(reg.expire(50.0).is_empty());
        assert_eq!(reg.list()[1].machine, "laptop");
    }

    /// Pattern D: the runners follow `local`, never expire, and a report under a runner's name isn't listed twice.
    #[test]
    fn runners_are_listed_after_local_and_never_expire() {
        let mut reg = Registry::default();
        reg.report(r("desktop", 30.0), 100.0);
        reg.report(r("laptop", 30.0), 100.0);
        assert!(reg.set_runners(vec!["desktop".into(), "cloud-1".into()]));
        assert!(!reg.set_runners(vec!["cloud-1".into(), "desktop".into()]));
        let names =
            |reg: &Registry| -> Vec<String> { reg.list().into_iter().map(|m| m.machine).collect() };
        assert_eq!(names(&reg), ["local", "cloud-1", "desktop", "laptop"]);
        assert_eq!(
            reg.list()[2].slots.len(),
            0,
            "the runner's own entry, not the report"
        );
        assert_eq!(reg.expire(1000.0), ["desktop", "laptop"]);
        assert_eq!(names(&reg), ["local", "cloud-1", "desktop"]);
        assert!(reg.set_runners(vec![]));
        assert_eq!(names(&reg), ["local"]);
    }

    /// Pattern D.
    #[test]
    fn local_never_expires() {
        let mut reg = Registry::default();
        assert!(reg.expire(f64::MAX).is_empty());
        let l = reg.list();
        assert_eq!((l[0].machine.as_str(), l[0].local), (LOCAL, true));
        let slot = Slot {
            id: "local-1".into(),
            holder: Some("job".into()),
            kind: "agent-job".into(),
        };
        assert!(reg.set_local(vec![slot.clone()]));
        assert!(!reg.set_local(vec![slot]));
        assert!(reg.expire(f64::MAX).is_empty());
        assert_eq!(reg.list()[0].slots.len(), 1);
    }
}
