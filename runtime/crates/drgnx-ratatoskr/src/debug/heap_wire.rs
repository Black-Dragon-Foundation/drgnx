//! `debug/heap` and `debug/heap/close` (runstav `methods::debug_heap`): a graph read at the current stop and laid out,
//! kept by id so its next read keeps the cards' cells and says what changed; at each new stop of its session an open
//! graph is read again and sent as `debug-heap` to the editor that opened it.

use super::Debug;
use super::heap::{self, Graph, Limits, Node};
use super::heap_layout::{self, Layout};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug_heap::{
    DebugHeap, DebugHeapClosed, DebugHeapGraph, HeapCard, HeapCut, HeapEdge, HeapField, HeapNode,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

/// An open graph: what it reads and its last read.
struct Kept {
    session: String,
    /// The editor's connection that opened it.
    conn: u64,
    /// The stop it was last read at.
    epoch: Option<u64>,
    /// None: the frame's locals.
    expr: Option<String>,
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

fn limits(p: &DebugHeap, base: Limits) -> Limits {
    Limits {
        nodes: p.limit.map_or(base.nodes, |l| l as usize),
        depth: p.depth.map_or(base.depth, |d| d as usize),
        ..base
    }
}

/// G (of EXPR, None: the frame's locals) laid out as L, against the last read by D: `debug/heap`'s answer and the
/// `debug-heap` push.
pub(super) fn wire(
    id: &str,
    session: &str,
    expr: Option<&str>,
    g: &Graph,
    l: &Layout,
    d: heap::Diff,
) -> DebugHeapGraph {
    DebugHeapGraph {
        graph: id.to_owned(),
        session: session.to_owned(),
        expr: expr.unwrap_or_default().to_owned(),
        locals: expr.is_none(),
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
                        cut: f.cut,
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
                cut: e.cut,
            })
            .collect(),
        cuts: l
            .cuts
            .iter()
            .map(|c| HeapCut {
                from: c.from.clone(),
                field: c.field,
                count: c.count,
                col: c.col,
                row: c.row,
                width: c.width,
            })
            .collect(),
        width: l.width,
        height: l.height,
        added: d.added,
        changed: d.changed,
        gone: d.gone,
    }
}

impl Heaps {
    /// P read for the editor on connection CONN: a new graph, or an open one again.
    pub async fn read(&self, d: &Debug, conn: u64, p: DebugHeap) -> Result<DebugHeapGraph, String> {
        let (id, session, expr, lim, before) = match &p.graph {
            Some(g) => {
                let open = self.open.lock().expect("heaps");
                let k = open
                    .get(g)
                    .ok_or_else(|| format!("no open heap graph {g}"))?;
                (
                    g.clone(),
                    k.session.clone(),
                    k.expr.clone(),
                    limits(&p, k.limits),
                    Some((k.nodes.clone(), k.layout.clone())),
                )
            }
            None => {
                let n = self.next.fetch_add(1, Ordering::Relaxed) + 1;
                (
                    format!("h{n}"),
                    p.session.clone().unwrap_or_default(),
                    p.expr.clone().filter(|_| p.locals != Some(true)),
                    limits(&p, Limits::default()),
                    None,
                )
            }
        };
        let epoch = d.stop_of(&session).map(|s| s.epoch);
        let g = heap::read(d, &session, p.frame, expr.as_deref(), lim).await?;
        let l = heap_layout::layout(&g, before.as_ref().map(|(_, l)| l));
        let diff = before
            .as_ref()
            .map_or_else(heap::Diff::default, |(n, _)| heap::diff(n, &g.nodes));
        let out = wire(&id, &session, expr.as_deref(), &g, &l, diff);
        // the recorded run keeps it with the stop (sealed like the rest: spec §19.2)
        if let (Some(rec), Some(e)) = (d.records(), epoch) {
            rec.heap(&session, e, json!(out));
        }
        let mut open = self.open.lock().expect("heaps");
        // graphs of sessions that have ended go with them
        open.retain(|_, k| d.session(&k.session).is_some_and(|h| !h.is_ended()));
        open.insert(
            id,
            Kept {
                session,
                conn,
                epoch,
                expr,
                limits: lim,
                nodes: g.nodes,
                layout: l,
            },
        );
        Ok(out)
    }

    /// Forget GRAPH; whether it was open.
    pub fn close(&self, graph: &str) -> bool {
        self.open.lock().expect("heaps").remove(graph).is_some()
    }

    /// Whether SESSION has an open graph.
    pub fn any_of(&self, session: &str) -> bool {
        self.open
            .lock()
            .expect("heaps")
            .values()
            .any(|k| k.session == session)
    }

    /// A new stop (EPOCH) of SESSION: each of its open graphs not read at it is read again (the selected frame) and
    /// sent as `debug-heap` to the editor that opened it.
    pub async fn at_stop(&self, d: &Debug, session: &str, epoch: u64) {
        let due: Vec<(String, u64)> = self
            .open
            .lock()
            .expect("heaps")
            .iter()
            .filter(|(_, k)| k.session == session && k.epoch != Some(epoch))
            .map(|(id, k)| (id.clone(), k.conn))
            .collect();
        for (id, conn) in due {
            let p = DebugHeap {
                session: None,
                frame: None,
                expr: None,
                locals: None,
                graph: Some(id.clone()),
                limit: None,
                depth: None,
            };
            let v = match self.read(d, conn, p).await {
                Ok(g) => json!(g),
                Err(e) => json!({"graph": id, "session": session, "error": e}),
            };
            d.send_to(conn, "debug-heap", v);
        }
    }
}

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// P served by the heap graph's methods, or handed back.
pub async fn serve(
    front: &Front,
    caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    let d = front.debug.debug(front);
    Ok(match p {
        Params::DebugHeap(p) => d
            .heaps()
            .read(d, caller.conn_id, p)
            .await
            .map(|v| json!(v))
            .map_err(err),
        Params::DebugHeapClose(p) => Ok(json!(DebugHeapClosed {
            closed: d.heaps().close(&p.graph)
        })),
        other => return Err(Box::new(other)),
    })
}
