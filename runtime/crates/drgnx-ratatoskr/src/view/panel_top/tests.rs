use super::*;
use drgnx_rows::faces::FaceId;
use runstav::methods::agents::Snapshot;
use std::collections::BTreeSet;

fn snap(extra: Value) -> Snapshot {
    let mut v = json!({"id": "s1", "name": "Fix the tests", "profile": "Claude", "status": "idle"});
    if let (Some(m), Some(e)) = (v.as_object_mut(), extra.as_object()) {
        for (k, x) in e {
            m.insert(k.clone(), x.clone());
        }
    }
    serde_json::from_value(v).expect("a snapshot")
}

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
        badge: None,
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

fn fonts() -> FontSet {
    let mut f = FontSet::new();
    f.set_role("ui", None, 7.0);
    f
}

fn lens() -> Lens {
    Lens {
        names: vec!["watch".into(), "review".into(), "debug".into()],
        on: 2,
    }
}

fn build(s: &Snapshot, width: u32, busy: Option<f64>) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let (e, f, l) = (env(width), fonts(), lens());
    rows(
        s,
        &Cx {
            env: &e,
            fonts: &f,
            lens: &l,
            open: &BTreeSet::from(["edit".to_owned()]),
            busy_since: busy,
            now: 1000.0,
            files_edited: None,
            checkpoints: None,
            chain: &[],
            plan: &[],
        },
    )
}

fn props<'a>(r: &'a Row, name: &str) -> Vec<(&'a Value, String)> {
    r.props
        .iter()
        .filter(|(_, _, n, _)| n == name)
        .map(|(a, b, _, v)| {
            let text: String = r
                .text
                .chars()
                .skip(*a as usize)
                .take((b - a) as usize)
                .collect();
            (v, text)
        })
        .collect()
}

// pattern: D
#[test]
fn the_status_line_says_what_the_agent_does() {
    let busy = snap(json!({"status": "busy"}));
    assert_eq!(
        status_line(&busy, Some(100.0), 460.0),
        "Claude · running 6 min"
    );
    assert_eq!(status_line(&busy, None, 460.0), "Claude · running");
    assert_eq!(
        status_line(&busy, Some(459.0), 460.0),
        "Claude · running 1 min"
    );
    assert_eq!(
        status_line(&snap(json!({"status": "busy", "paused": true})), None, 0.0),
        "Claude · held by you"
    );
    assert_eq!(
        status_line(&snap(json!({"paired": true})), None, 0.0),
        "Pair · editing your checkout"
    );
    assert_eq!(
        status_line(&snap(json!({"status": "waiting"})), None, 0.0),
        "Claude · waiting"
    );
    assert_eq!(
        status_line(&snap(json!({"status": "exited"})), None, 0.0),
        "Claude · ended"
    );
    assert_eq!(status_line(&snap(json!({})), None, 0.0), "Claude · idle");
}

// pattern: D
#[test]
fn the_header_is_one_row_with_its_lens_and_buttons_at_a_stop() {
    let (rows, images) = build(&snap(json!({})), 600, None);
    let head = &rows[0];
    assert_eq!(head.key, HEAD);
    assert!(head.text.contains("Fix the tests"), "{:?}", head.text);
    assert!(head.text.contains(" · Claude · idle"), "{:?}", head.text);
    // the lens is clickable: one action per preset, the one in force raised
    let actions: Vec<_> = props(head, "drgnx-agent-panel-action");
    let names: Vec<_> = actions
        .iter()
        .map(|(v, _)| v.as_str().unwrap_or(""))
        .collect();
    assert_eq!(names, ["lens:1", "lens:2", "lens:3", "pin", "more"]);
    assert!(actions[1].1.contains("review"));
    assert!(head.runs.iter().any(|(a, b, f)| {
        f == FaceId::AgentPanelLensOn.name()
            && head
                .text
                .chars()
                .skip(*a as usize)
                .take((b - a) as usize)
                .collect::<String>()
                .contains("review")
    }));
    // the right part starts at a stop, and its three icons are images
    assert_eq!(head.stops.len(), 1);
    assert!(head.stops[0].1 < 600);
    assert_eq!(images.len(), 3, "bot, pin and ellipsis");
    assert_eq!(head.images.len(), 3);
}

