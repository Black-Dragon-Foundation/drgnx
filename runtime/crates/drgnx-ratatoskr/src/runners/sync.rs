//! The hub's half of sync (docs/guide/runners.md, "What is sent where"; design §6.2, §6.6): a job's inputs frozen at
//! submit, its trust from what the public origin has, and how its code reaches a runner.
//!
//! - [`freeze`]: the commit, its tree, the overlay manifest and the declared extras (`sleipnir::sync::capture`), with
//!   every overlay file's bytes copied into the hub's blob store, so later edits never change what the job runs.
//! - [`job_trust`]: `public` only for a public project whose commit the public origin's refs reach (H7).
//! - [`plan`]: an origin fetch, a resumable bundle, a push, or never, by the job's trust, the runner's and the gap.
//! - [`overlay_for`]: what of the overlay a runner gets: never the lock's protected files; for a `shared` runner only
//!   with `drgnx-runners-shared-overlay` on and every file passing the secret scan.
//! - [`make_bundle`] and [`send_bundle`]: the bundle of what a mirror lacks, in 1 MiB chunks from an offset.
//!
//! Git on the user's repository runs only through sleipnir's hardened git, and only reads it: no hook, fsmonitor,
//! system or global config runs, and nothing is written into the repository.

use forseti::{JobTrust, RunnerTrust};
use serde::{Deserialize, Serialize};
use sha2::Digest;
use sleipnir::proto::{Frame, JobRef, ManifestEntry, Sha256};
use sleipnir::sync::capture::{self, Entry, MODE_LINK};
use sleipnir::sync::git::Git;
use std::ffi::OsStr;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// GIT's output for ARGS, run for WHAT; its failure as words.
fn git_out<S: AsRef<OsStr>>(git: &Git, what: &str, args: &[S]) -> Result<Vec<u8>, String> {
    let out = git
        .cmd(args)
        .output()
        .map_err(|e| format!("git ({what}): {e}"))?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let tail = &err[err.len().saturating_sub(500)..];
        Err(format!(
            "git ({what}) exited {}: {}",
            out.status.code().unwrap_or(-1),
            tail.trim_end()
        ))
    }
}

/// Whether S is an object id (40 or 64 lower-case hex digits).
fn oid(s: &str) -> bool {
    matches!(s.len(), 40 | 64)
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The hardened git on the user's worktree at TOP.
fn user_git(top: &Path) -> Result<Git, String> {
    Git::for_worktree(top).map_err(|e| format!("{}: not a git worktree: {e}", top.display()))
}

/// The REFS this repository holds as commits.
fn present(git: &Git, refs: &[String]) -> Vec<String> {
    refs.iter()
        .filter(|r| oid(r))
        .filter(|r| {
            git.cmd(["cat-file", "-e", &format!("{r}^{{commit}}")])
                .status()
                .is_ok_and(|s| s.success())
        })
        .cloned()
        .collect()
}

/// A project's visibility (`drgnx-runners-project-visibility`): the user's word, never guessed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
    Public,
    #[default]
    Private,
}

impl Visibility {
    /// The setting's value: `public`, else private.
    pub fn parse(s: &str) -> Visibility {
        if s == "public" {
            Visibility::Public
        } else {
            Visibility::Private
        }
    }
}

/// A job's trust (design §6.6): `private+keys` when it names keys; `public` only when its project is public **and**
/// the public origin's refs reach its commit; `private` otherwise.
pub fn job_trust(visibility: Visibility, not_on_origin: u32, keys: &[String]) -> JobTrust {
    if !keys.is_empty() {
        JobTrust::PrivateKeys
    } else if visibility == Visibility::Public && not_on_origin == 0 {
        JobTrust::Public
    } else {
        JobTrust::Private
    }
}

/// What the hub knows of the repository's origin: its URL (`remote.origin.url`) and the commits its
/// remote-tracking refs (`refs/remotes/origin/*`) point at.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Origin {
    pub url: Option<String>,
    pub refs: Vec<String>,
}

