//! Programs that only root can change: root-owned, not group- or world-writable, in root-owned directories up to
//! `/`, found among fixed candidates and never through `PATH` (Task 1).

use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};

use rustix::fs::{Mode, fstat};

use crate::{FsError, Kind, open_path};

/// A program only root can change, and the identity it was checked under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedProgram {
    pub path: PathBuf,
    pub dev: u64,
    pub ino: u64,
}

const WHY_NOT_ABSOLUTE: &str = "not an absolute path without `.` and `..` components";
const WHY_LINK: &str = "a link in its path";
const WHY_NOT_FOUND: &str = "not found";
const WHY_CANNOT_OPEN: &str = "cannot be opened";
const WHY_NOT_REGULAR: &str = "not a regular file";
const WHY_NOT_EXECUTABLE: &str = "no execute bit";
const WHY_NOT_ROOT: &str = "not owned by root";
const WHY_WRITABLE: &str = "group- or world-writable";
const WHY_PARENT_NOT_ROOT: &str = "a parent directory is not owned by root";
const WHY_PARENT_WRITABLE: &str = "a parent directory is group- or world-writable";
const WHY_NO_CANDIDATE: &str = "no candidate given";

/// The first of `candidates` that only root can change, never looked up through `PATH`:
/// - an absolute path with no `.` or `..` component, opened with `open_path` (no link in any component);
/// - a regular file with an execute bit, owned by uid 0, not group- or world-writable;
/// - every ancestor up to `/` a directory owned by uid 0, not group- or world-writable.
///
/// No candidate passing gives the last one's `Untrusted { path, why }`. `Unsupported` (no `openat2`) ends the search
/// at once: no candidate could pass.
pub fn trusted_program(candidates: &[&Path]) -> Result<TrustedProgram, FsError> {
    let mut last = (PathBuf::new(), WHY_NO_CANDIDATE);
    for path in candidates {
        match check(path) {
            Ok(t) => return Ok(t),
            Err(Why::Unsupported(w)) => return Err(FsError::Unsupported(w)),
            Err(Why::Untrusted(why)) => last = (path.to_path_buf(), why),
        }
    }
    Err(FsError::Untrusted {
        path: last.0,
        why: last.1,
    })
}

