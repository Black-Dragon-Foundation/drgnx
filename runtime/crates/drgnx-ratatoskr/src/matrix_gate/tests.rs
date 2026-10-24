use super::*;
use norn::matrix::Role;
use norn::store::CoordDb;
use norn::write::cards::card_settle;
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::{Class, TxMeta};

fn meta(c: Class) -> TxMeta {
    TxMeta::new("t", c, "test")
}

fn who(r: Role) -> Who {
    Who {
        role: Some(r),
        ..Who::default()
    }
}

fn db() -> (tempfile::TempDir, CoordDb) {
    let dir = tempfile::tempdir().unwrap();
    let db = CoordDb::spawn(dir.path().join("work.db"));
    (dir, db)
}

fn ctx(command: &str) -> ActionCtx {
    ActionCtx {
        facts: serde_json::from_value(json!({"command": command})).unwrap(),
        ..ActionCtx::default()
    }
}

fn ask_commit(preset: &str, verdict: &str) -> Value {
    json!({"preset": preset, "cells": [
        {"action": "commit", "column": {"role": "worker"}, "verdict": verdict}]})
}

#[tokio::test]
async fn ask_makes_one_card_with_facts_only() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&ask_commit("cautious", "ask")).unwrap();
    let (a, b, n, data, title) = db
        .write(meta(Class::System), move |tx| {
            let c = ctx("git commit -m x");
            let a = g.check(tx, &who(Role::Worker), Action::Commit, &c, 1.0)?;
            let b = g.check(tx, &who(Role::Worker), Action::Commit, &c, 2.0)?;
            let n: i64 =
                tx.sql()
                    .query_row("select count(*) from card where kind = 'matrix'", [], |r| {
                        r.get(0)
                    })?;
            let (d, t): (String, String) = tx.sql().query_row(
                "select data, title from card where kind = 'matrix'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            Ok((a, b, n, d, t))
        })
        .await
        .unwrap();
    assert!(matches!(a, Gate::Ask(_)));
    assert_eq!(a, b);
    assert_eq!(n, 1);
    let v: Value = serde_json::from_str(&data).unwrap();
    let mut keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(
        keys,
        [
            "action", "amount", "facts", "plan", "project", "session", "who"
        ]
    );
    assert_eq!(
        v["facts"],
        json!({"command": "git commit -m x", "paths": []})
    );
    assert_eq!(title, "commit: git commit -m x");
}

#[tokio::test]
async fn a_preset_switch_applies_from_the_next_action() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&json!({"preset": "cautious"})).unwrap();
    let g2 = g.clone();
    let before = db
        .write(meta(Class::System), move |tx| {
            g2.check(
                tx,
                &who(Role::Manager),
                Action::MergeIntegration,
                &ctx("m"),
                1.0,
            )
        })
        .await
        .unwrap();
    assert!(matches!(before, Gate::Ask(_)));
    g.apply_setting(&json!({"preset": "balanced"})).unwrap();
    let after = db
        .write(meta(Class::System), move |tx| {
            g.check(
                tx,
                &who(Role::Manager),
                Action::MergeIntegration,
                &ctx("m"),
                2.0,
            )
        })
        .await
        .unwrap();
    assert_eq!(after, Gate::Allow);
}

#[tokio::test]
async fn recheck_after_switch_to_balanced_refuses() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&ask_commit("cautious", "ask")).unwrap();
    let g2 = g.clone();
    let id = db
        .write(meta(Class::System), move |tx| {
            let Gate::Ask(id) = g2.check(tx, &who(Role::Worker), Action::Commit, &ctx("c"), 1.0)?
            else {
                panic!("asked");
            };
            card_settle(tx, id, "allow", 2.0)?;
            Ok(id)
        })
        .await
        .unwrap();
    let g3 = g.clone();
    let now = db.read(move |c| Ok(g3.recheck(c, id, 3.0))).await.unwrap();
    assert_eq!(now, Gate::Allow);
    g.apply_setting(&ask_commit("balanced", "never")).unwrap();
    let later = db.read(move |c| Ok(g.recheck(c, id, 4.0))).await.unwrap();
    assert!(matches!(later, Gate::Never(_)));
}

