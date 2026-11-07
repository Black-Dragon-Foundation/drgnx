//! The hub's side of a terminal's life: adoption by pid and start time, the hello's protocol, the session's grace.
//! The workers here are fakes on the terminal's socket (the real worker's rows are in drgnx-term's tests).

use super::*;
use drgnx_term::proto::PROTO;
use tokio::net::UnixListener;

#[derive(Default)]
struct Events(Mutex<Vec<(u64, String, Value)>>);

impl Sink for Events {
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.0.lock().unwrap().push((conn, event.to_owned(), data));
        true
    }
}

/// A fake worker on SOCKET: says hello with PROTO, then hands each line it reads to the receiver.
fn fake_worker(socket: &Path, proto: (u32, u32)) -> mpsc::UnboundedReceiver<In> {
    let l = UnixListener::bind(socket).unwrap();
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let (s, _) = l.accept().await.unwrap();
        let (r, mut w) = s.into_split();
        let hello = Out::Hello {
            proto,
            pid: std::process::id(),
            shell_pid: 4242,
        };
        let line = serde_json::to_string(&hello).unwrap() + "\n";
        w.write_all(line.as_bytes()).await.unwrap();
        let mut r = BufReader::new(r);
        let mut line = String::new();
        while r.read_line(&mut line).await.unwrap_or(0) > 0 {
            if let Ok(m) = serde_json::from_str::<In>(&line) {
                let _ = tx.send(m);
            }
            line.clear();
        }
        drop(w);
    });
    rx
}

/// A record of this process (alive, by pid and start time) for terminal ID in DIR.
fn record(dir: &Path, id: &str, session: &str) -> Record {
    let pid = std::process::id() as i32;
    let rec = Record {
        id: id.into(),
        unit: None,
        pid,
        start_time: draugr::start_time(pid).unwrap(),
        shell_pid: Some(4242),
        socket: dir.join(format!("{id}.sock")),
        view: format!("term:{id}"),
        class: "gui".into(),
        cwd: "/".into(),
        session: Some(session.into()),
    };
    rec.write(dir).unwrap();
    rec
}

async fn next(rx: &mut mpsc::UnboundedReceiver<In>) -> In {
    crate::clock::timeout(Duration::from_secs(5), rx.recv())
        .await
        .expect("the worker heard nothing")
        .expect("the hub dropped the worker")
}

async fn open(dir: &Path) -> (Terms, Arc<Events>) {
    let t = Terms::default();
    let ev = Arc::new(Events::default());
    t.open(dir.to_path_buf(), ev.clone(), 7).await;
    (t, ev)
}

#[tokio::test]
async fn adopts_by_pid_and_start_time_without_systemd() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    let rec = record(dir, "aa", "s1");
    let mut rx = fake_worker(&rec.socket, PROTO);
    // a worker that died while no hub ran: a pid that is not the process of its start time
    let mut dead = record(dir, "bb", "s1");
    dead.start_time += 1;
    dead.write(dir).unwrap();
    let (t, ev) = open(dir).await;
    assert_eq!(
        t.record("aa").map(|r| r.shell_pid),
        Some(Some(4242)),
        "adopted"
    );
    assert_eq!(t.is_old("aa"), Some(false));
    assert!(t.record("bb").is_none(), "the dead one is not adopted");
    assert!(!dir.join("bb.json").exists(), "its record goes");
    // its session says hello again: the worker draws for that connection, from a reset
    t.hello(3, "s1");
    match next(&mut rx).await {
        In::Attach {
            view, class, hub, ..
        } => assert_eq!((view.as_str(), class.as_str(), hub), ("term:aa", "gui", 7)),
        m => panic!("expected an attach, got {m:?}"),
    }
    assert!(t.send("aa", &In::Text { text: "x".into() }));
    assert!(matches!(next(&mut rx).await, In::Text { .. }));
    let _ = ev;
}

#[tokio::test]
async fn old_minor_protocol_is_adopted() {
    let tmp = tempfile::tempdir().unwrap();
    let rec = record(tmp.path(), "aa", "s1");
    let mut rx = fake_worker(&rec.socket, (PROTO.0, PROTO.1 + 5));
    let (t, _ev) = open(tmp.path()).await;
    assert_eq!(
        t.is_old("aa"),
        Some(false),
        "a newer minor speaks this hub's protocol"
    );
    assert!(t.send("aa", &In::Text { text: "x".into() }));
    assert!(matches!(next(&mut rx).await, In::Text { .. }));
}

