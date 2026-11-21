//! The shared write path (docs/develop/hub.md, "The Search view's writes"): change sets, their apply and their undo.
//!
//! - **A change set** is an edit set (`search/edits`, [`super::edits`]) kept under a number, then what its apply wrote:
//!   per file how (the hub on disk, or the editor in its buffer) and the inverse edits. The hub keeps the last
//!   [`KEEP`].
//! - **The apply** (`search/apply`) takes each file's turn in the hub's write queue, the pair door's
//!   ([`crate::pair::door::Door::user_turn`]), so a paired chat's writes and the user's never interleave on a file.
//!   Just before writing, the open set is asked who has the file: an editor (the door's open set, or the asking
//!   editor's own list of its buffers) gets `search-apply` and answers `search/applied`; no answer within the door's
//!   time to live skips the file ("the editor did not answer"), never written behind its buffer. Any other file is
//!   written on disk ([`crate::pair::disk::replace`]) only when its bytes are the ones the edit set read ("changed on
//!   disk since the preview").
//! - **Undo** (`search/undo`) writes the inverse edits by the same queue; a file edited since (its digest or its
//!   buffer's tick not the ones after the write) is left alone and named.
//! - The end of either is `search-change` to the asking connection.

use super::edits::{CHANGED_SINCE_PREVIEW, GONE, Planned, splice, unwritable};
use crate::front::Front;
use crate::pair::Refusal;
use crate::pair::door::{MARGIN, TTL_MS};
use crate::pair::open_set::Route;
use runstav::methods::search::{
    AppliedParams, ChangeDone, ChangeOrigin, EditSkip, SearchApply, SearchEdit,
};
use serde_json::json;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;
use xxhash_rust::xxh3::xxh3_64;

/// How many change sets the hub keeps (Undo reaches this far back).
pub(super) const KEEP: usize = 20;

/// What a file is skipped with when its editor did not answer in time.
pub(super) const NO_ANSWER: &str = "the editor did not answer";

/// What an undo leaves a file alone with.
pub(super) const EDITED_SINCE: &str = "edited since the replacement";

/// How a file of a change set was written.
#[derive(Clone, Debug, PartialEq)]
pub(super) enum By {
    /// On disk by the hub: the digest of the bytes it wrote.
    Disk { after: u64 },
    /// In the editor's buffer: its tick after the write, and when it saved, the digest of the file then.
    Editor {
        tick: Option<u64>,
        after: Option<u64>,
    },
}

/// A file a change set wrote: how, and the edits that put it back.
#[derive(Clone, Debug)]
pub(super) struct Written {
    pub path: String,
    pub by: By,
    pub inverse: Vec<SearchEdit>,
}

/// A change set: the files to write (its edit set) and, once applied, what was written.
#[derive(Clone, Debug)]
pub(super) struct ChangeSet {
    pub id: u64,
    pub conn: u64,
    pub view: String,
    pub root: PathBuf,
    pub origin: ChangeOrigin,
    pub undoes: Option<u64>,
    pub files: Vec<Planned>,
    /// Its apply started (a change set is written once).
    pub started: bool,
    pub written: Vec<Written>,
}

/// The hub's change sets, and the editors' answers waited for.
#[derive(Default)]
pub(super) struct Changes {
    st: Mutex<St>,
}

#[derive(Default)]
struct St {
    next: u64,
    sets: VecDeque<ChangeSet>,
    waiting: HashMap<(u64, String), oneshot::Sender<AppliedParams>>,
}

