//! A resumable bundle's receiver (docs/develop/sleipnir.md, "Sync"). When the mirror lacks more than 8 MiB, the hub
//! sends one git bundle in 1 MiB chunks. The runner appends them to `<root>/bundles/<repo>.<sha256>.part`, which
//! survives a drop: after a reconnect the hub resumes from its size. A complete bundle is checked against its sha256,
//! then fetched into the mirror with every object checked. A bundle that fails either check never reaches the mirror.

use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use rustix::fs::FlockOperation;
use sha2::{Digest, Sha256};

use super::mirror::{Mirror, check_id};
use super::{Result, hex, refused};

/// Above this many bytes of missing objects the hub sends a bundle; below, it pushes (design 6.2).
pub const BUNDLE_OVER: u64 = 8 << 20;
/// Bundle chunks are at most this long.
pub const CHUNK: usize = 1 << 20;

/// The bundle the hub declared: its sha256 and size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BundleRef {
    pub sha256: [u8; 32],
    pub size: u64,
}

/// One bundle being received. It holds an exclusive lock on its partial file, so a receiver for a dropped link's
/// leftover process and one for the reconnect never write at once.
pub struct Receiver {
    root: PathBuf,
    repo: String,
    want: BundleRef,
    path: PathBuf,
    file: fs::File,
    offset: u64,
}

