//! Fork from here, compare, take across and redo on live sessions of the mock agent (`ratatoskr-mock acp --state`,
//! real processes) in a real git repository (pattern C: each step waits for the mock's answer, its log or the step
//! bus, never a time).  The history's times are the steps' own, read from the store, so where a record falls against
//! a step is fixed, not raced.

use super::*;
use crate::agents::session::attach_tests::Fx;
use crate::history::revert::apply;
use crate::history::revert::live::{FIVE, Live, git, prompted, row_acp, turn, turn_end, user};
use runstav::methods::agents::StartParams;
use runstav::methods::history::RestoreLevel;
use serde_json::json;
use std::path::Path;

async fn start_as(fx: &Fx, profile: &str) -> String {
    start_in(fx, profile, None).await
}

/// A session of PROFILE in the work folder, in the matrix column ROLE (none: a chat).
async fn start_in(fx: &Fx, profile: &str, role: Option<&str>) -> String {
    let p: StartParams =
        serde_json::from_value(json!({"profile": profile, "cwd": fx.work(), "role": role}))
            .unwrap();
    fx.front
        .core
        .agents
        .start(&fx.front, p, &user())
        .await
        .expect("a session")
        .id
}

/// A repository with `a.txt` at its first commit.
fn repo(fx: &Fx) {
    let wt = fx.work();
    git(&wt, &["init", "-q", "-b", "main"]);
    std::fs::write(wt.join("a.txt"), FIVE).unwrap();
    git(&wt, &["add", "-A"]);
    git(&wt, &["commit", "-q", "-m", "base"]);
}

async fn fork_at(fx: &Fx, sid: &str, seq: i64, message: &str) -> w::Forked {
    fork(
        &fx.front,
        &user(),
        w::ForkParams {
            session: sid.into(),
            seq,
            message: message.into(),
            profile: None,
        },
    )
    .await
    .expect("a fork")
}

/// SID's steps: `(seq, message_id, start, end)`.
async fn steps(fx: &Fx, sid: &str) -> Vec<(i64, Option<String>, f64, Option<f64>)> {
    let key = format!("session:{sid}");
    fx.front
        .writer
        .db
        .read(move |c| norn::read::steps::for_session(c, &key, 0))
        .await
        .unwrap()
        .into_iter()
        .map(|s| (s.seq, s.message_id, s.start, s.end))
        .collect()
}

/// The records of KIND in every project's history.
fn records(fx: &Fx, kind: verdandi::Kind) -> Vec<verdandi::OpRecord> {
    let mut out = Vec::new();
    for hub in fx.front.core.history.all(&fx.front.dirs.get().unwrap().hub) {
        hub.with(|h| {
            for id in 1..=h.count("op").unwrap() {
                let r = h.op(verdandi::OpId(id)).unwrap();
                if r.kind == kind {
                    out.push(r);
                }
            }
        });
    }
    out
}

/// The second agent starts from the step: its tree is the step's checkpoint, its conversation is the source's forked
/// at the step's message and told the user's message, the source runs on untouched, and the history has one fork.
#[tokio::test(flavor = "multi_thread")]
async fn second_agent_runs_from_the_checkpoint() {
    let l = Live::new().await;
    let edited = l.fx.read("a.txt");
    let src_acp = row_acp(&l.fx, &l.sid).await.unwrap();
    let f = fork_at(&l.fx, &l.sid, l.target, "try it the other way").await;
    assert_ne!(f.id, l.sid);
    assert_eq!(f.level, RestoreLevel::Message);
    assert_ne!(f.branch, f.source_branch);
    assert_eq!(
        std::fs::read_to_string(Path::new(&f.path).join("a.txt")).unwrap(),
        FIVE
    );
    assert_eq!(l.fx.read("a.txt"), edited, "the source's files stay");
    // the cut: the last message at or before the step
    let cut = steps(&l.fx, &l.sid)
        .await
        .into_iter()
        .filter(|s| s.0 <= l.target)
        .filter_map(|s| s.1)
        .next_back();
    let forks = l.fx.logged("a.log", "session/fork");
    assert_eq!(forks.len(), 1, "{forks:?}");
    assert_eq!(
        (&forks[0]["from"], &forks[0]["messageId"]),
        (&json!(src_acp), &json!(cut))
    );
    let b = row_acp(&l.fx, &f.id).await.unwrap();
    let prompts = prompted(&l.fx, "try it the other way").await;
    assert!(
        prompts
            .iter()
            .any(|p| p["sessionId"] == json!(b) && p["text"] == json!("try it the other way")),
        "{prompts:?}"
    );
    let src = l.fx.front.core.agents.find(&l.sid).unwrap();
    assert!(!src.is_closed());
    assert_eq!(
        row_acp(&l.fx, &l.sid).await.as_deref(),
        Some(src_acp.as_str())
    );
    assert_eq!(records(&l.fx, verdandi::Kind::Fork).len(), 1);
}

