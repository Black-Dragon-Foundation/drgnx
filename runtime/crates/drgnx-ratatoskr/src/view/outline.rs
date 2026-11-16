//! The Outline panel's rows (`outline/set`): the editor names the file it shows; the hub outlines it with Hrafn's parse
//! (`hrafn::symbols::outline_text`) over the editor's text of it where the edit history tracks the buffer (unsaved
//! typing included), else the file on disk, and keeps the outline per (connection, view). An edit the history takes for
//! that file outlines it again once the edits pause ([`QUIET`] of the hub's clock); a saved file the history does not
//! track is sent again by the editor. The model is a list `order` of a node per definition, its `line` (from 1) and
//! `label` fields: the editor asks Sjá which one a line is in (`at-line`) and where a row goes. A row is the name,
//! indented two columns per definition around it, its key over it; a file with nothing to outline is one notice row.

use super::explorer::{INDENT, RowLook};
use super::model::Doc;
use super::{Key, Views, icons, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::fit::FontSet;
use drgnx_rows::fit_row::{Room, fit_row};
use drgnx_rows::{ImageId, Row, RowBuilder};
use hrafn::symbols::OutlineEntry;
use runstav::methods::view::{
    Display, OutlineScope, OutlineScopes, OutlineScopesParams, OutlineSet, ViewEnv,
};
use runstav::wire::Error;
use serde_json::json;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The largest text outlined, in bytes (the Lisp Outline's limit).
pub const OUTLINE_MAX: usize = 1 << 20;

/// Whether a text of LEN bytes is past [`OUTLINE_MAX`]: the one check every path to an outline goes through.
pub fn too_large(len: u64) -> bool {
    len > OUTLINE_MAX as u64
}

/// How long the edits to a shown file pause before it is outlined again.
pub const QUIET: Duration = Duration::from_millis(500);

/// What a view shows: a file's definitions, or a notice in their place.
#[derive(Clone, Debug, PartialEq)]
pub enum Shown {
    Entries(Vec<OutlineEntry>),
    Notice(&'static str),
}

/// The notice of a view with no file, or a file with nothing to outline.
pub const NONE: &str = "No outline for this file";
/// The notice of a file past [`OUTLINE_MAX`].
pub const LARGE: &str = "This file is too large for an outline";

/// One view: the file it shows (its true name), the generation of its latest ask, what it shows.
#[derive(Default)]
struct One {
    file: Option<String>,
    generation: u64,
    shown: Option<Arc<Shown>>,
}

/// The Outline views of every (connection, view).
#[derive(Default)]
pub struct Outlines {
    views: Mutex<HashMap<(u64, String), One>>,
    /// The latest parses `outline/scopes` made, newest last: (file, its text's hash, its definitions); at most
    /// [`PARSED_FILES`], so a scroll or a moved point asks again without parsing again.
    parsed: Mutex<VecDeque<Parsed>>,
}

/// One kept parse: the file, its text's hash, its definitions.
type Parsed = (String, u64, Arc<Vec<OutlineEntry>>);

/// How many files' parses `outline/scopes` keeps.
pub const PARSED_FILES: usize = 8;

impl Outlines {
    fn shown(&self, conn: u64, view: &str) -> Option<Arc<Shown>> {
        lock(&self.views)
            .get(&(conn, view.to_owned()))
            .and_then(|o| o.shown.clone())
    }

    pub(super) fn stop(&self, conn: u64, view: &str) {
        lock(&self.views).remove(&(conn, view.to_owned()));
    }

    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
    }
}

/// What TEXT of PATH shows: its definitions, else a notice.
pub fn shown_of(path: &str, text: &str) -> Shown {
    if too_large(text.len() as u64) {
        return Shown::Notice(LARGE);
    }
    match hrafn::symbols::outline_text(path, text) {
        Some((_, entries)) if !entries.is_empty() => Shown::Entries(entries),
        _ => Shown::Notice(NONE),
    }
}

/// FILE's text as the editor has it (the history's mirror), else as the disk has it; a notice when it is too large or
/// cannot be read.
async fn text_of(f: &Front, file: &str) -> Result<String, &'static str> {
    if let Some((t, _)) = crate::editor::mirror_of(f, file).await {
        return Ok(t);
    }
    let path = file.to_owned();
    crate::clock::blocking(move || {
        let meta = std::fs::metadata(&path).map_err(|_| NONE)?;
        if !meta.is_file() {
            return Err(NONE);
        }
        if too_large(meta.len()) {
            return Err(LARGE);
        }
        let bytes = std::fs::read(&path).map_err(|_| NONE)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    })
    .await
    .unwrap_or(Err(NONE))
}

/// The keys of ENTRIES, in order: `DEPTH:N:NAME`, N counting the earlier entries of that name and depth, so a
/// definition that only moved keeps its key (and its row is not drawn again).
pub fn keys(entries: &[OutlineEntry]) -> Vec<String> {
    let mut seen: HashMap<(&str, u32), u32> = HashMap::new();
    entries
        .iter()
        .map(|e| {
            let n = seen.entry((e.name.as_str(), e.depth)).or_default();
            let key = format!("{}:{}:{}", e.depth, n, e.name);
            *n += 1;
            key
        })
        .collect()
}

/// The key of a notice's row.
pub const NOTICE_KEY: &str = "notice";

/// SHOWN's model: a node per definition with its `line` and `label`, the list `order` in file order (a notice: empty).
pub fn doc(shown: &Shown) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "links",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["order"],
            "classes": ["selected"],
            "flags": [],
            "forms": [],
            "start": "order",
        }),
        ..Doc::default()
    };
    let mut order = Vec::new();
    if let Shown::Entries(entries) = shown {
        for (e, key) in entries.iter().zip(keys(entries)) {
            d.nodes.insert(
                key.clone(),
                json!({"id": key, "kind": e.kind, "flags": 0,
                       "fields": [["label", e.name], ["line", e.line_start]]}),
            );
            order.push(key);
        }
    }
    d.lists.insert("order".into(), order);
    d
}

