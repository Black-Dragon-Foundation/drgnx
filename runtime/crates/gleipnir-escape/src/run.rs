//! Running one row: needs and skips, the control run, `ratatoskr sandbox run`, the comparison (Task 14).
//!
//! The judging is in pure functions ([`judge_control`], [`judge_lines`], [`judge_run`], [`subset`], [`skip_reason`])
//! so it is tested without a sandbox. [`run_row`] is the glue: fixtures, the processes, the data the judges read.
//!
//! The rules (docs/develop/gleipnir.md, "Proving it"):
//! - only the reasons in [`Skip`] may skip a row. Anything else, a sandbox refusal among them, is a fail, so a
//!   regression that refuses every spec can never look green;
//! - the sandbox's own outcome is read from the `--result` file, never from the exit code (a child may exit 3);
//! - a canary's text anywhere in the output or the result file fails the row.

use crate::fixture::{Canary, Fixture};
use crate::row::{After, KillWho, Need, Platform, Raw, Row, Setup, TierName};
use crate::{ProbeLine, errno_from_name};
use serde_json::Value;
use std::fmt;
use std::io::{BufRead, Read};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// The files `ratatoskr` and the probe live in.
#[derive(Debug, Clone)]
pub struct Opts {
    pub ratatoskr: PathBuf,
    pub probe: PathBuf,
}

/// What this machine is, found once.
#[derive(Debug, Clone)]
pub struct Host {
    pub in_container: bool,
    pub root: bool,
    pub landlock_abi: u8,
    pub x32: bool,
}

/// The only reasons a row may be skipped (review B2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Skip {
    InContainer,
    NeedsMacos,
    NeedsLinux,
    NeedsX86_64,
    X32Off,
    NeedsRoot,
    LandlockBelow { have: u8, need: u8 },
}

