//! git from a root-owned path, with overrides no repository config can undo (SB-FR17-1), and a check that a
//! repository's git dir and config are not in a folder an agent writes (docs/develop/runtime.md, "draugr").

use std::ffi::{OsStr, OsString};
use std::fmt;
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

use eitri::{FsError, Kind, TrustedProgram, open_beneath, open_path, read_regular};

/// Where git runs: on the host for Ratatoskr itself (`read_only` adds `--no-optional-locks`), or inside a sandbox,
/// where it reads no system or global config and no home.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Place {
    Trusted { read_only: bool },
    InSandbox,
}

/// One git call: where, the protocols it may use (`GIT_ALLOW_PROTOCOL`), and the arguments from the subcommand on.
#[derive(Debug, Clone)]
pub struct GitCall {
    pub place: Place,
    pub allow_protocols: Vec<&'static str>,
    pub args: Vec<OsString>,
}

/// Why a git call or a repository was refused.
#[derive(Debug)]
pub enum GitRefusal {
    /// An argument that sets config, runs a program, writes a file or moves the repository.
    Arg { arg: OsString, why: &'static str },
    /// A protocol that may not be allowed (`ext`, which runs a command), or a malformed name.
    Protocol { name: &'static str },
    /// The git dir, its config, the common dir or a worktree's config lies in a ledger folder.
    InLedger { path: PathBuf },
    /// A path of the repository could not be opened as it must be (missing, a link, too large, …).
    Fs { path: PathBuf, err: FsError },
    /// A `.git` file or `commondir` that does not say where the git dir is.
    Malformed { path: PathBuf, why: &'static str },
}

impl fmt::Display for GitRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GitRefusal::Arg { arg, why } => {
                write!(f, "git argument {} refused: {why}", arg.to_string_lossy())
            }
            GitRefusal::Protocol { name } => write!(f, "git protocol {name:?} may not be allowed"),
            GitRefusal::InLedger { path } => write!(
                f,
                "{}: in a folder agents write; git there is not trusted",
                path.display()
            ),
            GitRefusal::Fs { path, err } => write!(f, "{}: {err}", path.display()),
            GitRefusal::Malformed { path, why } => write!(f, "{}: {why}", path.display()),
        }
    }
}

impl std::error::Error for GitRefusal {}

/// The git to run, at a path only root can change, never looked up through `PATH`:
/// - Linux: `/usr/bin/git`;
/// - macOS: `<developer dir>/usr/bin/git`, the developer dir read from the root-owned link
///   `/private/var/db/xcode_select_link`, never the `/usr/bin/git` shim (it runs whatever developer dir is selected).
///   Xcode under the admin-writable `/Applications` is refused; the Command Line Tools pass.
pub fn git_program() -> Result<TrustedProgram, FsError> {
    platform_git()
}

// Linux: the distribution's git. Android: no git at a root-owned path, so the refusal at the end of the chain.
#[cfg(target_os = "linux")]
fn platform_git() -> Result<TrustedProgram, FsError> {
    eitri::trusted_program(&[Path::new("/usr/bin/git")])
}

// macOS only (Android: the refusal below).
#[cfg(target_os = "macos")]
fn platform_git() -> Result<TrustedProgram, FsError> {
    git_from_xcode_link(Path::new("/private/var/db/xcode_select_link"))
}

// Every other OS, Android included: no trusted git; fails closed.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_git() -> Result<TrustedProgram, FsError> {
    Err(FsError::Unsupported(
        "no git at a root-owned path on this OS",
    ))
}

#[cfg(any(test, target_os = "macos"))]
const WHY_LINK_DIR: &str = "the link's directory, or one above it, is not root's alone";
#[cfg(any(test, target_os = "macos"))]
const WHY_NOT_A_LINK: &str = "not a link";
#[cfg(any(test, target_os = "macos"))]
const WHY_LINK_OWNER: &str = "the link is not owned by root";

