//! The commands that ask a running hub (or the machine) something: `status`, `doctor --json` and `restart`.
//!
//! `doctor --json` is
//! `{binary: {path, commit, test_hooks}, running: {commit, pid}?, gateway: {port, registrations, providers, keys_held,
//! warnings, keys_refused?}?, store: {schema, writer, failed, denied_in}?, socket_dir: {path, mode, ok}, sqlite,
//! job_agents, sandbox: {backend, version, ok, reason, fix, landlock_abi, in_use}}`.  `store` is the running hub's
//! work.db: a failed move to schema 7, and the copies that still hold what its deny-list kept out; and from files
//! (also with no hub, when work.db exists) `wal_bytes`, `last_backup`, `backup_ok`, `backup_age_s`, `deny_list:
//! {opted_in, warnings}`, `copies: {pre7, schema5}` and `warnings` (a WAL above 64 MiB, a backup older than 48 h or
//! one that failed its check, the opt-in file's problems).
//! `gateway` is the running hub's (its `status`): `keys_held` names providers only,
//! `warnings` are its clear-text providers (the settings' provider table), and `keys_refused` (only when there is one) says why
//! the hub takes no key: it could not keep other processes out of its memory (on macOS, started under a debugger). `sandbox` is the job sandbox's check
//! (`gleipnir::check`), `in_use` false until phase 6.
//! `socket_dir.ok` is true when the directory is the user's own with mode 0700, and also while it does not exist yet
//! (the hub makes it private at its first start); `mode` is then null.

use crate::client::{self, Client};
use crate::front::JOB_AGENTS;
use crate::sandbox;
use gleipnir::Tier;
use gleipnir::check::Check;
use runstav::paths::{self, Env};
use serde_json::{Value, json};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;

const ASK: Duration = Duration::from_secs(5);

/// `doctor`'s whole ask of a running hub (the user connection and its `status`),
/// and the least a ping after it gets: together under the 2 s the editor's doctor waits for the report (review M2),
/// so a slow hub is reported as running, not as a binary that gave no answer.
const DOCTOR_ASK: Duration = Duration::from_millis(1500);
const DOCTOR_PING: Duration = Duration::from_millis(300);
/// The sandbox check inside `doctor`, run beside the hub ask: a slow probe is reported as one that did not finish.
const DOCTOR_CHECK: Duration = Duration::from_millis(1400);
// core/drgnx-doctor.el waits 2 s for `doctor --json`
const _: () = assert!(DOCTOR_ASK.as_millis() + DOCTOR_PING.as_millis() < 2000);

/// The running hub's pid and commit, and its `status`'s `gateway` and `store`, for the report.
pub struct Running {
    pub pid: u32,
    pub commit: Option<String>,
    pub gateway: Option<Value>,
    pub store: Option<Value>,
}

/// The socket directory's state.
fn socket_dir(socket: &Path, uid: u32) -> Value {
    let dir = socket.parent().unwrap_or(Path::new("/"));
    match std::fs::symlink_metadata(dir) {
        Ok(m) => {
            let mode = m.permissions().mode() & 0o777;
            json!({
                "path": dir,
                "mode": format!("{mode:04o}"),
                "ok": m.is_dir() && mode == 0o700 && m.uid() == uid,
            })
        }
        Err(_) => json!({"path": dir, "mode": null, "ok": true}),
    }
}

/// The job sandbox section: what the check found. `in_use` is false until jobs run in it (phase 6).
fn sandbox_section(c: &Check) -> Value {
    json!({
        "backend": c.backend.name(),
        "version": c.version,
        "ok": c.ok,
        "reason": c.reason,
        "fix": c.fix,
        "landlock_abi": c.landlock_abi,
        "in_use": false,
    })
}

/// The doctor's text line about the sandbox. It says what works here and that jobs do not use it yet; it never says a
/// job is "sandboxed".
pub fn sandbox_line(c: &Check) -> String {
    if c.ok {
        let name = match &c.version {
            Some(v) => format!("{} {v}", c.backend.name()),
            None => c.backend.name().to_string(),
        };
        format!(
            "job sandbox backend: {name} works here ({}); job agents do not use it yet (phase 6)",
            c.layers_text()
        )
    } else {
        let mut out = format!(
            "job sandbox backend: not available here: {}",
            c.reason.as_deref().unwrap_or("unknown")
        );
        if let Some(fix) = &c.fix {
            out.push_str(&format!(" \u{2014} {fix}"));
        }
        out
    }
}

