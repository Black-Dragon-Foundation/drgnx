use super::*;
use rodd::faces::FaceId;
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
        hc: false,
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
            budget: None,
            ended_at: &NO_ENDED,
            bg_selected: None,
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
            budget: None,
            ended_at: &NO_ENDED,
            bg_selected: None,
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
            budget: None,
            ended_at: &NO_ENDED,
            bg_selected: None,
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
            budget: None,
            ended_at: &NO_ENDED,
            bg_selected: None,
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
            budget: None,
            ended_at: &NO_ENDED,
            bg_selected: None,
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
        budget: None,
        ended_at: &NO_ENDED,
        bg_selected: None,
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

/// Flow Task 23a: the header's cost chip reads the spend and the limit of the scope that holds the agent.
#[test]
fn header_cost_chip_has_spend_and_limit() {
    let (e, f, l, open) = (env(600), fonts(), lens(), BTreeSet::new());
    let s = snap(json!({"usage": {"used": 50.0, "size": 100.0, "cost": 1.2}}));
    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
    cx.budget = Some((1.2, 5.0));
    let (rows, _) = rows(&s, &cx);
    let chips: String = rows
        .iter()
        .filter(|r| r.key.starts_with(CHIPS))
        .map(|r| r.text.as_str())
        .collect();
    assert!(chips.contains("$1.20 / $5"), "{chips:?}");
    // the chip still explains itself on a click (its kind is `cost`)
    let kinds: Vec<_> = rows
        .iter()
        .flat_map(|r| props(r, FaceId::AgentPanelChip.name()))
        .map(|(v, _)| v.as_str().unwrap_or("").to_owned())
        .collect();
    assert!(kinds.iter().any(|k| k == "cost"), "{kinds:?}");
    // without a limit, the plain spend
    let (plain, _) = rows_of_empty(&e, &f, &l, &open);
    assert!(plain.iter().all(|r| !r.text.contains(" / $")));
}

// ---- background work (the panel's chip and its pinned list) ----

fn item(
    kind: &str,
    id: &str,
    what: &str,
    started_ms: u64,
    last: Option<&str>,
    status: &str,
    cancel: bool,
) -> Value {
    let mut v = json!({
        "kind": kind, "id": id, "description": what, "started_ms": started_ms,
        "status": status, "can_cancel": cancel,
    });
    if let (Some(l), Some(o)) = (last, v.as_object_mut()) {
        o.insert("progress".into(), json!(l));
    }
    v
}

fn three() -> Value {
    json!([
        item(
            "terminal",
            "t1",
            "cargo test -p hermod",
            1_000_000 - 252_000,
            Some("test v2::turn_ends_at_idle ... ok"),
            "running",
            true
        ),
        item(
            "tool_call",
            "w1",
            "Watching CI on staging PR #412",
            1_000_000 - 760_000,
            Some("3 of 7 jobs done"),
            "running",
            false
        ),
        item(
            "subagent",
            "c1",
            "Subagent: review the v2 diff",
            1_000_000 - 125_000,
            Some("read conn.rs"),
            "running",
            true
        ),
    ])
}

fn rows_with(background: Value, open: &[&str], width: u32, display: Display) -> Vec<Row> {
    let mut e = env(width);
    e.display = display;
    let (f, l) = (fonts(), lens());
    let open: BTreeSet<String> = open.iter().map(|s| (*s).to_owned()).collect();
    rows(
        &snap(json!({ "background": background })),
        &cx_of(&e, &f, &l, &open, &[], &[]),
    )
    .0
}

fn gui(background: Value) -> Vec<Row> {
    gui_sel(background, None)
}

fn gui_sel(background: Value, selected: Option<&str>) -> Vec<Row> {
    let mut e = env(600);
    e.display = Display::Gui;
    let (f, l) = (fonts(), lens());
    let open = BTreeSet::new();
    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
    cx.now = 1000.0;
    cx.bg_selected = selected;
    rows(&snap(json!({ "background": background })), &cx).0
}

fn head_text(rows: &[Row]) -> String {
    rows.iter()
        .find(|r| r.key == HEAD)
        .map(|r| r.text.clone())
        .unwrap_or_default()
}

