//! The hub's side of a terminal's life: adoption by pid and start time, the hello's protocol, the session's grace.
//! The workers here are fakes on the terminal's socket (the real worker's rows are in drgnx-term's tests).

use super::*;
use glugg::proto::PROTO;
use tokio::net::UnixListener;

#[derive(Default)]
struct Events(Mutex<Vec<(u64, String, Value)>>);

impl Sink for Events {
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        saman::lock(&self.0).push((conn, event.to_owned(), data));
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
                crate::soft::done(tx.send(m), "tx send");
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
        ..Record::default()
    };
    rec.write(dir).unwrap();
    rec
}

/// The next message the worker hears but `term/list`'s status questions (a fake worker never answers them).
async fn next(rx: &mut mpsc::UnboundedReceiver<In>) -> In {
    loop {
        match crate::clock::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("the worker heard nothing")
            .expect("the hub dropped the worker")
        {
            In::Status { .. } => {}
            m => return m,
        }
    }
}

/// What the worker heard so far, but status questions.
fn heard(rx: &mut mpsc::UnboundedReceiver<In>) -> Vec<In> {
    std::iter::from_fn(|| rx.try_recv().ok())
        .filter(|m| !matches!(m, In::Status { .. }))
        .collect()
}

async fn open(dir: &Path) -> (Terms, Arc<Events>) {
    let t = Terms::default();
    let ev = Arc::new(Events::default());
    t.open(dir.to_path_buf(), ev.clone(), 7).await;
    (t, ev)
}

#[test]
fn adopts_by_pid_and_start_time_without_systemd() {
    saman::block_on_current(async move {
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
        let _only_when_used_elsewhere = &ev;
    })
}

#[test]
fn old_minor_protocol_is_adopted() {
    saman::block_on_current(async move {
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
    })
}

#[test]
fn major_mismatch_marks_terminal_old() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let rec = record(tmp.path(), "aa", "s1");
        let mut rx = fake_worker(&rec.socket, (PROTO.0 + 1, 0));
        let (t, _ev) = open(tmp.path()).await;
        assert_eq!(t.is_old("aa"), Some(true), "from before the update");
        assert!(
            !t.send("aa", &In::Text { text: "x".into() }),
            "nothing but close is sent to it"
        );
        let st = t.list(Duration::from_millis(200), None).await;
        assert!(
            st[0].old && st[0].running,
            "listed as old, its program counted as running: {st:?}"
        );
        assert!(t.send("aa", &In::Close { signal: None }));
        assert!(matches!(next(&mut rx).await, In::Close { .. }));
    })
}

/// Terminal ID's entry in `term/list` as session SESSION asks.
async fn listed(t: &Terms, id: &str, session: Option<&str>) -> Status {
    t.list(Duration::from_millis(200), session)
        .await
        .into_iter()
        .find(|s| s.id == id)
        .expect("listed")
}

#[test]
fn orphaned_at_once_detached_after_the_grace() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let rec = record(dir, "aa", "s1");
        let mut rx = fake_worker(&rec.socket, PROTO);
        let (t, ev) = open(dir).await;
        t.hello(3, "s1");
        assert!(matches!(next(&mut rx).await, In::Attach { .. }));
        // another Emacs, live all along
        t.hello(9, "s2");
        let s = listed(&t, "aa", Some("s1")).await;
        assert!(s.mine && !s.orphaned && s.detached_at.is_none(), "{s:?}");
        // times on the hub's clock, the one its session watcher ticks on: a made-up one would be long past the grace late
        // in a run of many tests in one process, and the watcher would detach early
        let at = mono_ms();
        t.gone_at(3, at);
        assert!(
            matches!(next(&mut rx).await, In::Detach),
            "no client: the worker stops drawing"
        );
        let s = listed(&t, "aa", Some("s2")).await;
        assert!(s.orphaned && !s.mine, "offered at once: {s:?}");
        t.tick(at + life::GRACE_MS - 1);
        // a reconnect within the grace keeps it
        t.hello(4, "s1");
        assert!(matches!(next(&mut rx).await, In::Attach { .. }));
        assert!(!listed(&t, "aa", Some("s2")).await.orphaned);
        let at = mono_ms();
        t.gone_at(4, at);
        assert!(matches!(next(&mut rx).await, In::Detach));
        t.tick(at + life::GRACE_MS);
        let s = listed(&t, "aa", Some("s2")).await;
        assert!(s.detached_at.is_some(), "detached: {s:?}");
        assert!(
            registry::read_all(dir)[0].detached_at.is_some(),
            "in the record"
        );
        assert!(
            !heard(&mut rx).iter().any(|m| matches!(m, In::Close { .. })),
            "a detached terminal keeps running"
        );
        let got: Vec<(u64, String, Value)> = saman::lock(&ev.0).clone();
        assert!(
            got.contains(&(9, "term/detached".into(), json!({"ids": ["aa"]}))),
            "the live session hears of it: {got:?}"
        );
    })
}

