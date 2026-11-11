//! `<state>/term/<id>.json`: what a hub needs to adopt a worker a hub before it started (docs/develop/terminal.md,
//! "Lifetime"). Written through a rename, so a half-written record is never read.

use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub id: String,
    /// The worker's scope (`drgnx-term-<id>`), when it has one.
    #[serde(default)]
    pub unit: Option<String>,
    /// The worker's pid and its start time (clock ticks since boot): a reused pid is not the worker.
    pub pid: i32,
    pub start_time: u64,
    /// The program's pid on the PTY (from the worker's hello).
    #[serde(default)]
    pub shell_pid: Option<u32>,
    pub socket: PathBuf,
    /// The editor's view (`term:<id>`) and display class.
    pub view: String,
    pub class: String,
    pub cwd: String,
    /// The editor session it draws for (none: kept at that session's quit). A session gone past the hub's grace
    /// leaves it detached, not ended.
    #[serde(default)]
    pub session: Option<String>,
    /// When it was detached, in ms since the epoch (none: a session has it, or had it a moment ago).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detached_at: Option<u64>,
    /// The program and its arguments, as started.
    #[serde(default)]
    pub command: Vec<String>,
    /// Where the editor showed it (`panel`, `editor`), so a reattach opens it there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    /// A terminal in a remote folder: TRAMP's prefix of it (`/ssh:host:`), so a reattach knows its host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
}

impl Record {
    pub fn path(dir: &Path, id: &str) -> PathBuf {
        dir.join(format!("{id}.json"))
    }

    pub fn write(&self, dir: &Path) -> io::Result<()> {
        std::fs::create_dir_all(dir)?;
        let path = Record::path(dir, &self.id);
        let tmp = dir.join(format!(".{}.json.tmp", self.id));
        std::fs::write(
            &tmp,
            serde_json::to_vec_pretty(self).map_err(io::Error::other)?,
        )?;
        std::fs::rename(tmp, path)
    }

    pub fn remove(dir: &Path, id: &str) {
        let _ = std::fs::remove_file(Record::path(dir, id));
    }
}

/// Every record in DIR (unreadable ones skipped), by id.
pub fn read_all(dir: &Path) -> Vec<Record> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<Record> = rd
        .flatten()
        .filter(|e| {
            e.file_name()
                .to_str()
                .is_some_and(|n| n.ends_with(".json") && !n.starts_with('.'))
        })
        .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
        .collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_round_trip() {
        let dir = std::env::temp_dir().join(format!("drgnx-term-reg-{}", std::process::id()));
        let r = Record {
            id: "a1".into(),
            pid: 7,
            start_time: 9,
            socket: dir.join("a1.sock"),
            view: "term:a1".into(),
            class: "gui".into(),
            cwd: "/".into(),
            ..Record::default()
        };
        r.write(&dir).unwrap();
        std::fs::write(dir.join("junk.json"), "{").unwrap();
        assert_eq!(read_all(&dir), vec![r.clone()]);
        Record::remove(&dir, "a1");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
