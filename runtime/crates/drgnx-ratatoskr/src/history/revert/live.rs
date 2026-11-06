//! Revert to here on a live session of the mock agent (`ratatoskr-mock acp --state`, real processes) in a real git
//! tree (pattern C): a test hook parks the revert after a named step and announces it; the test reads what holds
//! there and lets it go on, or ends it there as a crash does, and a second hub on the same stores finishes it.
//!
//! The work: a repository with `a.txt` at its first commit; turn one of the session says something (its first step
//! is the checkpoint the revert goes back to), turn two edits `a.txt` and commits it.

use super::*;
use crate::agents::session::attach_tests::Fx;
use crate::exec::{CheckKind, ExecSpec, Starter, UserJob};
use runstav::methods::agents::StartParams;
use runstav::methods::exec::ExecStatus;
use std::time::Duration;
use tokio::sync::oneshot;

const FIVE: &str = "l1\nl2\nl3\nl4\nl5\n";

fn git(dir: &Path, args: &[&str]) -> String {
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
    crate::runner::user()
}

/// The next step of SID that ends a turn, from STEPS: its `seq`.
async fn turn_end(
    steps: &mut tokio::sync::broadcast::Receiver<crate::agents::StepEvent>,
    sid: &str,
) -> i64 {
    loop {
        let s = crate::clock::timeout(Duration::from_secs(60), steps.recv())
            .await
            .expect("a step in time")
            .expect("the step bus");
        if s.session == sid && s.step.turn_id.is_some() {
            return s.step.seq as i64;
        }
    }
}

/// One turn of TEXT in SID of FRONT, to its end: the `seq` of its last step.
async fn turn(f: &Front, sid: &str, text: &str) -> i64 {
    let mut steps = f.core.agents.subscribe_steps();
    f.core.agents.send(sid, text.into()).unwrap();
    turn_end(&mut steps, sid).await
}

/// The values of KEY in the mock's log A.
fn logged(fx: &Fx, key: &str) -> Vec<serde_json::Value> {
    fx.logged("a.log", key)
}

/// The mock's prompts once one says TEXT.
async fn prompted(fx: &Fx, text: &'static str) -> Vec<serde_json::Value> {
    let path = fx.dir.path().join("a.log");
    crate::clock::blocking(move || {
        skuld::wait_until(&format!("the mock is prompted {text:?}"), 60, || {
            let all: Vec<serde_json::Value> = std::fs::read_to_string(&path)
                .unwrap_or_default()
                .lines()
                .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                .filter_map(|v| v.get("prompt").cloned())
                .collect();
            all.iter()
                .any(|p| p["text"].as_str().is_some_and(|t| t.contains(text)))
                .then_some(all)
        })
    })
    .await
    .unwrap()
}

async fn row_acp(fx: &Fx, sid: &str) -> Option<String> {
    let s = sid.to_owned();
    fx.runtime
        .read(move |c| {
            Ok(
                c.query_row("select acp from asession where sid = ?1", [&s], |r| {
                    r.get(0)
                })
                .ok(),
            )
        })
        .await
        .unwrap()
}

/// A live session in a repository: its sid and the step turn one ended at.
struct Live {
    fx: Fx,
    sid: String,
    target: i64,
}

impl Live {
    async fn new() -> Live {
        let fx = Fx::new();
        let wt = fx.work();
        git(&wt, &["init", "-q", "-b", "main"]);
        std::fs::write(wt.join("a.txt"), FIVE).unwrap();
        git(&wt, &["add", "-A"]);
        git(&wt, &["commit", "-q", "-m", "base"]);
        let sid = start(&fx, None).await;
        // the session's first checkpoint is not always taken (a separate finding): the target is turn two's
        turn(&fx.front, &sid, "zero").await;
        let target = turn(&fx.front, &sid, "one").await;
        turn(&fx.front, &sid, "tool:edit a.txt\ncommit agent").await;
        assert_ne!(fx.read("a.txt"), FIVE, "the agent's edit");
        Live { fx, sid, target }
    }

    fn wt(&self) -> PathBuf {
        self.fx.work()
    }

