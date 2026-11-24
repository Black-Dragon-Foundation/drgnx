//! G3 per cell (spec §17): 100,000 formulas of two sources each (over 1,000 states), every one pulled once, so each
//! has its value, its closure and its edges. The live heap the cells added, divided by the cells, is held to 96 B on
//! average; the worst of five runs to the 160 B ceiling.
//!
//! Each formula reads one source among the 64 cells made just before it and one among the 1,024 before it: every cell
//! has two readers on average, spread like real views (a few have many), so edges spill as they would.

mod common;

use std::process::ExitCode;
use std::sync::Arc;

use tafl::{Engine, Formula, InstanceKey, Stage, State};

const STATES: usize = 1_000;
const FORMULAS: usize = 100_000;
const RUNS: usize = 5;

/// One run: the heap bytes per cell, and the engine's own estimate per cell.
fn one() -> (f64, f64) {
    let pool = Arc::new(saman::Executor::new(1).expect("the work pool"));
    let mut e = Engine::new(pool, Arc::new(common::Real));
    let s = e.slab(InstanceKey {
        doc: Arc::from("bench"),
        path: Arc::from(&[][..]),
    });
    let mut states: Vec<State<u64>> = Vec::with_capacity(STATES);
    let mut fs: Vec<Formula<u64>> = Vec::with_capacity(FORMULAS);
    let before = common::live();
    for i in 0..STATES {
        states.push(e.state(s, i as u64));
    }
    for st in &states {
        let a = *st;
        fs.push(e.formula(s, Stage::Formula, move |r| a.get(r) + 1));
    }
    let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x as usize
    };
    while fs.len() < FORMULAS {
        let n = fs.len();
        let a = fs[n - 1 - next() % 64.min(n)];
        let b = fs[n - 1 - next() % 1024.min(n)];
        fs.push(e.formula(s, Stage::Formula, move |r| {
            a.get(r).wrapping_add(b.get(r)) % 1_000_003
        }));
    }
    // in creation order: each formula's sources are up to date before it runs
    for f in &fs {
        e.pull(*f);
    }
    let added = common::live() - before;
    let cells = (STATES + FORMULAS) as f64;
    let stats = e.stats();
    assert_eq!(stats.cells as usize, STATES + FORMULAS);
    (added as f64 / cells, stats.bytes as f64 / cells)
}

fn main() -> ExitCode {
    let mut b = common::Bench::new("tafl_cells");
    let runs: Vec<(f64, f64)> = (0..RUNS).map(|_| one()).collect();
    let avg = runs.iter().map(|r| r.0).sum::<f64>() / RUNS as f64;
    let worst = runs.iter().map(|r| r.0).fold(0.0, f64::max);
    let est = runs.iter().map(|r| r.1).sum::<f64>() / RUNS as f64;
    b.bar("bytes_per_cell", avg, 96.0);
    b.bar("bytes_per_cell_worst", worst, 160.0);
    b.metric("engine_bytes_per_cell", est);
    b.finish()
}
