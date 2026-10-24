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

#[tokio::test]
async fn delegation_allows_without_a_card() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&ask_commit("balanced", "ask")).unwrap();
    let r = db
        .write(meta(Class::System), move |tx| {
            let m = who(Role::Manager);
            let c0 = ActionCtx::default();
            let asked = g.effective_for(tx.sql(), &m, &c0, 1.0);
            g.delegate(tx.sql(), &m, &c0, "w1", asked, 1.0).unwrap();
            let c = ActionCtx {
                session: Some("w1".into()),
                ..ctx("c")
            };
            let own = g.check(
                tx,
                &who(Role::Worker),
                Action::Commit,
                &ActionCtx {
                    session: None,
                    ..ctx("c")
                },
                2.0,
            )?;
            let delegated = g.check(tx, &who(Role::Worker), Action::Commit, &c, 2.0)?;
            Ok((own, delegated))
        })
        .await
        .unwrap();
    assert!(matches!(r.0, Gate::Ask(_)));
    assert_eq!(r.1, Gate::Allow);
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
