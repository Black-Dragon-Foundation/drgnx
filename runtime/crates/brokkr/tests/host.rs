//! The WASM host against the fixture plugins (`runtime/plugins/fixtures`, built at test time) and component text for
//! what no toolchain emits on purpose. Every limit has a test that a hostile plugin breaks.
//!
//! The runtimes are multi-thread with 2 workers, the hub's shape. No test reads a clock or sleeps: deadlines are the
//! host's own, and the one wait is `skuld::wait_until_async` for calls to be admitted.

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use brokkr::limits::{MAX_JSON_BYTES, MAX_LOG_BYTES};
use brokkr::test_support::fixture;
use brokkr::{
    BoxFuture, CallError, Host, HostError, HostIo, HttpReq, HttpResp, Installed, Kv, Level, Limits,
    Plugin, Point, REFUSED_HEADERS, Verdict, scan,
};
use serde_json::{Value, json};

/// A key-value store in memory.
#[derive(Default)]
struct MemKv(Mutex<HashMap<String, Vec<u8>>>);

impl Kv for MemKv {
    fn get(&self, key: &str) -> Option<Vec<u8>> {
        self.0.lock().unwrap().get(key).cloned()
    }
    fn put(&self, key: &str, value: &[u8]) -> Result<(), String> {
        self.0.lock().unwrap().insert(key.into(), value.to_vec());
        Ok(())
    }
    fn delete(&self, key: &str) -> Result<(), String> {
        self.0.lock().unwrap().remove(key);
        Ok(())
    }
}

/// The hub's side, recorded: every request that reached it, every denial it was told of, a KV store per plugin name,
/// every log line.
struct TestIo {
    requests: Mutex<Vec<(String, HttpReq)>>,
    denied: Mutex<Vec<(String, String)>>,
    reply_bytes: usize,
    kv: HashMap<String, MemKv>,
    nobody: MemKv,
    logs: Mutex<Vec<(String, Level, String)>>,
}

impl TestIo {
    fn new(plugins: &[&str], reply_bytes: usize) -> Arc<TestIo> {
        Arc::new(TestIo {
            requests: Mutex::default(),
            denied: Mutex::default(),
            reply_bytes,
            kv: plugins
                .iter()
                .map(|p| (p.to_string(), MemKv::default()))
                .collect(),
            nobody: MemKv::default(),
            logs: Mutex::default(),
        })
    }
    fn requests(&self) -> Vec<(String, HttpReq)> {
        self.requests.lock().unwrap().clone()
    }
}

impl HostIo for TestIo {
    fn http(&self, plugin: &str, req: HttpReq) -> BoxFuture<'_, Result<HttpResp, String>> {
        self.requests.lock().unwrap().push((plugin.into(), req));
        let body = vec![b'x'; self.reply_bytes];
        Box::pin(async move {
            Ok(HttpResp {
                status: 200,
                headers: vec![("content-type".into(), "text/plain".into())],
                body,
            })
        })
    }
    fn denied(&self, plugin: &str, host: &str, _: &str) -> BoxFuture<'_, ()> {
        self.denied
            .lock()
            .unwrap()
            .push((plugin.into(), host.into()));
        Box::pin(async {})
    }
    fn kv(&self, plugin: &str) -> &dyn Kv {
        self.kv.get(plugin).unwrap_or(&self.nobody)
    }
    fn log(&self, plugin: &str, level: Level, text: &str) {
        self.logs
            .lock()
            .unwrap()
            .push((plugin.into(), level, text.into()));
    }
}

fn io() -> Arc<dyn HostIo> {
    TestIo::new(&[], 2)
}

fn host() -> Arc<Host> {
    Arc::new(Host::new(Limits::default()).unwrap())
}

/// The fixture `name` as `scan` reads it.
fn installed(name: &str) -> Installed {
    let root = fixture(name).parent().unwrap().to_path_buf();
    find(&root, name)
}

