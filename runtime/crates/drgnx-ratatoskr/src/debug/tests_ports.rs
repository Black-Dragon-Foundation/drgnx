//! Each session's block of loopback ports (spec §21): claimed machine-wide, probed, released; the listeners on it
//! checked to be the session's own.
use super::ports::{self, Blocks, MAC_EPHEMERAL, free};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

// The blocks' tests probe with their own function: on Linux other tests' outgoing connections take ports anywhere in
// 32768-60999, so a real probe of a fixed range would fail now and then. Each test has its own lock directory.

fn locks(t: &tempfile::TempDir) -> std::path::PathBuf {
    t.path().join("drgnx-debug-ports")
}

#[test]
fn the_default_range_is_below_the_ephemeral_ports_and_locks_in_the_shared_tmp() {
    let b = Blocks::default();
    assert!(b.range().end <= MAC_EPHEMERAL);
    assert_eq!(b.size(), 8);
    assert!(
        Path::new(ports::LOCK_DIR).starts_with(if cfg!(target_os = "macos") {
            "/private/tmp"
        } else {
            "/tmp"
        })
    );
}

#[test]
fn a_port_a_listener_holds_is_not_free() {
    let held = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    assert!(!free(held.local_addr().unwrap().port()));
}

#[test]
fn the_real_probe_passes_over_a_block_with_a_held_port() {
    // a port the kernel gave this test: the block that starts there is never handed out while it is held
    let held = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let p = held.local_addr().unwrap().port();
    let t = tempfile::tempdir().unwrap();
    let blocks = Blocks::with(p..p.saturating_add(16), 8, free, &locks(&t));
    if let Ok(b) = blocks.claim() {
        assert!(!b.ports().contains(&p), "{:?} holds {p}", b.ports());
    }
}

#[test]
fn two_sessions_get_disjoint_blocks_and_a_released_block_comes_back() {
    let t = tempfile::tempdir().unwrap();
    let blocks = Blocks::with(46100..46124, 8, |_| true, &locks(&t));
    let a = blocks.claim().unwrap();
    let b = blocks.claim().unwrap();
    assert_eq!(a.ports(), (46100..46108).collect::<Vec<_>>());
    assert_eq!(b.ports(), (46108..46116).collect::<Vec<_>>());
    drop(a);
    let c = blocks.claim().unwrap();
    assert_eq!(c.ports()[0], 46100);
    drop(b);
    drop(c);
}

#[test]
fn a_block_with_a_port_another_process_listens_on_is_passed_over() {
    // the block's fourth port is taken (as the macOS runner's 47610 was)
    let t = tempfile::tempdir().unwrap();
    let blocks = Blocks::with(46200..46216, 8, |p| p != 46203, &locks(&t));
    let b = blocks.claim().unwrap();
    assert_eq!(b.ports()[0], 46208);
}

#[test]
fn when_every_block_is_taken_the_session_is_refused_with_the_range() {
    let t = tempfile::tempdir().unwrap();
    let blocks = Blocks::with(46300..46316, 8, |p| p != 46310, &locks(&t));
    let _a = blocks.claim().unwrap();
    let e = blocks.claim().unwrap_err();
    assert!(e.contains("46300") && e.contains("46315"), "{e}");
}

#[test]
fn two_hubs_sharing_the_lock_directory_never_share_a_block() {
    // two hubs' tables (no shared state but the directory): the lock file decides
    let t = tempfile::tempdir().unwrap();
    let one = Blocks::with(46400..46424, 8, |_| true, &locks(&t));
    let two = Blocks::with(46400..46424, 8, |_| true, &locks(&t));
    let a = one.claim().unwrap();
    let b = two.claim().unwrap();
    assert_ne!(a.ports()[0], b.ports()[0]);
    drop(a);
    assert_eq!(two.claim().unwrap().ports()[0], 46400);
    // the directory is shared and sticky, each lock file open to every account
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode(&locks(&t)), 0o1777);
    assert_eq!(mode(&locks(&t).join("block-46400")), 0o666);
}

