//! The row and patch format: positions, runs, ids on the wire.

use drgnx_rows::{ImageId, Op, Patch, Row, RowBuilder};
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
