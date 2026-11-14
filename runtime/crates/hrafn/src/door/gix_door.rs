//! The read-only in-process door of touched trees, on `gix`.
//!
//! It reads refs, the index, trees and `.gitattributes`, and hashes raw bytes (as `git hash-object --no-filters`).
//! It never runs anything the repository names: no filter driver, hook or fsmonitor (gix's filter pipeline and
//! status are not used), never the git binary (the repository is opened isolated: its own config only, no
//! environment, global or system config), and it writes nothing. Submodules are never opened: gitlinks are skipped.
use super::{
    Blob, CONVERSIONS, DoorKind, Head, Obj, Status, TreeChange, TreeEntry, TreeGit, autocrlf_on,
    converts,
};
use crate::files::{Commit, Git};
use gix::bstr::ByteSlice;
use gix::{ObjectId, Repository};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::io;
use std::os::fd::AsFd;
use std::path::Path;
use std::sync::atomic::AtomicBool;

/// The read-only `gix` door of touched trees.
pub struct GixDoor;

fn err(e: impl std::fmt::Display) -> io::Error {
    io::Error::other(format!("gix: {e}"))
}

fn open(root: &Path) -> io::Result<Repository> {
    gix::open_opts(root, gix::open::Options::isolated()).map_err(err)
}

fn oid(hex: &str) -> io::Result<ObjectId> {
    ObjectId::from_hex(hex.as_bytes()).map_err(err)
}

/// One level of a tree: name → (mode, id).
fn level(
    repo: &Repository,
    tree: Option<ObjectId>,
) -> io::Result<BTreeMap<String, (gix::objs::tree::EntryMode, ObjectId)>> {
    let mut m = BTreeMap::new();
    if let Some(id) = tree {
        let t = repo.find_tree(id).map_err(err)?;
        for e in t.decode().map_err(err)?.entries {
            m.insert(
                e.filename.to_str_lossy().into_owned(),
                (e.mode, e.oid.to_owned()),
            );
        }
    }
    Ok(m)
}

fn commit_tree(repo: &Repository, commit: &str) -> io::Result<ObjectId> {
    let t = repo
        .find_object(oid(commit)?)
        .map_err(err)?
        .peel_to_tree()
        .map_err(err)?;
    Ok(t.id)
}

/// A blob or link entry as an `Obj`; trees and gitlinks are not.
fn obj(mode: gix::objs::tree::EntryMode, id: &ObjectId) -> Option<Obj> {
    (mode.is_blob_or_symlink()).then(|| Obj {
        mode: u32::from(mode.value()),
        blob: id.to_string(),
    })
}

fn flatten(
    repo: &Repository,
    tree: ObjectId,
    prefix: &str,
    out: &mut BTreeMap<String, Obj>,
) -> io::Result<()> {
    for (name, (mode, id)) in level(repo, Some(tree))? {
        let path = format!("{prefix}{name}");
        if mode.is_tree() {
            flatten(repo, id, &format!("{path}/"), out)?;
        } else if let Some(o) = obj(mode, &id) {
            out.insert(path, o);
        }
    }
    Ok(())
}

/// The recursive tree diff: equal subtrees are skipped, a path that is a tree on one side and a blob on the other
/// gives both the subtree's changes and the blob's.
fn diff(
    repo: &Repository,
    a: Option<ObjectId>,
    b: Option<ObjectId>,
    prefix: &str,
    out: &mut Vec<TreeChange>,
) -> io::Result<()> {
    let (la, lb) = (level(repo, a)?, level(repo, b)?);
    let names: BTreeSet<&String> = la.keys().chain(lb.keys()).collect();
    for name in names {
        let (ea, eb) = (la.get(name), lb.get(name));
        if ea == eb {
            continue;
        }
        let path = format!("{prefix}{name}");
        let tree = |e: Option<&(gix::objs::tree::EntryMode, ObjectId)>| {
            e.filter(|(m, _)| m.is_tree()).map(|(_, id)| *id)
        };
        let (ta, tb) = (tree(ea), tree(eb));
        if ta.is_some() || tb.is_some() {
            diff(repo, ta, tb, &format!("{path}/"), out)?;
        }
        let (old, new) = (
            ea.and_then(|(m, id)| obj(*m, id)),
            eb.and_then(|(m, id)| obj(*m, id)),
        );
        if old != new {
            out.push(TreeChange { path, old, new });
        }
    }
    Ok(())
}

