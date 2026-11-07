//! Capture: a file's new content, from an agent's write, the watcher, a rescan or a git event, becomes operations on its
//! document (a diff onto the branch's text, by the author's peer) and one record; files that are not text take the
//! snapshot class (a version with a blob id, no document).
//!
//! A tree an agent works in is read as the agent's files are: `eitri::read_regular` below the tree's folder, no link
//! followed, a FIFO refused at once; a link is recorded as a link (its target's name), never read through.  Secret
//! files are never read.  Blob ids come from the bytes read, through the git directory the tree names.

use super::blob;
use super::origin::OriginEv;
use super::{Class, FileVersion, Hub, Inner, Tree};
use serde_json::{Value, json};
use std::os::fd::AsFd;
use std::path::Path;
use verdandi::text::{Coding, canonical};
use verdandi::{BranchId, Cause, Change, DocId, Kind, PeerId, Record, Result, Span};

/// Larger files take the snapshot class.
const TEXT_CAP: u64 = 4 << 20;

/// Files whose versions are the lock tool's, not an editor's: the snapshot class.
const LOCKS: &[&str] = &[
    "Cargo.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "poetry.lock",
    "flake.lock",
    "go.sum",
    "Gemfile.lock",
    "composer.lock",
    "uv.lock",
    "bun.lockb",
];

fn name_of(rel: &str) -> &str {
    rel.rsplit('/').next().unwrap_or(rel)
}

/// Whether REL names a credentials file: never read into the history.
pub(crate) fn is_secret(rel: &str) -> bool {
    let name = name_of(rel);
    gleipnir::toolchain::SECRET_FILES
        .iter()
        .any(|s| rel == *s || rel.ends_with(&format!("/{s}")) || name == *s)
        || crate::timeline::snapshot::ALSO_SECRET
            .iter()
            .any(|s| match s.strip_prefix('*') {
                Some(suffix) => name.ends_with(suffix),
                None => name == *s,
            })
}

/// REL's text at the tree's base commit, as the document holds it.
pub(crate) fn base_text(tree: &Tree, rel: &str) -> Option<String> {
    let commit = tree.base.as_deref()?;
    let b = blob::text_at(&tree.git_dir, &tree.root, commit, rel)?;
    canonical(&b, Coding::detect(&b)).ok()
}

/// What is at a path now.
pub(crate) enum Seen {
    /// Not there (or no longer a regular file).
    Gone,
    /// A link: its target's name.
    Link(String),
    Bytes(Vec<u8>),
    /// More than [`TEXT_CAP`] bytes: not read; the key says which version of it this is (its size and time).
    Big(String),
    /// Not to be recorded: a FIFO, a directory, a link above the file, the tree itself unreadable.
    Skip,
}

