//! `cargo xtask measure`: PSS and idle wakeups of a running process (or one we spawn), written as a JSON report and
//! compared to an earlier report. Exits 1 on a regression beyond 5 %.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::{Child, Command, ExitCode, Stdio};
use std::time::Duration;

use vag::{Report, pss_kib, wakeups};

/// How long a spawned command gets to start up and go idle before it is measured.
const SETTLE: Duration = Duration::from_secs(1);
/// How long the wakeups are counted.
const WINDOW: Duration = Duration::from_secs(2);
/// A metric that grows by more than this fraction against `--base` is a regression.
const TOLERANCE: f64 = 0.05;

struct Args {
    scenario: String,
    target: Target,
    out: PathBuf,
    base: Option<PathBuf>,
}

enum Target {
    Pid(u32),
    Spawn(Vec<String>),
}

fn parse(args: Vec<String>) -> Result<Args, String> {
    let mut it = args.into_iter();
    let scenario = it
        .next()
        .filter(|s| !s.starts_with("--"))
        .ok_or("missing <scenario>")?;
    let (mut pid, mut spawn, mut out, mut base) = (None, None, None, None);
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--pid" => {
                pid = Some(
                    it.next()
                        .and_then(|v| v.parse().ok())
                        .ok_or("--pid needs a number")?,
                )
            }
            // the command and its arguments are everything after --spawn, so it goes last
            "--spawn" => spawn = Some(it.by_ref().collect::<Vec<_>>()),
            "--out" => out = Some(PathBuf::from(it.next().ok_or("--out needs a path")?)),
            "--base" => base = Some(PathBuf::from(it.next().ok_or("--base needs a path")?)),
            other => return Err(format!("unknown flag `{other}`")),
        }
    }
    let target = match (pid, spawn) {
        (Some(p), None) => Target::Pid(p),
        (None, Some(cmd)) if !cmd.is_empty() => Target::Spawn(cmd),
        _ => return Err("give exactly one of --pid PID or --spawn CMD".into()),
    };
    Ok(Args {
        scenario,
        target,
        out: out.ok_or("missing --out FILE")?,
        base,
    })
}

/// The records scene's report, unless `--out` names another.
const RECORDS_BASELINE: &str = "crates/std/vag/baselines/records_org_scale.json";

/// `cargo xtask measure records_org_scale [--reps N] [--out FILE]`: ratatoskr's `records_org_scale` example (release)
/// on a generated tree shaped like the org folder, under `target/`; its medians become a report (a baseline the
/// bars are set from, not a bar).
fn records_org_scale(args: &[String]) -> Result<ExitCode, String> {
    let (mut reps, mut out) = ("5".to_string(), PathBuf::from(RECORDS_BASELINE));
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--reps" => reps = it.next().ok_or("--reps needs a number")?.clone(),
            "--out" => out = PathBuf::from(it.next().ok_or("--out needs a path")?),
            other => return Err(format!("unknown flag `{other}`")),
        }
    }
    let tree = PathBuf::from("target/records_org_scale");
    let json = PathBuf::from("target/records_org_scale.json");
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_string());
    let status = Command::new(cargo)
        .args([
            "run",
            "--release",
            "--locked",
            "-p",
            "ratatoskr",
            "--example",
            "records_org_scale",
            "--",
        ])
        .arg(&tree)
        .arg(&json)
        .arg(&reps)
        .status()
        .map_err(|e| format!("cannot start cargo: {e}"))?;
    if !status.success() {
        return Err(format!("records_org_scale: {status}"));
    }
    let text = std::fs::read_to_string(&json).map_err(|e| format!("{}: {e}", json.display()))?;
    let metrics: BTreeMap<String, f64> =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", json.display()))?;
    let report = Report {
        name: "records_org_scale".to_string(),
        commit: git_commit(),
        machine: std::fs::read_to_string("/proc/sys/kernel/hostname")
            .unwrap_or_default()
            .trim()
            .to_string(),
        metrics,
    };
    report.write_json(&out).map_err(|e| e.to_string())?;
    println!("{}: {:?}", report.name, report.metrics);
    Ok(ExitCode::SUCCESS)
}

pub fn run(args: Vec<String>) -> Result<ExitCode, String> {
    if args.first().map(String::as_str) == Some("records_org_scale") {
        return records_org_scale(&args[1..]);
    }
    let args = parse(args)?;
    let mut child: Option<Child> = None;
    let pid = match &args.target {
        Target::Pid(pid) => *pid,
        Target::Spawn(cmd) => {
            let spawned = Command::new(&cmd[0])
                .args(&cmd[1..])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| format!("cannot start `{}`: {e}", cmd[0]))?;
            let pid = spawned.id();
            child = Some(spawned);
            std::thread::sleep(SETTLE);
            pid
        }
    };
    let measured = measure(pid);
    if let Some(mut c) = child {
        let _ = c.kill();
        let _ = c.wait();
    }
    let (pss, w) = measured?;

    let report = Report {
        name: args.scenario,
        commit: git_commit(),
        machine: std::fs::read_to_string("/proc/sys/kernel/hostname")
            .unwrap_or_default()
            .trim()
            .to_string(),
        metrics: BTreeMap::from([
            ("pss_kib".to_string(), pss as f64),
            (
                "wakeups_per_s".to_string(),
                w.total as f64 / WINDOW.as_secs_f64(),
            ),
        ]),
    };
    report.write_json(&args.out).map_err(|e| e.to_string())?;
    println!("{}: {:?}", report.name, report.metrics);
    for (comm, n) in w.per_thread.iter().filter(|(_, n)| *n > 0) {
        println!("  {n:>6} switches  {comm}");
    }

    let Some(base_path) = args.base else {
        return Ok(ExitCode::SUCCESS);
    };
    let base = Report::read_json(&base_path).map_err(|e| e.to_string())?;
    let regressions = report.compare(&base, TOLERANCE);
    for r in &regressions {
        eprintln!("regression: {r}");
    }
    Ok(if regressions.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}

fn measure(pid: u32) -> Result<(u64, vag::ThreadWakeups), String> {
    let pss = pss_kib(pid).map_err(|e| e.to_string())?;
    let w = wakeups(pid, WINDOW).map_err(|e| e.to_string())?;
    Ok((pss, w))
}

fn git_commit() -> String {
    Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}
