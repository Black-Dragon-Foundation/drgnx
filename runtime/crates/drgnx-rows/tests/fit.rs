//! The fitter on the fixture fonts (test/fixtures/fonts: Inter, JetBrains Mono, Vazirmatn's variable `wght`).

use drgnx_rows::fit::{self, ELLIPSIS, Font, FontSet, Measure, SLACK};
use drgnx_rows::fit_tty;
use std::path::PathBuf;
use std::sync::Arc;

fn fixture(name: &str) -> Arc<Vec<u8>> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/fixtures/fonts")
        .join(name);
    Arc::new(std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display())))
}

fn inter(px: f32) -> Font {
    Font::new(fixture("Inter-Regular.ttf"), 0, px, &[]).unwrap()
}

fn set(px: f32) -> FontSet {
    let mut s = FontSet::new();
    s.set_role("ui", Some(inter(px)), 7.0);
    s.set_role(
        "code",
        Some(Font::new(fixture("JetBrainsMono-Regular.otf"), 0, px, &[]).unwrap()),
        7.0,
    );
    s
}

const LABELS: [&str; 4] = [
    "Implement the render offload's row format",
    "fix: 3 flaky tests (#4711), part 2/5",
    "a",
    "WWWWWWWWWWiiiiiiiiii..........,,,,,,,,,,",
];

/// Writes skrifa's sums for the fixture strings (fractional and rounded per glyph) to
/// test/fixtures/rows-fit-sums.eld, which the GUI row compares with Emacs's `string-pixel-width`.
#[test]
fn fit_sums() {
    let strings = [
        "The quick brown fox jumps over the lazy d",
        "0123456789 0123456789 0123456789 0123456",
        "(a, b); [c: d] {e - f} 'g' \"h\" i/j k_l m.",
        "Implement the render offload's row format",
        "fix: 3 flaky tests (#4711), part 2/5 done",
        "WWWWWWWWWWiiiiiiiiiiMMMMMMMMMMllllllllll",
    ];
    let mut out = String::from(
        ";; skrifa's advance sums per string, written by `cargo test -p drgnx-rows fit_sums` when missing (test/ui/rows-fit-gui-test.el reads it)\n(\n",
    );
    for (family, file) in [
        ("Inter", "Inter-Regular.ttf"),
        ("JetBrains Mono", "JetBrainsMono-Regular.otf"),
    ] {
        for px in 11..=16 {
            let f = Font::new(fixture(file), 0, px as f32, &[]).unwrap();
            for s in strings {
                let adv: Vec<f32> = s.chars().map(|c| f.advance(c).unwrap()).collect();
                let frac: f32 = adv.iter().sum();
                let round: f32 = adv.iter().map(|a| a.round()).sum();
                out.push_str(&format!(
                    " (:family {family:?} :px {px} :text {s:?} :fractional {frac:.3} :per-glyph {round:.0})\n"
                ));
            }
        }
    }
    out.push_str(")\n");
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/rows-fit-sums.eld");
    // written when missing (delete it to write it again: the GUI row then measures the new sums)
    if !path.exists() {
        std::fs::write(&path, &out).unwrap();
    }
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        out,
        "{} is not these sums: delete it to write it again",
        path.display()
    );
}

#[test]
fn fits_within_width_minus_slack() {
    let s = set(13.0);
    for label in LABELS {
        for w in [40.0, 80.0, 120.0, 200.0, 400.0] {
            let f = fit::fit(&s, "ui", label, w);
            assert!(
                fit::width(&s, "ui", &f) <= w - SLACK,
                "{label:?} at {w}: {f:?}"
            );
            if f != label {
                // trimmed: one more char would not have fitted
                let kept = f.chars().count() - 1;
                let more: String = label.chars().take(kept + 1).chain([ELLIPSIS]).collect();
                assert!(
                    fit::width(&s, "ui", &more) > w - SLACK,
                    "{label:?} at {w}: cut short: {f:?}"
                );
            }
        }
    }
}

