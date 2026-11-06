//! Test repositories with real git, and a blob store over a directory (what the hub would have sent).

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::capture::{Entry, Inputs};
use super::hex;
use super::slot::Blobs;

/// The user's git in a test: plain git in `dir`, with no system or global config and a fixed identity.
pub fn user_git(dir: &Path, args: &[&str]) -> Vec<u8> {
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
        .expect("git runs");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}

pub fn path(root: &Path, rel: &[u8]) -> PathBuf {
    root.join(OsStr::from_bytes(rel))
}

pub fn write(root: &Path, rel: &[u8], bytes: &[u8]) {
    let p = path(root, rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, bytes).unwrap();
}

/// The time as the filesystem under `dir` stamps it now (the mtime of a file written just now): what the files'
/// ages are measured against, without a read of the process's own clock.
pub fn fs_now(dir: &Path) -> std::time::SystemTime {
    let probe = dir.join(".fs-now");
    fs::write(&probe, b"").unwrap();
    fs::metadata(&probe).unwrap().modified().unwrap()
}

/// A repository at `dir/repo` with `files` committed; returns its path and the commit.
pub fn repo(dir: &Path, files: &[(&[u8], &[u8])]) -> (PathBuf, String) {
    let repo = dir.join("repo");
    fs::create_dir_all(&repo).unwrap();
    user_git(&repo, &["init", "-q"]);
    for (rel, bytes) in files {
        write(&repo, rel, bytes);
    }
    user_git(&repo, &["add", "-A"]);
    user_git(&repo, &["commit", "-qm", "one"]);
    let commit = head(&repo);
    (repo, commit)
}

pub fn commit_all(repo: &Path, msg: &str) -> String {
    user_git(repo, &["add", "-A"]);
    user_git(repo, &["commit", "-qm", msg]);
    head(repo)
}

pub fn head(repo: &Path) -> String {
    String::from_utf8(user_git(repo, &["rev-parse", "HEAD"]))
        .unwrap()
        .trim()
        .to_string()
}

/// The blobs a hub would have sent: each overlay file's bytes (a link's target), named by its sha256 hex.
pub struct DirBlobs {
    pub dir: PathBuf,
}

impl DirBlobs {
    pub fn of(dir: &Path, repo: &Path, inputs: &Inputs) -> DirBlobs {
        fs::create_dir_all(dir).unwrap();
        for e in inputs.manifest.iter().chain(&inputs.extras) {
            if let Entry::File {
                path: rel, sha256, ..
            } = e
            {
                let src = path(repo, rel);
                let meta = fs::symlink_metadata(&src).unwrap();
                let bytes = if meta.file_type().is_symlink() {
                    fs::read_link(&src).unwrap().as_os_str().as_bytes().to_vec()
                } else {
                    fs::read(&src).unwrap()
                };
                fs::write(dir.join(hex(sha256)), bytes).unwrap();
            }
        }
        DirBlobs {
            dir: dir.to_path_buf(),
        }
    }
}

impl Blobs for DirBlobs {
    fn path(&self, sha256: &[u8; 32]) -> PathBuf {
        self.dir.join(hex(sha256))
    }
}

/// Every name under `root` (raw bytes, relative) with its kind and contents, never following a link.
pub fn tree(root: &Path) -> BTreeMap<Vec<u8>, String> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<Vec<u8>, String>) {
        for e in fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let p = e.path();
            let rel = p
                .strip_prefix(root)
                .unwrap()
                .as_os_str()
                .as_bytes()
                .to_vec();
            let ft = e.file_type().unwrap();
            if ft.is_symlink() {
                out.insert(
                    rel,
                    format!("link {}", fs::read_link(&p).unwrap().display()),
                );
            } else if ft.is_dir() {
                out.insert(rel, "dir".into());
                walk(root, &p, out);
            } else {
                out.insert(
                    rel,
                    format!("file {}", String::from_utf8_lossy(&fs::read(&p).unwrap())),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

/// A script at `at` that appends `name` to `marker` when anything runs it.
pub fn marker_script(at: &Path, marker: &Path, name: &str) {
    fs::create_dir_all(at.parent().unwrap()).unwrap();
    fs::write(
        at,
        format!("#!/bin/sh\necho {name} >> '{}'\n", marker.display()),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(at, fs::Permissions::from_mode(0o755)).unwrap();
}

/// Every hook git may run while a checkout is updated, so a git that read the planted dir would run one.
pub const HOOKS: &[&str] = &[
    "post-checkout",
    "post-index-change",
    "reference-transaction",
    "pre-commit",
    "post-commit",
    "post-merge",
    "pre-auto-gc",
    "post-rewrite",
    "pre-push",
    "fsmonitor-watchman",
];