/// The doctor's report for ENV, with RUNNING when a hub answered.
pub fn report(env: &Env, binary: &Path, running: Option<Running>, sandbox: &Check) -> Value {
    let socket = paths::socket_path(env);
    let mut v = json!({
        "binary": {
            "path": binary,
            "commit": crate::version::COMMIT,
            "test_hooks": cfg!(feature = "test-hooks"),
        },
        "socket_dir": socket_dir(&socket, env.uid),
        "sqlite": crate::version::sqlite(),
        "job_agents": JOB_AGENTS,
        "sandbox": sandbox_section(sandbox),
    });
    if let Some(r) = running {
        v["running"] = json!({"pid": r.pid, "commit": r.commit});
        if let Some(g) = r.gateway {
            v["gateway"] = json!({
                "port": g["port"],
                "registrations": g["registrations"],
                "providers": g["providers"],
                "keys_held": g.get("keys_held").cloned().unwrap_or_else(|| json!([])),
                "warnings": g.get("warnings").cloned().unwrap_or_else(|| json!([])),
            });
            if let Some(why) = g.get("keys_refused").filter(|w| w.is_string()) {
                v["gateway"]["keys_refused"] = why.clone();
            }
        }
        if let Some(s) = r.store {
            v["store"] = json!({
                "schema": s["schema"],
                "writer": s["writer"],
                "failed": s.get("failed").cloned().unwrap_or(Value::Null),
                "denied_in": s.get("denied_in").cloned().unwrap_or_else(|| json!([])),
            });
            for k in ["wal_bytes", "last_backup", "backup_ok"] {
                if let Some(x) = s.get(k) {
                    v["store"][k] = x.clone();
                }
            }
        }
    }
    store_files(env, &mut v, now_secs());
    v
}

/// work.db's WAL above this size warns: an editor that keeps a read open stops it being checkpointed.
pub const WAL_WARN: u64 = 64 << 20;

/// A backup older than this warns (the nightly one is at 03:00).
pub const BACKUP_STALE: u64 = 48 * 3600;

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Unix seconds of `YYYY-MM-DDTHH:MM:SSZ` (what `status.store.last_backup` is).
fn parse_rfc3339(t: &str) -> Option<u64> {
    let (date, time) = t.strip_suffix('Z')?.split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let mut c = time.split(':').map(|x| x.parse::<i64>().ok());
    let (h, mi, s) = (c.next()??, c.next()??, c.next()??);
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    u64::try_from(days * 86_400 + h * 3600 + mi * 60 + s).ok()
}

