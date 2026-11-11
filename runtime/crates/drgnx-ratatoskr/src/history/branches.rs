//! Fork from here (`docs/develop/hub.md`, "Fork from here"), and the branches a fork makes.  `history/fork` starts a
//! second agent in its own tree at a step's checkpoint (`tree::fork_tree`), its history branch at the step's record
//! (`History::fork`, one `fork` record) and its conversation forked there (`rewind::fork_conversation`); no task, no
//! job, no approval: a direct act of the user's.  `history/fork/drop` ends it, `history/compare` and `history/take`
//! work across two branches, `history/redo` puts back what a revert undid.  All user only.
//!
//! The user's work is never overwritten: a take refuses a file whose disk differs from what its history holds, and a
//! redo merges with the user's later edit or leaves the file, listed `edited-later`.

use super::capture::{self, Seen};
use super::origin::OriginEv;
use super::revert::{self, Merge, refused, user_only};
use super::{Hub, Tree};
use crate::agents::queue::Origin;
use crate::agents::rewind::{self, Target};
use crate::agents::session::{self, internal, invalid};
use crate::dispatch::Caller;
use crate::front::Front;
use crate::timeline::snapshot;
use runstav::methods::history as w;
use runstav::wire::Error;
use serde_json::json;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use verdandi::{BranchKind, Cause, Kind, OpId, Record};

fn hub_dir(f: &Front) -> Result<PathBuf, Error> {
    f.dirs
        .get()
        .map(|d| d.hub.clone())
        .ok_or_else(|| internal("the hub has no state folder"))
}

fn store(e: verdandi::Error) -> Error {
    match e {
        verdandi::Error::Refused(m) => invalid("history", m),
        verdandi::Error::NotFound(m) => invalid("history", format!("not found: {m}")),
        e => internal(e.to_string()),
    }
}

/// F on a blocking thread (the store and git block).
async fn blocking<R: Send + 'static>(
    f: impl FnOnce() -> Result<R, Error> + Send + 'static,
) -> Result<R, Error> {
    crate::clock::blocking(f)
        .await
        .map_err(|e| internal(e.to_string()))?
}

fn user_author() -> serde_json::Value {
    json!({"kind": "user"})
}

/// Where a fork of a step cuts the history: the record the step anchors, else the newest record the session caused
/// by the step's end.
enum Cut {
    Op(i64),
    Time(f64),
}

async fn step_of(f: &Front, t: &Target) -> Result<norn::read::steps::Step, Error> {
    let (key, seq) = (format!("session:{}", t.sid), t.seq);
    f.writer
        .db
        .read(move |c| {
            Ok(norn::read::steps::for_session(c, &key, seq - 1)?
                .into_iter()
                .find(|s| s.seq == seq))
        })
        .await
        .map_err(|e| internal(format!("the session's step: {e}")))?
        .ok_or_else(|| invalid("seq", format!("session {} has no step {}", t.sid, t.seq)))
}

/// The trusted repository a fork of session SID's work was made in, as `tree::fork_tree` chose it: the worktree's
/// recorded repository, else the source's own folder when no sandboxed agent worked there.
async fn source_repo(f: &Front, sid: &str) -> Option<PathBuf> {
    let (_, cwd, _) = rewind::source_of(&f.core.agents, f, sid).await.ok()?;
    let cw = cwd.to_string_lossy().into_owned();
    let base = f
        .writer
        .db
        .read(move |c| norn::read::work::base(c, &cw))
        .await
        .ok()?;
    match base {
        Some(b) => Some(PathBuf::from(b.repo)),
        None if !f.core.runs.git().is_touched(&cwd).await.unwrap_or(true) => Some(cwd),
        None => None,
    }
}

