//! The Work map's model for the editor's replica (docs/develop/hub.md, "The native view model"): the items a rows
//! view shows as nodes with their links (`vegvisir::nav`), the edges among them, and the lists the walking keys
//! follow. The class names are the faces' order in the editor.

use crate::view::model::Doc;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use vegvisir::layout::Layout;
use vegvisir::model::Fields;
use vegvisir::{EdgeKind, ItemId, Kind, Model, nav};

/// The map's descriptor: the scheme, the chain, what search matches, the lists, classes, flags and forms.
fn descriptor() -> Value {
    json!({
        "scheme": "links",
        "chain_kinds": ["came-from", "edits", "reads", "runs-on"],
        "match_fields": ["label", "task"],
        "lists": ["team", "needs-you", "outline", "plans"],
        "classes": ["selected", "match", "chain", "dim"],
        "flags": ["needs-you", "warn", "live"],
        "forms": [{"name": "graph"}, {"name": "outline", "list": "outline"}],
        "start": "team",
    })
}

/// A serde enum's word (`agent`, `came-from`, `needs-you`).
fn word<T: serde::Serialize>(t: &T) -> Value {
    serde_json::to_value(t).unwrap_or(Value::Null)
}

/// The fields of F the editor reads beside the card (the review panel's summary): an agent's plan steps (`done` of
/// `steps`), its edits (`edit_files`, `edit_plus`, `edit_minus`), `reads`, last `conclusion`, `spend` and `minutes`,
/// each only when known.
pub(crate) fn card_fields(f: &Fields) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some((done, steps)) = f.progress {
        out.extend([json!(["done", done]), json!(["steps", steps])]);
    }
    if let Some((files, plus, minus)) = f.edits {
        out.extend([
            json!(["edit_files", files]),
            json!(["edit_plus", plus]),
            json!(["edit_minus", minus]),
        ]);
    }
    if let Some(r) = f.reads {
        out.push(json!(["reads", r]));
    }
    if let Some(c) = &f.conclusion {
        out.push(json!(["conclusion", c]));
    }
    if let Some(s) = &f.spend {
        out.push(json!(["spend", s]));
    }
    if let Some(m) = f.minutes {
        out.push(json!(["minutes", m]));
    }
    out
}

/// The model of the items SENT of model M, laid out by L.
pub(crate) fn doc(m: &Model, l: &Layout, sent: &BTreeSet<ItemId>) -> Doc {
    let links = nav::links(m, l, sent);
    let mut d = Doc {
        descriptor: descriptor(),
        ..Doc::default()
    };
    // the agents each item overlaps (an agent's `overlaps` field: the ids, space-separated)
    let mut overlaps: BTreeMap<&ItemId, Vec<&str>> = BTreeMap::new();
    let edges = m.edges();
    for e in edges
        .iter()
        .filter(|e| e.kind == EdgeKind::Overlap && sent.contains(&e.from) && sent.contains(&e.to))
    {
        overlaps.entry(&e.from).or_default().push(e.to.as_str());
        overlaps.entry(&e.to).or_default().push(e.from.as_str());
    }
    let mut plans = Vec::new();
    for (id, it) in m.items().into_iter().filter(|(id, _)| sent.contains(id)) {
        if it.kind == Kind::Plan {
            plans.push(id.0.clone());
        }
        let mut flags = 0u32;
        for (bit, on) in [it.needs_you, it.warn, it.live].into_iter().enumerate() {
            if on {
                flags |= 1 << bit;
            }
        }
        let mut fields = vec![json!(["label", it.label])];
        if let Some(s) = it.fields.state {
            fields.push(json!(["state", word(&s)]));
        }
        if let Some(t) = &it.fields.task {
            fields.push(json!(["task", t]));
        }
        fields.extend(card_fields(&it.fields));
        if let Some(o) = overlaps.get_mut(&id) {
            o.sort_unstable();
            o.dedup();
            fields.push(json!(["overlaps", o.join(" ")]));
        }
        // the card's rect in layout units (the map's motion capture reads it)
        if let Some(r) = l.at.get(&id) {
            for (name, v) in [("x", r.x), ("y", r.y), ("w", r.w), ("h", r.h)] {
                fields.push(json!([name, v]));
            }
        }
        let k = links.get(&id).cloned().unwrap_or_default();
        let mut navs = serde_json::Map::new();
        for (name, to) in [
            ("up", k.up),
            ("down", k.down),
            ("left", k.left),
            ("right", k.right),
        ] {
            if let Some(to) = to {
                navs.insert(name.into(), json!(to));
            }
        }
        let mut node = json!({"id": id, "kind": word(&it.kind), "flags": flags, "nav": navs, "fields": fields});
        if let Some(p) = &it.parent {
            node["parent"] = json!(p);
        }
        if let Some(t) = &k.then {
            node["then"] = json!(t);
        }
        d.nodes.insert(id.0, node);
    }
    for e in m.edges() {
        if sent.contains(&e.from) && sent.contains(&e.to) {
            let kind = word(&e.kind).as_str().unwrap_or_default().to_owned();
            d.edges.insert((e.from.0, e.to.0, kind));
        }
    }
    let ids = |v: Vec<ItemId>| v.into_iter().map(|i| i.0).collect::<Vec<_>>();
    d.lists.insert("team".into(), ids(nav::team(m, sent)));
    d.lists
        .insert("needs-you".into(), ids(nav::needs_you(m, sent)));
    d.lists.insert("outline".into(), ids(nav::outline(m, sent)));
    d.lists.insert("plans".into(), plans);
    d
}
