//! The coordination tools (Tasks 7 and 8): who an agent is, the guard, the report limit, the report tools' rules, and
//! the Lisp oracle's tool cases replayed.  `test/fixtures/coord-parity/tools-*.input.json` is run against the Rust
//! tools with the case's clock and identities; each answer and the tables must equal `CASE.expect.json`, which
//! `gen.el` made by running the Lisp tools of `core/drgnx-coord-mcp.el`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use mimir::{BoxFuture, ToolResult};
use norn::store::CoordDb;
use norn::tools::guard::IDENTITY_ARGS;
use norn::tools::{Clock, Coord, Hub, Identity, SessionRow, tools};
use serde_json::{Value, json};
use urdr::Connection;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures")
}

/// A hub that answers no `agents/list` (as when none runs) and counts what it is told.
#[derive(Default)]
struct CountingHub {
    notified: AtomicUsize,
}

impl Hub for CountingHub {
    fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
        Box::pin(async { None::<Vec<SessionRow>> })
    }
    fn notify(&self) {
        self.notified.fetch_add(1, Ordering::SeqCst);
    }
}

/// A schema-6 `work.db` in a temporary directory, the tools' `Coord` on it, and its clock.
struct World {
    dir: tempfile::TempDir,
    file: PathBuf,
    db: CoordDb,
    hub: Arc<CountingHub>,
    time: Arc<AtomicU64>,
    coord: Arc<Coord>,
}

impl World {
    fn new(setup: &[&str]) -> World {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        {
            let c = Connection::open(&file).unwrap();
            c.execute_batch(&std::fs::read_to_string(fixtures().join("work-db-6.sql")).unwrap())
                .unwrap();
            for sql in setup {
                c.execute_batch(sql).unwrap();
            }
        }
        let db = CoordDb::spawn(&file);
        let hub = Arc::new(CountingHub::default());
        let time = Arc::new(AtomicU64::new(1_000.5f64.to_bits()));
        let coord = Arc::new(World::coord_on(&db, &hub, &time));
        World {
            dir,
            file,
            db,
            hub,
            time,
            coord,
        }
    }

    fn coord_on(db: &CoordDb, hub: &Arc<CountingHub>, time: &Arc<AtomicU64>) -> Coord {
        let t = time.clone();
        let clock: Clock = Arc::new(move || f64::from_bits(t.load(Ordering::SeqCst)));
        Coord::with_clock(db.clone(), hub.clone(), clock)
    }

    /// A `Coord` as after a hub restart: the same store, nothing in memory.
    fn restarted(&self) -> Arc<Coord> {
        Arc::new(World::coord_on(&self.db, &self.hub, &self.time))
    }

    fn at(&self, t: f64) {
        self.time.store(t.to_bits(), Ordering::SeqCst);
    }

    async fn call(&self, who: &Identity, name: &str, args: Value) -> (bool, String) {
        call_on(&self.coord, who, name, args).await
    }

    fn conn(&self) -> Connection {
        Connection::open(&self.file).unwrap()
    }