/// A fork's tree PATH removed: a linked worktree through the trusted REPO's git (`worktree remove --force`, then
/// `worktree prune`; never git in the tree, whose `.git` its agent wrote), then whatever is left (`remove_dir_all`
/// follows no link).
async fn remove_tree(repo: Option<PathBuf>, path: &Path) {
    let p = path.to_path_buf();
    let _ = crate::clock::blocking(move || {
        let git = |args: &[&std::ffi::OsStr]| {
            if let Some(r) = &repo {
                let _ = std::process::Command::new("git")
                    .arg("-C")
                    .arg(r)
                    .args(args)
                    .env("GIT_TERMINAL_PROMPT", "0")
                    .stdin(std::process::Stdio::null())
                    .output();
            }
        };
        git(&[
            "worktree".as_ref(),
            "remove".as_ref(),
            "--force".as_ref(),
            p.as_os_str(),
        ]);
        if p.exists()
            && let Err(e) = std::fs::remove_dir_all(&p)
        {
            tracing::warn!(path = %p.display(), "the fork's tree is not removed: {e}");
        }
        git(&["worktree".as_ref(), "prune".as_ref()]);
    })
    .await;
}

/// The branch NAME of HUB frozen at the hub's time (kept for compare until it expires).
async fn freeze(hub: &Arc<Hub>, name: &str) {
    let (h, name, now) = (hub.clone(), name.to_owned(), crate::clock::wall_secs());
    let r = crate::clock::blocking(move || {
        let mut g = h.lock();
        match g.h.find_branch(&name)? {
            Some(b) => g.h.freeze(b, now),
            None => Ok(()),
        }
    })
    .await;
    if let Ok(Err(e)) = r {
        tracing::warn!("a fork's branch is not frozen: {e}");
    }
}

/// The fork's history branch: named for its tree DST (so the tree's later changes land on it), holding the source
/// tree SRC's documents as they were at CUT, with one `fork` record.  A cut that holds no document of the source's
/// branch (the history has none of its files yet) starts the branch from its base.  Its name, the source's, and the
/// project's history.
async fn branch_fork(
    f: &Front,
    hubdir: &Path,
    t: &Target,
    src: &Path,
    dst: &Path,
    cut: Cut,
) -> Result<(String, String, Arc<Hub>), Error> {
    let (hub, from) = f.core.history.of_tree(hubdir, src)?;
    let (_, to) = f.core.history.of_tree(hubdir, dst)?;
    let (h2, sid, seq, now) = (hub.clone(), t.sid.clone(), t.seq, crate::clock::wall_secs());
    let (name, source) = blocking(move || {
        let mut g = h2.lock();
        let source = g.branch(&from).map_err(store)?;
        let author = g.h.peer(&user_author(), None).map_err(store)?;
        let name = to.branch_name();
        let at = match cut {
            Cut::Op(op) => Some(OpId(op)),
            Cut::Time(at) => g.h.last_caused_by(&sid, at).map_err(store)?,
        };
        let forked = match at {
            Some(at) => match g.h.fork(at, source, &name, author, now) {
                Ok(_) => true,
                Err(verdandi::Error::Refused(_)) => false,
                Err(e) => return Err(store(e)),
            },
            None => false,
        };
        if !forked {
            g.h.branch(&name, BranchKind::Fork, to.base.as_deref())
                .map_err(store)?;
            g.h.record(Record {
                kind: Kind::Fork,
                author,
                cause: Cause {
                    session: Some(sid),
                    step: Some(seq.to_string()),
                    ..Cause::default()
                },
                spans: Vec::new(),
                parents: at.into_iter().collect(),
                git: None,
                summary: format!("fork {name}"),
                at: now,
            })
            .map_err(store)?;
        }
        Ok((name, from.branch_name()))
    })
    .await?;
    Ok((name, source, hub))
}

