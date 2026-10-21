//! The command line (lexopt): `ratatoskr serve [--foreground] [--parent-pid PID] [--supervisor none|self|launchd]`,
//! `ensure`, `stop`, `status`, `doctor`, `restart`, `version [--json]`, `methods --json|--markdown`,
//! `sandbox check`, `sandbox-inner …` and `relay …` (the sandbox's inner helper and its relay, their arguments taken
//! raw), and with
//! the `test-hooks` feature `sandbox run …`.  A line that does not parse exits 2 ([`crate::Exit::Usage`]).

use std::ffi::OsString;
#[cfg(feature = "test-hooks")]
use std::path::PathBuf;
use std::time::Duration;

pub const USAGE: &str = "usage: ratatoskr serve [--foreground] [--parent-pid PID] [--supervisor none|self|launchd]\n\
    \x20      ratatoskr ensure [--timeout SECS]\n\
    \x20      ratatoskr stop [--timeout SECS]\n\
    \x20      ratatoskr status [--json]\n\
    \x20      ratatoskr doctor [--json]\n\
    \x20      ratatoskr restart\n\
    \x20      ratatoskr version [--json]\n\
    \x20      ratatoskr methods --json|--markdown\n\
    \x20      ratatoskr sandbox-inner --spec-fd 3 -- CMD...   (the sandbox's inner helper; run by the sandbox only)\n\
    \x20      ratatoskr relay --parent-pid PID [--ready-fd N] PORT=SOCKET...   (the sandbox's relay; run by the sandbox only)\n\
    \x20      ratatoskr sandbox check [--json] [--tier full|reduced]   (does the job sandbox start here?)\n\
    \x20      ratatoskr sandbox run --spec FILE --result FILE [--tier full|reduced] [--bwrap PATH]\n\
    \x20          [--pause-before-spawn FIFO] [--landlock-omit PATH]... [--landlock-abi-cap N] -- CMD...   (test builds only)";

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
    /// The machine's report: JSON with `--json` (the editor's doctor), else a few lines of text.
    Doctor {
        json: bool,
    },
    /// `sandbox check`: whether the job sandbox starts here, the real invocation as the probe.
    SandboxCheck(SandboxCheckArgs),
    /// Ask the running hub to restart (the editor's Hub: Restart Now).
    Restart,
    /// The sandbox's inner helper (`gleipnir::inner::inner_main`): every argument after the command is its own,
    /// untouched. `main` runs it before any thread or runtime exists.
    SandboxInner {
        args: Vec<OsString>,
    },
    /// The sandbox's relay (`gleipnir::net::relay::main`), its arguments untouched. It builds its own runtime.
    Relay {
        args: Vec<OsString>,
    },
    /// `sandbox run` (test-hooks only): one command under the sandbox, for the escape rows.
    #[cfg(feature = "test-hooks")]
    SandboxRun(SandboxRunArgs),
}

/// `sandbox check`'s arguments.
#[derive(Debug, PartialEq, Eq)]
pub struct SandboxCheckArgs {
    pub json: bool,
    pub tier: gleipnir::Tier,
    /// `--bwrap PATH` (test-hooks only): the only bwrap looked at, held to the same rules.
    pub bwrap: Option<std::path::PathBuf>,
}

/// `sandbox run`'s arguments (test-hooks only).
#[cfg(feature = "test-hooks")]
#[derive(Debug, PartialEq, Eq)]
pub struct SandboxRunArgs {
    /// The spec, as `gleipnir::Spec` JSON.
    pub spec: PathBuf,
    /// Where `{"refused", "layers", "exit"}` is written.
    pub result: PathBuf,
    pub tier: gleipnir::Tier,
    pub bwrap: Option<PathBuf>,
    /// Write `opened\n` here once the sources are opened, then wait for one line back.
    pub pause_before_spawn: Option<PathBuf>,
    pub landlock_omit: Vec<PathBuf>,
    pub landlock_abi_cap: Option<u8>,
    pub command: Vec<String>,
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
        "doctor" => {
            let mut json = false;
            while let Some(arg) = p.next().map_err(e)? {
                match arg {
                    Long("json") => json = true,
                    other => return Err(other.unexpected().to_string()),
                }
            }
            Ok(Command::Doctor { json })
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
        // The helper reads its own arguments (`--spec-fd N -- CMD…`): nothing here may interpret the command's.
        "sandbox-inner" => Ok(Command::SandboxInner {
            args: p.raw_args().map_err(e)?.collect(),
        }),
        // The relay parses its own arguments too (`gleipnir::net::relay::main`).
        "relay" => Ok(Command::Relay {
            args: p.raw_args().map_err(e)?.collect(),
        }),
        "sandbox" => {
            let sub = match p.next().map_err(e)? {
                Some(Value(v)) => v.string().map_err(e)?,
                Some(other) => return Err(other.unexpected().to_string()),
                None => return Err("sandbox needs a subcommand".into()),
            };
            match sub.as_str() {
                "check" => sandbox_check(&mut p).map(Command::SandboxCheck),
                #[cfg(feature = "test-hooks")]
                "run" => sandbox_run(&mut p).map(Command::SandboxRun),
                // Without the test hooks there is no `sandbox run`: a release build cannot run a spec from a file.
                #[cfg(not(feature = "test-hooks"))]
                "run" => Err("sandbox run exists only in a test-hooks build".into()),
                other => Err(format!("unknown sandbox subcommand {other:?}")),
            }
        }
        other => Err(format!("unknown command {other:?}")),
    }
}

