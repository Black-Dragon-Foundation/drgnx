//! The ranked file query (Quick Open, Find): a root's names and the N best of them for a query.
//!
//! The names ([`names`]) are what a repository's `git ls-files -z --cached --others --exclude-standard` lists, with no
//! file read; elsewhere a walk that follows no link and applies the `.gitignore` files it meets. Binary, large and
//! linked files are names like any other. Hrafn's exclude globs apply to both, and the search setting
//! (`drgnx-search-ignore-rules`, [`Ignore`]) decides whether dot paths and secret-looking names are left out as the
//! index leaves them out (`index`) or listed (`real`).
//!
//! The ranking ([`NameList::top`], and [`rank`] for the overlay's view): every word of the query (case-insensitive) is
//! in the path; a basename that starts with the first word and holds them all first, then a basename that holds them
//! all, then a path that does; shorter, then by path, among equals.
//!
//! In a worktree view (H16 overlay design §4) the file set is the base's paths, less the tree's tombstones, plus the
//! tree's new paths. One base list is shared by every view; a tree adds a small delta.

use crate::CodeStore;
use crate::files::Glob;
use crate::grep::{Ignore, searched};
use crate::store::StoreError;
use crate::tree::View;
use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// A tree's difference from the base's file list.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Delta {
    /// Paths the tree has and the base does not.
    pub added: Vec<String>,
    /// Base paths the tree does not admit (its tombstones).
    pub removed: HashSet<String>,
}

/// The base's file list (the paths it has content for), sorted.
pub async fn base_paths(store: &CodeStore) -> Result<Arc<[String]>, StoreError> {
    let paths: Vec<String> = store
        .handle()
        .read(|c| {
            let mut st = c.prepare(
                "select path from file where tree = 0 and blob is not null order by path",
            )?;
            Ok(st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?)
        })
        .await?;
    Ok(Arc::from(paths))
}

/// VIEW's delta from the base (empty for the base view): read from the tree's own rows, through the `file` primary
/// key, so it costs the tree's differing paths only.
pub async fn delta(store: &CodeStore, view: View) -> Result<Delta, StoreError> {
    let View::Tree(t) = view else {
        return Ok(Delta::default());
    };
    let rows: Vec<(String, bool, bool)> = store
        .handle()
        .read(move |c| {
            let mut st = c.prepare(
                "select f.path, f.blob is null,
                   exists (select 1 from file b where b.tree = 0 and b.path = f.path and b.blob is not null)
                 from file f where f.tree = ?1 order by f.path",
            )?;
            Ok(st
                .query_map([t.0], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<_, _>>()?)
        })
        .await?;
    let mut d = Delta::default();
    for (path, tombstone, in_base) in rows {
        match (tombstone, in_base) {
            (true, true) => {
                d.removed.insert(path);
            }
            (false, false) => d.added.push(path),
            // T's other content of a base path, or a tombstone over nothing: the list is the same
            _ => {}
        }
    }
    Ok(d)
}

/// The words of QUERY, lower case.
fn words(query: &str) -> Vec<String> {
    query.split_whitespace().map(str::to_lowercase).collect()
}

/// LOWER's tier for WORDS (see the module's doc), or none when a word is not in it.
fn tier(lower: &str, words: &[String]) -> Option<u8> {
    if !words.iter().all(|w| lower.contains(w.as_str())) {
        return None;
    }
    let name = lower.rsplit('/').next().unwrap_or(lower);
    let all_in_name = words.iter().all(|w| name.contains(w.as_str()));
    Some(match words.first() {
        Some(w) if all_in_name && name.starts_with(w.as_str()) => 0,
        _ if all_in_name => 1,
        _ => 2,
    })
}

/// The N best paths of BASE with DELTA applied for QUERY.
pub fn rank(base: &[String], delta: &Delta, query: &str, n: usize) -> Vec<String> {
    let ws = words(query);
    let mut scored: Vec<(u8, usize, &str)> = base
        .iter()
        .filter(|p| !delta.removed.contains(*p))
        .chain(&delta.added)
        .filter_map(|p| Some((tier(&p.to_lowercase(), &ws)?, p.len(), p.as_str())))
        .collect();
    scored.sort_unstable();
    scored
        .into_iter()
        .take(n)
        .map(|(_, _, p)| p.to_string())
        .collect()
}

/// The N best paths of VIEW for QUERY.
pub async fn files(
    store: &CodeStore,
    view: View,
    query: &str,
    n: usize,
) -> Result<Vec<String>, StoreError> {
    let (base, d) = (base_paths(store).await?, delta(store, view).await?);
    Ok(rank(&base, &d, query, n))
}

/// A ranked name: the path and where the query's words matched in it (character ranges, sorted, not overlapping).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ranked {
    pub path: String,
    pub runs: Vec<(usize, usize)>,
}

