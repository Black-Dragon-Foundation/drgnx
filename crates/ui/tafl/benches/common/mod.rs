//! What the gate benches share: a counting allocator (live heap bytes), a real clock through stund, and the report that
//! records each metric against its bar (a `vag::Report`; the bench exits 1 when a bar is missed).

#![allow(dead_code)]

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::process::ExitCode;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

/// Counts the live heap bytes of the process (as requested, not as the allocator rounds them).
struct Counting;

static LIVE: AtomicI64 = AtomicI64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        LIVE.fetch_add(l.size() as i64, Ordering::Relaxed);
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size() as i64, Ordering::Relaxed);
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        LIVE.fetch_add(n as i64 - l.size() as i64, Ordering::Relaxed);
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// Live heap bytes now.
pub fn live() -> i64 {
    LIVE.load(Ordering::Relaxed)
}

/// The real clock, through stund (tokio's when nothing is installed).
pub struct Real;

impl stund::Provider for Real {
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(stund::sleep(d))
    }
    fn now(&self) -> Duration {
        stund::now()
    }
}

/// The 99th percentile of V (sorted in place).
pub fn p99(v: &mut [f64]) -> f64 {
    v.sort_by(f64::total_cmp);
    let i = ((v.len() as f64) * 0.99).ceil() as usize;
    v[i.saturating_sub(1).min(v.len() - 1)]
}

/// One bench's report: its metrics and the bars they were held to.
pub struct Bench {
    name: &'static str,
    metrics: BTreeMap<String, f64>,
    lines: Vec<String>,
    missed: usize,
}

impl Bench {
    pub fn new(name: &'static str) -> Bench {
        Bench {
            name,
            metrics: BTreeMap::new(),
            lines: Vec::new(),
            missed: 0,
        }
    }

    /// A metric with no bar (context for the reader).
    pub fn metric(&mut self, k: &str, v: f64) {
        self.metrics.insert(k.to_string(), v);
        self.lines.push(format!("{}: {k} = {v:.3}", self.name));
    }

    /// A metric held to V <= MAX.
    pub fn bar(&mut self, k: &str, v: f64, max: f64) {
        self.metrics.insert(k.to_string(), v);
        let ok = v <= max;
        if !ok {
            self.missed += 1;
        }
        let verdict = if ok { "ok" } else { "MISSED" };
        self.lines.push(format!(
            "{}: {k} = {v:.3} (bar <= {max}) {verdict}",
            self.name
        ));
    }

    /// Write the report (`--out PATH`, else `target/vag/NAME.json` under the working directory) and say each line on
    /// stderr; exit 1 when a bar was missed.
    pub fn finish(self) -> ExitCode {
        let args: Vec<String> = std::env::args().collect();
        let out = args
            .iter()
            .position(|a| a == "--out")
            .and_then(|i| args.get(i + 1).cloned())
            .unwrap_or_else(|| format!("target/vag/{}.json", self.name));
        let report = vag::Report {
            name: self.name.to_string(),
            commit: std::env::var("DRGNX_COMMIT").unwrap_or_else(|_| "unknown".into()),
            machine: std::env::var("DRGNX_MACHINE").unwrap_or_else(|_| "unknown".into()),
            metrics: self.metrics,
        };
        let mut said = Vec::new();
        if let Some(dir) = std::path::Path::new(&out).parent()
            && let Err(e) = std::fs::create_dir_all(dir)
        {
            said.push(format!("{}: cannot make {}: {e}", self.name, dir.display()));
        }
        if let Err(e) = report.write_json(&out) {
            said.push(format!("{}: cannot write {out}: {e}", self.name));
        }
        let failed = self.missed > 0 || !said.is_empty();
        said.extend(self.lines);
        said.push(format!(
            "{}: report {out}; {} bar(s) missed",
            self.name, self.missed
        ));
        for l in &said {
            // stderr gone: the report file is the record
            if annall::cli_err(l).is_err() {
                break;
            }
        }
        if failed {
            ExitCode::from(1)
        } else {
            ExitCode::SUCCESS
        }
    }
}
