use super::*;

fn row(id: &str, state: w::State) -> w::Row {
    w::Row {
        id: id.into(),
        kind: w::Kind::Package,
        name: id.trim_start_matches("pkg:").into(),
        summary: "Does a thing".into(),
        state,
        source: "melpa".into(),
        signed: w::Signed::UnsignedArchive,
        version: Some("1.2".into()),
        latest: Some("1.3".into()),
        downloads: None,
        why: vec![],
    }
}

fn section(name: &str, minus_updates: bool) -> w::ListSection {
    w::ListSection {
        name: name.into(),
        title: name.to_uppercase(),
        search: w::SearchParams {
            query: String::new(),
            filters: w::Filters::default(),
            sort: None,
            offset: None,
            limit: None,
        },
        minus_updates,
    }
}

fn params(dense: bool) -> w::ListParams {
    w::ListParams {
        view: "extensions".into(),
        sections: vec![section("installed", true), section("updates", false)],
        dense,
        glyphs: vec![w::Glyph {
            kind: "package".into(),
            gui: "▣".into(),
            tty: "#".into(),
        }],
        restart: vec!["pkg:b".into()],
        generations: vec![],
    }
}

fn text(rows: &[Row], key: &str) -> String {
    rows.iter()
        .find(|r| r.key == key)
        .map(|r| r.text.clone())
        .unwrap_or_default()
}

/// A graphical class at scale 2: 16 px icons are 32 device px, the 6 px gap 12.
const GUI: Look = Look {
    gui: Some((32, 12)),
};

/// [D] On a graphical display a row's kind is the Explorer's kind of mark: a Lucide icon (`package` for a package and a
/// generation, `plug` for a plugin, `blocks` for a module) at the row's icon size, its glyph as the alt text, then the
/// gap, both in `shadow` (the icon's colour is the text's around it); each icon is sent once. A terminal keeps the ASCII
/// glyph and gets no image. The env's scale sizes them as `drgnx-px` does.
#[test]
fn extensions_kinds_are_lucide_icons_on_a_graphical_display() {
    let mut p = params(false);
    p.glyphs = ["package", "plugin", "module"]
        .iter()
        .map(|k| w::Glyph {
            kind: (*k).into(),
            gui: format!("g-{k}"),
            tty: format!("t-{k}"),
        })
        .collect();
    p.generations = vec![w::Generation {
        n: 2,
        time: String::new(),
        note: None,
        differs: vec![],
        in_use: false,
        current: true,
        size: None,
        copies: None,
    }];
    let mut plugin = row("plugin:p", w::State::On);
    plugin.kind = w::Kind::Plugin;
    let mut module = row("module:m", w::State::On);
    module.kind = w::Kind::Module;
    let (b, _) = build(
        &p,
        vec![
            (3, vec![row("pkg:a", w::State::Installed), plugin, module]),
            (0, vec![]),
        ],
    );
    let (rows, images) = rows(&b, GUI);
    let id = |n: &str| icons::svg(n, 32).unwrap().0;
    for (key, icon, alt) in [
        ("pkg:a", "package", "g-package"),
        ("plugin:p", "plug", "g-plugin"),
        ("module:m", "blocks", "g-module"),
        ("gen:2", "package", "g-package"),
    ] {
        let r = rows.iter().find(|r| r.key == key).unwrap();
        assert_eq!(r.images, vec![(0, id(icon), alt.to_owned())], "{key}");
        assert_eq!(r.spaces, vec![(1, 12, 32)], "{key}");
        assert!(
            r.runs.contains(&(0, 2, "shadow".to_owned())),
            "{key}: {:?}",
            r.runs
        );
    }
    let mut sent: Vec<_> = images.iter().map(|i| i.0).collect();
    sent.sort();
    let mut want = vec![id("package"), id("plug"), id("blocks")];
    want.sort();
    assert_eq!(sent, want);
    // the env's look: scale 1.25 rounds 16 px to 20 and 6 to 8 (half up); a terminal has none
    let env = |display, scale| ViewEnv {
        view: "extensions".into(),
        class: "c".into(),
        epoch: 1,
        display,
        scale,
        fonts: vec![],
        cell: (8, 16),
        width_px: 800,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
    };
    assert_eq!(Look::of(&env(Display::Gui, 1.25)).gui, Some((20, 8)));
    assert_eq!(Look::of(&env(Display::Tty, 1.0)), Look::TTY);
    let (tty, none) = super::rows(&b, Look::TTY);
    assert!(none.is_empty() && tty.iter().all(|r| r.images.is_empty()));
    assert_eq!(text(&tty, "plugin:p"), "t-plugin plugin:p 1.2  on");
}

