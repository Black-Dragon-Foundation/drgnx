//! The map core's and the layout's budgets (design §13, `work-layout-hub-p95`): timing tests, run by the timing lane
//! on the optimized build (`test/timing-rust.txt`), never by the other Rust jobs.

use vegvisir::{
    Core, Event, Mode, PresenceEntry, PresenceFact, StepFact, ViewId, ViewOp, ViewState, fixture,
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
        view: ViewId {
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
        let start = stund::real::instant();
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
        let start = stund::real::instant();
        let l = vegvisir::layout::layout(m, v, if i % 3 == 2 { Some(&prev) } else { None });
        times.push(start.elapsed().as_nanos());
        if i % 3 == 0 {
            prev = l;
        }
    }
    let p = p95(times);
    assert!(p <= 2_000_000, "layout p95 {p} ns");
}

/// The Timeline's and the Schedule's budgets (the timeline spec's §12): their rows on a 1000-px env.
mod timeline_schedule {
    use super::p95;
    use rodd::fit::Measure;
    use rodd::svg::Palette;
    use vegvisir::render::Env;
    use vegvisir::schedule::{self, BarFacts, SchedRow};
    use vegvisir::trail::{self, Detail, Lane, NowLine, Step, TrailFilter, Window, Zone};

    struct Cols;

    impl Measure for Cols {
        fn advance(&self, _role: &str, _ch: char) -> Option<f32> {
            Some(8.0)
        }
        fn fallback(&self, _role: &str) -> f32 {
            8.0
        }
    }