#[test]
fn an_attached_terminal_is_not_offered() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let rec = record(tmp.path(), "aa", "s1");
        let mut rx = fake_worker(&rec.socket, PROTO);
        let (t, _ev) = open(tmp.path()).await;
        t.hello(3, "s1");
        assert!(matches!(next(&mut rx).await, In::Attach { .. }));
        t.hello(9, "s2");
        assert!(
            t.attach_to(9, "aa", 80, 24, (8, 16), false).is_err(),
            "no stealing from a live Emacs"
        );
        // the hub's clock, as above
        let at = mono_ms();
        t.gone_at(3, at);
        assert!(matches!(next(&mut rx).await, In::Detach));
        let rec = t.attach_to(9, "aa", 80, 24, (8, 16), false).unwrap();
        assert_eq!(
            rec.session.as_deref(),
            Some("s2"),
            "moved to the new session"
        );
        match next(&mut rx).await {
            In::Resize {
                cols: 80,
                rows: 24,
                redraw: true,
                ..
            } => {}
            m => panic!("expected a redrawing resize, got {m:?}"),
        }
        assert!(matches!(next(&mut rx).await, In::Attach { .. }));
        let s = listed(&t, "aa", Some("s2")).await;
        assert!(s.mine && !s.orphaned && s.detached_at.is_none(), "{s:?}");
        // the old session's grace no longer reaches it
        t.tick(at + life::GRACE_MS);
        assert!(listed(&t, "aa", Some("s2")).await.detached_at.is_none());
    })
}

#[test]
fn a_detached_terminal_survives_a_hub_restart() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let mut rec = record(dir, "aa", "s1");
        rec.session = None;
        rec.detached_at = Some(1_700_000_000_000);
        rec.write(dir).unwrap();
        let mut rx = fake_worker(&rec.socket, PROTO);
        let (t, _ev) = open(dir).await;
        t.tick(10 * life::GRACE_MS);
        let s = listed(&t, "aa", None).await;
        assert_eq!(s.detached_at, Some(1_700_000_000_000), "{s:?}");
        assert_eq!(heard(&mut rx), [], "nothing sent: not closed");
    })
}

#[test]
fn session_end_keeps_the_terminals_it_names() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let a = record(tmp.path(), "aa", "s1");
        let b = record(tmp.path(), "bb", "s1");
        let mut ra = fake_worker(&a.socket, PROTO);
        let mut rb = fake_worker(&b.socket, PROTO);
        let (t, ev) = open(tmp.path()).await;
        t.hello(3, "s1");
        t.hello(9, "s2");
        assert!(matches!(next(&mut ra).await, In::Attach { .. }));
        assert!(matches!(next(&mut rb).await, In::Attach { .. }));
        assert_eq!(t.end_session("s1", &["aa".to_owned()]), 1, "one closed");
        assert!(matches!(next(&mut ra).await, In::Detach), "kept, detached");
        assert!(matches!(next(&mut rb).await, In::Close { signal: None }));
        let s = listed(&t, "aa", Some("s2")).await;
        assert!(s.detached_at.is_some() && !s.mine, "{s:?}");
        assert!(saman::lock(&ev.0).contains(&(9, "term/detached".into(), json!({"ids": ["aa"]}))));
    })
}

