//! Gleipnir as Ratatoskr uses it (docs/develop/gleipnir.md, "Using it"): the [`context`] of paths no spec may
//! touch, the inner [`helper`] (this binary), [`to_draugr`] for the spawn, and, with the `test-hooks` feature,
//! `sandbox run` ([`run`]) for the escape rows. Nothing here runs a job yet (phase 6), and nothing is called
//! sandboxed.

use crate::cli::SandboxCheckArgs;
use draugr::PassFd;
use gleipnir::check::{Check, Ran};
use gleipnir::{Context, InnerCommand, Invocation, Prepared, Refusal, Rule, Tier};
use runstav::paths::{self, Env};
use std::ffi::{CStr, OsStr, OsString};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Environment names never passed into a sandbox beside `gleipnir::BASE_ENV_DENY`: drgnx's own dirs, the agent's
/// identity and the hub's socket and pid.
pub const ENV_DENY: &[&str] = &[
    "DRGNX_DATA_DIR",
    "DRGNX_CONFIG_DIR",
    "DRGNX_AGENT",
    "DRGNX_HUB_SERVE_SOCKET",
    "DRGNX_HUB_PARENT_PID",
];

/// What no spec may expose, for the hub `env` describes, as true names (GL-T2-2):
/// - closed: drgnx's data, config and state dirs; every socket dir a hub may use (`<runtime>/drgnx`, `<state>/hub`,
///   `<tmp>/drgnx-hub-UID`); `DRGNX_DIR` (the checkout); Emacs's server dirs (`<tmp>/emacsUID`, `/tmp/emacsUID`,
///   `<runtime>/emacs`); and this binary's own dir (review M12), so no write bind can replace the helper;
/// - `user_sockets`: `SSH_AUTH_SOCK` and the D-Bus session bus's `unix:path=`;
/// - `run_parents`: `<socket dir>/s`, where session dirs are made;
/// - `program_dirs`: the absolute `PATH` entries (a relative one names no fixed place and is left out; Task 2);
/// - `env_deny`: [`ENV_DENY`].
///
/// Each path is taken to its true name on disk: a link is resolved, and a path that does not exist keeps the true
/// name of its deepest existing ancestor. One that cannot be named (not UTF-8, not absolute, a dangling link) is left
/// out. `open_inside_closed` stays empty: a job's own dir is phase 6's.
pub fn context(env: &Env) -> Context {
    let exe = idle_exe();
    context_for(env, exe.as_deref())
}

fn idle_exe() -> Option<PathBuf> {
    crate::idle::resolve_exe().ok().map(Path::to_path_buf)
}

/// [`context`] for a helper at `helper` (`None`: none known; nothing more is closed).
pub fn context_for(env: &Env, helper: Option<&Path>) -> Context {
    let var = |name: &str| {
        env.vars
            .get(name)
            .filter(|v| v.starts_with('/'))
            .map(PathBuf::from)
    };
    let tmp = ["TMPDIR", "TMP", "TEMP"]
        .iter()
        .find_map(|n| env.vars.get(*n).filter(|v| !v.is_empty()))
        .filter(|v| v.starts_with('/'))
        .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    let uid = env.uid;
    let state = paths::state_dir(env);
    let socket = paths::socket_path(env);
    let socket_dir = socket.parent().unwrap_or(Path::new("/")).to_path_buf();
    let runtime = var("XDG_RUNTIME_DIR");
    let mut closed = vec![
        paths::data_dir(env),
        paths::config_dir(env),
        state.clone(),
        state.join("hub"),
        socket_dir.clone(),
        tmp.join(format!("drgnx-hub-{uid}")),
        tmp.join(format!("emacs{uid}")),
        PathBuf::from(format!("/tmp/emacs{uid}")),
    ];
    closed.extend(
        runtime
            .iter()
            .flat_map(|r| [r.join("drgnx"), r.join("emacs")]),
    );
    closed.extend(var("DRGNX_DIR"));
    closed.extend(helper.and_then(Path::parent).map(Path::to_path_buf));
    let mut user_sockets: Vec<PathBuf> = var("SSH_AUTH_SOCK").into_iter().collect();
    if let Some(bus) = env.vars.get("DBUS_SESSION_BUS_ADDRESS") {
        user_sockets.extend(dbus_paths(bus, runtime.as_deref()));
    }
    let program_dirs = env
        .vars
        .get("PATH")
        .map(|p| p.split(':').map(PathBuf::from).collect::<Vec<_>>())
        .unwrap_or_default();
    let home = var("HOME")
        .or_else(|| passwd_home(uid))
        .unwrap_or_else(|| PathBuf::from("/"));
    Context {
        home: true_name(&home).unwrap_or_else(|| PathBuf::from("/")),
        closed: true_names(closed),
        open_inside_closed: vec![],
        user_sockets: true_names(user_sockets),
        run_parents: true_names([socket_dir.join("s")]),
        program_dirs: true_names(program_dirs),
        env_deny: ENV_DENY.iter().map(|s| s.to_string()).collect(),
    }
}

