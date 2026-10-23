//! The tracker's tests (Task 13): a schema-7 database in memory, two projects (`alpha`, `beta`), ops run in their
//! own committed tx as the tools will run them.

use std::collections::HashMap;

use proptest::prelude::*;
use serde_json::json;
use urdr::Connection;
use urdr::graph::entity::{self, Changes, Ent, EntityNew, Lease, Origin};
use urdr::graph::{Class, Tx, TxMeta, WriteError};

use super::*;
use crate::grants::{self, Access, What, Who};
use crate::scope::Caller;
use crate::scope::testkit::{guard, project};
use crate::store::tests::db7;

pub(crate) struct Fx {
    pub(crate) c: Connection,
    pub(crate) a: i64,
    pub(crate) b: i64,
}

impl Fx {
    pub(crate) fn new() -> Fx {
        let mut c = db7();
        let a = project(&mut c, "alpha");
        let b = project(&mut c, "beta");
        Fx { c, a, b }
    }

    /// An agent session SID in project alpha.
    pub(crate) fn agent(&self, sid: &str) -> Caller {
        self.agent_in(sid, Some(self.a))
    }

    pub(crate) fn agent_in(&self, sid: &str, project: Option<i64>) -> Caller {
        Caller {
            class: Class::Agent,
            actor: format!("agent:{sid}"),
            session: Some(sid.into()),
            profile: None,
            job: None,
            project,
            backend: false,
        }
    }

    /// The user, writing into PROJECT (as `tasks/write` will).
    pub(crate) fn user(&self, project: i64) -> Caller {
        Caller {
            project: Some(project),
            ..Caller::user(false)
        }
    }

    /// OP by CALLER in a tx of its own, committed unless it failed.
    pub(crate) fn run(&mut self, caller: &Caller, op: TaskOp) -> Result<TaskAnswer, WriteError> {
        let mut tx = Tx::for_test(
            &mut self.c,
            caller.tx_meta(format!("mcp:task_write/{}", op.name())),
            guard(),
        );
        let r = super::op(&mut tx, caller, op);
        if r.is_ok() {
            tx.commit_for_test().unwrap();
        }
        r
    }

