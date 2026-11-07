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
use vegvisir::{Edge, EdgeKind, Item, ItemId, NeedsYou};

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
    #[serde(default)]
    needs_you: Vec<NeedsYou>,
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

/// The palette a test draws with: one distinct colour per role.
fn palette() -> Palette {
    let roles = [
        "edge", "edit", "accent", "warn", "chip-bg", "chip-fg", "agent-1", "agent-2", "agent-3",
        "agent-4", "agent-5", "agent-6",
    ];
    Palette(
        roles
            .iter()
            .enumerate()
            .map(|(i, r)| ((*r).to_owned(), format!("#00{i:02}00")))
            .collect(),
    )
}

/// [D] Every row of the fixture frame, bands and lanes included, is the editor's; lanes at one column of a row are
/// one image whose words name them all.
#[test]
fn lanes_on_one_column_are_one_image() {
    let (items, edges, mut layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&pal), &Cols);
    let golden = [
        ("band:2:0:0", "<384><img>"),
        ("band:3:0:0", "<192><img><384><img>"),
        ("band:4:0:0", "<192><img><384><img>"),
        ("band:5:0:0", "<0><img><192><img><384><img>"),
        ("band:4:0:1", "<0><img><192><img><384><img>"),
        ("band:6:0:0", "<192><img><384><img>"),
    ];
    for (key, want) in golden {
        let r = drawn
            .rows
            .iter()
            .find(|r| r.key == key)
            .unwrap_or_else(|| panic!("{key}"));
        assert_eq!(flat(r), want, "{key}");
    }
    assert_eq!(
        layout_row(&drawn.rows, "row:5:0:0"),
        "Branches<99><img><120>⑂ rp-df-hub · edi…<280><364>⑂ rp-fx-sess · ed…<524>\n"
    );
    assert_eq!(
        layout_row(&drawn.rows, "row:4:0:1"),
        "<116>● O explore<284><291><img><403><img>\n<116>running 2m<284><291><img><403><img>\n"
    );
    // every image a row names is drawn
    for r in &drawn.rows {
        for (_, id, _) in &r.images {
            assert!(
                drawn.images.iter().any(|(i, _)| i == id),
                "{id:?} of {}",
                r.key
            );
        }
    }
    // a second lane at the first one's column: still one image a line, naming both
    let mut extra = layout.lanes[1].clone();
    extra.kind = EdgeKind::Reads;
    extra.from = ItemId("agent:a1".into());
    layout.lanes.push(extra);
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&pal), &Cols);
    let line = drawn
        .rows
        .iter()
        .find(|r| r.key == "row:4:0:1:0")
        .expect("the subagent's line");
    assert_eq!(
        line.images.len(),
        2,
        "two columns, one image each: {line:?}"
    );
    let alt = &line.images[0].2;
    assert!(
        alt.contains("(edits)") && alt.contains("(reads)") && alt.contains("; "),
        "{alt}"
    );
}

