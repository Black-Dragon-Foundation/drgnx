//! What a revert cannot undo.  Pattern D throughout: a temp store, temp repositories and a local bare remote; no
//! network and no hub process.

use super::*;
use norn::write::decisions::{Decide, DecideResult, decide};
use norn::write::messages::{self, Send};
use runstav::methods::history::Pushed;
use serde_json::json;
use std::path::Path;
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::{Class, TxMeta, link};

fn front_in(dir: &Path) -> Front {
    crate::runner::graph_plan_tests::front(dir)
}

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn repo() -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    sh(d.path(), &["init", "-q", "-b", "main"]);
    d
}

/// Commit TEXT as FILE in DIR; its sha.
fn commit(dir: &Path, file: &str, text: &str, subject: &str) -> String {
    std::fs::write(dir.join(file), text).unwrap();
    sh(dir, &["add", file]);
    sh(dir, &["commit", "-q", "-m", subject]);
    sh(dir, &["rev-parse", "HEAD"])
}

/// A tx of session SID (none: the hub's) through TOOL.
fn meta(sid: Option<&str>, tool: &str) -> TxMeta {
    let mut m = TxMeta::new(
        sid.map_or("t".into(), |s| format!("agent:{s}")),
        Class::System,
        tool,
    );
    m.session = sid.map(str::to_owned);
    m
}

/// Step SEQ of SID, started at START, with COST in UNIT and TOKENS in and out, decision log version 0.
async fn step(f: &Front, sid: &str, seq: i64, start: f64, cost: Option<(f64, &str)>, tokens: i64) {
    let (session, unit) = (format!("session:{sid}"), cost.map(|c| c.1.to_owned()));
    let cost = cost.map(|c| c.0);
    f.writer
        .db
        .write(meta(None, "test"), move |tx| {
            tx.sql().execute(
                "insert into step (session, seq, class, start, end, agent, tokens_in, tokens_out, cost, cost_unit, \
                 log_version) values (?1, ?2, 'tool', ?3, ?3, 'agent:mock', ?4, ?4, ?5, ?6, 0)",
                (&session, seq, start, tokens, cost, &unit),
            )?;
            Ok(())
        })
        .await
        .unwrap();
}

/// The time of the newest tx.
async fn last_at(f: &Front) -> f64 {
    f.writer
        .db
        .read(|c| Ok(c.query_row("select max(at) from tx", [], |r| r.get(0))?))
        .await
        .unwrap()
}