    /// F in a committed tx of META.
    fn write<R>(
        &mut self,
        meta: TxMeta,
        f: impl FnOnce(&mut Tx<'_>) -> Result<R, WriteError>,
    ) -> R {
        let mut tx = Tx::for_test(&mut self.c, meta, guard());
        let r = f(&mut tx).unwrap();
        tx.commit_for_test().unwrap();
        r
    }

    /// A task TITLE made by CALLER: its id.
    pub(crate) fn task(&mut self, caller: &Caller, title: &str) -> String {
        match ok(self.run(caller, create(title))) {
            TaskAnswer::Done { id, .. } => id,
            _ => unreachable!(),
        }
    }

    /// CALLER claims ID: the lease's epoch.
    pub(crate) fn claim(&mut self, caller: &Caller, id: &str) -> i64 {
        match ok(self.run(caller, TaskOp::Claim { id: id.into() })) {
            TaskAnswer::Done { lease: Some(l), .. } => l,
            other => panic!("{other:?}"),
        }
    }

    pub(crate) fn link(&mut self, caller: &Caller, src: &str, kind: &str, dst: &str) {
        ok(self.run(
            caller,
            TaskOp::Link {
                src: src.into(),
                kind: kind.into(),
                dst: dst.into(),
            },
        ));
    }

    pub(crate) fn ent(&self, id: &str) -> Ent {
        entity::by_id(&self.c, id).unwrap().unwrap()
    }

    pub(crate) fn ver(&self, id: &str) -> i64 {
        self.ent(id).ver
    }

    pub(crate) fn n(&self, id: &str) -> i64 {
        self.ent(id).n
    }

    /// ID's lease runs out (the hub's clock moved on).
    fn expire(&mut self, id: &str) {
        let e = self.ent(id);
        self.write(TxMeta::new("hub", Class::System, "test"), |tx| {
            entity::update(
                tx,
                e.n,
                None,
                Changes {
                    lease: Some(Lease {
                        until: Some(1.0),
                        ..e.lease.clone()
                    }),
                    ..Changes::default()
                },
            )
        });
    }

    fn count(&self, sql: &str) -> i64 {
        self.c.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    fn update(
        &mut self,
        caller: &Caller,
        id: &str,
        f: impl FnOnce(&mut ops::Fields),
    ) -> Result<TaskAnswer, WriteError> {
        let mut fields = ops::Fields::default();
        f(&mut fields);
        let ver = self.ver(id);
        self.run(
            caller,
            TaskOp::Update {
                id: id.into(),
                ver,
                title: fields.title,
                body: fields.body,
                priority: fields.priority,
                acceptance: fields.acceptance,
                status: fields.status,
            },
        )
    }

    /// A grant to SID to edit the user's task ID.
    fn edit_grant(&mut self, sid: &str, id: &str) {
        let n = self.n(id);
        self.write(TxMeta::new("user", Class::User, "test"), |tx| {
            grants::create(
                tx,
                Who::Session(sid.into()),
                What::Task(n),
                Access::EditUserTasks,
                None,
            )
        });
    }

    fn only_user_closes(&mut self, on: bool) {
        self.write(TxMeta::new("user", Class::User, "test"), |tx| {
            crate::write::meta::put_text(tx, ONLY_USER_CLOSES, if on { "1" } else { "0" })
                .map_err(|e| WriteError::Sql(e.to_string()))
        });
    }
}

pub(crate) fn create(title: &str) -> TaskOp {
    TaskOp::Create {
        title: title.into(),
        body: None,
        priority: None,
        labels: vec![],
        acceptance: None,
        parent: None,
    }
}

/// A `Done` answer, else a panic naming what came.
pub(crate) fn ok(r: Result<TaskAnswer, WriteError>) -> TaskAnswer {
    match r {
        Ok(a @ TaskAnswer::Done { .. }) => a,
        other => panic!("not done: {other:?}"),
    }
}

/// The refusal's text, else a panic.
fn no(r: Result<TaskAnswer, WriteError>) -> String {
    match r {
        Err(WriteError::Refused(t)) => t,
        other => panic!("not refused: {other:?}"),
    }
}

fn lost(r: Result<TaskAnswer, WriteError>) -> (Option<String>, LostHow, Option<String>) {
    match r {
        Ok(TaskAnswer::LeaseLost {
            by,
            how,
            note,
            next,
            ..
        }) => {
            assert_eq!(next, "stop work on this task; read your notices");
            (by, how, note)
        }
        other => panic!("not lease_lost: {other:?}"),
    }
}

#[test]
fn create_in_own_project_only() {
    let mut fx = Fx::new();
    let a = fx.agent("s1");
    let got = ok(fx.run(
        &a,
        TaskOp::Create {
            title: "Parse\nthe file".into(),
            body: Some("all of it".into()),
            priority: Some(1),
            labels: vec!["parser".into(), "parser".into(), " ".into()],
            acceptance: Some("tests pass".into()),
            parent: None,
        },
    ));
    let TaskAnswer::Done {
        id,
        title,
        ver,
        lease,
        ..
    } = got
    else {
        unreachable!()
    };
    assert_eq!((title.as_str(), ver, lease), ("Parse the file", 1, None));
    let suffix = id
        .strip_prefix("task:al-")
        .expect("the alias's two letters");
    assert_eq!(suffix.len(), 5);
    assert!(
        suffix
            .bytes()
            .all(|b| b.is_ascii_digit() || b.is_ascii_lowercase())
    );
    let e = fx.ent(&id);
    assert_eq!(e.project, Some(fx.a));
    assert_eq!(e.status.as_deref(), Some("open"));
    assert_eq!(e.origin, Origin::Recorded);
    assert_eq!(
        e.data,
        json!({"labels": ["parser"], "acceptance": "tests pass"})
    );
    // A caller without a project writes nothing.
    let homeless = fx.agent_in("s2", None);
    assert!(no(fx.run(&homeless, create("x"))).contains("no project"));
    // A parent in another project is no parent of a task here.
    let b_task = fx.task(&fx.user(fx.b), "theirs");
    let mut op = create("child");
    if let TaskOp::Create { parent, .. } = &mut op {
        *parent = Some(b_task.clone());
    }
    assert_eq!(no(fx.run(&a, op)), format!("no such task: {b_task}"));
    // A parent here: the child is its part.
    let mut op = create("child");
    if let TaskOp::Create { parent, .. } = &mut op {
        *parent = Some(id.clone());
    }
    let TaskAnswer::Done { id: child, .. } = ok(fx.run(&a, op)) else {
        unreachable!()
    };
    let links = fx.count(&format!(
        "select count(*) from link where kind = 'parent_of' and src = {} and dst = {}",
        fx.n(&id),
        fx.n(&child)
    ));
    assert_eq!(links, 1);
}

#[test]
fn out_of_scope_is_no_such_task() {
    let mut fx = Fx::new();
    let a = fx.agent("s1");
    let theirs = fx.task(&fx.user(fx.b), "beta's");
    let ver = fx.ver(&theirs);
    for op in [
        TaskOp::Claim { id: theirs.clone() },
        TaskOp::Label {
            id: theirs.clone(),
            add: vec!["x".into()],
            remove: vec![],
        },
        TaskOp::Update {
            id: theirs.clone(),
            ver,
            title: Some("mine now".into()),
            body: None,
            priority: None,
            acceptance: None,
            status: None,
        },
    ] {
        assert_eq!(no(fx.run(&a, op)), format!("no such task: {theirs}"));
    }
    // An id that does not exist reads the same.
    assert_eq!(
        no(fx.run(
            &a,
            TaskOp::Claim {
                id: "task:be-zzzzz".into()
            }
        )),
        "no such task: task:be-zzzzz"
    );
    // Under a read grant the task is seen, and still not written.
    let (pa, pb) = (fx.a, fx.b);
    fx.write(TxMeta::new("user", Class::User, "test"), |tx| {
        grants::create(tx, Who::Project(pa), What::Project(pb), Access::Read, None)
    });
    let t = no(fx.run(&a, TaskOp::Claim { id: theirs.clone() }));
    assert!(t.contains("another project"), "{t}");
    assert_eq!(fx.ent(&theirs).ver, ver);
}

#[test]
fn parsed_and_board_are_refused() {
    let mut fx = Fx::new();
    let a = fx.agent("s1");
    let pa = fx.a;
    let scan = TxMeta::new("scan:/w/alpha", Class::System, "scan");
    let parsed = |id: &str, kind: &str, project: Option<i64>, path: &str| EntityNew {
        id: id.into(),
        kind: kind.into(),
        project,
        title: Some("parsed".into()),
        status: Some("open".into()),
        body: None,
        priority: None,
        assignee: None,
        data: json!({ "path": path }),
        origin: Origin::Parsed,
        source: Some(path.into()),
    };
    fx.write(scan.clone(), |tx| {
        entity::create(
            tx,
            parsed(
                "task:/w/alpha/docs/plan.md#3",
                "task",
                Some(pa),
                "/w/alpha/docs/plan.md",
            ),
        )
    });
    fx.write(scan, |tx| {
        entity::create(
            tx,
            parsed("todo:/h/org/board.org#2", "todo", None, "/h/org/board.org"),
        )
    });
    let t = no(fx.run(
        &a,
        TaskOp::Claim {
            id: "task:/w/alpha/docs/plan.md#3".into(),
        },
    ));
    assert_eq!(
        t,
        "this comes from /w/alpha/docs/plan.md; add a note or a task that relates to it"
    );
    let t = no(fx.run(
        &a,
        TaskOp::Label {
            id: "todo:/h/org/board.org#2".into(),
            add: vec!["x".into()],
            remove: vec![],
        },
    ));
    assert!(t.starts_with("this comes from"), "{t}");
    // The user too: the next scan would overwrite the change.
    let t = no(fx.run(
        &fx.user(pa),
        TaskOp::Label {
            id: "todo:/h/org/board.org#2".into(),
            add: vec!["x".into()],
            remove: vec![],
        },
    ));
    assert!(t.starts_with("this comes from /h/org/board.org"), "{t}");
    // A task that relates to it is fine.
    let mine = fx.task(&a, "do the plan's step 3");
    fx.link(&a, &mine, "relates", "task:/w/alpha/docs/plan.md#3");
    // A ready-link onto it is not.
    let t = no(fx.run(
        &a,
        TaskOp::Link {
            src: mine.clone(),
            kind: "blocks".into(),
            dst: "task:/w/alpha/docs/plan.md#3".into(),
        },
    ));
    assert!(t.starts_with("this comes from"), "{t}");
}

#[test]
fn job_tasks_are_refused() {
    let mut fx = Fx::new();
    let a = fx.agent("s1");
    let job = crate::write::jobs::NewJob {
        id: "j".into(),
        title: "J".into(),
        plan: None,
        repo: None,
        tasks: vec![crate::write::jobs::NewTask {
            n: 1,
            title: "t1".into(),
            role: None,
            deps: vec![],
        }],
        data: None,
    };
    fx.write(TxMeta::new("hub", Class::System, "test"), |tx| {
        crate::write::jobs::job_create(tx, job, 1.0).map_err(|e| WriteError::Sql(e.to_string()))
    });
    let want = "this task belongs to job j; use claim_task, update_task or complete_task";
    assert_eq!(
        no(fx.run(
            &a,
            TaskOp::Claim {
                id: "task:j#1".into()
            }
        )),
        want
    );
    assert_eq!(
        no(fx.run(
            &fx.user(fx.a),
            TaskOp::Label {
                id: "task:j#1".into(),
                add: vec!["x".into()],
                remove: vec![],
            }
        )),
        want
    );
    let mine = fx.task(&a, "mine");
    assert_eq!(
        no(fx.run(
            &a,
            TaskOp::Link {
                src: mine,
                kind: "blocks".into(),
                dst: "task:j#1".into(),
            }
        )),
        want
    );
}

#[test]
fn a_stale_ver_is_a_conflict_with_changed_since() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t = fx.task(&a, "first");
    let tx_b = {
        ok(fx.update(&b, &t, |f| f.title = Some("second".into())));
        fx.ent(&t).field_tx["title"]
    };
    // a still has version 1.
    let got = fx.run(
        &a,
        TaskOp::Update {
            id: t.clone(),
            ver: 1,
            title: None,
            body: Some("a's body".into()),
            priority: None,
            acceptance: None,
            status: None,
        },
    );
    let shown = format!("{got:?}");
    let Ok(TaskAnswer::Conflict {
        id,
        ver,
        changed_since,
        next,
    }) = got
    else {
        panic!("{shown}")
    };
    assert_eq!((id.as_str(), ver), (t.as_str(), 2));
    assert_eq!(changed_since.len(), 1);
    let c = &changed_since[0];
    assert_eq!(
        (c.field.as_str(), &c.to, c.by.as_str(), c.class, c.tx),
        ("title", &json!("second"), "agent:b", Class::Agent, tx_b)
    );
    assert_eq!(next, "re-read with task_read get, then retry with ver 2");
    // Nothing written, no event.
    let e = fx.ent(&t);
    assert_eq!((e.ver, e.body), (2, None));
    assert_eq!(
        fx.count("select count(*) from event where summary like 'update%'"),
        1
    );
}

#[test]
fn label_and_link_need_no_ver() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t = fx.task(&a, "one");
    let u = fx.task(&a, "two");
    ok(fx.update(&b, &t, |f| f.priority = Some(3)));
    // a never read version 2, and labels and links need none.
    for (who, add) in [(&a, "x"), (&b, "y"), (&a, "x")] {
        ok(fx.run(
            who,
            TaskOp::Label {
                id: t.clone(),
                add: vec![add.into()],
                remove: vec![],
            },
        ));
    }
    assert_eq!(labels_of(&fx.ent(&t)), ["x", "y"]);
    ok(fx.run(
        &a,
        TaskOp::Label {
            id: t.clone(),
            add: vec![],
            remove: vec!["x".into(), "absent".into()],
        },
    ));
    assert_eq!(labels_of(&fx.ent(&t)), ["y"]);
    fx.link(&a, &t, "relates", &u);
    fx.link(&b, &t, "relates", &u);
    assert_eq!(
        fx.count(
            "select count(*) from link where kind = 'relates' and tx_to = 4611686018427387904"
        ),
        1
    );
    ok(fx.run(
        &b,
        TaskOp::Unlink {
            src: t.clone(),
            kind: "relates".into(),
            dst: u.clone(),
        },
    ));
    assert_eq!(
        fx.count(
            "select count(*) from link where kind = 'relates' and tx_to = 4611686018427387904"
        ),
        0
    );
}