    fn count(&self, sql: &str) -> i64 {
        self.conn().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    fn text(&self, sql: &str) -> Option<String> {
        self.conn().query_row(sql, [], |r| r.get(0)).ok()
    }

    /// Rows any tool could have written (the setup's own rows and the three schema keys apart).
    fn written(&self) -> i64 {
        self.count(
            "select (select count(*) from event) + (select count(*) from message) + (select count(*) from card)
                  + (select count(*) from decision)
                  + (select count(*) from agent where seen > 1.0)
                  + (select count(*) from meta where key not in ('schema', 'compat-read', 'migrate-6-dropped'))",
        )
    }
}

/// Call tool NAME as the server does: its check, then its call.  (error?, text).
async fn call_on(coord: &Arc<Coord>, who: &Identity, name: &str, args: Value) -> (bool, String) {
    let all = tools();
    let tool = all
        .iter()
        .find(|t| t.name() == name)
        .unwrap_or_else(|| panic!("no tool {name}"));
    if let Err(e) = tool.check(&args) {
        return (true, e.to_string());
    }
    let ctx = (coord.clone(), who.clone());
    match tool.call(&ctx, args).await {
        ToolResult::Ok { text, .. } => (false, text),
        ToolResult::Err(text) => (true, text),
    }
}

fn session(agent: &str, job: Option<&str>, home: &Path) -> Identity {
    Identity::Session {
        agent: agent.into(),
        job: job.map(str::to_owned),
        task: None,
        home: home.to_path_buf(),
    }
}

/// One valid call of each of this task's tools.
fn report_calls() -> Vec<(&'static str, Value)> {
    vec![
        ("hello", json!({})),
        ("report_edit", json!({"paths": ["a.rs"]})),
        ("report_test", json!({"command": "make"})),
        ("ask_user", json!({"question": "Which?"})),
        ("list_agents", json!({})),
    ]
}

#[tokio::test]
async fn identity_args_are_refused() {
    let w = World::new(&[]);
    let who = session("s-1", None, w.dir.path());
    let all = tools();
    assert!(!all.is_empty());
    for tool in &all {
        for k in IDENTITY_ARGS {
            let mut args = serde_json::Map::new();
            args.insert(k.into(), json!("s-2"));
            let (error, text) = w.call(&who, tool.name(), Value::Object(args)).await;
            assert!(error, "{} took `{k}`: {text}", tool.name());
            assert!(
                text.starts_with(&format!("{k}: ")),
                "{}: {text}",
                tool.name()
            );
        }
    }
    assert_eq!(w.written(), 0, "nothing is written");
}

#[tokio::test]
async fn user_is_never_an_identity() {
    let w = World::new(&[]);
    for id in ["user", "User", " USER ", "uSeR"] {
        let who = session(id, None, w.dir.path());
        for (name, args) in report_calls() {
            let (error, text) = w.call(&who, name, args).await;
            assert!(
                error && text.starts_with("\"user\" is the user"),
                "{id} {name}: {text}"
            );
        }
    }
    assert_eq!(w.written(), 0);
}

#[tokio::test]
async fn none_identity_reads_but_never_writes() {
    let w = World::new(&[]);
    for (name, args) in report_calls() {
        let (error, text) = w.call(&Identity::None, name, args).await;
        if name == "list_agents" {
            assert_eq!((error, text.as_str()), (false, "null"));
        } else {
            assert!(
                error && text.contains("no agent identity"),
                "{name}: {text}"
            );
        }
    }
    assert_eq!(w.written(), 0);
}

#[tokio::test]
async fn outside_is_refused_the_job_tools() {
    let w = World::new(&[
        "insert into job values ('j1', 'Job', null, null, 'running', 1.0, null)",
        "insert into jtask (id, job, n, title, role, status) values ('j1#1', 'j1', 1, 'One', 'implement', 'ready')",
    ]);
    let out = Identity::outside(
        "claude",
        4242,
        Some(1_700_000_000.0),
        Some(w.dir.path().into()),
    )
    .unwrap();
    let refused = "jobs are drgnx's: report your work with report_edit (task j1#1 is for drgnx's own job agents)";
    for name in ["hello", "ask_user"] {
        let args = if name == "hello" {
            json!({"task": "j1#1"})
        } else {
            json!({"question": "ok?", "task": "j1#1"})
        };
        assert_eq!(
            w.call(&out, name, args).await,
            (true, refused.to_string()),
            "{name}"
        );
    }
    // the job tools (Task 8), each as the Lisp refuses it; skipped until they are in the list
    let job_tools = [
        (
            "record_decision",
            json!({"kind": "build", "subject": "s", "reason": "r", "seen_version": 0}),
            "jobs are drgnx's",
        ),
        (
            "claim_task",
            json!({"task": "j1#1", "seen_version": 0}),
            "jobs are drgnx's",
        ),
        (
            "update_task",
            json!({"task": "j1#1", "status": "running", "seen_version": 0}),
            "jobs are drgnx's",
        ),
        (
            "complete_task",
            json!({"task": "j1#1", "seen_version": 0}),
            "jobs are drgnx's",
        ),
        (
            "escalate",
            json!({"subject": "s", "text": "t", "seen_version": 0}),
            "ask the user with ask_user",
        ),
    ];
    let names: Vec<&str> = tools().iter().map(|t| t.name()).collect();
    for (name, args, says) in job_tools {
        if names.contains(&name) {
            let (error, text) = w.call(&out, name, args).await;
            assert!(error && text.contains(says), "{name}: {text}");
        }
    }
    assert_eq!(w.written(), 0);
    assert_eq!(
        w.text("select status || ':' || coalesce(agent, '') from jtask where id = 'j1#1'"),
        Some("ready:".into())
    );
    // what an outside agent may write carries no job and no task
    let (error, text) = w
        .call(&out, "report_test", json!({"command": "make"}))
        .await;
    assert!(!error, "{text}");
    assert!(out.id().unwrap().starts_with("ext:claude:4242-"));
    assert_eq!(
        w.count(&format!(
            "select count(*) from event where agent = '{}' and job is null and task is null",
            out.id().unwrap()
        )),
        1
    );
}

fn held(text: &str) -> bool {
    text.starts_with("HELD: more than 20 reports a minute (20 a minute is the limit)")
}

#[tokio::test]
async fn report_rate_holds_the_21st_and_tells_once_an_hour() {
    let w = World::new(&[]);
    let who = session("s-1", Some("j1"), w.dir.path());
    let report = || w.call(&who, "report_test", json!({"command": "make check"}));
    let cards = || w.count("select count(*) from card where kind = 'rate' and job = 'j1'");
    let t0 = 1_700_000_000.5;
    w.at(t0);
    for i in 0..20 {
        let (error, text) = report().await;
        assert!(!error && !held(&text), "report {i}: {text}");
    }
    let (error, text) = report().await;
    assert!(!error && held(&text), "the 21st is held: {text}");
    assert_eq!(
        w.count("select count(*) from event where kind = 'test'"),
        20,
        "a held report writes nothing"
    );
    assert_eq!(cards(), 1, "the user is told");
    assert_eq!(
        w.text("select value from meta where key = 'rate-told:s-1'"),
        Some(t0.to_string())
    );
    assert!(held(&report().await.1));
    assert_eq!(cards(), 1, "told once");
    // a minute on, the agent reports again; held again within the hour, nobody is told twice
    w.at(t0 + 61.0);
    for _ in 0..20 {
        assert!(!held(&report().await.1));
    }
    assert!(held(&report().await.1));
    assert_eq!(cards(), 1);
    // an hour on, the user is told again
    w.at(t0 + 3700.0);
    for _ in 0..20 {
        assert!(!held(&report().await.1));
    }
    assert!(held(&report().await.1));
    assert_eq!(cards(), 2);
    // a hub started again counts afresh, and the store's stamp keeps the card to one an hour
    let again = w.restarted();
    w.at(t0 + 3710.0);
    for _ in 0..20 {
        assert!(!held(
            &call_on(&again, &who, "report_test", json!({"command": "x"}))
                .await
                .1
        ));
    }
    assert!(held(
        &call_on(&again, &who, "report_test", json!({"command": "x"}))
            .await
            .1
    ));
    assert_eq!(cards(), 2, "the store remembers it told");
    assert!(
        w.hub.notified.load(Ordering::SeqCst) >= 80,
        "every report tells the hub"
    );
}

#[tokio::test]
async fn report_edit_path_rules() {
    let w = World::new(&[]);
    let proj = std::fs::canonicalize(w.dir.path()).unwrap().join("proj");
    std::fs::create_dir(&proj).unwrap();
    let who = session("s-1", None, &proj);
    let (error, text) = w
        .call(
            &who,
            "report_edit",
            json!({"paths": ["src/a.rs", "./b.rs"]}),
        )
        .await;
    assert!(!error, "{text}");
    assert_eq!(serde_json::from_str::<Value>(&text).unwrap()["paths"], 2);
    let data: Value =
        serde_json::from_str(&w.text("select data from event where id = 1").unwrap()).unwrap();
    assert_eq!(
        data,
        json!({"root": proj.to_str().unwrap(), "paths": ["src/a.rs", "b.rs"]})
    );
    for (paths, n) in [
        (json!("x.rs, y.rs"), 2),
        (json!("one.rs\n two, three.rs\n"), 2),
    ] {
        let (error, text) = w.call(&who, "report_edit", json!({"paths": paths})).await;
        assert!(!error, "{text}");
        assert_eq!(serde_json::from_str::<Value>(&text).unwrap()["paths"], n);
    }
    let refusals = [
        (
            "../x",
            "../x has a `..': name it from the folder you work in".to_string(),
        ),
        (
            "a/../../x",
            "a/../../x has a `..': name it from the folder you work in".to_string(),
        ),
        ("/ssh:x:/y", "/ssh:x:/y is not a local path".to_string()),
        (
            "/sudo::/etc/x",
            "/sudo::/etc/x is not a local path".to_string(),
        ),
        (
            "/etc/passwd",
            format!(
                "/etc/passwd is outside {}, the folder you work in",
                proj.display()
            ),
        ),
    ];
    for (path, says) in refusals {
        let (error, text) = w.call(&who, "report_edit", json!({"paths": [path]})).await;
        assert_eq!((error, text), (true, says), "{path}");
    }
    let many: Vec<String> = (0..1001).map(|i| format!("f{i}.rs")).collect();
    let (error, text) = w.call(&who, "report_edit", json!({"paths": many})).await;
    assert_eq!(
        (error, text.as_str()),
        (true, "1001 paths: at most 1000 in one report")
    );
    // a root of `/` is too wide: an agent started in the wrong place
    let wide = session("s-2", None, Path::new("/"));
    let (error, text) = w
        .call(&wide, "report_edit", json!({"paths": ["etc/x"]}))
        .await;
    assert!(
        error && text.starts_with("The folder you work in is / — "),
        "{text}"
    );
    assert_eq!(
        w.count("select count(*) from event"),
        3,
        "only the reports that passed"
    );
}

#[tokio::test]
async fn hello_cwd_must_be_inside_home() {
    let w = World::new(&[]);
    let proj = std::fs::canonicalize(w.dir.path()).unwrap().join("proj");
    std::fs::create_dir_all(proj.join("sub")).unwrap();
    let who = session("s-1", None, &proj);
    let (error, text) = w.call(&who, "hello", json!({"cwd": "/"})).await;
    assert_eq!(
        (error, text),
        (
            true,
            format!(
                "/ is outside {}, the folder this server was started in",
                proj.display()
            )
        )
    );
    let (error, text) = w.call(&who, "hello", json!({"cwd": "missing"})).await;
    assert_eq!(
        (error, text),
        (true, format!("{}/missing is not a folder", proj.display()))
    );
    assert_eq!(w.written(), 0);
    let (error, text) = w
        .call(
            &who,
            "hello",
            json!({"cwd": "sub", "name": "claude · test", "plan": "p\nq"}),
        )
        .await;
    assert!(!error, "{text}");
    let sub = proj.join("sub").to_str().unwrap().to_owned();
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap(),
        json!({"agent": "s-1", "version": 0, "cwd": sub, "worktree": null, "base": null})
    );
    assert_eq!(
        w.text("select name || '|' || cwd || '|' || plan from agent where id = 's-1'"),
        Some(format!("claude · test|{sub}|p q"))
    );
    assert_eq!(
        w.text("select summary from event where kind = 'start'"),
        Some(format!("claude · test started in {sub}"))
    );
    // a later hello without a cwd keeps the registered one
    let (_, text) = w.call(&who, "hello", json!({})).await;
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap()["cwd"],
        json!(sub)
    );
    // an outside bridge that named no folder has none to register
    let lost = Identity::outside("zed", 7, Some(1.0), None).unwrap();
    let (error, text) = w.call(&lost, "hello", json!({})).await;
    assert!(
        error && text.starts_with("No folder is known for you"),
        "{text}"
    );
}

