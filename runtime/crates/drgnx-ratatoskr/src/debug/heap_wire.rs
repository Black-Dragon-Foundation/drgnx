//! `debug/heap` and `debug/heap/close` (runstav `methods::debug_heap`): a graph read at the current stop and laid out,
//! kept by id so its next read keeps the cards' cells and says what changed.

use super::heap::{self, Graph, Limits, Node};
use super::heap_layout::{self, Layout};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug_heap::{
    DebugHeap, DebugHeapClose, DebugHeapClosed, DebugHeapGraph, HeapCard, HeapEdge, HeapField,
    HeapNode,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

/// An open graph: what it reads and its last read.
struct Kept {
    session: String,
    frame: Option<i64>,
    expr: String,
    limits: Limits,
    nodes: Vec<Node>,
    layout: Layout,
}

/// The open graphs.
#[derive(Default)]
pub struct Heaps {
    open: Mutex<HashMap<String, Kept>>,
    next: AtomicU64,
}

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

fn limits(p: &DebugHeap, base: Limits) -> Limits {
    Limits {
        nodes: p.limit.map_or(base.nodes, |l| l as usize),
        depth: p.depth.map_or(base.depth, |d| d as usize),
        ..base
    }
}

fn wire(
    id: &str,
    session: &str,
    expr: &str,
    g: &Graph,
    l: &Layout,
    d: heap::Diff,
) -> DebugHeapGraph {
    DebugHeapGraph {
        graph: id.to_owned(),
        session: session.to_owned(),
        expr: expr.to_owned(),
        node: g.roots.first().and_then(|(_, n)| n.clone()),
        nodes: g
            .nodes
            .iter()
            .map(|n| HeapNode {
                id: n.id.clone(),
                ty: n.ty.clone(),
                path: n.path.clone(),
                fields: n
                    .fields
                    .iter()
                    .map(|f| HeapField {
                        name: f.name.clone(),
                        value: f.value.clone(),
                        to: f.to.clone(),
                    })
                    .collect(),
            })
            .collect(),
        cut: g.cut,
        cards: l
            .cards
            .iter()
            .map(|c| HeapCard {
                id: c.id.clone(),
                col: c.col,
                row: c.row,
                width: c.width,
                height: c.height,
            })
            .collect(),
        edges: l
            .edges
            .iter()
            .map(|e| HeapEdge {
                from: e.from.clone(),
                field: e.field,
                to: e.to.clone(),
                points: e.points.iter().map(|&(c, r)| [c, r]).collect(),
            })
            .collect(),
        width: l.width,
        height: l.height,
        added: d.added,
        changed: d.changed,
        gone: d.gone,
    }
}

async fn read(front: &Front, p: DebugHeap) -> Result<DebugHeapGraph, Error> {
    let hub = &front.debug;
    let d = hub.debug(front);
    let (id, session, frame, expr, lim, before) = match &p.graph {
        Some(g) => {
            let open = hub.heaps.open.lock().expect("heaps");
            let k = open
                .get(g)
                .ok_or_else(|| err(format!("no open heap graph {g}")))?;
            (
                g.clone(),
                k.session.clone(),
                p.frame.or(k.frame),
                k.expr.clone(),
                limits(&p, k.limits),
                Some((k.nodes.clone(), k.layout.clone())),
            )
        }
        None => {
            let n = hub.heaps.next.fetch_add(1, Ordering::Relaxed) + 1;
            (
                format!("h{n}"),
                p.session.clone().unwrap_or_default(),
                p.frame,
                p.expr.clone().unwrap_or_default(),
                limits(&p, Limits::default()),
                None,
            )
        }
    };
    let g = heap::read(d, &session, frame, &expr, lim)
        .await
        .map_err(err)?;
    let l = heap_layout::layout(&g, before.as_ref().map(|(_, l)| l));
    let diff = before
        .as_ref()
        .map_or_else(heap::Diff::default, |(n, _)| heap::diff(n, &g.nodes));
    let out = wire(&id, &session, &expr, &g, &l, diff);
    let mut open = hub.heaps.open.lock().expect("heaps");
    // graphs of sessions that have ended go with them
    open.retain(|_, k| d.session(&k.session).is_some_and(|h| !h.is_ended()));
    open.insert(
        id,
        Kept {
            session,
            frame,
            expr,
            limits: lim,
            nodes: g.nodes,
            layout: l,
        },
    );
    Ok(out)
}

fn close(front: &Front, p: DebugHeapClose) -> DebugHeapClosed {
    let closed = front
        .debug
        .heaps
        .open
        .lock()
        .expect("heaps")
        .remove(&p.graph)
        .is_some();
    DebugHeapClosed { closed }
}

/// P served by the heap graph's methods, or handed back.
pub async fn serve(
    front: &Front,
    _caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match p {
        Params::DebugHeap(p) => read(front, p).await.map(|v| json!(v)),
        Params::DebugHeapClose(p) => Ok(json!(close(front, p))),
        other => return Err(Box::new(other)),
    })
}