impl fmt::Display for Skip {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Skip::InContainer => f.write_str("inside a container"),
            Skip::NeedsMacos => f.write_str("needs macos"),
            Skip::NeedsLinux => f.write_str("needs linux"),
            Skip::NeedsX86_64 => f.write_str("needs x86_64"),
            Skip::X32Off => f.write_str("x32 is off"),
            Skip::NeedsRoot => f.write_str("needs root"),
            Skip::LandlockBelow { have, need } => write!(f, "Landlock ABI {have} below {need}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Pass,
    Fail(String),
    Skip(String),
}

// ---------------------------------------------------------------------------------------------------------------
// Skips

/// Why the row cannot run here, if it cannot. Anything not in [`Skip`] is no reason.
pub fn skip_reason(row: &Row, host: &Host) -> Option<Skip> {
    let linux = cfg!(target_os = "linux");
    let macos = cfg!(target_os = "macos");
    let needs = |n: Need| row.needs.contains(&n);
    if (row.platform() == Platform::Macos || needs(Need::Macos)) && !macos {
        return Some(Skip::NeedsMacos);
    }
    let linux_only = row.platform() == Platform::Linux
        || [
            Need::Linux,
            Need::Bwrap,
            Need::Reduced,
            Need::Landlock,
            Need::Seccomp,
            Need::Netns,
            Need::X32,
        ]
        .into_iter()
        .any(needs);
    if linux_only && !linux {
        return Some(Skip::NeedsLinux);
    }
    if (needs(Need::X86_64) || needs(Need::X32)) && std::env::consts::ARCH != "x86_64" {
        return Some(Skip::NeedsX86_64);
    }
    if needs(Need::X32) && !host.x32 {
        return Some(Skip::X32Off);
    }
    if needs(Need::Root) && !host.root {
        return Some(Skip::NeedsRoot);
    }
    if (needs(Need::Bwrap) || needs(Need::Netns)) && host.in_container {
        return Some(Skip::InContainer);
    }
    let landlock = if needs(Need::Reduced) {
        Some(gleipnir::LANDLOCK_FLOOR_REDUCED)
    } else if needs(Need::Landlock) {
        Some(gleipnir::LANDLOCK_FLOOR_FULL)
    } else {
        None
    };
    if let Some(need) = landlock
        && host.landlock_abi < need
    {
        return Some(Skip::LandlockBelow {
            have: host.landlock_abi,
            need,
        });
    }
    None
}

pub fn detect_host(probe: &Path) -> Host {
    let probe_one = |args: &[&str]| -> Option<ProbeLine> {
        let out = Command::new(probe)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .ok()?;
        serde_json::from_slice(out.stdout.split(|b| *b == b'\n').next()?).ok()
    };
    let landlock_abi = probe_one(&["landlock-abi"])
        .filter(|l| l.result == "reached")
        .and_then(|l| l.detail?.parse().ok())
        .unwrap_or(0);
    let x32 = probe_one(&["syscall", "x32-getpid"]).is_some_and(|l| l.result == "reached");
    let root = rustix::process::geteuid().is_root()
        || Command::new("sudo")
            .args(["-n", "true"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
    Host {
        in_container: Path::new("/run/.containerenv").exists() || Path::new("/.dockerenv").exists(),
        root,
        landlock_abi,
        x32,
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Judging

fn errno_in(line: &ProbeLine, allowed: &[String]) -> bool {
    let Some(got) = line.errno.as_deref().and_then(errno_from_name) else {
        return false;
    };
    allowed.iter().any(|a| errno_from_name(a) == Some(got))
}

fn show(l: &ProbeLine) -> String {
    format!(
        "{} {} -> {}{}{}",
        l.probe,
        l.arg,
        l.result,
        l.errno.as_ref().map_or(String::new(), |e| format!(" {e}")),
        l.detail
            .as_ref()
            .map_or(String::new(), |d| format!(" ({d})")),
    )
}

/// The lines against the expectations, one to one. More lines than expectations are not looked at.
pub fn judge_lines(expect: &[crate::row::Expect], lines: &[ProbeLine]) -> Result<(), String> {
    for (i, e) in expect.iter().enumerate() {
        let l = lines
            .get(i)
            .ok_or_else(|| format!("probe {} printed no line", i + 1))?;
        let want = match e.result {
            crate::row::ResultKind::Reached => "reached",
            crate::row::ResultKind::Blocked => "blocked",
        };
        if l.result != want {
            return Err(format!("probe {}: wanted {want}, got {}", i + 1, show(l)));
        }
        if want == "blocked" && !e.errno.is_empty() && !errno_in(l, &e.errno) {
            return Err(format!(
                "probe {}: wanted errno in {:?}, got {}",
                i + 1,
                e.errno,
                show(l)
            ));
        }
        if let Some(d) = &e.detail
            && l.detail.as_deref() != Some(d.as_str())
        {
            return Err(format!(
                "probe {}: wanted detail {d:?}, got {}",
                i + 1,
                show(l)
            ));
        }
    }
    Ok(())
}

/// The control run: every probe gives its unfiltered result (`reached`, or the row's `control_expect`).
pub fn judge_control(row: &Row, lines: &[ProbeLine]) -> Result<(), String> {
    let default: Vec<crate::row::Expect>;
    let want = match &row.control_expect {
        Some(c) => c.as_slice(),
        None => {
            default = row
                .probes
                .iter()
                .map(|_| crate::row::Expect {
                    result: crate::row::ResultKind::Reached,
                    errno: vec![],
                    detail: None,
                })
                .collect();
            &default
        }
    };
    if lines.len() != row.probes.len() {
        return Err(format!(
            "control did not reach: {} lines for {} probes",
            lines.len(),
            row.probes.len()
        ));
    }
    judge_lines(want, lines).map_err(|e| format!("control did not reach: {e}"))
}

/// `want` is contained in `actual`: objects key by key, other values equal. A key `NAME_contains` asks that the
/// string at `NAME` contain the text. A wanted object needs an object (even `{}`: `{"refused": {}}` against a
/// `refused` of `null` fails, gate review S12).
pub fn subset(actual: &Value, want: &Value) -> Result<(), String> {
    fn go(path: &str, a: &Value, w: &Value) -> Result<(), String> {
        match (a, w) {
            (a, Value::Object(_)) if !a.is_object() => {
                Err(format!("{path}: wanted an object, got {a}"))
            }
            (_, Value::Object(wm)) => {
                for (k, wv) in wm {
                    if let Some(base) = k.strip_suffix("_contains") {
                        let text = a.get(base).and_then(Value::as_str).unwrap_or("");
                        let needle = wv.as_str().unwrap_or("");
                        if !text.contains(needle) {
                            return Err(format!("{path}.{base}: {text:?} lacks {needle:?}"));
                        }
                        continue;
                    }
                    go(&format!("{path}.{k}"), a.get(k).unwrap_or(&Value::Null), wv)?;
                }
                Ok(())
            }
            (a, w) if a == w => Ok(()),
            (a, w) => Err(format!("{path}: wanted {w}, got {a}")),
        }
    }
    go("$", actual, want)
}

/// What a run left behind.
#[derive(Debug, Default)]
pub struct RunData {
    /// A control or unsandboxed run: there is no result file.
    pub direct: bool,
    pub result_file: Option<Value>,
    pub lines: Vec<ProbeLine>,
    pub bad_lines: Vec<String>,
    pub stdout: String,
    pub stderr: String,
    pub result_text: String,
    /// `(listener, connections)` for each of the row's `listeners_silent`.
    pub silent: Vec<(String, usize)>,
    pub events: Vec<String>,
    /// The row's `proxy_events` with placeholders filled (`None`: take the row's text as it is).
    pub events_wanted: Option<Vec<String>>,
    /// Paths of `files_absent` that exist.
    pub present: Vec<String>,
    pub gone_failure: Option<String>,
    pub exit: Option<i32>,
}

/// The first canary whose text is in `haystacks`.
pub fn leaked<'a>(canaries: &'a [Canary], haystacks: &[&str]) -> Option<&'a Canary> {
    canaries
        .iter()
        .find(|c| haystacks.iter().any(|h| h.contains(&c.text)))
}

pub fn judge_run(row: &Row, d: &RunData, canaries: &[Canary]) -> Result<(), String> {
    if let Some(c) = leaked(canaries, &[&d.stdout, &d.stderr, &d.result_text]) {
        return Err(format!("canary text ({}) appeared in the output", c.name));
    }
    if let Some(bad) = d.bad_lines.first() {
        return Err(format!("an output line is not a probe line: {bad:?}"));
    }
    if let Some(raw) = &row.raw {
        return judge_raw(raw, d);
    }
    // A row that kills the `sandbox run` process itself leaves no result file to judge.
    let run_killed = row.after.as_ref().is_some_and(|a| a.kill == KillWho::Run);
    if !d.direct && !run_killed {
        let r = d
            .result_file
            .as_ref()
            .ok_or_else(|| format!("no result file; stderr: {}", tail(&d.stderr)))?;
        match &row.result {
            Some(want) => {
                subset(r, want).map_err(|e| format!("result: {e}"))?;
                // A refused row expects no line: the program never ran, so it printed nothing (gate review S12).
                if row.expect.is_empty() && !d.stdout.trim().is_empty() {
                    return Err(format!(
                        "the run was to print nothing, yet it printed: {}",
                        tail(&d.stdout)
                    ));
                }
            }
            None if row.after.is_some() => {}
            None => {
                if !r["refused"].is_null() {
                    return Err(format!(
                        "the sandbox refused the run: {}; stderr: {}",
                        r["refused"],
                        tail(&d.stderr)
                    ));
                }
                if r["exit"] != 0 {
                    return Err(format!(
                        "the run exited {}; stderr: {}",
                        r["exit"],
                        tail(&d.stderr)
                    ));
                }
                if d.lines.len() != row.probes.len() {
                    return Err(format!(
                        "{} lines for {} probes",
                        d.lines.len(),
                        row.probes.len()
                    ));
                }
            }
        }
    } else if d.direct && d.lines.len() != row.probes.len() {
        return Err(format!(
            "{} lines for {} probes",
            d.lines.len(),
            row.probes.len()
        ));
    }
    judge_lines(&row.expect, &d.lines)?;
    if let Some((name, n)) = d.silent.iter().find(|(_, n)| *n > 0) {
        return Err(format!("listener {name} saw {n} connection(s)"));
    }
    if let Some(want) = d.events_wanted.as_ref().or(row.proxy_events.as_ref()) {
        let mut want = want.clone();
        want.sort();
        if d.events != want {
            return Err(format!("proxy events: wanted {want:?}, got {:?}", d.events));
        }
    }
    if let Some(p) = d.present.first() {
        return Err(format!("{p} exists after the run"));
    }
    if let Some(g) = &d.gone_failure {
        return Err(g.clone());
    }
    Ok(())
}

fn judge_raw(raw: &Raw, d: &RunData) -> Result<(), String> {
    if let Some(code) = raw.exit
        && d.exit != Some(code)
    {
        return Err(format!(
            "exit {:?}, wanted {code}; stderr: {}",
            d.exit,
            tail(&d.stderr)
        ));
    }
    for s in &raw.stdout_contains {
        if !d.stdout.contains(s) {
            return Err(format!("stdout lacks {s:?}: {}", tail(&d.stdout)));
        }
    }
    if let Some(want) = &raw.json {
        let got: Value = serde_json::from_str(&d.stdout)
            .map_err(|e| format!("stdout is not JSON ({e}): {}", tail(&d.stdout)))?;
        subset(&got, want).map_err(|e| format!("stdout JSON: {e}"))?;
    }
    if let Some(p) = d.present.first() {
        return Err(format!("{p} exists after the run"));
    }
    Ok(())
}

fn tail(s: &str) -> String {
    let t = s.trim();
    let skip = t.chars().count().saturating_sub(300);
    t.chars()
        .skip(skip)
        .collect::<String>()
        .replace('\n', " | ")
}

// ---------------------------------------------------------------------------------------------------------------
// Running

fn probe_args(probes: &[Vec<String>]) -> Vec<String> {
    let mut out = Vec::new();
    for (i, p) in probes.iter().enumerate() {
        if i > 0 {
            out.push("--and".to_string());
        }
        out.extend(p.iter().cloned());
    }
    out
}

fn expand_all(fx: &Fixture, v: &Value) -> Result<Value, String> {
    Ok(match v {
        Value::String(s) => Value::String(fx.expand(s)?),
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| expand_all(fx, x))
                .collect::<Result<_, _>>()?,
        ),
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, x)| Ok((k.clone(), expand_all(fx, x)?)))
                .collect::<Result<_, String>>()?,
        ),
        other => other.clone(),
    })
}