    async fn preview(&self) -> w::RevertCard {
        let r = preview(
            &self.fx.front,
            &user(),
            w::RevertPreviewParams {
                session: Some(self.sid.clone()),
                seq: Some(self.target),
                decision: None,
            },
        )
        .await;
        match r {
            Ok(card) => card,
            Err(e) => {
                let key = format!("session:{}", self.sid);
                let steps = self
                    .fx
                    .front
                    .writer
                    .db
                    .read(move |c| norn::read::steps::for_session(c, &key, 0))
                    .await
                    .unwrap();
                let shown: Vec<_> = steps
                    .iter()
                    .map(|s| (s.seq, s.class, s.snapshot.clone(), s.turn_id.clone()))
                    .collect();
                let root = self.fx.dir.path().join("hub").join("checkpoints");
                let refs = snapshot::repo_of(&root, &self.wt());
                let listed = std::process::Command::new("git")
                    .args(["for-each-ref"])
                    .current_dir(&refs)
                    .output()
                    .map(|o| String::from_utf8_lossy(&o.stdout).into_owned());
                panic!(
                    "{e:?}: target {} steps {shown:?} refs {listed:?}",
                    self.target
                )
            }
        }
    }

    /// Apply a fresh preview; the hook parks it after AFTER, where CHECK runs, and GO says whether it goes on.
    async fn apply_parked<C, Fut>(
        &self,
        after: RevertStep,
        go: bool,
        check: C,
    ) -> Result<w::Applied, Error>
    where
        C: FnOnce() -> Fut,
        Fut: std::future::Future<Output = ()>,
    {
        let card = self.preview().await;
        let (reached_tx, reached) = oneshot::channel();
        let (go_tx, go_rx) = oneshot::channel();
        *lock(&self.fx.front.core.history.reverts.park) = Some(Park {
            after,
            reached: reached_tx,
            go: go_rx,
        });
        let me = user();
        let applying = apply(
            &self.fx.front,
            &me,
            w::RevertApplyParams {
                preview_id: card.preview_id,
                mode: None,
                choices: vec![],
                message: None,
            },
        );
        let parked = async {
            reached.await.expect("the revert parks");
            check().await;
            go_tx.send(go).unwrap();
        };
        let (a, ()) = tokio::join!(applying, parked);
        a
    }

    /// The hub dies at the park: its agent is gone with it (the row stays), and a second hub on the same stores
    /// finishes the revert at its start.
    async fn crash_and_restart(&self) -> Front {
        if let Ok(s) = self.fx.front.core.agents.find(&self.sid) {
            s.close_now().await;
        }
        self.second().await
    }

    async fn second(&self) -> Front {
        let p = |s: &str| self.fx.dir.path().join(s);
        let f = Front::new(
            runstav::proof::Cap::generate().unwrap(),
            p("hub-y.sock"),
            crate::store::WorkDb::spawn(p("work.db")).unwrap(),
            norn::store::CoordDb::spawn(p("work.db")),
        );
        f.settings.open(p("config"), self.fx.runtime.clone());
        let _ = f.dirs.set(crate::graph::StoreDirs {
            home: p("home"),
            config: p("config"),
            hub: p("hub"),
        });
        f.core.agents.open_store(self.fx.runtime.clone());
        f.refresh_settings().await;
        f
    }

    /// The revert records of the session in the project's history.
    fn reverts(&self, f: &Front) -> usize {
        let dirs = f.dirs.get().unwrap();
        let (hub, _) = f.core.history.of_tree(&dirs.hub, &self.wt()).unwrap();
        let g = hub.lock();
        g.h.caused_by(&self.sid, 0.0)
            .unwrap()
            .into_iter()
            .filter(|op| g.h.op(*op).unwrap().kind == verdandi::Kind::Revert)
            .count()
    }

    fn forks(&self) -> usize {
        logged(&self.fx, "session/fork").len()
    }
}

impl Fx {
    fn read(&self, rel: &str) -> String {
        std::fs::read_to_string(self.work().join(rel)).unwrap_or_default()
    }
}

async fn start(fx: &Fx, parent: Option<&str>) -> String {
    let p: StartParams =
        serde_json::from_value(json!({"profile": "mock-claude", "cwd": fx.work()})).unwrap();
    let hub = &fx.front.core.agents;
    match parent {
        None => hub.start(&fx.front, p, &user()).await,
        Some(m) => {
            let sid = crate::agents::session::new_sid().unwrap();
            hub.start_child(&fx.front, p, m, &sid).await
        }
    }
    .expect("a session")
    .id
}

/// The machine's one slot: the jobs of the session run, or queue behind it.
fn open_exec(fx: &Fx) {
    fx.front.core.exec.open(
        fx.dir.path().join("exec"),
        crate::exec::Hooks {
            admission: crate::runners::local::Admission::Fixed(1),
            plain_sessions: true,
            systemd: false,
            ..crate::exec::Hooks::default()
        },
    );
}

