use super::*;
use norn::store::CoordDb;
use norn::write::jobs::{NewJob, NewTask, job_create};
use urdr::graph::{Class, TxMeta};

fn meta(c: Class) -> TxMeta {
    TxMeta::new("t", c, "test")
}

const PLAN: &str = "# Plan\n\n## Task 1: first\n\nDo one.\n\n## Task 2: second\n\nDo two.\n\n### Part A\n\nmore\n\n- [ ] **Step 1: Tests.** write them. **Author check:** fmt and the `brief::` tests.\n";

async fn setup() -> (tempfile::TempDir, CoordDb, String) {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("repo");
    std::fs::create_dir(&repo).unwrap();
    std::fs::write(repo.join("AGENTS.md"), "# Rules\n\nbe kind\n").unwrap();
    let plan = dir.path().join("plan.md");
    std::fs::write(&plan, PLAN).unwrap();
    let db = CoordDb::spawn(dir.path().join("work.db"));
    let (p, r) = (
        plan.to_string_lossy().into_owned(),
        repo.to_string_lossy().into_owned(),
    );
    let t = |n, deps: Vec<i64>| NewTask {
        n,
        title: format!("Task {n}"),
        role: None,
        deps,
    };
    let job = NewJob {
        id: "J".into(),
        title: "j".into(),
        plan: Some(p.clone()),
        repo: Some(r),
        tasks: vec![t(1, vec![]), t(2, vec![1])],
        data: None,
    };
    db.write(meta(Class::System), move |tx| job_create(tx, job, 1.0))
        .await
        .unwrap();
    (dir, db, p)
}

fn worker() -> Who {
    Who {
        role: Some(Role::Worker),
        ..Who::default()
    }
}

async fn gathered(db: &CoordDb, task: &'static str) -> (Vec<(BriefPart, String)>, String) {
    let gate = MatrixGate::default();
    db.read(move |c| gather(c, &gate, task, (worker(), ActionCtx::default()), 1.0))
        .await
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_brief_says_what_the_gate_will_do_for_its_session() {
    let (_d, db, _) = setup().await;
    let gate = MatrixGate::default();
    // the user's Never for one provider, and a manager's delegation that leaves out code.ci-config
    gate.apply_setting(&json!({"cells": [
        {"action": "commit", "column": {"provider": "p1"}, "verdict": "never"}]}))
        .unwrap();
    let mgr = Who {
        role: Some(Role::Manager),
        ..Who::default()
    };
    let (g, m) = (gate.clone(), mgr.clone());
    db.read(move |c| {
        let mut asked = g.effective_for(c, &m, &ActionCtx::default(), 1.0);
        asked.cells.remove(&Action::CodeCiConfig);
        g.delegate(c, &m, &ActionCtx::default(), "w1", asked, 1.0)
            .unwrap();
        Ok(())
    })
    .await
    .unwrap();
    let who = Who {
        provider: Some("p1".into()),
        ..worker()
    };
    let ctx = ActionCtx {
        session: Some("w1".into()),
        ..ActionCtx::default()
    };
    let (g, w, x) = (gate.clone(), who.clone(), ctx.clone());
    let (parts, _) = db
        .read(move |c| gather(c, &g, "J#1", (w, x), 1.0))
        .await
        .unwrap();
    let m = &parts
        .iter()
        .find(|(p, _)| *p == BriefPart::Matrix)
        .unwrap()
        .1;
    let seam = db
        .read(move |c| Ok(gate.effective_for(c, &who, &ctx, 1.0)))
        .await
        .unwrap();
    assert_eq!(*m, matrix_lines(&seam));
    assert!(
        !m.contains("- commit:") && !m.contains("- code.ci-config:"),
        "{m}"
    );
    assert!(m.contains("- code.edit: allow"), "{m}");
}

#[tokio::test(flavor = "multi_thread")]
async fn brief_has_every_part() {
    let (_d, db, plan) = setup().await;
    db.write(meta(Class::System), |tx| {
        let t1 = entity::by_id(tx.sql(), "task:J#1")?.unwrap();
        let r = entity::create(
            tx,
            EntityNew {
                id: "report:xx-aaaaa".into(),
                kind: "report".into(),
                project: None,
                title: None,
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({"interfaces": "fn one() -> u8"}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        link::add(tx, r.n, "report_of", t1.n, None, Origin::Recorded, None)?;
        Ok(())
    })
    .await
    .unwrap();
    let (parts, pointer) = gathered(&db, "J#2").await;
    let (text, parts, cut) = assemble("J#2", parts, &pointer);
    assert!(!cut);
    let get = |p| parts.iter().find(|(q, _)| *q == p).unwrap().1.clone();
    assert!(get(BriefPart::PlanSection).contains("Do two."));
    assert!(!get(BriefPart::PlanSection).contains("Do one."));
    assert!(get(BriefPart::AgentsMd).contains("be kind"));
    let m = get(BriefPart::Matrix);
    assert!(!m.is_empty() && !m.contains(": never"));
    assert!(get(BriefPart::BaseBranch).contains("job/J (your branch is job/J-2"));
    assert!(get(BriefPart::Interfaces).contains("J#1: fn one() -> u8"));
    assert!(get(BriefPart::Check).contains("brief::"));
    assert!(get(BriefPart::ViewPath).contains(&plan));
    assert!(text.contains("## Interfaces from earlier tasks"));
}

#[tokio::test(flavor = "multi_thread")]
async fn missing_reports_leave_interfaces_empty() {
    let (_d, db, _) = setup().await;
    let (parts, _) = gathered(&db, "task:J#2").await;
    let i = parts
        .iter()
        .find(|(p, _)| *p == BriefPart::Interfaces)
        .unwrap();
    assert!(i.1.is_empty());
    assert_eq!(parts.len(), 7);
}

#[tokio::test(flavor = "multi_thread")]
async fn edited_brief_wins() {
    let (_d, db, _) = setup().await;
    assert_eq!(db.read(|c| edited(c, "J#1")).await.unwrap(), None);
    for text in ["mine", "mine, again"] {
        let id = db
            .write(meta(Class::User), move |tx| set_in(tx, "J#1", text.into()))
            .await
            .unwrap();
        assert_eq!(id, "note:brief-J#1");
    }
    assert_eq!(
        db.read(|c| edited(c, "task:J#1")).await.unwrap().as_deref(),
        Some("mine, again")
    );
    assert!(
        db.write(meta(Class::User), |tx| set_in(tx, "J#9", "x".into()))
            .await
            .is_err()
    );
}

#[test]
fn cap_cuts_at_a_heading() {
    let mut section = String::from("### Task 1: big\n\n");
    for i in 0..40 {
        section.push_str(&format!("#### Part {i}\n\n{}\n\n", "word ".repeat(100)));
    }
    let parts = vec![
        (BriefPart::PlanSection, section.clone()),
        (BriefPart::Check, "run it".into()),
    ];
    let (text, parts, cut) = assemble("J#1", parts, "see the plan");
    assert!(cut && text.len() <= CAP);
    let kept = &parts[0].1;
    assert!(kept.len() < section.len());
    let body = kept.split("\n\n[cut here").next().unwrap();
    assert!(section.starts_with(body));
    // the cut is before a heading: what follows in the original starts with one
    assert!(section[body.len()..].trim_start().starts_with("####"));
    assert!(kept.contains("[cut here to fit the brief: see the plan]"));
    assert!(text.contains("run it"));
}
