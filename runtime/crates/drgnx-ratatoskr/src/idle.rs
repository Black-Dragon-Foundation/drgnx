//! Restart-when-idle (design 3.2; review C3): the hub notices that its binary on disk changed and restarts, but only
//! between turns.
//!
//! - At start the executable's path is resolved **once** ([`resolve_exe`]) and its `(dev, inode, mtime)` recorded
//!   ([`ExeWatch`]).  At each tick that **path** is statted, never `/proc/self/exe`: that link follows the running
//!   inode, which a rename-replace leaves alone, so it never changes.
//! - A changed stamp makes `<path> version --json` run (5 s deadline).  Only an answer with another `commit` counts;
//!   a missing, half-written or failing file is logged and looked at again at the next tick.
//! - Then the `notice` event goes out, and the hub exits 75 as soon as it is idle: in phase 1 the backend's
//!   `agents/list` has no `busy` session and `job/status` no `running` job.  An answer that does not come, or does
//!   not fit, is not idle.  A hub is never restarted while anything is busy.

use crate::backend::Backend;
use crate::front::Front;
use serde_json::{Value, json};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::io::AsyncReadExt;

/// How often the binary is looked at.
pub const TICK: Duration = Duration::from_secs(2);

/// How long `<path> version --json` has to answer.
pub const VERSION_DEADLINE: Duration = Duration::from_secs(5);

/// The `notice` event's id (the editor's notices replace by id).
pub const NOTICE_ID: &str = "restart-when-idle";

static START_EXE: OnceLock<PathBuf> = OnceLock::new();

/// The executable's path as resolved at start (set by [`resolve_exe`]; a re-exec runs this path).
pub fn start_exe() -> Option<&'static Path> {
    START_EXE.get().map(PathBuf::as_path)
}

/// Resolve the running executable's path once.  Linux and Android: `readlink /proc/self/exe`, which at start names the file on
/// disk; macOS: `_NSGetExecutablePath` (what `current_exe` calls) and `realpath`.
pub fn resolve_exe() -> std::io::Result<&'static Path> {
    if let Some(p) = START_EXE.get() {
        return Ok(p);
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let path = std::fs::read_link("/proc/self/exe")?;
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let path = std::fs::canonicalize(std::env::current_exe()?)?;
    Ok(START_EXE.get_or_init(|| path).as_path())
}

/// What identifies a file's content for the watch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    dev: u64,
    ino: u64,
    mtime: (i64, i64),
}

impl Stamp {
    fn of(path: &Path) -> std::io::Result<Stamp> {
        let m = std::fs::metadata(path)?;
        Ok(Stamp {
            dev: m.dev(),
            ino: m.ino(),
            mtime: (m.mtime(), m.mtime_nsec()),
        })
    }
}

/// The watch on the resolved executable path.
#[derive(Debug)]
pub struct ExeWatch {
    path: PathBuf,
    start: Stamp,
}

impl ExeWatch {
    /// Watch PATH, recording its stamp now.
    pub fn new(path: &Path) -> std::io::Result<ExeWatch> {
        Ok(ExeWatch {
            path: path.to_path_buf(),
            start: Stamp::of(path)?,
        })
    }

    /// The stamp of the path now (none while it is missing).
    pub fn stamp(&self) -> Option<Stamp> {
        Stamp::of(&self.path).ok()
    }

    /// Does the file at the path differ from the one at start?  A missing file has not changed.
    pub fn changed(&self) -> bool {
        self.stamp().is_some_and(|s| s != self.start)
    }

    /// The stamp at start.
    pub fn start(&self) -> Stamp {
        self.start
    }
}

/// What `<path> version --json` says of the file at the path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Build {
    /// Another commit than the running one.
    Other(String),
    /// The running commit again (a touch, a re-install of the same build).
    Same,
    /// No answer: missing, half written, failing, too slow.
    Unknown,
}

