//! The Work map's rows built in the hub (`vegvisir::render`), against the editor's former rows of the fixture frame
//! (`test/fixtures/work-space/rows-golden.eld`, recorded from its Lisp drawing at scale 1 with 8 px a column).
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
        selected: None,
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

/// [D] The rows with no lanes and no tiles are the editor's, character for character and stop for stop (a chip's icon is an image, one placeholder character, since the Lucide icons).
#[test]
fn golden_rows_of_the_fixture() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let golden = [
        (
            "row:1:0:0",
            "You asked<388><img> fix deferred testi…<580>\n",
        ),
        ("row:2:0:0", "Specs<420><img> race-proof tests<596>\n"),
        ("row:3:0:0", "Plans<232><img> deferred testing…<408>\n"),
        (
            "row:4:0:0",
            "Agents<84>●  O  Opus · hub rows<316><328>●  S  Sonnet · fx-sess<560>\n\
             <84>SESSION-END-LOSES-STARTED-1<316><328>review item 3<560>\n\
             <84>testing · 32 min · $1.20 ·…<316><328>needs you · 5 min<560>\n\
             <84>→ turn_core drops the star…<316><328>→ fixed in seq<560>\n\
             <84>⚠ shares files with Sonnet…<316><328>⚠ shares files with Opus ·…<560>\n",
        ),
        (
            "row:6:0:0",
            "Files<248><img> session.rs +…<392><404><img> desktop 3/…<532>\n",
        ),
    ];
    let bad: Vec<String> = golden
        .iter()
        .filter(|(key, want)| layout_row(&drawn.rows, key) != *want)
        .map(|(key, _)| format!("{key}: {:?}", layout_row(&drawn.rows, key)))
        .collect();
    assert!(bad.is_empty(), "{bad:#?}");
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
            selected: None,
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
        "Branches<99><img><120><img> rp-df-hub · ed…<280><364><img> rp-fx-sess · e…<524>\n"
    );
    assert_eq!(
        layout_row(&drawn.rows, "row:4:0:1"),
        "<116>●  O  explore<284><291><img><403><img>\n<116>running 2m<284><291><img><403><img>\n"
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
    let row = render::strip(&s, &f.needs_you, &machines, &[], &gui(&pal), &Cols).0;
    assert_eq!(row.key, "strip");
    assert!(
        row.text.contains("⚑ Codex asks: cargo clippy  g1"),
        "{row:?}"
    );
    assert!(row.text.contains("desk 3/16"), "{row:?}");
    // the card covers the agent that needs you: no chip of its own
    assert!(!row.text.contains("fx-sess needs you"), "{row:?}");
    assert!(row.runs.iter().any(|r| r.2 == "drgnx-work-needs-you"));
    assert!(row.runs.iter().any(|r| r.2 == "drgnx-work-chip"));
    // the machines' chips end at the right edge
    let (pos, px) = *row.stops.last().expect("a stop before the machines");
    let tail: String = row.text.chars().skip(pos as usize + 1).collect();
    // each chip's icon is 16 px in the one character of its placeholder (8 px here)
    let icons = row.images.iter().filter(|i| i.0 > pos).count() as u32;
    assert_eq!(
        px + 8 * tail.chars().count() as u32 + 8 * icons,
        1000,
        "{tail:?}"
    );
    // more than nine: the first nine and +N
    let many: Vec<NeedsYou> = (0..12)
        .map(|i| NeedsYou {
            about: vec![],
            text: format!("ask {i}"),
            ..f.needs_you[0].clone()
        })
        .collect();
    let row = render::strip(&s, &many, &machines, &[], &gui(&pal), &Cols).0;
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

/// [D] A card's text is drawn in the UI font, its meta line in the code font (work-space-dark.html: the title, task
/// and conclusion in Inter, "testing · 32 min · $1.20" in mono): every card line carries `drgnx-work-card` under the
/// card's box face, the agent's name `drgnx-work-title` and the line of its minutes and spend `drgnx-work-meta`.
#[test]
fn card_text_names_the_ui_font_the_title_and_the_meta_line() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let faces_at = |key: &str, word: &str| -> Vec<String> {
        let r = drawn.rows.iter().find(|r| r.key == key).expect(key);
        let at = r
            .text
            .find(word)
            .unwrap_or_else(|| panic!("{word} in {:?}", r.text));
        let at = u32::try_from(r.text[..at].chars().count()).unwrap();
        r.runs
            .iter()
            .filter(|(s, e, _)| *s <= at && at < *e)
            .map(|(_, _, f)| f.clone())
            .collect()
    };
    for (key, word) in [
        ("row:4:0:0:0", "Opus"),
        ("row:4:0:0:1", "SESSION"),
        ("row:4:0:0:2", "testing"),
        ("row:4:0:0:3", "turn_core"),
        ("row:3:0:0:0", "deferred"),
    ] {
        let faces = faces_at(key, word);
        assert!(
            faces.iter().any(|f| f == "drgnx-work-card"),
            "{key}: {faces:?}"
        );
    }
    assert!(
        faces_at("row:4:0:0:0", "Opus")
            .iter()
            .any(|f| f == "drgnx-work-title")
    );
    assert!(
        faces_at("row:4:0:0:2", "testing")
            .iter()
            .any(|f| f == "drgnx-text-muted")
    );
    // the numbers of the going line are the code font, the words the UI font (work-space-dark.html `.meta2 .n`)
    assert!(
        faces_at("row:4:0:0:2", "32")
            .iter()
            .any(|f| f == "drgnx-work-meta")
    );
}