/// The git under the developer dir that `link` (xcode-select's link) names. Every directory from the link's own up
/// to `/` is opened without links and must be root's and not group- or world-writable; the link must be root's;
/// `<target>/usr/bin/git` must pass `trusted_program` (so a relative or `..` target is refused). Compiled for tests
/// on every OS, so the resolver runs against a fixture on Linux.
#[cfg(any(test, target_os = "macos"))]
fn git_from_xcode_link(link: &Path) -> Result<TrustedProgram, FsError> {
    use std::ffi::CString;
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStringExt;

    let untrusted = |why| FsError::Untrusted {
        path: link.to_path_buf(),
        why,
    };
    let (Some(dir), Some(name)) = (link.parent(), link.file_name()) else {
        return Err(untrusted(WHY_NOT_A_LINK));
    };
    let mut dir_fd = None;
    for d in dir.ancestors() {
        let pinned = eitri::open_path(d, eitri::Kind::Dir)?;
        let st = fstat_at(pinned.fd.as_raw_fd(), None)?;
        if st.st_uid != 0 || st.st_mode & 0o022 != 0 {
            return Err(untrusted(WHY_LINK_DIR));
        }
        dir_fd.get_or_insert(pinned.fd);
    }
    let dir_fd = dir_fd.ok_or_else(|| untrusted(WHY_NOT_A_LINK))?;
    let name = CString::new(name.as_bytes()).map_err(|_| untrusted(WHY_NOT_A_LINK))?;
    let st = fstat_at(dir_fd.as_raw_fd(), Some(&name))?;
    if st.st_mode & libc::S_IFMT != libc::S_IFLNK {
        return Err(untrusted(WHY_NOT_A_LINK));
    }
    if st.st_uid != 0 {
        return Err(untrusted(WHY_LINK_OWNER));
    }
    let mut buf = vec![0u8; 4096];
    // SAFETY: readlinkat(2) writes at most `buf.len()` bytes into `buf`.
    let n = unsafe {
        libc::readlinkat(
            dir_fd.as_raw_fd(),
            name.as_ptr(),
            buf.as_mut_ptr().cast(),
            buf.len(),
        )
    };
    let n = usize::try_from(n).map_err(|_| std::io::Error::last_os_error())?;
    if n >= buf.len() {
        return Err(untrusted(WHY_NOT_A_LINK));
    }
    buf.truncate(n);
    let dev = PathBuf::from(OsString::from_vec(buf));
    eitri::trusted_program(&[&dev.join("usr/bin/git")])
}

/// `fstat` of `fd`, or with `name`, `fstatat(fd, name, AT_SYMLINK_NOFOLLOW)`.
#[cfg(any(test, target_os = "macos"))]
fn fstat_at(fd: std::os::fd::RawFd, name: Option<&std::ffi::CStr>) -> std::io::Result<libc::stat> {
    let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: fstat(2) / fstatat(2) fill `st` on success; `name` is NUL-terminated.
    let r = unsafe {
        match name {
            None => libc::fstat(fd, st.as_mut_ptr()),
            Some(n) => libc::fstatat(fd, n.as_ptr(), st.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW),
        }
    };
    if r != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: the call succeeded, so `st` is initialised.
    Ok(unsafe { st.assume_init() })
}

/// The start of every call: no fsmonitor or hook runs, no pager or editor starts, and `ext::` never runs a command.
const OVERRIDES: [&str; 10] = [
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.pager=cat",
    "-c",
    "core.editor=false",
    "-c",
    "protocol.ext.allow=never",
];

const WHY_CONFIG: &str = "sets config";
const WHY_PROGRAM: &str = "runs a program";
const WHY_FILE: &str = "writes a file or a template";
const WHY_REPO: &str = "moves the repository (it would bypass check_trusted_repo)";

/// Long options refused anywhere, also as `--NAME=VALUE` and as any abbreviation git would accept (a prefix).
const REFUSED_LONG: [(&str, &str); 14] = [
    ("config", WHY_CONFIG),
    ("config-env", WHY_CONFIG),
    ("textconv", WHY_PROGRAM),
    ("ext-diff", WHY_PROGRAM),
    ("extcmd", WHY_PROGRAM),
    ("upload-pack", WHY_PROGRAM),
    ("receive-pack", WHY_PROGRAM),
    ("exec", WHY_PROGRAM),
    ("exec-path", WHY_PROGRAM),
    ("open-files-in-pager", WHY_PROGRAM),
    ("output", WHY_FILE),
    ("template", WHY_FILE),
    ("git-dir", WHY_REPO),
    ("work-tree", WHY_REPO),
];

/// Short options refused anywhere, alone, with a value attached, or in a cluster (`-iO`).
const REFUSED_SHORT: [(u8, &str); 3] = [(b'c', WHY_CONFIG), (b'O', WHY_PROGRAM), (b'C', WHY_REPO)];

/// Short options refused after a subcommand, where they name a program (`--upload-pack`, `--exec`, `--extcmd`).
const REFUSED_AFTER: [(&str, u8); 7] = [
    ("clone", b'u'),
    ("fetch", b'u'),
    ("pull", b'u'),
    ("ls-remote", b'u'),
    ("archive", b'u'),
    ("rebase", b'x'),
    ("difftool", b'x'),
];