/// The row's spec with the harness's defaults, placeholders filled. `bin` (the probe's directory) joins `read`.
pub fn build_spec(fx: &Fixture, row: &Row, bin: &Path) -> Result<Value, String> {
    build_spec_for(fx, row, bin, cfg!(target_os = "linux"))
}

/// [`build_spec`] for a Linux or a macOS target, so the macOS defaults are tested on Linux too.
pub fn build_spec_for(fx: &Fixture, row: &Row, bin: &Path, linux: bool) -> Result<Value, String> {
    let mut spec = match &row.spec {
        Value::Null => serde_json::json!({}),
        v @ Value::Object(_) => v.clone(),
        _ => return Err("spec must be an object".into()),
    };
    let reduced = row.tier == TierName::Reduced;
    {
        let m = spec.as_object_mut().expect("object");
        m.entry("chdir").or_insert_with(|| "${W}".into());
        let mut env = serde_json::json!([["PATH", "/usr/bin:/bin"]]);
        if !m.contains_key("net") {
            // The session's own network: isolated, with the relay to the fixture's proxy (Linux needs one). The
            // full tier uses 3128; the reduced tier's relay shares the host's loopback, so it gets a free port.
            let tier = if reduced {
                gleipnir::Tier::Reduced
            } else {
                gleipnir::Tier::Full
            };
            if linux {
                let port = gleipnir::backend::relay_ports(tier, &[3128])
                    .map_err(|e| format!("relay port: {e}"))?[0];
                m.insert("net".into(), serde_json::json!({"isolated": {"relay": [{"port": port, "socket": "${RUN}/proxy.sock"}]}}));
                m.entry("run").or_insert_with(
                    || serde_json::json!({"mode": "ro", "source": "${RUN}", "dest": "${RUN}"}),
                );
                m.entry("sockets")
                    .or_insert_with(|| serde_json::json!(["${RUN}/proxy.sock"]));
                env.as_array_mut().expect("array").push(serde_json::json!([
                    "HTTPS_PROXY",
                    format!("http://127.0.0.1:{port}")
                ]));
            } else {
                // macOS: no relay and no namespace; Seatbelt lists the one loopback port the proxy listens on.
                let port = fx.addrs.proxy_tcp.port();
                m.insert(
                    "net".into(),
                    serde_json::json!({"isolated": {"mac_tcp_ports": [port]}}),
                );
                env.as_array_mut().expect("array").push(serde_json::json!([
                    "HTTPS_PROXY",
                    format!("http://127.0.0.1:{port}")
                ]));
            }
        }
        m.entry("env").or_insert(env);
        m.entry("layers").or_insert_with(|| {
            // macOS has no Landlock: its only valid minimum is 0.
            let abi = match (linux, reduced) {
                (false, _) => 0,
                (true, true) => gleipnir::LANDLOCK_FLOOR_REDUCED,
                (true, false) => gleipnir::LANDLOCK_FLOOR_FULL,
            };
            serde_json::json!({"landlock_min_abi": abi})
        });
        if reduced {
            m.entry("tmp").or_insert_with(|| "${TMP}".into());
        }
        let read = m.entry("read").or_insert_with(|| serde_json::json!([]));
        if let Some(a) = read.as_array_mut() {
            a.push(Value::String(bin.to_string_lossy().into_owned()));
        }
    }
    expand_all(fx, &spec)
}

