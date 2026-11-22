//! Kernels are real processes (`sh` scripts that are not kernels) with a scripted peer in the test playing the sockets.

use std::path::PathBuf;

use bytes::Bytes;
use serde_json::{Value, json};
use zeromq::{PubSocket, RouterSocket, Socket, SocketRecv, SocketSend, ZmqMessage};

use super::*;
use crate::notebook::session::frames;
use crate::notebook::spec::private_folder;
use crate::notebook::wire::{self, Key};

fn spec(script: &str, interrupt: Interrupt) -> Kernelspec {
    Kernelspec {
        name: "fake".into(),
        display_name: "Fake".into(),
        language: "fake".into(),
        argv: vec![
            "sh".into(),
            "-c".into(),
            script.into(),
            "kernel".into(),
            "{connection_file}".into(),
        ],
        env: vec![],
        interrupt,
        transport: crate::notebook::spec::Transport::Ipc,
        dir: PathBuf::from("/nowhere"),
    }
}

fn quick() -> Timeouts {
    Timeouts {
        ready: Duration::from_secs(30),
        ping: Duration::from_millis(20),
        grace: Duration::from_millis(300),
        ..Timeouts::default()
    }
}

fn tmp() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("nk")
        .tempdir_in("/tmp")
        .unwrap()
}

fn group_alive(pid: i32) -> bool {
    // SAFETY: signal 0 only tests for existence
    unsafe { libc::kill(-pid, 0) == 0 }
}

fn zmq(key: &Key, m: &Message) -> ZmqMessage {
    let frames: Vec<Bytes> = wire::encode(key, m).into_iter().map(Bytes::from).collect();
    ZmqMessage::try_from(frames).unwrap()
}

/// The scripted kernel's side: binds the sockets a real kernel would, before the hub looks.
struct Peer {
    shell: RouterSocket,
    iopub: PubSocket,
    control: RouterSocket,
    _stdin: RouterSocket,
}

async fn bind(folder: &Path, id: &str) -> Peer {
    let prefix = folder.join(format!("k-{id}"));
    let ep = |n| format!("ipc://{}-{n}", prefix.display());
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
    Peer {
        shell,
        iopub,
        control,
        _stdin: stdin,
    }
}

/// The key is only known once the connection file exists: read it from there, as a kernel does.
async fn key_of(folder: &Path, id: &str) -> Key {
    let path = folder.join(format!("kernel-{id}.json"));
    skuld::wait_until_async("the connection file", 30, || async {
        let v: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
        Key::from_connection_file(v["key"].as_str()?)
    })
    .await
}