fn lock(m: &Mutex<St>) -> std::sync::MutexGuard<'_, St> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Changes {
    /// A new change set of CONN's VIEW: its number.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn add(
        &self,
        conn: u64,
        view: &str,
        root: PathBuf,
        origin: ChangeOrigin,
        undoes: Option<u64>,
        files: Vec<Planned>,
    ) -> u64 {
        let mut st = lock(&self.st);
        st.next += 1;
        let id = st.next;
        st.sets.push_back(ChangeSet {
            id,
            conn,
            view: view.to_owned(),
            root,
            origin,
            undoes,
            files,
            started: false,
            written: Vec::new(),
        });
        while st.sets.len() > KEEP {
            st.sets.pop_front();
        }
        id
    }

    /// Change set ID of CONN, marked started: none when there is none, another connection's, or started already.
    fn start(&self, conn: u64, id: u64) -> Option<ChangeSet> {
        let mut st = lock(&self.st);
        let set = st.sets.iter_mut().find(|s| s.id == id && s.conn == conn)?;
        if set.started {
            return None;
        }
        set.started = true;
        Some(set.clone())
    }

    /// Change set ID of CONN as it is now (an undo reads what it wrote).
    pub(super) fn get(&self, conn: u64, id: u64) -> Option<ChangeSet> {
        lock(&self.st)
            .sets
            .iter()
            .find(|s| s.id == id && s.conn == conn)
            .cloned()
    }

    fn written(&self, id: u64, w: Written) {
        if let Some(s) = lock(&self.st).sets.iter_mut().find(|s| s.id == id) {
            s.written.retain(|o| o.path != w.path);
            s.written.push(w);
        }
    }

    /// The editor's answer A: to the write waiting for it (true), or, past its time, recorded with its change set
    /// still (false), so Undo puts back what it wrote late.
    pub(super) fn answer(&self, a: AppliedParams) -> bool {
        let tx = lock(&self.st).waiting.remove(&(a.change, a.path.clone()));
        match tx {
            Some(tx) => tx.send(a).is_ok(),
            None => {
                if !a.applied.is_empty() {
                    let after = a.saved.then(|| digest_of(Path::new(&a.path))).flatten();
                    self.written(
                        a.change,
                        Written {
                            path: a.path.clone(),
                            by: By::Editor {
                                tick: a.tick,
                                after,
                            },
                            inverse: a.inverse,
                        },
                    );
                }
                false
            }
        }
    }
}

/// The digest of FILE's bytes now; none when it cannot be read.
fn digest_of(file: &Path) -> Option<u64> {
    std::fs::read(file).ok().map(|b| xxh3_64(&b))
}

/// Where the write of FILE goes now: the editor that has it (the door's open set, else the asking connection CONN
/// when its list OPEN names it), refused (a large or remote buffer, an editor away), or none: the disk.
fn target(
    f: &Front,
    file: &Path,
    open: &HashSet<String>,
    conn: u64,
) -> Option<Result<u64, String>> {
    match f.pair.route(file) {
        Route::Editor(c) => Some(Ok(c)),
        Route::Refused(why) => Some(Err(why.to_owned())),
        Route::Disk => open
            .contains(file.to_string_lossy().as_ref())
            .then_some(Ok(conn)),
    }
}

/// The editor C writes EDITS of PATH (change set CHANGE of VIEW) in its buffer: its answer, or why not.
async fn ask_editor(
    f: &Front,
    c: u64,
    change: u64,
    view: &str,
    path: &str,
    edits: Vec<SearchEdit>,
    tick: Option<u64>,
) -> Result<AppliedParams, String> {
    let changes = &f.core.views.greps.changes;
    let (tx, rx) = oneshot::channel();
    let key = (change, path.to_owned());
    lock(&changes.st).waiting.insert(key.clone(), tx);
    let ev = SearchApply {
        view: view.to_owned(),
        change,
        path: path.to_owned(),
        edits,
        ttl_ms: TTL_MS,
        tick,
    };
    if !f.send_to(c, "search-apply", json!(ev)) {
        lock(&changes.st).waiting.remove(&key);
        return Err(crate::pair::door::EDITOR_AWAY.to_owned());
    }
    let got = crate::clock::timeout(std::time::Duration::from_millis(TTL_MS) + MARGIN, rx).await;
    lock(&changes.st).waiting.remove(&key);
    match got {
        Ok(Ok(a)) => Ok(a),
        _ => Err(NO_ANSWER.to_owned()),
    }
}

