//! G5 at engine level (spec §17): 100 cursors typing at once. Each keystroke is one transaction of 100 state writes
//! (every cursor moves), then one frame over the visible blocks: the 40 visible lines and the 100 cursor rows, in a
//! document of 10,000 lines whose line cells read a durable theme. One marking pass a keystroke; the UI work (the
//! transaction and the frame) p99 ≤ 2 ms over 2,000 keystrokes.

mod common;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use tafl::{CellId, Engine, Formula, InstanceKey, Origin, Stage, State};

const LINES: usize = 10_000;
const CURSORS: usize = 100;
const VISIBLE: usize = 40;
const WARM: usize = 200;
const KEYS: usize = 2_000;

fn main() -> ExitCode {
    let pool = Arc::new(saman::Executor::new(1).expect("the work pool"));
    let mut e = Engine::new(pool, Arc::new(common::Real));
    let s = e.slab(InstanceKey {
        doc: Arc::from("bench"),
        path: Arc::from(&[][..]),
    });
    let theme = e.durable(s, 14u32);
    let text: Vec<State<u64>> = (0..LINES).map(|i| e.state(s, i as u64)).collect();
    let lines: Vec<Formula<(u32, u64)>> = text
        .iter()
        .map(|t| {
            let t = *t;
            e.formula(s, Stage::Items, move |r| (theme.get(r) * 2, t.get(r)))
        })
        .collect();
    let cursors: Vec<State<(u32, u32)>> = (0..CURSORS)
        .map(|i| e.state(s, ((i * LINES / CURSORS) as u32, 0)))
        .collect();
    let rows: Vec<Formula<(u32, u32, u64)>> = cursors
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let c = *c;
            let line = lines[i * LINES / CURSORS];
            e.formula(s, Stage::Items, move |r| {
                let (_, col) = c.get(r);
                let (size, len) = line.get(r);
                (col, size, len)
            })
        })
        .collect();
    let mut roots: Vec<CellId> = lines[..VISIBLE].iter().map(|l| l.id()).collect();
    roots.extend(rows.iter().map(|r| r.id()));
    let budget = Duration::from_millis(16);
    e.frame(&roots, budget);

    let mut times = Vec::with_capacity(KEYS);
    let mut passes_max = 0u64;
    let mut passes_min = u64::MAX;
    for k in 0..WARM + KEYS {
        let before = e.stats().mark_passes;
        let t0 = stund::now();
        e.write(Origin::User, |w| {
            for c in &cursors {
                c.update(w, |p| (p.0, p.1 + 1));
            }
        });
        let passes = e.stats().mark_passes - before;
        let out = e.frame(&roots, budget);
        let took = stund::now().saturating_sub(t0);
        assert_eq!(
            out.changed_items.len(),
            CURSORS,
            "every cursor row is damage"
        );
        if k >= WARM {
            times.push(took.as_secs_f64() * 1e3);
            passes_max = passes_max.max(passes);
            passes_min = passes_min.min(passes);
        }
    }
    let mut b = common::Bench::new("tafl_cursors");
    let p99 = common::p99(&mut times);
    let mean = times.iter().sum::<f64>() / times.len() as f64;
    b.bar("mark_passes_per_keystroke", passes_max as f64, 1.0);
    // and at least one: a keystroke that marked nothing would pass the bar above for the wrong reason
    b.bar("no_marking_pass", f64::from(u8::from(passes_min == 0)), 0.0);
    b.bar("ui_work_p99_ms", p99, 2.0);
    b.metric("ui_work_mean_ms", mean);
    b.finish()
}