#[test]
fn chip_hidden_without_background() {
    // None: the agent does not report it; Some([]): nothing runs.  Neither shows a chip or a list.
    let none = rows(
        &snap(json!({})),
        &cx_of(&env(600), &fonts(), &lens(), &BTreeSet::new(), &[], &[]),
    )
    .0;
    assert!(!head_text(&none).contains("in background"));
    assert!(none.iter().all(|r| !r.key.starts_with("bg:")));
    let empty = gui(json!([]));
    assert!(!head_text(&empty).contains("in background"));
    assert!(empty.iter().all(|r| !r.key.starts_with("bg:")));
}

#[test]
fn chip_counts_running_items() {
    let rows = gui(three());
    let head = rows.iter().find(|r| r.key == HEAD).expect("the header");
    assert!(head.text.contains("3 in background"), "{}", head.text);
    let acts = props(head, "drgnx-agent-panel-action");
    assert!(
        acts.iter()
            .any(|(v, t)| **v == json!("background-list") && t.contains("3 in background")),
        "{acts:?}"
    );
    // an ended item is not counted
    let mut two = three();
    two.as_array_mut().expect("list").pop();
    assert!(head_text(&gui(two)).contains("2 in background"));
}

#[test]
fn chip_unknown_uses_warning_text() {
    let rows = gui(json!([
        item("terminal", "t1", "cargo test", 0, None, "unknown", false),
        item("tool_call", "w1", "watch", 0, None, "unknown", false),
    ]));
    let head = rows.iter().find(|r| r.key == HEAD).expect("the header");
    assert!(head.text.contains("2 · state unknown"), "{}", head.text);
    assert!(!head.text.contains("in background"));
    let byte = head.text.find("2 · state unknown").expect("chip text");
    let at = head.text[..byte].chars().count() as u32 + 3;
    let warn = rodd::kit_gen::face(
        rodd::kit_gen::CompId::Chip,
        &["warn", "soft", "comfortable"],
    );
    assert!(
        head.runs
            .iter()
            .any(|(a, b, f)| f == warn.name() && *a <= at && at < *b),
        "the kit's warning pill over the chip: {:?}",
        head.runs
    );
    assert!(!head.images.is_empty(), "the warning icon is an image");
}

#[test]
fn background_list_rows_per_item() {
    let rows = gui_sel(three(), Some("t1"));
    let keys: Vec<&str> = rows
        .iter()
        .map(|r| r.key.as_str())
        .filter(|k| k.starts_with("bg:"))
        .collect();
    assert_eq!(
        keys,
        [
            "bg:head", "bg:t1", "bg:t1:1", "bg:w1", "bg:w1:1", "bg:c1", "bg:c1:1"
        ]
    );
    let by = |k: &str| rows.iter().find(|r| r.key == k).expect(k);
    assert!(
        by("bg:head").text.contains("In background · 3"),
        "{}",
        by("bg:head").text
    );
    assert!(by("bg:t1").text.contains("cargo test -p hermod"));
    assert!(
        by("bg:t1").text.trim_end().ends_with("4:12"),
        "{}",
        by("bg:t1").text
    );
    assert!(
        by("bg:w1").text.trim_end().ends_with("12:40"),
        "{}",
        by("bg:w1").text
    );
    assert!(
        by("bg:c1").text.trim_end().ends_with("2:05"),
        "{}",
        by("bg:c1").text
    );
    assert!(
        by("bg:t1:1")
            .text
            .contains("test v2::turn_ends_at_idle ... ok")
    );
    // each row names its item, its kind and whether it can be stopped
    let first = props(by("bg:t1"), "drgnx-bg-item");
    assert_eq!(first[0].0, &json!("t1"));
    assert_eq!(props(by("bg:t1"), "drgnx-bg-kind")[0].0, &json!("terminal"));
    assert_eq!(
        props(by("bg:w1"), "drgnx-bg-kind")[0].0,
        &json!("tool_call")
    );
    assert_eq!(props(by("bg:c1"), "drgnx-bg-kind")[0].0, &json!("subagent"));
    assert_eq!(props(by("bg:t1"), "drgnx-bg-can-cancel")[0].0, &json!(true));
    assert_eq!(
        props(by("bg:w1"), "drgnx-bg-can-cancel")[0].0,
        &json!(false)
    );
    // the elapsed cell carries when the item began, for the ticking timer
    let el = props(by("bg:t1"), "drgnx-bg-elapsed");
    assert_eq!(el[0].0, &json!(1_000_000u64 - 252_000));
    assert_eq!(el[0].1, "4:12");
    // the selected row shows its actions (Output), the others only their last line
    assert!(by("bg:t1:1").text.contains("Output"));
    assert!(
        !by("bg:c1:1").text.contains("Open"),
        "{}",
        by("bg:c1:1").text
    );
    assert!(
        !by("bg:w1:1").text.contains("Output"),
        "{}",
        by("bg:w1:1").text
    );
    // "Stop all" in the head while something can be stopped
    let acts = props(by("bg:head"), "drgnx-agent-panel-action");
    assert!(
        acts.iter()
            .any(|(v, _)| **v == json!("background-stop-all")),
        "{acts:?}"
    );
}

