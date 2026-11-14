//! The hub's notebooks against real `sh` processes standing in for kernels and a scripted peer playing their sockets.

use bytes::Bytes;
use zeromq::{PubSocket, RouterSocket, Socket, SocketRecv, SocketSend, ZmqMessage};

use super::*;
use crate::agents::lock::Enforced;
use crate::notebook::session::frames;
use crate::notebook::spec::private_folder;
use crate::notebook::wire::{self, Key};

mod views;

const NB: &str = r##"{
 "cells": [
  {"cell_type": "code", "id": "a", "metadata": {}, "execution_count": null, "outputs": [{"output_type": "stream", "name": "stdout", "text": ["old\n"]}], "source": ["ok"]},
  {"cell_type": "code", "id": "b", "metadata": {}, "execution_count": null, "outputs": [], "source": ["BOOM"]},
  {"cell_type": "code", "id": "c", "metadata": {}, "execution_count": null, "outputs": [], "source": ["after"]}
 ],
 "metadata": {"kernelspec": {"name": "fake", "language": "fake", "display_name": "Fake"}},
 "nbformat": 4, "nbformat_minor": 5
}"##;

#[derive(Default)]
struct Events(
    Mutex<Vec<(u64, String, Value)>>,
    std::sync::atomic::AtomicBool,
    /// The editor's queue is backed up: every lossy send is dropped.
    std::sync::atomic::AtomicBool,
    /// How many input requests were dropped that way.
    std::sync::atomic::AtomicUsize,
);

impl Sink for Events {
    fn broadcast(&self, _: &str, _: Value, _: Option<u64>) {}
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.0.lock().unwrap().push((conn, event.into(), data));
        true
    }
    /// The editor can be made to leave: every send says it is gone.
    fn send_lossy(&self, conn: u64, event: &str, data: Value) -> Delivery {
        if self.1.load(Ordering::SeqCst) {
            return Delivery::Gone;
        }
        if self.2.load(Ordering::SeqCst) {
            if event == "notebook-input-request" {
                self.3.fetch_add(1, Ordering::SeqCst);
            }
            return Delivery::Dropped;
        }
        self.send(conn, event, data);
        Delivery::Sent
    }
}

impl Events {
    fn of(&self, name: &str) -> Vec<Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.1 == name)
            .map(|e| e.2.clone())
            .collect()
    }
    /// The latest tail of CELL.
    fn tail(&self, cell: &str) -> Option<Value> {
        self.of("notebook-tail")
            .into_iter()
            .rev()
            .find(|t| t["cell"] == cell)
    }
    fn state(&self) -> Option<String> {
        self.of("notebook-status")
            .last()
            .and_then(|s| s["state"].as_str().map(String::from))
    }
}

struct World {
    d: tempfile::TempDir,
    events: Arc<Events>,
    hub: Notebooks,
    path: PathBuf,
}

