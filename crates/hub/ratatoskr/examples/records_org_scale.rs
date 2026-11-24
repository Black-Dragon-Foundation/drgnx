//! The records system at the size of an org folder (`docs/develop/records.md`, "Scale"): run by
//! `cargo xtask measure records_org_scale`, which writes the report.
//!
//! `records_org_scale TREE OUT [REPS]`: generates under TREE a project shaped like the org folder (2,000 record files,
//! about 50 MB: 900 plans, 199 ledgers, 600 specs, 300 decision records and a 1,500-row `DEFERRED.md`), then, REPS times
//! on a fresh store, times the cold import, the second (idempotent) import, `sync_all` and `records/status`. OUT gets
//! the medians in milliseconds, the peak RSS and the tree's size, as one JSON object. TREE is removed at the end.

use norn::deny::DenyList;
use norn::store::CoordDb;
use ratatoskr::records::{Ears, ViewEvent, Views, import_core, status_core};
use serde_json::json;
use std::path::{Path, PathBuf};

const PLANS: usize = 900;
const LEDGERS: usize = 199;
const SPECS: usize = 600;
const DECISIONS: usize = 300;
const DEFERRED_ROWS: usize = 1500;

/// Filler prose, about 400 bytes a paragraph.
const PROSE: &str = "The importer reads this paragraph as part of its piece. It names a crate, a test row and a \
reason, the way a real plan does, so the parser and the merge see text shaped like the org folder's own: words, \
`code spans`, a [link](../specs/x/spec-1.md) and a list of things that must hold before the task is done. Nothing \
here is special; the size is the point.\n\n";

fn io(e: std::io::Error) -> villa::Error {
    villa::Error::from(e)
}

fn put(path: &Path, text: &str) -> villa::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(io)?;
    }
    ratatoskr::fsio::write(path, text).map_err(io)
}

/// TEXT padded with prose to about BYTES.
fn padded(mut text: String, bytes: usize) -> String {
    while text.len() < bytes {
        text.push_str(PROSE);
    }
    text
}

fn plan(i: usize) -> String {
    let mut t = format!("# Plan {i}: a synthetic plan\n\n**Goal:** what plan {i} builds.\n\n");
    for task in 1..=20 {
        t.push_str(&format!("### Task {task}: step {task} of plan {i}\n\n"));
        for step in 1..=5 {
            let tick = if (i + task + step).is_multiple_of(3) {
                'x'
            } else {
                ' '
            };
            t.push_str(&format!("- [{tick}] **Step {step}:** do part {step}\n"));
        }
        t.push('\n');
        t.push_str(&PROSE.repeat(3));
    }
    padded(t, 32 * 1024)
}

fn ledger(i: usize) -> String {
    let mut t = format!("# Ledger: plan {i}\n\n");
    for w in 1..=6 {
        t.push_str(&format!(
            "## Wave {w}\n\n- base `abc{w:04}`, tip `def{w:04}`\n\n{PROSE}"
        ));
    }
    padded(t, 15 * 1024)
}

fn spec(i: usize) -> String {
    let mut t = format!("# Spec {i}: a synthetic design\n\n**Status:** approved\n\n{PROSE}");
    for s in 1..=12 {
        t.push_str(&format!("## {s}. Section {s}\n\n{PROSE}{PROSE}"));
    }
    padded(t, 25 * 1024)
}

fn decision(i: usize) -> String {
    let t = format!(
        "# ADR {i}: a synthetic decision\n\n**Status:** accepted\n\n## Context\n\n{PROSE}## Decision\n\n{PROSE}\
         ## Consequences\n\n{PROSE}"
    );
    padded(t, 8 * 1024)
}

fn deferred() -> String {
    let mut t = String::from(
        "# Deferred items\n\nSynthetic register.\n\n| # | Area | Item | Status |\n|---|---|---|---|\n",
    );
    for r in 1..=DEFERRED_ROWS {
        let status = if r % 4 == 0 { "fixed in M2" } else { "open" };
        t.push_str(&format!(
            "| D-{r} | area-{} | item {r}: a thing to do later, with a reason and a place | {status} |\n",
            r % 17
        ));
    }
    t
}