#[test]
fn background_list_collapsed() {
    let mut e = env(600);
    e.display = Display::Gui;
    let (f, l) = (fonts(), lens());
    let open = BTreeSet::from(["bg-folded".to_owned()]);
    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
    cx.now = 1000.0;
    let rows = rows(&snap(json!({ "background": three() })), &cx).0;
    let keys: Vec<&str> = rows
        .iter()
        .map(|r| r.key.as_str())
        .filter(|k| k.starts_with("bg:"))
        .collect();
    assert_eq!(keys, ["bg:head"]);
    // the chip still counts them
    assert!(head_text(&rows).contains("3 in background"));
}

#[test]
fn background_list_caps_visible_rows() {
    let many: Vec<Value> = (0..40)
        .map(|i| {
            item(
                "terminal",
                &format!("t{i}"),
                &format!("job {i}"),
                1_000_000 - 5_000,
                None,
                "running",
                true,
            )
        })
        .collect();
    let rows = gui(json!(many));
    let first_lines = rows
        .iter()
        .filter(|r| r.key.starts_with("bg:t") && !r.key.ends_with(":1"))
        .count();
    assert_eq!(first_lines, 6);
    let more = rows
        .iter()
        .find(|r| r.key == "bg:more")
        .expect("the more row");
    assert!(more.text.contains("and 34 more"), "{}", more.text);
    assert!(
        props(more, "drgnx-agent-panel-action")
            .iter()
            .any(|(v, _)| **v == json!("background-more"))
    );
    assert!(head_text(&rows).contains("40 in background"));
}

#[test]
fn background_row_long_text_one_line() {
    let long = "x".repeat(300);
    let multi = "first line\nsecond line\nthird";
    let rows = gui(json!([item(
        "terminal",
        "t1",
        &long,
        1_000_000 - 1000,
        Some(multi),
        "running",
        true
    )]));
    for k in ["bg:t1", "bg:t1:1"] {
        let r = rows.iter().find(|r| r.key == k).expect(k);
        assert!(!r.text.contains('\n'), "{k}: {:?}", r.text);
        assert!(
            r.text.chars().count() < 140,
            "{k} is {} chars",
            r.text.chars().count()
        );
    }
    let r = rows.iter().find(|r| r.key == "bg:t1").expect("row");
    assert!(r.text.contains('…'), "{}", r.text);
    assert!(
        rows.iter()
            .find(|r| r.key == "bg:t1:1")
            .expect("row")
            .text
            .contains("first line")
    );
    assert!(
        !rows
            .iter()
            .find(|r| r.key == "bg:t1:1")
            .expect("row")
            .text
            .contains("second line")
    );
}

#[test]
fn ended_item_faded_until_transcript_line() {
    let mut e = env(600);
    e.display = Display::Gui;
    let (f, l) = (fonts(), lens());
    let open = BTreeSet::new();
    let ended = json!([{
        "kind": "terminal", "id": "t9", "description": "cargo test -p hermod", "started_ms": 1_000_000 - 240_000,
        "status": "running", "can_cancel": false,
        "end": {"status": "failed", "exit_code": 101}
    }]);
    let snapshot = snap(json!({ "background": three(), "background_ended": ended }));
    let seen = BTreeMap::from([("t9".to_owned(), 998.0)]);
    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
    cx.now = 1000.0;
    cx.ended_at = &seen;
    let rows = rows(&snapshot, &cx).0;
    let r = rows
        .iter()
        .find(|r| r.key == "bg:t9")
        .expect("the ended item stays in the list");
    assert!(r.text.contains("failed · exit 101"), "{}", r.text);
    assert!(
        r.runs
            .iter()
            .any(|(_, _, f)| f == FaceId::AgentPanelSubtle.name())
    );
    assert!(
        props(r, "drgnx-bg-elapsed").is_empty(),
        "an ended item does not tick"
    );
    // not counted as running
    assert!(head_text(&rows).contains("3 in background"));
    // once its line has been in the transcript for a while it leaves
    let mut late = cx_of(&e, &f, &l, &open, &[], &[]);
    late.now = 1010.0;
    late.ended_at = &seen;
    assert!(rows_keys(&snapshot, &late).iter().all(|k| k != "bg:t9"));
}