/// The store section's facts that live in files, and its warnings: the WAL's size, the newest dated copy, the
/// personal-notes opt-in file (norn's deny-list as it loads now), and the copies a deny-list kept text out of
/// (`work-pre7-*.db`, `work.db.schema5`).  The section appears when the hub told its `store` or `work.db` exists.
/// The FTS and integrity checks run on each nightly copy before it is kept (`backup_ok`); the live file is never
/// opened here (one writer, and `integrity-check` is a write).
fn store_files(env: &Env, v: &mut Value, now: u64) {
    let data = paths::data_dir(env);
    let work = data.join("work.db");
    if v.get("store").is_none() && !work.exists() {
        return;
    }
    if v.get("store").is_none() {
        v["store"] = json!({});
    }
    let mut warnings: Vec<String> = Vec::new();
    // the WAL
    if v["store"].get("wal_bytes").is_none() {
        let mut wal = work.as_os_str().to_owned();
        wal.push("-wal");
        if let Ok(m) = std::fs::metadata(&wal) {
            v["store"]["wal_bytes"] = json!(m.len());
        }
    }
    if let Some(b) = v["store"]["wal_bytes"].as_u64().filter(|b| *b > WAL_WARN) {
        warnings.push(format!(
            "work.db-wal is {} MiB (above {} MiB): close idle editors so it can be checkpointed",
            b >> 20,
            WAL_WARN >> 20
        ));
    }
    // the last backup: the hub's word, else the newest dated copy on disk
    let backup = data.join("backup");
    let mut dated: Vec<(u64, String)> = std::fs::read_dir(&backup)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let at = e.metadata().ok()?.modified().ok()?;
            let at = at.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
            (name.starts_with("work-") && name.ends_with(".db") && !name.starts_with("work-pre7-"))
                .then_some((at, name))
        })
        .collect();
    dated.sort();
    let at = v["store"]["last_backup"]
        .as_str()
        .and_then(parse_rfc3339)
        .or_else(|| dated.last().map(|(t, _)| *t));
    if v["store"].get("last_backup").is_none()
        && let Some(t) = at
    {
        v["store"]["last_backup"] = json!(crate::log::rfc3339(t));
    }
    if let Some(t) = at {
        v["store"]["backup_age_s"] = json!(now.saturating_sub(t));
    }
    match at {
        Some(t) if now.saturating_sub(t) > BACKUP_STALE => warnings.push(format!(
            "the last backup is {} hours old (the nightly one runs at 03:00): `drgnx graph backup`",
            now.saturating_sub(t) / 3600
        )),
        None if work.exists() => {
            warnings.push("work.db has no backup yet: `drgnx graph backup`".into())
        }
        _ => {}
    }
    if v["store"]["backup_ok"] == false {
        warnings.push(
            "the last backup failed its integrity or full-text check; the older copy was kept: see the hub log"
                .into(),
        );
    }
    // the personal-notes opt-in file, as it loads now
    if let Some(home) = env.vars.get("HOME").filter(|h| Path::new(h).is_absolute()) {
        let deny = norn::deny::DenyList::load(Path::new(home), &paths::config_dir(env));
        v["store"]["deny_list"] = json!({
            "opted_in": deny.opt_ins().len(),
            "warnings": deny.warnings(),
        });
        warnings.extend(deny.warnings().iter().cloned());
    }
    // the copies that may hold what the deny-list kept out
    let pre7: Vec<String> = std::fs::read_dir(&backup)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("work-pre7-"))
        .collect();
    let mut schema5 = work.as_os_str().to_owned();
    schema5.push(".schema5");
    v["store"]["copies"] = json!({
        "pre7": pre7,
        "schema5": std::path::PathBuf::from(schema5).exists(),
    });
    v["store"]["warnings"] = json!(warnings);
}

/// What the doctor and `status` say of work.db beyond "ready": a migration that failed (and how to go back), and the
/// copies that still hold what the migration's deny-list kept out.
fn store_lines(store: &Value) -> String {
    let mut out = String::new();
    if let Some(why) = store.get("failed").and_then(Value::as_str) {
        out.push_str(&format!(
            "\nwork.db: {why} (work.db is still schema 6; `ratatoskr store restore-pre7` puts the pre-migration copy \
             back if it is needed)"
        ));
    }
    for w in store
        .get("warnings")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        out.push_str(&format!("\nwork.db: {w}"));
    }
    if let Some(copies) = store.get("denied_in").and_then(Value::as_array)
        && !copies.is_empty()
    {
        let names: Vec<&str> = copies.iter().filter_map(Value::as_str).collect();
        out.push_str(&format!(
            "\nwork.db: the migration kept personal notes out; these copies still hold them, remove them once you \
             no longer need them: {}",
            names.join(", ")
        ));
    }
    out
}

/// `status`: the hub's `status` (with `"running": true`), or `{"running": false}` and exit 1 when none answers.
pub fn status(env: &Env, json_out: bool) -> i32 {
    let socket = paths::socket_path(env);
    if let Some(why) = client::refused(&socket) {
        if json_out {
            println!("{}", json!({"running": false, "error": why}));
        }
        eprintln!("ratatoskr status: {why}");
        return 1;
    }
    let asked = Client::user(env, ASK).and_then(|mut c| c.call("status", json!({}), ASK));
    match asked {
        Ok(mut v) => {
            if json_out {
                v["running"] = json!(true);
                println!("{v}");
            } else {
                println!("{}", summary(&v));
            }
            0
        }
        Err(e) => match client::ping(&socket, Duration::from_secs(1)) {
            // a hub answers but would not tell: say so rather than "not running"
            Some(pid) => {
                if json_out {
                    println!("{}", json!({"running": true, "pid": pid, "error": e}));
                } else {
                    println!("running (pid {pid}), but status failed: {e}");
                }
                1
            }
            None => {
                if json_out {
                    println!("{}", json!({"running": false}));
                } else {
                    println!("not running");
                }
                1
            }
        },
    }
}