/// The tree under ROOT; its size in bytes.
fn generate(root: &Path) -> villa::Result<u64> {
    let mut files: Vec<(PathBuf, String)> = Vec::new();
    for i in 0..PLANS {
        let dir = root.join(format!("docs/plans/p{:02}", i / 100));
        files.push((dir.join(format!("plan-{i}.md")), plan(i)));
        if i < LEDGERS {
            files.push((dir.join(format!("plan-{i}.ledger.md")), ledger(i)));
        }
    }
    for i in 0..SPECS {
        files.push((
            root.join(format!("docs/specs/s{:02}/spec-{i}.md", i / 100)),
            spec(i),
        ));
    }
    for i in 0..DECISIONS {
        files.push((root.join(format!("docs/decisions/adr-{i}.md")), decision(i)));
    }
    files.push((root.join("DEFERRED.md"), deferred()));
    let mut bytes = 0;
    for (p, t) in &files {
        put(p, t)?;
        bytes += t.len() as u64;
    }
    Ok(bytes)
}

fn ms(since: stund::Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v.get(v.len() / 2).copied().unwrap_or(0.0)
}

/// The process's peak resident set, KiB (`VmHWM`).
fn peak_rss_kib() -> f64 {
    ratatoskr::fsio::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find_map(|l| l.strip_prefix("VmHWM:"))
                .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        })
        .unwrap_or(0.0)
}

/// One rep on a fresh store under STATE: the four timings, ms.
async fn rep(root: &Path, state: &Path) -> villa::Result<[f64; 4]> {
    let fail = |e: runstav::wire::Error| villa::Error::internal(e.message);
    let db = CoordDb::spawn(state.join("work.db"));
    let views = Views::default();
    let deny = DenyList::load(&state.join("home"), &state.join("config"));
    let hub = state.join("hub");
    let quiet = |_e: ViewEvent| {};
    let ears = Ears {
        emit: &quiet,
        deny: &deny,
    };
    let t = stund::Instant::now();
    let cold = import_core(&db, &views, &hub, root, None, None, false, ears)
        .await
        .map_err(fail)?;
    let cold_ms = ms(t);
    if cold.files.len() < PLANS + LEDGERS + SPECS + DECISIONS {
        return Err(villa::Error::internal(format!(
            "the import found {} files",
            cold.files.len()
        )));
    }
    let t = stund::Instant::now();
    import_core(&db, &views, &hub, root, None, None, false, ears)
        .await
        .map_err(fail)?;
    let again_ms = ms(t);
    let t = stund::Instant::now();
    views.sync_all(&db).await.map_err(fail)?;
    let sync_ms = ms(t);
    let t = stund::Instant::now();
    status_core(&db, &views, None).await.map_err(fail)?;
    let status_ms = ms(t);
    Ok([cold_ms, again_ms, sync_ms, status_ms])
}

fn main() -> villa::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(tree), Some(out)) = (args.first(), args.get(1)) else {
        return Err(villa::Error::invalid(
            "usage: records_org_scale TREE OUT [REPS]",
        ));
    };
    let reps: usize = args.get(2).and_then(|r| r.parse().ok()).unwrap_or(5).max(1);
    // absolute: the deny list (personal notes) compares absolute paths
    let tree = std::path::absolute(tree).map_err(io)?;
    if tree.exists() {
        std::fs::remove_dir_all(&tree).map_err(io)?;
    }
    let root = tree.join("folder");
    let bytes = generate(&root)?;
    let mut runs: Vec<[f64; 4]> = Vec::new();
    for r in 0..reps {
        let state = tree.join(format!("state-{r}"));
        std::fs::create_dir_all(&state).map_err(io)?;
        let one = saman::block_on_current(rep(&root, &state))?;
        annall::cli_out(&format!(
            "rep {r}: cold {:.0} ms, again {:.0} ms, sync_all {:.0} ms, status {:.0} ms",
            one[0], one[1], one[2], one[3]
        ))?;
        runs.push(one);
        std::fs::remove_dir_all(&state).map_err(io)?;
    }
    let col = |i: usize| median(runs.iter().map(|r| r[i]).collect());
    let report = json!({
        "import_cold_ms": col(0),
        "import_again_ms": col(1),
        "sync_all_ms": col(2),
        "status_ms": col(3),
        "peak_rss_kib": peak_rss_kib(),
        "tree_bytes": bytes as f64,
        "tree_files": (PLANS + LEDGERS + SPECS + DECISIONS + 1) as f64,
        "reps": reps as f64,
    });
    put(Path::new(out), &report.to_string())?;
    std::fs::remove_dir_all(&tree).map_err(io)?;
    Ok(())
}
