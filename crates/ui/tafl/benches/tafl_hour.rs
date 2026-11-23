//! G6 at engine level (spec §17): one hour on a virtual clock. A Files-like screen of 40 row instances over a filtered
//! collection of 5,000 items scrolls by one row a second (a row's slab dropped at the top, one made at the bottom, its
//! named state kept by name), the query changes every 10 s, and a minute clock drives "ago" labels and the status line.
//! The screen repeats every 200 s, so the same screen at 400 s (warm) and at 3,600 s must have the same cell count, and
//! the engine's bytes and the live heap must be flat (within 1%).

mod common;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use tafl::{CellId, Engine, InstanceKey, List, Monotone, Origin, SlabId, Splice, Stage, StateKey};

tafl::model! {
    pub struct Item { pub name: Arc<str>, pub size: u64 }
}

const ITEMS: u64 = 5_000;
const ROWS: usize = 40;
const PERIOD: u64 = 200;
const QUERIES: [&str; 4] = ["1", "12", "3", ""];
const WARM: u64 = 400;
const HOUR: u64 = 3_600;

fn matches(it: &Item, q: &Arc<str>) -> bool {
    it.name.contains(&**q)
}

fn refines(old: &Arc<str>, new: &Arc<str>) -> bool {
    new.contains(&**old)
}

/// One row instance: its slab and its demand roots.
struct Row {
    slab: SlabId,
    roots: [CellId; 2],
}

fn row(e: &mut Engine, shown: List<Item>, minute: tafl::Formula<Duration>, k: usize) -> Row {
    let slab = e.slab(InstanceKey {
        doc: Arc::from("files"),
        path: Arc::from(&[k as u32][..]),
    });
    let expanded = e.named_state(
        slab,
        StateKey {
            doc: Arc::from("files"),
            path: Arc::from(&[k as u32][..]),
            name: Arc::from("expanded"),
        },
        false,
    );
    if k.is_multiple_of(7) {
        e.write(Origin::User, |w| expanded.set(w, true));
    }
    let label = e.formula(slab, Stage::Items, move |r| {
        let w = shown.window(r, k..k + 1);
        let name = w
            .iter()
            .next()
            .map(|o| o.name(r).to_string())
            .unwrap_or_default();
        format!("{}{name}", if expanded.get(r) { "v " } else { "> " })
    });
    let ago = e.formula(slab, Stage::Items, move |r| {
        format!("{} min ago", minute.get(r).as_secs() / 60 % 60)
    });
    Row {
        slab,
        roots: [label.id(), ago.id()],
    }
}

fn main() -> ExitCode {
    let clock = stund::Manual::default();
    let pool = Arc::new(saman::Executor::new(1).expect("the work pool"));
    let mut e = Engine::new(pool, Arc::new(clock.clone()));
    let chrome = e.slab(InstanceKey {
        doc: Arc::from("files"),
        path: Arc::from(&[][..]),
    });
    let items = e.list::<Item>();
    e.write(Origin::Model, |w| {
        let objs = (0..ITEMS)
            .map(|i| {
                w.insert(Item {
                    name: format!("file-{i}.rs").into(),
                    size: i * 37 % 4096,
                })
                .model_ref()
            })
            .collect();
        items.splice(
            w,
            Splice::Insert {
                after: None,
                items: objs,
            },
        );
    });
    let query: tafl::State<Arc<str>> = e.state(chrome, Arc::from(QUERIES[0]));
    let shown = items.filter_by(
        &mut e,
        move |r| query.get(r),
        matches,
        Monotone::Yes(refines),
    );
    let minute = e.clock(Duration::from_secs(60));
    let status = e.formula(chrome, Stage::Items, move |r| {
        format!(
            "{} of {} · {} min",
            shown.len(r),
            items.len(r),
            minute.get(r).as_secs() / 60
        )
    });

    let mut rows: Vec<Row> = (0..ROWS).map(|k| row(&mut e, shown, minute, k)).collect();
    let budget = Duration::from_millis(16);
    let mut warm = None;
    for t in 1..=HOUR {
        clock.advance(Duration::from_secs(1));
        // scroll one row: the top row's slab goes, a new one comes at the bottom
        let top = (t - 1) % PERIOD;
        let gone = rows.remove(0);
        e.drop_slab(gone.slab);
        let k = ((top + ROWS as u64) % PERIOD) as usize;
        rows.push(row(&mut e, shown, minute, k));
        if t % 10 == 0 {
            let q = QUERIES[(t / 10) as usize % QUERIES.len()];
            e.write(Origin::User, |w| query.set(w, Arc::from(q)));
        }
        let mut roots = vec![status.id()];
        roots.extend(rows.iter().flat_map(|r| r.roots));
        let out = e.frame(&roots, budget);
        assert!(
            out.deferred.is_empty(),
            "a frame of the hour ran over its budget on a virtual clock"
        );
        if t == WARM {
            warm = Some((e.stats(), common::live()));
        }
    }
    let (w, w_live) = warm.expect("the warm point is inside the hour");
    let end = e.stats();
    let end_live = common::live();
    let mut b = common::Bench::new("tafl_hour");
    b.bar(
        "cell_count_change",
        (end.cells as f64 - w.cells as f64).abs(),
        0.0,
    );
    b.bar(
        "engine_bytes_drift",
        (end.bytes as f64 - w.bytes as f64) / w.bytes as f64,
        0.01,
    );
    b.bar(
        "heap_drift",
        (end_live - w_live) as f64 / w_live as f64,
        0.01,
    );
    b.metric("cells", end.cells as f64);
    b.metric("engine_bytes", end.bytes as f64);
    b.metric("heap_bytes", end_live as f64);
    b.metric("timers", end.timers as f64);
    b.metric("stored_states", e.stored_states() as f64);
    b.finish()
}
