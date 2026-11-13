//! The heap graph (spec §19.7 D7): the objects reachable from a variable at a stop, as nodes with fields, and the
//! references between them as edges. DAP has no object identity, so each adapter is asked for one with an
//! expression in the stopped frame ([`Ident`]): Python's `id`, Go's `uintptr` of a pointer, a native pointer's
//! address. A variable whose identity is not known is a node of its own, named by its path (a tree, not a graph).

use super::BoxFut;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};

/// What the walk asks the stopped session: a reference's children, and an expression's value in the stopped frame.
pub trait Probe: Send + Sync {
    fn variables(&self, reference: i64) -> BoxFut<'_, Result<Vec<Value>, String>>;
    fn evaluate(&self, expression: String) -> BoxFut<'_, Result<String, String>>;
}

/// How an adapter tells objects apart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ident {
    /// debugpy: `id(E)`.
    Python,
    /// delve: `uintptr(E)` of a pointer (`*T`); a pointer's one child `(*E)` is the object itself.
    Go,
    /// lldb-dap, CodeLLDB, gdb: `(void *)(E)` of a pointer (`T *`).
    Native,
    /// js-debug: a tag from a hidden `WeakMap` the hub keeps on `globalThis` under `Symbol.for('drgnx.ids')` while a
    /// session is attached ([`JS_TAG`], removed by [`JS_FORGET`]); objects are only added to it as keys.
    Js,
    /// No identity: every variable is its own node (a tree).
    Paths,
}

/// js-debug's identity of `{}` (an object or function: its tag, a small integer; anything else: null).
pub const JS_TAG: &str = "((o) => { if (o === null || (typeof o !== 'object' && typeof o !== 'function')) return null; \
const m = (globalThis[Symbol.for('drgnx.ids')] ??= { n: 0, w: new WeakMap() }); \
if (!m.w.has(o)) m.w.set(o, ++m.n); return m.w.get(o); })({})";

/// Removes [`JS_TAG`]'s map: evaluated before a detach that leaves the program running.
pub const JS_FORGET: &str = "delete globalThis[Symbol.for('drgnx.ids')]";

impl Ident {
    /// The identity an adapter type gives.
    pub fn of(adapter_type: &str) -> Ident {
        match adapter_type {
            "debugpy" | "python" => Ident::Python,
            "go" => Ident::Go,
            "lldb" | "lldb-dap" | "codelldb" | "cppdbg" | "gdb" => Ident::Native,
            "pwa-node" | "node" | "pwa-chrome" | "chrome" | "pwa-msedge" | "msedge"
            | "pwa-extensionHost" => Ident::Js,
            _ => Ident::Paths,
        }
    }
}

/// A field of a node: a scalar's text, or (`to`) the node it refers to.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Field {
    pub name: String,
    pub value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

/// An object.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Node {
    pub id: String,
    /// Its type as the adapter names it (empty when it gives none).
    #[serde(rename = "type")]
    pub ty: String,
    /// The expression that reached it first.
    pub path: String,
    pub fields: Vec<Field>,
}

/// The graph from some roots.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Graph {
    /// Each root's name and its node (None: a scalar, or not reached).
    pub roots: Vec<(String, Option<String>)>,
    pub nodes: Vec<Node>,
    /// References left unfollowed at the limit or the depth.
    pub cut: u32,
}

/// The walk's bounds.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub nodes: usize,
    pub depth: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            nodes: 50,
            depth: 8,
        }
    }
}

/// Children that are the adapter's own grouping or internals, never the object's fields: debugpy's groups and
/// js-debug's `[[Prototype]]`, `[[Scopes]]` and the like.
fn internal(name: &str) -> bool {
    name.starts_with("[[")
        || matches!(
            name,
            "special variables" | "function variables" | "class variables" | "protected variables"
        )
}

fn reference(v: &Value) -> i64 {
    v["variablesReference"].as_i64().unwrap_or(0)
}

fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or_default()
}

/// Where a variable's node goes once it is known.
#[derive(Clone, Copy)]
enum Slot {
    Root(usize),
    Field(usize, usize),
}