/// Answer `kernel_info_request` on shell with a reply and publish a `status`, until told to stop; hand the socket back after.
fn serve_ready(mut p: Peer, key: Key) -> tokio::task::JoinHandle<Peer> {
    tokio::spawn(async move {
        loop {
            let f = frames(p.shell.recv().await.unwrap());
            let req = wire::decode(&key, &f).unwrap();
            let mut rep = Message::request("kernel", "kernel_info_reply", json!({"status": "ok"}));
            rep.parent = serde_json::to_value(&req.header).unwrap();
            rep.idents = vec![f[0].clone()];
            p.shell.send(zmq(&key, &rep)).await.unwrap();
            let st = Message::request("kernel", "status", json!({"execution_state": "idle"}));
            p.iopub.send(zmq(&key, &st)).await.unwrap();
            if req.header.msg_type != "kernel_info_request" {
                return p;
            }
            if !f.is_empty() && req.content.get("last").is_some() {
                return p;
            }
        }
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_that_exits_at_once_is_an_error_with_its_stderr_and_leaves_no_file() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let e = Kernel::start(
        &spec("echo boom >&2; exit 3", Interrupt::Signal),
        &folder,
        "a",
        d.path(),
        quick(),
    )
    .await
    .err()
    .unwrap();
    assert!(e.contains("exited with 3") && e.contains("boom"), "{e}");
    assert!(
        !folder.join("kernel-a.json").exists(),
        "the connection file went with the kernel"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_that_never_binds_is_killed_with_its_group_at_the_deadline() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let pidfile = d.path().join("pid");
    let script = format!("echo $$ > {}; sleep 600 & wait", pidfile.display());
    let t = Timeouts {
        ready: Duration::from_millis(300),
        ..quick()
    };
    let e = Kernel::start(&spec(&script, Interrupt::Signal), &folder, "b", d.path(), t)
        .await
        .err()
        .unwrap();
    assert!(e.contains("not ready within"), "{e}");
    let pid: i32 = std::fs::read_to_string(&pidfile)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    skuld::wait_until("the group to go", 30, || (!group_alive(pid)).then_some(()));
    assert!(!folder.join("kernel-b.json").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_is_ready_when_it_answers_kernel_info_and_publishes_a_status() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let peer = bind(&folder, "c").await;
    let serving = tokio::spawn({
        let folder = folder.clone();
        async move { serve_ready(peer, key_of(&folder, "c").await).await.unwrap() }
    });
    let k = Kernel::start(
        &spec("sleep 600", Interrupt::Signal),
        &folder,
        "c",
        d.path(),
        quick(),
    )
    .await
    .unwrap();
    assert!(group_alive(k.pid()));
    let id = k
        .request(Channel::Shell, "execute_request", json!({"code": "1+1"}))
        .unwrap();
    assert!(id.starts_with(&k.session_id));
    let exit = k.shutdown().await;
    assert!(
        exit.signal.is_some(),
        "a kernel that ignores the request is killed after the grace: {exit:?}"
    );
    drop(serving);
    assert!(!folder.join("kernel-c.json").exists());
}

/// A status published before the hub's SUB took hold is lost (a slow joiner): the hub must ask again until one arrives, not stop at the reply.
#[tokio::test(flavor = "multi_thread")]
async fn a_status_lost_before_the_subscription_took_hold_is_asked_for_again() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let mut peer = bind(&folder, "c").await;
    let key = key_of_later(&folder, "c");
    tokio::spawn(async move {
        let key = key.await;
        let mut first = true;
        loop {
            let f = frames(peer.shell.recv().await.unwrap());
            let req = wire::decode(&key, &f).unwrap();
            let mut rep = Message::request("kernel", "kernel_info_reply", json!({"status": "ok"}));
            rep.parent = serde_json::to_value(&req.header).unwrap();
            rep.idents = vec![f[0].clone()];
            peer.shell.send(zmq(&key, &rep)).await.unwrap();
            if !std::mem::take(&mut first) {
                let st = Message::request("kernel", "status", json!({"execution_state": "idle"}));
                peer.iopub.send(zmq(&key, &st)).await.unwrap();
            }
        }
    });
    let t = Timeouts {
        ready: Duration::from_secs(5),
        ..quick()
    };
    let k = Kernel::start(
        &spec("sleep 600", Interrupt::Signal),
        &folder,
        "c",
        d.path(),
        t,
    )
    .await
    .expect("ready once a later status arrives");
    k.shutdown().await;
}

fn key_of_later(
    folder: &Path,
    id: &str,
) -> impl std::future::Future<Output = Key> + Send + 'static {
    let (folder, id) = (folder.to_path_buf(), id.to_string());
    async move { key_of(&folder, &id).await }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_killed_from_outside_is_reported_as_exited() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let peer = bind(&folder, "d").await;
    let f2 = folder.clone();
    tokio::spawn(async move { serve_ready(peer, key_of(&f2, "d").await).await });
    let mut k = Kernel::start(
        &spec("sleep 600", Interrupt::Signal),
        &folder,
        "d",
        d.path(),
        quick(),
    )
    .await
    .unwrap();
    // SAFETY: the group of the kernel this test started
    unsafe { libc::kill(-k.pid(), libc::SIGKILL) };
    loop {
        match k.next().await {
            KernelEvent::Exited(e) => {
                assert_eq!(e.signal, Some(libc::SIGKILL));
                break;
            }
            KernelEvent::Message(..) => {}
            other => panic!("{other:?}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn interrupt_is_a_signal_to_the_group_or_a_control_message() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let marker = d.path().join("got-int");
    let up = d.path().join("trap-set");
    let script = format!(
        "trap 'echo got > {}' INT; echo up > {}; while :; do sleep 0.05; done",
        marker.display(),
        up.display()
    );
    let peer = bind(&folder, "e").await;
    let f2 = folder.clone();
    tokio::spawn(async move { serve_ready(peer, key_of(&f2, "e").await).await });
    let k = Kernel::start(
        &spec(&script, Interrupt::Signal),
        &folder,
        "e",
        d.path(),
        quick(),
    )
    .await
    .unwrap();
    // ready does not mean the script got as far as its trap
    skuld::wait_until("the script's trap", 30, || up.exists().then_some(()));
    k.interrupt().unwrap();
    skuld::wait_until("the kernel's SIGINT trap", 30, || {
        marker.exists().then_some(())
    });
    k.kill().await;

    // message mode: the request reaches control, nothing is signalled
    let peer = bind(&folder, "f").await;
    let f2 = folder.clone();
    let key_task = tokio::spawn(async move { key_of(&f2, "f").await });
    let marker2 = d.path().join("got-int-2");
    let script2 = format!(
        "trap 'echo got > {}' INT; while :; do sleep 0.05; done",
        marker2.display()
    );
    let f3 = folder.clone();
    let start = tokio::spawn({
        let d = d.path().to_path_buf();
        async move { Kernel::start(&spec(&script2, Interrupt::Message), &f3, "f", &d, quick()).await }
    });
    let key = key_task.await.unwrap();
    let serving = serve_ready(peer, key.clone());
    let k = start.await.unwrap().unwrap();
    let mut p = {
        // the ready loop ends with the next request; give the peer back by sending one that says so
        k.request(Channel::Shell, "kernel_info_request", json!({"last": true}))
            .unwrap();
        serving.await.unwrap()
    };
    k.interrupt().unwrap();
    let f = frames(p.control.recv().await.unwrap());
    assert_eq!(
        wire::decode(&key, &f).unwrap().header.msg_type,
        "interrupt_request"
    );
    assert!(!marker2.exists(), "no signal was sent");
    k.kill().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_that_floods_the_hub_is_killed() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let mut peer = bind(&folder, "g").await;
    let key = {
        let f2 = folder.clone();
        let k = tokio::spawn(async move { key_of(&f2, "g").await });
        let start = tokio::spawn({
            let (folder, d) = (folder.clone(), d.path().to_path_buf());
            let t = Timeouts {
                limits: Limits {
                    flood_bytes: 150_000,
                    ..Limits::default()
                },
                ..quick()
            };
            async move {
                Kernel::start(&spec("sleep 600", Interrupt::Signal), &folder, "g", &d, t).await
            }
        });
        let key = k.await.unwrap();
        // answer the first kernel_info_request, then publish; ready needs the status too
        let f = frames(peer.shell.recv().await.unwrap());
        let req = wire::decode(&key, &f).unwrap();
        let mut rep = Message::request("kernel", "kernel_info_reply", json!({}));
        rep.parent = serde_json::to_value(&req.header).unwrap();
        rep.idents = vec![f[0].clone()];
        peer.shell.send(zmq(&key, &rep)).await.unwrap();
        let st = zmq(
            &key,
            &Message::request("kernel", "status", json!({"execution_state": "idle"})),
        );
        let peer = tokio::sync::Mutex::new(peer);
        skuld::wait_until_async("ready", 30, || async {
            peer.lock().await.iopub.send(st.clone()).await.unwrap();
            start.is_finished().then_some(())
        })
        .await;
        let mut peer = peer.into_inner();
        let mut kernel = start.await.unwrap().unwrap();
        let big = json!({"name": "stdout", "text": "x".repeat(60_000)});
        for _ in 0..8 {
            peer.iopub
                .send(zmq(
                    &key,
                    &Message::request("kernel", "stream", big.clone()),
                ))
                .await
                .unwrap();
        }
        let pid = kernel.pid();
        let mut seen = Vec::new();
        loop {
            match kernel.next().await {
                KernelEvent::Flood => break,
                KernelEvent::Exited(e) => panic!(
                    "exited before the flood was seen: pid {pid} (kernel id g), exit code {:?} signal {:?} stderr {:?}; \
                     events before it: {seen:?}",
                    e.code, e.signal, e.stderr
                ),
                KernelEvent::Message(c, m) => {
                    seen.push(format!("message {c:?} {}", m.header.msg_type))
                }
                KernelEvent::Closed(c, why) => seen.push(format!("closed {c:?}: {why}")),
            }
        }
        skuld::wait_until("the flooding kernel's group to go", 30, || {
            (!group_alive(pid)).then_some(())
        });
        key
    };
    let _ = key;
}

fn plan(enforced: crate::agents::lock::Enforced) -> crate::agents::lock::LaunchPlan {
    crate::agents::lock::LaunchPlan {
        argv: vec![],
        env: vec![],
        session_meta: None,
        protected_ro: vec![],
        login_dir: None,
        enforced,
        gateway: false,
        trace: None,
        ro_files: vec![],
        gateway_url_env: vec![],
    }
}

#[test]
fn a_sealed_session_refuses_a_kernel_and_an_ordinary_one_does_not() {
    use crate::agents::lock::Enforced;
    let r = refuse_when_sealed(&plan(Enforced::Yes)).unwrap_err();
    assert_eq!(
        r.0,
        "a notebook kernel runs unconfined and is not started in a sealed session"
    );
    assert_eq!(
        refuse_when_sealed(&plan(Enforced::No("an ordinary session"))),
        Ok(())
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_start_that_is_dropped_part_way_kills_the_kernel_it_began() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let pidfile = d.path().join("pid");
    let script = format!("echo $$ > {}; sleep 600 & wait", pidfile.display());
    let (folder2, cwd) = (folder.clone(), d.path().to_path_buf());
    let start = tokio::spawn(async move {
        Kernel::start(
            &spec(&script, Interrupt::Signal),
            &folder2,
            "x",
            &cwd,
            quick(),
        )
        .await
    });
    let pid: i32 = skuld::wait_until("the kernel's pid", 30, || {
        std::fs::read_to_string(&pidfile).ok()?.trim().parse().ok()
    });
    start.abort();
    let _ = start.await;
    skuld::wait_until("the group to go", 30, || (!group_alive(pid)).then_some(()));
}

#[tokio::test(flavor = "multi_thread")]
async fn start_checks_the_private_folder_itself() {
    let d = tmp();
    let folder = d.path().join("loose");
    std::fs::create_dir(&folder).unwrap();
    std::fs::set_permissions(&folder, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let e = Kernel::start(
        &spec("sleep 600", Interrupt::Signal),
        &folder,
        "p",
        d.path(),
        quick(),
    )
    .await
    .err()
    .unwrap();
    assert!(e.contains("0700"), "{e}");
}

#[tokio::test(flavor = "multi_thread")]
async fn workers_a_kernel_forked_go_with_it_and_nothing_is_signalled_after_it_is_gone() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let workers = d.path().join("worker");
    let peer = bind(&folder, "w").await;
    let f2 = folder.clone();
    tokio::spawn(async move { serve_ready(peer, key_of(&f2, "w").await).await });
    let script = format!(
        "sleep 600 & echo $! > {}; exec sleep 600",
        workers.display()
    );
    let mut k = Kernel::start(
        &spec(&script, Interrupt::Signal),
        &folder,
        "w",
        d.path(),
        quick(),
    )
    .await
    .unwrap();
    let worker: i32 = skuld::wait_until("the worker's pid", 30, || {
        std::fs::read_to_string(&workers).ok()?.trim().parse().ok()
    });
    // only the leader dies (not its group)
    // SAFETY: the process this test started
    unsafe { libc::kill(k.pid(), libc::SIGKILL) };
    loop {
        if let KernelEvent::Exited(_) = k.next().await {
            break;
        }
    }
    skuld::wait_until("the forked worker to go", 30, || {
        (!draugr::alive(worker)).then_some(())
    });
    assert!(
        k.interrupt().is_err(),
        "no signal goes to a group whose leader is gone"
    );
}

#[cfg(feature = "test-hooks")]
#[test]
fn a_wait_for_an_exit_that_never_comes_ends_at_its_bound_on_the_virtual_clock() {
    // the test's own clock: the process's (install_virtual) would reach every other test's threads
    crate::clock::on_virtual(async {
        // the sender stays: the exit is never sent, and the channel is not closed
        let (_tx, mut rx) = watch::channel(None::<Exit>);
        let waiting = crate::clock::spawn("test:exit-wait", async move {
            exited_within(&mut rx, END_WITHIN).await
        });
        crate::clock::advance(END_WITHIN).await;
        assert_eq!(waiting.await.unwrap(), None);
        let (tx, mut rx) = watch::channel(None::<Exit>);
        let exit = Exit {
            code: Some(0),
            signal: None,
            stderr: String::new(),
        };
        tx.send(Some(exit.clone())).unwrap();
        assert_eq!(exited_within(&mut rx, END_WITHIN).await, Some(exit));
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn kill_and_the_wait_after_a_kill_are_bounded_by_exited_within() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let peer = bind(&folder, "bw").await;
    let f2 = folder.clone();
    tokio::spawn(async move { serve_ready(peer, key_of(&f2, "bw").await).await });
    let k = Kernel::start(
        &spec("sleep 600", Interrupt::Signal),
        &folder,
        "bw",
        d.path(),
        quick(),
    )
    .await
    .unwrap();
    let before = BOUNDED_WAITS.load(std::sync::atomic::Ordering::SeqCst);
    let exit = k.kill().await;
    assert!(exit.signal.is_some());
    assert!(
        BOUNDED_WAITS.load(std::sync::atomic::Ordering::SeqCst) > before,
        "the wait went through exited_within"
    );
}

// ----- the transport: ipc first, tcp for a kernel that cannot (design §5.2) -----

use crate::notebook::spec::Transport;

/// A kernel that writes the transport its connection file names to LOG, then ends with 3 (a refusal: no socket was made).
fn recording(log: &Path, transport: Transport, tail: &str) -> Kernelspec {
    let script = format!(
        "grep -o '\"transport\":\"[a-z]*\"' \"$1\" >> {}; {tail}",
        log.display()
    );
    let mut s = spec(&script, Interrupt::Signal);
    s.transport = transport;
    s
}

fn transports(log: &Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(|l| l.replace("\"transport\":", "").replace('"', ""))
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_that_refuses_ipc_is_started_once_more_over_tcp_and_the_error_names_both() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let log = d.path().join("log");
    let e = Kernel::start(
        &recording(&log, Transport::Ipc, "echo no ipc >&2; exit 3"),
        &folder,
        "a",
        d.path(),
        quick(),
    )
    .await
    .err()
    .unwrap();
    assert_eq!(
        transports(&log),
        ["ipc", "tcp"],
        "one try each, in that order"
    );
    assert!(
        e.contains("over ipc") && e.contains("over tcp") && e.contains("no ipc"),
        "{e}"
    );
    assert!(!folder.join("kernel-a.json").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernelspec_that_says_tcp_is_tried_over_tcp_only() {
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let log = d.path().join("log");
    let e = Kernel::start(
        &recording(&log, Transport::Tcp, "exit 3"),
        &folder,
        "a",
        d.path(),
        quick(),
    )
    .await
    .err()
    .unwrap();
    assert_eq!(transports(&log), ["tcp"]);
    assert!(!e.contains("over ipc"), "{e}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_kernel_that_started_and_was_not_ready_is_not_tried_over_tcp() {
    // a kernel that made no refusal (it is alive, only silent) has nothing to do with the transport
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let log = d.path().join("log");
    let t = Timeouts {
        ready: Duration::from_millis(300),
        ..quick()
    };
    let e = Kernel::start(
        &recording(&log, Transport::Ipc, "sleep 600 & wait"),
        &folder,
        "a",
        d.path(),
        t,
    )
    .await
    .err()
    .unwrap();
    assert_eq!(transports(&log), ["ipc"]);
    assert!(e.contains("not ready within"), "{e}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_listener_that_is_not_the_kernels_is_an_error_naming_the_port_and_is_never_connected_to()
{
    let d = tmp();
    let folder = private_folder(&d.path().join("s")).unwrap();
    let block = crate::debug::ports::machine().claim().unwrap();
    let port = block.ports()[0];
    // a stranger (this process, not the kernel's group) listens on the shell port before the kernel does
    let stranger = std::net::TcpListener::bind(("127.0.0.1", port)).unwrap();
    stranger.set_nonblocking(true).unwrap();
    let log = d.path().join("log");
    let e = Kernel::start_on(
        &recording(&log, Transport::Tcp, "sleep 600 & wait"),
        &folder,
        "a",
        d.path(),
        quick(),
        Some(block),
    )
    .await
    .err()
    .unwrap();
    assert!(
        e.contains(&format!("port {port}")) && e.contains("not the session's"),
        "{e}"
    );
    assert!(
        matches!(stranger.accept(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock),
        "the hub never connected to a port that is not the kernel's"
    );
    assert!(!folder.join("kernel-a.json").exists());
}