/// FILE (inside ROOT) on disk, written with EDITS when its bytes are still those of digest EXPECT: the digest of the
/// bytes written, the inverse edits and the attributes the new file did not keep (`disk::replace`), or why not.
/// Blocking.
pub(super) fn write_disk(
    root: &Path,
    file: &Path,
    expect: u64,
    edits: &[SearchEdit],
) -> Result<(u64, Vec<SearchEdit>, Vec<String>), String> {
    let real = file.canonicalize().map_err(|_| GONE.to_owned())?;
    let mut out = None;
    let lost = crate::pair::disk::replace(
        root,
        &real,
        |raw| {
            let raw = raw.ok_or_else(|| Refusal(GONE.into()))?;
            if xxh3_64(raw) != expect {
                return Err(Refusal(CHANGED_SINCE_PREVIEW.into()));
            }
            if let Some(why) = unwritable(raw) {
                return Err(Refusal(why.into()));
            }
            let text = std::str::from_utf8(raw).map_err(|e| Refusal(e.to_string()))?;
            let (new, inverse) = splice(text, edits).map_err(Refusal)?;
            let bytes = new.into_bytes();
            out = Some((xxh3_64(&bytes), inverse));
            Ok(bytes)
        },
        None,
        CHANGED_SINCE_PREVIEW,
    )
    .map_err(|r| r.0)?;
    out.map(|(after, inverse)| (after, inverse, lost))
        .ok_or_else(|| GONE.to_owned())
}

/// What one change set's run wrote, for its `search-change`.
#[derive(Default)]
struct Tally {
    written: u64,
    files: u64,
    skipped: Vec<EditSkip>,
    left: Vec<String>,
    /// Attribute name → how many files written on disk did not keep it.
    lost: std::collections::BTreeMap<String, u64>,
}

impl Tally {
    fn skip_all(&mut self, path: &str, edits: &[SearchEdit], why: &str) {
        self.skipped.extend(edits.iter().map(|e| EditSkip {
            id: Some(e.id.clone()),
            path: path.to_owned(),
            why: why.to_owned(),
        }));
    }

    /// One log line for the run's attributes not kept (`N files: security.selinux not kept`), none when all were.
    fn log_lost(&self) {
        for (name, n) in &self.lost {
            tracing::info!("{n} file(s): {name} not kept");
        }
    }

    fn done(self, set: &ChangeSet) -> ChangeDone {
        ChangeDone {
            view: set.view.clone(),
            change: set.id,
            origin: set.origin,
            undoes: set.undoes,
            written: self.written,
            files: self.files,
            skipped: self.skipped,
            left: self.left,
        }
    }
}

