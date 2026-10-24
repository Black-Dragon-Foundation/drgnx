//! Step snapshots (Task 19, Calls made 15): a shadow repository per worktree under `<state>/hub/checkpoints/<hash>.git`
//! and, in it, a tree of the worktree written with a persistent per-session index (a temporary one loses the stat
//! cache and rehashes the whole tree every step), kept as `refs/drgnx/s/<sid>/<seq>`.  Secret files are never in a
//! tree.  Restore and fork are part 4's.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Names that never enter a snapshot, besides the sandbox's secret files ([`gleipnir::toolchain::SECRET_FILES`]).
const ALSO_SECRET: &[&str] = &["secrets.env", "*.pem", "*.key", "id_rsa", "id_ed25519"];

/// What [`prune`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pruned {
    /// Under the cap already.
    Fits,
    /// Finished sessions' refs were removed (their names) and the repositories collected; now under the cap.
    Freed(Vec<String>),
    /// Over the cap with nothing finished left to remove: snapshots stop (a running task's refs are never removed).
    Stop,
}

/// A name safe in a ref and a file name.
fn safe(sid: &str) -> String {
    sid.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// The shadow repository of WORKTREE under ROOT (`<hash>.git`; FNV-1a of the path, stable across builds).
pub fn repo_of(root: &Path, worktree: &Path) -> PathBuf {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in worktree.to_string_lossy().bytes() {
        h = (h ^ u64::from(b)).wrapping_mul(0x100000001b3);
    }
    root.join(format!("{h:016x}.git"))
}

fn git(
    repo: &Path,
    worktree: Option<&Path>,
    index: Option<&Path>,
    args: &[&str],
) -> Result<String, String> {
    let mut c = Command::new("git");
    c.env("GIT_DIR", repo)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE");
    if let Some(w) = worktree {
        c.env("GIT_WORK_TREE", w).current_dir(w);
    } else {
        c.current_dir(repo);
    }
    if let Some(i) = index {
        c.env("GIT_INDEX_FILE", i);
    }
    let out = c.args(args).output().map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "git {}: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// The pathspecs that leave the secret files out: the fixed names, EXTRA (the secrets table's paths, relative to
/// the worktree) and the usual key files, anywhere in the tree.
fn excludes(extra: &[String]) -> Vec<String> {
    let mut names: BTreeSet<String> = gleipnir::toolchain::SECRET_FILES
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    names.extend(ALSO_SECRET.iter().map(|s| (*s).to_string()));
    let mut out: Vec<String> = names
        .into_iter()
        .map(|n| format!(":(exclude,glob)**/{n}"))
        .collect();
    out.extend(extra.iter().map(|p| {
        format!(
            ":(exclude,glob){}",
            p.trim_start_matches("./").trim_start_matches('/')
        )
    }));
    out
}

/// A tree of WORKTREE, kept as `refs/drgnx/s/<SID>/<SEQ>` in its shadow repository under ROOT; answers the tree id.
/// EXTRA are more paths to leave out (relative to the worktree).  Blocking: callers run it off the async threads.
pub fn take(
    root: &Path,
    worktree: &Path,
    sid: &str,
    seq: u64,
    extra: &[String],
) -> Result<String, String> {
    let repo = repo_of(root, worktree);
    if !repo.join("HEAD").exists() {
        std::fs::create_dir_all(&repo).map_err(|e| format!("{}: {e}", repo.display()))?;
        git(&repo, None, None, &["init", "--bare", "-q", "."])?;
    }
    let index = repo.join(format!("index-{}", safe(sid)));
    let mut add: Vec<String> = ["add", "-A", "--ignore-errors", "--", "."]
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    add.extend(excludes(extra));
    let add: Vec<&str> = add.iter().map(String::as_str).collect();
    git(&repo, Some(worktree), Some(&index), &add)?;
    let tree = git(&repo, Some(worktree), Some(&index), &["write-tree"])?;
    let name = format!("refs/drgnx/s/{}/{seq}", safe(sid));
    git(&repo, None, None, &["update-ref", &name, &tree])?;
    Ok(tree)
}

/// Bytes under DIR (files only).
fn size_of(dir: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return 0;
    };
    rd.flatten()
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() => size_of(&e.path()),
            Ok(m) => m.len(),
            Err(_) => 0,
        })
        .sum()
}

/// The size of REPOS together.
pub fn size(repos: &[PathBuf]) -> u64 {
    repos.iter().map(|r| size_of(r)).sum()
}

