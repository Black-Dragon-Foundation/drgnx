//! The disk path (docs/develop/hub.md, "Pair mode"): a paired chat's write of a file no editor has open lands on disk
//! here, atomically, as the agent's own version in the edit history.
//!
//! - **Only over what the agent read.** An existing file is written only when its content hash equals the last read
//!   the hub served the session ([`CHANGED`] otherwise, [`UNREAD`] without a read); a file that does not exist is
//!   created by a whole-file write.  Hashes are of the canonical text (no BOM, LF), so a read and the disk compare
//!   whatever their line ends.
//! - **The file's form is kept**: its BOM and its CRLF line ends go back on the new text ([`Form`]).
//! - **Atomic**: a temporary file in the same folder, created beneath the checkout's folder without following a link,
//!   gets the old file's mode, owner (when the hub may set it), ACLs, extended attributes and SELinux context (the last
//!   two are extended attributes too), is synced and renamed over the file.  A hard link is broken on purpose: the
//!   other names keep the old text.  The door's gate resolved a link to its target inside the checkout, so the target
//!   is written; a link left at the name (one that names nothing) is refused.  Just before the rename the name is
//!   looked at once more ([`replace`]): another file there (inode, size, change time) refuses the write.  A writer
//!   outside drgnx between that look and the rename is not excluded (rename is no compare-and-swap); the Search view's
//!   writes ([`replace`] too) share this path.
//! - **Folders**: missing parents inside the checkout are made only after every check has passed, and removed again
//!   when the write then fails, so a refused write leaves nothing behind.
//! - **Recorded first**: the caller's record (the history's `on_agent_write`) runs before the rename, so the watcher's
//!   event about the file finds the version known and does not count it as an outside edit.

use std::ffi::OsStr;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{AtFlags, FileType, Mode, OFlags, XattrFlags};
use rustix::io::Errno;
use sha2::Digest;

use super::Refusal;
use super::door::WriteKind;
use super::writes::Served;

/// What a write of an existing file answers when the disk is not what the session read.
pub const CHANGED: &str = "changed since you read it; read it with read_file";

/// What a write of an existing file answers when the session never read it.
pub const UNREAD: &str = "you have not read it yet; read it with read_file, then retry";

/// The caller's record of the new bytes, run before the rename.
pub type Record = Box<dyn FnOnce(&Path, &[u8]) + Send>;

/// A file's form: a byte-order mark and CRLF line ends.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Form {
    pub bom: bool,
    pub crlf: bool,
}

impl Form {
    /// RAW's form: a leading BOM; CRLF when its first line end is one.
    pub fn of(raw: &str) -> Form {
        let body = raw.strip_prefix('\u{feff}').unwrap_or(raw);
        Form {
            bom: body.len() != raw.len(),
            crlf: body
                .find('\n')
                .is_some_and(|i| i > 0 && &body[i - 1..i] == "\r"),
        }
    }

    /// TEXT (canonical) in this form.
    pub fn render(self, text: &str) -> String {
        let mut out = String::with_capacity(text.len() + 3);
        if self.bom {
            out.push('\u{feff}');
        }
        if self.crlf {
            out.push_str(&text.replace("\r\n", "\n").replace('\n', "\r\n"));
        } else {
            out.push_str(text);
        }
        out
    }
}

/// RAW without its BOM, with LF line ends.
pub fn canonical(raw: &str) -> String {
    raw.strip_prefix('\u{feff}')
        .unwrap_or(raw)
        .replace("\r\n", "\n")
}

