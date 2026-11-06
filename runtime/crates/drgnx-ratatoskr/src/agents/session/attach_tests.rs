//! A launch on the mock agent (`ratatoskr-mock acp`, a real process; each test waits for the launch's answer, then
//! reads the mock's log): an attach by fork carries the lock, and a fork that cannot land is a new conversation at
//! Summary level.

use super::*;
use std::os::unix::fs::PermissionsExt;

/// A front whose settings hold the mock profiles, in a folder of its own: `mock-claude` (log `a.log`) and
/// `mock-claude-refusing` (its `default` mode refused, log `b.log`) on one `--state` folder, and `mock-gemini`
/// (log `g.log`).
pub(super) struct Fx {
    pub dir: tempfile::TempDir,
    pub front: Front,
    _store: urdr::Store,
}

impl Fx {
    pub fn new() -> Fx {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("work.db");
        urdr::Connection::open(&db)
            .unwrap()
            .execute_batch(include_str!(
                "../../../../../../test/fixtures/work-db-6.sql"
            ))
            .unwrap();
        let p = |s: &str| dir.path().join(s);
        for d in ["config", "work", "state"] {
            std::fs::create_dir_all(p(d)).unwrap();
        }
        let mock = crate::embed::tests::mock_binary();
        let cmd = |kind: &str, log: &str, extra: &str| {
            format!(
                "({mock:?} \"acp\" \"--as\" \"{kind}\" \"--state\" {:?} \"--log\" {:?}{extra})",
                p("state"),
                p(log)
            )
        };
        let file = p("config").join("settings.el");
        std::fs::write(
            &file,
            format!(
                "(drgnx-settings :version 1 (drgnx-agents-profiles ((\"mock-claude\" :provider claude :command {}) \
                 (\"mock-claude-refusing\" :provider claude :command {}) (\"mock-gemini\" :provider gemini :command {}))))\n",
                cmd("claude", "a.log", ""),
                cmd("claude", "b.log", " \"--refuse-mode\" \"default\""),
                cmd("gemini", "g.log", "")
            ),
        )
        .unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let front = Front::new(
            runstav::proof::Cap::generate().unwrap(),
            dir.path().join("hub-x.sock"),
            crate::store::WorkDb::spawn(db.clone()).unwrap(),
            norn::store::CoordDb::spawn(db),
        );
        let (store, runtime) = crate::runtime_db::open(dir.path()).unwrap();
        front.settings.open(p("config"), runtime);
        Fx {
            dir,
            front,
            _store: store,
        }
    }

    pub fn work(&self) -> PathBuf {
        self.dir.path().join("work")
    }

    pub async fn profile(&self, name: &str) -> AgentProfile {
        self.front.refresh_settings().await;
        find_profile(&self.front, name).expect("the mock profile")
    }

    /// PROFILE's agent launched in the work folder for a new session id, attached by ATTACH.
    pub async fn launch(
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