#[test]
fn ellipsis_trims() {
    let s = set(13.0);
    let f = fit::fit(&s, "ui", LABELS[0], 100.0);
    assert!(f.ends_with(ELLIPSIS), "{f:?}");
    assert!(LABELS[0].starts_with(f.trim_end_matches(ELLIPSIS)));
    assert_eq!(fit::fit(&s, "ui", "a", 100.0), "a");
}

/// A TrueType collection of FONTS, built in the test: the header, then each font's table directory with its
/// offsets moved to where its tables are copied.
fn ttc(fonts: &[&[u8]]) -> Vec<u8> {
    let be16 = |b: &[u8], at: usize| u16::from_be_bytes([b[at], b[at + 1]]) as usize;
    let be32 =
        |b: &[u8], at: usize| u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]) as usize;
    let head = 12 + 4 * fonts.len();
    let dirs: Vec<usize> = fonts.iter().map(|f| 12 + 16 * be16(f, 4)).collect();
    let mut out = Vec::new();
    out.extend_from_slice(b"ttcf");
    out.extend_from_slice(&0x0001_0000u32.to_be_bytes());
    out.extend_from_slice(&(fonts.len() as u32).to_be_bytes());
    let mut at = head;
    for d in &dirs {
        out.extend_from_slice(&(at as u32).to_be_bytes());
        at += d;
    }
    // the tables go after every directory
    let mut data_at = at;
    let mut data = Vec::new();
    for (f, d) in fonts.iter().zip(&dirs) {
        let mut dir = f[..*d].to_vec();
        for t in 0..be16(f, 4) {
            let rec = 12 + 16 * t;
            let (off, len) = (be32(f, rec + 8), be32(f, rec + 12));
            dir[rec + 8..rec + 12].copy_from_slice(&((data_at + data.len()) as u32).to_be_bytes());
            data.extend_from_slice(&f[off..off + len]);
            while data.len() % 4 != 0 {
                data.push(0);
            }
        }
        out.extend_from_slice(&dir);
    }
    data_at = out.len();
    let _ = data_at;
    out.extend_from_slice(&data);
    out
}

#[test]
fn ttc_index_selects_face() {
    let both = Arc::new(ttc(&[
        &fixture("Inter-Regular.ttf"),
        &fixture("JetBrainsMono-Regular.otf"),
    ]));
    let a = Font::new(both.clone(), 0, 13.0, &[]).unwrap();
    let b = Font::new(both, 1, 13.0, &[]).unwrap();
    // Inter is proportional, JetBrains Mono is not
    assert_ne!(a.advance('i'), a.advance('W'));
    assert_eq!(b.advance('i'), b.advance('W'));
    assert_eq!(a.advance('W'), inter(13.0).advance('W'));
}

#[test]
fn wght_location_changes_advances() {
    let data = fixture("Vazirmatn-wght.ttf");
    let thin = Font::new(data.clone(), 0, 16.0, &[("wght", 100.0)]).unwrap();
    let black = Font::new(data, 0, 16.0, &[("wght", 900.0)]).unwrap();
    let (t, b) = (thin.advance('a').unwrap(), black.advance('a').unwrap());
    assert!(b > t, "wght 900 {b} is not wider than 100 {t}");
}

