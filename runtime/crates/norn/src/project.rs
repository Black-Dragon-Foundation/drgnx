//! Projects (Task 10; storage §5.3): `project:<root commit, 12 hex>`, taken once and kept; worktrees share their
//! repository's; slugs as `project_alias` rows. The git reads are the hardened ones of `hello` (`draugr::git` with
//! `Place::Trusted { read_only: true }`, a minimal environment, 3 s), run outside any write transaction.

use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::ffi::{OsStr, OsString};
use std::hash::{BuildHasher, Hasher};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Value, json};
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::{Tx, WriteError};

/// A repository as git shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectRef {
    /// `project:<12 hex>`, or `project:x-<8 base36>` before the first commit. What a first registration takes:
    /// [`register`] answers the project already stored for this repository when there is one.
    pub id: String,
    /// The git top-level (a worktree's main repository's for worktrees).
    pub root: PathBuf,
    /// The folder name (an alias).
    pub slug: String,
    /// The root commit the id is made from: the earliest by committer date, ties by sha.
    pub root_commit: Option<String>,
    /// Every root commit reachable from HEAD, in that order (a later merge can bring in an earlier one; the stored
    /// project is still found through the one it was made from).
    pub roots: Vec<String>,
}

/// How long a git command may take before it is given up (as `hello`'s).
const GIT_TIMEOUT: Duration = Duration::from_secs(3);

/// The variables git keeps from the hub's environment (as `hello`'s, call 10).
const GIT_ENV: [&str; 6] = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"];

/// git ARGS in DIR, blocking: its whole output, or `None` when git is not the trusted one, fails, or takes over
/// [`GIT_TIMEOUT`] (it is killed). `draugr::git`'s overrides, no terminal, stdin closed, a minimal environment.
pub(crate) fn git(dir: &Path, args: &[&str]) -> Option<String> {
    use draugr::git::{GitCall, Place, command, git_program};
    let program = git_program().ok()?;
    let (argv, extra) = command(&GitCall {
        place: Place::Trusted { read_only: true },
        allow_protocols: Vec::new(),
        args: args.iter().map(OsString::from).collect(),
    })
    .ok()?;
    let set: Vec<(&str, &OsStr)> = extra
        .iter()
        .filter_map(|(k, v)| Some((k.to_str()?, v.as_os_str())))
        .collect();
    let env = draugr::env::build(&GIT_ENV, &[], &set);
    let mut child = Command::new(&program.path)
        .args(&argv)
        .current_dir(dir)
        .env_clear()
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let (send, recv) = mpsc::channel();
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let read = stdout.read_to_end(&mut out).map(|_| out).ok();
        let _ = send.send(read);
    });
    let Ok(out) = recv.recv_timeout(GIT_TIMEOUT) else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    if !child.wait().ok()?.success() {
        return None;
    }
    String::from_utf8(out?).ok()
}

fn first_line(text: &str) -> Option<&str> {
    text.lines().find(|l| !l.is_empty())
}

/// `$HOME` as a truename.
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .and_then(|h| std::fs::canonicalize(h).ok())
}

/// `x-` and 8 base36 characters, random.
fn random_x() -> String {
    let mut h = RandomState::new().build_hasher();
    h.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos()),
    );
    h.write_u32(std::process::id());
    format!("x-{}", base36(h.finish(), 8))
}

/// The last LEN base36 digits of V.
pub(crate) fn base36(mut v: u64, len: usize) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = vec![b'0'; len];
    for slot in out.iter_mut().rev() {
        *slot = DIGITS[(v % 36) as usize];
        v /= 36;
    }
    String::from_utf8(out).expect("ASCII digits")
}

