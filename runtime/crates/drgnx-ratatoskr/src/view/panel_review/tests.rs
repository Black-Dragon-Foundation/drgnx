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
        tail: None,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        glyphs: Vec::new(),
        ascii: false,
        density: Default::default(),
        attach: false,
        rows_in_sja: false,
        headless: false,
    }
}

const DIFF: &str = "--- a/a.el\n+++ b/a.el\n@@ -215,2 +215,3 @@\n-  (when p\n+  (if p\n     (send p)\n+    (queue p)\n@@ -300 +301 @@\n-x\n+y\n";

fn fonts() -> FontSet {
    let mut f = FontSet::new();
    f.set_role("ui", None, 7.0);
    f
}

fn text(r: &Row) -> String {
    r.text.clone()
}

fn action_of(r: &Row, name: &str) -> Vec<String> {
    r.props
        .iter()
        .filter(|(_, _, n, _)| n == "drgnx-agent-panel-action")
        .filter_map(|(_, _, _, v)| v.as_str().map(str::to_owned))
        .filter(|a| a.starts_with(name))
        .collect()
}

// pattern: D
#[test]
fn a_diff_splits_into_its_hunks() {
    let h = parse_hunks(DIFF);
    assert_eq!(h.len(), 2);
    assert_eq!(h[0].header, "@@ -215,2 +215,3 @@");
    assert_eq!(h[0].lines.len(), 4);
    assert_eq!(h[1].lines, ["-x", "+y"]);
}

// pattern: D
#[test]
fn review_diff_is_a_kit_diff_block() {
    // a hunk is the kit's diff block: the head row, the `@@` row and the numbered lines, each in its part's kit face,
    // the card's plain ring over them (top, mid, bottom); Reject and Accept carry the panel's own click props
    let e = env(400);
    let fonts = fonts();
    let diffs = [("a.el".to_owned(), DIFF.to_owned())];
    let (rows, _) = rows(&In {
        env: &e,
        fonts: &fonts,
        diffs: &diffs,
        permissions: &[],
        queue: &[],
    });
    let rows: Vec<Row> = rows.into_iter().filter(|r| r.key != "c:gap").collect();
    let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "c:diff:a.el:0/0",
            "c:diff:a.el:0/h0",
            "c:diff:a.el:0/h0/0",
            "c:diff:a.el:0/h0/1",
            "c:diff:a.el:0/h0/2",
            "c:diff:a.el:0/h0/3",
            "c:diff:a.el:1/0",
            "c:diff:a.el:1/h0",
            "c:diff:a.el:1/h0/0",
            "c:diff:a.el:1/h0/1"
        ]
    );
    let head = text(&rows[0]);
    assert!(head.contains("a.el · hunk 1 of 2"), "{head}");
    assert!(head.contains("+2") && head.contains("\u{2212}1"), "{head}");
    assert_eq!(
        action_of(&rows[0], "card:"),
        ["card:reject:a.el:0", "card:accept:a.el:0"]
    );
    // the removed line has the old number, the added the new: 215 - and 215 +, then the context 216, the add 217
    assert!(text(&rows[2]).contains("215 -   (when p"));
    assert!(text(&rows[3]).contains("215 +   (if p"));
    assert!(text(&rows[4]).contains("216      (send p)"));
    assert!(text(&rows[5]).contains("217 +     (queue p)"));
    let has = |r: &Row, f: FaceId| r.runs.iter().any(|(_, _, g)| g == f.name());
    assert!(has(&rows[0], FaceId::KitDiffBlockHead));
    assert!(has(&rows[1], FaceId::KitDiffBlockHunk));
    assert!(has(&rows[2], FaceId::KitDiffBlockDel));
    assert!(has(&rows[3], FaceId::KitDiffBlockAdd));
    assert!(has(&rows[4], FaceId::KitDiffBlockCtx));
    assert!(has(&rows[0], FaceId::KitCardPlainTop));
    assert!(has(&rows[2], FaceId::KitCardPlainMid));
    assert!(has(&rows[5], FaceId::KitCardPlainBottom));
    assert!(
        rows[2]
            .props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-agent-panel-card" && *v == json!(["diff", "a.el", 0]))
    );
}

// pattern: D
#[test]
fn a_narrow_panel_fits_the_name_before_the_buttons_and_keeps_the_icon() {
    let e = env(180);
    let fonts = fonts();
    let path = "core/a-long-directory/drgnx-gateway.el";
    let diffs = [(path.to_owned(), DIFF.to_owned())];
    let (rows, images) = rows(&In {
        env: &e,
        fonts: &fonts,
        diffs: &diffs,
        permissions: &[],
        queue: &[],
    });
    let rows: Vec<Row> = rows.into_iter().filter(|r| r.key != "c:gap").collect();
    let head = text(&rows[0]);
    assert!(!head.contains(path), "{head}");
    assert!(head.contains("Reject") && head.contains("Accept"), "{head}");
    // the file's icon is drawn as an image whose SVG goes with the rows
    assert_eq!(rows[0].images.len(), 1);
    assert!(images.iter().any(|(id, _)| *id == rows[0].images[0].1));
}

// pattern: D
#[test]
fn a_request_is_a_ringed_line_over_allow_always_and_deny() {
    let e = env(400);
    let fonts = fonts();
    let p = [Permission {
        id: Some(RpcId::Int(7)),
        title: Some("Read the gateway's log".into()),
        tool: None,
        options: vec![],
    }];
    let (rows, _) = rows(&In {
        env: &e,
        fonts: &fonts,
        diffs: &[],
        permissions: &p,
        queue: &[],
    });
    let rows: Vec<Row> = rows.into_iter().filter(|r| r.key != "c:gap").collect();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].key, "c:perm:7:0");
    assert!(text(&rows[0]).contains("Read the gateway's log?"));
    assert!(
        rows[0]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::AgentPanelPermHead.name())
    );
    assert_eq!(
        action_of(&rows[1], "card:"),
        ["card:allow:7", "card:always:7", "card:deny:7"]
    );
    assert!(text(&rows[1]).contains("Allow"));
    // the key hints are in the buttons' help, not jammed onto their labels (audit A3)
    for hint in ["Allow ↵", "Always A", "Deny D"] {
        assert!(!text(&rows[1]).contains(hint), "{hint}");
    }
}

// pattern: D
#[test]
fn a_queued_note_is_a_row_that_names_its_number() {
    let e = env(400);
    let fonts = fonts();
    let q = ["first".to_owned(), "second".to_owned()];
    let (rows, _) = rows(&In {
        env: &e,
        fonts: &fonts,
        diffs: &[],
        permissions: &[],
        queue: &q,
    });
    let rows: Vec<Row> = rows.into_iter().filter(|r| r.key != "c:gap").collect();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].key, "c:q:1");
    assert!(text(&rows[1]).contains("queued 2  second"));
    assert!(
        rows[1]
            .props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-agent-panel-queued" && *v == json!(1))
    );
}
