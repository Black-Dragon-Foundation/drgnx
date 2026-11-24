//! The project registry (docs/guide/runners.md, "Projects"): the projects the user registered with the hub, and which
//! clone on this machine belongs to which. Not [`super::registry`], which holds the runners.
//!
//! - A project is bound to its repository's **root set** (every root commit, sorted: a repo may have several) and its
//!   origin URL, recorded at [`Projects::add`]; its id is the hub's, never a folder name or a pack's `:project`.
//! - A job's project comes only from [`Projects::resolve`]: its clone's git common dir (which every worktree of the
//!   clone shares) is looked up in `project_clones` and the mapping re-checked by one object lookup (`git cat-file -e`
//!   of the recorded root), so a clone deleted and replaced by another repo at the same path is resolved again. Only a
//!   clone not seen yet (or a failed re-check) walks to its roots, once; the answer is kept.
//! - A clone maps to a project when the origins are equal and the root sets share a root: a fork with another origin
//!   is another project. Two matches are refused as ambiguous, a shallow clone (its graft point looks like a root) with
//!   its fix, `git fetch --unshallow`.
//!
//! Git runs through sleipnir's hardened git and only reads. The state is kept in `runtime.db` (`projects`,
//! `project_clones`), written in order on a task of its own; none: in memory only (unit tests).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use forseti::ProjectId;
use serde::{Deserialize, Serialize};
use sleipnir::sync::git::Git;
use stund::Instant;
use tokio::sync::mpsc;

/// A registered project.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Project {
    pub id: ProjectId,
    /// The display name (unique): what the pack's `:project` must say.
    pub name: String,
    /// `git remote get-url origin` at registration; empty when the repo has no origin.
    pub origin: String,
    /// Every root commit, sorted.
    pub roots: Vec<String>,
}

/// What a tree resolves to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolved {
    Known(ProjectId),
    NotRegistered,
    Shallow,
    Ambiguous(Vec<ProjectId>),
}

impl Resolved {
    /// The job's project id (empty unless known) and, when it is not known, why: the words a job that may not leave
    /// this machine for it shows ([`forseti::WaitReason::NotRegistered`]).
    pub fn for_job(
        &self,
        tree: &Path,
        names: &dyn Fn(&ProjectId) -> String,
    ) -> (ProjectId, Option<String>) {
        match self {
            Resolved::Known(id) => (id.clone(), None),
            Resolved::NotRegistered => (
                ProjectId::default(),
                Some(format!(
                    "its tree is in no registered project: `drgnx jobs project add {}` registers it",
                    tree.display()
                )),
            ),
            Resolved::Shallow => (
                ProjectId::default(),
                Some(
                    "its clone is shallow (a graft point looks like a root): `git fetch --unshallow` there, and it maps"
                        .into(),
                ),
            ),
            Resolved::Ambiguous(ids) => (
                ProjectId::default(),
                Some(format!(
                    "its clone matches the projects {}: remove the one it is not",
                    ids.iter().map(names).collect::<Vec<_>>().join(" and ")
                )),
            ),
        }
    }
}

/// A write to `runtime.db`, in order.
type DbOp = Box<dyn FnOnce(&urdr::Connection) -> Result<(), urdr::Error> + Send>;

/// How long a clone that matched no project (or two) is answered from memory before it is walked again; a
/// registration or removal forgets every such answer at once.
const MISS_KEPT: Duration = Duration::from_secs(300);

/// The registry.
#[derive(Default)]
pub struct Projects {
    projects: BTreeMap<ProjectId, Project>,
    /// Each clone's git common dir: its project and the root its mapping is re-checked by.
    clones: BTreeMap<PathBuf, (ProjectId, String)>,
    /// Clones that matched no project, or two, and when.
    misses: BTreeMap<PathBuf, (Resolved, Instant)>,
    db: Option<mpsc::UnboundedSender<DbOp>>,
    /// The root walks so far (a test hook: a second submit of a clone walks nothing).
    walks: u64,
}

