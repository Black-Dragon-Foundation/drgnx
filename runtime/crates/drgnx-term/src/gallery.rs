//! A terminal's images on the worker's side (docs/develop/terminal.md, "Images"): sixel and iTerm2 sequences cut out of
//! the output and decoded on one helper thread while the bytes after them wait; the canvas files the rows show; the
//! files' lifetime; the settings.

use crate::engine::Engine;
use crate::image::{self, At, Cutter, Iterm, ItermArgs, Piece, Pixels, Placement};
use crate::rows::Key;
use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc;

/// The text property a row's image slice rides on: `[file x y w h alt]` (file "": ALT shows instead, on the
/// placement's first row: y 0).
pub const IMAGE_PROP: &str = "drgnx-term-image";
/// The most output bytes queued behind a decode; past it the loop stops reading the PTY (the kernel's back-pressure).
pub const QUEUE_MAX: usize = 1 << 20;

/// Settings (`drgnx-term-image-*`).
#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub storage_limit: u64,
    pub file_medium: bool,
    pub max_bytes: usize,
    pub disk_max: u64,
    pub fps: f64,
    pub remote: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            storage_limit: 64 << 20,
            file_medium: false,
            max_bytes: 32 << 20,
            disk_max: 256 << 20,
            fps: 10.0,
            remote: false,
        }
    }
}

/// One row's part of a placement: the cells COL0..COL1 show the canvas FILE's rectangle (X, Y, W, H), or ALT.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Slice {
    pub col0: u32,
    pub col1: u32,
    pub file: String,
    pub rect: (u32, u32, u32, u32),
    pub alt: String,
}

impl Slice {
    pub fn value(&self) -> serde_json::Value {
        serde_json::json!([
            self.file,
            self.rect.0,
            self.rect.1,
            self.rect.2,
            self.rect.3,
            self.alt
        ])
    }
}

/// What a canvas is drawn from: its file is written once per key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CanvasKey {
    image: u32,
    generation: u64,
    cols: u32,
    rows: u32,
    offset: (u32, u32),
    px: (u32, u32),
    source: (u32, u32, u32, u32),
    cell: (u32, u32),
}