/// [D] Every char is asked of the editor once per (role, char), those the font has too: the editor's advance is the
/// one it draws (hinted), and it wins over the file's.
#[test]
fn every_glyph_asks_once_per_font_char() {
    let s = set(13.0);
    // Inter has no Devanagari
    let _ = fit::fit(&s, "ui", "ab कख", 400.0);
    let _ = fit::fit(&s, "ui", "कख क", 400.0);
    let asks = s.take_asks();
    assert_eq!(
        asks,
        ['a', 'b', ' ', 'क', 'ख']
            .iter()
            .map(|c| ("ui".to_owned(), *c))
            .collect::<Vec<_>>()
    );
    assert!(s.take_asks().is_empty());
    // the editor draws `a` a pixel wider than the file says: its advance wins
    let file = s.advance("ui", 'a').unwrap();
    s.glyphs(&[("ui".into(), 'a', file + 1.0)]);
    assert_eq!(s.advance("ui", 'a'), Some(file + 1.0));
    // answered: the editor's advance is used, nothing is asked again
    s.glyphs(&[("ui".into(), 'क', 11.0), ("ui".into(), 'ख', 12.0)]);
    assert_eq!(s.advance("ui", 'क'), Some(11.0));
    let _ = fit::fit(&s, "ui", "कख", 400.0);
    assert!(s.take_asks().is_empty());
}

#[test]
fn measured_width_cache_wins() {
    let s = set(13.0);
    let text = LABELS[0];
    let sum = fit::width(&s, "ui", text);
    s.measured("ui", text, sum + 50.0);
    assert_eq!(fit::width(&s, "ui", text), sum + 50.0);
    // the measurement makes it overflow a width the sum fitted
    let w = sum + SLACK + 10.0;
    assert_ne!(fit::fit(&s, "ui", text, w), text);
    // bounded: the oldest goes first
    for i in 0..fit::MEASURED_MAX {
        s.measured("ui", &format!("s{i}"), 1.0);
    }
    assert_eq!(fit::width(&s, "ui", text), sum);
}

#[test]
fn no_font_file_measures_through_the_editor() {
    let mut s = FontSet::new();
    s.set_role("ui", None, 7.0);
    assert_eq!(s.advance("ui", 'a'), None);
    assert_eq!(s.take_asks(), vec![("ui".to_owned(), 'a')]);
    s.glyphs(&[("ui".into(), 'a', 6.0)]);
    assert_eq!(fit::width(&s, "ui", "aa"), 12.0);
}

/// A grapheme cluster is as wide as its first char, and a cut never splits one: with no font file (macOS) the editor
/// answers each char alone, where a lone combining mark, a ZWJ and the emoji it joins each have a width the drawn
/// cluster does not.
#[test]
fn a_cluster_is_as_wide_as_its_first_char() {
    let mut s = FontSet::new();
    s.set_role("ui", None, 7.0);
    s.glyphs(&[
        ("ui".into(), 'e', 6.0),
        ("ui".into(), '\u{301}', 5.0),
        ("ui".into(), '\u{1F469}', 14.0),
        ("ui".into(), '\u{200D}', 3.0),
        ("ui".into(), '\u{1F4BB}', 14.0),
        ("ui".into(), ELLIPSIS, 6.0),
    ]);
    assert_eq!(fit::width(&s, "ui", "e\u{301}e"), 12.0);
    assert_eq!(
        fit::width(&s, "ui", "\u{1F469}\u{200D}\u{1F4BB} e"),
        14.0 + 7.0 + 6.0
    );
    // four clusters (24 px) in 28 px: the budget 18 less the ellipsis leaves room for two whole ones
    assert_eq!(
        fit::fit(&s, "ui", "e\u{301}e\u{301}e\u{301}e\u{301}", 28.0),
        "e\u{301}e\u{301}…"
    );
}

#[test]
fn tty_uses_emacs_width_table() {
    // unicode-width: 'a' 1, '漢' 2; Emacs's table makes '→' (U+2192, ambiguous) 2 and '漢' 1
    let table = [(0x2192, 0x2192, 2u8), (0x6f22, 0x6f22, 1u8)];
    assert_eq!(fit_tty::width("a→漢漢", &[]), 6);
    assert_eq!(fit_tty::width("a→漢漢", &table), 5);
    assert_eq!(fit_tty::fit("abcdef", 4, &[]), "abc…");
    assert_eq!(fit_tty::fit("漢漢漢", 4, &[]), "漢…");
    assert_eq!(fit_tty::fit("漢漢漢", 4, &table), "漢漢漢");
}