/// `history/fork`: the tree, the branch and the conversation, in that order; a conversation that cannot start takes
/// the tree away again and freezes the branch.
pub async fn fork(f: &Front, c: &Caller, p: w::ForkParams) -> Result<w::Forked, Error> {
    user_only(c)?;
    if p.message.trim().is_empty() {
        return Err(invalid(
            "message",
            "a fork starts with your message: what the second agent is to do",
        ));
    }
    let t = Target {
        sid: p.session.trim_start_matches("session:").to_owned(),
        seq: p.seq,
    };
    let hubdir = hub_dir(f)?;
    let (_, src_cwd, _) = rewind::source_of(&f.core.agents, f, &t.sid).await?;
    let step = step_of(f, &t).await?;
    let cut = match step.history_op {
        Some(op) => Cut::Op(op),
        None => Cut::Time(step.end.unwrap_or(step.start)),
    };
    let sid = session::new_sid()?;
    let tree = super::tree::fork_tree(f, &t, &sid).await?;
    let (branch, source_branch, hub) =
        match branch_fork(f, &hubdir, &t, &src_cwd, &tree.path, cut).await {
            Ok(v) => v,
            Err(e) => {
                remove_tree(source_repo(f, &t.sid).await, &tree.path).await;
                return Err(e);
            }
        };
    // a worker's fork works in its own tree as its source did; a chat's stays a chat (its project read-only)
    let role = f
        .core
        .agents
        .find(&t.sid)
        .ok()
        .map(|s| s.role())
        .filter(|r| *r == runstav::methods::matrix::Role::Worker);
    let started = rewind::fork_conversation(
        &f.core.agents,
        f,
        c,
        &t,
        &tree.path,
        p.profile.as_deref(),
        p.message,
        Some(sid),
        role,
    )
    .await;
    match started {
        Ok((s, level)) => Ok(w::Forked {
            id: s.id,
            branch,
            source_branch,
            path: tree.path.to_string_lossy().into_owned(),
            level,
        }),
        Err(e) => {
            freeze(&hub, &branch).await;
            remove_tree(source_repo(f, &t.sid).await, &tree.path).await;
            Err(e)
        }
    }
}

/// The session SID was forked from: none when it is no fork.
async fn forked_from(f: &Front, sid: &str) -> Result<Option<String>, Error> {
    let key = format!("session:{sid}");
    f.writer
        .db
        .read(move |c| {
            Ok(c.query_row(
                "select d.id from link l join entity s on s.n = l.src join entity d on d.n = l.dst \
                 where l.kind = 'forked_from' and s.id = ?1 order by l.id desc limit 1",
                [&key],
                |r| r.get::<_, String>(0),
            )
            .ok())
        })
        .await
        .map_err(|e| internal(format!("the fork's link: {e}")))
        .map(|s| s.map(|s| s.trim_start_matches("session:").to_owned()))
}

/// `history/fork/drop`: the fork's agent stopped, its tree removed (only a tree the hub made for this fork), its
/// history branch frozen.  Its git branch stays.
pub async fn drop_fork(f: &Front, c: &Caller, p: w::ForkDropParams) -> Result<w::Done, Error> {
    user_only(c)?;
    let id = p.id.trim_start_matches("session:").to_owned();
    let Some(source) = forked_from(f, &id).await? else {
        return Err(invalid("id", format!("session {id} is no fork")));
    };
    let hubdir = hub_dir(f)?;
    let (_, cwd, _) = rewind::source_of(&f.core.agents, f, &id).await?;
    let sid8: String = id.chars().take(8).collect();
    let ours = cwd.to_string_lossy().contains(&format!("fork-{sid8}"));
    if f.core.agents.find(&id).is_ok()
        && let Err(e) = f.core.agents.kill(&id).await
    {
        tracing::warn!(sid = id, "the fork's agent is not stopped: {}", e.message);
    }
    if cwd.is_dir() {
        if let Ok((hub, tree)) = f.core.history.of_tree(&hubdir, &cwd) {
            freeze(&hub, &tree.branch_name()).await;
        }
        if ours {
            remove_tree(source_repo(f, &source).await, &cwd).await;
        }
    }
    Ok(w::Done { ok: true })
}