impl CanvasKey {
    fn of(p: &Placement, cell: (u32, u32)) -> CanvasKey {
        CanvasKey {
            image: p.image,
            generation: p.generation,
            cols: p.cols,
            rows: p.rows,
            offset: p.offset,
            px: p.px,
            source: p.source,
            cell,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Canvas {
    Pending,
    Ready { file: String, bytes: u64, seq: u64 },
    Refused,
}

enum Job {
    Sixel {
        params: Vec<u8>,
        data: Vec<u8>,
        at: At,
    },
    Iterm {
        args: ItermArgs,
        data: Vec<u8>,
        at: At,
    },
    Canvas {
        key: CanvasKey,
        placement: Placement,
        image: Pixels,
        path: PathBuf,
        cap: u64,
    },
}

enum Done {
    /// A decoded sequence: the engine's bytes, or why it was refused.
    Engine(Result<Vec<u8>, String>),
    Canvas {
        key: CanvasKey,
        bytes: Option<u64>,
    },
}

fn work(job: Job) -> Done {
    match job {
        Job::Sixel { params, data, at } => Done::Engine(
            image::decode_sixel(&params, &data, at.cap).map(|p| image::sixel_bytes(&p, &at)),
        ),
        Job::Iterm { args, data, at } => {
            Done::Engine(image::decode_iterm(&args, &data, &at).map(|p| image::kitty_command(&p)))
        }
        Job::Canvas {
            key,
            placement,
            image,
            path,
            cap,
        } => {
            let bytes = image::canvas(&placement, &image, key.cell, cap).and_then(|c| {
                let png = image::encode_png(&c);
                write_private(&path, &png).ok().map(|_| png.len() as u64)
            });
            Done::Canvas { key, bytes }
        }
    }
}

/// Write BYTES to PATH, mode 0600, through a rename (Emacs never reads half a file).
fn write_private(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(bytes)?;
    std::fs::rename(&tmp, path)
}

/// The one helper thread: jobs in, results out in order, a byte on WAKE per result.
struct Helper {
    jobs: mpsc::Sender<Job>,
    done: mpsc::Receiver<Done>,
    wake: UnixStream,
}

impl Helper {
    fn start() -> std::io::Result<Helper> {
        let (wake, ping) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        let (jobs, jobs_rx) = mpsc::channel::<Job>();
        let (done_tx, done) = mpsc::channel::<Done>();
        std::thread::Builder::new()
            .name("images".into())
            .spawn(move || {
                let mut ping = ping;
                for job in jobs_rx {
                    if done_tx.send(work(job)).is_err() {
                        break;
                    }
                    let _ = ping.write_all(&[1]);
                }
            })?;
        Ok(Helper { jobs, done, wake })
    }
}

enum Queued {
    Bytes(Vec<u8>),
    Sixel { params: Vec<u8>, data: Vec<u8> },
    Iterm(ItermArgs, Vec<u8>),
}

/// The memory a terminal's scope may use (`memory.max` of its cgroup), when there is one.
fn memory_max() -> Option<u64> {
    let cg = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    let path = cg.lines().find_map(|l| l.strip_prefix("0::"))?;
    std::fs::read_to_string(format!("/sys/fs/cgroup{path}/memory.max"))
        .ok()?
        .trim()
        .parse()
        .ok()
}

pub struct Gallery {
    pub settings: Settings,
    cutter: Cutter,
    iterm: Iterm,
    helper: Option<Helper>,
    /// A decode in flight: the output after it waits in QUEUE.
    waiting: bool,
    queue: VecDeque<Queued>,
    queued: usize,
    dir: Option<PathBuf>,
    canvases: HashMap<CanvasKey, Canvas>,
    seq: u64,
    disk: u64,
    memory_max: Option<u64>,
    /// The slices each row the editor holds was sent with, and that row (to send it again with an evicted file's alt).
    sent: HashMap<Key, (Vec<Slice>, drgnx_rows::Row)>,
    /// Files no row names any more, each with the patch version that dropped the last one: deleted once acked.
    dropping: Vec<(u64, String)>,
    /// When the next animation frame is due, and when the last one was drawn.
    pub animation_due: Option<u64>,
    pub animation_last: Option<u64>,
    /// Whether a window shows the terminal (`term/visible`): animations advance only then.
    pub visible: bool,
    /// The slices each engine row was last drawn with, for a backfill of rows that scrolled past unseen; the oldest
    /// of `SEEN_MAX` go first.
    seen: HashMap<crate::rows::RowId, Vec<Slice>>,
    seen_order: VecDeque<crate::rows::RowId>,
}

/// The most engine rows whose slices are remembered.
const SEEN_MAX: usize = 4096;

impl Gallery {
    /// Images written into DIR (none: images are not drawn, only stored).
    pub fn new(dir: Option<PathBuf>) -> Gallery {
        let settings = Settings::default();
        Gallery {
            cutter: Cutter::new(settings.max_bytes),
            settings,
            iterm: Iterm::default(),
            helper: None,
            waiting: false,
            queue: VecDeque::new(),
            queued: 0,
            dir,
            canvases: HashMap::new(),
            seq: 0,
            disk: 0,
            memory_max: memory_max(),
            sent: HashMap::new(),
            dropping: Vec::new(),
            animation_due: None,
            animation_last: None,
            visible: true,
            seen: HashMap::new(),
            seen_order: VecDeque::new(),
        }
    }

    /// The decode cap: the storage limit, and a quarter of the scope's memory.
    pub fn cap(&self) -> u64 {
        let m = self.memory_max.map_or(u64::MAX, |m| m / 4);
        self.settings.storage_limit.min(m)
    }

    /// The engine's image settings from these settings: direct data always; temporary files and shared memory on a
    /// local terminal; any file only when the setting allows it, never on a remote one.
    pub fn apply(&mut self, engine: &mut Engine) {
        let s = &self.settings;
        let temp = std::env::temp_dir();
        let temp = (!s.remote).then(|| temp.to_string_lossy().into_owned());
        engine.set_images(
            s.storage_limit,
            temp.as_deref(),
            !s.remote,
            s.file_medium && !s.remote,
        );
        crate::engine::set_decode_cap(self.cap());
        self.cutter.set_max(s.max_bytes);
    }

    /// The socket the loop polls for finished helper work.
    pub fn wake(&self) -> Option<&UnixStream> {
        self.helper.as_ref().map(|h| &h.wake)
    }

    /// Whether the loop should read more output (not while a decode holds a full queue).
    pub fn wants_output(&self) -> bool {
        self.queued < QUEUE_MAX
    }

    /// The program's output: bytes to ENGINE, images cut out and decoded in order.
    pub fn output(&mut self, bytes: &[u8], engine: &mut Engine) {
        let mut pieces: Vec<Queued> = Vec::new();
        let max = self.settings.max_bytes;
        let waiting = self.waiting;
        let iterm = &mut self.iterm;
        self.cutter.feed(bytes, |p| match p {
            Piece::Pass(b) => {
                if !waiting && pieces.is_empty() {
                    engine.write(b);
                } else {
                    pieces.push(Queued::Bytes(b.to_vec()));
                }
            }
            Piece::Sixel { params, data } => pieces.push(Queued::Sixel { params, data }),
            Piece::Iterm(seq) => {
                if let Some((args, data)) = iterm.take(&seq, max) {
                    pieces.push(Queued::Iterm(args, data));
                }
            }
            Piece::TooLong => {
                tracing::info!(max, "an image sequence over image-max-bytes: dropped")
            }
        });
        for q in pieces {
            if let Queued::Bytes(b) = &q {
                self.queued += b.len();
            }
            self.queue.push_back(q);
        }
        self.drain(engine);
    }

    /// Send queued output to ENGINE until a sequence must be decoded.
    fn drain(&mut self, engine: &mut Engine) {
        while !self.waiting {
            let Some(q) = self.queue.pop_front() else {
                return;
            };
            let at = || {
                let (cols, rows, cell) = engine.size();
                At {
                    cell,
                    cols,
                    rows,
                    col: engine.cursor_col(),
                    cap: self.cap(),
                }
            };
            let job = match q {
                Queued::Bytes(b) => {
                    self.queued -= b.len();
                    engine.write(&b);
                    continue;
                }
                Queued::Sixel { params, data } => Job::Sixel {
                    params,
                    data,
                    at: at(),
                },
                Queued::Iterm(args, data) => Job::Iterm {
                    args,
                    data,
                    at: at(),
                },
            };
            if self.submit(job) {
                self.waiting = true;
            }
        }
    }

    fn submit(&mut self, job: Job) -> bool {
        if self.helper.is_none() {
            match Helper::start() {
                Ok(h) => self.helper = Some(h),
                Err(e) => {
                    tracing::warn!(error = %e, "no image helper: images are dropped");
                    return false;
                }
            }
        }
        self.helper
            .as_ref()
            .is_some_and(|h| h.jobs.send(job).is_ok())
    }

    /// Take the helper's finished work (the loop saw WAKE, or a test waits with BLOCK): decoded images go to ENGINE
    /// and the output behind them follows. True when what to draw changed.
    pub fn collect(&mut self, engine: &mut Engine, block: bool) -> bool {
        let Some(h) = &mut self.helper else {
            return false;
        };
        let mut sink = [0u8; 64];
        while matches!(h.wake.read(&mut sink), Ok(n) if n > 0) {}
        let mut done = Vec::new();
        if block && let Ok(d) = h.done.recv() {
            done.push(d);
        }
        while let Ok(d) = h.done.try_recv() {
            done.push(d);
        }
        let changed = !done.is_empty();
        for d in done {
            match d {
                Done::Engine(r) => {
                    match r {
                        Ok(bytes) => engine.write(&bytes),
                        Err(why) => tracing::info!(%why, "an image refused"),
                    }
                    self.waiting = false;
                    self.drain(engine);
                }
                Done::Canvas { key, bytes } => {
                    let entry = match bytes {
                        Some(bytes) => {
                            self.seq += 1;
                            self.disk += bytes;
                            Canvas::Ready {
                                file: self.file_of(&key),
                                bytes,
                                seq: self.seq,
                            }
                        }
                        None => {
                            tracing::info!(image = key.image, "a canvas refused (over the limit)");
                            Canvas::Refused
                        }
                    };
                    self.canvases.insert(key, entry);
                }
            }
        }
        changed
    }

    /// Whether the helper has work out (a test waits for it).
    pub fn busy(&self) -> bool {
        self.waiting || self.canvases.values().any(|c| *c == Canvas::Pending)
    }

    fn file_of(&self, key: &CanvasKey) -> String {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        key.hash(&mut h);
        let name = format!("{:016x}.png", h.finish());
        self.dir.as_ref().map_or(name.clone(), |d| {
            d.join(&name).to_string_lossy().into_owned()
        })
    }

    /// The slices of the placements ENGINE captured, by viewport row (from -ABOVE): ready canvases drawn, missing ones
    /// asked of the helper, refused ones shown by their alt on their first row.
    pub fn slices(&mut self, engine: &mut Engine, above: i32) -> HashMap<i32, Vec<Slice>> {
        let mut out: HashMap<i32, Vec<Slice>> = HashMap::new();
        if self.dir.is_none() {
            return out;
        }
        let (cols_n, rows_n, cell) = engine.size();
        if cell.0 == 0 || cell.1 == 0 {
            return out;
        }
        for p in engine.placements() {
            let key = CanvasKey::of(&p, cell);
            let alt = format!("[image {}×{}]", p.px.0, p.px.1);
            let file = match self.canvases.get(&key) {
                Some(Canvas::Ready { file, .. }) => Some(file.clone()),
                Some(Canvas::Pending) => continue,
                Some(Canvas::Refused) => None,
                None => {
                    let Some(pixels) = engine.image(p.image) else {
                        continue;
                    };
                    let path = PathBuf::from(self.file_of(&key));
                    if let Some(d) = &self.dir
                        && let Err(e) = make_private_dir(d)
                    {
                        tracing::warn!(error = %e, "no image directory: images are not drawn");
                        self.dir = None;
                        return HashMap::new();
                    }
                    let cap = self.cap();
                    let job = Job::Canvas {
                        key,
                        placement: p,
                        image: pixels,
                        path,
                        cap,
                    };
                    if self.submit(job) {
                        self.canvases.insert(key, Canvas::Pending);
                    }
                    continue;
                }
            };
            let c0 = p.col.max(0) as u32;
            let c1 = (p.col + p.cols as i32).clamp(0, cols_n as i32) as u32;
            if c0 >= c1 {
                continue;
            }
            for r in 0..p.rows as i32 {
                let y = p.row + r;
                if y < -above || y >= rows_n as i32 {
                    continue;
                }
                let slice = match &file {
                    Some(f) => Slice {
                        col0: c0,
                        col1: c1,
                        file: f.clone(),
                        rect: (
                            (c0 as i32 - p.col) as u32 * cell.0,
                            r as u32 * cell.1,
                            (c1 - c0) * cell.0,
                            cell.1,
                        ),
                        alt: alt.clone(),
                    },
                    None if r == 0 => Slice {
                        col0: c0,
                        col1: c1,
                        file: String::new(),
                        rect: (0, 0, 0, 0),
                        alt: alt.clone(),
                    },
                    None => continue,
                };
                // a higher placement (later: they come lowest z first) covers what it overlaps
                let row = out.entry(y).or_default();
                row.retain(|s| s.col1 <= slice.col0 || s.col0 >= slice.col1);
                row.push(slice);
            }
        }
        for v in out.values_mut() {
            v.sort_by_key(|s| s.col0);
        }
        out
    }

    /// Engine row ID was drawn with SLICES.
    pub fn seen(&mut self, id: crate::rows::RowId, slices: &[Slice]) {
        if self.seen.insert(id, slices.to_vec()).is_none() {
            self.seen_order.push_back(id);
            if self.seen_order.len() > SEEN_MAX
                && let Some(old) = self.seen_order.pop_front()
            {
                self.seen.remove(&old);
            }
        }
    }

    /// The slices engine row ID was last drawn with; a slice whose file went shows its alt.
    pub fn seen_slices(&self, id: &crate::rows::RowId) -> Vec<Slice> {
        let live: HashSet<&str> = self
            .canvases
            .values()
            .filter_map(|c| match c {
                Canvas::Ready { file, .. } => Some(file.as_str()),
                _ => None,
            })
            .collect();
        let mut v = self.seen.get(id).cloned().unwrap_or_default();
        for s in &mut v {
            if !live.contains(s.file.as_str()) {
                s.file.clear();
            }
        }
        v
    }

    /// The slices row KEY was last sent with.
    pub fn sent(&self, key: &str) -> &[Slice] {
        self.sent.get(key).map_or(&[], |v| v.0.as_slice())
    }

    /// ROW goes with SLICES in patch VERSION.
    pub fn note(&mut self, row: &drgnx_rows::Row, slices: &[Slice], version: u64) {
        let old = if slices.is_empty() {
            self.sent.remove(&row.key)
        } else {
            self.sent
                .insert(row.key.clone(), (slices.to_vec(), row.clone()))
        };
        if let Some((old, _)) = old {
            self.release(old, version);
        }
    }

    /// Rows KEYS left the editor's buffer in patch VERSION.
    pub fn gone(&mut self, keys: &[Key], version: u64) {
        for k in keys {
            if let Some((old, _)) = self.sent.remove(k) {
                self.release(old, version);
            }
        }
    }

    /// The editor's buffer was replaced (a reset) in patch VERSION.
    pub fn reset(&mut self, version: u64) {
        let all: Vec<Slice> = self.sent.drain().flat_map(|(_, v)| v.0).collect();
        self.release(all, version);
    }

    fn release(&mut self, slices: Vec<Slice>, version: u64) {
        let named: HashSet<&str> = self
            .sent
            .values()
            .flat_map(|v| &v.0)
            .map(|s| s.file.as_str())
            .collect();
        let mut drop: Vec<String> = slices
            .into_iter()
            .map(|s| s.file)
            .filter(|f| !f.is_empty() && !named.contains(f.as_str()))
            .collect();
        drop.sort();
        drop.dedup();
        self.dropping.extend(drop.into_iter().map(|f| (version, f)));
    }

    /// The editor applied patch VERSION: files no row names since then are deleted.
    pub fn acked(&mut self, version: u64) {
        let named: HashSet<String> = self
            .sent
            .values()
            .flat_map(|v| &v.0)
            .map(|s| s.file.clone())
            .collect();
        let (due, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut self.dropping)
            .into_iter()
            .partition(|(v, _)| *v <= version);
        self.dropping = keep;
        for (_, f) in due {
            if !named.contains(&f) {
                self.delete(&f);
            }
        }
    }

    fn delete(&mut self, file: &str) {
        let _ = std::fs::remove_file(file);
        let disk = &mut self.disk;
        self.canvases.retain(|_, c| match c {
            Canvas::Ready { file: f, bytes, .. } if f == file => {
                *disk = disk.saturating_sub(*bytes);
                false
            }
            _ => true,
        });
    }

    /// Over `image-disk-max`: the oldest files no screen row shows are deleted; the rows above the screen that named
    /// one are given back, showing that file's alt.
    pub fn evict(&mut self, on_screen: &HashSet<String>) -> Vec<drgnx_rows::Row> {
        let mut changed = Vec::new();
        while self.disk > self.settings.disk_max {
            let oldest = self
                .canvases
                .values()
                .filter_map(|c| match c {
                    Canvas::Ready { file, seq, .. } if !on_screen.contains(file) => {
                        Some((*seq, file.clone()))
                    }
                    _ => None,
                })
                .min();
            let Some((_, file)) = oldest else { break };
            self.delete(&file);
            for (slices, row) in self.sent.values_mut() {
                if !slices.iter().any(|s| s.file == file) {
                    continue;
                }
                // the alt shows on the placement's first row (rect y 0), as for a refused canvas
                for s in slices.iter_mut().filter(|s| s.file == file) {
                    s.file.clear();
                }
                // the row's image properties are its slices, in order
                let mut it = slices.iter();
                for p in row.props.iter_mut().filter(|p| p.2 == IMAGE_PROP) {
                    if let Some(s) = it.next() {
                        p.3 = s.value();
                    }
                }
                changed.push(row.clone());
            }
        }
        changed
    }
}

fn make_private_dir(d: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(d)?;
    std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))
}

impl Drop for Gallery {
    fn drop(&mut self) {
        if let Some(d) = &self.dir {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}
