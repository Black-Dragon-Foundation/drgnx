//! `HubGit`, the hub's [`super::RunGit`] (Task 17): worktree and snapshot modes, the merge gate (changed set from
//! `git diff --raw` in the trusted repository, `.github/`, `Makefile*`, `build.rs`, job scripts ask; the lock's
//! protected paths are refused), trial merges in a scratch worktree; git for run folders only inside a sandbox
//! (SB-FR17-1), with the touched-folder ledger (`op` rows in `runtime.db`).
//!
//! The gate never runs git in a task folder (SB-T21-1, SB-T13-1): in snapshot mode the task's bundle is imported
//! into the trusted repository (verified, fsck'd, ref written compare-and-swap) and everything is read there.
//! Every git call has a deadline and none runs on the runner's tick.

use super::clash::FileDiff;
use super::{GitError, GitFuture, RunGit, TaskTree, TreeMode, TrialResult};
use crate::agents::lock::PROTECTED_RO;
use crate::matrix_gate::Gate;
use runstav::methods::matrix::Facts;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;
use tokio::process::Command;

#[cfg(test)]
mod tests;

/// What the gate asks of the runner: the user's acceptance marks and the `code.ci-config` question.
pub trait GatePolicy: Send + Sync {
    /// The paths of TREE's task the user accepted, each with the diff hash it was accepted against
    /// (see [`HubGit::diff_hashes`]).
    fn accepted<'a>(&'a self, tree: &'a TaskTree) -> GitFuture<'a, BTreeMap<String, String>>;
    /// The matrix's answer for a change to CI or build files (Ask under Balanced: one card from FACTS).
    fn ci_config<'a>(&'a self, tree: &'a TaskTree, facts: Facts) -> GitFuture<'a, Gate>;
}

/// One changed path and the hash of its diff (mode, blob ids and status of the raw record).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    pub hash: String,
}

/// What the gate looked at: the branch tip in the trusted repository and what changed since the base.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inspection {
    pub tip: String,
    pub changed: Vec<Change>,
    /// SHA-256 over every path and its hash.
    pub diff_hash: String,
}

/// The result of merging a checked tip.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MergeOutcome {
    Merged,
    Conflict(Vec<PathBuf>),
}

#[derive(Clone)]
struct Checked {
    tip: String,
    cleared: bool,
}

/// The hub's git for plan runs.
pub struct HubGit {
    root: PathBuf,
    mode: TreeMode,
    policy: Box<dyn GatePolicy>,
    db: Option<urdr::Handle>,
    deadline: Duration,
    env: Vec<(String, String)>,
    checked: Mutex<HashMap<String, Checked>>,
}

fn err(what: impl Into<String>, stderr: impl Into<String>) -> GitError {
    GitError {
        what: what.into(),
        stderr: stderr.into(),
    }
}

fn sha(s: &str) -> String {
    Sha256::digest(s.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn name_ok(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with(['-', '.'])
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | ':' | '+'))
}

fn is_protected(p: &str) -> bool {
    PROTECTED_RO
        .iter()
        .any(|q| p == *q || p.strip_prefix(q).is_some_and(|r| r.starts_with('/')))
}

fn is_ci_or_build(p: &str) -> bool {
    let base = p.rsplit('/').next().unwrap_or(p);
    p.starts_with(".github/")
        || base.starts_with("Makefile")
        || base == "build.rs"
        || base.ends_with(".sh")
}

impl HubGit {
    /// TREES is where task trees and run stores live (`<root>/<run>/<task>`, `<root>/<run>.git`).
    pub fn new(
        root: PathBuf,
        mode: TreeMode,
        policy: Box<dyn GatePolicy>,
        db: Option<urdr::Handle>,
    ) -> Self {
        HubGit {
            root,
            mode,
            policy,
            db,
            deadline: Duration::from_secs(120),
            env: Vec::new(),
            checked: Mutex::new(HashMap::new()),
        }
    }

    /// Extra environment for every git process (tests point HOME at a temp folder).
    pub fn with_env(mut self, env: Vec<(String, String)>) -> Self {
        self.env = env;
        self
    }

