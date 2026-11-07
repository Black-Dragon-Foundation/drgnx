//! The trail and the Timeline as rows (`vegvisir::trail`): what a new conclusion or step dirties, every order of
//! their arrival, the env's time zone. Pure ([A], [D]).

use drgnx_rows::fit::Measure;
use drgnx_rows::svg::Palette;
use drgnx_rows::{Op, Row};
use vegvisir::render::Env;
use vegvisir::trail::{self, Conclusion, Detail, Lane, Step, Zone};

struct Cols;

impl Measure for Cols {
    fn advance(&self, _role: &str, ch: char) -> Option<f32> {
        Some(8.0 * drgnx_rows::fit_tty::char_width(ch, &[]) as f32)
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
    }
}

/// Step ID at START, closed 2 s later: a read of `src/aN.rs`.
fn step(id: i64, start: f64) -> Step {
    Step {
        id,
        seq: u64::try_from(id).unwrap(),
        class: "tool".into(),
        tool: Some("Read".into()),
        detail: Detail {
            kind: Some("read".into()),
            path: Some(format!("src/a{id}.rs")),
            ..Detail::default()
        },
        start,
        end: Some(start + 2.0),
    }
}

fn conclusion(n: u32, on: i64, rests: &[i64]) -> Conclusion {
    Conclusion {
        n,
        kind: "finding".into(),
        text: format!("finding {n}"),
        step: Some(on),
        rests_on: rests.to_vec(),
        unmatched: Vec::new(),
    }
}

/// [A] A new conclusion resting on step 2 replaces only step 2's row (its pill) and inserts its card after step 3,
/// where it was stamped.
#[test]
fn a_conclusion_dirties_only_its_steps() {
    let p = Palette::default();
    let steps: Vec<Step> = (1..=4).map(|i| step(i, 1000.0 + 10.0 * i as f64)).collect();
    let before = trail::trail_rows(&steps, &[], &env(&p), Zone(0));
    assert_eq!(before.len(), 4, "{before:?}");
    let after = trail::trail_rows(&steps, &[conclusion(1, 3, &[2])], &env(&p), Zone(0));
    let ops = drgnx_rows::diff(&before, &after);
    let replaced: Vec<&str> = ops
        .iter()
        .flat_map(|o| match o {
            Op::Replace(rows) => rows.iter().map(|r| r.key.as_str()).collect(),
            _ => Vec::new(),
        })
        .collect();
    assert_eq!(replaced, ["step:2"], "{ops:?}");
    assert!(
        ops.iter().any(
            |o| matches!(o, Op::Insert { after: Some(a), rows } if a == "step:3" && rows.len() == 2)
        ),
        "{ops:?}"
    );
    let s2 = after.iter().find(|r| r.key == "step:2").unwrap();
    assert!(s2.text.contains("src/a2.rs [1]"), "{}", s2.text);
}

/// [A] A step inside the Timeline's range redraws its own lane only; one past the range moves every lane's scale.
#[test]
fn timeline_lane_redraws_only_on_its_range() {
    let p = Palette::default();
    let lane = |id: &str, steps: Vec<Step>| Lane {
        id: id.into(),
        label: format!("agent {id}"),
        steps,
    };
    let a = vec![step(1, 1000.0), step(2, 1100.0)];
    let b = vec![step(3, 1010.0)];
    let before = trail::timeline_rows(
        &[lane("a", a.clone()), lane("b", b.clone())],
        &env(&p),
        &Cols,
        Zone(0),
    );
    let mut b2 = b.clone();
    b2.push(step(4, 1050.0));
    let inside = trail::timeline_rows(
        &[lane("a", a.clone()), lane("b", b2)],
        &env(&p),
        &Cols,
        Zone(0),
    );
    match drgnx_rows::diff(&before, &inside).as_slice() {
        [Op::Replace(rows)] => assert_eq!(
            rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
            ["lane:b"]
        ),
        ops => panic!("one lane: {ops:?}"),
    }
    let mut b3 = b;
    b3.push(step(5, 1500.0));
    let past = trail::timeline_rows(&[lane("a", a), lane("b", b3)], &env(&p), &Cols, Zone(0));
    match drgnx_rows::diff(&before, &past).as_slice() {
        [Op::Replace(rows)] => assert_eq!(
            rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
            ["axis", "lane:a", "lane:b"]
        ),
        ops => panic!("the range moved: {ops:?}"),
    }
}

