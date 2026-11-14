//! The Buffers panel's rows (`buffers/set`): the editor tells the hub which buffers are open (and only when that set,
//! a name or an unsaved flag changes), the window's scope and the filter; the hub keeps them per (connection, view) in
//! the order they were first put and builds one row per buffer shown: the file's icon, the name (dimmed when git
//! ignores the file), the git status and the unsaved flag over the name, the buffer's id over the row. The editor draws
//! the right edge (the git letter, ● or the close button) from those properties, for the rows it drew.

use super::explorer::{INDENT, RowLook};
use super::{Key, Views, git, icons, lock};
use crate::dispatch::Caller;
use crate::front::Front;
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::view::{BufferOp, BuffersSet};
use runstav::wire::Error;
use serde_json::json;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// One open buffer as the editor sent it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Buf {
    pub id: String,
    pub name: String,
    pub file: Option<String>,
    pub modified: bool,
}

/// One view's open buffers: each id's place in the open order, the buffers by that place, the scope (the ids on rows
/// when the window's buffers are shown, none: all) and the filter (lower case).
#[derive(Debug, Default)]
pub struct Set {
    seq: u64,
    at: HashMap<String, u64>,
    order: BTreeMap<u64, Buf>,
    scope: Option<HashSet<String>>,
    filter: Option<String>,
}

impl Set {
    /// OPS applied in order.
    pub fn apply(&mut self, ops: Vec<BufferOp>) {
        for op in ops {
            match op {
                BufferOp::Reset => {
                    self.at.clear();
                    self.order.clear();
                }
                BufferOp::Put {
                    id,
                    name,
                    file,
                    modified,
                } => {
                    let buf = Buf {
                        id: id.clone(),
                        name,
                        file,
                        modified,
                    };
                    let at = match self.at.get(&id) {
                        Some(at) => *at,
                        None => {
                            self.seq += 1;
                            self.at.insert(id, self.seq);
                            self.seq
                        }
                    };
                    self.order.insert(at, buf);
                }
                BufferOp::Modified { id, modified } => {
                    if let Some(b) = self.at.get(&id).and_then(|at| self.order.get_mut(at)) {
                        b.modified = modified;
                    }
                }
                BufferOp::Remove { id } => {
                    if let Some(at) = self.at.remove(&id) {
                        self.order.remove(&at);
                    }
                }
                BufferOp::Scope { ids } => self.scope = ids.map(|ids| ids.into_iter().collect()),
                BufferOp::Filter { text } => {
                    self.filter = text.filter(|t| !t.is_empty()).map(|t| t.to_lowercase())
                }
            }
        }
    }

    /// The buffers on rows, in the open order: those in the scope whose names hold the filter (any case).
    pub fn shown(&self) -> Vec<Buf> {
        self.order
            .values()
            .filter(|b| self.scope.as_ref().is_none_or(|s| s.contains(&b.id)))
            .filter(|b| {
                self.filter
                    .as_ref()
                    .is_none_or(|q| b.name.to_lowercase().contains(q.as_str()))
            })
            .cloned()
            .collect()
    }
}

/// The open buffers of every (connection, view) that sent them.
#[derive(Default)]
pub struct Buffers {
    sets: Mutex<HashMap<(u64, String), Set>>,
}

impl Buffers {
    fn shown(&self, conn: u64, view: &str) -> Option<Vec<Buf>> {
        lock(&self.sets)
            .get(&(conn, view.to_owned()))
            .map(Set::shown)
    }

    fn views_of(&self, conn: u64) -> Vec<String> {
        lock(&self.sets)
            .keys()
            .filter(|(c, _)| *c == conn)
            .map(|(_, v)| v.clone())
            .collect()
    }

    pub(super) fn stop(&self, conn: u64, view: &str) {
        lock(&self.sets).remove(&(conn, view.to_owned()));
    }

    pub(super) fn gone(&self, conn: u64) {
        lock(&self.sets).retain(|(c, _), _| *c != conn);
    }
}

/// FILE's git status from STATUSES (each a repository's root and its last read status): its own, else an ignored or
/// untracked folder's around it.
pub fn mark_of(file: &str, statuses: &[(PathBuf, Arc<git::Status>)]) -> Option<git::Kind> {
    statuses.iter().find_map(|(root, st)| {
        let root = root.to_string_lossy();
        let rel = file
            .strip_prefix(root.trim_end_matches('/'))?
            .strip_prefix('/')?;
        st.files.get(rel).copied().or_else(|| {
            let mut above = rel;
            while let Some(i) = above.rfind('/') {
                above = &above[..i];
                if let Some(k @ (git::Kind::Ignored | git::Kind::Untracked)) = st.files.get(above) {
                    return Some(*k);
                }
            }
            None
        })
    })
}

