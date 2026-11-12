//! A launch on the mock agent (`ratatoskr-mock acp`, a real process; each test waits for the launch's answer, then
//! reads the mock's log): an attach by fork carries the lock, and a fork that cannot land is a new conversation at
//! Summary level.

use super::*;
use std::os::unix::fs::PermissionsExt;

/// A front whose settings hold the mock profiles, in a folder of its own: `mock-claude` (log `a.log`) and
/// `mock-claude-refusing` (its `default` mode refused, log `b.log`) on one `--state` folder, `mock-gemini`
/// (log `g.log`) and `mock-codex` (log `c.log`).  Its hub records sessions in `runtime.db` and keeps transcripts and queues in `hub/`.
pub(crate) struct Fx {
    pub dir: tempfile::TempDir,
    pub front: Front,
    pub runtime: urdr::Handle,
    _store: urdr::Store,
}

impl Fx {
    pub fn new() -> Fx {
        let dir = tempfile::tempdir().unwrap();
        // the graph writer makes work.db at the current schema
        let db = dir.path().join("work.db");
        let p = |s: &str| dir.path().join(s);
        for d in ["config", "work", "state", "home", "hub"] {
            std::fs::create_dir_all(p(d)).unwrap();
        }
        let front = Front::new(
            runstav::proof::Cap::generate().unwrap(),
            dir.path().join("hub-x.sock"),
            crate::store::WorkDb::spawn(db.clone()).unwrap(),
            norn::store::CoordDb::spawn(db),
        );
        let (store, runtime) = crate::runtime_db::open(dir.path()).unwrap();
        front.settings.open(p("config"), runtime.clone());
        let _ = front.dirs.set(crate::graph::StoreDirs {
            home: p("home"),
            config: p("config"),
            hub: p("hub"),
        });
        front.core.agents.open_store(runtime.clone());
        let fx = Fx {
            dir,
            front,
            runtime,
            _store: store,
        };
        fx.write_settings(None);
        fx
    }

    /// The settings file with every mock profile but WITHOUT.
    pub fn write_settings(&self, without: Option<&str>) {
        let p = |s: &str| self.dir.path().join(s);
        let mock = crate::embed::tests::mock_binary();
        let cmd = |kind: &str, log: &str, extra: &str| {
            format!(
                "({mock:?} \"acp\" \"--as\" \"{kind}\" \"--state\" {:?} \"--log\" {:?}{extra})",
                p("state"),
                p(log)
            )
        };
        let profiles = [
            ("mock-claude", "claude", cmd("claude", "a.log", "")),
            (
                "mock-claude-refusing",
                "claude",
                cmd("claude", "b.log", " \"--refuse-mode\" \"default\""),
            ),
            ("mock-gemini", "gemini", cmd("gemini", "g.log", "")),
            ("mock-codex", "codex", cmd("codex", "c.log", "")),
        ];
        let list: Vec<String> = profiles
            .iter()
            .filter(|(name, ..)| Some(*name) != without)
            .map(|(name, provider, c)| format!("(\"{name}\" :provider {provider} :command {c})"))
            .collect();
        let file = p("config").join("settings.el");
        std::fs::write(
            &file,
            format!(
                "(drgnx-settings :version 1 (drgnx-agents-profiles ({})))\n",
                list.join(" ")
            ),
        )
        .unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    }

    pub fn work(&self) -> PathBuf {
        self.dir.path().join("work")
    }

    pub async fn profile(&self, name: &str) -> AgentProfile {
        self.front.refresh_settings().await;
        find_profile(&self.front, name).expect("the mock profile")
    }

    /// PROFILE's agent launched in the work folder for a new session id, attached by ATTACH.
    async fn launch(
        &self,
        profile: &str,
        attach: &Attach,
    ) -> Result<(Launched, tokio::sync::mpsc::Receiver<Event>), Error> {
        let p = self.profile(profile).await;
        let sid = new_sid().unwrap();
        launch(
            &self.front,
            &p,
            Role::Chat,
            &sid,
            &self.work(),
            attach,
            (None, None, &[]),
        )
        .await
    }