/// [D] A tile that draws the same strokes is the same image: the same id across draws, sent once.
#[test]
fn tiles_are_image_ids_reused_across_draws() {
    let (items, edges, mut layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let a = render::rows(&s, &Index::of(&s), &gui(&pal), &Cols);
    let b = render::rows(&s, &Index::of(&s), &gui(&pal), &Cols);
    assert!(!a.images.is_empty());
    assert_eq!(a.images, b.images, "the same draw, the same images");
    let ids = |d: &render::Drawn| d.images.iter().map(|i| i.0).collect::<BTreeSet<_>>();
    let mut uniq = ids(&a);
    assert_eq!(uniq.len(), a.images.len(), "each image once");
    // a card's field changes: no tile changes
    let mut items2 = items.clone();
    items2
        .get_mut(&ItemId("agent:a1".into()))
        .unwrap()
        .fields
        .minutes = Some(33);
    let s = scene(&items2, &edges, &layout, &new);
    assert_eq!(
        ids(&render::rows(&s, &Index::of(&s), &gui(&pal), &Cols)),
        uniq
    );
    // one band's curve moves: only that band's tiles are new
    layout.bands[0].segs[0].x1 += 4;
    let s = scene(&items, &edges, &layout, &new);
    let moved = ids(&render::rows(&s, &Index::of(&s), &gui(&pal), &Cols));
    let fresh: Vec<_> = moved.difference(&uniq).collect();
    assert_eq!(fresh.len(), 1, "one tile of the moved band: {fresh:?}");
    uniq.retain(|i| moved.contains(i));
    assert_eq!(uniq.len(), a.images.len() - 1);
}

/// [D] The needs-you strip: a chip with its jump key per entry (nine at most, then +N), the machines' load at the
/// right edge.
#[test]
fn strip_chips_rows() {
    let f: Frame = serde_json::from_str(include_str!(
        "../../../../test/fixtures/work-space/frame.json"
    ))
    .unwrap();
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let machines: Vec<Item> = items
        .values()
        .filter(|i| i.id.0.starts_with("machine:"))
        .cloned()
        .collect();
    let row = render::strip(&s, &f.needs_you, &machines, &gui(&pal), &Cols);
    assert_eq!(row.key, "strip");
    assert!(
        row.text.contains("⚑ Codex asks: cargo clippy  g1"),
        "{row:?}"
    );
    assert!(row.text.contains("desktop 3/16"), "{row:?}");
    // the card covers the agent that needs you: no chip of its own
    assert!(!row.text.contains("fx-sess needs you"), "{row:?}");
    assert!(row.runs.iter().any(|r| r.2 == "drgnx-work-needs-you"));
    assert!(row.runs.iter().any(|r| r.2 == "drgnx-work-chip"));
    // the machines' chips end at the right edge
    let (pos, px) = *row.stops.last().expect("a stop before the machines");
    let tail: String = row.text.chars().skip(pos as usize + 1).collect();
    assert_eq!(px + 8 * tail.chars().count() as u32, 1000, "{tail:?}");
    // more than nine: the first nine and +N
    let many: Vec<NeedsYou> = (0..12)
        .map(|i| NeedsYou {
            about: vec![],
            text: format!("ask {i}"),
            ..f.needs_you[0].clone()
        })
        .collect();
    let row = render::strip(&s, &many, &machines, &gui(&pal), &Cols);
    assert!(
        row.text.contains("g9") && !row.text.contains("g10") && row.text.contains("+4"),
        "{}",
        row.text
    );
}

/// [D] A new env epoch (a theme) gives every image a new id: no old tile is reused.
#[test]
fn theme_epoch_changes_tile_ids() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let one = render::rows(&s, &Index::of(&s), &gui(&pal), &Cols);
    let two = render::rows(
        &s,
        &Index::of(&s),
        &Env {
            epoch: 2,
            ..gui(&pal)
        },
        &Cols,
    );
    assert!(!one.images.is_empty());
    assert!(one.images.iter().all(|(i, _)| i.epoch == 1));
    assert!(two.images.iter().all(|(i, _)| i.epoch == 2));
    let a: BTreeSet<u64> = one.images.iter().map(|i| i.0.hash).collect();
    let b: BTreeSet<u64> = two.images.iter().map(|i| i.0.hash).collect();
    assert_eq!(a, b, "the same strokes");
}

/// [D] The map's lanes and tiles take every colour from the env's palette.
#[test]
fn svg_has_no_colour_outside_the_palette() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    // the selection's chain too: the accent and an agent's colour
    let chain: Vec<Edge> = edges.clone();
    let s = Scene {
        chain: &chain,
        ..scene(&items, &edges, &layout, &new)
    };
    let drawn = render::rows(&s, &Index::of(&s), &gui(&pal), &Cols);
    let allowed: BTreeSet<&str> = pal
        .0
        .iter()
        .map(|(_, c)| c.as_str())
        .chain(["none", "currentColor"])
        .collect();
    let mut seen = BTreeSet::new();
    for (_, svg) in &drawn.images {
        for attr in ["fill=\"", "stroke=\""] {
            for (i, _) in svg.match_indices(attr) {
                let v = &svg[i + attr.len()..];
                let v = &v[..v.find('"').unwrap()];
                assert!(allowed.contains(v), "{v} in {svg}");
                seen.insert(v.to_owned());
            }
        }
    }
    assert!(seen.contains("#000200"), "the chain's accent: {seen:?}");
    assert!(seen.len() >= 3, "{seen:?}");
}