#[test]
fn a_dropped_block_is_free_while_a_forked_child_still_holds_its_descriptor() {
    // A child forked by another thread holds a copy of every descriptor until it execs (the copy shares the lock):
    // the block is free when the session lets it go, not when the last copy closes.
    let t = tempfile::tempdir().unwrap();
    let one = Blocks::with(46700..46716, 8, |_| true, &locks(&t));
    let two = Blocks::with(46700..46716, 8, |_| true, &locks(&t));
    let a = one.claim().unwrap();
    // SAFETY: the child only waits for its kill (pause(2) is async-signal-safe) and never returns into the harness.
    let pid = unsafe { libc::fork() };
    if pid == 0 {
        loop {
            unsafe { libc::pause() };
        }
    }
    assert!(pid > 0);
    drop(a);
    let got = two.claim().map(|b| b.ports()[0]);
    // SAFETY: the child forked above; reaped so it leaves no zombie.
    unsafe {
        libc::kill(pid, libc::SIGKILL);
        libc::waitpid(pid, std::ptr::null_mut(), 0);
    }
    assert_eq!(got, Ok(46700));
}

#[test]
fn a_lock_directory_others_could_empty_is_refused() {
    // not sticky: another account could delete a held lock file and lock a new one of the same name
    let t = tempfile::tempdir().unwrap();
    let d = locks(&t);
    std::fs::create_dir(&d).unwrap();
    std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o777)).unwrap();
    let e = Blocks::with(46500..46508, 8, |_| true, &d)
        .claim()
        .unwrap_err();
    assert!(e.contains("sticky"), "{e}");
}

const HOLDER: &str = "debug::tests_ports::holder_of_a_block_for_another_test";

/// Not a test of its own: `a_block_another_process_holds_is_passed_over` runs it as a second process, which claims
/// a block in `DRGNX_TEST_HOLD_DIR`, says which, and holds it until its stdin closes.
#[test]
#[ignore = "a helper process of a_block_another_process_holds_is_passed_over"]
fn holder_of_a_block_for_another_test() {
    let Some(dir) = std::env::var_os("DRGNX_TEST_HOLD_DIR") else {
        return;
    };
    let blocks = Blocks::with(46600..46616, 8, |_| true, Path::new(&dir));
    let b = blocks.claim().unwrap();
    println!("drgnx-held {}", b.ports()[0]);
    let mut rest = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut rest);
    drop(b);
}

#[test]
fn a_block_another_process_holds_is_passed_over() {
    let t = tempfile::tempdir().unwrap();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            HOLDER,
            "--nocapture",
            "--test-threads=1",
        ])
        .env("DRGNX_TEST_HOLD_DIR", locks(&t))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let held: u16 = loop {
        let mut line = String::new();
        assert!(
            out.read_line(&mut line).unwrap() > 0,
            "the holder ended without a block"
        );
        // libtest writes the test's name on the same line first
        if let Some(p) = line.split("drgnx-held ").nth(1) {
            break p.trim().parse().unwrap();
        }
    };
    let blocks = Blocks::with(46600..46616, 8, |_| true, &locks(&t));
    let mine = blocks.claim().unwrap();
    assert_ne!(mine.ports()[0], held);
    // the lock dies with the process
    drop(child.stdin.take());
    assert!(child.wait().unwrap().success());
    drop(mine);
    let again = Blocks::with(46600..46616, 8, |_| true, &locks(&t));
    assert_eq!(again.claim().unwrap().ports()[0], 46600);
}

#[test]
fn a_listener_is_the_sessions_only_when_its_process_group_is() {
    let held = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let p = held.local_addr().unwrap().port();
    let me = rustix::process::getpgrp().as_raw_nonzero().get();
    assert_eq!(ports::owned(p, &[me]), Ok(true));
    // another group's listener: never connected to, and named
    let e = ports::owned(p, &[me + 1_000_000]).unwrap_err();
    assert!(e.contains(&p.to_string()), "{e}");
    drop(held);
}