#[test]
fn hello_alone_keeps_terminals_where_they_draw() {
    saman::block_on_current(async move {
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
    })
}

#[test]
fn an_editor_holding_rows_in_sja_gets_them_on_the_raw_line() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let rec = record(tmp.path(), "aa", "s1");
        let mut rx = fake_worker(&rec.socket, PROTO);
        let (t, ev) = open(tmp.path()).await;
        t.hello(3, "s1");
        let patch = || Out::Patch {
            patch: Box::new(rodd::Patch {
                view: "term:aa".into(),
                class: "gui".into(),
                hub: 7,
                base: 0,
                version: 1,
                env_epoch: 2,
                ops: vec![],
                images: vec![],
                styles: vec![],
                term: None,
                model: None,
            }),
        };
        // the env says where the rows are held; the worker hears the epoch either way
        assert!(t.env("aa", 2, false));
        t.on_line("aa", patch());
        assert!(t.env("aa", 2, true));
        t.on_line("aa", patch());
        // the worker hears the hello's attach, then each env
        while !matches!(next(&mut rx).await, In::Env { env_epoch: 2 }) {}
        let got: Vec<(u64, String, Value)> = saman::lock(&ev.0).clone();
        let got: Vec<&(u64, String, Value)> = got
            .iter()
            .filter(|(_, e, _)| e.starts_with("view-"))
            .collect();
        assert_eq!(got.len(), 2, "{got:?}");
        assert_eq!((got[0].0, got[0].1.as_str()), (3, "view-patch"));
        assert_eq!(got[0].2["view"], "term:aa");
        assert_eq!((got[1].0, got[1].1.as_str()), (3, "view-model"));
        assert_eq!(got[1].2["view"], "term:aa");
        assert_eq!(
            got[1].2["rows"], got[0].2,
            "the rows line carries the patch whole"
        );
    })
}

#[test]
fn clean_exit_closes_at_once() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let a = record(tmp.path(), "aa", "s1");
        let b = record(tmp.path(), "bb", "s2");
        let mut ra = fake_worker(&a.socket, PROTO);
        let mut rb = fake_worker(&b.socket, PROTO);
        let (t, _ev) = open(tmp.path()).await;
        t.end_session("s1", &[]);
        assert!(matches!(next(&mut ra).await, In::Close { signal: None }));
        assert!(rb.try_recv().is_err(), "another session's terminal stays");
    })
}

#[test]
fn a_clipboard_read_reaches_the_owner_and_its_answer_the_worker() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let rec = record(dir, "aa", "s1");
        let l = UnixListener::bind(&rec.socket).unwrap();
        let (heard_tx, mut heard) = mpsc::unbounded_channel();
        let worker = tokio::spawn(async move {
            let (s, _) = l.accept().await.unwrap();
            let (r, mut w) = s.into_split();
            for out in [
                Out::Hello {
                    proto: PROTO,
                    pid: 1,
                    shell_pid: 4242,
                },
                Out::ClipboardRead {
                    req: 5,
                    primary: false,
                },
            ] {
                w.write_all((serde_json::to_string(&out).unwrap() + "\n").as_bytes())
                    .await
                    .unwrap();
                crate::clock::sleep(Duration::from_millis(100)).await;
            }
            let mut r = BufReader::new(r);
            let mut line = String::new();
            while r.read_line(&mut line).await.unwrap_or(0) > 0 {
                if let Ok(m @ In::ClipboardReply { .. }) = serde_json::from_str::<In>(&line) {
                    crate::soft::done(heard_tx.send(m), "heard_tx send");
                }
                line.clear();
            }
        });
        let (t, ev) = open(dir).await;
        t.hello(3, "s1");
        for _ in 0..100 {
            if saman::lock(&ev.0)
                .iter()
                .any(|(_, e, _)| e == "term/clipboard-read")
            {
                break;
            }
            crate::clock::sleep(Duration::from_millis(20)).await;
        }
        let got = saman::lock(&ev.0).clone();
        assert!(
            got.contains(&(
                3,
                "term/clipboard-read".into(),
                json!({"id": "aa", "req": 5, "primary": false})
            )),
            "{got:?}"
        );
        assert!(t.send(
            "aa",
            &In::ClipboardReply {
                req: 5,
                text: Some("hi".into())
            }
        ));
        let m = crate::clock::timeout(Duration::from_secs(5), heard.recv())
            .await
            .expect("the worker never heard the answer");
        assert_eq!(
            m,
            Some(In::ClipboardReply {
                req: 5,
                text: Some("hi".into())
            })
        );
        worker.abort();
    })
}

