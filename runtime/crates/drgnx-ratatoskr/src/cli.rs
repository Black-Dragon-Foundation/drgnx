//! The command line (lexopt): `ratatoskr serve [--foreground] [--parent-pid PID] [--agent-socket SID[:JOB]]…`,
//! `ratatoskr version [--json]` and `ratatoskr methods --json|--markdown`.  A line that does not parse exits 2
//! ([`crate::Exit::Usage`]).

use std::ffi::OsString;

pub const USAGE: &str = "usage: ratatoskr serve [--foreground] [--parent-pid PID]\n\
    \x20      ratatoskr version [--json]\n\
    \x20      ratatoskr methods --json|--markdown";

#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Serve(ServeArgs),
    Version {
        json: bool,
    },
    /// The registry: `runtime/protocol/methods.json`'s content, or the docs' Markdown table.
    Methods {
        markdown: bool,
    },
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ServeArgs {
    /// Stay in the foreground (no self-detach; tests and supervisors).
    pub foreground: bool,
    /// End when this process is gone (checked each second); the last `--parent-pid` counts.
    pub parent_pid: Option<u32>,
    /// `--agent-socket SID[:JOB]` (test-hooks only, and only with `--foreground`): the hello task serves them.
    pub agent_sockets: Vec<AgentSocket>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct AgentSocket {
    pub sid: String,
    pub job: Option<String>,
}

pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<Command, String> {
    use lexopt::prelude::*;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let command = match p.next().map_err(e)? {
        Some(Value(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("a command is needed".into()),
    };
    match command.as_str() {
        "serve" => {
            let mut a = ServeArgs::default();
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("foreground") => a.foreground = true,
                    Long("parent-pid") => {
                        let pid: u32 = p.value().map_err(e)?.parse().map_err(e)?;
                        if pid == 0 {
                            return Err("--parent-pid takes a pid above 0".into());
                        }
                        a.parent_pid = Some(pid);
                    }
                    #[cfg(feature = "test-hooks")]
                    Long("agent-socket") => {
                        let v = p.value().map_err(e)?.string().map_err(e)?;
                        a.agent_sockets.push(agent_socket(&v)?);
                    }
                    other => return Err(other.unexpected().to_string()),
                }
            }
            if !a.agent_sockets.is_empty() && !a.foreground {
                return Err("--agent-socket needs --foreground".into());
            }
            Ok(Command::Serve(a))
        }
        "version" => {
            let mut json = false;
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("json") => json = true,
                    other => return Err(other.unexpected().to_string()),
                }
            }
            Ok(Command::Version { json })
        }
        "methods" => {
            let mut markdown = None;
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("json") if markdown.is_none() => markdown = Some(false),
                    Long("markdown") if markdown.is_none() => markdown = Some(true),
                    other => return Err(other.unexpected().to_string()),
                }
            }
            let markdown = markdown.ok_or("methods takes --json or --markdown")?;
            Ok(Command::Methods { markdown })
        }
        other => Err(format!("unknown command {other:?}")),
    }
}

/// `SID[:JOB]`, each a name of letters, digits, `-` and `_` (it becomes part of a socket's file name).
#[cfg(feature = "test-hooks")]
fn agent_socket(v: &str) -> Result<AgentSocket, String> {
    let name_ok = |s: &str| {
        !s.is_empty()
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    };
    let (sid, job) = match v.split_once(':') {
        Some((s, j)) => (s, Some(j)),
        None => (v, None),
    };
    if !name_ok(sid) || job.is_some_and(|j| !name_ok(j)) {
        return Err(format!(
            "--agent-socket takes SID[:JOB] (letters, digits, - and _), not {v:?}"
        ));
    }
    Ok(AgentSocket {
        sid: sid.to_string(),
        job: job.map(str::to_string),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<Command, String> {
        parse(args.iter().map(OsString::from))
    }

    #[test]
    fn serve_and_version_parse() {
        assert_eq!(p(&["serve"]), Ok(Command::Serve(ServeArgs::default())));
        assert_eq!(
            p(&["serve", "--foreground", "--parent-pid", "42"]),
            Ok(Command::Serve(ServeArgs {
                foreground: true,
                parent_pid: Some(42),
                agent_sockets: vec![],
            }))
        );
        // the last --parent-pid counts (a test can name its own parent after the harness's)
        assert_eq!(
            p(&["serve", "--parent-pid", "42", "--parent-pid", "43"]),
            Ok(Command::Serve(ServeArgs {
                foreground: false,
                parent_pid: Some(43),
                agent_sockets: vec![],
            }))
        );
        assert_eq!(p(&["version"]), Ok(Command::Version { json: false }));
        assert_eq!(
            p(&["version", "--json"]),
            Ok(Command::Version { json: true })
        );
        assert_eq!(
            p(&["methods", "--json"]),
            Ok(Command::Methods { markdown: false })
        );
        assert_eq!(
            p(&["methods", "--markdown"]),
            Ok(Command::Methods { markdown: true })
        );
    }

    #[test]
    fn usage_errors() {
        for bad in [
            &[][..],
            &["frobnicate"],
            &["serve", "--nope"],
            &["serve", "--parent-pid"],
            &["serve", "--parent-pid", "x"],
            &["serve", "--parent-pid", "0"],
            &["serve", "extra"],
            &["version", "--yaml"],
            &["methods"],
            &["methods", "--json", "--markdown"],
            &["methods", "--yaml"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} parsed");
        }
    }

    #[cfg(not(feature = "test-hooks"))]
    #[test]
    fn agent_socket_is_unknown_without_test_hooks() {
        assert!(p(&["serve", "--foreground", "--agent-socket", "s1"]).is_err());
    }

    #[cfg(feature = "test-hooks")]
    #[test]
    fn agent_socket_needs_foreground_and_a_safe_name() {
        assert_eq!(
            p(&[
                "serve",
                "--foreground",
                "--agent-socket",
                "s1:j1",
                "--agent-socket",
                "s2"
            ]),
            Ok(Command::Serve(ServeArgs {
                foreground: true,
                parent_pid: None,
                agent_sockets: vec![
                    AgentSocket {
                        sid: "s1".into(),
                        job: Some("j1".into())
                    },
                    AgentSocket {
                        sid: "s2".into(),
                        job: None
                    },
                ],
            }))
        );
        assert!(
            p(&["serve", "--agent-socket", "s1"]).is_err(),
            "without --foreground"
        );
        for bad in ["", "../x", "a/b", "s1:", ":j", "s 1"] {
            assert!(
                p(&["serve", "--foreground", "--agent-socket", bad]).is_err(),
                "{bad:?}"
            );
        }
    }
}
