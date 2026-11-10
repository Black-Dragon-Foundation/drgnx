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

/// The `splice` ops that turn the editor's list OLD into NEW, when they are shorter than NEW whole; None when the whole
/// list is the shorter way or a splice cannot say it.
/// - Same window start (or no window): one splice, what is left after their common prefix and suffix. Its total must
///   move by the ids added less the ids removed (Sjá moves a window's total by exactly that).
/// - A window moved over the same total: the ids both windows hold must agree; the old ids after them become the new
///   ids after them, then the old ids before them the new ids before them, each splice naming the new `from` (Sjá
///   sets it and keeps the total).
fn splice_json(
    name: &str,
    old: &[String],
    old_window: Option<&(usize, usize)>,
    new: &[String],
    new_window: Option<&(usize, usize)>,
) -> Option<Vec<Value>> {
    match (old_window, new_window) {
        (None, None) => {}
        (Some(&(ot, of)), Some(&(nt, nf))) if of != nf => {
            return (ot == nt)
                .then(|| move_json(name, old, of, new, nf))
                .flatten();
        }
        (Some(&(ot, _)), Some(&(nt, _))) => {
            let by = |a: usize, b: usize| {
                i128::try_from(a).unwrap_or(0) - i128::try_from(b).unwrap_or(0)
            };
            if by(nt, ot) != by(new.len(), old.len()) {
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
    Some(vec![
        json!({"splice": {"name": name, "at": prefix, "remove": old.len() - prefix - suffix, "ids": ids}}),
    ])
}

/// [`splice_json`] for a window moved from OF to NF over the same total.
fn move_json(
    name: &str,
    old: &[String],
    of: usize,
    new: &[String],
    nf: usize,
) -> Option<Vec<Value>> {
    let start = of.max(nf);
    let end = (of + old.len()).min(nf + new.len());
    if end <= start {
        return None;
    }
    let (so, sn, k) = (start - of, start - nf, end - start);
    if old[so..so + k] != new[sn..sn + k] {
        return None;
    }
    let (head, tail) = (&new[..sn], &new[sn + k..]);
    if ids_len(head) + ids_len(tail) >= ids_len(new) {
        return None;
    }
    let mut ops = Vec::new();
    if so + k < old.len() || !tail.is_empty() {
        ops.push(json!({"splice": {"name": name, "at": so + k, "remove": old.len() - so - k, "ids": tail, "from": nf}}));
    }
    if so > 0 || !head.is_empty() {
        ops.push(json!({"splice": {"name": name, "at": 0, "remove": so, "ids": head, "from": nf}}));
    }
    Some(ops)
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
                ops.extend(
                    old.lists
                        .get(name)
                        .and_then(|o| splice_json(name, o, old.windows.get(name), ids, window))
                        .unwrap_or_else(|| vec![json!({ "list": list_json(name, ids, window) })]),
                );
            }
        }
        for name in old.lists.keys().filter(|n| !self.lists.contains_key(*n)) {
            ops.push(json!({ "list": list_json(name, &[], None) }));
        }
        ops
    }
}