#[test]
fn exit_reaches_the_owner_and_the_record_goes() {
    saman::block_on_current(async move {
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
        let got: Vec<(u64, String)> = saman::lock(&ev.0)
            .iter()
            .map(|(c, e, _)| (*c, e.clone()))
            .collect();
        assert_eq!(
            got,
            [(3, "term/title".to_owned()), (3, "term/exit".to_owned())]
        );
    })
}

#[test]
fn wait_exit_gives_a_command_end_s_status_or_the_program_s_exit() {
    saman::block_on_current(async move {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let rec = record(dir, "aa", "s1");
        let l = UnixListener::bind(&rec.socket).unwrap();
        // the worker writes each batch when the test says so, after the test has started waiting
        let (go, mut gone) = mpsc::unbounded_channel::<Vec<Out>>();
        let worker = crate::clock::spawn("test:term-wait-exit", async move {
            let (s, _) = l.accept().await.unwrap();
            let (_r, mut w) = s.into_split();
            let hello = Out::Hello {
                proto: PROTO,
                pid: 1,
                shell_pid: 4242,
            };
            w.write_all((serde_json::to_string(&hello).unwrap() + "\n").as_bytes())
                .await
                .unwrap();
            while let Some(batch) = gone.recv().await {
                for out in batch {
                    w.write_all((serde_json::to_string(&out).unwrap() + "\n").as_bytes())
                        .await
                        .unwrap();
                }
            }
        });
        let (t, _ev) = open(dir).await;
        t.hello(3, "s1");
        for _ in 0..50 {
            if t.record("aa").is_some() {
                break;
            }
            crate::clock::sleep(Duration::from_millis(20)).await;
        }
        // OSC 133: a prompt and a command start say nothing; the command's end with its status does
        let first = t.wait_exit("aa");
        go.send(vec![
            Out::Prompt {
                kind: 1,
                exit: None,
            },
            Out::Prompt {
                kind: 3,
                exit: None,
            },
            Out::Prompt {
                kind: 4,
                exit: Some(3),
            },
        ])
        .unwrap();
        let got = crate::clock::timeout(Duration::from_secs(5), first).await;
        assert_eq!(got, Ok(Some(3)), "the command end's status");
        // the program's end: a signal reads as 128 + it, as a shell says
        let second = t.wait_exit("aa");
        go.send(vec![Out::Exit {
            code: None,
            signal: Some(9),
        }])
        .unwrap();
        let got = crate::clock::timeout(Duration::from_secs(5), second).await;
        assert_eq!(got, Ok(Some(137)), "the program's end");
        // no such terminal (this one ended): at once
        let got = crate::clock::timeout(Duration::from_secs(5), t.wait_exit("aa")).await;
        assert_eq!(got, Ok(None));
        drop(go);
        crate::soft::done(
            crate::clock::timeout(Duration::from_secs(5), worker).await,
            "crate::clock::timeout",
        );
    })
}