/// Why one candidate failed: a refusal, or `Unsupported`, which ends the search (no candidate can pass).
#[derive(Debug, PartialEq, Eq)]
enum Why {
    Untrusted(&'static str),
    Unsupported(&'static str),
}

fn check(path: &Path) -> Result<TrustedProgram, Why> {
    // Compared as bytes: `Path`'s own equality ignores `.` components, repeated and trailing slashes.
    let plain = path.components().collect::<PathBuf>();
    if !path.is_absolute()
        || plain.as_os_str() != path.as_os_str()
        || path.components().any(|c| c == Component::ParentDir)
    {
        return Err(Why::Untrusted(WHY_NOT_ABSOLUTE));
    }
    let pinned = open_path(path, Kind::File).map_err(|e| match e {
        FsError::Unsupported(w) => Why::Unsupported(w),
        FsError::Link { .. } => Why::Untrusted(WHY_LINK),
        FsError::NotRegular => Why::Untrusted(WHY_NOT_REGULAR),
        FsError::Io(e) if e.kind() == ErrorKind::NotFound => Why::Untrusted(WHY_NOT_FOUND),
        _ => Why::Untrusted(WHY_CANNOT_OPEN),
    })?;
    let st = fstat(&pinned.fd).map_err(|_| Why::Untrusted(WHY_CANNOT_OPEN))?;
    let mode = Mode::from_raw_mode(st.st_mode);
    if !mode.intersects(Mode::XUSR | Mode::XGRP | Mode::XOTH) {
        return Err(Why::Untrusted(WHY_NOT_EXECUTABLE));
    }
    if st.st_uid != 0 {
        return Err(Why::Untrusted(WHY_NOT_ROOT));
    }
    if mode.intersects(Mode::WGRP | Mode::WOTH) {
        return Err(Why::Untrusted(WHY_WRITABLE));
    }
    ancestors(path)?;
    Ok(TrustedProgram {
        path: path.to_path_buf(),
        dev: pinned.dev,
        ino: pinned.ino,
    })
}

/// Every ancestor of `path` up to `/`: a directory, owned by uid 0, not group- or world-writable.
fn ancestors(path: &Path) -> Result<(), Why> {
    for dir in path.ancestors().skip(1) {
        let pinned = open_path(dir, Kind::Dir).map_err(|e| match e {
            FsError::Unsupported(w) => Why::Unsupported(w),
            FsError::Link { .. } => Why::Untrusted(WHY_LINK),
            _ => Why::Untrusted(WHY_CANNOT_OPEN),
        })?;
        let st = fstat(&pinned.fd).map_err(|_| Why::Untrusted(WHY_CANNOT_OPEN))?;
        if st.st_uid != 0 {
            return Err(Why::Untrusted(WHY_PARENT_NOT_ROOT));
        }
        if Mode::from_raw_mode(st.st_mode).intersects(Mode::WGRP | Mode::WOTH) {
            return Err(Why::Untrusted(WHY_PARENT_WRITABLE));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt, chown, symlink};

    fn why(r: Result<TrustedProgram, FsError>) -> &'static str {
        match r {
            Err(FsError::Untrusted { why, .. }) => why,
            other => panic!("expected Untrusted, got {other:?}"),
        }
    }

    fn uid0(test: &str) -> bool {
        let root = rustix::process::geteuid().is_root();
        if !root {
            eprintln!("{test}: needs uid 0; skipped");
        }
        root
    }

    fn chmod(p: &Path, mode: u32) {
        fs::set_permissions(p, fs::Permissions::from_mode(mode)).unwrap();
    }

    /// `/var/lib/glp-XXXXXX/sub/prog` (0755 each, root's): a fixture that passes, for uid 0 only.
    fn root_owned_fixture() -> (tempfile::TempDir, PathBuf) {
        let top = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/var/lib")
            .unwrap();
        chmod(top.path(), 0o755);
        let sub = top.path().join("sub");
        fs::create_dir(&sub).unwrap();
        chmod(&sub, 0o755);
        let prog = sub.join("prog");
        fs::write(&prog, b"#!/bin/sh\n").unwrap();
        chmod(&prog, 0o755);
        (top, prog)
    }

    #[test]
    fn usr_bin_env_is_trusted() {
        let t = trusted_program(&[Path::new("/usr/bin/env")]).unwrap();
        let m = fs::symlink_metadata("/usr/bin/env").unwrap();
        assert_eq!(
            t,
            TrustedProgram {
                path: "/usr/bin/env".into(),
                dev: m.dev(),
                ino: m.ino()
            }
        );
    }

    #[test]
    fn the_first_passing_candidate_wins_and_the_last_failure_is_returned() {
        let t = trusted_program(&[Path::new("/nonexistent-glp/env"), Path::new("/usr/bin/env")])
            .unwrap();
        assert_eq!(t.path, Path::new("/usr/bin/env"));
        assert_eq!(why(trusted_program(&[])), WHY_NO_CANDIDATE);
        assert_eq!(
            why(trusted_program(&[Path::new("/nonexistent-glp/env")])),
            WHY_NOT_FOUND
        );
        for bad in [
            "usr/bin/env",
            "/usr/bin/../bin/env",
            "/usr/bin/./env",
            "//usr/bin/env",
            "/usr/bin/env/",
            "",
        ] {
            match trusted_program(&[Path::new("/nonexistent-glp/env"), Path::new(bad)]) {
                Err(FsError::Untrusted { path, why }) => {
                    assert_eq!(
                        (path.as_path(), why),
                        (Path::new(bad), WHY_NOT_ABSOLUTE),
                        "{bad}"
                    );
                }
                other => panic!("{bad}: {other:?}"),
            }
        }
    }

    #[test]
    fn a_user_owned_file_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        // the true name: on macOS the temp dir is under /var, a link to /private/var (refused as a link first)
        let prog = fs::canonicalize(dir.path()).unwrap().join("prog");
        fs::write(&prog, b"#!/bin/sh\n").unwrap();
        chmod(&prog, 0o755);
        if rustix::process::geteuid().is_root() {
            chown(&prog, Some(65534), Some(65534)).unwrap();
        }
        assert_eq!(why(trusted_program(&[&prog])), WHY_NOT_ROOT);
    }

    #[test]
    fn a_group_writable_parent_is_refused() {
        if !uid0("a_group_writable_parent_is_refused") {
            return;
        }
        let (_top, prog) = root_owned_fixture();
        let sub = prog.parent().unwrap();
        // The control: the fixture passes as made.
        assert_eq!(trusted_program(&[&prog]).unwrap().path, prog);
        chmod(sub, 0o775);
        assert_eq!(why(trusted_program(&[&prog])), WHY_PARENT_WRITABLE);
        chmod(sub, 0o757);
        assert_eq!(why(trusted_program(&[&prog])), WHY_PARENT_WRITABLE);
        chmod(top_of(&prog), 0o775);
        chmod(sub, 0o755);
        assert_eq!(why(trusted_program(&[&prog])), WHY_PARENT_WRITABLE);
    }

    fn top_of(prog: &Path) -> &Path {
        prog.parent().unwrap().parent().unwrap()
    }

    #[test]
    fn a_parent_not_owned_by_root_is_refused() {
        if !uid0("a_parent_not_owned_by_root_is_refused") {
            return;
        }
        let (_top, prog) = root_owned_fixture();
        assert_eq!(trusted_program(&[&prog]).unwrap().path, prog);
        chown(prog.parent().unwrap(), Some(65534), None).unwrap();
        assert_eq!(why(trusted_program(&[&prog])), WHY_PARENT_NOT_ROOT);
    }

    #[test]
    fn a_group_or_world_writable_file_is_refused() {
        if !uid0("a_group_or_world_writable_file_is_refused") {
            return;
        }
        let (_top, prog) = root_owned_fixture();
        assert_eq!(trusted_program(&[&prog]).unwrap().path, prog);
        chmod(&prog, 0o775);
        assert_eq!(why(trusted_program(&[&prog])), WHY_WRITABLE);
        chmod(&prog, 0o757);
        assert_eq!(why(trusted_program(&[&prog])), WHY_WRITABLE);
    }

    #[test]
    fn a_file_without_an_execute_bit_is_refused() {
        if !uid0("a_file_without_an_execute_bit_is_refused") {
            return;
        }
        let (_top, prog) = root_owned_fixture();
        assert_eq!(trusted_program(&[&prog]).unwrap().path, prog);
        chmod(&prog, 0o644);
        assert_eq!(why(trusted_program(&[&prog])), WHY_NOT_EXECUTABLE);
        chmod(&prog, 0o744);
        assert_eq!(trusted_program(&[&prog]).unwrap().path, prog);
    }

    #[test]
    fn a_directory_or_a_link_is_refused() {
        if !uid0("a_directory_or_a_link_is_refused") {
            return;
        }
        let (_top, prog) = root_owned_fixture();
        let sub = prog.parent().unwrap();
        fs::create_dir(sub.join("dir")).unwrap();
        chmod(&sub.join("dir"), 0o755);
        assert_eq!(why(trusted_program(&[&sub.join("dir")])), WHY_NOT_REGULAR);
        symlink(&prog, sub.join("link")).unwrap();
        assert_eq!(why(trusted_program(&[&sub.join("link")])), WHY_LINK);
    }

    #[test]
    fn tmp_is_never_a_trusted_parent() {
        // macOS: /tmp is a link to /private/tmp (refused as a link); the directory itself is /private/tmp.
        let tmp = Path::new(if cfg!(target_os = "macos") {
            "/private/tmp"
        } else {
            "/tmp"
        });
        assert_eq!(
            ancestors(&tmp.join("prog")).unwrap_err(),
            Why::Untrusted(WHY_PARENT_WRITABLE)
        );
        if !uid0("tmp_is_never_a_trusted_parent (the whole candidate)") {
            return;
        }
        // Root's own 0755 program in root's own 0700 directory under /tmp.
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let prog = dir.path().join("prog");
        fs::write(&prog, b"#!/bin/sh\n").unwrap();
        chmod(&prog, 0o755);
        assert_eq!(why(trusted_program(&[&prog])), WHY_PARENT_WRITABLE);
    }

    #[test]
    fn ancestors_of_a_system_program_pass() {
        ancestors(Path::new("/usr/bin/env")).unwrap();
    }
}
