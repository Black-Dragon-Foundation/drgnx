//! Resource telemetry (Task 38; `docs/develop/sleipnir.md`, "Resource telemetry"): the sampler a runner keeps.
//!
//! The [`Engine`] reads the machine's files (`/proc`, a cgroup tree) through descriptors it keeps open (`pread` at
//! offset 0 each tick, one buffer, nothing allocated per sample), for the runner, each slot, each reservation and each
//! job; it feeds stored buckets ([`super::telemetry_store`]) at `store_ms` and the viewers that watch, each at its own
//! rate but never below `live_min_ms`. The engine is pure over an injected clock (`now_ms`) and injected roots, so a
//! test drives it over a fixture tree and a manual clock; [`spawn`] is the thread that drives it for real.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::proto::telemetry::{Level, Marker, Range, Ranged, Sample};

/// The rates the runner keeps (`runner.conf` `[telemetry]`, applied at once).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rates {
    /// Stored window width, ms.
    pub store_ms: u64,
    /// The fastest a viewer may ask, ms.
    pub live_min_ms: u64,
    /// Days of history kept.
    pub keep_days: u64,
    /// How often the disk readings (statvfs) are taken, s.
    pub disk_every_s: u64,
    /// Whether a GPU reader runs.
    pub gpu: bool,
}

impl Default for Rates {
    fn default() -> Rates {
        Rates {
            store_ms: 1000,
            live_min_ms: 5,
            keep_days: 14,
            disk_every_s: 60,
            gpu: true,
        }
    }
}

impl Rates {
    /// The rates in a `runner.conf`'s `[telemetry]` table (`key = number`, `gpu = true|false`); what is not there, or
    /// is not a sensible number (zero), keeps its default.
    pub fn parse(conf: &str) -> Rates {
        let mut r = Rates::default();
        let mut inside = false;
        for line in conf.lines() {
            let line = line.trim();
            if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                inside = name.trim() == "telemetry";
                continue;
            }
            let (true, Some((k, v))) = (inside, line.split_once('=')) else {
                continue;
            };
            let (k, v) = (k.trim(), v.trim());
            let number = v.parse::<u64>().ok().filter(|n| *n > 0);
            match k {
                "store_ms" => r.store_ms = number.unwrap_or(r.store_ms),
                "live_min_ms" => r.live_min_ms = number.unwrap_or(r.live_min_ms),
                "keep_days" => r.keep_days = number.unwrap_or(r.keep_days),
                "disk_every_s" => r.disk_every_s = number.unwrap_or(r.disk_every_s),
                "gpu" => r.gpu = v.parse().unwrap_or(r.gpu),
                _ => {}
            }
        }
        r
    }

    /// What a viewer's ASK_MS comes to: not below `live_min_ms`; none asked (0) is the store rate.
    pub fn clamp(&self, ask_ms: u64) -> u64 {
        if ask_ms == 0 {
            self.store_ms
        } else {
            ask_ms.max(self.live_min_ms)
        }
    }
}

/// Where the engine reads.
#[derive(Clone, Debug)]
pub struct Roots {
    /// `/proc`.
    pub proc: PathBuf,
    /// The directory a target's cgroup path is joined to.
    pub cgroup: PathBuf,
    /// Whose filesystem's free space the disk readings are.
    pub folder: PathBuf,
}

/// Something to sample below the machine: a slot, a reservation or a job.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub level: Level,
    pub id: String,
    /// Its cgroup directory, below [`Roots::cgroup`]; none for a reservation, which has no cgroup of its own.
    pub cgroup: Option<PathBuf>,
    /// A reservation's: reserved and used, MiB.
    pub reserved_mib: u64,
    pub used_mib: u64,
    /// A slot's: the jobs on it now; its series are the sum of theirs (CPU, memory, swap, IO) with its own cgroup's,
    /// when it has one.
    pub members: Vec<String>,
}

impl Target {
    /// A job, in its cgroup.
    pub fn job(id: &str, cgroup: PathBuf) -> Target {
        Target {
            level: Level::Job,
            id: id.into(),
            cgroup: Some(cgroup),
            reserved_mib: 0,
            used_mib: 0,
            members: vec![],
        }
    }

    /// A slot instance with the jobs on it (and a cgroup of its own, where it has one).
    pub fn slot(id: &str, cgroup: Option<PathBuf>, members: Vec<String>) -> Target {
        Target {
            level: Level::Slot,
            id: id.into(),
            cgroup,
            reserved_mib: 0,
            used_mib: 0,
            members,
        }
    }

    /// A job's reservation: MiB reserved, MiB used.
    pub fn reservation(id: &str, reserved_mib: u64, used_mib: u64) -> Target {
        Target {
            level: Level::Reservation,
            id: id.into(),
            cgroup: None,
            reserved_mib,
            used_mib,
            members: vec![],
        }
    }
}

/// A GPU reader (NVML or amdgpu sysfs), the optional part: its absence is no series, never an error.
pub trait GpuReader: Send {
    /// (utilisation percent, memory MiB), none when the reading fails.
    fn read(&mut self) -> Option<(f64, f64)>;
}

/// What one watcher gets from a tick.
#[derive(Clone, Debug, PartialEq)]
pub struct Out {
    pub watch: u64,
    pub every_ms: u64,
    pub samples: Vec<Sample>,
    pub markers: Vec<Marker>,
}

/// A viewer.
struct Watcher {
    id: u64,
    level: Level,
    ids: Vec<String>,
    ask_ms: u64,
    next_due: u64,
}

/// One reading of the last sampling: target INDEX (0: the runner, n: target n - 1), metric byte, value.
struct Reading {
    level: Level,
    index: usize,
    metric: u8,
    value: f64,
}

/// What the previous sampling saw, for the rates (a counter's difference over the seconds between).
#[derive(Default, Clone, Copy)]
struct Prev {
    at_ms: u64,
    cpu: Option<f64>,
    io_bytes: Option<f64>,
    net_rx: Option<f64>,
    net_tx: Option<f64>,
    /// When the slow files (pressure averages, peak, swap) were last read.
    slow_at: Option<u64>,
}

/// The slow files are read once in this many ms.
const SLOW_MS: u64 = 1000;

/// One stored window being filled.
#[derive(Clone, Copy)]
struct Acc {
    window: u64,
    width: u64,
    count: u32,
    min: f64,
    max: f64,
    sum: f64,
    last: f64,
}

/// One file of a series' source: not opened yet, held open, or not there (tried again every [`RETRY`] samplings).
#[derive(Default)]
enum Slot {
    #[default]
    Unopened,
    Open(std::fs::File),
    Missing,
}

/// The files of one id (the runner's: [`RUNNER_FILES`]; a target's: [`TARGET_FILES`]) and what its last sampling saw.
#[derive(Default)]
struct Book {
    prev: Prev,
    /// Where its files are.
    dir: PathBuf,
    slots: [Slot; 8],
}

/// FILES' text for BOOK's slot K (the file NAME in its directory).
fn read<'a>(files: &'a mut Files, book: &mut Book, k: usize, name: &str) -> Option<&'a str> {
    let Book { dir, slots, .. } = book;
    files.text(&mut slots[k], dir, name)
}