fn script(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// git for the fixture itself: no overrides, `HOME` in the temporary root.
fn plain_git(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}");
    String::from_utf8(out.stdout).unwrap().trim().to_owned()
}

#[tokio::test]
async fn hello_git_read_runs_no_hook_or_fsmonitor() {
    let w = World::new(&[]);
    let root = std::fs::canonicalize(w.dir.path()).unwrap();
    let repo = root.join("repo");
    plain_git(
        &root,
        &root,
        &["-c", "init.defaultBranch=main", "init", "-q", "repo"],
    );
    std::fs::write(repo.join("a"), "a\n").unwrap();
    plain_git(&root, &repo, &["add", "a"]);
    plain_git(
        &root,
        &repo,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "one",
        ],
    );
    let canary = root.join("canary");
    let c = canary.display();
    for hook in [
        "post-checkout",
        "post-index-change",
        "reference-transaction",
        "pre-auto-gc",
    ] {
        script(
            &repo.join(".git/hooks").join(hook),
            &format!("echo {hook} >> '{c}'"),
        );
    }
    let fsmon = root.join("fsmonitor");
    script(&fsmon, &format!("echo fsmonitor >> '{c}'; exit 1"));
    plain_git(
        &root,
        &repo,
        &["config", "core.fsmonitor", fsmon.to_str().unwrap()],
    );
    let head = plain_git(&root, &repo, &["rev-parse", "HEAD"]);

    let who = session("s-1", None, &repo);
    let (error, text) = w.call(&who, "hello", json!({})).await;
    assert!(!error, "{text}");
    let answer: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(answer["worktree"], json!(repo.to_str().unwrap()));
    assert_eq!(answer["base"], json!(head));
    assert_eq!(
        w.text("select branch from agent where id = 's-1'"),
        Some("main".into())
    );
    assert!(
        !canary.exists(),
        "a hook or the fsmonitor ran: {:?}",
        std::fs::read_to_string(&canary)
    );
    // the control: plain git runs the planted fsmonitor
    plain_git(&root, &repo, &["status", "--porcelain"]);
    assert!(
        canary.exists(),
        "the fixture's fsmonitor never ran, so the test proves nothing"
    );
}