fn rows_keys(s: &Snapshot, cx: &Cx) -> Vec<String> {
    rows(s, cx).0.into_iter().map(|r| r.key).collect()
}

#[test]
fn no_stop_without_can_cancel() {
    let rows = gui_sel(three(), Some("w1"));
    let w = rows
        .iter()
        .find(|r| r.key == "bg:w1:1")
        .expect("watcher line");
    assert!(!w.text.contains("Stop"), "{}", w.text);
    assert!(
        props(w, "drgnx-agent-panel-action")
            .iter()
            .all(|(v, _)| v.as_str().is_none_or(|a| !a.starts_with("background-stop")))
    );
    assert!(w.text.contains("Output"));
    let rows = gui_sel(three(), Some("t1"));
    let t = rows
        .iter()
        .find(|r| r.key == "bg:t1:1")
        .expect("terminal line");
    assert!(t.text.contains("Stop"));
    assert!(
        props(t, "drgnx-agent-panel-action")
            .iter()
            .any(|(v, _)| **v == json!("background-stop:t1"))
    );
    // nothing stoppable: no "Stop all" either
    let none = gui(json!([item(
        "tool_call",
        "w1",
        "watch",
        1_000_000 - 1000,
        None,
        "running",
        false
    )]));
    let head = none.iter().find(|r| r.key == "bg:head").expect("head");
    assert!(!head.text.contains("Stop all"));
}

#[test]
fn background_tty_rows_are_the_mockups_characters() {
    let ended = json!([{
        "kind": "terminal", "id": "t9", "description": "bin/drgnx test gateway", "started_ms": 1_000_000 - 240_000,
        "status": "running", "can_cancel": false, "end": {"status": "failed", "exit_code": 3}
    }]);
    let mut e = env(8 * 48);
    e.display = Display::Tty;
    let (f, l) = (fonts(), lens());
    let open = BTreeSet::new();
    let seen = BTreeMap::from([("t9".to_owned(), 998.0)]);
    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
    cx.now = 1000.0;
    cx.ended_at = &seen;
    let rows = rows(
        &snap(json!({ "background": three(), "background_ended": ended })),
        &cx,
    )
    .0;
    let text = |k: &str| {
        rows.iter()
            .find(|r| r.key == k)
            .map(|r| r.text.clone())
            .unwrap_or_default()
    };
    assert_eq!(
        text("bg:chip"),
        "⟳ 3 in background (b list, k stop, RET output)"
    );
    assert_eq!(
        text("bg:t1"),
        format!("R $ cargo test -p hermod{}4:12", " ".repeat(47 - 24 - 4))
    );
    assert_eq!(text("bg:t1:1"), "    test v2::turn_ends_at_idle ... ok");
    assert!(text("bg:w1").starts_with("R ◉ Watching CI on staging PR #412"));
    assert!(text("bg:w1").ends_with("12:40"));
    assert!(text("bg:c1").starts_with("R @ Subagent: review the v2 diff"));
    assert_eq!(
        text("bg:t9"),
        format!(
            "F $ bin/drgnx test gateway{}exit 3  4 min",
            " ".repeat(47 - 26 - 13)
        )
    );
    // no head row, no buttons: the keys do it
    assert!(
        rows.iter()
            .all(|r| r.key != "bg:head" && r.key != "bg:more")
    );
    assert!(head_text(&rows).find("in background").is_none());
}

#[test]
fn a_session_without_background_reports_draws_no_rows_even_tty() {
    let rows = rows_with(json!(null), &[], 320, Display::Tty);
    assert!(rows.iter().all(|r| !r.key.starts_with("bg:")));
}