/// V's identity: what IDENT's expression gives, else its path (`evaluateName`, else its name).
async fn identity(probe: &dyn Probe, ident: Ident, v: &Value) -> String {
    let path = match text(v, "evaluateName") {
        "" => text(v, "name"),
        e => e,
    };
    let ty = text(v, "type").trim();
    let asked = match ident {
        Ident::Python if !text(v, "evaluateName").is_empty() => Some(format!("id({path})")),
        Ident::Go if ty.starts_with('*') && !text(v, "evaluateName").is_empty() => {
            Some(format!("uintptr({path})"))
        }
        Ident::Native if ty.ends_with('*') && !text(v, "evaluateName").is_empty() => {
            Some(format!("(void *)({path})"))
        }
        Ident::Js if !text(v, "evaluateName").is_empty() => Some(JS_TAG.replace("{}", path)),
        _ => None,
    };
    let Some(expr) = asked else {
        return path.to_owned();
    };
    let Ok(answer) = probe.evaluate(expr).await else {
        return path.to_owned();
    };
    let answer = answer.trim();
    let id = match ident {
        // delve: "41391058592384 = 0x25a51b582280"
        Ident::Go => answer
            .rsplit_once("= ")
            .map(|(_, h)| h.to_owned())
            .or_else(|| answer.parse::<u64>().ok().map(|n| format!("0x{n:x}"))),
        // lldb: "0x000000000f31b040" (some print "(void *) $0 = 0x…")
        Ident::Native => answer
            .split_whitespace()
            .find(|w| w.starts_with("0x"))
            .map(str::to_owned),
        // the map's tag; null for a primitive (it stays a path)
        Ident::Js => answer.parse::<u64>().ok().map(|n| format!("js:{n}")),
        _ => (!answer.is_empty()).then(|| answer.to_owned()),
    };
    id.unwrap_or_else(|| path.to_owned())
}

/// V's type and fields: its children, or for a Go pointer its one dereferenced child's.
async fn fields_of(probe: &dyn Probe, ident: Ident, v: &Value) -> (String, Vec<Value>) {
    let mut ty = text(v, "type").to_owned();
    let mut kids = probe.variables(reference(v)).await.unwrap_or_default();
    if ident == Ident::Go
        && kids.len() == 1
        && text(&kids[0], "evaluateName").starts_with("(*")
        && reference(&kids[0]) > 0
    {
        let inner = kids.remove(0);
        ty = text(&inner, "type").to_owned();
        kids = probe.variables(reference(&inner)).await.unwrap_or_default();
    }
    kids.retain(|k| !internal(text(k, "name")));
    (ty, kids)
}

/// The graph of ROOTS (DAP variables of the stopped frame), breadth first, within LIMITS. Each object is expanded
/// once; a reference to one already seen is an edge to it.
pub async fn walk(probe: &dyn Probe, ident: Ident, roots: Vec<Value>, limits: Limits) -> Graph {
    let mut g = Graph::default();
    let mut by_id: BTreeMap<String, usize> = BTreeMap::new();
    let mut todo: VecDeque<(Value, usize, Slot)> = VecDeque::new();
    for (i, v) in roots.into_iter().enumerate() {
        g.roots.push((text(&v, "name").to_owned(), None));
        if reference(&v) > 0 {
            todo.push_back((v, 0, Slot::Root(i)));
        }
    }
    while let Some((v, depth, slot)) = todo.pop_front() {
        let id = identity(probe, ident, &v).await;
        let at = match by_id.get(&id) {
            Some(&n) => Some(n),
            None if g.nodes.len() >= limits.nodes || depth >= limits.depth => {
                g.cut += 1;
                None
            }
            None => {
                let (ty, kids) = fields_of(probe, ident, &v).await;
                let n = g.nodes.len();
                let mut fields = Vec::with_capacity(kids.len());
                for (f, k) in kids.into_iter().enumerate() {
                    fields.push(Field {
                        name: text(&k, "name").to_owned(),
                        value: text(&k, "value").to_owned(),
                        to: None,
                    });
                    if reference(&k) > 0 {
                        todo.push_back((k, depth + 1, Slot::Field(n, f)));
                    }
                }
                let path = match text(&v, "evaluateName") {
                    "" => text(&v, "name"),
                    e => e,
                };
                g.nodes.push(Node {
                    id: id.clone(),
                    ty,
                    path: path.to_owned(),
                    fields,
                });
                by_id.insert(id, n);
                Some(n)
            }
        };
        let Some(n) = at else { continue };
        let id = g.nodes[n].id.clone();
        match slot {
            Slot::Root(r) => g.roots[r].1 = Some(id),
            Slot::Field(o, f) => g.nodes[o].fields[f].to = Some(id),
        }
    }
    g
}

/// A stopped session as the walk's [`Probe`]: stop EPOCH, its frame FRAME.
pub struct SessionProbe {
    pub handle: super::session::Handle,
    pub epoch: u64,
    pub frame: i64,
}

impl Probe for SessionProbe {
    fn variables(&self, reference: i64) -> BoxFut<'_, Result<Vec<Value>, String>> {
        Box::pin(self.handle.variables(self.epoch, reference))
    }
    fn evaluate(&self, expression: String) -> BoxFut<'_, Result<String, String>> {
        Box::pin(async move {
            let body = self
                .handle
                .request(
                    "evaluate",
                    serde_json::json!({"expression": expression, "frameId": self.frame, "context": "watch"}),
                )
                .await?;
            Ok(text(&body, "result").to_owned())
        })
    }
}