/// Bring REPOS (a project's shadow repositories) under CAP bytes: the refs of FINISHED sessions (oldest first) go one
/// session at a time, then the repositories are collected (`git gc --prune=now`).  A running session's refs are never
/// removed: over the cap with no finished session left answers [`Pruned::Stop`].
pub fn prune(repos: &[PathBuf], cap: u64, finished: &[String]) -> Pruned {
    if size(repos) <= cap {
        return Pruned::Fits;
    }
    let mut gone = Vec::new();
    for sid in finished {
        let prefix = format!("refs/drgnx/s/{}/", safe(sid));
        let mut any = false;
        for repo in repos {
            let Ok(refs) = git(
                repo,
                None,
                None,
                &["for-each-ref", "--format=%(refname)", &prefix],
            ) else {
                continue;
            };
            for r in refs.lines().filter(|l| !l.is_empty()) {
                any |= git(repo, None, None, &["update-ref", "-d", r]).is_ok();
            }
            let _ = std::fs::remove_file(repo.join(format!("index-{}", safe(sid))));
        }
        if !any {
            continue;
        }
        gone.push(sid.clone());
        for repo in repos {
            let _ = git(repo, None, None, &["gc", "-q", "--prune=now"]);
        }
        if size(repos) <= cap {
            return Pruned::Freed(gone);
        }
    }
    if gone.is_empty() {
        Pruned::Stop
    } else if size(repos) <= cap {
        Pruned::Freed(gone)
    } else {
        Pruned::Stop
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Bytes git cannot compress much.
    fn noise(seed: u64, n: usize) -> Vec<u8> {
        let mut x = seed | 1;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 24) as u8
            })
            .collect()
    }

    fn listing(repo: &Path, tree: &str) -> Vec<String> {
        git(repo, None, None, &["ls-tree", "-r", "--name-only", tree])
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect()
    }

    #[test]
    fn timeline_snapshot_after_an_edit() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("a.txt"), "one").unwrap();
        let t1 = take(&root, &wt, "s1", 1, &[]).unwrap();
        std::fs::write(wt.join("a.txt"), "two").unwrap();
        let t2 = take(&root, &wt, "s1", 2, &[]).unwrap();
        assert_ne!(t1, t2);
        let repo = repo_of(&root, &wt);
        assert_eq!(
            git(&repo, None, None, &["rev-parse", "refs/drgnx/s/s1/1"]).unwrap(),
            t1
        );
        assert_eq!(
            git(&repo, None, None, &["rev-parse", "refs/drgnx/s/s1/2"]).unwrap(),
            t2
        );
        assert_eq!(listing(&repo, &t2), ["a.txt"]);
        // the same content again is the same tree
        assert_eq!(take(&root, &wt, "s1", 3, &[]).unwrap(), t2);
    }

    #[test]
    fn timeline_snapshot_skips_secret_files() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        for f in [
            "a.txt",
            ".env",
            "sub/.env",
            "sub/.npmrc",
            "secrets.env",
            "x.pem",
            "keep/own-secret.txt",
        ] {
            let p = wt.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, "x").unwrap();
        }
        let t = take(&root, &wt, "s1", 1, &["keep/own-secret.txt".into()]).unwrap();
        assert_eq!(listing(&repo_of(&root, &wt), &t), ["a.txt"]);
    }

    #[test]
    fn timeline_cap_prunes_finished_first() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("big"), noise(1, 60_000)).unwrap();
        take(&root, &wt, "old", 1, &[]).unwrap();
        std::fs::write(wt.join("big"), noise(2, 60_000)).unwrap();
        take(&root, &wt, "live", 1, &[]).unwrap();
        let repos = vec![repo_of(&root, &wt)];
        let before = size(&repos);
        assert_eq!(prune(&repos, before, &["old".into()]), Pruned::Fits);
        assert_eq!(
            prune(&repos, before - 30_000, &["old".into()]),
            Pruned::Freed(vec!["old".into()])
        );
        assert!(size(&repos) < before - 30_000);
        let refs = git(
            &repos[0],
            None,
            None,
            &["for-each-ref", "--format=%(refname)"],
        )
        .unwrap();
        assert_eq!(refs, "refs/drgnx/s/live/1");
    }

    #[test]
    fn timeline_cap_with_nothing_finished_stops_with_a_notice() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("big"), noise(3, 60_000)).unwrap();
        take(&root, &wt, "live", 1, &[]).unwrap();
        let repos = vec![repo_of(&root, &wt)];
        assert_eq!(prune(&repos, 1_000, &[]), Pruned::Stop);
        let refs = git(
            &repos[0],
            None,
            None,
            &["for-each-ref", "--format=%(refname)"],
        )
        .unwrap();
        assert_eq!(refs, "refs/drgnx/s/live/1");
    }
}
