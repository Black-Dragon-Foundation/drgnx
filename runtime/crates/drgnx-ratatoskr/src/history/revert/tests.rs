//! Revert to here on a store, a repository and the checkpoints, with no agent process (pattern D: each step's I/O is
//! awaited in turn; nothing races).  The source is a finished worker (an entity, no row), so the conversation is not
//! restored and no session runs.
//!
//! The work: a repository with `a.txt` (five lines) at commit H0; step 2's checkpoint is H0's files; the agent then
//! changes `a.txt`'s first line and adds `b.txt` in step 3 (checkpointed), and commits it (H1) unless told not to.

use super::*;
use crate::dispatch::Caller;
use runstav::registry::Class;
use std::path::Path;

const FIVE: &str = "l1\nl2\nl3\nl4\nl5\n";
const AGENT: &str = "A1\nl2\nl3\nl4\nl5\n";

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn user() -> Caller {
    Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    }
}

struct Fx {
    _d: tempfile::TempDir,
    f: Front,
    root: PathBuf,
    wt: PathBuf,
}

impl Fx {
    /// The work above; COMMIT: the agent commits step 3 (the head moves).  SNAPSHOT: step 2 has its checkpoint.
    async fn new(commit: bool, snapshot: bool) -> Fx {
        let d = tempfile::tempdir().unwrap();
        let f = crate::runner::graph_plan_tests::front(d.path());
        for s in ["home", "config", "hub"] {
            std::fs::create_dir_all(d.path().join(s)).unwrap();
        }
        let _ = f.dirs.set(crate::graph::StoreDirs {
            home: d.path().join("home"),
            config: d.path().join("config"),
            hub: d.path().join("hub"),
        });
        let root = d.path().join("hub").join("checkpoints");
        let wt = d.path().join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        sh(&wt, &["init", "-q", "-b", "main"]);
        std::fs::write(wt.join("a.txt"), FIVE).unwrap();
        sh(&wt, &["add", "-A"]);
        sh(&wt, &["commit", "-q", "-m", "base"]);
        let h0 = sh(&wt, &["rev-parse", "HEAD"]);
        let cp2 = snapshot::take(&root, &wt, "s1", 2, &[]).unwrap();
        std::fs::write(wt.join("a.txt"), AGENT).unwrap();
        std::fs::write(wt.join("b.txt"), "agent's\n").unwrap();
        if commit {
            sh(&wt, &["add", "-A"]);
            sh(&wt, &["commit", "-q", "-m", "agent"]);
        }
        let cp3 = snapshot::take(&root, &wt, "s1", 3, &[]).unwrap();
        let h3 = sh(&wt, &["rev-parse", "HEAD"]);
        let cwd = wt.to_string_lossy().into_owned();
        let cp2 = snapshot.then_some(cp2);
        f.writer
            .db
            .write(
                urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "test"),
                move |tx| {
                    let project = tx.meta().project;
                    let e = |id: &str, kind: &str, data| urdr::graph::entity::EntityNew {
                        id: id.into(),
                        kind: kind.into(),
                        project,
                        title: None,
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data,
                        origin: urdr::graph::entity::Origin::Recorded,
                        source: None,
                    };
                    urdr::graph::entity::create(
                        tx,
                        e(
                            "session:s1",
                            "session",
                            json!({"profile": "mock", "cwd": cwd, "role": "worker"}),
                        ),
                    )?;
                    tx.sql().execute(
                        "insert into step (session, seq, class, start, snapshot, head) values \
                         ('session:s1', 1, 'tool', 1.0, null, ?1), ('session:s1', 2, 'tool', 2.0, ?2, ?1), \
                         ('session:s1', 3, 'tool', 3.0, ?3, ?4)",
                        (&h0, &cp2, &cp3, &h3),
                    )?;
                    let step = |seq: i64| -> i64 {
                        tx.sql()
                            .query_row(
                                "select id from step where session = 'session:s1' and seq = ?1",
                                [seq],
                                |r| r.get(0),
                            )
                            .unwrap()
                    };
                    let (s2, s3) = (step(2), step(3));
                    urdr::graph::entity::create(
                        tx,
                        e(
                            "decision:1",
                            "decision",
                            json!({"session": "s1", "step": s2, "text": "kept"}),
                        ),
                    )?;
                    urdr::graph::entity::create(
                        tx,
                        e(
                            "decision:2",
                            "decision",
                            json!({"session": "s1", "step": s3, "text": "goes"}),
                        ),
                    )?;
                    Ok(())
                },
            )
            .await
            .unwrap();
        Fx { _d: d, f, root, wt }
    }

    async fn preview(&self) -> Result<w::RevertCard, Error> {
        preview(
            &self.f,
            &user(),
            w::RevertPreviewParams {
                session: Some("s1".into()),
                seq: Some(2),
                decision: None,
            },
        )
        .await
    }

    async fn apply(
        &self,
        id: i64,
        mode: Option<RevertMode>,
        choices: Vec<RevertChoice>,
    ) -> Result<w::Applied, Error> {
        apply(
            &self.f,
            &user(),
            w::RevertApplyParams {
                preview_id: id,
                mode,
                choices,
                message: None,
            },
        )
        .await
    }

    fn read(&self, rel: &str) -> Option<String> {
        std::fs::read_to_string(self.wt.join(rel)).ok()
    }

    async fn status_of(&self, n: i64) -> Option<String> {
        let id = format!("decision:{n}");
        self.f
            .writer
            .db
            .read(move |c| Ok(urdr::graph::entity::by_id(c, &id)?.and_then(|e| e.status)))
            .await
            .unwrap()
    }

    async fn undone(&self) -> Vec<i64> {
        self.f
            .writer
            .db
            .read(|c| {
                let mut q = c.prepare(
                    "select seq from step where session = 'session:s1' and undone_by is not null order by seq",
                )?;
                let v = q
                    .query_map([], |r| r.get(0))?
                    .collect::<Result<Vec<i64>, _>>()?;
                Ok(v)
            })
            .await
            .unwrap()
    }

    fn pending(&self) -> Vec<(verdandi::OpId, String)> {
        let dirs = self.f.dirs.get().unwrap();
        let (hub, _) = self.f.core.history.of_tree(&dirs.hub, &self.wt).unwrap();
        hub.lock().h.pending().unwrap()
    }
}

