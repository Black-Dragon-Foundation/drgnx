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

#[test]
fn missing_glyph_asks_once_per_font_char() {
    let s = set(13.0);
    // Inter has no Devanagari
    let _ = fit::fit(&s, "ui", "ab कख", 400.0);
    let _ = fit::fit(&s, "ui", "कख क", 400.0);
    let asks = s.take_asks();
    assert_eq!(asks, vec![("ui".to_owned(), 'क'), ("ui".to_owned(), 'ख')]);
    assert!(s.take_asks().is_empty());
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