/// The turns running, from `agents/list`'s and `job/status`'s results: `busy` sessions plus `running` jobs.  None
/// when either does not have the shape (an answer that does not fit is no answer: not idle).
pub fn count_busy(agents: &Value, jobs: &Value) -> Option<u64> {
    fn list<'a>(v: &'a Value, key: &str) -> Option<&'a [Value]> {
        match v.get(key)? {
            Value::Array(a) => Some(a),
            Value::Null => Some(&[]),
            _ => None,
        }
    }
    let busy = list(agents, "sessions")?
        .iter()
        .filter(|s| s["status"] == "busy")
        .count();
    let running = list(jobs, "jobs")?
        .iter()
        .filter(|j| j["status"] == "running")
        .count();
    Some((busy + running) as u64)
}

/// What the watch looks at besides the file: the build behind it and the backend's turns.  Used inside this crate
/// only (static dispatch, from a spawned task), so the futures' auto traits are known where they matter.
#[allow(async_fn_in_trait)]
pub trait Source {
    /// The stamp of the path now.
    fn stamp(&self) -> Option<Stamp>;
    /// What the build at the path is.
    async fn build(&self) -> Build;
    /// The turns running; none when that cannot be told.
    async fn busy(&self) -> Option<u64>;
}

/// What a tick found.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Tick {
    /// The `notice` to send: the turns the restart waits for (none inside: the backend did not say).
    pub notice: Option<Option<u64>>,
    /// Exit 75 now.
    pub restart: bool,
}

/// The decision, one tick at a time.
#[derive(Debug)]
pub struct Watcher {
    start: Option<Stamp>,
    /// The stamp of the build that proved to be another one.
    confirmed: Option<Stamp>,
    /// The count the last notice gave.
    told: Option<Option<u64>>,
}

impl Watcher {
    pub fn new(start: Option<Stamp>) -> Watcher {
        Watcher {
            start,
            confirmed: None,
            told: None,
        }
    }

    /// Look once.  A changed file is checked with `version` first; once it is another build, the notice goes out
    /// (again whenever the count changes) and the hub restarts the first time nothing is busy.
    pub async fn tick(&mut self, src: &impl Source) -> Tick {
        let Some(now) = src.stamp() else {
            // missing: nothing to restart into, whatever was seen before
            if self.confirmed.take().is_some() {
                tracing::warn!("the new binary is gone again: not restarting");
            }
            return Tick::default();
        };
        if Some(now) == self.start {
            self.confirmed = None;
            return Tick::default();
        }
        if self.confirmed != Some(now) {
            self.confirmed = None;
            match src.build().await {
                Build::Other(commit) => {
                    tracing::info!(commit, "the binary on disk is another build");
                    self.confirmed = Some(now);
                }
                // the same build again: this stamp is the baseline from now on
                Build::Same => self.start = Some(now),
                // missing, half written, failing: looked at again at the next tick
                Build::Unknown => {}
            }
            if self.confirmed.is_none() {
                return Tick::default();
            }
        }
        let busy = src.busy().await;
        let mut tick = Tick::default();
        // idle only on a positive answer of zero: an answer that does not come is not idle
        if busy == Some(0) {
            tick.restart = true;
        }
        if self.told != Some(busy) {
            self.told = Some(busy);
            tick.notice = Some(busy);
        }
        tick
    }
}

/// `<path> version --json` against COMMIT, the running build's.
pub async fn build_at(path: &Path, commit: &str) -> Build {
    let mut child = match tokio::process::Command::new(path)
        .args(["version", "--json"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("cannot run {} version: {e}", path.display());
            return Build::Unknown;
        }
    };
    let Some(mut out) = child.stdout.take() else {
        return Build::Unknown;
    };
    let run = async {
        let mut text = String::new();
        (&mut out)
            .take(1 << 16)
            .read_to_string(&mut text)
            .await
            .ok()?;
        let status = child.wait().await.ok()?;
        status.success().then_some(text)
    };
    let text = match tokio::time::timeout(VERSION_DEADLINE, run).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            tracing::warn!("{} version failed", path.display());
            return Build::Unknown;
        }
        Err(_) => {
            tracing::warn!("{} version did not answer in 5 s", path.display());
            return Build::Unknown;
        }
    };
    let found = serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| v.get("commit")?.as_str().map(str::to_string));
    match found {
        Some(c) if c == commit => Build::Same,
        Some(c) => Build::Other(c),
        None => {
            tracing::warn!("{} version said no commit", path.display());
            Build::Unknown
        }
    }
}