#[tokio::test]
async fn concurrent_label_adds_lose_none() {
    use crate::project::{self, ProjectRef};
    use crate::store::{CoordDb, CoordError};
    let dir = tempfile::tempdir().unwrap();
    let db = CoordDb::spawn(dir.path().join("work.db"));
    let root = ProjectRef {
        id: "project:0123456789ab".into(),
        root: dir.path().join("alpha"),
        slug: "alpha".into(),
        root_commit: Some("0123456789ab0123456789ab0123456789ab0123".into()),
        roots: vec!["0123456789ab0123456789ab0123456789ab0123".into()],
    };
    let p = db
        .write(TxMeta::new("hub", Class::System, "test"), move |tx| {
            Ok(project::register(tx, &root)?)
        })
        .await
        .unwrap();
    let agent = |sid: &str| Caller {
        class: Class::Agent,
        actor: format!("agent:{sid}"),
        session: Some(sid.into()),
        profile: None,
        job: None,
        project: Some(p),
        backend: false,
    };
    let maker = agent("s0");
    let id = match db
        .write(maker.tx_meta("mcp:task_write/create"), move |tx| {
            Ok(op(tx, &maker, create("shared"))?)
        })
        .await
        .unwrap()
    {
        TaskAnswer::Done { id, .. } => id,
        other => panic!("{other:?}"),
    };
    let mut runs = Vec::new();
    for i in 0..24 {
        let db = db.clone();
        let id = id.clone();
        let who = agent(&format!("s{}", i % 3));
        runs.push(tokio::spawn(async move {
            db.write(who.tx_meta("mcp:task_write/label"), move |tx| {
                op(
                    tx,
                    &who,
                    TaskOp::Label {
                        id,
                        add: vec![format!("l{i}")],
                        remove: vec![],
                    },
                )
                .map_err(CoordError::from)
            })
            .await
        }));
    }
    for r in runs {
        assert!(matches!(r.await.unwrap(), Ok(TaskAnswer::Done { .. })));
    }
    let (labels, ver) = db
        .read(move |c| {
            let e = entity::by_id(c, &id)?.unwrap();
            Ok((labels_of(&e), e.ver))
        })
        .await
        .unwrap();
    let mut want: Vec<String> = (0..24).map(|i| format!("l{i}")).collect();
    let mut got = labels.clone();
    want.sort();
    got.sort();
    assert_eq!(got, want);
    assert_eq!(ver, 25);
}