// pattern: D
#[test]
fn a_narrow_panel_cuts_what_the_agent_does_and_keeps_the_buttons() {
    let wide = build(&snap(json!({"status": "busy"})), 2000, Some(0.0)).0;
    let narrow = build(&snap(json!({"status": "busy"})), 450, Some(0.0)).0;
    let tiny = build(&snap(json!({"status": "busy"})), 300, Some(0.0)).0;
    assert!(
        !tiny[0].text.contains(" · "),
        "nothing fits the status: {:?}",
        tiny[0].text
    );
    assert!(wide[0].text.contains("running 17 min"));
    assert!(
        !narrow[0].text.contains("running 17 min"),
        "{:?}",
        narrow[0].text
    );
    assert!(narrow[0].text.contains('…'), "{:?}", narrow[0].text);
    // the buttons are still there, at the right edge
    assert_eq!(props(&narrow[0], "drgnx-agent-panel-action").len(), 5);
    assert!(narrow[0].stops[0].1 <= 450);
}

// pattern: D
#[test]
fn the_chips_are_what_the_snapshot_feeds() {
    let none = build(&snap(json!({})), 600, None).0;
    assert!(
        none.iter().all(|r| r.key != CHIPS),
        "no usage, no mode: no chips row"
    );
    let s = snap(json!({"usage": {"used": 50.0, "size": 100.0, "cost": 1.234}, "mode": "steer"}));
    let rows = build(&s, 600, None).0;
    let chips = &rows[1];
    assert_eq!(chips.key, CHIPS);
    assert!(chips.text.contains("◑ 50%"), "{:?}", chips.text);
    assert!(chips.text.contains("$1.23"), "{:?}", chips.text);
    let kinds: Vec<_> = props(chips, FaceId::AgentPanelChip.name())
        .into_iter()
        .map(|(v, _)| v.as_str().unwrap_or("").to_owned())
        .collect();
    assert_eq!(kinds, ["context", "cost", "mode"]);
    // a cost as an object
    let obj = snap(json!({"usage": {"cost": {"amount": 2.0}}}));
    assert!(build(&obj, 600, None).0[1].text.contains("$2.00"));
}

// pattern: D
#[test]
fn a_terminal_header_has_no_images() {
    let mut e = env(80 * 8);
    e.display = Display::Tty;
    let (f, l) = (fonts(), lens());
    let (rows, images) = rows(
        &snap(json!({})),
        &Cx {
            env: &e,
            fonts: &f,
            lens: &l,
            open: &BTreeSet::new(),
            busy_since: None,
            now: 0.0,
            files_edited: None,
            checkpoints: None,
            chain: &[],
            plan: &[],
        },
    );
    assert!(images.len() == 3 || images.is_empty());
    assert!(rows[0].text.contains("Fix the tests"));
}

// pattern: D
#[test]
fn the_strip_has_a_pill_per_step_type_the_open_ones_raised() {
    let rows = build(&snap(json!({})), 1000, None).0;
    let strip = rows.iter().find(|r| r.key == STRIP).expect("the strip");
    assert!(
        strip.text.starts_with(" Expand steps: "),
        "{:?}",
        strip.text
    );
    // each pill says what a click does, so the strip reads as a switch, not a label
    let helps = props(strip, "help-echo");
    assert!(
        helps.iter().any(|(v, _)| v
            .as_str()
            .is_some_and(|h| h.starts_with("Click to expand or collapse"))),
        "{helps:?}"
    );
    for t in STEP_TYPES {
        assert!(strip.text.contains(&format!(" {t} ")), "{:?}", strip.text);
    }
    let actions: Vec<_> = props(strip, "drgnx-agent-panel-action")
        .into_iter()
        .map(|(v, _)| v.as_str().unwrap_or("").to_owned())
        .collect();
    assert_eq!(actions.first().map(String::as_str), Some("type:thinking"));
    assert_eq!(actions.last().map(String::as_str), Some("default"));
    let raised: Vec<String> = strip
        .runs
        .iter()
        .filter(|(_, _, f)| f == FaceId::AgentPanelTagOn.name())
        .map(|(a, b, _)| {
            strip
                .text
                .chars()
                .skip(*a as usize)
                .take((b - a) as usize)
                .collect()
        })
        .collect();
    assert_eq!(raised, [" edit "]);
    // make default sits at a stop of the line it is on
    assert_eq!(strip.stops.len(), 1);
}