/// A finished worker's revert: the files back at the step, the decision after it withdrawn and the one at it kept,
/// the later step marked undone, one forward commit, the conversation not restored with the label, a fork offered.
#[tokio::test(flavor = "multi_thread")]
async fn a_finished_worker_reverts_code_decisions_and_commit() {
    let fx = Fx::new(true, true).await;
    let card = fx.preview().await.unwrap();
    assert_eq!(
        card.conversation,
        w::ConversationRestore::NotRestored {
            label: FINISHED.into()
        }
    );
    assert!(card.fork && card.blocked.is_empty() && card.overlaps.is_empty());
    assert_eq!(card.files, ["a.txt", "b.txt"]);
    let head = snapshot::head_of(&fx.wt);
    let a = fx.apply(card.preview_id, None, vec![]).await.unwrap();
    assert_eq!(fx.read("a.txt").as_deref(), Some(FIVE));
    assert_eq!(fx.read("b.txt"), None);
    assert_eq!(fx.status_of(2).await.as_deref(), Some("withdrawn"));
    assert_eq!(fx.status_of(1).await, None);
    assert_eq!(fx.undone().await, [3]);
    assert!(a.commit.is_some() && a.commit != head, "{a:?}");
    assert_eq!(sh(&fx.wt, &["rev-list", "--count", "HEAD"]), "3");
    assert_eq!(sh(&fx.wt, &["status", "--porcelain"]), "");
    assert_eq!(a.conversation, card.conversation);
    assert!(fx.pending().is_empty());
}

/// The head did not move after the step (the agent committed nothing): the files go back and nothing is committed.
#[tokio::test(flavor = "multi_thread")]
async fn no_commit_when_head_is_unchanged() {
    let fx = Fx::new(false, true).await;
    let head = snapshot::head_of(&fx.wt);
    let card = fx.preview().await.unwrap();
    let a = fx.apply(card.preview_id, None, vec![]).await.unwrap();
    assert_eq!(a.commit, None);
    assert_eq!(snapshot::head_of(&fx.wt), head);
    assert_eq!(fx.read("a.txt").as_deref(), Some(FIVE));
}

