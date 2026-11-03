//! What the Lisp runtime left behind, handled at the first start after the update (docs/develop/hub.md, "Start";
//! docs/guide/install.md, "Updating past phase 7").
//!
//! [`migrate`] moves the old hub's state aside, never deleting it, into `<state>/hub/migrated-p7/` (0700), with the
//! original names kept:
//!
//! - from `<state>/hub/`: `registrations.eld`, `sessions.eld`, `port`, `hub-timers-report.eld`, the folder `bodies/` and
//!   every `hub-*.d/` folder that holds only `backend.sock`;
//! - `<state>/sandbox/`;
//! - the editor's command jobs, `<state>/jobs/<id>/`, but only a job that has ended (an `exit` file, or a `pid` file
//!   that names a process that is gone).  A job that still runs keeps its folder, so its log is not pulled from under
//!   it, and is reported in `left` until a later start finds it ended.
//!
//! `migrated-p7/done` (a JSON [`Moved`]) makes later starts move nothing but the jobs that have ended since.  A move
//! across filesystems copies, syncs and only then removes the source; a copy that fails leaves the source where it
//! was.  The old backend's process is reaped before this runs, like any recorded group (`server::reap_recorded`).
//!
//! [`section`] is the doctor's `legacy` section: what was moved, what is left, and the user's processes that are still
//! the Lisp runtime's (`drgnx-hub-main`, `drgnx-coord-mcp-main`).

use runstav::paths::{self, Env};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The folder under `<state>/hub/` that takes what moves.
pub const DIR: &str = "migrated-p7";
const DONE: &str = "done";
const HUB_FILES: [&str; 5] = [
    "registrations.eld",
    "sessions.eld",
    "port",
    "hub-timers-report.eld",
    "bodies",
];
/// A job folder with no readable `pid` and no `exit` is a job still starting until its folder has been quiet this long.
const JOB_QUIET: Duration = Duration::from_secs(60);
/// What names the Lisp runtime's processes on their command lines.
const MARKERS: [&str; 2] = ["drgnx-hub-main", "drgnx-coord-mcp-main"];

/// What [`migrate`] did, as `done` records it: where things went, what moved, and what stays (a running job, or
/// something that could not move), as names relative to the state directory.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Moved {
    pub at: Option<PathBuf>,
    pub moved: Vec<String>,
    pub left: Vec<String>,
}

/// The one `rename` the moves go through: a test replaces it to make a move cross a filesystem.
type Rename<'a> = &'a dyn Fn(&Path, &Path) -> io::Result<()>;

struct Item {
    name: String,
    from: PathBuf,
    to: PathBuf,
}

/// Move what the Lisp runtime left in ENV's state directory aside (see the module).  A name that cannot move is
/// logged and listed in `left`; an error is only a `migrated-p7` that cannot be made or recorded.
pub fn migrate(env: &Env) -> io::Result<Moved> {
    migrate_in(&paths::state_dir(env), &by_rename)
}

fn by_rename(from: &Path, to: &Path) -> io::Result<()> {
    std::fs::rename(from, to)
}

fn migrate_in(state: &Path, rename: Rename) -> io::Result<Moved> {
    let mig = state.join("hub").join(DIR);
    let done_path = mig.join(DONE);
    let prior = read_done(&done_path);
    let (items, jobs_left) = plan(state, &mig, prior.is_none());
    let mut m = prior.clone().unwrap_or_default();
    let mut left: Vec<String> = m
        .left
        .iter()
        .filter(|n| !n.starts_with("jobs/"))
        .cloned()
        .collect();
    left.extend(jobs_left);
    left.sort();
    if items.is_empty() && (left.is_empty() || prior.as_ref().is_some_and(|p| p.left == left)) {
        // nothing to move, and nothing new to say (a first start on a fresh install writes nothing at all)
        return Ok(m);
    }
    paths::private_dir(&mig)?;
    for it in items {
        if std::fs::symlink_metadata(&it.to).is_ok() {
            tracing::warn!(
                "{} is already in {}: left where it is",
                it.name,
                mig.display()
            );
            left.push(it.name);
            continue;
        }
        if it.name.starts_with("jobs/") {
            paths::private_dir(&mig.join("jobs"))?;
        }
        match relocate(rename, &it.from, &it.to) {
            Ok(()) => m.moved.push(it.name),
            Err(e) => {
                tracing::warn!("cannot move {} aside: {e}: left where it is", it.name);
                left.push(it.name);
            }
        }
    }
    left.sort();
    left.dedup();
    m.left = left;
    m.at = Some(mig);
    write_done(&done_path, &m)?;
    Ok(m)
}