#[test]
fn claim_needs_ready() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let first = fx.task(&a, "first");
    let second = fx.task(&a, "second");
    fx.link(&a, &first, "blocks", &second);
    let t = no(fx.run(&b, TaskOp::Claim { id: second.clone() }));
    assert_eq!(
        t,
        format!("{second} is not ready: blocked by {first} (they finish first)")
    );
    let lease = fx.claim(&a, &first);
    assert_eq!(lease, 1);
    // Claimed and live: not b's to claim, and not a's again.
    let t = no(fx.run(&b, TaskOp::Claim { id: first.clone() }));
    assert!(t.contains("is claimed by agent:a"), "{t}");
    let t = no(fx.run(&a, TaskOp::Claim { id: first.clone() }));
    assert!(t.starts_with("you hold"), "{t}");
    ok(fx.run(
        &a,
        TaskOp::Complete {
            id: first.clone(),
            lease,
            note: None,
        },
    ));
    // in-review still blocks; done does not.
    assert!(no(fx.run(&b, TaskOp::Claim { id: second.clone() })).contains("blocked by"));
    ok(fx.update(&a, &first, |f| f.status = Some("done".into())));
    assert_eq!(fx.claim(&b, &second), 1);
    let e = fx.ent(&second);
    assert_eq!(
        (
            e.status.as_deref(),
            e.assignee.as_deref(),
            e.lease.holder.as_deref()
        ),
        (Some("claimed"), Some("agent:b"), Some("agent:b"))
    );
    // The claim links b's session to the task.
    assert_eq!(
        fx.count(&format!(
            "select count(*) from link l join entity s on s.n = l.src \
             where s.id = 'session:b' and l.kind = 'works_on' and l.dst = {}",
            e.n
        )),
        1
    );
    // A parent waits for its parts.
    let parent = fx.task(&a, "parent");
    let mut op = create("part");
    if let TaskOp::Create { parent: p, .. } = &mut op {
        *p = Some(parent.clone());
    }
    ok(fx.run(&a, op));
    assert!(no(fx.run(&b, TaskOp::Claim { id: parent })).contains("waits for its parts"));
}

#[test]
fn claim_after_expiry() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t = fx.task(&a, "one");
    assert_eq!(fx.claim(&a, &t), 1);
    fx.expire(&t);
    assert_eq!(fx.claim(&b, &t), 2);
    let (by, how, note) = lost(fx.run(
        &a,
        TaskOp::Heartbeat {
            id: t.clone(),
            lease: 1,
        },
    ));
    assert_eq!(
        (by.as_deref(), how, note),
        (Some("agent:b"), LostHow::Reclaimed, None)
    );
    // b holds it.
    ok(fx.run(
        &b,
        TaskOp::Heartbeat {
            id: t.clone(),
            lease: 2,
        },
    ));
    // An expired lease that nobody took over: still its holder's to lose.
    fx.expire(&t);
    let (by, how, _) = lost(fx.run(
        &b,
        TaskOp::Heartbeat {
            id: t.clone(),
            lease: 2,
        },
    ));
    assert_eq!((by, how), (None, LostHow::Expired));
}

#[test]
fn a_lost_lease_is_refused_on_every_holder_op() {
    let mut fx = Fx::new();
    let (a, b, c) = (fx.agent("a"), fx.agent("b"), fx.agent("c"));
    let holder_ops = |id: &str, lease: i64| {
        vec![
            TaskOp::Heartbeat {
                id: id.into(),
                lease,
            },
            TaskOp::Release {
                id: id.into(),
                lease,
                note: None,
            },
            TaskOp::Handoff {
                id: id.into(),
                lease,
                to: None,
                note: "done half".into(),
            },
            TaskOp::Complete {
                id: id.into(),
                lease,
                note: None,
            },
        ]
    };
    // Reassigned away.
    let t = fx.task(&a, "one");
    let lease = fx.claim(&a, &t);
    let ver = fx.ver(&t);
    ok(fx.run(
        &b,
        TaskOp::Reassign {
            id: t.clone(),
            ver,
            to: Some("agent:c".into()),
            note: "a is stuck; c takes it".into(),
        },
    ));
    let before = fx.ent(&t);
    for op in holder_ops(&t, lease) {
        let (by, how, note) = lost(fx.run(&a, op));
        assert_eq!(
            (by.as_deref(), how, note.as_deref()),
            (
                Some("agent:b"),
                LostHow::Reassign,
                Some("a is stuck; c takes it")
            )
        );
    }
    assert_eq!(fx.ent(&t), before, "nothing written");
    // Never held: the same answer for an agent that only guesses the epoch.
    for op in holder_ops(&t, before.lease.epoch) {
        assert!(matches!(fx.run(&c, op), Ok(TaskAnswer::LeaseLost { .. })));
    }
    // The holder with the wrong epoch while its lease is live (a session that reconnected after a claim of its own).
    let u = fx.task(&a, "two");
    let old = fx.claim(&a, &u);
    fx.expire(&u);
    let new = fx.claim(&a, &u);
    assert_eq!((old, new), (1, 2));
    for op in holder_ops(&u, old) {
        assert!(matches!(fx.run(&a, op), Ok(TaskAnswer::LeaseLost { .. })));
    }
    // A run-out lease.
    fx.expire(&u);
    for op in holder_ops(&u, new) {
        let (_, how, _) = lost(fx.run(&a, op));
        assert_eq!(how, LostHow::Expired);
    }
    // No status change while another holds it live.
    let w = fx.task(&a, "three");
    fx.claim(&a, &w);
    let t = no(fx.update(&b, &w, |f| f.status = Some("blocked".into())));
    assert!(t.contains("only the holder changes its status"), "{t}");
}

#[test]
fn reassign_bumps_the_epoch() {
    let mut fx = Fx::new();
    let (a, b, c) = (fx.agent("a"), fx.agent("b"), fx.agent("c"));
    let t = fx.task(&a, "one");
    assert_eq!(fx.claim(&a, &t), 1);
    let ver = fx.ver(&t);
    let t2 = no(fx.run(
        &b,
        TaskOp::Reassign {
            id: t.clone(),
            ver,
            to: Some("agent:c".into()),
            note: " ".into(),
        },
    ));
    assert!(t2.contains("needs a note"), "{t2}");
    ok(fx.run(
        &b,
        TaskOp::Reassign {
            id: t.clone(),
            ver,
            to: Some("agent:c".into()),
            note: "c knows the lexer".into(),
        },
    ));
    let e = fx.ent(&t);
    assert_eq!(
        e.lease,
        Lease {
            holder: None,
            epoch: 2,
            until: None
        }
    );
    assert_eq!(
        (e.status.as_deref(), e.assignee.as_deref()),
        (Some("open"), Some("agent:c"))
    );
    // The note is a note entity about the task.
    assert_eq!(
        fx.count(&format!(
            "select count(*) from entity n join link l on l.src = n.n \
             where n.kind = 'note' and n.body = 'c knows the lexer' and l.kind = 'about' and l.dst = {}",
            e.n
        )),
        1
    );
    // c claims: the next epoch.
    assert_eq!(fx.claim(&c, &t), 3);
    // A stale ver is a conflict, nothing reassigned.
    let r = fx.run(
        &b,
        TaskOp::Reassign {
            id: t.clone(),
            ver,
            to: None,
            note: "again".into(),
        },
    );
    assert!(matches!(r, Ok(TaskAnswer::Conflict { .. })), "{r:?}");
    assert_eq!(fx.ent(&t).lease.epoch, 3);
}

