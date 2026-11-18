//! The trail and the Timeline as rows (`vegvisir::trail`): what a new conclusion or step dirties, every order of
//! their arrival, the env's time zone. Pure ([A], [D]).

use drgnx_rows::faces::FaceId;
use drgnx_rows::fit::Measure;
use drgnx_rows::svg::Palette;
use drgnx_rows::{Op, Row};
use vegvisir::render::Env;
use vegvisir::trail::{self, Conclusion, Detail, Lane, SegKind, Step, TrailFilter, Window, Zone};

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
    // the step a conclusion rests on starts with its number in a circle (a badge), the others with room for one
    assert!(s2.text.contains(" 1 "), "{}", s2.text);
    assert!(
        s2.runs.iter().any(|r| r.2 == FaceId::WorkStepNumber.name()),
        "{s2:?}"
    );
}

/// The Timeline's rows over the time LANES cover, as a view with no window draws them.
fn timeline(lanes: &[Lane], p: &Palette) -> Vec<Row> {
    let (from, to) = trail::range(lanes);
    let e = env(p);
    trail::timeline_rows(
        lanes,
        &e,
        &Cols,
        Zone(0),
        &Window { from, to },
        trail::track_cols(&e),
        TrailFilter::All,
        None,
        0.0,
    )
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
    let before = timeline(&[lane("a", a.clone()), lane("b", b.clone())], &p);
    let mut b2 = b.clone();
    b2.push(step(4, 1050.0));
    let inside = timeline(&[lane("a", a.clone()), lane("b", b2)], &p);
    match drgnx_rows::diff(&before, &inside).as_slice() {
        [Op::Replace(rows)] => assert_eq!(
            rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
            ["lane:b"]
        ),
        ops => panic!("one lane: {ops:?}"),
    }
    let mut b3 = b;
    b3.push(step(5, 1500.0));
    let past = timeline(&[lane("a", a), lane("b", b3)], &p);
    match drgnx_rows::diff(&before, &past).as_slice() {
        [Op::Replace(rows)] => assert_eq!(
            rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
            ["axis", "lane:a", "lane:b"]
        ),
        ops => panic!("the range moved: {ops:?}"),
    }
}

/// A step of CLASS (and detail KIND) from START to END.
fn seg(id: i64, class: &str, kind: Option<&str>, start: f64, end: f64) -> Step {
    Step {
        id,
        seq: u64::try_from(id).unwrap(),
        class: class.into(),
        tool: None,
        detail: Detail {
            kind: kind.map(Into::into),
            ..Detail::default()
        },
        start,
        end: Some(end),
    }
}

/// [Review Focus 4] Ten thousand short steps of every kind on a 200-column track: at most one segment a column, in
/// order, inside the track; the lane's row holds as few stops.
#[test]
fn bins_never_exceed_one_segment_per_column() {
    let kinds = [
        ("tool", Some("read")),
        ("tool", Some("edit")),
        ("think", None),
        ("user-wait", None),
        ("tool", None),
    ];
    let steps: Vec<Step> = (0..10_000)
        .map(|i| {
            let (c, k) = kinds[i % kinds.len()];
            seg(i as i64 + 1, c, k, i as f64 * 0.1, i as f64 * 0.1 + 0.08)
        })
        .collect();
    let win = Window {
        from: 0.0,
        to: 1000.0,
    };
    let bins = trail::bins(&steps, &win, 200, 1000.0);
    assert!(!bins.is_empty() && bins.len() <= 200, "{}", bins.len());
    let mut at = 0;
    for b in &bins {
        assert!(b.c0 >= at && b.c1 > b.c0 && b.c1 <= 200, "{b:?}");
        at = b.c1;
    }
    let p = Palette::default();
    let e = env(&p);
    let rows = trail::timeline_rows(
        &[Lane {
            id: "a".into(),
            label: "a".into(),
            steps,
        }],
        &e,
        &Cols,
        Zone(0),
        &win,
        200,
        TrailFilter::All,
        None,
        0.0,
    );
    // a stop to each segment's start and one to its end
    assert!(rows[1].stops.len() <= 2 * 200, "{}", rows[1].stops.len());
}

