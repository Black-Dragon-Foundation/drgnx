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

// The gate's seams the tests above reach only through the hub: the session's scope, the front's settings, the
// editors' event, the written card's time, the reasons and titles a card or a refusal shows.

fn front(dir: &std::path::Path) -> Front {
    Front::new(
        runstav::proof::Cap::generate().unwrap(),
        dir.join("hub-x.sock"),
        crate::store::WorkDb::spawn(dir.join("work.db")).unwrap(),
        CoordDb::spawn(dir.join("work.db")),
        Arc::new(crate::dispatch::NoBackend),
    )
}

async fn set_matrix(f: &Front, v: Value) {
    f.settings
        .set_overrides(
            None,
            vec![crate::settings::overrides::Override {
                name: "drgnx-agents-matrix".into(),
                value: v,
                source: "test".into(),
            }],
        )
        .await
        .unwrap();
}

fn caller() -> Caller {
    Caller {
        class: runstav::registry::Class::User,
        sid: None,
        job: None,
        conn_id: 1,
        backend: false,
    }
}

/// Entity ID of KIND whose `matrix` field the user wrote: CELLS (action, role) are Never.
async fn never_override(
    db: &CoordDb,
    id: &'static str,
    kind: &'static str,
    cells: &[(&str, &str)],
) {
    let rows: Vec<Value> = cells
        .iter()
        .map(|(a, r)| json!({"action": a, "column": {"role": r}, "verdict": "never"}))
        .collect();
    db.write(meta(Class::User), move |tx| {
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: kind.into(),
                project: None,
                title: Some("e".into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({ "matrix": rows }),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        Ok(())
    })
    .await
    .unwrap();
}

#[test]
fn a_session_acts_in_the_plan_and_project_of_its_scope() {
    let runs = crate::runner::Runs::default();
    runs.set_scope("s1", "plan:p".into(), Some("project:q".into()));
    let c = ActionCtx::of_session(&runs.scopes(), "s1");
    assert_eq!(
        (
            c.plan.as_deref(),
            c.project.as_deref(),
            c.session.as_deref()
        ),
        (Some("plan:p"), Some("project:q"), Some("s1"))
    );
    let none = ActionCtx::of_session(&runs.scopes(), "s2");
    assert_eq!(
        (none.plan, none.project, none.session.as_deref()),
        (None, None, Some("s2"))
    );
}

#[tokio::test]
async fn the_time_presets_follow_the_local_minute_of_the_clock() {
    let g = MatrixGate::default();
    // a minute that is not midnight's, so a clock read as 0 does not fall in the range
    let now = (0..)
        .map(|k| 1_700_000_000.0 + f64::from(k) * 60.0)
        .find(|t| minute(*t) != 0)
        .unwrap();
    let m = minute(now);
    assert_eq!(m as u32, local(now as u64).minute);
    g.apply_setting(&json!({"preset": "cautious", "time": [
        {"when": {"between": [m, m + 1]}, "preset": "autonomous"}]}))
        .unwrap();
    assert_eq!(g.active_preset(now), Preset::Autonomous);
    assert_eq!(g.active_preset(now + 120.0), Preset::Cautious);
}

#[tokio::test]
async fn a_card_title_names_the_path_or_the_diff_when_there_is_no_command() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&ask_commit("cautious", "ask")).unwrap();
    let hash = "ab".repeat(32);
    let facts = [
        json!({"paths": ["/w/a.rs", "/w/b.rs"]}),
        json!({"diff_hash": hash.clone()}),
    ];
    let titles = db
        .write(meta(Class::System), move |tx| {
            for (i, f) in facts.into_iter().enumerate() {
                let c = ActionCtx {
                    facts: serde_json::from_value(f).unwrap(),
                    ..ActionCtx::default()
                };
                g.check(tx, &who(Role::Worker), Action::Commit, &c, i as f64)?;
            }
            let mut q = tx
                .sql()
                .prepare("select title from card where kind = 'matrix' order by id")?;
            Ok(q.query_map([], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap();
    assert_eq!(
        titles,
        [
            "commit: /w/a.rs".to_string(),
            format!("commit: diff {hash}")
        ]
    );
}

#[tokio::test]
async fn a_refusal_says_why_and_an_allowance_says_nothing() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    let (never, allowed, over) = db
        .read(move |c| {
            let w = who(Role::Worker);
            let x = ActionCtx::default();
            let spend = ActionCtx {
                amount: Some(11.0),
                ..ActionCtx::default()
            };
            Ok((
                g.dry(c, &w, Action::Unsandboxed, &x, 1.0),
                g.dry(c, &w, Action::CodeRead, &x, 1.0),
                g.dry(c, &w, Action::Spend, &spend, 1.0),
            ))
        })
        .await
        .unwrap();
    assert_eq!(never.verdict, Verdict::Never);
    assert_eq!(
        never.why.as_deref(),
        Some("unsandboxed is never allowed here")
    );
    assert_eq!((allowed.verdict, allowed.why), (Verdict::Allow, None));
    assert_eq!(over.verdict, Verdict::Never);
    assert!(over.why.unwrap().contains("over its limit"));
}

#[tokio::test]
async fn a_declined_card_refuses_and_an_open_one_follows_the_matrix_now() {
    let (_d, db) = db();
    let g = MatrixGate::default();
    g.apply_setting(&ask_commit("cautious", "ask")).unwrap();
    let g2 = g.clone();
    let (open, declined) = db
        .write(meta(Class::System), move |tx| {
            let mut ask = |cmd: &str, t: f64| match g2.check(
                tx,
                &who(Role::Worker),
                Action::Commit,
                &ctx(cmd),
                t,
            )? {
                Gate::Ask(id) => Ok::<i64, CoordError>(id),
                other => panic!("asked, got {other:?}"),
            };
            let open = ask("one", 1.0)?;
            let declined = ask("two", 2.0)?;
            card_settle(tx, declined, "deny", 3.0)?;
            Ok((open, declined))
        })
        .await
        .unwrap();
    let at = |g: &MatrixGate, id| {
        let g = g.clone();
        let db = &db;
        async move { db.read(move |c| Ok(g.recheck(c, id, 4.0))).await.unwrap() }
    };
    assert_eq!(at(&g, open).await, Gate::Ask(open));
    assert_eq!(
        at(&g, declined).await,
        Gate::Never("the user declined".into())
    );
    // the matrix now allows what the open card asked: no answer is needed
    g.apply_setting(&ask_commit("cautious", "allow")).unwrap();
    assert_eq!(at(&g, open).await, Gate::Allow);
    assert_eq!(
        at(&g, declined).await,
        Gate::Never("the user declined".into())
    );
}

#[test]
fn a_dropped_delegation_is_gone() {
    let g = MatrixGate::default();
    g.set_delegated("w1", Delegation::default());
    g.set_delegated("w2", Delegation::default());
    assert!(g.delegated_to("w1").is_some());
    g.drop_delegation("w1");
    assert!(g.delegated_to("w1").is_none());
    assert!(g.delegated_to("w2").is_some());
}

#[tokio::test]
async fn a_workers_manager_binds_it_in_the_managers_project_and_plan() {
    let (_d, db) = db();
    never_override(&db, "project:q", "project", &[("commit", "manager")]).await;
    never_override(&db, "plan:p", "plan", &[("code.edit", "manager")]).await;
    let g = MatrixGate::default();
    let manager = who(Role::Manager);
    // the manager handed its worker everything an Autonomous manager has; only its own cells narrow that
    let all = effective(&[&preset(Preset::Autonomous)], &manager);
    let delegation = |project: Option<&str>, plan: Option<&str>| Delegation {
        cells: all.clone(),
        manager: Some(Manager {
            who: manager.clone(),
            project: project.map(str::to_owned),
            plan: plan.map(str::to_owned),
        }),
    };
    g.set_delegated("in-project", delegation(Some("project:q"), None));
    g.set_delegated("in-plan", delegation(None, Some("plan:p")));
    g.set_delegated("elsewhere", delegation(None, None));
    let verdicts = db
        .read(move |c| {
            let at = |sid: &str, a| {
                let x = ActionCtx {
                    session: Some(sid.into()),
                    ..ActionCtx::default()
                };
                g.dry(c, &who(Role::Worker), a, &x, 1.0).verdict
            };
            Ok([
                at("in-project", Action::Commit),
                at("in-plan", Action::CodeEdit),
                at("elsewhere", Action::Commit),
                at("elsewhere", Action::CodeEdit),
            ])
        })
        .await
        .unwrap();
    assert_eq!(
        verdicts,
        [
            Verdict::Never,
            Verdict::Never,
            Verdict::Allow,
            Verdict::Allow
        ]
    );
}

#[tokio::test]
async fn the_view_shows_the_project_and_the_plan_overrides() {
    let (_d, db) = db();
    never_override(&db, "project:q", "project", &[("commit", "manager")]).await;
    never_override(&db, "plan:p", "plan", &[("code.edit", "manager")]).await;
    let g = MatrixGate::default();
    let p: GetParams =
        serde_json::from_value(json!({"project": "project:q", "plan": "plan:p"})).unwrap();
    let v = db.read(move |c| Ok(g.view(c, &p, 1.0))).await.unwrap();
    let cell = |a| {
        v.cells
            .iter()
            .find(|r| r.action == a && r.column == Column::Role(Role::Manager))
            .map(|r| r.verdict)
    };
    assert_eq!(cell(Action::Commit), Some(Verdict::Never));
    assert_eq!(cell(Action::CodeEdit), Some(Verdict::Never));
}

#[tokio::test]
async fn the_gate_reads_the_front_settings_and_announces_a_new_card() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    set_matrix(&f, ask_commit("cautious", "ask")).await;
    // refresh and refresh_from take the setting the front holds
    let (a, b) = (MatrixGate::default(), MatrixGate::default());
    a.refresh(&f);
    b.refresh_from(&f.settings);
    assert_eq!(a.active_preset(0.0), Preset::Cautious);
    assert_eq!(b.active_preset(0.0), Preset::Cautious);
    // the effective cells now are the setting's, not an empty set
    let e = f
        .core
        .matrix
        .effective_now(
            &f.settings,
            &f.writer,
            who(Role::Worker),
            ActionCtx::default(),
        )
        .await
        .unwrap();
    assert_eq!(e.cell(Action::Commit).verdict, Verdict::Ask);
    assert_eq!(e.cell(Action::CodeRead).verdict, Verdict::Allow);
    // a new matrix card is written with the clock's time and announced to the editors
    let out = Arc::new(crate::conn::Outbox::new(1));
    f.editors.subscribe(1, out.clone());
    let before = now_secs();
    let gate = f
        .core
        .matrix
        .decide(
            &f.settings,
            &f.writer,
            who(Role::Worker),
            Action::Commit,
            ctx("git commit"),
        )
        .await;
    let Gate::Ask(id) = gate else {
        panic!("asked, got {gate:?}")
    };
    assert!(id > 0);
    let at: f64 = f
        .writer
        .db
        .read(move |c| Ok(c.query_row("select at from card where id = ?1", [id], |r| r.get(0))?))
        .await
        .unwrap();
    assert!((before..=now_secs()).contains(&at), "{at} vs {before}");
    let lines = out.take_lines();
    assert_eq!(lines.len(), 1, "{lines:?}");
    let ev: Value = serde_json::from_str(lines[0].trim()).unwrap();
    assert_eq!(ev["event"], "card", "{ev}");
    assert_eq!(ev["data"]["id"], id);
    assert_eq!(ev["data"]["kind"], "matrix");
    assert_eq!(ev["data"]["title"], "commit: git commit");
}

#[tokio::test]
async fn presence_sets_the_away_flag_and_answers_it() {
    let dir = tempfile::tempdir().unwrap();
    let f = front(dir.path());
    f.core
        .matrix
        .apply_setting(
            &json!({"preset": "balanced", "time": [{"when": "away", "preset": "cautious"}]}),
        )
        .unwrap();
    let c = caller();
    assert!(
        presence(&f, &c, PresenceParams { away: true })
            .await
            .unwrap()
    );
    assert_eq!(f.core.matrix.active_preset(0.0), Preset::Cautious);
    assert!(
        !presence(&f, &c, PresenceParams { away: false })
            .await
            .unwrap()
    );
    assert_eq!(f.core.matrix.active_preset(0.0), Preset::Balanced);
}