#[test]
fn a_reconnecting_holder_with_an_old_epoch_is_refused() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let t = fx.task(&a, "one");
    let first = fx.claim(&a, &t);
    fx.expire(&t);
    // The same session claims again after its lease ran out (it reconnected): the old epoch is dead.
    let second = fx.claim(&a, &t);
    assert!(second > first);
    assert!(matches!(
        fx.run(
            &a,
            TaskOp::Heartbeat {
                id: t.clone(),
                lease: first
            }
        ),
        Ok(TaskAnswer::LeaseLost { .. })
    ));
    assert!(matches!(
        fx.run(
            &a,
            TaskOp::Complete {
                id: t.clone(),
                lease: first,
                note: None
            }
        ),
        Ok(TaskAnswer::LeaseLost { .. })
    ));
    assert_eq!(fx.ent(&t).status.as_deref(), Some("claimed"));
    ok(fx.run(
        &a,
        TaskOp::Heartbeat {
            id: t.clone(),
            lease: second,
        },
    ));
}

#[test]
fn user_made_text_needs_the_grant() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t = fx.task(&fx.user(fx.a), "the user's");
    let other = fx.task(&a, "an agent's");
    for f in [
        ops::Fields {
            title: Some("renamed".into()),
            ..Default::default()
        },
        ops::Fields {
            body: Some("rewritten".into()),
            ..Default::default()
        },
        ops::Fields {
            acceptance: Some("less".into()),
            ..Default::default()
        },
    ] {
        let t2 = no(fx.update(&a, &t, |x| *x = f));
        assert!(t2.contains("only with the user's permission"), "{t2}");
    }
    // Notes, links, labels and priority are always fine.
    fx.link(&a, &other, "relates", &t);
    ok(fx.run(
        &a,
        TaskOp::Label {
            id: t.clone(),
            add: vec!["x".into()],
            remove: vec![],
        },
    ));
    ok(fx.update(&a, &t, |f| f.priority = Some(1)));
    // With the grant (this session only).
    fx.edit_grant("a", &t);
    ok(fx.update(&a, &t, |f| f.title = Some("renamed".into())));
    assert_eq!(fx.ent(&t).title.as_deref(), Some("renamed"));
    assert!(no(fx.update(&b, &t, |f| f.body = Some("b's".into()))).contains("permission"));
    // An agent's task is anyone's in the project.
    ok(fx.update(&b, &other, |f| f.title = Some("b renamed it".into())));
}

#[test]
fn split_children_and_replace() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t = fx.task(&a, "big");
    ok(fx.run(
        &a,
        TaskOp::Label {
            id: t.clone(),
            add: vec!["core".into()],
            remove: vec![],
        },
    ));
    ok(fx.update(&a, &t, |f| f.priority = Some(2)));
    let ver = fx.ver(&t);
    let TaskAnswer::Done { parts, ver: v2, .. } = ok(fx.run(
        &b,
        TaskOp::Split {
            id: t.clone(),
            ver,
            parts: vec!["half one".into(), "half two".into()],
            mode: None,
        },
    )) else {
        unreachable!()
    };
    assert_eq!(v2, ver, "children leave the original as it was");
    assert_eq!(parts.len(), 2);
    let n = fx.n(&t);
    for p in &parts {
        let e = fx.ent(p);
        assert_eq!((e.project, e.priority), (Some(fx.a), Some(2)));
        assert_eq!(labels_of(&e), ["core"]);
        for (kind, src, dst) in [("split_from", e.n, n), ("parent_of", n, e.n)] {
            assert_eq!(
                fx.count(&format!(
                    "select count(*) from link where kind = '{kind}' and src = {src} and dst = {dst}"
                )),
                1,
                "{kind}"
            );
        }
    }
    // The original waits for its parts.
    assert!(!is_ready(&fx.c, n, now_secs()).unwrap());
    // Replace: the original dropped, duplicates to the parts.
    let u = fx.task(&a, "wrong shape");
    let ver = fx.ver(&u);
    let TaskAnswer::Done { parts, .. } = ok(fx.run(
        &a,
        TaskOp::Split {
            id: u.clone(),
            ver,
            parts: vec!["right shape".into()],
            mode: Some("replace".into()),
        },
    )) else {
        unreachable!()
    };
    assert_eq!(fx.ent(&u).status.as_deref(), Some("dropped"));
    let (un, pn) = (fx.n(&u), fx.n(&parts[0]));
    assert_eq!(
        fx.count(&format!(
            "select count(*) from link where kind = 'duplicates' and src = {un} and dst = {pn}"
        )),
        1
    );
    assert!(
        no(fx.run(
            &a,
            TaskOp::Split {
                id: t.clone(),
                ver: fx.ver(&t),
                parts: vec!["x".into()],
                mode: Some("halves".into()),
            }
        ))
        .contains("not a split mode")
    );
}

#[test]
fn a_blocks_cycle_is_refused_with_its_path() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let t1 = fx.task(&a, "one");
    let t2 = fx.task(&a, "two");
    let t3 = fx.task(&a, "three");
    fx.link(&a, &t1, "blocks", &t2);
    fx.link(&a, &t2, "blocks", &t3);
    let t = no(fx.run(
        &a,
        TaskOp::Link {
            src: t3.clone(),
            kind: "blocks".into(),
            dst: t1.clone(),
        },
    ));
    assert_eq!(
        t,
        format!("this would make a blocks cycle: {t3} → {t1} → {t2} → {t3}")
    );
    assert!(
        no(fx.run(
            &a,
            TaskOp::Link {
                src: t1.clone(),
                kind: "blocks".into(),
                dst: t1.clone(),
            }
        ))
        .contains("itself")
    );
    // Unlinked, the same link is fine.
    ok(fx.run(
        &a,
        TaskOp::Unlink {
            src: t2.clone(),
            kind: "blocks".into(),
            dst: t3.clone(),
        },
    ));
    fx.link(&a, &t3, "blocks", &t1);
}