fn find_children(pid: u32) -> Vec<u32> {
    let Ok(dir) = std::fs::read_dir("/proc") else {
        return vec![];
    };
    let mut out = Vec::new();
    for e in dir.flatten() {
        let Some(child) = e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(e.path().join("stat")) else {
            continue;
        };
        // "pid (comm) S ppid …": the comm may hold spaces and parentheses, so cut at the last ')'.
        let ppid = stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().nth(1))
            .and_then(|p| p.parse::<u32>().ok());
        if ppid == Some(pid) {
            out.push(child);
        }
    }
    out.sort();
    out
}

fn cmdline_matches(needle: &str) -> bool {
    let Ok(dir) = std::fs::read_dir("/proc") else {
        return false;
    };
    dir.flatten().any(|e| {
        e.file_name()
            .to_str()
            .is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit()))
            && std::fs::read(e.path().join("cmdline"))
                .map(|b| {
                    String::from_utf8_lossy(&b)
                        .replace('\0', " ")
                        .contains(needle)
                })
                .unwrap_or(false)
    })
}

/// Do what `after` says; return a failure text, if any.
fn act(after: &After, child: &Child) -> Option<String> {
    if let Some(g) = &after.gone
        && !cmdline_matches(&g.matching)
    {
        return Some(format!(
            "no process matching {:?} existed before the kill",
            g.matching
        ));
    }
    let target = match after.kill {
        KillWho::Run => child.id() as i32,
        KillWho::Group => match find_children(child.id()).first() {
            Some(c) => -(*c as i32),
            None => return Some("no sandbox process found to kill".into()),
        },
    };
    // SAFETY: kill(2) with plain integers.
    unsafe { libc::kill(target, after.signal) };
    let g = after.gone.as_ref()?;
    let end = Instant::now() + Duration::from_millis(g.within_ms);
    while Instant::now() < end {
        if !cmdline_matches(&g.matching) {
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Some(format!(
        "a process matching {:?} was still there {} ms after the kill",
        g.matching, g.within_ms
    ))
}

/// The `--pause-before-spawn` dance: wait for `opened`, run the swaps, answer with a line. Non-blocking opens, so a
/// `ratatoskr` that refuses before it gets there cannot hang the harness.
fn pause_dance(fifo: &Path, swaps: &[(PathBuf, PathBuf)], child: &mut Child) -> Result<(), String> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(30);
    // SAFETY: plain open/read/write/close on a path we made.
    unsafe {
        let r = libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_NONBLOCK);
        if r < 0 {
            return Err(format!("open fifo: {}", std::io::Error::last_os_error()));
        }
        let mut got = Vec::new();
        let mut buf = [0u8; 64];
        while !got.ends_with(b"\n") {
            let n = libc::read(r, buf.as_mut_ptr().cast(), buf.len());
            if n > 0 {
                got.extend_from_slice(&buf[..n as usize]);
                continue;
            }
            if matches!(child.try_wait(), Ok(Some(_))) {
                libc::close(r);
                return Ok(()); // refused before the pause: the result file says why
            }
            if Instant::now() > deadline {
                libc::close(r);
                return Err("ratatoskr never reached --pause-before-spawn".into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        libc::close(r);
        for (path, target) in swaps {
            let mut aside = path.clone().into_os_string();
            aside.push(".orig");
            std::fs::rename(path, &aside).map_err(|e| format!("swap {}: {e}", path.display()))?;
            std::os::unix::fs::symlink(target, path)
                .map_err(|e| format!("swap {}: {e}", path.display()))?;
        }
        loop {
            let w = libc::open(c.as_ptr(), libc::O_WRONLY | libc::O_NONBLOCK);
            if w >= 0 {
                libc::write(w, b"go\n".as_ptr().cast(), 3);
                libc::close(w);
                return Ok(());
            }
            if matches!(child.try_wait(), Ok(Some(_))) || Instant::now() > deadline {
                return Err("ratatoskr stopped waiting at --pause-before-spawn".into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

struct Driven {
    stdout_lines: Vec<String>,
    stderr: String,
    exit: Option<i32>,
    gone_failure: Option<String>,
}

/// Start `cmd`, stream its stdout lines, act on `after`, and wait (at most a minute).
fn drive(
    mut cmd: Command,
    after: Option<&After>,
    pause: Option<(&Path, &[(PathBuf, PathBuf)])>,
) -> Result<Driven, String> {
    use std::os::unix::process::ExitStatusExt;
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("cannot start {:?}: {e}", cmd.get_program()))?;
    let (tx, rx) = mpsc::channel::<String>();
    let out = child.stdout.take().expect("piped");
    std::thread::spawn(move || {
        for l in std::io::BufReader::new(out).lines().map_while(Result::ok) {
            if tx.send(l).is_err() {
                return;
            }
        }
    });
    let err = Arc::new(Mutex::new(String::new()));
    let (err2, mut errp) = (err.clone(), child.stderr.take().expect("piped"));
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        while let Ok(n @ 1..) = errp.read(&mut buf) {
            err2.lock()
                .unwrap()
                .push_str(&String::from_utf8_lossy(&buf[..n]));
        }
    });
    if let Some((fifo, swaps)) = pause
        && let Err(e) = pause_dance(fifo, swaps, &mut child)
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err(e);
    }
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut lines = Vec::new();
    let mut acted = false;
    let mut gone_failure = None;
    let status = loop {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(l) => {
                lines.push(l);
                if let Some(a) = after
                    && !acted
                    && lines.len() >= a.after_lines
                {
                    acted = true;
                    gone_failure = act(a, &child);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                std::thread::sleep(Duration::from_millis(20))
            }
        }
        if let Ok(Some(st)) = child.try_wait() {
            break st;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("timed out after 60 s".into());
        }
    };
    while let Ok(l) = rx.recv_timeout(Duration::from_millis(300)) {
        lines.push(l);
    }
    std::thread::sleep(Duration::from_millis(50));
    let stderr = err.lock().unwrap().clone();
    Ok(Driven {
        stdout_lines: lines,
        stderr,
        exit: status.code().or_else(|| status.signal().map(|s| 128 + s)),
        gone_failure,
    })
}

fn parse_lines(lines: &[String]) -> (Vec<ProbeLine>, Vec<String>) {
    let (mut good, mut bad) = (Vec::new(), Vec::new());
    for l in lines {
        match serde_json::from_str::<ProbeLine>(l) {
            Ok(p) => good.push(p),
            Err(_) => bad.push(l.clone()),
        }
    }
    (good, bad)
}

/// Setup that both runs share (a link in the fixture, the sleep), and what only the sandboxed run uses.
#[derive(Default)]
struct Prepared {
    path_dir: Option<PathBuf>,
    canary_fds: Vec<i32>,
    swaps: Vec<(PathBuf, PathBuf)>,
}

fn sudo(args: &[&str]) -> Result<(), String> {
    let mut cmd = if rustix::process::geteuid().is_root() {
        let mut c = Command::new(args[0]);
        c.args(&args[1..]);
        c
    } else {
        let mut c = Command::new("sudo");
        c.arg("-n").args(args);
        c
    };
    let out = cmd
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("{}: {e}", args[0]))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{} failed: {}",
            args.join(" "),
            tail(&String::from_utf8_lossy(&out.stderr))
        ))
    }
}

