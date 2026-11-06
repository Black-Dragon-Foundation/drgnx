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
use std::time::Duration;

/// Environment names never passed into a sandbox beside `gleipnir::BASE_ENV_DENY`: drgnx's own dirs, the agent's
/// identity, and the names the Lisp backend of older hubs was given (its socket, parent pid and secret), should one
/// still be set.
pub const ENV_DENY: &[&str] = &[
    "DRGNX_DATA_DIR",
    "DRGNX_CONFIG_DIR",
    "DRGNX_AGENT",
    "DRGNX_HUB_SERVE_SOCKET",
    "DRGNX_HUB_PARENT_PID",
    "DRGNX_HUB_SERVE_SECRET",
];

/// What no spec may expose, for the hub `env` describes, as true names (GL-T2-2):
/// - closed: drgnx's data, config, cache and state dirs; every socket dir a hub may use (`<runtime>/drgnx`, `<state>/hub`,
///   `<tmp>/drgnx-hub-UID`); `DRGNX_DIR` (the checkout); Emacs's server dirs (`<tmp>/emacsUID`, `/tmp/emacsUID`,
///   `<runtime>/emacs`); and this binary's own dir (review M12), so no write bind can replace the helper;
/// - `user_sockets`: `SSH_AUTH_SOCK` and the D-Bus session bus's `unix:path=`;
/// - `run_parents`: `paths::session_parents`, where session dirs are made (`<socket dir>/s`, and the fallback
///   `<tmp>/drgnx-hub-UID/s`), never the backend's `hub-HASH.d/` (review M10);
/// - `program_dirs`: the absolute `PATH` entries (a relative one names no fixed place and is left out; Task 2);
/// - `env_deny`: [`ENV_DENY`].
///
/// Each path is taken to its true name on disk: a link is resolved, and a path that does not exist keeps the true
/// name of its deepest existing ancestor. One that cannot be named (not UTF-8, not absolute, a dangling link) is left
/// out. `open_inside_closed` is [`runs_root`] alone, where workers' worktrees are (a job's own dir is phase 6's).
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
        // the package cache a sync installs from (`<cache>/packages`): no job may plant a file there
        paths::cache_dir(env),
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
        // the runs' worktrees, and the browsers `drgnx browser install` put in the data dir (a session reads its own)
        open_inside_closed: true_names([runs_root(env), paths::data_dir(env).join("browsers")]),
        user_sockets: true_names(user_sockets),
        run_parents: true_names(paths::session_parents(env, &socket)),
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
        browser_host_args: vec![OsString::from("browser-host")],
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
    let end = crate::clock::now() + timeout;
    let left = || end.saturating_duration_since(crate::clock::now());
    let Prepared {
        invocation,
        status,
        layers,
        browser,
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
        Some(fd) => gleipnir::inner::read_status_for(fd, &|| child.stderr_tail(), left(), browser),
        None => layers.ok_or_else(|| setup("no status line and no layers".into())),
    };
    let mut exit = None;
    let finished = report.is_ok()
        && match crate::clock::timeout(left(), child.wait()).await {
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
            crate::clock::timeout(Duration::from_secs(7), child.wait())
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
        println!("{}", check_json(&check));
    } else {
        println!("{}", check_text(&check));
    }
    i32::from(!check.ok)
}

/// The check's text, and on the reduced tier the line that it cannot pin your settings files
/// ([`crate::sandbox_settings::pins_note`]).
pub fn check_text(check: &Check) -> String {
    match crate::sandbox_settings::pins_note(check.backend) {
        Some(note) => format!("{}\n{note}", check.text()),
        None => check.text(),
    }
}

