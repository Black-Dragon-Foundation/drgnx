//! A run file (spec §19.2): `<state>/debug/runs/<run>.drun`, the bulk of a recorded run. Append-only frames (one JSON
//! object a line: a stop with its capture, or a probe hit), gathered into blocks of at most [`BLOCK`] bytes, each
//! compressed with zstd and sealed: `DRUN2\n` and the file's salt, then per block its raw length and its sealed length
//! (u32, little-endian) and the sealed bytes. The index (`<run>.drun.idx`, JSON, sealed, written whole at each block)
//! says where each block starts, the event numbers it holds and the stops in it, so a past stop is read from one block.
//!
//! Sealed: ChaCha20-Poly1305 under the file's key (the keyring's key and the salt, [`super::runkey`]); a file read
//! with another key, or changed, reads as "cannot be read".
//!
//! The file is capped ([`CAP`], 64 MB): past it, the oldest probe hits go first, block by block (the file is written
//! again without them). Stops are never dropped; with no hit left to drop, new hits are dropped instead.

use super::runkey::{FileKey, Key, SALT_LEN};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// A block's raw size before it is written.
pub const BLOCK: usize = 64 * 1024;
/// The largest run file.
pub const CAP: u64 = 64 * 1024 * 1024;
const MAGIC: &[u8] = b"DRUN2\n";
/// The header: the magic and the salt.
const HEAD: usize = MAGIC.len() + SALT_LEN;
const BLOCK_AAD: &[u8] = b"drun block";
const INDEX_AAD: &[u8] = b"drun index";
const LEVEL: i32 = 3;

/// One stop of a run: where the program stopped and how it got there.
///
/// - `index` is the stop's number in the run's event order: every stop and every probe hit takes the next number of
///   one counter, so the hits before stop k are those whose `seq` is below `stops[k].index`.
/// - `thread` is the DAP thread id of the stopping thread.
/// - `bp_hit` (a breakpoint stop): how many times the breakpoint at (`path`, `line`) has stopped in this run, counting
///   this stop (1-based).
/// - `steps`: the step operations in order since the last breakpoint stop (`next`, `in`, `out`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunStop {
    pub index: u64,
    pub t_ms: u64,
    pub reason: String,
    pub thread: i64,
    /// The top frame's file ("" when it has none: a source reference).
    pub path: String,
    /// The top frame's line (0: none).
    pub line: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bp_hit: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<String>,
    /// The session that stopped (the run's own, or a child's).
    #[serde(default)]
    pub session: String,
}

/// One probe hit: the probe, the thread expression's value as text ("" where the language has none), the value's
/// text, and its number in the run's event order (see [`RunStop`]).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunHit {
    pub probe: String,
    pub thread: String,
    pub value: String,
    pub seq: u64,
    #[serde(default)]
    pub t_ms: u64,
}

/// One frame of a run file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "k", rename_all = "lowercase")]
pub enum Frame {
    Stop { stop: RunStop, capture: Value },
    Hit(RunHit),
}

impl Frame {
    pub fn seq(&self) -> u64 {
        match self {
            Frame::Stop { stop, .. } => stop.index,
            Frame::Hit(h) => h.seq,
        }
    }
}

/// Where a block is and what it holds.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct BlockMeta {
    pub off: u64,
    pub len: u32,
    pub raw: u32,
    pub first: u64,
    pub last: u64,
    pub hits: u32,
    /// The `index` of each stop in it.
    pub stops: Vec<u64>,
}

/// The index: the blocks, the stops (in order), and what was dropped.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Index {
    pub blocks: Vec<BlockMeta>,
    pub stops: Vec<RunStop>,
    /// Hits kept, per probe.
    pub hits: std::collections::BTreeMap<String, u64>,
    /// Hits dropped to stay under the cap.
    pub dropped: u64,
}

fn idx_path(path: &Path) -> PathBuf {
    let mut p = path.as_os_str().to_owned();
    p.push(".idx");
    PathBuf::from(p)
}

fn encode(frames: &[Frame]) -> Vec<u8> {
    let mut raw = Vec::new();
    for f in frames {
        if serde_json::to_writer(&mut raw, f).is_ok() {
            raw.push(b'\n');
        }
    }
    raw
}

fn decode(raw: &[u8]) -> Vec<Frame> {
    raw.split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .filter_map(|l| serde_json::from_slice(l).ok())
        .collect()
}

/// A run file being written.
pub struct RunFile {
    path: PathBuf,
    cap: u64,
    size: u64,
    pending: Vec<Frame>,
    pending_raw: usize,
    index: Index,
    /// No hit left to drop and still at the cap: new hits are dropped.
    full: bool,
    key: Arc<FileKey>,
}

