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
