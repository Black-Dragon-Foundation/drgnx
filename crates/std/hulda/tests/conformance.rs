//! The data-hygiene standard (docs/develop/standards/data-hygiene.md). Review focus 4: a secret in an error's source
//! chain never reaches a log line. That a `Debug`-deriving token type fails the scanner is xtask's test
//! `derive_debug_on_token_type_fails_scan`.

use hulda::{REDACTED, Redact, Secret};

const TOKEN: &str = "tok-5f1e-not-for-logs";

/// An upstream failure that carries the credential it was sent with.
#[derive(Debug)]
struct Refusal {
    sent: Secret<String>,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "the server refused a {}-byte credential",
            self.sent.expose().len()
        )
    }
}

impl std::error::Error for Refusal {}

fn log_text() -> String {
    let path = stig::state().join("log").join(annall::LOG_FILE);
    String::from_utf8(std::fs::read(path).unwrap_or_default()).unwrap()
}

#[test]
fn secret_prints_redacted() {
    let s = Secret::new(TOKEN.to_string());
    assert_eq!(format!("{s:?}"), REDACTED);
    assert_eq!(format!("{s}"), REDACTED);
    assert_eq!(s.redacted(), REDACTED);
    assert_eq!(s.expose(), TOKEN);
}

#[test]
fn secret_in_error_source_is_redacted_in_log() {
    let _sb = raun::Sandbox::new();
    let guard = annall::init(annall::LogConfig::default()).unwrap();
    let e = villa::Error::refused("The server refused your sign-in.").with_source(Refusal {
        sent: Secret::new(TOKEN.to_string()),
    });
    annall::log_error(&e);
    drop(guard);
    let text = log_text();
    assert!(text.contains("The server refused your sign-in."), "{text}");
    assert!(text.contains(REDACTED), "{text}");
    assert!(!text.contains(TOKEN), "the token reached the log: {text}");
}

#[test]
fn redact_field_in_log() {
    let _sb = raun::Sandbox::new();
    let guard = annall::init(annall::LogConfig::default()).unwrap();
    let s = Secret::new(TOKEN.to_string());
    tracing::info!(token = annall::redact(&s), "signed in");
    drop(guard);
    let text = log_text();
    assert!(
        text.contains("signed in") && text.contains(REDACTED),
        "{text}"
    );
    assert!(!text.contains(TOKEN), "{text}");
}