#[tokio::test]
async fn delegate_refuses_wider() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    let wide = effective(&[&preset(Preset::Autonomous)], &who(Role::Manager));
    let same = effective(&[&preset(Preset::Balanced)], &who(Role::Manager));
    let r = db
        .read(move |c| {
            let m = who(Role::Manager);
            let c0 = ActionCtx::default();
            let bad = g.delegate(c, &m, &c0, "w1", wide, 1.0);
            let ok = g.delegate(c, &m, &c0, "w1", same, 1.0);
            Ok((bad, ok))
        })
        .await
        .unwrap();
    assert_eq!(r.0.unwrap_err().action, Action::AgentsStart);
    assert!(r.1.is_ok());
}

/// Worker session W1's verdict on A after a manager (all its own cells) delegated to it, under SETTING.
async fn delegated_verdict(setting: Value, a: Action) -> Verdict {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&json!({"preset": "balanced"})).unwrap();
    let g2 = g.clone();
    db.read(move |c| {
        let m = who(Role::Manager);
        let asked = g2.effective_for(c, &m, &ActionCtx::default(), 1.0);
        g2.delegate(c, &m, &ActionCtx::default(), "w1", asked, 1.0)
            .unwrap();
        Ok(())
    })
    .await
    .unwrap();
    g.apply_setting(&setting).unwrap();
    let c = ActionCtx {
        session: Some("w1".into()),
        ..ctx("c")
    };
    db.read(move |conn| Ok(g.dry(conn, &who(Role::Worker), a, &c, 2.0).verdict))
        .await
        .unwrap()
}

#[tokio::test]
async fn a_delegation_never_widens_the_workers_own_cells() {
    // the manager may commit (Balanced) and hands that on; the user's worker cell still binds the worker
    assert_eq!(
        delegated_verdict(ask_commit("balanced", "ask"), Action::Commit).await,
        Verdict::Ask
    );
    assert_eq!(
        delegated_verdict(ask_commit("balanced", "never"), Action::Commit).await,
        Verdict::Never
    );
    // a provider's Never binds a delegated worker of that provider too
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&json!({"preset": "balanced", "cells": [
        {"action": "commit", "column": {"provider": "p1"}, "verdict": "never"}]}))
        .unwrap();
    let v = db
        .read(move |c| {
            let m = who(Role::Manager);
            let asked = g.effective_for(c, &m, &ActionCtx::default(), 1.0);
            g.delegate(c, &m, &ActionCtx::default(), "w1", asked, 1.0)
                .unwrap();
            let w = Who {
                provider: Some("p1".into()),
                ..who(Role::Worker)
            };
            let x = ActionCtx {
                session: Some("w1".into()),
                ..ctx("c")
            };
            Ok(g.dry(c, &w, Action::Commit, &x, 2.0).verdict)
        })
        .await
        .unwrap();
    assert_eq!(v, Verdict::Never);
}

#[tokio::test]
async fn tightening_the_manager_reaches_its_workers() {
    let manager_never = json!({"preset": "balanced", "cells": [
        {"action": "commit", "column": {"role": "manager"}, "verdict": "never"}]});
    assert_eq!(
        delegated_verdict(manager_never, Action::Commit).await,
        Verdict::Never
    );
    // and the away preset reaches them as well (Cautious asks for a worker's machines, Balanced allows them)
    let away = json!({"preset": "balanced", "time": [{"when": "away", "preset": "cautious"}]});
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&away).unwrap();
    let g2 = g.clone();
    db.read(move |c| {
        let m = who(Role::Manager);
        let asked = g2.effective_for(c, &m, &ActionCtx::default(), 1.0);
        g2.delegate(c, &m, &ActionCtx::default(), "w1", asked, 1.0)
            .unwrap();
        Ok(())
    })
    .await
    .unwrap();
    g.set_away(true);
    let x = ActionCtx {
        session: Some("w1".into()),
        ..ctx("c")
    };
    let v = db
        .read(move |c| {
            Ok(g.dry(c, &who(Role::Worker), Action::Machines, &x, 2.0)
                .verdict)
        })
        .await
        .unwrap();
    assert_eq!(v, Verdict::Ask);
}