/// `history/compare`: in whichever project's history holds both branches.
pub async fn compare(f: &Front, c: &Caller, p: w::CompareParams) -> Result<w::Compared, Error> {
    user_only(c)?;
    for hub in f.core.history.all(&hub_dir(f)?) {
        let (a, b) = (p.a.clone(), p.b.clone());
        let found = blocking(move || {
            let mut g = hub.lock();
            let h = &mut g.h;
            let (Some(a), Some(b)) = (
                h.find_branch(&a).map_err(store)?,
                h.find_branch(&b).map_err(store)?,
            ) else {
                return Ok(None);
            };
            let mut files = Vec::new();
            for d in h.compare(a, b).map_err(store)? {
                let mut hunks = Vec::new();
                for x in d.hunks {
                    let author = match x.author {
                        Some(peer) => h.author_of(peer).map_err(store)?,
                        None => None,
                    };
                    let rec = match x.step {
                        Some(op) => Some(h.op(op).map_err(store)?),
                        None => None,
                    };
                    let n = |v: usize| i64::try_from(v).unwrap_or(i64::MAX);
                    hunks.push(w::ComparedHunk {
                        ours_start: n(x.ours_start),
                        ours_end: n(x.ours_end),
                        theirs_start: n(x.theirs_start),
                        theirs_end: n(x.theirs_end),
                        ours_text: x.ours_text,
                        theirs_text: x.theirs_text,
                        author,
                        record: x.step.map(|o| o.0),
                        session: rec.as_ref().and_then(|r| r.cause.session.clone()),
                        step: rec.and_then(|r| r.cause.step),
                    });
                }
                files.push(w::ComparedFile {
                    path: d.path,
                    hunks,
                });
            }
            Ok(Some(w::Compared { files }))
        })
        .await?;
        if let Some(c) = found {
            return Ok(c);
        }
    }
    Err(invalid(
        "a",
        format!("no project's history holds both {} and {}", p.a, p.b),
    ))
}

/// REL's mode under DIR, read through `eitri` (no link followed).
fn mode_of(dir: std::os::fd::BorrowedFd<'_>, rel: &str) -> Option<u32> {
    let o = eitri::open_beneath(dir, Path::new(rel), eitri::Kind::File).ok()?;
    let st = rustix::fs::fstat(&o.fd).ok()?;
    // st_mode is a u16 on macOS
    #[allow(clippy::useless_conversion)]
    let mode = u32::from(st.st_mode) & 0o777;
    Some(mode)
}

/// `history/take`.
pub async fn take(f: &Front, c: &Caller, p: w::TakeParams) -> Result<w::Taken, Error> {
    user_only(c)?;
    if p.hunks.is_empty() {
        return Err(invalid("hunks", "nothing to take"));
    }
    let (hub, tree) = f
        .core
        .history
        .of_tree(&hub_dir(f)?, Path::new(&p.worktree))?;
    let Some(_held) = f.core.history.reverts.hold(&tree.root) else {
        return Err(refused(
            "busy",
            "a revert, a redo or a take of this tree runs",
        ));
    };
    let (h2, t2, now) = (hub.clone(), tree.clone(), crate::clock::wall_secs());
    let taken = blocking(move || take_in(&h2, &t2, &p, now)).await?;
    f.broadcast(
        "history/applied",
        json!({"op": taken.op, "paths": taken.written, "worktree": tree.root}),
    );
    Ok(taken)
}