/// [D] An agent whose label already names its model ("Opus · hub rows": the model's own label for a session with a
/// model) is drawn with the model once, not "Opus · Opus · hub rows".
#[test]
fn a_label_that_names_the_model_is_not_prefixed_with_it_again() {
    let (mut items, edges, layout) = frame();
    let id = ItemId("agent:a1".into());
    let a = items.get_mut(&id).expect("the first agent");
    let model = a.fields.model.clone().expect("it has a model");
    a.label = format!("{model} · hub rows");
    let new = BTreeSet::new();
    let palette = Palette::default();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let line = drawn
        .rows
        .iter()
        .find(|r| r.key == "row:4:0:0:0")
        .expect("the agents' first line");
    assert!(
        line.text.contains(&format!("{model} · hub")),
        "{:?}",
        line.text
    );
    assert!(
        !line.text.contains(&format!("{model} · {model}")),
        "{:?}",
        line.text
    );
}

/// [D] The strip is drawn in the UI font, and a long entry is cut with an ellipsis at a chip's own width (260 px), so
/// the entries after it and the machines' load at the right edge stay on the line (work-space-dark.html).
#[test]
fn a_long_strip_entry_is_cut_and_the_row_is_ui_text() {
    let f: Frame = serde_json::from_str(include_str!(
        "../../../../test/fixtures/work-space/frame.json"
    ))
    .unwrap();
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let long: Vec<NeedsYou> = vec![NeedsYou {
        about: vec![],
        text: "the gates hold the merge: no red for its test commit, and then some more words"
            .into(),
        ..f.needs_you[0].clone()
    }];
    let row = render::strip(&s, &long, &[], &[], &gui(&pal), &Cols).0;
    assert!(row.text.contains("…  g1"), "{:?}", row.text);
    assert!(!row.text.contains("some more words"), "{:?}", row.text);
    let end = u32::try_from(row.text.chars().count()).unwrap();
    assert!(
        row.runs
            .iter()
            .any(|r| r.0 == 0 && r.1 >= end - 1 && r.2 == "drgnx-work-card"),
        "{:?}",
        row.runs
    );
}

