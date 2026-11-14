//! A pack folder, checked whole (`ratatoskr packs check`): the manifest, every file it names, `highlights.scm`, and no
//! symlink leaving the folder.

use std::path::{Path, PathBuf};

use crate::check::{Claims, Problem, ProblemKind, Source, check, p};
use crate::highlights;
use crate::manifest::{Manifest, read};

#[derive(Debug)]
pub struct Report {
    pub manifest: Option<Manifest>,
    pub problems: Vec<Problem>,
}

/// The files of the tree under DIR (relative, `/`-separated), and the symlinks among them that leave it.
fn walk(root: &Path, dir: &Path, problems: &mut Vec<Problem>, depth: usize) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let path = e.path();
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            if !inside(root, &path) {
                problems.push(p(ProblemKind::Tree, rel, "a symlink leaving the pack"));
            }
        } else if meta.is_dir() && depth < 16 {
            walk(root, &path, problems, depth + 1);
        }
    }
}

fn inside(root: &Path, file: &Path) -> bool {
    match (root.canonicalize(), file.canonicalize()) {
        (Ok(r), Ok(f)) => f.starts_with(r),
        _ => false,
    }
}

/// Reads REL under DIR for the field AT: a problem when it is missing, or a symlink out of DIR.
fn file(dir: &Path, rel: &str, at: &str, problems: &mut Vec<Problem>) -> Option<String> {
    let path: PathBuf = dir.join(rel);
    let Ok(meta) = std::fs::symlink_metadata(&path) else {
        problems.push(p(
            ProblemKind::Missing,
            at,
            format!("{rel} is not in the pack"),
        ));
        return None;
    };
    if meta.file_type().is_symlink() && !inside(dir, &path) {
        problems.push(p(
            ProblemKind::Tree,
            at,
            format!("{rel} is a symlink leaving the pack"),
        ));
        return None;
    }
    if meta.len() > 4 << 20 {
        problems.push(p(ProblemKind::Schema, at, format!("{rel} is over 4 MiB")));
        return None;
    }
    match std::fs::read_to_string(&path) {
        Ok(t) => Some(t),
        Err(e) => {
            problems.push(p(ProblemKind::Missing, at, format!("{rel}: {e}")));
            None
        }
    }
}

pub fn check_dir(dir: &Path, source: Source, claims: &Claims) -> Report {
    let mut problems = Vec::new();
    let manifest = match file_bytes(dir) {
        Err(e) => {
            problems.push(p(ProblemKind::Missing, "pack.eld", e));
            None
        }
        Ok(bytes) => match read(&bytes) {
            Err(e) => {
                problems.push(p(
                    ProblemKind::Schema,
                    e.path.clone().unwrap_or_else(|| "pack.eld".into()),
                    e.message,
                ));
                None
            }
            Ok(m) => Some(m),
        },
    };
    walk(dir, dir, &mut problems, 0);
    if let Some(m) = &manifest {
        problems.extend(check(m, source, claims));
        let named = [
            (
                "hrafn.tags",
                m.hrafn.as_ref().and_then(|h| h.tags.as_deref()),
            ),
            (
                "hrafn.chunks",
                m.hrafn.as_ref().and_then(|h| h.chunks.as_deref()),
            ),
            (
                "inline.query",
                m.inline.as_ref().and_then(|i| i.query.as_deref()),
            ),
        ];
        for (at, rel) in named {
            if let Some(rel) = rel
                && !problems.iter().any(|q| q.path == at)
            {
                file(dir, rel, at, &mut problems);
            }
        }
        let generic = m.mode.as_ref().is_some_and(|m| m.generic);
        let hl = "queries/highlights.scm";
        let present = std::fs::symlink_metadata(dir.join(hl)).is_ok();
        if (generic || present)
            && let Some(text) = file(dir, hl, hl, &mut problems)
        {
            for why in highlights::check(&text) {
                problems.push(p(ProblemKind::Highlights, hl, why));
            }
        }
    }
    Report { manifest, problems }
}

fn file_bytes(dir: &Path) -> Result<Vec<u8>, String> {
    std::fs::read(dir.join("pack.eld")).map_err(|e| format!("pack.eld: {e}"))
}
