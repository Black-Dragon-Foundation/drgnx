//! The Work map's rows built in the hub (`vegvisir::render`), against the editor's own rows of the fixture frame
//! (`test/fixtures/work-space/rows-golden.eld`, drawn by `drgnx-work-map-row-text` at scale 1 with 8 px a column).
//! Pure: a fixed-advance measure, no fonts, no clock ([D]).

use std::collections::{BTreeMap, BTreeSet};

use drgnx_rows::fit::Measure;
use drgnx_rows::svg::Palette;
use drgnx_rows::{Op, Row};
use serde::Deserialize;
use vegvisir::layout::Layout;
use vegvisir::render::{self, Env, Index, Outline, Scene};
use vegvisir::{Edge, Item, ItemId};

/// 8 px a column, as a batch Emacs measures (`drgnx-view-text-width` on a terminal frame).
struct Cols;

impl Measure for Cols {
    fn advance(&self, _role: &str, ch: char) -> Option<f32> {
        Some(8.0 * drgnx_rows::fit_tty::char_width(ch, &[]) as f32)
    }
    fn fallback(&self, _role: &str) -> f32 {
        8.0
    }
}

#[derive(Deserialize)]
struct Frame {
    items: Vec<Item>,
    edges: Vec<Edge>,
    layout: Layout,
}

fn frame() -> (BTreeMap<ItemId, Item>, Vec<Edge>, Layout) {
    let f: Frame = serde_json::from_str(include_str!(
        "../../../../test/fixtures/work-space/frame.json"
    ))
    .expect("the fixture frame");
    let items = f.items.into_iter().map(|i| (i.id.clone(), i)).collect();
    (items, f.edges, f.layout)
}

fn gui(palette: &Palette) -> Env<'_> {
    Env {
        epoch: 1,
        scale: 1.0,
        tty: false,
        cell: (8, 16),
        width_px: 1000,
        palette,
        tty_widths: &[],
        line: (16, 80),
    }
}

fn scene<'a>(
    items: &'a BTreeMap<ItemId, Item>,
    edges: &'a [Edge],
    layout: &'a Layout,
    new: &'a BTreeSet<ItemId>,
) -> Scene<'a> {
    Scene {
        items,
        edges,
        layout,
        new,
        chain: &[],
        outline: Outline::Off,
        now: 0,
    }
}

/// A row as the golden shows it: a stop as `<PX>`, an image as `<img>`.
fn flat(r: &Row) -> String {
    let mut out = String::new();
    for (i, c) in r.text.chars().enumerate() {
        let i = u32::try_from(i).unwrap();
        if let Some((_, px)) = r.stops.iter().find(|s| s.0 == i) {
            out.push_str(&format!("<{px}>"));
        } else if r.images.iter().any(|m| m.0 == i) {
            out.push_str("<img>");
        } else {
            out.push(c);
        }
    }
    out
}

/// The text of layout row KEY (`row:L:B:S`): its lines' rows joined, each ending in a newline.
fn layout_row(rows: &[Row], key: &str) -> String {
    let prefix = format!("{key}:");
    rows.iter()
        .filter(|r| r.key.starts_with(&prefix))
        .map(|r| flat(r) + "\n")
        .collect()
}

/// [D] The rows with no lanes and no tiles are the editor's, character for character and stop for stop.
#[test]
fn golden_rows_of_the_fixture() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let golden = [
        ("row:1:0:0", "You asked<388>❝ fix deferred testin…<580>\n"),
        ("row:2:0:0", "Specs<420>◫ race-proof tests<596>\n"),
        ("row:3:0:0", "Plans<232>☰ deferred testing…<408>\n"),
        (
            "row:4:0:0",
            "Agents<84>● O  Opus · hub rows<316><328>● S  Sonnet · fx-sess<560>\n\
             <84>SESSION-END-LOSES-STARTED-1<316><328>review item 3<560>\n\
             <84>testing · 32 min · $1.20 ·…<316><328>needs you · 5 min<560>\n\
             <84>→ turn_core drops the star…<316><328>→ fixed in seq<560>\n\
             <84>⚠ shares files with Sonnet…<316><328>⚠ shares files with Opus ·…<560>\n",
        ),
        (
            "row:6:0:0",
            "Files<248>▭ session.rs · …<392><404>▣ desktop · 3…<532>\n",
        ),
    ];
    for (key, want) in golden {
        assert_eq!(layout_row(&drawn.rows, key), want, "row {key}");
    }
    // each line names its item, and has its height
    let a1 = drawn
        .rows
        .iter()
        .find(|r| r.key == "row:4:0:0:0")
        .expect("the agents' first line");
    let at = u32::try_from(a1.text.chars().position(|c| c == 'h').unwrap()).unwrap();
    assert!(
        a1.props
            .iter()
            .any(|(s, e, n, v)| n == "drgnx-work-id" && v == "agent:a1" && *s <= at && at < *e),
        "{a1:?}"
    );
    assert!(
        drawn.rows.iter().all(|r| r.height.is_some()),
        "every line has its height"
    );
    // the rows come in y order, each band above its row
    let keys: Vec<&str> = drawn.rows.iter().map(|r| r.key.as_str()).collect();
    let pos = |k: &str| {
        keys.iter()
            .position(|x| *x == k)
            .unwrap_or_else(|| panic!("{k} in {keys:?}"))
    };
    assert!(pos("band:2:0:0") < pos("row:2:0:0:0"));
    assert!(pos("row:5:0:0:0") < pos("band:4:0:1") && pos("band:4:0:1") < pos("row:4:0:1:0"));
}