/// A set whose `ui` chars are all 10 px (no font file: the average), with the face `big` drawn in a font of its own
/// whose chars are 20 px, and `boxed` in `ui` with a 3 px box at each end.
fn tens() -> FontSet {
    let mut s = FontSet::new();
    s.set_role("ui", None, 10.0);
    s.face_answer(
        "big",
        fit::Ink {
            role: "big".into(),
            pad: 0.0,
        },
        Some((None, 20.0)),
    );
    s.face_answer(
        "boxed",
        fit::Ink {
            role: "ui".into(),
            pad: 3.0,
        },
        None,
    );
    s
}

fn fitted(row: &mut drgnx_rows::Row, width_px: u32, m: &dyn Measure) -> bool {
    let none = |_: &drgnx_rows::ImageId| None;
    drgnx_rows::fit_row::fit_row(
        row,
        m,
        &drgnx_rows::fit_row::Room {
            width_px,
            tty: None,
            image_px: &none,
            tail: None,
        },
    )
}

#[test]
fn a_row_wider_than_its_window_is_cut_at_its_edge() {
    let s = tens();
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push("abcdefghij", None);
    let mut row = b.finish();
    // 100 px in 80: cut to 70 less the ellipsis (10): six chars
    assert!(fitted(&mut row, 80, &s));
    assert_eq!(row.text, "abcdef…");
    let mut same = row.clone();
    assert!(!fitted(&mut same, 80, &s), "a fitted row is not cut again");
}

#[test]
fn each_run_is_measured_in_the_font_its_face_draws_in() {
    let s = tens();
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push("ab", None).push("cd", Some("big"));
    let mut row = b.finish();
    // 20 + 40 px fits 60, and the row says `big`'s text is measured in its own role
    assert!(!fitted(&mut row, 60, &s));
    assert_eq!(row.fonts, vec![(2, 4, "big".to_owned())]);
    // in 50 px: 40 px of room less the ellipsis in `big` (20): `ab` and one `c`? no, 20 + 20 + 20 > 40: `ab…`
    assert!(fitted(&mut row, 50, &s));
    assert_eq!(row.text, "ab…");
    assert_eq!(row.runs, vec![]);
    // a box's ends count
    let mut b = drgnx_rows::RowBuilder::new("k");
    b.push("abcd", Some("boxed"));
    let mut row = b.finish();
    assert!(
        fitted(&mut row, 45, &s),
        "40 px of text and 6 of box run past 45"
    );
}

#[test]
fn a_segment_is_cut_at_the_stop_after_it() {
    let s = tens();
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push("abcdefgh", Some("x")).stop(60).push("12", None);
    let mut row = b.finish();
    // 80 px before a stop at 60: cut to 50 less the ellipsis, the stop and the text after it kept and moved
    assert!(fitted(&mut row, 200, &s));
    assert_eq!(row.text, "abcd… 12");
    assert_eq!(row.stops, vec![(5, 60)]);
    assert_eq!(row.runs, vec![(0, 5, "x".to_owned())]);
    // the text after the last stop is cut at the window's edge
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push("ab", None).stop(60).push("123456", None);
    let mut row = b.finish();
    assert!(fitted(&mut row, 100, &s));
    assert_eq!(row.text, "ab 12…");
}