/// [A] Steps and conclusions arriving in every order (each arrival a draw from what came so far) end on the rows of
/// the whole set, and every intermediate draw's diff applies.
#[test]
fn every_order_steps_and_conclusions_converge() {
    let p = Palette::default();
    let all_steps: Vec<Step> = (1..=3).map(|i| step(i, 1000.0 + i as f64)).collect();
    let all_concs = vec![conclusion(1, 2, &[1, 2]), conclusion(2, 3, &[3])];
    let want = trail::trail_rows(&all_steps, &all_concs, &env(&p), Zone(0));
    assert_eq!(
        want.len(),
        7,
        "three steps and two cards of two lines: {want:?}"
    );
    // the five arrivals: three steps and two conclusions, in every order
    let n = 5;
    let mut orders: Vec<Vec<usize>> = vec![vec![]];
    for _ in 0..n {
        orders = orders
            .into_iter()
            .flat_map(|o| {
                let rest: Vec<usize> = (0..n).filter(|i| !o.contains(i)).collect();
                rest.into_iter().map(move |i| [o.clone(), vec![i]].concat())
            })
            .collect();
    }
    assert_eq!(orders.len(), 120);
    for order in orders {
        let (mut steps, mut concs) = (Vec::new(), Vec::new());
        let mut held: Vec<Row> = Vec::new();
        for i in order.iter().copied() {
            if i < 3 {
                steps.push(all_steps[i].clone());
            } else {
                concs.push(all_concs[i - 3].clone());
            }
            let now = trail::trail_rows(&steps, &concs, &env(&p), Zone(0));
            let ops = drgnx_rows::diff(&held, &now);
            held = apply(held, &ops);
            assert_eq!(held, now, "order {order:?}");
        }
        assert_eq!(held, want, "order {order:?}");
    }
}

fn apply(mut rows: Vec<Row>, ops: &[Op]) -> Vec<Row> {
    for op in ops {
        match op {
            Op::Reset(r) => rows = r.clone(),
            Op::Insert { after, rows: new } => {
                let at = after
                    .as_ref()
                    .and_then(|k| rows.iter().position(|r| &r.key == k))
                    .map_or(0, |i| i + 1);
                for (j, r) in new.iter().enumerate() {
                    rows.insert(at + j, r.clone());
                }
            }
            Op::Replace(new) => {
                for r in new {
                    if let Some(o) = rows.iter_mut().find(|o| o.key == r.key) {
                        *o = r.clone();
                    }
                }
            }
            Op::Remove(keys) => rows.retain(|r| !keys.contains(&r.key)),
        }
    }
    rows
}

/// [D] One step, two zones: two row texts, each the step's time in its zone.
#[test]
fn timestamps_use_the_env_time_zone() {
    let p = Palette::default();
    // 2026-11-07 09:30:00 UTC
    let s = vec![step(1, 1_794_043_800.0)];
    let utc = trail::trail_rows(&s, &[], &env(&p), Zone::parse("+0000"));
    let ist = trail::trail_rows(&s, &[], &env(&p), Zone::parse("+0530"));
    assert!(utc[0].text.contains("09:30:00 2.0s"), "{}", utc[0].text);
    assert!(ist[0].text.contains("15:00:00 2.0s"), "{}", ist[0].text);
    assert_eq!(Zone::parse("-0800").time(1_794_043_800.0), "01:30:00");
    assert_eq!(Zone::parse("IST"), Zone(0), "a name is no offset");
}