async fn job(fx: &Fx, sid: &str, script: &str) -> String {
    let wt = fx.work();
    fx.front
        .core
        .exec
        .start(ExecSpec {
            starter: Starter::Session(sid.into()),
            cwd: wt.clone(),
            worktree: Some(wt),
            argv: vec!["sh".into(), "-c".into(), script.into()],
            timebox: Duration::from_secs(600),
            kind: CheckKind::Other,
            container: None,
            user: UserJob::default(),
            place: Default::default(),
        })
        .await
        .unwrap()
}

/// A job that says it runs (a file it makes), then sleeps: its id once the file is there.
async fn running_job(fx: &Fx, sid: &str) -> String {
    let started = fx.dir.path().join("first-started");
    let id = job(
        fx,
        sid,
        &format!("touch {}; exec sleep 600", started.display()),
    )
    .await;
    crate::clock::blocking(move || {
        skuld::wait_until("the job runs", 60, || started.exists().then_some(()))
    })
    .await
    .unwrap();
    id
}

/// The session's running job is stopped before the revert touches a file.
#[tokio::test(flavor = "multi_thread")]
async fn stops_the_sessions_jobs_first() {
    let l = Live::new().await;
    open_exec(&l.fx);
    let id = running_job(&l.fx, &l.sid).await;
    assert_eq!(
        l.fx.front.core.exec.get(&id).unwrap().status,
        ExecStatus::Running
    );
    let edited = l.fx.read("a.txt");
    let a = l
        .apply_parked(RevertStep::Quiet, true, || async {
            assert_eq!(
                l.fx.front.core.exec.get(&id).unwrap().status,
                ExecStatus::Stopped
            );
            assert_eq!(l.fx.read("a.txt"), edited, "no file written yet");
        })
        .await
        .unwrap();
    assert_eq!(l.fx.read("a.txt"), FIVE);
    assert_eq!(a.conversation, w::ConversationRestore::Restored);
}

/// A job of the session waiting in the queue is cancelled: it never starts.
#[tokio::test(flavor = "multi_thread")]
async fn cancels_queued_jobs() {
    let l = Live::new().await;
    open_exec(&l.fx);
    let first = running_job(&l.fx, &l.sid).await;
    let marker = l.fx.dir.path().join("second-ran");
    let second = job(&l.fx, &l.sid, &format!("touch {}", marker.display())).await;
    assert!(l.fx.front.core.exec.is_queued(&second));
    let edited = l.fx.read("a.txt");
    l.apply_parked(RevertStep::Quiet, true, || async {
        let exec = &l.fx.front.core.exec;
        assert_eq!(exec.get(&first).unwrap().status, ExecStatus::Stopped);
        assert_eq!(exec.get(&second).unwrap().status, ExecStatus::Stopped);
        assert_eq!(l.fx.read("a.txt"), edited);
    })
    .await
    .unwrap();
    assert!(!marker.exists(), "the queued job never started");
}

/// The hub dies after the files are written and before the conversation: the next start finishes the revert from
/// its pending record, one revert record, the conversation rewound once.
#[tokio::test(flavor = "multi_thread")]
async fn restart_between_code_and_conversation_finishes() {
    let l = Live::new().await;
    let before = row_acp(&l.fx, &l.sid).await.unwrap();
    let r = l
        .apply_parked(RevertStep::Files, false, || async {
            assert_eq!(l.fx.read("a.txt"), FIVE);
        })
        .await;
    assert!(r.is_err(), "{r:?}");
    assert_eq!(
        row_acp(&l.fx, &l.sid).await.as_deref(),
        Some(before.as_str())
    );
    assert_eq!(l.forks(), 0);
    let f2 = l.crash_and_restart().await;
    finish_pending(&f2).await;
    assert_eq!(l.fx.read("a.txt"), FIVE);
    assert_ne!(row_acp(&l.fx, &l.sid).await.unwrap(), before);
    assert_eq!(l.forks(), 1);
    assert_eq!(l.reverts(&f2), 1);
    assert!(
        f2.core
            .history
            .all(&f2.dirs.get().unwrap().hub)
            .iter()
            .all(|h| h.lock().h.pending().unwrap().is_empty())
    );
}