    pub fn with_deadline(mut self, d: Duration) -> Self {
        self.deadline = d;
        self
    }

    async fn git_in(&self, dir: &Path, args: &[&str]) -> Result<String, GitError> {
        self.run(Some(dir), args).await
    }

    async fn run(&self, dir: Option<&Path>, args: &[&str]) -> Result<String, GitError> {
        let what = format!("git {}", args.join(" "));
        let mut c = Command::new("git");
        c.args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("LC_ALL", "C")
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true);
        for (k, v) in &self.env {
            c.env(k, v);
        }
        if let Some(d) = dir {
            c.current_dir(d);
        }
        let out = tokio::time::timeout(self.deadline, c.output())
            .await
            .map_err(|_| err(what.clone(), "past its deadline"))?
            .map_err(|e| err(what.clone(), e.to_string()))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(err(
                what,
                String::from_utf8_lossy(&out.stderr).trim().to_owned(),
            ))
        }
    }

    // ---- the touched-folder ledger ----

    /// Record that a sandboxed agent worked in FOLDER: plain git never runs there again (sticky, across restarts).
    pub async fn touch(&self, folder: &Path) -> Result<(), GitError> {
        let Some(db) = &self.db else { return Ok(()) };
        let f = folder.to_string_lossy().into_owned();
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        db.write(move |c| {
            c.execute(
                "insert or ignore into op(folder, kind, at) values (?1, 'touched', ?2)",
                (f, at),
            )?;
            Ok(())
        })
        .await
        .map_err(|e| err("touch", e.to_string()))
    }

    pub async fn is_touched(&self, folder: &Path) -> bool {
        let Some(db) = &self.db else { return false };
        let f = folder.to_string_lossy().into_owned();
        db.read(move |c| {
            Ok(c.query_row(
                "select count(*) from op where folder = ?1 and kind = 'touched'",
                [f],
                |r| r.get::<_, i64>(0),
            )? > 0)
        })
        .await
        // a ledger that cannot be read: refuse rather than run plain git
        .unwrap_or(true)
    }

    /// Git in a run folder: plain git is refused where a sandboxed agent worked; SANDBOXED says the call itself
    /// runs inside the sandbox.
    pub async fn folder_git(
        &self,
        folder: &Path,
        args: &[&str],
        sandboxed: bool,
    ) -> Result<String, GitError> {
        if !sandboxed && self.is_touched(folder).await {
            return Err(err(
                format!("git {}", args.join(" ")),
                format!(
                    "{} was touched by a sandboxed agent: git runs there only inside the sandbox",
                    folder.display()
                ),
            ));
        }
        self.git_in(folder, args).await
    }

    // ---- snapshot bundles ----

    /// Where a snapshot task's bundle is.
    pub fn bundle_path(tree: &TaskTree) -> PathBuf {
        let name = tree
            .path
            .file_name()
            .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        tree.path.with_file_name(format!("{name}.bundle"))
    }

    /// Write TREE's bundle from its folder (a folder git call: SANDBOXED as for [`Self::folder_git`]).
    pub async fn write_bundle(
        &self,
        tree: &TaskTree,
        sandboxed: bool,
    ) -> Result<PathBuf, GitError> {
        let out = Self::bundle_path(tree);
        let o = out.to_string_lossy().into_owned();
        self.folder_git(
            &tree.path,
            &[
                "bundle",
                "create",
                "-q",
                &o,
                &format!("refs/heads/{}", tree.branch),
            ],
            sandboxed,
        )
        .await?;
        Ok(out)
    }

    /// Bring TREE's bundle into REPO: prerequisites verified, objects fsck'd on the way in, the branch written
    /// compare-and-swap (it must be absent, or at EXPECTED_OLD) and a descendant of the task's base.
    pub async fn import_bundle(
        &self,
        repo: &Path,
        tree: &TaskTree,
        expected_old: Option<&str>,
    ) -> Result<String, GitError> {
        let bundle = Self::bundle_path(tree);
        let b = bundle.to_string_lossy().into_owned();
        self.git_in(repo, &["bundle", "verify", "-q", &b]).await?;
        let incoming = format!("refs/drgnx/incoming/{}", tree.branch);
        let spec = format!("+refs/heads/{}:{incoming}", tree.branch);
        self.git_in(
            repo,
            &[
                "-c",
                "fetch.fsckObjects=true",
                "-c",
                "transfer.fsckObjects=true",
                "fetch",
                "-q",
                "--no-tags",
                &b,
                &spec,
            ],
        )
        .await?;
        let tip = self
            .git_in(repo, &["rev-parse", "--verify", &incoming])
            .await?
            .trim()
            .to_owned();
        let result = async {
            self.git_in(repo, &["merge-base", "--is-ancestor", &tree.base, &tip])
                .await
                .map_err(|_| {
                    err(
                        "import",
                        "the bundle's branch does not descend from the task's base",
                    )
                })?;
            let branch_ref = format!("refs/heads/{}", tree.branch);
            self.git_in(
                repo,
                &["update-ref", &branch_ref, &tip, expected_old.unwrap_or("")],
            )
            .await
        }
        .await;
        let _ = self.git_in(repo, &["update-ref", "-d", &incoming]).await;
        result.map(|_| tip)
    }

    // ---- the gate ----

    /// The changed set of TREE's branch since its base, read in the trusted REPO (a snapshot's bundle is imported
    /// first), with the hash of each path's diff.
    pub async fn inspect(&self, repo: &Path, tree: &TaskTree) -> Result<Inspection, GitError> {
        if tree.mode == TreeMode::Snapshot {
            let branch_ref = format!("refs/heads/{}", tree.branch);
            let old = self
                .git_in(repo, &["rev-parse", "--verify", "-q", &branch_ref])
                .await
                .ok()
                .map(|s| s.trim().to_owned());
            self.import_bundle(repo, tree, old.as_deref()).await?;
        }
        let branch_ref = format!("refs/heads/{}", tree.branch);
        let tip = self
            .git_in(repo, &["rev-parse", "--verify", &branch_ref])
            .await?
            .trim()
            .to_owned();
        let raw = self
            .git_in(
                repo,
                &[
                    "diff",
                    "--raw",
                    "-z",
                    "--no-renames",
                    "--no-abbrev",
                    &tree.base,
                    &tip,
                ],
            )
            .await?;
        let mut changed = Vec::new();
        let mut it = raw.split('\0');
        while let (Some(meta), Some(path)) = (it.next(), it.next()) {
            if meta.is_empty() {
                break;
            }
            changed.push(Change {
                path: path.to_owned(),
                hash: sha(&format!("{meta}\t{path}")),
            });
        }
        changed.sort_by(|a, b| a.path.cmp(&b.path));
        let all: String = changed
            .iter()
            .map(|c| format!("{}\0{}\n", c.path, c.hash))
            .collect();
        Ok(Inspection {
            tip,
            changed,
            diff_hash: sha(&all),
        })
    }

    /// Path → diff hash now: what an acceptance mark must carry to count.
    pub async fn diff_hashes(
        &self,
        repo: &Path,
        tree: &TaskTree,
    ) -> Result<BTreeMap<String, String>, GitError> {
        Ok(self
            .inspect(repo, tree)
            .await?
            .changed
            .into_iter()
            .map(|c| (c.path, c.hash))
            .collect())
    }

    /// The changed paths with the hash of each diff and the lines it touches (against the task's base): what the
    /// clash rules read.
    pub async fn diff_files(
        &self,
        repo: &Path,
        tree: &TaskTree,
    ) -> Result<BTreeMap<String, FileDiff>, GitError> {
        let ins = self.inspect(repo, tree).await?;
        let text = self
            .git_in(
                repo,
                &[
                    "diff",
                    "-U0",
                    "--no-renames",
                    "--no-color",
                    "--no-ext-diff",
                    &tree.base,
                    &ins.tip,
                ],
            )
            .await?;
        let mut ranges = parse_ranges(&text);
        Ok(ins
            .changed
            .into_iter()
            .map(|c| {
                let r = ranges.remove(&c.path).unwrap_or_default();
                (
                    c.path,
                    FileDiff {
                        hash: c.hash,
                        ranges: r,
                    },
                )
            })
            .collect())
    }

    /// The gate's answer.  Protected paths are refused; a path not accepted against its current diff hash waits
    /// (Never, with the count); CI and build files ask; otherwise Allow, and the tip checked is remembered.
    async fn gate(&self, repo: &Path, tree: &TaskTree) -> Result<Gate, GitError> {
        let ins = self.inspect(repo, tree).await?;
        if ins.changed.is_empty() {
            return Ok(Gate::Never("the task changed nothing".into()));
        }
        let protected: Vec<&str> = ins
            .changed
            .iter()
            .map(|c| c.path.as_str())
            .filter(|p| is_protected(p))
            .collect();
        if !protected.is_empty() {
            return Ok(Gate::Never(format!(
                "protected configuration changed: {} (these files never merge: the agent's configuration and the files the \
                 user's tools run; remove them from the branch)",
                protected.join(", ")
            )));
        }
        let marks = self.policy.accepted(tree).await?;
        let accepted = ins
            .changed
            .iter()
            .filter(|c| marks.get(&c.path) == Some(&c.hash))
            .count();
        if accepted < ins.changed.len() {
            return Ok(Gate::Never(format!(
                "{accepted} of {} files accepted against the current diff",
                ins.changed.len()
            )));
        }
        self.checked.lock().unwrap().insert(
            tree.branch.clone(),
            Checked {
                tip: ins.tip.clone(),
                cleared: false,
            },
        );
        let ci: Vec<String> = ins
            .changed
            .iter()
            .filter(|c| is_ci_or_build(&c.path))
            .map(|c| format!("{}/{}", repo.display(), c.path))
            .take(64)
            .collect();
        let verdict = if ci.is_empty() {
            Gate::Allow
        } else {
            let facts: Facts = serde_json::from_value(serde_json::json!({
                "paths": ci, "diff_hash": ins.diff_hash,
            }))
            .map_err(|e| err("facts", e.to_string()))?;
            self.policy.ci_config(tree, facts).await?
        };
        if verdict == Gate::Allow {
            self.clear(&tree.branch);
        }
        Ok(verdict)
    }

    /// The card for BRANCH's CI/build change was answered yes: its checked tip may merge.
    pub fn clear(&self, branch: &str) {
        if let Some(c) = self.checked.lock().unwrap().get_mut(branch) {
            c.cleared = true;
        }
    }

    /// Merge exactly the tip the gate checked into the tree at JOB_TREE (`merge --no-ff`).  A branch that moved
    /// since the check, or one the gate did not clear, is refused; a conflict is aborted and listed.
    pub async fn merge(&self, job_tree: &Path, tree: &TaskTree) -> Result<MergeOutcome, GitError> {
        let branch_ref = format!("refs/heads/{}", tree.branch);
        let now = self
            .git_in(job_tree, &["rev-parse", "--verify", &branch_ref])
            .await?
            .trim()
            .to_owned();
        let checked = self.checked.lock().unwrap().get(&tree.branch).cloned();
        match checked {
            Some(c) if c.cleared && c.tip == now => {}
            Some(c) if c.tip != now => {
                return Err(err("merge", "the branch's tip moved after the check"));
            }
            _ => return Err(err("merge", "the gate has not cleared this task")),
        }
        let msg = format!("Merge {}", tree.branch);
        let r = self
            .git_in(
                job_tree,
                &[
                    "-c",
                    "user.name=drgnx",
                    "-c",
                    "user.email=drgnx@localhost",
                    "merge",
                    "--no-ff",
                    "-q",
                    "-m",
                    &msg,
                    &now,
                ],
            )
            .await;
        match r {
            Ok(_) => {
                self.checked.lock().unwrap().remove(&tree.branch);
                Ok(MergeOutcome::Merged)
            }
            Err(e) => {
                let files = self
                    .git_in(job_tree, &["diff", "--name-only", "--diff-filter=U"])
                    .await
                    .unwrap_or_default();
                let files: Vec<PathBuf> = files.lines().map(PathBuf::from).collect();
                if self.git_in(job_tree, &["merge", "--abort"]).await.is_err() {
                    let _ = self.git_in(job_tree, &["reset", "--merge"]).await;
                }
                if files.is_empty() {
                    Err(e)
                } else {
                    Ok(MergeOutcome::Conflict(files))
                }
            }
        }
    }

    // ---- trees ----

    async fn make_tree(
        &self,
        repo: &Path,
        run: &str,
        task: &str,
        base: &str,
    ) -> Result<TaskTree, GitError> {
        if !name_ok(run) || !name_ok(task) {
            return Err(err(
                "task_worktree",
                "a run or task name is not a plain name",
            ));
        }
        let branch = format!("job/{run}-{task}");
        let path = self.root.join(run).join(task);
        let tree = TaskTree {
            path: path.clone(),
            branch: branch.clone(),
            base: base.to_owned(),
            mode: self.mode,
        };
        // a worktree's branch is in the trusted repository; a snapshot's is in the tree's own `.git`, which the
        // agent writes: its ref files are looked at, no git runs there
        let have = match self.mode {
            TreeMode::Worktree => self
                .git_in(
                    repo,
                    &[
                        "rev-parse",
                        "--verify",
                        "-q",
                        &format!("refs/heads/{branch}"),
                    ],
                )
                .await
                .is_ok(),
            TreeMode::Snapshot => {
                let dot = path.join(".git");
                dot.join("refs/heads").join(&branch).is_file()
                    || std::fs::read_to_string(dot.join("packed-refs")).is_ok_and(|t| {
                        t.lines()
                            .any(|l| l.ends_with(&format!(" refs/heads/{branch}")))
                    })
            }
        };
        if have && path.exists() {
            return Ok(tree);
        }
        std::fs::create_dir_all(path.parent().unwrap_or(&self.root))
            .map_err(|e| err("task_worktree", e.to_string()))?;
        let p = path.to_string_lossy().into_owned();
        match self.mode {
            TreeMode::Worktree => {
                self.git_in(repo, &["worktree", "add", "-q", "-b", &branch, &p, base])
                    .await?;
            }
            TreeMode::Snapshot => {
                let store = self.root.join(format!("{run}.git"));
                let s = store.to_string_lossy().into_owned();
                let r = repo.to_string_lossy().into_owned();
                if store.exists() {
                    self.git_in(
                        &store,
                        &["fetch", "-q", "--no-tags", &r, "+refs/heads/*:refs/heads/*"],
                    )
                    .await?;
                } else {
                    self.run(None, &["clone", "-q", "--bare", "--no-hardlinks", &r, &s])
                        .await?;
                }
                self.git_in(&store, &["cat-file", "-e", &format!("{base}^{{commit}}")])
                    .await?;
                std::fs::create_dir_all(&path).map_err(|e| err("task_worktree", e.to_string()))?;
                let dot_git = path.join(".git").to_string_lossy().into_owned();
                reflink_copy(&s, &dot_git).await?;
                let g = format!("--git-dir={dot_git}");
                self.run(None, &[&g, "config", "core.bare", "false"])
                    .await?;
                self.run(
                    None,
                    &[&g, "update-ref", &format!("refs/heads/{branch}"), base],
                )
                .await?;
                self.run(
                    None,
                    &[&g, "symbolic-ref", "HEAD", &format!("refs/heads/{branch}")],
                )
                .await?;
                self.git_in(&path, &["reset", "-q", "--hard"]).await?;
            }
        }
        Ok(tree)
    }

    async fn trial(&self, repo: &Path, branches: &[String]) -> Result<TrialResult, GitError> {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::fs::create_dir_all(&self.root).map_err(|e| err("trial_merge", e.to_string()))?;
        let scratch = self.root.join(format!(".trial-{}-{n}", std::process::id()));
        let s = scratch.to_string_lossy().into_owned();
        self.git_in(repo, &["worktree", "add", "-q", "--detach", &s, "HEAD"])
            .await?;
        let result = async {
            let mut conflicts: Vec<PathBuf> = Vec::new();
            for b in branches {
                let r = self
                    .git_in(
                        &scratch,
                        &[
                            "-c",
                            "core.hooksPath=/dev/null",
                            "-c",
                            "user.name=drgnx",
                            "-c",
                            "user.email=drgnx@localhost",
                            "merge",
                            "--no-ff",
                            "-q",
                            "-m",
                            "trial",
                            b,
                        ],
                    )
                    .await;
                if let Err(e) = r {
                    let files = self
                        .git_in(&scratch, &["diff", "--name-only", "--diff-filter=U"])
                        .await
                        .unwrap_or_default();
                    let files: Vec<PathBuf> = files.lines().map(PathBuf::from).collect();
                    if files.is_empty() {
                        // not a conflict: the branch is unknown or git failed
                        return Err(e);
                    }
                    conflicts.extend(files);
                    let _ = self.git_in(&scratch, &["merge", "--abort"]).await;
                }
            }
            conflicts.sort();
            conflicts.dedup();
            Ok(TrialResult {
                clean: conflicts.is_empty(),
                conflicts,
            })
        }
        .await;
        let _ = self
            .git_in(repo, &["worktree", "remove", "--force", &s])
            .await;
        let _ = std::fs::remove_dir_all(&scratch);
        result
    }
}