fn setup(fx: &mut Fixture, row: &Row, control: bool) -> Result<Prepared, String> {
    let mut p = Prepared::default();
    for step in &row.setup {
        match step {
            Setup::StartSleep {} => fx.start_sleep().map_err(|e| format!("start-sleep: {e}"))?,
            Setup::PlantLink { path, target } => {
                let (path, target) = (fx.expand(path)?, fx.expand(target)?);
                if let Some(parent) = Path::new(&path).parent() {
                    std::fs::create_dir_all(parent).map_err(|e| format!("plant-link: {e}"))?;
                }
                std::os::unix::fs::symlink(&target, &path)
                    .map_err(|e| format!("plant-link {path}: {e}"))?;
            }
            Setup::MakeDir { path } => {
                let path = fx.expand(path)?;
                std::fs::create_dir_all(&path).map_err(|e| format!("make-dir {path}: {e}"))?;
            }
            Setup::MakeFile { path, text } => {
                let (path, text) = (fx.expand(path)?, fx.expand(text)?);
                if let Some(parent) = Path::new(&path).parent() {
                    std::fs::create_dir_all(parent).map_err(|e| format!("make-file: {e}"))?;
                }
                std::fs::write(&path, text).map_err(|e| format!("make-file {path}: {e}"))?;
            }
            // Applied to the command itself, in both runs ([`controlling_tty`]).
            Setup::ControllingTty {} => {}
            // The rest belong to the sandboxed run alone: the control would only trip over them.
            _ if control => {}
            Setup::SwapToLink { path, target } => p
                .swaps
                .push((fx.expand(path)?.into(), fx.expand(target)?.into())),
            Setup::CanaryFd { n } => p.canary_fds.push(*n),
            Setup::PathBwrap { name } => {
                let dir = fx.path("pathbin");
                std::fs::create_dir_all(&dir).map_err(|e| format!("path-bwrap: {e}"))?;
                let script = dir.join(name.as_deref().unwrap_or("bwrap"));
                let marker = fx.value("MARKER")?;
                std::fs::write(
                    &script,
                    format!("#!/bin/sh\necho called > '{marker}'\nexit 0\n"),
                )
                .map_err(|e| e.to_string())?;
                set_mode(&script, 0o755)?;
                p.path_dir = Some(dir);
            }
            Setup::FakeBwrap { version } => {
                let marker = fx.value("MARKER")?;
                let tmpl = "/var/lib/glp-XXXXXX";
                let out = {
                    let mut c = if rustix::process::geteuid().is_root() {
                        Command::new("mktemp")
                    } else {
                        let mut c = Command::new("sudo");
                        c.args(["-n", "mktemp"]);
                        c
                    };
                    c.args(["-d", tmpl])
                        .output()
                        .map_err(|e| format!("fake-bwrap: {e}"))?
                };
                if !out.status.success() {
                    return Err(format!(
                        "fake-bwrap: mktemp failed: {}",
                        tail(&String::from_utf8_lossy(&out.stderr))
                    ));
                }
                let dir = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
                fx.root_dirs.push(dir.clone());
                let script = fx.path("fake-bwrap.sh");
                std::fs::write(
                    &script,
                    format!(
                        "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"bubblewrap {version}\"; exit 0; fi\n\
                         echo called > '{marker}'\nexit 0\n"
                    ),
                )
                .map_err(|e| e.to_string())?;
                let (d, s) = (
                    dir.to_string_lossy().into_owned(),
                    script.to_string_lossy().into_owned(),
                );
                let dest = format!("{d}/bwrap");
                sudo(&["chmod", "0755", &d])?;
                sudo(&["install", "-m", "0755", "-o", "root", &s, &dest])?;
            }
        }
    }
    Ok(p)
}

