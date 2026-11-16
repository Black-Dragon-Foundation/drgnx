//! The repositories a Source Control view lists: every repository in or under the workspace's folders (a folder
//! holding `.git`, a directory or a linked worktree's file), nested ones too, then the linked worktrees each one
//! names (`git worktree list --porcelain`), at most [`REPOS_MAX`].

use std::collections::{BTreeSet, VecDeque};
use std::path::{Path, PathBuf};

/// The most repositories a view lists.
pub const REPOS_MAX: usize = 200;
/// The most folders one scan looks into.
pub const FOLDERS_MAX: usize = 50_000;
/// How deep under a workspace folder a repository is looked for.
pub const DEPTH_MAX: usize = 6;

/// Folders never looked into: git's own, and the trees of packages and builds.
const SKIPPED: [&str; 4] = [".git", "node_modules", "target", ".venv"];

/// A repository found: its top folder and the name its row shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub root: PathBuf,
    pub name: String,
    /// A linked worktree: its main repository's top.
    pub main: Option<PathBuf>,
}

fn is_repo(dir: &Path) -> bool {
    dir.join(".git").exists()
}

fn base(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| p.to_string_lossy().into_owned())
}

/// The repositories in and under ROOTS, breadth first, each workspace folder's in turn, then each one's linked
/// worktrees ([`worktrees_of`]) not found already, after them.
pub fn find(roots: &[PathBuf]) -> Vec<Found> {
    let mut seen: BTreeSet<PathBuf> = BTreeSet::new();
    let mut found: Vec<Found> = Vec::new();
    let mut folders = 0usize;
    let add = |found: &mut Vec<Found>, seen: &mut BTreeSet<PathBuf>, f: Found| {
        let key = std::fs::canonicalize(&f.root).unwrap_or_else(|_| f.root.clone());
        if found.len() < REPOS_MAX && seen.insert(key) {
            found.push(f);
        }
    };
    for root in roots {
        // a workspace folder inside a repository: that repository
        if !is_repo(root)
            && let Some(top) = root.ancestors().skip(1).find(|a| is_repo(a))
        {
            add(
                &mut found,
                &mut seen,
                Found {
                    root: top.to_path_buf(),
                    name: base(top),
                    main: None,
                },
            );
        }
        let mut queue: VecDeque<(PathBuf, usize)> = VecDeque::from([(root.clone(), 0)]);
        while let Some((dir, depth)) = queue.pop_front() {
            if found.len() >= REPOS_MAX || folders >= FOLDERS_MAX {
                break;
            }
            folders += 1;
            if is_repo(&dir) {
                let main = linked_main(&dir);
                let name = match &main {
                    Some(m) => format!("{} · {}", base(m), base(&dir)),
                    None => base(&dir),
                };
                add(
                    &mut found,
                    &mut seen,
                    Found {
                        root: dir.clone(),
                        name,
                        main,
                    },
                );
            }
            if depth >= DEPTH_MAX {
                continue;
            }
            let Ok(rd) = std::fs::read_dir(&dir) else {
                continue;
            };
            let mut kids: Vec<PathBuf> = rd
                .flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .filter(|e| !SKIPPED.iter().any(|s| e.file_name() == *s))
                .map(|e| e.path())
                .collect();
            kids.sort();
            queue.extend(kids.into_iter().map(|k| (k, depth + 1)));
        }
    }
    // the linked worktrees of each repository found, after it
    let mains: Vec<Found> = found.iter().filter(|f| f.main.is_none()).cloned().collect();
    for m in mains {
        for wt in worktrees_of(&m.root) {
            if wt.is_dir() {
                let name = format!("{} · {}", m.name, base(&wt));
                add(
                    &mut found,
                    &mut seen,
                    Found {
                        root: wt,
                        name,
                        main: Some(m.root.clone()),
                    },
                );
            }
        }
    }
    found
}

/// A linked worktree's main repository: the top above the common dir its `.git` file names, else none.
fn linked_main(dir: &Path) -> Option<PathBuf> {
    let (gitdir, common) = super::super::git::git_dirs(dir)?;
    if gitdir == common {
        return None;
    }
    let common = std::fs::canonicalize(common).ok()?;
    (common.file_name()? == ".git").then(|| common.parent().map(Path::to_path_buf))?
}

/// The linked worktrees of the repository at MAIN: what each `worktrees/*/gitdir` of its git dir names (the
/// worktree's `.git` file), without running git.
pub fn worktrees_of(main: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(main.join(".git").join("worktrees")) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = rd
        .flatten()
        .filter_map(|e| std::fs::read_to_string(e.path().join("gitdir")).ok())
        .filter_map(|t| Path::new(t.trim()).parent().map(Path::to_path_buf))
        .collect();
    out.sort();
    out
}