const RUNNER_FILES: [&str; 7] = [
    "meminfo",
    "pressure/cpu",
    "pressure/memory",
    "pressure/io",
    "stat",
    "diskstats",
    "net/dev",
];
const TARGET_FILES: [&str; 8] = [
    "cpu.stat",
    "memory.current",
    "memory.peak",
    "memory.swap.current",
    "cpu.pressure",
    "memory.pressure",
    "io.pressure",
    "io.stat",
];
/// A file that was not there is looked for again after this many samplings.
const RETRY: u64 = 200;

/// The one buffer every file is read into, at offset 0 (the descriptors stay open).
#[derive(Default)]
struct Files {
    buf: Vec<u8>,
}

impl Files {
    /// The text of NAME in DIR now through SLOT, or none when it can't be read.
    fn text(&mut self, slot: &mut Slot, dir: &Path, name: &str) -> Option<&str> {
        use std::os::unix::fs::FileExt as _;
        if matches!(slot, Slot::Unopened) {
            *slot = match crate::fsio::open_read(dir.join(name)) {
                Ok(f) => Slot::Open(f),
                Err(_) => Slot::Missing,
            };
        }
        let Slot::Open(f) = slot else {
            return None;
        };
        if self.buf.len() < 64 * 1024 {
            self.buf.resize(64 * 1024, 0);
        }
        let Ok(n) = f.read_at(&mut self.buf, 0) else {
            *slot = Slot::Unopened;
            return None;
        };
        std::str::from_utf8(&self.buf[..n]).ok()
    }
}

/// The value after `KEY` in a line of TEXT that starts with PREFIX (`some avg10=1.50 …`).
fn after<'a>(text: &'a str, prefix: &str, key: &str) -> Option<&'a str> {
    let line = text.lines().find(|l| l.starts_with(prefix))?;
    let rest = &line[line.find(key)? + key.len()..];
    Some(rest.split_whitespace().next().unwrap_or(rest))
}

fn number(text: &str) -> Option<f64> {
    text.trim().parse().ok()
}

// the stored byte of each metric, in the order of `proto::telemetry::METRICS` (a test holds them equal)
const M_CPU: u8 = 1;
const M_MEM: u8 = 2;
const M_MEM_AVAIL: u8 = 3;
const M_MEM_PEAK: u8 = 4;
const M_SWAP: u8 = 5;
const M_PSI_CPU: u8 = 6;
const M_PSI_MEM: u8 = 7;
const M_PSI_IO: u8 = 8;
const M_IO: u8 = 9;
const M_NET_RX: u8 = 10;
const M_NET_TX: u8 = 11;
const M_DISK_FREE: u8 = 12;
const M_RESERVED: u8 = 14;
const M_USED: u8 = 15;
const M_HEADROOM: u8 = 16;
const M_JOBS: u8 = 17;
const M_GPU_UTIL: u8 = 18;
const M_GPU_MEM: u8 = 19;

/// The seconds of CPU the machine has done (`/proc/stat`'s first line, less idle and iowait).
fn busy_seconds(t: &str) -> Option<f64> {
    let mut sum = 0.0;
    let mut idle = 0.0;
    for (i, n) in t.lines().next()?.split_whitespace().skip(1).enumerate() {
        let n: f64 = n.parse().ok()?;
        sum += n;
        if i == 3 || i == 4 {
            idle += n;
        }
    }
    Some((sum - idle) / USER_HZ)
}

/// Bytes the whole disks of `/proc/diskstats` have read and written.
fn disk_bytes(t: &str) -> f64 {
    let mut total = 0.0;
    for l in t.lines() {
        let mut f = l.split_whitespace();
        let (Some(name), Some(read), Some(written)) = (f.nth(2), f.nth(2), f.nth(3)) else {
            continue;
        };
        if let (true, Ok(r), Ok(w)) = (
            whole_disk(name),
            read.parse::<f64>(),
            written.parse::<f64>(),
        ) {
            total += (r + w) * 512.0;
        }
    }
    total
}

/// Bytes received and sent by the interfaces of `/proc/net/dev`, the loopback aside.
fn net_bytes(t: &str) -> (f64, f64) {
    let mut total = (0.0, 0.0);
    for l in t.lines() {
        let Some((name, rest)) = l.split_once(':') else {
            continue;
        };
        if name.trim() == "lo" {
            continue;
        }
        let mut f = rest.split_whitespace();
        let (Some(rx), Some(tx)) = (f.next(), f.nth(7)) else {
            continue;
        };
        if let (Ok(rx), Ok(tx)) = (rx.parse::<f64>(), tx.parse::<f64>()) {
            total = (total.0 + rx, total.1 + tx);
        }
    }
    total
}

/// Bytes a cgroup's `io.stat` says were read and written.
fn io_stat_bytes(t: &str) -> f64 {
    let mut total = 0.0;
    for kv in t.split_whitespace() {
        if let Some((k, v)) = kv.split_once('=')
            && matches!(k, "rbytes" | "wbytes")
            && let Ok(v) = v.parse::<f64>()
        {
            total += v;
        }
    }
    total
}

/// USER_HZ: the unit `/proc/stat` counts CPU time in.
const USER_HZ: f64 = 100.0;
const MIB: f64 = 1024.0 * 1024.0;
/// Frames of a rate under this are batched.
const BATCH_MS: u64 = 16;

/// The sampler and its books.
pub struct Engine {
    roots: Roots,
    rates: Rates,
    store: super::telemetry_store::Store,
    gpu: Option<Box<dyn GpuReader>>,
    targets: Vec<Target>,
    headroom: Option<i64>,
    taken: u64,
    last_sample: Option<u64>,
    watchers: Vec<Watcher>,
    files: Files,
    /// Index 0 is the runner, n the target n - 1.
    books: Vec<Book>,
    scratch: Vec<Reading>,
    /// The windows open: by level, id, then metric byte.
    accs: BTreeMap<Level, BTreeMap<String, BTreeMap<u8, Acc>>>,
    /// Records waiting for the next write.
    to_write: Vec<super::telemetry_store::Record>,
    /// Markers not yet handed to the watchers.
    fresh: Vec<Marker>,
    /// What each watcher has waiting, with the time its first sample came.
    pending: BTreeMap<u64, (u64, Out)>,
    disk_free_gb: Option<f64>,
    disk_at_ms: Option<u64>,
}

impl Engine {
    pub fn new(
        roots: Roots,
        rates: Rates,
        store: &Path,
        gpu: Option<Box<dyn GpuReader>>,
    ) -> Engine {
        let runner = Book {
            dir: roots.proc.clone(),
            ..Book::default()
        };
        Engine {
            roots,
            rates,
            store: super::telemetry_store::Store::at(store),
            gpu,
            targets: vec![],
            headroom: None,
            taken: 0,
            last_sample: None,
            watchers: vec![],
            files: Files::default(),
            books: vec![runner],
            scratch: Vec::new(),
            accs: BTreeMap::new(),
            to_write: vec![],
            fresh: vec![],
            pending: BTreeMap::new(),
            disk_free_gb: None,
            disk_at_ms: None,
        }
    }

    /// New rates, at once: the next tick samples at the new interval, a watcher's rate is clamped again, the next
    /// stored window has the new width.
    pub fn set_rates(&mut self, rates: Rates) {
        self.rates = rates;
    }

