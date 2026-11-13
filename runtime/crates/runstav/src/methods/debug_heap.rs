//! The heap graph (docs/develop/debugging.md, spec §19.7 D7): `debug/heap` reads the objects reachable from an
//! expression at the current stop as cards and edges laid out in cells, and reads an open graph again at a later stop
//! with what changed; `debug/heap/close` forgets it.  The user's (the values are the program's).

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The longest expression or id, in bytes.
pub const TEXT_MAX: usize = 4096;
/// The most objects one graph holds.
pub const HEAP_NODES_MAX: u32 = 200;
/// The deepest one graph goes.
pub const HEAP_DEPTH_MAX: u32 = 32;

/// `debug/heap`: the graph of EXPR (a variable's `evaluateName`) in SESSION's FRAME (the selected one when none), at
/// most LIMIT objects (default 50) and DEPTH levels (default 8); or, with GRAPH, that open graph read again at the
/// session's current stop.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugHeap {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graph: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub depth: Option<u32>,
}

/// A field of an object: its NAME and VALUE text, and the object it refers to (TO).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HeapField {
    pub name: String,
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

/// An object: its ID (the adapter's identity, or its path), TYPE, the PATH that reached it first, its FIELDS.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HeapNode {
    pub id: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub path: String,
    pub fields: Vec<HeapField>,
}

/// An object's card: COL, ROW, WIDTH and HEIGHT in cells.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HeapCard {
    pub id: String,
    pub col: u32,
    pub row: u32,
    pub width: u32,
    pub height: u32,
}

/// A reference: from field FIELD's row of card FROM into card TO's top row, through POINTS ([col, row] cells,
/// straight runs).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct HeapEdge {
    pub from: String,
    pub field: u32,
    pub to: String,
    pub points: Vec<[u32; 2]>,
}

/// `debug/heap`'s answer: the GRAPH's id; the root's NODE (none: a scalar); the objects, CUT (references left at the
/// limit, the depth or the time), the layout (CARDS, EDGES, WIDTH × HEIGHT cells); against the graph's last read, the
/// objects ADDED, CHANGED (a field's value or reference) and GONE.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugHeapGraph {
    pub graph: String,
    pub session: String,
    pub expr: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
    pub nodes: Vec<HeapNode>,
    pub cut: u32,
    pub cards: Vec<HeapCard>,
    pub edges: Vec<HeapEdge>,
    pub width: u32,
    pub height: u32,
    pub added: Vec<String>,
    pub changed: Vec<String>,
    pub gone: Vec<String>,
}

/// `debug/heap/close`: forget GRAPH.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugHeapClose {
    pub graph: String,
}

/// `debug/heap/close`'s answer: whether there was such a graph.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DebugHeapClosed {
    pub closed: bool,
}

fn text(field: &'static str, s: &str) -> Result<(), Error> {
    if s.is_empty() || s.len() > TEXT_MAX {
        return Err(invalid(field, "1 to 4096 bytes"));
    }
    Ok(())
}

fn check(p: &DebugHeap) -> Result<(), Error> {
    match (&p.graph, &p.session, &p.expr) {
        (Some(g), _, _) => text("graph", g)?,
        (None, Some(s), Some(e)) => {
            text("session", s)?;
            text("expr", e)?;
        }
        (None, None, _) => return Err(invalid("session", "a session (or an open graph)")),
        (None, Some(_), None) => return Err(invalid("expr", "an expression (or an open graph)")),
    }
    if p.limit.is_some_and(|l| !(1..=HEAP_NODES_MAX).contains(&l)) {
        return Err(invalid("limit", "1 to 200 objects"));
    }
    if p.depth.is_some_and(|d| !(1..=HEAP_DEPTH_MAX).contains(&d)) {
        return Err(invalid("depth", "1 to 32 levels"));
    }
    Ok(())
}

fn check_close(p: &DebugHeapClose) -> Result<(), Error> {
    text("graph", &p.graph)
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "debug/heap", DebugHeap(DebugHeap) -> DebugHeapGraph,
            classes: [User], writes: false,
            doc: "the objects reachable from an expression at the current stop as cards and edges laid out in cells (each adapter's object identity: a shared object is one card, a cycle closes); with an open graph, it read again at the current stop with what was added, changed and gone",
            check: check,
        ),
        method!(
            "debug/heap/close", DebugHeapClose(DebugHeapClose) -> DebugHeapClosed,
            classes: [User], writes: false,
            doc: "forget an open heap graph",
            check: check_close,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::{self, Class};
    use serde_json::json;

    #[test]
    fn heap_is_the_users_and_takes_an_expression_or_a_graph() {
        let m = registry::find("debug/heap").expect("debug/heap is registered");
        assert!(m.allows(Class::User) && !m.allows(Class::Agent));
        assert!((m.decode)(&json!({"session": "d1", "expr": "a.next"})).is_ok());
        assert!((m.decode)(&json!({"graph": "h1"})).is_ok());
        for (bad, path) in [
            (json!({"expr": "a"}), "session"),
            (json!({"session": "d1"}), "expr"),
            (json!({"graph": "h1", "limit": 201}), "limit"),
            (json!({"graph": "h1", "depth": 0}), "depth"),
        ] {
            assert_eq!(
                (m.decode)(&bad).err().and_then(|e| e.path).as_deref(),
                Some(path)
            );
        }
        let c = registry::find("debug/heap/close").expect("debug/heap/close is registered");
        assert!((c.decode)(&json!({"graph": ""})).is_err());
    }
}
