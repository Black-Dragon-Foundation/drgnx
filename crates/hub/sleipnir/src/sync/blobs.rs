//! The overlay's blob store on a runner (docs/develop/sleipnir.md, "Sync"): `<root>/blobs/<sha256 hex>`, one file per
//! content hash. The hub sends only the blobs `missing` names; `put` keeps a blob only when its bytes hash to its
//! name, so a slot never checks out bytes other than those captured.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use super::slot::Blobs;
use super::{Result, hex, refused, sha256};

pub struct Store {
    dir: PathBuf,
}

impl Store {
    /// The store under the runner folder `root`, made if it isn't there.
    pub fn open(root: &Path) -> io::Result<Store> {
        let dir = root.join("blobs");
        fs::create_dir_all(&dir)?;
        Ok(Store { dir })
    }

    /// The hashes of `want` the store lacks, each once, in the order asked.
    pub fn missing(&self, want: &[[u8; 32]]) -> Vec<[u8; 32]> {
        let mut out: Vec<[u8; 32]> = Vec::new();
        for sha in want {
            if !out.contains(sha) && fs::symlink_metadata(self.path(sha)).is_err() {
                out.push(*sha);
            }
        }
        out
    }

    /// Keeps `bytes` as the blob `sha`, or refuses them when they hash to something else. The file appears whole or
    /// not at all (written aside, then renamed).
    pub fn put(&self, sha: &[u8; 32], bytes: &[u8]) -> Result<()> {
        if sha256(bytes) != *sha {
            return Err(refused(
                hex(sha).as_bytes(),
                "the bytes don't hash to the blob's name",
            ));
        }
        let tmp = self
            .dir
            .join(format!(".{}.{}.tmp", hex(sha), std::process::id()));
        let mut f = fs::File::options()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&tmp, self.path(sha))?;
        Ok(())
    }
}

impl Blobs for Store {
    fn path(&self, sha256: &[u8; 32]) -> PathBuf {
        self.dir.join(hex(sha256))
    }
}

#[cfg(test)]
mod tests {
    use super::super::SyncError;
    use super::*;

    // [D] pure
    #[test]
    fn a_blob_with_the_wrong_hash_is_refused() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::open(t.path()).unwrap();
        let good = sha256(b"the overlay's bytes\n");
        let other = sha256(b"something else\n");
        assert_eq!(s.missing(&[good, other, good]), vec![good, other]);

        match s.put(&good, b"not those bytes\n") {
            Err(SyncError::Refused { .. }) => {}
            r => panic!("expected a refusal, got {r:?}"),
        }
        assert_eq!(
            s.missing(&[good]),
            vec![good],
            "a refused blob is never kept"
        );
        assert_eq!(
            fs::read_dir(t.path().join("blobs")).unwrap().count(),
            0,
            "nothing is left aside either"
        );

        s.put(&good, b"the overlay's bytes\n").unwrap();
        assert_eq!(s.missing(&[good, other]), vec![other]);
        assert_eq!(fs::read(s.path(&good)).unwrap(), b"the overlay's bytes\n");
    }
}
