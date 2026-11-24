//! Unpacking a downloaded archive safely: only regular files and folders, no entry absolute or climbing, no name twice,
//! files created new, sizes counted as written.  Shared by the browser, the debug adapters and the search engine installs.

use std::collections::HashSet;
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

/// What an install does not go past.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// Bytes of the download.
    pub download: u64,
    /// Bytes of one unpacked file.
    pub entry: u64,
    /// Bytes of everything unpacked.
    pub unpacked: u64,
    pub entries: usize,
}

impl Default for Limits {
    fn default() -> Self {
        const MIB: u64 = 1 << 20;
        Limits {
            download: 512 * MIB,
            entry: 1024 * MIB,
            unpacked: 2048 * MIB,
            entries: 4096,
        }
    }
}

/// Why an install (or an unpack) stopped.
#[derive(Debug, PartialEq, Eq)]
pub enum InstallError {
    /// V is not in the table.
    NotPinned {
        asked: String,
        pinned: Vec<String>,
    },
    /// The platform has no digest yet (or drgnx has no key for this machine).
    PlatformNotPinned(String),
    NotHttps(String),
    Network(String),
    TooLarge(String),
    DigestMismatch {
        expected: String,
        got: String,
    },
    /// An archive entry that is absolute, climbs, links, or is neither a file nor a folder.
    Unsafe(String),
    Archive(String),
    Io(String),
}

impl fmt::Display for InstallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotPinned { asked, pinned } => write!(
                f,
                "version {asked} is not one drgnx knows a digest for (pinned: {})",
                pinned.join(", ")
            ),
            Self::PlatformNotPinned(p) => write!(
                f,
                "this platform ({p}) has no pinned download yet; install a distro package or set \
`drgnx-agents-browser-program`"
            ),
            Self::NotHttps(u) => write!(f, "refusing a download that is not https: {u}"),
            Self::Network(m) => write!(f, "download failed: {m}"),
            Self::TooLarge(m) => write!(f, "too large: {m}"),
            Self::DigestMismatch { expected, got } => write!(
                f,
                "the download's sha256 is {got}, the pin says {expected}; nothing was installed"
            ),
            Self::Unsafe(m) => write!(f, "unsafe archive, nothing was installed: {m}"),
            Self::Archive(m) => write!(f, "bad archive: {m}"),
            Self::Io(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for InstallError {}

/// `InstallError::Io` naming the file WHAT.
pub fn io_err(what: &Path, e: io::Error) -> InstallError {
    InstallError::Io(format!("{}: {e}", what.display()))
}

/// ZIP into DEST.  Only regular files and folders are made; an entry that is absolute, climbs out, links, or repeats a
/// name fails the whole unpack.  Files are created new (never over anything), and sizes are counted as they are
/// written, not as the archive declares them.
pub fn unpack(zip: &Path, dest: &Path, limits: Limits) -> Result<(), InstallError> {
    let file = File::open(zip).map_err(|e| io_err(zip, e))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| InstallError::Archive(e.to_string()))?;
    if archive.len() > limits.entries {
        return Err(InstallError::TooLarge(format!(
            "the archive has {} entries",
            archive.len()
        )));
    }
    let mut seen = HashSet::new();
    let mut total = 0u64;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| InstallError::Archive(e.to_string()))?;
        let raw = String::from_utf8_lossy(entry.name_raw()).into_owned();
        let unsafe_name = || InstallError::Unsafe(format!("entry {raw:?}"));
        // judged on the name as written: the library may normalise an absolute name into a relative one
        if raw.starts_with('/') || raw.split('/').any(|c| c == "..") {
            return Err(unsafe_name());
        }
        let name = entry.enclosed_name().ok_or_else(unsafe_name)?;
        if name.as_os_str().is_empty()
            || name
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
        {
            return Err(unsafe_name());
        }
        let mode = entry.unix_mode().unwrap_or(0);
        match mode & 0o170000 {
            0 | 0o100000 | 0o040000 => {}
            0o120000 => return Err(InstallError::Unsafe(format!("entry {raw:?} is a link"))),
            _ => {
                return Err(InstallError::Unsafe(format!(
                    "entry {raw:?} is not a file or a folder"
                )));
            }
        }
        let target = dest.join(&name);
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|e| io_err(&target, e))?;
            continue;
        }
        if !seen.insert(name.clone()) {
            return Err(InstallError::Unsafe(format!("entry {raw:?} appears twice")));
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
        }
        let perm = if mode & 0o111 != 0 { 0o755 } else { 0o644 };
        let mut out = eitri::create_exclusive(&target, perm)
            .map_err(std::io::Error::from)
            .map_err(|e| io_err(&target, e))?;
        let allowed = limits.entry.min(limits.unpacked - total);
        let n = io::copy(&mut (&mut entry).take(allowed + 1), &mut out)
            .map_err(|e| InstallError::Archive(format!("{raw}: {e}")))?;
        if n > allowed {
            return Err(InstallError::TooLarge(format!(
                "entry {raw:?} passes the unpack limits"
            )));
        }
        total += n;
    }
    Ok(())
}