/// What to move, and the jobs that stay.  The hub's own files and `sandbox/` only on the first pass.
fn plan(state: &Path, mig: &Path, first: bool) -> (Vec<Item>, Vec<String>) {
    let hub = state.join("hub");
    let mut items = Vec::new();
    let mut add = |name: String, from: PathBuf, to: PathBuf| items.push(Item { name, from, to });
    if first {
        for f in HUB_FILES {
            if std::fs::symlink_metadata(hub.join(f)).is_ok() {
                add(format!("hub/{f}"), hub.join(f), mig.join(f));
            }
        }
        for n in names(&hub) {
            if n.starts_with("hub-")
                && n.ends_with(".d")
                && holds_only_the_backend_socket(&hub.join(&n))
            {
                add(format!("hub/{n}"), hub.join(&n), mig.join(&n));
            }
        }
        if std::fs::symlink_metadata(state.join("sandbox")).is_ok() {
            add("sandbox".into(), state.join("sandbox"), mig.join("sandbox"));
        }
    }
    let mut left = Vec::new();
    let jobs = state.join("jobs");
    for id in names(&jobs) {
        let dir = jobs.join(&id);
        if !std::fs::symlink_metadata(&dir).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        if job_ended(&dir) {
            add(format!("jobs/{id}"), dir, mig.join("jobs").join(&id));
        } else {
            left.push(format!("jobs/{id}"));
        }
    }
    (items, left)
}

/// The sorted names in DIR (none when it is not there).
fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    v.sort();
    v
}

fn holds_only_the_backend_socket(dir: &Path) -> bool {
    std::fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir()) && names(dir) == ["backend.sock"]
}

/// Whether the command job in DIR has ended: an `exit` file, or a `pid` file naming a process that is gone.  A pid
/// that cannot be read counts as a job still starting until its folder has been quiet for [`JOB_QUIET`].
fn job_ended(dir: &Path) -> bool {
    if dir.join("exit").exists() {
        return true;
    }
    let pid = std::fs::read_to_string(dir.join("pid"))
        .ok()
        .and_then(|t| t.trim().parse::<i32>().ok())
        .filter(|p| *p > 0);
    match pid {
        Some(p) => !draugr::alive(p),
        None => std::fs::metadata(dir)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| SystemTime::now().duration_since(t).ok())
            .is_some_and(|age| age >= JOB_QUIET),
    }
}

fn read_done(path: &Path) -> Option<Moved> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn write_done(path: &Path, m: &Moved) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(&serde_json::to_vec(m).map_err(io::Error::other)?)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;
    sync_dir(path.parent().unwrap_or(Path::new("/")))
}

fn sync_dir(dir: &Path) -> io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
}

/// FROM to TO, by rename; across filesystems (EXDEV) by copy, sync, then removal of the source.  The copy is made
/// under a name of its own and renamed into place, so a failed copy leaves no half-made TO and the source untouched.
fn relocate(rename: Rename, from: &Path, to: &Path) -> io::Result<()> {
    match rename(from, to) {
        Err(e) if e.raw_os_error() == Some(libc::EXDEV) => {}
        done => return done,
    }
    let name = to.file_name().unwrap_or_default().to_string_lossy();
    let partial = to.with_file_name(format!(".{name}.partial"));
    if std::fs::symlink_metadata(&partial).is_ok() {
        remove_any(&partial)?; // a copy of ours that a crash cut short
    }
    let made = copy_tree(from, &partial).and_then(|()| std::fs::rename(&partial, to));
    if let Err(e) = made {
        let _ = remove_any(&partial);
        return Err(e);
    }
    sync_dir(to.parent().unwrap_or(Path::new("/")))?;
    remove_any(from)
}

/// SRC copied to DST (which must not exist), every file and folder synced.  What is neither a file, a folder nor a
/// link (a socket) cannot be copied: an error.
fn copy_tree(src: &Path, dst: &Path) -> io::Result<()> {
    let meta = std::fs::symlink_metadata(src)?;
    let kind = meta.file_type();
    if kind.is_dir() {
        std::fs::create_dir(dst)?;
        for n in names(src) {
            copy_tree(&src.join(&n), &dst.join(&n))?;
        }
        std::fs::set_permissions(dst, meta.permissions())?;
        sync_dir(dst)
    } else if kind.is_file() {
        std::fs::copy(src, dst)?;
        std::fs::File::open(dst)?.sync_all()
    } else if kind.is_symlink() {
        std::os::unix::fs::symlink(std::fs::read_link(src)?, dst)
    } else {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            format!("{} is not a file, a folder or a link", src.display()),
        ))
    }
}

