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
    }
}

fn text(rows: &[Row], key: &str) -> String {
    rows.iter()
        .find(|r| r.key == key)
        .map(|r| r.text.clone())
        .unwrap_or_default()
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
    let rows = rows(&b, Display::Gui);
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
    assert_eq!(text(&rows, "pkg:a"), "▣ a 1.2");
    assert_eq!(
        text(&rows, "pkg:b"),
        "▣ b 1.2  update to 1.3  restart to use"
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
    let tty = super::rows(&dense, Display::Tty);
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
}
