//! The heap graph's layout (the design's §3): each object a card in cells (its type row, then a row per field), laid
//! out in layers left to right by distance from the roots, each layer's order following its references' sources;
//! each reference an edge of straight runs from its field's row to the target card's top row (Glitnir rounds the
//! bends). A reference back to an earlier layer goes round above the cards. Given the last stop's layout, cards that
//! are still there keep their cells and new ones take free cells, so a step moves nothing that did not change.

use super::heap::Graph;
use serde::Serialize;

/// A card: its object's id and its cells.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Card {
    pub id: String,
    pub col: u32,
    pub row: u32,
    pub width: u32,
    pub height: u32,
}

/// A reference: from the field FIELD of the card FROM to the card TO, through POINTS (cells, column then row).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Edge {
    pub from: String,
    pub field: u32,
    pub to: String,
    pub points: Vec<(u32, u32)>,
}

/// The graph laid out: WIDTH × HEIGHT cells.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Layout {
    pub cards: Vec<Card>,
    pub edges: Vec<Edge>,
    pub width: u32,
    pub height: u32,
}

impl Layout {
    pub fn card(&self, id: &str) -> Option<&Card> {
        self.cards.iter().find(|c| c.id == id)
    }
}

/// Fields a card shows; the rest are one "+N more" row (their edges leave from it).
pub const FIELDS_SHOWN: usize = 8;
/// A value's text on a card is cut to this many characters.
const VALUE_CHARS: usize = 24;
/// Columns between layers (room for the edges' vertical runs), and the margin left of the first.
const GAP: u32 = 6;
const LEFT: u32 = 3;

/// A card's cells for a node: its type row and its shown field rows; its widest row plus a cell each side.
fn size(n: &super::heap::Node) -> (u32, u32) {
    let shown = n.fields.len().min(FIELDS_SHOWN);
    let more = usize::from(n.fields.len() > FIELDS_SHOWN);
    let row = |f: &super::heap::Field| {
        f.name.chars().count() + 2 + f.value.chars().count().min(VALUE_CHARS)
    };
    let widest = n
        .fields
        .iter()
        .take(FIELDS_SHOWN)
        .map(row)
        .chain([n.ty.chars().count(), if more == 1 { 10 } else { 0 }])
        .max()
        .unwrap_or(0);
    (as_u32(widest + 2), as_u32(1 + shown + more))
}

fn as_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// The card a field's edge leaves from: its own row, or the "+N more" row.
fn field_row(f: usize) -> u32 {
    as_u32(1 + f.min(FIELDS_SHOWN))
}

fn apart(a: &Card, b: &Card) -> bool {
    a.col + a.width < b.col
        || b.col + b.width < a.col
        || a.row + a.height < b.row
        || b.row + b.height < a.row
}