/// The notice for N turns still running (none: the backend did not say).
pub fn notice(n: Option<u64>) -> Value {
    let text = match n {
        Some(0) => "drgnx was updated; the hub restarts now".to_string(),
        Some(1) => {
            "drgnx was updated; the hub restarts when its 1 running turn finishes".to_string()
        }
        Some(n) => format!("drgnx was updated; the hub restarts when its {n} running turns finish"),
        None => "drgnx was updated; the hub restarts when its running turns finish".to_string(),
    };
    json!({
        "source": "hub",
        "severity": "warn",
        "id": NOTICE_ID,
        "life": "condition",
        "text": text,
        "command": "hub-restart-now",
    })
}

/// The real source: the watch, this build's commit and the backend.
struct Real {
    watch: ExeWatch,
    backend: Arc<Backend>,
}

impl Source for Real {
    fn stamp(&self) -> Option<Stamp> {
        self.watch.stamp()
    }

    async fn build(&self) -> Build {
        build_at(&self.watch.path, crate::version::COMMIT).await
    }

    async fn busy(&self) -> Option<u64> {
        self.backend.busy().await
    }
}

/// The task: every TICK, look; send the notice; ask the front for a restart when idle.  Ends when it has.
pub async fn run(front: Arc<Front>, backend: Arc<Backend>, tick: Duration) {
    let Some(path) = start_exe() else {
        tracing::warn!("no resolved executable path: restart-when-idle is off");
        return;
    };
    let watch = match ExeWatch::new(path) {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!(
                "cannot stat {}: {e}: restart-when-idle is off",
                path.display()
            );
            return;
        }
    };
    let mut state = Watcher::new(Some(watch.start()));
    let src = Real { watch, backend };
    let mut every = tokio::time::interval(tick);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    every.tick().await;
    loop {
        every.tick().await;
        let t = state.tick(&src).await;
        if let Some(n) = t.notice {
            front.broadcast("notice", notice(n));
        }
        if t.restart {
            tracing::info!("the binary changed and nothing is busy: restarting");
            front.ask_restart();
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    /// A source the test drives: the stamp, what the build says and the turns.
    struct Fake {
        stamp: Cell<Option<Stamp>>,
        commit: Cell<Option<&'static str>>,
        busy: Cell<Option<u64>>,
        asked: Cell<u32>,
    }

    impl Source for Fake {
        fn stamp(&self) -> Option<Stamp> {
            self.stamp.get()
        }
        async fn build(&self) -> Build {
            self.asked.set(self.asked.get() + 1);
            match self.commit.get() {
                Some(c) => Build::Other(c.to_string()),
                None => Build::Unknown,
            }
        }
        async fn busy(&self) -> Option<u64> {
            self.busy.get()
        }
    }

    fn stamp(n: u64) -> Stamp {
        Stamp {
            dev: 1,
            ino: n,
            mtime: (n as i64, 0),
        }
    }

    fn fake(now: Option<Stamp>) -> Fake {
        Fake {
            stamp: Cell::new(now),
            commit: Cell::new(None),
            busy: Cell::new(Some(0)),
            asked: Cell::new(0),
        }
    }

    fn block<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(f)
    }

    // `the_path_is_statted_not_proc_self_exe` runs a child process, which a fork inside this test binary would let
    // hold the lock tests' descriptors until its exec: it is in tests/server.rs.

    #[test]
    fn busy_means_a_busy_session_or_a_running_job() {
        let idle_a =
            json!({"sessions": [{"id": "a", "status": "idle"}, {"id": "b", "status": "exited"}]});
        let none_j = json!({"jobs": []});
        assert_eq!(count_busy(&idle_a, &none_j), Some(0));
        let busy_a =
            json!({"sessions": [{"id": "a", "status": "busy"}, {"id": "b", "status": "idle"}]});
        assert_eq!(count_busy(&busy_a, &none_j), Some(1));
        let run_j =
            json!({"jobs": [{"id": "j", "status": "running"}, {"id": "k", "status": "done"}]});
        assert_eq!(count_busy(&idle_a, &run_j), Some(1));
        assert_eq!(count_busy(&busy_a, &run_j), Some(2));
        // null lists are empty; anything else is no answer
        assert_eq!(
            count_busy(&json!({"sessions": null}), &json!({"jobs": null})),
            Some(0)
        );
        assert_eq!(count_busy(&json!({}), &none_j), None);
        assert_eq!(count_busy(&idle_a, &json!({"jobs": "x"})), None);
        assert_eq!(count_busy(&json!("x"), &none_j), None);
    }

    #[test]
    fn a_hub_is_never_restarted_while_anything_is_busy_or_unknown() {
        let src = fake(Some(stamp(2)));
        src.commit.set(Some("newer"));
        let mut w = Watcher::new(Some(stamp(1)));
        // busy: a notice, no restart, however many ticks
        src.busy.set(Some(2));
        let t = block(w.tick(&src));
        assert_eq!(
            t,
            Tick {
                notice: Some(Some(2)),
                restart: false
            }
        );
        for _ in 0..3 {
            assert_eq!(
                block(w.tick(&src)),
                Tick::default(),
                "told once, still waiting"
            );
        }
        // the count changes: told again, still no restart
        src.busy.set(Some(1));
        assert_eq!(
            block(w.tick(&src)),
            Tick {
                notice: Some(Some(1)),
                restart: false
            }
        );
        // nothing answers: not idle
        src.busy.set(None);
        assert!(!block(w.tick(&src)).restart);
        // idle: restart
        src.busy.set(Some(0));
        assert!(block(w.tick(&src)).restart);
    }

    #[test]
    fn an_unchanged_missing_or_unconfirmed_binary_never_restarts() {
        let mut w = Watcher::new(Some(stamp(1)));
        // unchanged
        let src = fake(Some(stamp(1)));
        assert_eq!(block(w.tick(&src)), Tick::default());
        assert_eq!(src.asked.get(), 0, "no version run for an unchanged file");
        // missing
        let src = fake(None);
        assert_eq!(block(w.tick(&src)), Tick::default());
        // changed, but version gives no other commit (broken, or the same build)
        let src = fake(Some(stamp(2)));
        src.busy.set(Some(0));
        assert_eq!(block(w.tick(&src)), Tick::default());
        assert_eq!(block(w.tick(&src)), Tick::default());
        assert_eq!(src.asked.get(), 2, "asked again at each tick");
        // then it turns out to be another build
        src.commit.set(Some("newer"));
        assert_eq!(
            block(w.tick(&src)),
            Tick {
                notice: Some(Some(0)),
                restart: true
            }
        );
    }

    #[test]
    fn the_same_build_again_becomes_the_baseline() {
        struct Same(Cell<u32>);
        impl Source for Same {
            fn stamp(&self) -> Option<Stamp> {
                Some(stamp(2))
            }
            async fn build(&self) -> Build {
                self.0.set(self.0.get() + 1);
                Build::Same
            }
            async fn busy(&self) -> Option<u64> {
                Some(0)
            }
        }
        let src = Same(Cell::new(0));
        let mut w = Watcher::new(Some(stamp(1)));
        assert_eq!(block(w.tick(&src)), Tick::default());
        assert_eq!(block(w.tick(&src)), Tick::default());
        assert_eq!(src.0.get(), 1, "version ran once, not at every tick");
    }

    #[test]
    fn a_confirmed_binary_that_vanishes_is_forgotten() {
        let src = fake(Some(stamp(2)));
        src.commit.set(Some("newer"));
        src.busy.set(Some(1));
        let mut w = Watcher::new(Some(stamp(1)));
        assert_eq!(block(w.tick(&src)).notice, Some(Some(1)));
        src.stamp.set(None);
        src.busy.set(Some(0));
        assert_eq!(
            block(w.tick(&src)),
            Tick::default(),
            "gone: no restart into nothing"
        );
    }

    #[test]
    fn the_notice_names_the_command_and_the_turns() {
        let n = notice(Some(3));
        assert_eq!(n["id"], NOTICE_ID);
        assert_eq!(n["command"], "hub-restart-now");
        assert_eq!(n["life"], "condition");
        assert_eq!(
            n["text"],
            "drgnx was updated; the hub restarts when its 3 running turns finish"
        );
        assert!(
            drgnx_proto::events::event("notice").is_some_and(|e| (e.check)(&n).is_ok()),
            "it fits the registry's notice"
        );
    }
}
