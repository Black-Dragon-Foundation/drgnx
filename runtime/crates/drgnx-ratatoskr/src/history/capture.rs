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
    /// More than [`TEXT_CAP`] bytes.
    Big,
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
        Err(eitri::FsError::TooLarge { .. }) => Seen::Big,
        Err(eitri::FsError::Link { .. }) => link_target(&dir, rel).map_or(Seen::Skip, Seen::Link),
        Err(eitri::FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => Seen::Gone,
        Err(_) => Seen::Skip,
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
        self.h.branch(
            &tree.branch_name(),
            verdandi::BranchKind::Worktree,
            tree.base.as_deref(),
        )
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
                if self.origin.last(rel).is_none() && base_text(tree, rel).is_none() {
                    return Ok(None);
                }
                (None, Plan::Text(String::new()), "gone".to_owned())
            }
            Seen::Big => (None, Plan::Snapshot, "big".to_owned()),
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
        if self.origin.step(ev).is_none() {
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
        let mut ad = self
            .h
            .activate(doc, branch, || Ok(base_text(tree, rel).unwrap_or_default()))?;
        let old = ad.text();
        let mut spans = Vec::new();
        for ch in diff(&old, &new) {
            spans.extend(ad.apply(peer, &ch)?);
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
        let spans = staged
            .iter()
            .flat_map(|s| s.spans.iter().map(|sp| (s.doc, *sp)))
            .filter_map(|(d, sp)| d.map(|d| (d, sp)))
            .collect();
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
        Ok(staged
            .into_iter()
            .map(|s| FileVersion {
                worktree: tree.id.0.clone(),
                path: s.path,
                blob: s.blob,
                op: op.0,
                class: s.class,
            })
            .collect())
    }
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

    /// The watcher saw REL change.
    pub fn on_disk_change(&self, tree: &Tree, rel: &str, now: f64) -> Result<Vec<FileVersion>> {
        self.observe(tree, &[rel.to_owned()], Src::Watch, now)
    }

    /// A step-boundary rescan of RELS.
    pub fn rescan(&self, tree: &Tree, rels: &[String], now: f64) -> Result<Vec<FileVersion>> {
        self.observe(tree, rels, Src::Rescan, now)
    }

    /// A rescan of every path the hub knows a version of.
    pub fn rescan_known(&self, tree: &Tree, now: f64) -> Result<Vec<FileVersion>> {
        let rels: Vec<String> = self.lock().origin.paths().cloned().collect();
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
