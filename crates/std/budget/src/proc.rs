//! `/proc` readers: PSS over a process tree and per-thread context-switch deltas.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::Error;

const PROC: &str = "/proc";

fn io_err(path: &Path, source: io::Error) -> Error {
    Error::Io {
        path: path.to_path_buf(),
        source,
    }
}

fn read(path: &Path) -> Result<String, Error> {
    fs::read_to_string(path).map_err(|e| io_err(path, e))
}

/// The proportional set size of `pid` and all its descendants, in KiB (`Pss:` of `/proc/PID/smaps_rollup`).
/// A descendant that exits while we walk is skipped; `pid` itself must be readable.
pub fn pss_kib(pid: u32) -> Result<u64, Error> {
    pss_kib_at(Path::new(PROC), pid)
}

/// [`pss_kib`] against another `/proc` root (a fake tree in the tests).
pub fn pss_kib_at(root: &Path, pid: u32) -> Result<u64, Error> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for entry in fs::read_dir(root).map_err(|e| io_err(root, e))?.flatten() {
        let Some(child) = entry
            .file_name()
            .to_str()
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        if let Some(ppid) = fs::read_to_string(entry.path().join("stat"))
            .ok()
            .as_deref()
            .and_then(parent_pid)
        {
            children.entry(ppid).or_default().push(child);
        }
    }
    let mut total = own_pss_kib(root, pid)?;
    let mut queue = children.remove(&pid).unwrap_or_default();
    while let Some(next) = queue.pop() {
        match own_pss_kib(root, next) {
            Ok(kib) => total += kib,
            Err(Error::Io { source, .. }) if source.kind() == io::ErrorKind::NotFound => continue,
            Err(Error::Io { source, .. }) if source.kind() == io::ErrorKind::PermissionDenied => {
                continue;
            }
            Err(e) => return Err(e),
        }
        queue.extend(children.remove(&next).unwrap_or_default());
    }
    Ok(total)
}

fn own_pss_kib(root: &Path, pid: u32) -> Result<u64, Error> {
    let path = root.join(pid.to_string()).join("smaps_rollup");
    let text = read(&path)?;
    text.lines()
        .find_map(|l| l.strip_prefix("Pss:"))
        .and_then(|rest| rest.trim().strip_suffix("kB"))
        .and_then(|n| n.trim().parse().ok())
        .ok_or(Error::Parse {
            path,
            what: "a `Pss: N kB` line",
        })
}

/// The parent pid in a `/proc/PID/stat` line. The comm is in parentheses and may hold spaces and parentheses, so
/// the fields start after the last `)`: state, then ppid.
fn parent_pid(stat: &str) -> Option<u32> {
    stat.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

/// Context switches per thread over a window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadWakeups {
    /// Every thread of the process: its `comm` and its switches (voluntary plus involuntary) in the window.
    pub per_thread: Vec<(String, u64)>,
    pub total: u64,
}

/// Counts every thread of `pid`'s context switches over `window`: the deltas of
/// `voluntary_ctxt_switches + nonvoluntary_ctxt_switches` in `/proc/PID/task/*/status`. A thread that starts inside
/// the window counts all its switches; one that exits inside it is not listed.
pub fn wakeups(pid: u32, window: Duration) -> Result<ThreadWakeups, Error> {
    wakeups_at(Path::new(PROC), pid, window)
}

/// [`wakeups`] against another `/proc` root.
pub fn wakeups_at(root: &Path, pid: u32, window: Duration) -> Result<ThreadWakeups, Error> {
    let before = snapshot(root, pid)?;
    std::thread::sleep(window);
    let after = snapshot(root, pid)?;
    let per_thread: Vec<(String, u64)> = after
        .into_iter()
        .map(|(tid, (comm, now))| {
            let was = before.get(&tid).map_or(0, |(_, n)| *n);
            (comm, now.saturating_sub(was))
        })
        .collect();
    let total = per_thread.iter().map(|(_, n)| n).sum();
    Ok(ThreadWakeups { per_thread, total })
}

/// tid -> (comm, switches so far).
fn snapshot(root: &Path, pid: u32) -> Result<BTreeMap<u32, (String, u64)>, Error> {
    let tasks: PathBuf = root.join(pid.to_string()).join("task");
    let mut out = BTreeMap::new();
    for entry in fs::read_dir(&tasks)
        .map_err(|e| io_err(&tasks, e))?
        .flatten()
    {
        let Some(tid) = entry
            .file_name()
            .to_str()
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        let path = entry.path().join("status");
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue, // the thread just exited
            Err(e) => return Err(io_err(&path, e)),
        };
        out.insert(
            tid,
            parse_status(&text).ok_or(Error::Parse {
                path,
                what: "Name and ctxt_switches lines",
            })?,
        );
    }
    Ok(out)
}

fn parse_status(text: &str) -> Option<(String, u64)> {
    let field = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key))
            .map(str::trim)
    };
    let voluntary: u64 = field("voluntary_ctxt_switches:")?.parse().ok()?;
    let involuntary: u64 = field("nonvoluntary_ctxt_switches:")?.parse().ok()?;
    Some((field("Name:")?.to_string(), voluntary + involuntary))
}
