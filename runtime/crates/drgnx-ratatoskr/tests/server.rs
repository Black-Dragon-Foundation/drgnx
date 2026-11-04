//! The server core against the real binary, each hub in its own temporary root with a clean environment (`support`):
//! nothing reaches `~` or the user's runtime dir.

mod support;

use runstav::paths;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use support::{BIN, Hub, Root, ping};
#[cfg(feature = "test-hooks")]
use {
    serde_json::{Value, json},
    support::{Client, FAILED_AFTER, mock_binary},
};

fn mode(p: &Path) -> u32 {
    std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777
}

#[test]
fn methods_prints_the_committed_registry() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let run = |flag: &str| {
        let out = Command::new(BIN).args(["methods", flag]).output().unwrap();
        assert!(out.status.success(), "methods {flag}: {out:?}");
        String::from_utf8(out.stdout).unwrap()
    };
    let committed = std::fs::read_to_string(repo.join("runtime/protocol/methods.json")).unwrap();
    assert_eq!(run("--json"), committed);
    let docs = std::fs::read_to_string(repo.join("docs/develop/hub.md")).unwrap();
    let table = run("--markdown");
    assert!(table.starts_with("| Method | Class |"), "{table}");
    assert!(
        docs.contains(&table),
        "hub.md's table is not `methods --markdown`"
    );
    let out = Command::new(BIN).arg("methods").output().unwrap();
    assert_eq!(out.status.code(), Some(2), "neither flag is a usage error");
}

#[test]
fn peer_uid_is_checked() {
    use drgnx_ratatoskr::conn::peer_allowed;
    assert!(peer_allowed(1000, 1000));
    assert!(!peer_allowed(1001, 1000), "another user");
    assert!(!peer_allowed(0, 1000), "root is another uid too");
    assert!(!peer_allowed(1000, 0), "a hub run as root refuses users");
}

#[test]
fn two_hubs_one_lock_second_exits_3() {
    let root = Root::new();
    let socket = root.socket();
    let mut first = Hub::start(&root, 1);
    first.wait_ready(&socket);
    let mut second = Hub::start(&root, 2);
    let status = second.wait_exit();
    assert_eq!(status.code(), Some(3), "{}", second.stderr_text());
    assert!(
        second.stderr_text().contains("another hub serves here"),
        "{}",
        second.stderr_text()
    );
    // the first one still serves, its socket untouched
    assert!(ping(&socket));
    assert!(first.exited().is_none());
}

#[test]
fn the_path_is_statted_not_proc_self_exe() {
    use drgnx_ratatoskr::idle::ExeWatch;
    let dir = tempfile::tempdir().unwrap();
    let sleep = ["/usr/bin/sleep", "/bin/sleep"]
        .into_iter()
        .find(|p| Path::new(p).exists())
        .expect("a sleep binary");
    let (live, other) = (dir.path().join("live"), dir.path().join("other"));
    // `live` is a link to the system's sleep, never a file this process wrote: executing a file just written can fail
    // as busy (ETXTBSY) while another thread forks, and the link has nothing to wait for. The watch statts the path
    // (through the link); the replacement is a file of another inode.
    std::os::unix::fs::symlink(sleep, &live).unwrap();
    std::fs::copy(sleep, &other).unwrap();
    // a running process whose image is what `live` points to
    // `spawn` can return before the exec, while /proc/PID/exe still names this test binary: wait for the exec
    let mut cmd = Command::new(&live);
    cmd.arg("60");
    let (mut child, exec) = support::ExecHandshake::spawn(&mut cmd).unwrap();
    exec.wait();
    let by_path = ExeWatch::new(&live).unwrap();
    #[cfg(target_os = "linux")]
    let by_link = ExeWatch::new(Path::new(&format!("/proc/{}/exe", child.id()))).unwrap();
    assert!(!by_path.changed());
    // the update: a rename-replace of the file at the path
    std::fs::rename(&other, &live).unwrap();
    assert!(by_path.changed(), "the path now holds another file");
    #[cfg(target_os = "linux")]
    assert!(
        !by_link.changed(),
        "/proc/PID/exe follows the running inode, which a rename leaves alone"
    );
    // a missing file has not changed (it is looked at again later)
    std::fs::remove_file(&live).unwrap();
    assert!(!by_path.changed());
    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn launchd_never_loops_on_exit_3() {
    // launchd restarts on every non-zero exit: under `--supervisor launchd` "another hub serves" ends 0, with the
    // real code and reason in the hub's log and on stderr; without it the same start ends 3 (the test above)
    let root = Root::new();
    let socket = root.socket();
    let mut first = Hub::start(&root, 1);
    first.wait_ready(&socket);
    let mut second = Hub::start_with(&root, 2, &["--supervisor", "launchd"]);
    let status = second.wait_exit();
    assert_eq!(status.code(), Some(0), "{}", second.stderr_text());
    assert!(
        second.stderr_text().contains("another hub serves here"),
        "{}",
        second.stderr_text()
    );
    assert!(
        second.stderr_text().contains("exit 3 mapped to 0"),
        "{}",
        second.stderr_text()
    );
    assert!(ping(&socket));
}

#[test]
fn the_stop_command_ends_a_hub_and_signals_nothing_for_a_stale_lock() {
    let root = Root::new();
    let socket = root.socket();
    let stop = |extra: &[&str]| {
        Command::new(BIN)
            .arg("stop")
            .args(extra)
            .env_clear()
            .envs(root.vars())
            .output()
            .unwrap()
    };
    // a stale lock file naming a live process nobody holds: not running, and the process lives
    let mut sleeper = Command::new("sleep").arg("60").spawn().unwrap();
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    // private, as a hub makes it (stop refuses a directory open to others)
    paths::private_dir(socket.parent().unwrap()).unwrap();
    std::fs::write(paths::lock_path(&socket), format!("{} 1\n", sleeper.id())).unwrap();
    let out = stop(&[]);
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("not running"));
    assert!(
        sleeper.try_wait().unwrap().is_none(),
        "stop signalled a stale lock's pid"
    );
    let _ = sleeper.kill();
    let _ = sleeper.wait();
    // a running hub: stopped by name and pid
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let out = stop(&["--timeout", "10"]);
    assert_eq!(out.status.code(), Some(0), "{out:?} {}", hub.stderr_text());
    assert!(
        String::from_utf8_lossy(&out.stdout)
            .contains(&format!("stopped Ratatoskr (pid {})", hub.pid())),
        "{out:?}"
    );
    assert_eq!(hub.wait_exit().code(), Some(0));
}