/// A commit entity for SHA of SESSION, read in STORE.
async fn commit_entity(f: &Front, sha: &str, session: &str, store: &Path) -> i64 {
    let data = json!({"sha": sha, "repo": store.to_string_lossy(), "session": session,
                      "store": store.to_string_lossy()});
    let id = format!("commit:{sha}");
    f.writer
        .db
        .write(meta(Some(session), "test"), move |tx| {
            let project = tx.meta().project;
            let e = entity::create(
                tx,
                EntityNew {
                    id,
                    kind: "commit".into(),
                    project,
                    title: None,
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data,
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
            Ok(e.n)
        })
        .await
        .unwrap()
}

/// Decision of SESSION that the commit entity N implements; its number.
async fn decision(f: &Front, session: &str, subject: &str, commit_n: i64) -> i64 {
    let subject = subject.to_owned();
    f.writer
        .db
        .write(meta(Some(session), "test"), move |tx| {
            let r = decide(
                tx,
                Decide {
                    kind: "build".into(),
                    subject,
                    author: "agent".into(),
                    ..Decide::default()
                },
                1.0,
            )?;
            let DecideResult::Ok { n, .. } = r else {
                panic!("{r:?}")
            };
            let d = entity::by_id(tx.sql(), &format!("decision:{n}"))?.unwrap();
            link::add(
                tx,
                commit_n,
                "implements",
                d.n,
                None,
                Origin::Recorded,
                None,
            )?;
            Ok(n)
        })
        .await
        .unwrap()
}

/// An entity of KIND as session SID's tx through TOOL.
async fn made(f: &Front, sid: &str, tool: &str, id: &str, kind: &str) {
    let (id, kind) = (id.to_owned(), kind.to_owned());
    f.writer
        .db
        .write(meta(Some(sid), tool), move |tx| {
            let project = tx.meta().project;
            entity::create(
                tx,
                EntityNew {
                    id,
                    kind,
                    project,
                    title: Some("t".into()),
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
            Ok(())
        })
        .await
        .unwrap();
}

fn target(sid: &str, seq: i64) -> Target {
    Target {
        sid: sid.into(),
        seq,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_a_pushed_commit() {
    let (dir, d, remote) = (
        tempfile::tempdir().unwrap(),
        repo(),
        tempfile::tempdir().unwrap(),
    );
    let f = front_in(dir.path());
    sh(remote.path(), &["init", "-q", "--bare"]);
    commit(d.path(), "a.txt", "base\n", "base");
    sh(
        d.path(),
        &["remote", "add", "origin", &remote.path().to_string_lossy()],
    );
    sh(d.path(), &["push", "-q", "origin", "main"]);
    step(&f, "s1", 1, 0.0, None, 0).await;
    let c1 = commit(d.path(), "a.txt", "one\n", "c1");
    sh(d.path(), &["push", "-q", "origin", "main"]);
    let c2 = commit(d.path(), "a.txt", "two\n", "c2");
    commit_entity(&f, &c1, "s1", d.path()).await;
    commit_entity(&f, &c2, "s1", d.path()).await;
    let e = of(&f, &target("s1", 1)).await.unwrap();
    // c2 is only here; c1 reached the remote
    assert_eq!(
        e.pushed,
        [Pushed {
            commit: c1,
            refs: vec!["origin/main".into()]
        }]
    );
    assert_eq!(e.label, "computed");
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_read_messages_only() {
    let dir = tempfile::tempdir().unwrap();
    let f = front_in(dir.path());
    step(&f, "s1", 1, 100.0, None, 0).await;
    let ids = f
        .writer
        .db
        .write(meta(None, "test"), |tx| {
            let mut ids = Vec::new();
            for (sender, at, state) in [
                ("agent:mock", 50.0, "read"),
                ("agent:mock", 150.0, "read"),
                ("agent:mock", 160.0, "delivered"),
                ("agent:mock", 170.0, "acted"),
                ("agent:other", 150.0, "read"),
            ] {
                let s = Send {
                    sender: Some(sender.into()),
                    recipient: "user".into(),
                    text: "hi".into(),
                    ..Send::default()
                };
                let messages::SendResult::Ok { id, .. } = messages::send(tx, s, at)? else {
                    panic!("held")
                };
                assert!(messages::mark(tx, id, state, at + 1.0)?);
                ids.push(id);
            }
            Ok(ids)
        })
        .await
        .unwrap();
    let e = of(&f, &target("s1", 1)).await.unwrap();
    // before the step, only delivered, and another agent's: not listed
    assert_eq!(e.messages_read, [ids[1], ids[3]]);
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_filed_tasks_and_spend_after_the_step() {
    let dir = tempfile::tempdir().unwrap();
    let f = front_in(dir.path());
    made(&f, "s1", "mcp:task_write", "task:early", "task").await;
    let start = last_at(&f).await;
    step(&f, "s1", 1, start, Some((2.0, "usd")), 100).await;
    step(&f, "s1", 2, start, Some((0.25, "usd")), 10).await;
    step(&f, "s1", 3, start, Some((0.5, "usd-est")), 1).await;
    made(&f, "s1", "mcp:task_write", "task:late", "task").await;
    made(&f, "s2", "mcp:task_write", "task:other", "task").await;
    made(
        &f,
        "s1",
        norn::tools::settings::PROPOSED_TOOL,
        "setting:x",
        "setting",
    )
    .await;
    assert!(last_at(&f).await > start);
    let e = of(&f, &target("s1", 1)).await.unwrap();
    assert_eq!(e.tasks_filed, ["task:late"]);
    assert_eq!(e.settings, ["setting:x"]);
    // the steps after the step: not the step's own
    assert_eq!(
        e.spent.cost_by_unit,
        [("usd".to_string(), 0.25), ("usd-est".to_string(), 0.5)]
            .into_iter()
            .collect()
    );
    assert_eq!(e.spent.tokens, 22);
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_running_jobs() {
    let dir = tempfile::tempdir().unwrap();
    let f = front_in(dir.path());
    step(&f, "s1", 1, 0.0, None, 0).await;
    let live = f.core.exec.live();
    live.started("j1", "s1");
    live.started("j2", "s2");
    let e = of(&f, &target("s1", 1)).await.unwrap();
    assert_eq!(e.jobs_running, ["j1 (here)"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_queued_and_remote_jobs() {
    let dir = tempfile::tempdir().unwrap();
    let f = front_in(dir.path());
    let (_store, db) = crate::runtime_db::open(dir.path()).unwrap();
    f.core.agents.open_store(db.clone());
    step(&f, "s1", 1, 0.0, None, 0).await;
    db.write(|c| {
        Ok(c.execute_batch(
            "insert into rq_job (id, spec, own, effective, trust, project, state, submitted, attempt) values \
             ('q1', '{\"session\": \"s1\"}', 3, 3, 'own', 'p', 'queued', 1.0, 0), \
             ('r1', '{\"session\": \"s1\"}', 3, 3, 'own', 'p', 'running', 1.0, 1), \
             ('q2', '{\"session\": \"s2\"}', 3, 3, 'own', 'p', 'queued', 1.0, 0); \
             insert into rq_attempt (job, attempt, nonce, runner, placed, state) values \
             ('r1', 1, 'n', 'box', 2.0, 'running');",
        )?)
    })
    .await
    .unwrap();
    let e = of(&f, &target("s1", 1)).await.unwrap();
    assert_eq!(e.jobs_running, ["q1 (queued)", "r1 (on box)"]);
}

/// Session S1's decision with a commit on line 3 of a file, and a later commit by AUTHOR on the same line, with its
/// own decision, both on the repository's branch: the second depends on the first.
async fn dependent_on_top(f: &Front, d: &Path, author: &str) -> (i64, i64, String) {
    commit(d, "a.txt", "1\n2\n3\n4\n", "base");
    step(f, "s1", 1, 0.0, None, 0).await;
    let c1 = commit(d, "a.txt", "1\n2\nA\n4\n", "c1");
    let c2 = commit(d, "a.txt", "1\n2\nB\n4\n", "c2");
    let n1 = commit_entity(f, &c1, "s1", d).await;
    let n2 = commit_entity(f, &c2, author, d).await;
    let d1 = decision(f, "s1", "d1", n1).await;
    let d2 = decision(f, author, "d2", n2).await;
    (d1, d2, c2)
}

#[tokio::test(flavor = "multi_thread")]
async fn blocked_when_a_dependent_merged_on_top() {
    let (dir, d) = (tempfile::tempdir().unwrap(), repo());
    let f = front_in(dir.path());
    let (d1, d2, c2) = dependent_on_top(&f, d.path(), "s2").await;
    let deps = crate::runner::effects::dependents(&f, d1).await.unwrap();
    assert_eq!(deps.decisions, [d2]);
    let b = blocked(&f, &deps, "s1").await.unwrap();
    assert_eq!(
        b,
        [Blocked {
            decision: d2,
            commit: c2,
            session: "s2".into(),
            branch: "main".into()
        }]
    );
    // the session's own decision that another relies on is listed among what cannot be undone
    let e = of(&f, &target("s1", 1)).await.unwrap();
    assert_eq!(e.decisions_relied_on, [d1]);
}

#[tokio::test(flavor = "multi_thread")]
async fn not_blocked_by_the_sessions_own_merge() {
    let (dir, d) = (tempfile::tempdir().unwrap(), repo());
    let f = front_in(dir.path());
    let (d1, d2, _c2) = dependent_on_top(&f, d.path(), "s1").await;
    let deps = crate::runner::effects::dependents(&f, d1).await.unwrap();
    assert_eq!(deps.decisions, [d2]);
    // the dependent is the session's own: the revert takes it too
    assert!(blocked(&f, &deps, "s1").await.unwrap().is_empty());
}
