//! test-pattern: pure (D): the outline's keys, model and rows from a text, no hub.

use super::*;
use runstav::methods::view::{Display, ViewEnv};

const RS: &str = "struct W;\nimpl W {\n    fn size(&self) {}\n}\nfn later() {}\n";

fn env(display: Display, scale: f32) -> ViewEnv {
    ViewEnv {
        view: "outline".into(),
        class: "c".into(),
        epoch: 1,
        display,
        scale,
        fonts: vec![],
        cell: (8, 16),
        width_px: 300,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
        rows_in_sja: false,
    }
}

fn entries(text: &str) -> Vec<OutlineEntry> {
    match shown_of("src/a.rs", text) {
        Shown::Entries(e) => e,
        Shown::Notice(n) => panic!("a notice: {n}"),
    }
}

#[test]
fn a_moved_definition_keeps_its_key() {
    let before = keys(&entries(RS));
    assert_eq!(before, ["0:0:W", "0:1:W", "1:0:size", "0:0:later"]);
    let after = keys(&entries(&format!("// a comment\n\n{RS}")));
    assert_eq!(after, before, "lines moved, keys did not");
}

#[test]
fn the_model_holds_each_definitions_line() {
    let d = doc(&shown_of("src/a.rs", RS));
    assert_eq!(
        d.lists["order"],
        ["0:0:W", "0:1:W", "1:0:size", "0:0:later"]
    );
    assert_eq!(
        d.nodes["1:0:size"]["fields"],
        json!([["label", "size"], ["line", 3]])
    );
    assert_eq!(d.nodes["0:0:later"]["fields"][1], json!(["line", 5]));
    assert!(doc(&Shown::Notice(NONE)).lists["order"].is_empty());
}

#[test]
fn rows_indent_by_the_definitions_around() {
    let look = RowLook::of(&env(Display::Tty, 1.0), INDENT, 1);
    let (built, images) = rows(&shown_of("src/a.rs", RS), &look);
    let text: Vec<&str> = built.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(text, ["  W", "  W", "    size", "  later"]);
    assert!(images.is_empty());
    assert_eq!(
        built[2].props,
        vec![(0, 8, "drgnx-work-id".to_owned(), json!("1:0:size"))]
    );
}

#[test]
fn the_size_guard_is_one_check_at_the_lisp_outlines_limit() {
    assert!(!too_large(OUTLINE_MAX as u64));
    assert!(too_large(OUTLINE_MAX as u64 + 1));
    // a large text with definitions in it is still only the notice: nothing is parsed
    let big = format!("fn kept() {{}}\n{}", "x".repeat(OUTLINE_MAX));
    assert_eq!(shown_of("src/a.rs", &big), Shown::Notice(LARGE));
}

#[test]
fn nothing_to_outline_is_one_notice() {
    assert_eq!(shown_of("notes.txt", "just words\n"), Shown::Notice(NONE));
    assert_eq!(shown_of("src/a.rs", "// nothing\n"), Shown::Notice(NONE));
    let big = "x".repeat(OUTLINE_MAX + 1);
    assert_eq!(shown_of("src/a.rs", &big), Shown::Notice(LARGE));
    let tty = RowLook::of(&env(Display::Tty, 1.0), INDENT, 1);
    let (built, images) = rows(&Shown::Notice(NONE), &tty);
    assert_eq!(built[0].text, format!("  {NONE}"));
    assert!(images.is_empty());
    assert!(built[0].props.iter().any(|p| p.2 == "drgnx-row-inert"));
    let gui = RowLook::of(&env(Display::Gui, 2.0), INDENT, 1);
    let (built, images) = rows(&Shown::Notice(NONE), &gui);
    assert_eq!(
        built[0].text,
        format!("    {NONE}"),
        "the icon's placeholder and a space"
    );
    assert_eq!(images.len(), 1);
    assert_eq!(built[0].images[0].0, 2);
}