#[test]
fn cap_is_64_hex_0600_and_gone_after_stop() {
    let root = Root::new();
    let socket = root.socket();
    let cap = paths::cap_path(&socket);
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let text = std::fs::read_to_string(&cap).unwrap();
    assert_eq!(text.len(), 64, "{text:?}");
    assert!(
        text.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    );
    assert_eq!(mode(&cap), 0o600);
    assert_eq!(mode(&socket), 0o600);
    assert_eq!(mode(socket.parent().unwrap()), 0o700);
    // no temporary file of the cap's is left beside it
    let names: Vec<String> = std::fs::read_dir(socket.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names.len(), 3, "socket, cap and lock only: {names:?}");
    hub.term();
    let status = hub.wait_exit();
    assert_eq!(status.code(), Some(0), "{}", hub.stderr_text());
    assert!(!cap.exists(), "the cap is removed at stop");
    assert!(!socket.exists(), "the socket is removed at stop");
    // the log never holds the cap
    for e in std::fs::read_dir(root.log_dir()).unwrap() {
        let log = std::fs::read_to_string(e.unwrap().path()).unwrap();
        assert!(!log.contains(&text), "the cap is in the log");
    }
}

#[test]
fn the_lock_file_holds_pid_and_start_time() {
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let lock = paths::lock_path(&socket);
    assert_eq!(mode(&lock), 0o600);
    let text = std::fs::read_to_string(&lock).unwrap();
    let fields: Vec<&str> = text
        .strip_suffix('\n')
        .expect("one line")
        .split(' ')
        .collect();
    assert_eq!(fields.len(), 2, "{text:?}");
    assert_eq!(fields[0], hub.pid().to_string());
    let start: u64 = fields[1].parse().expect("a number");
    assert!(start > 0);
    if cfg!(target_os = "linux") {
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", hub.pid())).unwrap();
        let field_22 = stat
            .rsplit_once(')')
            .unwrap()
            .1
            .split_whitespace()
            .nth(19)
            .unwrap();
        assert_eq!(fields[1], field_22);
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn a_stopped_reader_is_dropped_after_16_mib_while_another_keeps_reading() {
    use std::io::Read;
    const LINES: u64 = 512;
    const SIZE: u64 = 64 * 1024; // 32 MiB in all
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let flood =
        json!({"id": 1, "method": "__test_flood", "params": {"lines": LINES, "size": SIZE}});

    // the stopped reader: asks for the flood and reads nothing
    let mut stopped = Client::open(&socket);
    stopped.send(flood.clone());

    // the reader that keeps reading gets every line and then the answer
    let mut reading = Client::open(&socket);
    reading.send(flood);
    let (answer, before) = reading.answer(1);
    assert_eq!(answer["result"]["queued"], json!(LINES), "{answer}");
    let floods = before.iter().filter(|v| v["event"] == "flood").count();
    assert_eq!(floods as u64, LINES);

    // the stopped one was dropped: what it reads now ends early, without the answer
    let mut got = 0usize;
    let mut buf = vec![0u8; 1 << 16];
    let mut all = Vec::new();
    loop {
        match stopped.reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                got += n;
                all.extend_from_slice(&buf[..n]);
            }
            Err(e) => panic!("the stopped reader was not closed: {e}"),
        }
    }
    assert!(
        got < (LINES * SIZE) as usize,
        "it got the whole flood ({got} bytes)"
    );
    assert!(
        !String::from_utf8_lossy(&all).contains("\"queued\""),
        "the dropped connection got the answer"
    );
    // the hub serves on, and says why it dropped the reader
    assert!(ping(&socket));
    // the line is written by the hub, which says nothing when it has: the log is looked at again until it shows
    // (`FAILED_AFTER` only bounds a failure)
    skuld::wait_until(
        "the hub logs why it dropped the reader",
        FAILED_AFTER.as_secs(),
        || {
            let log: String = std::fs::read_dir(root.log_dir())
                .unwrap()
                .map(|e| std::fs::read_to_string(e.unwrap().path()).unwrap())
                .collect();
            log.contains("queued over 16 MiB").then_some(())
        },
    );
}