    /// The values of KEY in the mock's LOG, in order.
    pub fn logged(&self, log: &str, key: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.path().join(log))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v.get(key).cloned())
            .collect()
    }
}

fn fork_of(source: &str, at: Option<&str>) -> Attach {
    Attach::Fork {
        source: source.into(),
        at: at.map(|m| hermod::ForkPoint {
            message_id: m.into(),
        }),
        level: RestoreLevel::Message,
    }
}

#[tokio::test]
async fn fork_keeps_the_lock() {
    let fx = Fx::new();
    let (src, _rx) = fx.launch("mock-claude", &Attach::New).await.unwrap();
    let source = src.acp.0.to_string();
    let (l, _rx2) = fx
        .launch("mock-claude", &fork_of(&source, None))
        .await
        .expect("a fork");
    assert_eq!(l.level, Some(RestoreLevel::Message));
    assert_ne!(&*l.acp.0, source.as_str());
    let fork = fx.logged("a.log", "session/fork");
    assert_eq!(fork.len(), 1, "{fork:?}");
    assert_eq!(fork[0]["from"], json!(source));
    assert!(
        fork[0]["claude_options"].is_object(),
        "the lock's options go with the fork: {fork:?}"
    );
    // the lock is verified after a fork as after `session/new`: one that does not hold ends the launch
    let refused = fx
        .launch("mock-claude-refusing", &fork_of(&source, None))
        .await;
    let Err(e) = refused else {
        panic!("a fork whose lock does not hold launched")
    };
    assert!(e.message.contains("refused"), "{}", e.message);
    assert_eq!(fx.logged("b.log", "session/fork").len(), 1, "it was a fork");
}

#[tokio::test]
async fn fork_failure_falls_back_to_summary() {
    let fx = Fx::new();
    let (src, _rx) = fx.launch("mock-claude", &Attach::New).await.unwrap();
    let source = src.acp.0.to_string();
    // the provider's transcript is gone
    std::fs::remove_file(fx.dir.path().join("state").join(format!("{source}.json"))).unwrap();
    drop(src);
    let (l, _rx2) = fx
        .launch("mock-claude", &fork_of(&source, Some("a-1-1")))
        .await
        .expect("the session lands though its fork does not");
    assert_eq!(l.level, Some(RestoreLevel::Summary));
    assert!(l.level_why.is_some(), "the reason is returned");
    assert!(fx.logged("a.log", "session/fork").is_empty());
    let new: Vec<Value> = fx.logged("a.log", "session/new");
    assert!(
        new.iter().any(|n| n["sessionId"] == json!(&*l.acp.0)),
        "a new conversation: {new:?}"
    );
    let block = hermod::ContentBlock::Text(hermod::schema::v1::TextContent::new("hello"));
    l.conn
        .prompt(&l.acp, vec![block], None)
        .await
        .expect("the session is alive");
}

#[tokio::test]
async fn gemini_lands_as_summary() {
    let fx = Fx::new();
    let (l, _rx) = fx
        .launch("mock-gemini", &fork_of("s1", None))
        .await
        .expect("a session");
    assert_eq!(l.level, Some(RestoreLevel::Summary));
    assert!(l.level_why.is_some());
    assert_eq!(fx.logged("g.log", "session/new").len(), 1);
}