/// The hub dies after the conversation was rewound: the next start does not rewind it again.
#[tokio::test(flavor = "multi_thread")]
async fn restart_after_the_conversation_does_not_rewind_again() {
    let l = Live::new().await;
    let r = l
        .apply_parked(RevertStep::Conversation, false, || async {})
        .await;
    assert!(r.is_err(), "{r:?}");
    assert_eq!(l.forks(), 1);
    let rewound = row_acp(&l.fx, &l.sid).await;
    let f2 = l.crash_and_restart().await;
    finish_pending(&f2).await;
    assert_eq!(l.forks(), 1, "one session/fork in the mock's log");
    assert_eq!(row_acp(&l.fx, &l.sid).await, rewound);
    assert_eq!(l.reverts(&f2), 1);
}

/// The hub dies after the forward commit: the next start makes no second one.
#[tokio::test(flavor = "multi_thread")]
async fn restart_after_the_commit_is_quiet() {
    let l = Live::new().await;
    let r = l.apply_parked(RevertStep::Commit, false, || async {}).await;
    assert!(r.is_err(), "{r:?}");
    let head = snapshot::head_of(&l.wt());
    let count = git(&l.wt(), &["rev-list", "--count", "HEAD"]);
    assert_eq!(count, "3", "base, the agent's, the revert's");
    let f2 = l.crash_and_restart().await;
    finish_pending(&f2).await;
    assert_eq!(snapshot::head_of(&l.wt()), head);
    assert_eq!(git(&l.wt(), &["rev-list", "--count", "HEAD"]), count);
}

/// Finishing a revert twice (two starts) changes nothing the first did not.
#[tokio::test(flavor = "multi_thread")]
async fn restart_finishing_twice_changes_nothing() {
    let l = Live::new().await;
    let r = l.apply_parked(RevertStep::Record, false, || async {}).await;
    assert!(r.is_err(), "{r:?}");
    let f2 = l.crash_and_restart().await;
    finish_pending(&f2).await;
    let (head, acp, forks) = (
        snapshot::head_of(&l.wt()),
        row_acp(&l.fx, &l.sid).await,
        l.forks(),
    );
    assert_eq!(l.fx.read("a.txt"), FIVE);
    let f3 = l.second().await;
    finish_pending(&f3).await;
    finish_pending(&f2).await;
    assert_eq!(snapshot::head_of(&l.wt()), head);
    assert_eq!(row_acp(&l.fx, &l.sid).await, acp);
    assert_eq!(l.forks(), forks);
    assert_eq!(l.reverts(&f3), 1);
}

/// A runner's patch for the session that returns once the revert is recorded is kept on its job and listed, never
/// applied; one that returns after the revert finds none running.
#[tokio::test(flavor = "multi_thread")]
async fn a_runners_patch_after_the_revert_is_kept_not_applied() {
    let l = Live::new().await;
    let a = l
        .apply_parked(RevertStep::Record, true, || async {
            assert!(patch_returned(&l.fx.front, &l.sid, "job-remote-1"));
        })
        .await
        .unwrap();
    assert_eq!(a.kept_patches, ["job-remote-1"]);
    assert_eq!(l.fx.read("a.txt"), FIVE);
    assert!(!patch_returned(&l.fx.front, &l.sid, "job-remote-2"));
}

/// A manager's worker reverted: the manager is told, in its own conversation.
#[tokio::test(flavor = "multi_thread")]
async fn manager_is_told() {
    let fx = Fx::new();
    let wt = fx.work();
    git(&wt, &["init", "-q", "-b", "main"]);
    std::fs::write(wt.join("a.txt"), FIVE).unwrap();
    git(&wt, &["add", "-A"]);
    git(&wt, &["commit", "-q", "-m", "base"]);
    let manager = start(&fx, None).await;
    turn(&fx.front, &manager, "one").await;
    let sid = start(&fx, Some(&manager)).await;
    turn(&fx.front, &sid, "zero").await;
    let target = turn(&fx.front, &sid, "one").await;
    turn(&fx.front, &sid, "tool:edit a.txt").await;
    let l = Live { fx, sid, target };
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
    .unwrap();
    let macp = row_acp(&l.fx, &manager).await.unwrap();
    let prompts = prompted(&l.fx, "reverted").await;
    let told: Vec<&str> = prompts
        .iter()
        .filter(|p| p["sessionId"] == json!(macp))
        .filter_map(|p| p["text"].as_str())
        .filter(|t| t.contains("reverted"))
        .collect();
    assert_eq!(told.len(), 1, "{prompts:?}");
    assert!(told[0].contains(&l.sid), "{}", told[0]);
}