/// The check's JSON with `pins_note` (the same line, or null).
pub fn check_json(check: &Check) -> serde_json::Value {
    let mut v = check.to_json();
    v["pins_note"] = crate::sandbox_settings::pins_note(check.backend).into();
    v
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
        // `_hub`: the hub's end of a `--browser-probe` run's socketpair, held until the run is over.
        let (prepared, _hub) = match prepare(a) {
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
            browser,
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
            Some(fd) => {
                gleipnir::inner::read_status_for(fd, &|| child.stderr_tail(), deadline, browser)
            }
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
        let _ = crate::clock::timeout(Duration::from_secs(2), pump).await;
        let tail = child.stderr_tail();
        let _ = io::stderr().write_all(tail.as_bytes());
        out
    }

    /// Detect the backend, read and validate the spec for it, and prepare the run (every source opened). With
    /// `--browser-probe`, the browser host's argv is the probe's and the run makes the socketpair: the host's end goes
    /// to the sandbox, the hub's end is returned.
    fn prepare(
        a: &SandboxRunArgs,
    ) -> Result<(Prepared, Option<std::os::unix::net::UnixStream>), Refusal> {
        let helper = helper().map_err(|e| setup(format!("the helper's own path: {e}")))?;
        let sandbox = Sandbox::detect(a.tier, helper, a.bwrap.clone())?;
        #[cfg(target_os = "macos")]
        let sandbox = sandbox.with_mac(mac_context());
        let text = std::fs::read_to_string(&a.spec).map_err(|e| Refusal {
            rule: Rule::Malformed,
            path: Some(a.spec.clone()),
            message: format!("{}: {e}", a.spec.display()),
        })?;
        let mut spec: Spec = serde_json::from_str(&text).map_err(|e| Refusal {
            rule: Rule::Malformed,
            path: Some(a.spec.clone()),
            message: format!("{}: {e}", a.spec.display()),
        })?;
        let target = sandbox
            .target()
            .ok_or_else(|| setup("no sandbox backend here".into()))?;
        let env = Env::process();
        let mut ctx = context(&env);
        if a.settings_guards {
            // As phase 6's job spec builder will: your config files closed, the roots' settings files pinned.
            let config = paths::config_dir(&env);
            let files = crate::sandbox_settings::read_user_lisp_files(&config, &ctx.home);
            ctx.closed
                .extend(crate::sandbox_settings::closed_config_targets(
                    &config, &files,
                ));
            let pins = crate::sandbox_settings::settings_pins(&spec.write);
            spec.binds.extend(pins);
        }
        let valid = gleipnir::validate(spec, &ctx, target)?;
        let hooks = TestHooks {
            landlock_omit: a.landlock_omit.clone(),
            abi_cap: a.landlock_abi_cap,
            browser_argv: a.browser_probe.clone(),
        };
        let (hub, host) = if a.browser_probe.is_empty() {
            (None, None)
        } else {
            let (hub, host) = std::os::unix::net::UnixStream::pair()
                .map_err(|e| setup(format!("the browser's socketpair: {e}")))?;
            (Some(hub), Some(std::os::fd::OwnedFd::from(host)))
        };
        let prepared = sandbox.prepare(valid, a.command.clone(), host, hooks)?;
        Ok((prepared, hub))
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

/// The proxy port inside a session whose network is the provider's only.
pub const PROXY_PORT: u16 = 3128;

/// The gateway port inside a session on a gateway profile: relayed to its `gateway.sock`.
pub const GATEWAY_PORT: u16 = 3129;

/// The allow-list of a job's proxy by its network cell (exact `host:port`), and the tier part of a session's
/// (`agents::net::provider_hosts`).  The lists are the setting `agents-net-hosts` (HOSTS: tier name to hosts; shipped default: the package registries of
/// crates.io, npm and PyPI under `packages`).  Provider-only has the `provider-only` list (shipped: none; a job has no
/// provider); the packages cell reaches the `packages` list.  `Open` shares the host's network for a session and gets
/// the packages list here.  A tier the setting does not name reaches nothing.
pub fn allowed_hosts(
    net: crate::agents::launch::NetCell,
    hosts: &[(String, Vec<String>)],
) -> Vec<String> {
    use crate::agents::launch::NetCell;
    let tier = match net {
        NetCell::ProviderOnly => "provider-only",
        NetCell::ProviderAndPackages | NetCell::Open => "packages",
    };
    hosts
        .iter()
        .filter(|(t, _)| t == tier)
        .flat_map(|(_, h)| h.iter().cloned())
        .collect()
}

/// The protected paths of the lock, resolved against the session's worktree CWD (an absolute entry stays as it is) and
/// made to exist, so a bind can pin them: a later-created `.envrc` or `.claude/settings.json` is read-only as well.
/// A missing entry is created empty (a file for [`crate::agents::lock::PROTECTED_FILES`], else a folder) when its
/// parent is a folder; one whose parent is none (`.git/hooks` in a linked worktree, where `.git` is a file; the hooks
/// live outside the worktree, which is not writable) is left out.
fn pin_protected(
    cwd: &Path,
    protected: &[PathBuf],
) -> Result<(Vec<PathBuf>, Vec<PathBuf>), Refusal> {
    let (mut out, mut made_here) = (Vec::new(), Vec::new());
    for rel in protected {
        let p = cwd.join(rel);
        if out.contains(&p) {
            continue;
        }
        if p.symlink_metadata().is_err() {
            if !p.parent().is_some_and(Path::is_dir) {
                continue;
            }
            let is_file = p
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| crate::agents::lock::PROTECTED_FILES.contains(&n));
            let made = if is_file {
                std::fs::write(&p, b"")
            } else {
                std::fs::create_dir(&p)
            };
            made.map_err(|e| Refusal {
                rule: Rule::Setup,
                path: Some(p.clone()),
                message: format!("{}: cannot pin it read-only: {e}", p.display()),
            })?;
            made_here.push(p.clone());
        }
        out.push(p);
    }
    Ok((out, made_here))
}

/// Where the stubs [`pin_protected`] made for session SID are listed (in the hub's scratch, out of the agent's reach).
fn stubs_file(scratch: &Path) -> PathBuf {
    scratch.join("stubs")
}

/// Remove the stubs the hub made in a worktree for a session whose scratch is SCRATCH, when they are still empty and
/// not in the git index (an agent's real file is never touched; a committed one is the merge gate's).  Called when
/// the session ends, so an empty `.envrc` or `mise.toml` never lingers in a checkout.
pub fn remove_stubs(scratch: &Path, worktree: &Path) {
    let list = stubs_file(scratch);
    let Ok(text) = std::fs::read_to_string(&list) else {
        return;
    };
    let index = git_dirs(worktree)
        .and_then(|g| std::fs::read(g.gitdir.join("index")).ok())
        .unwrap_or_default();
    for line in text.lines() {
        let p = Path::new(line);
        let Ok(rel) = p.strip_prefix(worktree) else {
            continue;
        };
        let tracked = rel.to_str().is_some_and(|r| {
            let r = r.as_bytes();
            index.windows(r.len().max(1)).any(|w| w == r)
        });
        let Ok(m) = p.symlink_metadata() else {
            continue;
        };
        if tracked {
            continue;
        }
        let _ = if m.is_file() && m.len() == 0 {
            std::fs::remove_file(p)
        } else if m.is_dir() {
            std::fs::remove_dir(p)
        } else {
            Ok(())
        };
    }
    let _ = std::fs::remove_file(list);
}

/// A worktree's git folders: its own (`gitdir`; `.git` itself in a plain checkout) and the common one (`common`),
/// which holds the hooks, the config, the objects and the refs of every worktree of the repository.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitDirs {
    pub gitdir: PathBuf,
    pub common: PathBuf,
}