/// The lines `status` prints without `--json`.
fn summary(v: &Value) -> String {
    let text = |p: &Value| p.as_str().unwrap_or("?").to_string();
    let mut out = format!(
        "running: pid {}, commit {}, socket {}",
        v["pid"],
        text(&v["runtime"]["commit"]),
        text(&v["socket"])
    );
    if let Some(b) = v.get("backend") {
        out.push_str(&format!("\nbackend: {}", text(&b["state"])));
        if let Some(pid) = b.get("pid") {
            out.push_str(&format!(" (pid {pid})"));
        }
    }
    if let Some(n) = v.get("read_only") {
        out.push_str(&format!(
            "\nread-only: work.db is schema {n}, newer than this hub's"
        ));
    }
    if let Some(s) = v.get("store") {
        out.push_str(&store_lines(s));
    }
    out.push_str(&keys_refused_line(&v["gateway"]));
    out.push_str(&format!("\njob agents: {}", text(&v["job_agents"])));
    out
}

/// `doctor`: `--json` is the report; without it, a few lines of text. The sandbox check runs beside the hub ask, so
/// the two together stay under the editor's 2 s.
pub fn doctor(env: &Env, json_out: bool) -> i32 {
    let socket = paths::socket_path(env);
    let binary = crate::idle::resolve_exe()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let deadline = std::time::Instant::now() + DOCTOR_ASK;
    let left = || deadline.saturating_duration_since(std::time::Instant::now());
    let (running, sandbox) = std::thread::scope(|s| {
        let check = s.spawn(|| sandbox::check_blocking(Tier::Full, None, DOCTOR_CHECK));
        let running = Client::user(env, left())
            .and_then(|mut c| c.call("status", json!({}), left()))
            .ok()
            .map(|s| Running {
                pid: s["pid"]
                    .as_u64()
                    .and_then(|p| u32::try_from(p).ok())
                    .unwrap_or(0),
                commit: s["runtime"]["commit"].as_str().map(str::to_string),
                gateway: s.get("gateway").cloned(),
                store: s.get("store").cloned(),
            })
            .or_else(|| {
                client::ping(&socket, left().max(DOCTOR_PING)).map(|pid| Running {
                    pid,
                    commit: None,
                    gateway: None,
                    store: None,
                })
            });
        let check = check
            .join()
            .unwrap_or_else(|_| Check::failed("the check panicked".into(), None));
        (running, check)
    });
    let v = report(env, &binary, running, &sandbox);
    if json_out {
        println!("{v}");
    } else {
        println!("{}", text(&v, &sandbox));
    }
    0
}

/// The lines `doctor` prints without `--json`.
fn text(v: &Value, sandbox: &Check) -> String {
    let t = |p: &Value| p.as_str().unwrap_or("?").to_string();
    let mut out = format!(
        "binary: {} (commit {})\nsocket dir: {} (mode {}, {})",
        t(&v["binary"]["path"]),
        t(&v["binary"]["commit"]),
        t(&v["socket_dir"]["path"]),
        t(&v["socket_dir"]["mode"]),
        if v["socket_dir"]["ok"] == true {
            "ok"
        } else {
            "not private"
        },
    );
    if let Some(r) = v.get("running") {
        out.push_str(&format!("\nrunning: pid {}", r["pid"]));
    }
    if let Some(s) = v.get("store") {
        out.push_str(&store_lines(s));
    }
    out.push_str(&keys_refused_line(&v["gateway"]));
    out.push_str(&format!("\njob agents: {}", t(&v["job_agents"])));
    out.push_str(&format!("\n{}", sandbox_line(sandbox)));
    out
}

/// A line for a running hub that refuses keys (its GATEWAY status says why), else nothing.
fn keys_refused_line(gateway: &Value) -> String {
    gateway["keys_refused"]
        .as_str()
        .map(|why| format!("\nkeys: refused, this hub cannot protect keys: {why}"))
        .unwrap_or_default()
}

