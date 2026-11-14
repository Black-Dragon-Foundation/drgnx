//! The heap graph's layout: cards in cells, edges as polylines between them.
use super::heap::{Field, Graph, Node};
use super::heap_layout::{self, Layout};

fn n(id: &str, ty: &str, fields: &[(&str, &str, Option<&str>)]) -> Node {
    Node {
        id: id.into(),
        ty: ty.into(),
        path: id.into(),
        fields: fields
            .iter()
            .map(|(name, value, to)| Field {
                name: (*name).into(),
                value: (*value).into(),
                to: to.map(str::to_owned),
                cut: None,
            })
            .collect(),
    }
}

/// a → b → c → a, `shared` = b.
fn ring() -> Graph {
    Graph {
        roots: vec![
            ("a".into(), Some("A".into())),
            ("b".into(), Some("B".into())),
            ("c".into(), Some("C".into())),
            ("shared".into(), Some("B".into())),
        ],
        nodes: vec![
            n(
                "A",
                "Node",
                &[("v", "1", None), ("next", "Node", Some("B"))],
            ),
            n(
                "B",
                "Node",
                &[("v", "2", None), ("next", "Node", Some("C"))],
            ),
            n(
                "C",
                "Node",
                &[("v", "3", None), ("next", "Node", Some("A"))],
            ),
        ],
        cut: 0,
    }
}

fn overlap(l: &Layout) -> Option<(String, String)> {
    for (i, a) in l.cards.iter().enumerate() {
        for b in &l.cards[i + 1..] {
            // one free cell between cards at least
            let apart = a.col + a.width < b.col
                || b.col + b.width < a.col
                || a.row + a.height < b.row
                || b.row + b.height < a.row;
            if !apart {
                return Some((a.id.clone(), b.id.clone()));
            }
        }
    }
    None
}

#[test]
fn each_object_is_a_card_sized_to_its_rows() {
    let l = heap_layout::layout(&ring(), None);
    assert_eq!(l.cards.len(), 3);
    let a = l.card("A").unwrap();
    // the type row, then one row per field
    assert_eq!(a.height, 3);
    // the widest row ("next  Node") plus a cell of padding each side
    assert!(a.width >= "next  Node".len() as u32 + 2, "{a:?}");
    assert_eq!(overlap(&l), None, "{l:#?}");
    assert!(
        l.cards
            .iter()
            .all(|c| c.col + c.width <= l.width && c.row + c.height <= l.height)
    );
}

#[test]
fn references_go_left_to_right_by_depth_from_the_roots() {
    // one root (Show as Graph on `a`): a, then b, then c
    let mut g = ring();
    g.roots.truncate(1);
    let l = heap_layout::layout(&g, None);
    let (a, b, c) = (
        l.card("A").unwrap(),
        l.card("B").unwrap(),
        l.card("C").unwrap(),
    );
    assert!(a.col < b.col && b.col < c.col, "{l:#?}");
    // every root is in the first layer
    let all = heap_layout::layout(&ring(), None);
    assert!(
        all.cards.iter().all(|c| c.col == all.cards[0].col),
        "{all:#?}"
    );
}

#[test]
fn an_edge_leaves_its_fields_row_and_enters_its_cards_top_row() {
    let l = heap_layout::layout(&ring(), None);
    assert_eq!(l.edges.len(), 3, "{l:#?}");
    for e in &l.edges {
        let (from, to) = (l.card(&e.from).unwrap(), l.card(&e.to).unwrap());
        let (s, t) = (e.points[0], *e.points.last().unwrap());
        assert_eq!(
            s,
            (from.col + from.width, from.row + 1 + e.field),
            "{e:?} from {from:?}"
        );
        assert_eq!(t, (to.col, to.row), "{e:?} into {to:?}");
        // straight runs only (Glitnir rounds the bends)
        for w in e.points.windows(2) {
            assert!(w[0].0 == w[1].0 || w[0].1 == w[1].1, "a diagonal in {e:?}");
        }
    }
}

#[test]
fn a_back_edge_goes_round_above_the_cards() {
    let l = heap_layout::layout(&ring(), None);
    let back = l.edges.iter().find(|e| e.from == "C").unwrap();
    let top = l.cards.iter().map(|c| c.row).min().unwrap();
    // it climbs out of C's field row, above every card in its way, and comes down to A's top row from above
    assert!(
        back.points.iter().any(|p| p.1 < top || p.1 == 0),
        "{back:?}"
    );
    let a = l.card("A").unwrap();
    let before_end = back.points[back.points.len() - 2];
    assert!(before_end.0 < a.col || before_end.1 < a.row, "{back:?}");
}

#[test]
fn cards_keep_their_cells_across_stops_and_new_ones_take_free_cells() {
    let first = heap_layout::layout(&ring(), None);
    let mut g = ring();
    // a new object D from C, and B's value changed
    g.nodes[1].fields[0].value = "20".into();
    g.nodes[2].fields.push(Field {
        name: "extra".into(),
        value: "Node".into(),
        to: Some("D".into()),
        cut: None,
    });
    g.nodes.push(n("D", "Node", &[("v", "4", None)]));
    let next = heap_layout::layout(&g, Some(&first));
    for id in ["A", "B"] {
        let (x, y) = (first.card(id).unwrap(), next.card(id).unwrap());
        assert_eq!((x.col, x.row), (y.col, y.row), "{id} moved");
    }
    assert_eq!(next.cards.len(), 4);
    assert_eq!(overlap(&next), None, "{next:#?}");
}

