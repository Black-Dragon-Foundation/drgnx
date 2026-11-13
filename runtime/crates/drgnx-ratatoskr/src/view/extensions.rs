//! The Extensions list as a view (`extensions/list`; docs/develop/hub.md, "The Extensions list"): the editor names its
//! sections (a search each, in order), the hub runs them and builds the list: a header row `section:NAME` ("Title
//! (N)") and each row's line (glyph, name, version, the state's chip, "restart to use"), then its summary line unless
//! dense. A row an earlier section holds is not shown again; Installed leaves out the rows that wait in Updates. The
//! generations the editor sends end the list as a Generations section (rows `gen:N`, the model's `gen` field). The
//! model (a `tree`: a `section` node per header, a node per row under it, the list `order`) goes first, then the rows
//! to every class of the view; a class that gets its env later is built from the request kept per (connection,
//! view). Only a row's kind mark depends on the class: a Lucide icon on a graphical display (`package`, `plug`,
//! `blocks`, sized as the Explorer's), the kind's ASCII glyph on a terminal.

use super::model::Doc;
use super::{Key, Views, icons, lock};
use crate::front::Front;
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::extensions as w;
use runstav::methods::view::{Display, ViewEnv};
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
    /// The Generations section that ends the list, newest first (none: no section).
    pub generations: Vec<w::Generation>,
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
        generations: p.generations.clone(),
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
        // a row the user did not ask for: a neutral warning, not a failure
        S::Missing => (
            "missing: no archive you use has it".into(),
            "drgnx-status-warn",
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

/// How a class draws a row's kind: on a graphical display a Lucide icon and the gap after it, in device px (the
/// Explorer's row: 16 px icons, 6 px gaps, window-dark.html `.row`); on a terminal the kind's ASCII glyph.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Look {
    pub gui: Option<(u32, u32)>,
}

impl Look {
    pub const TTY: Look = Look { gui: None };

    /// ENV's look: the sizes at its scale, rounded half up (`drgnx-px`).
    pub fn of(env: &ViewEnv) -> Self {
        let px = |v: f32| (f64::from(v) * f64::from(env.scale) + 0.5 + 1e-9).floor() as u32;
        match env.display {
            Display::Gui => Look {
                gui: Some((px(icons::SIZE), px(6.0))),
            },
            Display::Tty => Look::TTY,
        }
    }
}

/// The glyph kind of ROW (the editor's glyph table) and its icon.
fn kind_of(r: &w::Row) -> (&'static str, &'static str) {
    match r.kind {
        w::Kind::Plugin => ("plugin", "plug"),
        w::Kind::Module => ("module", "blocks"),
        _ => ("package", "package"),
    }
}

/// The mark of KIND at the start of L: in LOOK's graphical form ICON (the kind's glyph its alt text) and the gap, in
/// `shadow`, the icon put into IMAGES; else the glyph and a space.
fn mark(
    b: &Built,
    l: &mut RowBuilder,
    (kind, icon): (&str, &str),
    look: Look,
    images: &mut BTreeMap<ImageId, String>,
) {
    let g = b.glyphs.iter().find(|g| g.kind == kind);
    if let Some((size, gap)) = look.gui
        && let Some((id, svg)) = icons::svg(icon, size)
    {
        let at = l.pos();
        images.insert(id, svg);
        l.image(id, g.map_or("", |g| g.gui.as_str()))
            .space(gap, size, "shadow");
        let end = l.pos();
        l.face(at, end, "shadow");
    } else if let Some(g) = g {
        let glyph = if look.gui.is_some() { &g.gui } else { &g.tty };
        l.push(glyph, None).push(" ", None);
    }
}

fn spans(mut row: RowBuilder, id: &str) -> Row {
    let end = row.pos();
    row.prop(0, end, "drgnx-work-id", json!(id))
        .prop(0, end, "drgnx-extensions-id", json!(id));
    row.finish()
}

/// A header's face: a dock section's title, as the Explorer's (window-dark.html `.sec`).
const HEADER: &str = "drgnx-wb-section";

