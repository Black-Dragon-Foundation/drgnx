//! Starting and stopping a hub from the command line (design 3.2): `ensure` and `stop`.
//!
//! `ensure` pings; when nothing answers it starts a hub the way the platform supervises it, and waits for `ping`:
//!
//! | where | how | restarted on a crash |
//! |---|---|---|
//! | Linux with a user systemd | `systemd-run --user --unit=ratatoskr-HASH --collect -p Restart=on-failure …` | yes; 75 forced, 1 2 3 never |
//! | macOS with a `gui/UID` domain | `launchctl bootstrap` of `<state>/hub/launchd.plist` (`kickstart` when loaded) | yes; `serve --supervisor launchd` maps 1 2 3 to 0 |
//! | otherwise (`RATATOSKR_SUPERVISOR=none`, containers) | the binary starts itself detached (`setsid`), `serve --supervisor self` | no; a restart re-executes it |
//!
//! Only variable *names* go in an argv (`--setenv=NAME`), so no value, and no key, is ever in a command line.
//! Programs are the root-owned ones at fixed paths, never found through `PATH`.
//!
//! Both refuse a socket directory that is not this user's private one ([`client::trusted`]): a `/tmp` fallback
//! directory another user made first would otherwise name any of this user's processes in its lock.
//!
//! `stop` signals nothing unless the lock is really held: the lock file is probed with `flock` first, so a stale file
//! naming a live pid (a reused one) is "not running".  A held lock gets a `shutdown` over the socket; only when that
//! does not release it is SIGTERM sent, and only to the process listening on the hub's socket
//! ([`peer::listener_of`]; through a pidfd on Linux and Android) when it is the pid the lock names with the start
//! time it recorded ([`lock::signal_target`]).  Anything else is refused with "signal it yourself"; a command line or
//! an executable's path is never evidence.  A Lisp hub from before Ratatoskr (a lock directory) gets the v0
//! `shutdown`, and SIGTERM only for a pid whose command line names `drgnx-hub-main`.

use crate::client::{self, Client};
use crate::lock::{self, Holder, Procs};
use crate::peer;
use runstav::paths::{self, Env};
use serde_json::json;
use std::ffi::OsString;
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The names a supervisor passes on, each only when set (review I11): the directories (a long path would resolve
/// differently under systemd or launchd than in the editor without `TMPDIR` and `HOME`), drgnx's own, and the names the
/// backend's agents use.
pub const SUPERVISOR_ENV: &[&str] = &[
    "DRGNX_DATA_DIR",
    "DRGNX_CONFIG_DIR",
    "XDG_RUNTIME_DIR",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "HOME",
    "TMPDIR",
    "TMP",
    "TEMP",
    "DRGNX_EMACS",
    "DRGNX_DIR",
    "DRGNX_RATATOSKR_LOG",
    "SSH_AUTH_SOCK",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "CLAUDE_CONFIG_DIR",
    "TERM",
    "COLORTERM",
    "DISPLAY",
    "WAYLAND_DISPLAY",
];

/// The 8 hex digits of `hub-HASH.sock`.
pub fn hash(socket: &Path) -> String {
    socket
        .file_stem()
        .map(|s| s.to_string_lossy().trim_start_matches("hub-").to_string())
        .unwrap_or_default()
}

/// The transient systemd unit of this data dir.
pub fn unit_name(hash: &str) -> String {
    format!("ratatoskr-{hash}")
}

/// The launchd label of this data dir.
pub fn label(hash: &str) -> String {
    format!("org.blackdragonfoundation.ratatoskr.{hash}")
}

/// The names of [`SUPERVISOR_ENV`] that are set (and not empty) in ENV.
pub fn present(env: &Env) -> Vec<&'static str> {
    SUPERVISOR_ENV
        .iter()
        .copied()
        .filter(|n| env.vars.get(*n).is_some_and(|v| !v.is_empty()))
        .collect()
}

