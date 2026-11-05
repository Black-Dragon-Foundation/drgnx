//! The doctor's smoke run (docs/guide/agent-browser.md, "The doctor's lines"): a throwaway session with the browser
//! (sid `check-<8 hex>`, command `sleep 60`) in which the hub connects to its own broker with the session's secret,
//! opens `data:text/html,<p>drgnx`, takes a screenshot and stops.  `ratatoskr doctor --json` runs on a 2 s deadline, so
//! the run is the hub method `browser/check`; its answer is kept in `<state>/hub/browser-check.json`, which the doctor
//! reads ([`read`]).
//!
//! The session is the real thing: the same shape as an agent's (`sandbox::browser_for`, so it reports the reasons a
//! session would get), the same launch and the same broker.  It differs in two things: its gate allows (no card is
//! raised for a check), and the broker passes the browser's stderr lines on, where one naming `/sys/` is a read the
//! layer refuses (`sys_missed`).  The whole run has a deadline of [`DEADLINE`]; whatever it started is gone after it.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use fastwebsockets::{FragmentCollector, Frame, OpCode, Payload, Role, WebSocket};
use norn::matrix::{Verdict, Who};
use runstav::paths::{self, Env};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::agents::launch;
use crate::agents::lock::{Enforced, LaunchPlan};
use crate::agents::net::{BrowserHub, CheckHooks, SessionNet, pins, start_browser_with};
use crate::front::Front;
use crate::matrix_gate::Gate;

pub use runstav::methods::hub::BrowserCheckResult as CheckResult;

/// The whole run, from the first step to the last.
pub const DEADLINE: Duration = Duration::from_secs(45);
/// A downloaded browser older than this many days warns (the doctor's `age_warning`).
pub const AGE_WARN_DAYS: u64 = 28;
/// How long one reply from the browser may take once it runs.
const STEP: Duration = Duration::from_secs(20);

/// `<state>/hub/browser-check.json`.
pub fn result_path(env: &Env) -> PathBuf {
    paths::state_dir(env).join("hub").join("browser-check.json")
}

/// Keep RESULT where the doctor reads it (a private file, written whole or not at all).
pub fn write(env: &Env, result: &CheckResult) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let path = result_path(env);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(result)?)?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    std::fs::rename(&tmp, &path)
}

/// The last result, when there is one and it reads.
pub fn read(env: &Env) -> Option<CheckResult> {
    serde_json::from_slice(&std::fs::read(result_path(env)).ok()?).ok()
}