impl Projects {
    /// The registry as `runtime.db` keeps it; none: an empty one in memory.
    pub async fn open(db: Option<urdr::Handle>) -> Projects {
        let mut p = Projects::default();
        let Some(handle) = db else {
            return p;
        };
        let rows = handle
            .read(|c| {
                let mut s = c.prepare("select id, name, origin, roots from projects")?;
                let projects = s
                    .query_map([], |r| {
                        Ok(Project {
                            id: ProjectId(r.get(0)?),
                            name: r.get(1)?,
                            origin: r.get(2)?,
                            roots: r
                                .get::<_, String>(3)?
                                .split(',')
                                .filter(|x| !x.is_empty())
                                .map(String::from)
                                .collect(),
                        })
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                let mut s = c.prepare("select common_dir, project, root from project_clones")?;
                let clones = s
                    .query_map([], |r| {
                        Ok((
                            PathBuf::from(r.get::<_, String>(0)?),
                            ProjectId(r.get(1)?),
                            r.get::<_, String>(2)?,
                        ))
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok((projects, clones))
            })
            .await;
        match rows {
            Ok((projects, clones)) => {
                for x in projects {
                    p.projects.insert(x.id.clone(), x);
                }
                for (dir, id, root) in clones {
                    if p.projects.contains_key(&id) {
                        p.clones.insert(dir, (id, root));
                    }
                }
            }
            Err(e) => tracing::warn!("runners: the project registry in runtime.db: {e}"),
        }
        let (tx, mut rx) = mpsc::unbounded_channel::<DbOp>();
        crate::clock::spawn("runners:projects-db", async move {
            while let Some(op) = rx.recv().await {
                if let Err(e) = handle.write(op).await {
                    tracing::warn!("runners: the project registry's runtime.db write: {e}");
                }
            }
        });
        p.db = Some(tx);
        p
    }

    fn persist(&self, op: DbOp) {
        if let Some(db) = &self.db {
            crate::soft::done(db.send(op), "project db send");
        }
    }

    /// Resolves when every write made so far has reached `runtime.db` (the writes run in order on one task).
    pub async fn flushed(&self) {
        let Some(db) = &self.db else {
            return;
        };
        let (tx, rx) = tokio::sync::oneshot::channel();
        let op: DbOp = Box::new(move |_| {
            saman::delivered(tx.send(()), "project db flush");
            Ok(())
        });
        if db.send(op).is_ok() {
            crate::soft::done(rx.await, "project db flush");
        }
    }

    /// Every registered project, by id.
    pub fn list(&self) -> Vec<Project> {
        self.projects.values().cloned().collect()
    }

    /// Project ID, if registered.
    pub fn get(&self, id: &ProjectId) -> Option<&Project> {
        self.projects.get(id)
    }

    /// The root walks so far.
    pub fn walks(&self) -> u64 {
        self.walks
    }

    /// The repository REPO registered, under NAME (default: its top folder's name). Refused: not a git repository, a
    /// shallow clone, no commit, a name taken, or a project with the same origin whose root set shares a root (the
    /// same repository registered twice). REPO's clone maps to it at once.
    pub fn add(&mut self, repo: &Path, name: Option<&str>) -> villa::Result<Project> {
        let (top, git) = open_git(repo)?;
        if shallow(&git)? {
            return Err(villa::Error::refused(format!(
                "{} is a shallow clone: its graft point would count as a root. Run `git fetch --unshallow` there, then \
                 add it again",
                top.display()
            )));
        }
        let roots = roots(&git)?;
        if roots.is_empty() {
            return Err(villa::Error::invalid(format!(
                "{} has no commit yet",
                top.display()
            )));
        }
        let origin = origin(&git);
        let name = match name {
            Some(n) => n.to_string(),
            None => top
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
        };
        if name.is_empty() || name.len() > 128 || name.chars().any(char::is_control) {
            return Err(villa::Error::invalid(format!(
                "a project's name is 1 to 128 characters, no control characters: {name:?}"
            )));
        }
        if let Some(p) = self.projects.values().find(|p| p.name == name) {
            return Err(villa::Error::conflict(format!(
                "the name {name:?} is project {}'s",
                p.id
            )));
        }
        if let Some(p) = self
            .projects
            .values()
            .find(|p| p.origin == origin && shares_a_root(&p.roots, &roots))
        {
            return Err(villa::Error::conflict(format!(
                "{} is project {:?} ({}) already: the same origin and a shared root commit",
                top.display(),
                p.name,
                p.id
            )));
        }
        let project = Project {
            id: new_id(),
            name,
            origin,
            roots,
        };
        let row = project.clone();
        self.persist(Box::new(move |c| {
            c.execute(
                "insert into projects(id, name, origin, roots) values (?1, ?2, ?3, ?4)",
                (&row.id.0, &row.name, &row.origin, row.roots.join(",")),
            )?;
            Ok(())
        }));
        self.projects.insert(project.id.clone(), project.clone());
        self.misses.clear();
        if let Ok(dir) = common_dir(&git) {
            self.map(dir, &project.id, &project.roots[0]);
        }
        Ok(project)
    }

    /// Project ID removed, with every clone mapped to it.
    pub fn remove(&mut self, id: &ProjectId) -> villa::Result<()> {
        if self.projects.remove(id).is_none() {
            return Err(villa::Error::not_found(format!("no project {id}")));
        }
        self.clones.retain(|_, (p, _)| p != id);
        self.misses.clear();
        let id = id.0.clone();
        self.persist(Box::new(move |c| {
            c.execute("delete from project_clones where project = ?1", [&id])?;
            c.execute("delete from projects where id = ?1", [&id])?;
            Ok(())
        }));
        Ok(())
    }

    /// The project WORKTREE (or a folder inside it) belongs to: by its clone's mapping, re-checked by one object lookup;
    /// a clone not seen yet (or whose re-check failed) walks to its roots once.
    pub fn resolve(&mut self, worktree: &Path) -> Resolved {
        let Ok((_, git)) = open_git(worktree) else {
            return Resolved::NotRegistered;
        };
        let Ok(dir) = common_dir(&git) else {
            return Resolved::NotRegistered;
        };
        if let Some((id, root)) = self.clones.get(&dir).cloned() {
            if self.projects.contains_key(&id) && has_object(&git, &root) {
                return Resolved::Known(id);
            }
            // replaced at the same path (or its project gone): forget it, and walk
            self.clones.remove(&dir);
            let d = dir.to_string_lossy().into_owned();
            self.persist(Box::new(move |c| {
                c.execute("delete from project_clones where common_dir = ?1", [&d])?;
                Ok(())
            }));
        }
        if let Some((r, at)) = self.misses.get(&dir)
            && at.elapsed() < MISS_KEPT
        {
            return r.clone();
        }
        match shallow(&git) {
            Ok(true) => return Resolved::Shallow,
            Ok(false) => {}
            Err(_) => return Resolved::NotRegistered,
        }
        self.walks += 1;
        let Ok(roots) = roots(&git) else {
            return Resolved::NotRegistered;
        };
        let origin = origin(&git);
        let hits: Vec<&Project> = self
            .projects
            .values()
            .filter(|p| p.origin == origin && shares_a_root(&p.roots, &roots))
            .collect();
        let r = match hits.as_slice() {
            [p] => {
                let id = p.id.clone();
                let root = p
                    .roots
                    .iter()
                    .find(|r| roots.contains(r))
                    .cloned()
                    .unwrap_or_default();
                self.map(dir, &id, &root);
                return Resolved::Known(id);
            }
            [] => Resolved::NotRegistered,
            many => Resolved::Ambiguous(many.iter().map(|p| p.id.clone()).collect()),
        };
        self.misses.insert(dir, (r.clone(), Instant::now()));
        r
    }

    /// The pack of project ID's tree names PACK_PROJECT as its `:project`: refused unless it is the registered name. The
    /// pack's name is shown, never looked up.
    pub fn check_pack(&self, id: &ProjectId, pack_project: &str) -> villa::Result<()> {
        let Some(p) = self.projects.get(id) else {
            return Err(villa::Error::not_found(
                "the pack's tree is in no registered project",
            ));
        };
        if p.name == pack_project {
            Ok(())
        } else {
            Err(villa::Error::invalid(format!(
                "the pack says project {pack_project:?}; its tree is registered as {:?}",
                p.name
            )))
        }
    }

    fn map(&mut self, dir: PathBuf, id: &ProjectId, root: &str) {
        self.clones
            .insert(dir.clone(), (id.clone(), root.to_string()));
        let (d, id, root) = (
            dir.to_string_lossy().into_owned(),
            id.0.clone(),
            root.to_string(),
        );
        self.persist(Box::new(move |c| {
            c.execute(
                "insert or replace into project_clones(common_dir, project, root) values (?1, ?2, ?3)",
                (&d, &id, &root),
            )?;
            Ok(())
        }));
    }
}

/// A new project id: `p` and 12 hex digits from the system's random source.
fn new_id() -> ProjectId {
    let mut b = [0u8; 6];
    use std::io::Read;
    if let Err(e) = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)) {
        panic!("runners: no random bytes for a project id: {e}");
    }
    ProjectId(format!(
        "p{}",
        b.iter().map(|x| format!("{x:02x}")).collect::<String>()
    ))
}

fn shares_a_root(a: &[String], b: &[String]) -> bool {
    a.iter().any(|r| b.contains(r))
}

/// The worktree PATH is in (its nearest folder holding `.git`), and its git.
fn open_git(path: &Path) -> villa::Result<(PathBuf, Git)> {
    let top = path
        .ancestors()
        .find(|d| d.join(".git").exists())
        .ok_or_else(|| {
            villa::Error::invalid(format!("{} is in no git repository", path.display()))
        })?;
    let git =
        Git::for_worktree(top).map_err(|e| villa::Error::io(format!("{}: {e}", top.display())))?;
    Ok((top.to_path_buf(), git))
}

/// What git said to ARGS: its stdout, trimmed, when it succeeded. The child runs on a thread of its own
/// (`draugr::run` starts a runtime, which a caller already inside one cannot).
fn run(git: &Git, args: &[&str]) -> villa::Result<(bool, String, String)> {
    let spec = git.cmd(args);
    let what = args[0].to_string();
    let o = saman::spawn_thread("projects-git", move || {
        draugr::run(spec, Duration::from_secs(60))
    })
    .map_err(|e| villa::Error::io(format!("git {what}: {e}")))?
    .join()
    .map_err(|_| villa::Error::internal(format!("git {}: its thread panicked", args[0])))?
    .map_err(|e| villa::Error::io(format!("git {}: {e}", args[0])))?;
    Ok((
        o.status.success(),
        String::from_utf8_lossy(&o.stdout).trim_end().to_string(),
        o.stderr.trim_end().to_string(),
    ))
}

fn out(git: &Git, args: &[&str]) -> villa::Result<String> {
    let (ok, stdout, stderr) = run(git, args)?;
    if ok {
        Ok(stdout)
    } else {
        Err(villa::Error::io(format!("git {}: {stderr}", args[0])))
    }
}

/// The clone's git common dir, absolute and canonical: one per clone, whatever worktree of it asks.
fn common_dir(git: &Git) -> villa::Result<PathBuf> {
    let d = out(
        git,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    std::fs::canonicalize(&d).map_err(|e| villa::Error::io(format!("{d}: {e}")))
}

fn shallow(git: &Git) -> villa::Result<bool> {
    Ok(out(git, &["rev-parse", "--is-shallow-repository"])? == "true")
}

/// Every root commit of every ref, sorted.
fn roots(git: &Git) -> villa::Result<Vec<String>> {
    let mut v: Vec<String> = out(git, &["rev-list", "--max-parents=0", "--all"])?
        .lines()
        .map(String::from)
        .collect();
    v.sort();
    v.dedup();
    Ok(v)
}

fn origin(git: &Git) -> String {
    out(git, &["remote", "get-url", "origin"]).unwrap_or_default()
}

fn has_object(git: &Git, oid: &str) -> bool {
    !oid.is_empty() && run(git, &["cat-file", "-e", oid]).is_ok_and(|(ok, _, _)| ok)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proc::Command;

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.invalid",
                "-c",
                "init.defaultBranch=main",
                "-c",
                "protocol.file.allow=always",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    /// A repo at DIR/NAME with one commit (a file SEED holding SEED, so two repos have two roots) and ORIGIN.
    fn repo(dir: &Path, name: &str, seed: &str, origin: Option<&str>) -> PathBuf {
        let r = dir.join(name);
        std::fs::create_dir_all(&r).unwrap();
        git(&r, &["init", "-q"]);
        crate::fsio::write(r.join(seed), seed).unwrap();
        git(&r, &["add", seed]);
        git(&r, &["commit", "-qm", seed]);
        if let Some(o) = origin {
            git(&r, &["remote", "add", "origin", o]);
        }
        r
    }

    fn id(r: &Resolved) -> ProjectId {
        match r {
            Resolved::Known(id) => id.clone(),
            other => panic!("not known: {other:?}"),
        }
    }

    #[test]
    fn a_repo_cloned_as_drgnx_is_not_drgnx() {
        // [D] a folder named as a registered project, with another history and origin, is no project
        let t = tempfile::tempdir().unwrap();
        let mut p = Projects::default();
        let real = repo(
            t.path(),
            "real",
            "a",
            Some("https://example.invalid/drgnx.git"),
        );
        p.add(&real, Some("drgnx")).unwrap();
        let other = repo(
            &t.path().join("x"),
            "drgnx",
            "b",
            Some("https://example.invalid/other.git"),
        );
        assert_eq!(p.resolve(&other), Resolved::NotRegistered);
        let (pid, why) = p.resolve(&other).for_job(&other, &|i| i.0.clone());
        assert_eq!(pid, ProjectId::default());
        assert!(why.unwrap().contains("drgnx jobs project add"));
    }

    #[test]
    fn two_worktrees_are_one_project() {
        // [D] a linked worktree shares its clone's common dir: one project, one mapping
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", Some("https://example.invalid/r.git"));
        let w = t.path().join("w");
        git(&r, &["worktree", "add", "-q", w.to_str().unwrap()]);
        let mut p = Projects::default();
        let added = p.add(&r, None).unwrap();
        assert_eq!(added.name, "r");
        assert_eq!(id(&p.resolve(&r)), added.id);
        assert_eq!(id(&p.resolve(&w)), added.id);
        // a folder inside a worktree is the worktree's
        std::fs::create_dir_all(w.join("sub")).unwrap();
        assert_eq!(id(&p.resolve(&w.join("sub"))), added.id);
        assert_eq!(p.walks(), 0);
    }

    #[test]
    fn a_packs_project_mismatch_is_refused() {
        // [D] the pack's :project must be the registered name; it is never looked up
        let t = tempfile::tempdir().unwrap();
        let mut p = Projects::default();
        let a = p
            .add(&repo(t.path(), "a", "a", None), Some("hello-c"))
            .unwrap();
        p.add(&repo(t.path(), "b", "b", None), Some("other"))
            .unwrap();
        p.check_pack(&a.id, "hello-c").unwrap();
        let e = p.check_pack(&a.id, "other").unwrap_err();
        let e = e.message();
        assert!(e.contains("\"other\"") && e.contains("\"hello-c\""), "{e}");
        assert!(p.check_pack(&ProjectId::default(), "hello-c").is_err());
    }

    #[test]
    fn a_shallow_clone_is_refused_with_its_card() {
        // [D] a shallow clone's graft point is no root: refused at add, and Shallow (with the fix) at resolve
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", None);
        crate::fsio::write(r.join("a"), "a2").unwrap();
        git(&r, &["commit", "-qam", "two"]);
        let url = format!("file://{}", r.display());
        git(t.path(), &["clone", "-q", "--depth", "1", &url, "s"]);
        let s = t.path().join("s");
        let mut p = Projects::default();
        let e = p.add(&s, None).unwrap_err();
        assert!(e.message().contains("git fetch --unshallow"), "{e}");
        p.add(&r, Some("r")).unwrap();
        assert_eq!(p.resolve(&s), Resolved::Shallow);
        let (_, why) = Resolved::Shallow.for_job(&s, &|i| i.0.clone());
        assert!(why.unwrap().contains("git fetch --unshallow"));
    }

    #[test]
    fn a_repo_with_two_roots_maps() {
        // [D] an unrelated history merged in: two roots; a clone sharing either maps
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", Some("o"));
        let other = repo(t.path(), "other", "b", None);
        git(&r, &["fetch", "-q", other.to_str().unwrap(), "main:side"]);
        git(
            &r,
            &[
                "merge",
                "-q",
                "--allow-unrelated-histories",
                "-m",
                "join",
                "side",
            ],
        );
        let mut p = Projects::default();
        let added = p.add(&r, None).unwrap();
        assert_eq!(added.roots.len(), 2);
        let mut sorted = added.roots.clone();
        sorted.sort();
        assert_eq!(added.roots, sorted);
        // a clone of only the merged-in side, same origin: it shares one root
        let c = t.path().join("c");
        git(t.path(), &["clone", "-q", other.to_str().unwrap(), "c"]);
        git(&c, &["remote", "set-url", "origin", "o"]);
        assert_eq!(id(&p.resolve(&c)), added.id);
    }

    #[test]
    fn a_second_submit_runs_no_root_walk() {
        // [D] a clone not seen yet walks once; every later resolve is the mapping plus one object lookup
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", Some("o"));
        let mut p = Projects::default();
        let added = p.add(&r, None).unwrap();
        git(t.path(), &["clone", "-q", r.to_str().unwrap(), "c"]);
        let c = t.path().join("c");
        git(&c, &["remote", "set-url", "origin", "o"]);
        assert_eq!(id(&p.resolve(&c)), added.id);
        assert_eq!(p.walks(), 1);
        assert_eq!(id(&p.resolve(&c)), added.id);
        assert_eq!(id(&p.resolve(&c)), added.id);
        assert_eq!(p.walks(), 1);
    }

    #[test]
    fn a_clone_replaced_at_the_same_path_is_re_resolved() {
        // [D] the mapping is re-checked by its root: another repo at the same path is not the old project
        let t = tempfile::tempdir().unwrap();
        let mut p = Projects::default();
        let r = repo(t.path(), "r", "a", Some("o"));
        let added = p.add(&r, None).unwrap();
        assert_eq!(id(&p.resolve(&r)), added.id);
        std::fs::remove_dir_all(&r).unwrap();
        let again = repo(t.path(), "r", "b", Some("o"));
        assert_eq!(p.resolve(&again), Resolved::NotRegistered);
    }

    #[test]
    fn a_fork_with_another_origin_is_not_the_upstream() {
        // [D] the same history under another origin is another project (its caches are not the upstream's)
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", Some("https://example.invalid/up.git"));
        let mut p = Projects::default();
        let up = p.add(&r, Some("up")).unwrap();
        git(t.path(), &["clone", "-q", r.to_str().unwrap(), "fork"]);
        let f = t.path().join("fork");
        git(
            &f,
            &[
                "remote",
                "set-url",
                "origin",
                "https://example.invalid/fork.git",
            ],
        );
        assert_eq!(p.resolve(&f), Resolved::NotRegistered);
        let fork = p.add(&f, Some("fork")).unwrap();
        assert_ne!(fork.id, up.id);
        assert_eq!(id(&p.resolve(&f)), fork.id);
        assert_eq!(id(&p.resolve(&r)), up.id);
    }

    #[test]
    fn two_overlapping_registrations_are_refused() {
        // [D] the same repository (same origin, a shared root) twice: refused, whatever the name
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", Some("o"));
        let mut p = Projects::default();
        p.add(&r, Some("one")).unwrap();
        git(t.path(), &["clone", "-q", r.to_str().unwrap(), "c"]);
        let c = t.path().join("c");
        git(&c, &["remote", "set-url", "origin", "o"]);
        let e = p.add(&c, Some("two")).unwrap_err();
        assert!(e.message().contains("already"), "{e}");
        // a name is one project's
        let e = p
            .add(&repo(t.path(), "s", "s", None), Some("one"))
            .unwrap_err();
        assert!(e.message().contains("\"one\""), "{e}");
        assert_eq!(p.list().len(), 1);
    }

    #[test]
    fn a_removed_project_resolves_no_more() {
        // [D] removal forgets the project and its clones
        let t = tempfile::tempdir().unwrap();
        let r = repo(t.path(), "r", "a", None);
        let mut p = Projects::default();
        let a = p.add(&r, None).unwrap();
        p.remove(&a.id).unwrap();
        assert_eq!(p.resolve(&r), Resolved::NotRegistered);
        assert!(p.remove(&a.id).is_err());
    }

    #[test]
    fn the_registry_survives_a_restart() {
        // [D] a file: what add wrote is what the next hub reads
        saman::block_on_current(async move {
            let t = tempfile::tempdir().unwrap();
            let r = repo(t.path(), "r", "a", Some("o"));
            let (_store, h) = crate::runtime_db::open(t.path()).unwrap();
            let mut p = Projects::open(Some(h.clone())).await;
            let a = p.add(&r, Some("name")).unwrap();
            // the writes are queued in order: once flushed, a read sees them
            p.flushed().await;
            drop(p);
            let seen = h
                .read(|c| {
                    Ok(c.query_row("select count(*) from project_clones", [], |r| {
                        r.get::<_, i64>(0)
                    })?)
                })
                .await
                .unwrap();
            assert_eq!(seen, 1);
            let mut p = Projects::open(Some(h)).await;
            assert_eq!(p.list(), vec![a.clone()]);
            assert_eq!(id(&p.resolve(&r)), a.id);
            assert_eq!(p.walks(), 0);
        });
    }
}