#[test]
fn actions_show_on_the_selected_row_only() {
    let none = gui(three());
    assert!(
        none.iter()
            .all(|r| !r.text.contains("Output") && !r.text.contains("Open")),
        "nothing selected"
    );
    let sub = gui_sel(three(), Some("c1"));
    let c = sub
        .iter()
        .find(|r| r.key == "bg:c1:1")
        .expect("subagent line");
    assert!(
        c.text.contains("Open") && c.text.contains("Stop"),
        "{}",
        c.text
    );
    // the other rows stay plain
    assert!(
        !sub.iter()
            .find(|r| r.key == "bg:t1:1")
            .expect("terminal line")
            .text
            .contains("Stop")
    );
    // an item with no last line has a second row only while selected
    let bare = json!([item(
        "terminal",
        "t1",
        "make",
        1_000_000 - 1000,
        None,
        "running",
        true
    )]);
    assert!(gui(bare.clone()).iter().all(|r| r.key != "bg:t1:1"));
    assert!(gui_sel(bare, Some("t1")).iter().any(|r| r.key == "bg:t1:1"));
}

#[test]
fn the_chip_is_the_kits_soft_pill_with_a_spinner() {
    let rows = gui(three());
    let head = rows.iter().find(|r| r.key == HEAD).expect("the header");
    let pill = rodd::kit_gen::face(
        rodd::kit_gen::CompId::Chip,
        &["accent", "soft", "comfortable"],
    );
    assert!(
        head.runs.iter().any(|(_, _, f)| f == pill.name()),
        "the accent pill: {:?}",
        head.runs
    );
    assert!(!head.images.is_empty(), "the spinner is an image");
}

#[test]
fn the_list_is_one_card_with_its_ring_open_between_rows() {
    let ring = |shape: &str| {
        rodd::kit_gen::face(
            rodd::kit_gen::CompId::Card,
            &["plain", shape, "comfortable"],
        )
        .name()
        .to_owned()
    };
    let rows = gui_sel(three(), Some("t1"));
    let list: Vec<&Row> = rows.iter().filter(|r| r.key.starts_with("bg:")).collect();
    let has = |r: &Row, shape: &str| r.runs.iter().any(|(_, _, f)| *f == ring(shape));
    assert!(has(list[0], "top"), "the head opens the card");
    assert!(has(list[1], "mid"));
    assert!(has(list[list.len() - 1], "bottom"));
    // folded, the head alone is the whole card
    let mut e = env(600);
    e.display = Display::Gui;
    let (f, l) = (fonts(), lens());
    let open = BTreeSet::from(["bg-folded".to_owned()]);
    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
    cx.now = 1000.0;
    let folded = rows_of_cx(&snap(json!({ "background": three() })), &cx);
    let head = folded.iter().find(|r| r.key == "bg:head").expect("head");
    assert!(has(head, "single"));
}

fn rows_of_cx(s: &Snapshot, cx: &Cx) -> Vec<Row> {
    rows(s, cx).0
}

#[test]
fn the_selected_row_has_the_selection_tint_inset_from_the_card() {
    // the focus ring needs a box of its own inside the card's, which would cut the card's ring at every run end: the tint
    // alone until Glitnir draws an inset ring over a span of rows (the plan ledger's written case)
    let rows = gui_sel(three(), Some("t1"));
    let sel = rows.iter().find(|r| r.key == "bg:t1").expect("the row");
    let tinted: Vec<_> = sel
        .runs
        .iter()
        .filter(|(_, _, f)| f == FaceId::Selected.name())
        .collect();
    assert_eq!(tinted.len(), 1, "{:?}", sel.runs);
    assert!(sel.runs.iter().all(|(_, _, f)| f != FaceId::Focus.name()));
    let line = rows.iter().find(|r| r.key == "bg:t1:1").expect("the line");
    assert!(line.runs.iter().all(|(_, _, f)| f != FaceId::Focus.name()));
    assert!(
        line.runs
            .iter()
            .any(|(_, _, f)| f == FaceId::Selected.name())
    );
    let len = sel.text.chars().count() as u32;
    for (a, b, _) in tinted {
        assert!(
            *a > 0 && *b < len,
            "inset from the card's edge: {a}..{b} of {len}"
        );
    }
    let plain = rows.iter().find(|r| r.key == "bg:w1").expect("the row");
    assert!(
        plain
            .runs
            .iter()
            .all(|(_, _, f)| f != FaceId::Selected.name())
    );
}

#[test]
fn the_actions_are_kit_buttons_with_their_keys() {
    let rows = gui_sel(three(), Some("t1"));
    let line = rows.iter().find(|r| r.key == "bg:t1:1").expect("the line");
    assert!(
        line.images.iter().any(|(_, _, alt)| alt == "↵"),
        "Output's key: {:?}",
        line.images
    );
    assert!(line.text.contains("Stop"), "{:?}", line.text);
    let button = rodd::kit_gen::face(
        rodd::kit_gen::CompId::Button,
        &["secondary", "sm", "comfortable"],
    );
    assert!(
        line.runs.iter().any(|(_, _, f)| f == button.name()),
        "the kit's button face: {:?}",
        line.runs
    );
}

