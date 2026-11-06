//! One hunk of an agent's record reverted, and who undid each hunk (`docs/develop/hub.md`, "One hunk of a record"):
//! `history/op/hunks` lists a record's hunks, or every record of a session's agent on a worktree's branch (a paired
//! chat writes the user's buffers, so its records are there); `history/revert/hunk` reverts one, keeping the user's
//! later typing.  The hub never writes behind an open buffer: when an editor buffer tracks the file, the editor applies
//! the edits as the origin `revert:<op>` and its batch writes the `revert` record ([`Hub::batch`]).  User only.

use super::capture::Seen;
use super::origin::OriginEv;
use super::revert::{refused, user_only};
use super::{Hub, Tree};
use crate::agents::session::{internal, invalid};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::history as w;
use runstav::wire::Error as WireError;
use serde_json::{Value, json};
use std::os::fd::AsFd;
use std::path::Path;
use std::sync::Arc;
use verdandi::{
    Change, Error, FlushReason, HunkConflict, HunkPlan, HunkState, OpHunk, OpId, Result,
};

/// What a hunk's revert did.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// Applied by the hub, the file written: the `revert` record.
    Applied(OpId),
    /// An editor buffer holds the file: it applies EDITS when its text hashes to VERSION.
    InBuffer {
        buffer_id: String,
        version: String,
        edits: Vec<Change>,
    },
    Conflict(HunkConflict),
    /// Undone already, by these records.
    Undone(Vec<OpId>),
}

/// A hunk and, per record that undid it, that record's author.
pub type Listed = (OpHunk, Vec<(OpId, Option<Value>)>);

impl Hub {
    /// The hunks of record OP, or of every record of SESSION's agent, on TREE's branch.  Typing not settled yet is
    /// written into its records first, so "undone by" names them.
    pub fn op_hunks(
        &self,
        tree: &Tree,
        op: Option<i64>,
        session: Option<&str>,
        now: f64,
    ) -> Result<Vec<Listed>> {
        let mut g = self.lock();
        let inner = &mut *g;
        inner
            .settler
            .flush(&mut inner.h, FlushReason::Revert, now)?;
        let branch = inner.branch(tree)?;
        let ops = match (op, session) {
            (Some(op), _) => vec![OpId(op)],
            (None, Some(s)) => inner.h.records_of(branch, s)?,
            (None, None) => Vec::new(),
        };
        let mut out = Vec::new();
        for op in ops {
            for h in inner.h.op_hunks(branch, op)? {
                let mut by = Vec::new();
                for o in &h.undone_by {
                    let author = inner.h.author_of(inner.h.op(*o)?.author)?;
                    by.push((*o, author));
                }
                out.push((h, by));
            }
        }
        Ok(out)
    }

    /// Revert hunk INDEX of record OP in REL of TREE as the user's operations at NOW.  With an editor buffer tracking
    /// the file, the edits go to it; else the hub applies them and writes the file, refused as stale when the disk
    /// is not what the history holds.
    pub fn revert_hunk(
        &self,
        tree: &Tree,
        op: i64,
        rel: &str,
        index: usize,
        now: f64,
    ) -> Result<Outcome> {
        let mut g = self.lock();
        let inner = &mut *g;
        inner
            .settler
            .flush(&mut inner.h, FlushReason::Revert, now)?;
        let branch = inner.branch(tree)?;
        let doc = inner.h.doc_for(rel)?;
        let op = OpId(op);
        let text = inner
            .h
            .activate(doc, branch, || {
                Ok(super::capture::base_text(tree, rel).unwrap_or_default())
            })?
            .text();
        let edits = match inner.h.plan_hunk_revert(branch, op, doc, index)? {
            HunkPlan::Edits(e) => e,
            HunkPlan::Conflict(c) => return Ok(Outcome::Conflict(c)),
            HunkPlan::Undone(by) => return Ok(Outcome::Undone(by)),
        };
        if let Some((id, _)) = inner
            .buffers
            .iter()
            .find(|(_, b)| b.doc == doc && b.branch == branch)
        {
            return Ok(Outcome::InBuffer {
                buffer_id: id.clone(),
                version: super::methods::hash(&text),
                edits,
            });
        }
        let disk = match super::capture::read(tree, rel) {
            Seen::Bytes(b) => b,
            _ => return Err(Error::Refused(format!("stale: {rel} is no text file here"))),
        };
        if disk != text.as_bytes() {
            return Err(Error::Refused(format!(
                "stale: {rel} on disk differs from its history: save it, then try again"
            )));
        }
        let peer = inner.peer(branch, "user", &json!({"kind": "user"}))?;
        let rev = inner
            .h
            .apply_hunk_revert(branch, op, doc, &edits, peer, now)?;
        let after = inner.h.text(doc, branch)?;
        // the hub's own version: the watcher's event about it is no outside edit
        if let Ok(hash) = super::blob::hash_object(&tree.git_dir, &tree.root, rel, after.as_bytes())
        {
            inner.origin.step(OriginEv::HubWrite {
                path: rel.to_owned(),
                hash,
            });
        }
        let dir = std::fs::File::open(&tree.root)?;
        let mode = eitri::open_beneath(dir.as_fd(), Path::new(rel), eitri::Kind::File)
            .ok()
            .and_then(|o| rustix::fs::fstat(&o.fd).ok())
            .map_or(0o644, |st| st.st_mode & 0o777);
        eitri::write_regular(dir.as_fd(), Path::new(rel), after.as_bytes(), mode)
            .map_err(|e| Error::Refused(format!("{rel}: {e}")))?;
        Ok(Outcome::Applied(rev))
    }
}