/// G laid out; with PREV (the last stop's), the cards still there keep their cells.
pub fn layout(g: &Graph, prev: Option<&Layout>) -> Layout {
    let index: std::collections::HashMap<&str, usize> = g
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.id.as_str(), i))
        .collect();
    let targets = |i: usize| {
        g.nodes[i]
            .fields
            .iter()
            .filter_map(|f| f.to.as_deref().and_then(|t| index.get(t).copied()))
            .collect::<Vec<_>>()
    };
    // layers: breadth first from the roots, in the roots' order then the fields'
    let mut layer = vec![usize::MAX; g.nodes.len()];
    let mut order: Vec<usize> = vec![];
    let mut queue = std::collections::VecDeque::new();
    for (_, id) in &g.roots {
        if let Some(&i) = id.as_deref().and_then(|id| index.get(id))
            && layer[i] == usize::MAX
        {
            layer[i] = 0;
            queue.push_back(i);
        }
    }
    // a node no root reaches (none from the walk) starts a layer 0 of its own
    for i in 0..g.nodes.len() {
        if queue.is_empty() && layer[i] == usize::MAX {
            layer[i] = 0;
            queue.push_back(i);
        }
        while let Some(i) = queue.pop_front() {
            order.push(i);
            for t in targets(i) {
                if layer[t] == usize::MAX {
                    layer[t] = layer[i] + 1;
                    queue.push_back(t);
                }
            }
        }
    }
    let layers = layer.iter().copied().max().map_or(0, |m| m + 1);
    let mut by_layer: Vec<Vec<usize>> = vec![vec![]; layers];
    for &i in &order {
        by_layer[layer[i]].push(i);
    }
    // each layer after the first ordered by its references' sources in the layer before (barycentre, stable)
    let mut pos = vec![0f64; g.nodes.len()];
    for _sweep in 0..2 {
        for l in 0..layers {
            if l > 0 {
                let key = |i: usize| {
                    let src: Vec<f64> = by_layer[l - 1]
                        .iter()
                        .flat_map(|&s| {
                            g.nodes[s]
                                .fields
                                .iter()
                                .enumerate()
                                .filter(|(_, f)| f.to.as_deref() == Some(g.nodes[i].id.as_str()))
                                .map(move |(k, _)| (s, k))
                        })
                        .map(|(s, k)| pos[s] + k as f64 / 100.0)
                        .collect();
                    if src.is_empty() {
                        pos[i]
                    } else {
                        src.iter().sum::<f64>() / src.len() as f64
                    }
                };
                let keys: Vec<(usize, f64)> = by_layer[l].iter().map(|&i| (i, key(i))).collect();
                let mut sorted = keys;
                sorted.sort_by(|a, b| a.1.total_cmp(&b.1));
                by_layer[l] = sorted.into_iter().map(|(i, _)| i).collect();
            }
            for (p, &i) in by_layer[l].iter().enumerate() {
                pos[i] = p as f64;
            }
        }
    }
    let sizes: Vec<(u32, u32)> = g.nodes.iter().map(size).collect();
    // the edges that go back (or stay in a layer) each get a lane above the cards
    let backs = g
        .nodes
        .iter()
        .enumerate()
        .flat_map(|(i, n)| {
            n.fields
                .iter()
                .filter_map(move |f| f.to.as_deref().map(|t| (i, t)))
        })
        .filter(|(i, t)| index.get(t).is_some_and(|&t| layer[t] <= layer[*i]))
        .count();
    let top = as_u32(backs + 1).max(2);
    // fresh cells: layers left to right, each as wide as its widest card; cards stacked with a row between
    let mut col_of = vec![LEFT; layers + 1];
    for l in 0..layers {
        let w = by_layer[l].iter().map(|&i| sizes[i].0).max().unwrap_or(0);
        col_of[l + 1] = col_of[l] + w + GAP;
    }
    let mut cards: Vec<Card> = vec![];
    let mut fresh: Vec<(usize, Card)> = vec![];
    for l in 0..layers {
        let mut row = top;
        for &i in &by_layer[l] {
            let (width, height) = sizes[i];
            let c = Card {
                id: g.nodes[i].id.clone(),
                col: col_of[l],
                row,
                width,
                height,
            };
            row += height + 1;
            fresh.push((i, c));
        }
    }
    // the last stop's cells first, then the new cards at their fresh cells, moved down until free
    let kept = |id: &str| prev.and_then(|p| p.card(id));
    for (_, c) in &fresh {
        if let Some(p) = kept(&c.id) {
            cards.push(Card {
                col: p.col,
                row: p.row,
                ..c.clone()
            });
        }
    }
    for (_, c) in fresh {
        if kept(&c.id).is_some() {
            continue;
        }
        let mut c = c;
        while cards.iter().any(|o| !apart(o, &c)) {
            c.row += 1;
        }
        cards.push(c);
    }
    // in the graph's order, so the same graph gives the same list
    cards.sort_by_key(|c| index.get(c.id.as_str()).copied().unwrap_or(usize::MAX));
    let at = |id: &str| cards.iter().find(|c| c.id == id);
    let mut edges = vec![];
    let mut lane = 0u32;
    for (i, n) in g.nodes.iter().enumerate() {
        let Some(s) = at(&n.id) else { continue };
        for (k, f) in n.fields.iter().enumerate() {
            let Some(t) = f.to.as_deref().and_then(at) else {
                continue;
            };
            let start = (s.col + s.width, s.row + field_row(k));
            let end = (t.col, t.row);
            let forward = index
                .get(t.id.as_str())
                .is_some_and(|&j| layer[j] > layer[i])
                && t.col > start.0 + 2;
            let mut points = if forward {
                let x = t.col - 2;
                vec![start, (x, start.1), (x, end.1), end]
            } else {
                // up into its lane above every card, across, and down into the target from its left
                let y = lane.min(top - 1);
                lane += 1;
                let (out, inn) = (start.0 + 2, t.col.saturating_sub(2));
                vec![start, (out, start.1), (out, y), (inn, y), (inn, end.1), end]
            };
            points.dedup();
            edges.push(Edge {
                from: n.id.clone(),
                field: as_u32(k.min(FIELDS_SHOWN)),
                to: t.id.clone(),
                points,
            });
        }
    }
    let width = cards
        .iter()
        .map(|c| c.col + c.width)
        .chain(edges.iter().flat_map(|e| e.points.iter().map(|p| p.0)))
        .max()
        .unwrap_or(0)
        + LEFT;
    let height = cards.iter().map(|c| c.row + c.height).max().unwrap_or(0) + 1;
    Layout {
        cards,
        edges,
        width,
        height,
    }
}