    /// What to sample below the machine, and admission's headroom line (`avail − floor − reserved`, MiB) as of now.
    pub fn set_targets(&mut self, targets: Vec<Target>, headroom_mib: Option<i64>) {
        // a target that stays keeps its open files and its last reading; a gone one's files close; a new one starts empty
        let mut old: Vec<Option<Book>> = std::mem::take(&mut self.books)
            .into_iter()
            .map(Some)
            .collect();
        let mut books = vec![old.first_mut().and_then(Option::take).unwrap_or_default()];
        for t in &targets {
            let kept = self
                .targets
                .iter()
                .position(|o| o.level == t.level && o.id == t.id)
                .and_then(|i| old.get_mut(i + 1).and_then(Option::take));
            books.push(kept.unwrap_or_else(|| {
                Book {
                    dir: t
                        .cgroup
                        .as_ref()
                        .map(|c| self.roots.cgroup.join(c))
                        .unwrap_or_default(),
                    ..Book::default()
                }
            }));
        }
        self.books = books;
        self.targets = targets;
        self.headroom = headroom_mib;
    }

    /// Watcher ID wants LEVEL's samples (IDS, none: all) every ASK_MS; the rate it gets.
    pub fn watch(
        &mut self,
        id: u64,
        level: Level,
        ids: Vec<String>,
        ask_ms: u64,
        now_ms: u64,
    ) -> u64 {
        self.watchers.retain(|w| w.id != id);
        self.watchers.push(Watcher {
            id,
            level,
            ids,
            ask_ms,
            next_due: now_ms,
        });
        self.rates.clamp(ask_ms)
    }

    pub fn unwatch(&mut self, id: u64) {
        self.watchers.retain(|w| w.id != id);
        self.pending.remove(&id);
    }

    /// A moment on the timeline; watchers and the store get it with the next samples.
    pub fn mark(&mut self, m: Marker) {
        self.to_write
            .push(super::telemetry_store::Record::Marker(m.clone()));
        self.fresh.push(m);
    }

    /// How often the engine samples now: the fastest watcher's rate, else the store rate.
    pub fn interval_ms(&self) -> u64 {
        self.watchers
            .iter()
            .map(|w| self.rates.clamp(w.ask_ms))
            .min()
            .unwrap_or(self.rates.store_ms)
    }

    /// How many samplings have run.
    pub fn taken(&self) -> u64 {
        self.taken
    }

    /// When the next sampling is due (ms), none before the first.
    pub fn next_due_ms(&self) -> u64 {
        self.last_sample
            .map_or(0, |t| t.saturating_add(self.interval_ms()))
    }

    /// Samples when one is due at NOW_MS and returns what the watchers are to hear (a watcher hears at its own rate;
    /// frames of a rate under 16 ms are batched per 16 ms).
    pub fn tick(&mut self, now_ms: u64) -> Vec<Out> {
        if now_ms >= self.next_due_ms() {
            self.last_sample = Some(now_ms);
            self.taken += 1;
            self.sample(now_ms);
            self.feed_store(now_ms);
            self.hear(now_ms);
        }
        let mut out = Vec::new();
        let ready: Vec<u64> = self
            .pending
            .iter()
            .filter(|(_, (since, o))| {
                o.every_ms >= BATCH_MS || now_ms.saturating_sub(*since) >= BATCH_MS
            })
            .map(|(id, _)| *id)
            .collect();
        for id in ready {
            if let Some((_, o)) = self.pending.remove(&id) {
                out.push(o);
            }
        }
        if !self.to_write.is_empty() {
            self.write_out();
        }
        out
    }

    /// The history RANGE asks for: the store's, the records waiting to be written and the windows still open.
    pub fn range(&self, r: &Range) -> Ranged {
        let mut recs = self.store.read(r.from, r.to);
        recs.extend(self.to_write.iter().cloned());
        for (level, ids) in &self.accs {
            for (id, metrics) in ids {
                for (code, a) in metrics {
                    if let Some(name) = crate::proto::telemetry::metric_name(*code) {
                        recs.push(super::telemetry_store::Record::Bucket {
                            level: *level,
                            id: id.clone(),
                            metric: name,
                            b: bucket_of(a),
                        });
                    }
                }
            }
        }
        recs.retain(|rec| {
            let t = match rec {
                super::telemetry_store::Record::Bucket { b, .. } => b.t,
                super::telemetry_store::Record::Marker(m) => m.at_ms,
            };
            t >= r.from && t < r.to
        });
        super::telemetry_store::ranged(recs, r)
    }

    /// Writes the open windows out and prunes at `keep_days`.
    pub fn flush(&mut self, now_ms: u64) {
        let accs = std::mem::take(&mut self.accs);
        for (level, ids) in accs {
            for (id, metrics) in ids {
                for (code, a) in metrics {
                    if let Some(name) = crate::proto::telemetry::metric_name(code) {
                        self.to_write.push(super::telemetry_store::Record::Bucket {
                            level,
                            id: id.clone(),
                            metric: name,
                            b: bucket_of(&a),
                        });
                    }
                }
            }
        }
        self.write_out();
        self.store.prune(now_ms, self.rates.keep_days);
    }

    fn write_out(&mut self) {
        let recs = std::mem::take(&mut self.to_write);
        if let Err(e) = self.store.append(&recs) {
            crate::eline!("sleipnir serve: telemetry: {e}");
        }
    }

    fn push(&mut self, level: Level, index: usize, metric: u8, value: f64) {
        self.scratch.push(Reading {
            level,
            index,
            metric,
            value,
        });
    }

    /// One sampling: every series of the machine and the targets, into the scratch.
    fn sample(&mut self, now_ms: u64) {
        self.scratch.clear();
        if self.taken.is_multiple_of(RETRY) {
            for b in &mut self.books {
                for s in &mut b.slots {
                    if matches!(s, Slot::Missing) {
                        *s = Slot::Unopened;
                    }
                }
            }
        }
        let mut prev = self.books[0].prev;
        let dt = prev_dt(prev.at_ms, now_ms);
        let kb = read(&mut self.files, &mut self.books[0], 0, RUNNER_FILES[0])
            .and_then(|t| after(t, "MemAvailable:", ":"))
            .and_then(number);
        if let Some(kb) = kb {
            self.push(Level::Runner, 0, M_MEM_AVAIL, kb / 1024.0);
        }
        if prev
            .slow_at
            .is_none_or(|t| now_ms.saturating_sub(t) >= SLOW_MS)
        {
            prev.slow_at = Some(now_ms);
            for (k, m) in [(1, M_PSI_CPU), (2, M_PSI_MEM), (3, M_PSI_IO)] {
                let v = read(&mut self.files, &mut self.books[0], k, RUNNER_FILES[k])
                    .and_then(|t| after(t, "some", "avg10="))
                    .and_then(number);
                if let Some(v) = v {
                    self.push(Level::Runner, 0, m, v);
                }
            }
        }
        let busy =
            read(&mut self.files, &mut self.books[0], 4, RUNNER_FILES[4]).and_then(busy_seconds);
        if let (Some(now), Some(then), Some(dt)) = (busy, prev.cpu, dt) {
            self.push(Level::Runner, 0, M_CPU, (now - then) / dt);
        }
        prev.cpu = busy.or(prev.cpu);
        let sectors = read(&mut self.files, &mut self.books[0], 5, RUNNER_FILES[5]).map(disk_bytes);
        if let (Some(now), Some(then), Some(dt)) = (sectors, prev.io_bytes, dt) {
            self.push(Level::Runner, 0, M_IO, (now - then) / MIB / dt);
        }
        prev.io_bytes = sectors.or(prev.io_bytes);
        let net = read(&mut self.files, &mut self.books[0], 6, RUNNER_FILES[6]).map(net_bytes);
        if let (Some((rx, tx)), Some(dt)) = (net, dt) {
            if let (Some(r0), Some(t0)) = (prev.net_rx, prev.net_tx) {
                self.push(Level::Runner, 0, M_NET_RX, (rx - r0) / MIB / dt);
                self.push(Level::Runner, 0, M_NET_TX, (tx - t0) / MIB / dt);
            }
            prev.net_rx = Some(rx);
            prev.net_tx = Some(tx);
        }
        let due = self
            .disk_at_ms
            .is_none_or(|t| now_ms.saturating_sub(t) >= self.rates.disk_every_s * 1000);
        if due {
            self.disk_at_ms = Some(now_ms);
            self.disk_free_gb = rustix::fs::statvfs(&self.roots.folder)
                .ok()
                .map(|s| s.f_bavail.saturating_mul(s.f_frsize) as f64 / 1e9);
        }
        if let Some(v) = self.disk_free_gb {
            self.push(Level::Runner, 0, M_DISK_FREE, v);
        }
        let jobs = self
            .targets
            .iter()
            .filter(|t| t.level == Level::Job)
            .count();
        self.push(Level::Runner, 0, M_JOBS, jobs as f64);
        if let Some(h) = self.headroom {
            self.push(Level::Runner, 0, M_HEADROOM, h as f64);
        }
        if self.rates.gpu {
            let gpu = self.gpu.as_mut().and_then(|g| g.read());
            if let Some((util, mem)) = gpu {
                self.push(Level::Runner, 0, M_GPU_UTIL, util);
                self.push(Level::Runner, 0, M_GPU_MEM, mem);
            }
        }
        self.books[0].prev = Prev {
            at_ms: now_ms,
            ..prev
        };
        for i in 0..self.targets.len() {
            self.sample_target(i, now_ms);
        }
        self.sum_members();
    }