/// [D] A sum that comes within the slack of the window's edge may be off by more than what is left (no shaping,
/// kerning or hinting): the editor is asked to measure that segment as drawn, once, and its width decides from then
/// on (a row it measured wider is cut).
#[test]
fn a_segment_too_close_to_its_end_is_measured_by_the_editor() {
    let s = tens();
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push("ab", Some("big")).push("cdef", None);
    let row = b.finish();
    // 40 + 40 = 80 px in 85: within the slack of the edge, kept whole, and asked
    let mut near = row.clone();
    assert!(!fitted(&mut near, 85, &s));
    assert_eq!(near.text, "abcdef");
    let asks = s.take_measure_asks();
    assert_eq!(
        asks,
        vec![(
            "big+ui".to_owned(),
            "abcdef".to_owned(),
            vec![(0, 2, "big".to_owned())]
        )]
    );
    // asked once
    assert!(!fitted(&mut row.clone(), 85, &s));
    assert!(s.take_measure_asks().is_empty());
    // far from the edge: not asked
    let mut far = row.clone();
    b = drgnx_rows::RowBuilder::new("r2");
    b.push("ab", None);
    let short = b.finish();
    assert!(!fitted(&mut short.clone(), 85, &s));
    assert!(s.take_measure_asks().is_empty());
    // the editor drew it 88 px wide: now it is cut
    s.measured("big+ui", "abcdef", 88.0);
    assert!(fitted(&mut far, 85, &s));
    assert!(far.text.ends_with('…'), "{}", far.text);
}

/// [D] The editor measures a segment's text without its images' and spaces' placeholders (their widths are known): a
/// row's strut stays out of what it is asked, and its width is added to what it answers.
#[test]
fn a_segment_is_asked_without_its_placeholders() {
    let s = tens();
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.space(5, 30, "strut")
        .push("abc", Some("big"))
        .push("de", None);
    let mut row = b.finish();
    // 5 + 60 + 20 = 85 px in 90: asked, the strut left out and the runs moved past it
    assert!(!fitted(&mut row, 90, &s));
    let asks = s.take_measure_asks();
    assert_eq!(asks.len(), 1, "{asks:?}");
    assert_eq!(asks[0].1, "abcde");
    assert!(asks[0].2.contains(&(0, 3, "big".to_owned())), "{asks:?}");
    // the editor drew the text 86 px wide: with the strut, 91 > 90, so the row is cut
    s.measured(&asks[0].0, "abcde", 86.0);
    assert!(fitted(&mut row, 90, &s));
    assert!(row.text.ends_with('…'), "{}", row.text);
}

/// [D] A cluster of several chars (here a ZWJ sequence the font does not join) is measured by the editor in the faces
/// over it, and its width then counts in the row's sum: the row is cut where the drawn text reaches its edge, not past
/// it.
#[test]
fn a_joined_cluster_is_measured_by_the_editor() {
    let s = tens();
    let zwj = "\u{1F469}\u{200D}\u{1F4BB}";
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push(&format!("ab{zwj}cdefg"), None);
    let mut row = b.finish();
    // the sum (8 clusters, 80 px) fits 95 px: the cluster is asked, alone, in the row's faces
    assert!(!fitted(&mut row, 95, &s));
    let asks = s.take_measure_asks();
    assert!(asks.iter().any(|a| a.1 == zwj), "{asks:?}");
    // the editor drew it as three emoji, 30 px: 100 px of text in 95, so the row is cut before its end
    s.measured("ui", zwj, 30.0);
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push(&format!("ab{zwj}cdefg"), None);
    let mut row = b.finish();
    assert!(fitted(&mut row, 95, &s));
    assert!(row.text.ends_with('…'), "{}", row.text);
}

/// [D] A text no wider than the ellipsis is never cut to it: the cut would draw no narrower and lose the text (a
/// debug value `8` drawn as `…` in a narrow Locals row).
#[test]
fn a_text_no_wider_than_the_ellipsis_stays_whole() {
    let s = set(14.0);
    let ell = fit::width(&s, "code", &ELLIPSIS.to_string());
    assert!(fit::width(&s, "code", "8") <= ell);
    assert_eq!(fit::fit(&s, "code", "8", SLACK + ell / 2.0), "8");
    // wider than the ellipsis: cut as before
    assert_eq!(fit::fit(&s, "code", "88", SLACK + ell / 2.0), "…");
}

