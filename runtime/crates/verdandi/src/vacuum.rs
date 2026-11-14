//! A checked copy of `history.db` for the nightly backup: `VACUUM INTO` a temporary file beside the destination, an
//! integrity check of that file, then a rename over the destination.  A copy that fails leaves nothing behind and the
//! old copy where it was.

use crate::{Error, History, Result};
use rusqlite::{Connection, OpenFlags};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

fn tmp_of(dest: &Path) -> PathBuf {
    let mut t = dest.as_os_str().to_owned();
    t.push(".tmp");
    PathBuf::from(t)
}

/// Copy the database CONN reads to DEST; the bytes of the copy.
fn copy_via(conn: &Connection, dest: &Path) -> Result<u64> {
    if let Some(parent) = dest.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = tmp_of(dest);
    let _ = std::fs::remove_file(&tmp);
    let done = (|| -> Result<u64> {
        let to = tmp
            .to_str()
            .ok_or_else(|| Error::Refused("the backup path is not UTF-8".into()))?;
        conn.execute("vacuum into ?1", [to])?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        let check: String = Connection::open_with_flags(&tmp, OpenFlags::SQLITE_OPEN_READ_ONLY)?
            .query_row("pragma integrity_check", [], |r| r.get(0))?;
        if check != "ok" {
            return Err(Error::Refused(format!(
                "the copy failed its check: {check}"
            )));
        }
        std::fs::rename(&tmp, dest)?;
        Ok(std::fs::metadata(dest)?.len())
    })();
    if done.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    done
}

/// A checked copy of the `history.db` file SRC (nobody need have it open) as DEST.
pub fn vacuum_file(src: &Path, dest: &Path) -> Result<u64> {
    let conn = Connection::open_with_flags(src, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    copy_via(&conn, dest)
}

impl History {
    /// A checked copy of this store as DEST, replacing what is there; the bytes of the copy.
    pub fn vacuum_into(&self, dest: &Path) -> Result<u64> {
        copy_via(&self.conn, dest)
    }
}