/// One file of SET written with EDITS (TICK: an undo's buffer tick), by its editor or on disk over digest EXPECT
/// (none: the disk is not written, the file is left alone with NO_DISK). Recorded with the set; the tally counts it.
#[allow(clippy::too_many_arguments)]
async fn write_file(
    f: &Arc<Front>,
    set: &ChangeSet,
    open: &HashSet<String>,
    path: &str,
    edits: Vec<SearchEdit>,
    tick: Option<u64>,
    expect: Result<u64, &str>,
    tally: &mut Tally,
) {
    let changes = &f.core.views.greps.changes;
    let file = PathBuf::from(path);
    let _turn = f.pair.user_turn(&file).await;
    let editor = match target(f, &file, open, set.conn) {
        Some(Err(why)) => return tally.skip_all(path, &edits, &why),
        Some(Ok(c)) => match ask_editor(f, c, set.id, &set.view, path, edits.clone(), tick).await {
            Err(why) => return tally.skip_all(path, &edits, &why),
            Ok(a) if a.not_open => None,
            Ok(a) => Some(a),
        },
        None => None,
    };
    if let Some(a) = editor {
        let path_of = |id: String, why: String| EditSkip {
            id: Some(id),
            path: path.to_owned(),
            why,
        };
        if set.origin == ChangeOrigin::Undo && a.applied.is_empty() && !a.skipped.is_empty() {
            tally.left.push(path.to_owned());
        }
        tally
            .skipped
            .extend(a.skipped.into_iter().map(|s| path_of(s.id, s.why)));
        if a.applied.is_empty() {
            return;
        }
        tally.written += a.applied.len() as u64;
        tally.files += 1;
        let after = if a.saved {
            let p = file.clone();
            crate::clock::blocking(move || digest_of(&p))
                .await
                .ok()
                .flatten()
        } else {
            None
        };
        changes.written(
            set.id,
            Written {
                path: path.to_owned(),
                by: By::Editor {
                    tick: a.tick,
                    after,
                },
                inverse: a.inverse,
            },
        );
        return;
    }
    let expect = match expect {
        Ok(d) => d,
        Err(why) => {
            if set.origin == ChangeOrigin::Undo {
                tally.left.push(path.to_owned());
            }
            return tally.skip_all(path, &edits, why);
        }
    };
    let (root, p, es) = (set.root.clone(), file.clone(), edits.clone());
    let res = crate::clock::blocking(move || write_disk(&root, &p, expect, &es))
        .await
        .unwrap_or_else(|e| Err(e.to_string()));
    match res {
        Ok((after, inverse, lost)) => {
            for name in lost {
                *tally.lost.entry(name).or_default() += 1;
            }
            tally.written += edits.len() as u64;
            tally.files += 1;
            changes.written(
                set.id,
                Written {
                    path: path.to_owned(),
                    by: By::Disk { after },
                    inverse,
                },
            );
        }
        Err(why) => {
            if set.origin == ChangeOrigin::Undo {
                tally.left.push(path.to_owned());
            }
            tally.skip_all(path, &edits, &why)
        }
    }
}

/// `search/apply`: change set CHANGE of the caller CONN written, file by file, on a task of its own; its end is
/// `search-change`. False when there is no such change set, or its apply ran already.
pub(super) fn apply(f: &Arc<Front>, conn: u64, change: u64, open: Vec<String>) -> bool {
    let Some(set) = f.core.views.greps.changes.start(conn, change) else {
        return false;
    };
    let f = f.clone();
    let open: HashSet<String> = open.into_iter().collect();
    crate::clock::spawn("search:apply", async move {
        let mut tally = Tally::default();
        for p in &set.files {
            write_file(
                &f,
                &set,
                &open,
                &p.path,
                p.edits.clone(),
                None,
                Ok(p.xxh3),
                &mut tally,
            )
            .await;
        }
        tally.log_lost();
        f.send_to(set.conn, "search-change", json!(tally.done(&set)));
    });
    true
}

