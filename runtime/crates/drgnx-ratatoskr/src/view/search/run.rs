//! A run's own records: each file it found matches in, with the run's numbers of those matches (`m:RUN:N`) and the
//! file as the search read it (a snapshot: size, change time, inode, a digest of its bytes); and the remap keys that
//! carry the user's unticks from one run to the next.

use hrafn::grep::Match;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::SystemTime;
use xxhash_rust::xxh3::{Xxh3, xxh3_64};

/// A file larger than this is snapshot without a digest (it is not read whole: a write of it is refused as too large
/// anyway, `docs/guide/large-files.md`).
pub(super) const DIGEST_MAX: u64 = 16 << 20;

/// A file as a run read it: what tells "changed since the search" (`search/edits`, the preview) from a file left alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Snap {
    pub size: u64,
    pub mtime: Option<SystemTime>,
    pub inode: u64,
    /// The 64-bit xxh3 of its bytes; none past [`DIGEST_MAX`].
    pub xxh3: Option<u64>,
    /// The editor buffer's `buffer-chars-modified-tick` when the run searched the buffer's text (`search/buffer`),
    /// not the file.
    pub tick: Option<u64>,
}

/// An editor's buffer of a file with unsaved edits, as `search/buffer` sent it: its text is searched in place of the
/// file's. A buffer over the editor's large-file threshold sends no text (`None`): the file is searched on disk, and
/// its header says the buffer is open in chunks.
#[derive(Clone, Debug)]
pub(super) struct Buffer {
    pub tick: u64,
    pub text: Option<std::sync::Arc<str>>,
}

/// The snapshot of a buffer's TEXT at TICK.
pub(super) fn buffer_snap(tick: u64, text: &str) -> Snap {
    Snap {
        size: text.len() as u64,
        mtime: None,
        inode: 0,
        xxh3: Some(xxh3_64(text.as_bytes())),
        tick: Some(tick),
    }
}

/// FILE's snapshot now; none when it cannot be read.
pub(super) fn snapshot(file: &Path) -> Option<Snap> {
    let meta = std::fs::metadata(file).ok()?;
    #[cfg(unix)]
    let inode = std::os::unix::fs::MetadataExt::ino(&meta);
    #[cfg(not(unix))]
    let inode = 0;
    let xxh3 = if meta.len() <= DIGEST_MAX {
        Some(xxh3_64(&std::fs::read(file).ok()?))
    } else {
        None
    };
    Some(Snap {
        size: meta.len(),
        mtime: meta.modified().ok(),
        inode,
        xxh3,
        tick: None,
    })
}

/// One file's matches in a run: in the order the searcher gave them, each with its number in the run (its id
/// `m:RUN:N`; a file searched again from its buffer gets new numbers, after the run's others), and the file's
/// snapshot.
#[derive(Clone, Debug)]
pub(super) struct Found {
    pub file: String,
    pub ms: Vec<Match>,
    pub ns: Vec<u32>,
    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "recorded now; the edit set reads it to tell a file changed since the search"
        )
    )]
    pub snap: Option<Snap>,
    /// The file's buffer is open in chunks (too large to send): these are the matches on disk.
    pub large: bool,
}

/// The id of match N of run RUN (its node, its row's key).
pub(super) fn match_id(run: u64, n: u32) -> String {
    format!("m:{run}:{n}")
}

/// The run and number of a match id; none for any other key.
pub(super) fn parse_match_id(id: &str) -> Option<(u64, u32)> {
    let (run, n) = id.strip_prefix("m:")?.split_once(':')?;
    Some((run.parse().ok()?, n.parse().ok()?))
}

/// The match M is to the user across runs: its file, its columns and the text around it (not its line, so lines added
/// above it keep it). Two matches of one run with the same key are the same to the user: neither inherits a tick.
pub(super) fn remap_key(m: &Match) -> u64 {
    let mut h = Xxh3::new();
    for part in [
        m.file.as_bytes(),
        m.before.as_bytes(),
        m.text.as_bytes(),
        m.after.as_bytes(),
    ] {
        h.update(&(part.len() as u64).to_le_bytes());
        h.update(part);
    }
    h.update(&m.col.to_le_bytes());
    h.update(&m.end.to_le_bytes());
    h.digest()
}

/// The keys of the matches IDS name among FILES (a run numbered RUN); ids of another run are left out.
pub(super) fn keys_of(run: u64, files: &[Found], ids: &[String]) -> HashSet<u64> {
    let mut want: HashSet<u32> = ids
        .iter()
        .filter_map(|id| parse_match_id(id))
        .filter(|(r, _)| *r == run)
        .map(|(_, n)| n)
        .collect();
    let mut keys = HashSet::new();
    for f in files {
        if want.is_empty() {
            break;
        }
        for (m, n) in f.ms.iter().zip(&f.ns) {
            if want.remove(n) {
                keys.insert(remap_key(m));
            }
        }
    }
    keys
}

/// The ids among FILES (a run numbered RUN) whose key is in KEYS and held by that match alone, in the run's order.
pub(super) fn ids_with(run: u64, files: &[Found], keys: &HashSet<u64>) -> Vec<String> {
    if keys.is_empty() {
        return Vec::new();
    }
    let mut seen: HashMap<u64, Option<u32>> = HashMap::new();
    for f in files {
        for (m, n) in f.ms.iter().zip(&f.ns) {
            let k = remap_key(m);
            if keys.contains(&k) {
                seen.entry(k)
                    .and_modify(|one| *one = None)
                    .or_insert(Some(*n));
            }
        }
    }
    let mut ns: Vec<u32> = seen.into_values().flatten().collect();
    ns.sort_unstable();
    ns.into_iter().map(|n| match_id(run, n)).collect()
}
