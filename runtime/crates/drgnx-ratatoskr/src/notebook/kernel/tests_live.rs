//! Live: a real ipykernel, over ipc and over tcp (design §5.2, §5.3; `docs/develop/testing.md`, "Live notebook kernels").
//!
//! The kernel is the hash-pinned one of `test/container/ipykernel-requirements.txt` (the adapter image has it as a Python 3.15
//! venv at `/opt/nb-kernel`, `test/container/debug-adapters-image.sh`): `DRGNX_NB_KERNEL_PYTHON` names its python. A lane that
//! runs the ignored rows without it fails here, naming the image; it never skips.

use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;
use crate::notebook::spec::{Transport, private_folder};

/// The python of the pinned kernel venv.
fn kernel_python() -> String {
    let python = std::env::var("DRGNX_NB_KERNEL_PYTHON")
        .unwrap_or_else(|_| "/opt/nb-kernel/bin/python3".into());
    let ok = std::process::Command::new(&python)
        .args(["-c", "import ipykernel_launcher"])
        .output()
        .is_ok_and(|o| o.status.success());
    assert!(
        ok,
        "{python} cannot import ipykernel: run these rows in the adapter image (test/container/Containerfile.debug), which has the hash-pinned kernel at /opt/nb-kernel and sets DRGNX_NB_KERNEL_PYTHON"
    );
    python
}

fn live_spec(transport: Transport) -> Kernelspec {
    Kernelspec {
        name: "python3-live".into(),
        display_name: "Python (live test)".into(),
        language: "python".into(),
        argv: vec![
            kernel_python(),
            "-m".into(),
            "ipykernel_launcher".into(),
            "-f".into(),
            "{connection_file}".into(),
        ],
        env: vec![],
        interrupt: Interrupt::Signal,
        transport,
        dir: PathBuf::from("/nowhere"),
    }
}

fn tmp() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("nl")
        .tempdir_in("/tmp")
        .unwrap()
}

fn timeouts() -> Timeouts {
    Timeouts {
        ready: Duration::from_secs(120),
        grace: Duration::from_secs(10),
        ..Timeouts::default()
    }
}

/// What a cell run showed: its iopub text, the shell reply's status, and whether an input request came.
#[derive(Default, Debug)]
struct Run {
    stream: String,
    status: Option<String>,
    error_name: Option<String>,
    asked: Option<String>,
}

/// Send CODE and read events until its shell reply and its `idle` status are both in; INPUT answers an `input_request`.
async fn run(k: &mut Kernel, code: &str, input: Option<&str>) -> Run {
    let id = k
        .request(
            Channel::Shell,
            "execute_request",
            json!({"code": code, "silent": false, "store_history": true, "allow_stdin": input.is_some(), "stop_on_error": true}),
        )
        .unwrap();
    let (mut out, mut reply, mut idle) = (Run::default(), false, false);
    while !(reply && idle) {
        let ev = crate::clock::timeout(Duration::from_secs(60), k.next())
            .await
            .unwrap_or_else(|_| panic!("no end to {code:?}: {out:?}"));
        let KernelEvent::Message(channel, m) = ev else {
            panic!("the kernel ended or failed during {code:?}: {ev:?}");
        };
        let ours = m.parent.get("msg_id").and_then(Value::as_str) == Some(id.as_str());
        match (channel, m.header.msg_type.as_str()) {
            (Channel::Stdin, "input_request") => {
                out.asked = m
                    .content
                    .get("prompt")
                    .and_then(Value::as_str)
                    .map(String::from);
                // the reply goes back through the stdin socket, which carries the shell's identity
                let mut r = Message::request(
                    &k.session_id,
                    "input_reply",
                    json!({"value": input.unwrap_or(""), "status": "ok"}),
                );
                r.parent = serde_json::to_value(&m.header).unwrap();
                k.send(Channel::Stdin, &r).unwrap();
            }
            (Channel::Iopub, "stream") if ours => {
                out.stream
                    .push_str(m.content["text"].as_str().unwrap_or(""));
            }
            (Channel::Iopub, "error") if ours => {
                out.error_name = m
                    .content
                    .get("ename")
                    .and_then(Value::as_str)
                    .map(String::from);
            }
            (Channel::Iopub, "status") if ours => {
                idle = m.content["execution_state"] == "idle";
            }
            (Channel::Shell, "execute_reply") if ours => {
                out.status = m
                    .content
                    .get("status")
                    .and_then(Value::as_str)
                    .map(String::from);
                reply = true;
            }
            _ => {}
        }
    }
    out
}