fn world(interrupt: &str) -> World {
    let d = tempfile::Builder::new()
        .prefix("nh")
        .tempdir_in("/tmp")
        .unwrap();
    let kernels = d.path().join("kernels");
    std::fs::create_dir_all(kernels.join("fake")).unwrap();
    let argv = r#"["sh", "-c", "sleep 600", "kernel", "{connection_file}"]"#;
    std::fs::write(
        kernels.join("fake/kernel.json"),
        format!(r#"{{"argv": {argv}, "display_name": "Fake", "language": "fake", "interrupt_mode": "{interrupt}"}}"#),
    )
    .unwrap();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let path = d.path().join("n.ipynb");
    std::fs::write(&path, NB).unwrap();
    let events = Arc::new(Events::default());
    let t = Timeouts {
        ready: Duration::from_secs(30),
        ping: Duration::from_millis(20),
        grace: Duration::from_millis(300),
        ..Timeouts::default()
    };
    let hub = Notebooks::new(events.clone(), folder, vec![kernels], t);
    World {
        d,
        events,
        hub,
        path,
    }
}

fn zmq(key: &Key, m: &Message) -> ZmqMessage {
    let f: Vec<Bytes> = wire::encode(key, m).into_iter().map(Bytes::from).collect();
    ZmqMessage::try_from(f).unwrap()
}

fn reply_to(req: &Message, t: &str, content: Value) -> Message {
    let mut m = Message::request("kernel", t, content);
    m.parent = serde_json::to_value(&req.header).unwrap();
    m
}

#[derive(Default)]
struct Seen {
    executed: Mutex<Vec<String>>,
    control: Mutex<Vec<String>>,
}

/// The kernel's side of notebook `nb1` (its first kernel): answers `kernel_info`, runs what it is sent (the code is its own output;
/// BOOM is an error, SLOW never answers, ASK asks for input), and notes what reached it.
fn kernel_side(folder: &Path, id: &str, nth: u32, seen: Arc<Seen>) -> tokio::task::JoinHandle<()> {
    let prefix = folder.join(format!("k-{id}-k{nth}"));
    let ep = move |n| format!("ipc://{}-{n}", prefix.display());
    let path = folder.join(format!("kernel-{id}-k{nth}.json"));
    tokio::spawn(async move {
        let (mut shell, mut iopub, mut stdin, mut control) = (
            RouterSocket::new(),
            PubSocket::new(),
            RouterSocket::new(),
            RouterSocket::new(),
        );
        shell.bind(&ep(1)).await.unwrap();
        iopub.bind(&ep(2)).await.unwrap();
        stdin.bind(&ep(3)).await.unwrap();
        control.bind(&ep(4)).await.unwrap();
        let key = skuld::wait_until_async("the connection file", 30, || async {
            let v: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
            Key::from_connection_file(v["key"].as_str()?)
        })
        .await;
        let seen2 = seen.clone();
        let k2 = key.clone();
        tokio::spawn(async move {
            while let Ok(m) = control.recv().await {
                if let Ok(d) = wire::decode(&k2, &frames(m)) {
                    seen2.control.lock().unwrap().push(d.header.msg_type);
                }
            }
        });
        let mut count = 0;
        let mut late = None;
        loop {
            let f = frames(shell.recv().await.unwrap());
            let Ok(req) = wire::decode(&key, &f) else {
                continue;
            };
            let status = |state: &str| {
                zmq(
                    &key,
                    &reply_to(&req, "status", json!({"execution_state": state})),
                )
            };
            if req.header.msg_type == "kernel_info_request" {
                let mut rep = reply_to(&req, "kernel_info_reply", json!({"status": "ok"}));
                rep.idents = vec![f[0].clone()];
                shell.send(zmq(&key, &rep)).await.unwrap();
                iopub.send(status("idle")).await.unwrap();
                continue;
            }
            if let Some((old, ident)) = late.take() {
                let mut q = reply_to(
                    &old,
                    "input_request",
                    json!({"prompt": "too late? ", "password": false}),
                );
                q.idents = vec![ident];
                stdin.send(zmq(&key, &q)).await.unwrap();
            }
            let code = req.content["code"].as_str().unwrap_or("").to_string();
            seen.executed.lock().unwrap().push(code.clone());
            count += 1;
            iopub.send(status("busy")).await.unwrap();
            if code == "SLOW" {
                continue;
            }
            if code == "LOGIT" {
                // a message of the kernel's own: no parent header
                let own = Message::request(
                    "kernel",
                    "stream",
                    json!({"name": "stderr", "text": "kernel log line\nsecond"}),
                );
                iopub.send(zmq(&key, &own)).await.unwrap();
            }
            let mut text = code.clone();
            if matches!(code.as_str(), "ASK" | "ASKLONG" | "ASKTWICE") {
                let prompt = if code == "ASKLONG" {
                    format!("{}\u{202e}\x1b[31m", "p".repeat(5000))
                } else {
                    "name? ".to_string()
                };
                let mut ask = reply_to(
                    &req,
                    "input_request",
                    json!({"prompt": prompt, "password": false}),
                );
                ask.idents = vec![f[0].clone()];
                stdin.send(zmq(&key, &ask)).await.unwrap();
                if code == "ASKTWICE" {
                    // a second question while the first is open
                    let mut again = reply_to(
                        &req,
                        "input_request",
                        json!({"prompt": "again? ", "password": false}),
                    );
                    again.idents = vec![f[0].clone()];
                    stdin.send(zmq(&key, &again)).await.unwrap();
                }
                let got = frames(stdin.recv().await.unwrap());
                text = wire::decode(&key, &got).unwrap().content["value"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
            }
            let out = reply_to(&req, "stream", json!({"name": "stdout", "text": text}));
            iopub.send(zmq(&key, &out)).await.unwrap();
            let ok = code != "BOOM";
            if !ok {
                let e = reply_to(
                    &req,
                    "error",
                    json!({"ename": "Boom", "evalue": "no", "traceback": ["tb"]}),
                );
                iopub.send(zmq(&key, &e)).await.unwrap();
            }
            let mut rep = reply_to(
                &req,
                "execute_reply",
                json!({"status": if ok { "ok" } else { "error" }, "execution_count": count}),
            );
            rep.idents = vec![f[0].clone()];
            shell.send(zmq(&key, &rep)).await.unwrap();
            iopub.send(status("idle")).await.unwrap();
            if code == "ASKLATE" {
                // a question after the run is over: it is sent when the next request comes, which the hub sends only once the
                // run has ended (sent at once, it could pass the run's reply and idle on their other sockets)
                late = Some((req.clone(), f[0].clone()));
            }
        }
    })
}

async fn started(w: &World) -> (String, Arc<Seen>) {
    let opened = w.hub.open(7, &w.path, None).await.unwrap();
    let id = opened.id.clone();
    assert!(
        id.starts_with("nb") && id.len() == 34,
        "an id nobody can guess: {id}"
    );
    let seen = Arc::new(Seen::default());
    kernel_side(
        &private_folder(&w.d.path().join("s")).unwrap(),
        &id,
        1,
        seen.clone(),
    );
    assert_eq!(w.hub.start(7, &id, None, None).await.unwrap(), "fake");
    (id, seen)
}

fn sync(id: &str, source: &str) -> CellSync {
    CellSync {
        id: id.into(),
        kind: hrafn::notebook::Kind::Code,
        source: source.into(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_notebook_opens_with_its_files_outputs_as_stale_tails_and_a_bad_file_is_an_error() {
    let w = world("signal");
    let o = w.hub.open(7, &w.path, None).await.unwrap();
    assert_eq!(
        (
            o.cells.len(),
            o.kernelspec.as_deref(),
            o.language.as_deref()
        ),
        (3, Some("fake"), Some("fake"))
    );
    let a = o.tails.iter().find(|t| t["cell"] == "a").unwrap();
    assert_eq!(
        (a["text"].as_str(), a["stale"].as_bool()),
        (Some("old\n"), Some(true))
    );
    assert_eq!(
        (a["head"]["text"].as_str(), a["head"]["state"].as_str()),
        (Some("[ ]  fake"), Some("idle"))
    );
    // the contract's type holds what the hub sends
    let typed: runstav::methods::notebook::NotebookTail =
        serde_json::from_value(a.clone()).unwrap();
    assert_eq!(
        (typed.cell.as_str(), typed.head.state.as_str(), typed.stale),
        ("a", "idle", true)
    );
    assert_eq!(
        serde_json::to_value(&typed).unwrap()["head"]["runs"],
        a["head"]["runs"]
    );
    assert_eq!(
        w.hub
            .kernels()
            .iter()
            .map(|k| k.name.as_str())
            .collect::<Vec<_>>(),
        ["fake"]
    );
    assert!(
        w.hub
            .open(7, &w.d.path().join("nope.ipynb"), None)
            .await
            .is_err()
    );
    assert!(w.hub.open(7, &w.path, Some("[]".into())).await.is_err());
    assert!(
        w.hub.tail(7, &o.id, "a").await.unwrap()["stale"]
            .as_bool()
            .unwrap()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cell_runs_its_output_reaches_the_editor_and_save_writes_it() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(7, &id, &[sync("a", "print(1)")])
        .await
        .unwrap();
    let t = skuld::wait_until("the cell's tail", 30, || {
        w.events.tail("a").filter(|t| t["text"] == "print(1)")
    });
    assert_eq!(
        (t["stale"].as_bool(), t["id"].as_str()),
        (Some(false), Some(id.as_str()))
    );
    assert!(t["version"].as_u64().unwrap() >= 2);
    skuld::wait_until("idle", 30, || {
        (w.events.state().as_deref() == Some("idle")).then_some(())
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["print(1)"]);
    // the editor is told through the connection that opened it
    assert!(w.events.0.lock().unwrap().iter().all(|e| e.0 == 7));
    w.hub.save(7, &id, None).await.unwrap();
    let saved: Value = serde_json::from_slice(&std::fs::read(&w.path).unwrap()).unwrap();
    assert_eq!(saved["cells"][0]["outputs"][0]["text"], json!(["print(1)"]));
    assert_eq!(saved["cells"][0]["execution_count"], 1);
    assert_eq!(saved["cells"][0]["source"], json!(["print(1)"]));
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_error_aborts_the_cells_queued_behind_it_and_they_never_reach_the_kernel() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(
            7,
            &id,
            &[sync("a", "ok"), sync("b", "BOOM"), sync("c", "after")],
        )
        .await
        .unwrap();
    skuld::wait_until("c aborted", 30, || {
        w.events.tail("c").filter(|t| t["text"] == "aborted")
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["ok", "BOOM"]);
    let b = w.events.tail("b").unwrap();
    assert!(
        b["text"].as_str().unwrap().starts_with("BOOM\nBoom: no"),
        "{b}"
    );
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_interrupt_cancels_what_is_queued_and_asks_the_kernel_by_message_when_its_spec_says_so()
{
    let w = world("message");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(7, &id, &[sync("a", "SLOW"), sync("b", "x")])
        .await
        .unwrap();
    skuld::wait_until("a busy", 30, || {
        w.events
            .of("notebook-status")
            .iter()
            .any(|s| s["state"] == "busy" && s["cell"] == "a")
            .then_some(())
    });
    w.hub.interrupt(7, &id).await.unwrap();
    skuld::wait_until("b cancelled", 30, || {
        w.events.tail("b").filter(|t| t["text"] == "cancelled")
    });
    skuld::wait_until("the interrupt request", 30, || {
        seen.control
            .lock()
            .unwrap()
            .iter()
            .any(|t| t == "interrupt_request")
            .then_some(())
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["SLOW"]);
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_asking_for_input_gets_the_answer_through_the_stdin_socket() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(7, &id, &[sync("a", "ASK")]).await.unwrap();
    let ask = skuld::wait_until("the input request", 30, || {
        w.events.of("notebook-input-request").into_iter().next()
    });
    assert_eq!(
        (
            ask["prompt"].as_str(),
            ask["cell"].as_str(),
            ask["password"].as_bool()
        ),
        (Some("name? "), Some("a"), Some(false))
    );
    w.hub
        .input(7, &id, ask["request"].as_str().unwrap(), "bob")
        .await
        .unwrap();
    skuld::wait_until("the answer shown", 30, || {
        w.events.tail("a").filter(|t| t["text"] == "bob")
    });
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_sealed_session_gets_no_kernel_and_a_missing_kernel_is_named() {
    let w = world("signal");
    let id = w.hub.open(7, &w.path, None).await.unwrap().id;
    let plan = LaunchPlan {
        argv: vec![],
        env: vec![],
        session_meta: None,
        protected_ro: vec![],
        login_dir: None,
        enforced: Enforced::Yes,
        gateway: false,
        trace: None,
        ro_files: vec![],
        gateway_url_env: vec![],
    };
    let e = w.hub.start(7, &id, None, Some(&plan)).await.unwrap_err();
    assert_eq!(
        e,
        "a notebook kernel runs unconfined and is not started in a sealed session"
    );
    assert!(w.hub.start(7, "nope", None, None).await.is_err());
    assert!(
        w.hub.execute(7, &id, &[sync("a", "x")]).await.is_err(),
        "no kernel started"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn shutdown_ends_the_kernel_says_so_and_removes_its_connection_file() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    let file = private_folder(&w.d.path().join("s"))
        .unwrap()
        .join(format!("kernel-{id}-k1.json"));
    assert!(file.exists());
    let exit = w.hub.shutdown(7, &id).await.unwrap();
    assert!(exit.signal.is_some() || exit.code.is_some());
    assert_eq!(w.events.state().as_deref(), Some("dead"));
    skuld::wait_until("the file to go", 30, || (!file.exists()).then_some(()));
    assert!(w.hub.kernel_name(7, &id).is_none());
    assert!(
        w.hub.shutdown(7, &id).await.is_err(),
        "a second one has nothing to end"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tail_carries_the_execution_count_and_a_head_that_follows_the_cell_through_its_states() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(7, &id, &[sync("a", "SLOW")]).await.unwrap();
    // queued and running show [*]
    let running = skuld::wait_until("a running head", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["head"]["state"] == "running")
    });
    assert_eq!(running["head"]["text"], "[*]  fake");
    assert_eq!(
        running["head"]["runs"][0],
        json!({"start": 0, "end": 3, "fg": null, "bg": null, "bold": true,
                                                    "italic": false, "underline": false, "inverse": false})
    );
    w.hub.close(7, &id).await;

    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(7, &id, &[sync("a", "ok")]).await.unwrap();
    let done = skuld::wait_until("the finished head", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["head"]["state"] == "idle" && t["execution_count"] == 1)
    });
    assert_eq!(done["head"]["text"], "[1]  fake");
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn clear_empties_one_cell_or_all_and_leaves_a_running_cell_alone() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub
        .execute(7, &id, &[sync("a", "ok"), sync("b", "two")])
        .await
        .unwrap();
    skuld::wait_until("both done", 30, || {
        w.events
            .tail("b")
            .filter(|t| t["text"] == "two" && t["head"]["state"] == "idle")
    });
    w.hub.clear(7, &id, Some("a")).await.unwrap();
    let a = w.events.tail("a").unwrap();
    assert_eq!(
        (
            a["text"].as_str(),
            a["execution_count"].is_null(),
            a["head"]["text"].as_str()
        ),
        (Some(""), true, Some("[ ]  fake"))
    );
    assert_eq!(
        w.hub.tail(7, &id, "b").await.unwrap()["text"],
        "two",
        "the other cell keeps its output"
    );
    w.hub.clear(7, &id, None).await.unwrap();
    assert_eq!(w.hub.tail(7, &id, "b").await.unwrap()["text"], "");
    assert!(w.hub.clear(7, &id, Some("nope")).await.is_err());
    // a running cell is not cleared
    w.hub.execute(7, &id, &[sync("c", "SLOW")]).await.unwrap();
    skuld::wait_until("c running", 30, || {
        w.events
            .tail("c")
            .filter(|t| t["head"]["state"] == "running")
    });
    let before = w.events.of("notebook-tail").len();
    w.hub.clear(7, &id, Some("c")).await.unwrap();
    assert_eq!(
        w.hub.tail(7, &id, "c").await.unwrap()["head"]["state"],
        "running"
    );
    assert!(w.events.of("notebook-tail").len() >= before);
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_ends_the_kernel_and_starts_a_new_one_with_a_new_connection() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub.execute(7, &id, &[sync("a", "before")]).await.unwrap();
    skuld::wait_until("ran", 30, || {
        w.events.tail("a").filter(|t| t["text"] == "before")
    });
    let folder = private_folder(&w.d.path().join("s")).unwrap();
    let seen2 = Arc::new(Seen::default());
    kernel_side(&folder, &id, 2, seen2.clone());
    assert_eq!(w.hub.restart(7, &id).await.unwrap(), "fake");
    assert!(
        !folder.join(format!("kernel-{id}-k1.json")).exists(),
        "the old connection file went"
    );
    assert!(
        folder.join(format!("kernel-{id}-k2.json")).exists(),
        "a new one, with its own key"
    );
    w.hub.execute(7, &id, &[sync("b", "after")]).await.unwrap();
    skuld::wait_until("ran on the new kernel", 30, || {
        w.events.tail("b").filter(|t| t["text"] == "after")
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["before"]);
    assert_eq!(*seen2.executed.lock().unwrap(), ["after"]);
    assert!(w.hub.restart(7, "nope").await.is_err());
    w.hub.close(7, &id).await;
}

fn spawn_peer(w: &World, id: &str, nth: u32) -> Arc<Seen> {
    let seen = Arc::new(Seen::default());
    kernel_side(
        &private_folder(&w.d.path().join("s")).unwrap(),
        id,
        nth,
        seen.clone(),
    );
    seen
}

#[tokio::test(flavor = "multi_thread")]
async fn a_notebook_is_its_connections_and_ends_with_it() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    // another connection has no such notebook, whatever it calls
    assert!(w.hub.tail(8, &id, "a").await.is_err());
    assert!(w.hub.execute(8, &id, &[sync("a", "x")]).await.is_err());
    assert!(w.hub.save(8, &id, None).await.is_err());
    assert!(w.hub.shutdown(8, &id).await.is_err());
    assert!(w.hub.interrupt(8, &id).await.is_err());
    assert!(w.hub.input(8, &id, "r", "v").await.is_err());
    assert!(w.hub.clear(8, &id, None).await.is_err());
    assert!(w.hub.output(8, &id, "a").await.is_err());
    assert!(w.hub.sync(8, &id, &[]).await.is_err());
    assert!(w.hub.start(8, &id, None, None).await.is_err());
    assert!(w.hub.restart(8, &id).await.is_err());
    w.hub.close(8, &id).await;
    assert!(
        w.hub.tail(7, &id, "a").await.is_ok(),
        "another connection's close did nothing"
    );
    assert!(seen.executed.lock().unwrap().is_empty());
    // the editor leaves: the notebook is forgotten and the kernel's connection file goes with it
    let file = private_folder(&w.d.path().join("s"))
        .unwrap()
        .join(format!("kernel-{id}-k1.json"));
    assert!(file.exists());
    w.hub.gone(7).await;
    assert!(w.hub.tail(7, &id, "a").await.is_err());
    skuld::wait_until("the file to go", 30, || (!file.exists()).then_some(()));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pump_whose_editor_is_gone_stops_and_the_kernel_with_it() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    let file = private_folder(&w.d.path().join("s"))
        .unwrap()
        .join(format!("kernel-{id}-k1.json"));
    skuld::wait_until("the pump's first status", 30, || {
        (w.events.state().as_deref() == Some("idle")).then_some(())
    });
    w.events.1.store(true, Ordering::SeqCst);
    w.hub.execute(7, &id, &[sync("a", "SLOW")]).await.unwrap();
    skuld::wait_until("the kernel to be ended", 30, || {
        (!file.exists()).then_some(())
    });
    skuld::wait_until("the slot to be free", 30, || {
        w.hub.kernel_name(7, &id).is_none().then_some(())
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn only_regular_notebook_files_ending_in_ipynb_are_opened() {
    let w = world("signal");
    let fifo = w.d.path().join("pipe.ipynb");
    rustix::fs::mknodat(
        rustix::fs::CWD,
        &fifo,
        rustix::fs::FileType::Fifo,
        rustix::fs::Mode::from_raw_mode(0o600),
        0,
    )
    .unwrap();
    let zero = w.d.path().join("zero.ipynb");
    std::os::unix::fs::symlink("/dev/zero", &zero).unwrap();
    // an open that waits or reads for ever would hang these: they are asked on a thread with a deadline
    let slot = Arc::new(Mutex::new(None));
    let s2 = slot.clone();
    let (a, b) = (fifo.clone(), zero.clone());
    std::thread::spawn(move || *s2.lock().unwrap() = Some((read_notebook(&a), read_notebook(&b))));
    let (f, z) = skuld::wait_until("the reads", 30, || slot.lock().unwrap().take());
    assert!(f.unwrap_err().contains("not a regular file"));
    assert!(z.unwrap_err().contains("not a regular file"));
    assert!(read_notebook(&w.path).is_ok());
    let e = w
        .hub
        .open(7, &w.d.path().join("notes.json"), Some("{}".into()))
        .await
        .unwrap_err();
    assert!(e.contains("not a .ipynb file"), "{e}");
    assert!(
        w.hub
            .open(7, &w.d.path().join("n.IPYNB"), Some(NB.into()))
            .await
            .is_ok()
    );
    // one connection holds at most MAX_OPEN
    for _ in 0..MAX_OPEN {
        let _ = w.hub.open(9, &w.path, None).await;
    }
    assert!(
        w.hub
            .open(9, &w.path, None)
            .await
            .unwrap_err()
            .contains("close one first")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn two_starts_at_once_make_one_kernel() {
    let w = world("signal");
    let id = w.hub.open(7, &w.path, None).await.unwrap().id;
    let _seen = spawn_peer(&w, &id, 1);
    let (a, b) = tokio::join!(
        w.hub.start(7, &id, None, None),
        w.hub.start(7, &id, None, None)
    );
    assert_eq!(
        [a.is_ok(), b.is_ok()].iter().filter(|x| **x).count(),
        1,
        "{a:?} {b:?}"
    );
    let refused = a.err().or(b.err()).unwrap();
    assert!(refused.contains("already has a kernel"), "{refused}");
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_start_that_fails_leaves_the_slot_free() {
    let w = world("signal");
    let id = w.hub.open(7, &w.path, None).await.unwrap().id;
    // no kernel by that name and the notebook's language has no kernelspec either: nothing starts
    std::fs::remove_dir_all(w.d.path().join("kernels/fake")).unwrap();
    assert!(
        w.hub
            .start(7, &id, Some("nothere"), None)
            .await
            .unwrap_err()
            .contains("no kernel")
    );
    std::fs::create_dir_all(w.d.path().join("kernels/fake")).unwrap();
    std::fs::write(
        w.d.path().join("kernels/fake/kernel.json"),
        r#"{"argv": ["sh", "-c", "sleep 600", "kernel", "{connection_file}"], "display_name": "Fake", "language": "fake"}"#,
    )
    .unwrap();
    let _seen = spawn_peer(&w, &id, 1);
    assert_eq!(
        w.hub.start(7, &id, None, None).await.unwrap(),
        "fake",
        "the failed start did not keep the slot"
    );
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_question_to_the_editor_is_short_clean_one_at_a_time_and_only_from_the_running_cell() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub
        .execute(7, &id, &[sync("a", "ASKLONG")])
        .await
        .unwrap();
    let ask = skuld::wait_until("the request", 30, || {
        w.events.of("notebook-input-request").into_iter().next()
    });
    let prompt = ask["prompt"].as_str().unwrap();
    assert_eq!(prompt.chars().count(), PROMPT_CHARS);
    assert!(!prompt.contains('\u{202e}') && !prompt.contains('\x1b'));
    w.hub
        .input(7, &id, ask["request"].as_str().unwrap(), "x")
        .await
        .unwrap();
    skuld::wait_until("done", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["head"]["state"] == "idle" && t["text"] == "x")
    });
    // a second question while one is open is not forwarded
    w.hub
        .execute(7, &id, &[sync("b", "ASKTWICE")])
        .await
        .unwrap();
    skuld::wait_until("the first", 30, || {
        (w.events.of("notebook-input-request").len() >= 2).then_some(())
    });
    let ours = w.events.of("notebook-input-request");
    w.hub
        .input(7, &id, ours[1]["request"].as_str().unwrap(), "y")
        .await
        .unwrap();
    skuld::wait_until("b done", 30, || {
        w.events
            .tail("b")
            .filter(|t| t["head"]["state"] == "idle" && t["text"] == "y")
    });
    assert_eq!(
        w.events.of("notebook-input-request").len(),
        2,
        "one for b, not two"
    );
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn what_a_finished_run_held_is_let_go() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    for i in 0..12 {
        w.hub
            .execute(7, &id, &[sync("a", &format!("run {i}"))])
            .await
            .unwrap();
        skuld::wait_until("the run", 30, || {
            w.events
                .tail("a")
                .filter(|t| t["text"] == format!("run {i}") && t["head"]["state"] == "idle")
        });
    }
    skuld::wait_until("nothing held", 30, || {
        (w.hub.held_runs(7, &id) == Some(0)).then_some(())
    });
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cell_that_never_started_keeps_its_outputs_in_the_notebook_and_the_file() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    // b runs for ever, a (which has the file's output) waits behind it
    w.hub
        .execute(7, &id, &[sync("b", "SLOW"), sync("a", "ok")])
        .await
        .unwrap();
    skuld::wait_until("b running", 30, || {
        w.events
            .tail("b")
            .filter(|t| t["head"]["state"] == "running")
    });
    w.hub.interrupt(7, &id).await.unwrap();
    let a = skuld::wait_until("a cancelled", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["text"].as_str().is_some_and(|t| t.ends_with("cancelled")))
    });
    assert!(a["text"].as_str().unwrap().starts_with("old\n"), "{a}");
    w.hub.save(7, &id, None).await.unwrap();
    let saved: Value = serde_json::from_slice(&std::fs::read(&w.path).unwrap()).unwrap();
    assert_eq!(
        saved["cells"][0]["outputs"][0]["text"],
        json!(["old\n"]),
        "the file's output was not blanked"
    );
    w.hub.close(7, &id).await;
}

#[test]
fn at_most_a_hundred_tails_a_second_go_for_a_notebook() {
    let t0 = crate::clock::now();
    let mut b = Budget::new(t0);
    for i in 0..TAILS_PER_SEC {
        assert!(b.allowed(t0 + Duration::from_millis(i as u64)), "{i}");
        b.spend();
    }
    assert!(
        !b.allowed(t0 + Duration::from_millis(500)),
        "the window is full"
    );
    assert!(b.allowed(t0 + Duration::from_millis(1000)), "a new window");
}

#[test]
fn a_backed_up_editor_loses_events_not_its_subscription() {
    let editors = crate::settings::agents::Editors::default();
    let out = Arc::new(crate::conn::Outbox::new(5));
    editors.subscribe(5, out.clone());
    let big = json!({"text": "x".repeat(1 << 20)});
    let mut sent = 0;
    let mut dropped = false;
    for _ in 0..10 {
        match editors.send_to_lossy(5, "notebook-tail", big.clone()) {
            Delivery::Sent => sent += 1,
            Delivery::Dropped => {
                dropped = true;
                break;
            }
            Delivery::Gone => panic!("the subscription went"),
        }
    }
    assert!(
        dropped && (3..=4).contains(&sent),
        "{sent} sent, dropped {dropped}"
    );
    assert_eq!(
        editors.send_to_lossy(5, "notebook-tail", big.clone()),
        Delivery::Dropped,
        "still backed up"
    );
    assert!(
        editors.send_to(5, "other", json!({})),
        "the editor is still subscribed to everything else"
    );
    assert_eq!(
        editors.send_to_lossy(6, "x", json!({})),
        Delivery::Gone,
        "no such editor"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_question_after_the_run_is_over_is_not_forwarded() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(7, &id, &[sync("a", "ASKLATE")])
        .await
        .unwrap();
    skuld::wait_until("a done", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["head"]["state"] == "idle" && t["text"] == "ASKLATE")
    });
    // the next run is answered after the late question was sent: the question has been through the hub by then
    w.hub.execute(7, &id, &[sync("b", "ok")]).await.unwrap();
    skuld::wait_until("b done", 30, || {
        w.events
            .tail("b")
            .filter(|t| t["head"]["state"] == "idle" && t["text"] == "ok")
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["ASKLATE", "ok"]);
    assert!(w.events.of("notebook-input-request").is_empty());
    w.hub.close(7, &id).await;
}

/// A notebook of N code cells with output, each of LINES rows of WIDTH characters.
fn big_notebook(n: usize, lines: usize, width: usize) -> String {
    let text: Vec<String> = (0..lines)
        .map(|_| format!("{}\n", "x".repeat(width)))
        .collect();
    let out = json!([{"output_type": "stream", "name": "stdout", "text": text}]);
    let cells: Vec<Value> = (0..n)
        .map(|i| json!({"cell_type": "code", "id": format!("c{i}"), "metadata": {}, "execution_count": i, "outputs": out, "source": [format!("{i}")]}))
        .collect();
    json!({"cells": cells, "metadata": {}, "nbformat": 4, "nbformat_minor": 5}).to_string()
}

#[tokio::test(flavor = "multi_thread")]
async fn open_answers_with_the_tails_of_the_first_cells_with_output_within_a_budget_and_counts_the_rest()
 {
    let w = world("signal");
    // 300 cells with output, and one without: tails for 200, the rest asked for
    let mut nb: Value = serde_json::from_str(&big_notebook(300, 1, 10)).unwrap();
    nb["cells"].as_array_mut().unwrap().push(json!({"cell_type": "code", "id": "bare", "metadata": {}, "execution_count": null, "outputs": [], "source": []}));
    let o = w.hub.open(7, &w.path, Some(nb.to_string())).await.unwrap();
    assert_eq!(
        (o.tails.len(), o.more_tails, o.cells.len()),
        (OPEN_TAILS_MAX, 100, 301)
    );
    assert!(
        o.tails.iter().all(|t| t["cell"] != "bare"),
        "a cell without output has no tail"
    );
    let late = w.hub.tail(7, &o.id, "c299").await.unwrap();
    assert_eq!(late["text"], "xxxxxxxxxx\n");
    // large tails stop at the byte budget
    let o = w
        .hub
        .open(7, &w.path, Some(big_notebook(150, 20, 400)))
        .await
        .unwrap();
    let bytes: usize = o.tails.iter().map(|t| t.to_string().len()).sum();
    assert!(
        o.tails.len() < 150 && o.more_tails > 0 && o.tails.len() + o.more_tails == 150,
        "{} {}",
        o.tails.len(),
        o.more_tails
    );
    assert!(bytes < OPEN_TAILS_BYTES + 20_000, "{bytes}");
    // sources past the answer's budget are refused
    let huge = json!({"cells": [{"cell_type": "code", "id": "h", "metadata": {}, "execution_count": null, "outputs": [],
                                  "source": ["x".repeat(OPEN_SOURCE_BYTES + 1)]}], "metadata": {}, "nbformat": 4, "nbformat_minor": 5});
    let e = w
        .hub
        .open(7, &w.path, Some(huge.to_string()))
        .await
        .unwrap_err();
    assert!(e.contains("MiB of cell sources"), "{e}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_notebook_closed_while_its_kernel_starts_does_not_keep_the_kernel() {
    let w = world("signal");
    let id = w.hub.open(7, &w.path, None).await.unwrap().id;
    let hub = Arc::new(w.hub);
    let file = private_folder(&w.d.path().join("s"))
        .unwrap()
        .join(format!("kernel-{id}-k1.json"));
    // the kernel's side is not there yet: the start waits for its sockets
    let (h2, id2) = (hub.clone(), id.clone());
    let starting = tokio::spawn(async move { h2.start(7, &id2, None, None).await });
    skuld::wait_until("the kernel to be starting", 30, || {
        file.exists().then_some(())
    });
    hub.close(7, &id).await;
    let _peer = {
        let seen = Arc::new(Seen::default());
        kernel_side(
            &private_folder(&w.d.path().join("s")).unwrap(),
            &id,
            1,
            seen,
        )
    };
    let e = starting.await.unwrap().unwrap_err();
    assert!(e.contains("closed while its kernel started"), "{e}");
    skuld::wait_until("the kernel's connection file to go", 30, || {
        (!file.exists()).then_some(())
    });
    assert!(hub.tail(7, &id, "a").await.is_err());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_status_and_an_input_request_a_backed_up_editor_did_not_take_are_sent_again() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.events.2.store(true, Ordering::SeqCst);
    w.hub.execute(7, &id, &[sync("a", "ASK")]).await.unwrap();
    skuld::wait_until("the question to have been dropped", 30, || {
        (w.events.3.load(Ordering::SeqCst) >= 1).then_some(())
    });
    assert!(w.events.of("notebook-input-request").is_empty());
    // the editor takes events again: the latest status and the question come
    w.events.2.store(false, Ordering::SeqCst);
    let ask = skuld::wait_until("the question", 30, || {
        w.events.of("notebook-input-request").into_iter().next()
    });
    assert_eq!(ask["prompt"], "name? ");
    skuld::wait_until("the latest status", 30, || {
        w.events
            .of("notebook-status")
            .last()
            .filter(|s| s["state"] == "busy" && s["cell"] == "a")
            .cloned()
    });
    w.hub
        .input(7, &id, ask["request"].as_str().unwrap(), "z")
        .await
        .unwrap();
    skuld::wait_until("done", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["text"] == "z" && t["head"]["state"] == "idle")
    });
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_id_the_notebook_does_not_have_is_not_queued() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(7, &id, &[sync("ghost", "x"), sync("a", "ok")])
        .await
        .unwrap();
    skuld::wait_until("a done", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["text"] == "ok" && t["head"]["state"] == "idle")
    });
    assert_eq!(
        *seen.executed.lock().unwrap(),
        ["ok"],
        "the kernel was asked for nothing else"
    );
    assert!(
        w.events.tail("ghost").is_none(),
        "no state or tail was made for it"
    );
    assert!(
        !w.hub
            .get(7, &id)
            .unwrap()
            .states
            .lock()
            .unwrap()
            .contains_key("ghost"),
        "no run state is kept for an id the notebook does not have"
    );
    skuld::wait_until("nothing held", 30, || {
        (w.hub.held_runs(7, &id) == Some(0)).then_some(())
    });
    w.hub.close(7, &id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn opens_that_run_at_once_cannot_pass_the_limit_together() {
    let w = world("signal");
    let hub = Arc::new(w.hub);
    let path = w.path.clone();
    let tasks: Vec<_> = (0..(MAX_OPEN * 3))
        .map(|_| {
            let (hub, path) = (hub.clone(), path.clone());
            tokio::spawn(async move { hub.open(9, &path, None).await.is_ok() })
        })
        .collect();
    let mut ok = 0;
    for t in tasks {
        ok += usize::from(t.await.unwrap());
    }
    assert_eq!(ok, MAX_OPEN);
    // and a place that was reserved and not used is given back
    assert!(hub.open(9, &w.d.path().join("x.txt"), None).await.is_err());
    assert!(
        hub.open(10, &path, None).await.is_ok(),
        "another connection has its own places"
    );
}