#[test]
fn a_ready_link_into_another_project_is_refused() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let mine = fx.task(&a, "mine");
    let theirs = fx.task(&fx.user(fx.b), "theirs");
    // Unseen: no such entity.
    assert_eq!(
        no(fx.run(
            &a,
            TaskOp::Link {
                src: mine.clone(),
                kind: "relates".into(),
                dst: theirs.clone(),
            }
        )),
        format!("no such entity: {theirs}")
    );
    let (pa, pb) = (fx.a, fx.b);
    fx.write(TxMeta::new("user", Class::User, "test"), |tx| {
        grants::create(tx, Who::Project(pa), What::Project(pb), Access::Read, None)
    });
    for kind in ["blocks", "parent_of"] {
        let t = no(fx.run(
            &a,
            TaskOp::Link {
                src: mine.clone(),
                kind: kind.into(),
                dst: theirs.clone(),
            },
        ));
        assert!(t.contains("not grantable"), "{kind}: {t}");
    }
    // An association may point there under the grant; the source must be a's own.
    fx.link(&a, &mine, "relates", &theirs);
    fx.link(&a, &mine, "duplicates", &theirs);
    assert!(
        no(fx.run(
            &a,
            TaskOp::Link {
                src: theirs.clone(),
                kind: "relates".into(),
                dst: mine.clone(),
            }
        ))
        .contains("another project")
    );
}

#[test]
fn secrets_are_refused() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let secret = format!("pass{}={}", "word", "hunter2-hunter2");
    assert!(runstav::secrets::looks_like_secret(&secret).is_some());
    let t = no(fx.run(&a, create(&format!("use {secret}"))));
    assert_eq!(
        t,
        "the title looks like a secret (assignment); do not store credentials"
    );
    let t = fx.task(&a, "fine");
    for (field, f) in [
        (
            "body",
            ops::Fields {
                body: Some(secret.clone()),
                ..Default::default()
            },
        ),
        (
            "acceptance",
            ops::Fields {
                acceptance: Some(secret.clone()),
                ..Default::default()
            },
        ),
    ] {
        let got = no(fx.update(&a, &t, |x| *x = f));
        assert!(
            got.starts_with(&format!("the {field} looks like a secret")),
            "{got}"
        );
    }
    let got = no(fx.run(
        &a,
        TaskOp::Label {
            id: t.clone(),
            add: vec![secret.clone()],
            remove: vec![],
        },
    ));
    assert!(got.starts_with("the label looks like a secret"), "{got}");
    let lease = fx.claim(&a, &t);
    let got = no(fx.run(
        &a,
        TaskOp::Release {
            id: t.clone(),
            lease,
            note: Some(secret.clone()),
        },
    ));
    assert!(got.starts_with("the note looks like a secret"), "{got}");
    assert_eq!(
        fx.count("select count(*) from entity where kind = 'note'"),
        0
    );
}

#[test]
fn every_op_is_one_tx_and_one_event() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let user = fx.user(fx.a);
    let t = fx.task(&a, "one");
    let u = fx.task(&a, "two");
    let step = |fx: &mut Fx, who: &Caller, op: TaskOp| {
        let name = op.name();
        let (txs, events) = (
            fx.count("select count(*) from tx"),
            fx.count("select count(*) from event"),
        );
        let got = fx.run(who, op);
        assert!(
            matches!(
                got,
                Ok(TaskAnswer::Done { .. } | TaskAnswer::Proposed { .. })
            ),
            "{name}: {got:?}"
        );
        assert_eq!(fx.count("select count(*) from tx"), txs + 1, "{name}");
        assert_eq!(fx.count("select count(*) from event"), events + 1, "{name}");
        let (kind, summary, by, at): (String, String, i64, String) =
            fx.c.query_row(
                "select e.kind, e.summary, e.tx, t.actor from event e join tx t on t.id = e.tx \
                 order by e.id desc limit 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(kind, "task", "{name}");
        assert!(summary.starts_with(name), "{name}: {summary}");
        assert!(!summary.contains('\n'));
        assert_eq!(by, fx.count("select max(id) from tx"), "{name}");
        assert_eq!(at, who.actor, "{name}");
    };
    step(&mut fx, &a, create("three"));
    let ver = fx.ver(&t);
    step(
        &mut fx,
        &b,
        TaskOp::Update {
            id: t.clone(),
            ver,
            title: Some("one!".into()),
            body: None,
            priority: None,
            acceptance: None,
            status: None,
        },
    );
    step(
        &mut fx,
        &b,
        TaskOp::Label {
            id: t.clone(),
            add: vec!["x".into()],
            remove: vec![],
        },
    );
    step(
        &mut fx,
        &a,
        TaskOp::Link {
            src: t.clone(),
            kind: "relates".into(),
            dst: u.clone(),
        },
    );
    step(
        &mut fx,
        &a,
        TaskOp::Unlink {
            src: t.clone(),
            kind: "relates".into(),
            dst: u.clone(),
        },
    );
    step(&mut fx, &a, TaskOp::Claim { id: t.clone() });
    let lease = fx.ent(&t).lease.epoch;
    step(
        &mut fx,
        &a,
        TaskOp::Heartbeat {
            id: t.clone(),
            lease,
        },
    );
    step(
        &mut fx,
        &a,
        TaskOp::Handoff {
            id: t.clone(),
            lease,
            to: Some("agent:b".into()),
            note: "over to b".into(),
        },
    );
    step(&mut fx, &b, TaskOp::Claim { id: t.clone() });
    let lease = fx.ent(&t).lease.epoch;
    step(
        &mut fx,
        &b,
        TaskOp::Release {
            id: t.clone(),
            lease,
            note: Some("not now".into()),
        },
    );
    let ver = fx.ver(&t);
    step(
        &mut fx,
        &a,
        TaskOp::Reassign {
            id: t.clone(),
            ver,
            to: None,
            note: "anyone".into(),
        },
    );
    let ver = fx.ver(&u);
    step(
        &mut fx,
        &a,
        TaskOp::Split {
            id: u.clone(),
            ver,
            parts: vec!["u1".into(), "u2".into()],
            mode: None,
        },
    );
    step(&mut fx, &a, TaskOp::Claim { id: t.clone() });
    let lease = fx.ent(&t).lease.epoch;
    step(
        &mut fx,
        &a,
        TaskOp::Complete {
            id: t.clone(),
            lease,
            note: None,
        },
    );
    step(
        &mut fx,
        &user,
        TaskOp::Tools {
            id: t.clone(),
            tracker: Some(false),
        },
    );
}