/// B's row in LOOK: two characters of room (on a graphical display a space, then the file's icon with the gap either
/// side, as the Explorer's top files), then the name as one row shows it; the git status (not ignored: the name is
/// dimmed) and the unsaved flag over the name, the id over the row. Icons go into IMAGES.
fn buffer_row(
    b: &Buf,
    mark: Option<git::Kind>,
    look: &RowLook,
    images: &mut BTreeMap<ImageId, String>,
) -> Row {
    let mut r = RowBuilder::new(b.id.clone());
    match look.gui {
        Some((_, icon, gap)) => {
            r.push(" ", None);
            r.space(gap, icon, "default");
            let kind = icons::file_icon(file_name(b));
            match icons::svg(kind, icon) {
                Some((id, svg)) => {
                    images.insert(id, svg);
                    r.image(id, " ");
                }
                None => {
                    r.push(" ", None);
                }
            }
            r.space(gap, icon, "default");
        }
        None => {
            r.push("  ", None);
        }
    }
    let name = r.pos();
    let ignored = mark == Some(git::Kind::Ignored);
    r.push(
        &super::explorer::display(&b.name),
        ignored.then_some("drgnx-git-ignored"),
    );
    let end = r.pos();
    if let Some(k) = mark.filter(|_| !ignored) {
        r.prop(name, end, "drgnx-git-status", json!(k.name()));
    }
    if b.modified {
        r.prop(name, end, "drgnx-buffers-modified", json!(true));
    }
    r.prop(0, end, "drgnx-work-id", json!(b.id));
    r.finish()
}

/// The name B's icon is chosen by: its file's, else the buffer's.
fn file_name(b: &Buf) -> &str {
    b.file
        .as_deref()
        .map(|f| f.trim_end_matches('/'))
        .and_then(|f| f.rsplit('/').next())
        .filter(|n| !n.is_empty())
        .unwrap_or(&b.name)
}

/// The rows of SHOWN in LOOK, the git marks from STATUSES, and the icons they name (each once).
pub fn buffer_rows(
    shown: &[Buf],
    statuses: &[(PathBuf, Arc<git::Status>)],
    look: &RowLook,
) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut images = BTreeMap::new();
    let rows = shown
        .iter()
        .map(|b| {
            let mark = b.file.as_deref().and_then(|f| mark_of(f, statuses));
            buffer_row(b, mark, look, &mut images)
        })
        .collect();
    (rows, images.into_iter().collect())
}

impl Views {
    /// The rows of KEY's view's buffers for its class; false when the view has none (no `buffers/set` yet).
    pub(super) fn buffers_build(&self, f: &Front, key: &Key) -> bool {
        let Some(shown) = self.buffers.shown(key.0, &key.1) else {
            return false;
        };
        let statuses = self.letters.statuses(key.0);
        self.publish_built(f, key, |env, _| {
            buffer_rows(&shown, &statuses, &RowLook::of(env, INDENT, 1))
        });
        true
    }

    /// Every class of CONN's VIEW gets its buffers' rows again; only the rows that changed go out.
    fn buffers_all(&self, f: &Front, conn: u64, view: &str) {
        let classes = lock(&self.store).classes(conn, view);
        for class in classes {
            self.buffers_build(f, &(conn, view.to_owned(), class));
        }
    }

    /// CONN's git statuses changed (`git/letters` read one): its Buffers panels draw their marks again.
    pub(super) fn buffers_decor_changed(&self, f: &Front, conn: u64) {
        for view in self.buffers.views_of(conn) {
            self.buffers_all(f, conn, &view);
        }
    }
}

/// `buffers/set`: P's changes to the caller's VIEW's open buffers, then the rows that changed to every class of it.
pub fn set(f: &Front, c: &Caller, p: BuffersSet) -> Result<bool, Error> {
    let views = &f.core.views;
    lock(&views.buffers.sets)
        .entry((c.conn_id, p.view.clone()))
        .or_default()
        .apply(p.ops);
    views.buffers_all(f, c.conn_id, &p.view);
    Ok(true)
}

#[cfg(test)]
mod tests;