/// The origin of the worktree at TOP, read through the hardened git.
pub fn origin_of(top: &Path) -> Result<Origin, String> {
    let git = user_git(top)?;
    let url = git
        .cmd(["config", "--get", "remote.origin.url"])
        .output()
        .map_err(|e| format!("git (read the origin): {e}"))?;
    let url = match url.status.code() {
        Some(0) => Some(String::from_utf8_lossy(&url.stdout).trim().to_string()),
        // not set
        Some(1) => None,
        c => return Err(format!("git (read the origin) exited {c:?}")),
    };
    let listed = git_out(
        &git,
        "list the origin's refs",
        &[
            "for-each-ref",
            "--format=%(objectname)",
            "refs/remotes/origin/",
        ],
    )?;
    let mut refs: Vec<String> = Vec::new();
    for r in String::from_utf8_lossy(&listed).lines() {
        if oid(r) && !refs.iter().any(|x| x == r) {
            refs.push(r.to_string());
        }
    }
    Ok(Origin {
        url: url.filter(|u| !u.is_empty()),
        refs,
    })
}

/// How many commits of COMMIT's history none of REFS reaches: 0 when the origin has it.
pub fn not_on(top: &Path, commit: &str, refs: &[String]) -> Result<u32, String> {
    if !oid(commit) {
        return Err(format!("{commit:?} is not an object id"));
    }
    let git = user_git(top)?;
    let mut args = vec!["rev-list".to_string(), "--count".into(), commit.into()];
    let refs = present(&git, refs);
    if !refs.is_empty() {
        args.push("--not".into());
        args.extend(refs);
    }
    let out = git_out(&git, "count the commits the origin lacks", &args)?;
    String::from_utf8_lossy(&out)
        .trim()
        .parse()
        .map_err(|e| format!("git (count the commits the origin lacks): {e}"))
}

/// A job's inputs, frozen at submit: what every runner gets, whatever the worktree holds by then.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Frozen {
    /// The worktree they were captured from (the hub's git reads its objects for a bundle).
    pub worktree: PathBuf,
    /// The repository's mirror on runners: its id (letters, digits, `.`, `_`, `-`).
    pub repo: String,
    pub commit: String,
    pub tree: String,
    /// The overlay: every uncommitted change against the commit.
    pub manifest: Vec<ManifestEntry>,
    /// The declared gitignored inputs.
    pub extras: Vec<ManifestEntry>,
    /// sha256 over the tree id, the overlay and the extras.
    pub input_key: String,
    /// The hub's store the overlay's bytes were copied into (`<store>/blobs/<sha256>`); its bundles go in
    /// `<store>/bundles/`.
    pub blobs: PathBuf,
    pub origin_url: Option<String>,
    /// Commits of the job's history the public origin's refs don't reach.
    pub not_on_origin: u32,
    pub visibility: Visibility,
    /// `drgnx-runners-shared-overlay`: a shared runner may get the overlay, once scanned.
    pub shared_overlay: bool,
}

impl Frozen {
    /// The job's trust: [`job_trust`] over what was frozen and the keys it names.
    pub fn trust(&self, keys: &[String]) -> JobTrust {
        job_trust(self.visibility, self.not_on_origin, keys)
    }

    /// The commits the origin lacks, as placement's words count them: only a public project's (a private project's
    /// job is private wherever its commits are).
    pub fn commits_not_on_origin(&self) -> u32 {
        match self.visibility {
            Visibility::Public => self.not_on_origin,
            Visibility::Private => 0,
        }
    }
}

