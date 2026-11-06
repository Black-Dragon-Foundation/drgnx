//! An attempt's folder on the runner, `<root>/jobs/<id>.<attempt>/`:
//!
//! - `attempt.json`: who placed it (the hub id and the `JobRef` with its nonce), the spec, the grant, the bundle its
//!   job-exec runs from, its unit;
//! - `job.json`, `log`, `result.json`, `kill_reason`: job-exec's (`linux::jobexec`);
//! - `src/`, `target/`: the job's source (when the hub synced none: an empty folder) and its target dir; a synced
//!   attempt reads its slot (`<root>/slots/<id>/`), or its private copy `tree/` when it writes the tree;
//! - `cancelled`: the hub cancelled it; `collected`: the hub has its result, so the folder may go.
//!
//! The folders are the runner's whole memory of its attempts: a new `serve` lists them at `hello`.

use crate::proto::{AttemptInfo, AttemptState, JobRef};
use forseti::{Expected, Grant, JobSpec, Priority};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

pub const META: &str = "attempt.json";
pub const LOG: &str = "log";
pub const COLLECTED: &str = "collected";
pub const CANCELLED: &str = "cancelled";

/// What `serve` records about an attempt when it admits it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Meta {
    pub hub_id: String,
    pub r: JobRef,
    pub spec: JobSpec,
    pub priority: Priority,
    pub grant: Grant,
    #[serde(default)]
    pub expected: Option<Expected>,
    /// The `bin/<name>` folder whose `sleipnir` runs the attempt's job-exec.
    pub bundle: String,
    /// The unit, once started.
    #[serde(default)]
    pub unit: Option<String>,
    pub admitted: u64,
    #[serde(default)]
    pub started: Option<u64>,
    /// The offer's frozen input key (empty: the hub sent none).
    #[serde(default)]
    pub input_key: String,
    /// The checkout slot the attempt reads (its id), once it started on one.
    #[serde(default)]
    pub slot: Option<String>,
}

/// `<root>/jobs`.
pub fn jobs(root: &Path) -> PathBuf {
    root.join("jobs")
}

/// The folder of attempt ATTEMPT of job ID.
pub fn dir(root: &Path, id: &str, attempt: u32) -> PathBuf {
    jobs(root).join(format!("{id}.{attempt}"))
}

pub fn read_meta(dir: &Path) -> io::Result<Meta> {
    serde_json::from_slice(&fs::read(dir.join(META))?).map_err(io::Error::other)
}

/// Writes META by rename, so a reader sees the old record or the new one.
pub fn write_meta(dir: &Path, meta: &Meta) -> io::Result<()> {
    let tmp = dir.join(format!(".{META}.tmp"));
    fs::write(
        &tmp,
        serde_json::to_vec_pretty(meta).map_err(io::Error::other)?,
    )?;
    fs::rename(&tmp, dir.join(META))
}

/// One attempt folder as `serve` finds it.
#[derive(Clone, Debug)]
pub struct Found {
    pub dir: PathBuf,
    pub meta: Meta,
    pub state: AttemptState,
    pub log_len: u64,
    /// Seconds since its record was last written.
    pub age_s: u64,
    pub collected: bool,
}

impl Found {
    pub fn info(&self) -> AttemptInfo {
        AttemptInfo {
            r: self.meta.r.clone(),
            state: self.state,
            log_offset: self.log_len,
        }
    }
}

/// The state of the attempt in DIR with META: finished once its `result.json` is there, running while its unit is
/// active (ACTIVE asks systemd), lost otherwise.
pub fn state(dir: &Path, meta: &Meta, active: &dyn Fn(&str) -> bool) -> AttemptState {
    if dir.join(crate::linux::result::RESULT).exists() {
        AttemptState::Finished
    } else if meta.unit.as_deref().is_some_and(active) {
        AttemptState::Running
    } else {
        AttemptState::Lost
    }
}

/// Every attempt folder under ROOT with a readable record, of any hub.
pub fn scan(root: &Path, active: &dyn Fn(&str) -> bool) -> Vec<Found> {
    let Ok(rd) = fs::read_dir(jobs(root)) else {
        return vec![];
    };
    let now = SystemTime::now();
    let mut out: Vec<Found> = rd
        .flatten()
        .filter_map(|e| {
            let dir = e.path();
            let meta = read_meta(&dir).ok()?;
            let age_s = fs::metadata(dir.join(META))
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| now.duration_since(t).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            Some(Found {
                state: state(&dir, &meta, active),
                log_len: fs::metadata(dir.join(LOG)).map(|m| m.len()).unwrap_or(0),
                collected: dir.join(COLLECTED).exists(),
                age_s,
                dir,
                meta,
            })
        })
        .collect();
    out.sort_by(|a, b| a.dir.cmp(&b.dir));
    out
}