/// SHA-256 in hex of RAW's canonical text.
pub fn content_hash(raw: &str) -> String {
    sha2::Sha256::digest(canonical(raw).as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The new text of a file whose disk text is DISK (none: it does not exist), written by KIND over the session's read
/// SERVED: its canonical text, or why not.
pub fn plan(
    disk: Option<&str>,
    served: Option<&Served>,
    kind: &WriteKind,
) -> Result<String, Refusal> {
    let Some(disk) = disk else {
        return match kind {
            WriteKind::Whole { content } => Ok(canonical(content)),
            WriteKind::Edit { .. } => Err(Refusal(
                "the file does not exist; create it with write_file".into(),
            )),
        };
    };
    let Some(served) = served else {
        return Err(Refusal(UNREAD.into()));
    };
    if content_hash(&served.text) != content_hash(disk) {
        return Err(Refusal(CHANGED.into()));
    }
    let text = canonical(disk);
    match kind {
        WriteKind::Whole { content } => Ok(canonical(content)),
        WriteKind::Edit { old, new } => {
            let (old, new) = (canonical(old), canonical(new));
            if old.is_empty() {
                return Err(Refusal(format!(
                    "old is empty: give the exact text to replace; {CHANGED}"
                )));
            }
            match text.match_indices(&old).count() {
                1 => Ok(text.replacen(&old, &new, 1)),
                0 => Err(Refusal(format!("old is not in the file: {CHANGED}"))),
                _ => Err(Refusal(
                    "old matches more than once in the file; give more of it".into(),
                )),
            }
        }
    }
}

fn io(what: &str, e: impl std::fmt::Display) -> Refusal {
    Refusal(format!("{what}: {e}"))
}

/// The folder beneath ROOT_FD at the names NAMES, made where missing when MAKE (each one made pushed on MADE with its
/// parent's fd); none when a folder is missing and not MAKE.
fn folders(
    root: BorrowedFd<'_>,
    names: &[&OsStr],
    make: bool,
    made: &mut Vec<(OwnedFd, Vec<u8>)>,
) -> Result<Option<OwnedFd>, Refusal> {
    let mut cur = rustix::io::fcntl_dupfd_cloexec(root, 0).map_err(|e| io("the checkout", e))?;
    for n in names {
        let next = match eitri::open_beneath(cur.as_fd(), Path::new(n), eitri::Kind::Dir) {
            Ok(p) => p.fd,
            Err(eitri::FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
                if !make {
                    return Ok(None);
                }
                rustix::fs::mkdirat(cur.as_fd(), *n, Mode::from_raw_mode(0o777))
                    .map_err(|e| io("a folder", e))?;
                let fd = eitri::open_beneath(cur.as_fd(), Path::new(n), eitri::Kind::Dir)
                    .map_err(|e| io("a folder", e))?
                    .fd;
                made.push((cur, n.as_bytes().to_vec()));
                cur = fd;
                continue;
            }
            Err(e) => return Err(io(&Path::new(n).display().to_string(), e)),
        };
        cur = next;
    }
    Ok(Some(cur))
}

/// The folders MADE removed again, deepest first.
fn unmake(made: Vec<(OwnedFd, Vec<u8>)>) {
    for (parent, name) in made.into_iter().rev() {
        let _ = rustix::fs::unlinkat(parent.as_fd(), OsStr::from_bytes(&name), AtFlags::REMOVEDIR);
    }
}

fn temp_name() -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    format!(
        ".drgnx-pair-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    )
}

/// Every extended attribute of FROM (ACLs and the SELinux context among them) set on TO: the names of those TO ends
/// up without or with another value (lost; not fatal). One that cannot be set but that TO already holds with FROM's
/// value (a new file's SELinux context is its folder's default, usually the old file's, and a confined process may not
/// set it) is not lost.
fn copy_xattrs(from: BorrowedFd<'_>, to: BorrowedFd<'_>) -> Vec<String> {
    // the kernel's bounds: a name list and a value hold at most 64 KiB
    let mut list = vec![0u8; 1 << 16];
    let Ok(n) = rustix::fs::flistxattr(from, &mut list[..]) else {
        return Vec::new();
    };
    let mut value = vec![0u8; 1 << 16];
    let mut theirs = vec![0u8; 1 << 16];
    let mut lost = Vec::new();
    for name in list[..n].split(|b| *b == 0).filter(|s| !s.is_empty()) {
        let name = OsStr::from_bytes(name);
        let Ok(len) = rustix::fs::fgetxattr(from, name, &mut value[..]) else {
            continue;
        };
        if rustix::fs::fsetxattr(to, name, &value[..len], XattrFlags::empty()).is_err()
            && rustix::fs::fgetxattr(to, name, &mut theirs[..])
                .map_or(true, |l| theirs[..l] != value[..len])
        {
            lost.push(name.to_string_lossy().into_owned());
        }
    }
    lost
}

fn write_all(fd: BorrowedFd<'_>, mut bytes: &[u8]) -> Result<(), Errno> {
    while !bytes.is_empty() {
        match rustix::io::write(fd, bytes) {
            Ok(0) => return Err(Errno::IO),
            Ok(n) => bytes = &bytes[n..],
            Err(Errno::INTR) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// The write of KIND to REAL (resolved, inside ROOT) over the session's read SERVED: atomic, its form and attributes
/// kept, RECORD told the bytes before the rename.  The new canonical text, or why not (and then nothing is left
/// behind).  Blocking.
pub fn write(
    root: &Path,
    real: &Path,
    served: Option<&Served>,
    kind: &WriteKind,
    record: Option<Record>,
) -> Result<String, Refusal> {
    let mut new = String::new();
    replace(
        root,
        real,
        |raw| {
            let raw = raw
                .map(|b| {
                    std::str::from_utf8(b).map_err(|_| {
                        Refusal(format!(
                            "{}: not UTF-8 text; it is not written",
                            real.display()
                        ))
                    })
                })
                .transpose()?;
            new = plan(raw, served, kind)?;
            let form = raw.map(Form::of).unwrap_or_default();
            Ok(form.render(&new).into_bytes())
        },
        record,
        CHANGED,
    )
    .map(|lost| {
        if !lost.is_empty() {
            tracing::info!(file = %real.display(), "a pair write did not keep: {}", lost.join(", "));
        }
    })?;
    Ok(new)
}

/// The bytes of REAL (resolved, inside ROOT) replaced by what MAKE gives for its bytes now (none: it does not exist),
/// atomically, its mode, owner and attributes kept, RECORD told the bytes before the rename.  Just before the rename
/// the name is looked at once more: a file that is not the one read (another inode, size or change time) refuses
/// with RACED, and nothing is written.  Why not, else the names of the attributes not kept (`copy_xattrs`); a refusal
/// leaves nothing behind.  Blocking.
pub fn replace(
    root: &Path,
    real: &Path,
    make: impl FnOnce(Option<&[u8]>) -> Result<Vec<u8>, Refusal>,
    record: Option<Record>,
    raced: &str,
) -> Result<Vec<String>, Refusal> {
    let root = root
        .canonicalize()
        .map_err(|e| io(&root.display().to_string(), e))?;
    let rel = real
        .strip_prefix(&root)
        .map_err(|_| Refusal(format!("{}: outside your project", real.display())))?;
    let mut names: Vec<&OsStr> = Vec::new();
    for c in rel.components() {
        match c {
            Component::Normal(n) => names.push(n),
            _ => return Err(Refusal(format!("{}: not a plain path", real.display()))),
        }
    }
    let Some(name) = names.pop() else {
        return Err(Refusal("the path names no file".into()));
    };
    let root_fd = eitri::open_path(&root, eitri::Kind::Dir).map_err(|e| io("the checkout", e))?;
    // every check before anything is made: the parent as it is, the file, its text and the plan
    let mut none = Vec::new();
    let parent = folders(root_fd.fd.as_fd(), &names, false, &mut none)?;
    let old = match &parent {
        None => None,
        Some(p) => match rustix::fs::openat(
            p.as_fd(),
            name,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK | OFlags::NOCTTY,
            Mode::empty(),
        ) {
            Ok(fd) => Some(fd),
            Err(Errno::NOENT) => None,
            Err(Errno::LOOP) => {
                return Err(Refusal(format!(
                    "{}: a link that names nothing inside your project; it is not written",
                    real.display()
                )));
            }
            Err(e) => return Err(io(&real.display().to_string(), e)),
        },
    };
    let (raw, st) = match &old {
        None => (None, None),
        Some(fd) => {
            let st = rustix::fs::fstat(fd).map_err(|e| io(&real.display().to_string(), e))?;
            if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile {
                return Err(Refusal(format!("{}: not a regular file", real.display())));
            }
            let mut f = std::fs::File::from(
                rustix::io::fcntl_dupfd_cloexec(fd, 0).map_err(|e| io("the file", e))?,
            );
            let mut buf = Vec::new();
            std::io::Read::read_to_end(&mut f, &mut buf)
                .map_err(|e| io(&real.display().to_string(), e))?;
            (Some(buf), Some(st))
        }
    };
    let bytes = make(raw.as_deref())?;
    // the checks passed: the folders, the temporary file, its attributes, the record, the rename
    let mut made = Vec::new();
    let done = (|| -> Result<Vec<String>, Refusal> {
        let parent = match parent {
            Some(p) => p,
            None => folders(root_fd.fd.as_fd(), &names, true, &mut made)?
                .ok_or_else(|| Refusal("a folder could not be made".into()))?,
        };
        let mode = st.as_ref().map_or(0o666, |s| s.st_mode & 0o7777);
        let tmp = temp_name();
        let fd = rustix::fs::openat(
            parent.as_fd(),
            tmp.as_str(),
            OFlags::WRONLY
                | OFlags::CREATE
                | OFlags::EXCL
                | OFlags::NOFOLLOW
                | OFlags::CLOEXEC
                | OFlags::NOCTTY,
            Mode::from_raw_mode(mode & 0o777),
        )
        .map_err(|e| io(&real.display().to_string(), e))?;
        let mut lost = Vec::new();
        let rest = (|| -> Result<(), Refusal> {
            write_all(fd.as_fd(), &bytes).map_err(|e| io("the write", e))?;
            if let (Some(st), Some(old)) = (&st, &old) {
                if rustix::fs::fchown(
                    &fd,
                    Some(rustix::fs::Uid::from_raw(st.st_uid)),
                    Some(rustix::fs::Gid::from_raw(st.st_gid)),
                )
                .is_err()
                {
                    tracing::info!("a pair write keeps the hub's owner: it may not set the file's");
                }
                rustix::fs::fchmod(&fd, Mode::from_raw_mode(mode))
                    .map_err(|e| io("the mode", e))?;
                lost = copy_xattrs(old.as_fd(), fd.as_fd());
            }
            rustix::fs::fsync(&fd).map_err(|e| io("the write", e))?;
            // the name once more, just before the rename: still the file read (or still none)
            let now = rustix::fs::statat(parent.as_fd(), name, AtFlags::SYMLINK_NOFOLLOW).ok();
            let same = match (&st, &now) {
                (None, None) => true,
                (Some(a), Some(b)) => {
                    (a.st_dev, a.st_ino, a.st_size, a.st_mtime, a.st_mtime_nsec)
                        == (b.st_dev, b.st_ino, b.st_size, b.st_mtime, b.st_mtime_nsec)
                }
                _ => false,
            };
            if !same {
                return Err(Refusal(raced.to_string()));
            }
            if let Some(r) = record {
                r(real, &bytes);
            }
            rustix::fs::renameat(parent.as_fd(), tmp.as_str(), parent.as_fd(), name)
                .map_err(|e| io(&real.display().to_string(), e))
        })();
        if rest.is_err() {
            let _ = rustix::fs::unlinkat(parent.as_fd(), tmp.as_str(), AtFlags::empty());
        }
        rest.map(|()| lost)
    })();
    match done {
        Ok(lost) => Ok(lost),
        Err(e) => {
            unmake(made);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(text: &str) -> Served {
        Served {
            text: text.into(),
            version: None,
        }
    }

    fn whole(c: &str) -> WriteKind {
        WriteKind::Whole { content: c.into() }
    }

    /// [D] A file whose disk text is not the session's last read is refused, and so is one it never read; a file that
    /// does not exist is created by a whole-file write without a read.
    #[test]
    fn hash_precondition_refuses_a_changed_file() {
        let r = plan(Some("b\n"), Some(&read("a\n")), &whole("c\n")).unwrap_err();
        assert_eq!(r.0, CHANGED);
        let r = plan(Some("a\n"), None, &whole("c\n")).unwrap_err();
        assert_eq!(r.0, UNREAD);
        assert_eq!(plan(None, None, &whole("c\n")).unwrap(), "c\n");
        assert_eq!(
            plan(Some("a\n"), Some(&read("a\n")), &whole("c\n")).unwrap(),
            "c\n"
        );
        let edit = WriteKind::Edit {
            old: "a".into(),
            new: "z".into(),
        };
        assert!(plan(Some("b\n"), Some(&read("a\n")), &edit).is_err());
        assert_eq!(plan(Some("a\n"), Some(&read("a\n")), &edit).unwrap(), "z\n");
    }

    /// [D] CRLF line ends and a BOM are kept: the read (served raw from disk, or canonical from an editor) matches the
    /// disk whatever its line ends, and the new text goes back in the file's form.
    #[test]
    fn crlf_and_bom_are_kept() {
        let disk = "\u{feff}one\r\ntwo\r\n";
        let f = Form::of(disk);
        assert_eq!(
            f,
            Form {
                bom: true,
                crlf: true
            }
        );
        let new = plan(Some(disk), Some(&read("one\ntwo\n")), &whole("one\nTWO\n")).unwrap();
        assert_eq!(f.render(&new), "\u{feff}one\r\nTWO\r\n");
        let edit = WriteKind::Edit {
            old: "one\r\ntwo".into(),
            new: "1\n2".into(),
        };
        let new = plan(Some(disk), Some(&read(disk)), &edit).unwrap();
        assert_eq!(f.render(&new), "\u{feff}1\r\n2\r\n");
        assert_eq!(Form::of("a\nb\r\n"), Form::default());
    }

    fn xattr(f: &Path, name: &str) -> Option<Vec<u8>> {
        let mut v = vec![0u8; 1 << 12];
        let n = rustix::fs::getxattr(f, name, &mut v[..]).ok()?;
        Some(v[..n].to_vec())
    }

    /// [D] A replaced file keeps the old one's attributes: its SELinux context is the same after the write (a
    /// confined hub may not set it, but the new file already has it: not reported as lost), a user attribute is
    /// copied, and nothing is reported lost.
    #[test]
    fn attributes_are_kept_and_only_real_losses_reported() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        let f = root.join("a.txt");
        std::fs::write(&f, "one\n").unwrap();
        let user = rustix::fs::setxattr(&f, "user.drgnx", b"1", XattrFlags::empty()).is_ok();
        let label = xattr(&f, "security.selinux");
        let lost = replace(&root, &f, |_| Ok(b"two\n".to_vec()), None, "raced").unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "two\n");
        assert_eq!(
            xattr(&f, "security.selinux"),
            label,
            "the SELinux context changed"
        );
        if user {
            assert_eq!(xattr(&f, "user.drgnx").as_deref(), Some(&b"1"[..]));
        }
        assert!(lost.is_empty(), "{lost:?}");
    }

    /// [D] Missing folders are made inside the checkout, never for a path outside it.
    #[test]
    fn parent_folders_are_created_inside_the_checkout_only() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        std::fs::create_dir(root.join("co")).unwrap();
        let co = root.join("co");
        let f = co.join("x/y/new.txt");
        assert_eq!(write(&co, &f, None, &whole("hi\n"), None).unwrap(), "hi\n");
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "hi\n");
        let out = root.join("out/new.txt");
        assert!(write(&co, &out, None, &whole("hi\n"), None).is_err());
        assert!(
            !root.join("out").exists(),
            "nothing made outside the checkout"
        );
    }

    /// [D] A write that fails after its folders were made (a name too long for the file system) removes them; a
    /// refused write (an edit of a file that does not exist) makes none.
    #[test]
    fn a_failed_write_removes_the_folders_it_made() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        let long = "n".repeat(300);
        let f = root.join("a/b").join(&long);
        assert!(write(&root, &f, None, &whole("x\n"), None).is_err());
        assert!(!root.join("a").exists(), "the folders it made are gone");
        let edit = WriteKind::Edit {
            old: "a".into(),
            new: "b".into(),
        };
        assert!(write(&root, &root.join("c/d.txt"), None, &edit, None).is_err());
        assert!(!root.join("c").exists());
        let names: Vec<_> = std::fs::read_dir(&root).unwrap().collect();
        assert!(names.is_empty(), "nothing left behind: {names:?}");
    }
}
