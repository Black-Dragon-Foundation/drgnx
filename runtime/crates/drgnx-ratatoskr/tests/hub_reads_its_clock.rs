//! The hub reads time only through `crate::clock` (docs/develop/hub.md, "Test hooks", "The hub clock").
//!
//! A raw timer or clock read anywhere else escapes `__test_advance`: a test could not decide when it fires.  This scans
//! the crate's non-test sources and names every raw call by file and line.  `clock.rs` itself is exempt, and a blocking
//! thread's limit on something outside the hub uses `clock::real_now()`, which does not match.  A raw spawn names no
//! origin: what its task writes to a client is unnamed under the sequencer, so each file's raw spawns are counted
//! against [`RAW_SPAWNS`].

use std::fs;
use std::path::{Path, PathBuf};

/// Substrings that mean a raw read of time or a raw timer.
const RAW: &[&str] = &[
    "Instant::now(",
    "SystemTime::now(",
    "tokio::time::sleep",
    "tokio::time::timeout",
    "tokio::time::interval",
    "tokio::time::MissedTickBehavior",
    "time::sleep_until",
    "set_missed_tick_behavior",
];

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            sources(&p, out);
        } else if p.extension().is_some_and(|e| e == "rs") {
            out.push(p);
        }
    }
}

/// A file that is test code as a whole: the clock itself, and the `tests.rs` / `tests/` files of a module.
fn exempt(rel: &str) -> bool {
    rel == "clock.rs"
        || rel.starts_with("clock/")
        || rel.ends_with("/tests.rs")
        || rel == "tests.rs"
        || rel.contains("/tests/")
}

/// The raw sites in one file's text, skipping comments and items under `#[cfg(test)]`.
fn raw_sites(text: &str) -> Vec<(usize, String)> {
    sites_of(text, RAW)
}

/// The lines of TEXT that hold one of PATTERNS, skipping comments and items under `#[cfg(test)]`.
fn sites_of(text: &str, patterns: &[&str]) -> Vec<(usize, String)> {
    let mut found = Vec::new();
    let mut skip_depth: Option<i32> = None;
    let mut pending_cfg_test = false;
    for (i, line) in text.lines().enumerate() {
        let t = line.trim_start();
        if let Some(depth) = skip_depth.as_mut() {
            *depth += line.matches('{').count() as i32 - line.matches('}').count() as i32;
            if *depth <= 0 {
                skip_depth = None;
            }
            continue;
        }
        if t.starts_with("#[cfg(test)]") || t.starts_with("#[cfg(all(test") {
            pending_cfg_test = true;
            continue;
        }
        if pending_cfg_test {
            if t.starts_with("#[") {
                continue;
            }
            pending_cfg_test = false;
            let opens = line.matches('{').count() as i32;
            let closes = line.matches('}').count() as i32;
            if opens > closes {
                skip_depth = Some(opens - closes);
            }
            continue;
        }
        if t.starts_with("//") {
            continue;
        }
        if patterns.iter().any(|p| line.contains(p)) {
            found.push((i + 1, t.to_string()));
        }
    }
    found
}

/// The crate's non-test sources, as (path under `src/`, text), in path order.
fn hub_sources() -> Vec<(String, String)> {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    sources(&src, &mut files);
    files
        .into_iter()
        .filter_map(|f| {
            let rel = f
                .strip_prefix(&src)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            (!exempt(&rel)).then(|| (rel, fs::read_to_string(&f).unwrap()))
        })
        .collect()
}

#[test]
fn no_raw_time_outside_the_clock() {
    let mut bad = Vec::new();
    for (rel, text) in hub_sources() {
        for (n, line) in raw_sites(&text) {
            bad.push(format!("src/{rel}:{n}: {line}"));
        }
    }
    assert!(
        bad.is_empty(),
        "{} raw time call(s) outside src/clock.rs; use crate::clock::{{now, wall, sleep, timeout, interval, spawn}} \
         (clock::real_now() for a blocking thread's limit on something outside the hub):\n{}",
        bad.len(),
        bad.join("\n")
    );
}

/// A raw spawn: a task without an origin.
const RAW_SPAWN: &[&str] = &["tokio::spawn(", "tokio::task::spawn("];

/// The raw spawns each file may hold, and why.  A task that writes to a client is started by `clock::spawn`: under
/// the sequencer a write from a task without an origin is counted as unnamed, and a gated test fails on it.
const RAW_SPAWNS: &[(&str, usize, &str)] = &[
    // never write to a client
    ("budget.rs", 1, "saves the budgets"),
    ("exec/container.rs", 1, "drains the proxy's asks"),
    (
        "gateway.rs",
        2,
        "the gateway's listeners: their events reach clients through gateway::run_events",
    ),
    ("sandbox.rs", 1, "the sandbox binary's stdout"),
    (
        "sequencer.rs",
        1,
        "the sequencer itself, a serving step, and no clock task",
    ),
    (
        "server.rs",
        3,
        "the accept loops and the connections: a connection's writes are serving steps",
    ),
    ("agents/mod.rs", 1, "the hub's shutdown"),
    // write to clients: not on the clock yet; the gated tests do not reach them
    ("server.rs", 3, "the resume, the embedder and the backup"),
    ("sessions.rs", 2, "a session's MCP sockets"),
    ("agents/wake.rs", 1, "a job end's wake"),
    (
        "agents/session.rs",
        6,
        "a session's run, turns, steps and permission asks",
    ),
    ("runner/tick.rs", 2, "a plan task's start and fallback"),
    ("runner/review.rs", 1, "a plan review's work"),
];

#[test]
fn no_raw_spawn_outside_the_clock() {
    let mut bad = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for (rel, text) in hub_sources() {
        let sites = sites_of(&text, RAW_SPAWN);
        let allowed: usize = RAW_SPAWNS
            .iter()
            .filter(|(f, ..)| *f == rel)
            .map(|(_, n, _)| n)
            .sum();
        if sites.len() != allowed {
            bad.push(format!(
                "src/{rel}: {} raw spawn(s), {allowed} listed:",
                sites.len()
            ));
            bad.extend(sites.iter().map(|(n, l)| format!("  src/{rel}:{n}: {l}")));
        }
        seen.insert(rel);
    }
    for (f, ..) in RAW_SPAWNS {
        if !seen.contains(*f) {
            bad.push(format!("src/{f}: listed, and no such file"));
        }
    }
    assert!(
        bad.is_empty(),
        "raw spawns outside src/clock.rs differ from RAW_SPAWNS; a task that writes to a client starts with \
         crate::clock::spawn(\"module:what\", …) (and a list entry goes when its site does):\n{}",
        bad.join("\n")
    );
}

#[test]
fn the_scan_skips_comments_and_cfg_test_items() {
    let text = "// Instant::now()\nfn a() { clock::now(); }\n#[cfg(test)]\nmod t {\n    fn b() { std::time::Instant::now(); }\n}\nfn c() { std::time::SystemTime::now(); }\n";
    let sites = raw_sites(text);
    assert_eq!(sites.len(), 1);
    assert_eq!(sites[0].0, 7);
}