/// `restart`: ask the running hub to restart (it answers, then exits 75 or re-executes itself).
pub fn restart(env: &Env) -> i32 {
    match Client::user(env, ASK).and_then(|mut c| c.call("restart", json!({}), ASK)) {
        Ok(_) => {
            println!("restarting");
            0
        }
        Err(e) => {
            eprintln!("ratatoskr restart: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_report_has_every_key_and_judges_the_socket_dir() {
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path().join("r");
        std::fs::create_dir(&run).unwrap();
        std::fs::set_permissions(&run, std::fs::Permissions::from_mode(0o700)).unwrap();
        let uid = rustix::process::geteuid().as_raw();
        let p = |s: &str| dir.path().join(s).to_string_lossy().into_owned();
        let env = Env::new(
            &[
                ("XDG_RUNTIME_DIR", &p("r")),
                ("DRGNX_DATA_DIR", &p("d")),
                ("XDG_STATE_HOME", &p("s")),
                ("HOME", &p("h")),
            ],
            uid,
        );
        let sock_dir = paths::socket_path(&env).parent().unwrap().to_path_buf();
        std::fs::create_dir_all(&sock_dir).unwrap();
        std::fs::set_permissions(&sock_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let v = report(&env, Path::new("/opt/ratatoskr"), None, &working());
        assert_eq!(v["binary"]["path"], "/opt/ratatoskr");
        assert_eq!(v["binary"]["commit"], crate::version::COMMIT);
        assert_eq!(v["binary"]["test_hooks"], cfg!(feature = "test-hooks"));
        assert_eq!(v["socket_dir"]["mode"], "0700");
        assert_eq!(v["socket_dir"]["ok"], true);
        assert!(v["sqlite"].as_str().unwrap().starts_with("3."));
        assert_eq!(v["job_agents"], JOB_AGENTS);
        assert!(v.get("running").is_none());
        // too open: not ok
        std::fs::set_permissions(&sock_dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let open = report(&env, Path::new("/b"), None, &working());
        assert_eq!(open["socket_dir"]["ok"], false);
        assert_eq!(open["socket_dir"]["mode"], "0755");
        let up = report(
            &env,
            Path::new("/b"),
            Some(Running {
                pid: 7,
                commit: Some("abc".into()),
                gateway: Some(
                    json!({"port": 4100, "registrations": 2, "requests": 9, "providers": 3,
                    "keys_held": ["openrouter"],
                    "warnings": [{"provider": "lan", "text": "lan's key travels in clear text over http://192.0.2.10; use https"}]}),
                ),
                store: Some(json!({"schema": 6, "writer": "not-ready", "writes": 0,
                    "failed": "the move of work.db to schema 7 failed: x", "denied_in": ["/d/backup/work-pre7-1.db"]})),
            }),
            &working(),
        );
        for (k, want) in [
            ("schema", json!(6)),
            ("writer", json!("not-ready")),
            ("failed", json!("the move of work.db to schema 7 failed: x")),
            ("denied_in", json!(["/d/backup/work-pre7-1.db"])),
            ("warnings", json!([])),
        ] {
            assert_eq!(up["store"][k], want, "{k}");
        }
        assert_eq!(
            up["store"]["deny_list"],
            json!({"opted_in": 0, "warnings": []})
        );
        let lines = store_lines(&up["store"]);
        assert!(lines.contains("restore-pre7"), "{lines}");
        assert!(lines.contains("/d/backup/work-pre7-1.db"), "{lines}");
        assert_eq!(up["running"], json!({"pid": 7, "commit": "abc"}));
        // the gateway's ids and warnings only, never its traffic
        assert_eq!(
            up["gateway"],
            json!({"port": 4100, "registrations": 2, "providers": 3, "keys_held": ["openrouter"],
                   "warnings": [{"provider": "lan", "text": "lan's key travels in clear text over http://192.0.2.10; use https"}]})
        );
        assert!(open.get("gateway").is_none());
    }

    #[test]
    fn rfc3339_reads_back_what_the_log_writes() {
        for secs in [0, 86_399, 19_782 * 86_400 + 3_661, 1_800_000_000] {
            assert_eq!(parse_rfc3339(&crate::log::rfc3339(secs)), Some(secs));
        }
        assert_eq!(parse_rfc3339("yesterday"), None);
    }

    /// The store section from files alone: a big WAL, a stale backup, a bad opt-in file and the copies kept.
    #[test]
    fn the_store_section_warns_and_lists_the_copies() {
        let dir = tempfile::tempdir().unwrap();
        let (data, home, config) = (
            dir.path().join("d"),
            dir.path().join("h"),
            dir.path().join("c"),
        );
        std::fs::create_dir_all(data.join("backup")).unwrap();
        std::fs::create_dir_all(home.join("org")).unwrap();
        std::fs::create_dir_all(&config).unwrap();
        std::fs::write(data.join("work.db"), b"x").unwrap();
        let wal = std::fs::File::create(data.join("work.db-wal")).unwrap();
        wal.set_len(WAL_WARN + (1 << 20)).unwrap();
        std::fs::write(data.join("work.db.schema5"), b"x").unwrap();
        std::fs::write(data.join("backup/work-pre7-1.db"), b"x").unwrap();
        std::fs::write(data.join("backup/work-20200101.db"), b"x").unwrap();
        // an opt-in file anyone can write is refused with a warning
        let allow = config.join("personal-notes-allow.json");
        std::fs::write(&allow, "[]").unwrap();
        std::fs::set_permissions(&allow, std::fs::Permissions::from_mode(0o666)).unwrap();
        let path = |p: &Path| p.to_string_lossy().into_owned();
        let env = Env::new(
            &[
                ("DRGNX_DATA_DIR", &path(&data)),
                ("DRGNX_CONFIG_DIR", &path(&config)),
                ("HOME", &path(&home)),
            ],
            1000,
        );
        let mut v = json!({});
        let long_after = now_secs() + 3 * 86_400;
        store_files(&env, &mut v, long_after);
        let s = &v["store"];
        let w = s["warnings"].to_string();
        assert!(w.contains("close idle editors"), "{w}");
        assert!(w.contains("hours old"), "{w}");
        assert!(
            w.contains("writable") || w.contains("personal-notes-allow"),
            "{w}"
        );
        assert_eq!(
            s["copies"],
            json!({"pre7": ["work-pre7-1.db"], "schema5": true})
        );
        assert_eq!(s["deny_list"]["opted_in"], 0);
        assert!(s["backup_age_s"].as_u64().unwrap() > BACKUP_STALE);
        // no work.db and no hub: no section
        let mut none = json!({});
        let empty = Env::new(&[("DRGNX_DATA_DIR", &path(&dir.path().join("none")))], 1000);
        store_files(&empty, &mut none, 0);
        assert!(none.get("store").is_none());
    }

    #[test]
    fn a_missing_socket_dir_is_fine_until_the_first_start() {
        let env = Env::new(
            &[
                ("XDG_STATE_HOME", "/nonexistent/s"),
                ("HOME", "/nonexistent/h"),
            ],
            1000,
        );
        let v = report(&env, Path::new("/b"), None, &working());
        assert_eq!(v["socket_dir"]["ok"], true);
        assert!(v["socket_dir"]["mode"].is_null());
    }

    fn working() -> Check {
        Check {
            backend: gleipnir::BackendKind::Bwrap,
            program: Some("/usr/bin/bwrap".into()),
            version: Some("0.12.0".into()),
            ok: true,
            reason: None,
            fix: None,
            layers: Some(gleipnir::LayersReport {
                landlock_abi: 10,
                landlock: "enforced".into(),
                seccomp: true,
                no_new_privs: true,
                new_session: true,
                relay: true,
                seatbelt: false,
            }),
            landlock_abi: 10,
            container: false,
            stderr: None,
        }
    }

    fn broken() -> Check {
        Check {
            ok: false,
            backend: gleipnir::BackendKind::None,
            reason: Some(
                "AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later)".into(),
            ),
            fix: Some("load the profile".into()),
            layers: None,
            ..working()
        }
    }

    fn report_of(c: &Check) -> Value {
        let env = Env::new(&[("HOME", "/nonexistent/h")], 1000);
        report(&env, Path::new("/b"), None, c)
    }

    #[test]
    fn sandbox_section_shape() {
        let v = report_of(&working());
        assert_eq!(
            v["sandbox"],
            json!({
                "backend": "bwrap", "version": "0.12.0", "ok": true, "reason": null, "fix": null,
                "landlock_abi": 10, "in_use": false,
            })
        );
        let v = report_of(&broken());
        assert_eq!(v["sandbox"]["backend"], "none");
        assert_eq!(v["sandbox"]["ok"], false);
        assert!(
            v["sandbox"]["reason"]
                .as_str()
                .unwrap()
                .starts_with("AppArmor")
        );
        assert_eq!(v["sandbox"]["fix"], "load the profile");
        assert_eq!(v["sandbox"]["in_use"], false);
        assert_eq!(
            sandbox_line(&working()),
            "job sandbox backend: bwrap 0.12.0 works here (Landlock ABI 10, seccomp); job agents do not use it yet (phase 6)"
        );
        assert_eq!(
            sandbox_line(&broken()),
            "job sandbox backend: not available here: AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later) \u{2014} load the profile"
        );
    }

    /// Nothing runs in the sandbox yet, so no state of the check says a job is sandboxed: not the line, not the section.
    #[test]
    fn sandbox_line_never_says_sandboxed() {
        let seatbelt = Check {
            backend: gleipnir::BackendKind::Seatbelt,
            version: None,
            layers: Some(gleipnir::LayersReport::seatbelt()),
            ..working()
        };
        for c in [
            working(),
            broken(),
            seatbelt,
            Check::failed("x".into(), None),
        ] {
            let line = sandbox_line(&c);
            let section = report_of(&c)["sandbox"].to_string();
            let text = text(&report_of(&c), &c);
            for s in [&line, &section] {
                assert!(!s.to_lowercase().contains("sandboxed"), "{s}");
            }
            // the text as a whole may say what job agents do today ("unsandboxed"), but never claims otherwise
            assert!(
                text.lines()
                    .all(|l| !l.contains("sandboxed") || l.starts_with("job agents: unsandboxed")),
                "{text}"
            );
        }
        assert!(sandbox_line(&working()).contains("job agents do not use it yet"));
    }

    /// Review m2: a hub that refuses keys (on macOS, started under a debugger) says why in `doctor` and `status`.
    #[test]
    fn a_hub_that_refuses_keys_says_so() {
        let env = Env::new(
            &[
                ("XDG_STATE_HOME", "/nonexistent/s"),
                ("HOME", "/nonexistent/h"),
            ],
            1000,
        );
        let why = "cannot deny debuggers the hub: Operation not permitted (os error 1)";
        let up = report(
            &env,
            Path::new("/b"),
            Some(Running {
                pid: 7,
                commit: None,
                gateway: Some(
                    json!({"port": 4100, "registrations": 0, "providers": 0, "keys_refused": why}),
                ),
                store: None,
            }),
            &working(),
        );
        assert_eq!(up["gateway"]["keys_refused"], why);
        let line = format!("keys: refused, this hub cannot protect keys: {why}");
        assert!(text(&up, &working()).contains(&line));
        let s = summary(
            &json!({"pid": 5, "socket": "/s", "runtime": {"commit": "c1"},
                                "gateway": {"keys_refused": why}, "job_agents": JOB_AGENTS}),
        );
        assert!(s.contains(&line), "{s}");
        // a hub that takes keys: no such key, no such line
        let fine = report(
            &env,
            Path::new("/b"),
            Some(Running {
                pid: 7,
                commit: None,
                gateway: Some(json!({"port": 4100, "registrations": 0, "providers": 0})),
                store: None,
            }),
            &working(),
        );
        assert!(fine["gateway"].get("keys_refused").is_none());
        assert!(!text(&fine, &working()).contains("keys: refused"));
    }

    #[test]
    fn the_summary_names_pid_commit_backend_and_job_agents() {
        let s = summary(&json!({
            "pid": 5, "socket": "/s", "runtime": {"commit": "c1"},
            "backend": {"state": "running", "pid": 9}, "job_agents": JOB_AGENTS,
        }));
        assert!(s.contains("pid 5, commit c1, socket /s"), "{s}");
        assert!(s.contains("backend: running (pid 9)"), "{s}");
        assert!(s.contains("unsandboxed (as on main"), "{s}");
    }
}