fn head_tree(repo: &Repository) -> io::Result<BTreeMap<String, Obj>> {
    let mut m = BTreeMap::new();
    if let Some(id) = repo.head().map_err(err)?.id() {
        flatten(repo, commit_tree(repo, &id.to_string())?, "", &mut m)?;
    }
    Ok(m)
}

/// Untracked files and untracked nested repositories, under the repository's excludes.
fn walk(repo: &Repository, index: &gix::index::State) -> io::Result<(Vec<String>, Vec<String>)> {
    use gix::dir::entry::{Kind, Status};
    let opts = repo
        .dirwalk_options()
        .map_err(err)?
        .emit_untracked(gix::dir::walk::EmissionMode::Matching)
        .emit_tracked(false)
        .emit_ignored(None)
        .emit_pruned(false)
        .emit_empty_directories(false)
        .recurse_repositories(false);
    let mut collect = gix::dir::walk::delegate::Collect::default();
    repo.dirwalk(
        index,
        std::iter::empty::<&str>(),
        &AtomicBool::new(false),
        opts,
        &mut collect,
    )
    .map_err(err)?;
    let (mut files, mut repos) = (Vec::new(), Vec::new());
    for (e, _) in collect.unorded_entries {
        if e.status != Status::Untracked {
            continue;
        }
        let p = e.rela_path.to_str_lossy().into_owned();
        match e.disk_kind {
            Some(Kind::File | Kind::Symlink) => files.push(p),
            Some(Kind::Repository) => repos.push(p),
            _ => {}
        }
    }
    files.sort();
    repos.sort();
    Ok((files, repos))
}

/// The raw blob id of a working-tree file (a link's is its target), read beneath `root` with no link followed.
fn raw_hash(
    repo: &Repository,
    root: &eitri::Pinned,
    root_path: &Path,
    rel: &str,
) -> io::Result<String> {
    let bytes = match eitri::read_regular(root.fd.as_fd(), Path::new(rel), u64::MAX) {
        Ok(b) => b,
        Err(eitri::FsError::Link { .. }) | Err(eitri::FsError::NotRegular) => {
            // the last component is a link (its parents were checked by the read's resolution)
            let parent = Path::new(rel)
                .parent()
                .filter(|p| !p.as_os_str().is_empty());
            if let Some(dir) = parent {
                eitri::open_beneath(root.fd.as_fd(), dir, eitri::Kind::Dir)
                    .map_err(|e| io::Error::other(format!("{rel}: {e}")))?;
            }
            let meta = std::fs::symlink_metadata(root_path.join(rel))?;
            if !meta.file_type().is_symlink() {
                return Err(io::Error::other(format!("{rel}: not a file or a link")));
            }
            std::os::unix::ffi::OsStringExt::into_vec(
                std::fs::read_link(root_path.join(rel))?.into_os_string(),
            )
        }
        Err(e) => return Err(io::Error::other(format!("{rel}: {e}"))),
    };
    let id =
        gix::objs::compute_hash(repo.object_hash(), gix::objs::Kind::Blob, &bytes).map_err(err)?;
    Ok(id.to_string())
}