/// SHOWN's rows in LOOK, and the icon a notice names.  A definition: two columns, two more per definition around it,
/// the name as one row shows it, the key over the row.  A notice: the info icon (a graphical display) and the text,
/// muted, inert.
pub fn rows(shown: &Shown, look: &RowLook) -> (Vec<Row>, Vec<(ImageId, String)>) {
    match shown {
        Shown::Entries(entries) => {
            let rows = entries
                .iter()
                .zip(keys(entries))
                .map(|(e, key)| {
                    let mut r = RowBuilder::new(key.clone());
                    r.push(&" ".repeat(2 + 2 * e.depth as usize), None);
                    r.push(&super::explorer::display(&e.name), None);
                    let end = r.pos();
                    r.prop(0, end, "drgnx-work-id", json!(key));
                    r.finish()
                })
                .collect();
            (rows, Vec::new())
        }
        Shown::Notice(text) => {
            let (row, images) = notice_row(NOTICE_KEY, text, look, true);
            (vec![row], images)
        }
    }
}

/// A notice's row KEY: two columns, the info icon (a graphical display, when ICON) and TEXT, muted, inert.
fn notice_row(key: &str, text: &str, look: &RowLook, icon: bool) -> (Row, Vec<(ImageId, String)>) {
    let mut images = BTreeMap::new();
    let mut r = RowBuilder::new(key);
    r.push("  ", None);
    if let Some((_, size, _)) = look.gui
        && let Some((id, svg)) = icons::svg("info", size)
    {
        if icon {
            images.insert(id, svg);
            r.image(id, " ");
        } else {
            r.push(" ", None); // the icon's place, so the lines start together
        }
        r.push(" ", None);
    }
    r.push(text, None);
    let end = r.pos();
    r.face(0, end, "drgnx-text-muted");
    r.prop(0, end, "drgnx-row-inert", json!(true));
    (r.finish(), images.into_iter().collect())
}