/// Environment pairs, in order.
pub type Env = Vec<(OsString, OsString)>;

/// The argv after the program and the environment additions for `call`, or the refusal.
///
/// The argv is [`OVERRIDES`], then `--no-optional-locks` for a trusted read, then `call.args`. The environment is
/// `GIT_TERMINAL_PROMPT=0` and `GIT_ALLOW_PROTOCOL`, plus, in a sandbox, no system or global config or attributes,
/// no home and no LFS smudge. It never carries `DEVELOPER_DIR`, `TOOLCHAINS` or `SDKROOT`; the caller's own part of
/// the environment must not either. Values that came from an agent go after `--`, or are checked as hex object ids.
pub fn command(call: &GitCall) -> Result<(Vec<OsString>, Env), GitRefusal> {
    for &name in &call.allow_protocols {
        if name.is_empty() || name == "ext" || name.contains(':') {
            return Err(GitRefusal::Protocol { name });
        }
    }
    let mut after: Vec<u8> = Vec::new();
    for arg in &call.args {
        let bytes = arg.as_bytes();
        if let Some(why) = refused(bytes, &after) {
            return Err(GitRefusal::Arg {
                arg: arg.clone(),
                why,
            });
        }
        if let Some(&(_, letter)) = REFUSED_AFTER.iter().find(|(s, _)| s.as_bytes() == bytes) {
            after.push(letter);
        }
    }
    let mut argv: Vec<OsString> = OVERRIDES.iter().map(OsString::from).collect();
    if call.place == (Place::Trusted { read_only: true }) {
        argv.push("--no-optional-locks".into());
    }
    argv.extend(call.args.iter().cloned());
    let mut env: Vec<(OsString, OsString)> = vec![
        ("GIT_TERMINAL_PROMPT".into(), "0".into()),
        (
            "GIT_ALLOW_PROTOCOL".into(),
            call.allow_protocols.join(":").into(),
        ),
    ];
    if call.place == Place::InSandbox {
        env.extend(
            [
                ("GIT_CONFIG_NOSYSTEM", "1"),
                ("GIT_CONFIG_GLOBAL", "/dev/null"),
                ("GIT_ATTR_NOSYSTEM", "1"),
                ("HOME", "/nonexistent"),
                ("GIT_LFS_SKIP_SMUDGE", "1"),
            ]
            .map(|(k, v)| (k.into(), v.into())),
        );
    }
    Ok((argv, env))
}

/// Why `arg` is refused, if it is: a refused long option or an abbreviation of one, or a single-dash argument
/// holding a refused short letter (`after`: the letters refused since a subcommand was seen).
fn refused(arg: &[u8], after: &[u8]) -> Option<&'static str> {
    if let Some(long) = arg.strip_prefix(b"--") {
        let name = long.split(|&b| b == b'=').next().unwrap_or_default();
        if name.is_empty() {
            return None;
        }
        return REFUSED_LONG
            .iter()
            .find(|(full, _)| full.as_bytes().starts_with(name))
            .map(|&(_, why)| why);
    }
    let letters = arg.strip_prefix(b"-")?;
    REFUSED_SHORT
        .iter()
        .copied()
        .chain(after.iter().map(|&l| (l, WHY_PROGRAM)))
        .find(|(l, _)| letters.contains(l))
        .map(|(_, why)| why)
}

/// How much of a `.git` file or a `commondir` file is read.
const GIT_FILE_CAP: u64 = 4096;

