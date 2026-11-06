//! Cloud credentials (docs/guide/runners.md, "Cloud: what you give drgnx"; design §6.7.1): where the hub gets the
//! user's scoped role, and how it keeps it.
//!
//! - **A credential command**, the default: `aws configure export-credentials`, `gcloud auth print-access-token`. The
//!   hub runs it with no terminal (stdin on `/dev/null`, a session of its own, so `/dev/tty` cannot open) and a time
//!   limit, and refuses it when it asks for anything: a prompt on its error output, a wait past the limit, a failure.
//!   Each of those is "log in at a terminal first" ([`super::CloudError::NeedsLogin`]), never an answer from the hub.
//! - **A key in the keyring**, the fallback: it arrives through `runners/keys` like a job key and is read from
//!   [`crate::runners::keys::Keys`] by name.
//!
//! What a command prints is read into memory that is wiped when dropped, parsed into `SecretString`s and never
//! written, logged or put in an error: errors name the command and what went wrong, never its output.

use super::CloudError;
use crate::runners::keys::Keys;
use secrecy::{ExposeSecret, SecretString};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use zeroize::Zeroizing;

/// Where a provider's credentials come from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// A command that prints them (`aws configure export-credentials`), run with no terminal.
    Command(Vec<String>),
    /// A key the editor hands over from the keyring, by name.
    Keyring(String),
}

/// How long a credential command may take before it is refused (an SSO refresh is a network round trip).
pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

/// Credentials are fetched again this long before they expire.
const REFRESH_MARGIN: Duration = Duration::from_secs(300);

/// Why a credential command gave nothing the hub can use. None of these carries what the command printed.
#[derive(Debug, PartialEq, Eq)]
pub enum CredError {
    /// It asked for input (a code, a password, a confirmation).
    Prompted,
    /// It did not finish within its limit (it waited for input it cannot get).
    TimedOut,
    /// It could not start, or exited with a failure.
    Failed(String),
    /// It printed something that is not credentials.
    Unreadable(String),
}

impl std::fmt::Display for CredError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CredError::Prompted => {
                f.write_str("it asked for input, and the hub never answers a prompt")
            }
            CredError::TimedOut => {
                f.write_str("it did not finish in time (it may be waiting for input)")
            }
            CredError::Failed(why) => write!(f, "it failed: {why}"),
            CredError::Unreadable(why) => write!(f, "its output is not credentials: {why}"),
        }
    }
}

/// The words of a prompt on a credential command's error output.
const PROMPTS: [&str; 10] = [
    "password",
    "passphrase",
    "enter ",
    "mfa",
    "token code",
    "[y/n]",
    "(y/n)",
    "press enter",
    "verification code",
    "do you want",
];

/// Whether STDERR reads as a prompt: words that ask for input, or a last line left open for the answer.
fn looks_like_a_prompt(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    let open_line = !stderr.trim().is_empty() && !stderr.ends_with('\n');
    open_line || PROMPTS.iter().any(|p| lower.contains(p))
}