/// The commits after the step become one forward commit: the agent's commit stays in the log, and the new one undoes
/// it.
#[tokio::test(flavor = "multi_thread")]
async fn commits_after_the_step_get_one_forward_commit() {
    let fx = Fx::new(true, true).await;
    let card = fx.preview().await.unwrap();
    let a = fx.apply(card.preview_id, None, vec![]).await.unwrap();
    let log = sh(&fx.wt, &["log", "--format=%s"]);
    assert_eq!(log, "revert to step 2 of session s1\nagent\nbase");
    assert_eq!(a.commit, snapshot::head_of(&fx.wt));
}

/// The user edited a line the agent did not touch after the agent's last step: the revert merges, so the agent's line
/// goes back and the user's edit stays.  The file is listed as edited later without overlapping.
#[tokio::test(flavor = "multi_thread")]
async fn users_later_edit_is_merged_not_overwritten() {
    let fx = Fx::new(false, true).await;
    std::fs::write(fx.wt.join("a.txt"), "A1\nl2\nl3\nl4\nU5\n").unwrap();
    let card = fx.preview().await.unwrap();
    assert_eq!(card.non_overlapping_files, ["a.txt"]);
    assert!(card.overlaps.is_empty());
    let a = fx.apply(card.preview_id, None, vec![]).await.unwrap();
    assert_eq!(fx.read("a.txt").as_deref(), Some("l1\nl2\nl3\nl4\nU5\n"));
    assert!(a.skipped.is_empty(), "{:?}", a.skipped);
}

/// The user edited the agent's own line after it: an overlap.  With no answer the user's file stays as it is (never
/// overwritten) and is listed; taking the reverted file writes the step's, and the user's version is kept under the
/// record's `undone` ref.
#[tokio::test(flavor = "multi_thread")]
async fn users_conflicting_edit_is_kept_unless_chosen() {
    let fx = Fx::new(false, true).await;
    let mine = "U1\nl2\nl3\nl4\nl5\n";
    std::fs::write(fx.wt.join("a.txt"), mine).unwrap();
    let card = fx.preview().await.unwrap();
    assert_eq!(card.overlaps.len(), 1);
    assert_eq!(card.overlaps[0].path, "a.txt");
    assert_eq!(card.overlaps[0].users.as_deref(), Some(mine));
    assert_eq!(card.overlaps[0].reverted.as_deref(), Some(FIVE));
    let a = fx.apply(card.preview_id, None, vec![]).await.unwrap();
    assert_eq!(fx.read("a.txt").as_deref(), Some(mine));
    assert!(
        a.skipped
            .iter()
            .any(|s| s.path == "a.txt" && s.reason == "edited-later"),
        "{:?}",
        a.skipped
    );
    // the agent's b.txt went all the same
    assert_eq!(fx.read("b.txt"), None);

    // again, taking the reverted file: the user's version is kept under undone
    let fx = Fx::new(false, true).await;
    std::fs::write(fx.wt.join("a.txt"), mine).unwrap();
    let card = fx.preview().await.unwrap();
    let a = fx
        .apply(card.preview_id, None, vec![RevertChoice::TakeReverted])
        .await
        .unwrap();
    assert_eq!(fx.read("a.txt").as_deref(), Some(FIVE));
    let kept = snapshot::blob(&fx.root, &fx.wt, &a.undone, "a.txt").unwrap();
    assert_eq!(String::from_utf8(kept).unwrap(), mine);
}

/// An edited answer writes the user's text in the overlap's place.
#[tokio::test(flavor = "multi_thread")]
async fn an_edited_answer_writes_its_text() {
    let fx = Fx::new(false, true).await;
    std::fs::write(fx.wt.join("a.txt"), "U1\nl2\nl3\nl4\nl5\n").unwrap();
    let card = fx.preview().await.unwrap();
    fx.apply(
        card.preview_id,
        None,
        vec![RevertChoice::Edited {
            text: "E1\n".into(),
        }],
    )
    .await
    .unwrap();
    assert_eq!(fx.read("a.txt").as_deref(), Some("E1\n"));
}

/// Roll back mine too: every file goes back to the step, and what the user had is kept under `undone`.
#[tokio::test(flavor = "multi_thread")]
async fn roll_back_mine_keeps_the_users_version_under_undone() {
    let fx = Fx::new(false, true).await;
    let mine = "A1\nl2\nl3\nl4\nU5\n";
    std::fs::write(fx.wt.join("a.txt"), mine).unwrap();
    let card = fx.preview().await.unwrap();
    let a = fx
        .apply(card.preview_id, Some(RevertMode::RollBackMine), vec![])
        .await
        .unwrap();
    assert_eq!(fx.read("a.txt").as_deref(), Some(FIVE));
    let kept = snapshot::blob(&fx.root, &fx.wt, &a.undone, "a.txt").unwrap();
    assert_eq!(String::from_utf8(kept).unwrap(), mine);
}