/// The arguments of `systemd-run`: names only after `--setenv=`.  Exits 1 (cannot start), 2 (usage) and 3 (another
/// hub serves) are never restarted (`Restart=on-failure` alone restarts every non-zero exit until the start limit),
/// 75 always is.
pub fn systemd_args(unit: &str, exe: &Path, names: &[&str]) -> Vec<OsString> {
    let mut a: Vec<OsString> = [
        "--user",
        &format!("--unit={unit}"),
        "--collect",
        "-p",
        "Restart=on-failure",
        "-p",
        "RestartForceExitStatus=75",
        "-p",
        "RestartPreventExitStatus=1 2 3",
        "-p",
        "KillMode=mixed",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    a.extend(
        names
            .iter()
            .map(|n| OsString::from(format!("--setenv={n}"))),
    );
    a.push(exe.into());
    a.push("serve".into());
    a
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The launchd job of this data dir.  `serve --supervisor launchd` maps its exits 1, 2 and 3 to 0 (launchd restarts
/// on every non-zero exit and cannot be told otherwise), so `KeepAlive {SuccessfulExit: false}` restarts only a crash
/// and a 75.
pub fn launchd_plist(label: &str, exe: &Path, vars: &[(String, String)], log: &Path) -> String {
    let mut env = String::new();
    for (k, v) in vars {
        env.push_str(&format!(
            "    <key>{}</key><string>{}</string>\n",
            xml(k),
            xml(v)
        ));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\">\n\
         <dict>\n\
         \x20 <key>Label</key><string>{label}</string>\n\
         \x20 <key>ProgramArguments</key>\n\
         \x20 <array>\n\
         \x20   <string>{exe}</string>\n\
         \x20   <string>serve</string>\n\
         \x20   <string>--supervisor</string>\n\
         \x20   <string>launchd</string>\n\
         \x20 </array>\n\
         \x20 <key>EnvironmentVariables</key>\n\
         \x20 <dict>\n{env}\x20 </dict>\n\
         \x20 <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n\
         \x20 <key>ProcessType</key><string>Background</string>\n\
         \x20 <key>StandardErrorPath</key><string>{log}</string>\n\
         \x20 <key>StandardOutPath</key><string>{log}</string>\n\
         </dict>\n\
         </plist>\n",
        label = xml(label),
        exe = xml(&exe.to_string_lossy()),
        log = xml(&log.to_string_lossy()),
    )
}

/// FILE replaced by TEXT atomically, mode 0600 from the start (a temporary file beside it, never a link).
pub fn write_private(file: &Path, text: &str) -> io::Result<()> {
    let mut name = file.as_os_str().to_owned();
    name.push(format!(".tmp-{}", std::process::id()));
    let tmp = PathBuf::from(name);
    let _ = std::fs::remove_file(&tmp);
    let written = (|| {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, file)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

/// `launchctl`, as far as `ensure` needs it: does a command succeed?
pub trait Launchctl {
    fn ok(&self, args: &[&str]) -> bool;
}

/// The real `/bin/launchctl`.
pub struct RealLaunchctl(pub PathBuf);

impl Launchctl for RealLaunchctl {
    fn ok(&self, args: &[&str]) -> bool {
        Command::new(&self.0)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }
}

/// What starting through launchd came to.
#[derive(Debug, PartialEq, Eq)]
pub enum Launched {
    Started,
    /// No `gui/UID` domain (an SSH session): the hub detaches itself instead.
    NoDomain,
}

/// Load the job at PLIST for LABEL in `gui/UID`: `bootstrap`, or `kickstart` when the label is already loaded (a
/// second `bootstrap` fails).  A loaded label whose plist CHANGED (a new `DRGNX_EMACS`, a new `SSH_AUTH_SOCK` after
/// logging in again) is `bootout` first and bootstrapped again: `kickstart` would run it with the old arguments and
/// environment until logout (review M8).
pub fn launchd_start(
    ctl: &dyn Launchctl,
    uid: u32,
    label: &str,
    plist: &Path,
    changed: bool,
) -> Result<Launched, String> {
    let domain = format!("gui/{uid}");
    if !ctl.ok(&["print", &domain]) {
        return Ok(Launched::NoDomain);
    }
    let target = format!("{domain}/{label}");
    let loaded = ctl.ok(&["print", &target]);
    // a failed bootout leaves it loaded: the bootstrap below then fails and says so
    if loaded && changed {
        ctl.ok(&["bootout", &target]);
    }
    let (verb, arg): (&str, String) = if loaded && !changed {
        ("kickstart", target)
    } else {
        ("bootstrap", plist.to_string_lossy().into_owned())
    };
    let first = if verb == "kickstart" {
        vec![verb, arg.as_str()]
    } else {
        vec![verb, domain.as_str(), arg.as_str()]
    };
    if ctl.ok(&first) {
        Ok(Launched::Started)
    } else {
        Err(format!("launchctl {verb} failed"))
    }
}

/// PATH when it is a file owned by root that no one else can write, in a directory the same holds for.
fn trusted(path: &Path) -> bool {
    let safe = |p: &Path| {
        std::fs::metadata(p).is_ok_and(|m| m.uid() == 0 && m.permissions().mode() & 0o022 == 0)
    };
    path.is_file() && safe(path) && path.parent().is_some_and(safe)
}

/// The first of CANDIDATES that is [`trusted`].
fn program(candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().map(PathBuf::from).find(|p| trusted(p))
}

/// How `ensure` starts a hub here.
#[derive(Debug, PartialEq, Eq)]
pub enum Mode {
    Systemd(PathBuf),
    Launchd(PathBuf),
    /// The hub detaches itself; WHY is what made it not use a supervisor (none: it was asked not to).
    SelfDetach(Option<String>),
}

/// The supervisor for ENV: `RATATOSKR_SUPERVISOR=none` is none; Linux with a user systemd (the manager's directory
/// in `XDG_RUNTIME_DIR`) is systemd; macOS is launchd (its domain is checked when it starts).
pub fn choose(env: &Env) -> Mode {
    if env.vars.get("RATATOSKR_SUPERVISOR").map(String::as_str) == Some("none") {
        return Mode::SelfDetach(None);
    }
    if cfg!(target_os = "macos") {
        return match program(&["/bin/launchctl"]) {
            Some(p) => Mode::Launchd(p),
            None => Mode::SelfDetach(Some("no /bin/launchctl".into())),
        };
    }
    // Android stance: systemd and launchd are desktop facts, so the hub detaches itself there (a service is later work).
    if cfg!(target_os = "android") {
        return Mode::SelfDetach(Some("no supervisor on Android".into()));
    }
    let manager = env
        .vars
        .get("XDG_RUNTIME_DIR")
        .filter(|r| r.starts_with('/'))
        .is_some_and(|r| Path::new(r).join("systemd").is_dir());
    if !manager {
        return Mode::SelfDetach(Some("no systemd user manager".into()));
    }
    match program(&["/usr/bin/systemd-run", "/bin/systemd-run"]) {
        Some(p) => Mode::Systemd(p),
        None => Mode::SelfDetach(Some("no root-owned systemd-run".into())),
    }
}

/// Start this binary detached from the caller: a session of its own (`setsid`), stdio on `/dev/null`, running `serve
/// --supervisor self`.  Every descriptor Rust opens is close-on-exec, so nothing else is inherited.  The child is
/// handed back so the caller can see it end early.
pub fn detach(exe: &Path) -> io::Result<std::process::Child> {
    let mut cmd = Command::new(exe);
    cmd.args(["serve", "--supervisor", "self"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: only `setsid(2)`, which is async-signal-safe, runs between fork and exec.
    unsafe {
        cmd.pre_exec(|| {
            rustix::process::setsid()
                .map(|_| ())
                .map_err(io::Error::from)
        });
    }
    cmd.spawn()
}

/// What `ensure` runs once nothing answers.  Err is the reason it could not start one.
fn start(env: &Env, socket: &Path, exe: &Path) -> Result<Option<std::process::Child>, String> {
    let h = hash(socket);
    match choose(env) {
        Mode::Systemd(prog) => {
            let args = systemd_args(&unit_name(&h), exe, &present(env));
            let out = Command::new(prog)
                .args(args)
                .stdin(Stdio::null())
                .output()
                .map_err(|e| format!("systemd-run: {e}"))?;
            let said = String::from_utf8_lossy(&out.stderr);
            // a racing `ensure` already made the unit: both then ping
            if out.status.success()
                || said.contains("already exists")
                || said.contains("already loaded")
            {
                Ok(None)
            } else {
                Err(format!("systemd-run failed: {}", said.trim()))
            }
        }
        Mode::Launchd(prog) => {
            let state = paths::state_dir(env).join("hub");
            paths::private_dir(&state).map_err(|e| e.to_string())?;
            let plist = state.join("launchd.plist");
            let vars: Vec<(String, String)> = present(env)
                .into_iter()
                .filter_map(|n| env.vars.get(n).map(|v| (n.to_string(), v.clone())))
                .collect();
            let text = launchd_plist(&label(&h), exe, &vars, &state.join("launchd.log"));
            let changed = std::fs::read_to_string(&plist).ok().as_deref() != Some(text.as_str());
            write_private(&plist, &text).map_err(|e| format!("{}: {e}", plist.display()))?;
            match launchd_start(&RealLaunchctl(prog), env.uid, &label(&h), &plist, changed)? {
                Launched::Started => Ok(None),
                Launched::NoDomain => {
                    eprintln!(
                        "ratatoskr ensure: no gui/{} launchd domain (an SSH session?): the hub detaches itself and is not restarted on a crash",
                        env.uid
                    );
                    detach(exe).map(Some).map_err(|e| e.to_string())
                }
            }
        }
        Mode::SelfDetach(why) => {
            if let Some(why) = why {
                eprintln!(
                    "ratatoskr ensure: {why}: the hub detaches itself and is not restarted on a crash"
                );
            }
            detach(exe).map(Some).map_err(|e| e.to_string())
        }
    }
}

/// The newest error the hub logged, for a wait that timed out: the last ERROR line of the newest log file.
fn log_reason(env: &Env) -> Option<(String, PathBuf)> {
    let dir = paths::state_dir(env).join("hub").join("log");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect();
    files.sort();
    let file = files.pop()?;
    let text = std::fs::read(&file).ok()?;
    let tail = &text[text.len().saturating_sub(1 << 16)..];
    let reason = String::from_utf8_lossy(tail)
        .lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find(|v| v["level"] == "ERROR")
        .and_then(|v| v["fields"]["message"].as_str().map(str::to_string));
    reason.map(|r| (r, file))
}

/// `ensure`: the exit code (0 running, 1 not started, 3 a Lisp hub serves).
pub fn ensure(env: &Env, timeout: Duration) -> i32 {
    let socket = paths::socket_path(env);
    // a socket directory that is not this user's private one: nothing there is trusted, and no hub could start there
    if let Some(why) = client::refused(&socket) {
        eprintln!("ratatoskr ensure: {why}");
        return 1;
    }
    // a Lisp hub from before Ratatoskr serves here, answering a ping or not: said as `serve` says it (review M1)
    let lock_path = paths::lock_path(&socket);
    if let Some((pid, lock::LispLock::Respect)) = lock::lisp_dir(&lock_path, &lock::System) {
        eprintln!(
            "ratatoskr ensure: {} (pid {})",
            lock::LISP_HUB_SERVES,
            pid.map_or_else(|| "unknown".to_string(), |p| p.to_string())
        );
        return 3;
    }
    if client::ping(&socket, Duration::from_secs(1)).is_some() {
        println!("{}", socket.display());
        return 0;
    }
    let exe = match crate::idle::resolve_exe() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("ratatoskr ensure: cannot find its own path: {e}");
            return 1;
        }
    };
    let mut child = match start(env, &socket, exe) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ratatoskr ensure: cannot start a hub: {e}");
            return 1;
        }
    };
    let deadline = Instant::now() + timeout;
    let mut ended = None;
    loop {
        if client::ping(&socket, Duration::from_secs(1)).is_some() {
            println!("{}", socket.display());
            return 0;
        }
        // a hub that ended early (cannot start; or it lost a race to another `ensure`, whose hub then answers)
        if ended.is_none()
            && let Some(c) = child.as_mut()
            && let Ok(Some(status)) = c.try_wait()
        {
            ended = Some(status);
        }
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let why = match (log_reason(env), ended) {
        (Some((r, file)), _) => format!("{r} (log: {})", file.display()),
        (None, Some(s)) => format!(
            "the hub ended with {s} (log: {}/hub/log)",
            paths::state_dir(env).display()
        ),
        (None, None) => format!(
            "no answer on {} (log: {}/hub/log)",
            socket.display(),
            paths::state_dir(env).display()
        ),
    };
    eprintln!(
        "ratatoskr ensure: the hub did not answer within {} s: {why}",
        timeout.as_secs()
    );
    1
}

/// Wait up to WITHIN for the lock at PATH to be released (nobody holds it any more).
fn wait_released(path: &Path, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    loop {
        match lock::holder(path, &lock::System) {
            Ok(Holder::Ratatoskr { .. }) => {}
            _ => return true,
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Wait up to WITHIN for the Lisp lock directory at PATH to be gone.
fn wait_gone(path: &Path, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while std::fs::symlink_metadata(path).is_ok() {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

fn term(pid: u32) {
    if let Ok(p) = i32::try_from(pid)
        && p > 1
    {
        // SAFETY: a plain kill(2) of one positive pid that the caller has checked is ours to stop
        unsafe { libc::kill(p, libc::SIGTERM) };
    }
}

fn start_time_of(pid: u32) -> Option<u64> {
    i32::try_from(pid)
        .ok()
        .and_then(|p| draugr::start_time(p).ok())
}

/// `stop`: the exit code (0 stopped or not running, 1 it would not stop).
pub fn stop(env: &Env, timeout: Duration) -> i32 {
    let socket = paths::socket_path(env);
    let lock_path = paths::lock_path(&socket);
    match lock::holder(&lock_path, &lock::System) {
        // a refused directory says why itself
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            eprintln!("ratatoskr stop: {e}");
            1
        }
        Err(e) => {
            eprintln!(
                "ratatoskr stop: cannot look at {}: {e}",
                lock_path.display()
            );
            1
        }
        // nothing holds it: no signal at all, whatever pid a stale file names
        Ok(Holder::Nobody) => {
            println!("not running");
            0
        }
        Ok(Holder::Lisp { pid }) => stop_lisp(&socket, &lock_path, pid, timeout),
        Ok(Holder::Ratatoskr { pid, start }) => {
            stop_ratatoskr(&socket, &lock_path, pid, start, timeout)
        }
    }
}

fn named(pid: Option<u32>) -> String {
    pid.map_or_else(String::new, |p| format!(" (pid {p})"))
}

fn stop_ratatoskr(
    socket: &Path,
    lock_path: &Path,
    pid: Option<u32>,
    start: Option<u64>,
    timeout: Duration,
) -> i32 {
    let asked = Client::user_at(socket, Duration::from_secs(5))
        .and_then(|mut c| c.call("shutdown", json!({}), Duration::from_secs(5)));
    if let Err(e) = asked {
        eprintln!("ratatoskr stop: the hub did not take a shutdown ({e})");
    }
    if wait_released(lock_path, timeout) {
        println!("stopped Ratatoskr{}", named(pid));
        return 0;
    }
    // the target is the process listening on the socket, never what the lock's text or a command line names
    let signalled = peer::listener_of(socket).and_then(|listener| {
        let p = lock::signal_target(pid, start, &listener, start_time_of)?;
        listener
            .terminate()
            .map(|()| p)
            .map_err(|e| format!("SIGTERM to pid {p} failed ({e})"))
    });
    match signalled {
        Ok(p) => {
            if wait_released(lock_path, timeout) {
                println!("stopped Ratatoskr (pid {p}, by SIGTERM)");
                0
            } else {
                eprintln!(
                    "ratatoskr stop: pid {p} did not stop within {} s",
                    timeout.as_secs()
                );
                1
            }
        }
        Err(why) => {
            eprintln!(
                "ratatoskr stop: the hub did not stop and {why}; signal it yourself{}",
                pid.map_or_else(String::new, |p| format!(": pid {p}"))
            );
            1
        }
    }
}

fn stop_lisp(socket: &Path, lock_dir: &Path, pid: Option<u32>, timeout: Duration) -> i32 {
    // a Lisp hub serves a v0 `shutdown` without a hello
    client::v0_call(socket, "shutdown");
    if wait_gone(lock_dir, timeout) {
        println!("stopped the Lisp hub{}", named(pid));
        return 0;
    }
    // it stays: SIGTERM only a live process whose command line names the hub
    let current = lock::lisp_dir(lock_dir, &lock::System)
        .and_then(|(p, _)| p)
        .or(pid);
    match current {
        Some(p) if lock::alive(p) && lock::System.is_lisp_hub(p) => {
            term(p);
            if wait_gone(lock_dir, timeout) {
                println!("stopped the Lisp hub (pid {p}, by SIGTERM)");
                0
            } else {
                eprintln!(
                    "ratatoskr stop: the Lisp hub (pid {p}) did not stop within {} s",
                    timeout.as_secs()
                );
                1
            }
        }
        Some(p) => {
            let what = if lock::alive(p) {
                "is not a drgnx hub"
            } else {
                "is gone"
            };
            eprintln!(
                "ratatoskr stop: the lock names pid {p}, which {what}: remove {}",
                lock_dir.display()
            );
            1
        }
        None => {
            eprintln!(
                "ratatoskr stop: the lock names no process: remove {}",
                lock_dir.display()
            );
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn env(vars: &[(&str, &str)]) -> Env {
        Env::new(vars, 1000)
    }

    fn after_setenv(args: &[OsString]) -> Vec<String> {
        args.iter()
            .filter_map(|a| a.to_str()?.strip_prefix("--setenv=").map(str::to_string))
            .collect()
    }

    #[test]
    fn systemd_run_argv_has_no_values() {
        // a data dir with `$HOME` and a space in it: A-42's class
        let e = env(&[
            ("DRGNX_DATA_DIR", "/srv/u/my data/$HOME/x"),
            ("HOME", "/srv/u"),
            ("TMPDIR", "/tmp/a b"),
            ("SSH_AUTH_SOCK", "/run/user/1000/ssh-agent.socket"),
        ]);
        let args = systemd_args(
            "ratatoskr-abcd1234",
            Path::new("/opt/r/ratatoskr"),
            &present(&e),
        );
        for n in after_setenv(&args) {
            assert!(
                !n.contains('=') && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
                "{n} is a name"
            );
        }
        for a in &args {
            let a = a.to_str().unwrap();
            assert!(
                !a.contains("my data")
                    && !a.contains("$HOME")
                    && !a.contains("ssh-agent")
                    && !a.contains("/tmp/a b"),
                "a value in argv: {a}"
            );
        }
        assert_eq!(args.last().unwrap(), "serve");
        assert_eq!(args[args.len() - 2], "/opt/r/ratatoskr");
    }

    #[test]
    fn systemd_run_argv_passes_tmpdir_and_home() {
        let e = env(&[("HOME", "/srv/u"), ("TMPDIR", "/tmp/x")]);
        let names = after_setenv(&systemd_args("u", Path::new("/r"), &present(&e)));
        assert_eq!(names, vec!["HOME", "TMPDIR"]);
        // a name that is not set is not passed
        let none = after_setenv(&systemd_args("u", Path::new("/r"), &present(&env(&[]))));
        assert!(none.is_empty());
        // an empty value is not set either
        assert!(present(&env(&[("HOME", "")])).is_empty());
    }

    #[test]
    fn every_supervisor_name_the_plan_lists_is_passed() {
        for n in [
            "DRGNX_DATA_DIR",
            "DRGNX_CONFIG_DIR",
            "XDG_RUNTIME_DIR",
            "XDG_STATE_HOME",
            "XDG_DATA_HOME",
            "XDG_CONFIG_HOME",
            "XDG_CACHE_HOME",
            "HOME",
            "TMPDIR",
            "TMP",
            "TEMP",
            "DRGNX_EMACS",
            "DRGNX_DIR",
            "DRGNX_RATATOSKR_LOG",
            "SSH_AUTH_SOCK",
            "CLAUDE_CONFIG_DIR",
            "TERM",
            "COLORTERM",
            "DISPLAY",
            "WAYLAND_DISPLAY",
        ] {
            assert!(SUPERVISOR_ENV.contains(&n), "{n}");
        }
        // no provider key is ever passed on
        assert!(SUPERVISOR_ENV.iter().all(|n| !n.contains("KEY")));
    }

    #[test]
    fn systemd_argv_prevents_restart_on_1_2_3() {
        let args: Vec<String> = systemd_args("u", Path::new("/r"), &[])
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(
            args.contains(&"RestartPreventExitStatus=1 2 3".to_string()),
            "{args:?}"
        );
        assert!(
            args.contains(&"RestartForceExitStatus=75".to_string()),
            "{args:?}"
        );
        assert!(args.contains(&"Restart=on-failure".to_string()));
        assert!(args.contains(&"KillMode=mixed".to_string()));
        assert!(args.contains(&"--unit=u".to_string()));
    }

    #[test]
    fn launchd_plist_is_0600_and_names_the_label() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("launchd.plist");
        let label = label("abcd1234");
        assert_eq!(label, "org.blackdragonfoundation.ratatoskr.abcd1234");
        let text = launchd_plist(
            &label,
            Path::new("/opt/r/ratatoskr"),
            &[("HOME".into(), "/srv/u & <x>".into())],
            Path::new("/s/launchd.log"),
        );
        write_private(&file, &text).unwrap();
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let got = std::fs::read_to_string(&file).unwrap();
        assert!(
            got.contains(&format!("<key>Label</key><string>{label}</string>")),
            "{got}"
        );
        assert!(got.contains("<key>SuccessfulExit</key><false/>"));
        assert!(got.contains("<string>Background</string>"));
        // values are escaped
        assert!(got.contains("/srv/u &amp; &lt;x&gt;"), "{got}");
        // no temporary file is left
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn launchd_plist_never_loops_on_exit_3() {
        let text = launchd_plist("l", Path::new("/r"), &[], Path::new("/log"));
        let args: Vec<&str> = text
            .split("<array>")
            .nth(1)
            .unwrap()
            .split("</array>")
            .next()
            .unwrap()
            .split("<string>")
            .skip(1)
            .map(|s| s.split("</string>").next().unwrap())
            .collect();
        assert_eq!(args, vec!["/r", "serve", "--supervisor", "launchd"]);
    }

    /// A `launchctl` that records its arguments and says which `print`s succeed.
    struct Stub {
        calls: RefCell<Vec<Vec<String>>>,
        loaded: bool,
        domain: bool,
    }

    impl Launchctl for Stub {
        fn ok(&self, args: &[&str]) -> bool {
            self.calls
                .borrow_mut()
                .push(args.iter().map(|a| a.to_string()).collect());
            match args {
                ["print", target] if target.matches('/').count() == 2 => self.loaded,
                ["print", _] => self.domain,
                _ => true,
            }
        }
    }

    #[test]
    fn a_loaded_label_is_kickstarted_not_bootstrapped() {
        let stub = Stub {
            calls: RefCell::new(vec![]),
            loaded: true,
            domain: true,
        };
        let r = launchd_start(&stub, 501, "L", Path::new("/p.plist"), false);
        assert_eq!(r, Ok(Launched::Started));
        let calls = stub.calls.borrow();
        assert!(
            calls
                .iter()
                .any(|c| c[0] == "kickstart" && c[1] == "gui/501/L"),
            "{calls:?}"
        );
        assert!(calls.iter().all(|c| c[0] != "bootstrap"), "{calls:?}");
        // loaded, but its plist changed: out and in again, never kickstarted with the old one
        let stub = Stub {
            calls: RefCell::new(vec![]),
            loaded: true,
            domain: true,
        };
        assert_eq!(
            launchd_start(&stub, 501, "L", Path::new("/p.plist"), true),
            Ok(Launched::Started)
        );
        let calls = stub.calls.borrow();
        let at = |verb: &str| calls.iter().position(|c| c[0] == verb);
        assert!(
            at("bootout").is_some_and(|b| calls[b] == ["bootout", "gui/501/L"]),
            "{calls:?}"
        );
        assert!(at("bootout") < at("bootstrap"), "{calls:?}");
        assert!(at("kickstart").is_none(), "{calls:?}");
        // not loaded: bootstrap into the domain with the plist
        let stub = Stub {
            calls: RefCell::new(vec![]),
            loaded: false,
            domain: true,
        };
        assert_eq!(
            launchd_start(&stub, 501, "L", Path::new("/p.plist"), true),
            Ok(Launched::Started)
        );
        let calls = stub.calls.borrow();
        assert!(
            calls
                .iter()
                .any(|c| c == &["bootstrap", "gui/501", "/p.plist"]),
            "{calls:?}"
        );
        // no gui domain (ssh): nothing is loaded, the caller detaches
        let stub = Stub {
            calls: RefCell::new(vec![]),
            loaded: false,
            domain: false,
        };
        assert_eq!(
            launchd_start(&stub, 501, "L", Path::new("/p"), true),
            Ok(Launched::NoDomain)
        );
        assert!(stub.calls.borrow().iter().all(|c| c[0] == "print"));
    }

    #[test]
    fn the_hash_is_the_sockets_and_none_means_no_supervisor() {
        assert_eq!(
            hash(Path::new("/run/u/drgnx/hub-0a1b2c3d.sock")),
            "0a1b2c3d"
        );
        assert_eq!(unit_name("0a1b2c3d"), "ratatoskr-0a1b2c3d");
        assert_eq!(
            choose(&env(&[("RATATOSKR_SUPERVISOR", "none")])),
            Mode::SelfDetach(None)
        );
    }
}