#[tokio::test]
async fn major_mismatch_marks_terminal_old() {
    let tmp = tempfile::tempdir().unwrap();
    let rec = record(tmp.path(), "aa", "s1");
    let mut rx = fake_worker(&rec.socket, (PROTO.0 + 1, 0));
    let (t, _ev) = open(tmp.path()).await;
    assert_eq!(t.is_old("aa"), Some(true), "from before the update");
    assert!(
        !t.send("aa", &In::Text { text: "x".into() }),
        "nothing but close is sent to it"
    );
    let st = t.list(Duration::from_millis(200)).await;
    assert!(
        st[0].old && st[0].running,
        "listed as old, its program counted as running: {st:?}"
    );
    assert!(t.send("aa", &In::Close { signal: None }));
    assert!(matches!(next(&mut rx).await, In::Close { .. }));
}

#[tokio::test]
async fn session_gone_after_60s_ends_worker() {
    let tmp = tempfile::tempdir().unwrap();
    let rec = record(tmp.path(), "aa", "s1");
    let mut rx = fake_worker(&rec.socket, PROTO);
    let (t, _ev) = open(tmp.path()).await;
    t.hello(3, "s1");
    assert!(matches!(next(&mut rx).await, In::Attach { .. }));
    t.gone_at(3, 1_000);
    t.tick(1_000 + life::GRACE_MS - 1);
    // a reconnect within the grace keeps it
    t.hello(4, "s1");
    assert!(matches!(next(&mut rx).await, In::Attach { .. }));
    t.tick(1_000 + life::GRACE_MS + 1);
    t.gone_at(4, 100_000);
    t.tick(100_000 + life::GRACE_MS - 1);
    assert!(rx.try_recv().is_err(), "nothing before the grace ran out");
    t.tick(100_000 + life::GRACE_MS);
    assert!(
        matches!(next(&mut rx).await, In::Close { signal: None }),
        "the session is gone: its worker ends"
    );
}

#[tokio::test]
async fn hello_alone_keeps_terminals_where_they_draw() {
    let tmp = tempfile::tempdir().unwrap();
    let rec = record(tmp.path(), "aa", "s1");
    let mut rx = fake_worker(&rec.socket, PROTO);
    let (t, _ev) = open(tmp.path()).await;
    // a connection of the session that does not subscribe (the editor's call connection) moves nothing
    t.note_session(5, "s1");
    assert_eq!(t.session_of(5).as_deref(), Some("s1"));
    assert!(t.send("aa", &In::Text { text: "x".into() }));
    assert!(
        matches!(next(&mut rx).await, In::Text { .. }),
        "no attach came before the text"
    );
}

#[tokio::test]
async fn clean_exit_closes_at_once() {
    let tmp = tempfile::tempdir().unwrap();
    let a = record(tmp.path(), "aa", "s1");
    let b = record(tmp.path(), "bb", "s2");
    let mut ra = fake_worker(&a.socket, PROTO);
    let mut rb = fake_worker(&b.socket, PROTO);
    let (t, _ev) = open(tmp.path()).await;
    t.end_session("s1");
    assert!(matches!(next(&mut ra).await, In::Close { signal: None }));
    assert!(rb.try_recv().is_err(), "another session's terminal stays");
}

#[tokio::test]
async fn exit_reaches_the_owner_and_the_record_goes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    let rec = record(dir, "aa", "s1");
    let l = UnixListener::bind(&rec.socket).unwrap();
    let worker = tokio::spawn(async move {
        let (s, _) = l.accept().await.unwrap();
        let (_r, mut w) = s.into_split();
        for out in [
            Out::Hello {
                proto: PROTO,
                pid: 1,
                shell_pid: 4242,
            },
            Out::Title {
                title: "vim".into(),
            },
            Out::Exit {
                code: Some(0),
                signal: None,
            },
        ] {
            w.write_all((serde_json::to_string(&out).unwrap() + "\n").as_bytes())
                .await
                .unwrap();
            // the hub reassigns the owner at its hello first
            crate::clock::sleep(Duration::from_millis(100)).await;
        }
    });
    let (t, ev) = open(dir).await;
    t.hello(3, "s1");
    crate::clock::timeout(Duration::from_secs(5), worker)
        .await
        .expect("the hub never connected to the worker")
        .unwrap();
    for _ in 0..50 {
        if t.record("aa").is_none() {
            break;
        }
        crate::clock::sleep(Duration::from_millis(20)).await;
    }
    assert!(t.record("aa").is_none());
    assert!(!dir.join("aa.json").exists(), "its record goes");
    let got: Vec<(u64, String)> =
        ev.0.lock()
            .unwrap()
            .iter()
            .map(|(c, e, _)| (*c, e.clone()))
            .collect();
    assert_eq!(
        got,
        [(3, "term/title".to_owned()), (3, "term/exit".to_owned())]
    );
}