/// ARGV shell-quoted, for the card that asks the user to run it in a terminal.
pub fn shown(argv: &[String]) -> String {
    argv.iter()
        .map(|w| {
            if !w.is_empty()
                && w.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_./=:@,".contains(&b))
            {
                w.clone()
            } else {
                format!("'{}'", w.replace('\'', r"'\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Runs ARGV with no terminal and returns what it printed on stdout, in memory that is wiped when dropped. Refused on
/// a prompt (even when it then exits 0), past TIMEOUT (its whole process group is killed) and on a failure.
pub async fn run_command(
    argv: &[String],
    timeout: Duration,
) -> Result<Zeroizing<Vec<u8>>, CredError> {
    let Some((prog, args)) = argv.split_first() else {
        return Err(CredError::Failed("the credential command is empty".into()));
    };
    let mut cmd = tokio::process::Command::new(prog);
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    // SAFETY: only `setsid(2)`, which is async-signal-safe, runs between fork and exec. A session of its own has no
    // controlling terminal, so the command cannot open `/dev/tty` to ask the user anything.
    unsafe {
        cmd.pre_exec(|| {
            rustix::process::setsid()
                .map(|_| ())
                .map_err(std::io::Error::from)
        });
    }
    let child = cmd
        .spawn()
        .map_err(|e| CredError::Failed(format!("{prog} did not start: {e}")))?;
    let group = child
        .id()
        .and_then(|p| rustix::process::Pid::from_raw(p as i32));
    let out = match crate::clock::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => return Err(CredError::Failed(format!("{prog}: {e}"))),
        Err(_) => {
            if let Some(g) = group {
                let _ = rustix::process::kill_process_group(g, rustix::process::Signal::KILL);
            }
            return Err(CredError::TimedOut);
        }
    };
    let stdout = Zeroizing::new(out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    if looks_like_a_prompt(&stderr) {
        return Err(CredError::Prompted);
    }
    if !out.status.success() {
        return Err(CredError::Failed(format!(
            "{prog} exited with {}",
            out.status
        )));
    }
    if stdout.iter().all(u8::is_ascii_whitespace) {
        return Err(CredError::Unreadable(format!("{prog} printed nothing")));
    }
    Ok(stdout)
}

/// AWS credentials, held in memory only: never `Debug`, `Clone` or `Serialize`.
pub struct AwsCredentials {
    pub access_key_id: SecretString,
    pub secret_access_key: SecretString,
    pub session_token: Option<SecretString>,
    pub expires: Option<SystemTime>,
}

/// Reads the credential process JSON `aws configure export-credentials` prints (and a keyring key holds):
/// `{"Version": 1, "AccessKeyId": …, "SecretAccessKey": …, "SessionToken": …, "Expiration": …}`.
pub fn parse_aws(json: &[u8]) -> Result<AwsCredentials, CredError> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Process {
        version: Option<u32>,
        access_key_id: String,
        secret_access_key: String,
        session_token: Option<String>,
        expiration: Option<String>,
    }
    let p: Process = serde_json::from_slice(json).map_err(|e| {
        // the position only: serde's message can quote the input
        CredError::Unreadable(format!(
            "not the credential process JSON (line {}, column {})",
            e.line(),
            e.column()
        ))
    })?;
    if p.version.is_some_and(|v| v != 1) {
        return Err(CredError::Unreadable("only Version 1 is understood".into()));
    }
    let expires = match p.expiration.as_deref() {
        None => None,
        Some(t) => Some(
            super::parse_time(t)
                .ok_or_else(|| CredError::Unreadable("Expiration is not a time".into()))?,
        ),
    };
    Ok(AwsCredentials {
        access_key_id: SecretString::from(p.access_key_id),
        secret_access_key: SecretString::from(p.secret_access_key),
        session_token: p.session_token.map(SecretString::from),
        expires,
    })
}

/// A provider's credentials as it needs them: from its [`Source`], kept until shortly before they expire.
pub struct Resolver {
    source: Source,
    keys: Option<Arc<Keys>>,
    cached: Mutex<Option<Arc<AwsCredentials>>>,
}

impl Resolver {
    /// Credentials from SOURCE; a keyring source reads KEYS (the hub's handed-over keys).
    pub fn new(source: Source, keys: Option<Arc<Keys>>) -> Resolver {
        Resolver {
            source,
            keys,
            cached: Mutex::new(None),
        }
    }

    /// The command the user runs in a terminal when the credentials need a login: the credential command itself, or,
    /// for a keyring key, the command that hands it over again.
    pub fn login_command(&self) -> String {
        match &self.source {
            Source::Command(argv) => shown(argv),
            Source::Keyring(name) => {
                format!("drgnx runner keys {}", shown(std::slice::from_ref(name)))
            }
        }
    }

    /// Forget what is cached: the provider said the credentials are expired.
    pub fn forget(&self) {
        *self.cached.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// The AWS credentials, fetched when none are cached or they expire within five minutes.
    pub async fn aws(&self) -> Result<Arc<AwsCredentials>, CloudError> {
        let now = crate::clock::wall();
        if let Some(c) = self
            .cached
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            && c.expires.is_none_or(|t| t > now + REFRESH_MARGIN)
        {
            return Ok(c.clone());
        }
        let creds = match &self.source {
            Source::Command(argv) => {
                let out = run_command(argv, COMMAND_TIMEOUT).await.map_err(|e| {
                    tracing::warn!(command = %argv.first().map(String::as_str).unwrap_or(""), why = %e,
                        "runners: the cloud credential command was refused");
                    CloudError::NeedsLogin(self.login_command())
                })?;
                parse_aws(&out)
                    .map_err(|e| CloudError::Other(format!("the credential command: {e}")))?
            }
            Source::Keyring(name) => {
                let value = self
                    .keys
                    .as_ref()
                    .and_then(|k| k.value(name))
                    .ok_or_else(|| CloudError::NeedsLogin(self.login_command()))?;
                parse_aws(value.expose_secret().as_bytes())
                    .map_err(|e| CloudError::Other(format!("the keyring key {name:?}: {e}")))?
            }
        };
        let creds = Arc::new(creds);
        *self.cached.lock().unwrap_or_else(|e| e.into_inner()) = Some(creds.clone());
        Ok(creds)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> Vec<String> {
        vec!["sh".into(), "-c".into(), script.into()]
    }

    /// A fake credential process JSON, built in pieces.
    fn fake_json() -> String {
        let id = ["AS", "IA", "FAKEFAKEFAKE0001"].concat();
        let secret = ["fake", "/secret", "+key", "0000"].concat();
        format!(
            "{{\"Version\":1,\"AccessKeyId\":\"{id}\",\"SecretAccessKey\":\"{secret}\",\"SessionToken\":\"tok\",\"Expiration\":\"2026-11-06T01:00:00+00:00\"}}"
        )
    }

    // [D] pure (a real child, no timing: it answers or fails at once)
    #[tokio::test]
    async fn a_credential_command_that_prompts_is_refused() {
        // a prompt on stderr is refused even when the command then goes on and exits 0
        let mfa = sh(&format!(
            "printf 'Enter MFA code for arn:aws:iam::000000000000:mfa/u: ' >&2; read code; printf '%s' '{}'",
            fake_json()
        ));
        assert_eq!(
            run_command(&mfa, COMMAND_TIMEOUT).await.err(),
            Some(CredError::Prompted)
        );
        // no terminal to open: the command is in a session of its own
        let tty = sh("exec 3</dev/tty || exit 9; echo opened");
        assert!(matches!(
            run_command(&tty, COMMAND_TIMEOUT).await,
            Err(CredError::Failed(_))
        ));
        // stdin is empty, not the hub's
        let stdin = sh("if read -r x; then echo got-input; else exit 3; fi");
        assert!(matches!(
            run_command(&stdin, COMMAND_TIMEOUT).await,
            Err(CredError::Failed(_))
        ));
        // a well-behaved command gives credentials; the error of a broken one never quotes its output
        let good = sh(&format!("printf '%s' '{}'", fake_json()));
        let out = run_command(&good, COMMAND_TIMEOUT).await.unwrap();
        let c = parse_aws(&out).unwrap();
        assert!(
            c.access_key_id
                .expose_secret()
                .ends_with("FAKEFAKEFAKE0001")
        );
        assert_eq!(c.session_token.unwrap().expose_secret(), "tok");
        assert!(c.expires.is_some());
        let bad = parse_aws(b"{\"AccessKeyId\": \"leaked-value\"")
            .err()
            .unwrap();
        assert!(!bad.to_string().contains("leaked-value"), "{bad}");
        assert_eq!(
            shown(&[
                "aws".into(),
                "configure".into(),
                "export-credentials".into(),
                "a b".into()
            ]),
            "aws configure export-credentials 'a b'"
        );
    }
}