/// The git top-level of CWD and its project; `None` outside a repository, for the home folder itself (a repository
/// of dotfiles holds no project, as `hello` rules), or when the trusted git cannot run. Blocking (runs git): not on
/// an async worker, never under the writer's lock.
pub fn resolve(cwd: &Path) -> Option<ProjectRef> {
    let top = git(cwd, &["rev-parse", "--show-toplevel"])?;
    let top = std::fs::canonicalize(first_line(&top)?).ok()?;
    // A linked worktree's common dir is its main repository's `.git`: the main top-level is its parent.
    let root = git(
        cwd,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    .and_then(|out| first_line(&out).and_then(|l| std::fs::canonicalize(l).ok()))
    .filter(|common| common.file_name() == Some(OsStr::new(".git")))
    .and_then(|common| common.parent().map(Path::to_path_buf))
    .unwrap_or(top);
    if home_dir().as_deref() == Some(root.as_path()) {
        return None;
    }
    let slug = root.file_name()?.to_string_lossy().into_owned();
    let mut roots: Vec<(i64, String)> =
        git(cwd, &["log", "--max-parents=0", "--format=%ct %H", "HEAD"])
            .map(|out| {
                out.lines()
                    .filter_map(|l| {
                        let (ct, sha) = l.split_once(' ')?;
                        let ok = sha.len() >= 12 && sha.bytes().all(|b| b.is_ascii_hexdigit());
                        Some((ct.parse().ok()?, ok.then(|| sha.to_ascii_lowercase())?))
                    })
                    .collect()
            })
            .unwrap_or_default();
    roots.sort();
    let roots: Vec<String> = roots.into_iter().map(|(_, sha)| sha).collect();
    let root_commit = roots.first().cloned();
    let id = match &root_commit {
        Some(sha) => format!("project:{}", &sha[..12]),
        None => format!("project:{}", random_x()),
    };
    Some(ProjectRef {
        id,
        root,
        slug,
        root_commit,
        roots,
    })
}

/// A live `project` entity: `(n, data.root, data.path)`.
type Stored = (i64, Option<String>, Option<String>);

/// The live `project` entities.
fn projects(tx: &Tx<'_>) -> Result<Vec<Stored>, WriteError> {
    let mut stmt = tx.sql().prepare(
        "select n, json_extract(data, '$.root'), json_extract(data, '$.path') from entity \
         where kind = 'project' and retired_tx is null order by n",
    )?;
    let rows = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// A new `project` entity for ROOT under ID, its `project` column its own `n`.
fn create(tx: &mut Tx<'_>, id: &str, root: &ProjectRef) -> Result<i64, WriteError> {
    let ent = entity::create(
        tx,
        EntityNew {
            id: id.to_string(),
            kind: "project".into(),
            project: None,
            title: Some(root.slug.clone()),
            status: None,
            body: None,
            priority: None,
            assignee: None,
            data: json!({
                "root": root.root_commit,
                "path": root.root.to_string_lossy(),
            }),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    entity::update(
        tx,
        ent.n,
        None,
        Changes {
            project: Some(Some(ent.n)),
            ..Changes::default()
        },
    )?;
    Ok(ent.n)
}

/// The project entity of ROOT (made when new) and its `n`; its slug becomes an alias when no project has it yet (a
/// renamed folder adds one; a slug another project holds stays with it).
///
/// - With a root commit: the stored project made from any of ROOT's roots (so a later merge of an earlier root
///   changes nothing), else a new `project:<12 hex>`. A `project:x-…` project of the same folder (made before the
///   first commit) gives its aliases to it and is retired, `data.moved_to` naming the new id.
/// - Without one: the `project:x-…` project of the same folder, else a new one under `root.id`.
pub fn register(tx: &mut Tx<'_>, root: &ProjectRef) -> Result<i64, WriteError> {
    let path = root.root.to_string_lossy().into_owned();
    let path = Some(path.as_str());
    let live = projects(tx)?;
    let n = match &root.root_commit {
        Some(_) => {
            let stored = live
                .iter()
                .find(|(_, r, _)| r.as_ref().is_some_and(|r| root.roots.contains(r)));
            let n = match stored {
                Some((n, _, _)) => *n,
                None => create(tx, &root.id, root)?,
            };
            for (x, _, _) in live
                .iter()
                .filter(|(x, r, p)| *x != n && r.is_none() && p.as_deref() == path)
            {
                let slugs: Vec<String> = {
                    let mut stmt = tx.sql().prepare(
                        "select slug from project_alias where project = ?1 order by slug",
                    )?;
                    stmt.query_map([x], |r| r.get(0))?
                        .collect::<Result<_, _>>()?
                };
                for slug in slugs {
                    entity::set_alias(tx, &slug, n)?;
                }
                let moved_to = entity::by_n(tx.sql(), n)?.map_or(Value::Null, |e| json!(e.id));
                entity::update(
                    tx,
                    *x,
                    None,
                    Changes {
                        data_patch: Some(json!({ "moved_to": moved_to })),
                        ..Changes::default()
                    },
                )?;
                entity::retire(tx, *x)?;
            }
            n
        }
        None => match live
            .iter()
            .find(|(_, r, p)| r.is_none() && p.as_deref() == path)
        {
            Some((n, _, _)) => *n,
            None => create(tx, &root.id, root)?,
        },
    };
    let holder: Option<i64> = tx
        .sql()
        .query_row(
            "select project from project_alias where slug = ?1",
            [&root.slug],
            |r| r.get(0),
        )
        .map(Some)
        .or_else(|e| match e {
            urdr::SqliteError::QueryReturnedNoRows => Ok(None),
            e => Err(e),
        })?;
    if holder.is_none() {
        entity::set_alias(tx, &root.slug, n)?;
    }
    Ok(n)
}

/// Folders resolved to projects outside any write transaction (the hub fills it when a session starts; Task 11's
/// migration fills it at its step 0), so [`crate::scope::Caller::from_identity`] runs no git. A folder resolved but
/// not yet registered has no `n`, and a caller there has no project until [`ProjectCache::set_registered`]. Keyed by
/// the folder exactly as given (the session's `home`); bounded by the folders sessions start in, [`Self::forget`]
/// drops one.
#[derive(Debug, Default)]
pub struct ProjectCache {
    dirs: HashMap<PathBuf, Option<(ProjectRef, Option<i64>)>>,
}

impl ProjectCache {
    /// Resolve DIR now ([`resolve`]: blocking, runs git) and keep the answer; a known `n` is kept while the
    /// resolved id is unchanged.
    pub fn fill(&mut self, dir: &Path) -> Option<&ProjectRef> {
        let resolved = resolve(dir);
        let n = match (self.dirs.get(dir), &resolved) {
            (Some(Some((old, n))), Some(new)) if old.id == new.id => *n,
            _ => None,
        };
        self.insert(dir.to_path_buf(), resolved);
        if let Some(n) = n {
            self.set_n(dir, n);
        }
        self.get(dir)
    }

    /// Keep PROJECT (an answer of [`resolve`], or `None`: no project) for DIR, unregistered.
    pub fn insert(&mut self, dir: PathBuf, project: Option<ProjectRef>) {
        self.dirs.insert(dir, project.map(|p| (p, None)));
    }

    /// DIR's project as resolved, if DIR was resolved and is in one.
    pub fn get(&self, dir: &Path) -> Option<&ProjectRef> {
        self.dirs.get(dir)?.as_ref().map(|(p, _)| p)
    }

    /// The registered entity `n` of DIR's project.
    pub fn project_n(&self, dir: &Path) -> Option<i64> {
        self.dirs.get(dir)?.as_ref()?.1
    }

    /// The resolved projects not registered yet (one per id), for one write of [`register`]s.
    pub fn unregistered(&self) -> Vec<ProjectRef> {
        let mut out: Vec<ProjectRef> = Vec::new();
        for (p, n) in self.dirs.values().flatten() {
            if n.is_none() && !out.iter().any(|o| o.id == p.id) {
                out.push(p.clone());
            }
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }

    /// [`register`] answered N for the project resolved as ID: every folder resolved to it gets it.
    pub fn set_registered(&mut self, id: &str, n: i64) {
        for (p, slot) in self.dirs.values_mut().flatten() {
            if p.id == id {
                *slot = Some(n);
            }
        }
    }

    fn set_n(&mut self, dir: &Path, n: i64) {
        if let Some(Some((_, slot))) = self.dirs.get_mut(dir) {
            *slot = Some(n);
        }
    }

    /// Forget DIR.
    pub fn forget(&mut self, dir: &Path) {
        self.dirs.remove(dir);
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::scope::testkit;
    use std::process::Command;
    use urdr::graph::{Class, TxMeta};

    /// A git command for the fixtures: no global or system config, fixed names, dates from DATE (unix seconds).
    fn sh(dir: &Path, args: &[&str], date: Option<i64>) {
        let mut cmd = Command::new("git");
        cmd.args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args([
                "-c",
                "init.defaultBranch=main",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(d) = date {
            cmd.env("GIT_COMMITTER_DATE", format!("@{d} +0000"))
                .env("GIT_AUTHOR_DATE", format!("@{d} +0000"));
        }
        let status = cmd.status().expect("git runs");
        assert!(status.success(), "git {args:?} in {}", dir.display());
    }

    /// A repository NAME under BASE with one commit at DATE.
    pub(crate) fn repo(base: &Path, name: &str, date: Option<i64>) -> PathBuf {
        let dir = base.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        sh(&dir, &["init", "-q"], None);
        if let Some(d) = date {
            sh(
                &dir,
                &["commit", "-q", "--allow-empty", "-m", "first"],
                Some(d),
            );
        }
        dir
    }

    fn hub() -> TxMeta {
        TxMeta::new("hub", Class::System, "test")
    }

    fn aliases(conn: &urdr::Connection) -> Vec<(String, i64)> {
        let mut stmt = conn
            .prepare("select slug, project from project_alias order by slug")
            .unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn root_commit_is_stable_across_a_folder_rename() {
        let base = tempfile::tempdir().unwrap();
        let alpha = repo(base.path(), "alpha", Some(1_600_000_000));
        let before = resolve(&alpha).expect("a repository");
        assert!(before.id.starts_with("project:") && before.id.len() == "project:".len() + 12);
        assert_eq!(before.slug, "alpha");
        let beta = base.path().join("beta");
        std::fs::rename(&alpha, &beta).unwrap();
        let after = resolve(&beta).expect("a repository");
        assert_eq!(after.id, before.id);
        assert_eq!(after.slug, "beta");

        let (_d, _p, mut conn) = testkit::db();
        let n1 = testkit::write(&mut conn, hub(), |tx| register(tx, &before)).unwrap();
        let n2 = testkit::write(&mut conn, hub(), |tx| register(tx, &after)).unwrap();
        assert_eq!(n1, n2);
        assert_eq!(
            aliases(&conn),
            [("alpha".to_string(), n1), ("beta".to_string(), n1)]
        );
        let e = entity::by_n(&conn, n1).unwrap().unwrap();
        assert_eq!(e.id, before.id);
        assert_eq!(e.project, Some(n1));
        assert_eq!(e.data["root"], json!(before.root_commit));
    }

    #[test]
    fn several_roots_pick_the_earliest() {
        let base = tempfile::tempdir().unwrap();
        let dir = repo(base.path(), "many", Some(1_700_000_000));
        let first = resolve(&dir).unwrap();
        let (_d, _p, mut conn) = testkit::db();
        let n = testkit::write(&mut conn, hub(), |tx| register(tx, &first)).unwrap();
        // An unrelated history with an earlier root, merged in.
        sh(&dir, &["checkout", "-q", "--orphan", "old"], None);
        sh(
            &dir,
            &["commit", "-q", "--allow-empty", "-m", "old"],
            Some(1_500_000_000),
        );
        sh(&dir, &["checkout", "-q", "main"], None);
        sh(
            &dir,
            &[
                "merge",
                "-q",
                "--allow-unrelated-histories",
                "-m",
                "merge",
                "old",
            ],
            Some(1_700_000_100),
        );
        let merged = resolve(&dir).unwrap();
        assert_eq!(merged.roots.len(), 2);
        assert_ne!(
            merged.id, first.id,
            "the earliest root names a fresh registration"
        );
        assert_eq!(merged.roots[1], first.root_commit.clone().unwrap());
        // The stored project never changes.
        let again = testkit::write(&mut conn, hub(), |tx| register(tx, &merged)).unwrap();
        assert_eq!(again, n);
        // A fresh store takes the earliest root.
        let (_d2, _p2, mut fresh) = testkit::db();
        let m = testkit::write(&mut fresh, hub(), |tx| register(tx, &merged)).unwrap();
        assert_eq!(entity::by_n(&fresh, m).unwrap().unwrap().id, merged.id);
    }

    #[test]
    fn worktrees_share_a_project() {
        let base = tempfile::tempdir().unwrap();
        let main = repo(base.path(), "main-repo", Some(1_600_000_000));
        sh(
            &main,
            &["worktree", "add", "-q", "-b", "side", "../side-wt"],
            None,
        );
        let wt = base.path().join("side-wt");
        let a = resolve(&main).unwrap();
        let b = resolve(&wt).unwrap();
        assert_eq!(a, b);
        assert_eq!(b.slug, "main-repo");
        // From a folder inside the worktree too.
        std::fs::create_dir(wt.join("sub")).unwrap();
        assert_eq!(resolve(&wt.join("sub")).unwrap().id, a.id);
    }

    #[test]
    fn no_commits_gets_x_then_moves() {
        let base = tempfile::tempdir().unwrap();
        let dir = repo(base.path(), "fresh", None);
        let x = resolve(&dir).unwrap();
        assert!(x.id.starts_with("project:x-") && x.id.len() == "project:x-".len() + 8);
        assert_eq!(x.root_commit, None);
        let (_d, _p, mut conn) = testkit::db();
        let nx = testkit::write(&mut conn, hub(), |tx| register(tx, &x)).unwrap();
        // Resolved again (a new random id): the same folder's project.
        let x2 = resolve(&dir).unwrap();
        assert_eq!(
            testkit::write(&mut conn, hub(), |tx| register(tx, &x2)).unwrap(),
            nx
        );
        sh(
            &dir,
            &["commit", "-q", "--allow-empty", "-m", "first"],
            Some(1_600_000_000),
        );
        let real = resolve(&dir).unwrap();
        assert!(!real.id.starts_with("project:x-"));
        let n = testkit::write(&mut conn, hub(), |tx| register(tx, &real)).unwrap();
        assert_ne!(n, nx);
        assert_eq!(aliases(&conn), [("fresh".to_string(), n)]);
        let old = entity::by_n(&conn, nx).unwrap().unwrap();
        assert!(old.retired_tx.is_some());
        assert_eq!(old.data["moved_to"], json!(real.id));
    }

    #[test]
    fn outside_a_repo_is_none() {
        let base = tempfile::tempdir().unwrap();
        // Unless the temp folder itself lies in a repository (then there is nothing to show here).
        if git(base.path(), &["rev-parse", "--show-toplevel"]).is_none() {
            assert_eq!(resolve(base.path()), None);
        }
        assert_eq!(resolve(&base.path().join("missing")), None);
        let mut cache = ProjectCache::default();
        assert_eq!(cache.fill(&base.path().join("missing")), None);
        assert_eq!(cache.project_n(&base.path().join("missing")), None);
    }

    #[test]
    fn the_cache_hands_out_registered_projects_only() {
        let base = tempfile::tempdir().unwrap();
        let dir = repo(base.path(), "cached", Some(1_600_000_000));
        let mut cache = ProjectCache::default();
        let p = cache.fill(&dir).cloned().unwrap();
        assert_eq!(cache.project_n(&dir), None);
        assert_eq!(cache.unregistered(), std::slice::from_ref(&p));
        cache.set_registered(&p.id, 7);
        assert_eq!(cache.project_n(&dir), Some(7));
        assert!(cache.unregistered().is_empty());
        cache.fill(&dir);
        assert_eq!(cache.project_n(&dir), Some(7), "the same id keeps its n");
        cache.forget(&dir);
        assert_eq!(cache.get(&dir), None);
    }
}