/// SHOWN's rows in LOOK for ENV's window, measured in FONTS: as [`rows`], but a notice wider than the window wraps
/// at its spaces onto rows of its own (keys `notice`, `notice-2`, …) instead of being cut (the store fits every row it
/// publishes to the window, `drgnx_rows::fit_row`): a notice is read whole.
pub fn rows_in(
    shown: &Shown,
    look: &RowLook,
    env: &ViewEnv,
    fonts: &FontSet,
) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let Shown::Notice(text) = shown else {
        return rows(shown, look);
    };
    if env.width_px == 0 || env.headless {
        return rows(shown, look);
    }
    let (_, icon_images) = notice_row(NOTICE_KEY, "", look, true);
    let image_px = |id: &ImageId| {
        icon_images
            .iter()
            .find(|(i, _)| i == id)
            .and_then(|(_, svg)| drgnx_rows::image::svg_width(svg))
    };
    let room = Room {
        width_px: env.width_px,
        tty: matches!(env.display, Display::Tty)
            .then_some((env.cell.0.max(1), env.tty_widths.as_slice())),
        image_px: &image_px,
    };
    let fits = |line: &str, first: bool| {
        let (mut r, _) = notice_row(NOTICE_KEY, line, look, first);
        !fit_row(&mut r, fonts, &room)
    };
    let mut lines: Vec<String> = Vec::new();
    for word in text.split(' ') {
        let first = lines.len() == 1;
        match lines.last_mut() {
            Some(line) if fits(&format!("{line} {word}"), first) => {
                line.push(' ');
                line.push_str(word);
            }
            _ => lines.push(word.to_owned()),
        }
    }
    let mut out = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let key = if i == 0 {
            NOTICE_KEY.to_owned()
        } else {
            format!("{NOTICE_KEY}-{}", i + 1)
        };
        out.push(notice_row(&key, line, look, i == 0).0);
    }
    (out, icon_images)
}

impl Views {
    /// The rows of KEY's view's outline for its class; false when the view has none (no `outline/set` yet).
    pub(super) fn outline_build(&self, f: &Front, key: &Key) -> bool {
        let Some(shown) = self.outlines.shown(key.0, &key.1) else {
            return false;
        };
        self.publish_built(f, key, |env, fonts| {
            rows_in(&shown, &RowLook::of(env, INDENT, 1), env, fonts)
        });
        true
    }

    /// CONN's VIEW shows SHOWN now: the model first, then the rows that changed to every class of it.
    fn outline_publish(&self, f: &Front, conn: u64, view: &str, shown: &Shown) {
        self.publish_model(f, conn, view, doc(shown));
        let classes = lock(&self.store).classes(conn, view);
        for class in classes {
            self.outline_build(f, &(conn, view.to_owned(), class));
        }
    }
}

/// Outline CONN's VIEW's file again for its ask GENERATION; nothing when a later ask came meanwhile.
async fn refresh(f: &Front, conn: u64, view: &str, generation: u64) {
    let file = {
        let views = lock(&f.core.views.outlines.views);
        match views.get(&(conn, view.to_owned())) {
            Some(o) if o.generation == generation => o.file.clone(),
            _ => return,
        }
    };
    let shown = match file {
        None => Shown::Notice(NONE),
        Some(file) => match text_of(f, &file).await {
            Err(notice) => Shown::Notice(notice),
            Ok(text) => crate::clock::blocking(move || shown_of(&file, &text))
                .await
                .unwrap_or(Shown::Notice(NONE)),
        },
    };
    let shown = Arc::new(shown);
    {
        let mut views = lock(&f.core.views.outlines.views);
        match views.get_mut(&(conn, view.to_owned())) {
            Some(o) if o.generation == generation => o.shown = Some(shown.clone()),
            _ => return,
        }
    }
    f.core.views.outline_publish(f, conn, view, &shown);
}

