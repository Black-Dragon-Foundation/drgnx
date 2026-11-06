//! The hook engine through the plugin host: `hooks::run` with `PluginHooks` over real fixture plugins
//! (`runtime/plugins/fixtures`, built at test time). Pattern C (handshake): each run's records are the only wait.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use brokkr::test_support::fixture;
use brokkr::{BoxFuture, Host, HostIo, HttpReq, HttpResp, Kv, Level, Limits, Plugin, scan};
use norn::hooks::{HookInput, PluginHooks, Point, Verdict, run};
use serde_json::json;

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

/// A step with no session or job: no HTTP, no store.
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

fn load(host: &Host, name: &str) -> Arc<Plugin> {
    let root = fixture(name).parent().unwrap().to_path_buf();
    let i = scan(&root)
        .into_iter()
        .filter_map(Result::ok)
        .find(|i| i.manifest.name.as_str() == name)
        .unwrap();
    Arc::new(host.load(&i, i.hash).unwrap())
}

fn step(point: Point, detail: serde_json::Value) -> HookInput {
    HookInput {
        point,
        session: Some("s-1".into()),
        step: Some(3),
        tool_kind: Some("execute".into()),
        tool: Some("Bash".into()),
        paths: Vec::<PathBuf>::new(),
        command: None,
        detail,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spinning_plugin_hook_fails_timed_out_within_the_points_budget() {
    let host = Host::new(Limits::default()).unwrap();
    let plugins = [load(&host, "slow-hook")];
    let hooks = PluginHooks {
        host: &host,
        io: Arc::new(NoIo),
        refresh: |_: &mut HookInput| {},
    };
    let input = step(
        Point::BeforeTool,
        json!({"tool": {"kind": "execute", "input": {}}}),
    );
    let records = run(
        &input,
        Duration::from_millis(300),
        true,
        &[],
        &plugins,
        &hooks,
    )
    .await;
    assert_eq!(records.len(), 1);
    // the deadline is what is left of the budget when the hook starts, a little under 300 ms on a real clock
    let error = records[0].error.as_deref().unwrap_or("");
    assert!(
        error.starts_with("hook slow-hook failed: timed out (") && error.ends_with(" ms)"),
        "{records:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_plugin_change_is_refused_where_the_site_takes_none_and_refreshed_where_it_does() {
    let host = Host::new(Limits::default()).unwrap();
    let plugins = [load(&host, "rewrite-commit-msg")];
    let refreshed = AtomicUsize::new(0);
    let hooks = PluginHooks {
        host: &host,
        io: Arc::new(NoIo),
        refresh: |_: &mut HookInput| {
            refreshed.fetch_add(1, Ordering::SeqCst);
        },
    };
    let input = step(Point::BeforeCommit, json!({"commit": {"message": "merge"}}));
    let budget = Duration::from_secs(10);
    let refused = run(&input, budget, false, &[], &plugins, &hooks).await;
    assert_eq!(
        refused[0].error.as_deref(),
        Some("hook rewrite-commit-msg failed: change is not accepted here")
    );
    assert_eq!(refreshed.load(Ordering::SeqCst), 0);
    let taken = run(&input, budget, true, &[], &plugins, &hooks).await;
    assert_eq!(
        taken[0].verdict,
        Some(Verdict::Change(json!({"message": "merge [checked]"})))
    );
    assert_eq!(refreshed.load(Ordering::SeqCst), 1);
}