/// A Codex fork in its new tree marks that tree untrusted, so a `.codex/config.toml` there is not loaded as the user's
/// (codex-acp reads `projects."<cwd>".trust_level`; the lock puts it in the `CODEX_CONFIG` its process starts with, and
/// the mock logs that config).
#[tokio::test(flavor = "multi_thread")]
async fn codex_new_cwd_is_marked_untrusted() {
    let fx = Fx::new();
    repo(&fx);
    let sid = start_as(&fx, "mock-codex").await;
    turn(&fx.front, &sid, "zero").await;
    let target = turn(&fx.front, &sid, "one").await;
    let f = fork_at(&fx, &sid, target, "go on").await;
    let configs = fx.logged("c.log", "codex_config");
    assert_eq!(
        configs
            .last()
            .map(|c| &c["config"]["projects"][f.path.as_str()]["trust_level"]),
        Some(&json!("untrusted")),
        "{} in {configs:?}",
        f.path
    );
}

/// The entities of a task, a job, a proposal or an exec, and the `jtask` rows: what a fork never makes.
async fn work_rows(fx: &Fx) -> (i64, i64) {
    fx.front
        .writer
        .db
        .read(|c| {
            let ents = c.query_row(
                "select count(*) from entity where kind in ('task', 'job', 'proposal', 'exec', 'card')",
                [],
                |r| r.get(0),
            )?;
            let tasks = c
                .query_row("select count(*) from jtask", [], |r| r.get(0))
                .unwrap_or(0);
            Ok((ents, tasks))
        })
        .await
        .unwrap()
}

/// A fork is the user's own act: no task, no job, no proposal or card, and the new session works on nothing.
#[tokio::test(flavor = "multi_thread")]
async fn has_no_task_or_job() {
    let l = Live::new().await;
    let before = work_rows(&l.fx).await;
    let f = fork_at(&l.fx, &l.sid, l.target, "go on").await;
    assert_eq!(work_rows(&l.fx).await, before);
    assert!(l.fx.front.core.exec.list(Some(&f.id), false).is_empty());
    let key = format!("session:{}", f.id);
    let works_on: i64 =
        l.fx.front
            .writer
            .db
            .read(move |c| {
                Ok(c.query_row(
                    "select count(*) from link l join entity s on s.n = l.src \
                 where s.id = ?1 and l.kind = 'works_on'",
                    [&key],
                    |r| r.get(0),
                )?)
            })
            .await
            .unwrap();
    assert_eq!(works_on, 0);
}

/// A fork whose branches differ in `b.txt`.
struct Two {
    fx: Fx,
    sid: String,
    f: w::Forked,
}

/// The source agent (a worker) wrote `b.txt` as "one\n" in the turn before the step and "one\ntwo\n" in the turn after
/// it; the fork's agent wrote "one\nthree\n" in its tree in its first turn.  Every write is the agent's own
/// `fs/write_text_file`, served and recorded by the session's handler.
async fn two() -> Two {
    let fx = Fx::new();
    repo(&fx);
    let sid = start_in(&fx, "mock-claude", Some("worker")).await;
    turn(&fx.front, &sid, "fs:write b.txt one\\n").await;
    assert_eq!(fx.read("b.txt"), "one\n", "the handler wrote it");
    let target = turn(&fx.front, &sid, "one").await;
    turn(&fx.front, &sid, "fs:write b.txt one\\ntwo\\n").await;
    let mut steps = fx.front.core.agents.subscribe_steps();
    let f = fork_at(&fx, &sid, target, "fs:write b.txt one\\nthree\\n").await;
    turn_end(&mut steps, &f.id).await;
    assert_eq!(
        std::fs::read_to_string(Path::new(&f.path).join("b.txt")).unwrap(),
        "one\nthree\n",
        "the fork's agent wrote over the checkpoint"
    );
    Two { fx, sid, f }
}