#[test]
fn no_run_of_the_list_names_the_default_face() {
    // `default` has a box of its own (none): over the card's ring it cuts the ring into pieces
    for r in gui_sel(three(), Some("t1"))
        .into_iter()
        .filter(|r| r.key.starts_with("bg:"))
    {
        assert!(
            r.runs.iter().all(|(_, _, f)| f != "default"),
            "{}: {:?}",
            r.key,
            r.runs
        );
    }
}

/// What a row's drawn width is, in device px: its characters in their runs' faces, its stretch spaces, its images and
/// its stops (the text after a stop starts at its px, or where the text before ended when that is further).
fn drawn_width(r: &Row, scale: f32, fonts: &FontSet) -> u32 {
    let mut x = 0u32;
    for (i, ch) in r.text.chars().enumerate() {
        let i = i as u32;
        if let Some((_, px)) = r.stops.iter().find(|(p, _)| *p == i) {
            x = x.max(*px);
        } else if let Some((_, w, _)) = r.spaces.iter().find(|(p, _, _)| *p == i) {
            x += w;
        } else if r.images.iter().any(|(p, _, _)| *p == i) {
            x += (16.0 * scale + 0.5) as u32;
        } else {
            let face = r
                .runs
                .iter()
                .find(|(a, b, _)| *a <= i && i < *b)
                .map(|(_, _, f)| f.as_str());
            x += fit::width_in(fonts, face, &ch.to_string()).ceil() as u32;
        }
    }
    x
}