/// A session's file that waits on the disk holds none of the hub's two workers: its queue file is a FIFO with no
/// reader (an open for writing waits there, as one waits on a slow disk), a reader of the session's state comes
/// next, and the runtime still runs a task.  The write lands once the disk answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_that_waits_on_the_disk_holds_no_worker() {
    let fx = Fx::new();
    let p: runstav::methods::agents::StartParams =
        serde_json::from_value(json!({"profile": "mock-claude", "cwd": fx.work()})).unwrap();
    let agents = &fx.front.core.agents;
    let sid = agents
        .start(&fx.front, p, &crate::runner::user())
        .await
        .expect("a session")
        .id;
    // a turn that stays busy, and a message queued behind it: the queue on disk holds "later" alone once the turn has
    // taken "silent 30" (a file that still held both was written again when the turn began, and could come back
    // between the test's remove and its mkfifo)
    agents.send(&sid, "silent 30".into()).unwrap();
    agents.send(&sid, "later".into()).unwrap();
    let queue = fx
        .dir
        .path()
        .join(format!("hub/transcripts/{sid}.queue.json"));
    let q = queue.clone();
    crate::clock::blocking(move || {
        skuld::wait_until("the queue on disk", 60, || {
            std::fs::read_to_string(&q)
                .ok()
                .filter(|t| t.contains("later") && !t.contains("silent 30"))
        })
    })
    .await
    .unwrap();
    let s = agents.find(&sid).unwrap();
    s.disk.written().await;
    std::fs::remove_file(&queue).unwrap();
    let made = std::process::Command::new("mkfifo")
        .arg(&queue)
        .status()
        .unwrap();
    assert!(made.success());
    // the write is queued and the task that asked for it ends, on a worker, while the open waits on the FIFO (a write
    // done in the task held its worker and the state lock until a reader came: the test hung here)
    let w = s.clone();
    tokio::spawn(async move { w.persist_queue() })
        .await
        .unwrap();
    // the state is free for the next reader, on a worker
    let r = s.clone();
    tokio::spawn(async move {
        r.observe();
    })
    .await
    .unwrap();
    let mut landed = std::pin::pin!(s.disk.written());
    let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
    assert!(
        std::future::Future::poll(landed.as_mut(), &mut cx).is_pending(),
        "the queue's write still waits on the disk"
    );
    // the disk answers: the write waiting on the FIFO goes on
    let read = std::thread::spawn(move || {
        let text = std::fs::read_to_string(&queue);
        // the session's later writes (its turn's end, the test's end) find a plain file again
        std::fs::remove_file(&queue).unwrap();
        text
    });
    landed.await;
    let written = read.join().unwrap().unwrap();
    assert!(written.contains("later"), "the queue written: {written}");
}

/// A resume whose files wait on the disk holds no thread of the runtime: the closed session's meta file is a FIFO
/// whose writer writes only once the runtime has run another task, on a runtime of one thread.  A read done in the
/// resume's task held that thread, so the other task never ran and the writer never wrote: the test hung here.
#[tokio::test]
async fn a_resume_that_waits_on_the_disk_holds_no_thread() {
    let fx = Fx::new();
    let p: runstav::methods::agents::StartParams =
        serde_json::from_value(json!({"profile": "mock-claude", "cwd": fx.work()})).unwrap();
    let agents = &fx.front.core.agents;
    let sid = agents
        .start(&fx.front, p, &crate::runner::user())
        .await
        .expect("a session")
        .id;
    agents.find(&sid).unwrap().close_now().await;
    let meta = fx
        .dir
        .path()
        .join(format!("hub/transcripts/{sid}.meta.json"));
    let text = std::fs::read_to_string(&meta).unwrap_or_else(|_| "{}".into());
    let _ = std::fs::remove_file(&meta);
    let made = std::process::Command::new("mkfifo")
        .arg(&meta)
        .status()
        .unwrap();
    assert!(made.success());
    // the disk: answers once the resume reads, and writes once it is told to
    let (opened_tx, opened) = std::sync::mpsc::channel::<()>();
    let (go, go_rx) = std::sync::mpsc::channel::<()>();
    let fifo = meta.clone();
    let disk = std::thread::spawn(move || {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().write(true).open(&fifo).unwrap();
        opened_tx.send(()).unwrap();
        go_rx.recv().unwrap();
        f.write_all(text.as_bytes()).unwrap();
    });
    let other = async {
        crate::clock::blocking(move || opened.recv().unwrap())
            .await
            .unwrap();
        // another task runs while the resume waits on the disk
        tokio::task::yield_now().await;
        go.send(()).unwrap();
    };
    let (resumed, ()) = tokio::join!(
        crate::agents::session::resume_closed(agents, &fx.front, &sid),
        other
    );
    resumed.expect("the session resumes");
    disk.join().unwrap();
    // the session's later writes find a plain file again
    let _ = std::fs::remove_file(&meta);
}
