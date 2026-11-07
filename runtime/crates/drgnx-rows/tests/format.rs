//! The row and patch format: positions, runs, ids on the wire.

use drgnx_rows::{Colour, CursorShape, Face, ImageId, Op, Patch, Row, RowBuilder, Style, TermMeta};
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[test]
fn positions_are_scalar_indices() {
    // CJK, a ZWJ family emoji, a combining mark, Hebrew (RTL), each between ASCII
    for piece in [
        "漢字かな",
        "👨\u{200d}👩\u{200d}👧",
        "e\u{301}",
        "שָׁלוֹם",
        "abc",
    ] {
        let mut b = RowBuilder::new("k");
        b.push("x ", None)
            .push(piece, Some("drgnx-accent"))
            .push(" y", Some("drgnx-dim"));
        let r = b.finish();
        let n = |s: &str| u32::try_from(s.chars().count()).unwrap();
        assert_eq!(
            r.runs[0],
            (2, 2 + n(piece), "drgnx-accent".into()),
            "{piece}"
        );
        assert_eq!(r.runs[1].1, n(&r.text), "{piece}");
        // a run's ends cut the text where the pieces meet
        let cut: String = r.text.chars().skip(2).take(n(piece) as usize).collect();
        assert_eq!(cut, piece);
    }
}

#[test]
fn adjacent_equal_runs_merge() {
    let mut b = RowBuilder::new("k");
    b.push("ab", Some("f"))
        .push("cd", Some("f"))
        .push("e", None)
        .push("g", Some("f"))
        .push("h", Some("g"));
    let r = b.finish();
    assert_eq!(
        r.runs,
        vec![(0, 4, "f".into()), (5, 6, "f".into()), (6, 7, "g".into())]
    );
}

fn keys(v: &Value, out: &mut BTreeSet<String>) {
    match v {
        Value::Object(m) => {
            for (k, x) in m {
                out.insert(k.clone());
                keys(x, out);
            }
        }
        Value::Array(a) => a.iter().for_each(|x| keys(x, out)),
        _ => {}
    }
}