fn find(root: &Path, name: &str) -> Installed {
    scan(root)
        .into_iter()
        .filter_map(Result::ok)
        .find(|i| i.manifest.name.as_str() == name)
        .unwrap_or_else(|| panic!("no plugin {name} under {}", root.display()))
}

fn load(host: &Host, name: &str) -> Plugin {
    let i = installed(name);
    host.load(&i, i.hash).unwrap()
}

/// The fixture `name` installed again under `root` as `new`: a second plugin with the same code.
fn renamed(name: &str, new: &str, root: &Path) -> Installed {
    let from = fixture(name);
    let manifest = fs::read_to_string(from.join("plugin.json"))
        .unwrap()
        .replace(
            &format!("\"name\": \"{name}\""),
            &format!("\"name\": \"{new}\""),
        );
    let dir = root.join(new);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("plugin.json"), manifest).unwrap();
    fs::copy(from.join("plugin.wasm"), dir.join("plugin.wasm")).unwrap();
    find(root, new)
}

/// A plugin of component text: one ability, `echo`, whose `call` answers `{}`. Its core module's start function
/// makes HANDLES handles of a resource the component defines; EXTRA is more component text.
fn text_plugin(root: &Path, name: &str, handles: u32, extra: &str) -> Installed {
    let text = format!(
        r#"(component
  (type $r (resource (rep i32)))
  (core func $new (canon resource.new $r))
  (core module $m
    (import "" "new" (func $new (param i32) (result i32)))
    (memory (export "mem") 1)
    (data (i32.const 0) "\00\00\00\00\10\00\00\00\02\00\00\00")
    (data (i32.const 16) "{{}}")
    (func $start (local $i i32)
      (block $done
        (loop $more
          (br_if $done (i32.ge_u (local.get $i) (i32.const {handles})))
          (drop (call $new (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $more))))
    (start $start)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 1024))
    (func (export "call") (param i32 i32 i32 i32) (result i32) (i32.const 0)))
  (core instance $i (instantiate $m (with "" (instance (export "new" (func $new))))))
  {extra}
  (func $call (param "tool" string) (param "args-json" string) (result (result string (error string)))
    (canon lift (core func $i "call") (memory (core memory $i "mem")) (realloc (core func $i "realloc"))))
  (instance $ability (export "call" (func $call)))
  (export "drgnx:agent-tools/ability@0.1.0" (instance $ability)))"#
    );
    let wasm = wat::parse_str(&text).unwrap();
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    let manifest = json!({"name": name, "version": "0.1.0", "abilities": [
        {"name": "echo", "description": "Answers {}.", "input_schema": {"type": "object"}}]});
    fs::write(dir.join("plugin.json"), manifest.to_string()).unwrap();
    fs::write(dir.join("plugin.wasm"), wasm).unwrap();
    find(root, name)
}

/// `http-ability`'s `fetch` with ARGS.
async fn fetch(
    host: &Host,
    p: &Plugin,
    io: Arc<dyn HostIo>,
    args: Value,
) -> Result<Value, CallError> {
    host.call_ability(p, "fetch", args, io).await
}

fn spin(
    host: &Arc<Host>,
    p: &Plugin,
    secs: u64,
) -> tokio::task::JoinHandle<Result<Verdict, CallError>> {
    let (host, p) = (host.clone(), p.clone());
    tokio::spawn(async move {
        host.run_hook(
            &p,
            Point::BeforeTool,
            json!({}),
            Duration::from_secs(secs),
            io(),
        )
        .await
    })
}

async fn running(host: &Arc<Host>, n: usize) {
    skuld::wait_until_async(&format!("{n} calls admitted"), 60, || {
        let h = host.clone();
        async move { (h.calls_running() == n).then_some(()) }
    })
    .await;
}

// Pattern C (handshake): one call, its answer is the only wait.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn echo_ability_round_trips() {
    let host = host();
    let p = load(&host, "echo-ability");
    let args = json!({"a": [1, "two", {"three": null}], "b": "é"});
    let got = host.call_ability(&p, "echo", args.clone(), io()).await;
    assert_eq!(got, Ok(args));
    // an ability the manifest does not declare is never called
    let other = host.call_ability(&p, "nope", json!({}), io()).await;
    assert!(matches!(other, Err(CallError::Refused(_))), "{other:?}");
}