/// A column takes the kind with the most time in it, and that kind's longest step; a tie goes to the kind earlier in
/// the spec's table (read before edit).
#[test]
fn a_bin_takes_its_longest_kind() {
    let win = Window {
        from: 0.0,
        to: 10.0,
    };
    let steps = vec![
        seg(1, "tool", Some("read"), 0.0, 3.0),
        seg(2, "tool", Some("edit"), 3.0, 5.0),
        seg(3, "tool", Some("edit"), 5.0, 9.0),
        seg(4, "think", None, 9.0, 10.0),
    ];
    let b = trail::bins(&steps, &win, 1, 10.0);
    assert_eq!(b.len(), 1);
    assert_eq!((b[0].kind, b[0].seq), (SegKind::Edit, 3));
    let tie = vec![
        seg(1, "tool", Some("edit"), 0.0, 5.0),
        seg(2, "tool", Some("read"), 5.0, 10.0),
    ];
    assert_eq!(trail::bins(&tie, &win, 1, 10.0)[0].kind, SegKind::Read);
    // wide steps keep a segment each
    let wide = trail::bins(&steps, &win, 10, 10.0);
    assert_eq!(
        wide.iter().map(|b| (b.c0, b.c1, b.seq)).collect::<Vec<_>>(),
        [(0, 3, 1), (3, 5, 2), (5, 9, 3), (9, 10, 4)]
    );
    // the letters of the spec's table
    assert_eq!(
        [
            SegKind::Read,
            SegKind::Edit,
            SegKind::Think,
            SegKind::WaitYou,
            SegKind::WaitMachine,
            SegKind::Paused,
            SegKind::Stalled
        ]
        .map(SegKind::letter),
        ['R', 'E', '·', 'Y', 'M', 'P', '!']
    );
}

/// The Edits filter keeps edit segments in their colour and greys the rest; Waits keeps the waits.
#[test]
fn the_edits_filter_keeps_only_edits() {
    let p = Palette::default();
    let e = env(&p);
    let steps = vec![
        seg(1, "tool", Some("read"), 0.0, 40.0),
        seg(2, "tool", Some("edit"), 40.0, 70.0),
        seg(3, "user-wait", None, 70.0, 100.0),
    ];
    let win = Window {
        from: 0.0,
        to: 100.0,
    };
    let faces = |filter| -> Vec<(String, String)> {
        let rows = trail::timeline_rows(
            &[Lane {
                id: "a".into(),
                label: "a".into(),
                steps: steps.clone(),
            }],
            &e,
            &Cols,
            Zone(0),
            &win,
            100,
            filter,
            None,
            0.0,
        );
        let r = &rows[1];
        r.props
            .iter()
            .filter(|(_, _, n, _)| n == "drgnx-work-kind")
            .map(|(s, _, _, v)| {
                let face = r
                    .runs
                    .iter()
                    .find(|(a, _, _)| a == s)
                    .map(|(_, _, f)| f.clone())
                    .unwrap_or_default();
                (v.as_str().unwrap_or("").to_owned(), face)
            })
            .collect()
    };
    let dim = FaceId::WorkDim.name().to_owned();
    assert_eq!(
        faces(TrailFilter::Edits),
        [
            ("R".to_owned(), dim.clone()),
            ("E".to_owned(), FaceId::KitRangeBarSegEdit.name().to_owned()),
            ("Y".to_owned(), dim.clone()),
        ]
    );
    assert_eq!(
        faces(TrailFilter::Waits),
        [
            ("R".to_owned(), dim.clone()),
            ("E".to_owned(), dim),
            ("Y".to_owned(), FaceId::KitRangeBarSegWait.name().to_owned()),
        ]
    );
}

