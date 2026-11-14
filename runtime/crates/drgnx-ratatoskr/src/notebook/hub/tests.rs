//! The hub's notebooks against real `sh` processes standing in for kernels and a scripted peer playing their sockets.

use bytes::Bytes;
use zeromq::{PubSocket, RouterSocket, Socket, SocketRecv, SocketSend, ZmqMessage};

use super::*;
use crate::agents::lock::Enforced;
use crate::notebook::session::frames;
use crate::notebook::spec::private_folder;
use crate::notebook::wire::{self, Key};

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
struct Events(Mutex<Vec<(u64, String, Value)>>);

impl Sink for Events {
    fn broadcast(&self, _: &str, _: Value, _: Option<u64>) {}
    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.0.lock().unwrap().push((conn, event.into(), data));
        true
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
fn kernel_side(folder: &Path, nth: u32, seen: Arc<Seen>) -> tokio::task::JoinHandle<()> {
    let prefix = folder.join(format!("k-nb1-k{nth}"));
    let ep = move |n| format!("ipc://{}-{n}", prefix.display());
    let path = folder.join(format!("kernel-nb1-k{nth}.json"));
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
            let code = req.content["code"].as_str().unwrap_or("").to_string();
            seen.executed.lock().unwrap().push(code.clone());
            count += 1;
            iopub.send(status("busy")).await.unwrap();
            if code == "SLOW" {
                continue;
            }
            let mut text = code.clone();
            if code == "ASK" {
                let mut ask = reply_to(
                    &req,
                    "input_request",
                    json!({"prompt": "name? ", "password": false}),
                );
                ask.idents = vec![f[0].clone()];
                stdin.send(zmq(&key, &ask)).await.unwrap();
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
        }
    })
}

