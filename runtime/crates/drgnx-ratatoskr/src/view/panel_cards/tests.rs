use super::*;
use drgnx_rows::faces::FaceId;
use runstav::methods::view::Display;

fn env(width: u32) -> ViewEnv {
    ViewEnv {
        view: "agent-panel/s1".into(),
        class: "gui-1".into(),
        epoch: 1,
        display: Display::Gui,
        scale: 1.0,
        fonts: vec![],
        cell: (8, 16),
        width_px: width,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
        rows_in_sja: false,
        headless: false,
    }
}

fn input<'a>(e: &'a ViewEnv) -> In<'a> {
    In {
        env: e,
        pins: &[],
        plan: None,
        files: &[],
        paired: &[],
        edits: &[],
        ledger_open: false,
        ledger_mark: None,
    }
}

fn shapes(rows: &[Row]) -> Vec<String> {
    rows.iter()
        .map(|r| {
            r.runs
                .iter()
                .find(|(_, _, f)| f.starts_with("drgnx-card-"))
                .map(|(_, _, f)| f.clone())
                .unwrap_or_default()
        })
        .collect()
}

// pattern: D
#[test]
fn nothing_pinned_planned_or_edited_is_no_card() {
    let e = env(400);
    assert!(rows(&input(&e)).is_empty());
}

// pattern: D
#[test]
fn a_pin_is_a_single_card_that_names_its_number() {
    let e = env(400);
    let pins = ["Run the tests".to_owned(), "Read the spec".to_owned()];
    let r = rows(&In {
        pins: &pins,
        ..input(&e)
    });
    assert_eq!(
        r.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
        ["p:pin0:0", "p:pin1:0"]
    );
    assert!(
        r[0].text.contains("⚑ Run the tests   (P unpin)"),
        "{:?}",
        r[0].text
    );
    assert_eq!(
        shapes(&r),
        [FaceId::CardSingle.name(), FaceId::CardSingle.name()]
    );
    assert!(
        r[1].props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-agent-panel-pin" && *v == json!(1))
    );
    // the card runs to the panel's right edge, 12 px in
    assert_eq!(r[0].stops.len(), 1);
    assert_eq!(r[0].stops[0].1, 388);
}

// pattern: D
#[test]
fn the_to_do_list_counts_what_is_done() {
    let e = env(400);
    let plan = [
        ("completed".to_owned(), "Read".to_owned()),
        ("in_progress".to_owned(), "Write".to_owned()),
        ("pending".to_owned(), "Test".to_owned()),
    ];
    let r = rows(&In {
        plan: Some(&plan),
        ..input(&e)
    });
    let texts: Vec<&str> = r.iter().map(|r| r.text.trim()).collect();
    assert_eq!(
        texts,
        ["To do · 1 of 3 done", "☑ Read", "◐ Write", "☐ Test"]
    );
    assert_eq!(
        shapes(&r),
        [
            FaceId::CardTop.name(),
            FaceId::CardMid.name(),
            FaceId::CardMid.name(),
            FaceId::CardBottom.name()
        ]
    );
    assert_eq!(r[0].key, "p:todo:0");
}

// pattern: D
#[test]
fn the_ledger_counts_the_edits_since_you_looked_and_lists_on_demand() {
    let e = env(400);
    let files = [
        FileEdit {
            path: "a.el".into(),
            plus: 3,
            minus: 1,
        },
        FileEdit {
            path: "b.el".into(),
            plus: 0,
            minus: 2,
        },
    ];
    let edits = [2, 5, 9];
    let closed = rows(&In {
        files: &files,
        edits: &edits,
        ledger_mark: Some(4),
        ..input(&e)
    });
    assert_eq!(closed.len(), 1);
    assert!(
        closed[0]
            .text
            .contains("Edits · 2 files · 2 new since you looked   (L list)"),
        "{:?}",
        closed[0].text
    );
    assert!(
        closed[0]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::StatusAttention.name())
    );
    assert!(
        closed[0]
            .props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-agent-panel-action" && *v == json!("card:ledger"))
    );
    let open = rows(&In {
        files: &files,
        edits: &edits,
        ledger_open: true,
        ledger_mark: Some(9),
        ..input(&e)
    });
    let texts: Vec<&str> = open.iter().map(|r| r.text.trim()).collect();
    assert_eq!(
        texts,
        ["Edits · 2 files   (L fold)", "a.el  +3 −1", "b.el  +0 −2"]
    );
    assert!(open[0].runs.iter().any(|(_, _, f)| f == "bold"));
}

// pattern: D
#[test]
fn a_paired_chats_ledger_lists_its_hunks_and_what_became_of_them() {
    let e = env(400);
    let h = |index: i64, state: &str, by: Value| -> OpHunk {
        serde_json::from_value(
            json!({"op": 7, "path": "src/x.el", "index": index, "start_line": 3, "end_line": 5,
            "text": "t", "deleted": "", "state": state, "undone_by": by}),
        )
        .expect("a hunk")
    };
    let paired = [
        h(0, "live", json!([])),
        h(1, "undone", json!([{"op": 8, "author": {"kind": "user"}}])),
        h(
            2,
            "partly-undone",
            json!([{"op": 9, "author": {"kind": "agent"}}]),
        ),
    ];
    let r = rows(&In {
        paired: &paired,
        ledger_open: true,
        ..input(&e)
    });
    let texts: Vec<&str> = r.iter().map(|r| r.text.trim()).collect();
    assert_eq!(texts[0], "Edits · 1 file   (L fold)");
    assert_eq!(texts[1], "src/x.el  3–5");
    assert_eq!(texts[2], "src/x.el  3–5  · undone by you");
    assert_eq!(texts[3], "src/x.el  3–5  · partly undone");
    assert!(r[1].props.iter().any(|(_, _, n, v)| n == "drgnx-agent-panel-op-hunk" && *v == json!([7, "src/x.el", 0])));
}