impl RunFile {
    /// A new run file at PATH, capped at CAP bytes, sealed under KEY.
    pub fn create(path: &Path, cap: u64, key: &Key) -> std::io::Result<RunFile> {
        if let Some(d) = path.parent() {
            std::fs::create_dir_all(d)?;
        }
        let salt = super::runkey::new_salt();
        let mut head = MAGIC.to_vec();
        head.extend_from_slice(&salt);
        std::fs::write(path, &head)?;
        let f = RunFile {
            path: path.to_owned(),
            cap,
            size: HEAD as u64,
            pending: vec![],
            pending_raw: 0,
            index: Index::default(),
            full: false,
            key: Arc::new(FileKey::new(key, &salt)),
        };
        f.write_index();
        Ok(f)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The file's size on disk.
    pub fn size(&self) -> u64 {
        self.size
    }

    pub fn index(&self) -> &Index {
        &self.index
    }

    /// Append FRAME; a full block is written. False: a hit dropped (the file is full of stops).
    pub fn append(&mut self, frame: Frame) -> bool {
        match &frame {
            Frame::Hit(h) => {
                if self.full {
                    self.index.dropped += 1;
                    return false;
                }
                *self.index.hits.entry(h.probe.clone()).or_default() += 1;
            }
            Frame::Stop { stop, .. } => self.index.stops.push(stop.clone()),
        }
        self.pending_raw += serde_json::to_vec(&frame).map(|v| v.len() + 1).unwrap_or(0);
        self.pending.push(frame);
        if self.pending_raw >= BLOCK {
            self.flush();
        }
        true
    }

    /// Write what is pending as a block (and the index).
    pub fn flush(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let frames = std::mem::take(&mut self.pending);
        self.pending_raw = 0;
        let (meta, bytes) = block(&self.key, &frames, 0);
        if self.size + bytes.len() as u64 > self.cap {
            self.make_room(bytes.len() as u64);
        }
        let mut meta = meta;
        meta.off = self.size;
        match std::fs::OpenOptions::new().append(true).open(&self.path) {
            Ok(mut f) => {
                if let Err(e) = f.write_all(&bytes) {
                    tracing::warn!(target: "drgnx::debug", "run file {}: {e}", self.path.display());
                    return;
                }
            }
            Err(e) => {
                tracing::warn!(target: "drgnx::debug", "run file {}: {e}", self.path.display());
                return;
            }
        }
        self.size += bytes.len() as u64;
        self.index.blocks.push(meta);
        self.write_index();
    }

    fn write_index(&self) {
        let text = serde_json::to_vec(&self.index).unwrap_or_default();
        let sealed = self.key.seal(INDEX_AAD, &text);
        if let Err(e) = write_atomic(&idx_path(&self.path), &sealed) {
            tracing::warn!(target: "drgnx::debug", "run index {}: {e}", self.path.display());
        }
    }

    /// Room for NEED more bytes under the cap: the oldest blocks lose their hits until the file, written again, fits
    /// three quarters of the cap with NEED added. With no hit left, new hits are dropped from now on.
    fn make_room(&mut self, need: u64) {
        let target = self.cap / 4 * 3;
        let Ok(r) = Reader::with(&self.path, self.key.clone()) else {
            return;
        };
        let mut blocks: Vec<Vec<Frame>> = (0..self.index.blocks.len())
            .map(|i| r.block(i).unwrap_or_default())
            .collect();
        let mut sizes: Vec<u64> = self
            .index
            .blocks
            .iter()
            .map(|b| u64::from(b.len) + 8)
            .collect();
        let total = |s: &[u64]| HEAD as u64 + s.iter().sum::<u64>();
        for i in 0..blocks.len() {
            if total(&sizes) + need <= target {
                break;
            }
            let before = blocks[i].len();
            blocks[i].retain(|f| matches!(f, Frame::Stop { .. }));
            let gone = before - blocks[i].len();
            if gone == 0 {
                continue;
            }
            self.index.dropped += gone as u64;
            sizes[i] = block(&self.key, &blocks[i], 0).1.len() as u64;
        }
        if total(&sizes) + need > self.cap {
            self.full = true;
        }
        // written again (the same salt; each block a new nonce): the blocks that still hold frames
        let mut out = r.bytes[..HEAD].to_vec();
        let mut metas = vec![];
        for frames in blocks.iter().filter(|b| !b.is_empty()) {
            let (mut meta, bytes) = block(&self.key, frames, 0);
            meta.off = out.len() as u64;
            out.extend_from_slice(&bytes);
            metas.push(meta);
        }
        let tmp = self.path.with_extension("drun.tmp");
        if std::fs::write(&tmp, &out)
            .and_then(|()| std::fs::rename(&tmp, &self.path))
            .is_err()
        {
            return;
        }
        self.size = out.len() as u64;
        self.index.blocks = metas;
        // the kept hits per probe, counted again
        self.index.hits.clear();
        for f in blocks.iter().flatten() {
            if let Frame::Hit(h) = f {
                *self.index.hits.entry(h.probe.clone()).or_default() += 1;
            }
        }
        for f in &self.pending {
            if let Frame::Hit(h) = f {
                *self.index.hits.entry(h.probe.clone()).or_default() += 1;
            }
        }
    }

    /// Every frame, written or pending, in order.
    pub fn frames(&mut self) -> Vec<Frame> {
        self.flush();
        Reader::with(&self.path, self.key.clone())
            .map(|r| r.frames())
            .unwrap_or_default()
    }
}

/// PATH's bytes written whole: a file beside it, renamed over it.
fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".drgnx-tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

/// FRAMES as one block sealed under KEY: its meta (offset OFF) and its bytes (the header and the sealed, compressed
/// frames).
fn block(key: &FileKey, frames: &[Frame], off: u64) -> (BlockMeta, Vec<u8>) {
    let raw = encode(frames);
    let comp = key.seal(
        BLOCK_AAD,
        &zstd::bulk::compress(&raw, LEVEL).unwrap_or_default(),
    );
    let mut bytes = Vec::with_capacity(comp.len() + 8);
    bytes.extend_from_slice(&u32::try_from(raw.len()).unwrap_or(u32::MAX).to_le_bytes());
    bytes.extend_from_slice(&u32::try_from(comp.len()).unwrap_or(u32::MAX).to_le_bytes());
    bytes.extend_from_slice(&comp);
    let meta = BlockMeta {
        off,
        len: u32::try_from(comp.len()).unwrap_or(u32::MAX),
        raw: u32::try_from(raw.len()).unwrap_or(u32::MAX),
        first: frames.first().map_or(0, Frame::seq),
        last: frames.last().map_or(0, Frame::seq),
        hits: u32::try_from(frames.iter().filter(|f| matches!(f, Frame::Hit(_))).count())
            .unwrap_or(u32::MAX),
        stops: frames
            .iter()
            .filter_map(|f| match f {
                Frame::Stop { stop, .. } => Some(stop.index),
                Frame::Hit(_) => None,
            })
            .collect(),
    };
    (meta, bytes)
}

/// A run file read back, through its index.
pub struct Reader {
    bytes: Vec<u8>,
    pub index: Index,
    key: Arc<FileKey>,
}

/// Why a run file was not read.
#[derive(Debug)]
pub enum Unread {
    /// No file there, or it could not be read from disk.
    Io(std::io::Error),
    /// Not a run file this hub writes, or sealed under another key, or changed.
    Sealed,
}

impl std::fmt::Display for Unread {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Unread::Io(e) => write!(f, "{e}"),
            Unread::Sealed => {
                f.write_str("cannot be read: it was sealed under another key, or changed")
            }
        }
    }
}

