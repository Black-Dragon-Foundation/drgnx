//! The runner's mirrors (docs/develop/sleipnir.md, "Sync"): one bare repository per repository id, at
//! `<root>/git/<id>/`, written only through the hardened git (`super::git`). Jobs never see a mirror; slots borrow
//! its objects through their own git dirs.
//!
//! A mirror gets its objects three ways:
//!
//! - `fetch_origin`: from the project's origin, at the runner's own bandwidth, with the origin's token or deploy key
//!   served to git from memory (`super::cred`), never written to a file;
//! - a bundle (`super::bundle`), fetched in once its sha256 matches;
//! - the hub's `git push`, whose `--receive-pack` is `sleipnir git-receive` (`git_receive`).
//!
//! Refs land under `refs/origin/` (the origin's branches and tags) and `refs/hub/` (what the hub sent).

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::cred::{self, OriginCred};
use super::git::{Git, run, spawn};
use super::{Result, refused};

/// A bare mirror under the runner folder.
#[derive(Clone, Debug)]
pub struct Mirror {
    pub root: PathBuf,
    pub id: String,
    pub git_dir: PathBuf,
    /// The binary git runs as the origin's credential helper (`sleipnir credential-helper`): this process's own.
    pub helper: PathBuf,
}

/// A repository id names one directory: letters, digits, `.`, `_` and `-`, at most 64, not starting with `.` or `-`.
pub fn check_id(id: &str) -> Result<()> {
    let ok = !id.is_empty()
        && id.len() <= 64
        && !id.starts_with(['.', '-'])
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
    if ok {
        Ok(())
    } else {
        Err(refused(id.as_bytes(), "not a repository id"))
    }
}

/// An origin git may fetch from: `https://` without a user or password in it, `ssh://`, or `user@host:path`.
/// Plain `http://` only under `test-hooks`. Never a local path, `file://`, `ext::` or anything starting with `-`.
pub fn check_url(url: &str) -> Result<()> {
    let bad = |why| Err(refused(url.as_bytes(), why));
    if url.is_empty() || url.starts_with('-') || url.bytes().any(|b| b < 0x20 || b == 0x7f) {
        return bad("not an origin URL");
    }
    if url.contains("::") {
        return bad("a remote helper is never run");
    }
    let authority = |rest: &str| rest.split('/').next().unwrap_or("").to_string();
    if let Some(rest) = url.strip_prefix("https://") {
        let a = authority(rest);
        if a.is_empty() {
            return bad("an origin URL with no host");
        }
        if a.contains('@') {
            return bad("a credential in the URL (name the token as the origin key instead)");
        }
        return Ok(());
    }
    #[cfg(feature = "test-hooks")]
    if url.starts_with("http://") {
        return Ok(());
    }
    if let Some(rest) = url.strip_prefix("ssh://") {
        return if authority(rest).is_empty() {
            bad("an origin URL with no host")
        } else {
            Ok(())
        };
    }
    if !url.contains("://")
        && let Some((host, _)) = url.split_once(':')
        && !host.is_empty()
        && !host.contains('/')
    {
        return Ok(());
    }
    bad("an origin is an https or ssh URL")
}

impl Mirror {
    /// The mirror for `repo_id` under `root`, made bare (with no template, so no sample hook) if it isn't there.
    /// `core.hooksPath=/dev/null` is written into its config every time, besides the hardened git's own `-c`.
    pub fn ensure(root: &Path, repo_id: &str) -> Result<Mirror> {
        check_id(repo_id)?;
        let m = Mirror {
            root: root.to_path_buf(),
            id: repo_id.to_string(),
            git_dir: root.join("git").join(repo_id),
            helper: std::env::current_exe().unwrap_or_else(|_| PathBuf::from("sleipnir")),
        };
        if fs::symlink_metadata(m.git_dir.join("HEAD")).is_err() {
            fs::create_dir_all(&m.git_dir)?;
            run(
                "make the mirror",
                m.git().cmd(["init", "-q", "--bare", "--template="]),
                None,
            )?;
        }
        run(
            "turn the mirror's hooks off",
            m.git().cmd([
                "config",
                "--local",
                "--replace-all",
                "core.hooksPath",
                "/dev/null",
            ]),
            None,
        )?;
        Ok(m)
    }

    /// The hardened git on this mirror (bare: no work tree).
    pub fn git(&self) -> Git {
        Git {
            git_dir: self.git_dir.clone(),
            work_tree: None,
        }
    }