/// The files moved after the preview (the user typed): `stale`, and nothing was written or recorded.
#[tokio::test(flavor = "multi_thread")]
async fn stale_preview_is_refused() {
    let fx = Fx::new(false, true).await;
    let card = fx.preview().await.unwrap();
    std::fs::write(fx.wt.join("c.txt"), "typed\n").unwrap();
    let e = fx.apply(card.preview_id, None, vec![]).await.unwrap_err();
    assert!(e.message.starts_with("stale:"), "{e:?}");
    assert_eq!(fx.read("a.txt").as_deref(), Some(AGENT));
    assert_eq!(fx.status_of(2).await, None);
    assert!(fx.undone().await.is_empty());
    // a preview is used once
    let e = fx.apply(card.preview_id, None, vec![]).await.unwrap_err();
    assert!(e.message.starts_with("stale:"), "{e:?}");
}

/// An agent's own connection cannot preview or apply a revert.
#[tokio::test(flavor = "multi_thread")]
async fn agent_class_is_refused() {
    let fx = Fx::new(false, true).await;
    let agent = Caller {
        class: Class::Agent,
        sid: Some("s1".into()),
        job: None,
        conn_id: 2,
    };
    let p = w::RevertPreviewParams {
        session: Some("s1".into()),
        seq: Some(2),
        decision: None,
    };
    let e = preview(&fx.f, &agent, p).await.unwrap_err();
    assert!(e.message.starts_with("not-revertible:"), "{e:?}");
}

/// A step with no checkpoint is older than the history: refused before anything is kept.
#[tokio::test(flavor = "multi_thread")]
async fn older_than_the_history_is_refused() {
    let fx = Fx::new(false, false).await;
    // the snapshots' refs of step 2 go too: nothing holds that step
    sh(
        &snapshot::repo_of(&fx.root, &fx.wt),
        &["update-ref", "-d", "refs/drgnx/s/s1/2"],
    );
    let e = fx.preview().await.unwrap_err();
    assert!(e.message.starts_with("not-revertible:"), "{e:?}");
}

/// A decision names the step it was recorded in: the preview by decision is the step's.
#[tokio::test(flavor = "multi_thread")]
async fn preview_by_decision_is_its_step() {
    let fx = Fx::new(false, true).await;
    let card = preview(
        &fx.f,
        &user(),
        w::RevertPreviewParams {
            session: None,
            seq: None,
            decision: Some(1),
        },
    )
    .await
    .unwrap();
    assert_eq!((card.session.as_str(), card.seq), ("s1", 2));
}

/// A crash after the record (pending kept, nothing else done): the next start finishes it once, and finishing again
/// changes nothing.
#[tokio::test(flavor = "multi_thread")]
async fn a_pending_revert_is_finished_at_start_once() {
    let fx = Fx::new(true, true).await;
    let card = fx.preview().await.unwrap();
    let plan = fx.f.core.history.reverts.take(card.preview_id).unwrap();
    let saved = Saved {
        plan,
        mode: RevertMode::KeepMine,
        choices: vec![],
        message: None,
        acp_before: None,
    };
    // the steps up to the record, as a crash leaves them
    let op = record(&fx.f, &saved).await.unwrap();
    assert_eq!(fx.pending().first().map(|(o, _)| o.0), Some(op));
    assert_eq!(fx.read("a.txt").as_deref(), Some(AGENT));
    finish_pending(&fx.f).await;
    assert!(fx.pending().is_empty());
    assert_eq!(fx.read("a.txt").as_deref(), Some(FIVE));
    assert_eq!(fx.undone().await, [3]);
    let head = snapshot::head_of(&fx.wt);
    assert_eq!(sh(&fx.wt, &["rev-list", "--count", "HEAD"]), "3");
    finish_pending(&fx.f).await;
    assert_eq!(snapshot::head_of(&fx.wt), head);
    assert_eq!(fx.status_of(2).await.as_deref(), Some("withdrawn"));
}