/// Freezes the inputs of the worktree at TOP with the declared EXTRAS: captured, and the overlay's bytes copied into
/// the blob store BLOBS. A file that changes while it is copied refuses the freeze, naming it.
pub fn freeze(
    top: &Path,
    extras: &[PathBuf],
    visibility: Visibility,
    shared_overlay: bool,
    blobs: &Path,
) -> Result<Frozen, String> {
    let inputs = capture::capture(top, extras).map_err(|e| format!("the job's inputs: {e}"))?;
    let origin = origin_of(top)?;
    let not_on_origin = not_on(top, &inputs.commit, &origin.refs)?;
    let store = sleipnir::sync::blobs::Store::open(blobs)
        .map_err(|e| format!("the hub's blob store {}: {e}", blobs.display()))?;
    for e in inputs.manifest.iter().chain(&inputs.extras) {
        let Entry::File {
            path, mode, sha256, ..
        } = e
        else {
            continue;
        };
        // the lock's files are never sent, so never kept either
        if protected(path) || store.missing(&[*sha256]).is_empty() {
            continue;
        }
        let full = top.join(OsStr::from_bytes(path));
        let bytes = if *mode == MODE_LINK {
            std::fs::read_link(&full).map(|t| t.into_os_string().into_vec())
        } else {
            std::fs::read(&full)
        };
        let named = || String::from_utf8_lossy(path).escape_debug().to_string();
        let bytes = bytes.map_err(|e| format!("{}: {e}", named()))?;
        store.put(sha256, &bytes).map_err(|_| {
            format!(
                "{}: it changed while it was read; start the job again",
                named()
            )
        })?;
    }
    Ok(Frozen {
        worktree: top.to_path_buf(),
        repo: repo_id(top, origin.url.as_deref())?,
        input_key: capture::input_key(&inputs),
        commit: inputs.commit,
        tree: inputs.tree,
        manifest: inputs.manifest.into_iter().map(entry).collect(),
        extras: inputs.extras.into_iter().map(entry).collect(),
        blobs: blobs.to_path_buf(),
        origin_url: origin.url,
        not_on_origin,
        visibility,
        shared_overlay,
    })
}

/// A capture entry as the protocol carries it.
fn entry(e: Entry) -> ManifestEntry {
    match e {
        Entry::File {
            path,
            mode,
            sha256,
            size,
        } => ManifestEntry::File {
            path,
            mode,
            sha256: Sha256(sha256),
            size,
        },
        Entry::Deleted { path } => ManifestEntry::Deleted { path },
    }
}

/// The repository's mirror id on runners: its name (the origin URL's last part, else its folder's) and 8 hex digits
/// of the origin URL (else the repository's own folder), so two repositories of one name never share a mirror's refs.
fn repo_id(top: &Path, url: Option<&str>) -> Result<String, String> {
    let common = git_out(
        &user_git(top)?,
        "find the repository",
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    let common = PathBuf::from(OsStr::from_bytes(common.trim_ascii_end()));
    let folder = common
        .parent()
        .and_then(Path::file_name)
        .map(|n| n.to_string_lossy().into_owned());
    let name = url
        .and_then(|u| u.trim_end_matches('/').rsplit(['/', ':']).next())
        .map(|n| n.trim_end_matches(".git").to_string())
        .or(folder)
        .unwrap_or_default();
    let mut name: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "._-".contains(*c))
        .take(40)
        .collect();
    name = name.trim_start_matches(['.', '-']).to_string();
    if name.is_empty() {
        name = "repo".into();
    }
    let what = url.map_or_else(
        || common.as_os_str().as_bytes().to_vec(),
        |u| u.as_bytes().to_vec(),
    );
    let h = sha2::Sha256::digest(&what);
    Ok(format!("{name}-{}", hex(&h[..4])))
}

/// Whether PATH (repository-relative) is one of the lock's protected paths or under one.
fn protected(path: &[u8]) -> bool {
    crate::agents::lock::PROTECTED_RO.iter().any(|p| {
        let p = p.as_bytes();
        path == p || (path.starts_with(p) && path.get(p.len()) == Some(&b'/'))
    })
}

/// How a runner gets a job's commit (design §6.2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncPlan {
    /// The runner fetches from the origin itself; CRED names the project's deploy key or token
    /// (`drgnx-runners-origin-key`), none for a public origin.
    Origin { url: String, cred: Option<String> },
    /// One resumable bundle of the BYTES of objects the mirror lacks (more than 8 MiB).
    Bundle { bytes: u64 },
    /// `git push` into the mirror: a small gap.
    Push,
    /// Never to this runner, and why.
    Never(String),
}

/// Above this many bytes of missing objects a bundle goes; below, a push (design §6.2).
pub const BUNDLE_OVER: u64 = 8 << 20;