fn true_names(paths: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = paths.into_iter().filter_map(|p| true_name(&p)).collect();
    out.sort();
    out.dedup();
    out
}

/// `p`'s true name: absolute and UTF-8, each existing component resolved as the kernel would (a link to its
/// target, `..` to the true parent), and the part that does not exist kept as written (`.` and `//` dropped, `..`
/// taken lexically: a missing dir cannot be a link). `None` for a relative or non-UTF-8 path or a dangling link.
pub fn true_name(p: &Path) -> Option<PathBuf> {
    p.to_str()?;
    if !p.is_absolute() {
        return None;
    }
    let mut out = PathBuf::from("/");
    let mut missing = false;
    for c in p.components() {
        match c {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(name) => {
                out.push(name);
                if !missing {
                    match std::fs::symlink_metadata(&out) {
                        Ok(_) => out = std::fs::canonicalize(&out).ok()?,
                        Err(_) => missing = true,
                    }
                }
            }
            Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// The socket paths of a D-Bus address list: each `unix:` address's `path=` (with `%XX` unescaped), and
/// `runtime=yes`'s `<runtime>/bus`. Abstract and TCP addresses name no file.
fn dbus_paths(address: &str, runtime: Option<&Path>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for addr in address.split(';') {
        let Some(kvs) = addr.strip_prefix("unix:") else {
            continue;
        };
        for kv in kvs.split(',') {
            match kv.split_once('=') {
                Some(("path", v)) => out.push(PathBuf::from(OsStr::from_bytes(&unescape(v)))),
                Some(("runtime", "yes")) => out.extend(runtime.map(|r| r.join("bus"))),
                _ => {}
            }
        }
    }
    out
}

/// D-Bus's `%XX` escapes.
fn unescape(v: &str) -> Vec<u8> {
    let b = v.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = b
            .get(i + 1..i + 3)
            .and_then(|h| std::str::from_utf8(h).ok());
        match (b[i], hex.and_then(|h| u8::from_str_radix(h, 16).ok())) {
            (b'%', Some(byte)) => {
                out.push(byte);
                i += 3;
            }
            (c, _) => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// The home in the password database, for a process without `HOME`.
fn passwd_home(uid: u32) -> Option<PathBuf> {
    let mut buf = vec![0 as libc::c_char; 16 * 1024];
    // SAFETY: an all-zero passwd is a valid value to be overwritten; getpwuid_r writes only into `pw` and `buf`.
    let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is to a live local of the stated size.
    let r = unsafe { libc::getpwuid_r(uid, &mut pw, buf.as_mut_ptr(), buf.len(), &mut found) };
    if r != 0 || found.is_null() || pw.pw_dir.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r succeeded, so pw_dir points to a NUL-terminated string inside `buf`.
    let dir = unsafe { CStr::from_ptr(pw.pw_dir) };
    Some(PathBuf::from(OsStr::from_bytes(dir.to_bytes()))).filter(|p| p.is_absolute())
}

/// This binary as the inner helper: `sandbox-inner` inside, `relay` for the relay. The path is the one resolved at
/// start (`idle::resolve_exe`), which a later update on disk does not change.
pub fn helper() -> io::Result<InnerCommand> {
    Ok(helper_at(crate::idle::resolve_exe()?))
}

/// [`helper`] for the binary at `exe`.
pub fn helper_at(exe: &Path) -> InnerCommand {
    InnerCommand {
        source: exe.to_path_buf(),
        inner_args: vec![OsString::from("sandbox-inner")],
        relay_args: vec![OsString::from("relay")],
    }
}

/// The invocation as a draugr spawn: stdin `/dev/null`, each fd at its number, a session of its own when the
/// backend needs one (the reduced tier). The spec moves into `draugr::spawn_pinned`, which drops the fds once the
/// child runs, so the status pipe's only write end goes with it (review S6).
pub fn to_draugr(inv: Invocation) -> draugr::Spec {
    draugr::Spec {
        program: inv.program,
        args: inv.args,
        env: inv.env,
        cwd: inv.cwd,
        stdin_null: true,
        pass_fds: inv
            .fds
            .into_iter()
            .map(|(fd, target)| PassFd {
                fd: Arc::new(fd),
                target,
            })
            .collect(),
        new_session: inv.new_session,
    }
}

/// The macOS facts for the Seatbelt profile: the developer dir behind xcode-select's root-owned link, read the way
/// draugr finds git (`<developer dir>/usr/bin/git`), or none.
#[cfg(target_os = "macos")]
pub fn mac_context() -> gleipnir::sbpl::MacContext {
    let developer_dir = draugr::git::git_program()
        .ok()
        .and_then(|g| g.path.ancestors().nth(3).map(Path::to_path_buf));
    gleipnir::sbpl::MacContext {
        developer_dir,
        ..Default::default()
    }
}

/// A start that failed before the program ran, as a refusal.
fn setup(message: String) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message,
    }
}

/// The check's spawn: the prepared probe started the way a job is (`draugr::spawn_pinned`), its status line read, and
/// its exit awaited, all within `timeout`. Whatever is still running at the deadline is killed.
pub async fn run_probe(prepared: Prepared, timeout: Duration) -> Ran {
    let end = Instant::now() + timeout;
    let left = || end.saturating_duration_since(Instant::now());
    let Prepared {
        invocation,
        status,
        layers,
    } = prepared;
    let mut child = match draugr::spawn_pinned(to_draugr(invocation)).await {
        Ok(c) => c,
        Err(e) => {
            return Ran {
                layers: Err(setup(format!("cannot start the sandbox: {e}"))),
                exit: None,
                stderr: String::new(),
            };
        }
    };
    let report = match status {
        // Blocking, on the thread that drives this future; the runtime's worker keeps reading the stderr tail.
        Some(fd) => gleipnir::read_status(fd, &|| child.stderr_tail(), left()),
        None => layers.ok_or_else(|| setup("no status line and no layers".into())),
    };
    let mut exit = None;
    let finished = report.is_ok()
        && match tokio::time::timeout(left(), child.wait()).await {
            Ok(Ok(Some(s))) => {
                exit = Some(s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0)));
                true
            }
            _ => false,
        };
    if !finished {
        // The group cannot go while its leader is an unreaped zombie (a start that failed at once): reap it while
        // the group is ended.
        let _ = tokio::join!(
            draugr::kill_group(child.id(), draugr::reap::GRACE, &draugr::RealSignaller),
            tokio::time::timeout(Duration::from_secs(7), child.wait())
        );
    }
    Ran {
        layers: report,
        exit,
        stderr: child.stderr_tail(),
    }
}

/// The check for `tier` here, on a runtime of its own (the doctor and the command line have none), within `timeout`.
pub fn check_blocking(tier: Tier, bwrap: Option<PathBuf>, timeout: Duration) -> Check {
    let helper = match helper() {
        Ok(h) => h,
        Err(e) => return Check::failed(format!("the helper's own path: {e}"), None),
    };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build();
    match runtime {
        Ok(rt) => rt.block_on(gleipnir::check::check(
            helper, tier, bwrap, timeout, run_probe,
        )),
        Err(e) => Check::failed(format!("no async runtime: {e}"), None),
    }
}

/// How long `sandbox check` lets the probe run (review S16).
pub const CHECK_TIMEOUT: Duration = Duration::from_secs(5);

/// `ratatoskr sandbox check`: the text form or `--json`; exit 0 when the sandbox starts here, else 1.
pub fn check_command(args: SandboxCheckArgs) -> i32 {
    let check = check_blocking(args.tier, args.bwrap, CHECK_TIMEOUT);
    if args.json {
        println!("{}", check.to_json());
    } else {
        println!("{}", check.text());
    }
    i32::from(!check.ok)
}

#[cfg(feature = "test-hooks")]
pub use run::run;

/// `ratatoskr sandbox run` (test-hooks only).
#[cfg(feature = "test-hooks")]
mod run {
    use super::*;
    use crate::cli::SandboxRunArgs;
    use gleipnir::{LayersReport, Prepared, Refusal, Rule, Sandbox, Spec, TestHooks};
    use std::io::{BufRead, Write};
    use std::os::unix::process::ExitStatusExt;
    use std::time::Duration;

    /// The exit when the run was refused (nothing spawned, or the helper refused before the program).
    const REFUSED: i32 = 3;

    #[derive(Default)]
    struct Outcome {
        refused: Option<Refusal>,
        layers: Option<LayersReport>,
        exit: Option<i32>,
    }

    /// Detect, validate against [`context`], prepare, (pause,) spawn through `draugr::spawn_pinned`, read the
    /// status line within its deadline, wait; then write `{"refused", "layers", "exit"}` to `--result`. Exits
    /// [`REFUSED`] when refused, else with the child's code. The child's stdout is passed through; its stderr tail is
    /// written to stderr once it has exited. Rows judge by the result file only: the child may exit 3 itself.
    pub fn run(args: SandboxRunArgs) -> i32 {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build();
        let outcome = match runtime {
            Ok(rt) => rt.block_on(run_in(&args)),
            Err(e) => Outcome {
                refused: Some(setup(format!("no async runtime: {e}"))),
                ..Outcome::default()
            },
        };
        let refused = outcome.refused.as_ref().map(|r| {
            serde_json::json!({
                "rule": format!("{:?}", r.rule),
                "path": r.path.as_ref().map(|p| p.to_string_lossy()),
                "message": r.message,
            })
        });
        let result = serde_json::json!({
            "refused": refused,
            "layers": outcome.layers,
            "exit": outcome.exit,
        });
        if let Err(e) = std::fs::write(&args.result, format!("{result}\n")) {
            eprintln!("ratatoskr sandbox run: {}: {e}", args.result.display());
            return REFUSED;
        }
        if let Some(r) = &outcome.refused {
            eprintln!("ratatoskr sandbox run: refused: {r}");
            return REFUSED;
        }
        outcome.exit.unwrap_or(REFUSED)
    }

    async fn run_in(a: &SandboxRunArgs) -> Outcome {
        let prepared = match prepare(a) {
            Ok(p) => p,
            Err(r) => {
                return Outcome {
                    refused: Some(r),
                    ..Outcome::default()
                };
            }
        };
        if let Some(fifo) = &a.pause_before_spawn
            && let Err(e) = pause(fifo)
        {
            return Outcome {
                refused: Some(setup(format!(
                    "--pause-before-spawn {}: {e}",
                    fifo.display()
                ))),
                ..Outcome::default()
            };
        }
        let Prepared {
            invocation,
            status,
            layers,
        } = prepared;
        let mut child = match draugr::spawn_pinned(to_draugr(invocation)).await {
            Ok(c) => c,
            Err(e) => {
                return Outcome {
                    refused: Some(setup(format!("cannot start the sandbox: {e}"))),
                    ..Outcome::default()
                };
            }
        };
        let stdout = child.take_stdout();
        // The child's stdout, passed through (tokio's own stdout is not built here: small writes to ours).
        let pump = tokio::spawn(async move {
            use tokio::io::AsyncReadExt;
            let Some(mut out) = stdout else { return };
            let mut buf = [0u8; 8192];
            while let Ok(n @ 1..) = out.read(&mut buf).await {
                let mut o = io::stdout().lock();
                if o.write_all(&buf[..n]).and_then(|()| o.flush()).is_err() {
                    return;
                }
            }
        });
        // The status line: the helper's (Linux), within its deadline; Seatbelt's layers are known already.
        let deadline = gleipnir::inner::SETUP_DEADLINE
            + Duration::from_millis(gleipnir::inner::RELAY_READY_TIMEOUT_MS.into());
        let report = match status {
            // Blocking, on the thread that drives this future; the runtime's worker keeps reading the stderr tail.
            Some(fd) => gleipnir::read_status(fd, &|| child.stderr_tail(), deadline),
            None => layers.ok_or_else(|| setup("no status line and no layers".into())),
        };
        let mut out = Outcome::default();
        let mut waited = None;
        match report {
            Ok(l) => out.layers = Some(l),
            Err(r) => {
                // The group cannot go while its leader is an unreaped zombie (a start that failed at once):
                // reap it while the group is ended, or this waits out the whole grace and kill time.
                let (_, status) = tokio::join!(
                    draugr::kill_group(child.id(), draugr::reap::GRACE, &draugr::RealSignaller),
                    child.wait()
                );
                waited = Some(status);
                out.refused = Some(r);
            }
        }
        let status = match waited {
            Some(status) => status,
            None => child.wait().await,
        };
        out.exit = match status {
            Ok(Some(s)) => Some(s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0))),
            _ => None,
        };
        let _ = tokio::time::timeout(Duration::from_secs(2), pump).await;
        let tail = child.stderr_tail();
        let _ = io::stderr().write_all(tail.as_bytes());
        out
    }

    /// Detect the backend, read and validate the spec for it, and prepare the run (every source opened).
    fn prepare(a: &SandboxRunArgs) -> Result<Prepared, Refusal> {
        let helper = helper().map_err(|e| setup(format!("the helper's own path: {e}")))?;
        let sandbox = Sandbox::detect(a.tier, helper, a.bwrap.clone())?;
        #[cfg(target_os = "macos")]
        let sandbox = sandbox.with_mac(mac_context());
        let text = std::fs::read_to_string(&a.spec).map_err(|e| Refusal {
            rule: Rule::Malformed,
            path: Some(a.spec.clone()),
            message: format!("{}: {e}", a.spec.display()),
        })?;
        let spec: Spec = serde_json::from_str(&text).map_err(|e| Refusal {
            rule: Rule::Malformed,
            path: Some(a.spec.clone()),
            message: format!("{}: {e}", a.spec.display()),
        })?;
        let target = sandbox
            .target()
            .ok_or_else(|| setup("no sandbox backend here".into()))?;
        let valid = gleipnir::validate(spec, &context(&Env::process()), target)?;
        let hooks = TestHooks {
            landlock_omit: a.landlock_omit.clone(),
            abi_cap: a.landlock_abi_cap,
        };
        sandbox.prepare(valid, a.command.clone(), hooks)
    }

    /// Say `opened` on `fifo`, then wait for one line back.
    fn pause(fifo: &Path) -> io::Result<()> {
        std::fs::OpenOptions::new()
            .write(true)
            .open(fifo)?
            .write_all(b"opened\n")?;
        let mut line = String::new();
        io::BufReader::new(std::fs::File::open(fifo)?).read_line(&mut line)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests;