/// BUILT's rows in LOOK: each header, then each row's line and (unless dense, and when it has one) its summary line;
/// and the icons they name, each once.  The faces are the Explorer's: the name is the buffer's UI text, the version and
/// the summary muted.
pub fn rows(b: &Built, look: Look) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut out = Vec::new();
    let mut images = BTreeMap::new();
    for s in &b.sections {
        let key = format!("section:{}", s.name);
        let mut h = RowBuilder::new(key.clone());
        h.push(&format!("{} ({})", s.title, s.count), Some(HEADER));
        let end = h.pos();
        h.prop(0, end, "drgnx-work-id", json!(key)); // a header is no row a command acts on
        out.push(h.finish());
        for r in &s.rows {
            let mut l = RowBuilder::new(r.id.clone());
            mark(b, &mut l, kind_of(r), look, &mut images);
            l.push(&r.name, None);
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
            let words: Vec<&str> = [Some(r.summary.as_str()), Some(r.source.as_str()), trust(r)]
                .into_iter()
                .flatten()
                .filter(|w| !w.is_empty())
                .collect();
            if !b.dense && !words.is_empty() {
                let mut d = RowBuilder::new(format!("{}/2", r.id));
                d.push(&format!("    {}", words.join(" · ")), Some("shadow"));
                out.push(spans(d, &r.id));
            }
        }
    }
    generation_rows(b, look, &mut out, &mut images);
    (out, images.into_iter().collect())
}

/// The Generations section: its header, then per generation its line (number, time, note, in use or current, size),
/// what differs from the one before it and the copies note, as lines under it.  A span names `gen:N` (no extension
/// id: the extension commands act on none of these).
fn generation_rows(
    b: &Built,
    look: Look,
    out: &mut Vec<Row>,
    images: &mut BTreeMap<ImageId, String>,
) {
    if b.generations.is_empty() {
        return;
    }
    let mut h = RowBuilder::new("section:generations");
    h.push(
        &format!("Generations ({})", b.generations.len()),
        Some(HEADER),
    );
    let end = h.pos();
    h.prop(0, end, "drgnx-work-id", json!("section:generations"));
    out.push(h.finish());
    let line = |key: String, id: &str, text: &str| {
        let mut l = RowBuilder::new(key);
        l.push(&format!("    {text}"), Some("shadow"));
        let end = l.pos();
        l.prop(0, end, "drgnx-work-id", json!(id));
        l.finish()
    };
    for g in &b.generations {
        let id = format!("gen:{}", g.n);
        let mut l = RowBuilder::new(id.clone());
        mark(b, &mut l, ("package", "package"), look, images);
        l.push(&format!("#{}", g.n), None);
        if !g.time.is_empty() {
            l.push(&format!("  {}", g.time), None);
        }
        if let Some(note) = &g.note {
            l.push(&format!("  {note}"), None);
        }
        if g.in_use {
            l.push("  ", None).push("in use", Some("drgnx-status-warn"));
        } else if g.current {
            l.push("  ", None).push("current", Some("drgnx-status-ok"));
        }
        if let Some(size) = &g.size {
            l.push(&format!("  {size}"), None);
        }
        let end = l.pos();
        l.prop(0, end, "drgnx-work-id", json!(id));
        out.push(l.finish());
        if !g.differs.is_empty() {
            out.push(line(format!("{id}/2"), &id, &g.differs.join(" · ")));
        }
        if let Some(copies) = &g.copies {
            out.push(line(format!("{id}/3"), &id, copies));
        }
    }
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
                json!(["label", r.name]), // the row's name (the editor reads it as `label`)
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
    let total = total
        + if b.generations.is_empty() {
            0
        } else {
            1 + b.generations.len()
        };
    if !b.generations.is_empty() && order.len() + 1 + b.generations.len() <= MODEL_WINDOW {
        let sid = "section:generations".to_owned();
        d.nodes.insert(
            sid.clone(),
            json!({"id": sid, "kind": "section", "flags": 1,
                   "fields": [["label", "Generations"], ["section", "generations"], ["count", b.generations.len()]]}),
        );
        order.push(sid.clone());
        for g in &b.generations {
            let id = format!("gen:{}", g.n);
            d.nodes.insert(
                id.clone(),
                json!({"id": id, "kind": "generation", "flags": 0, "parent": sid,
                       "fields": [["label", format!("#{}", g.n)], ["gen", g.n], ["section", "generations"]]}),
            );
            order.push(id);
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
        let look = lock(&self.store).env_of(key).map(Look::of);
        if let Some(look) = look {
            let (rows, images) = rows(&b, look);
            if let Some(p) = lock(&self.store).publish(key, rows, &images) {
                f.send_to(key.0, "view-patch", json!(p));
            }
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
        let Some(look) = store.env_of(&key).map(Look::of) else {
            continue;
        };
        let (rows, images) = rows(&built, look);
        if let Some(patch) = store.publish(&key, rows, &images) {
            f.send_to(conn, "view-patch", json!(patch));
        }
    }
    w::ListResult { sections: totals }
}

#[cfg(test)]
mod tests;