/// `sandbox check [--json] [--tier full|reduced]`, and with test-hooks `[--bwrap PATH]`.
fn sandbox_check(p: &mut lexopt::Parser) -> Result<SandboxCheckArgs, String> {
    use lexopt::prelude::*;
    let e = |e: lexopt::Error| e.to_string();
    let mut a = SandboxCheckArgs {
        json: false,
        tier: gleipnir::Tier::Full,
        bwrap: None,
    };
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("json") => a.json = true,
            Long("tier") => {
                a.tier = match p.value().map_err(e)?.string().map_err(e)?.as_str() {
                    "full" => gleipnir::Tier::Full,
                    "reduced" => gleipnir::Tier::Reduced,
                    other => return Err(format!("--tier takes full or reduced, not {other:?}")),
                }
            }
            #[cfg(feature = "test-hooks")]
            Long("bwrap") => a.bwrap = Some(PathBuf::from(p.value().map_err(e)?)),
            other => return Err(other.unexpected().to_string()),
        }
    }
    Ok(a)
}

/// `sandbox run`'s options, then the command: everything from the first argument that is not an option (after
/// `--`) is the command's, untouched.
#[cfg(feature = "test-hooks")]
fn sandbox_run(p: &mut lexopt::Parser) -> Result<SandboxRunArgs, String> {
    use lexopt::prelude::*;
    let e = |e: lexopt::Error| e.to_string();
    let (mut spec, mut result, mut tier) = (None, None, gleipnir::Tier::Full);
    let (mut bwrap, mut pause, mut omit, mut cap) = (None, None, Vec::new(), None);
    let mut command: Vec<OsString> = Vec::new();
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("spec") => spec = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("result") => result = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("tier") => {
                tier = match p.value().map_err(e)?.string().map_err(e)?.as_str() {
                    "full" => gleipnir::Tier::Full,
                    "reduced" => gleipnir::Tier::Reduced,
                    other => return Err(format!("--tier takes full or reduced, not {other:?}")),
                }
            }
            Long("bwrap") => bwrap = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("pause-before-spawn") => pause = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("landlock-omit") => omit.push(PathBuf::from(p.value().map_err(e)?)),
            Long("landlock-abi-cap") => cap = Some(p.value().map_err(e)?.parse().map_err(e)?),
            Value(first) => {
                command.push(first);
                command.extend(p.raw_args().map_err(e)?);
                break;
            }
            other => return Err(other.unexpected().to_string()),
        }
    }
    let command = command
        .into_iter()
        .map(|a| {
            a.into_string()
                .map_err(|a| format!("the command is not UTF-8: {a:?}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(SandboxRunArgs {
        spec: spec.ok_or("sandbox run needs --spec FILE")?,
        result: result.ok_or("sandbox run needs --result FILE")?,
        tier,
        bwrap,
        pause_before_spawn: pause,
        landlock_omit: omit,
        landlock_abi_cap: cap,
        command: (!command.is_empty())
            .then_some(command)
            .ok_or("sandbox run needs a command after --")?,
    })
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
        assert_eq!(p(&["doctor", "--json"]), Ok(Command::Doctor { json: true }));
        assert_eq!(p(&["doctor"]), Ok(Command::Doctor { json: false }));
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

    /// `sandbox-inner` takes its arguments raw: nothing after it is read as an option of ratatoskr's, so a
    /// command's own flags reach the helper unchanged, and no runtime is involved in parsing it.
    #[test]
    fn sandbox_inner_parses_without_a_runtime() {
        let rest = [
            "--spec-fd",
            "3",
            "--",
            "/bin/sh",
            "-c",
            "echo --json",
            "--nope",
        ];
        let mut all = vec!["sandbox-inner"];
        all.extend(rest);
        assert_eq!(
            p(&all),
            Ok(Command::SandboxInner {
                args: rest.map(OsString::from).to_vec()
            })
        );
        assert_eq!(
            p(&["sandbox-inner"]),
            Ok(Command::SandboxInner { args: vec![] })
        );
    }

    /// `relay` takes its arguments raw, like `sandbox-inner`: the relay parses its own.
    #[test]
    fn relay_parses_raw() {
        let rest = [
            "--ready-fd",
            "3",
            "3128=/run/drgnx/proxy.sock",
            "--parent-pid",
            "7",
        ];
        let mut all = vec!["relay"];
        all.extend(rest);
        assert_eq!(
            p(&all),
            Ok(Command::Relay {
                args: rest.map(OsString::from).to_vec()
            })
        );
    }

    #[test]
    fn sandbox_check_parses() {
        let args = |json, tier| {
            Ok(Command::SandboxCheck(SandboxCheckArgs {
                json,
                tier,
                bwrap: None,
            }))
        };
        assert_eq!(p(&["sandbox", "check"]), args(false, gleipnir::Tier::Full));
        assert_eq!(
            p(&["sandbox", "check", "--json", "--tier", "reduced"]),
            args(true, gleipnir::Tier::Reduced)
        );
        assert_eq!(
            p(&["sandbox", "check", "--tier", "full"]),
            args(false, gleipnir::Tier::Full)
        );
        for bad in [
            &["sandbox", "check", "--tier", "half"][..],
            &["sandbox", "check", "--tier"],
            &["sandbox", "check", "extra"],
            &["sandbox", "check", "--yaml"],
        ] {
            assert!(p(bad).is_err(), "{bad:?} parsed");
        }
    }

    /// `--bwrap` is a test hook: a release build refuses it, a test build takes it.
    #[test]
    fn bwrap_override_needs_test_hooks() {
        let r = p(&["sandbox", "check", "--bwrap", "/opt/bwrap"]);
        #[cfg(feature = "test-hooks")]
        assert_eq!(
            r,
            Ok(Command::SandboxCheck(SandboxCheckArgs {
                json: false,
                tier: gleipnir::Tier::Full,
                bwrap: Some("/opt/bwrap".into()),
            }))
        );
        #[cfg(not(feature = "test-hooks"))]
        assert!(r.unwrap_err().contains("--bwrap"));
    }

    /// A release build has no `sandbox run`: a spec from a file never runs there.
    #[cfg(not(feature = "test-hooks"))]
    #[test]
    fn sandbox_run_refused_without_test_hooks() {
        let r = p(&[
            "sandbox",
            "run",
            "--spec",
            "/s",
            "--result",
            "/r",
            "--",
            "/bin/true",
        ]);
        assert!(r.unwrap_err().contains("test-hooks"));
    }

    #[cfg(feature = "test-hooks")]
    #[test]
    fn sandbox_run_parses() {
        assert_eq!(
            p(&[
                "sandbox",
                "run",
                "--spec",
                "/s.json",
                "--result",
                "/r.json",
                "--tier",
                "reduced",
                "--bwrap",
                "/b",
                "--pause-before-spawn",
                "/f",
                "--landlock-omit",
                "/a",
                "--landlock-omit",
                "/b",
                "--landlock-abi-cap",
                "8",
                "--",
                "/bin/sh",
                "-c",
                "echo --spec",
            ]),
            Ok(Command::SandboxRun(SandboxRunArgs {
                spec: "/s.json".into(),
                result: "/r.json".into(),
                tier: gleipnir::Tier::Reduced,
                bwrap: Some("/b".into()),
                pause_before_spawn: Some("/f".into()),
                landlock_omit: vec!["/a".into(), "/b".into()],
                landlock_abi_cap: Some(8),
                command: vec!["/bin/sh".into(), "-c".into(), "echo --spec".into()],
            }))
        );
        let Ok(Command::SandboxRun(a)) =
            p(&["sandbox", "run", "--spec", "s", "--result", "r", "--", "x"])
        else {
            panic!("parses");
        };
        assert_eq!(a.tier, gleipnir::Tier::Full, "the default tier");
        for bad in [
            &["sandbox", "run", "--result", "r", "--", "x"][..],
            &["sandbox", "run", "--spec", "s", "--", "x"],
            &["sandbox", "run", "--spec", "s", "--result", "r"],
            &[
                "sandbox", "run", "--spec", "s", "--result", "r", "--tier", "half", "--", "x",
            ],
            &[
                "sandbox",
                "run",
                "--spec",
                "s",
                "--result",
                "r",
                "--landlock-abi-cap",
                "x",
                "--",
                "x",
            ],
        ] {
            assert!(p(bad).is_err(), "{bad:?} parsed");
        }
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
            &["sandbox"],
            &["sandbox", "frobnicate"],
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
