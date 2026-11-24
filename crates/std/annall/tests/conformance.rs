//! The logging standard (docs/develop/standards/logging.md): events go to a JSON file under the state directory,
//! inside a test sandbox (never the real home). That a `println!` elsewhere fails the scanner is xtask's test
//! `cli_out_is_the_only_printer`.

fn log_text() -> String {
    let path = stig::state().join("log").join(annall::LOG_FILE);
    String::from_utf8(std::fs::read(&path).unwrap_or_default()).unwrap()
}

#[test]
fn log_init_writes_under_state() {
    let _sb = raun::Sandbox::new();
    let guard = annall::init(annall::LogConfig::default()).unwrap();
    tracing::info!(answer = 42, "hello log");
    drop(guard);
    let text = log_text();
    let line = text
        .lines()
        .find(|l| l.contains("hello log"))
        .unwrap_or_else(|| panic!("no event in {text:?}"));
    assert!(
        line.starts_with('{') && line.contains("\"answer\":42"),
        "{line}"
    );
}

#[test]
fn log_error_writes_the_kind_and_the_whole_chain() {
    let _sb = raun::Sandbox::new();
    let guard = annall::init(annall::LogConfig::default()).unwrap();
    let e = villa::Error::unavailable("The hub is not running.")
        .with_detail("socket refused")
        .with_source(std::io::Error::other("connection refused (os error 111)"));
    annall::log_error(&e);
    drop(guard);
    let text = log_text();
    for part in [
        "unavailable",
        "The hub is not running.",
        "socket refused",
        "connection refused",
    ] {
        assert!(text.contains(part), "{text} lacks {part}");
    }
}

#[test]
fn a_second_init_is_a_conflict() {
    let _sb = raun::Sandbox::new();
    let _guard = annall::init(annall::LogConfig::default()).unwrap();
    let again = annall::init(annall::LogConfig::default())
        .map(|_| ())
        .unwrap_err();
    assert_eq!(again.kind(), villa::Kind::Conflict);
}

#[test]
fn cli_out_and_cli_err_print() {
    annall::cli_out("annall: a line for stdout").unwrap();
    annall::cli_err("annall: a line for stderr").unwrap();
}

#[test]
fn the_stderr_sink_writes_json_lines_to_stderr_and_makes_no_file() {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    let _sb = raun::Sandbox::new();
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: pipe(2) fills two descriptors; dup2(2) points descriptor 2 at the write end, as a hub does for a worker
    let mut read = unsafe {
        assert_eq!(libc::pipe(fds.as_mut_ptr()), 0);
        assert!(libc::dup2(fds[1], 2) >= 0);
        libc::close(fds[1]);
        std::fs::File::from_raw_fd(fds[0])
    };
    let guard = annall::init(annall::LogConfig {
        sink: annall::Sink::Stderr,
        ..annall::LogConfig::default()
    })
    .unwrap();
    tracing::info!(answer = 7, "hello stderr");
    drop(guard);
    // SAFETY: closing descriptor 2 (the pipe's write end) ends the stream for the reader
    unsafe { libc::close(2) };
    let mut text = String::new();
    read.read_to_string(&mut text).unwrap();
    let line = text
        .lines()
        .find(|l| l.contains("hello stderr"))
        .unwrap_or_else(|| panic!("no event in {text:?}"));
    assert!(
        line.starts_with('{') && line.contains("\"answer\":7"),
        "{line}"
    );
    assert!(
        !stig::state().join("log").join(annall::LOG_FILE).exists(),
        "the stderr sink makes no log file"
    );
}

#[test]
fn raw_out_writes_the_bytes_it_is_given_and_nothing_else() {
    use std::io::{Read, Write};
    use std::os::fd::FromRawFd;
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: pipe(2) fills two descriptors; dup2(2) points descriptor 1 at the write end, as a hub does for a worker
    let mut read = unsafe {
        assert_eq!(libc::pipe(fds.as_mut_ptr()), 0);
        assert!(libc::dup2(fds[1], 1) >= 0);
        libc::close(fds[1]);
        std::fs::File::from_raw_fd(fds[0])
    };
    let mut out = annall::raw_out();
    out.write_all(b"\x00key\xff").unwrap();
    out.flush().unwrap();
    // SAFETY: closing descriptor 1 (the pipe's write end) ends the stream for the reader
    unsafe { libc::close(1) };
    let mut bytes = Vec::new();
    read.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"\x00key\xff", "no newline, no encoding");
}