/// A windowed list's move ([`Sent::move_window`]): list NAME's new WINDOW (total, from); HELD, every node id of the new
/// model, the list's ids `HELD[ORDER]` and the others their parents.
pub struct WindowMove<'a> {
    pub name: &'a str,
    pub window: (usize, usize),
    pub held: &'a [String],
    pub order: std::ops::Range<usize>,
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

    /// The editor's model, one list NAME that is a window and its nodes, moves to WINDOW over HELD ([`WindowMove`]);
    /// NODE(i) builds `HELD[i]`'s wire object. The ops the diff would send for that move (the nodes gone, the new ones, the list), made from the
    /// move alone: NODE runs only for the ids the editor does not hold, and no node is compared, so a move costs what
    /// it changes, not the model. The caller vouches that the nodes held stay as they are. None (the builder publishes
    /// the whole) when nothing was sent, a reset is due, the model is not one windowed list without edges, or the
    /// list's total changed (a list that grew is published whole).
    pub fn move_window(
        &mut self,
        WindowMove {
            name,
            window,
            held,
            order,
        }: WindowMove,
        mut node: impl FnMut(usize) -> Value,
    ) -> Option<Out> {
        if self.reset_due {
            return None;
        }
        let doc = self.doc.as_mut()?;
        if doc.lists.len() != 1
            || doc.windows.get(name).map(|w| w.0) != Some(window.0)
            || !doc.edges.is_empty()
        {
            return None;
        }
        let keep: std::collections::HashSet<&str> = held.iter().map(String::as_str).collect();
        let gone: Vec<String> = doc
            .nodes
            .keys()
            .filter(|id| !keep.contains(id.as_str()))
            .cloned()
            .collect();
        let mut added: Vec<(String, Value)> = held
            .iter()
            .enumerate()
            .filter(|(_, id)| !doc.nodes.contains_key(*id))
            .map(|(i, id)| (id.clone(), node(i)))
            .collect();
        added.sort_by(|a, b| a.0.cmp(&b.0));
        let ids = held[order].to_vec();
        let mut ops = Vec::new();
        if !gone.is_empty() {
            ops.push(json!({ "remove": gone }));
        }
        if !added.is_empty() {
            ops.push(json!({ "nodes": added.iter().map(|(_, n)| n).collect::<Vec<_>>() }));
        }
        let old = doc.lists.get(name).map(Vec::as_slice).unwrap_or_default();
        let old_window = doc.windows.get(name);
        if old != ids.as_slice() || old_window != Some(&window) {
            ops.extend(
                splice_json(name, old, old_window, &ids, Some(&window)).unwrap_or_else(|| {
                    vec![json!({ "list": list_json(name, &ids, Some(&window)) })]
                }),
            );
        }
        if ops.is_empty() {
            return None;
        }
        for id in &gone {
            doc.nodes.remove(id);
        }
        doc.nodes.extend(added);
        doc.lists.insert(name.to_owned(), ids);
        doc.windows.insert(name.to_owned(), window);
        Some(self.send(ops))
    }

    /// The editor's model gains NODES (id, wire object), new, and their IDS at the end of list NAME: the ops the diff
    /// would send for that change (the nodes by id, then a splice), made from it alone, so a builder that only appends
    /// pays for what it adds, not for the whole model. None (the builder publishes the whole) when nothing was sent, a
    /// reset is due, or NAME is a window of a longer list.
    pub fn append(
        &mut self,
        nodes: Vec<(String, Value)>,
        name: &str,
        ids: Vec<String>,
    ) -> Option<Out> {
        if self.reset_due {
            return None;
        }
        let doc = self.doc.as_mut()?;
        if doc.windows.contains_key(name) {
            return None;
        }
        let list = doc.lists.get_mut(name)?;
        let at = list.len();
        list.extend(ids.iter().cloned());
        let mut nodes = nodes;
        nodes.sort_by(|a, b| a.0.cmp(&b.0));
        let mut ops = Vec::new();
        if !nodes.is_empty() {
            ops.push(json!({ "nodes": nodes.iter().map(|(_, n)| n).collect::<Vec<_>>() }));
        }
        if !ids.is_empty() {
            ops.push(json!({"splice": {"name": name, "at": at, "remove": 0, "ids": ids}}));
        }
        for (id, n) in nodes {
            doc.nodes.insert(id, n);
        }
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
                match (s.get("from"), e.1.as_mut()) {
                    (Some(f), Some((_, from))) => {
                        *from = usize::try_from(f.as_u64().unwrap()).unwrap();
                    }
                    (Some(_), None) => panic!("a splice names a from for a whole list"),
                    (None, Some((t, _))) => *t = (*t + added).saturating_sub(remove),
                    (None, None) => {}
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
    fn a_window_that_grows_with_its_list_splices_and_a_window_that_moves_splices_its_ends() {
        let old = doc(ids(0..100), Some((500, 0)));
        let ops = doc(ids(0..110), Some((510, 0))).diff(&old);
        assert!(only_op(&ops).get("splice").is_some(), "{ops:?}");
        // the total moved with no ids to carry it: a splice cannot say that
        let ops = doc(ids(0..100), Some((510, 0))).diff(&old);
        assert!(only_op(&ops).get("list").is_some(), "{ops:?}");
        // a new `from` over the same total: the ids that leave and come, each splice naming it
        let new = doc(ids(10..110), Some((500, 10)));
        let ops = new.diff(&old);
        assert_eq!(ops.len(), 2, "{ops:?}");
        assert_eq!(
            ops[0]["splice"]["at"],
            json!(100),
            "the tail first: {ops:?}"
        );
        assert_eq!(
            ops[1]["splice"]["remove"],
            json!(10),
            "then the head: {ops:?}"
        );
        assert!(
            ops.iter().all(|op| op["splice"]["from"] == json!(10)),
            "{ops:?}"
        );
        let mut state = state_of(&old);
        apply(&ops, &mut state);
        assert_eq!(state, state_of(&new));
        // backward, and a move with no ids in common: the list whole
        let ops = doc(ids(0..100), Some((500, 0))).diff(&new);
        assert_eq!(ops.len(), 2, "{ops:?}");
        let ops = doc(ids(200..300), Some((500, 200))).diff(&old);
        assert_eq!(only_op(&ops)["list"]["from"], json!(200), "{ops:?}");
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

    fn mv(
        window: (usize, usize),
        held: &[String],
        order: std::ops::Range<usize>,
    ) -> WindowMove<'_> {
        WindowMove {
            name: "order",
            window,
            held,
            order,
        }
    }

    fn node(id: &str) -> (String, Value) {
        (id.to_owned(), json!({"id": id, "kind": "match"}))
    }

    /// A window move is the ops the diff would send for the same move, made from the move alone: the node builder runs
    /// only for the ids the editor does not hold, and the sent model is the new one. Refused with no model sent, a
    /// reset due, or a list that is not a window (the builder publishes the whole).
    #[test]
    fn a_window_move_sends_what_the_diff_would() {
        let parent = |d: &mut Doc, id: &str| {
            d.nodes.insert(id.into(), node(id).1);
        };
        let mut old = doc(ids(10..20), Some((40, 10)));
        old.nodes = ids(10..20).iter().map(|i| node(i)).collect();
        parent(&mut old, "p:a");
        let mut sent = Sent::default();
        assert!(
            sent.move_window(mv((40, 15), &[], 0..0), |_| unreachable!())
                .is_none()
        );
        sent.publish(old.clone()).unwrap();
        // the new window, 15..25, under a parent of its own
        let mut new = doc(ids(15..25), Some((40, 15)));
        new.nodes = ids(15..25).iter().map(|i| node(i)).collect();
        parent(&mut new, "p:b");
        let mut held = vec!["p:b".to_owned()];
        held.extend(ids(15..25));
        let mut built = Vec::new();
        let out = sent
            .move_window(mv((40, 15), &held, 1..11), |i| {
                built.push(held[i].clone());
                node(&held[i]).1
            })
            .unwrap();
        assert_eq!(out.model, json!({ "ops": new.diff(&old) }));
        let mut want = vec!["p:b".to_owned()];
        want.extend(ids(20..25));
        assert_eq!(
            built, want,
            "only the nodes the editor did not hold are built"
        );
        assert!(sent.publish(new).is_none(), "the sent model is the new one");
        assert!(
            sent.move_window(mv((41, 0), &held, 1..11), |_| unreachable!())
                .is_none(),
            "a list that grew is published whole"
        );
        sent.reset_due();
        assert!(
            sent.move_window(mv((40, 0), &held, 1..11), |_| unreachable!())
                .is_none()
        );
        let mut whole = Sent::default();
        whole.publish(doc(ids(0..3), None)).unwrap();
        assert!(
            whole
                .move_window(mv((3, 0), &[], 0..0), |_| unreachable!())
                .is_none()
        );
    }

    /// An append is the ops the diff would send for the same change, made from the change alone; refused with no model
    /// sent, a reset due, or a windowed list (the builder publishes the whole).
    #[test]
    fn an_append_sends_what_the_diff_would() {
        let mut sent = Sent::default();
        assert!(
            sent.append(vec![node("n:0")], "order", vec!["n:0".into()])
                .is_none()
        );
        let mut old = doc(ids(0..3), None);
        old.nodes = ids(0..3).iter().map(|i| node(i)).collect();
        sent.publish(old.clone()).unwrap();
        let mut new = old.clone();
        let added = ["n:9", "n:10"];
        for id in added {
            new.nodes.insert(id.into(), node(id).1);
            new.lists.get_mut("order").unwrap().push(id.into());
        }
        let out = sent
            .append(
                added.iter().map(|i| node(i)).collect(),
                "order",
                added.iter().map(|i| (*i).to_owned()).collect(),
            )
            .unwrap();
        assert_eq!(out.model, json!({ "ops": new.diff(&old) }));
        assert!(sent.publish(new).is_none(), "the sent model is the new one");
        sent.reset_due();
        assert!(
            sent.append(vec![node("n:11")], "order", vec!["n:11".into()])
                .is_none()
        );
        let mut windowed = Sent::default();
        windowed.publish(doc(ids(0..3), Some((9, 0)))).unwrap();
        assert!(
            windowed
                .append(vec![node("n:3")], "order", vec!["n:3".into()])
                .is_none()
        );
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

        /// A window of one whole list moved anywhere: the diff applied to the old window is the new one.
        #[test]
        fn a_moved_window_applied_is_the_new_window(
            whole in proptest::collection::vec(0u8..30, 1..60),
            (a, la, b, lb) in (0usize..60, 0usize..60, 0usize..60, 0usize..60),
        ) {
            let all: Vec<String> = whole.iter().enumerate().map(|(i, x)| format!("n:{i}:{x}")).collect();
            let total = all.len();
            let win = |from: usize, len: usize| {
                let from = from % total;
                let len = len.min(total - from);
                doc(all[from..from + len].to_vec(), Some((total, from)))
            };
            let (old, new) = (win(a, la), win(b, lb));
            let mut state = state_of(&old);
            apply(&new.diff(&old), &mut state);
            prop_assert_eq!(state, state_of(&new));
        }
    }
}