fn filtered_in(
    repo: &Repository,
    index: &gix::index::State,
    paths: &[String],
) -> io::Result<Vec<String>> {
    let autocrlf = repo
        .config_snapshot()
        .string("core.autocrlf")
        .map(|v| v.to_str_lossy().into_owned());
    let autocrlf = autocrlf_on(autocrlf.as_deref());
    let hit = |values: &[String]| {
        let values: [&str; 5] = std::array::from_fn(|i| values[i].as_str());
        converts(&values, autocrlf)
    };
    attr_hits(repo, index, paths, hit, &CONVERSIONS)
}

/// The paths whose values of `names` (as `git check-attr` prints them) pass `hit`.
fn attr_hits(
    repo: &Repository,
    index: &gix::index::State,
    paths: &[String],
    hit: impl Fn(&[String]) -> bool,
    names: &[&str],
) -> io::Result<Vec<String>> {
    use gix::attrs::StateRef;
    if paths.is_empty() {
        return Ok(vec![]);
    }
    let source = gix::worktree::stack::state::attributes::Source::WorktreeThenIdMapping;
    let mut stack = repo.attributes_only(index, source).map_err(err)?;
    let mut out = Vec::new();
    for p in paths {
        let mut m = stack.selected_attribute_matches(names.iter().copied());
        stack
            .at_path(Path::new(p), None)
            .map_err(err)?
            .matching_attributes(&mut m);
        let mut values = vec!["unspecified".to_string(); names.len()];
        for a in m.iter_selected() {
            if let Some(i) = names.iter().position(|n| *n == a.assignment.name.as_str()) {
                values[i] = match a.assignment.state {
                    StateRef::Set => "set".into(),
                    StateRef::Unset => "unset".into(),
                    StateRef::Value(v) => v.as_bstr().to_str_lossy().into_owned(),
                    StateRef::Unspecified => "unspecified".into(),
                };
            }
        }
        if hit(&values) {
            out.push(p.clone());
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

fn index_of(repo: &Repository) -> io::Result<gix::worktree::Index> {
    repo.index_or_empty().map_err(err)
}

impl TreeGit for GixDoor {
    fn kind(&self) -> DoorKind {
        DoorKind::Gix
    }

    fn head(&self, root: &Path) -> io::Result<Head> {
        let repo = open(root)?;
        let head = repo.head().map_err(err)?;
        Ok(Head {
            id: head.id().map(|i| i.to_string()),
            symref: head
                .referent_name()
                .map(|n| n.as_bstr().to_str_lossy().into_owned()),
        })
    }

    fn tree_diff(&self, root: &Path, a: &str, b: &str) -> io::Result<Vec<TreeChange>> {
        let repo = open(root)?;
        let mut out = Vec::new();
        diff(
            &repo,
            Some(commit_tree(&repo, a)?),
            Some(commit_tree(&repo, b)?),
            "",
            &mut out,
        )?;
        out.sort_by(|x, y| x.path.cmp(&y.path));
        Ok(out)
    }

    fn stat_status(&self, root: &Path) -> io::Result<Status> {
        let repo = open(root)?;
        let index = index_of(&repo)?;
        let opts = repo.stat_options().map_err(err)?;
        let head = head_tree(&repo)?;
        let stamp = index.timestamp();
        let mut dirty = BTreeSet::new();
        let mut seen = HashSet::new();
        for e in index.entries() {
            if e.mode.is_submodule() {
                continue;
            }
            let path = e.path(&index).to_str_lossy().into_owned();
            seen.insert(path.clone());
            let staged = head.get(&path)
                != Some(&Obj {
                    mode: e.mode.bits(),
                    blob: e.id.to_string(),
                });
            if e.stage_raw() != 0 || staged {
                dirty.insert(path);
                continue;
            }
            if e.flags.contains(gix::index::entry::Flags::SKIP_WORKTREE) {
                continue;
            }
            // stat only: a changed or racy stat is "possibly dirty"; the overlay reads and hashes it
            let clean = gix::index::fs::Metadata::from_path_no_follow(&root.join(&path))
                .ok()
                .and_then(|m| gix::index::entry::Stat::from_fs(&m).ok())
                .is_some_and(|st| e.stat.matches(&st, opts) && !e.stat.is_racy(stamp, opts));
            if !clean {
                dirty.insert(path);
            }
        }
        dirty.extend(head.into_keys().filter(|p| !seen.contains(p)));
        let (untracked, _) = walk(&repo, &index)?;
        Ok(Status {
            dirty: dirty.into_iter().collect(),
            untracked,
        })
    }

    fn ls_tree(&self, root: &Path, commit: &str) -> io::Result<Vec<TreeEntry>> {
        let repo = open(root)?;
        let mut m = BTreeMap::new();
        flatten(&repo, commit_tree(&repo, commit)?, "", &mut m)?;
        Ok(m.into_iter()
            .map(|(path, o)| TreeEntry {
                path,
                mode: o.mode,
                blob: o.blob,
            })
            .collect())
    }

    fn blobs(&self, root: &Path, paths: &[String]) -> io::Result<Vec<Blob>> {
        let repo = open(root)?;
        let index = index_of(&repo)?;
        let uncertain: HashSet<String> = filtered_in(&repo, &index, paths)?.into_iter().collect();
        let pinned = eitri::open_path(root, eitri::Kind::Dir)
            .map_err(|e| io::Error::other(format!("tree root: {e}")))?;
        paths
            .iter()
            .map(|p| {
                Ok(Blob {
                    id: raw_hash(&repo, &pinned, root, p)?,
                    uncertain: uncertain.contains(p),
                })
            })
            .collect()
    }

    fn filtered(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>> {
        let repo = open(root)?;
        let index = index_of(&repo)?;
        filtered_in(&repo, &index, paths)
    }

    fn as_git(&self) -> &dyn Git {
        self
    }
}

/// The file list's questions, in-process: the fallback listing of a touched tree runs on it. `history` and `show`
/// (the eval's) are not served.
impl Git for GixDoor {
    fn ls_files(&self, root: &Path) -> io::Result<Vec<String>> {
        let repo = open(root)?;
        let index = index_of(&repo)?;
        let mut all: Vec<String> = index
            .entries()
            .iter()
            .filter(|e| !e.mode.is_submodule())
            .map(|e| e.path(&index).to_str_lossy().into_owned())
            .collect();
        all.extend(walk(&repo, &index)?.0);
        all.sort();
        all.dedup();
        Ok(all)
    }

    fn blobs(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>> {
        let repo = open(root)?;
        let pinned = eitri::open_path(root, eitri::Kind::Dir)
            .map_err(|e| io::Error::other(format!("tree root: {e}")))?;
        paths
            .iter()
            .map(|p| raw_hash(&repo, &pinned, root, p))
            .collect()
    }

    fn head(&self, root: &Path) -> io::Result<String> {
        TreeGit::head(self, root)?
            .id
            .ok_or_else(|| io::Error::other("gix: HEAD is unborn"))
    }

    fn nested(&self, root: &Path) -> io::Result<Vec<String>> {
        let repo = open(root)?;
        let index = index_of(&repo)?;
        let mut out = walk(&repo, &index)?.1;
        out.extend(
            index
                .entries()
                .iter()
                .filter(|e| e.mode.is_submodule())
                .map(|e| e.path(&index).to_str_lossy().into_owned()),
        );
        out.sort();
        out.dedup();
        Ok(out)
    }

    fn generated(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>> {
        let repo = open(root)?;
        let index = index_of(&repo)?;
        attr_hits(
            &repo,
            &index,
            paths,
            |v| v.iter().any(|x| x == "set" || x == "true"),
            &["linguist-generated", "linguist-vendored"],
        )
    }

    fn history(&self, _root: &Path, _limit: usize) -> io::Result<Vec<Commit>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "gix door: no history",
        ))
    }

    fn show(&self, _root: &Path, _rev: &str, _path: &str) -> io::Result<Vec<u8>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "gix door: no show",
        ))
    }
}
