//! A view's model for the editor's replica (docs/develop/hub.md, "The native view model"): what a builder says the
//! model is now ([`Doc`]), and the ops that turn what the editor was last sent into it. The ops are Sjá's wire
//! (`{"ops": [...]}`): `reset`, `edges` (removals first), `remove`, `nodes`, `edges` (additions), `list`. Pure: no
//! I/O, no clock.

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// An edge: (from, to, kind).
pub type Edge = (String, String, String);

/// A view's model as its builder makes it: the descriptor, each node (its wire object, `id` included), the edges and
/// the lists; a list named in `windows` is a window `(total, from)` of a longer one (design §2.5).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Doc {
    pub descriptor: Value,
    pub nodes: BTreeMap<String, Value>,
    pub edges: BTreeSet<Edge>,
    pub lists: BTreeMap<String, Vec<String>>,
    pub windows: BTreeMap<String, (usize, usize)>,
}

fn edges_json<'a>(edges: impl Iterator<Item = &'a Edge>) -> Value {
    Value::Array(edges.map(|(a, b, k)| json!([a, b, k])).collect())
}

fn list_json(name: &str, ids: &[String], window: Option<&(usize, usize)>) -> Value {
    let mut l = json!({"name": name, "ids": ids});
    if let Some((total, from)) = window {
        l["total"] = json!(total);
        l["from"] = json!(from);
    }
    l
}

impl Doc {
    /// The op that makes the editor's model exactly this.
    pub fn reset(&self) -> Value {
        json!({"reset": {
            "descriptor": self.descriptor,
            "nodes": self.nodes.values().collect::<Vec<_>>(),
            "edges": edges_json(self.edges.iter()),
            "lists": self.lists.iter().map(|(n, ids)| list_json(n, ids, self.windows.get(n))).collect::<Vec<_>>(),
        }})
    }

    /// The ops that turn OLD into this; a reset when the descriptor changed; none when nothing did.
    pub fn diff(&self, old: &Doc) -> Vec<Value> {
        if self.descriptor != old.descriptor {
            return vec![self.reset()];
        }
        let mut ops = Vec::new();
        let gone_edges: Vec<&Edge> = old.edges.difference(&self.edges).collect();
        if !gone_edges.is_empty() {
            ops.push(json!({"edges": {"remove": edges_json(gone_edges.into_iter())}}));
        }
        let gone: Vec<&String> = old
            .nodes
            .keys()
            .filter(|id| !self.nodes.contains_key(*id))
            .collect();
        if !gone.is_empty() {
            ops.push(json!({ "remove": gone }));
        }
        let changed: Vec<&Value> = self
            .nodes
            .iter()
            .filter(|(id, n)| old.nodes.get(*id) != Some(*n))
            .map(|(_, n)| n)
            .collect();
        if !changed.is_empty() {
            ops.push(json!({ "nodes": changed }));
        }
        let new_edges: Vec<&Edge> = self.edges.difference(&old.edges).collect();
        if !new_edges.is_empty() {
            ops.push(json!({"edges": {"add": edges_json(new_edges.into_iter())}}));
        }
        for (name, ids) in &self.lists {
            let window = self.windows.get(name);
            if old.lists.get(name) != Some(ids) || old.windows.get(name) != window {
                ops.push(json!({ "list": list_json(name, ids, window) }));
            }
        }
        for name in old.lists.keys().filter(|n| !self.lists.contains_key(*n)) {
            ops.push(json!({ "list": list_json(name, &[], None) }));
        }
        ops
    }
}

/// What one view's editor was last sent: the version and the model, and whether the next send is a reset.
#[derive(Default)]
pub struct Sent {
    pub version: u64,
    doc: Option<Doc>,
    reset_due: bool,
}

/// One `view-model`: base, version and the model string.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Out {
    pub base: u64,
    pub version: u64,
    /// The model's first op is a reset.
    pub reset: bool,
    pub model: String,
}

impl Sent {
    /// The editor now gets DOC: the ops from what it holds (a reset first, after [`Sent::reset_due`]), or none when
    /// nothing changed.
    pub fn publish(&mut self, doc: Doc) -> Option<Out> {
        let ops = match &self.doc {
            Some(old) if !self.reset_due => doc.diff(old),
            _ => vec![doc.reset()],
        };
        if ops.is_empty() {
            return None;
        }
        self.doc = Some(doc);
        Some(self.send(ops))
    }

    /// The editor's replica asked again: a reset of what it was last sent (none before the first send).
    pub fn resync(&mut self) -> Option<Out> {
        let reset = self.doc.as_ref()?.reset();
        Some(self.send(vec![reset]))
    }

    /// The view was hidden: its next model is a reset.
    pub fn reset_due(&mut self) {
        self.reset_due = true;
    }

    fn send(&mut self, ops: Vec<Value>) -> Out {
        self.reset_due = false;
        let base = self.version;
        self.version += 1;
        Out {
            base,
            version: self.version,
            reset: ops.first().is_some_and(|op| op.get("reset").is_some()),
            model: json!({ "ops": ops }).to_string(),
        }
    }
}
