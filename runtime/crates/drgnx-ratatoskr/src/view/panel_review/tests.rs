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
fn a_hunk_is_a_header_over_numbered_lines_in_card_faces() {
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
            "c:diff:a.el:0:h",
            "c:diff:a.el:0:0",
            "c:diff:a.el:0:1",
            "c:diff:a.el:0:2",
            "c:diff:a.el:0:3",
            "c:diff:a.el:1:h",
            "c:diff:a.el:1:0",
            "c:diff:a.el:1:1"
        ]
    );
    let head = text(&rows[0]);
    assert!(head.contains("a.el"), "{head}");
    assert!(head.contains("215–217 · hunk 1 of 2"), "{head}");
    assert_eq!(
        action_of(&rows[0], "card:"),
        ["card:reject:a.el:0", "card:accept:a.el:0"]
    );
    // the removed line has the old number, the added the new: 215 - and 215 +, then the context 216, the add 217
    assert!(text(&rows[1]).contains("215 -  (when p"));
    assert!(text(&rows[2]).contains("215 +  (if p"));
    assert!(text(&rows[3]).contains("216      (send p)"));
    assert!(text(&rows[4]).contains("217 +    (queue p)"));
    let shape = |r: &Row| {
        r.runs
            .iter()
            .find(|(_, _, f)| f.starts_with("drgnx-card-"))
            .map(|(_, _, f)| f.clone())
            .unwrap_or_default()
    };
    assert_eq!(shape(&rows[1]), FaceId::CardTop.name());
    assert_eq!(shape(&rows[3]), FaceId::CardMid.name());
    assert_eq!(shape(&rows[4]), FaceId::CardBottom.name());
    assert!(
        rows[1]
            .runs
            .iter()
            .any(|(_, _, f)| f == FaceId::AgentPanelRemoved.name())
    );
    assert!(
        rows[1]
            .props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-agent-panel-card" && *v == json!(["diff", "a.el", 0]))
    );
}

// pattern: D
#[test]
fn a_request_is_a_needs_you_question_card_answered_with_y_a_n() {
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
    // the kit's question card (`kit::expand_rows`): its rows are `c:perm:7/N`, the head names the request
    assert!(!rows.is_empty());
    assert!(
        rows.iter().all(|r| r.key.starts_with("c:perm:7/")),
        "{:?}",
        rows.iter().map(|r| r.key.clone()).collect::<Vec<_>>()
    );
    assert!(
        text(&rows[0]).contains("Read the gateway's log?"),
        "{}",
        text(&rows[0])
    );
    // each choice is a button of the kit's action kind `agent-panel-card`: [kind, verb, id]
    let actions: Vec<Value> = rows
        .iter()
        .flat_map(|r| r.props.iter())
        .filter(|(_, _, n, _)| n == "drgnx-action")
        .map(|(_, _, _, v)| v.clone())
        .collect();
    assert_eq!(
        actions,
        [
            json!(["agent-panel-card", "allow", "7"]),
            json!(["agent-panel-card", "always", "7"]),
            json!(["agent-panel-card", "deny", "7"]),
        ]
    );
    // the card's rows still name the request (the panel's commands read the card at point), and carry the kit's
    // key hints: y allows, a allows always, n denies
    assert!(rows.iter().all(|r| {
        r.props
            .iter()
            .any(|(_, _, n, v)| n == "drgnx-agent-panel-card" && *v == json!(["perm", "7"]))
    }));
    let all: String = rows.iter().map(text).collect::<Vec<_>>().join("\n");
    for hint in ["y", "a", "n"] {
        assert!(all.contains(hint), "{hint}: {all}");
    }
}

// pattern: D
#[test]
fn a_narrow_panel_drops_the_label_before_the_buttons() {
    let e = env(180);
    let fonts = fonts();
    let diffs = [(
        "core/a-long-directory/drgnx-gateway.el".to_owned(),
        DIFF.to_owned(),
    )];
    let (rows, _) = rows(&In {
        env: &e,
        fonts: &fonts,
        diffs: &diffs,
        permissions: &[],
        queue: &[],
    });
    let rows: Vec<Row> = rows.into_iter().filter(|r| r.key != "c:gap").collect();
    let head = text(&rows[0]);
    assert!(!head.contains("hunk 1 of"), "{head}");
    assert!(head.contains("Reject") && head.contains("Accept"));
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