impl Reader {
    /// The run file at PATH, its salt read from its header, opened with the keyring's KEY.
    pub fn open(path: &Path, key: &Key) -> Result<Reader, Unread> {
        let head = {
            let mut h = [0u8; HEAD];
            let mut f = std::fs::File::open(path).map_err(Unread::Io)?;
            std::io::Read::read_exact(&mut f, &mut h).map_err(|_| Unread::Sealed)?;
            h
        };
        if !head.starts_with(MAGIC) {
            return Err(Unread::Sealed);
        }
        let salt: [u8; SALT_LEN] = head[MAGIC.len()..].try_into().map_err(|_| Unread::Sealed)?;
        Reader::with(path, Arc::new(FileKey::new(key, &salt)))
    }

    fn with(path: &Path, key: Arc<FileKey>) -> Result<Reader, Unread> {
        let bytes = std::fs::read(path).map_err(Unread::Io)?;
        if !bytes.starts_with(MAGIC) || bytes.len() < HEAD {
            return Err(Unread::Sealed);
        }
        let index: Index = match std::fs::read(idx_path(path)) {
            Ok(sealed) => {
                let text = key.open(INDEX_AAD, &sealed).ok_or(Unread::Sealed)?;
                serde_json::from_slice(&text).map_err(|_| Unread::Sealed)?
            }
            Err(_) => Index::default(),
        };
        Ok(Reader { bytes, index, key })
    }

    /// Block I's frames.
    pub fn block(&self, i: usize) -> Option<Vec<Frame>> {
        let m = self.index.blocks.get(i)?;
        let off = usize::try_from(m.off).ok()?;
        let start = off + 8;
        let end = start + m.len as usize;
        let comp = self.key.open(BLOCK_AAD, self.bytes.get(start..end)?)?;
        let raw = zstd::bulk::decompress(&comp, m.raw as usize).ok()?;
        Some(decode(&raw))
    }

    /// Every frame, in order.
    pub fn frames(&self) -> Vec<Frame> {
        (0..self.index.blocks.len())
            .filter_map(|i| self.block(i))
            .flatten()
            .collect()
    }

    /// The stop numbered INDEX with its capture, from its block alone.
    pub fn stop(&self, index: u64) -> Option<(RunStop, Value)> {
        let b = self
            .index
            .blocks
            .iter()
            .position(|b| b.stops.contains(&index))?;
        self.block(b)?.into_iter().find_map(|f| match f {
            Frame::Stop { stop, capture } if stop.index == index => Some((stop, capture)),
            _ => None,
        })
    }
}