#[test]
fn ready_is_computed() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t1 = fx.task(&a, "one");
    let t2 = fx.task(&a, "two");
    let t3 = fx.task(&a, "three");
    fx.task(&fx.user(fx.b), "beta's");
    fx.link(&a, &t1, "blocks", &t2);
    ok(fx.run(
        &a,
        TaskOp::Label {
            id: t3.clone(),
            add: vec!["ui".into()],
            remove: vec![],
        },
    ));
    let ids = |fx: &Fx, who: &Caller, labels: &[&str]| -> Vec<String> {
        let scope = crate::scope::for_caller(&fx.c, who, now_secs()).unwrap();
        let labels: Vec<String> = labels.iter().map(|l| (*l).to_string()).collect();
        ready(&fx.c, &scope, &labels, 50)
            .unwrap()
            .into_iter()
            .map(|e| e.id)
            .collect()
    };
    assert_eq!(ids(&fx, &a, &[]), [t1.clone(), t3.clone()]);
    assert_eq!(ids(&fx, &a, &["ui"]), std::slice::from_ref(&t3));
    // Claimed: not ready; its lease run out: ready again.
    fx.claim(&b, &t3);
    assert_eq!(ids(&fx, &a, &[]), std::slice::from_ref(&t1));
    fx.expire(&t3);
    assert_eq!(ids(&fx, &a, &[]), [t1.clone(), t3.clone()]);
    // The blocker done: the blocked one is ready.
    ok(fx.update(&a, &t1, |f| f.status = Some("done".into())));
    assert_eq!(ids(&fx, &a, &[]), [t2.clone(), t3.clone()]);
    // Another project's agent sees none of alpha's; the user sees every project's.
    assert_eq!(ids(&fx, &fx.agent_in("z", Some(fx.b)), &[]).len(), 1);
    assert_eq!(ids(&fx, &Caller::user(false), &[]).len(), 3);
    // Nothing stores readiness.
    assert_eq!(
        fx.count("select count(*) from entity where status = 'ready'"),
        0
    );
}

#[test]
fn tools_is_user_only() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let user = fx.user(fx.a);
    let t = fx.task(&a, "one");
    assert_eq!(
        no(fx.run(
            &a,
            TaskOp::Tools {
                id: t.clone(),
                tracker: Some(false),
            }
        )),
        "only the user sets a task's tools"
    );
    ok(fx.run(
        &user,
        TaskOp::Tools {
            id: t.clone(),
            tracker: Some(false),
        },
    ));
    assert_eq!(fx.ent(&t).data["tracker_tools"], json!(false));
    ok(fx.run(
        &user,
        TaskOp::Tools {
            id: t.clone(),
            tracker: None,
        },
    ));
    assert!(fx.ent(&t).data.get("tracker_tools").is_none());
    // A job's task too (the user sets it until job files say so).
    fx.write(TxMeta::new("hub", Class::System, "test"), |tx| {
        crate::write::jobs::job_create(
            tx,
            crate::write::jobs::NewJob {
                id: "j".into(),
                title: "J".into(),
                plan: None,
                repo: None,
                tasks: vec![crate::write::jobs::NewTask {
                    n: 1,
                    title: "t1".into(),
                    role: None,
                    deps: vec![],
                }],
                data: None,
            },
            1.0,
        )
        .map_err(|e| WriteError::Sql(e.to_string()))
    });
    ok(fx.run(
        &user,
        TaskOp::Tools {
            id: "task:j#1".into(),
            tracker: Some(true),
        },
    ));
    assert_eq!(fx.ent("task:j#1").data["tracker_tools"], json!(true));
}

#[test]
fn with_the_grant_done_is_done() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let t = fx.task(&fx.user(fx.a), "the user's");
    let u = fx.task(&fx.user(fx.a), "another of the user's");
    fx.edit_grant("a", &t);
    fx.edit_grant("a", &u);
    let lease = fx.claim(&a, &t);
    ok(fx.run(
        &a,
        TaskOp::Complete {
            id: t.clone(),
            lease,
            note: Some("all green".into()),
        },
    ));
    assert_eq!(fx.ent(&t).status.as_deref(), Some("done"));
    ok(fx.update(&a, &u, |f| f.status = Some("done".into())));
    assert_eq!(fx.ent(&u).status.as_deref(), Some("done"));
    assert_eq!(fx.count("select count(*) from card"), 0);
}

#[test]
fn only_i_close_turns_done_into_a_proposal() {
    let mut fx = Fx::new();
    let (a, b) = (fx.agent("a"), fx.agent("b"));
    let t = fx.task(&fx.user(fx.a), "the user's");
    fx.edit_grant("a", &t);
    fx.edit_grant("b", &t);
    fx.only_user_closes(true);
    let lease = fx.claim(&a, &t);
    let ver = fx.ver(&t);
    let got = fx.run(
        &a,
        TaskOp::Complete {
            id: t.clone(),
            lease,
            note: Some("all green".into()),
        },
    );
    let shown = format!("{got:?}");
    let Ok(TaskAnswer::Proposed { card }) = got else {
        panic!("{shown}")
    };
    // No status changed; a close card about the task, and the user told.
    let e = fx.ent(&t);
    assert_eq!((e.status.as_deref(), e.ver), (Some("claimed"), ver));
    let (kind, entity, job, data, state): (String, i64, Option<String>, String, String) =
        fx.c.query_row(
            "select kind, entity, job, data, state from card where id = ?1",
            [card],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        (kind.as_str(), entity, job, state.as_str()),
        ("close", e.n, None, "open")
    );
    let data: serde_json::Value = serde_json::from_str(&data).unwrap();
    assert_eq!(
        (
            data["task"].as_str(),
            data["ver"].as_i64(),
            data["by"].as_str()
        ),
        (Some(t.as_str()), Some(ver), Some("agent:a"))
    );
    assert!(
        data["note"]
            .as_str()
            .is_some_and(|n| n.starts_with("note:al-"))
    );
    assert_eq!(
        fx.count("select count(*) from message where recipient = 'user' and entity is not null"),
        1
    );
    // a gives it back; b's done merges into the open card.
    ok(fx.run(
        &a,
        TaskOp::Release {
            id: t.clone(),
            lease,
            note: None,
        },
    ));
    let got = fx.update(&b, &t, |f| f.status = Some("done".into()));
    assert!(
        matches!(got, Ok(TaskAnswer::Proposed { card: c }) if c == card),
        "{got:?}"
    );
    assert_eq!(fx.count("select count(*) from card"), 1);
    let by: String =
        fx.c.query_row("select json_extract(data, '$.by') from card", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(by, "agent:b");
    // Off again: done is done.
    fx.only_user_closes(false);
    ok(fx.update(&b, &t, |f| f.status = Some("done".into())));
    assert_eq!(fx.ent(&t).status.as_deref(), Some("done"));
}

#[test]
fn a_proposal_never_unblocks() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let users = fx.task(&fx.user(fx.a), "the user's");
    let dependent = fx.task(&a, "after it");
    fx.link(&a, &users, "blocks", &dependent);
    fx.edit_grant("a", &users);
    fx.only_user_closes(true);
    let got = fx.update(&a, &users, |f| f.status = Some("done".into()));
    assert!(matches!(got, Ok(TaskAnswer::Proposed { .. })), "{got:?}");
    let scope = crate::scope::for_caller(&fx.c, &a, now_secs()).unwrap();
    let ready_ids: Vec<String> = ready(&fx.c, &scope, &[], 50)
        .unwrap()
        .into_iter()
        .map(|e| e.id)
        .collect();
    assert!(!ready_ids.contains(&dependent), "{ready_ids:?}");
    assert!(no(fx.run(&a, TaskOp::Claim { id: dependent })).contains("blocked by"));
}

