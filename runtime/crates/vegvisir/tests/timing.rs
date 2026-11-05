//! The map core's and the layout's budgets (design §13, `work-layout-hub-p95`): timing tests, run by the timing lane
//! on the optimized build (`test/timing-rust.txt`), never by the other Rust jobs.

use std::time::Instant;

use vegvisir::{
    Core, Event, Mode, PresenceEntry, PresenceFact, StepFact, ViewKey, ViewOp, ViewState, fixture,
};

fn p95(mut v: Vec<u128>) -> u128 {
    v.sort_unstable();
    v[v.len() * 95 / 100]
}

/// The 30-agent fixture's live traffic: steps, presence, a changed set and the clock, one event at a time.
fn live_events(n: usize) -> Vec<Event> {
    (0..n)
        .map(|i| {
            let s = format!("s{:02}", i % 26 + 1);
            match i % 10 {
                0..=5 => Event::Step(StepFact {
                    session: s,
                    step: 2 + i as i64,
                    class: "edit".into(),
                    minute: 60,
                    conclusion: (i % 7 == 0).then(|| format!("conclusion {i}")),
                }),
                6 | 7 => Event::Presence(PresenceFact {
                    file: format!("drgnx/core/drgnx-hub-core.el{}", i % 3),
                    entries: vec![PresenceEntry {
                        session: s,
                        mode: if i % 2 == 0 { Mode::Read } else { Mode::Edit },
                        line: Some(i as u32),
                    }],
                }),
                8 => Event::Changed {
                    worktree: "wt/as2-map".into(),
                    base: "c-as2".into(),
                    files: (0..7)
                        .map(|k| {
                            (
                                format!("drgnx/runtime/crates/vegvisir/src/f{k}.rs"),
                                (k + i as u32, 0),
                            )
                        })
                        .collect(),
                },
                _ => Event::Tick {
                    minute: 61 + i as u64,
                },
            }
        })
        .collect()
}

/// A core step on the 30-agent model (about 200 items, a shown view) stays within 50 µs at p95.
#[test]
#[ignore = "timing: a core step on the 30-agent model within 50 us at p95"]
fn core_step_within_50_us() {
    let mut core = Core::new();
    for e in fixture::thirty() {
        core.step(e);
    }
    core.step(Event::View(ViewOp::Open {
        view: ViewKey {
            conn: 1,
            view: "map".into(),
        },
        state: ViewState {
            width_units: 226,
            ..ViewState::default()
        },
        shown: true,
    }));
    let mut times = Vec::new();
    for e in live_events(2000) {
        let start = Instant::now();
        let effects = core.step(e);
        times.push(start.elapsed().as_nanos());
        std::hint::black_box(effects);
    }
    let p = p95(times);
    assert!(p <= 50_000, "core step p95 {p} ns");
}

/// The layout of the 30-agent model (about 200 items) at 1000 px stays within 2 ms at p95: the default view, the
/// overlaps filter (every edited file of the overlapping branches) and a relayout with the previous layout.
#[test]
#[ignore = "timing: the layout of the 30-agent model within 2 ms at p95"]
fn layout_200_items_within_2_ms() {
    let mut core = Core::new();
    for e in fixture::thirty() {
        core.step(e);
    }
    let m = core.model();
    let plain = ViewState {
        width_units: 226,
        ..ViewState::default()
    };
    let mut overlaps = plain.clone();
    overlaps.filters.overlaps = true;
    let mut prev = vegvisir::layout::layout(m, &plain, None);
    let mut times = Vec::new();
    for i in 0..300 {
        let v = if i % 3 == 1 { &overlaps } else { &plain };
        let start = Instant::now();
        let l = vegvisir::layout::layout(m, v, if i % 3 == 2 { Some(&prev) } else { None });
        times.push(start.elapsed().as_nanos());
        if i % 3 == 0 {
            prev = l;
        }
    }
    let p = p95(times);
    assert!(p <= 2_000_000, "layout p95 {p} ns");
}
