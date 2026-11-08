//! The Extensions list as a view (`extensions/list`; docs/develop/hub.md, "The Extensions list"): the editor names its
//! sections (a search each, in order), the hub runs them and builds the list: a header row `section:NAME` ("Title
//! (N)") and each row's line (glyph, name, version, the state's chip, "restart to use"), then its summary line unless
//! dense. A row an earlier section holds is not shown again; Installed leaves out the rows that wait in Updates. The
//! model (a `tree`: a `section` node per header, a node per row under it, the list `order`) goes first, then the rows
//! to every class of the view; a class that gets its env later is built from the request kept per (connection,
//! view). Only the glyphs depend on the class (a terminal's ASCII form).

use super::model::Doc;
use super::{Key, Views, lock};
use crate::front::Front;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::extensions as w;
use runstav::methods::view::Display;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, Mutex};

/// The rows the model holds; past them its list `order` is a window of the first ones.
const MODEL_WINDOW: usize = 20_000;

/// One section as built: its name, title, the count its header shows, the rows it shows.
#[derive(Clone, Debug, PartialEq)]
pub struct Section {
    pub name: String,
    pub title: String,
    pub count: u32,
    pub rows: Vec<w::Row>,
}

/// A view's last list: what every class's rows are built from.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Built {
    pub sections: Vec<Section>,
    pub dense: bool,
    pub glyphs: Vec<w::Glyph>,
    pub restart: HashSet<String>,
}

/// The lists, one per (connection, view).
#[derive(Default)]
pub(super) struct Lists {
    last: Mutex<BTreeMap<(u64, String), Arc<Built>>>,
}

impl Lists {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.last).retain(|(c, _), _| *c != conn);
    }

    pub(super) fn stop(&self, conn: u64, view: &str) {
        lock(&self.last).remove(&(conn, view.to_owned()));
    }
}

/// The sections as shown, from each section's (total, rows) in P's order: earlier sections' rows left out, Installed
/// without the rows that wait in Updates, a section with none dropped. The search section's header counts its total,
/// the others the rows they hold (before the rows an earlier section showed are left out).
pub fn build(p: &w::ListParams, found: Vec<(u32, Vec<w::Row>)>) -> (Built, Vec<w::ListTotal>) {
    let mut seen: HashSet<String> = HashSet::new();
    let mut sections = Vec::new();
    let mut totals = Vec::new();
    for (s, (total, rows)) in p.sections.iter().zip(found) {
        totals.push(w::ListTotal {
            name: s.name.clone(),
            total,
            loaded: rows.len() as u32,
        });
        let held: Vec<w::Row> = rows
            .into_iter()
            .filter(|r| !(s.minus_updates && r.state == w::State::Update))
            .collect();
        let count = if s.name == "search" {
            total
        } else {
            held.len() as u32
        };
        let shown: Vec<w::Row> = held
            .into_iter()
            .filter(|r| seen.insert(r.id.clone()))
            .collect();
        if !shown.is_empty() {
            sections.push(Section {
                name: s.name.clone(),
                title: s.title.clone(),
                count,
                rows: shown,
            });
        }
    }
    let built = Built {
        sections,
        dense: p.dense,
        glyphs: p.glyphs.clone(),
        restart: p.restart.iter().cloned().collect(),
    };
    (built, totals)
}

fn word<T: serde::Serialize>(v: T) -> String {
    match serde_json::to_value(v) {
        Ok(Value::String(s)) => s,
        _ => String::new(),
    }
}

/// The chip ROW's state gives it, and its face (the list's `drgnx-extensions-list--state-chip`).
fn state_chip(r: &w::Row) -> Option<(String, &'static str)> {
    use w::State as S;
    Some(match r.state {
        S::Unapproved => (
            "not approved: it does not run".into(),
            "drgnx-status-needs-you",
        ),
        S::Changed => ("changed: approve it again".into(), "drgnx-status-needs-you"),
        S::Disabled => ("disabled".into(), "shadow"),
        S::Broken => ("broken".into(), "drgnx-status-fail"),
        S::Update => (
            r.latest
                .as_ref()
                .map_or_else(|| "update".into(), |l| format!("update to {l}")),
            "drgnx-status-warn",
        ),
        S::Held => ("held".into(), "drgnx-status-warn"),
        S::Incompat => ("needs a newer Emacs".into(), "drgnx-status-warn"),
        S::Missing => (
            "missing: no archive you use has it".into(),
            "drgnx-status-fail",
        ),
        S::Failed => ("failed".into(), "drgnx-status-fail"),
        S::NeedsPackage => ("waits for a package".into(), "drgnx-status-warn"),
        S::Dependency => ("dependency".into(), "drgnx-status-info"),
        S::On => ("on".into(), "drgnx-status-ok"),
        S::Off => ("off".into(), "shadow"),
        S::Available | S::Installed | S::BuiltIn => return None,
    })
}

/// The trust word of ROW's source.
fn trust(r: &w::Row) -> Option<&'static str> {
    use w::Signed as G;
    match r.signed {
        G::Signed => Some("signed"),
        G::SigningArchive => Some("signed archive"),
        G::UnsignedArchive => Some("unsigned archive"),
        G::Local => Some("local"),
        G::GitCommit => Some("Git commit"),
        G::HashApproved => Some("hash approved"),
        G::None => None,
    }
}

fn glyph<'a>(b: &'a Built, r: &w::Row, display: Display) -> Option<&'a str> {
    let kind = match r.kind {
        w::Kind::Plugin => "plugin",
        w::Kind::Module => "module",
        _ => "package",
    };
    let g = b.glyphs.iter().find(|g| g.kind == kind)?;
    Some(if display == Display::Tty {
        &g.tty
    } else {
        &g.gui
    })
}

