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

/// Why a `real-sandbox` row cannot run against `bin`: a test-hooks hub starts its sessions unsandboxed, and a hub
/// whose `sandbox check --json` does not say `ok` has no sandbox here.  `None`: it can.
fn no_real_sandbox(bin: &std::path::Path) -> Option<String> {
    if test_hooks(bin) {
        return Some("the hub binary has test-hooks: its sessions start unsandboxed".into());
    }
    let out = Command::new(bin)
        .args(["sandbox", "check", "--json"])
        .output();
    let check = out
        .ok()
        .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok());
    match check {
        Some(c) if c["ok"] == true => None,
        Some(c) => Some(format!(
            "no sandbox here: {}",
            c["reason"].as_str().unwrap_or("the check failed")
        )),
        None => Some("no sandbox here: `sandbox check --json` gave no answer".into()),
    }
}

/// The JSON `bin ARGS` prints, run in a fresh root (nothing of `~` is read).
fn hub_json(bin: &std::path::Path, args: &[&str]) -> Option<serde_json::Value> {
    let root = hub::Root::new().ok()?;
    let out = Command::new(bin)
        .args(args)
        .env_clear()
        .envs(root.base_env(vec![]))
        .output()
        .ok()?;
    serde_json::from_slice(&out.stdout).ok()
}

/// Why the hub `bin` gives sessions no browser here, for a `chromium` row: its kernel's Landlock ABI (from its
/// `sandbox check`) is below the browser's 9, or it resolves no Chromium (`browser list`).  `None`: it does.
fn no_browser(bin: &std::path::Path) -> Option<String> {
    let abi = hub_json(bin, &["sandbox", "check", "--json"])
        .and_then(|c| c["landlock_abi"].as_u64())
        .unwrap_or(0);
    if abi < 9 {
        return Some(format!(
            "Landlock ABI {abi} is below 9: the hub gives sessions no browser here"
        ));
    }
    match hub_json(bin, &["browser", "list", "--json"]) {
        Some(l) if !l["browser"].is_null() => None,
        Some(l) => Some(format!(
            "no Chromium for sessions here: {}",
            l["fix"].as_str().unwrap_or("`browser list` found none")
        )),
        None => Some("no Chromium for sessions here: `browser list --json` gave no answer".into()),
    }
}

/// Why `ratatoskr-mock cdp-drive` cannot run Playwright MCP here: no `node` on the PATH, or no Playwright MCP in
/// `/opt/pw-mcp` (the browser test image's).  `None`: it can.
fn no_playwright() -> Option<String> {
    let node = std::env::var_os("PATH")
        .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join("node").is_file()));
    let cli = std::path::Path::new("/opt/pw-mcp/node_modules/@playwright/mcp/cli.js");
    match (node, cli.is_file()) {
        (false, _) => Some("needs node on the PATH (the browser test image)".into()),
        (_, false) => Some(format!(
            "needs Playwright MCP at {} (the browser test image)",
            cli.display()
        )),
        _ => None,
    }
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
    // an outside agent's identity is its bridge's parent process, and an orphan's is refused (`sessions::outside`):
    // the harness plays the bridge, so straight under a container's init (`podman run --init … sh -c '… && domr …'`) its
    // parent is PID 1 and `mcp/an-outside-bridge-is-ext-and-unverified` is refused there only. Then it runs as its own
    // child, whose parent is this one, as under a desktop's or CI's shell.
    if std::os::unix::process::parent_id() == 1 {
        let status = std::env::current_exe().and_then(|me| Command::new(me).args(&argv).status());
        return match status {
            Ok(s) => ExitCode::from(s.code().map_or(1, |c| u8::try_from(c).unwrap_or(1))),
            Err(e) => {
                eprintln!("domr: cannot run as its own child: {e}");
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
    // a tag's probe runs only when a row this run selects needs it
    let selected_need = |tag: &str| {
        scenarios
            .iter()
            .filter(|s| {
                args.only
                    .as_deref()
                    .is_none_or(|g| scenario::glob(g, &s.name))
            })
            .any(|s| s.requires.iter().any(|t| t == tag))
    };
    let on = |name: &str| std::env::var(name).as_deref() == Ok("1");
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
        no_rootless: selected_need("rootless")
            .then(scenario::no_rootless)
            .flatten(),
        user_t: scenario::selinux_user_t(),
        ptrace_stays: scenario::ptrace_effective() && !scenario::setpriv_available(),
        no_real_sandbox: selected_need("real-sandbox")
            .then(|| no_real_sandbox(&args.hub_bin))
            .flatten(),
        no_browser: selected_need("chromium")
            .then(|| no_browser(&args.hub_bin))
            .flatten(),
        no_playwright: selected_need("playwright-mcp")
            .then(no_playwright)
            .flatten(),
        browsers_required: on("DRGNX_TEST_REAL_BROWSER"),
        internet: on("DRGNX_TEST_INTERNET"),
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