/// [D] The layer labels: the name on its layer's first row only, a collapsed layer's with its count; the index the
/// rows are built from is made once per layout and only read per row.
#[test]
fn layer_labels_sorted_once() {
    let (items, edges, mut layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let env = gui(&palette);
    let s = scene(&items, &edges, &layout, &new);
    let index = Index::of(&s);
    let a = render::rows(&s, &index, &env, &Cols);
    let b = render::rows(&s, &index, &env, &Cols);
    assert_eq!(a.rows, b.rows, "the same index draws the same rows");
    let label = |rows: &[Row], key: &str| -> String {
        let r = rows
            .iter()
            .find(|r| r.key == key)
            .unwrap_or_else(|| panic!("{key}"));
        flat(r).split('<').next().unwrap_or("").to_owned()
    };
    assert_eq!(label(&a.rows, "row:4:0:0:0"), "Agents");
    assert_eq!(label(&a.rows, "row:4:0:0:1"), "", "only the first line");
    assert_eq!(
        label(&a.rows, "row:4:0:1:0"),
        "",
        "only the layer's first row"
    );
    // the files layer collapsed: one thin row, its name with the count of its items
    for r in layout.rows.iter_mut().filter(|r| r.layer == 6) {
        r.collapsed = true;
    }
    layout
        .at
        .retain(|id, _| !matches!(id.kind().map(|k| k.layer()), Some(6)));
    let s = scene(&items, &edges, &layout, &new);
    let c = render::rows(&s, &Index::of(&s), &env, &Cols);
    assert_eq!(label(&c.rows, "row:6:0:0:0"), "Files · 2");
}

/// [D] A card that changed its width changes only its own lines: the diff is one replace of them, and a width the
/// layout did not change changes nothing.
#[test]
fn width_change_replaces_only_rows_whose_fit_changed() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let env = gui(&palette);
    let s = scene(&items, &edges, &layout, &new);
    let before = render::rows(&s, &Index::of(&s), &env, &Cols).rows;
    assert!(!before.is_empty());
    let wider = Env {
        width_px: 1400,
        ..gui(&palette)
    };
    let same = render::rows(&s, &Index::of(&s), &wider, &Cols).rows;
    assert!(
        drgnx_rows::diff(&before, &same).is_empty(),
        "the layout's units hold the width"
    );
    let mut narrow = layout.clone();
    narrow.at.get_mut(&ItemId("agent:a2".into())).unwrap().w = 40;
    let s = scene(&items, &edges, &narrow, &new);
    let after = render::rows(&s, &Index::of(&s), &env, &Cols).rows;
    match drgnx_rows::diff(&before, &after).as_slice() {
        [Op::Replace(rows)] => {
            let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
            assert_eq!(
                keys,
                [
                    "row:4:0:0:0",
                    "row:4:0:0:1",
                    "row:4:0:0:2",
                    "row:4:0:0:3",
                    "row:4:0:0:4"
                ]
            );
        }
        ops => panic!("one replace of the agents' lines: {ops:?}"),
    }
}

/// [D] A terminal's map is the outline: a block per agent, each line within the columns.
#[test]
fn tty_outline_rows() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    for cols in [80u32, 120] {
        let env = Env {
            tty: true,
            cell: (1, 1),
            width_px: cols,
            ..gui(&palette)
        };
        let s = Scene {
            outline: Outline::Auto,
            ..scene(&items, &edges, &layout, &new)
        };
        let drawn = render::rows(&s, &Index::of(&s), &env, &Cols);
        let lines: Vec<&str> = drawn.rows.iter().map(|r| r.text.as_str()).collect();
        assert!(!lines.is_empty());
        for l in &lines {
            assert!(
                drgnx_rows::fit_tty::width(l, &[]) <= cols as usize,
                "{l:?} in {cols}"
            );
        }
        assert!(
            drawn.rows.iter().all(|r| r.key.starts_with("outline:")),
            "{:?}",
            drawn.rows
        );
        assert!(
            lines.iter().any(|l| l.starts_with("● Opus · hub rows")),
            "{lines:?}"
        );
        assert!(
            lines
                .iter()
                .any(|l| l.starts_with("   why:      you: \"fix deferred testing rows\""))
        );
        assert!(
            lines
                .iter()
                .any(|l| l.starts_with("   touches:  ") && l.contains("rp-df-hub"))
        );
        assert!(
            lines
                .iter()
                .any(|l| l.contains("turn_core drops the started flag"))
        );
        assert!(drawn.images.is_empty());
    }
}