fn spans(mut row: RowBuilder, id: &str) -> Row {
    let end = row.pos();
    row.prop(0, end, "drgnx-work-id", json!(id))
        .prop(0, end, "drgnx-extensions-id", json!(id));
    row.finish()
}

/// BUILT's rows in DISPLAY's class: each header, then each row's line and (unless dense) its summary line.
pub fn rows(b: &Built, display: Display) -> Vec<Row> {
    let mut out = Vec::new();
    for s in &b.sections {
        let key = format!("section:{}", s.name);
        let mut h = RowBuilder::new(key.clone());
        h.push(&format!("{} ({})", s.title, s.count), Some("bold"));
        let end = h.pos();
        h.prop(0, end, "drgnx-work-id", json!(key)); // a header is no row a command acts on
        out.push(h.finish());
        for r in &s.rows {
            let mut l = RowBuilder::new(r.id.clone());
            if let Some(g) = glyph(b, r, display) {
                l.push(g, None).push(" ", None);
            }
            l.push(&r.name, Some("bold"));
            if let Some(v) = &r.version {
                l.push(&format!(" {v}"), Some("shadow"));
            }
            if let Some((chip, face)) = state_chip(r) {
                l.push("  ", None).push(&chip, Some(face));
            }
            if b.restart.contains(&r.id) {
                l.push("  ", None)
                    .push("restart to use", Some("drgnx-status-warn"));
            }
            out.push(spans(l, &r.id));
            if !b.dense {
                let words: Vec<&str> =
                    [Some(r.summary.as_str()), Some(r.source.as_str()), trust(r)]
                        .into_iter()
                        .flatten()
                        .filter(|w| !w.is_empty())
                        .collect();
                let mut d = RowBuilder::new(format!("{}/2", r.id));
                d.push(&format!("    {}", words.join(" · ")), Some("shadow"));
                out.push(spans(d, &r.id));
            }
        }
    }
    out
}

/// BUILT's model: a `tree` of a `section` node per header and a node per row under it (the row's kind), with what
/// the editor's commands read of a row as fields; the list `order` in the rows' order.
pub fn doc(b: &Built) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "tree",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["order"],
            "classes": ["selected", "match", "dim"],
            "flags": ["expanded"],
            "forms": [],
            "start": "order",
        }),
        ..Doc::default()
    };
    let total: usize = b.sections.iter().map(|s| 1 + s.rows.len()).sum();
    let mut order = Vec::new();
    'all: for s in &b.sections {
        let sid = format!("section:{}", s.name);
        if order.len() >= MODEL_WINDOW {
            break;
        }
        d.nodes.insert(
            sid.clone(),
            json!({"id": sid, "kind": "section", "flags": 1,
                   "fields": [["label", s.title], ["section", s.name], ["count", s.count]]}),
        );
        order.push(sid.clone());
        for r in &s.rows {
            if order.len() >= MODEL_WINDOW {
                break 'all;
            }
            let mut fields = vec![
                json!(["label", r.name]),
                json!(["name", r.name]),
                json!(["state", word(r.state)]),
                json!(["signed", word(r.signed)]),
                json!(["source", r.source]),
                json!(["section", s.name]),
            ];
            if let Some(v) = &r.version {
                fields.push(json!(["version", v]));
            }
            if let Some(v) = &r.latest {
                fields.push(json!(["latest", v]));
            }
            d.nodes.insert(
                r.id.clone(),
                json!({"id": r.id, "kind": word(r.kind), "flags": 0, "parent": sid, "fields": fields}),
            );
            order.push(r.id.clone());
        }
    }
    if total > order.len() {
        d.windows.insert("order".into(), (total, 0));
    }
    d.lists.insert("order".into(), order);
    d
}

impl Views {
    /// KEY's rows from its view's last list, for a class that just got its env; false when the view has none.
    pub(super) fn extensions_build(&self, f: &Front, key: &Key) -> bool {
        let Some(b) = lock(&self.lists.last).get(&(key.0, key.1.clone())).cloned() else {
            return false;
        };
        self.publish_model(f, key.0, &key.1, doc(&b));
        let display = lock(&self.store).env_of(key).map(|e| e.display);
        if let Some(display) = display
            && let Some(p) = lock(&self.store).publish(key, rows(&b, display), &[])
        {
            f.send_to(key.0, "view-patch", json!(p));
        }
        true
    }
}

/// `extensions/list`: keep CONN's list for its view, send the model, then the rows to every class it shows the view
/// in; the answer is each section's total and how many rows the list holds of it.
pub fn list(
    f: &Front,
    conn: u64,
    p: w::ListParams,
    found: Vec<(u32, Vec<w::Row>)>,
) -> w::ListResult {
    let views = &f.core.views;
    let (built, totals) = build(&p, found);
    let built = Arc::new(built);
    lock(&views.lists.last).insert((conn, p.view.clone()), built.clone());
    views.publish_model(f, conn, &p.view, doc(&built));
    let mut store = lock(&views.store);
    for class in store.classes(conn, &p.view) {
        let key = (conn, p.view.clone(), class);
        let Some(display) = store.env_of(&key).map(|e| e.display) else {
            continue;
        };
        if let Some(patch) = store.publish(&key, rows(&built, display), &[]) {
            f.send_to(conn, "view-patch", json!(patch));
        }
    }
    w::ListResult { sections: totals }
}

#[cfg(test)]
mod tests;