// ---- the Lisp oracle's cases ----

/// "__REP:C:N__" is the character C, N times.
fn expand(v: Value) -> Value {
    match v {
        Value::String(s) => {
            let rep = s
                .strip_prefix("__REP:")
                .and_then(|r| r.strip_suffix("__"))
                .and_then(|r| r.split_once(':'));
            match rep {
                Some((c, n)) if c.chars().count() == 1 => {
                    Value::String(c.repeat(n.parse().expect("repeat count")))
                }
                _ => Value::String(s),
            }
        }
        Value::Array(a) => Value::Array(a.into_iter().map(expand).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, expand(v))).collect()),
        v => v,
    }
}

/// Every number as a float, so `100` and `100.0` compare equal.
fn norm(v: Value) -> Value {
    match v {
        Value::Number(n) => json!(n.as_f64().unwrap()),
        Value::Array(a) => Value::Array(a.into_iter().map(norm).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, norm(v))).collect()),
        v => v,
    }
}

/// One table as the oracle dumps it: rows in rowid order (`meta` by key), `data` parsed.
fn dump(conn: &Connection, table: &str) -> Value {
    let cols: Vec<String> = {
        let mut st = conn
            .prepare("select name from pragma_table_info(?1)")
            .unwrap();
        st.query_map([table], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    };
    let pairs: Vec<String> = cols.iter().map(|c| format!("'{c}', \"{c}\"")).collect();
    let order = if table == "meta" { "key" } else { "rowid" };
    let sql = format!(
        "select coalesce(json_group_array(json_object({})), '[]') from (select * from {table} order by {order})",
        pairs.join(", ")
    );
    let text: String = conn.query_row(&sql, [], |r| r.get(0)).unwrap();
    let mut rows: Value = serde_json::from_str(&text).unwrap();
    for row in rows.as_array_mut().unwrap() {
        if let Some(Value::String(d)) = row.get("data").cloned() {
            row["data"] = serde_json::from_str(&d).unwrap();
        }
    }
    rows
}

/// The identity a case's call names: {agent, job?, task?} (a session), {outside, tag} or null.
fn identity_of(v: &Value) -> Identity {
    let text = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    if v.is_null() {
        Identity::None
    } else if let Some(kind) = text("outside") {
        Identity::Outside {
            id: format!("ext:{kind}:{}", text("tag").unwrap()),
            kind,
            home: None,
        }
    } else {
        Identity::Session {
            agent: text("agent").unwrap(),
            job: text("job"),
            task: text("task"),
            home: PathBuf::from("/nonexistent-parity"),
        }
    }
}

/// A tool's text as compared: JSON as its value (the key order is the answer structs'), any other text as itself.
fn answer(v: &Value) -> Value {
    let mut v = v.clone();
    if let Some(Value::String(t)) = v.get("text")
        && let Ok(parsed) = serde_json::from_str::<Value>(t)
    {
        v["text"] = norm(parsed);
    }
    v
}

#[tokio::test]
async fn every_tool_fixture_replays() {
    let dir = fixtures().join("coord-parity");
    let mut inputs: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            let name = p.file_name().unwrap().to_string_lossy();
            name.starts_with("tools-") && name.ends_with(".input.json")
        })
        .collect();
    inputs.sort();
    assert!(!inputs.is_empty(), "no tool cases in {}", dir.display());
    for path in inputs {
        let name = path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .replace(".input.json", "");
        let input = expand(serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap());
        let expect = expand(
            serde_json::from_slice(
                &std::fs::read(dir.join(format!("{name}.expect.json"))).unwrap(),
            )
            .unwrap(),
        );
        let setup: Vec<&str> = input["setup"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap())
            .collect();
        let w = World::new(&setup);
        let calls = input["calls"].as_array().unwrap();
        let wanted = expect["results"].as_array().unwrap();
        assert_eq!(calls.len(), wanted.len(), "case {name}");
        for (i, (call, want)) in calls.iter().zip(wanted).enumerate() {
            w.at(call["now"].as_f64().expect("a tool call names its time"));
            let who = identity_of(&call["identity"]);
            let (error, text) = w
                .call(&who, call["tool"].as_str().unwrap(), call["args"].clone())
                .await;
            let mut got = serde_json::Map::new();
            got.insert(
                if error { "error" } else { "text" }.into(),
                Value::String(text),
            );
            let got = Value::Object(got);
            assert_eq!(answer(&got), answer(want), "case {name}, call {i}");
        }
        let conn = w.conn();
        for (table, rows) in expect["tables"].as_object().unwrap() {
            assert_eq!(
                norm(dump(&conn, table)),
                norm(rows.clone()),
                "case {name}, table {table}"
            );
        }
    }
}