/// A root's names with their lower-case forms, made once per listing and ranked per query.
pub struct NameList {
    names: Vec<String>,
    lower: Vec<String>,
}

/// A query looks at its cancel flag after this many names.
const CANCEL_EVERY: usize = 4096;

impl NameList {
    pub fn new(names: Vec<String>) -> NameList {
        let lower = names.iter().map(|n| n.to_lowercase()).collect();
        NameList { names, lower }
    }

    pub fn len(&self) -> usize {
        self.names.len()
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }

    /// The N best names for QUERY; none when CANCEL was set while it ran (a newer query took its place).
    pub fn top(&self, query: &str, n: usize, cancel: &AtomicBool) -> Option<Vec<Ranked>> {
        let ws = words(query);
        let mut scored: Vec<(u8, usize, usize)> = Vec::new();
        for (i, lower) in self.lower.iter().enumerate() {
            if i % CANCEL_EVERY == 0 && cancel.load(Ordering::Relaxed) {
                return None;
            }
            if let Some(t) = tier(lower, &ws) {
                scored.push((t, self.names[i].len(), i));
            }
        }
        if cancel.load(Ordering::Relaxed) {
            return None;
        }
        let key = |&(t, len, i): &(u8, usize, usize)| (t, len, &self.names[i]);
        if scored.len() > n && n > 0 {
            scored.select_nth_unstable_by(n - 1, |a, b| key(a).cmp(&key(b)));
        }
        scored.truncate(n);
        scored.sort_unstable_by(|a, b| key(a).cmp(&key(b)));
        Some(
            scored
                .into_iter()
                .map(|(_, _, i)| Ranked {
                    path: self.names[i].clone(),
                    runs: runs(&self.names[i], &self.lower[i], &ws),
                })
                .collect(),
        )
    }
}

/// Where WORDS matched in PATH (LOWER its lower case): each word's first place in the basename, else in the path, as
/// character ranges, merged. None when lower-casing changed the length (the places would not line up).
fn runs(path: &str, lower: &str, words: &[String]) -> Vec<(usize, usize)> {
    if path.len() != lower.len() || path.chars().count() != lower.chars().count() {
        return vec![];
    }
    let base = lower.rfind('/').map_or(0, |i| i + 1);
    let mut out: Vec<(usize, usize)> = words
        .iter()
        .filter(|w| !w.is_empty())
        .filter_map(|w| {
            let at = lower[base..]
                .find(w.as_str())
                .map(|i| i + base)
                .or_else(|| lower.find(w.as_str()))?;
            let from = lower[..at].chars().count();
            Some((from, from + w.chars().count()))
        })
        .collect();
    out.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for (a, b) in out {
        match merged.last_mut() {
            Some(last) if a <= last.1 => last.1 = last.1.max(b),
            _ => merged.push((a, b)),
        }
    }
    merged
}

/// ROOT's names (relative, sorted): see the module's doc. EXCLUDE are Hrafn's exclude globs.
pub fn names(root: &Path, ignore: Ignore, exclude: &[String]) -> io::Result<Vec<String>> {
    let exclude: Vec<Glob> = exclude.iter().map(|g| Glob::config(g)).collect();
    let mut out = if root.ancestors().any(|d| d.join(".git").exists()) {
        git_names(root)?
    } else {
        let mut out = Vec::new();
        walk(root, "", &mut Vec::new(), &mut out)?;
        out
    };
    out.retain(|p| searched(ignore, p) && !exclude.iter().any(|g| g.matches(p)));
    out.sort_unstable();
    out.dedup();
    Ok(out)
}