fn failed(browser: Option<Value>, why: String) -> CheckResult {
    CheckResult {
        ok: false,
        browser,
        start_ms: 0,
        peak_bytes: None,
        sys_missed: false,
        screenshot_bytes: 0,
        why: Some(why),
        at: crate::log::rfc3339(now()),
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// The size in bytes of what BASE64 (standard alphabet, padded) holds.
fn decoded_len(base64: &str) -> u64 {
    let pad = base64.bytes().rev().take_while(|b| *b == b'=').count();
    (base64.len() as u64 / 4 * 3).saturating_sub(pad as u64)
}

/// Whether a browser stderr line names a path under `/sys/`.
fn names_sys(line: &str) -> bool {
    line.contains("/sys/")
}

/// Run the check, keep its result for the doctor and answer it.  Never fails: a check that could not run is a result
/// with `ok: false` and `why`.
pub async fn run(front: &Front) -> CheckResult {
    let started = Instant::now();
    let mut pid = None;
    let mut browser = None;
    let outcome = tokio::time::timeout(DEADLINE, attempt(front, &mut pid, &mut browser)).await;
    if let Some(pid) = pid {
        draugr::kill_group(pid, Duration::ZERO, &draugr::RealSignaller).await;
    }
    let result = match outcome {
        Ok(Ok(r)) => r,
        Ok(Err(why)) => failed(browser, why),
        Err(_) => failed(
            browser,
            format!(
                "the check did not finish within {} s",
                started.elapsed().as_secs()
            ),
        ),
    };
    let env = Env::process();
    if let Err(e) = write(&env, &result) {
        tracing::warn!("the browser check's result was not kept: {e}");
    }
    result
}

/// The steps; PID is the sandbox's process group once it runs, and BROWSER the program found, both for [`run`] to
/// report and to clean up after.
async fn attempt(
    front: &Front,
    pid: &mut Option<i32>,
    browser: &mut Option<Value>,
) -> Result<CheckResult, String> {
    let cur = front.settings.current();
    let v = cur.loaded.values.clone();
    let data = paths::data_dir(&Env::process());
    let found = tokio::task::spawn_blocking(move || {
        crate::browser::resolve::resolve(&cur.loaded.values, &data)
    })
    .await
    .map_err(|e| format!("the browser lookup failed: {e}"))?;
    *browser = found.as_ref().ok().map(|f| json!(f));
    let backend = launch::detect().await.ok().map(|s| s.kind());
    let secret = crate::browser::Secret::new().map_err(|e| format!("no random bytes: {e}"))?;
    let shape = crate::sandbox::browser_for(
        Verdict::Allow,
        backend,
        landlock_abi(),
        found,
        v.agents_browser_local_ports.clone(),
        v.agents_browser_max_message,
        secret.clone(),
    )
    .map_err(|n| format!("{}; fix: {}", n.why, n.fix))?
    .ok_or("the browser is not available")?;

    let env = front.shell_env.paths_env();
    let sid = format!("check-{}", &secret.hex()[..8]);
    let dir = paths::make_session_dir(&env, &paths::socket_path(&env), &sid)
        .map_err(|e| format!("the check's session directory: {e}"))?;
    let result = session(front, &env, &sid, &dir, shape, secret, pid).await;
    let _ = std::fs::remove_dir_all(&dir);
    if let Ok(scratch) = launch::scratch_dir(&env, &sid) {
        let _ = std::fs::remove_dir_all(scratch);
    }
    result.map(|mut r| {
        r.browser = browser.clone();
        r
    })
}

/// The kernel's Landlock ABI; a `test-hooks` build reads `DRGNX_TEST_BROWSER_CHECK_ABI` instead.
fn landlock_abi() -> u8 {
    #[cfg(feature = "test-hooks")]
    if let Some(n) = std::env::var("DRGNX_TEST_BROWSER_CHECK_ABI")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        return n;
    }
    gleipnir::landlock::kernel_abi()
}

async fn session(
    front: &Front,
    env: &Env,
    sid: &str,
    dir: &std::path::Path,
    shape: crate::sandbox::BrowserShape,
    secret: crate::browser::Secret,
    pid: &mut Option<i32>,
) -> Result<CheckResult, String> {
    let plan = LaunchPlan {
        argv: vec!["sleep".into(), "60".into()],
        env: Vec::new(),
        session_meta: None,
        protected_ro: Vec::new(),
        login_dir: None,
        enforced: Enforced::No("the browser check"),
        gateway: false,
        trace: None,
    };
    let pinned = pins(&front.settings.current().loaded.values);
    let mut net = SessionNet::start(dir, sid, Vec::new(), pinned, None)
        .map_err(|e| format!("the check's network: {e}"))?;
    let launched = launch::spawn_plain(env, &plan, sid, Some(shape))
        .await
        .map_err(|r| format!("the sandbox refused the launch: {}", r.message))?;
    let hub = launched
        .browser
        .ok_or("the launch made no browser socketpair")?;
    let (stderr_tx, mut stderr_rx) = mpsc::unbounded_channel();
    let hooks = CheckHooks {
        gate: Arc::new(|| Box::pin(async { Gate::Allow }) as mimir::BoxFuture<'static, Gate>),
        stderr: stderr_tx,
    };
    let unit = crate::exec::unit::systemd_user().then(|| crate::exec::unit::session_unit_name(sid));
    let mut spec = launched.spec;
    if unit.is_some() {
        let memory = front
            .settings
            .current()
            .loaded
            .values
            .agents_session_memory
            .clone();
        spec = crate::exec::unit::session_scope(spec, sid, &memory);
    }
    start_browser_with(
        front,
        &mut net,
        sid,
        Who::default(),
        BrowserHub {
            hub,
            secret: secret.clone(),
            unit: None,
            held: None,
        },
        Some(hooks),
    )
    .await
    .map_err(|e| format!("the check's browser: {e}"))?;
    let child = draugr::spawn(spec)
        .await
        .map_err(|e| format!("the sandbox did not start: {e}"))?;
    *pid = Some(child.id());
    if let Some(fd) = launched.status {
        let stderr = child.stderr();
        let read = tokio::task::spawn_blocking(move || {
            gleipnir::inner::read_status_for(fd, &|| stderr.get(), Duration::from_secs(20), true)
        })
        .await
        .map_err(|e| format!("reading the sandbox status: {e}"))?;
        read.map_err(|e| format!("the sandbox did not start: {}", e.message))?;
    }
    let (start_ms, screenshot) = screenshot(&dir.join(paths::SESSION_CDP_SOCKET), &secret).await?;
    let peak_bytes = match &unit {
        Some(u) => peak(u).await,
        None => None,
    };
    drop(net);
    let mut sys_missed = false;
    while let Ok(line) = stderr_rx.try_recv() {
        sys_missed |= names_sys(&line);
    }
    Ok(CheckResult {
        ok: screenshot > 0,
        browser: None,
        start_ms,
        peak_bytes,
        sys_missed,
        screenshot_bytes: screenshot,
        why: (screenshot == 0).then(|| "the screenshot was empty".to_owned()),
        at: crate::log::rfc3339(now()),
    })
}

/// The scope's peak memory, when its manager says (`systemctl --user show -P MemoryPeak`, within 2 s).
async fn peak(unit: &str) -> Option<u64> {
    let out = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::process::Command::new("systemctl")
            .args(["--user", "show", "-P", "MemoryPeak", unit])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

/// The hub as the agent: connect to SOCK with SECRET, open the page, take the screenshot.  Answers the time from the
/// connect to the page's target and the screenshot's size.
async fn screenshot(
    sock: &std::path::Path,
    secret: &crate::browser::Secret,
) -> Result<(u64, u64), String> {
    let t0 = Instant::now();
    let mut s = UnixStream::connect(sock)
        .await
        .map_err(|e| format!("the broker's socket: {e}"))?;
    let head = format!(
        "GET {}{} HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        crate::browser::broker::PATH_PREFIX,
        secret.hex()
    );
    s.write_all(head.as_bytes())
        .await
        .map_err(|e| format!("the broker: {e}"))?;
    let mut got = Vec::new();
    while !got.ends_with(b"\r\n\r\n") {
        let mut b = [0u8; 1];
        let n = tokio::time::timeout(STEP, s.read(&mut b))
            .await
            .map_err(|_| "the broker did not answer".to_owned())?
            .map_err(|e| format!("the broker: {e}"))?;
        if n == 0 || got.len() > 8192 {
            return Err("the broker closed the connection".into());
        }
        got.push(b[0]);
    }
    let text = String::from_utf8_lossy(&got).into_owned();
    if text.split(' ').nth(1) != Some("101") {
        return Err(format!(
            "the broker refused the check: {}",
            text.lines().next().unwrap_or("")
        ));
    }
    let mut ws = FragmentCollector::new(WebSocket::after_handshake(s, Role::Client));
    let target = call(
        &mut ws,
        1,
        "Target.createTarget",
        json!({"url": "data:text/html,<p>drgnx"}),
        None,
    )
    .await?;
    let start_ms = u64::try_from(t0.elapsed().as_millis()).unwrap_or(u64::MAX);
    let target_id = target["targetId"].as_str().ok_or("no target id")?;
    let attached = call(
        &mut ws,
        2,
        "Target.attachToTarget",
        json!({"targetId": target_id, "flatten": true}),
        None,
    )
    .await?;
    let session = attached["sessionId"].as_str().ok_or("no session id")?;
    let shot = call(
        &mut ws,
        3,
        "Page.captureScreenshot",
        json!({}),
        Some(session),
    )
    .await?;
    let bytes = decoded_len(shot["data"].as_str().unwrap_or(""));
    let _ = ws.write_frame(Frame::close(1000, b"done")).await;
    Ok((start_ms, bytes))
}

/// One CDP command, and its `result` (events and other replies are skipped).
async fn call(
    ws: &mut FragmentCollector<UnixStream>,
    id: u64,
    method: &str,
    params: Value,
    session: Option<&str>,
) -> Result<Value, String> {
    let mut msg = json!({"id": id, "method": method, "params": params});
    if let Some(s) = session {
        msg["sessionId"] = json!(s);
    }
    ws.write_frame(Frame::text(Payload::Owned(msg.to_string().into_bytes())))
        .await
        .map_err(|e| format!("{method}: {e}"))?;
    let deadline = Instant::now() + STEP;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let f = tokio::time::timeout(left, ws.read_frame())
            .await
            .map_err(|_| format!("{method}: no answer within {} s", STEP.as_secs()))?
            .map_err(|e| format!("{method}: {e}"))?;
        match f.opcode {
            OpCode::Close => {
                let why = String::from_utf8_lossy(f.payload.get(2..).unwrap_or(&[])).into_owned();
                return Err(format!("{method}: the broker closed the connection: {why}"));
            }
            OpCode::Text | OpCode::Binary => {
                let Ok(v) = serde_json::from_slice::<Value>(&f.payload) else {
                    continue;
                };
                if v["id"] == id {
                    if let Some(e) = v.get("error") {
                        return Err(format!(
                            "{method}: {}",
                            e["message"].as_str().unwrap_or("failed")
                        ));
                    }
                    return Ok(v["result"].clone());
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(dir: &std::path::Path) -> Env {
        Env::new(
            &[
                ("XDG_STATE_HOME", dir.to_str().unwrap()),
                ("HOME", dir.to_str().unwrap()),
            ],
            1000,
        )
    }

    #[test]
    fn result_is_cached_and_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let env = env(dir.path());
        assert!(read(&env).is_none());
        let r = CheckResult {
            ok: true,
            browser: Some(json!({"path": "/usr/bin/x", "kind": "headless-shell"})),
            start_ms: 812,
            peak_bytes: Some(123_456_789),
            sys_missed: false,
            screenshot_bytes: 2048,
            why: None,
            at: "2026-11-04T10:00:00Z".into(),
        };
        write(&env, &r).unwrap();
        assert_eq!(read(&env), Some(r.clone()));
        // a newer result replaces it; a file that does not parse is no result
        let failed = failed(None, "no browser".into());
        write(&env, &failed).unwrap();
        assert_eq!(read(&env).unwrap().why.as_deref(), Some("no browser"));
        std::fs::write(result_path(&env), b"{").unwrap();
        assert!(read(&env).is_none());
    }

    #[test]
    fn screenshot_size_and_sys_lines() {
        assert_eq!(decoded_len(""), 0);
        assert_eq!(decoded_len("QUJD"), 3);
        assert_eq!(decoded_len("QUI="), 2);
        assert_eq!(decoded_len("QQ=="), 1);
        assert!(names_sys(
            "Failed to open /sys/devices/system/cpu: Permission denied"
        ));
        assert!(!names_sys("fake-chromium: up"));
    }
}