fn take_in(hub: &Hub, tree: &Tree, p: &w::TakeParams, now: f64) -> Result<w::Taken, Error> {
    let mut g = hub.lock();
    let from =
        g.h.find_branch(&p.from)
            .map_err(store)?
            .ok_or_else(|| invalid("from", format!("no branch {}", p.from)))?;
    let to = g.branch(tree).map_err(store)?;
    let mut files: Vec<(String, verdandi::DocId)> = Vec::new();
    let mut refs = Vec::new();
    let offset = |v: i64| usize::try_from(v).map_err(|_| invalid("hunks", "a negative offset"));
    for h in &p.hunks {
        if !super::tree::restorable(Path::new(&h.path), &[]) {
            return Err(invalid(
                "hunks",
                format!("protected: the hub never writes {}", h.path),
            ));
        }
        let doc = g.h.doc_for(&h.path).map_err(store)?;
        refs.push(verdandi::HunkRef {
            doc,
            theirs_start: offset(h.theirs_start)?,
            theirs_end: offset(h.theirs_end)?,
        });
        if !files.iter().any(|(_, d)| *d == doc) {
            files.push((h.path.clone(), doc));
        }
    }
    // the user's work is never overwritten: each file on disk is what its history holds
    for (rel, doc) in &files {
        let text =
            g.h.activate(*doc, to, || {
                Ok(capture::base_text(tree, rel).unwrap_or_default())
            })
            .map_err(store)?
            .text();
        let disk = match capture::read(tree, rel) {
            Seen::Bytes(b) => b,
            Seen::Gone => Vec::new(),
            _ => {
                return Err(refused(
                    revert::STALE,
                    format!("{rel} is no text file here"),
                ));
            }
        };
        if disk != text.as_bytes() {
            return Err(refused(
                revert::STALE,
                format!("{rel} on disk differs from its history: save it, then compare again"),
            ));
        }
    }
    let peer = g.peer(to, "user", &user_author()).map_err(store)?;
    let op = g.h.take(from, to, &refs, peer, now).map_err(store)?;
    let dir = std::fs::File::open(&tree.root)
        .map_err(|e| internal(format!("{}: {e}", tree.root.display())))?;
    let (mut written, mut skipped) = (Vec::new(), Vec::new());
    for (rel, doc) in files {
        let text = g.h.text(doc, to).map_err(store)?;
        // the hub's own version: the watcher's event about it is no outside edit
        if let Ok(hash) = super::blob::hash_object(&tree.git_dir, &tree.root, &rel, text.as_bytes())
        {
            g.origin.step(
                &tree.id.0,
                OriginEv::HubWrite {
                    path: rel.clone(),
                    hash,
                },
            );
        }
        let mode = mode_of(dir.as_fd(), &rel).unwrap_or(0o644);
        match eitri::write_regular(dir.as_fd(), Path::new(&rel), text.as_bytes(), mode) {
            Ok(()) => written.push(rel),
            Err(e) => skipped.push(w::RevertSkipped {
                path: rel,
                reason: e.to_string(),
            }),
        }
    }
    Ok(w::Taken {
        op: op.0,
        written,
        skipped,
    })
}

/// What a redo writes: paths back from the files as the revert found them, merged texts, and the paths left.
type RedoPlan = (Vec<PathBuf>, Vec<Merge>, Vec<(PathBuf, String)>);

/// The redo of the revert that kept the files as it found them under UNDONE, from the step's CHECKPOINT: each path
/// the revert changed goes back to UNDONE's version when the user has not touched it since (it is the checkpoint's
/// still), is merged with the user's later edit where they do not meet (`merge3`: base the checkpoint's, ours the
/// user's, theirs the undone), and is left, `edited-later`, where they meet.
fn redo_plan(root: &Path, cwd: &Path, checkpoint: &str, undone: &str) -> Result<RedoPlan, String> {
    let now = snapshot::tree_now(root, cwd, cwd, &[])?;
    let (mut back, mut merges, mut skipped) = (Vec::new(), Vec::new(), Vec::new());
    let regular = |m: u32| m == 0o100644 || m == 0o100755;
    for c in snapshot::changed(root, cwd, checkpoint, undone)? {
        let rel = c.path.to_string_lossy().into_owned();
        if !super::tree::restorable(&c.path, &[]) {
            skipped.push((c.path, "protected".into()));
            continue;
        }
        if c.from_mode == 0o160000 || c.to_mode == 0o160000 {
            skipped.push((c.path, "gitlink".into()));
            continue;
        }
        let id = |t: &str| snapshot::blob_id(root, cwd, t, &rel);
        let (n, k, u) = (id(&now), id(checkpoint), id(undone));
        if n == u {
            continue;
        }
        if n == k {
            back.push(c.path);
            continue;
        }
        let text = |t: &str| {
            snapshot::blob(root, cwd, t, &rel)
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
        };
        if regular(c.from_mode)
            && regular(c.to_mode)
            && let (Some(base), Some(ours), Some(theirs)) =
                (text(checkpoint), text(&now), text(undone))
            && let Ok((true, merged)) = verdandi::merge3(&base, &ours, &theirs)
        {
            merges.push(Merge {
                path: c.path,
                text: merged,
                mode: c.to_mode & 0o777,
            });
            continue;
        }
        skipped.push((c.path, "edited-later".into()));
    }
    Ok((back, merges, skipped))
}