/// The git folders of WORKTREE, as true names: `.git` is a folder (a plain checkout), or a file `gitdir: PATH` (a
/// linked worktree) whose folder names the common one in `commondir`.  None: not a git worktree.
pub fn git_dirs(worktree: &Path) -> Option<GitDirs> {
    let dot = worktree.join(".git");
    let meta = dot.symlink_metadata().ok()?;
    if meta.is_dir() {
        let d = std::fs::canonicalize(&dot).ok()?;
        return Some(GitDirs {
            gitdir: d.clone(),
            common: d,
        });
    }
    let text = std::fs::read_to_string(&dot).ok()?;
    let path = text.lines().next()?.strip_prefix("gitdir:")?.trim();
    let gitdir = std::fs::canonicalize(worktree.join(path)).ok()?;
    let common = match std::fs::read_to_string(gitdir.join("commondir")) {
        Ok(c) => std::fs::canonicalize(gitdir.join(c.trim())).ok()?,
        Err(_) => gitdir.clone(),
    };
    Some(GitDirs { gitdir, common })
}

/// What a sandboxed agent must not write in the git folders of WORKTREE: git runs code it finds in `hooks`, in
/// `config` and in `config.worktree` (the worktree's, and each submodule's folder under `modules/`), so the user's
/// next git command would run what the agent left there.  Those are pinned read-only.  Only a git folder inside the
/// worktree is the agent's to write (a snapshot task has its own `.git`, a copy of the run's store); the common folder
/// of a linked worktree is the user's repository and is not given to a sandboxed agent at all (it could rewrite
/// the user's branches), so nothing there is pinned or opened.  Every pin exists (a missing `hooks` folder is made).
pub fn git_access(worktree: &Path) -> Vec<PathBuf> {
    let (Some(g), Ok(real)) = (git_dirs(worktree), std::fs::canonicalize(worktree)) else {
        return vec![];
    };
    if !g.gitdir.starts_with(&real) || !g.common.starts_with(&real) {
        return vec![];
    }
    let mut pins: Vec<PathBuf> = Vec::new();
    let mut add = |p: PathBuf| {
        if p.symlink_metadata().is_ok() && !pins.contains(&p) {
            pins.push(p);
        }
    };
    // a repository always has a hooks folder; make it if it is gone, so a hook cannot be added later
    let hooks = g.common.join("hooks");
    if !hooks.exists() {
        let _ = std::fs::create_dir(&hooks);
    }
    for dir in [&g.common, &g.gitdir] {
        for n in ["hooks", "config", "config.worktree"] {
            add(dir.join(n));
        }
    }
    // each linked worktree's folder (one level) and each submodule's (nested, to a depth of four)
    for kind in ["worktrees", "modules"] {
        let mut todo = vec![(g.common.join(kind), 0usize)];
        while let Some((dir, depth)) = todo.pop() {
            let Ok(rd) = std::fs::read_dir(&dir) else {
                continue;
            };
            for e in rd.flatten() {
                let p = e.path();
                if !p.is_dir() || p.is_symlink() {
                    continue;
                }
                for n in ["hooks", "config", "config.worktree"] {
                    add(p.join(n));
                }
                if kind == "modules" && depth < 4 {
                    todo.push((p.join("modules"), depth + 1));
                }
            }
        }
    }
    pins
}

/// Where the hub makes the worktrees of plan runs and manager-started workers (`<state>/hub/runs`).  It lies inside
/// closed folders, so the context opens exactly this folder ([`context_for`]): a spec may name a tree in it (the
/// hub builds each spec, and only for the session's own tree), nothing else of the state folder.
pub fn runs_root(env: &Env) -> PathBuf {
    paths::state_dir(env).join("hub").join("runs")
}

/// What a session's spec is built from (Task 10): its id, where it works, what else it reads, the network cell, and
/// its browser, when it has one.
#[derive(Debug, Clone)]
pub struct SessionShape {
    pub sid: String,
    pub cwd: PathBuf,
    pub write: Vec<PathBuf>,
    pub read: Vec<PathBuf>,
    pub net: crate::agents::launch::NetCell,
    pub browser: Option<BrowserShape>,
}

/// The web relay's port inside a browser session: the browser's proxy, to `web.sock`.
pub const WEB_PORT: u16 = 3130;
/// The CDP relay's port inside a browser session: the agent's endpoint, to `cdp.sock`.
pub const CDP_PORT: u16 = 9222;
/// Fontconfig's cache, read by the browser when the host has one.
pub const FONTCONFIG_CACHE: &str = "/var/cache/fontconfig";
/// What a browser session's environment never carries: a display, the user's runtime dir.
pub const NO_DISPLAY_ENV: [&str; 3] = ["WAYLAND_DISPLAY", "DISPLAY", "XDG_RUNTIME_DIR"];