/// [D] A chip's glyph is a Lucide icon (etc/icons) in an image of its own, one placeholder character where the glyph
/// was, in the palette's colour at 1.6 stroke, and the text after it is fitted to what is left.
#[test]
fn a_chip_has_a_lucide_icon_image() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette(vec![("chip-fg".into(), "#a2a5b2".into())]);
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let ask = drawn
        .rows
        .iter()
        .find(|r| r.key == "row:1:0:0:0")
        .expect("the asks' row");
    assert_eq!(ask.images.len(), 1, "{ask:?}");
    let svg = drawn
        .images
        .iter()
        .find(|(id, _)| *id == ask.images[0].1)
        .map(|(_, s)| s.as_str())
        .expect("its image");
    assert!(svg.contains("M22 17a2 2 0 0 1-2 2H6.828"), "{svg}");
    assert!(
        svg.contains("stroke=\"#a2a5b2\"") && svg.contains("stroke-width=\"1.6\""),
        "{svg}"
    );
    assert!(!ask.text.contains('❝'), "{:?}", ask.text);
    // a tile of the strip's: a machine takes a monitor, a laptop its own
    let machine = drawn
        .rows
        .iter()
        .find(|r| r.key.starts_with("row:6:") && r.text.contains("desk"))
        .expect("the machines' row");
    assert!(!machine.images.is_empty(), "{machine:?}");
}

/// [D] The selected card is drawn in its own ring faces (the accent ring of work-space-dark.html), the others in the
/// plain ones: the hub knows the selection, and the editor only inserts.
#[test]
fn the_selected_card_has_its_own_ring_faces() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let pick = ItemId("agent:a1".into());
    let mut s = scene(&items, &edges, &layout, &new);
    s.selected = Some(&pick);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let faces = |key: &str, word: &str| -> Vec<String> {
        let r = drawn.rows.iter().find(|r| r.key == key).expect(key);
        let at = r
            .text
            .find(word)
            .unwrap_or_else(|| panic!("{word} in {:?}", r.text));
        let at = u32::try_from(r.text[..at].chars().count()).unwrap();
        r.runs
            .iter()
            .filter(|(s, e, _)| *s <= at && at < *e)
            .map(|(_, _, f)| f.clone())
            .collect()
    };
    assert!(faces("row:4:0:0:0", "Opus").contains(&"drgnx-card-sel-top".to_owned()));
    assert!(faces("row:4:0:0:2", "testing").contains(&"drgnx-card-sel-mid".to_owned()));
    assert!(faces("row:4:0:0:4", "shares").contains(&"drgnx-card-sel-bottom".to_owned()));
    assert!(faces("row:4:0:0:0", "Sonnet").contains(&"drgnx-card-top".to_owned()));
    assert!(faces("row:3:0:0:0", "deferred").contains(&"drgnx-card-single".to_owned()));
}

/// [D] The strip carries the forecast and cost chips before the machines' (work-space-dark.html: "wk 41 % ▲ Thu",
/// "$31 / $40", "desk 3/16"), all at the right edge.
#[test]
fn the_strip_has_the_forecast_and_cost_chips_before_the_machines() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let machines: Vec<Item> = items
        .values()
        .filter(|i| i.id.0.starts_with("machine:"))
        .cloned()
        .collect();
    let extra = vec!["wk 41 % ▲ Thu".to_owned(), "$31 / $40".to_owned()];
    let row = render::strip(&s, &[], &machines, &extra, &gui(&pal), &Cols).0;
    let wk = row.text.find("wk 41 % ▲ Thu").expect("the forecast chip");
    let cost = row.text.find("$31 / $40").expect("the cost chip");
    let desk = row.text.find("desk 3/16").expect("a machine");
    assert!(wk < cost && cost < desk, "{:?}", row.text);
}

/// [D] With a selection, the items off its chain are drawn dim (`drgnx-work-dim` under their own faces), the selected
/// one and those on its chain are not (work-space-dark.html: the rest muted).
#[test]
fn items_off_the_selections_chain_are_dim() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let pick = ItemId("agent:a1".into());
    let mut s = scene(&items, &edges, &layout, &new);
    s.selected = Some(&pick);
    // the chain: the selection's own edges only (what it came from and what it touches)
    let chain: Vec<Edge> = edges
        .iter()
        .filter(|e| e.kind == EdgeKind::CameFrom && (e.from == pick || e.to == pick))
        .cloned()
        .collect();
    s.chain = &chain;
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let dim = |key: &str, word: &str| -> bool {
        let r = drawn.rows.iter().find(|r| r.key == key).expect(key);
        let at = r
            .text
            .find(word)
            .unwrap_or_else(|| panic!("{word} in {:?}", r.text));
        let at = u32::try_from(r.text[..at].chars().count()).unwrap();
        r.runs
            .iter()
            .any(|(s, e, f)| *s <= at && at < *e && f == "drgnx-work-dim")
    };
    assert!(!dim("row:4:0:0:0", "Opus"), "the selected agent is lit");
    assert!(
        dim("row:4:0:0:0", "Sonnet"),
        "an agent off the chain is dim"
    );
    // with no selection nothing is dim
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    assert!(
        drawn
            .rows
            .iter()
            .all(|r| r.runs.iter().all(|x| x.2 != "drgnx-work-dim"))
    );
}