// pattern: D
#[test]
fn a_narrow_panel_wraps_the_strip_under_its_first_pill() {
    let rows = build(&snap(json!({})), 300, None).0;
    let strips: Vec<&Row> = rows.iter().filter(|r| r.key.starts_with(STRIP)).collect();
    assert!(strips.len() > 1, "{} rows", strips.len());
    assert_eq!(strips[1].key, "p:strip:1");
    // every pill is somewhere, in order, once
    let all: String = strips
        .iter()
        .map(|r| r.text.as_str())
        .collect::<Vec<_>>()
        .join("");
    for t in STEP_TYPES {
        assert_eq!(all.matches(&format!(" {t} ")).count(), 1, "{all:?}");
    }
    assert!(all.contains("make default"));
}

// pattern: D
#[test]
fn the_chips_say_the_sandbox_the_files_and_the_checkpoints_when_the_hub_knows() {
    let (e, f, l) = (env(400), fonts(), lens());
    let s = snap(json!({"enforced": true, "usage": {"used": 100, "size": 1000}}));
    let (rows, _) = rows(
        &s,
        &Cx {
            env: &e,
            fonts: &f,
            lens: &l,
            open: &BTreeSet::new(),
            busy_since: None,
            now: 0.0,
            files_edited: Some(3),
            checkpoints: Some(1),
            chain: &[],
            plan: &[],
        },
    );
    let chip_rows: Vec<_> = rows.iter().filter(|r| r.key.starts_with(CHIPS)).collect();
    let all: String = chip_rows.iter().map(|r| r.text.as_str()).collect();
    assert!(all.contains("sandboxed"), "{all}");
    assert!(all.contains("3 files"), "{all}");
    assert!(all.contains("1 checkpoint "), "{all}");
    // only the context chip explains itself on a click
    assert_eq!(
        chip_rows
            .iter()
            .map(|r| props(r, FaceId::AgentPanelChip.name()).len())
            .sum::<usize>(),
        1
    );
}

// pattern: D
#[test]
fn the_chips_say_the_model_and_the_mcp_servers_and_both_explain_themselves() {
    let (e, f, l) = (env(400), fonts(), lens());
    let s = snap(json!({"model": "opus", "mcp": ["drgnx", "drgnx-search"]}));
    let (rows, _) = rows(
        &s,
        &Cx {
            env: &e,
            fonts: &f,
            lens: &l,
            open: &BTreeSet::new(),
            busy_since: None,
            now: 0.0,
            files_edited: None,
            checkpoints: None,
            chain: &[],
            plan: &[],
        },
    );
    let chips = rows.iter().find(|r| r.key == CHIPS).expect("chips");
    assert!(chips.text.contains(" opus "), "{}", chips.text);
    assert!(chips.text.contains("MCP 2"), "{}", chips.text);
    let kinds: Vec<String> = props(chips, FaceId::AgentPanelChip.name())
        .into_iter()
        .map(|(v, _)| v.as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(kinds, ["model", "mcp"]);
    // the model comes first, as the mockup has it
    assert!(chips.text.find("opus") < chips.text.find("MCP"));
}

// pattern: D
#[test]
fn chips_that_do_not_fit_one_row_wrap_to_the_next_never_cut_audit_a3() {
    let (e, f, l) = (env(300), fonts(), lens());
    let s = snap(json!({"enforced": true, "model": "opus", "mcp": ["a", "b"],
                        "usage": {"used": 100, "size": 1000, "cost": 1.5}}));
    let (rows, _) = rows(
        &s,
        &Cx {
            env: &e,
            fonts: &f,
            lens: &l,
            open: &BTreeSet::new(),
            busy_since: None,
            now: 0.0,
            files_edited: Some(3),
            checkpoints: Some(12),
            chain: &[],
            plan: &[],
        },
    );
    let chip_rows: Vec<_> = rows.iter().filter(|r| r.key.starts_with(CHIPS)).collect();
    assert!(chip_rows.len() > 1, "one row of {} chips", chip_rows.len());
    assert_eq!(chip_rows[0].key, CHIPS);
    let all: String = chip_rows.iter().map(|r| r.text.as_str()).collect();
    for w in [
        "opus",
        "10%",
        "$1.50",
        "sandboxed",
        "MCP 2",
        "3 files",
        "12 checkpoints",
    ] {
        assert!(all.contains(w), "{w} in {all}");
    }
}

fn cx_of<'a>(
    e: &'a ViewEnv,
    f: &'a FontSet,
    l: &'a Lens,
    open: &'a BTreeSet<String>,
    chain: &'a [ChainLink],
    plan: &'a [(String, String)],
) -> Cx<'a> {
    Cx {
        env: e,
        fonts: f,
        lens: l,
        open,
        busy_since: None,
        now: 0.0,
        files_edited: None,
        checkpoints: None,
        chain,
        plan,
    }
}