/// The browser a session gets (design §6.1): the program found (`browser::resolve`), the relay ports, the agent's
/// local servers it may reach, the largest CDP message and the session's CDP secret (never shown by `Debug`).
#[derive(Debug, Clone)]
pub struct BrowserShape {
    pub program: PathBuf,
    pub kind: crate::browser::resolve::Kind,
    pub web_port: u16,
    pub cdp_port: u16,
    pub local_ports: Vec<u16>,
    pub max_message: u64,
    pub secret: crate::browser::Secret,
}

/// Why a session whose `browser` cell allows one starts without it (OD1 (b)): the reason (`kind` names it for the
/// one notice per hub run, `why` says it) and what fixes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoBrowser {
    pub kind: &'static str,
    pub why: String,
    pub fix: String,
}

/// The browser a session gets under its `browser` cell CELL: none for Never; else the program FOUND, when the
/// sandbox is bubblewrap's full tier (BACKEND) and the kernel's Landlock ABI is at least 9 (ABI).  Otherwise the
/// reason it has none.  LOCAL_PORTS, MAX_MESSAGE and SECRET go into the shape as they are.
#[allow(clippy::too_many_arguments)]
pub fn browser_for(
    cell: norn::matrix::Verdict,
    backend: Option<gleipnir::BackendKind>,
    abi: u8,
    found: Result<crate::browser::resolve::Found, crate::browser::resolve::NotFound>,
    local_ports: Vec<u16>,
    max_message: u64,
    secret: crate::browser::Secret,
) -> Result<Option<BrowserShape>, NoBrowser> {
    if cell == norn::matrix::Verdict::Never {
        return Ok(None);
    }
    if backend != Some(gleipnir::BackendKind::Bwrap) {
        return Err(NoBrowser {
            kind: "tier",
            why: "the agent browser needs bubblewrap's full sandbox tier, which this host does not run".into(),
            fix: "install bubblewrap 0.12 or later and allow user namespaces (`ratatoskr sandbox check` says what \
                  is missing)"
                .into(),
        });
    }
    if abi < gleipnir::LANDLOCK_FLOOR_BROWSER {
        return Err(NoBrowser {
            kind: "landlock",
            why: format!(
                "the kernel's Landlock ABI is {abi}; the agent browser needs {}",
                gleipnir::LANDLOCK_FLOOR_BROWSER
            ),
            fix: "run a newer kernel, one with Landlock ABI 9 or later".into(),
        });
    }
    let found = found.map_err(|n| NoBrowser {
        kind: "program",
        why: "no browser was found for the agent browser".into(),
        fix: n.fix,
    })?;
    Ok(Some(BrowserShape {
        program: found.path,
        kind: found.kind,
        web_port: WEB_PORT,
        cdp_port: CDP_PORT,
        local_ports,
        max_message,
        secret,
    }))
}

/// The temporary directory `env` names (`TMPDIR`, `TMP`, `TEMP`, else `/tmp`).
pub fn tmp_dir(env: &Env) -> PathBuf {
    ["TMPDIR", "TMP", "TEMP"]
        .iter()
        .find_map(|n| env.vars.get(*n).filter(|v| !v.is_empty()))
        .filter(|v| v.starts_with('/'))
        .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from)
}

/// The `PATH` a session gets when the hub's environment has none.
const DEFAULT_PATH: &str = "/usr/local/bin:/usr/bin:/bin";

/// What a session reads of the user's toolchains (docs/develop/gleipnir.md, "Toolchain roots"), and its program.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toolchain {
    /// The read-only roots under the home: bin dirs and install roots, never a whole tool home.
    pub read: Vec<PathBuf>,
    /// The credential files inside them (the full tier and macOS; the reduced tier cannot hide inside a granted
    /// root, so it leaves a root that holds one out instead).
    pub hide: Vec<PathBuf>,
    /// The program to run: its `PATH` hit (or its absolute path), with the folder as its true name and the file
    /// name kept (a link keeps the name its program may go by).
    pub program: PathBuf,
}