/// REL below the tree's folder as the agent left it, no link followed.
pub(crate) fn read(tree: &Tree, rel: &str) -> Seen {
    use rustix::fs::{Mode, OFlags};
    let Ok(dir) = rustix::fs::open(
        &tree.root,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    ) else {
        return Seen::Skip;
    };
    match eitri::read_regular(dir.as_fd(), Path::new(rel), TEXT_CAP) {
        Ok(b) => Seen::Bytes(b),
        Err(eitri::FsError::TooLarge { .. }) => Seen::Big(big_key(tree, rel)),
        Err(eitri::FsError::Link { .. }) => link_target(&dir, rel).map_or(Seen::Skip, Seen::Link),
        Err(eitri::FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => Seen::Gone,
        Err(_) => Seen::Skip,
    }
}

/// What tells one version of an unread big file from the next: its size and change time (reading it to hash it would
/// stall the hub for as long as the read takes).  Two writes of the same size inside one file-time tick share a key.
fn big_key(tree: &Tree, rel: &str) -> String {
    use std::os::unix::fs::MetadataExt;
    match std::fs::symlink_metadata(tree.root.join(rel)) {
        Ok(m) => format!("big-{}-{}-{}", m.len(), m.mtime(), m.mtime_nsec()),
        Err(_) => "big".to_owned(),
    }
}

/// The target of the link at REL, read in its folder opened with no link followed (a link in a folder above: none).
fn link_target(dir: &std::os::fd::OwnedFd, rel: &str) -> Option<String> {
    let p = Path::new(rel);
    let name = p.file_name()?;
    let parent = match p.parent() {
        Some(q) if !q.as_os_str().is_empty() => {
            Some(eitri::open_beneath(dir.as_fd(), q, eitri::Kind::Dir).ok()?)
        }
        _ => None,
    };
    let fd = parent.as_ref().map_or(dir.as_fd(), |p| p.fd.as_fd());
    let target = rustix::fs::readlinkat(fd, name, Vec::new()).ok()?;
    Some(target.to_string_lossy().into_owned())
}

/// Which event the content is told to the origin core as.
#[derive(Clone, Copy)]
pub(crate) enum Src {
    Hub,
    Watch,
    Rescan,
}

/// One path's new version, not yet in a record.
pub(crate) struct Staged {
    pub path: String,
    pub blob: Option<String>,
    pub class: Class,
    pub doc: Option<DocId>,
    pub spans: Vec<Span>,
}

enum Plan {
    Text(String),
    Snapshot,
}

fn refused(e: String) -> verdandi::Error {
    verdandi::Error::Refused(e)
}

/// The changes that turn OLD into NEW, ascending, each in the coordinates the document has after the earlier ones.
pub(crate) fn diff(old: &str, new: &str) -> Vec<Change> {
    fn starts(lines: &[&str]) -> Vec<usize> {
        let mut v = vec![0usize];
        let mut n = 0;
        for l in lines {
            n += l.chars().count();
            v.push(n);
        }
        v
    }
    let (ol, nl): (Vec<&str>, Vec<&str>) = (
        old.split_inclusive('\n').collect(),
        new.split_inclusive('\n').collect(),
    );
    let o = starts(&ol);
    let d = similar::TextDiff::from_lines(old, new);
    let mut delta: isize = 0;
    let mut out = Vec::new();
    for op in d.ops() {
        let (tag, or, nr) = op.as_tag_tuple();
        if tag == similar::DiffTag::Equal {
            continue;
        }
        let (start, old_len) = (o[or.start], o[or.end] - o[or.start]);
        let inserted: String = nl[nr].concat();
        let added = inserted.chars().count();
        out.push(Change {
            start: usize::try_from(start as isize + delta).unwrap_or(0),
            old_len,
            inserted,
        });
        delta += added as isize - old_len as isize;
    }
    out
}

impl Inner {
    pub(crate) fn branch(&mut self, tree: &Tree) -> Result<BranchId> {
        tree.branch_in(&mut self.h)
    }

    /// The peer of AUTHOR (named KEY) on BRANCH, made on first use.
    pub(crate) fn peer(&mut self, branch: BranchId, key: &str, author: &Value) -> Result<PeerId> {
        if let Some(p) = self.peers.get(&(branch, key.to_owned())) {
            return Ok(*p);
        }
        let p = self.h.peer(author, Some(branch))?;
        self.peers.insert((branch, key.to_owned()), p);
        Ok(p)
    }

    /// REL's new content SEEN, told to the origin core as SRC: the version it is, applied onto its document as the
    /// author's operations.  None when it is no new version.
    pub(crate) fn stage(
        &mut self,
        tree: &Tree,
        rel: &str,
        seen: Seen,
        src: Src,
        key: &str,
        author: &Value,
    ) -> Result<Option<Staged>> {
        if rel.starts_with(".git/") || rel == ".git" || is_secret(rel) {
            return Ok(None);
        }
        let (blob, plan, hash) = match seen {
            Seen::Skip => return Ok(None),
            Seen::Gone => {
                if self.origin.last(&tree.id.0, rel).is_none() && base_text(tree, rel).is_none() {
                    return Ok(None);
                }
                (None, Plan::Text(String::new()), "gone".to_owned())
            }
            Seen::Big(key) => (None, Plan::Snapshot, key),
            Seen::Link(target) => {
                let b = blob::hash_raw(&tree.git_dir, &tree.root, target.as_bytes())
                    .map_err(refused)?;
                (Some(b.clone()), Plan::Snapshot, b)
            }
            Seen::Bytes(bytes) => {
                let b =
                    blob::hash_object(&tree.git_dir, &tree.root, rel, &bytes).map_err(refused)?;
                let name = name_of(rel);
                let plan = if LOCKS.contains(&name)
                    || bytes.len() as u64 > TEXT_CAP
                    || blob::is_generated(&tree.git_dir, &tree.root, rel)
                {
                    Plan::Snapshot
                } else {
                    match canonical(&bytes, Coding::detect(&bytes)) {
                        Ok(text) => Plan::Text(text),
                        Err(_) => Plan::Snapshot,
                    }
                };
                (Some(b.clone()), plan, b)
            }
        };
        let (path, hash) = (rel.to_owned(), hash);
        let ev = match src {
            Src::Hub => OriginEv::HubWrite { path, hash },
            Src::Watch => OriginEv::Watch { path, hash },
            Src::Rescan => OriginEv::Rescan { path, hash },
        };
        if self.origin.step(&tree.id.0, ev).is_none() {
            return Ok(None);
        }
        let Plan::Text(new) = plan else {
            return Ok(Some(Staged {
                path: rel.to_owned(),
                blob,
                class: Class::Snapshot,
                doc: None,
                spans: Vec::new(),
            }));
        };
        let branch = self.branch(tree)?;
        let peer = self.peer(branch, key, author)?;
        let doc = self.h.doc_for(rel)?;
        let old = self
            .h
            .activate(doc, branch, || Ok(base_text(tree, rel).unwrap_or_default()))?
            .text();
        // the line authors, in step before the operations (each one keeps them in step)
        let _ = self.kept_ranges(doc, branch);
        let mut ad = self.h.activate(doc, branch, || Ok(String::new()))?;
        let mut spans = Vec::new();
        // a key in the file is stored as stars (the file keeps it, and the next look at it is no new version)
        for ch in diff(&old, &verdandi::redact::redact(&new)) {
            let before = ad.frontier();
            spans.extend(ad.apply(peer, &ch)?);
            super::kept_op(
                &mut self.kept,
                (doc, branch),
                key,
                &ch,
                &before,
                ad.frontier(),
            );
        }
        Ok(Some(Staged {
            path: rel.to_owned(),
            blob,
            class: Class::Text,
            doc: Some(doc),
            spans,
        }))
    }

    /// STAGED as one record of KIND by the author KEY; none when nothing changed.
    #[allow(clippy::too_many_arguments)]
    fn finish(
        &mut self,
        tree: &Tree,
        kind: Kind,
        key: &str,
        author: &Value,
        cause: Cause,
        summary: String,
        staged: Vec<Staged>,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        if staged
            .iter()
            .all(|s| s.class == Class::Text && s.spans.is_empty())
        {
            return Ok(Vec::new());
        }
        let branch = self.branch(tree)?;
        let author_peer = self.peer(branch, key, author)?;
        let spans = spans_of(&staged);
        let op = self.h.record(Record {
            kind,
            author: author_peer,
            cause,
            spans,
            parents: Vec::new(),
            git: None,
            summary,
            at: now,
        })?;
        Ok(versions(tree, staged, op.0))
    }

    /// What the hub is about to write at REL in TREE for the user's own act (a revert, a redo), SEEN as the file will
    /// be: staged onto its document as the user's operations and told to the origin core as the hub's write, so the
    /// history holds the file as the act leaves it and the watcher's event about it is no outside edit.  None when it
    /// is no new version.  The caller writes the record that holds the spans.
    pub(crate) fn stage_users(
        &mut self,
        tree: &Tree,
        rel: &str,
        seen: Seen,
    ) -> Result<Option<Staged>> {
        let (key, author) = user();
        self.stage(tree, rel, seen, Src::Hub, &key, &author)
    }

    /// The user's peer on TREE's branch (the one their typing in a drgnx buffer is by): the author of the records of
    /// the user's own acts.
    pub(crate) fn user_peer(&mut self, tree: &Tree) -> Result<PeerId> {
        let branch = self.branch(tree)?;
        let (key, author) = user();
        self.peer(branch, &key, &author)
    }
}

/// The spans STAGED made, by document, for the record that holds them.
pub(crate) fn spans_of(staged: &[Staged]) -> Vec<(DocId, Span)> {
    staged
        .iter()
        .flat_map(|s| s.spans.iter().map(|sp| (s.doc, *sp)))
        .filter_map(|(d, sp)| d.map(|d| (d, sp)))
        .collect()
}

/// The versions STAGED are in TREE, made by record OP.
pub(crate) fn versions(tree: &Tree, staged: Vec<Staged>, op: i64) -> Vec<FileVersion> {
    staged
        .into_iter()
        .map(|s| FileVersion {
            worktree: tree.id.0.clone(),
            path: s.path,
            blob: s.blob,
            op,
            class: s.class,
        })
        .collect()
}

/// A session's tool calls and step claims, as the hold over its tree's watcher events reads them: the session sets
/// `call` while a tool call runs and counts the steps it closes (`sent`); its claim stage counts the steps it has
/// claimed.  Busy while a call runs or a closed step is not claimed yet.
#[derive(Debug, Default)]
pub struct Flight {
    pub call: std::sync::atomic::AtomicBool,
    pub sent: std::sync::atomic::AtomicU64,
    pub claimed: std::sync::atomic::AtomicU64,
}

impl Flight {
    pub fn busy(&self) -> bool {
        use std::sync::atomic::Ordering::SeqCst;
        self.call.load(SeqCst) || self.claimed.load(SeqCst) < self.sent.load(SeqCst)
    }
}

/// An agent session working in a tree ([`Hub::attach_agent`]); dropped when the session ends, which ends its hold.
pub struct Attached {
    hub: std::sync::Arc<Hub>,
    tree: String,
    flight: std::sync::Arc<Flight>,
}

impl Drop for Attached {
    fn drop(&mut self) {
        let mut g = self.hub.lock();
        if let Some(v) = g.flights.get_mut(&self.tree) {
            v.retain(|f| !std::sync::Arc::ptr_eq(f, &self.flight));
            if v.is_empty() {
                g.flights.remove(&self.tree);
            }
        }
    }
}

impl Inner {
    /// A session working in TREE has a tool call running or a step not claimed yet.
    fn busy(&self, tree: &str) -> bool {
        self.flights
            .get(tree)
            .is_some_and(|v| v.iter().any(|f| f.busy()))
    }
}

fn user() -> (String, Value) {
    ("user".to_owned(), json!({"kind": "user"}))
}

fn agent(session: &str) -> (String, Value) {
    (
        format!("agent:{session}"),
        json!({"kind": "agent", "session": session}),
    )
}

fn external(source: &str) -> (String, Value) {
    (
        format!("external:{source}"),
        json!({"kind": "external", "source": source}),
    )
}

impl Hub {
    /// The hub is writing BYTES to REL for the agent SESSION (the handler calls this before the file is written, so
    /// the watcher's event about it finds the version known).
    pub fn on_agent_write(
        &self,
        tree: &Tree,
        rel: &str,
        bytes: &[u8],
        session: &str,
        cause: Cause,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        let (key, author) = agent(session);
        let mut g = self.lock();
        let s = g.stage(
            tree,
            rel,
            Seen::Bytes(bytes.to_vec()),
            Src::Hub,
            &key,
            &author,
        )?;
        let v = g.finish(
            tree,
            Kind::AgentStep,
            &key,
            &author,
            cause,
            format!("agent wrote {rel}"),
            s.into_iter().collect(),
            now,
        )?;
        drop(g);
        self.publish(&v);
        Ok(v)
    }

    /// The agent SESSION moved FROM to TO (already done on disk): one rename record, the old document emptied and the
    /// new one holding the text.
    pub fn on_agent_rename(
        &self,
        tree: &Tree,
        from: &str,
        to: &str,
        session: &str,
        cause: Cause,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        let (key, author) = agent(session);
        let mut g = self.lock();
        let mut staged = Vec::new();
        staged.extend(g.stage(tree, from, Seen::Gone, Src::Hub, &key, &author)?);
        staged.extend(g.stage(tree, to, read(tree, to), Src::Hub, &key, &author)?);
        let v = g.finish(
            tree,
            Kind::Rename,
            &key,
            &author,
            cause,
            format!("agent moved {from} to {to}"),
            staged,
            now,
        )?;
        drop(g);
        self.publish(&v);
        Ok(v)
    }

    /// The hub is applying a runner's returned changes in TREE (WRITES: each file's new bytes; none: removed), for the
    /// agent SESSION that started the job, or for RUNNER when the user did: one version, recorded before the files are
    /// written (as [`Self::on_agent_write`]).
    pub fn on_returned_writes(
        &self,
        tree: &Tree,
        writes: &[(String, Option<Vec<u8>>)],
        session: Option<&str>,
        runner: &str,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        let (key, author) = match session {
            Some(s) => agent(s),
            None => external(&format!("runner {runner}")),
        };
        let mut g = self.lock();
        let mut staged = Vec::new();
        for (rel, bytes) in writes {
            let seen = bytes.clone().map_or(Seen::Gone, Seen::Bytes);
            staged.extend(g.stage(tree, rel, seen, Src::Hub, &key, &author)?);
        }
        let summary = match writes {
            [(one, _)] => format!("runner {runner}'s changes wrote {one}"),
            _ => format!("runner {runner}'s changes wrote {} files", writes.len()),
        };
        let cause = Cause {
            session: session.map(String::from),
            ..Cause::default()
        };
        let v = g.finish(
            tree,
            if session.is_some() {
                Kind::AgentStep
            } else {
                Kind::External
            },
            &key,
            &author,
            cause,
            summary,
            staged,
            now,
        )?;
        drop(g);
        self.publish(&v);
        Ok(v)
    }

    /// The watcher saw REL change.  While a session working in TREE has a tool call running (or a closed step not
    /// claimed yet), the event is held for the step to claim ([`Self::claim`]); [`Self::release_held`] records what no
    /// step claimed once none is busy.
    pub fn on_disk_change(&self, tree: &Tree, rel: &str, now: f64) -> Result<Vec<FileVersion>> {
        {
            let mut g = self.lock();
            if g.busy(&tree.id.0) {
                let held = g.held.entry(tree.id.0.clone()).or_default();
                if !held.iter().any(|r| r == rel) {
                    held.push(rel.to_owned());
                }
                return Ok(Vec::new());
            }
        }
        self.observe(tree, &[rel.to_owned()], Src::Watch, now)
    }

    /// The held events of TREE once no session there is busy: outside changes, recorded at NOW.
    pub fn release_held(&self, tree: &Tree, now: f64) -> Result<Vec<FileVersion>> {
        let due = {
            let mut g = self.lock();
            if g.busy(&tree.id.0) {
                return Ok(Vec::new());
            }
            g.held.remove(&tree.id.0).unwrap_or_default()
        };
        if due.is_empty() {
            return Ok(Vec::new());
        }
        self.observe(tree, &due, Src::Watch, now)
    }

    /// A step-boundary rescan of RELS.
    pub fn rescan(&self, tree: &Tree, rels: &[String], now: f64) -> Result<Vec<FileVersion>> {
        self.observe(tree, rels, Src::Rescan, now)
    }

    /// The claim of a step of the agent SESSION that may have written files (CAUSE: the session and the step), as it
    /// closes: the files it NAMED, the paths of the watcher's events held while it ran, and with DIRTY every path that
    /// differs from TREE's head (a shell step names none; plain git, so only a tree the hub watches), rescanned.  A new
    /// version is the agent's, one record of the step; one the history holds already is none.
    #[allow(clippy::too_many_arguments)]
    pub fn claim(
        &self,
        tree: &Tree,
        named: &[String],
        dirty: bool,
        session: &str,
        cause: Cause,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        let mut rels: Vec<String> = named.to_vec();
        if dirty {
            for r in blob::dirty_paths(&tree.git_dir, &tree.root).map_err(refused)? {
                if !rels.contains(&r) {
                    rels.push(r);
                }
            }
        }
        let (key, author) = agent(session);
        let mut g = self.lock();
        for r in g.held.remove(&tree.id.0).unwrap_or_default() {
            if !rels.contains(&r) {
                rels.push(r);
            }
        }
        if rels.is_empty() {
            return Ok(Vec::new());
        }
        let mut staged = Vec::new();
        for rel in &rels {
            staged.extend(g.stage(tree, rel, read(tree, rel), Src::Rescan, &key, &author)?);
        }
        let summary = match staged.as_slice() {
            [one] => format!("agent's tool wrote {}", one.path),
            _ => format!("agent's tool wrote {} files", staged.len()),
        };
        let v = g.finish(
            tree,
            Kind::AgentStep,
            &key,
            &author,
            cause,
            summary,
            staged,
            now,
        )?;
        drop(g);
        self.publish(&v);
        Ok(v)
    }

    /// An agent session works in TREE until the guard is dropped: while FLIGHT is busy, the watcher's events there are
    /// held for its steps to claim.
    pub fn attach_agent(
        self: &std::sync::Arc<Self>,
        tree: &Tree,
        flight: std::sync::Arc<Flight>,
    ) -> Attached {
        self.lock()
            .flights
            .entry(tree.id.0.clone())
            .or_default()
            .push(flight.clone());
        Attached {
            hub: self.clone(),
            tree: tree.id.0.clone(),
            flight,
        }
    }

    /// A rescan of every path that differs from TREE's head (its uncommitted state when the watcher starts): what the
    /// history already holds is no new version.  Plain git runs in TREE: never one a sandboxed agent worked in.
    pub fn rescan_dirty(&self, tree: &Tree, now: f64) -> Result<Vec<FileVersion>> {
        let rels = blob::dirty_paths(&tree.git_dir, &tree.root).map_err(refused)?;
        if rels.is_empty() {
            return Ok(Vec::new());
        }
        self.rescan(tree, &rels, now)
    }

    /// A rescan of every path the hub knows a version of (a held one waits for its step).
    pub fn rescan_known(&self, tree: &Tree, now: f64) -> Result<Vec<FileVersion>> {
        let rels = {
            let g = self.lock();
            let held = g.held.get(&tree.id.0);
            let mut rels = g.origin.paths(&tree.id.0);
            rels.retain(|r| !held.is_some_and(|h| h.contains(r)));
            rels
        };
        self.rescan(tree, &rels, now)
    }

    fn observe(
        &self,
        tree: &Tree,
        rels: &[String],
        src: Src,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        let (key, author) = external("disk");
        let mut g = self.lock();
        let mut staged = Vec::new();
        for rel in rels {
            staged.extend(g.stage(tree, rel, read(tree, rel), src, &key, &author)?);
        }
        let summary = match rels {
            [one] => format!("{one} changed outside drgnx"),
            _ => format!("{} files changed outside drgnx", rels.len()),
        };
        let v = g.finish(
            tree,
            Kind::External,
            &key,
            &author,
            Cause::default(),
            summary,
            staged,
            now,
        )?;
        drop(g);
        self.publish(&v);
        Ok(v)
    }

    /// Git moved the tree from the commit OLD to NEW (REASON: checkout, merge, pull, …): every file that differs is
    /// one external record.
    pub fn on_git_event(
        &self,
        tree: &Tree,
        old: &str,
        new: &str,
        reason: &str,
        now: f64,
    ) -> Result<Vec<FileVersion>> {
        let paths = blob::changed_paths(&tree.git_dir, &tree.root, old, new).map_err(refused)?;
        let key = "external:git".to_owned();
        let author = json!({"kind": "external", "source": "git", "reason": reason});
        let mut g = self.lock();
        let mut staged = Vec::new();
        for rel in &paths {
            staged.extend(g.stage(tree, rel, read(tree, rel), Src::Rescan, &key, &author)?);
        }
        let v = g.finish(
            tree,
            Kind::External,
            &key,
            &author,
            Cause::default(),
            format!("git {reason}: {} files", paths.len()),
            staged,
            now,
        )?;
        drop(g);
        self.publish(&v);
        Ok(v)
    }
}

#[cfg(test)]
mod tests;