fn remove_any(path: &Path) -> io::Result<()> {
    if std::fs::symlink_metadata(path)?.is_dir() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    }
}

/// A process of the user's that is still the Lisp runtime's.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LispProcess {
    pub pid: u32,
    pub what: String,
}

fn marker_in(cmdline: &str) -> Option<&'static str> {
    MARKERS.into_iter().find(|m| cmdline.contains(m))
}

/// The doctor's `legacy` section: `{moved, left, at, lisp_processes}`.  `left` is read afresh (a job may have ended
/// since the last start).
pub fn section(env: &Env) -> Value {
    let state = paths::state_dir(env);
    let mig = state.join("hub").join(DIR);
    let done = read_done(&mig.join(DONE)).unwrap_or_default();
    let (_, jobs_left) = plan(&state, &mig, false);
    let mut left: Vec<String> = done
        .left
        .into_iter()
        .filter(|n| !n.starts_with("jobs/"))
        .chain(jobs_left)
        .collect();
    left.sort();
    json!({
        "moved": done.moved,
        "left": left,
        "at": done.at,
        "lisp_processes": lisp_processes(env.uid),
    })
}

/// The user's processes whose command line has `drgnx-hub-main` or `drgnx-coord-mcp-main`.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn lisp_processes(uid: u32) -> Vec<LispProcess> {
    scan_proc(Path::new("/proc"), uid)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn scan_proc(root: &Path, uid: u32) -> Vec<LispProcess> {
    use std::os::unix::fs::MetadataExt;
    let mut out: Vec<LispProcess> = names(root)
        .into_iter()
        .filter_map(|n| {
            let pid = n.parse::<u32>().ok()?;
            let dir = root.join(&n);
            if std::fs::metadata(&dir).ok()?.uid() != uid {
                return None;
            }
            let raw = std::fs::read(dir.join("cmdline")).ok()?;
            let what = marker_in(&String::from_utf8_lossy(&raw).replace('\0', " "))?;
            Some(LispProcess {
                pid,
                what: what.to_string(),
            })
        })
        .collect();
    out.sort_by_key(|p| p.pid);
    out
}