    /// A slot with no cgroup of its own reads as the sum of the jobs on it.
    fn sum_members(&mut self) {
        for i in 0..self.targets.len() {
            let t = &self.targets[i];
            if t.level != Level::Slot || t.cgroup.is_some() || t.members.is_empty() {
                continue;
            }
            let mut sums = [
                (M_CPU, 0.0, false),
                (M_MEM, 0.0, false),
                (M_SWAP, 0.0, false),
                (M_IO, 0.0, false),
            ];
            for r in &self.scratch {
                if r.level != Level::Job || r.index == 0 {
                    continue;
                }
                if !t.members.contains(&self.targets[r.index - 1].id) {
                    continue;
                }
                for s in &mut sums {
                    if s.0 == r.metric {
                        s.1 += r.value;
                        s.2 = true;
                    }
                }
            }
            let jobs = t.members.len() as f64;
            for (metric, value, seen) in sums {
                if seen {
                    self.push(Level::Slot, i + 1, metric, value);
                }
            }
            self.push(Level::Slot, i + 1, M_JOBS, jobs);
        }
    }

    fn sample_target(&mut self, i: usize, now_ms: u64) {
        let (level, reserved, used) = {
            let t = &self.targets[i];
            (t.level, t.reserved_mib, t.used_mib)
        };
        let index = i + 1;
        if level == Level::Reservation {
            self.push(level, index, M_RESERVED, reserved as f64);
            self.push(level, index, M_USED, used as f64);
            return;
        }
        if self.targets[i].cgroup.is_none() {
            return;
        }
        let mut prev = self.books[index].prev;
        let dt = prev_dt(prev.at_ms, now_ms);
        let usec = read(&mut self.files, &mut self.books[index], 0, TARGET_FILES[0])
            .and_then(|t| after(t, "usage_usec", "usage_usec "))
            .and_then(number);
        if let (Some(now), Some(then), Some(dt)) = (usec, prev.cpu, dt) {
            self.push(level, index, M_CPU, (now - then) / 1e6 / dt);
        }
        prev.cpu = usec.or(prev.cpu);
        let v = read(&mut self.files, &mut self.books[index], 1, TARGET_FILES[1]).and_then(number);
        if let Some(v) = v {
            self.push(level, index, M_MEM, v / MIB);
        }
        // the peak, the swap and the pressure averages move slowly (the kernel updates `avg10` every 2 s): once per
        // `SLOW_MS`, so a 5 ms stream costs three reads of a cgroup a tick, not eight
        if prev
            .slow_at
            .is_none_or(|t| now_ms.saturating_sub(t) >= SLOW_MS)
        {
            prev.slow_at = Some(now_ms);
            for (k, m) in [(2, M_MEM_PEAK), (3, M_SWAP)] {
                let v = read(&mut self.files, &mut self.books[index], k, TARGET_FILES[k])
                    .and_then(number);
                if let Some(v) = v {
                    self.push(level, index, m, v / MIB);
                }
            }
            for (k, m) in [(4, M_PSI_CPU), (5, M_PSI_MEM), (6, M_PSI_IO)] {
                let v = read(&mut self.files, &mut self.books[index], k, TARGET_FILES[k])
                    .and_then(|t| after(t, "some", "avg10="))
                    .and_then(number);
                if let Some(v) = v {
                    self.push(level, index, m, v);
                }
            }
        }
        let bytes =
            read(&mut self.files, &mut self.books[index], 7, TARGET_FILES[7]).map(io_stat_bytes);
        if let (Some(now), Some(then), Some(dt)) = (bytes, prev.io_bytes, dt) {
            self.push(level, index, M_IO, (now - then) / MIB / dt);
        }
        prev.io_bytes = bytes.or(prev.io_bytes);
        self.books[index].prev = Prev {
            at_ms: now_ms,
            ..prev
        };
    }

    /// The scratch into the stored windows.
    fn feed_store(&mut self, now_ms: u64) {
        let width = self.rates.store_ms.max(1);
        let window = now_ms - now_ms % width;
        for r in &self.scratch {
            let id = if r.index == 0 {
                "runner"
            } else {
                self.targets[r.index - 1].id.as_str()
            };
            let ids = self.accs.entry(r.level).or_default();
            if !ids.contains_key(id) {
                ids.insert(id.to_string(), BTreeMap::new());
            }
            let Some(metrics) = ids.get_mut(id) else {
                continue;
            };
            let acc = metrics.entry(r.metric).or_insert(Acc {
                window,
                width,
                count: 0,
                min: r.value,
                max: r.value,
                sum: 0.0,
                last: r.value,
            });
            if acc.window != window {
                if let Some(name) = crate::proto::telemetry::metric_name(r.metric) {
                    self.to_write.push(super::telemetry_store::Record::Bucket {
                        level: r.level,
                        id: id.to_string(),
                        metric: name,
                        b: bucket_of(acc),
                    });
                }
                *acc = Acc {
                    window,
                    width,
                    count: 0,
                    min: r.value,
                    max: r.value,
                    sum: 0.0,
                    last: r.value,
                };
            }
            acc.count += 1;
            acc.min = acc.min.min(r.value);
            acc.max = acc.max.max(r.value);
            acc.sum += r.value;
            acc.last = r.value;
        }
    }