/// The whole life of one real kernel on TRANSPORT: ready, code, an error, `input()` through the stdin socket, an interrupt, an
/// orderly shutdown, and nothing left behind.
async fn a_real_kernel_lives(transport: Transport) -> (tempfile::TempDir, PathBuf) {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let mut k = Kernel::start(&live_spec(transport), &folder, "live", d.path(), timeouts())
        .await
        .unwrap_or_else(|e| panic!("the kernel did not start: {e}"));
    let pid = k.pid();
    let file = folder.join("kernel-live.json");
    let body: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(
        body["transport"],
        if transport == Transport::Tcp {
            "tcp"
        } else {
            "ipc"
        },
        "{body}"
    );
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    if transport == Transport::Tcp {
        // the ports the hub claimed are the kernel's own: every listener on each is in the kernel's group (the check the
        // hub made before it connected, and that this run proves can say yes)
        for ch in ["shell", "iopub", "stdin", "control"] {
            let port = u16::try_from(body[format!("{ch}_port")].as_u64().unwrap()).unwrap();
            assert_eq!(
                crate::debug::ports::exclusively_owned(port, &[pid]),
                Ok(true),
                "{ch} port {port}"
            );
        }
        assert_eq!(body["ip"], "127.0.0.1");
    }

    let out = run(&mut k, "print(1 + 1)", None).await;
    assert_eq!(
        (out.status.as_deref(), out.stream.as_str()),
        (Some("ok"), "2\n"),
        "{out:?}"
    );

    let out = run(&mut k, "1 / 0", None).await;
    assert_eq!(
        (out.status.as_deref(), out.error_name.as_deref()),
        (Some("error"), Some("ZeroDivisionError")),
        "{out:?}"
    );

    let out = run(&mut k, "print('hello', input('name? '))", Some("Ada")).await;
    assert_eq!(out.asked.as_deref(), Some("name? "), "{out:?}");
    assert_eq!(out.stream, "hello Ada\n", "{out:?}");

    // a loop that never ends is interrupted by SIGINT to the group, and the kernel answers the next cell
    let id = k
        .request(
            Channel::Shell,
            "execute_request",
            json!({"code": "while True: pass", "stop_on_error": false}),
        )
        .unwrap();
    crate::clock::sleep(Duration::from_millis(500)).await;
    k.interrupt().unwrap();
    loop {
        match crate::clock::timeout(Duration::from_secs(30), k.next())
            .await
            .expect("the interrupt ended the loop")
        {
            KernelEvent::Message(Channel::Shell, m) if m.parent["msg_id"] == id.as_str() => {
                assert_eq!(m.content["status"], "error", "{:?}", m.content);
                assert_eq!(m.content["ename"], "KeyboardInterrupt");
                break;
            }
            KernelEvent::Exited(e) => panic!("the kernel died of the interrupt: {e}"),
            _ => {}
        }
    }
    let out = run(&mut k, "print('still here')", None).await;
    assert_eq!(out.stream, "still here\n", "{out:?}");

    let exit = k.shutdown().await;
    // The kernel ended by itself within the grace, not by our kill. (Its exit status is the kernel's own: ipykernel
    // sometimes aborts (SIGABRT) in its interpreter teardown, about one run in five, after it has done everything asked;
    // the status is printed whenever it is not a plain 0, so a pattern shows in the logs.)
    if exit.code != Some(0) {
        eprintln!(
            "the kernel's exit status after an orderly shutdown over {transport:?}: {exit:?}"
        );
    }
    assert!(
        exit.signal != Some(libc::SIGKILL) && exit.code.is_none_or(|c| c == 0),
        "an orderly shutdown ends the kernel by itself: {exit:?}"
    );
    assert!(!file.exists(), "the connection file goes with the kernel");
    // SAFETY: signal 0 only tests for existence
    assert!(
        unsafe { libc::kill(-pid, 0) } != 0,
        "no process of the kernel's group is left"
    );
    (d, folder)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: a real ipykernel (the adapter image: test/container/Containerfile.debug)"]
async fn a_real_ipykernel_lives_over_ipc() {
    let (_keep, folder) = a_real_kernel_lives(Transport::Ipc).await;
    // the sockets were files in the 0700 folder, and went with the kernel
    assert!(
        std::fs::read_dir(&folder)
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with("k-live-"))
    );
}

/// The positive path of the tcp transport and of `debug::ports::owned` over a kernel's group: a kernelspec that says it cannot
/// use ipc gets loopback ports the hub claimed, and the hub connects only once every listener on them is the kernel's.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: a real ipykernel (the adapter image: test/container/Containerfile.debug)"]
async fn a_real_ipykernel_lives_over_tcp() {
    let (_keep, folder) = a_real_kernel_lives(Transport::Tcp).await;
    // no socket files in the folder: the sockets were loopback ports, released with the kernel
    assert!(
        std::fs::read_dir(&folder)
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with("k-live"))
    );
}