    fn env(p: &Palette) -> Env<'_> {
        Env {
            epoch: 1,
            scale: 1.0,
            tty: false,
            cell: (8, 16),
            width_px: 1000,
            palette: p,
            tty_widths: &[],
            line: (16, 80),
            hc: false,
        }
    }

    /// 30 lanes of 10,000 steps each over the window's 10,000 s.
    fn lanes() -> Vec<Lane> {
        let kinds = [Some("read"), Some("edit"), None, Some("search")];
        (0..30)
            .map(|l| Lane {
                id: format!("s{l}"),
                label: format!("agent {l}"),
                steps: (0..10_000)
                    .map(|i| Step {
                        id: i,
                        seq: i as u64 + 1,
                        class: if i % 7 == 0 {
                            "think".into()
                        } else {
                            "tool".into()
                        },
                        tool: None,
                        detail: Detail {
                            kind: kinds[i as usize % 4].map(Into::into),
                            ..Detail::default()
                        },
                        start: i as f64,
                        end: Some(i as f64 + 0.7),
                    })
                    .collect(),
            })
            .collect()
    }

    /// 300 rows: 10 plans of 29 tasks under a spec, some done, some running, some not started.
    fn sched() -> Vec<SchedRow> {
        let mut out = vec![SchedRow {
            item: "spec:s".into(),
            label: "spec".into(),
            depth: 0,
            bar: None,
            budget: None,
        }];
        for p in 0..10 {
            out.push(SchedRow {
                item: format!("plan:p{p}"),
                label: format!("plan {p}"),
                depth: 1,
                bar: None,
                budget: None,
            });
            for t in 0..29 {
                let k = f64::from(p * 29 + t);
                let f = BarFacts {
                    started: (t % 3 != 2).then_some(k * 10.0),
                    ended: (t % 3 == 0).then_some(k * 10.0 + 300.0),
                    done: t % 3 == 0,
                    start: Some(k * 10.0),
                    p50: Some(k * 10.0 + 600.0),
                    p90: Some(k * 10.0 + 900.0),
                    baseline: Some(k * 10.0 + 500.0),
                    machine: Some(format!("m{}", t % 4)),
                    ..BarFacts::default()
                };
                out.push(SchedRow {
                    item: format!("task:p{p}#{t}"),
                    label: format!("task {t}"),
                    depth: 2,
                    bar: Some(schedule::bar(&f, 2000.0)),
                    budget: None,
                });
            }
        }
        out
    }

    fn timeline(l: &[Lane], e: &Env, win: &Window, now: f64) -> Vec<rodd::Row> {
        trail::timeline_rows(
            l,
            e,
            &Cols,
            Zone(0),
            win,
            trail::track_cols(e),
            TrailFilter::All,
            Some(now),
            now,
        )
    }

    fn sched_rows(r: &[SchedRow], e: &Env, win: &Window, now: f64) -> Vec<rodd::Row> {
        schedule::schedule_rows(
            r,
            e,
            &Cols,
            Zone(0),
            win,
            trail::track_cols(e),
            Some(now),
            now,
        )
    }

    #[test]
    #[ignore = "timing: the Activity's first rows at 30 lanes x 10,000 steps within 100 ms"]
    fn activity_open_within_100_ms() {
        let p = Palette::default();
        let e = env(&p);
        let l = lanes();
        let win = Window {
            from: 0.0,
            to: 10_000.0,
        };
        let t = stund::real::instant();
        let rows = timeline(&l, &e, &win, 9_000.0);
        let ms = t.elapsed().as_millis();
        assert_eq!(rows.len(), 31);
        assert!(ms <= 100, "activity-open {ms} ms");
    }

    #[test]
    #[ignore = "timing: the Schedule's first rows at 300 rows within 100 ms"]
    fn schedule_open_within_100_ms() {
        let p = Palette::default();
        let e = env(&p);
        let r = sched();
        let win = Window {
            from: 0.0,
            to: 4_000.0,
        };
        let t = stund::real::instant();
        let rows = sched_rows(&r, &e, &win, 2_000.0);
        let ms = t.elapsed().as_millis();
        assert!(rows.len() > 300);
        assert!(ms <= 100, "schedule-open {ms} ms");
    }

    #[test]
    #[ignore = "timing: a Schedule zoom (rows again over a new window) within 50 ms at p95"]
    fn schedule_zoom_within_50_ms() {
        let p = Palette::default();
        let e = env(&p);
        let r = sched();
        let mut ms = Vec::new();
        for i in 0..40 {
            let span = 1_000.0 + f64::from(i) * 200.0;
            let win = Window {
                from: 2_000.0 - span / 2.0,
                to: 2_000.0 + span / 2.0,
            };
            let t = stund::real::instant();
            let rows = sched_rows(&r, &e, &win, 2_000.0);
            ms.push(t.elapsed().as_millis());
            assert!(rows.len() > 300);
        }
        let p = p95(ms);
        assert!(p <= 50, "schedule-zoom p95 {p} ms");
    }

    // the clock is the `now` argument, not the wall: a plain test, not a timing one
    #[test]
    fn now_line_at_most_once_per_5_s() {
        let win = Window {
            from: 0.0,
            to: 600.0,
        };
        let mut line = NowLine::default();
        assert!(line.due(100.0, trail::now_col(&win, 4096, 100.0)));
        for window in 0..20 {
            let from = 100.5 + 5.0 * f64::from(window);
            let drawn = (0..5)
                .filter(|s| {
                    let now = from + f64::from(*s);
                    line.due(now, trail::now_col(&win, 4096, now))
                })
                .count();
            assert!(drawn <= 1, "now-line {drawn} draws in 5 s");
        }
    }

    #[test]
    #[ignore = "timing: a now-line move's patch (rows again and their diff) at 300 Schedule rows within 3 ms at p95"]
    fn now_line_patch_within_3_ms() {
        let p = Palette::default();
        let e = env(&p);
        let r = sched();
        let win = Window {
            from: 0.0,
            to: 4_000.0,
        };
        let mut before = sched_rows(&r, &e, &win, 2_000.0);
        let mut us = Vec::new();
        for i in 1..=40 {
            let now = 2_000.0 + 5.0 * f64::from(i);
            let t = stund::real::instant();
            let after = sched_rows(&r, &e, &win, now);
            let ops = rodd::diff(&before, &after);
            us.push(t.elapsed().as_micros());
            assert!(!ops.is_empty());
            before = after;
        }
        let p = p95(us);
        assert!(p <= 3_000, "now-line-patch p95 {p} us");
    }
}