/// How JOB's commit reaches a runner of trust RUNNER, whose mirror lacks MISSING bytes of its objects, with the
/// project's origin key ORIGIN_KEY (none: no deploy key named). The four cases of §6.2: the public origin (any
/// runner; the only way for `shared`), a private origin with a deploy key (`mine`, `my-cloud`), a bundle over 8 MiB, a
/// push below; `shared` never gets a commit the public origin lacks.
pub fn plan(job: &Frozen, runner: RunnerTrust, missing: u64, origin_key: Option<&str>) -> SyncPlan {
    let public = job.visibility == Visibility::Public && job.not_on_origin == 0;
    if runner == RunnerTrust::Shared {
        return match (&job.origin_url, public) {
            (Some(url), true) => SyncPlan::Origin {
                url: url.clone(),
                cred: None,
            },
            (None, true) => SyncPlan::Never(
                "runs here: the project has no origin a shared runner can fetch from".into(),
            ),
            (_, false) if job.commits_not_on_origin() > 0 => {
                let n = job.not_on_origin;
                let commits = if n == 1 { "commit" } else { "commits" };
                SyncPlan::Never(format!("runs here: {n} {commits} not on origin"))
            }
            (_, false) => SyncPlan::Never(format!(
                "runs here: project {} is private; the runner is shared",
                job.repo
            )),
        };
    }
    if let Some(url) = &job.origin_url {
        if public {
            return SyncPlan::Origin {
                url: url.clone(),
                cred: None,
            };
        }
        if let Some(key) = origin_key
            && job.not_on_origin == 0
        {
            return SyncPlan::Origin {
                url: url.clone(),
                cred: Some(key.into()),
            };
        }
    }
    if missing > BUNDLE_OVER {
        SyncPlan::Bundle { bytes: missing }
    } else {
        SyncPlan::Push
    }
}

/// The bytes of COMMIT's objects that none of MIRROR_REFS reaches (`git rev-list --objects --disk-usage`); a ref the
/// hub's repository doesn't hold is left out.
pub fn missing_bytes(top: &Path, commit: &str, mirror_refs: &[String]) -> Result<u64, String> {
    if !oid(commit) {
        return Err(format!("{commit:?} is not an object id"));
    }
    let git = user_git(top)?;
    let mut args = vec![
        "rev-list".to_string(),
        "--objects".into(),
        "--disk-usage".into(),
        commit.into(),
    ];
    let refs = present(&git, mirror_refs);
    if !refs.is_empty() {
        args.push("--not".into());
        args.extend(refs);
    }
    let out = git_out(&git, "measure what the mirror lacks", &args)?;
    String::from_utf8_lossy(&out)
        .trim()
        .parse()
        .map_err(|e| format!("git (measure what the mirror lacks): {e}"))
}

/// What of JOB's overlay and extras a runner of trust RUNNER gets: never a file of the lock's protected paths
/// (`.envrc`, `mise.toml`, `.claude`, `.codex`, `.gemini`, `.git/hooks`). A `shared` runner gets an overlay only with
/// `drgnx-runners-shared-overlay` on and every file passing `looks_like_secret`; otherwise why the job runs elsewhere.
pub fn overlay_for(job: &Frozen, runner: RunnerTrust) -> Result<Vec<ManifestEntry>, String> {
    let path = |e: &ManifestEntry| match e {
        ManifestEntry::File { path, .. } | ManifestEntry::Deleted { path } => path.clone(),
    };
    let sent: Vec<ManifestEntry> = job
        .manifest
        .iter()
        .chain(&job.extras)
        .filter(|e| !protected(&path(e)))
        .cloned()
        .collect();
    if runner != RunnerTrust::Shared || sent.is_empty() {
        return Ok(sent);
    }
    if !job.shared_overlay {
        let n = sent.len();
        let files = if n == 1 { "file" } else { "files" };
        return Err(format!(
            "runs here: {n} uncommitted {files}, and the project sends none to a shared runner \
             (drgnx-runners-shared-overlay is off)"
        ));
    }
    for e in &sent {
        let ManifestEntry::File {
            path,
            sha256: Sha256(sha),
            ..
        } = e
        else {
            continue;
        };
        let named = String::from_utf8_lossy(path).escape_debug().to_string();
        let bytes = std::fs::read(blob_path(job, sha))
            .map_err(|e| format!("runs here: the frozen bytes of {named}: {e}"))?;
        if let Some(kind) = runstav::secrets::looks_like_secret(&String::from_utf8_lossy(&bytes)) {
            return Err(format!(
                "runs here: {named} may hold a secret ({kind}); it is never sent to a shared runner"
            ));
        }
    }
    Ok(sent)
}