/// `search/undo`: change set CHANGE of the caller CONN put back by a new change set (origin undo), on a task of its
/// own; its end is `search-change`. False when there is no such change set.
pub(super) fn undo(f: &Arc<Front>, conn: u64, change: u64, open: Vec<String>) -> bool {
    let changes = &f.core.views.greps.changes;
    let Some(old) = changes.get(conn, change) else {
        return false;
    };
    let id = changes.add(
        conn,
        &old.view,
        old.root.clone(),
        ChangeOrigin::Undo,
        Some(change),
        Vec::new(),
    );
    let Some(set) = changes.start(conn, id) else {
        return false;
    };
    let f = f.clone();
    let open: HashSet<String> = open.into_iter().collect();
    crate::clock::spawn("search:undo", async move {
        let mut tally = Tally::default();
        for w in &old.written {
            // the editor checks its tick; the disk is written only over the digest after the write
            let (tick, expect) = match w.by {
                By::Disk { after } => (None, Ok(after)),
                By::Editor { tick, after } => (
                    Some(tick.unwrap_or(0)),
                    after.ok_or("closed without saving: undo it in its buffer"),
                ),
            };
            let expect = match expect {
                Ok(d) => {
                    let p = PathBuf::from(&w.path);
                    let now = crate::clock::blocking(move || digest_of(&p))
                        .await
                        .ok()
                        .flatten();
                    if now == Some(d) {
                        Ok(d)
                    } else {
                        Err(EDITED_SINCE)
                    }
                }
                Err(e) => Err(e),
            };
            // a file on disk edited since is left alone before any editor is asked
            if let (Err(why), By::Disk { .. }) = (expect, &w.by) {
                tally.left.push(w.path.clone());
                tally.skip_all(&w.path, &w.inverse, why);
                continue;
            }
            write_file(
                &f,
                &set,
                &open,
                &w.path,
                w.inverse.clone(),
                tick,
                expect,
                &mut tally,
            )
            .await;
        }
        tally.log_lost();
        f.send_to(set.conn, "search-change", json!(tally.done(&set)));
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn edit(id: &str, line: u32, col: u32, old: &str, new: &str) -> SearchEdit {
        SearchEdit {
            id: id.into(),
            line,
            col,
            end_line: line,
            end_col: col + old.chars().count() as u32,
            byte_start: 0,
            byte_end: 0,
            old: old.into(),
            new: new.into(),
        }
    }

    /// [D] A closed file is written only over the bytes the edit set read: its mode kept, the inverse puts it back; a
    /// file changed since the preview, or gone, is not written.
    #[test]
    fn disk_writes_check_the_digest_and_keep_the_mode() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        let f = root.join("a.txt");
        std::fs::write(&f, "x pending y\r\n").unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o640)).unwrap();
        let read = xxh3_64(b"x pending y\r\n");
        let es = [edit("m:1:0", 1, 2, "pending", "queued")];
        assert_eq!(
            write_disk(&root, &f, read ^ 1, &es).unwrap_err(),
            CHANGED_SINCE_PREVIEW
        );
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "x pending y\r\n");
        let (after, inverse, _) = write_disk(&root, &f, read, &es).unwrap();
        assert_eq!(
            std::fs::read_to_string(&f).unwrap(),
            "x queued y\r\n",
            "CRLF kept as it was"
        );
        assert_eq!(after, xxh3_64(b"x queued y\r\n"));
        assert_eq!(
            std::fs::metadata(&f).unwrap().permissions().mode() & 0o777,
            0o640
        );
        write_disk(&root, &f, after, &inverse).unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "x pending y\r\n");
        assert_eq!(
            write_disk(&root, &root.join("none"), 0, &es).unwrap_err(),
            GONE
        );
        let left: Vec<_> = std::fs::read_dir(&root).unwrap().collect();
        assert_eq!(left.len(), 1, "no temporary file left behind");
    }

    /// [D] Change sets: one per number, written once, another connection's not reachable, the last KEEP kept; an
    /// editor's answer that comes after its time is still recorded, so Undo reaches what it wrote.
    #[test]
    fn change_sets_are_kept_and_late_answers_recorded() {
        let c = Changes::default();
        let id = c.add(
            1,
            "s",
            "/r".into(),
            ChangeOrigin::ReplaceAll,
            None,
            Vec::new(),
        );
        assert!(c.start(2, id).is_none(), "another connection's");
        assert!(c.start(1, id).is_some());
        assert!(c.start(1, id).is_none(), "written once");
        let late = AppliedParams {
            change: id,
            path: "/r/a.txt".into(),
            applied: vec!["m:1:0".into()],
            skipped: vec![],
            inverse: vec![edit("m:1:0", 1, 0, "b", "a")],
            tick: Some(9),
            saved: false,
            not_open: false,
        };
        assert!(!c.answer(late), "nobody waited for it");
        let w = &c.get(1, id).unwrap().written;
        assert_eq!(w.len(), 1);
        assert_eq!(
            w[0].by,
            By::Editor {
                tick: Some(9),
                after: None
            }
        );
        for _ in 0..KEEP {
            c.add(
                1,
                "s",
                "/r".into(),
                ChangeOrigin::ReplaceAll,
                None,
                Vec::new(),
            );
        }
        assert!(c.get(1, id).is_none(), "only the last {KEEP} are kept");
    }
}