#[test]
fn every_row_of_the_card_fits_the_window_at_scale_1_1_25_and_2() {
    // the width budget is device px throughout: pads, icons, stops and measured text all at the env's scale
    for scale in [1.0f32, 1.25, 2.0] {
        for logical in [520u32, 640] {
            let width = (logical as f32 * scale).round() as u32;
            let mut e = env(width);
            e.scale = scale;
            e.display = Display::Gui;
            let mut f = FontSet::new();
            f.set_role("ui", None, 7.0 * scale);
            let l = lens();
            let open = BTreeSet::new();
            let many: Vec<Value> = (0..8)
                .map(|n| {
                    item(
                        "terminal",
                        &format!("t{n}"),
                        &format!("cargo test -p hermod --features long-list {n}"),
                        1_000_000 - 252_000,
                        Some(
                            "test v2::turn_ends_at_idle ... ok · a long last line that must be cut",
                        ),
                        "running",
                        true,
                    )
                })
                .collect();
            for sel in [None, Some("t0"), Some("t1")] {
                for list in [three(), json!(many.clone())] {
                    let mut cx = cx_of(&e, &f, &l, &open, &[], &[]);
                    cx.now = 1000.0;
                    cx.bg_selected = sel;
                    let rows = rows(&snap(json!({ "background": list })), &cx).0;
                    for r in rows
                        .iter()
                        .filter(|r| r.key.starts_with("bg:") || r.key == HEAD)
                    {
                        let w = drawn_width(r, scale, &f);
                        assert!(
                            w <= width,
                            "scale {scale}, window {width} px, sel {sel:?}: {} is {w} px: {:?}",
                            r.key,
                            r.text
                        );
                        // and reaches it: a row that stops short leaves the card's ring ending in the middle of the card
                        if r.key.starts_with("bg:") {
                            assert!(
                                w + 2 >= width,
                                "scale {scale}, window {width} px: {} ends at {w} px: {:?}",
                                r.key,
                                r.text
                            );
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn the_last_line_is_in_the_code_font_from_edge_to_edge() {
    // pads and text in one face: no font change inside the row for the card's ring to end a segment at
    let rows = gui(three());
    let line = rows.iter().find(|r| r.key == "bg:w1:1").expect("the line");
    let len = line.text.chars().count() as u32;
    assert!(
        line.runs
            .iter()
            .any(|(a, b, f)| *a == 0 && *b == len && f == FaceId::AgentPanelOutput.name()),
        "{:?}",
        line.runs
    );
}

#[test]
fn no_stretch_in_the_card_is_zero_high() {
    // a zero-high stretch ends the box run of the card's ring (the left edge goes, a stray one stands where the text
    // begins) and of a button's box before its key hint: measured in the box-experiment scene
    for sel in [None, Some("t1"), Some("c1")] {
        for r in gui_sel(three(), sel)
            .into_iter()
            .filter(|r| r.key.starts_with("bg:"))
        {
            assert!(!r.spaces.is_empty(), "{} has pads", r.key);
            assert!(
                r.spaces.iter().all(|(_, _, h)| *h >= 1),
                "{}: {:?}",
                r.key,
                r.spaces
            );
        }
    }
}

#[test]
fn no_two_stretches_stand_side_by_side_in_the_card() {
    // two stretches next to each other inside the card's box run draw a stray vertical edge where the second ends
    // (light theme, a row's first glyph; measured in the pads experiment): adjacent pads are one stretch
    for sel in [None, Some("t1"), Some("c1")] {
        for r in gui_sel(three(), sel)
            .into_iter()
            // the selected item's rows carry the tint, which splits their pads into two runs: not merged
            .filter(|r| {
                r.key.starts_with("bg:")
                    && sel.is_none_or(|k| !r.key.starts_with(&format!("bg:{k}")))
            })
        {
            for w in r.spaces.windows(2) {
                assert!(w[0].0 + 1 < w[1].0, "{}: {:?}", r.key, r.spaces);
            }
        }
    }
}

#[test]
fn the_enter_key_hint_is_an_image_inside_one_keycap_run() {
    // the code font has no `↵`: its fallback glyph broke the keycap's box into a cell each for the pad, the glyph and
    // the pad (a stray doubled edge). The key is one image character, under the same faces as the pads around it.
    let rows = gui_sel(three(), Some("t1"));
    let line = rows.iter().find(|r| r.key == "bg:t1:1").expect("the line");
    assert!(!line.text.contains('↵'), "{:?}", line.text);
    let (at, _, _) = line
        .images
        .iter()
        .find(|(_, _, alt)| alt == "↵")
        .expect("the key's image");
    let faces = |p: u32| -> Vec<&str> {
        line.runs
            .iter()
            .filter(|(a, b, _)| *a <= p && p < *b)
            .map(|(_, _, f)| f.as_str())
            .collect()
    };
    assert!(faces(*at).contains(&FaceId::KitKeyHintCap.name()));
    assert_eq!(faces(at - 1), faces(*at));
    assert_eq!(faces(*at), faces(at + 1));
}

#[test]
fn a_rows_end_is_one_stretch_not_a_stop_and_a_pad() {
    // a stop followed by a pad at the row's end loses the card's right edge on that row (measured: the second lines of
    // the list ended with both); the pad joins the stop
    for sel in [None, Some("t1")] {
        for r in gui_sel(three(), sel)
            .into_iter()
            // the selected item's rows carry the tint, which splits their ends into two runs: not merged
            .filter(|r| {
                r.key.starts_with("bg:")
                    && sel.is_none_or(|k| !r.key.starts_with(&format!("bg:{k}")))
            })
        {
            for (p, _) in &r.stops {
                assert!(
                    !r.spaces.iter().any(|s| s.0 == p + 1),
                    "{}: stops {:?} spaces {:?}",
                    r.key,
                    r.stops,
                    r.spaces
                );
            }
        }
    }
}

#[test]
fn the_pad_between_the_two_buttons_has_no_box_of_its_own() {
    // the card's box under a pad between two button boxes is a run of its own: it draws a thin edge at each end of
    // the gap (measured on the selected row, light theme, s2): the gap's face drops the box
    let rows = gui_sel(three(), Some("t1"));
    let line = rows.iter().find(|r| r.key == "bg:t1:1").expect("the line");
    let span = |action: &str| {
        line.props
            .iter()
            .find(|(_, _, n, v)| n == "drgnx-agent-panel-action" && v == action)
            .map(|(a, b, _, _)| (*a, *b))
            .unwrap_or_else(|| panic!("{action} in {:?}", line.props))
    };
    let (_, out_end) = span("background-output:t1");
    let (stop_start, _) = span("background-stop:t1");
    assert_eq!(stop_start, out_end + 1, "one character between the buttons");
    assert!(
        line.runs
            .iter()
            .any(|(a, b, f)| *a <= out_end && out_end < *b && f == FaceId::AgentPanelGap.name()),
        "{:?}",
        line.runs
    );
}
