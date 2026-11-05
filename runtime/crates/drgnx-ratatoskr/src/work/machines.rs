//! The machines the Work space shows (docs/develop/work-space.md, "Machines"): `local`, always, and those a user
//! connection reported (`machines/report`, from jobq) that have not yet expired.
//!
//! [`Registry`] is pure: it takes the time as an argument. [`Machines`] holds one behind the hub's lock, and the
//! handlers and [`run`] keep it current and send `machines-changed` when the list changed.

use crate::clock;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Empty;
use runstav::methods::work::{Machine, MachineReport, MachinesList, Slot};
use runstav::wire::Error;
use serde_json::json;
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

    /// `local` first, then the reported machines by name.
    pub fn list(&self) -> Vec<Machine> {
        let mut v = vec![Machine {
            machine: LOCAL.to_string(),
            slots: self.local.clone(),
            local: true,
        }];
        v.extend(self.remote.iter().map(|(m, r)| Machine {
            machine: m.clone(),
            slots: r.slots.clone(),
            local: false,
        }));
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
        self.reg.lock().expect("machines")
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
        f.core.map.machines(&list);
        f.broadcast(
            "machines-changed",
            json!(MachinesList {
                machines: list.clone()
            }),
        );
    }
    list
}

/// The local slots the hub starts with, read once the job pool is open and before anything is served: they are the
/// list's first state, not a change, so the first sweep sends no `machines-changed`.
pub fn seed(f: &Front) {
    f.core.machines.lock().set_local(local_slots(f));
}

/// The machines now (the registry brought up to date first): the Work map's seed.
pub(crate) fn list_now(f: &Front) -> Vec<Machine> {
    refresh(f)
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
        f.core.map.machines(&list);
        f.broadcast(
            "machines-changed",
            json!(MachinesList {
                machines: list.clone()
            }),
        );
    }
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