/// The toolchain roots `path` (a `PATH` value) leads into under `ctx.home`, and where `program` (the profile's
/// command: a name looked up on `path`, or an absolute path) is.  The program's own folder counts as a `PATH` entry, so a
/// link there leads to its install (`~/.local/bin/claude` → `~/.local/share/claude/versions/V/`).  Each root passes
/// validation's read rules for `target` (`gleipnir::toolchain::readable`); drgnx's data dir and checkout are never one.
/// The program is refused, naming its path, when it is not found, or when the sandbox would not see it: the file, or its
/// link's target, outside every root, every path in `granted` (the session's own reads and writes) and the system's
/// trees.
pub fn toolchain(
    env: &Env,
    ctx: &Context,
    path: &str,
    program: &OsStr,
    granted: &[PathBuf],
    tier: gleipnir::Tier,
    target: gleipnir::Target,
) -> Result<Toolchain, Refusal> {
    use gleipnir::toolchain;
    let refused = |p: &Path, why: &str| Refusal {
        rule: Rule::Setup,
        path: Some(p.to_path_buf()),
        message: format!("the agent's program {}: {why}", p.display()),
    };
    let path_dirs: Vec<PathBuf> = path
        .split(':')
        .filter(|d| d.starts_with('/'))
        .map(PathBuf::from)
        .collect();
    let named = Path::new(program);
    let hit = if program.as_bytes().contains(&b'/') {
        if !named.is_absolute() {
            return Err(refused(
                named,
                "a command with a slash must be an absolute path",
            ));
        }
        named.to_path_buf()
    } else {
        path_dirs
            .iter()
            .map(|d| d.join(named))
            .find(|p| is_executable(p))
            .ok_or_else(|| refused(named, "not found on PATH"))?
    };
    // the folder as its true name (a PATH entry that is a link is not there inside), the file name as it is
    let program = match (hit.parent().and_then(true_name), hit.file_name()) {
        (Some(dir), Some(name)) => dir.join(name),
        _ => return Err(refused(&hit, "its folder cannot be named")),
    };
    let real = std::fs::canonicalize(&program).map_err(|e| refused(&program, &format!("{e}")))?;
    let mut dirs = path_dirs;
    if let Some(dir) = program.parent().filter(|d| !dirs.iter().any(|p| p == d)) {
        dirs.push(dir.to_path_buf());
    }
    let mut exclude = vec![paths::data_dir(env)];
    exclude.extend(
        env.vars
            .get("DRGNX_DIR")
            .filter(|v| v.starts_with('/'))
            .map(PathBuf::from),
    );
    let mise = env
        .vars
        .get("MISE_DATA_DIR")
        .filter(|v| v.starts_with('/'))
        .map(PathBuf::from)
        .or_else(|| {
            env.vars
                .get("XDG_DATA_HOME")
                .filter(|v| v.starts_with('/'))
                .map(|d| Path::new(d).join("mise"))
        });
    let roots = toolchain::roots(&dirs, &ctx.home, mise.as_deref(), &exclude);
    let mut roots = toolchain::readable(roots, ctx, target);
    let mut hide = toolchain::hide_list(&roots);
    if tier == gleipnir::Tier::Reduced {
        // no mount namespace: a hide inside a granted root is refused, so a root holding a credential file stays out
        roots
            .dirs
            .retain(|d| !hide.iter().any(|h| h.starts_with(d)));
        roots.files.retain(|f| !hide.contains(f));
        hide.clear();
    }
    let seen = |p: &Path| {
        roots.dirs.iter().chain(granted).any(|r| p.starts_with(r))
            || roots.files.iter().any(|f| f == p)
            || (!p.starts_with(&ctx.home)
                && system_reads(target).iter().any(|s| p.starts_with(s))
                && !system_hidden(target).iter().any(|h| p.starts_with(h)))
    };
    for p in [&program, &real] {
        if !seen(p) || hide.iter().any(|h| h == p) {
            return Err(refused(
                p,
                "the sandbox does not show it (only bin folders and install roots under the home are bound, and \
                 a mise shim is not one: put the tool's own folder on PATH or name the program by its full path)",
            ));
        }
    }
    let mut read = roots.dirs;
    read.extend(roots.files);
    Ok(Toolchain {
        read,
        hide,
        program,
    })
}

/// An executable regular file (a link followed).
fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The system trees a sandbox of `target` shows read-only: bwrap's binds (`/usr`, its `SYSTEM_READS` and the
/// top-level dirs a host without a merged `/usr` keeps apart), the reduced tier's Landlock roots, Seatbelt's
/// `SYSTEM_READ` (deny-default: a path outside them, such as `/opt/local` or `/Applications`, is not readable).
fn system_reads(target: gleipnir::Target) -> Vec<PathBuf> {
    let all = |names: &[&str]| names.iter().map(PathBuf::from).collect::<Vec<_>>();
    match target {
        gleipnir::Target::LinuxBwrap => {
            let mut v = all(&["/usr"]);
            v.extend(all(gleipnir::bwrap::SYSTEM_READS));
            v.extend(
                gleipnir::bwrap::USR_MERGED
                    .iter()
                    .map(|d| Path::new("/").join(d)),
            );
            v
        }
        gleipnir::Target::LinuxReduced => all(gleipnir::landlock::REDUCED_SYSTEM_ROOTS),
        gleipnir::Target::Macos => all(gleipnir::sbpl::SYSTEM_READ),
    }
}

/// The system paths a sandbox of `target` never shows, though they lie inside [`system_reads`].
fn system_hidden(target: gleipnir::Target) -> &'static [&'static str] {
    match target {
        gleipnir::Target::Macos => gleipnir::sbpl::SYSTEM_HIDDEN,
        gleipnir::Target::LinuxBwrap | gleipnir::Target::LinuxReduced => &[],
    }
}

/// What a session's CLI gets of its login dir ([`login_grants`]).
#[derive(Default)]
struct LoginGrants {
    read: Vec<PathBuf>,
    write: Vec<PathBuf>,
    binds: Vec<gleipnir::Bind>,
}