fn store(e: Error) -> WireError {
    match e {
        Error::Refused(m) => invalid("history", m),
        Error::NotFound(m) => invalid("history", format!("not found: {m}")),
        e => internal(e.to_string()),
    }
}

fn tree_of(f: &Front, worktree: &str) -> std::result::Result<(Arc<Hub>, Tree), WireError> {
    let dir = f
        .dirs
        .get()
        .map(|d| d.hub.clone())
        .ok_or_else(|| internal("the hub has no state folder"))?;
    f.core.history.of_tree(&dir, Path::new(worktree))
}

fn n(v: usize) -> i64 {
    i64::try_from(v).unwrap_or(i64::MAX)
}

fn undone_by(by: Vec<(OpId, Option<Value>)>) -> Vec<w::UndoneBy> {
    by.into_iter()
        .map(|(op, author)| w::UndoneBy { op: op.0, author })
        .collect()
}

/// `history/op/hunks`.
pub async fn op_hunks(
    f: &Front,
    c: &Caller,
    p: w::OpHunksParams,
) -> std::result::Result<w::OpHunks, WireError> {
    user_only(c)?;
    if p.op.is_some() == p.session.is_some() {
        return Err(invalid("op", "name one record (op) or one session"));
    }
    let (hub, tree) = tree_of(f, &p.worktree)?;
    let session = p
        .session
        .map(|s| s.trim_start_matches("session:").to_owned());
    // the time is read here: a blocking thread does not carry the virtual clock
    let now = crate::clock::wall_secs();
    let listed = crate::clock::blocking(move || hub.op_hunks(&tree, p.op, session.as_deref(), now))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(store)?;
    Ok(w::OpHunks {
        hunks: listed
            .into_iter()
            .map(|(h, by)| w::OpHunk {
                op: h.op.0,
                path: h.path,
                index: n(h.index),
                start_line: n(h.start_line),
                end_line: n(h.end_line),
                text: h.text,
                deleted: h.deleted,
                state: match h.state {
                    HunkState::Live => w::HunkState::Live,
                    HunkState::PartlyUndone => w::HunkState::PartlyUndone,
                    HunkState::Undone => w::HunkState::Undone,
                },
                undone_by: undone_by(by),
            })
            .collect(),
    })
}

/// `history/revert/hunk`: one at a time per worktree, beside its reverts, redos and takes.
pub async fn revert_hunk(
    f: &Front,
    c: &Caller,
    p: w::RevertHunkParams,
) -> std::result::Result<w::HunkReverted, WireError> {
    user_only(c)?;
    let index = usize::try_from(p.hunk).map_err(|_| invalid("hunk", "a negative hunk"))?;
    if !super::tree::restorable(Path::new(&p.path), &[]) {
        return Err(invalid(
            "path",
            format!("protected: the hub never writes {}", p.path),
        ));
    }
    let (hub, tree) = tree_of(f, &p.worktree)?;
    let Some(_held) = f.core.history.reverts.hold(&tree.root) else {
        return Err(refused(
            "busy",
            "a revert, a redo or a take of this tree runs",
        ));
    };
    let (t2, path, now) = (tree.clone(), p.path.clone(), crate::clock::wall_secs());
    let out = crate::clock::blocking(move || hub.revert_hunk(&t2, p.op, &path, index, now))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(store)?;
    let mut r = w::HunkReverted {
        state: w::HunkRevertState::Applied,
        op: None,
        buffer_id: None,
        version: None,
        edits: Vec::new(),
        conflict: None,
        undone_by: Vec::new(),
    };
    match out {
        Outcome::Applied(op) => {
            r.op = Some(op.0);
            f.broadcast(
                "history/applied",
                json!({"op": op.0, "paths": [p.path], "worktree": tree.root}),
            );
        }
        Outcome::InBuffer {
            buffer_id,
            version,
            edits,
        } => {
            r.state = w::HunkRevertState::InBuffer;
            r.buffer_id = Some(buffer_id);
            r.version = Some(version);
            r.edits = edits
                .into_iter()
                .map(|c| w::BatchChange {
                    start: c.start as u64,
                    old_len: c.old_len as u64,
                    inserted: c.inserted,
                    origin: Some(format!("revert:{}", p.op)),
                })
                .collect();
        }
        Outcome::Conflict(c) => {
            r.state = w::HunkRevertState::Conflict;
            r.conflict = Some(w::HunkConflict {
                start_line: n(c.start_line),
                end_line: n(c.end_line),
                users: c.users,
                reverted: c.reverted,
            });
        }
        Outcome::Undone(by) => {
            r.state = w::HunkRevertState::Undone;
            r.undone_by = by
                .into_iter()
                .map(|op| w::UndoneBy {
                    op: op.0,
                    author: None,
                })
                .collect();
        }
    }
    Ok(r)
}

#[cfg(test)]
mod tests;