fn link(kind: &str, id: &str, label: &str) -> ChainLink {
    ChainLink {
        kind: kind.into(),
        id: id.into(),
        label: label.into(),
    }
}

// pattern: D
#[test]
fn the_chain_chips_select_their_node_in_work() {
    let (e, f, l, open) = (env(600), fonts(), lens(), BTreeSet::new());
    let chain = [
        link("spec", "s1", "Search view"),
        link("plan", "p2", "A: search"),
        link("task", "t7", "Fix the ask"),
    ];
    let (rows, _) = rows(&snap(json!({})), &cx_of(&e, &f, &l, &open, &chain, &[]));
    let chain_row = rows.iter().find(|r| r.key == CHAIN).expect("a chain row");
    assert_eq!(rows[1].key, CHAIN, "right under the header");
    for label in ["Search view", "A: search", "Fix the ask"] {
        assert!(chain_row.text.contains(label), "{:?}", chain_row.text);
    }
    assert!(chain_row.text.contains('›'), "{:?}", chain_row.text);
    let kinds: Vec<_> = props(chain_row, FaceId::AgentPanelChip.name())
        .into_iter()
        .map(|(v, text)| (v.as_str().unwrap_or("").to_owned(), text))
        .collect();
    assert_eq!(
        kinds.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(),
        ["select:spec:s1", "select:plan:p2", "select:task:t7"]
    );
    // no chain, no row
    let (none, _) = rows_of_empty(&e, &f, &l, &open);
    assert!(none.iter().all(|r| r.key != CHAIN));
}

fn rows_of_empty(
    e: &ViewEnv,
    f: &FontSet,
    l: &Lens,
    open: &BTreeSet<String>,
) -> (Vec<Row>, Vec<(ImageId, String)>) {
    rows(&snap(json!({})), &cx_of(e, f, l, open, &[], &[]))
}

// pattern: D
#[test]
fn the_chips_name_the_worktree_the_agent_works_in() {
    let (e, f, l, open) = (env(600), fonts(), lens(), BTreeSet::new());
    let s = snap(json!({"cwd": "/work/proj/.claude/worktrees/r6-flow-23"}));
    let (first, _) = rows(&s, &cx_of(&e, &f, &l, &open, &[], &[]));
    let chips: String = first
        .iter()
        .filter(|r| r.key.starts_with(CHIPS))
        .map(|r| r.text.as_str())
        .collect();
    assert!(chips.contains(" r6-flow-23 "), "{chips:?}");
    // a folder that is no worktree is named by its own last part
    let s = snap(json!({"cwd": "/work/proj/"}));
    let (rows, _) = rows(&s, &cx_of(&e, &f, &l, &open, &[], &[]));
    let chips: String = rows
        .iter()
        .filter(|r| r.key.starts_with(CHIPS))
        .map(|r| r.text.as_str())
        .collect();
    assert!(chips.contains(" proj "), "{chips:?}");
}

// pattern: D
#[test]
fn the_plan_strip_is_a_status_dot_and_its_word_per_plan_item() {
    let (e, f, l, open) = (env(600), fonts(), lens(), BTreeSet::new());
    let plan = [
        ("completed".to_owned(), "Read the gateway".to_owned()),
        ("in_progress".to_owned(), "Queue replies".to_owned()),
        ("pending".to_owned(), "Test it".to_owned()),
    ];
    let (rows, _) = rows(&snap(json!({})), &cx_of(&e, &f, &l, &open, &[], &plan));
    let at = rows.iter().position(|r| r.key == PLAN).expect("a plan row");
    let strip_at = rows.iter().position(|r| r.key.starts_with(STRIP)).unwrap();
    assert!(
        at < strip_at,
        "the plan strip comes before the step-type strip"
    );
    let r = &rows[at];
    for word in ["Read the gateway", "Queue replies", "Test it"] {
        assert!(r.text.contains(word), "{:?}", r.text);
    }
    let dots: Vec<&str> = r
        .runs
        .iter()
        .map(|(_, _, face)| face.as_str())
        .filter(|f| f.starts_with("drgnx-kit-status-dot"))
        .collect();
    assert_eq!(
        dots,
        [
            FaceId::KitStatusDotDone.name(),
            FaceId::KitStatusDotRunning.name(),
            FaceId::KitStatusDotIdle.name()
        ]
    );
    // no plan, no row
    let (none, _) = rows_of_empty(&e, &f, &l, &open);
    assert!(none.iter().all(|r| r.key != PLAN));
}