/// Every write the handler serves is in the history before the file is written: one `agent_step` record per write,
/// by the agent's peer, caused by its session, the document's text the written text.
#[tokio::test(flavor = "multi_thread")]
async fn the_handlers_writes_are_the_agents_records() {
    let t = two().await;
    let mine: Vec<_> = records(&t.fx, verdandi::Kind::AgentStep)
        .into_iter()
        .filter(|r| r.cause.session.as_deref() == Some(t.sid.as_str()))
        .collect();
    assert_eq!(mine.len(), 2, "{mine:?}");
    let dirs = t.fx.front.dirs.get().unwrap();
    let (hub, tree) =
        t.fx.front
            .core
            .history
            .of_tree(&dirs.hub, &t.fx.work())
            .unwrap();
    assert_eq!(
        hub.text(&tree, "b.txt").unwrap().as_deref(),
        Some("one\ntwo\n")
    );
    let author = hub.with(|h| h.author_of(mine[0].author).unwrap().unwrap());
    assert_eq!(author, json!({"kind": "agent", "session": t.sid}));
}

async fn compared(t: &Two, a: &str, b: &str) -> w::Compared {
    compare(
        &t.fx.front,
        &user(),
        w::CompareParams {
            a: a.into(),
            b: b.into(),
        },
    )
    .await
    .unwrap()
}

/// Compare names, per hunk, who wrote the text and in which record and step: the fork's agent for the fork's text,
/// the source's for the source's.
#[tokio::test(flavor = "multi_thread")]
async fn compare_names_author_and_step() {
    let t = two().await;
    let c = compared(&t, &t.f.source_branch, &t.f.branch).await;
    assert_eq!(c.files.len(), 1, "{c:?}");
    assert_eq!(c.files[0].path, "b.txt");
    let [h] = &c.files[0].hunks[..] else {
        panic!("one hunk: {c:?}")
    };
    assert_eq!(
        (h.ours_text.as_str(), h.theirs_text.as_str()),
        ("two\n", "three\n")
    );
    assert_eq!(h.author, Some(json!({"kind": "agent", "session": t.f.id})));
    // the write's step is not known yet when it is recorded (its row is written when the step ends): its session is
    assert_eq!(h.session.as_deref(), Some(t.f.id.as_str()));
    assert!(h.record.is_some());
    let back = compared(&t, &t.f.branch, &t.f.source_branch).await;
    let h = &back.files[0].hunks[0];
    assert_eq!(h.theirs_text, "two\n");
    assert_eq!(h.author, Some(json!({"kind": "agent", "session": t.sid})));
    assert_eq!(h.session.as_deref(), Some(t.sid.as_str()));
}

/// Dropping a fork stops its agent and removes its tree; its branch is frozen, kept for compare.
#[tokio::test(flavor = "multi_thread")]
async fn drop_frees_the_tree_and_keeps_compare() {
    let t = two().await;
    let before = compared(&t, &t.f.source_branch, &t.f.branch).await;
    drop_fork(
        &t.fx.front,
        &user(),
        w::ForkDropParams { id: t.f.id.clone() },
    )
    .await
    .unwrap();
    assert!(!Path::new(&t.f.path).exists());
    assert_eq!(
        row_acp(&t.fx, &t.f.id).await,
        None,
        "the fork's agent ended"
    );
    let listed = git(&t.fx.work(), &["worktree", "list", "--porcelain"]);
    assert!(!listed.contains(&t.f.path), "{listed}");
    assert_eq!(compared(&t, &t.f.source_branch, &t.f.branch).await, before);
    let frozen = records_pins(&t.fx)
        .into_iter()
        .any(|p| p.name == t.f.branch && p.kind == verdandi::PinKind::Frozen);
    assert!(frozen, "the fork's branch is frozen");
    assert!(!t.fx.front.core.agents.find(&t.sid).unwrap().is_closed());
    // the source is no fork
    let r = drop_fork(
        &t.fx.front,
        &user(),
        w::ForkDropParams { id: t.sid.clone() },
    )
    .await;
    assert!(r.is_err(), "{r:?}");
}

fn records_pins(fx: &Fx) -> Vec<verdandi::Pin> {
    fx.front
        .core
        .history
        .all(&fx.front.dirs.get().unwrap().hub)
        .iter()
        .flat_map(|h| h.with(|h| h.pins().unwrap()))
        .collect()
}