/// What git lists under ROOT (paths relative to it). A nested repository is listed as its folder (`dir/`): left out.
fn git_names(root: &Path) -> io::Result<Vec<String>> {
    let out = Command::new("git")
        .args([
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ])
        .current_dir(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "git ls-files: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(out
        .stdout
        .split(|b| *b == 0)
        .filter(|n| !n.is_empty() && !n.ends_with(b"/"))
        .map(|n| String::from_utf8_lossy(n).into_owned())
        .collect())
}

/// One `.gitignore` line: `!` keeps, a trailing `/` names folders only; the glob is placed under its file's folder.
struct Pattern {
    keep: bool,
    dir_only: bool,
    glob: Glob,
}

/// The `.gitignore` of the folder BASE (relative to the root, `""` for the root itself).
struct Rules {
    base: String,
    patterns: Vec<Pattern>,
}

impl Rules {
    fn read(file: &Path, base: &str) -> Option<Rules> {
        let text = std::fs::read_to_string(file).ok()?;
        let patterns = text
            .lines()
            .filter_map(|line| {
                let line = line.trim_end();
                if line.is_empty() || line.starts_with('#') {
                    return None;
                }
                let (keep, line) = match line.strip_prefix('!') {
                    Some(rest) => (true, rest),
                    None => (false, line.strip_prefix('\\').unwrap_or(line)),
                };
                let (dir_only, line) = match line.strip_suffix('/') {
                    Some(rest) => (true, rest),
                    None => (false, line),
                };
                // a slash before the end anchors the pattern to its file's folder; without one it matches at any depth
                let glob = match line.strip_prefix('/') {
                    Some(rest) => rest.to_owned(),
                    None if line.contains('/') => line.to_owned(),
                    None => format!("**/{line}"),
                };
                (!glob.is_empty()).then(|| Pattern {
                    keep,
                    dir_only,
                    glob: Glob::exact(&glob),
                })
            })
            .collect();
        Some(Rules {
            base: base.to_owned(),
            patterns,
        })
    }

    /// Whether this file decides REL (relative to the root): `Some(true)` ignored, `Some(false)` kept.
    fn decide(&self, rel: &str, dir: bool) -> Option<bool> {
        let under = if self.base.is_empty() {
            rel
        } else {
            rel.strip_prefix(&self.base)?.strip_prefix('/')?
        };
        self.patterns
            .iter()
            .rev()
            .find(|p| (dir || !p.dir_only) && p.glob.matches(under))
            .map(|p| !p.keep)
    }
}

/// Whether the `.gitignore` files in force (STACK, the root's first) ignore REL: the deepest file that decides wins.
fn ignored(stack: &[Rules], rel: &str, dir: bool) -> bool {
    stack
        .iter()
        .rev()
        .find_map(|r| r.decide(rel, dir))
        .unwrap_or(false)
}

/// The names under ROOT/DIR into OUT; STACK holds the `.gitignore` rules of DIR's folders.
fn walk(root: &Path, dir: &str, stack: &mut Vec<Rules>, out: &mut Vec<String>) -> io::Result<()> {
    let abs = root.join(dir);
    let pushed = match Rules::read(&abs.join(".gitignore"), dir) {
        Some(r) => {
            stack.push(r);
            true
        }
        None => false,
    };
    let entries = match std::fs::read_dir(&abs) {
        Ok(e) => e,
        // a folder that cannot be read lists nothing (the root itself must)
        Err(_) if !dir.is_empty() => {
            if pushed {
                stack.pop();
            }
            return Ok(());
        }
        Err(e) => return Err(e),
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == ".git" {
            continue;
        }
        let rel = if dir.is_empty() {
            name
        } else {
            format!("{dir}/{name}")
        };
        // the entry's own type: a link is never followed
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if ignored(stack, &rel, kind.is_dir()) {
            continue;
        }
        if kind.is_dir() {
            walk(root, &rel, stack, out)?;
        } else {
            out.push(rel);
        }
    }
    if pushed {
        stack.pop();
    }
    Ok(())
}
