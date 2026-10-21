//! The command line (lexopt): `ratatoskr serve [--foreground] [--parent-pid PID] [--supervisor none|self|launchd]`,
//! `ensure`, `stop`, `status`, `doctor`, `restart`, `version [--json]` and `methods --json|--markdown`.  A line that
//! does not parse exits 2 ([`crate::Exit::Usage`]).

use std::ffi::OsString;
use std::time::Duration;

pub const USAGE: &str = "usage: ratatoskr serve [--foreground] [--parent-pid PID] [--supervisor none|self|launchd]\n\
    \x20      ratatoskr ensure [--timeout SECS]\n\
    \x20      ratatoskr stop [--timeout SECS]\n\
    \x20      ratatoskr status [--json]\n\
    \x20      ratatoskr doctor [--json]\n\
    \x20      ratatoskr restart\n\
    \x20      ratatoskr version [--json]\n\
    \x20      ratatoskr methods --json|--markdown";

/// How long `ensure` waits for the hub to answer `ping`.
pub const ENSURE_TIMEOUT: Duration = Duration::from_secs(5);

/// How long `stop` waits for the lock to be released (the hub stops its backend for up to 10 s first).
pub const STOP_TIMEOUT: Duration = Duration::from_secs(15);

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
    /// Ping; start a hub when nothing answers; wait for it.
    Ensure {
        timeout: Duration,
    },
    /// End the hub (a Lisp hub from before Ratatoskr too).
    Stop {
        timeout: Duration,
    },
    Status {
        json: bool,
    },
    Doctor,
    /// Ask the running hub to restart (the editor's Hub: Restart Now).
    Restart,
}

/// What restarts a hub that exits 75 (and what `serve` maps its exits for).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Supervisor {
    /// Nothing is said (a test, a unit systemd restarts on its own): 75 is just the exit code.
    #[default]
    None,
    /// `ensure` detached this hub itself: nothing would restart it, so it re-executes itself on a restart.
    SelfDetached,
    /// launchd restarts on every non-zero exit: exits 1, 2 and 3 are mapped to 0 so it never loops on them.
    Launchd,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ServeArgs {
    /// Stay in the foreground (no self-detach; tests and supervisors).
    pub foreground: bool,
    /// End when this process is gone (checked each second); the last `--parent-pid` counts.
    pub parent_pid: Option<u32>,
    pub supervisor: Supervisor,
    /// `--idle-tick-ms N` (test-hooks only): the restart-when-idle tick, 2 s otherwise.
    pub idle_tick_ms: Option<u64>,
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
                    Long("supervisor") => {
                        a.supervisor = match p.value().map_err(e)?.string().map_err(e)?.as_str() {
                            "none" => Supervisor::None,
                            "self" => Supervisor::SelfDetached,
                            "launchd" => Supervisor::Launchd,
                            other => {
                                return Err(format!(
                                    "--supervisor takes none, self or launchd, not {other:?}"
                                ));
                            }
                        };
                    }
                    #[cfg(feature = "test-hooks")]
                    Long("idle-tick-ms") => {
                        let ms: u64 = p.value().map_err(e)?.parse().map_err(e)?;
                        if ms == 0 {
                            return Err("--idle-tick-ms takes a number above 0".into());
                        }
                        a.idle_tick_ms = Some(ms);
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
        "ensure" | "stop" => {
            let mut timeout = if command == "ensure" {
                ENSURE_TIMEOUT
            } else {
                STOP_TIMEOUT
            };
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("timeout") => {
                        let secs: u64 = p.value().map_err(e)?.parse().map_err(e)?;
                        timeout = Duration::from_secs(secs);
                    }
                    other => return Err(other.unexpected().to_string()),
                }
            }
            Ok(if command == "ensure" {
                Command::Ensure { timeout }
            } else {
                Command::Stop { timeout }
            })
        }
        "status" => {
            let mut json = false;
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("json") => json = true,
                    other => return Err(other.unexpected().to_string()),
                }
            }
            Ok(Command::Status { json })
        }
        // the report is JSON; --json is accepted for the plan's spelling
        "doctor" => {
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("json") => {}
                    other => return Err(other.unexpected().to_string()),
                }
            }
            Ok(Command::Doctor)
        }
        "restart" => match p.next().map_err(e)? {
            None => Ok(Command::Restart),
            Some(other) => Err(other.unexpected().to_string()),
        },
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
                ..ServeArgs::default()
            }))
        );
        // the last --parent-pid counts (a test can name its own parent after the harness's)
        assert_eq!(
            p(&["serve", "--parent-pid", "42", "--parent-pid", "43"]),
            Ok(Command::Serve(ServeArgs {
                parent_pid: Some(43),
                ..ServeArgs::default()
            }))
        );
        assert_eq!(
            p(&["serve", "--supervisor", "launchd"]),
            Ok(Command::Serve(ServeArgs {
                supervisor: Supervisor::Launchd,
                ..ServeArgs::default()
            }))
        );
        assert_eq!(
            p(&["serve", "--supervisor", "self"]),
            Ok(Command::Serve(ServeArgs {
                supervisor: Supervisor::SelfDetached,
                ..ServeArgs::default()
            }))
        );
        assert_eq!(
            p(&["ensure"]),
            Ok(Command::Ensure {
                timeout: ENSURE_TIMEOUT
            })
        );
        assert_eq!(
            p(&["ensure", "--timeout", "9"]),
            Ok(Command::Ensure {
                timeout: Duration::from_secs(9)
            })
        );
        assert_eq!(
            p(&["stop"]),
            Ok(Command::Stop {
                timeout: STOP_TIMEOUT
            })
        );
        assert_eq!(p(&["status"]), Ok(Command::Status { json: false }));
        assert_eq!(p(&["status", "--json"]), Ok(Command::Status { json: true }));
        assert_eq!(p(&["doctor", "--json"]), Ok(Command::Doctor));
        assert_eq!(p(&["restart"]), Ok(Command::Restart));
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
            &["serve", "--supervisor"],
            &["serve", "--supervisor", "systemd"],
            &["ensure", "--timeout"],
            &["ensure", "--timeout", "x"],
            &["stop", "extra"],
            &["status", "--yaml"],
            &["restart", "now"],
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
                ..ServeArgs::default()
            }))
        );
        assert_eq!(
            p(&["serve", "--idle-tick-ms", "200"]),
            Ok(Command::Serve(ServeArgs {
                idle_tick_ms: Some(200),
                ..ServeArgs::default()
            }))
        );
        assert!(p(&["serve", "--idle-tick-ms", "0"]).is_err());
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