/// The hub's file of blob SHA (`<store>/blobs/<sha256>`, sleipnir's blob store layout), for the frames that send it.
pub fn blob_path(job: &Frozen, sha: &[u8; 32]) -> PathBuf {
    job.blobs.join("blobs").join(hex(sha))
}

/// Sends JOB's blob SHA for attempt R through SEND, in chunks of at most 1 MiB, each with its offset and the total.
/// False when the link ended first.
pub fn send_blob(
    send: &dyn Fn(Frame) -> bool,
    r: &JobRef,
    job: &Frozen,
    sha: &[u8; 32],
) -> Result<bool, String> {
    let path = blob_path(job, sha);
    let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let total = bytes.len() as u64;
    let mut offset = 0;
    // an empty blob is one empty chunk
    for chunk in bytes
        .chunks(sleipnir::proto::MAX_CHUNK)
        .chain(bytes.is_empty().then_some(&[][..]))
    {
        let sent = send(Frame::Blob {
            r: r.clone(),
            sha256: Sha256(*sha),
            offset,
            total,
            bytes: chunk.to_vec(),
        });
        if !sent {
            return Ok(false);
        }
        offset += chunk.len() as u64;
    }
    Ok(true)
}

/// A bundle file the hub made for a runner: removed when it is dropped.
#[derive(Debug)]
pub struct BundleFile {
    pub path: PathBuf,
    pub sha256: [u8; 32],
    pub size: u64,
}

impl Drop for BundleFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// The bundle of COMMIT (as `refs/hub/job`) without what MIRROR_REFS reach, from the worktree at TOP, as a temporary
/// file under DIR. The user's repository is only read: the bundle is made in a temporary bare repository that
/// borrows its objects.
pub fn make_bundle(
    top: &Path,
    commit: &str,
    mirror_refs: &[String],
    dir: &Path,
) -> Result<BundleFile, String> {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    if !oid(commit) {
        return Err(format!("{commit:?} is not an object id"));
    }
    let user = user_git(top)?;
    let common = git_out(
        &user,
        "find the repository's objects",
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    let objects = PathBuf::from(OsStr::from_bytes(common.trim_ascii_end())).join("objects");
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let name = format!("{}-{}-{n}", &commit[..12], std::process::id());
    let work = dir.join(format!("{name}.git"));
    let made = (|| {
        std::fs::create_dir_all(&work).map_err(|e| format!("{}: {e}", work.display()))?;
        let bare = Git {
            git_dir: work.clone(),
            work_tree: None,
        };
        git_out(
            &bare,
            "make the bundle's repository",
            &["init", "-q", "--bare", "--template="],
        )?;
        let mut alt = objects.into_os_string().into_vec();
        alt.push(b'\n');
        std::fs::write(work.join("objects/info/alternates"), alt).map_err(|e| e.to_string())?;
        git_out(
            &bare,
            "name the commit",
            &["update-ref", "refs/hub/job", commit],
        )?;
        let file = dir.join(format!("{name}.bundle"));
        let mut args = vec![
            OsStr::new("bundle").to_os_string(),
            "create".into(),
            "-q".into(),
            file.clone().into_os_string(),
            "refs/hub/job".into(),
        ];
        let refs = present(&bare, mirror_refs);
        if !refs.is_empty() {
            args.push("--not".into());
            args.extend(refs.into_iter().map(Into::into));
        }
        git_out(&bare, "make the bundle", &args)?;
        Ok::<PathBuf, String>(file)
    })();
    let _ = std::fs::remove_dir_all(&work);
    let path = made?;
    let mut f = std::fs::File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; sleipnir::sync::bundle::CHUNK];
    let mut size = 0u64;
    loop {
        let k = f.read(&mut buf).map_err(|e| e.to_string())?;
        if k == 0 {
            break;
        }
        h.update(&buf[..k]);
        size += k as u64;
    }
    Ok(BundleFile {
        path,
        sha256: h.finalize().into(),
        size,
    })
}