#[test]
fn without_the_grant_in_review() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let t = fx.task(&fx.user(fx.a), "the user's");
    let lease = fx.claim(&a, &t);
    ok(fx.run(
        &a,
        TaskOp::Complete {
            id: t.clone(),
            lease,
            note: None,
        },
    ));
    assert_eq!(fx.ent(&t).status.as_deref(), Some("in-review"));
    let got = no(fx.update(&a, &t, |f| f.status = Some("done".into())));
    assert!(got.starts_with("the user closes this task"), "{got}");
    assert!(
        no(fx.update(&a, &t, |f| f.status = Some("blocked".into()))).contains("only in-review")
    );
    // The user closes it.
    ok(fx.update(&fx.user(fx.a), &t, |f| f.status = Some("done".into())));
    assert_eq!(fx.ent(&t).status.as_deref(), Some("done"));
}

#[test]
fn dropped_stays_the_users() {
    let mut fx = Fx::new();
    let a = fx.agent("a");
    let t = fx.task(&fx.user(fx.a), "the user's");
    fx.edit_grant("a", &t);
    let got = no(fx.update(&a, &t, |f| f.status = Some("dropped".into())));
    assert!(got.contains("only the user drops it"), "{got}");
    let ver = fx.ver(&t);
    let got = no(fx.run(
        &a,
        TaskOp::Split {
            id: t.clone(),
            ver,
            parts: vec!["x".into()],
            mode: Some("replace".into()),
        },
    ));
    assert!(got.contains("only the user drops it"), "{got}");
    ok(fx.update(&fx.user(fx.a), &t, |f| f.status = Some("dropped".into())));
    assert_eq!(fx.ent(&t).status.as_deref(), Some("dropped"));
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    /// 3 agents and random ops on 5 tasks: at most one live holder per task (by the fence itself), every write a tx
    /// with its author, no label a successful op added missing, and `ver` = 1 + the versions kept.
    #[test]
    fn random_interleavings_keep_the_invariants(
        steps in proptest::collection::vec((0usize..3, 0usize..5, 0u8..8, any::<bool>()), 1..40)
    ) {
        let mut fx = Fx::new();
        let agents: Vec<Caller> = ["p", "q", "r"].iter().map(|s| fx.agent(s)).collect();
        let tasks: Vec<String> = (0..5).map(|i| fx.task(&agents[0], &format!("t{i}"))).collect();
        let mut leases: HashMap<(usize, usize), i64> = HashMap::new();
        let mut added: Vec<(usize, String)> = Vec::new();
        for (i, (ag, tk, kind, stale)) in steps.into_iter().enumerate() {
            let who = agents[ag].clone();
            let id = tasks[tk].clone();
            let ver = fx.ver(&id) - i64::from(stale);
            let lease = leases.get(&(ag, tk)).copied().unwrap_or(0) - i64::from(stale);
            let op = match kind {
                0 => TaskOp::Claim { id },
                1 => TaskOp::Heartbeat { id, lease },
                2 => TaskOp::Release { id, lease, note: None },
                3 => TaskOp::Reassign { id, ver, to: None, note: "r".into() },
                4 => TaskOp::Label { id, add: vec![format!("l{i}")], remove: vec![] },
                5 => TaskOp::Update {
                    id, ver, title: Some(format!("t{i}")), body: None, priority: None, acceptance: None,
                    status: None,
                },
                6 => TaskOp::Complete { id, lease, note: None },
                _ => {
                    if fx.ent(&id).lease.holder.is_some() {
                        fx.expire(&id);
                    }
                    continue;
                }
            };
            let got = fx.run(&who, op);
            if let Ok(TaskAnswer::Done { lease: Some(l), .. }) = &got && kind == 0 {
                leases.insert((ag, tk), *l);
            }
            if kind == 4 && matches!(got, Ok(TaskAnswer::Done { .. })) {
                added.push((tk, format!("l{i}")));
            }
        }
        // The fence lets at most one remembered lease through per task (tried in a tx that is rolled back).
        for (tk, id) in tasks.iter().enumerate() {
            let mut through = 0;
            for (ag, who) in agents.iter().enumerate() {
                let Some(&lease) = leases.get(&(ag, tk)) else { continue };
                let mut tx = Tx::for_test(&mut fx.c, who.tx_meta("test"), guard());
                let r = super::op(&mut tx, who, TaskOp::Heartbeat { id: id.clone(), lease });
                drop(tx);
                if matches!(r, Ok(TaskAnswer::Done { .. })) {
                    through += 1;
                }
            }
            prop_assert!(through <= 1, "{id}: {through} holders");
        }
        // Every write is a tx with its author.
        for sql in [
            "select count(*) from entity e where not exists (select 1 from tx where id = e.updated_tx and actor <> '')",
            "select count(*) from entity_hist h where not exists (select 1 from tx where id = h.tx_to and actor <> '')",
            "select count(*) from link l where not exists (select 1 from tx where id = l.tx_from and actor <> '')",
            "select count(*) from event e where e.tx is null or not exists (select 1 from tx where id = e.tx and actor <> '')",
            "select count(*) from message m where not exists (select 1 from tx where id = m.tx and actor <> '')",
        ] {
            prop_assert_eq!(fx.count(sql), 0, "{}", sql);
        }
        // No label a successful op added is missing.
        for (tk, l) in &added {
            prop_assert!(labels_of(&fx.ent(&tasks[*tk])).contains(l), "{} lost {}", tasks[*tk], l);
        }
        // ver = 1 + the versions kept.
        prop_assert_eq!(
            fx.count("select count(*) from entity e where e.ver <> 1 + (select count(*) from entity_hist h where h.n = e.n)"),
            0
        );
    }
}