// Pattern C (handshake): the fixtures that must load all do, so the WASI list covers what Rust's std imports.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_fixture_that_needs_only_the_provided_interfaces_loads() {
    let host = host();
    for name in [
        "echo-ability",
        "deny-rm-hook",
        "rewrite-commit-msg",
        "annotate-edit",
        "slow-hook",
        "trap-hook",
        "big-alloc",
        "fs-importer",
        "http-ability",
    ] {
        let i = installed(name);
        host.load(&i, i.hash)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
    }
}

// Pattern C (handshake): the epoch deadline ends a guest that never returns.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spinning_hook_is_stopped_at_its_deadline() {
    let host = host();
    let p = load(&host, "slow-hook");
    let got = host
        .run_hook(
            &p,
            Point::BeforeTool,
            json!({}),
            Duration::from_millis(200),
            io(),
        )
        .await;
    assert_eq!(got, Err(CallError::Timeout));
    // the host goes on
    let deny = load(&host, "deny-rm-hook");
    let v = host
        .run_hook(
            &deny,
            Point::BeforeTool,
            json!({"tool": {"command": "rm -rf /"}}),
            Duration::from_secs(2),
            io(),
        )
        .await;
    assert_eq!(v, Ok(Verdict::Deny("no rm -rf".into())));
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_trap_is_trap_not_panic() {
    let host = host();
    let p = load(&host, "trap-hook");
    let got = host
        .run_hook(
            &p,
            Point::BeforeTool,
            json!({}),
            Duration::from_secs(2),
            io(),
        )
        .await;
    assert!(matches!(got, Err(CallError::Trap(_))), "{got:?}");
    let again = host
        .run_hook(
            &p,
            Point::BeforeTool,
            json!({}),
            Duration::from_secs(2),
            io(),
        )
        .await;
    assert!(
        matches!(again, Err(CallError::Trap(_))),
        "a fresh instance traps again: {again:?}"
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn memory_over_the_limit_traps() {
    let host = host();
    let p = load(&host, "big-alloc");
    let small = host
        .call_ability(&p, "alloc", json!({"mib": 8}), io())
        .await;
    assert_eq!(small, Ok(json!(8 << 20)));
    let big = host
        .call_ability(&p, "alloc", json!({"mib": 128}), io())
        .await;
    assert!(matches!(big, Err(CallError::Trap(_))), "{big:?}");
}

// Pattern C (handshake): every refusal is the import's error, and nothing reaches the hub's HTTP.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_to_an_undeclared_host_is_refused_before_io() {
    let host = host();
    let p = load(&host, "http-ability");
    let t = TestIo::new(&[], 2);
    for (url, why) in [
        (
            "https://evil.example.org/x",
            "not a host this plugin declared",
        ),
        ("http://api.example.com/x", "only https"),
        (
            "https://api.example.com:8443/x",
            "not a host this plugin declared",
        ),
        ("https://user@api.example.com/x", "credentials"),
        (
            "https://api.example.com.evil.org/x",
            "not a host this plugin declared",
        ),
        (
            "https://api.example.com./x",
            "not a host this plugin declared",
        ),
        ("https://evil.org\\@api.example.com/x", "backslash"),
        ("https://[::1]/x", "IP literal"),
        ("ftp://api.example.com/x", "only https"),
    ] {
        let got = fetch(&host, &p, t.clone(), json!({"url": url})).await;
        match got {
            Err(CallError::Plugin(m)) => assert!(m.contains(why), "{url}: {m}"),
            other => panic!("{url}: {other:?}"),
        }
    }
    assert_eq!(t.requests(), vec![], "a refused request reached the hub");
    // an undeclared host:port is told to the hub, which records it; a malformed URL names no host
    let denied: Vec<String> = t
        .denied
        .lock()
        .unwrap()
        .iter()
        .map(|(p, h)| {
            assert_eq!(p, "http-ability");
            h.clone()
        })
        .collect();
    assert_eq!(
        denied,
        [
            "evil.example.org:443",
            "api.example.com:8443",
            "api.example.com.evil.org:443",
            "api.example.com.:443"
        ]
    );
    let ok = fetch(
        &host,
        &p,
        t.clone(),
        json!({"url": "https://API.example.com/v1?q=1"}),
    )
    .await;
    assert_eq!(ok, Ok(json!({"status": 200, "body": "xx"})));
    let reqs = t.requests();
    assert_eq!(reqs.len(), 1);
    assert_eq!(reqs[0].0, "http-ability");
    assert_eq!(
        (reqs[0].1.host.as_str(), reqs[0].1.port),
        ("api.example.com", 443)
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn refused_headers_never_leave() {
    let host = host();
    let p = load(&host, "http-ability");
    let t = TestIo::new(&[], 2);
    let mut bad: Vec<(String, String)> = REFUSED_HEADERS
        .iter()
        .map(|h| (h.to_string(), "x".to_string()))
        .collect();
    bad.push(("Proxy-Authorization".into(), "Basic eA==".into()));
    bad.push(("HOST".into(), "evil.org".into()));
    bad.push(("x-ok".into(), "a\r\nhost: evil.org".into()));
    bad.push(("bad name".into(), "x".into()));
    for (name, value) in bad {
        let args = json!({"url": "https://api.example.com/", "headers": [[name, value]]});
        let got = fetch(&host, &p, t.clone(), args).await;
        assert!(matches!(&got, Err(CallError::Plugin(_))), "{name}: {got:?}");
    }
    assert_eq!(t.requests(), vec![], "a refused header reached the hub");
    let args = json!({"url": "https://api.example.com/", "headers": [["Accept", "text/plain"]]});
    assert!(fetch(&host, &p, t.clone(), args).await.is_ok());
    assert_eq!(
        t.requests()[0].1.headers,
        vec![("accept".to_string(), "text/plain".to_string())]
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_bodies_are_capped_at_1_mib() {
    let host = host();
    let p = load(&host, "http-ability");
    let t = TestIo::new(&[], 2);
    let big =
        json!({"url": "https://api.example.com/", "method": "post", "body_bytes": (1 << 20) + 1});
    let got = fetch(&host, &p, t.clone(), big).await;
    assert!(
        matches!(&got, Err(CallError::Plugin(m)) if m.contains("request body")),
        "{got:?}"
    );
    assert_eq!(t.requests(), vec![]);
    let at = json!({"url": "https://api.example.com/", "method": "post", "body_bytes": 1 << 20});
    assert!(fetch(&host, &p, t.clone(), at).await.is_ok());
    assert_eq!(t.requests()[0].1.body.len(), 1 << 20);
    let flood = TestIo::new(&[], (1 << 20) + 1);
    let got = fetch(&host, &p, flood, json!({"url": "https://api.example.com/"})).await;
    assert!(
        matches!(&got, Err(CallError::Plugin(m)) if m.contains("response body")),
        "{got:?}"
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn json_over_256_kib_is_refused_both_ways() {
    let host = host();
    let echo = load(&host, "echo-ability");
    let big = json!({"s": "a".repeat(MAX_JSON_BYTES)});
    let got = host.call_ability(&echo, "echo", big, io()).await;
    assert!(
        matches!(&got, Err(CallError::Refused(m)) if m.contains("arguments")),
        "{got:?}"
    );
    let input = json!({"s": "a".repeat(MAX_JSON_BYTES)});
    let deny = load(&host, "deny-rm-hook");
    let got = host
        .run_hook(
            &deny,
            Point::BeforeTool,
            input,
            Duration::from_secs(2),
            io(),
        )
        .await;
    assert!(
        matches!(&got, Err(CallError::Refused(m)) if m.contains("input")),
        "{got:?}"
    );
    // a reply of 300 KiB makes a result past the cap
    let p = load(&host, "http-ability");
    let got = fetch(
        &host,
        &p,
        TestIo::new(&[], 300 << 10),
        json!({"url": "https://api.example.com/"}),
    )
    .await;
    assert!(
        matches!(&got, Err(CallError::Refused(m)) if m.contains("result")),
        "{got:?}"
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn kv_is_per_plugin() {
    let tmp = tempfile::tempdir().unwrap();
    let host = host();
    let a = load(&host, "http-ability");
    let i = renamed("http-ability", "http-ability-b", tmp.path());
    let b = host.load(&i, i.hash).unwrap();
    let t = TestIo::new(&["http-ability", "http-ability-b"], 2);
    let put = json!({"op": "put", "key": "k", "value": "from a"});
    assert_eq!(
        host.call_ability(&a, "kv", put, t.clone()).await,
        Ok(json!({}))
    );
    let get = json!({"op": "get", "key": "k"});
    assert_eq!(
        host.call_ability(&b, "kv", get.clone(), t.clone()).await,
        Ok(Value::Null)
    );
    assert_eq!(
        host.call_ability(&a, "kv", get, t.clone()).await,
        Ok(json!("from a"))
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn kv_writes_per_call_are_capped() {
    let host = host();
    let p = load(&host, "http-ability");
    let t = TestIo::new(&["http-ability"], 2);
    let many = json!({"op": "put", "key": "k", "value": "v", "repeat": 70});
    let got = host.call_ability(&p, "kv", many, t.clone()).await.unwrap();
    assert_eq!(got["done"], json!(64), "{got}");
    assert!(got["error"].as_str().unwrap().contains("64"), "{got}");
    // the count is per call
    let one = json!({"op": "delete", "key": "k0"});
    assert_eq!(
        host.call_ability(&p, "kv", one, t.clone()).await,
        Ok(json!({}))
    );
    let long = json!({"op": "put", "key": "k".repeat(257), "value": "v"});
    let got = host.call_ability(&p, "kv", long, t).await;
    assert!(
        matches!(&got, Err(CallError::Plugin(m)) if m.contains("key")),
        "{got:?}"
    );
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn log_and_stdout_share_64_kib() {
    let host = host();
    let p = load(&host, "http-ability");
    let t = TestIo::new(&[], 2);
    let small = json!({"log_bytes": 10});
    assert!(
        host.call_ability(&p, "chatter", small, t.clone())
            .await
            .is_ok()
    );
    assert_eq!(
        t.logs.lock().unwrap().clone(),
        vec![("http-ability".to_string(), Level::Info, "l".repeat(10))]
    );
    t.logs.lock().unwrap().clear();
    let loud = json!({"log_bytes": 40_000, "stdout_bytes": 40_000});
    assert!(
        host.call_ability(&p, "chatter", loud, t.clone())
            .await
            .is_ok()
    );
    let logs = t.logs.lock().unwrap().clone();
    let (cut, text): (Vec<_>, Vec<_>) = logs.iter().partition(|(_, _, s)| s.contains("was cut"));
    let total: usize = text.iter().map(|(_, _, s)| s.len()).sum();
    assert_eq!(
        total,
        MAX_LOG_BYTES,
        "{:?}",
        logs.iter().map(|l| (l.1, l.2.len())).collect::<Vec<_>>()
    );
    assert_eq!(cut.len(), 1);
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hash_mismatch_never_instantiates() {
    let tmp = tempfile::tempdir().unwrap();
    let host = host();
    let i = renamed("echo-ability", "echo-copy", tmp.path());
    assert!(matches!(
        host.load(&i, [0; 32]),
        Err(HostError::NotApproved(_))
    ));
    // the code swapped on disk after the scan, approved hash in hand
    fs::copy(
        fixture("trap-hook").join("plugin.wasm"),
        i.dir.join("plugin.wasm"),
    )
    .unwrap();
    let got = host.load(&i, i.hash);
    assert!(
        matches!(&got, Err(HostError::NotApproved(m)) if m.contains("changed on disk")),
        "{got:?}"
    );
    // the manifest swapped: one more host
    let j = renamed("http-ability", "http-copy", tmp.path());
    let wider = fs::read_to_string(j.dir.join("plugin.json"))
        .unwrap()
        .replace(
            "\"api.example.com\"",
            "\"api.example.com\", \"evil.example.org\"",
        );
    fs::write(j.dir.join("plugin.json"), wider).unwrap();
    assert!(matches!(
        host.load(&j, j.hash),
        Err(HostError::NotApproved(_))
    ));
}

// Pattern C (handshake): two calls are admitted, then the third waits for a permit until its deadline.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_calls_of_one_plugin_a_third_is_busy_after_its_queue_deadline() {
    let host = host();
    let p = load(&host, "slow-hook");
    let (a, b) = (spin(&host, &p, 3), spin(&host, &p, 3));
    running(&host, 2).await;
    let third = host
        .run_hook(
            &p,
            Point::BeforeTool,
            json!({}),
            Duration::from_millis(200),
            io(),
        )
        .await;
    assert_eq!(third, Err(CallError::Busy));
    assert_eq!(a.await.unwrap(), Err(CallError::Timeout));
    assert_eq!(b.await.unwrap(), Err(CallError::Timeout));
    // the permits came back: the next call runs, and is stopped by its own deadline
    running(&host, 0).await;
    let next = host
        .run_hook(
            &p,
            Point::BeforeTool,
            json!({}),
            Duration::from_millis(200),
            io(),
        )
        .await;
    assert_eq!(next, Err(CallError::Timeout));
}

// Pattern C (handshake): four calls of two plugins are admitted; a third plugin, whose own cap is free, waits for a
// global permit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_global_cap_holds_across_plugins() {
    let tmp = tempfile::tempdir().unwrap();
    let host = host();
    let a = load(&host, "slow-hook");
    let ib = renamed("slow-hook", "slow-b", tmp.path());
    let b = host.load(&ib, ib.hash).unwrap();
    let ic = renamed("slow-hook", "slow-c", tmp.path());
    let c = host.load(&ic, ic.hash).unwrap();
    let calls = [
        spin(&host, &a, 3),
        spin(&host, &a, 3),
        spin(&host, &b, 3),
        spin(&host, &b, 3),
    ];
    running(&host, 4).await;
    let fifth = host
        .run_hook(
            &c,
            Point::BeforeTool,
            json!({}),
            Duration::from_millis(200),
            io(),
        )
        .await;
    assert_eq!(fifth, Err(CallError::Busy));
    for call in calls {
        assert_eq!(call.await.unwrap(), Err(CallError::Timeout));
    }
}

// Pattern C (handshake): both hooks hold their guest threads; a task on this 2-worker runtime (the hub's shape) must
// finish while both still spin. On the caller's workers they would hold both until their deadline.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_spinning_hooks_leave_the_hub_responsive() {
    let host = host();
    let p = load(&host, "slow-hook");
    let (a, b) = (spin(&host, &p, 3), spin(&host, &p, 3));
    running(&host, 2).await;
    tokio::spawn(async {
        for _ in 0..100 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(
        !a.is_finished() && !b.is_finished(),
        "the hub's runtime waited for the guests"
    );
    assert_eq!(a.await.unwrap(), Err(CallError::Timeout));
    assert_eq!(b.await.unwrap(), Err(CallError::Timeout));
}

// Pattern C (handshake).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_filesystem_import_finds_no_directory() {
    let host = host();
    let p = load(&host, "fs-importer");
    let got = host.call_ability(&p, "probe", json!({}), io()).await;
    assert_eq!(
        got,
        Ok(json!({"opened": false, "root_entries": null, "cwd_entries": null}))
    );
}

// Pattern D (pure): a load, no call.
#[test]
fn a_wasi_http_import_fails_to_load() {
    let host = Host::new(Limits::default()).unwrap();
    let i = installed("http-importer");
    let got = host.load(&i, i.hash);
    assert!(
        matches!(&got, Err(HostError::Import(m)) if m.contains("wasi:http/") && m.contains("which drgnx does not provide")),
        "{got:?}"
    );
}

// Pattern D (pure).
#[test]
fn a_socket_import_fails_to_load() {
    let host = Host::new(Limits::default()).unwrap();
    let i = installed("socket-importer");
    let got = host.load(&i, i.hash);
    assert!(
        matches!(&got, Err(HostError::Import(m)) if m.contains("wasi:sockets/") && m.contains("which drgnx does not provide")),
        "{got:?}"
    );
}

// Pattern C (handshake): component text, loaded and called.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_disabled_proposal_fails_to_load() {
    let tmp = tempfile::tempdir().unwrap();
    let host = host();
    let plain = text_plugin(tmp.path(), "plain", 0, "");
    let p = host.load(&plain, plain.hash).unwrap();
    assert_eq!(
        host.call_ability(&p, "echo", json!({}), io()).await,
        Ok(json!({}))
    );
    for (name, module) in [
        ("tail-call", "(core module (func $f (return_call $f)))"),
        ("memory64", "(core module (memory i64 1))"),
        ("multi-memory", "(core module (memory 1) (memory 1))"),
    ] {
        let i = text_plugin(tmp.path(), name, 0, module);
        // the same component as `plain` but for one module the engine refuses
        let got = host.load(&i, i.hash);
        assert!(
            matches!(&got, Err(HostError::Invalid(_))),
            "{name}: {got:?}"
        );
    }
}

// Pattern C (handshake): the handles are made by the start function, in the call's fresh instance.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn too_many_handles_trap() {
    let tmp = tempfile::tempdir().unwrap();
    let host = host();
    let under = text_plugin(tmp.path(), "handles-990", 990, "");
    let p = host.load(&under, under.hash).unwrap();
    assert_eq!(
        host.call_ability(&p, "echo", json!({}), io()).await,
        Ok(json!({}))
    );
    let over = text_plugin(tmp.path(), "handles-1001", 1001, "");
    let p = host.load(&over, over.hash).unwrap();
    let got = host.call_ability(&p, "echo", json!({}), io()).await;
    assert!(matches!(got, Err(CallError::Trap(_))), "{got:?}");
}

// Pattern C (handshake): the test runs itself again in a child process, which installs a SIGSEGV handler, starts the
// host and runs a call (so wasmtime's handlers are installed over it), then raises SIGSEGV outside any guest. The
// child's handler exits 42; without the chain the child would die by the signal.
#[test]
fn a_fault_outside_wasm_still_reaches_the_hubs_handler() {
    if std::env::var_os("BROKKR_FAULT_CHILD").is_some() {
        fault_child();
    }
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "a_fault_outside_wasm_still_reaches_the_hubs_handler",
            "--nocapture",
            "--test-threads",
            "1",
        ])
        .env("BROKKR_FAULT_CHILD", "1")
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(42),
        "{:?}\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
}

fn fault_child() -> ! {
    extern "C" fn on_segv(_: libc::c_int) {
        // SAFETY: async-signal-safe
        unsafe { libc::_exit(42) }
    }
    // SAFETY: a plain handler for SIGSEGV, installed before any other thread runs wasm
    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = on_segv as extern "C" fn(libc::c_int) as usize;
        libc::sigemptyset(&mut sa.sa_mask);
        assert_eq!(libc::sigaction(libc::SIGSEGV, &sa, std::ptr::null_mut()), 0);
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let host = host();
        let p = load(&host, "echo-ability");
        host.call_ability(&p, "echo", json!({}), io())
            .await
            .unwrap();
        // SAFETY: raises the signal on this thread, outside any guest
        unsafe { libc::raise(libc::SIGSEGV) };
    });
    std::process::exit(1)
}