/// Sends FILE as bundle ID of attempt R through SEND, in 1 MiB chunks from FROM_OFFSET; each chunk carries the total
/// and the bundle's sha256. False when the link ended first.
pub fn send_bundle(
    send: &dyn Fn(Frame) -> bool,
    r: &JobRef,
    id: &str,
    file: &BundleFile,
    from_offset: u64,
) -> Result<bool, String> {
    let mut f =
        std::fs::File::open(&file.path).map_err(|e| format!("{}: {e}", file.path.display()))?;
    f.seek(SeekFrom::Start(from_offset))
        .map_err(|e| e.to_string())?;
    let mut offset = from_offset;
    while offset < file.size {
        let want = (file.size - offset).min(sleipnir::sync::bundle::CHUNK as u64) as usize;
        let mut bytes = vec![0u8; want];
        f.read_exact(&mut bytes)
            .map_err(|e| format!("{}: {e}", file.path.display()))?;
        let sent = send(Frame::Bundle {
            r: r.clone(),
            id: id.into(),
            offset,
            total: file.size,
            sha256: Some(Sha256(file.sha256)),
            bytes,
        });
        if !sent {
            return Ok(false);
        }
        offset += want as u64;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sleipnir::proto::{Nonce, Sha256};
    use std::process::Command;

    /// The user's git in DIR: no system or global config, a fixed identity.
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
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    fn commit(dir: &Path, file: &str, text: &str) -> String {
        std::fs::write(dir.join(file), text).unwrap();
        git(dir, &["add", "-A"]);
        git(dir, &["commit", "-qm", file]);
        git(dir, &["rev-parse", "HEAD"])
    }

    /// A bare origin in T and a clone of it with one pushed commit: (the clone, the pushed commit).
    fn cloned(t: &Path) -> (PathBuf, String) {
        let origin = t.join("origin.git");
        git(t, &["init", "-q", "--bare", origin.to_str().unwrap()]);
        let work = t.join("work");
        git(t, &["clone", "-q", origin.to_str().unwrap(), "work"]);
        let a = commit(&work, "a", "a\n");
        git(&work, &["push", "-q", "origin", "HEAD:main"]);
        git(&work, &["fetch", "-q", "origin"]);
        (work, a)
    }

    fn frozen(visibility: Visibility, not_on_origin: u32) -> Frozen {
        Frozen {
            worktree: PathBuf::from("/w"),
            repo: "p".into(),
            commit: "a".repeat(40),
            tree: "b".repeat(40),
            manifest: vec![],
            extras: vec![],
            input_key: "k".into(),
            blobs: PathBuf::from("/blobs"),
            origin_url: Some("https://example.invalid/p.git".into()),
            not_on_origin,
            visibility,
            shared_overlay: false,
        }
    }

    // [D] pure (temp repos, real git): public needs both the project's word and the origin's refs
    #[test]
    fn public_needs_visibility_and_reachability() {
        let t = tempfile::tempdir().unwrap();
        let (work, a) = cloned(t.path());
        let o = origin_of(&work).unwrap();
        assert_eq!(o.refs, vec![a.clone()]);
        assert!(o.url.as_deref().is_some_and(|u| u.ends_with("origin.git")));
        assert_eq!(not_on(&work, &a, &o.refs).unwrap(), 0);
        let b = commit(&work, "b", "b\n");
        assert_eq!(not_on(&work, &b, &o.refs).unwrap(), 1);
        assert_eq!(
            not_on(&work, &b, &[]).unwrap(),
            2,
            "no origin: none of it is there"
        );

        let none: &[String] = &[];
        assert_eq!(job_trust(Visibility::Public, 0, none), JobTrust::Public);
        assert_eq!(job_trust(Visibility::Private, 0, none), JobTrust::Private);
        assert_eq!(job_trust(Visibility::Public, 1, none), JobTrust::Private);
        assert_eq!(
            job_trust(Visibility::Public, 0, &["K".into()]),
            JobTrust::PrivateKeys
        );

        // frozen at submit: one unpushed commit keeps a public project's job private, the push makes it public
        let blobs = t.path().join("blobs");
        let f = freeze(&work, &[], Visibility::Public, false, &blobs).unwrap();
        assert_eq!((f.commit.as_str(), f.not_on_origin), (b.as_str(), 1));
        assert_eq!(f.trust(&[]), JobTrust::Private);
        assert_eq!(f.commits_not_on_origin(), 1);
        git(&work, &["push", "-q", "origin", "HEAD:main"]);
        git(&work, &["fetch", "-q", "origin"]);
        let f = freeze(&work, &[], Visibility::Public, false, &blobs).unwrap();
        assert_eq!(f.trust(&[]), JobTrust::Public);
        let f = freeze(&work, &[], Visibility::Private, false, &blobs).unwrap();
        assert_eq!(
            (f.trust(&[]), f.commits_not_on_origin()),
            (JobTrust::Private, 0)
        );
    }

    // [D] pure: the four cases of §6.2's table, and never to `shared` without the public origin
    #[test]
    fn plan_picks_each_of_the_four_cases() {
        use RunnerTrust::*;
        let url = "https://example.invalid/p.git".to_string();
        let public = frozen(Visibility::Public, 0);
        for r in [Mine, MyCloud, Shared] {
            assert_eq!(
                plan(&public, r, 50 << 20, None),
                SyncPlan::Origin {
                    url: url.clone(),
                    cred: None
                },
                "{r:?}"
            );
        }
        let private = frozen(Visibility::Private, 0);
        for r in [Mine, MyCloud] {
            assert_eq!(
                plan(&private, r, 50 << 20, Some("DEPLOY")),
                SyncPlan::Origin {
                    url: url.clone(),
                    cred: Some("DEPLOY".into())
                }
            );
            assert_eq!(
                plan(&private, r, BUNDLE_OVER + 1, None),
                SyncPlan::Bundle {
                    bytes: BUNDLE_OVER + 1
                }
            );
            assert_eq!(plan(&private, r, BUNDLE_OVER, None), SyncPlan::Push);
        }
        // a deploy key fetches only what the origin has
        let ahead = frozen(Visibility::Private, 2);
        assert_eq!(plan(&ahead, Mine, 1, Some("DEPLOY")), SyncPlan::Push);
        // shared: the public origin or never, whatever the key or the gap
        let unpushed = frozen(Visibility::Public, 3);
        assert_eq!(
            plan(&unpushed, Shared, 1, Some("DEPLOY")),
            SyncPlan::Never("runs here: 3 commits not on origin".into())
        );
        assert!(matches!(
            plan(&private, Shared, 1, Some("DEPLOY")),
            SyncPlan::Never(w) if w.contains("private")
        ));
        let mut no_url = frozen(Visibility::Public, 0);
        no_url.origin_url = None;
        assert!(matches!(plan(&no_url, Shared, 1, None), SyncPlan::Never(_)));
        assert_eq!(
            plan(&no_url, Mine, 1, None),
            SyncPlan::Push,
            "no origin URL: pushed to a runner of the user's"
        );

        // the gap is measured against what the mirror already has
        let t = tempfile::tempdir().unwrap();
        let (work, a) = cloned(t.path());
        let noise: String = (0..20_000).map(|i| format!("{i:x}")).collect();
        let b = commit(&work, "big", &noise);
        let all = missing_bytes(&work, &b, &[]).unwrap();
        let gap = missing_bytes(&work, &b, std::slice::from_ref(&a)).unwrap();
        assert!(gap > 0 && gap < all, "{gap} of {all}");
        assert_eq!(
            missing_bytes(&work, &b, std::slice::from_ref(&b)).unwrap(),
            0
        );
        let unknown = "f".repeat(40);
        assert_eq!(
            missing_bytes(&work, &b, &[a, unknown]).unwrap(),
            gap,
            "a ref the hub lacks is left out"
        );
    }

    // [D] pure (a temp repo, real git): the lock's protected files are never sent, to any runner
    #[test]
    fn the_lock_files_are_never_in_an_overlay() {
        let t = tempfile::tempdir().unwrap();
        let (work, _) = cloned(t.path());
        std::fs::create_dir_all(work.join(".claude")).unwrap();
        std::fs::create_dir_all(work.join("src")).unwrap();
        for (f, text) in [
            (".envrc", "export TOKEN=x\n"),
            ("mise.toml", "[tools]\n"),
            (".claude/settings.json", "{}\n"),
            ("src/a.rs", "fn a() {}\n"),
        ] {
            std::fs::write(work.join(f), text).unwrap();
        }
        let blobs = t.path().join("blobs");
        let mut f = freeze(&work, &[], Visibility::Public, true, &blobs).unwrap();
        assert_eq!(f.manifest.len(), 4, "frozen whole: {:?}", f.manifest);
        let path = |e: &ManifestEntry| match e {
            ManifestEntry::File { path, .. } | ManifestEntry::Deleted { path } => path.clone(),
        };
        for r in [RunnerTrust::Mine, RunnerTrust::MyCloud, RunnerTrust::Shared] {
            let sent: Vec<Vec<u8>> = overlay_for(&f, r).unwrap().iter().map(path).collect();
            assert_eq!(sent, vec![b"src/a.rs".to_vec()], "{r:?}");
        }
        // only protected files changed: nothing to send, so a shared runner may take it even with the overlay off
        std::fs::remove_file(work.join("src/a.rs")).unwrap();
        f = freeze(&work, &[], Visibility::Public, false, &blobs).unwrap();
        assert_eq!(overlay_for(&f, RunnerTrust::Shared).unwrap(), vec![]);
        // the bytes of every sent file are in the hub's store, under their hash
        std::fs::write(work.join("src/a.rs"), "fn a() {}\n").unwrap();
        f = freeze(&work, &[], Visibility::Public, true, &blobs).unwrap();
        let Some(ManifestEntry::File {
            sha256: Sha256(sha),
            ..
        }) = overlay_for(&f, RunnerTrust::Mine).unwrap().first().cloned()
        else {
            panic!("a file")
        };
        assert_eq!(std::fs::read(blob_path(&f, &sha)).unwrap(), b"fn a() {}\n");
        assert_eq!(blob_path(&f, &sha), blobs.join("blobs").join(hex(&sha)));
        // a protected file's bytes never reach the store
        let kept = std::fs::read_dir(blobs.join("blobs")).unwrap().count();
        assert_eq!(kept, 1, "only src/a.rs's bytes are kept");
    }

    // [D] pure: a bundle goes in 1 MiB chunks from the offset, each with the total and the hash; its file goes with it
    #[test]
    fn a_bundle_is_sent_in_chunks_from_its_offset() {
        let t = tempfile::tempdir().unwrap();
        let (work, a) = cloned(t.path());
        // bytes no compressor shrinks (xorshift)
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        let noise: Vec<u8> = (0..3_000_000)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect();
        std::fs::write(work.join("noise"), &noise).unwrap();
        git(&work, &["add", "-A"]);
        git(&work, &["commit", "-qm", "noise"]);
        let b = git(&work, &["rev-parse", "HEAD"]);
        let file = make_bundle(&work, &b, &[a], &t.path().join("bundles")).unwrap();
        assert!(file.size > 2 << 20, "{}", file.size);
        let r = JobRef {
            job: "x1".into(),
            attempt: 1,
            nonce: Nonce([3; 16]),
        };
        let sent = std::cell::RefCell::new(vec![]);
        let send = |f: Frame| {
            sent.borrow_mut().push(f);
            true
        };
        let from = (1 << 20) + 5;
        assert!(send_bundle(&send, &r, "b1", &file, from).unwrap());
        let mut at = from;
        let mut bytes = vec![];
        for f in sent.borrow().iter() {
            let Frame::Bundle {
                r: x,
                id,
                offset,
                total,
                sha256,
                bytes: chunk,
            } = f
            else {
                panic!("{f:?}")
            };
            assert_eq!((x, id.as_str(), *offset, *total), (&r, "b1", at, file.size));
            assert_eq!(*sha256, Some(Sha256(file.sha256)));
            assert!(chunk.len() <= 1 << 20 && !chunk.is_empty());
            at += chunk.len() as u64;
            bytes.extend_from_slice(chunk);
        }
        assert_eq!(at, file.size);
        assert_eq!(bytes, std::fs::read(&file.path).unwrap()[from as usize..]);
        let path = file.path.clone();
        drop(file);
        assert!(!path.exists(), "the hub's temporary file goes with it");
    }
}