fn fitted_with_tail(
    row: &mut drgnx_rows::Row,
    width_px: u32,
    tail: (u32, u32),
    m: &dyn Measure,
) -> bool {
    let none = |_: &drgnx_rows::ImageId| None;
    drgnx_rows::fit_row::fit_row(
        row,
        m,
        &drgnx_rows::fit_row::Room {
            width_px,
            tty: None,
            image_px: &none,
            tail: Some(tail),
        },
    )
}

fn tail_row(text: &str, tail: drgnx_rows::Tail) -> drgnx_rows::Row {
    let mut b = drgnx_rows::RowBuilder::new("r");
    b.push(text, None).tail(tail);
    b.finish()
}

fn short(row: &drgnx_rows::Row) -> bool {
    row.props.iter().any(|p| p.2 == drgnx_rows::fit_row::SHORT)
}

#[test]
fn a_row_ends_short_of_what_its_tail_always_draws() {
    let s = tens();
    // the tail's mark starts 35 px from the edge, its control 24: in 120 px, 100 px of text
    // a clean row (the ⋯ on hover only) is cut at the full width, and says its text reaches the control's place
    let mut clean = tail_row("abcdefghij", drgnx_rows::Tail::Hover);
    assert!(
        !fitted_with_tail(&mut clean, 120, (35, 24), &s),
        "a clean row keeps its whole text: {}",
        clean.text
    );
    assert!(short(&clean), "its text reaches the ⋯'s place");
    // a row with a git mark ends short of the mark: 85 px less the ellipsis (and the slack)
    let mut marked = tail_row("abcdefghij", drgnx_rows::Tail::Mark);
    assert!(fitted_with_tail(&mut marked, 120, (35, 24), &s));
    assert!(
        marked.text.ends_with('…') && marked.text.chars().count() * 10 <= 85,
        "{}",
        marked.text
    );
    assert!(!short(&marked));
    // a control drawn always (a buffer's unsaved ●): short of the control
    let mut control = tail_row("abcdefghij", drgnx_rows::Tail::Control);
    assert!(fitted_with_tail(&mut control, 120, (35, 24), &s));
    assert!(control.text.chars().count() * 10 <= 96, "{}", control.text);
    // a short clean row leaves the ⋯ its place
    let mut room = tail_row("abc", drgnx_rows::Tail::Hover);
    assert!(!fitted_with_tail(&mut room, 120, (35, 24), &s));
    assert!(!short(&room));
}

/// [D] What the editor draws between a row's text and its tail (the Explorer's who-is-here badge, `keep`) counts as
/// text: the text ends that much shorter, and a clean row whose text and badge reach the ⋯'s place is short.
#[test]
fn a_row_keeps_room_for_its_badge() {
    let s = tens();
    // a marked row with a 20 px badge: text and badge end short of the mark (85 px), so 65 px of text at most
    let mut marked = tail_row("abcdefghij", drgnx_rows::Tail::Mark);
    marked.keep = 20;
    assert!(fitted_with_tail(&mut marked, 120, (35, 24), &s));
    assert!(
        marked.text.ends_with('…') && marked.text.chars().count() * 10 <= 65,
        "{}",
        marked.text
    );
    // a clean row of 80 px fits, but with its 20 px badge reaches the ⋯'s place (96 px)
    let mut clean = tail_row("abcdefgh", drgnx_rows::Tail::Hover);
    clean.keep = 20;
    assert!(!fitted_with_tail(&mut clean, 120, (35, 24), &s));
    assert!(short(&clean), "text and badge reach the ⋯'s place");
    // past the body with its badge: cut, so text and badge end inside it
    let mut long = tail_row("abcdefghijk", drgnx_rows::Tail::Hover);
    long.keep = 20;
    assert!(fitted_with_tail(&mut long, 120, (35, 24), &s));
    assert!(long.text.chars().count() * 10 <= 100, "{}", long.text);
}