/// A fake worker on SOCKET that says hello, then goes away at the first status question without answering it (a
/// worker whose program ended between the question and its answer).
fn worker_gone_at_status(socket: &Path) -> tokio::task::JoinHandle<()> {
    let l = UnixListener::bind(socket).unwrap();
    tokio::spawn(async move {
        let (s, _) = l.accept().await.unwrap();
        let (r, mut w) = s.into_split();
        let hello = Out::Hello {
            proto: PROTO,
            pid: std::process::id(),
            shell_pid: 4242,
        };
        let line = serde_json::to_string(&hello).unwrap() + "\n";
        w.write_all(line.as_bytes()).await.unwrap();
        let mut r = BufReader::new(r);
        let mut line = String::new();
        while r.read_line(&mut line).await.unwrap_or(0) > 0 {
            if matches!(serde_json::from_str::<In>(&line), Ok(In::Status { .. })) {
                return;
            }
            line.clear();
        }
    })
}

#[test]
fn a_worker_that_ends_unanswered_releases_the_list() {
    saman::block_on_current(async move {
        // The list waits for each worker's answer on the hub's clock, which stands still while a request is served under
        // the test clock: a worker that ended without answering must end that wait, not leave it to the deadline.
        let tmp = tempfile::tempdir().unwrap();
        let rec = record(tmp.path(), "aa", "s1");
        let worker = worker_gone_at_status(&rec.socket);
        let (t, _ev) = open(tmp.path()).await;
        let st = t.list(Duration::from_secs(24 * 3600), None).await;
        assert!(st.iter().all(|s| s.id != "aa") || st[0].running, "{st:?}");
        crate::soft::done(worker.await, "tests");
    })
}

/// A fake worker on SOCKET whose program reads the clipboard at once: hello, then `clipboard-read` REQ; each line it
/// hears goes to the receiver.
fn worker_reading_clipboard(socket: &Path, req: u64) -> mpsc::UnboundedReceiver<In> {
    let l = UnixListener::bind(socket).unwrap();
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let (s, _) = l.accept().await.unwrap();
        let (r, mut w) = s.into_split();
        let hello = Out::Hello {
            proto: PROTO,
            pid: std::process::id(),
            shell_pid: 4242,
        };
        let read = Out::ClipboardRead {
            req,
            primary: false,
        };
        for m in [hello, read] {
            let line = serde_json::to_string(&m).unwrap() + "\n";
            w.write_all(line.as_bytes()).await.unwrap();
        }
        let mut r = BufReader::new(r);
        let mut line = String::new();
        while r.read_line(&mut line).await.unwrap_or(0) > 0 {
            if let Ok(m) = serde_json::from_str::<In>(&line) {
                crate::soft::done(tx.send(m), "tx send");
            }
            line.clear();
        }
        drop(w);
    });
    rx
}

#[test]
fn an_unanswered_clipboard_read_is_denied_on_the_hubs_clock() {
    saman::block_on_current(async move {
        tokio::time::pause();
        // The worker's read waits for the editor; the hub answers "no" once CLIPBOARD_WAIT has passed on its own clock,
        // never sooner, so a test's clock (not the wall) decides when a read times out.
        let tmp = tempfile::tempdir().unwrap();
        let rec = record(tmp.path(), "aa", "s1");
        let mut rx = worker_reading_clipboard(&rec.socket, 9);
        let (_t, _ev) = open(tmp.path()).await;
        let t0 = crate::clock::now();
        let reply = loop {
            let m = crate::clock::timeout(Duration::from_secs(3600), rx.recv())
                .await
                .expect("the hub never answered the read")
                .expect("the hub dropped the worker");
            if let In::ClipboardReply { .. } = m {
                break m;
            }
        };
        assert!(
            matches!(reply, In::ClipboardReply { req: 9, text: None }),
            "{reply:?}"
        );
        assert!(crate::clock::now().duration_since(t0) >= CLIPBOARD_WAIT);
    })
}
