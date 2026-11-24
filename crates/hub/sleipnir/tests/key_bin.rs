//! `drgnx-key` on its own: the key line it sends, what it prints, its exit codes (75: the key was not delivered, 64: a
//! wrong request or a refusal), and that `exec` hands the key to the command's environment alone. A stand-in helper
//! answers on a socket path (`DRGNX_KEY_SOCK`); the real helper's rows run inside a fake runner (`runner_host_helper`).

use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;

mod support;

const KEY: &str = env!("CARGO_BIN_EXE_drgnx-key");

/// A helper on a fresh socket that answers its one request with REPLY and gives back the request line it read.
fn helper(reply: &'static [u8]) -> (tempfile::TempDir, PathBuf, std::thread::JoinHandle<String>) {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("key.sock");
    let listener = UnixListener::bind(&sock).unwrap();
    let served = saman::spawn_thread("key-helper", move || {
        let (mut s, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(s.try_clone().unwrap())
            .read_line(&mut line)
            .unwrap();
        s.write_all(reply).unwrap();
        line
    })
    .unwrap();
    (dir, sock, served)
}

/// `drgnx-key ARGS` with the helper at SOCK and EXTRA over the test's own environment.
fn run_key(sock: &std::path::Path, args: &[&str], extra: &[(&str, &OsStr)]) -> draugr::Output {
    let mut env: Vec<(&str, &OsStr)> = vec![("DRGNX_KEY_SOCK", sock.as_os_str())];
    env.extend_from_slice(extra);
    support::run(support::spec(KEY, args, &env))
}

#[test]
fn get_prints_the_key_and_nothing_else() {
    let (_dir, sock, served) = helper(b"ok 3\nabc");
    let out = run_key(&sock, &["get", "TOKEN"], &[]);
    assert_eq!(out.status.code(), Some(0), "{}", out.stderr);
    assert_eq!(out.stdout, b"abc");
    assert_eq!(served.join().unwrap(), "get TOKEN\n");
}

#[test]
fn a_key_that_never_comes_exits_75() {
    let (_dir, sock, _served) = helper(b"timeout\n");
    let out = run_key(&sock, &["get", "TOKEN"], &[]);
    assert_eq!(out.status.code(), Some(75), "{}", out.stderr);
    assert!(out.stdout.is_empty());
    assert!(
        out.stderr
            .contains("drgnx-key: key TOKEN was not delivered"),
        "{}",
        out.stderr
    );
}

#[test]
fn a_helper_that_cannot_be_reached_exits_75() {
    let dir = tempfile::tempdir().unwrap();
    let out = run_key(&dir.path().join("nobody.sock"), &["get", "TOKEN"], &[]);
    assert_eq!(out.status.code(), Some(75), "{}", out.stderr);
    assert!(
        out.stderr.contains("drgnx-key: the key socket"),
        "{}",
        out.stderr
    );
}

#[test]
fn a_refusal_exits_64_and_says_why() {
    let (_dir, sock, _served) = helper(b"no not granted\n");
    let out = run_key(&sock, &["get", "TOKEN"], &[]);
    assert_eq!(out.status.code(), Some(64), "{}", out.stderr);
    assert!(
        out.stderr.contains("drgnx-key: key TOKEN: not granted"),
        "{}",
        out.stderr
    );
}

#[test]
fn a_key_with_a_nul_in_it_is_refused() {
    let (_dir, sock, _served) = helper(b"ok 3\na\0b");
    let out = run_key(
        &sock,
        &["exec", "TOKEN=VAR", "--", "/bin/sh", "-c", "true"],
        &[],
    );
    assert_eq!(out.status.code(), Some(64), "{}", out.stderr);
    assert!(out.stderr.contains("a NUL in it"), "{}", out.stderr);
}

#[test]
fn exec_gives_the_key_to_the_command_and_keeps_the_rest_of_its_environment() {
    let (_dir, sock, served) = helper(b"ok 3\nabc");
    let out = run_key(
        &sock,
        &[
            "exec",
            "TOKEN=VAR",
            "--",
            "/bin/sh",
            "-c",
            "printf '%s|%s' \"$VAR\" \"$KEEP\"",
        ],
        &[("KEEP", OsStr::new("kept"))],
    );
    assert_eq!(out.status.code(), Some(0), "{}", out.stderr);
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "abc|kept");
    assert_eq!(served.join().unwrap(), "get TOKEN\n");
}

#[test]
fn a_command_that_cannot_start_exits_127() {
    let (_dir, sock, _served) = helper(b"ok 3\nabc");
    let out = run_key(
        &sock,
        &["exec", "TOKEN=VAR", "--", "/nonexistent/drgnx-command"],
        &[],
    );
    assert_eq!(out.status.code(), Some(127), "{}", out.stderr);
    assert!(
        out.stderr.contains("drgnx-key: /nonexistent/drgnx-command"),
        "{}",
        out.stderr
    );
}

#[test]
fn a_wrong_request_exits_64_with_the_usage() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("none.sock");
    let wrong: [&[&str]; 4] = [&[], &["get"], &["exec", "TOKEN=VAR"], &["get", "a b"]];
    for args in wrong {
        let out = run_key(&sock, args, &[]);
        assert_eq!(out.status.code(), Some(64), "{args:?}: {}", out.stderr);
        assert!(
            out.stderr.contains("usage: drgnx-key exec"),
            "{}",
            out.stderr
        );
    }
}