/// `history/redo`: a revert's files put back, one `redo` record naming it, one forward commit, and the agent told by
/// a message (its conversation is not restored).
pub async fn redo(f: &Front, c: &Caller, p: w::RedoParams) -> Result<w::Redone, Error> {
    user_only(c)?;
    let sid = p.session.trim_start_matches("session:").to_owned();
    let hubdir = hub_dir(f)?;
    let (_, cwd, _) = rewind::source_of(&f.core.agents, f, &sid).await?;
    let (hub, tree) = f.core.history.of_tree(&hubdir, &cwd)?;
    let (h2, s2, op) = (hub.clone(), sid.clone(), p.op);
    let seq = blocking(move || {
        let g = h2.lock();
        let r = g.h.op(OpId(op)).map_err(store)?;
        if r.kind != Kind::Revert || r.cause.session.as_deref() != Some(s2.as_str()) {
            return Err(invalid(
                "op",
                format!("record {op} is no revert of session {s2}"),
            ));
        }
        r.cause
            .step
            .as_deref()
            .and_then(|s| s.parse::<i64>().ok())
            .ok_or_else(|| invalid("op", format!("revert {op} names no step")))
    })
    .await?;
    let Some(_held) = f.core.history.reverts.hold(&cwd) else {
        return Err(refused(
            "busy",
            "a revert, a redo or a take of this tree runs",
        ));
    };
    let root = hubdir.join("checkpoints");
    let t = Target {
        sid: sid.clone(),
        seq,
    };
    let checkpoint = match step_of(f, &t).await?.snapshot {
        Some(cp) => cp,
        None => {
            let (r, w2, s3) = (root.clone(), cwd.clone(), sid.clone());
            crate::clock::blocking(move || snapshot::tree_at(&r, &w2, &s3, seq))
                .await
                .map_err(|e| internal(e.to_string()))?
                .ok_or_else(|| refused(revert::NOT_REVERTIBLE, "the step has no checkpoint"))?
        }
    };
    let undone = format!("refs/drgnx/undone/{op}");
    let (r, w2, cp, ud) = (
        root.clone(),
        cwd.clone(),
        checkpoint.clone(),
        undone.clone(),
    );
    let (back, merges, left) =
        blocking(move || redo_plan(&r, &w2, &cp, &ud).map_err(internal)).await?;
    let (r, w2, h2, t2, ud, cp) = (
        root.clone(),
        cwd.clone(),
        hub.clone(),
        tree.clone(),
        undone.clone(),
        checkpoint.clone(),
    );
    let (written, mut skipped, staged) = blocking(move || {
        let dir =
            std::fs::File::open(&w2).map_err(|e| internal(format!("{}: {e}", w2.display())))?;
        // what the redo leaves at each path, staged onto its document as the user's operations first (and told to
        // the origin core as the hub's write), so the history holds the files as the redo leaves them
        let modes: std::collections::HashMap<PathBuf, u32> = snapshot::changed(&r, &w2, &cp, &ud)
            .unwrap_or_default()
            .into_iter()
            .map(|c| (c.path, c.to_mode))
            .collect();
        let mut puts = Vec::new();
        for path in &back {
            let rel = path.to_string_lossy().into_owned();
            let bytes = || snapshot::blob(&r, &w2, &ud, &rel).ok();
            let seen = match modes.get(path) {
                Some(0) => Some(Seen::Gone),
                Some(0o100644 | 0o100755) => bytes().map(Seen::Bytes),
                Some(0o120000) => {
                    bytes().map(|b| Seen::Link(String::from_utf8_lossy(&b).into_owned()))
                }
                _ => None,
            };
            match seen {
                Some(seen) => puts.push((rel, seen)),
                // not a file the history reads: only announced, as the hub's write
                None => {
                    let hash =
                        snapshot::blob_id(&r, &w2, &ud, &rel).unwrap_or_else(|| "gone".into());
                    h2.lock()
                        .origin
                        .step(&t2.id.0, OriginEv::HubWrite { path: rel, hash });
                }
            }
        }
        for m in &merges {
            let rel = m.path.to_string_lossy().into_owned();
            puts.push((rel, Seen::Bytes(m.text.as_bytes().to_vec())));
        }
        let mut g = h2.lock();
        let mut staged = Vec::new();
        for (rel, seen) in puts {
            staged.extend(g.stage_users(&t2, &rel, seen).map_err(store)?);
        }
        drop(g);
        let done = snapshot::restore_into(&r, &w2, &w2, &ud, Some(&back), &[]).map_err(internal)?;
        let (mut written, mut skipped) = (done.written, done.skipped);
        for m in merges {
            match eitri::write_regular(dir.as_fd(), &m.path, m.text.as_bytes(), m.mode) {
                Ok(()) => written.push(m.path),
                Err(e) => skipped.push((m.path, e.to_string())),
            }
        }
        Ok((written, skipped, staged))
    })
    .await?;
    skipped.extend(left);
    let (h2, t2, s2, now) = (
        hub.clone(),
        tree.clone(),
        sid.clone(),
        crate::clock::wall_secs(),
    );
    let (redone, versions) = blocking(move || {
        let mut g = h2.lock();
        let author = g.user_peer(&t2).map_err(store)?;
        let redone =
            g.h.record(Record {
                kind: Kind::Redo,
                author,
                cause: Cause {
                    session: Some(s2.clone()),
                    step: Some(seq.to_string()),
                    ..Cause::default()
                },
                spans: capture::spans_of(&staged),
                parents: vec![OpId(op)],
                git: None,
                summary: format!("redo of revert {op} of session {s2}"),
                at: now,
            })
            .map_err(store)?;
        Ok((redone, capture::versions(&t2, staged, redone.0)))
    })
    .await?;
    hub.publish(&versions);
    let mut out = w::Redone {
        op: redone.0,
        written: written
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect(),
        skipped: skipped
            .into_iter()
            .map(|(p, reason)| w::RevertSkipped {
                path: p.to_string_lossy().into_owned(),
                reason,
            })
            .collect(),
        commit: None,
    };
    if !written.is_empty() {
        let subject = format!("redo of the revert to step {seq} of session {sid}");
        match super::tree::commit_in_sandbox(f, &sid, &cwd, &written, &subject).await {
            Ok(c) => out.commit = c,
            Err(e) => out.skipped.push(w::RevertSkipped {
                path: String::new(),
                reason: format!("commit: {e}"),
            }),
        }
    }
    tell_agent(f, &sid, seq, &out);
    f.broadcast(
        "history/applied",
        json!({"op": out.op, "paths": out.written, "worktree": cwd}),
    );
    Ok(out)
}

/// The session's agent told what the user's redo did (a message from the hub, queued behind its turn when it is
/// busy); a session not running is not told: the redo is in its record.
fn tell_agent(f: &Front, sid: &str, seq: i64, out: &w::Redone) {
    if out.written.is_empty() {
        return;
    }
    let text = format!(
        "[drgnx] The user redid what reverting you to your step {seq} undid: {} are back as they were before that \
         revert{}. Your conversation is not restored: it goes on from where the revert left it.{}",
        out.written.join(", "),
        if out.skipped.is_empty() {
            String::new()
        } else {
            format!(
                ", except {}, which the user changed since",
                out.skipped
                    .iter()
                    .map(|s| s.path.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        },
        out.commit
            .as_deref()
            .map(|c| format!(" The redo is commit {c}."))
            .unwrap_or_default()
    );
    if let Err(e) = f.core.agents.prompt(sid, text, Origin::Hub) {
        tracing::info!(sid, "the agent is not told of the redo: {}", e.message);
    }
}

#[cfg(test)]
mod live;