/// `outline/set`: the caller's VIEW shows P's file now; it is outlined before the answer.
pub async fn set(f: &Front, c: &Caller, p: OutlineSet) -> Result<bool, Error> {
    let file = p.file.as_deref().map(crate::work::presence::true_name);
    let generation = {
        let mut views = lock(&f.core.views.outlines.views);
        let o = views.entry((c.conn_id, p.view.clone())).or_default();
        o.file = file;
        o.generation += 1;
        o.generation
    };
    refresh(f, c.conn_id, &p.view, generation).await;
    Ok(true)
}

/// The edit history took an edit to FILE: every view showing it is outlined again once its edits pause.
pub fn touched(f: &Front, file: &str) {
    let file = crate::work::presence::true_name(file);
    let due: Vec<((u64, String), u64)> = {
        let mut views = lock(&f.core.views.outlines.views);
        views
            .iter_mut()
            .filter(|(_, o)| o.file.as_deref() == Some(file.as_str()))
            .map(|(k, o)| {
                o.generation += 1;
                (k.clone(), o.generation)
            })
            .collect()
    };
    let Some(front) = f.core.views.front_weak() else {
        return;
    };
    for ((conn, view), generation) in due {
        let front = front.clone();
        crate::clock::spawn("outline:quiet", async move {
            crate::clock::sleep(QUIET).await;
            if let Some(f) = front.upgrade() {
                refresh(&f, conn, &view, generation).await;
            }
        });
    }
}

/// The definitions of ENTRIES (in file order, as [`hrafn::symbols::outline_text`] gives them) that hold LINE,
/// outermost first: the ones that start on it or above and end on it or below.
pub fn scopes_at(entries: &[OutlineEntry], line: u32) -> Vec<OutlineScope> {
    entries
        .iter()
        .filter(|e| e.line_start <= line && line <= e.line_end)
        .map(|e| OutlineScope {
            name: e.name.clone(),
            line: e.line_start,
        })
        .collect()
}

/// FILE's definitions for its text TEXT: the parse kept for that text, else a new one (kept, the oldest let go past
/// [`PARSED_FILES`]).
async fn parsed(f: &Front, file: &str, text: String) -> Arc<Vec<OutlineEntry>> {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut h);
    let hash = h.finish();
    {
        let kept = lock(&f.core.views.outlines.parsed);
        if let Some((_, _, e)) = kept.iter().find(|(p, t, _)| p == file && *t == hash) {
            return e.clone();
        }
    }
    let path = file.to_owned();
    let entries = crate::clock::blocking(move || match shown_of(&path, &text) {
        Shown::Entries(e) => e,
        Shown::Notice(_) => Vec::new(),
    })
    .await
    .unwrap_or_default();
    let entries = Arc::new(entries);
    let mut kept = lock(&f.core.views.outlines.parsed);
    kept.retain(|(p, _, _)| p != file);
    kept.push_back((file.to_owned(), hash, entries.clone()));
    while kept.len() > PARSED_FILES {
        kept.pop_front();
    }
    entries
}

/// `outline/scopes`: the definitions around P's line of its file, from the text the Outline reads (the size guard
/// included: a file past it has none).
pub async fn scopes(f: &Front, p: OutlineScopesParams) -> Result<OutlineScopes, Error> {
    let file = match (&p.file, &p.worktree_root, &p.path) {
        (Some(f), _, _) => f.clone(),
        (None, Some(root), Some(path)) => std::path::Path::new(root)
            .join(path)
            .to_string_lossy()
            .into_owned(),
        _ => return Ok(OutlineScopes { scopes: Vec::new() }),
    };
    let file = crate::work::presence::true_name(&file);
    let Ok(text) = text_of(f, &file).await else {
        return Ok(OutlineScopes { scopes: Vec::new() });
    };
    let entries = parsed(f, &file, text).await;
    Ok(OutlineScopes {
        scopes: scopes_at(&entries, p.line),
    })
}

#[cfg(test)]
mod tests;