/// Refuses a repository whose git dir, config, common dir or worktree config lies in a folder for which `in_ledger`
/// is true (it is asked about each such path and every folder above it). The git dir is `repo/.git` as a directory,
/// or what a `.git` file's `gitdir:` line names; the common dir is what its `commondir` file names, or the git dir.
/// Every path is opened without links (a link is refused, since git would follow it) and compared after `..` is
/// resolved by its components (no link was followed, so that is where it leads).
pub fn check_trusted_repo(
    repo: &Path,
    in_ledger: &dyn Fn(&Path) -> bool,
) -> Result<(), GitRefusal> {
    let repo = normal(repo);
    let repo_fd = open_path(&repo, Kind::Dir).map_err(fs_err(&repo))?;
    let dotgit = repo.join(".git");
    let pinned =
        open_beneath(repo_fd.fd.as_fd(), Path::new(".git"), Kind::Any).map_err(fs_err(&dotgit))?;
    let git_dir = if pinned.is_dir {
        dotgit
    } else {
        let text = read_regular(repo_fd.fd.as_fd(), Path::new(".git"), GIT_FILE_CAP)
            .map_err(fs_err(&dotgit))?;
        let target = text
            .strip_prefix(b"gitdir: ")
            .map(|t| t.trim_ascii_end())
            .filter(|t| !t.is_empty())
            .ok_or(GitRefusal::Malformed {
                path: dotgit,
                why: "a .git file without a `gitdir: PATH` line",
            })?;
        normal(&repo.join(OsStr::from_bytes(target)))
    };
    outside(&git_dir, in_ledger)?;
    let git_fd = open_path(&git_dir, Kind::Dir).map_err(fs_err(&git_dir))?;

    let common = match read_regular(git_fd.fd.as_fd(), Path::new("commondir"), GIT_FILE_CAP) {
        Ok(text) => {
            let target = text.trim_ascii_end();
            if target.is_empty() {
                return Err(GitRefusal::Malformed {
                    path: git_dir.join("commondir"),
                    why: "an empty commondir file",
                });
            }
            normal(&git_dir.join(OsStr::from_bytes(target)))
        }
        Err(e) if not_found(&e) => git_dir.clone(),
        Err(e) => return Err(fs_err(&git_dir.join("commondir"))(e)),
    };
    outside(&common, in_ledger)?;
    let common_fd = open_path(&common, Kind::Dir).map_err(fs_err(&common))?;

    for (dir, fd) in [(&git_dir, &git_fd), (&common, &common_fd)] {
        for file in ["config", "config.worktree"] {
            config_file(dir, fd.fd.as_fd(), Path::new(file), in_ledger)?;
        }
    }
    let worktrees = common.join("worktrees");
    match open_beneath(common_fd.fd.as_fd(), Path::new("worktrees"), Kind::Dir) {
        Err(e) if not_found(&e) => {}
        Err(e) => return Err(fs_err(&worktrees)(e)),
        // Listed by path: the directory was just opened without a link, and each entry is opened beneath the
        // pinned descriptor, so a name listed from elsewhere is only not found.
        Ok(wt_fd) => {
            let entries =
                std::fs::read_dir(&worktrees).map_err(|e| fs_err(&worktrees)(e.into()))?;
            for entry in entries {
                let entry = entry.map_err(|e| fs_err(&worktrees)(e.into()))?;
                let rel = Path::new(&entry.file_name()).join("config.worktree");
                config_file(&worktrees, wt_fd.fd.as_fd(), &rel, in_ledger)?;
            }
        }
    }
    Ok(())
}

/// A config file git may read, `rel` beneath `dir`: absent, or a regular file reached without a link, outside every
/// ledger folder.
fn config_file(
    dir: &Path,
    dir_fd: BorrowedFd<'_>,
    rel: &Path,
    in_ledger: &dyn Fn(&Path) -> bool,
) -> Result<(), GitRefusal> {
    let path = dir.join(rel);
    match open_beneath(dir_fd, rel, Kind::File) {
        Ok(_) => outside(&path, in_ledger),
        Err(e) if not_found(&e) || matches!(e, FsError::NotDir) => Ok(()),
        Err(e) => Err(fs_err(&path)(e)),
    }
}

/// `InLedger` when `path` or a folder above it is a ledger folder.
fn outside(path: &Path, in_ledger: &dyn Fn(&Path) -> bool) -> Result<(), GitRefusal> {
    if path.ancestors().any(in_ledger) {
        return Err(GitRefusal::InLedger {
            path: path.to_path_buf(),
        });
    }
    Ok(())
}

fn not_found(e: &FsError) -> bool {
    matches!(e, FsError::Io(e) if e.kind() == std::io::ErrorKind::NotFound)
}

fn fs_err(path: &Path) -> impl FnOnce(FsError) -> GitRefusal + '_ {
    move |err| GitRefusal::Fs {
        path: path.to_path_buf(),
        err,
    }
}

