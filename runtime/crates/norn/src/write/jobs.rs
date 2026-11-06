//! Jobs (Task 6; entities since Urdr Task 12): `job_create` and `job_set`.  A job is a row of the kept `job` table; its tasks are entities `task:JOB#N` (call 5) with
//! `blocks` links from each dependency to the task that waits on it.

use super::event::{Event, EventKind, event};
use super::tasks::entity_id;
use crate::read::tasks::opt;
use crate::store::{CoordError, WTx};
use serde_json::{Value, json};
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::link;

/// One task of a new job; those without dependencies start `ready`, the rest `pending`.
#[derive(Debug, Clone)]
pub struct NewTask {
    pub n: i64,
    pub title: String,
    pub role: Option<String>,
    /// The numbers of the tasks (of the same job) this one waits on.
    pub deps: Vec<i64>,
}

#[derive(Debug, Clone)]
pub struct NewJob {
    pub id: String,
    pub title: String,
    pub plan: Option<String>,
    pub repo: Option<String>,
    pub tasks: Vec<NewTask>,
    /// Kept with the job (`drgnx-coord-job`'s data).
    pub data: Option<Value>,
}

/// Make the job, its tasks (`ID#N`, entities) and their dependencies (`blocks` links), at time NOW: the job's id
/// (`drgnx-coord-job-create`).  A dependency naming a task the job does not have is left out (a link needs both ends).
pub fn job_create(tx: &mut WTx<'_>, j: NewJob, now: f64) -> Result<String, CoordError> {
    let by = tx.id();
    tx.sql().execute(
        // the columns named: schema 7 adds `tx`
        "insert into job (id, title, plan, repo, status, created, data, tx) values (?1, ?2, ?3, ?4, 'proposed', ?5, ?6, ?7)",
        (
            &j.id,
            &j.title,
            &j.plan,
            &j.repo,
            now,
            j.data.as_ref().map(Value::to_string),
            by,
        ),
    )?;
    let project = tx.meta().project;
    let mut made: Vec<(i64, i64)> = Vec::new();
    for t in &j.tasks {
        let tid = format!("{}#{}", j.id, t.n);
        let e = entity::create(
            tx,
            EntityNew {
                id: entity_id(&tid),
                kind: "task".into(),
                project,
                title: Some(t.title.clone()),
                status: Some(
                    if t.deps.is_empty() {
                        "ready"
                    } else {
                        "pending"
                    }
                    .into(),
                ),
                body: None,
                priority: None,
                assignee: None,
                data: json!({"job": j.id, "n": t.n, "role": t.role}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        made.push((t.n, e.n));
    }
    for t in &j.tasks {
        let Some(&(_, task)) = made.iter().find(|(n, _)| *n == t.n) else {
            continue;
        };
        for d in &t.deps {
            if let Some(&(_, dep)) = made.iter().find(|(n, _)| n == d) {
                link::add(tx, dep, "blocks", task, None, Origin::Recorded, None)?;
            }
        }
    }
    Ok(j.id)
}

/// Change job ID's STATUS and/or DATA.  A change of STATUS leaves a `job` event (`drgnx-coord-job-set`).
pub fn job_set(
    tx: &mut WTx<'_>,
    id: &str,
    status: Option<&str>,
    data: Option<&Value>,
    now: f64,
) -> Result<(), CoordError> {
    let by = tx.id();
    if let Some(status) = status {
        let old: Option<Option<String>> =
            opt(tx
                .sql()
                .query_row("select status from job where id = ?1", [id], |r| r.get(0)))?;
        tx.sql().execute(
            "update job set status = ?1, tx = ?3 where id = ?2",
            (status, id, by),
        )?;
        if let Some(old) = old.flatten()
            && old != status
        {
            event(
                tx,
                Event {
                    at: now,
                    agent: None,
                    job: Some(id.to_owned()),
                    task: None,
                    kind: EventKind::Job,
                    summary: format!("job {id}: {old} -> {status}"),
                    data: Some(json!({"status": status})),
                    turn: false,
                },
            )?;
        }
    }
    if let Some(data) = data {
        tx.sql().execute(
            "update job set data = ?1, tx = ?3 where id = ?2",
            (data.to_string(), id, by),
        )?;
    }
    Ok(())
}

/// Whether job ID is `proposed`, read in TX.
fn proposed(tx: &WTx<'_>, id: &str) -> Result<bool, CoordError> {
    let status: Option<Option<String>> =
        opt(tx
            .sql()
            .query_row("select status from job where id = ?1", [id], |r| r.get(0)))?;
    Ok(status.flatten().as_deref() == Some("proposed"))
}

/// Job ID approved: `running`, its data DATA, only while it is still `proposed`, read in this same transaction (the
/// store's writes are one at a time), so of an approval and a withdrawal of one proposal exactly one holds.  Whether
/// it was.
pub fn approve_proposal(
    tx: &mut WTx<'_>,
    id: &str,
    data: &Value,
    now: f64,
) -> Result<bool, CoordError> {
    if !proposed(tx, id)? {
        return Ok(false);
    }
    job_set(tx, id, Some("running"), Some(data), now)?;
    Ok(true)
}

/// Job ID's proposal withdrawn: `stopped`, its data marked MARK (a proposal that never started), only while it is
/// still `proposed`, read in this same transaction: a job approved before it runs on.  Whether it was.
pub fn withdraw_proposal(
    tx: &mut WTx<'_>,
    id: &str,
    mark: &str,
    now: f64,
) -> Result<bool, CoordError> {
    if !proposed(tx, id)? {
        return Ok(false);
    }
    let data: Option<Option<String>> =
        opt(tx
            .sql()
            .query_row("select data from job where id = ?1", [id], |r| r.get(0)))?;
    let mut data = match data
        .flatten()
        .and_then(|d| serde_json::from_str::<Value>(&d).ok())
    {
        Some(Value::Object(m)) => m,
        _ => serde_json::Map::new(),
    };
    data.insert(mark.into(), json!(true));
    job_set(tx, id, Some("stopped"), Some(&Value::Object(data)), now)?;
    Ok(true)
}

/// Job ID stopped by the user, decided in this one transaction: a proposal is withdrawn (stopped, marked MARK, as
/// [`withdraw_proposal`]); any other job is stopped with its data as it is, so one approved a moment before is never
/// marked as a proposal that did not start.  Whether it was a proposal.
pub fn stop_job(tx: &mut WTx<'_>, id: &str, mark: &str, now: f64) -> Result<bool, CoordError> {
    if withdraw_proposal(tx, id, mark, now)? {
        return Ok(true);
    }
    job_set(tx, id, Some("stopped"), None, now)?;
    Ok(false)
}

/// Job ID paused (a budget limit was reached), only while it is `running`, read in this same transaction: a job
/// stopped first stays stopped.  Whether it was.
pub fn pause_running(tx: &mut WTx<'_>, id: &str, now: f64) -> Result<bool, CoordError> {
    let status: Option<Option<String>> =
        opt(tx
            .sql()
            .query_row("select status from job where id = ?1", [id], |r| r.get(0)))?;
    if status.flatten().as_deref() != Some("running") {
        return Ok(false);
    }
    job_set(tx, id, Some("paused"), None, now)?;
    Ok(true)
}

/// Job ID running again, read and written in this one transaction: only while it is `paused` or `stopped` and its
/// data has no MARK (a proposal that never started); BUDGET, when given, becomes its data's `budget`, the rest of its
/// data as it is now.  Why not, when it does not.
pub fn resume_job(
    tx: &mut WTx<'_>,
    id: &str,
    mark: &str,
    budget: Option<f64>,
    now: f64,
) -> Result<Result<(), String>, CoordError> {
    let row: Option<(Option<String>, Option<String>)> =
        opt(tx
            .sql()
            .query_row("select status, data from job where id = ?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            }))?;
    let Some((status, data)) = row else {
        return Ok(Err(format!("No job {id}")));
    };
    let status = status.unwrap_or_default();
    if !matches!(status.as_str(), "paused" | "stopped") {
        return Ok(Err(format!("Job {id} is {status}, not paused")));
    }
    let mut data = match data.and_then(|d| serde_json::from_str::<Value>(&d).ok()) {
        Some(Value::Object(m)) => m,
        _ => serde_json::Map::new(),
    };
    if data.contains_key(mark) {
        return Ok(Err(format!(
            "Job {id} was never approved: propose the plan again"
        )));
    }
    if let Some(b) = budget {
        data.insert("budget".into(), json!(b));
    }
    job_set(tx, id, Some("running"), Some(&Value::Object(data)), now)?;
    Ok(Ok(()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7, tx_of};

    #[test]
    fn a_job_with_dependencies_and_a_status_change() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let task = |n, deps: &[i64]| NewTask {
            n,
            title: format!("t{n}"),
            role: None,
            deps: deps.to_vec(),
        };
        job_create(
            &mut tx,
            NewJob {
                id: "j".into(),
                title: "J".into(),
                plan: None,
                repo: None,
                tasks: vec![task(1, &[]), task(2, &[1])],
                data: None,
            },
            5.0,
        )
        .unwrap();
        let st: Vec<String> = {
            let mut s = tx
                .sql()
                .prepare("select status from jtask order by n")
                .unwrap();
            s.query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(st, ["ready", "pending"]);
        let deps: Vec<(String, String)> = {
            let mut s = tx.sql().prepare("select task, dep from jdep").unwrap();
            s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(deps, [("j#2".to_string(), "j#1".to_string())]);
        job_set(&mut tx, "j", Some("running"), None, 6.0).unwrap();
        job_set(&mut tx, "j", Some("running"), None, 7.0).unwrap();
        let n: i64 = tx
            .sql()
            .query_row("select count(*) from event where kind = 'job'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(n, 1);
    }

    /// A revision's withdrawal and the user's approval of one proposal: each reads the status, then writes.
    #[derive(Clone, Debug)]
    enum Ev {
        WithdrawRead,
        WithdrawWrite,
        ApproveRead,
        ApproveWrite,
    }
    skuld::events!(Ev {
        WithdrawRead,
        WithdrawWrite,
        ApproveRead,
        ApproveWrite
    });

    /// A store with proposal `j`, and what each side saw and did.
    struct Race {
        c: urdr::Connection,
        withdraw_saw: bool,
        approve_saw: bool,
        withdrawn: bool,
        approved: bool,
    }

    impl Race {
        fn new() -> Race {
            let mut c = db7();
            let mut tx = tx_of(&mut c);
            job_create(
                &mut tx,
                NewJob {
                    id: "j".into(),
                    title: "J".into(),
                    plan: None,
                    repo: None,
                    tasks: Vec::new(),
                    data: None,
                },
                1.0,
            )
            .unwrap();
            tx.commit_for_test().unwrap();
            Race {
                c,
                withdraw_saw: false,
                approve_saw: false,
                withdrawn: false,
                approved: false,
            }
        }

        fn status(&self) -> String {
            self.c
                .query_row("select status from job where id = 'j'", [], |r| r.get(0))
                .unwrap()
        }

        /// F in one transaction, committed.
        fn write(&mut self, f: impl FnOnce(&mut WTx<'_>) -> bool) -> bool {
            let mut tx = tx_of(&mut self.c);
            let done = f(&mut tx);
            tx.commit_for_test().unwrap();
            done
        }
    }

    impl skuld::Core for Race {
        type Event = Ev;
        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            match ev {
                Ev::WithdrawRead => self.withdraw_saw = self.status() == "proposed",
                Ev::WithdrawWrite if self.withdraw_saw => {
                    self.withdrawn =
                        self.write(|tx| withdraw_proposal(tx, "j", "never_approved", 2.0).unwrap());
                }
                Ev::ApproveRead => self.approve_saw = self.status() == "proposed",
                Ev::ApproveWrite if self.approve_saw => {
                    self.approved =
                        self.write(|tx| approve_proposal(tx, "j", &json!({}), 3.0).unwrap());
                }
                _ => {}
            }
            Vec::new()
        }
    }

    /// A (every order): an approval between a withdrawal's status read and its write.  Exactly one of them holds,
    /// and an approved job is never stopped by the withdrawal (running work stops only on an explicit stop).
    #[test]
    fn every_order_an_approval_and_a_withdrawal_never_stop_a_running_job() {
        let mut p = skuld::Partial::new();
        p.source("say", vec![Ev::WithdrawRead, Ev::WithdrawWrite]);
        p.source("user", vec![Ev::ApproveRead, Ev::ApproveWrite]);
        let r = skuld::every_order(&p, skuld::Bound::default(), Race::new, |s, order| {
            let status =
                s.c.query_row("select status from job where id = 'j'", [], |r| {
                    r.get::<_, String>(0)
                });
            let status = status.map_err(|e| e.to_string())?;
            if s.approved && status != "running" {
                return Err(format!("an approved job is {status} in {order:?}"));
            }
            if s.approved && s.withdrawn {
                return Err(format!("approved and withdrawn both in {order:?}"));
            }
            Ok(())
        });
        assert!(r.orders > 1, "{r:?}");
    }

    /// The user's stop of a job and the writes it can meet: an approval (which reads the status, then writes), the
    /// budget pause.  The stop and the pause each decide in their one write ([`stop_job`], [`pause_running`]).
    #[derive(Clone, Debug)]
    enum StopEv {
        Stop,
        ApproveRead,
        ApproveWrite,
    }
    skuld::events!(StopEv {
        Stop,
        ApproveRead,
        ApproveWrite
    });

    /// The user's stop and the budget pause of a running job.
    #[derive(Clone, Debug)]
    enum PauseEv {
        Stop,
        Pause,
    }
    skuld::events!(PauseEv { Stop, Pause });

    struct Pauses(Stops);

    impl skuld::Core for Pauses {
        type Event = PauseEv;
        fn step(&mut self, ev: PauseEv) -> Vec<PauseEv> {
            match ev {
                PauseEv::Stop => {
                    skuld::Core::step(&mut self.0, StopEv::Stop);
                }
                PauseEv::Pause => {
                    self.0.r.write(|tx| pause_running(tx, "j", 4.0).unwrap());
                }
            }
            Vec::new()
        }
    }

    struct Stops {
        r: Race,
    }

    impl Stops {
        /// Job `j` at STATUS.
        fn at(status: &str) -> Stops {
            let mut r = Race::new();
            if status != "proposed" {
                r.write(|tx| job_set(tx, "j", Some(status), None, 1.5).is_ok());
            }
            Stops { r }
        }

        fn never_approved(&self) -> bool {
            self.r
                .c
                .query_row(
                    "select json_extract(data, '$.never_approved') is not null from job where id = 'j'",
                    [],
                    |r| r.get(0),
                )
                .unwrap()
        }
    }

    impl skuld::Core for Stops {
        type Event = StopEv;
        fn step(&mut self, ev: StopEv) -> Vec<StopEv> {
            match ev {
                StopEv::Stop => {
                    self.r
                        .write(|tx| stop_job(tx, "j", "never_approved", 2.0).is_ok());
                }
                StopEv::ApproveRead => self.r.approve_saw = self.r.status() == "proposed",
                StopEv::ApproveWrite if self.r.approve_saw => {
                    self.r.approved = self
                        .r
                        .write(|tx| approve_proposal(tx, "j", &json!({}), 3.0).unwrap());
                }
                _ => {}
            }
            Vec::new()
        }
    }

    /// A (every order): the user's stop of a proposal while the user approves it elsewhere (the card and the
    /// proposal buffer at once).  An approval that lands first runs and the stop then stops it, as any stop does, but
    /// it is never marked "never approved": `job/resume` can still pick its work up.
    #[test]
    fn every_order_a_stop_never_marks_an_approved_job() {
        let mut p = skuld::Partial::new();
        p.source("buffer", vec![StopEv::Stop]);
        p.source("card", vec![StopEv::ApproveRead, StopEv::ApproveWrite]);
        let r = skuld::every_order(
            &p,
            skuld::Bound::default(),
            || Stops::at("proposed"),
            |s, order| {
                if s.r.approved && s.never_approved() {
                    return Err(format!(
                        "an approved job marked never approved in {order:?}"
                    ));
                }
                if s.r.status() != "stopped" {
                    return Err(format!("a stopped job is {} in {order:?}", s.r.status()));
                }
                Ok(())
            },
        );
        assert!(r.orders > 1, "{r:?}");
    }

    /// A (every order): a budget limit pauses a running job while the user stops it.  A stopped job stays stopped.
    #[test]
    fn every_order_a_pause_never_undoes_a_stop() {
        let mut p = skuld::Partial::new();
        p.source("user", vec![PauseEv::Stop]);
        p.source("budget", vec![PauseEv::Pause]);
        let r = skuld::every_order(
            &p,
            skuld::Bound::default(),
            || Pauses(Stops::at("running")),
            |s, order| match s.0.r.status().as_str() {
                "stopped" => Ok(()),
                other => Err(format!("a stopped job is {other} in {order:?}")),
            },
        );
        assert!(r.orders > 1, "{r:?}");
    }

    /// D: a resume decides in its write: a running job, or a withdrawn proposal, is refused; a stopped job keeps the
    /// data it has now and takes the new budget.
    #[test]
    fn a_resume_reads_the_job_in_its_write() {
        let mut s = Stops::at("running");
        let resumed = |s: &mut Stops, budget| {
            let mut tx = tx_of(&mut s.r.c);
            let got = resume_job(&mut tx, "j", "never_approved", budget, 5.0).unwrap();
            tx.commit_for_test().unwrap();
            got
        };
        assert!(resumed(&mut s, None).unwrap_err().contains("is running"));
        s.r.write(|tx| {
            job_set(
                tx,
                "j",
                Some("stopped"),
                Some(&json!({"note": "kept"})),
                6.0,
            )
            .is_ok()
        });
        assert_eq!(resumed(&mut s, Some(7.0)), Ok(()));
        let data: String =
            s.r.c
                .query_row("select data from job where id = 'j'", [], |r| r.get(0))
                .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&data).unwrap(),
            json!({"note": "kept", "budget": 7.0})
        );
        let mut p = Stops::at("proposed");
        p.r.write(|tx| stop_job(tx, "j", "never_approved", 7.0).unwrap());
        assert!(
            resumed(&mut p, None)
                .unwrap_err()
                .contains("never approved")
        );
    }
}