/// Copy a bare store to a task's `.git`, sharing blocks where the filesystem can (APFS, btrfs, XFS).
async fn reflink_copy(from: &str, to: &str) -> Result<(), GitError> {
    for flags in [["-a", "--reflink=auto"], ["-a", "-c"], ["-a", "-a"]] {
        let _ = std::fs::remove_dir_all(to);
        let ok = Command::new("cp")
            .args(flags)
            .arg(from)
            .arg(to)
            .stderr(std::process::Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success());
        if ok {
            return Ok(());
        }
    }
    Err(err(
        "cp",
        "cannot copy the run's store into the task folder",
    ))
}

impl RunGit for HubGit {
    fn task_worktree<'a>(
        &'a self,
        repo: &'a Path,
        run: &'a str,
        task: &'a str,
        base: &'a str,
    ) -> GitFuture<'a, TaskTree> {
        Box::pin(self.make_tree(repo, run, task, base))
    }

    fn merge_gate<'a>(&'a self, repo: &'a Path, tree: &'a TaskTree) -> GitFuture<'a, Gate> {
        Box::pin(self.gate(repo, tree))
    }

    fn trial_merge<'a>(
        &'a self,
        repo: &'a Path,
        branches: &'a [String],
    ) -> GitFuture<'a, TrialResult> {
        Box::pin(self.trial(repo, branches))
    }

    fn diffs<'a>(
        &'a self,
        repo: &'a Path,
        tree: &'a TaskTree,
    ) -> GitFuture<'a, BTreeMap<String, FileDiff>> {
        Box::pin(self.diff_files(repo, tree))
    }

    fn touched<'a>(&'a self, folder: &'a Path) -> GitFuture<'a, ()> {
        Box::pin(self.touch(folder))
    }

    fn prepare<'a>(&'a self, tree: &'a TaskTree) -> GitFuture<'a, ()> {
        Box::pin(async move {
            if tree.mode == TreeMode::Snapshot {
                self.write_bundle(tree, true).await?;
            }
            Ok(())
        })
    }

    fn clear_gate(&self, branch: &str) {
        self.clear(branch);
    }

    fn mode(&self) -> TreeMode {
        self.mode
    }

    fn import<'a>(&'a self, repo: &'a Path, tree: &'a TaskTree) -> GitFuture<'a, ()> {
        Box::pin(async move {
            if tree.mode == TreeMode::Snapshot {
                self.write_bundle(tree, true).await?;
                self.inspect(repo, tree).await?;
            }
            Ok(())
        })
    }

    fn merge_into<'a>(
        &'a self,
        job_tree: &'a Path,
        tree: &'a TaskTree,
    ) -> GitFuture<'a, MergeOutcome> {
        Box::pin(HubGit::merge(self, job_tree, tree))
    }
}