    /// The mirror holds the commit `commit` (an object id).
    pub fn has_commit(&self, commit: &str) -> Result<bool> {
        if !matches!(commit.len(), 40 | 64) || !commit.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(refused(commit.as_bytes(), "not an object id"));
        }
        let ran = spawn(
            self.git()
                .cmd(["cat-file", "-e", &format!("{commit}^{{commit}}")]),
            None,
        )?;
        Ok(ran.code == Some(0))
    }

    /// The commits the mirror's refs point at, each once: what a bundle from the hub may leave out.
    pub fn ref_tips(&self) -> Result<Vec<String>> {
        let out = run(
            "list the mirror's refs",
            self.git().cmd(["for-each-ref", "--format=%(objectname)"]),
            None,
        )?;
        let mut tips: Vec<String> = Vec::new();
        for t in String::from_utf8_lossy(&out).lines() {
            if !t.is_empty() && !tips.iter().any(|x| x == t) {
                tips.push(t.to_string());
            }
        }
        Ok(tips)
    }

    /// Fetches the origin's branches and tags into `refs/origin/`. A token is served to git by `sleipnir
    /// credential-helper` from this process's memory; a deploy key goes into a per-fetch `ssh-agent`, killed after
    /// the fetch. Neither is ever written to a file, and no helper or key from any config is used.
    pub fn fetch_origin(&self, url: &str, cred: Option<OriginCred>) -> Result<()> {
        check_url(url)?;
        let served = cred
            .as_ref()
            .map(|c| cred::serve(&self.root, c, &self.helper))
            .transpose()?;
        let mut args: Vec<String> = [
            "-c",
            "credential.helper=",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.https.allow=always",
            "-c",
            "protocol.ssh.allow=always",
        ]
        .map(String::from)
        .to_vec();
        #[cfg(feature = "test-hooks")]
        args.extend(["-c".to_string(), "protocol.http.allow=always".to_string()]);
        if let Some(s) = &served {
            args.extend(s.args.iter().cloned());
        }
        args.extend(
            [
                "fetch",
                "-q",
                "--no-tags",
                "--prune",
                "--no-write-fetch-head",
                "--end-of-options",
                url,
                "+refs/heads/*:refs/origin/heads/*",
                "+refs/tags/*:refs/origin/tags/*",
            ]
            .map(String::from),
        );
        let mut c = self.git().cmd(&args);
        if let Some(s) = &served {
            for (k, v) in &s.env {
                c.env(k, v);
            }
        }
        let r = run("fetch from the origin", c, None);
        drop(served);
        r.map(|_| ())
    }

    /// Fetches a verified bundle file's refs into `refs/hub/`, every object checked.
    pub(crate) fn fetch_bundle(&self, file: &Path) -> Result<()> {
        let c = self.git().cmd([
            OsStr::new("fetch"),
            OsStr::new("-q"),
            OsStr::new("--no-tags"),
            OsStr::new("--no-write-fetch-head"),
            OsStr::new("--end-of-options"),
            file.as_os_str(),
            OsStr::new("+refs/*:refs/hub/*"),
        ]);
        run("fetch the bundle into the mirror", c, None)?;
        Ok(())
    }
}

/// The command `sleipnir git-receive --root ROOT REPO` execs: `git receive-pack` on the mirror REPO names (its id,
/// or its path `ROOT/git/<id>`), hardened as every git of sleipnir, with the caller's stdin and stdout (the hub's
/// `git push` over SSH). No hook runs and every object received is checked.
pub fn git_receive(root: &Path, repo: &str) -> Result<Command> {
    let trimmed = repo.trim_end_matches('/');
    let p = Path::new(trimmed);
    let id = p
        .file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| refused(repo.as_bytes(), "not a mirror"))?;
    if trimmed.contains('/') {
        let mirrors = fs::canonicalize(root.join("git")).ok();
        let parent = p.parent().and_then(|d| fs::canonicalize(d).ok());
        if mirrors.is_none() || parent != mirrors {
            return Err(refused(
                repo.as_bytes(),
                "not a mirror in the runner folder",
            ));
        }
    }
    let m = Mirror::ensure(root, id)?;
    let mut c = m
        .git()
        .cmd([OsStr::new("receive-pack"), m.git_dir.as_os_str()]);
    c.stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    Ok(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure
    #[test]
    fn an_origin_that_isnt_https_or_ssh_is_refused() {
        for good in [
            "https://github.com/org/repo.git",
            "ssh://git@github.com/org/repo.git",
            "git@github.com:org/repo.git",
            "github.com:org/repo",
        ] {
            assert!(check_url(good).is_ok(), "{good}");
        }
        for bad in [
            "",
            "-uhttps://x",
            "--upload-pack=touch /tmp/x",
            "ext::sh -c touch% /tmp/x",
            "fd::3",
            "file:///etc",
            "/srv/repo",
            "../repo",
            "https://user:token@github.com/org/repo.git",
            "https://token@github.com/org/repo.git",
            "https:///nohost",
            "https://github.com/org/repo\n",
            "ftp://example.invalid/repo",
        ] {
            assert!(check_url(bad).is_err(), "{bad:?} was allowed");
        }
        for bad in ["", ".", "..", "-x", "a/b", ".git", &"x".repeat(65)] {
            assert!(check_id(bad).is_err(), "{bad:?} was allowed");
        }
        check_id("drgnx-1.repo_x").unwrap();
    }

    // [D] pure (a temp repo, real git)
    #[test]
    fn a_mirror_is_bare_with_hooks_off() {
        let t = tempfile::tempdir().unwrap();
        let m = Mirror::ensure(t.path(), "r").unwrap();
        assert_eq!(m.git_dir, t.path().join("git/r"));
        assert!(m.git_dir.join("HEAD").is_file());
        assert!(
            !m.git_dir.join("hooks").exists(),
            "no template, so no sample hook"
        );
        let out = run(
            "read the config",
            m.git().cmd(["config", "--local", "core.hooksPath"]),
            None,
        )
        .unwrap();
        assert_eq!(out, b"/dev/null\n");
        let again = Mirror::ensure(t.path(), "r").unwrap();
        assert_eq!(again.git_dir, m.git_dir);
    }
}
