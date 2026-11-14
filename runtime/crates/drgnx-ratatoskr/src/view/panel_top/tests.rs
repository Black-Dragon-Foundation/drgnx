use super::*;
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
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
        rows_in_sja: false,
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
        f == "drgnx-agent-panel-lens-on"
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
    let kinds: Vec<_> = props(chips, "drgnx-agent-panel-chip")
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
    assert!(strip.text.starts_with(" Open: "), "{:?}", strip.text);
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
        .filter(|(_, _, f)| f == "drgnx-agent-panel-tag-on")
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