/// A pty's two ends, held open until the run has ended (closing the master would hang up the session).
struct Tty {
    _master: std::os::fd::OwnedFd,
    _slave: std::os::fd::OwnedFd,
}

/// The `controlling-tty` setup, when the row has it: `cmd` starts in a new session (`setsid`) whose controlling
/// terminal is a fresh pty's slave (`TIOCSCTTY`); the returned ends must outlive the run.
fn controlling_tty(row: &Row, cmd: &mut Command) -> Result<Option<Tty>, String> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    if !row
        .setup
        .iter()
        .any(|s| matches!(s, Setup::ControllingTty {}))
    {
        return Ok(None);
    }
    let err = |what: &str| {
        format!(
            "controlling-tty: {what}: {}",
            std::io::Error::last_os_error()
        )
    };
    // SAFETY: posix_openpt/grantpt/unlockpt/ptsname/open on fds we own; ptsname's static buffer is copied at once,
    // and no other harness thread calls it.
    let (master, slave) = unsafe {
        // macOS's posix_openpt takes only O_RDWR and O_NOCTTY: close-on-exec is set after.
        let m = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
        if m < 0 {
            return Err(err("posix_openpt"));
        }
        let master = OwnedFd::from_raw_fd(m);
        if libc::fcntl(m, libc::F_SETFD, libc::FD_CLOEXEC) != 0 {
            return Err(err("FD_CLOEXEC"));
        }
        if libc::grantpt(m) != 0 || libc::unlockpt(m) != 0 {
            return Err(err("grantpt/unlockpt"));
        }
        let name = libc::ptsname(m);
        if name.is_null() {
            return Err(err("ptsname"));
        }
        let name = std::ffi::CStr::from_ptr(name).to_owned();
        let s = libc::open(
            name.as_ptr(),
            libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC,
        );
        if s < 0 {
            return Err(err("open the slave"));
        }
        (master, OwnedFd::from_raw_fd(s))
    };
    let fd = slave.as_raw_fd();
    // SAFETY: setsid(2) and ioctl(2) between the fork and the exec; nothing allocates. The slave is still open in
    // the child here (close-on-exec closes it only at the exec), and the terminal stays its controlling one after.
    unsafe {
        cmd.pre_exec(move || {
            if libc::setsid() < 0 || libc::ioctl(fd, libc::TIOCSCTTY as _, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(Some(Tty {
        _master: master,
        _slave: slave,
    }))
}

fn set_mode(p: &Path, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode)).map_err(|e| e.to_string())
}

fn expand_list(fx: &Fixture, v: &[String]) -> Result<Vec<String>, String> {
    v.iter().map(|s| fx.expand(s)).collect()
}

/// The control run, or an unsandboxed row: the probes as a plain child, in a fixture of their own.
fn run_direct(opts: &Opts, row: &Row) -> Result<(Fixture, RunData), String> {
    let mut fx = Fixture::new().map_err(|e| format!("fixture: {e}"))?;
    setup(&mut fx, row, true)?;
    let probes = row
        .probes
        .iter()
        .map(|p| expand_list(&fx, p))
        .collect::<Result<Vec<_>, _>>()?;
    let mut cmd = Command::new(&opts.probe);
    cmd.args(probe_args(&probes))
        .env_clear()
        .envs(fx.env("/usr/bin:/bin"))
        .current_dir(fx.path("w"));
    crate::only_stdio(&mut cmd);
    let tty = controlling_tty(row, &mut cmd)?;
    let d = drive(cmd, None, None)?;
    drop(tty);
    let (lines, bad) = parse_lines(&d.stdout_lines);
    let data = RunData {
        direct: true,
        lines,
        bad_lines: bad,
        stdout: d.stdout_lines.join("\n"),
        stderr: d.stderr,
        exit: d.exit,
        ..RunData::default()
    };
    Ok((fx, data))
}

/// `ratatoskr sandbox run` (or the raw command) in a fresh fixture.
fn run_sandboxed(opts: &Opts, row: &Row) -> Result<(Fixture, RunData), String> {
    let mut fx = Fixture::new().map_err(|e| format!("fixture: {e}"))?;
    let prep = setup(&mut fx, row, false)?;
    let bin = fx.path("bin");
    let probe_copy = bin.join("gleipnir-probe");
    std::fs::copy(&opts.probe, &probe_copy).map_err(|e| format!("copy the probe: {e}"))?;
    let path = match &prep.path_dir {
        Some(d) => format!("{}:/usr/bin:/bin", d.display()),
        None => "/usr/bin:/bin".to_string(),
    };

    let mut cmd = Command::new(&opts.ratatoskr);
    cmd.env_clear()
        .envs(fx.env(&path))
        .current_dir(fx.path("w"));
    let fifo = fx.path("pause.fifo");
    let (spec_path, result_path) = (fx.path("spec.json"), fx.path("result.json"));
    if let Some(raw) = &row.raw {
        cmd.args(expand_list(&fx, &raw.args)?);
    } else {
        let spec = build_spec(&fx, row, &bin)?;
        std::fs::write(&spec_path, spec.to_string()).map_err(|e| e.to_string())?;
        cmd.args(["sandbox", "run", "--tier", row.tier.arg(), "--spec"])
            .arg(&spec_path)
            .arg("--result")
            .arg(&result_path);
        if let Some(b) = &row.bwrap {
            cmd.arg("--bwrap").arg(fx.expand(b)?);
        }
        if !prep.swaps.is_empty() {
            let c = std::ffi::CString::new(fifo.to_string_lossy().as_bytes())
                .map_err(|e| e.to_string())?;
            // SAFETY: mkfifo on a path in our fixture.
            if unsafe { libc::mkfifo(c.as_ptr(), 0o600) } != 0 {
                return Err(format!("mkfifo: {}", std::io::Error::last_os_error()));
            }
            cmd.arg("--pause-before-spawn").arg(&fifo);
        }
        for o in expand_list(&fx, &row.landlock_omit)? {
            cmd.arg("--landlock-omit").arg(o);
        }
        if let Some(n) = row.landlock_abi_cap {
            cmd.arg("--landlock-abi-cap").arg(n.to_string());
        }
        let probes = row
            .probes
            .iter()
            .map(|p| expand_list(&fx, p))
            .collect::<Result<Vec<_>, _>>()?;
        cmd.arg("--").arg(&probe_copy).args(probe_args(&probes));
    }
    // Held open until the run has ended, so the fd numbers below stay valid for the fork.
    let mut canary_file = None;
    if !prep.canary_fds.is_empty() {
        let canary = std::fs::File::open(fx.path("home/canary-dir/canary.txt"))
            .map_err(|e| e.to_string())?;
        let fds = prep.canary_fds.clone();
        let src = std::os::fd::AsRawFd::as_raw_fd(&canary);
        // SAFETY: dup2 between the fork and the exec; it allocates nothing and clears close-on-exec on the copy.
        unsafe {
            cmd.pre_exec(move || {
                for n in &fds {
                    if libc::dup2(src, *n) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                Ok(())
            });
        }
        canary_file = Some(canary);
    }
    let pause = (!prep.swaps.is_empty()).then_some((fifo.as_path(), prep.swaps.as_slice()));
    // `gone.match` may name the fixture (`${FIXTURE}/bin/gleipnir-probe …`), so a process the control run left
    // behind never stands in for this run's.
    let after = match &row.after {
        Some(a) => {
            let mut a = a.clone();
            if let Some(g) = &mut a.gone {
                g.matching = fx.expand(&g.matching)?;
            }
            Some(a)
        }
        None => None,
    };
    let tty = controlling_tty(row, &mut cmd)?;
    let d = drive(cmd, after.as_ref(), pause);
    drop(tty);
    drop(canary_file);
    finish(row, fx, d, &result_path)
}

fn finish(
    row: &Row,
    fx: Fixture,
    d: Result<Driven, String>,
    result_path: &Path,
) -> Result<(Fixture, RunData), String> {
    let d = d?;
    let result_text = std::fs::read_to_string(result_path).unwrap_or_default();
    let (lines, bad) = if row.raw.is_some() {
        (vec![], vec![])
    } else {
        parse_lines(&d.stdout_lines)
    };
    let present = row
        .files_absent
        .iter()
        .map(|p| fx.expand(p))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|p| std::fs::symlink_metadata(p).is_ok())
        .collect();
    let data = RunData {
        direct: false,
        result_file: serde_json::from_str(&result_text).ok(),
        lines,
        bad_lines: bad,
        stdout: d.stdout_lines.join("\n"),
        stderr: d.stderr,
        result_text,
        silent: row
            .listeners_silent
            .iter()
            .map(|n| (n.clone(), fx.seen(n)))
            .collect(),
        events: fx.proxy_events(),
        events_wanted: row
            .proxy_events
            .as_ref()
            .map(|w| expand_list(&fx, w))
            .transpose()?,
        present,
        gone_failure: d.gone_failure,
        exit: d.exit,
    };
    Ok((fx, data))
}

/// One row, start to end. Never panics on a row's account: every problem is a `Fail` with its reason.
pub fn run_row(opts: &Opts, host: &Host, row: &Row) -> Outcome {
    if let Some(s) = skip_reason(row, host) {
        return Outcome::Skip(s.to_string());
    }
    match run_checked(opts, row) {
        Ok(()) => Outcome::Pass,
        Err(e) => Outcome::Fail(e),
    }
}

fn run_checked(opts: &Opts, row: &Row) -> Result<(), String> {
    if row.unsandboxed {
        let (fx, data) = run_direct(opts, row)?;
        return judge_run(row, &data, &fx.canaries);
    }
    if row.control {
        let (_fx, data) = run_direct(opts, row)?;
        judge_control(row, &data.lines)
            .map_err(|e| format!("{e}; stderr: {}", tail(&data.stderr)))?;
    }
    let (fx, data) = run_sandboxed(opts, row)?;
    judge_run(row, &data, &fx.canaries)
}

#[cfg(test)]
mod tests;