/// What a session's CLI gets of its login dir DIR, which is never shown itself: the entries
/// [`crate::agents::lock::login_entries`] names that exist, each as the CLI uses it (a missing folder of its own state
/// is made first; a token file or a folder that is a link is left out; a folder that holds every session of the CLI,
/// yours too, is on the full tier an empty one of the session's own, `login/NAME` in its scratch, bound in its place,
/// and elsewhere not shown), and Claude's folder for the session's cwd
/// ([`crate::agents::lock::claude_project`]).  That folder is the session's own when its cwd is (a worktree, a chat's
/// scratch).  A chat in your project shares its cwd with your own Claude Code, whose transcripts and auto memory live
/// there, so it never gets that folder: on the full tier an empty one of its own (`claude-project` in its scratch) is
/// bound over it, and the other targets, which cannot bind, give it none (Claude Code then keeps no transcript of that
/// chat).
fn login_grants(
    dir: &Path,
    shape: &SessionShape,
    scratch: &Path,
    target: gleipnir::Target,
) -> Result<LoginGrants, Refusal> {
    use crate::agents::lock::LoginUse;
    let real = |p: &Path| {
        p.symlink_metadata()
            .is_ok_and(|m| !m.file_type().is_symlink())
    };
    let mut g = LoginGrants::default();
    for &(name, used) in crate::agents::lock::login_entries(dir) {
        let p = dir.join(name);
        match used {
            LoginUse::Read => read_login_entry(&p, target, &mut g),
            LoginUse::File => {
                if real(&p) {
                    g.write.push(p);
                }
            }
            LoginUse::Dir => {
                make_login_dir(&p)?;
                if real(&p) {
                    g.write.push(p);
                }
            }
            LoginUse::Own if target == gleipnir::Target::LinuxBwrap => {
                let own = scratch.join("login").join(name);
                paths::private_dir(&own).map_err(|e| Refusal {
                    rule: Rule::Setup,
                    path: Some(own.clone()),
                    message: format!("{}: {e}", own.display()),
                })?;
                g.binds.push(gleipnir::Bind {
                    mode: gleipnir::Mode::Rw,
                    source: own,
                    dest: p,
                });
            }
            LoginUse::Own => {}
        }
    }
    let Some(project) = crate::agents::lock::claude_project(dir, &shape.cwd) else {
        return Ok(g);
    };
    let own_cwd = shape.write.iter().any(|w| shape.cwd.starts_with(w));
    if !own_cwd && target != gleipnir::Target::LinuxBwrap {
        return Ok(g);
    }
    if let Some(projects) = project.parent() {
        make_login_dir(projects)?;
    }
    make_login_dir(&project)?;
    if !project.symlink_metadata().is_ok_and(|m| m.is_dir()) {
        return Ok(g);
    }
    if own_cwd {
        g.write.push(project);
        return Ok(g);
    }
    let own = scratch.join("claude-project");
    paths::private_dir(&own).map_err(|e| Refusal {
        rule: Rule::Setup,
        path: Some(own.clone()),
        message: format!("{}: {e}", own.display()),
    })?;
    g.binds.push(gleipnir::Bind {
        mode: gleipnir::Mode::Rw,
        source: own,
        dest: project,
    });
    Ok(g)
}

/// The login dir's entry P that the CLI loads, when it exists, made readable.  One that is a link (into your dotfiles)
/// is read at its true name, and on the full tier that file is bound read-only at P, where the CLI looks for it
/// (without a mount namespace P leads there itself); a link that leads nowhere gives nothing.
fn read_login_entry(p: &Path, target: gleipnir::Target, g: &mut LoginGrants) {
    let Ok(meta) = p.symlink_metadata() else {
        return;
    };
    if !meta.file_type().is_symlink() {
        g.read.push(p.to_path_buf());
        return;
    }
    let Ok(real) = std::fs::canonicalize(p) else {
        return;
    };
    g.read.push(real.clone());
    if target == gleipnir::Target::LinuxBwrap {
        g.binds.push(gleipnir::Bind {
            mode: gleipnir::Mode::Ro,
            source: real,
            dest: p.to_path_buf(),
        });
    }
}

/// Make the folder P in a login dir (0700) when it is missing and its parent is a folder, not a link; a link anywhere
/// is never followed here and is refused by the spec's true-name rule.
fn make_login_dir(p: &Path) -> Result<(), Refusal> {
    use std::os::unix::fs::DirBuilderExt;
    let real_dir = |d: &Path| d.symlink_metadata().is_ok_and(|m| m.is_dir());
    if p.symlink_metadata().is_ok() || !p.parent().is_some_and(real_dir) {
        return Ok(());
    }
    match std::fs::DirBuilder::new().mode(0o700).create(p) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(Refusal {
            rule: Rule::Setup,
            path: Some(p.to_path_buf()),
            message: format!("{}: {e}", p.display()),
        }),
    }
}

/// A session's spec ([`session_spec`]) and the program it runs ([`Toolchain::program`]).
#[derive(Debug, Clone)]
pub struct SessionSpec {
    pub spec: gleipnir::Spec,
    pub program: PathBuf,
}