/// The same, from `ps` (macOS has no `/proc`), given [`PS_DEADLINE`] to answer.
#[cfg(target_os = "macos")]
pub fn lisp_processes(uid: u32) -> Vec<LispProcess> {
    const PS_DEADLINE: Duration = Duration::from_secs(2);
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let out = std::process::Command::new("ps")
            .args(["-x", "-U", &uid.to_string(), "-o", "pid=,command="])
            .output();
        let _ = tx.send(out);
    });
    let Ok(Ok(out)) = rx.recv_timeout(PS_DEADLINE) else {
        return Vec::new();
    };
    let mut found: Vec<LispProcess> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let (pid, command) = l.trim_start().split_once(' ')?;
            Some(LispProcess {
                pid: pid.parse().ok()?,
                what: marker_in(command)?.to_string(),
            })
        })
        .collect();
    found.sort_by_key(|p| p.pid);
    found
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
pub fn lisp_processes(_uid: u32) -> Vec<LispProcess> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    fn put(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn exdev(_: &Path, _: &Path) -> io::Result<()> {
        Err(io::Error::from_raw_os_error(libc::EXDEV))
    }

    /// A state directory holding what the Lisp hub left.
    fn old_state() -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        plant(t.path());
        t
    }

    fn plant(s: &Path) {
        for f in [
            "registrations.eld",
            "sessions.eld",
            "port",
            "hub-timers-report.eld",
        ] {
            put(&s.join("hub").join(f), &format!("old {f}"));
        }
        put(&s.join("hub/bodies/b1"), "body");
        put(&s.join("hub/hub-ab12.d/backend.sock"), "");
        put(&s.join("hub/hub-keep.d/backend.sock"), "");
        put(&s.join("hub/hub-keep.d/other"), "stays");
        put(&s.join("hub/runtime.db"), "stays");
        put(&s.join("sandbox/profile.eld"), "sb");
    }

    fn moved_names() -> Vec<String> {
        [
            "hub/registrations.eld",
            "hub/sessions.eld",
            "hub/port",
            "hub/hub-timers-report.eld",
            "hub/bodies",
            "hub/hub-ab12.d",
            "sandbox",
        ]
        .map(String::from)
        .to_vec()
    }

    #[test]
    fn moves_each_file_once() {
        let t = old_state();
        let s = t.path();
        let m = migrate_in(s, &by_rename).unwrap();
        assert_eq!(m.moved, moved_names());
        assert!(m.left.is_empty());
        assert_eq!(m.at, Some(s.join("hub").join(DIR)));
        for n in [
            "registrations.eld",
            "sessions.eld",
            "port",
            "hub-timers-report.eld",
        ] {
            assert!(!s.join("hub").join(n).exists(), "{n} was left in hub/");
        }
        assert!(!s.join("sandbox").exists());
        // the rest of hub/ is not the old runtime's
        assert!(s.join("hub/runtime.db").exists());
        assert!(s.join("hub/hub-keep.d/other").exists());
        // a second start moves nothing, even when the old files are there again
        put(&s.join("hub/registrations.eld"), "new");
        let again = migrate_in(s, &by_rename).unwrap();
        assert_eq!(again, m);
        assert_eq!(
            std::fs::read_to_string(s.join("hub/registrations.eld")).unwrap(),
            "new"
        );
        let kept =
            std::fs::read_to_string(s.join("hub").join(DIR).join("registrations.eld")).unwrap();
        assert_eq!(kept, "old registrations.eld");
        // and the record on disk says the same
        assert_eq!(read_done(&s.join("hub").join(DIR).join(DONE)), Some(m));
    }

    #[test]
    fn keeps_names() {
        let t = old_state();
        let s = t.path();
        put(&s.join("jobs/20260101-1/exit"), "0");
        put(&s.join("jobs/20260101-1/log"), "out");
        // every move across a filesystem, so the copy path keeps names and modes too
        let m = migrate_in(s, &exdev).unwrap();
        let mut want = moved_names();
        want.push("jobs/20260101-1".into());
        assert_eq!(m.moved, want);
        let mig = s.join("hub").join(DIR);
        assert_eq!(mig.metadata().unwrap().permissions().mode() & 0o777, 0o700);
        for (rel, text) in [
            ("registrations.eld", "old registrations.eld"),
            ("port", "old port"),
            ("bodies/b1", "body"),
            ("hub-ab12.d/backend.sock", ""),
            ("sandbox/profile.eld", "sb"),
            ("jobs/20260101-1/log", "out"),
            ("jobs/20260101-1/exit", "0"),
        ] {
            assert_eq!(
                std::fs::read_to_string(mig.join(rel)).unwrap(),
                text,
                "{rel}"
            );
        }
        assert!(!s.join("jobs/20260101-1").exists());
        assert!(!s.join("hub/bodies").exists());
        // no copy in progress is left behind
        assert!(names(&mig).iter().all(|n| !n.ends_with(".partial")));
    }

    #[test]
    fn never_deletes_on_copy_failure() {
        let t = old_state();
        let s = t.path();
        // a folder with a socket in it cannot be copied
        let _l = UnixListener::bind(s.join("hub/bodies/s.sock")).unwrap();
        let m = migrate_in(s, &exdev).unwrap();
        assert_eq!(m.left, ["hub/bodies"]);
        assert!(!m.moved.contains(&"hub/bodies".to_string()));
        assert!(s.join("hub/bodies/b1").exists(), "the source is intact");
        let mig = s.join("hub").join(DIR);
        assert!(!mig.join("bodies").exists());
        assert!(names(&mig).iter().all(|n| !n.ends_with(".partial")));
        // the rest still moved
        assert_eq!(
            std::fs::read_to_string(mig.join("sandbox/profile.eld")).unwrap(),
            "sb"
        );
        // a rename that fails for any other reason moves nothing and deletes nothing
        let t2 = old_state();
        let denied = |_: &Path, _: &Path| Err(io::Error::from(io::ErrorKind::PermissionDenied));
        let m2 = migrate_in(t2.path(), &denied).unwrap();
        assert!(m2.moved.is_empty());
        assert_eq!(m2.left.len(), moved_names().len());
        assert!(t2.path().join("hub/registrations.eld").exists());
    }

    #[test]
    fn live_job_left() {
        let t = tempfile::tempdir().unwrap();
        let s = t.path();
        let me = std::process::id().to_string();
        put(&s.join("jobs/live/pid"), &me);
        put(&s.join("jobs/live/log"), "running");
        // a job whose exit file exists is over, whatever its pid names
        put(&s.join("jobs/exited/pid"), &me);
        put(&s.join("jobs/exited/exit"), "1");
        // a pid that names no process
        put(&s.join("jobs/gone/pid"), "2147483646");
        let m = migrate_in(s, &by_rename).unwrap();
        assert_eq!(m.left, ["jobs/live"]);
        assert_eq!(m.moved, ["jobs/exited", "jobs/gone"]);
        assert!(s.join("jobs/live/log").exists());
        let mig = s.join("hub").join(DIR);
        assert!(mig.join("jobs/gone/pid").exists());
        assert!(!s.join("jobs/gone").exists());
    }

    #[test]
    fn ended_job_moved_later() {
        let t = tempfile::tempdir().unwrap();
        let s = t.path();
        let mut job = std::process::Command::new("sleep")
            .arg("300")
            .spawn()
            .unwrap();
        put(&s.join("jobs/j/pid"), &job.id().to_string());
        put(&s.join("jobs/j/log"), "out");
        let first = migrate_in(s, &by_rename).unwrap();
        assert_eq!(first.left, ["jobs/j"]);
        assert!(first.moved.is_empty());
        // unchanged, while it runs
        assert_eq!(migrate_in(s, &by_rename).unwrap(), first);
        job.kill().unwrap();
        job.wait().unwrap();
        let later = migrate_in(s, &by_rename).unwrap();
        assert!(later.left.is_empty());
        assert_eq!(later.moved, ["jobs/j"]);
        let mig = s.join("hub").join(DIR);
        assert_eq!(
            std::fs::read_to_string(mig.join("jobs/j/log")).unwrap(),
            "out"
        );
        assert!(!s.join("jobs/j").exists());
    }

    #[test]
    fn a_fresh_install_writes_nothing() {
        let t = tempfile::tempdir().unwrap();
        let m = migrate_in(t.path(), &by_rename).unwrap();
        assert_eq!(m, Moved::default());
        assert!(!t.path().join("hub").exists());
    }

    #[test]
    fn the_scan_finds_the_users_lisp_processes() {
        let t = tempfile::tempdir().unwrap();
        let uid = rustix::process::geteuid().as_raw();
        put(
            &t.path().join("101/cmdline"),
            "emacs\0--eval\0(drgnx-hub-main)\0",
        );
        put(&t.path().join("102/cmdline"), "emacs\0-Q\0");
        put(
            &t.path().join("103/cmdline"),
            "emacs\0-f\0drgnx-coord-mcp-main\0",
        );
        put(&t.path().join("self/cmdline"), "drgnx-hub-main");
        assert_eq!(
            scan_proc(t.path(), uid),
            [
                LispProcess {
                    pid: 101,
                    what: "drgnx-hub-main".into()
                },
                LispProcess {
                    pid: 103,
                    what: "drgnx-coord-mcp-main".into()
                },
            ]
        );
        // another user's processes are not ours to report
        assert!(scan_proc(t.path(), uid + 1).is_empty());
        assert_eq!(marker_in("sleep 1"), None);
    }

    #[test]
    fn the_section_names_what_moved_and_what_is_left() {
        let t = tempfile::tempdir().unwrap();
        let home = t.path().to_string_lossy().into_owned();
        let env = Env::new(
            &[("HOME", &home), ("XDG_STATE_HOME", &home)],
            rustix::process::geteuid().as_raw(),
        );
        let state = paths::state_dir(&env);
        plant(&state);
        put(
            &state.join("jobs/live/pid"),
            &std::process::id().to_string(),
        );
        let before = section(&env);
        assert_eq!(before["moved"], json!([]));
        assert_eq!(before["at"], Value::Null);
        assert_eq!(before["left"], json!(["jobs/live"]));
        let m = migrate(&env).unwrap();
        let after = section(&env);
        assert_eq!(after["moved"], json!(m.moved));
        assert_eq!(
            after["moved"].as_array().unwrap().len(),
            moved_names().len()
        );
        assert_eq!(after["left"], json!(["jobs/live"]));
        assert_eq!(after["at"], json!(state.join("hub").join(DIR)));
    }
}