impl Receiver {
    /// The receiver for bundle `want` of repository `repo`, resuming its partial file. A partial of another bundle
    /// of the same repository is stale (the hub sends one at a time) and is removed.
    pub fn open(root: &Path, repo: &str, want: BundleRef) -> Result<Receiver> {
        check_id(repo)?;
        let dir = root.join("bundles");
        fs::create_dir_all(&dir)?;
        let name = format!("{repo}.{}.part", hex(&want.sha256));
        let prefix = format!("{repo}.");
        for e in fs::read_dir(&dir)? {
            let e = e?;
            let f = e.file_name();
            let f = f.to_string_lossy();
            // `<repo>.<64 hex>.part`, and not another repository's whose id starts with ours and a dot
            if f != name
                && f.starts_with(&prefix)
                && f.ends_with(".part")
                && f.len() == prefix.len() + 64 + 5
            {
                match fs::remove_file(e.path()) {
                    Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e.into()),
                    _ => {}
                }
            }
        }
        let path = dir.join(&name);
        let file = fs::File::options()
            .read(true)
            .append(true)
            .create(true)
            .open(&path)?;
        rustix::fs::flock(&file, FlockOperation::LockExclusive).map_err(io::Error::from)?;
        let mut offset = file.metadata()?.len();
        if offset > want.size {
            file.set_len(0)?;
            offset = 0;
        }
        Ok(Receiver {
            root: root.to_path_buf(),
            repo: repo.to_string(),
            want,
            path,
            file,
            offset,
        })
    }

    /// The bytes received so far: where the hub resumes.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Appends one chunk; refuses bytes past the declared size.
    pub fn append(&mut self, bytes: &[u8]) -> Result<()> {
        if self.offset + bytes.len() as u64 > self.want.size {
            return Err(refused(
                self.path.as_os_str().as_bytes(),
                "past the bundle's declared size",
            ));
        }
        (&self.file).write_all(bytes)?;
        self.offset += bytes.len() as u64;
        Ok(())
    }

    /// Checks the complete bundle's sha256 and fetches it into the mirror. The partial file is removed, unless the
    /// bundle is not complete yet.
    pub fn finish(self) -> Result<()> {
        let name = self.path.as_os_str().as_bytes();
        if self.offset != self.want.size {
            return Err(refused(name, "the bundle is not complete"));
        }
        self.file.sync_all()?;
        let mut h = Sha256::new();
        let mut f = fs::File::open(&self.path)?;
        let mut buf = vec![0; CHUNK];
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
        }
        let r = if h.finalize()[..] != self.want.sha256[..] {
            Err(refused(name, "the bundle's bytes don't hash to its sha256"))
        } else {
            Mirror::ensure(&self.root, &self.repo).and_then(|m| m.fetch_bundle(&self.path))
        };
        match fs::remove_file(&self.path) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e.into()),
            _ => {}
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::super::SyncError;
    use super::super::testutil::{self, user_git};
    use super::*;

    /// A repository with a commit of `n` bytes no compressor shrinks, its bundle's bytes and the commit.
    fn bundle(t: &Path, n: usize) -> (Vec<u8>, String) {
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        let bytes: Vec<u8> = (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect();
        let (repo, commit) = testutil::repo(t, &[(b"noise", &bytes)]);
        let file = t.join("b.bundle");
        user_git(&repo, &["bundle", "create", file.to_str().unwrap(), "main"]);
        (fs::read(&file).unwrap(), commit)
    }

    fn want(b: &[u8]) -> BundleRef {
        BundleRef {
            sha256: Sha256::digest(b).into(),
            size: b.len() as u64,
        }
    }

    // [D] pure (real git; the drop is a dropped receiver)
    #[test]
    fn bundle_resumes_from_its_size() {
        let t = tempfile::tempdir().unwrap();
        let (b, commit) = bundle(t.path(), 3 * CHUNK);
        let root = t.path().join("runner");
        let w = want(&b);
        let cut = b.len() * 2 / 5;

        let mut r = Receiver::open(&root, "r", w).unwrap();
        assert_eq!(r.offset(), 0);
        r.append(&b[..CHUNK]).unwrap();
        r.append(&b[CHUNK..cut]).unwrap();
        drop(r);

        let mut r = Receiver::open(&root, "r", w).unwrap();
        assert_eq!(r.offset(), cut as u64, "the partial file survives the drop");
        r.append(&b[cut..]).unwrap();
        assert!(
            matches!(r.append(b"x"), Err(SyncError::Refused { .. })),
            "never past the declared size"
        );
        r.finish().unwrap();

        let m = Mirror::ensure(&root, "r").unwrap();
        assert!(m.has_commit(&commit).unwrap());
        assert_eq!(
            fs::read_dir(root.join("bundles")).unwrap().count(),
            0,
            "a fetched bundle's file is removed"
        );

        // another bundle of the same repository starts again: the stale partial goes
        let mut r = Receiver::open(&root, "r", w).unwrap();
        r.append(&b[..10]).unwrap();
        drop(r);
        let other = BundleRef {
            sha256: [7; 32],
            size: 99,
        };
        assert_eq!(Receiver::open(&root, "r", other).unwrap().offset(), 0);
        assert_eq!(fs::read_dir(root.join("bundles")).unwrap().count(), 1);
    }

    // [D] pure (real git)
    #[test]
    fn a_corrupt_bundle_never_reaches_the_mirror() {
        let t = tempfile::tempdir().unwrap();
        let (b, commit) = bundle(t.path(), CHUNK);
        let root = t.path().join("runner");

        // the bytes differ from the declared hash: refused before git sees them
        let mut flipped = b.clone();
        let at = flipped.len() / 2;
        flipped[at] ^= 0x40;
        let mut r = Receiver::open(&root, "r", want(&b)).unwrap();
        r.append(&flipped).unwrap();
        assert!(matches!(r.finish(), Err(SyncError::Refused { .. })));

        // the hash matches the corrupt bytes: git's checks refuse the pack
        let mut r = Receiver::open(&root, "r", want(&flipped)).unwrap();
        r.append(&flipped).unwrap();
        assert!(r.finish().is_err());

        // a bundle that is short is not finished, and stays to be resumed
        let mut r = Receiver::open(&root, "r", want(&b)).unwrap();
        r.append(&b[..100]).unwrap();
        assert!(matches!(r.finish(), Err(SyncError::Refused { .. })));
        assert_eq!(Receiver::open(&root, "r", want(&b)).unwrap().offset(), 100);

        let m = Mirror::ensure(&root, "r").unwrap();
        assert!(
            !m.has_commit(&commit).unwrap(),
            "nothing reached the mirror"
        );
        let refs =
            super::super::git::run("list refs", m.git().cmd(["for-each-ref"]), None).unwrap();
        assert!(refs.is_empty(), "{}", String::from_utf8_lossy(&refs));
    }
}