#[cfg(feature = "test-hooks")]
#[test]
fn test_clock_emits_on_advance_only() {
    // A session's update goes out at most every 50 ms, on the hub's clock: under `--test-clock` the start's update
    // waits for `__test_advance` to reach its deadline, however much real time passes.
    let root = Root::new();
    let socket = root.socket();
    let config = root.dir.path().join("h/c");
    std::fs::create_dir_all(&config).unwrap();
    let settings = config.join("settings.el");
    std::fs::write(
        &settings,
        format!(
            "(drgnx-settings :version 1 (drgnx-agents-profiles ((\"mock\" :command ({:?} \"acp\" \"--as\" \"claude\")))))\n",
            mock_binary().display().to_string()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&settings, std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut hub = Hub::start_with(&root, 1, &["--test-clock"]);
    hub.wait_ready(&socket);
    let mut editor = Client::open(&socket);
    editor.hello(&socket);
    editor.send(json!({"id": 1, "method": "subscribe"}));
    assert_eq!(editor.answer(1).0["result"], json!(true));
    let mut c = Client::open(&socket);
    c.hello(&socket);
    c.send(json!({"id": 1, "method": "agents/start",
        "params": {"profile": "mock", "cwd": root.dir.path().join("h")}}));
    let (started, _) = c.answer(1);
    let sid = started["result"]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("{started}: {}", hub.stderr_text()))
        .to_string();
    let is_update = |v: &Value| v["event"] == "agent" && v["data"]["id"] == sid.as_str();
    let mut advance = |id: u64, ms: u64| {
        c.send(json!({"id": id, "method": "__test_advance", "params": {"ms": ms}}));
        c.answer(id).0["result"].clone()
    };
    // An advance returns once what it woke has run: an update it caused is queued on the editor's connection before
    // the advance is answered, so a ping sent after the answer comes back behind it.
    let a = advance(2, 49);
    assert_eq!(
        (a["now_ms"].clone(), a["busy"].clone()),
        (json!(49), json!([])),
        "{a}"
    );
    editor.send(json!({"id": 2, "method": "ping"}));
    let (_, before) = editor.answer(2);
    assert!(
        !before.iter().any(is_update),
        "an update before 50 ms: {before:?}"
    );
    let a = advance(3, 1);
    assert_eq!(
        (a["now_ms"].clone(), a["busy"].clone()),
        (json!(50), json!([])),
        "{a}"
    );
    assert!(a["woken"].as_u64().unwrap() >= 1, "{a}");
    editor.send(json!({"id": 3, "method": "ping"}));
    let (_, before) = editor.answer(3);
    assert!(
        before.iter().any(is_update),
        "no update at 50 ms: {before:?}"
    );
}

#[cfg(feature = "test-hooks")]
#[test]
fn the_lines_a_client_sent_before_it_left_are_served() {
    // A client asks for a flood, sends one more line once the hub is busy with it, and leaves without reading: the
    // flood's writes to it fail, and the line it sent is served all the same (a CLI's `exec/stop` as it exits, behind
    // answers it no longer reads).  The line is a refusal (a user method on a service connection), which `status`
    // counts.  The hub picks between a closed connection and its next line at random, so it is tried 20 times.
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start(&root, 1);
    hub.wait_ready(&socket);
    let refusals = |socket: &Path| {
        let mut c = Client::open(socket);
        c.send(json!({"id": 1, "method": "status"}));
        c.answer(1).0["result"]["refusals"]["count"]
            .as_u64()
            .unwrap()
    };
    for i in 1..=20u64 {
        let mut c = Client::open(&socket);
        assert_eq!(c.line().unwrap()["event"], "challenge");
        c.send(json!({"id": 1, "method": "__test_flood", "params": {"lines": 200, "size": 64}}));
        // the flood is under way, so the next line waits in the socket while the hub writes to a client that left
        assert_eq!(c.line().unwrap()["event"], "flood");
        c.send(json!({"id": 2, "method": "gateway/keys-held"}));
        drop(c);
        // the hub says nothing when it served the line: `status` is asked again until it counts it (`FAILED_AFTER`
        // only bounds a failure)
        skuld::wait_until(
            &format!("run {i}: the line sent before leaving is served"),
            FAILED_AFTER.as_secs(),
            || (refusals(&socket) >= i).then_some(()),
        );
    }
}

#[cfg(feature = "test-hooks")]
#[test]
fn a_hub_whose_store_is_slow_at_its_end_closes_its_connections_then_writes_its_queue() {
    // `shutdown`, with runtime.db's thread held by a job until SIGUSR1 and a write queued behind it
    // (`--test-hold-store`): each client still reads its end of file; the hub says the thread is still stopping and
    // waits for it, however long; released, it writes the queued write and ends
    use std::io::BufRead;
    let logs = |root: &Root| {
        let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(root.log_dir())
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        files.sort();
        files
            .iter()
            .map(|p| std::fs::read_to_string(p).unwrap())
            .collect::<String>()
    };
    let root = Root::new();
    let socket = root.socket();
    let mut hub = Hub::start_with(&root, 1, &["--test-hold-store"]);
    hub.wait_ready(&socket);
    let mut editor = Client::open(&socket);
    editor.hello(&socket);
    editor.send(json!({"id": 1, "method": "subscribe"}));
    editor.answer(1);
    let mut control = Client::open(&socket);
    control.hello(&socket);
    control.send(json!({"id": 1, "method": "shutdown"}));
    control.answer(1);
    for (name, c) in [("editor", &mut editor), ("control", &mut control)] {
        // to the end of file; a read that runs out of time (`FAILED_AFTER`) is the failure
        loop {
            let mut line = String::new();
            match c.reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) => panic!(
                    "the {name}'s connection did not end: {e}\n{}",
                    hub.stderr_text()
                ),
            }
        }
    }
    // the hub says nothing else while it waits: the log is looked at again until it names the thread (`FAILED_AFTER`
    // only bounds a failure)
    skuld::wait_until(
        "the hub says runtime.db's thread is still stopping",
        FAILED_AFTER.as_secs(),
        || {
            logs(&root)
                .contains("runtime.db's thread is still stopping")
                .then_some(())
        },
    );
    assert!(
        hub.exited().is_none(),
        "the hub ended with a write still queued: {}",
        hub.stderr_text()
    );
    let log = logs(&root);
    let closed = log
        .find("closed a connection: the hub ends")
        .expect("the connections' close is logged");
    let stopping = log.find("runtime.db's thread is still stopping").unwrap();
    assert!(closed < stopping, "the connections close first: {log}");
    // released: the queued write is written, then the hub ends as asked
    unsafe { libc::kill(hub.pid() as i32, libc::SIGUSR1) };
    let status = hub.wait_exit();
    assert_eq!(status.code(), Some(0), "{}", hub.stderr_text());
    let db = urdr::open_readonly(&root.dir.path().join("s/drgnx/hub/runtime.db")).unwrap();
    assert_eq!(
        urdr::meta(&db, "test-hold-store").unwrap().as_deref(),
        Some("written"),
        "the write queued behind the held job: {}",
        logs(&root)
    );
    assert!(!logs(&root).contains("abandoned"), "nothing was abandoned");
}

#[test]
fn a_child_is_its_image_once_the_exec_handshake_ends() {
    use support::ExecHandshake;
    // many spawns at once: `Command::spawn` can return before the exec, and the more threads fork, the likelier
    let threads: Vec<_> = (0..8)
        .map(|_| {
            std::thread::spawn(|| {
                let mut early = 0;
                for _ in 0..100 {
                    let mut cmd = Command::new("/bin/sleep");
                    cmd.arg("60");
                    let (mut child, exec) = ExecHandshake::spawn(&mut cmd).unwrap();
                    exec.wait();
                    let exe = std::fs::read_link(format!("/proc/{}/exe", child.id())).unwrap();
                    early += usize::from(exe.file_name().unwrap() != "sleep");
                    let _ = child.kill();
                    let _ = child.wait();
                }
                early
            })
        })
        .collect();
    let early: usize = threads.into_iter().map(|t| t.join().unwrap()).sum();
    assert_eq!(
        early, 0,
        "children still the test binary after the exec handshake"
    );
}
