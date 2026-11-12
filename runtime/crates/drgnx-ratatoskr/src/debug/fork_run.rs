//! A recorded run as D2's forks read it: a private copy of D1's `debug/record.rs` types and of its `config_hash`,
//! with the same names, so the switch at D1's merge is a deletion of this file (the coordinator's ruling, 2026-11-12).

use super::session::Request;
use serde_json::Value;
use std::path::PathBuf;

/// The launch snapshot: a tree of the checkpoints root's shadow repository of `source`, as
/// `timeline::snapshot::restore_into` takes it.
#[derive(Clone, Debug, PartialEq)]
pub struct RunSnapshot {
    pub checkpoints: PathBuf,
    pub source: PathBuf,
    pub tree: String,
}

/// A stop of the run. `index` and [`RunHit::seq`] count on one counter (the run's event order).
#[derive(Clone, Debug, PartialEq)]
pub struct RunStop {
    pub index: u64,
    /// Since the launch.
    pub t_ms: u64,
    pub reason: String,
    /// The DAP thread id.
    pub thread: i64,
    pub path: String,
    pub line: u32,
    /// The how-manyth stop of the breakpoint at (path, line), this one counted (1-based); none for a step's stop.
    pub bp_hit: Option<u32>,
    /// The steps since the last breakpoint stop, in order: `next`, `in`, `out`.
    pub steps: Vec<String>,
}

/// A probe: a logpoint with drgnx's marker.
#[derive(Clone, Debug, PartialEq)]
pub struct RunProbe {
    pub id: String,
    pub path: String,
    pub line: u32,
    pub expr: String,
}

/// A probe's hit: the thread expression's value and the probe's, as text.
#[derive(Clone, Debug, PartialEq)]
pub struct RunHit {
    pub probe: String,
    pub thread: String,
    pub value: String,
    pub seq: u64,
}

/// A recorded run, as a fork reads it.
#[derive(Clone, Debug, PartialEq)]
pub struct RunInfo {
    pub id: String,
    pub root: PathBuf,
    /// The `debug/start` parameters as they were sent, without the inputs' answers.
    pub start: Value,
    /// [`config_hash`] of the resolved configuration at the launch.
    pub config_hash: String,
    pub adapter_id: String,
    pub request: Request,
    pub snapshot: Option<RunSnapshot>,
    /// The `PYTHONHASHSEED` the hub set.
    pub hash_seed: Option<u32>,
    pub to_stop_ms: Option<u64>,
    pub stops: Vec<RunStop>,
    pub probes: Vec<RunProbe>,
    pub hits: Vec<RunHit>,
}

/// The recorded runs.
pub trait Runs: Send + Sync {
    fn run(&self, id: &str) -> Option<RunInfo>;
}

/// The hash of a resolved configuration (`launch::substitute`'s output, env values included): xxh3 of its JSON with
/// every object's keys sorted. Only the hash is kept, never the values.
pub fn config_hash(resolved: &Value) -> String {
    let mut bytes = Vec::new();
    canonical(resolved, &mut bytes);
    format!("{:016x}", xxhash_rust::xxh3::xxh3_64(&bytes))
}

fn canonical(v: &Value, out: &mut Vec<u8>) {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            out.push(b'{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                out.extend(Value::String(k.clone()).to_string().as_bytes());
                out.push(b':');
                canonical(&m[k], out);
            }
            out.push(b'}');
        }
        Value::Array(a) => {
            out.push(b'[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                canonical(x, out);
            }
            out.push(b']');
        }
        other => out.extend(other.to_string().as_bytes()),
    }
}
