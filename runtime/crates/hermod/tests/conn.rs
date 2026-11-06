//! hermod against scripted children: `/bin/sh` scripts that print canned JSON-RPC lines, and for a fork the mock agent
//! (`ratatoskr-mock acp`, a real process; a test waits for its answers and reads its log after them).

use hermod::schema::v1::{
    PermissionOptionId, RequestPermissionOutcome, RequestPermissionResponse, SessionUpdate,
};
use hermod::{
    ClientCaps, Conn, ConnOpts, Dir, Error, Event, ForkInto, ForkPoint, Incoming, LineTap,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc::Receiver;

const INIT: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}"#;
const NEW: &str = r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#;

fn upd(body: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{body}}}}}"#
    )
}

fn chunk(text: &str, id: Option<&str>) -> String {
    let mid = id.map_or(String::new(), |i| format!(r#","messageId":"{i}""#));
    upd(&format!(
        r#"{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":"{text}"}}{mid}}}"#
    ))
}

/// A script that answers `initialize` and `session/new` (two reads), then runs REST.
fn script(rest: &str) -> String {
    format!("read a; printf '%s\\n' '{INIT}'; read b; printf '%s\\n' '{NEW}'; {rest}")
}

fn spec(script: &str) -> draugr::Spec {
    draugr::Spec {
        program: "/bin/sh".into(),
        args: vec!["-c".into(), script.into()],
        env: draugr::env::build(&["PATH"], &[], &[]),
        cwd: None,
        stdin_null: false,
        pass_fds: vec![],
        new_session: false,
    }
}

fn opts() -> ConnOpts {
    ConnOpts {
        deadline: Duration::from_secs(10),
        stderr_tail: 4000,
        ..ConnOpts::default()
    }
}

async fn start(script: &str, opts: ConnOpts) -> (Conn, Receiver<Event>) {
    Conn::spawn(spec(script), opts).await.expect("spawn")
}

async fn open(conn: &Conn) -> hermod::SessionId {
    conn.initialize(ClientCaps::default())
        .await
        .expect("initialize");
    conn.new_session(Path::new("/work"), vec![], None)
        .await
        .expect("session/new")
}

async fn next(rx: &mut Receiver<Event>) -> Event {
    tokio::time::timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("an event in time")
        .expect("the channel is open")
}

#[tokio::test]
async fn initialize_then_session() {
    let (conn, mut rx) = start(&script("cat >/dev/null"), opts()).await;
    let info = conn.initialize(ClientCaps::default()).await.unwrap();
    assert!(info.auth.is_empty());
    assert!(info.meta.is_none());
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    assert_eq!(&*sid.0, "s1");
    drop(conn);
    assert!(matches!(
        next(&mut rx).await,
        Event::Exit { code: Some(0), .. }
    ));
}

#[tokio::test]
async fn every_update_is_stamped_on_receipt() {
    let rest = format!(
        "printf '%s\\n' '{}' '{}' '{}'; cat >/dev/null",
        chunk("a", None),
        chunk("b", None),
        chunk("c", None)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    let before = hermod::stamp::now();
    open(&conn).await;
    let mut stamps = vec![];
    while stamps.len() < 3 {
        if let Event::Update { at, sid, .. } = next(&mut rx).await {
            assert_eq!(&*sid.0, "s1");
            stamps.push(at);
        }
    }
    let after = hermod::stamp::now();
    assert!(
        stamps.windows(2).all(|w| w[0] <= w[1]),
        "stamps never go back: {stamps:?}"
    );
    assert!(
        stamps[0] >= before && stamps[2] <= after,
        "{before} <= {stamps:?} <= {after}"
    );
}

#[tokio::test]
async fn message_ids_are_kept() {
    let rest = format!(
        "printf '%s\\n' '{}' '{}'; cat >/dev/null",
        chunk("a", Some("m1")),
        chunk("b", None)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    open(&conn).await;
    let mut ids = vec![];
    while ids.len() < 2 {
        if let Event::Update {
            message_id, update, ..
        } = next(&mut rx).await
        {
            assert!(matches!(update, SessionUpdate::AgentMessageChunk(_)));
            ids.push(message_id);
        }
    }
    assert_eq!(ids, vec![Some("m1".to_string()), None]);
}

#[tokio::test]
async fn a_request_gets_a_responder_and_an_unanswered_one_is_cancelled_at_exit() {
    let req = |id: u32| {
        format!(
            r#"{{"jsonrpc":"2.0","id":{id},"method":"session/request_permission","params":{{"sessionId":"s1","toolCall":{{"toolCallId":"t{id}"}},"options":[{{"optionId":"yes","name":"Yes","kind":"allow_once"}}]}}}}"#
        )
    };
    // the first reply is echoed to stderr; the second request is never answered
    let rest = format!(
        "printf '%s\\n' '{}'; read r; echo \"$r\" >&2; printf '%s\\n' '{}'; sleep 0.3",
        req(100),
        req(101)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    open(&conn).await;
    let Event::Request(Incoming::Permission(p, responder)) = next(&mut rx).await else {
        panic!("a permission request")
    };
    assert_eq!(&*p.tool_call.tool_call_id.0, "t100");
    let outcome = RequestPermissionOutcome::Selected(
        hermod::schema::v1::SelectedPermissionOutcome::new(PermissionOptionId::new("yes")),
    );
    responder
        .respond(RequestPermissionResponse::new(outcome))
        .unwrap();
    let Event::Request(Incoming::Permission(_, mut second)) = next(&mut rx).await else {
        panic!("the second request")
    };
    assert!(!second.is_cancelled());
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    assert!(
        stderr.contains(r#""id":100"#) && stderr.contains("selected"),
        "{stderr}"
    );
    assert!(second.is_cancelled());
    second.cancelled().await;
    assert!(matches!(
        second.respond(RequestPermissionResponse::new(
            RequestPermissionOutcome::Cancelled
        )),
        Err(Error::Closed)
    ));
}

#[tokio::test]
async fn exit_comes_once_with_the_stderr_tail() {
    let rest = "echo 'a long first line that gets cut off, then boom' >&2; exit 3";
    let o = ConnOpts {
        stderr_tail: 10,
        ..opts()
    };
    let (conn, mut rx) = start(&script(rest), o).await;
    open(&conn).await;
    let Event::Exit {
        code,
        signal,
        stderr,
    } = next(&mut rx).await
    else {
        panic!("exit")
    };
    assert_eq!((code, signal), (Some(3), None));
    assert!(
        stderr.chars().count() <= 10 && stderr.trim_end().ends_with("boom"),
        "{stderr:?}"
    );
    assert!(
        rx.recv().await.is_none(),
        "no second Exit, nothing after it"
    );
    assert!(matches!(
        conn.set_mode(&hermod::SessionId::new("s1"), "code").await,
        Err(Error::Closed)
    ));
}

#[tokio::test]
async fn a_deadline_fails_the_call_not_the_conn() {
    // the first session/new is never answered; the second is
    let rest = format!(
        "read c; read d; printf '%s\\n' '{}'; cat >/dev/null",
        r#"{"jsonrpc":"2.0","id":4,"result":{"sessionId":"s9"}}"#
    );
    let o = ConnOpts {
        deadline: Duration::from_millis(300),
        ..opts()
    };
    let (conn, _rx) = start(&script(&rest), o).await;
    open(&conn).await;
    let r = conn.new_session(Path::new("/work"), vec![], None).await;
    assert!(
        matches!(r, Err(Error::Deadline(ref m)) if m == "session/new"),
        "{r:?}"
    );
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    assert_eq!(&*sid.0, "s9");
}

/// A line tap that keeps what it sees: each line with its direction and instant, and the exit.
#[derive(Default)]
struct Kept {
    lines: std::sync::Mutex<Vec<(Dir, String, std::time::Instant)>>,
    exits: std::sync::Mutex<Vec<(Option<i32>, String)>>,
}

impl LineTap for Kept {
    fn line(&self, dir: Dir, line: &str, at: std::time::Instant) {
        self.lines.lock().unwrap().push((dir, line.to_owned(), at));
    }
    fn exit(&self, code: Option<i32>, _signal: Option<i32>, stderr: &str) {
        self.exits.lock().unwrap().push((code, stderr.to_owned()));
    }
}

// Pattern C (handshake): every line the tap is asked about was answered or seen as an event first, and the exit comes
// after the child's own Exit event.
#[tokio::test]
async fn a_tap_sees_both_directions_in_order() {
    let tap = std::sync::Arc::new(Kept::default());
    let o = ConnOpts {
        tap: Some(tap.clone()),
        ..opts()
    };
    let rest = format!(
        "printf '%s\\n' '{}'; read p; echo tapped >&2; exit 0",
        chunk("a", None)
    );
    let (conn, mut rx) = start(&script(&rest), o).await;
    open(&conn).await;
    while !matches!(next(&mut rx).await, Event::Update { .. }) {}
    conn.cancel(&hermod::SessionId::new("s1")).unwrap();
    let Event::Exit { code, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    assert_eq!(code, Some(0));
    let lines = tap.lines.lock().unwrap().clone();
    let seen: Vec<(Dir, String)> = lines
        .iter()
        .map(|(d, l, _)| {
            let v: Value = serde_json::from_str(l).expect("a JSON line");
            let what = v["method"]
                .as_str()
                .map_or_else(|| format!("answer {}", v["id"]), str::to_owned);
            (*d, what)
        })
        .collect();
    assert_eq!(
        seen,
        vec![
            (Dir::In, "initialize".to_string()),
            (Dir::Out, "answer 1".to_string()),
            (Dir::In, "session/new".to_string()),
            (Dir::Out, "answer 2".to_string()),
            (Dir::Out, "session/update".to_string()),
            (Dir::In, "session/cancel".to_string()),
        ]
    );
    assert!(
        lines.windows(2).all(|w| w[0].2 <= w[1].2),
        "the instants never go back"
    );
    let exits = tap.exits.lock().unwrap().clone();
    assert!(
        matches!(&exits[..], [(Some(0), stderr)] if stderr.contains("tapped")),
        "{exits:?}"
    );
}

fn fork_of(source: &hermod::SessionId, cwd: &str, at: Option<&str>) -> ForkInto {
    ForkInto {
        source: source.clone(),
        cwd: cwd.into(),
        mcp: vec![],
        at: at.map(|m| ForkPoint {
            message_id: m.into(),
        }),
        meta: None,
    }
}

#[tokio::test]
async fn fork_sends_the_jetbrains_meta() {
    let rest = r#"read f; echo "$f" >&2; printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s2"}}'; cat >/dev/null"#;
    let (conn, mut rx) = start(&script(rest), opts()).await;
    let sid = open(&conn).await;
    let mut f = fork_of(&sid, "/elsewhere", Some("m7"));
    // a meta of the caller's own under `jetbrains` stays beside the fork point
    f.meta = Some(json!({"jetbrains": {"other": 1}, "claudeCode": {"options": {"x": 1}}}));
    let forked = conn.fork_into(f).await.unwrap();
    assert_eq!(&*forked.0, "s2");
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    let sent: Value = serde_json::from_str(stderr.trim()).unwrap();
    assert_eq!(sent["method"], "session/fork");
    assert_eq!(sent["params"]["sessionId"], "s1");
    assert_eq!(sent["params"]["cwd"], "/elsewhere");
    assert_eq!(sent["params"]["mcpServers"], json!([]));
    let meta = &sent["params"]["_meta"];
    let fork = &meta["jetbrains"]["air"]["fork"];
    assert_eq!(
        (fork["version"].as_i64(), fork["messageId"].as_str()),
        (Some(1), Some("m7"))
    );
    assert_eq!(meta["jetbrains"]["other"], 1);
    assert_eq!(meta["claudeCode"]["options"]["x"], 1);
}

/// `ratatoskr-mock` (domr's binary): `RATATOSKR_MOCK`, else beside this test's binary (`target/<profile>/`), built
/// there once when it is missing.
fn mock_bin() -> PathBuf {
    static BIN: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    BIN.get_or_init(|| {
        if let Some(p) = std::env::var_os("RATATOSKR_MOCK") {
            return p.into();
        }
        let exe = std::env::current_exe().unwrap();
        let dir = exe.parent().and_then(Path::parent).unwrap().to_path_buf();
        let bin = dir.join("ratatoskr-mock");
        if !bin.exists() {
            let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
            let profile = dir.file_name().unwrap().to_str().unwrap();
            let profile = if profile == "debug" { "dev" } else { profile };
            let ok = std::process::Command::new(cargo)
                .args([
                    "build",
                    "-p",
                    "domr",
                    "--bin",
                    "ratatoskr-mock",
                    "--profile",
                ])
                .arg(profile)
                .arg("--target-dir")
                .arg(dir.parent().unwrap())
                .status()
                .unwrap()
                .success();
            assert!(ok && bin.exists(), "ratatoskr-mock is not built");
        }
        bin
    })
    .clone()
}

/// The mock agent's files, in a folder of the test's own under the temporary directory: its `--state` folder and its
/// logs, one per process.  Removed when dropped.
struct Mock {
    dir: PathBuf,
}

impl Drop for Mock {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Mock {
    fn new() -> Mock {
        static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("hermod-mock-{}-{n}", std::process::id()));
        std::fs::create_dir_all(dir.join("state")).unwrap();
        Mock { dir }
    }

    /// A mock `--as claude` process with the shared state and its own LOG, initialized; its events drained.
    async fn start(&self, log: &str) -> Conn {
        let p = |s: &str| self.dir.join(s).into_os_string();
        let spec = draugr::Spec {
            program: mock_bin(),
            args: vec![
                "acp".into(),
                "--as".into(),
                "claude".into(),
                "--log".into(),
                p(log),
                "--state".into(),
                p("state"),
            ],
            env: draugr::env::build(&["PATH"], &[], &[]),
            cwd: None,
            stdin_null: false,
            pass_fds: vec![],
            new_session: false,
        };
        let (conn, mut rx) = Conn::spawn(spec, opts()).await.expect("spawn the mock");
        tokio::spawn(async move { while rx.recv().await.is_some() {} });
        conn.initialize(ClientCaps::default())
            .await
            .expect("initialize");
        conn
    }

    /// The values of KEY in LOG, in order.
    fn logged(&self, log: &str, key: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.join(log))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v.get(key).cloned())
            .collect()
    }
}

async fn say(conn: &Conn, sid: &hermod::SessionId, text: &str) {
    let block = hermod::ContentBlock::Text(hermod::schema::v1::TextContent::new(text));
    conn.prompt(sid, vec![block], None).await.expect("a turn");
}

#[tokio::test]
async fn fork_into_carries_cwd_mcp_and_lock_meta() {
    let m = Mock::new();
    let conn = m.start("a.log").await;
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    let mcp: hermod::McpServer = serde_json::from_value(
        json!({"name": "drgnx", "command": "/bin/true", "args": ["mcp-bridge"], "env": []}),
    )
    .unwrap();
    let mut f = fork_of(&sid, "/elsewhere", None);
    f.mcp = vec![mcp];
    f.meta = Some(json!({"claudeCode": {"options": {"permissionMode": "default"}}}));
    let forked = conn.fork_into(f).await.unwrap();
    let line = &m.logged("a.log", "session/fork")[0];
    assert_eq!(line["sessionId"], json!(&*forked.0));
    assert_eq!(line["cwd"], "/elsewhere");
    assert_eq!(line["mcpServers"][0]["name"], "drgnx");
    assert_eq!(line["claude_options"]["permissionMode"], "default");
}

#[tokio::test]
async fn fork_into_keeps_the_lock_meta_beside_the_fork_point() {
    let m = Mock::new();
    let conn = m.start("a.log").await;
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    say(&conn, &sid, "hello").await;
    let mut f = fork_of(&sid, "/work", Some("a-1-1"));
    f.meta = Some(json!({"claudeCode": {"options": {"permissionMode": "default"}}}));
    conn.fork_into(f).await.unwrap();
    let line = &m.logged("a.log", "session/fork")[0];
    assert_eq!(line["claude_options"]["permissionMode"], "default");
    assert_eq!(line["messageId"], "a-1-1");
    assert_eq!(line["kept"], 2, "the user's message and the first answer");
}

#[tokio::test]
async fn fork_into_works_on_a_connection_that_never_saw_the_session() {
    let m = Mock::new();
    let first = m.start("a.log").await;
    let sid = first
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    say(&first, &sid, "hello").await;
    drop(first);
    let second = m.start("b.log").await;
    let forked = second
        .fork_into(fork_of(&sid, "/work", None))
        .await
        .expect("a fork on a fresh connection");
    assert_ne!(forked, sid);
    let line = &m.logged("b.log", "session/fork")[0];
    assert_eq!(line["from"], json!(&*sid.0));
    assert_eq!(line["kept"], 3, "the whole history");
}

#[tokio::test]
async fn fork_into_unknown_message_is_an_error() {
    let m = Mock::new();
    let conn = m.start("a.log").await;
    let sid = conn
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    say(&conn, &sid, "hello").await;
    let r = conn.fork_into(fork_of(&sid, "/work", Some("nope"))).await;
    assert!(matches!(r, Err(Error::Rpc { code: -32602, .. })), "{r:?}");
    assert!(m.logged("a.log", "session/fork").is_empty());
}

#[tokio::test]
async fn fork_from_a_second_process_reads_state() {
    let m = Mock::new();
    let first = m.start("a.log").await;
    let sid = first
        .new_session(Path::new("/work"), vec![], None)
        .await
        .unwrap();
    say(&first, &sid, "one").await;
    say(&first, &sid, "two").await;
    drop(first);
    let second = m.start("b.log").await;
    let forked = second
        .fork_into(fork_of(&sid, "/work", Some("a-1-2")))
        .await
        .unwrap();
    let line = &m.logged("b.log", "session/fork")[0];
    assert_eq!(
        (line["kept"].as_u64(), line["turns"].as_u64()),
        (Some(3), Some(1)),
        "the cut: turn one's three messages"
    );
    // the fork goes on from the cut: its next turn is the second
    say(&second, &forked, "three").await;
    let prompts = m.logged("b.log", "prompt");
    assert_eq!(prompts[0]["turn"], 2);
    assert_eq!(prompts[0]["sessionId"], json!(&*forked.0));
}

#[tokio::test]
async fn unknown_notifications_are_ignored_unknown_requests_get_32601() {
    let rest = format!(
        r#"printf '%s\n' '{{"jsonrpc":"2.0","method":"foo/bar","params":{{}}}}' '{{"jsonrpc":"2.0","id":50,"method":"terminal/create","params":{{"sessionId":"s1","command":"ls"}}}}' '{}'; read r; echo "$r" >&2"#,
        chunk("x", None)
    );
    let (conn, mut rx) = start(&script(&rest), opts()).await;
    open(&conn).await;
    assert!(
        matches!(next(&mut rx).await, Event::Update { .. }),
        "the update after the unknown ones"
    );
    // our side queued the answer to the terminal request before the update above reached us, and the writer
    // sends everything queued before it closes the child's stdin; the child then echoes that line
    drop(conn);
    let Event::Exit { stderr, .. } = next(&mut rx).await else {
        panic!("exit")
    };
    assert!(
        stderr.contains("-32601") && stderr.contains(r#""id":50"#),
        "{stderr}"
    );
}

/// The stderr a child wrote before it said anything is readable while it runs (a sandbox's complaint before the
/// status line), from any thread.
#[tokio::test]
async fn stderr_is_readable_while_the_child_runs() {
    let (conn, _rx) = start("echo 'bwrap: no permission' >&2; cat >/dev/null", opts()).await;
    let tail = conn.stderr();
    tokio::task::spawn_blocking(move || {
        skuld::wait_until("the child's stderr holds its complaint", 10, || {
            tail.get().contains("bwrap: no permission").then_some(())
        });
    })
    .await
    .unwrap();
}

/// An agent's child is forked from draugr's pinned thread: a parent-death signal (what bwrap's `--die-with-parent`
/// sets) does not fire when the thread that called `Conn::spawn` retires.  Linux only (PR_SET_PDEATHSIG; util-linux's
/// setpriv).
#[cfg(target_os = "linux")]
#[test]
fn the_agent_survives_its_callers_thread() {
    let (stopped_tx, mut stopped) = tokio::sync::mpsc::unbounded_channel();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_keep_alive(Duration::from_millis(100))
        .on_thread_stop(move || {
            // this thread's own /proc entry: "PID/task/TID"
            let _ = stopped_tx.send(std::fs::read_link("/proc/thread-self").ok());
        })
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let mut spec = spec(&format!("read a; printf '%s\\n' '{INIT}'; cat >/dev/null"));
        let mut args: Vec<std::ffi::OsString> = ["--pdeathsig", "KILL", "--", "/bin/sh"]
            .map(Into::into)
            .to_vec();
        args.append(&mut spec.args);
        spec.program = "/usr/bin/setpriv".into();
        spec.args = args;
        let (conn, _rx) = tokio::task::spawn_blocking(|| {
            tokio::runtime::Handle::current().block_on(Conn::spawn(spec, opts()))
        })
        .await
        .unwrap()
        .expect("spawn");
        // the blocking thread retires after 100 ms idle; wait until its /proc entry is gone (the kernel has sent
        // the signals of its exit by then)
        let task = tokio::time::timeout(Duration::from_secs(30), stopped.recv())
            .await
            .expect("the blocking thread retired within 30 s")
            .flatten()
            .expect("its /proc entry");
        let entry = Path::new("/proc").join(task);
        tokio::time::timeout(Duration::from_secs(30), async {
            while entry.exists() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the retired thread exited within 30 s");
        conn.initialize(ClientCaps::default())
            .await
            .expect("the agent is alive after its caller's thread is gone");
    });
}