    /// The scratch and the fresh markers into what each watcher waits to be told.
    fn hear(&mut self, now_ms: u64) {
        let markers = std::mem::take(&mut self.fresh);
        for wi in 0..self.watchers.len() {
            let (id, due, every) = {
                let w = &self.watchers[wi];
                (w.id, now_ms >= w.next_due, self.rates.clamp(w.ask_ms))
            };
            let mut samples: Vec<Sample> = Vec::new();
            if due {
                let w = &self.watchers[wi];
                let mut i = 0;
                while i < self.scratch.len() {
                    let (lv, ix) = (self.scratch[i].level, self.scratch[i].index);
                    let mut values = BTreeMap::new();
                    while i < self.scratch.len()
                        && self.scratch[i].level == lv
                        && self.scratch[i].index == ix
                    {
                        let r = &self.scratch[i];
                        if let Some(name) = crate::proto::telemetry::metric_name(r.metric) {
                            values.insert(name.to_string(), r.value);
                        }
                        i += 1;
                    }
                    let sid = if ix == 0 {
                        "runner"
                    } else {
                        self.targets[ix - 1].id.as_str()
                    };
                    if lv == w.level && (w.ids.is_empty() || w.ids.iter().any(|x| x == sid)) {
                        samples.push(Sample {
                            at_ms: now_ms,
                            level: lv,
                            id: sid.to_string(),
                            values,
                        });
                    }
                }
                self.watchers[wi].next_due = now_ms + every;
            }
            if samples.is_empty() && markers.is_empty() {
                continue;
            }
            let (_, o) = self.pending.entry(id).or_insert((
                now_ms,
                Out {
                    watch: id,
                    every_ms: every,
                    samples: vec![],
                    markers: vec![],
                },
            ));
            o.every_ms = every;
            o.samples.extend(samples);
            o.markers.extend(markers.iter().cloned());
        }
    }
}

fn bucket_of(a: &Acc) -> super::telemetry_store::Bucket {
    super::telemetry_store::Bucket {
        t: a.window,
        width_ms: u32::try_from(a.width).unwrap_or(u32::MAX),
        count: a.count,
        min: a.min,
        max: a.max,
        mean: if a.count == 0 {
            a.last
        } else {
            a.sum / f64::from(a.count)
        },
        last: a.last,
    }
}

/// Seconds between two samplings, none for the first.
fn prev_dt(prev_ms: u64, now_ms: u64) -> Option<f64> {
    (now_ms > prev_ms).then(|| (now_ms - prev_ms) as f64 / 1000.0)
}

/// Whether a `/proc/diskstats` NAME is a whole disk (partitions and virtual devices count twice or not at all).
fn whole_disk(name: &str) -> bool {
    if ["loop", "ram", "zram", "dm-", "md", "sr"]
        .iter()
        .any(|p| name.starts_with(p))
    {
        return false;
    }
    if name.starts_with("nvme") || name.starts_with("mmcblk") {
        return !name.rsplit_once('p').is_some_and(|(head, tail)| {
            head.ends_with(|c: char| c.is_ascii_digit())
                && !tail.is_empty()
                && tail.chars().all(|c| c.is_ascii_digit())
        });
    }
    !name.ends_with(|c: char| c.is_ascii_digit())
}

/// An amdgpu card's sysfs files: `device/gpu_busy_percent` and `device/mem_info_vram_used`.
pub struct SysfsGpu {
    busy: PathBuf,
    vram: PathBuf,
}

impl SysfsGpu {
    /// The first card under SYS (`/sys`) that has the files, none when there is no such card.
    pub fn find(sys: &Path) -> Option<SysfsGpu> {
        let mut cards: Vec<PathBuf> = std::fs::read_dir(sys.join("class/drm"))
            .ok()?
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .is_some_and(|n| n.starts_with("card") && !n.contains('-'))
            })
            .map(|e| e.path())
            .collect();
        cards.sort();
        cards.into_iter().find_map(|c| {
            let busy = c.join("device/gpu_busy_percent");
            busy.exists().then(|| SysfsGpu {
                vram: c.join("device/mem_info_vram_used"),
                busy,
            })
        })
    }
}

impl GpuReader for SysfsGpu {
    fn read(&mut self) -> Option<(f64, f64)> {
        let util = number(&crate::fsio::read_to_string(&self.busy).ok()?)?;
        let vram = number(&crate::fsio::read_to_string(&self.vram).ok()?)?;
        Some((util, vram / MIB))
    }
}

/// What the thread is told.
pub enum Cmd {
    Watch {
        id: u64,
        level: Level,
        ids: Vec<String>,
        every_ms: u64,
    },
    Unwatch(u64),
    Range {
        id: u64,
        range: Range,
    },
    Targets(Vec<Target>, Option<i64>),
    Mark(Marker),
    Rates(Rates),
    Stop,
}

