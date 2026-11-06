//! The after-edit point over real fixture plugins (WASM components built at test time) on the real clock. Each test is
//! pattern C (handshake): the point's own outcome is the only wait.

use std::sync::Arc;

use brokkr::test_support::fixture;
use brokkr::{BoxFuture, HostIo, HttpReq, HttpResp, Kv, Level};
use serde_json::json;

use super::*;
use crate::settings::Settings;
use crate::settings::overrides::Override;

struct NoKv;

impl Kv for NoKv {
    fn get(&self, _: &str) -> Option<Vec<u8>> {
        None
    }
    fn put(&self, _: &str, _: &[u8]) -> Result<(), String> {
        Err("no store".into())
    }
    fn delete(&self, _: &str) -> Result<(), String> {
        Err("no store".into())
    }
}

struct NoIo;

impl HostIo for NoIo {
    fn http(&self, _: &str, _: HttpReq) -> BoxFuture<'_, Result<HttpResp, String>> {
        Box::pin(async { Err("no network here".to_string()) })
    }
    fn denied(&self, _: &str, _: &str, _: &str) -> BoxFuture<'_, ()> {
        Box::pin(async {})
    }
    fn kv(&self, _: &str) -> &dyn Kv {
        &NoKv
    }
    fn log(&self, _: &str, _: Level, _: &str) {}
}

struct Rig {
    dir: tempfile::TempDir,
    plugins: Plugins,
    _store: urdr::Store,
}

async fn rig(approved: &[&str]) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
    let settings = Arc::new(Settings::new());
    settings.open(dir.path().to_path_buf(), db.clone());
    settings.refresh().await;
    let plugins = Plugins::default();
    let root = dir.path().join("data").join("plugins");
    plugins.open(root.clone(), db, settings.clone());
    for name in approved {
        let from = fixture(name);
        let to = root.join(name);
        std::fs::create_dir_all(&to).unwrap();
        for f in ["plugin.json", "plugin.wasm"] {
            std::fs::copy(from.join(f), to.join(f)).unwrap();
        }
    }
    settings
        .set_overrides(
            None,
            vec![Override {
                name: "drgnx-agents-plugins".into(),
                value: json!(approved),
                source: "test".into(),
            }],
        )
        .await
        .unwrap();
    let rows = plugins.sync().await.unwrap().rows;
    for name in approved {
        let hash = rows.iter().find(|r| r.name == *name).unwrap().hash.clone();
        plugins.approve(name, hash.unwrap().as_str()).await.unwrap();
    }
    Rig {
        dir,
        plugins,
        _store: store,
    }
}

impl Rig {
    async fn ask(&self, path: &str, content: Option<&str>) -> Outcome {
        let root = self.dir.path().join("work");
        let edit = EditInfo {
            path: root.join(path),
            diff: Some("@@ -1 +1 @@\n-a\n+b\n".into()),
            content: content.map(str::to_owned),
            step: Some(4),
        };
        run_after_edit(&self.plugins, None, &root, Arc::new(NoIo), "s-1", &edit).await
    }
}

// [C] handshake: hooks/after-edit-annotates-the-step
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_annotation_reaches_the_outcome_with_its_path() {
    let r = rig(&["annotate-edit"]).await;
    let out = r.ask("src/a.rs", None).await;
    assert_eq!(out.annotations, ["edited src/a.rs"]);
    assert_eq!(out.decision, Decision::Proceed { changed: None });
}

// [C] handshake: hooks/after-edit-change-rewrites-an-fs-write
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_rewrites_an_fs_write() {
    let r = rig(&["change-edit"]).await;
    let out = r.ask("a.txt", Some("one\n")).await;
    assert_eq!(
        changed_content(&out),
        Some(("one\n// checked\n".to_owned(), "change-edit".to_owned()))
    );
}

// [C] handshake: hooks/after-edit-deny-refuses-an-fs-write
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deny_refuses_an_fs_write_with_its_reason() {
    let r = rig(&["deny-edit"]).await;
    let out = r.ask("Cargo.lock", Some("x")).await;
    let (name, reason) = refusal_of(&out).expect("denied");
    assert!(name.contains("deny-edit"), "{name}");
    assert_eq!(reason, "lock files are generated");
    assert_eq!(
        refusal_message(&reason),
        "drgnx refused the write: lock files are generated"
    );
    // another file is not refused
    assert_eq!(refusal_of(&r.ask("a.txt", Some("x")).await), None);
}

// [C] handshake: hooks/after-edit-deny-on-an-agent-edit-is-recorded
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_deny_on_an_agents_own_edit_is_a_refusal_to_mark() {
    let r = rig(&["deny-edit"]).await;
    let out = r.ask("Cargo.lock", None).await;
    assert!(refusal_of(&out).is_some(), "{out:?}");
}

// [C] handshake: an edit the agent made itself cannot be changed
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_on_an_agents_own_edit_changes_nothing() {
    let r = rig(&["change-edit"]).await;
    let out = r.ask("a.txt", None).await;
    assert_eq!(changed_content(&out), None);
    let (_, reason) = refusal_of(&out).expect("a change here is a failure");
    assert!(reason.contains("not accepted"), "{reason}");
}

// [D] pure: hooks/a-changed-write-tells-the-agent
#[test]
fn a_changed_write_tells_the_agent() {
    assert_eq!(
        change_notice("fmt", "src/a.rs"),
        "drgnx's hook fmt changed your write to src/a.rs; read the file before editing it again"
    );
}

// [D] pure: no hook is asked when none is listed
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_hooks_is_no_outcome() {
    let r = rig(&[]).await;
    let out = r.ask("a.txt", Some("x")).await;
    assert_eq!(out.decision, Decision::Proceed { changed: None });
    assert!(out.annotations.is_empty() && out.provenance.is_empty());
}
