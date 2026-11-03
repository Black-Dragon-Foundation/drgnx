//! domr: runs scenario files (docs/develop/runtime.md) against a hub binary, each in fresh temporary roots.
//!
//! `domr --hub-bin PATH --scenarios DIR [--only GLOB] [--only-tag TAG] [--require-all] [--perf OUT.json]`, and the helper
//! `domr connect-as --socket PATH` (the connection of another uid, relayed over stdio).

mod container_escape;
mod exec;
mod http;
mod hub;
mod matcher;
mod report;
mod scenario;

use report::{Outcome, Report};
use scenario::{Gate, Host};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, ExitCode};

const USAGE: &str = "usage: domr --hub-bin PATH --scenarios DIR [--only GLOB] [--only-tag TAG] [--require-all]\n\
    \x20      [--perf OUT.json]\n\
    \x20      domr connect-as --socket PATH";

struct Args {
    hub_bin: PathBuf,
    scenarios: PathBuf,
    only: Option<String>,
    only_tag: Option<String>,
    require_all: bool,
    perf: Option<PathBuf>,
}

fn parse_args(argv: &[String]) -> Result<Args, String> {
    let (mut hub_bin, mut scenarios, mut only, mut only_tag, mut perf) =
        (None, None, None, None, None);
    let mut require_all = false;
    let mut it = argv.iter();
    while let Some(a) = it.next() {
        let mut value = |name: &str| {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match a.as_str() {
            "--hub-bin" => hub_bin = Some(PathBuf::from(value("--hub-bin")?)),
            "--scenarios" => scenarios = Some(PathBuf::from(value("--scenarios")?)),
            "--only" => only = Some(value("--only")?),
            "--only-tag" => only_tag = Some(value("--only-tag")?),
            "--perf" => perf = Some(PathBuf::from(value("--perf")?)),
            "--require-all" => require_all = true,
            other => return Err(format!("unknown argument {other}")),
        }
    }
    // hubs run with their root as the working directory: paths must not be relative to this one
    let absolute = |p: PathBuf| std::fs::canonicalize(&p).unwrap_or(p);
    Ok(Args {
        hub_bin: absolute(hub_bin.ok_or("--hub-bin is required")?),
        scenarios: scenarios.ok_or("--scenarios is required")?,
        only,
        only_tag,
        require_all,
        perf,
    })
}

/// Does the binary say `"test_hooks": true` in `version --json`?
fn test_hooks(bin: &std::path::Path) -> bool {
    Command::new(bin)
        .args(["version", "--json"])
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
        .is_some_and(|v| v["test_hooks"] == true)
}

fn connect_as(argv: &[String]) -> Result<(), String> {
    let path = match argv {
        [flag, p] if flag == "--socket" => p,
        _ => return Err("connect-as --socket PATH".into()),
    };
    let sock = std::os::unix::net::UnixStream::connect(path)
        .map_err(|e| format!("cannot connect to {path}: {e}"))?;
    let mut to_hub = sock.try_clone().map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut stdin = std::io::stdin();
        while let Ok(n) = stdin.read(&mut buf) {
            if n == 0 || to_hub.write_all(&buf[..n]).is_err() {
                break;
            }
        }
        let _ = to_hub.shutdown(std::net::Shutdown::Write);
    });
    let mut from_hub = sock;
    let mut out = std::io::stdout();
    let mut buf = [0u8; 8192];
    while let Ok(n) = from_hub.read(&mut buf) {
        if n == 0 || out.write_all(&buf[..n]).and_then(|()| out.flush()).is_err() {
            break;
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.first().is_some_and(|a| a == "connect-as") {
        return match connect_as(&argv[1..]) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("connect-as: {e}");
                ExitCode::from(2)
            }
        };
    }
    let args = match parse_args(&argv) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("domr: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let scenarios = match scenario::load_dir(&args.scenarios) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("domr: {e}");
            return ExitCode::from(2);
        }
    };
    let hooks_needed = scenarios
        .iter()
        .any(|s| s.requires.iter().any(|t| t == "test-hooks"));
    let host = Host {
        sudo: scenarios
            .iter()
            .any(|s| s.requires.iter().any(|t| t == "sudo"))
            && scenario::sudo_available(),
        linux: cfg!(target_os = "linux"),
        macos: cfg!(target_os = "macos"),
        test_hooks: hooks_needed && test_hooks(&args.hub_bin),
        perf: args.perf.is_some(),
        podman: scenario::podman_available(),
        ptrace_stays: scenario::ptrace_effective() && !scenario::setpriv_available(),
    };
    let cfg = exec::Config {
        hub_bin: args.hub_bin.clone(),
        scenarios: std::fs::canonicalize(&args.scenarios)
            .unwrap_or_else(|_| args.scenarios.clone()),
    };
    let mut report = Report::default();
    for s in &scenarios {
        if args
            .only
            .as_deref()
            .is_some_and(|g| !scenario::glob(g, &s.name))
            || args
                .only_tag
                .as_deref()
                .is_some_and(|t| !s.requires.iter().any(|r| r == t))
        {
            continue;
        }
        let outcome = match scenario::gate(s, &host) {
            Gate::Skip { reason, excused } => Outcome::Skip { reason, excused },
            Gate::Run => {
                let ran = exec::run_scenario(&cfg, s, &mut report.perf);
                report::judge(ran, s.pending.as_deref())
            }
        };
        report.add(&s.name, &outcome);
        let _ = std::io::stdout().flush();
    }
    println!("{}", report.summary());
    if let Some(path) = &args.perf
        && let Err(e) = report.write_perf(path)
    {
        eprintln!("domr: {e}");
        return ExitCode::from(2);
    }
    ExitCode::from(report.exit_code(args.require_all) as u8)
}