#[tokio::test]
async fn a_delegation_allows_what_both_allow_without_a_card() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&json!({"preset": "balanced"})).unwrap();
    let r = db
        .write(meta(Class::System), move |tx| {
            let m = who(Role::Manager);
            let asked = g.effective_for(tx.sql(), &m, &ActionCtx::default(), 1.0);
            g.delegate(tx.sql(), &m, &ActionCtx::default(), "w1", asked, 1.0)
                .unwrap();
            let c = ActionCtx {
                session: Some("w1".into()),
                ..ctx("c")
            };
            g.check(tx, &who(Role::Worker), Action::Commit, &c, 2.0)
        })
        .await
        .unwrap();
    assert_eq!(r, Gate::Allow);
}

#[tokio::test]
async fn plan_override_only_by_the_user() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    let mk = |class: Class, id: &'static str| {
        db.write(meta(class), move |tx| {
            entity::create(
                tx,
                EntityNew {
                    id: id.into(),
                    kind: "plan".into(),
                    project: None,
                    title: Some("p".into()),
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({"matrix": [
                        {"action": "commit", "column": {"role": "worker"}, "verdict": "never"}]}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
            Ok(())
        })
    };
    mk(Class::User, "plan:u").await.unwrap();
    mk(Class::Agent, "plan:a").await.unwrap();
    let r = db
        .read(move |c| {
            let at = |p: &str| {
                let x = ActionCtx {
                    plan: Some(p.into()),
                    ..ActionCtx::default()
                };
                g.dry(c, &who(Role::Worker), Action::Commit, &x, 1.0)
                    .verdict
            };
            Ok((at("plan:u"), at("plan:a")))
        })
        .await
        .unwrap();
    assert_eq!(r, (Verdict::Never, Verdict::Allow));
}

#[tokio::test]
async fn an_override_counts_by_the_writer_of_its_own_field() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    let never = json!([{"action": "commit", "column": {"role": "worker"}, "verdict": "never"}]);
    let mk = |class: Class, id: &'static str, kind: &'static str, data: Value| {
        db.write(meta(class), move |tx| {
            entity::create(
                tx,
                EntityNew {
                    id: id.into(),
                    kind: kind.into(),
                    project: None,
                    title: Some("p".into()),
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data,
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
            Ok(())
        })
    };
    let note = |class: Class, id: &'static str| {
        db.write(meta(class), move |tx| {
            let n = entity::by_id(tx.sql(), id)?.unwrap().n;
            entity::update(
                tx,
                n,
                None,
                entity::Changes {
                    data_patch: Some(json!({"note": "x"})),
                    ..entity::Changes::default()
                },
            )?;
            Ok(())
        })
    };
    // the user's override, then an agent's write of another data field: the override still counts
    mk(
        Class::User,
        "plan:u",
        "plan",
        json!({"matrix": never.clone()}),
    )
    .await
    .unwrap();
    note(Class::Agent, "plan:u").await.unwrap();
    // an agent's override, then the user's write of another data field: still the agent's, ignored
    mk(
        Class::Agent,
        "plan:a",
        "plan",
        json!({"matrix": never.clone()}),
    )
    .await
    .unwrap();
    note(Class::User, "plan:a").await.unwrap();
    // a project's override is read the same way
    mk(
        Class::User,
        "project:q",
        "project",
        json!({"matrix": never}),
    )
    .await
    .unwrap();
    let r = db
        .read(move |c| {
            let at = |plan: Option<&str>, project: Option<&str>| {
                let x = ActionCtx {
                    plan: plan.map(str::to_owned),
                    project: project.map(str::to_owned),
                    ..ActionCtx::default()
                };
                g.dry(c, &who(Role::Worker), Action::Commit, &x, 1.0)
                    .verdict
            };
            Ok((
                at(Some("plan:u"), None),
                at(Some("plan:a"), None),
                at(None, Some("project:q")),
            ))
        })
        .await
        .unwrap();
    assert_eq!(r, (Verdict::Never, Verdict::Allow, Verdict::Never));
}