#[test]
fn the_same_graph_lays_out_the_same() {
    assert_eq!(
        heap_layout::layout(&ring(), None),
        heap_layout::layout(&ring(), None)
    );
}

#[test]
fn a_wide_fan_out_keeps_crossings_down() {
    // R → x0..x5, each xi → y(5 - i): the second layer's order follows the first (no crossings possible)
    let mut nodes = vec![n("R", "Root", &[("f", "X", None); 6])];
    let names: Vec<String> = (0..6).map(|i| format!("x{i}")).collect();
    let ys: Vec<String> = (0..6).map(|i| format!("y{i}")).collect();
    for (i, f) in nodes[0].fields.iter_mut().enumerate() {
        f.to = Some(names[i].clone());
    }
    for i in 0..6 {
        nodes.push(n(&names[i], "X", &[("y", "Y", Some(&ys[5 - i]))]));
    }
    for y in &ys {
        nodes.push(n(y, "Y", &[("v", "0", None)]));
    }
    let g = Graph {
        roots: vec![("r".into(), Some("R".into()))],
        nodes,
        cut: 0,
    };
    let l = heap_layout::layout(&g, None);
    assert_eq!(overlap(&l), None);
    let row = |id: &str| l.card(id).unwrap().row;
    for i in 0..5 {
        assert!(row(&names[i]) < row(&names[i + 1]), "x in field order");
        assert!(row(&ys[5 - i]) < row(&ys[4 - i]), "y follows x: {l:#?}");
    }
}

/// A cut field's edge ends at a stub ("+40 not shown") right of its card, marked cut (drawn dashed).
#[test]
fn a_cut_field_ends_at_a_stub() {
    let mut a = n("A", "Box", &[("v", "1", None), ("tags", "list[40]", None)]);
    a.fields[1].cut = Some(40);
    let g = Graph {
        roots: vec![("b".into(), Some("A".into()))],
        nodes: vec![a],
        cut: 1,
    };
    let l = heap_layout::layout(&g, None);
    let card = l.card("A").unwrap().clone();
    assert_eq!(l.cuts.len(), 1, "{l:#?}");
    let s = &l.cuts[0];
    assert_eq!((s.from.as_str(), s.field, s.count), ("A", 1, 40));
    assert!(s.col > card.col + card.width, "right of its card: {l:#?}");
    assert_eq!(s.width as usize, "+40 not shown".len() + 2);
    let e = l
        .edges
        .iter()
        .find(|e| e.cut)
        .unwrap_or_else(|| panic!("no cut edge: {l:#?}"));
    assert_eq!((e.from.as_str(), e.field, e.to.as_str()), ("A", 1, ""));
    assert_eq!(
        e.points.first(),
        Some(&(card.col + card.width, card.row + 2))
    );
    assert_eq!(e.points.last(), Some(&(s.col, s.row)));
    assert!(l.width >= s.col + s.width, "{l:#?}");
    assert!(l.height > s.row, "{l:#?}");
}

/// Stubs never sit on a card or on each other.
#[test]
fn stubs_take_free_cells() {
    let mut a = n(
        "A",
        "Box",
        &[
            ("x", "X", Some("B")),
            ("y", "list", None),
            ("z", "list", None),
        ],
    );
    a.fields[1].cut = Some(3);
    a.fields[2].cut = Some(7);
    let g = Graph {
        roots: vec![("a".into(), Some("A".into()))],
        nodes: vec![a, n("B", "X", &[("v", "1", None)])],
        cut: 2,
    };
    let l = heap_layout::layout(&g, None);
    assert_eq!(l.cuts.len(), 2, "{l:#?}");
    let boxes: Vec<(u32, u32, u32, u32)> = l
        .cards
        .iter()
        .map(|c| (c.col, c.row, c.width, c.height))
        .chain(l.cuts.iter().map(|s| (s.col, s.row, s.width, 1)))
        .collect();
    for (i, a) in boxes.iter().enumerate() {
        for b in &boxes[i + 1..] {
            let apart = a.0 + a.2 < b.0 || b.0 + b.2 < a.0 || a.1 + a.3 < b.1 || b.1 + b.3 < a.1;
            assert!(apart, "{a:?} and {b:?} touch: {l:#?}");
        }
    }
}

/// `debug/heap`'s answer and the `debug-heap` push carry the stubs and the cut edges.
#[test]
fn the_answer_carries_the_stubs() {
    let mut a = n("A", "Box", &[("v", "1", None), ("tags", "list[40]", None)]);
    a.fields[1].cut = Some(40);
    let g = Graph {
        roots: vec![("b".into(), Some("A".into()))],
        nodes: vec![a],
        cut: 1,
    };
    let l = heap_layout::layout(&g, None);
    let w = super::heap_wire::wire(
        "h1",
        "d1",
        Some("b"),
        &g,
        &l,
        super::heap::diff(&[], &g.nodes),
    );
    let v = serde_json::to_value(&w).unwrap();
    assert_eq!(v["nodes"][0]["fields"][1]["cut"], 40);
    assert_eq!(v["cuts"][0]["count"], 40);
    assert_eq!(v["cuts"][0]["from"], "A");
    let e = &v["edges"][0];
    assert_eq!(
        (e["cut"].clone(), e["to"].clone()),
        (serde_json::json!(true), serde_json::json!(""))
    );
}