/// The Gleipnir spec of one agent session: only `shape.write` (and in the CLI's login dir its token file and its
/// session's state, [`login_grants`]) writable, `shape.read`, what the CLI loads from its login dir, the
/// [`toolchain`] roots and the system readable (the toolchains' credential files hidden), the lock's `protected_ro`
/// pinned read-only, its session dir (`hub.sock`, and `proxy.sock` unless the network is open) read-only, the network
/// the cell's: the proxy through the relay, or the host's.  A plan on the gateway's socket (`LaunchPlan::gateway`) gets
/// a second relay port, to `gateway.sock`, with `ANTHROPIC_BASE_URL` on it and loopback in `NO_PROXY`; it needs an
/// isolated network.  The program's environment is a short base, the proxy's (and the gateway's) variables, and the
/// lock's `env` last (but its `ANTHROPIC_BASE_URL` on a gateway plan).  `scratch` is the session's private temp
/// parent.  The session dir is made here (`paths::make_session_dir`, which does nothing to one that is there); the
/// sockets in it need not exist yet.  There is no unsandboxed spec: nothing here builds one.
///
/// A shape with a browser ([`BrowserShape`]) also gets: the CDP relay ([`CDP_PORT`] → `cdp.sock`) and the web relay
/// ([`WEB_PORT`] → `web.sock`); its local ports in `extra_tcp_ports`; the program's folder (outside `/usr` and
/// `/opt`) and fontconfig's cache read-only; `PLAYWRIGHT_MCP_CDP_ENDPOINT` and `DRGNX_BROWSER_CDP`, the endpoint with
/// its secret, set by the hub alone (the lock's and an editor's are dropped); no `WAYLAND_DISPLAY`, `DISPLAY`,
/// `XDG_RUNTIME_DIR` nor `/run/user` path; and `Spec.browser` (`--headless-shell` or `--full`, `--max-message N`).
pub fn session_spec(
    env: &Env,
    ctx: &Context,
    plan: &crate::agents::lock::LaunchPlan,
    shape: &SessionShape,
    scratch: &Path,
    tier: gleipnir::Tier,
    target: gleipnir::Target,
) -> Result<SessionSpec, Refusal> {
    use crate::agents::launch::NetCell;
    use gleipnir::{Bind, Layers, Mode, Net, RelayPort, Spec};
    let malformed = |message: String| Refusal {
        rule: Rule::Malformed,
        path: None,
        message,
    };
    let command = plan
        .argv
        .first()
        .ok_or_else(|| malformed("the profile has no command".into()))?;
    // made here: a new session's id has no MCP session or agent socket yet, and `run`'s source must exist
    let run = paths::make_session_dir(env, &paths::socket_path(env), &shape.sid)
        .map_err(|e| malformed(format!("session dir: {e}")))?;
    let tmp = scratch.join("tmp");
    paths::private_dir(&tmp).map_err(|e| malformed(format!("{}: {e}", tmp.display())))?;
    let mut write = shape.write.clone();
    let mut read = shape.read.clone();
    // What the CLI uses of its own login dir, for it alone (`login_grants`); never the dir itself, never the home.
    let mut login_binds = Vec::new();
    if let Some(dir) = plan.login_dir.as_ref().filter(|d| d.exists()) {
        let g = login_grants(dir, shape, scratch, target)?;
        read.extend(g.read);
        write.extend(g.write);
        login_binds = g.binds;
    }
    let path = env
        .vars
        .get("PATH")
        .cloned()
        .unwrap_or_else(|| DEFAULT_PATH.into());
    let granted: Vec<PathBuf> = read.iter().chain(&write).cloned().collect();
    let tools = toolchain(env, ctx, &path, command, &granted, tier, target)?;
    let (pinned, made_here) = pin_protected(&shape.cwd, &plan.protected_ro)?;
    if !made_here.is_empty() {
        use std::io::Write;
        let record = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(stubs_file(scratch))
            .and_then(|mut f| {
                made_here
                    .iter()
                    .try_for_each(|p| writeln!(f, "{}", p.display()))
            });
        record.map_err(|e| malformed(format!("{}: {e}", scratch.display())))?;
    }
    read.extend(pinned.iter().cloned());
    read.extend(tools.read);
    let mut binds: Vec<Bind> = pinned
        .iter()
        .map(|p| Bind {
            mode: Mode::Ro,
            source: p.clone(),
            dest: p.clone(),
        })
        .collect();
    binds.extend(login_binds);
    let hub = run.join("hub.sock");
    // served by the session's provider proxy (`agents::net`), bound before the spawn
    let proxy = run.join(paths::SESSION_PROXY_SOCKET);
    let mut sockets = vec![hub];
    let mut vars: Vec<(String, String)> = vec![
        ("PATH".into(), path),
        ("HOME".into(), ctx.home.to_string_lossy().into_owned()),
        ("TMPDIR".into(), tmp.to_string_lossy().into_owned()),
    ];
    // the browser's web relay port, once its relays are made
    let mut browser: Option<(u16, &BrowserShape)> = None;
    let net = match shape.net {
        NetCell::Open if plan.gateway => {
            return Err(malformed(
                "a session on the gateway's socket needs an isolated network with its relay".into(),
            ));
        }
        NetCell::Open if shape.browser.is_some() => {
            return Err(malformed(
                "a session with the browser needs an isolated network with its relays".into(),
            ));
        }
        NetCell::Open => Net::Shared,
        NetCell::ProviderOnly | NetCell::ProviderAndPackages => {
            let mut wanted = vec![PROXY_PORT];
            if plan.gateway {
                wanted.push(GATEWAY_PORT);
            }
            if let Some(b) = &shape.browser {
                wanted.extend([b.cdp_port, b.web_port]);
            }
            let ports = gleipnir::backend::relay_ports(tier, &wanted)
                .map_err(|e| malformed(format!("no relay port: {e}")))?;
            sockets.push(proxy.clone());
            let url = format!("http://127.0.0.1:{}", ports[0]);
            for k in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
                vars.push((k.into(), url.clone()));
            }
            let mut relay = vec![RelayPort {
                port: ports[0],
                socket: proxy,
            }];
            if plan.gateway
                && let Some(&port) = ports.get(1)
            {
                // the gateway, straight to the session's gateway.sock (never through the proxy)
                let gateway = run.join(paths::SESSION_GATEWAY_SOCKET);
                sockets.push(gateway.clone());
                relay.push(RelayPort {
                    port,
                    socket: gateway,
                });
                vars.push((
                    "ANTHROPIC_BASE_URL".into(),
                    format!("http://127.0.0.1:{port}"),
                ));
                for k in ["NO_PROXY", "no_proxy"] {
                    vars.push((k.into(), "127.0.0.1,localhost".into()));
                }
            }
            if let Some(b) = &shape.browser {
                // the CDP relay to the broker on cdp.sock, the web relay to the web proxy on web.sock
                let at = if plan.gateway { 2 } else { 1 };
                let (cdp, web) = (ports[at], ports[at + 1]);
                for (port, name) in [
                    (cdp, paths::SESSION_CDP_SOCKET),
                    (web, paths::SESSION_WEB_SOCKET),
                ] {
                    let socket = run.join(name);
                    sockets.push(socket.clone());
                    relay.push(RelayPort { port, socket });
                }
                let url = b.secret.endpoint(cdp);
                for k in crate::browser::ENDPOINT_ENV {
                    vars.push((k.into(), url.clone()));
                }
                browser = Some((web, b));
            }
            Net::Isolated {
                mac_tcp_ports: if target == gleipnir::Target::Macos {
                    relay.iter().map(|r| r.port).collect()
                } else {
                    vec![]
                },
                relay,
            }
        }
    };
    // a gateway session's base URL is its relay's, whatever else set one; a browser session's endpoint is the hub's
    // alone, and it gets no display and no runtime dir of the user's
    let hubs_own = |k: &str| {
        (plan.gateway && k == "ANTHROPIC_BASE_URL")
            || (browser.is_some()
                && (crate::browser::ENDPOINT_ENV.contains(&k) || NO_DISPLAY_ENV.contains(&k)))
    };
    vars.extend(
        plan.env
            .iter()
            .filter(|(k, _)| !hubs_own(k.as_str()))
            .cloned(),
    );
    // its shell steps' opens (`work::trace`): Claude Code runs each Bash call through Gleipnir's wrapper (the full
    // tier's), another CLI's whole tree gets the listener from the inner helper; never on macOS
    let trace_sock = run.join(paths::SESSION_TRACE_SOCKET);
    let trace = match (plan.trace, target) {
        (Some(gleipnir::trace::Scope::Step), gleipnir::Target::LinuxBwrap) => {
            vars.push((
                "CLAUDE_CODE_SHELL_PREFIX".into(),
                gleipnir::TRACE_INSIDE.into(),
            ));
            gleipnir::Trace::PerStep {
                socket: trace_sock.clone(),
            }
        }
        (
            Some(gleipnir::trace::Scope::Tree),
            gleipnir::Target::LinuxBwrap | gleipnir::Target::LinuxReduced,
        ) => gleipnir::Trace::Tree {
            socket: trace_sock.clone(),
        },
        _ => gleipnir::Trace::Off,
    };
    if !trace.is_off() {
        sockets.push(trace_sock);
    }
    if browser.is_some() {
        for (k, v) in &mut vars {
            if k.as_str() == "PATH" {
                *v = v
                    .split(':')
                    .filter(|d| !d.starts_with("/run/user"))
                    .collect::<Vec<_>>()
                    .join(":");
            }
        }
        vars.retain(|(_, v)| !v.contains("/run/user"));
    }
    let mut extra_tcp_ports = Vec::new();
    let spec_browser = browser.map(|(web_port, b)| {
        // the program's own folder (a download's, or one outside /usr and /opt) and fontconfig's cache, read by the
        // agent's layer and by the browser's
        let mut extra_read: Vec<PathBuf> = Path::new(FONTCONFIG_CACHE)
            .is_dir()
            .then(|| PathBuf::from(FONTCONFIG_CACHE))
            .into_iter()
            .collect();
        if let Some(dir) = b.program.parent()
            && !["/usr", "/opt"].iter().any(|r| b.program.starts_with(r))
        {
            extra_read.push(dir.to_path_buf());
        }
        read.extend(extra_read.iter().cloned());
        extra_tcp_ports.extend(b.local_ports.iter().copied());
        let kind = match b.kind {
            crate::browser::resolve::Kind::HeadlessShell => "--headless-shell",
            crate::browser::resolve::Kind::Full => "--full",
        };
        gleipnir::SpecBrowser {
            program: b.program.clone(),
            own_dir: gleipnir::BROWSER_DIR_FULL.into(),
            web_port,
            local_ports: b.local_ports.clone(),
            extra_read,
            host_args: vec![
                kind.into(),
                "--max-message".into(),
                b.max_message.to_string(),
            ],
        }
    });
    let spec = Spec {
        read,
        write,
        hide: tools.hide,
        sockets,
        binds,
        home: None,
        run: Some(Bind {
            mode: Mode::Ro,
            source: run.clone(),
            dest: run,
        }),
        env: vars,
        chdir: shape.cwd.clone(),
        net,
        tmp: Some(tmp),
        layers: Layers::for_target(target),
        extra_tcp_ports,
        trace,
        browser: spec_browser,
    };
    Ok(SessionSpec {
        spec,
        program: tools.program,
    })
}

#[cfg(test)]
mod tests;