#[test]
fn ids_never_appear_as_object_keys() {
    let img = ImageId::of(b"<svg/>", 3);
    let mut b = RowBuilder::new("row-1");
    b.push("a", Some("f"))
        .prop(0, 1, "drgnx-work-id", json!("item-9"))
        .stop(40)
        .image(img, "*")
        .height(2, 18);
    let row = b.finish();
    let p = Patch {
        view: "view-1".into(),
        class: "gui-1".into(),
        hub: 7,
        base: 1,
        version: 2,
        env_epoch: 3,
        ops: vec![
            Op::Reset(vec![row.clone()]),
            Op::Insert {
                after: Some("row-1".into()),
                rows: vec![Row {
                    key: "row-2".into(),
                    ..row.clone()
                }],
            },
            Op::Replace(vec![row]),
            Op::Remove(vec!["row-2".into()]),
        ],
        images: [(img, "<svg/>".into())].into_iter().collect(),
        styles: vec![],
        term: None,
        model: None,
    };
    let v = serde_json::to_value(&p).unwrap();
    let mut found = BTreeSet::new();
    keys(&v, &mut found);
    let fixed: BTreeSet<String> = [
        "view",
        "class",
        "hub",
        "base",
        "version",
        "env_epoch",
        "ops",
        "images",
        "reset",
        "insert",
        "after",
        "rows",
        "replace",
        "remove",
        "key",
        "text",
        "runs",
        "props",
        "stops",
        "height",
        "lines",
        "unit",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    assert!(
        found.is_subset(&fixed),
        "keys that are not field names: {:?}",
        found.difference(&fixed).collect::<Vec<_>>()
    );
    // and it reads back
    assert_eq!(serde_json::from_value::<Patch>(v).unwrap(), p);
}

#[test]
fn image_id_changes_with_epoch() {
    let a = ImageId::of(b"<svg>a</svg>", 1);
    assert_eq!(a, ImageId::of(b"<svg>a</svg>", 1));
    assert_ne!(a, ImageId::of(b"<svg>a</svg>", 2));
    assert_ne!(a, ImageId::of(b"<svg>b</svg>", 1));
    let s = serde_json::to_value(a).unwrap();
    assert_ne!(
        s,
        serde_json::to_value(ImageId::of(b"<svg>a</svg>", 2)).unwrap()
    );
    assert_eq!(serde_json::from_value::<ImageId>(s).unwrap(), a);
}

/// A terminal patch: styles as `[[id, {...}]]`, colours as `{ansi}`/`{rgb}`/absent, the cursor as an array. Every
/// object key is a field name, never an id.
#[test]
fn styles_serialise_as_arrays() {
    let mut b = RowBuilder::new("41");
    b.push("ab", Some(&Face::Style(3).to_string()))
        .push("cd", Some(&Face::Style(12).to_string()));
    let p = Patch {
        view: "term-1".into(),
        class: "gui-1".into(),
        hub: 7,
        base: 1,
        version: 2,
        env_epoch: 1,
        ops: vec![Op::Insert {
            after: Some("40".into()),
            rows: vec![b.finish()],
        }],
        images: vec![],
        styles: vec![
            (
                3,
                Style {
                    fg: Colour::Ansi(1),
                    bold: true,
                    ..Style::default()
                },
            ),
            (
                12,
                Style {
                    bg: Colour::Rgb([0x0a, 0xb0, 0xff]),
                    ul_color: Colour::Ansi(9),
                    underline: true,
                    inverse: true,
                    ..Style::default()
                },
            ),
        ],
        term: Some(TermMeta {
            cursor: ("41".into(), 2, CursorShape::Bar, true),
            alt_screen: true,
            mouse_tracking: false,
            title: "vim".into(),
        }),
        model: None,
    };
    let v = serde_json::to_value(&p).unwrap();
    assert_eq!(
        v["styles"],
        json!([[3, {"fg": {"ansi": 1}, "bold": true}],
               [12, {"bg": {"rgb": "#0ab0ff"}, "ul_color": {"ansi": 9}, "underline": true, "inverse": true}]])
    );
    assert_eq!(
        v["term"],
        json!({"cursor": ["41", 2, "bar", true], "alt_screen": true, "mouse_tracking": false, "title": "vim"})
    );
    assert_eq!(
        v["ops"][0]["insert"]["rows"][0]["runs"],
        json!([[0, 2, "s:3"], [2, 4, "s:12"]])
    );
    let mut found = BTreeSet::new();
    keys(&v, &mut found);
    let fixed: BTreeSet<String> = [
        "view",
        "class",
        "hub",
        "base",
        "version",
        "env_epoch",
        "ops",
        "insert",
        "after",
        "rows",
        "key",
        "text",
        "runs",
        "styles",
        "fg",
        "bg",
        "ul_color",
        "bold",
        "faint",
        "italic",
        "underline",
        "strike",
        "inverse",
        "blink",
        "ansi",
        "rgb",
        "term",
        "cursor",
        "alt_screen",
        "mouse_tracking",
        "title",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    assert!(
        found.is_subset(&fixed),
        "keys that are not field names: {:?}",
        found.difference(&fixed).collect::<Vec<_>>()
    );
    assert_eq!(serde_json::from_value::<Patch>(v).unwrap(), p);
}

/// A run's face names a style as `s:<id>`; any other string stays a face name, and both survive the wire.
#[test]
fn style_run_round_trips() {
    let mut b = RowBuilder::new("1");
    b.push("x", Some(&Face::Style(4_000_000).to_string()))
        .push("y", Some("drgnx-dim"))
        .push("z", Some("s:"));
    let row = b.finish();
    let back: Row = serde_json::from_str(&serde_json::to_string(&row).unwrap()).unwrap();
    let faces: Vec<Face> = back.runs.iter().map(|r| Face::parse(&r.2)).collect();
    assert_eq!(
        faces,
        vec![
            Face::Style(4_000_000),
            Face::Named("drgnx-dim".into()),
            Face::Named("s:".into())
        ]
    );
    // every colour form reads back
    for c in [Colour::Ansi(15), Colour::Rgb([1, 2, 3]), Colour::Default] {
        let s = Style {
            fg: c,
            ..Style::default()
        };
        let v = serde_json::to_value(s).unwrap();
        assert_eq!(serde_json::from_value::<Style>(v).unwrap(), s, "{c:?}");
    }
}
