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
#[cfg(test)]
pub(super) fn snapshot(file: &Path) -> Option<Snap> {
    read(file, &[], false).map(|r| r.snap)
}

/// Each match's innermost definition (none at the top level), shared by the matches in it.
pub(super) type Ctx = Vec<Option<std::sync::Arc<crate::search::context::Def>>>;

/// What an index mode knows of a match past its text: a definition's kind and signature (Symbol), a hit's score, its
/// share of the best hit's and whether its lines moved since they were indexed (Meaning).
#[derive(Clone, Debug, PartialEq)]
pub(super) enum Mark {
    Def { kind: String, sig: String },
    Score { score: f64, share: f64, moved: bool },
}

/// A file as a run read it for its matches: its snapshot, with context on each match's definition, and an index
/// mode's marks (empty: none).
#[derive(Clone, Debug)]
pub(super) struct Read {
    pub snap: Snap,
    pub ctx: Ctx,
    pub marks: Vec<Option<Mark>>,
}

/// FILE read once for its matches MS: its snapshot, and each match's definition when CONTEXT; none when it cannot be
/// read.
pub(super) fn read(file: &Path, ms: &[Match], context: bool) -> Option<Read> {
    let meta = std::fs::metadata(file).ok()?;
    let bytes = if meta.len() <= DIGEST_MAX {
        Some(std::fs::read(file).ok()?)
    } else {
        None
    };
    let ctx = match (&bytes, context) {
        (Some(b), true) => std::str::from_utf8(b)
            .map(|text| ctx_of(&file.to_string_lossy(), text, ms))
            .unwrap_or_default(),
        _ => Vec::new(),
    };
    Some(Read {
        snap: snap_of(&meta, bytes.as_deref()),
        ctx,
        marks: Vec::new(),
    })
}

/// Each of MS's innermost definition in FILE, whose text is TEXT (`search::context`); empty when it has none.
pub(super) fn ctx_of(file: &str, text: &str, ms: &[Match]) -> Ctx {
    let Some(defs) = crate::search::context::defs(file, text) else {
        return Vec::new();
    };
    let mut last: Option<std::sync::Arc<crate::search::context::Def>> = None;
    ms.iter()
        .map(|m| {
            let d = defs.at(m.line)?;
            match &last {
                Some(l) if l.start == d.start && l.end == d.end => {}
                _ => last = Some(std::sync::Arc::new(d.clone())),
            }
            last.clone()
        })
        .collect()
}

/// The snapshot of a file of META whose bytes are BYTES (none past [`DIGEST_MAX`]).
fn snap_of(meta: &std::fs::Metadata, bytes: Option<&[u8]>) -> Snap {
    #[cfg(unix)]
    let inode = std::os::unix::fs::MetadataExt::ino(meta);
    #[cfg(not(unix))]
    let inode = 0;
    Snap {
        size: meta.len(),
        mtime: meta.modified().ok(),
        inode,
        xxh3: bytes.map(xxh3_64),
        tick: None,
    }
}

/// One file's matches in a run: in the order the searcher gave them, each with its number in the run (its id
/// `m:RUN:N`; a file searched again from its buffer gets new numbers, after the run's others), and the file's
/// snapshot.
#[derive(Clone, Debug)]
pub(super) struct Found {
    pub file: String,
    pub ms: Vec<Match>,
    pub ns: Vec<u32>,
    pub snap: Option<Snap>,
    /// The file's buffer is open in chunks (too large to send): these are the matches on disk.
    pub large: bool,
    /// Each match's definition (empty: none), and how many label rows they give ([`Found::labelled`]).
    pub ctx: Ctx,
    pub labels: usize,
    /// Each match's mark from an index mode (empty: none).
    pub marks: Vec<Option<Mark>>,
}

impl Found {
    /// FILE's matches MS (numbered NS) as READ gives them.
    pub(super) fn new(file: String, ms: Vec<Match>, ns: Vec<u32>, read: Option<Read>) -> Found {
        let (snap, ctx, marks) = match read {
            Some(r) => (Some(r.snap), r.ctx, r.marks),
            None => (None, Vec::new(), Vec::new()),
        };
        let mut f = Found {
            file,
            ms,
            ns,
            snap,
            large: false,
            ctx,
            labels: 0,
            marks,
        };
        f.labels = (0..f.ms.len()).filter(|i| f.labelled(*i).is_some()).count();
        f
    }

    /// Match I's label: its definition when it is the first match of it in a row (the match before is in another).
    pub(super) fn labelled(&self, i: usize) -> Option<&crate::search::context::Def> {
        let d = self.ctx.get(i)?.as_ref()?;
        let before = i.checked_sub(1).and_then(|j| self.ctx.get(j)?.as_ref());
        (!before.is_some_and(|b| std::sync::Arc::ptr_eq(b, d))).then_some(d.as_ref())
    }

    /// The file's rows: its header, its labels and its matches.
    pub(super) fn rows(&self) -> usize {
        1 + self.labels + self.ms.len()
    }
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