/// `path` with `.` dropped and each `..` taking off the component before it, by components only (`/..` is `/`).
fn normal(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(place: Place, args: &[&str]) -> GitCall {
        GitCall {
            place,
            allow_protocols: vec!["https", "file"],
            args: args.iter().map(OsString::from).collect(),
        }
    }

    fn strs(v: &[OsString]) -> Vec<&str> {
        v.iter().map(|s| s.to_str().unwrap()).collect()
    }

    fn env_strs(v: &[(OsString, OsString)]) -> Vec<(&str, &str)> {
        v.iter()
            .map(|(k, v)| (k.to_str().unwrap(), v.to_str().unwrap()))
            .collect()
    }

    const OVERRIDES: [&str; 10] = [
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.pager=cat",
        "-c",
        "core.editor=false",
        "-c",
        "protocol.ext.allow=never",
    ];

    #[test]
    fn trusted_read_has_the_overrides_and_no_optional_locks() {
        let (argv, env) = command(&call(
            Place::Trusted { read_only: true },
            &["status", "--porcelain"],
        ))
        .unwrap();
        let mut want = OVERRIDES.to_vec();
        want.extend(["--no-optional-locks", "status", "--porcelain"]);
        assert_eq!(strs(&argv), want);
        assert_eq!(
            env_strs(&env),
            [
                ("GIT_TERMINAL_PROMPT", "0"),
                ("GIT_ALLOW_PROTOCOL", "https:file")
            ]
        );

        let (argv, _) = command(&call(Place::Trusted { read_only: false }, &["fetch"])).unwrap();
        let mut want = OVERRIDES.to_vec();
        want.push("fetch");
        assert_eq!(strs(&argv), want);
    }

    #[test]
    fn in_sandbox_has_the_isolation_env() {
        let (argv, env) = command(&call(Place::InSandbox, &["log", "-1"])).unwrap();
        let mut want = OVERRIDES.to_vec();
        want.extend(["log", "-1"]);
        assert_eq!(strs(&argv), want);
        assert_eq!(
            env_strs(&env),
            [
                ("GIT_TERMINAL_PROMPT", "0"),
                ("GIT_ALLOW_PROTOCOL", "https:file"),
                ("GIT_CONFIG_NOSYSTEM", "1"),
                ("GIT_CONFIG_GLOBAL", "/dev/null"),
                ("GIT_ATTR_NOSYSTEM", "1"),
                ("HOME", "/nonexistent"),
                ("GIT_LFS_SKIP_SMUDGE", "1"),
            ]
        );
        for (k, _) in &env {
            for bad in ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"] {
                assert_ne!(k, bad);
            }
        }
    }

    #[test]
    fn caller_cannot_pass_config_or_programs() {
        let refused: &[&[&str]] = &[
            // config
            &["-c", "core.pager=sh"],
            &["status", "-c", "x=y"],
            &["--config", "x=y"],
            &["--config=x=y"],
            &["--config-env", "x=Y"],
            &["--config-env=x=Y"],
            // programs
            &["diff", "--textconv"],
            &["diff", "--textconv=x"],
            &["diff", "--ext-diff"],
            &["difftool", "--extcmd", "sh"],
            &["difftool", "--extcmd=sh"],
            &["ls-remote", "--upload-pack", "sh"],
            &["ls-remote", "--upload-pack=sh"],
            &["push", "--receive-pack=sh"],
            &["push", "--receive-pack", "sh"],
            &["rebase", "--exec", "sh"],
            &["rebase", "--exec=sh"],
            &["--exec-path"],
            &["--exec-path=/tmp"],
            &["grep", "-O", "x"],
            &["grep", "-Ovim", "x"],
            &["grep", "-iO", "x"],
            &["grep", "--open-files-in-pager", "x"],
            &["grep", "--open-files-in-pager=vim", "x"],
            // files and hooks
            &["diff", "--output", "f"],
            &["diff", "--output=f"],
            &["init", "--template", "t"],
            &["init", "--template=t"],
            // repository location
            &["--git-dir", "x", "status"],
            &["--git-dir=x", "status"],
            &["--work-tree", "x", "status"],
            &["--work-tree=x", "status"],
            &["-C", "x", "status"],
            &["-Cx", "status"],
            // abbreviations git accepts for long options
            &["ls-remote", "--upload-p=sh"],
            &["cat-file", "--textc", "x"],
            &["diff", "--outp=f"],
            &["--git-d=x", "status"],
            // anywhere, also after `--`
            &["log", "--", "--output=f"],
            // after a subcommand
            &["clone", "-u", "sh", "url"],
            &["clone", "-usht", "url"],
            &["clone", "-qu", "sh", "url"],
            &["fetch", "-u"],
            &["pull", "-u", "x"],
            &["ls-remote", "-u", "sh"],
            &["archive", "-u", "sh"],
            &["rebase", "-x", "sh"],
            &["rebase", "-ix", "sh"],
            &["difftool", "-x", "sh"],
        ];
        for args in refused {
            for place in [Place::Trusted { read_only: true }, Place::InSandbox] {
                match command(&call(place, args)) {
                    Err(GitRefusal::Arg { .. }) => {}
                    other => panic!("{args:?}: {other:?}"),
                }
            }
        }
        // Controls: the same letters where git gives them no program, file or config.
        let allowed: &[&[&str]] = &[
            &["status", "-u"],
            &["log", "-x"],
            &["diff", "--no-ext-diff", "--no-textconv"],
            &["log", "--", "file"],
            &["status", "--porcelain=v2"],
            &["rev-parse", "HEAD"],
        ];
        for args in allowed {
            command(&call(Place::InSandbox, args)).unwrap_or_else(|e| panic!("{args:?}: {e}"));
        }
    }

    #[test]
    fn the_ext_protocol_is_never_allowed() {
        for bad in ["ext", "ssh:ext", ""] {
            let mut c = call(Place::InSandbox, &["fetch"]);
            c.allow_protocols = vec![bad];
            match command(&c) {
                Err(GitRefusal::Protocol { name }) => assert_eq!(name, bad),
                other => panic!("{bad:?}: {other:?}"),
            }
        }
    }

    /// `/var/lib/glp-XXXXXX/{db/xcode_select_link → dev, dev/usr/bin/git}`, 0755 and root's: macOS's layout for the
    /// Command Line Tools, for uid 0 only.
    fn devdir_fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let top = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/var/lib")
            .unwrap();
        let mode = |p: &Path, m| std::fs::set_permissions(p, std::fs::Permissions::from_mode(m));
        mode(top.path(), 0o755).unwrap();
        let dev = top.path().join("dev");
        std::fs::create_dir_all(dev.join("usr/bin")).unwrap();
        std::fs::create_dir(top.path().join("db")).unwrap();
        for d in ["dev", "dev/usr", "dev/usr/bin", "db"] {
            mode(&top.path().join(d), 0o755).unwrap();
        }
        let git = dev.join("usr/bin/git");
        std::fs::write(&git, b"#!/bin/sh\n").unwrap();
        mode(&git, 0o755).unwrap();
        let link = top.path().join("db/xcode_select_link");
        symlink(&dev, &link).unwrap();
        (top, link, git)
    }

    #[test]
    fn macos_devdir_from_the_link() {
        use std::os::unix::fs::{PermissionsExt, lchown, symlink};
        if !is_root() {
            eprintln!("macos_devdir_from_the_link: needs uid 0; skipped");
            return;
        }
        let (top, link, git) = devdir_fixture();
        // The control: the Command Line Tools layout passes, and the git is the one under the developer dir.
        assert_eq!(git_from_xcode_link(&link).unwrap().path, git);

        // Xcode under an admin-writable /Applications: the developer dir's parent is group-writable.
        let dev = top.path().join("dev");
        std::fs::set_permissions(&dev, std::fs::Permissions::from_mode(0o775)).unwrap();
        assert!(matches!(
            git_from_xcode_link(&link),
            Err(FsError::Untrusted { .. })
        ));
        std::fs::set_permissions(&dev, std::fs::Permissions::from_mode(0o755)).unwrap();

        // A link someone else owns.
        lchown(&link, Some(65534), None).unwrap();
        assert!(matches!(
            git_from_xcode_link(&link),
            Err(FsError::Untrusted { .. })
        ));
        lchown(&link, Some(0), None).unwrap();

        // A link in a directory someone else can write.
        let db = link.parent().unwrap();
        std::fs::set_permissions(db, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(matches!(
            git_from_xcode_link(&link),
            Err(FsError::Untrusted { .. })
        ));
        std::fs::set_permissions(db, std::fs::Permissions::from_mode(0o755)).unwrap();

        // Not a link, or a relative or `..` target.
        let plain = db.join("plain");
        std::fs::create_dir(&plain).unwrap();
        assert!(git_from_xcode_link(&plain).is_err());
        for target in ["dev", "/var/lib/../lib/x"] {
            let l = db.join("other");
            let _ = std::fs::remove_file(&l);
            symlink(target, &l).unwrap();
            assert!(
                matches!(git_from_xcode_link(&l), Err(FsError::Untrusted { .. })),
                "{target}"
            );
        }
        assert_eq!(git_from_xcode_link(&link).unwrap().path, git);
    }

    fn is_root() -> bool {
        unsafe { libc::geteuid() == 0 }
    }
}
