//! A view's model for the editor's replica (docs/develop/hub.md, "The native view model"): what a builder says the
//! model is now ([`Doc`]), and the ops that turn what the editor was last sent into it. The ops are Sjá's wire
//! (`{"ops": [...]}`): `reset`, `edges` (removals first), `remove`, `nodes`, `edges` (additions), `list` or `splice`
//! (a changed list's middle, when that is shorter than the list). Pure: no
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

/// A list's JSON size, near enough to compare two ways of saying it: its ids and their separators.
fn ids_len(ids: &[String]) -> usize {
    ids.iter().map(|i| i.len() + 3).sum()
}

/// The `splice` that turns the editor's list OLD into NEW: what is left after their common prefix and suffix, when that
/// is shorter than NEW whole. None when the whole list is the shorter way, or when a splice cannot say it: a window
/// whose `from` moved, or whose total moved by other than the ids added less the ids removed (Sjá moves a window's total
/// by exactly that).
fn splice_json(
    name: &str,
    old: &[String],
    old_window: Option<&(usize, usize)>,
    new: &[String],
    new_window: Option<&(usize, usize)>,
) -> Option<Value> {
    match (old_window, new_window) {
        (None, None) => {}
        (Some(&(ot, of)), Some(&(nt, nf))) => {
            let by = |a: usize, b: usize| {
                i128::try_from(a).unwrap_or(0) - i128::try_from(b).unwrap_or(0)
            };
            if of != nf || by(nt, ot) != by(new.len(), old.len()) {
                return None;
            }
        }
        _ => return None,
    }
    let prefix = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    let suffix = old[prefix..]
        .iter()
        .rev()
        .zip(new[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let ids = &new[prefix..new.len() - suffix];
    if ids_len(ids) >= ids_len(new) {
        return None;
    }
    Some(
        json!({"splice": {"name": name, "at": prefix, "remove": old.len() - prefix - suffix, "ids": ids}}),
    )
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
                let op = old
                    .lists
                    .get(name)
                    .and_then(|o| splice_json(name, o, old.windows.get(name), ids, window))
                    .unwrap_or_else(|| json!({ "list": list_json(name, ids, window) }));
                ops.push(op);
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

/// One `view-model`: base, version and the model, `{"ops": [...]}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Out {
    pub base: u64,
    pub version: u64,
    /// The model's first op is a reset.
    pub reset: bool,
    pub model: Value,
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

    /// Whether there is a model to [`Sent::extend`]: one was sent and no reset is due.
    pub fn extendable(&self) -> bool {
        self.doc.is_some() && !self.reset_due
    }

    /// The editor's model gains NODES (wire objects, `id` included), new or changed: their op alone, none when none
    /// changed; the cost is theirs, not the model's. Only when [`Sent::extendable`].
    pub fn extend(&mut self, nodes: Vec<Value>) -> Option<Out> {
        let doc = self.doc.as_mut()?;
        let mut changed = Vec::new();
        for n in nodes {
            let id = n["id"].as_str().unwrap_or_default().to_owned();
            if doc.nodes.get(&id) != Some(&n) {
                doc.nodes.insert(id, n.clone());
                changed.push(n);
            }
        }
        if changed.is_empty() {
            return None;
        }
        Some(self.send(vec![json!({ "nodes": changed })]))
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
            model: json!({ "ops": ops }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn ids(r: std::ops::Range<usize>) -> Vec<String> {
        r.map(|i| format!("n:{i}")).collect()
    }

    fn doc(list: Vec<String>, window: Option<(usize, usize)>) -> Doc {
        let mut d = Doc {
            descriptor: json!({"scheme": "tree"}),
            ..Doc::default()
        };
        d.lists.insert("order".into(), list);
        if let Some(w) = window {
            d.windows.insert("order".into(), w);
        }
        d
    }

    /// Sjá's rule for a list op, as `nidhogg/sja/src/model.rs` has it: `list` replaces, `splice` edits and moves a
    /// window's total by what it added less what it removed.
    type Applied = BTreeMap<String, (Vec<String>, Option<(usize, usize)>)>;

    fn apply(ops: &[Value], state: &mut Applied) {
        for op in ops {
            if let Some(l) = op.get("list") {
                let name = l["name"].as_str().unwrap().to_owned();
                let list: Vec<String> = l["ids"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().to_owned())
                    .collect();
                let w = l.get("total").map(|t| {
                    (
                        usize::try_from(t.as_u64().unwrap()).unwrap(),
                        usize::try_from(l["from"].as_u64().unwrap()).unwrap(),
                    )
                });
                state.insert(name, (list, w));
            } else if let Some(s) = op.get("splice") {
                let name = s["name"].as_str().unwrap();
                let at = usize::try_from(s["at"].as_u64().unwrap()).unwrap();
                let remove = usize::try_from(s["remove"].as_u64().unwrap()).unwrap();
                let new: Vec<String> = s["ids"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().to_owned())
                    .collect();
                let e = state
                    .get_mut(name)
                    .expect("a splice names a list the editor has");
                assert!(at + remove <= e.0.len(), "a splice outside its list");
                let added = new.len();
                e.0.splice(at..at + remove, new);
                if let Some((t, _)) = e.1.as_mut() {
                    *t = (*t + added).saturating_sub(remove);
                }
            }
        }
    }

    fn state_of(d: &Doc) -> Applied {
        d.lists
            .iter()
            .map(|(n, l)| (n.clone(), (l.clone(), d.windows.get(n).copied())))
            .collect()
    }

    fn only_op(ops: &[Value]) -> &Value {
        assert_eq!(ops.len(), 1, "{ops:?}");
        &ops[0]
    }

    #[test]
    fn an_append_is_a_splice_at_the_end() {
        let old = doc(ids(0..1000), None);
        let new = doc(ids(0..1010), None);
        let ops = new.diff(&old);
        assert_eq!(
            only_op(&ops),
            &json!({"splice": {"name": "order", "at": 1000, "remove": 0, "ids": ids(1000..1010)}})
        );
    }

    #[test]
    fn an_insert_and_a_middle_removal_are_one_splice_each() {
        let old = doc(ids(0..100), None);
        let mut l = ids(0..100);
        l.insert(50, "x".into());
        let ops = doc(l, None).diff(&old);
        assert_eq!(
            only_op(&ops),
            &json!({"splice": {"name": "order", "at": 50, "remove": 0, "ids": ["x"]}})
        );
        let mut l = ids(0..100);
        l.drain(40..45);
        let ops = doc(l, None).diff(&old);
        assert_eq!(
            only_op(&ops),
            &json!({"splice": {"name": "order", "at": 40, "remove": 5, "ids": []}})
        );
    }

    #[test]
    fn a_window_that_grows_with_its_list_splices_and_a_window_that_moves_is_sent_whole() {
        let old = doc(ids(0..100), Some((500, 0)));
        let ops = doc(ids(0..110), Some((510, 0))).diff(&old);
        assert!(only_op(&ops).get("splice").is_some(), "{ops:?}");
        // the total moved with no ids to carry it: a splice cannot say that
        let ops = doc(ids(0..100), Some((510, 0))).diff(&old);
        assert!(only_op(&ops).get("list").is_some(), "{ops:?}");
        // a new `from`
        let ops = doc(ids(10..110), Some((500, 10))).diff(&old);
        assert_eq!(only_op(&ops)["list"]["from"], json!(10), "{ops:?}");
    }

    #[test]
    fn a_list_is_sent_whole_when_that_is_shorter_than_the_splice() {
        let old = doc(vec!["a".into(), "b".into(), "c".into()], None);
        let new = doc(vec!["c".into(), "b".into(), "a".into()], None);
        let ops = new.diff(&old);
        assert!(only_op(&ops).get("list").is_some(), "{ops:?}");
        // a list the editor has not got is sent whole
        let ops = doc(ids(0..3), None).diff(&Doc {
            descriptor: json!({"scheme": "tree"}),
            ..Doc::default()
        });
        assert!(only_op(&ops).get("list").is_some(), "{ops:?}");
    }

    fn lists_strategy() -> impl Strategy<Value = (Vec<u8>, Vec<u8>, bool)> {
        (
            proptest::collection::vec(0u8..12, 0..40),
            proptest::collection::vec(0u8..12, 0..40),
            any::<bool>(),
        )
    }

    proptest! {
        /// The old doc plus the diff, applied by the reference applier, is the new doc.
        #[test]
        fn the_diff_applied_to_the_old_doc_is_the_new_doc((a, b, windowed) in lists_strategy()) {
            let to = |v: &[u8]| v.iter().map(|x| format!("n:{x}")).collect::<Vec<_>>();
            let (la, lb) = (to(&a), to(&b));
            let (wa, wb) = if windowed { (Some((la.len() + 7, 0)), Some((lb.len() + 7, 0))) } else { (None, None) };
            let (old, new) = (doc(la, wa), doc(lb, wb));
            let mut state = state_of(&old);
            apply(&new.diff(&old), &mut state);
            prop_assert_eq!(state, state_of(&new));
        }
    }
}