/// [D] A branch's chip shows the tag of the machine its agent runs on (`desk 3`) in a chip of its own, in place of
/// its edits count (work-space-dark.html: "rp-df-hub  [desk 3]").
#[test]
fn a_branch_chip_shows_its_machine_tag() {
    let (mut items, edges, layout) = frame();
    let id = ItemId("branch:drgnx/rp-df-hub".into());
    let branch = items.get_mut(&id).expect("the branch");
    branch.fields.tag = Some("desk 3".into());
    branch.label = "rp-a".into(); // short enough for the 8 px column measure
    let new = BTreeSet::new();
    let palette = Palette::default();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let row = drawn
        .rows
        .iter()
        .find(|r| r.key.starts_with("row:5:") && r.text.contains("rp-a"))
        .expect("the branches' row");
    assert!(row.text.contains("desk 3"), "{:?}", row.text);
    assert!(!row.text.contains("edits 2"), "{:?}", row.text);
    assert!(row.runs.iter().any(|r| r.2 == "drgnx-work-chip"), "{row:?}");
}

/// [D] A machine's chip on the strip starts with its Lucide icon (a monitor, a laptop for "laptop") in an image of its
/// own, in the palette's colour, and the strip names the images it uses (work-space-dark.html: "desk 3/16").
#[test]
fn a_machine_chip_on_the_strip_has_its_icon() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let pal = palette();
    let s = scene(&items, &edges, &layout, &new);
    let machines: Vec<Item> = items
        .values()
        .filter(|i| i.id.0.starts_with("machine:"))
        .cloned()
        .collect();
    let (row, images) = render::strip(&s, &[], &machines, &[], &gui(&pal), &Cols);
    assert_eq!(row.images.len(), machines.len(), "{row:?}");
    assert!(!images.is_empty());
    let svg = images
        .iter()
        .find(|(id, _)| *id == row.images[0].1)
        .map(|(_, s)| s.as_str())
        .expect("its image");
    assert!(svg.contains("<svg") && svg.contains("stroke=\""), "{svg}");
}

/// [D] A file's chip shows its name and its change in the added and removed colours (`session.rs +40 −3`), a machine's
/// its own name (only the strip abbreviates), an agent's initial sits in a filled circle of its colour.
#[test]
fn chips_show_the_file_name_and_its_change_and_the_badge_is_a_circle() {
    let (items, edges, layout) = frame();
    let new = BTreeSet::new();
    let palette = Palette::default();
    let s = scene(&items, &edges, &layout, &new);
    let drawn = render::rows(&s, &Index::of(&s), &gui(&palette), &Cols);
    let files = drawn
        .rows
        .iter()
        .find(|r| r.key == "row:6:0:0:0")
        .expect("files");
    assert!(files.text.contains("session.rs"), "{files:?}");
    assert!(!files.text.contains("crates/"), "{files:?}");
    assert!(
        files.runs.iter().any(|r| r.2 == "drgnx-work-plus"),
        "{files:?}"
    );
    assert!(files.text.contains("desktop 3/"), "{files:?}");
    assert!(!files.text.contains("desk "), "{files:?}");
    let agent = drawn
        .rows
        .iter()
        .find(|r| r.key == "row:4:0:0:0")
        .expect("agents");
    assert!(
        agent
            .runs
            .iter()
            .any(|r| r.2.starts_with("drgnx-work-who-")),
        "{agent:?}"
    );
}