/// The changed line ranges of each path of a `git diff -U0` text: the new side of a hunk, or, when it only deletes,
/// the old side (inclusive start, exclusive end).
fn parse_ranges(text: &str) -> BTreeMap<String, Vec<(u32, u32)>> {
    fn hunk(l: &str) -> Option<(u32, u32)> {
        let mut it = l.split_whitespace();
        it.next()?;
        let old = it.next()?.strip_prefix('-')?;
        let new = it.next()?.strip_prefix('+')?;
        let pair = |s: &str| {
            let (a, b) = s.split_once(',').unwrap_or((s, "1"));
            Some((a.parse::<u32>().ok()?, b.parse::<u32>().ok()?))
        };
        let ((oa, ob), (na, nb)) = (pair(old)?, pair(new)?);
        Some(if nb > 0 {
            (na, na + nb)
        } else {
            (oa, oa + ob.max(1))
        })
    }
    let mut out: BTreeMap<String, Vec<(u32, u32)>> = BTreeMap::new();
    let (mut file, mut old, mut header) = (None::<String>, None::<String>, false);
    for l in text.lines() {
        if l.starts_with("diff --git ") {
            header = true;
        } else if header && let Some(p) = l.strip_prefix("--- ") {
            old = p.strip_prefix("a/").map(str::to_owned);
        } else if header && let Some(p) = l.strip_prefix("+++ ") {
            file = p.strip_prefix("b/").map(str::to_owned).or(old.take());
        } else if l.starts_with("@@ ") {
            header = false;
            if let (Some(f), Some(r)) = (&file, hunk(l)) {
                out.entry(f.clone()).or_default().push(r);
            }
        }
    }
    out
}