async fn started(w: &World) -> (String, Arc<Seen>) {
    let opened = w.hub.open(7, &w.path, None).await.unwrap();
    assert_eq!(opened.id, "nb1");
    let seen = Arc::new(Seen::default());
    kernel_side(
        &private_folder(&w.d.path().join("s")).unwrap(),
        1,
        seen.clone(),
    );
    assert_eq!(w.hub.start("nb1", None, None).await.unwrap(), "fake");
    ("nb1".into(), seen)
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
        w.hub.tail("nb1", "a").await.unwrap()["stale"]
            .as_bool()
            .unwrap()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cell_runs_its_output_reaches_the_editor_and_save_writes_it() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub.execute(&id, &[sync("a", "print(1)")]).await.unwrap();
    let t = skuld::wait_until("the cell's tail", 30, || {
        w.events.tail("a").filter(|t| t["text"] == "print(1)")
    });
    assert_eq!(
        (t["stale"].as_bool(), t["id"].as_str()),
        (Some(false), Some("nb1"))
    );
    assert!(t["version"].as_u64().unwrap() >= 2);
    skuld::wait_until("idle", 30, || {
        (w.events.state().as_deref() == Some("idle")).then_some(())
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["print(1)"]);
    // the editor is told through the connection that opened it
    assert!(w.events.0.lock().unwrap().iter().all(|e| e.0 == 7));
    w.hub.save(&id, None).await.unwrap();
    let saved: Value = serde_json::from_slice(&std::fs::read(&w.path).unwrap()).unwrap();
    assert_eq!(saved["cells"][0]["outputs"][0]["text"], json!(["print(1)"]));
    assert_eq!(saved["cells"][0]["execution_count"], 1);
    assert_eq!(saved["cells"][0]["source"], json!(["print(1)"]));
    w.hub.close(&id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_error_aborts_the_cells_queued_behind_it_and_they_never_reach_the_kernel() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(
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
    w.hub.close(&id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_interrupt_cancels_what_is_queued_and_asks_the_kernel_by_message_when_its_spec_says_so()
{
    let w = world("message");
    let (id, seen) = started(&w).await;
    w.hub
        .execute(&id, &[sync("a", "SLOW"), sync("b", "x")])
        .await
        .unwrap();
    skuld::wait_until("a busy", 30, || {
        w.events
            .of("notebook-status")
            .iter()
            .any(|s| s["state"] == "busy" && s["cell"] == "a")
            .then_some(())
    });
    w.hub.interrupt(&id).await.unwrap();
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
    w.hub.close(&id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_asking_for_input_gets_the_answer_through_the_stdin_socket() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(&id, &[sync("a", "ASK")]).await.unwrap();
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
        .input(&id, ask["request"].as_str().unwrap(), "bob")
        .await
        .unwrap();
    skuld::wait_until("the answer shown", 30, || {
        w.events.tail("a").filter(|t| t["text"] == "bob")
    });
    w.hub.close(&id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_sealed_session_gets_no_kernel_and_a_missing_kernel_is_named() {
    let w = world("signal");
    w.hub.open(7, &w.path, None).await.unwrap();
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
    let e = w.hub.start("nb1", None, Some(&plan)).await.unwrap_err();
    assert_eq!(
        e,
        "a notebook kernel runs unconfined and is not started in a sealed session"
    );
    assert!(w.hub.start("nope", None, None).await.is_err());
    assert!(
        w.hub.execute("nb1", &[sync("a", "x")]).await.is_err(),
        "no kernel started"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn shutdown_ends_the_kernel_says_so_and_removes_its_connection_file() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    let file = private_folder(&w.d.path().join("s"))
        .unwrap()
        .join("kernel-nb1-k1.json");
    assert!(file.exists());
    let exit = w.hub.shutdown(&id).await.unwrap();
    assert!(exit.signal.is_some() || exit.code.is_some());
    assert_eq!(w.events.state().as_deref(), Some("dead"));
    skuld::wait_until("the file to go", 30, || (!file.exists()).then_some(()));
    assert!(w.hub.kernel_name(&id).is_none());
    assert!(
        w.hub.shutdown(&id).await.is_err(),
        "a second one has nothing to end"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tail_carries_the_execution_count_and_a_head_that_follows_the_cell_through_its_states() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(&id, &[sync("a", "SLOW")]).await.unwrap();
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
    w.hub.close(&id).await;

    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(&id, &[sync("a", "ok")]).await.unwrap();
    let done = skuld::wait_until("the finished head", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["head"]["state"] == "idle" && t["execution_count"] == 1)
    });
    assert_eq!(done["head"]["text"], "[1]  fake");
    w.hub.close(&id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn clear_empties_one_cell_or_all_and_leaves_a_running_cell_alone() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub
        .execute(&id, &[sync("a", "ok"), sync("b", "two")])
        .await
        .unwrap();
    skuld::wait_until("both done", 30, || {
        w.events
            .tail("b")
            .filter(|t| t["text"] == "two" && t["head"]["state"] == "idle")
    });
    w.hub.clear(&id, Some("a")).await.unwrap();
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
        w.hub.tail(&id, "b").await.unwrap()["text"],
        "two",
        "the other cell keeps its output"
    );
    w.hub.clear(&id, None).await.unwrap();
    assert_eq!(w.hub.tail(&id, "b").await.unwrap()["text"], "");
    assert!(w.hub.clear(&id, Some("nope")).await.is_err());
    // a running cell is not cleared
    w.hub.execute(&id, &[sync("c", "SLOW")]).await.unwrap();
    skuld::wait_until("c running", 30, || {
        w.events
            .tail("c")
            .filter(|t| t["head"]["state"] == "running")
    });
    let before = w.events.of("notebook-tail").len();
    w.hub.clear(&id, Some("c")).await.unwrap();
    assert_eq!(
        w.hub.tail(&id, "c").await.unwrap()["head"]["state"],
        "running"
    );
    assert!(w.events.of("notebook-tail").len() >= before);
    w.hub.close(&id).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_ends_the_kernel_and_starts_a_new_one_with_a_new_connection() {
    let w = world("signal");
    let (id, seen) = started(&w).await;
    w.hub.execute(&id, &[sync("a", "before")]).await.unwrap();
    skuld::wait_until("ran", 30, || {
        w.events.tail("a").filter(|t| t["text"] == "before")
    });
    let folder = private_folder(&w.d.path().join("s")).unwrap();
    let seen2 = Arc::new(Seen::default());
    kernel_side(&folder, 2, seen2.clone());
    assert_eq!(w.hub.restart(&id).await.unwrap(), "fake");
    assert!(
        !folder.join("kernel-nb1-k1.json").exists(),
        "the old connection file went"
    );
    assert!(
        folder.join("kernel-nb1-k2.json").exists(),
        "a new one, with its own key"
    );
    w.hub.execute(&id, &[sync("b", "after")]).await.unwrap();
    skuld::wait_until("ran on the new kernel", 30, || {
        w.events.tail("b").filter(|t| t["text"] == "after")
    });
    assert_eq!(*seen.executed.lock().unwrap(), ["before"]);
    assert_eq!(*seen2.executed.lock().unwrap(), ["after"]);
    assert!(w.hub.restart("nope").await.is_err());
    w.hub.close(&id).await;
}