/// Take across: a whole hunk of the fork into the source's tree as the user's new text; part of a hunk is refused,
/// and a file that differs from its history on disk is never overwritten.
#[tokio::test(flavor = "multi_thread")]
async fn take_writes_whole_hunks_into_the_worktree() {
    let t = two().await;
    let wt = t.fx.work();
    let c = compared(&t, &t.f.source_branch, &t.f.branch).await;
    let h = &c.files[0].hunks[0];
    let taking = |end: i64| w::TakeParams {
        from: t.f.branch.clone(),
        worktree: wt.to_string_lossy().into_owned(),
        hunks: vec![w::TakeHunk {
            path: "b.txt".into(),
            theirs_start: h.theirs_start,
            theirs_end: end,
        }],
    };
    let part = take(&t.fx.front, &user(), taking(h.theirs_end - 1)).await;
    assert!(part.is_err(), "{part:?}");
    std::fs::write(wt.join("b.txt"), "mine\n").unwrap();
    let r = take(&t.fx.front, &user(), taking(h.theirs_end)).await;
    assert!(
        r.as_ref().is_err_and(|e| e.message.contains("stale")),
        "{r:?}"
    );
    assert_eq!(t.fx.read("b.txt"), "mine\n");
    std::fs::write(wt.join("b.txt"), "one\ntwo\n").unwrap();
    let r = take(&t.fx.front, &user(), taking(h.theirs_end))
        .await
        .unwrap();
    assert_eq!(r.written, ["b.txt"]);
    assert_eq!(t.fx.read("b.txt"), "one\nthree\n");
    let merges = records(&t.fx, verdandi::Kind::Merge);
    assert!(merges.iter().any(|m| m.id.0 == r.op), "{merges:?}");
}

async fn reverted(l: &Live) -> w::Applied {
    let card = l.preview().await;
    apply(
        &l.fx.front,
        &user(),
        w::RevertApplyParams {
            preview_id: card.preview_id,
            mode: None,
            choices: vec![],
            message: None,
        },
    )
    .await
    .unwrap()
}

async fn redone(l: &Live, op: i64) -> w::Redone {
    redo(
        &l.fx.front,
        &user(),
        w::RedoParams {
            session: l.sid.clone(),
            op,
        },
    )
    .await
    .unwrap()
}

/// Redo puts back what the revert undid, merged with the user's later edit that does not meet it: one `redo` record
/// naming the revert, one forward commit, and the agent told by a message (its conversation is not restored).
#[tokio::test(flavor = "multi_thread")]
async fn redo_puts_back_what_the_revert_undid() {
    let l = Live::new().await;
    let edited = l.fx.read("a.txt");
    let a = reverted(&l).await;
    assert_eq!(l.fx.read("a.txt"), FIVE);
    std::fs::write(l.wt().join("a.txt"), FIVE.replace("l1", "L1")).unwrap();
    let head = crate::timeline::snapshot::head_of(&l.wt());
    let r = redone(&l, a.op).await;
    assert_eq!(l.fx.read("a.txt"), edited.replace("l1", "L1"));
    assert_eq!(r.written, ["a.txt"]);
    assert!(r.commit.is_some() && crate::timeline::snapshot::head_of(&l.wt()) != head);
    let redo = records(&l.fx, verdandi::Kind::Redo);
    assert_eq!(redo.len(), 1);
    assert_eq!(redo[0].parents, [verdandi::OpId(a.op)]);
    assert_eq!(redo[0].id.0, r.op);
    let acp = row_acp(&l.fx, &l.sid).await.unwrap();
    let prompts = prompted(&l.fx, "redid").await;
    assert!(
        prompts.iter().any(|p| p["sessionId"] == json!(acp)
            && p["text"].as_str().is_some_and(|t| t.contains("redid"))),
        "{prompts:?}"
    );
}

/// A later edit of the user's that meets what the redo would put back stays, listed `edited-later`.
#[tokio::test(flavor = "multi_thread")]
async fn redo_keeps_the_users_conflicting_edit() {
    let l = Live::new().await;
    let a = reverted(&l).await;
    let mine = format!("{FIVE}mine\n");
    std::fs::write(l.wt().join("a.txt"), &mine).unwrap();
    let r = redone(&l, a.op).await;
    assert_eq!(l.fx.read("a.txt"), mine);
    assert!(r.written.is_empty(), "{r:?}");
    assert_eq!(
        r.skipped,
        [w::RevertSkipped {
            path: "a.txt".into(),
            reason: "edited-later".into()
        }]
    );
    // only a revert is redone
    let other = redo(
        &l.fx.front,
        &user(),
        w::RedoParams {
            session: l.sid.clone(),
            op: r.op,
        },
    )
    .await;
    assert!(other.is_err(), "{other:?}");
}