/// The now-line is drawn again at most once every five seconds, and only when it moved a column.
#[test]
fn the_now_line_republishes_at_most_every_five_seconds() {
    let mut line = trail::NowLine::default();
    assert!(line.due(100.0, Some(1)));
    assert!(!line.due(101.0, Some(2)), "a second later");
    assert!(!line.due(104.9, Some(3)), "under five seconds");
    assert!(line.due(105.0, Some(3)), "five seconds, moved");
    assert!(!line.due(111.0, Some(3)), "not moved");
    assert!(line.due(112.0, Some(4)));
    // a Timeline lane carries the line where it falls
    let p = Palette::default();
    let e = env(&p);
    let rows = trail::timeline_rows(
        &[Lane {
            id: "a".into(),
            label: "a".into(),
            steps: vec![seg(1, "think", None, 0.0, 10.0)],
        }],
        &e,
        &Cols,
        Zone(0),
        &Window {
            from: 0.0,
            to: 100.0,
        },
        100,
        TrailFilter::All,
        Some(50.0),
        50.0,
    );
    assert!(
        rows[1]
            .props
            .iter()
            .any(|(_, _, n, _)| n == "drgnx-work-now")
    );
    assert!(
        rows[1]
            .stops
            .iter()
            .any(|(_, px)| *px == trail::TRACK_X + 50)
    );
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

/// [D] A pause is the trail's paused step, at the time it began; when it ends (the agent was resumed) a note row
/// `resumed` follows it at the time it ended. A pause still going has no note.
#[test]
fn a_pause_and_its_resume_are_notes_in_the_trail() {
    let p = Palette::default();
    let paused = |id: i64, start: f64, end: Option<f64>| Step {
        class: "paused".into(),
        tool: None,
        detail: Detail::default(),
        end,
        ..step(id, start)
    };
    let s = vec![
        step(1, 1000.0),
        paused(2, 1002.0, Some(1060.0)),
        step(3, 1061.0),
    ];
    let rows = trail::trail_rows(&s, &[], &env(&p), Zone(0));
    let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    assert_eq!(keys, ["step:1", "step:2", "resumed:2", "step:3"]);
    assert!(
        rows[1].text.contains("paused") && rows[1].text.contains("00:16:42"),
        "{}",
        rows[1].text
    );
    assert!(
        rows[2].text.contains("resumed") && rows[2].text.contains("00:17:40"),
        "{}",
        rows[2].text
    );
    let open = trail::trail_rows(&[paused(2, 1002.0, None)], &[], &env(&p), Zone(0));
    assert_eq!(open.len(), 1, "{open:?}");
}

/// [D] One step, two zones: two row texts, each the step's time in its zone.
#[test]
fn timestamps_use_the_env_time_zone() {
    let p = Palette::default();
    // 2026-11-07 09:30:00 UTC
    let s = vec![step(1, 1_794_043_800.0)];
    let utc = trail::trail_rows(&s, &[], &env(&p), Zone::parse("+0000"));
    let ist = trail::trail_rows(&s, &[], &env(&p), Zone::parse("+0530"));
    assert!(utc[0].text.contains("09:30:00 · 2 s"), "{}", utc[0].text);
    assert!(ist[0].text.contains("15:00:00 · 2 s"), "{}", ist[0].text);
    assert_eq!(Zone::parse("-0800").time(1_794_043_800.0), "01:30:00");
    assert_eq!(Zone::parse("IST"), Zone(0), "a name is no offset");
}

/// [D] The trail is the mockup's tile (work-space-dark.html): rows in the UI font, each step's kind a Lucide icon in an
/// image of its own, its time and duration muted in the code font, and a conclusion's card in the accent ring (the
/// selected card's faces) with a lightbulb.
#[test]
fn trail_rows_are_ui_text_with_lucide_icons_and_a_finding_card() {
    let p = Palette(vec![("chip-fg".into(), "#a2a5b2".into())]);
    let steps = vec![step(1, 1000.0)];
    let (rows, images) =
        trail::trail_rows_with_images(&steps, &[conclusion(1, 1, &[1])], &env(&p), Zone(0), None);
    fn faces(r: &Row) -> Vec<&str> {
        r.runs.iter().map(|x| x.2.as_str()).collect()
    }
    let s = rows.iter().find(|r| r.key == "step:1").expect("the step");
    assert_eq!(s.images.len(), 1, "{s:?}");
    assert!(faces(s).contains(&FaceId::WorkPane.name()), "{s:?}");
    assert!(faces(s).contains(&FaceId::WorkMeta.name()), "{s:?}");
    let svg_of = |r: &Row| {
        images
            .iter()
            .find(|(id, _)| *id == r.images[0].1)
            .map(|(_, s)| s.clone())
            .expect("its image")
    };
    assert!(svg_of(s).contains("stroke=\"#a2a5b2\""), "{}", svg_of(s));
    let top = rows.iter().find(|r| r.key == "conc:1:0").expect("the card");
    let bottom = rows.iter().find(|r| r.key == "conc:1:1").expect("the card");
    assert!(faces(top).contains(&FaceId::CardSelTop.name()), "{top:?}");
    assert!(
        faces(bottom).contains(&FaceId::CardSelBottom.name()),
        "{bottom:?}"
    );
    assert_eq!(top.images.len(), 1, "{top:?}");
    assert!(top.text.contains("Finding"), "{:?}", top.text);
}

/// [D] A conclusion's card runs to the tile's right edge (a stop with the card's face at its end), as the mockup's
/// Finding card does, not just as far as its text.
#[test]
fn a_conclusion_card_runs_to_the_right_edge() {
    let p = Palette::default();
    let steps = vec![step(1, 1000.0)];
    let rows = trail::trail_rows(&steps, &[conclusion(1, 1, &[1])], &env(&p), Zone(0));
    for key in ["conc:1:0", "conc:1:1"] {
        let r = rows.iter().find(|r| r.key == key).expect(key);
        let (pos, px) = *r.stops.last().expect("a stop at the card's right edge");
        assert_eq!(
            usize::try_from(pos).unwrap() + 1,
            r.text.chars().count(),
            "{r:?}"
        );
        assert!(px >= 900, "{px}");
        assert!(
            r.runs
                .iter()
                .any(|(s, e, f)| *s == 0 && *e > pos && f.starts_with("drgnx-card-sel-")),
            "{r:?}"
        );
    }
}

/// [D] A step that a conclusion rests on starts with the conclusion's number in a circle, the others with the same room
/// empty; the newest conclusion's card says `new` while it rests on one of the last three steps
/// (work-space-dark.html `.cc .new`).
#[test]
fn numbered_circles_and_the_new_tag() {
    let p = Palette::default();
    let steps: Vec<Step> = (1..=6).map(|i| step(i, 1000.0 + 10.0 * i as f64)).collect();
    let concs = vec![conclusion(1, 2, &[2]), conclusion(2, 5, &[4, 5])];
    let rows = trail::trail_rows(&steps, &concs, &env(&p), Zone(0));
    let row = |k: &str| rows.iter().find(|r| r.key == k).expect(k);
    let badged = |r: &Row| r.runs.iter().any(|x| x.2 == FaceId::WorkStepNumber.name());
    assert!(badged(row("step:2")) && row("step:2").text.contains(" 1 "));
    assert!(badged(row("step:4")) && row("step:4").text.contains(" 2 "));
    assert!(!badged(row("step:1")) && !badged(row("step:3")));
    // the room is the same, so the icons line up
    let icon_at = |r: &Row| r.images[0].0;
    assert_eq!(icon_at(row("step:1")), icon_at(row("step:2")));
    assert!(
        row("conc:2:0").text.contains(" new "),
        "{:?}",
        row("conc:2:0")
    );
    assert!(
        !row("conc:1:0").text.contains(" new "),
        "{:?}",
        row("conc:1:0")
    );
    // the tag is plain text in the card's ring: a box of its own would break the ring
    assert!(
        row("conc:2:0")
            .runs
            .iter()
            .all(|r| r.2 != FaceId::Chip.name()),
        "{:?}",
        row("conc:2:0")
    );
    // the icons start at one pixel column, whatever the circle before them says
    assert!(!row("step:1").stops.is_empty());
    assert_eq!(
        row("step:1").stops.first().map(|s| s.1),
        row("step:2").stops.first().map(|s| s.1)
    );
}

/// [D] A step's row keeps its verb and its link colour on paths (work-space-dark.html `.trow`): `read PATH` with the
/// path in the accent, `web TITLE — HOST` muted, `thought: TEXT` muted and italic, `edit PATH +P −M` with the change
/// in the added and removed colours, `job PATH · WHERE`; durations have a space (`0.3 s`, `6 s`).
#[test]
fn a_step_row_keeps_its_verb_and_colours_its_paths() {
    let p = Palette::default();
    let mk = |id: i64, class: &str, kind: &str, d: Detail, took: f64| Step {
        id,
        seq: id as u64,
        class: class.into(),
        tool: None,
        detail: Detail {
            kind: Some(kind.into()),
            ..d
        },
        start: 1000.0 + id as f64,
        end: Some(1000.0 + id as f64 + took),
    };
    let steps = vec![
        mk(
            1,
            "tool",
            "read",
            Detail {
                path: Some("a/b.rs".into()),
                line_start: Some(1),
                line_end: Some(9),
                ..Detail::default()
            },
            0.3,
        ),
        mk(
            2,
            "tool",
            "fetch",
            Detail {
                url: Some("https://x.org/p".into()),
                title: Some("Spec".into()),
                ..Detail::default()
            },
            1.8,
        ),
        mk(
            3,
            "think",
            "",
            Detail {
                title: Some("the end handler…".into()),
                ..Detail::default()
            },
            6.0,
        ),
        mk(
            4,
            "tool",
            "edit",
            Detail {
                path: Some("s.rs".into()),
                title: Some("+40 −3".into()),
                ..Detail::default()
            },
            2.0,
        ),
        mk(
            5,
            "job-wait",
            "",
            Detail {
                path: Some("bin/t".into()),
                title: Some("desktop slot 3 · running".into()),
                ..Detail::default()
            },
            3.0,
        ),
    ];
    let rows = trail::trail_rows(&steps, &[], &env(&p), Zone(0));
    let face_of = |r: &Row, word: &str| {
        let at = r
            .text
            .find(word)
            .unwrap_or_else(|| panic!("{word} in {r:?}"));
        let at = r.text[..at].chars().count() as u32;
        r.runs
            .iter()
            .filter(|x| x.0 <= at && at < x.1)
            .map(|x| x.2.clone())
            .collect::<Vec<_>>()
    };
    assert!(rows[0].text.contains(" read a/b.rs:1–9"), "{:?}", rows[0]);
    assert!(face_of(&rows[0], "a/b.rs").contains(&FaceId::Accent.name().to_owned()));
    assert!(rows[0].text.contains("0.3 s"), "{:?}", rows[0]);
    assert!(rows[1].text.contains(" web Spec — x.org"), "{:?}", rows[1]);
    assert!(face_of(&rows[1], "Spec").contains(&FaceId::TextMuted.name().to_owned()));
    assert!(
        rows[2].text.contains(" thought: the end handler…"),
        "{:?}",
        rows[2]
    );
    assert!(face_of(&rows[2], "thought").contains(&FaceId::WorkThought.name().to_owned()));
    assert!(rows[2].text.contains("6 s"), "{:?}", rows[2]);
    assert!(rows[3].text.contains(" edit s.rs +40 −3"), "{:?}", rows[3]);
    assert!(face_of(&rows[3], "+40").contains(&FaceId::WorkPlus.name().to_owned()));
    assert!(face_of(&rows[3], "−3").contains(&FaceId::WorkMinus.name().to_owned()));
    assert!(
        rows[4]
            .text
            .contains(" job bin/t · desktop slot 3 · running"),
        "{:?}",
        rows[4]
    );
    assert!(face_of(&rows[4], "bin/t").contains(&FaceId::Accent.name().to_owned()));
}

/// [D] A finding's card keeps its keys line (`l light them · ↵ sources`) and its number is the filled circle.
#[test]
fn a_finding_card_keeps_its_keys_and_a_filled_number() {
    let p = Palette::default();
    let rows = trail::trail_rows(
        &[step(1, 1000.0)],
        &[conclusion(1, 1, &[1])],
        &env(&p),
        Zone(0),
    );
    let top = rows.iter().find(|r| r.key == "conc:1:0").expect("the card");
    assert!(
        top.runs.iter().any(|r| r.2 == FaceId::KitChipAccentSolid.name()),
        "{top:?}"
    );
    let sub = rows
        .iter()
        .find(|r| r.key == "conc:1:1")
        .expect("its keys line");
    assert!(
        sub.text
            .contains("based on 1 step ·  l  light them · ↵ sources"),
        "{sub:?}"
    );
    assert!(
        sub.runs.iter().any(|r| r.2 == FaceId::KitChipNeutralSoft.name()),
        "{sub:?}"
    );
}

/// [D] A step still open shows how long it has run (`32 s…`, work-space-dark.html), from the clock it is given; a closed
/// one shows its duration; with no clock an open step shows its time alone.
#[test]
fn an_open_step_shows_its_elapsed_seconds() {
    let p = Palette::default();
    let mut open = step(1, 1000.0);
    open.end = None;
    let (rows, _) =
        trail::trail_rows_with_images(&[open.clone()], &[], &env(&p), Zone(0), Some(1032.4));
    assert!(rows[0].text.contains("· 32 s…"), "{:?}", rows[0]);
    let (rows, _) = trail::trail_rows_with_images(&[open], &[], &env(&p), Zone(0), None);
    assert!(!rows[0].text.contains('…'), "{:?}", rows[0]);
    let (rows, _) =
        trail::trail_rows_with_images(&[step(2, 1000.0)], &[], &env(&p), Zone(0), Some(1500.0));
    assert!(rows[0].text.contains("· 2 s"), "{:?}", rows[0]);
}