/// Every column the list shows is in the hub's rows: the header's title and count, the glyph (the terminal's ASCII in
/// a tty class), the name, the version, the state's chip (the update's target), "restart to use", and the summary line
/// (summary, source, trust word) unless dense; each row's span names its id for the model and the commands. A row
/// with an update waits in Updates, not Installed, and is shown once.
#[test]
fn extensions_rows_carry_every_list_column() {
    let found = vec![
        (
            2,
            vec![
                row("pkg:a", w::State::Installed),
                row("pkg:b", w::State::Update),
            ],
        ),
        (1, vec![row("pkg:b", w::State::Update)]),
    ];
    let (b, totals) = build(&params(false), found.clone());
    assert_eq!(
        totals
            .iter()
            .map(|t| (t.name.as_str(), t.total, t.loaded))
            .collect::<Vec<_>>(),
        [("installed", 2, 2), ("updates", 1, 1)]
    );
    let (rows, _) = rows(&b, GUI);
    let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "section:installed",
            "pkg:a",
            "pkg:a/2",
            "section:updates",
            "pkg:b",
            "pkg:b/2"
        ]
    );
    assert_eq!(text(&rows, "section:installed"), "INSTALLED (1)");
    assert_eq!(text(&rows, "pkg:a"), "  a 1.2");
    assert_eq!(
        text(&rows, "pkg:b"),
        "  b 1.2  update to 1.3  restart to use"
    );
    assert_eq!(
        text(&rows, "pkg:b/2"),
        "    Does a thing · melpa · unsigned archive"
    );
    let b_row = rows.iter().find(|r| r.key == "pkg:b").unwrap();
    let props = serde_json::to_value(b_row).unwrap()["props"].clone();
    assert!(
        props
            .to_string()
            .contains(r#""drgnx-extensions-id","pkg:b""#),
        "{props}"
    );
    assert!(
        props.to_string().contains(r#""drgnx-work-id","pkg:b""#),
        "{props}"
    );
    let runs = serde_json::to_value(b_row).unwrap()["runs"].to_string();
    assert!(
        runs.contains("drgnx-status-warn") && runs.contains("bold") && runs.contains("shadow"),
        "{runs}"
    );
    // a terminal class: the glyph's ASCII form; dense: no summary lines
    let (dense, _) = build(&params(true), found);
    let (tty, images) = super::rows(&dense, Look::TTY);
    assert!(images.is_empty());
    assert_eq!(text(&tty, "pkg:a"), "# a 1.2");
    assert!(tty.iter().all(|r| !r.key.ends_with("/2")));
    // the model: a section node per header, a row node under it, the order the rows'
    let d = doc(&b);
    assert_eq!(
        d.lists["order"],
        ["section:installed", "pkg:a", "section:updates", "pkg:b"]
    );
    assert_eq!(d.nodes["pkg:b"]["parent"], "section:updates");
    assert!(
        d.nodes["pkg:b"]["fields"]
            .to_string()
            .contains(r#"["state","update"]"#)
    );
    // the row's name is its label, once: the model goes to the editor as one line, every byte of it a character there
    let fields = d.nodes["pkg:b"]["fields"].to_string();
    assert!(fields.contains(r#"["label","b"]"#), "{fields}");
    assert!(!fields.contains(r#"["name","#), "{fields}");
}

/// The Generations section: the editor sends the generations (it reads them from disk), the hub ends the list with a
/// header and a row per generation (number, time, note, in use or current, size), the differences and the copies
/// note as lines under it; each row's span names `gen:N`, and the model's node carries the `gen` the rollback reads.
#[test]
fn extensions_generations_end_the_list_with_their_gen() {
    let mut p = params(false);
    p.generations = vec![
        w::Generation {
            n: 4,
            time: "2026-11-12 10:00".into(),
            note: Some("update magit".into()),
            differs: vec!["magit 4.1 → 4.2".into()],
            in_use: false,
            current: true,
            size: Some("2k".into()),
            copies: Some("This file system copies the packages twice per change.".into()),
        },
        w::Generation {
            n: 3,
            time: "2026-11-11 09:00".into(),
            note: None,
            differs: vec![],
            in_use: true,
            current: false,
            size: None,
            copies: None,
        },
    ];
    let (b, _) = build(
        &p,
        vec![(1, vec![row("pkg:a", w::State::Installed)]), (0, vec![])],
    );
    let (rows, _) = rows(&b, GUI);
    let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "section:installed",
            "pkg:a",
            "pkg:a/2",
            "section:generations",
            "gen:4",
            "gen:4/2",
            "gen:4/3",
            "gen:3"
        ]
    );
    assert_eq!(text(&rows, "section:generations"), "Generations (2)");
    assert_eq!(
        text(&rows, "gen:4"),
        "  #4  2026-11-12 10:00  update magit  current  2k"
    );
    assert_eq!(text(&rows, "gen:4/2"), "    magit 4.1 → 4.2");
    assert_eq!(
        text(&rows, "gen:4/3"),
        "    This file system copies the packages twice per change."
    );
    assert_eq!(text(&rows, "gen:3"), "  #3  2026-11-11 09:00  in use");
    let props =
        serde_json::to_value(rows.iter().find(|r| r.key == "gen:4/2").unwrap()).unwrap()["props"]
            .to_string();
    assert!(props.contains(r#""drgnx-work-id","gen:4""#), "{props}");
    assert!(!props.contains("drgnx-extensions-id"), "{props}");
    let d = doc(&b);
    assert_eq!(
        d.lists["order"],
        [
            "section:installed",
            "pkg:a",
            "section:generations",
            "gen:4",
            "gen:3"
        ]
    );
    assert_eq!(d.nodes["gen:4"]["kind"], "generation");
    assert_eq!(d.nodes["gen:4"]["parent"], "section:generations");
    assert!(
        d.nodes["gen:4"]["fields"]
            .to_string()
            .contains(r#"["gen",4]"#)
    );
}