/// Epoch milliseconds now.
pub fn now_ms() -> u64 {
    stund::wall()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// How often the thread writes the open windows out, ms.
const FLUSH_EVERY_MS: u64 = 60_000;

/// Runs ENGINE on a thread of its own: it sleeps to the next sampling (or the next command), answers what it is told
/// and hands every frame it makes to EMIT. The sender ends it (`Cmd::Stop`, or dropped); it writes its windows out on
/// the way.
pub fn spawn(
    mut engine: Engine,
    emit: impl Fn(crate::proto::Frame) + Send + 'static,
) -> std::io::Result<std::sync::mpsc::Sender<Cmd>> {
    use crate::proto::Frame;
    use std::sync::mpsc::{RecvTimeoutError, channel};
    let (tx, rx) = channel::<Cmd>();
    saman::spawn_thread("serve-telemetry", move || {
        let mut flushed = now_ms();
        loop {
            let now = now_ms();
            let wait = engine.next_due_ms().saturating_sub(now).clamp(1, 1000);
            let cmd = match rx.recv_timeout(std::time::Duration::from_millis(wait)) {
                Ok(c) => Some(c),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => Some(Cmd::Stop),
            };
            match cmd {
                Some(Cmd::Stop) => break,
                Some(Cmd::Watch {
                    id,
                    level,
                    ids,
                    every_ms,
                }) => {
                    engine.watch(id, level, ids, every_ms, now_ms());
                }
                Some(Cmd::Unwatch(id)) => engine.unwatch(id),
                Some(Cmd::Range { id, range }) => emit(Frame::TelemetryRanged {
                    id,
                    ranged: engine.range(&range),
                }),
                Some(Cmd::Targets(t, h)) => engine.set_targets(t, h),
                Some(Cmd::Mark(m)) => engine.mark(m),
                Some(Cmd::Rates(r)) => engine.set_rates(r),
                None => {}
            }
            let now = now_ms();
            for o in engine.tick(now) {
                emit(Frame::Telemetry {
                    id: o.watch,
                    every_ms: o.every_ms,
                    samples: o.samples,
                    markers: o.markers,
                });
            }
            if now.saturating_sub(flushed) >= FLUSH_EVERY_MS {
                flushed = now;
                engine.flush(now);
            }
        }
        engine.flush(now_ms());
    })
    .map_err(|e| std::io::Error::other(e.to_string()))?;
    Ok(tx)
}

/// Admission's headroom line for MACHINE under LIMITS: the same budget admission decides on, MiB.
pub fn headroom_mib(m: &forseti::MachineState, limits: &forseti::Limits) -> i64 {
    forseti::admit::budget(m, limits).mem_mib
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fsio;

    const MIB: u64 = 1024 * 1024;

    struct Tree {
        t: tempfile::TempDir,
    }

    impl Tree {
        fn new() -> Tree {
            let t = tempfile::tempdir().unwrap();
            let me = Tree { t };
            me.put(
                "proc/meminfo",
                "MemTotal: 16384000 kB\nMemAvailable: 8192000 kB\n",
            );
            for w in ["cpu", "memory", "io"] {
                me.put(
                    &format!("proc/pressure/{w}"),
                    "some avg10=1.50 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.50 avg60=0.00 avg300=0.00 total=1\n",
                );
            }
            me.put("proc/stat", "cpu  100 0 100 800 0 0 0 0 0 0\n");
            me.put(
                "proc/diskstats",
                "   8       0 sda 10 0 2048 0 5 0 4096 0 0 0 0 0\n",
            );
            me.put(
                "proc/net/dev",
                "Inter-|   Receive |  Transmit\n face |bytes packets|bytes packets\n  eth0: 1048576 10 0 0 0 0 0 0 2097152 10 0 0 0 0 0 0\n",
            );
            me.job("jobs/a3f", 1_000_000, 1024 * MIB, 1_048_576);
            me.job("slots/s1-0", 500_000, 256 * MIB, 0);
            me
        }

        fn path(&self, rel: &str) -> PathBuf {
            self.t.path().join(rel)
        }

        fn put(&self, rel: &str, text: &str) {
            let p = self.path(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            // a file the engine holds open is rewritten where it is, as a kernel file is
            if p.exists() {
                fsio::write_in_place(p, text).unwrap();
            } else {
                fsio::write(p, text).unwrap();
            }
        }

        /// A cgroup directory with CPU_US of CPU time used, MEM bytes in use and READ bytes read.
        fn job(&self, rel: &str, cpu_us: u64, mem: u64, read: u64) {
            let d = format!("cgroup/{rel}");
            self.put(
                &format!("{d}/cpu.stat"),
                &format!("usage_usec {cpu_us}\nuser_usec 1\n"),
            );
            self.put(&format!("{d}/memory.current"), &format!("{mem}\n"));
            self.put(&format!("{d}/memory.peak"), &format!("{}\n", mem * 2));
            self.put(&format!("{d}/memory.swap.current"), "0\n");
            for w in ["cpu", "memory", "io"] {
                self.put(
                    &format!("{d}/{w}.pressure"),
                    "some avg10=2.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n",
                );
            }
            self.put(
                &format!("{d}/io.stat"),
                &format!("8:0 rbytes={read} wbytes=2097152 rios=1 wios=1\n"),
            );
        }

        fn roots(&self) -> Roots {
            Roots {
                proc: self.path("proc"),
                cgroup: self.path("cgroup"),
                folder: self.t.path().to_path_buf(),
            }
        }

        fn engine(&self, rates: Rates) -> Engine {
            let mut e = Engine::new(self.roots(), rates, &self.path("telemetry"), None);
            e.set_targets(
                vec![
                    Target::job("a3f", "jobs/a3f".into()),
                    Target::slot("s1-0", Some("slots/s1-0".into()), vec![]),
                    Target::reservation("a3f", 4096, 1024),
                ],
                Some(1234),
            );
            e
        }
    }

    fn values(outs: &[Out], level: Level, id: &str) -> Vec<(u64, BTreeMap<String, f64>)> {
        outs.iter()
            .flat_map(|o| o.samples.iter())
            .filter(|s| s.level == level && s.id == id)
            .map(|s| (s.at_ms, s.values.clone()))
            .collect()
    }

    /// Sample ids of LEVEL heard by WATCH over the ticks 0..=TO_MS step 1.
    fn run(e: &mut Engine, to_ms: u64) -> Vec<Out> {
        (0..=to_ms).flat_map(|t| e.tick(t)).collect()
    }

    /// [D] pure (a fixture tree): the sampler reads the machine's series, a slot's and a job's from files, a rate
    /// from two readings (CPU seconds over seconds, bytes over seconds), a level from one.
    #[test]
    fn the_sampler_reads_slot_job_and_machine_series() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        e.watch(1, Level::Runner, vec![], 1000, 0);
        e.watch(2, Level::Job, vec![], 1000, 0);
        e.watch(3, Level::Slot, vec![], 1000, 0);
        e.watch(4, Level::Reservation, vec![], 1000, 0);
        let first = e.tick(0);
        // two seconds later: 2 s of CPU in the job, 2 MiB read, the machine's 200 busy jiffies of 100 Hz
        t.job("jobs/a3f", 3_000_000, 1024 * MIB, 3 * MIB);
        t.put("proc/stat", "cpu  200 0 200 800 0 0 0 0 0 0\n");
        t.put(
            "proc/diskstats",
            "   8       0 sda 10 0 6144 0 5 0 4096 0 0 0 0 0\n",
        );
        let second = e.tick(2000);
        let all: Vec<Out> = first.into_iter().chain(second).collect();
        let job = values(&all, Level::Job, "a3f");
        assert_eq!(job.len(), 2);
        let j = &job[1].1;
        assert_eq!(j["cpu"], 1.0, "2 s of CPU over 2 s");
        assert_eq!(j["mem_mib"], 1024.0);
        assert_eq!(j["mem_peak_mib"], 2048.0);
        assert_eq!(j["swap_mib"], 0.0);
        assert_eq!(j["psi_cpu"], 2.0);
        assert_eq!(j["io_mibs"], 1.0, "2 MiB over 2 s");
        let slot = values(&all, Level::Slot, "s1-0");
        assert_eq!(slot[1].1["mem_mib"], 256.0);
        let m = &values(&all, Level::Runner, "runner")[1].1;
        assert_eq!(m["mem_avail_mib"], 8000.0);
        assert_eq!(m["psi_mem"], 1.5);
        assert_eq!(
            m["cpu"], 1.0,
            "100 jiffies of work over 2 s at 100 Hz, twice"
        );
        assert_eq!(m["io_mibs"], 1.0, "4096 sectors of 512 B over 2 s");
        assert_eq!(m["jobs"], 1.0);
        assert!(m["disk_free_gb"] >= 0.0);
        let r = &values(&all, Level::Reservation, "a3f")[1].1;
        assert_eq!((r["reserved_mib"], r["used_mib"]), (4096.0, 1024.0));
        assert_eq!(m["headroom_mib"], 1234.0);
    }

    /// [D] pure (a fixture tree): a slot with no cgroup of its own reads as the sum of the jobs on it, and counts them.
    #[test]
    fn a_slot_reads_as_the_sum_of_its_jobs() {
        let t = Tree::new();
        t.job("jobs/b4c", 500_000, 512 * MIB, 0);
        let mut e = t.engine(Rates::default());
        e.set_targets(
            vec![
                Target::job("a3f", "jobs/a3f".into()),
                Target::job("b4c", "jobs/b4c".into()),
                Target::job("zzz", "jobs/a3f".into()),
                Target::slot("s9-0", None, vec!["a3f".into(), "b4c".into()]),
            ],
            None,
        );
        e.watch(1, Level::Slot, vec![], 1000, 0);
        let first = e.tick(0);
        t.job("jobs/a3f", 3_000_000, 1024 * MIB, 1_048_576);
        t.job("jobs/b4c", 1_500_000, 512 * MIB, 0);
        let second = e.tick(2000);
        let all: Vec<Out> = first.into_iter().chain(second).collect();
        let slot = values(&all, Level::Slot, "s9-0");
        assert_eq!(slot.len(), 2);
        let v = &slot[1].1;
        assert_eq!(
            v["mem_mib"], 1536.0,
            "a3f's 1024 and b4c's 512; zzz is not on it"
        );
        assert_eq!(v["cpu"], 1.0 + 0.5, "2 s of CPU and 1 s over 2 s");
        assert_eq!(v["jobs"], 2.0);
    }

    /// [D] pure: a viewer hears samples at the rate it asked, to the millisecond.
    #[test]
    fn a_subscriber_gets_samples_at_its_asked_rate() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        assert_eq!(e.watch(1, Level::Job, vec![], 50, 0), 50);
        let outs = run(&mut e, 500);
        let at: Vec<u64> = values(&outs, Level::Job, "a3f")
            .iter()
            .map(|v| v.0)
            .collect();
        assert_eq!(at, (0..=10).map(|n| n * 50).collect::<Vec<_>>());
        assert!(outs.iter().all(|o| o.watch == 1 && o.every_ms == 50));
    }

    /// [D] pure: a rate below `live_min_ms` is the floor, and the engine's own interval follows.
    #[test]
    fn a_rate_below_live_min_is_clamped() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        assert_eq!(e.watch(1, Level::Job, vec![], 1, 0), 5);
        assert_eq!(e.interval_ms(), 5);
        let outs = run(&mut e, 40);
        let at: Vec<u64> = values(&outs, Level::Job, "a3f")
            .iter()
            .map(|v| v.0)
            .collect();
        assert!(at.windows(2).all(|w| w[1] - w[0] == 5), "{at:?}");
        assert!(at.len() >= 8, "{at:?}");
    }

    /// [D] pure: with nobody watching the engine samples at the store rate and says nothing to anyone.
    #[test]
    fn no_subscriber_falls_back_to_store_rate() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        assert_eq!(e.interval_ms(), 1000);
        let outs = run(&mut e, 3000);
        assert!(outs.is_empty());
        assert_eq!(e.taken(), 4, "at 0, 1000, 2000 and 3000");
        // the viewer goes: back to the store rate
        e.watch(1, Level::Job, vec![], 20, 3000);
        assert_eq!(e.interval_ms(), 20);
        e.unwatch(1);
        assert_eq!(e.interval_ms(), 1000);
    }

    /// [D] pure: two viewers share one sampler at the faster rate; the slower hears at its own.
    #[test]
    fn two_subscribers_share_one_sampler_at_the_faster_rate() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        e.watch(1, Level::Job, vec![], 100, 0);
        e.watch(2, Level::Job, vec![], 20, 0);
        assert_eq!(e.interval_ms(), 20);
        let outs = run(&mut e, 200);
        assert_eq!(e.taken(), 11, "one sampler, at the faster rate");
        let of = |w: u64| -> Vec<u64> {
            let mine: Vec<Out> = outs.iter().filter(|o| o.watch == w).cloned().collect();
            values(&mine, Level::Job, "a3f")
                .iter()
                .map(|v| v.0)
                .collect()
        };
        assert_eq!(of(1), [0, 100, 200]);
        assert_eq!(of(2).len(), 11);
    }

    /// [D] pure: a rate change reaches the running engine: the interval, a viewer's clamp and the stored window.
    #[test]
    fn a_rate_change_applies_without_restart() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        assert_eq!(e.watch(1, Level::Job, vec![], 5, 0), 5);
        e.set_rates(Rates {
            live_min_ms: 25,
            ..Rates::default()
        });
        assert_eq!(e.interval_ms(), 25, "the viewer's 5 is clamped again");
        e.unwatch(1);
        e.set_rates(Rates {
            store_ms: 200,
            ..Rates::default()
        });
        assert_eq!(e.interval_ms(), 200);
        for n in 0..=5 {
            e.tick(n * 200);
        }
        e.flush(1000);
        let r = e.range(&Range {
            level: Level::Job,
            ids: vec![],
            from: 0,
            to: 2000,
            step_ms: 0,
        });
        let mem = r.series.iter().find(|s| s.metric == "mem_mib").unwrap();
        let ts: Vec<u64> = mem.points.iter().map(|p| p.t).collect();
        assert_eq!(ts, [0, 200, 400, 600, 800, 1000]);
    }

    /// [D] pure: the headroom line is admission's own budget.
    #[test]
    fn the_headroom_line_matches_admission() {
        let m = forseti::MachineState {
            name: "t".into(),
            profile: forseti::Profile::Dedicated,
            now: 0,
            boot_id: "b".into(),
            mem_total_mib: 32_768,
            mem_available_mib: 16_384,
            psi: Default::default(),
            disk_free_gb: 500,
            disk_total_gb: 1000,
            disk_unused_gib: 0,
            on_ac: true,
            last_start: None,
            last_start_small: false,
            running: vec![],
            features: vec![],
            reachable: true,
            others: vec![],
            island: None,
        };
        let l = forseti::Limits::for_profile(forseti::Profile::Dedicated, 32_768, 8);
        assert_eq!(headroom_mib(&m, &l), forseti::admit::budget(&m, &l).mem_mib);
        assert_eq!(
            headroom_mib(&m, &l),
            16_384 - l.floor_mib as i64 - l.reserve_user_mib as i64
        );
    }

    struct Fixed(f64, f64);
    impl GpuReader for Fixed {
        fn read(&mut self) -> Option<(f64, f64)> {
            Some((self.0, self.1))
        }
    }

    /// [D] pure: with no GPU reader there is no GPU series and nothing fails; with one the series is there; with
    /// `gpu = false` a reader is not asked.
    #[test]
    fn no_gpu_reader_means_no_gpu_series_not_an_error() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        e.watch(1, Level::Runner, vec![], 100, 0);
        let outs = e.tick(0);
        let m = &values(&outs, Level::Runner, "runner")[0].1;
        assert!(!m.contains_key("gpu_util") && !m.contains_key("gpu_mem_mib"));
        let mut g = Engine::new(
            t.roots(),
            Rates::default(),
            &t.path("telemetry-gpu"),
            Some(Box::new(Fixed(40.0, 2048.0))),
        );
        g.watch(1, Level::Runner, vec![], 100, 0);
        let m = &values(&g.tick(0), Level::Runner, "runner")[0].1.clone();
        assert_eq!((m["gpu_util"], m["gpu_mem_mib"]), (40.0, 2048.0));
        let mut off = Engine::new(
            t.roots(),
            Rates {
                gpu: false,
                ..Rates::default()
            },
            &t.path("telemetry-off"),
            Some(Box::new(Fixed(40.0, 2048.0))),
        );
        off.watch(1, Level::Runner, vec![], 100, 0);
        assert!(
            !values(&off.tick(0), Level::Runner, "runner")[0]
                .1
                .contains_key("gpu_util")
        );
    }

    /// [D] pure: a marker rides the next frame to the viewers and is in the history at its time.
    #[test]
    fn event_markers_share_the_timeline() {
        let t = Tree::new();
        let mut e = t.engine(Rates::default());
        e.watch(1, Level::Job, vec![], 100, 0);
        e.tick(0);
        e.mark(Marker {
            at_ms: 40,
            id: "a3f".into(),
            kind: "paused".into(),
            detail: "pressure".into(),
        });
        let outs = e.tick(100);
        let heard: Vec<&Marker> = outs.iter().flat_map(|o| o.markers.iter()).collect();
        assert_eq!(heard.len(), 1);
        assert_eq!((heard[0].kind.as_str(), heard[0].at_ms), ("paused", 40));
        e.flush(100);
        let r = e.range(&Range {
            level: Level::Job,
            ids: vec![],
            from: 0,
            to: 1000,
            step_ms: 0,
        });
        assert_eq!(r.markers.len(), 1);
        assert_eq!(r.markers[0].detail, "pressure");
        // the series the marker sits beside is on the same clock
        assert!(r.series.iter().any(|s| s.points.iter().any(|p| p.t <= 40)));
    }

    /// [D] pure: the metric bytes the sampler uses are the format's.
    #[test]
    fn the_sampler_metric_bytes_are_the_formats() {
        use crate::proto::telemetry::metric_name;
        for (b, n) in [
            (M_CPU, "cpu"),
            (M_MEM, "mem_mib"),
            (M_MEM_AVAIL, "mem_avail_mib"),
            (M_MEM_PEAK, "mem_peak_mib"),
            (M_SWAP, "swap_mib"),
            (M_PSI_CPU, "psi_cpu"),
            (M_PSI_MEM, "psi_mem"),
            (M_PSI_IO, "psi_io"),
            (M_IO, "io_mibs"),
            (M_NET_RX, "net_rx_mibs"),
            (M_NET_TX, "net_tx_mibs"),
            (M_DISK_FREE, "disk_free_gb"),
            (M_RESERVED, "reserved_mib"),
            (M_USED, "used_mib"),
            (M_HEADROOM, "headroom_mib"),
            (M_JOBS, "jobs"),
            (M_GPU_UTIL, "gpu_util"),
            (M_GPU_MEM, "gpu_mem_mib"),
        ] {
            assert_eq!(metric_name(b), Some(n));
        }
    }

    /// [D] pure: the machine's counters parse: whole disks only (not partitions or virtual devices), interfaces but the
    /// loopback.
    #[test]
    fn disks_and_interfaces_are_counted_once() {
        let disks = "   8 0 sda 1 0 10 0 1 0 20 0 0 0 0\n   8 1 sda1 1 0 99 0 1 0 99 0 0 0 0\n 259 0 nvme0n1 1 0 10 0 1 0 20 0\n 259 1 nvme0n1p1 1 0 99 0 1 0 99 0\n   7 0 loop0 1 0 99 0 1 0 99 0\n 253 0 dm-0 1 0 99 0 1 0 99 0\n";
        assert_eq!(disk_bytes(disks), (10.0 + 20.0 + 10.0 + 20.0) * 512.0);
        let net = "h\nh\n    lo: 500 1 0 0 0 0 0 0 600 1\n  eth0: 10 1 0 0 0 0 0 0 20 1\n  eth1: 1 1 0 0 0 0 0 0 2 1\n";
        assert_eq!(net_bytes(net), (11.0, 22.0));
        assert_eq!(
            io_stat_bytes("8:0 rbytes=5 wbytes=7 rios=1\n8:16 rbytes=1 wbytes=1\n"),
            14.0
        );
    }

    /// [D] pure (a fixture tree): an amdgpu card's files read as utilisation and VRAM in MiB; a machine with no such
    /// card has no reader.
    #[test]
    fn an_amdgpu_card_reads_from_sysfs() {
        let t = Tree::new();
        assert!(SysfsGpu::find(&t.path("sys")).is_none());
        t.put("sys/class/drm/card0-DP-1/status", "connected\n");
        t.put("sys/class/drm/card1/device/gpu_busy_percent", "37\n");
        t.put(
            "sys/class/drm/card1/device/mem_info_vram_used",
            &format!("{}\n", 2048 * MIB),
        );
        let mut g = SysfsGpu::find(&t.path("sys")).unwrap();
        assert_eq!(g.read(), Some((37.0, 2048.0)));
    }

    /// [D] the thread: a watch it is told of streams `telemetry` frames to its emit, a range is answered with the
    /// history, and `Stop` ends it with its windows written. (The real clock: the wait only bounds a failure.)
    #[test]
    fn the_thread_streams_frames_and_answers_a_range() {
        use crate::proto::Frame;
        let t = Tree::new();
        let (tx, rx) = std::sync::mpsc::channel::<Frame>();
        let mut e = t.engine(Rates::default());
        e.set_rates(Rates {
            store_ms: 20,
            ..Rates::default()
        });
        let cmds = spawn(e, move |f| {
            drop(tx.send(f));
        })
        .unwrap();
        cmds.send(Cmd::Watch {
            id: 7,
            level: Level::Job,
            ids: vec![],
            every_ms: 20,
        })
        .unwrap();
        let wait = std::time::Duration::from_secs(20);
        let first = loop {
            match rx.recv_timeout(wait).expect("a telemetry frame") {
                Frame::Telemetry { id, samples, .. } if !samples.is_empty() => break (id, samples),
                _ => {}
            }
        };
        assert_eq!(first.0, 7);
        assert!(first.1.iter().all(|s| s.level == Level::Job));
        let now = now_ms();
        cmds.send(Cmd::Range {
            id: 8,
            range: Range {
                level: Level::Job,
                ids: vec![],
                from: now - 60_000,
                to: now + 60_000,
                step_ms: 0,
            },
        })
        .unwrap();
        let ranged = loop {
            if let Frame::TelemetryRanged { id, ranged } =
                rx.recv_timeout(wait).expect("a range answer")
            {
                break (id, ranged);
            }
        };
        assert_eq!(ranged.0, 8);
        assert!(ranged.1.series.iter().any(|s| s.id == "a3f"));
        cmds.send(Cmd::Stop).unwrap();
    }

    /// [D] pure: the rates read from a `runner.conf`, defaults for what is not there or is zero.
    #[test]
    fn rates_read_from_runner_conf() {
        let r = Rates::parse(
            "[io]\ndevice_mbps = 500\n[telemetry]\nstore_ms = 250\nlive_min_ms = 10\nkeep_days = 3\ngpu = false\ndisk_every_s = 0\n[other]\nstore_ms = 1\n",
        );
        assert_eq!(
            r,
            Rates {
                store_ms: 250,
                live_min_ms: 10,
                keep_days: 3,
                disk_every_s: 60,
                gpu: false
            }
        );
        assert_eq!(Rates::parse(""), Rates::default());
        assert_eq!(Rates::default().clamp(0), 1000);
        assert_eq!(Rates::default().clamp(2), 5);
    }

    /// [D] pure: the K-row. At 5 ms with ten cgroups a tick costs under 2 % of the interval (100 µs); the best of thirty
    /// short batches, so a busy machine (the other tests run beside this one) does not read as a slow sampler.
    #[test]
    fn sampler_cost_at_5ms_under_budget() {
        let t = Tree::new();
        for n in 0..8 {
            t.job(&format!("jobs/j{n}"), 1_000_000, 64 * MIB, 0);
        }
        let mut e = t.engine(Rates::default());
        let mut ts: Vec<Target> = (0..8)
            .map(|n| Target::job(&format!("j{n}"), format!("jobs/j{n}").into()))
            .collect();
        ts.push(Target::slot("s1-0", Some("slots/s1-0".into()), vec![]));
        e.set_targets(ts, None);
        e.watch(1, Level::Job, vec![], 5, 0);
        let mut best = u128::MAX;
        let mut now = 0;
        for _ in 0..30 {
            let start = stund::Instant::now();
            for _ in 0..20 {
                e.tick(now);
                now += 5;
            }
            best = best.min(start.elapsed().as_micros() / 20);
        }
        assert!(best < 100, "{best} µs a tick of 5 ms");
    }
}