/// The hub's [`GatePolicy`]: the acceptance marks of the task's worker session (`review_mark`, found by the worktree
/// the session registered) and `code.ci-config` through the matrix.  Holds the front weakly: the front owns the git.
pub struct HubPolicy(pub std::sync::Weak<crate::front::Front>);

impl HubPolicy {
    fn front(&self) -> Result<std::sync::Arc<crate::front::Front>, GitError> {
        self.0
            .upgrade()
            .ok_or_else(|| err("policy", "the hub is stopping"))
    }

    async fn session_of(
        front: &crate::front::Front,
        tree: &TaskTree,
    ) -> Result<Option<String>, GitError> {
        let path = tree.path.to_string_lossy().into_owned();
        front
            .writer
            .db
            .read(move |c| {
                Ok(c.query_row(
                    "select id from agent where worktree = ?1 order by started desc limit 1",
                    [path],
                    |r| r.get::<_, String>(0),
                )
                .ok())
            })
            .await
            .map_err(|e| err("agent lookup", format!("{e:?}")))
    }
}

impl GatePolicy for HubPolicy {
    fn accepted<'a>(&'a self, tree: &'a TaskTree) -> GitFuture<'a, BTreeMap<String, String>> {
        Box::pin(async move {
            let front = self.front()?;
            let Some(sid) = Self::session_of(&front, tree).await? else {
                return Ok(BTreeMap::new());
            };
            let marks = front
                .writer
                .db
                .read(move |c| norn::read::review::review_marks(c, &sid))
                .await
                .map_err(|e| err("review marks", format!("{e:?}")))?;
            Ok(marks
                .into_iter()
                .filter(|m| m.state == "accepted")
                .filter_map(|m| m.hash.map(|h| (m.path, h)))
                .collect())
        })
    }

    fn ci_config<'a>(&'a self, tree: &'a TaskTree, facts: Facts) -> GitFuture<'a, Gate> {
        Box::pin(async move {
            let front = self.front()?;
            let session = Self::session_of(&front, tree).await?;
            let (plan, project) = session
                .as_deref()
                .and_then(|s| front.core.runs.scope_of(s))
                .map_or((None, None), |(p, j)| (Some(p), j));
            let who = norn::matrix::Who {
                role: Some(norn::matrix::Role::Worker),
                ..Default::default()
            };
            let ctx = crate::matrix_gate::ActionCtx {
                project,
                plan,
                session,
                amount: None,
                facts,
            };
            Ok(front
                .core
                .matrix
                .decide(
                    &front.settings,
                    &front.writer,
                    who,
                    norn::matrix::Action::CodeCiConfig,
                    ctx,
                )
                .await)
        })
    }
}