/// The tar.gz TGZ into DEST, by the zip unpacker's rules: only regular files and folders, no entry absolute or
/// climbing, no name twice, files created new, sizes counted as written.
pub fn unpack_tgz(
    tgz: &Path,
    dest: &Path,
    limits: Limits,
    root: Option<&Path>,
) -> Result<(), InstallError> {
    let file = File::open(tgz).map_err(|e| InstallError::Io(format!("{}: {e}", tgz.display())))?;
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(file));
    let entries = archive
        .entries()
        .map_err(|e| InstallError::Archive(e.to_string()))?;
    let mut seen = std::collections::HashSet::new();
    let mut links: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let (mut total, mut count) = (0u64, 0usize);
    for entry in entries {
        let mut entry = entry.map_err(|e| InstallError::Archive(e.to_string()))?;
        count += 1;
        if count > limits.entries {
            return Err(InstallError::TooLarge(format!(
                "the archive has over {} entries",
                limits.entries
            )));
        }
        let raw = String::from_utf8_lossy(&entry.path_bytes()).into_owned();
        let unsafe_name = || InstallError::Unsafe(format!("entry {raw:?}"));
        if raw.starts_with('/') || raw.split('/').any(|c| c == "..") {
            return Err(unsafe_name());
        }
        let name = PathBuf::from(raw.trim_end_matches('/'));
        if name.as_os_str().is_empty()
            || name
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
        {
            return Err(unsafe_name());
        }
        // nothing is written through a link an earlier entry made: what a link names is then exactly its place in the archive
        if name.ancestors().skip(1).any(|a| links.contains(a)) {
            return Err(InstallError::Unsafe(format!(
                "entry {raw:?} is inside a link"
            )));
        }
        let target = dest.join(&name);
        let kind = entry.header().entry_type();
        if kind.is_dir() {
            fs::create_dir_all(&target)
                .map_err(|e| InstallError::Io(format!("{}: {e}", target.display())))?;
            continue;
        }
        if kind.is_symlink() {
            // a relative link that stays inside the archive's tree (a JDK's `legal/…` files point at each other)
            let to = entry
                .link_name()
                .map_err(|e| InstallError::Archive(e.to_string()))?
                .map(|t| t.into_owned())
                .ok_or_else(|| {
                    InstallError::Unsafe(format!("entry {raw:?} is a link with no target"))
                })?;
            // a link in the folder that becomes the install stays inside it (the rest of the archive is dropped)
            let base = root
                .filter(|r| name.starts_with(r))
                .map_or(0, |r| r.components().count());
            let mut depth =
                name.parent().map_or(0, |p| p.components().count()) as i64 - base as i64;
            // a `..` after a name would be resolved through whatever link that name is (`x/a -> ..`, then `../x/a/..`):
            // only leading `..` are allowed, so no target walks back out through a link
            let mut named = false;
            for c in to.components() {
                match c {
                    Component::Normal(_) => {
                        depth += 1;
                        named = true;
                    }
                    Component::ParentDir if named => {
                        return Err(InstallError::Unsafe(format!(
                            "entry {raw:?} links to {} (a `..` after a name)",
                            to.display()
                        )));
                    }
                    Component::ParentDir => depth -= 1,
                    Component::CurDir => {}
                    _ => {
                        return Err(InstallError::Unsafe(format!(
                            "entry {raw:?} links to {}",
                            to.display()
                        )));
                    }
                }
                if depth < 0 {
                    return Err(InstallError::Unsafe(format!(
                        "entry {raw:?} links out of the archive ({})",
                        to.display()
                    )));
                }
            }
            if !seen.insert(name.clone()) {
                return Err(InstallError::Unsafe(format!("entry {raw:?} appears twice")));
            }
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| InstallError::Io(format!("{}: {e}", parent.display())))?;
            }
            std::os::unix::fs::symlink(&to, &target)
                .map_err(|e| InstallError::Io(format!("{}: {e}", target.display())))?;
            links.insert(name);
            continue;
        }
        if kind.is_hard_link() {
            return Err(InstallError::Unsafe(format!(
                "entry {raw:?} is a hard link"
            )));
        }
        if !kind.is_file() {
            return Err(InstallError::Unsafe(format!(
                "entry {raw:?} is not a file or a folder"
            )));
        }
        if !seen.insert(name.clone()) {
            return Err(InstallError::Unsafe(format!("entry {raw:?} appears twice")));
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| InstallError::Io(format!("{}: {e}", parent.display())))?;
        }
        let mode = entry.header().mode().unwrap_or(0o644);
        let mut out =
            eitri::create_exclusive(&target, if mode & 0o111 != 0 { 0o755 } else { 0o644 })
                .map_err(std::io::Error::from)
                .map_err(|e| InstallError::Io(format!("{}: {e}", target.display())))?;
        let allowed = limits.entry.min(limits.unpacked - total);
        let n = io::copy(&mut (&mut entry).take(allowed + 1), &mut out)
            .map_err(|e| InstallError::Archive(format!("{raw}: {e}")))?;
        if n > allowed {
            return Err(InstallError::TooLarge(format!(
                "entry {raw:?} passes the unpack limits"
            )));
        }
        total += n;
    }
    Ok(())
}
