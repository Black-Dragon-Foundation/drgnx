//! `sleipnir serve`: the runner's end of the hub's control channel (`docs/develop/sleipnir.md`, "serve").
//!
//! ```text
//! sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation
//! ```
//!
//! It lives on stdin and stdout and exits at their end (or at `bye`, or when no frame came for 45 s): nothing is
//! installed or enabled, and between connections the runner has only its folder and, with linger, the attempts still
//! running in their own units. At every `hello` it re-probes linger and the runner contract and lists its attempts
//! from `<root>/jobs/`. It sends `ready` every 2 s and at every job end. An `offer` is admitted by `forseti` under the
//! machine's admission lock ([`admit`]); an admitted attempt's inputs come by `sync-have`, answered with what the
//! runner lacks (`sync-need`: the overlay's blobs, the commit), which comes as blobs, an origin fetch (in a thread of
//! its own, so pings go on) or a bundle; a `start` checks the attempt's slot out (`crate::sync::slot`) and runs it as a
//! transient unit running `sleipnir job-exec`;
//! logs are read from the attempt's log file by offset, never from a pipe; `finished` carries `result.json`. The
//! cleanup ([`cleanup`]) runs at start and at every job end, and touches only this hub's prefixed and labelled items.
//!
//! Blocking and threaded, no async runtime: one thread reads frames, the main loop handles them and ticks.

pub mod admit;
pub mod attempts;
pub mod cleanup;
pub mod platform;
#[cfg(test)]
mod platform_tests;

use crate::linux::jobexec::{self, KEY_USE};
use crate::linux::reserve::Reservation;
use crate::linux::resize;
use crate::linux::result::{RESULT, ResultJson};
use crate::proto::{
    AttemptState, Frame, FrameReader, FrameWriter, JobRef, Key, MAX_CHUNK, ManifestEntry,
    PROTO_VERSION, Sha256,
};
use crate::sync::blobs::Store;
use crate::sync::bundle::{BundleRef, Receiver};
use crate::sync::capture::Entry;
use crate::sync::mirror::{self, Mirror};
use crate::sync::slot::{self, Overlay, SlotKey};
use attempts::{CANCELLED, COLLECTED, LOG, Meta};
use forseti::classify::infra;
use forseti::safety::Level;
use forseti::{Action, JobId, Kind, Limits, Profile, RunningJob, Verdict};
use platform::{LaunchReq, Platform};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// `ready` this often.
pub const READY_EVERY: Duration = Duration::from_secs(2);
/// `ping` this often.
pub const PING_EVERY: Duration = Duration::from_secs(10);
/// The link is lost after this long without a frame.
pub const LINK_LOST_AFTER: Duration = Duration::from_secs(45);
/// How often the loop looks at its attempts' logs and results between frames.
const TICK: Duration = Duration::from_millis(100);
/// The slice root of every runner's jobs: `drgnx-runner.slice`, `drgnx-runner-work-<id>.slice`.
pub const SLICE_ROOT: &str = "drgnx-runner";
/// A unit's `RuntimeMaxSec` past the job's timeout: job-exec's own timeout writes the verdict first.
pub const UNIT_SLACK_S: u64 = 60;
/// The most log chunks one attempt sends per tick, so one busy log never starves the others.
const CHUNKS_PER_TICK: usize = 8;

/// How `serve` was started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub root: PathBuf,
    pub prefix: String,
    pub hub_id: String,
    pub profile: Profile,
    /// The machine's name in results (its host name).
    pub name: String,
    /// A cloud machine's watchdog folder (`--watchdog DIR`): `serve` writes the hub's heartbeat for it and sends what
    /// it notices (`preempting`, `idle`).
    pub watchdog: Option<PathBuf>,
}

/// Letters, digits and `-`, not at either end: a prefix and a hub id are parts of unit, slice, container and file
/// names.
fn plain(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && !s.ends_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

impl Config {
    /// `--root DIR --prefix P --hub-id H --profile dedicated|workstation [--watchdog DIR]`.
    pub fn parse(args: &[&str]) -> Result<Config, String> {
        let (mut root, mut prefix, mut hub_id, mut profile) = (None, None, None, None);
        let mut watchdog = None;
        let mut it = args.iter();
        while let Some(a) = it.next() {
            let mut val = || {
                it.next()
                    .map(|v| v.to_string())
                    .ok_or_else(|| format!("{a} needs a value"))
            };
            match *a {
                "--root" => root = Some(PathBuf::from(val()?)),
                "--prefix" => prefix = Some(val()?),
                "--hub-id" => hub_id = Some(val()?),
                "--profile" => {
                    profile = Some(match val()?.as_str() {
                        "dedicated" => Profile::Dedicated,
                        "workstation" => Profile::Workstation,
                        p => return Err(format!("--profile is dedicated or workstation, not {p}")),
                    })
                }
                "--watchdog" => {
                    let d = PathBuf::from(val()?);
                    if !d.is_absolute() {
                        return Err(format!("--watchdog must be absolute: {}", d.display()));
                    }
                    watchdog = Some(d);
                }
                other => return Err(format!("unknown option {other}")),
            }
        }
        let root = root.ok_or("--root is needed")?;
        if !root.is_absolute() {
            return Err(format!("--root must be absolute: {}", root.display()));
        }
        let prefix = prefix.ok_or("--prefix is needed")?;
        let hub_id = hub_id.ok_or("--hub-id is needed")?;
        if !plain(&prefix) || !plain(&hub_id) {
            return Err("--prefix and --hub-id are letters, digits and inner dashes".into());
        }
        let name = fs::read_to_string("/proc/sys/kernel/hostname")
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "runner".into());
        Ok(Config {
            root,
            prefix,
            hub_id,
            profile: profile.ok_or("--profile is needed")?,
            name,
            watchdog,
        })
    }

    /// This hub's scheduler name in the reservation files.
    pub fn scheduler(&self) -> String {
        format!("drgnx-{}", self.hub_id)
    }
}

fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// An attempt this `serve` knows: admitted here, or found running in the folder.
struct Live {
    dir: PathBuf,
    meta: Meta,
    /// The log offset sent up to; none until the hub attaches (a new attempt attaches at 0).
    pump: Option<u64>,
    /// Keys the hub sent that the job's helper hasn't taken yet (it is still coming up); in memory only.
    keys: Vec<Key>,
    /// What the hub's `sync-have` said the attempt's inputs are; none: it syncs nothing (an empty source).
    sync: Option<SyncIn>,
    /// The bundle being received for it, by its hash.
    bundle: Option<(Sha256, Receiver)>,
    /// Its origin fetch runs.
    fetching: bool,
    /// The deploy key or token the hub sent before `start` for its origin fetch; in memory only, gone once the fetch
    /// took it.
    origin_cred: Option<Key>,
}

impl Live {
    fn new(dir: PathBuf, meta: Meta) -> Live {
        Live {
            dir,
            meta,
            pump: None,
            keys: vec![],
            sync: None,
            bundle: None,
            fetching: false,
            origin_cred: None,
        }
    }
}

/// The origin credential of KEY for URL: a token over HTTPS (git's credential helper asks `serve` for it), else a
/// deploy key for an SSH origin.
fn origin_cred(url: &str, key: Key) -> crate::sync::cred::OriginCred {
    let value = secrecy::SecretString::from(key.value.expose().to_string());
    if url.starts_with("https://") || url.starts_with("http://") {
        crate::sync::cred::OriginCred::Https(value)
    } else {
        crate::sync::cred::OriginCred::SshKey(value)
    }
}

/// An attempt's inputs as the hub's `sync-have` names them: the commit of the repository whose mirror is REPO, and
/// the overlay.
struct SyncIn {
    repo: String,
    commit: String,
    manifest: Vec<Entry>,
}

/// A manifest entry as the slot takes it.
fn entry(e: ManifestEntry) -> Entry {
    match e {
        ManifestEntry::File {
            path,
            mode,
            sha256,
            size,
        } => Entry::File {
            path,
            mode,
            sha256: sha256.0,
            size,
        },
        ManifestEntry::Deleted { path } => Entry::Deleted { path },
    }
}

/// How many of the attempt's `key-use` lines went up as `key-use` frames (kept beside them, so a reconnect sends
/// each read once).
const KEY_USE_SENT: &str = "key-use.sent";
/// The hub's allow-list for the attempt's proxy (Linux: a Mac job has no network yet).
#[cfg(target_os = "linux")]
const NET_ALLOW: &str = "net-allow";

enum Event {
    Frame(Frame),
    End,
    Broken(String),
    /// An attempt's origin fetch ended: done, or why not.
    Fetched(JobRef, Result<(), String>),
}

/// What the loop does after a frame.
#[derive(PartialEq, Eq)]
enum Next {
    Go,
    Stop,
}

/// One `serve` process.
pub struct Serve<W: Write> {
    cfg: Config,
    w: FrameWriter<W>,
    /// The machine: everything `serve` asks of it goes through here.
    platform: Box<dyn Platform>,
    limits: Limits,
    scheduler: String,
    /// The `bin/<name>` folder this one runs from (empty outside a bundle).
    bundle: String,
    live: BTreeMap<(String, u32), Live>,
    hello: bool,
    last_start: Option<u64>,
    stop_admitting: bool,
    level2_since: Option<Instant>,
    last_kill: Option<Instant>,
    /// The jobs the ladder paused, until the pressure is gone.
    paused: BTreeSet<String>,
    /// The hub's head reserved here (its last `head` frame), which a grow leaves its room.
    head: Option<admit::HeadHere>,
    /// The CPU weights set on job slices (the others are at systemd's default).
    weights: BTreeMap<String, u32>,
    /// A P1–P2 offer was refused for CPU since the last `ready`.
    p12_waiting: bool,
    last_ready: Instant,
    last_ping: Instant,
    last_frame: Instant,
    last_units: Instant,
    /// Where a thread of this `serve` (an origin fetch) tells the loop it ended; none: such work runs in the loop.
    events: Option<mpsc::Sender<Event>>,
    /// The images the attempts it started ran in (so present here), for `ready`.
    images: BTreeSet<String>,
    /// With `--watchdog`: the heartbeat as last written, and when.
    heartbeat: crate::watchdog::Heartbeat,
    heartbeat_written: Option<Instant>,
    /// With `--watchdog`: the notice and the idle time already sent up.
    sent_preempting: bool,
    sent_idle: Option<u64>,
}

/// Runs `serve` with CFG on INPUT and OUTPUT until the link ends; the exit status.
pub fn run<R: Read + Send + 'static, W: Write>(cfg: Config, input: R, output: W) -> i32 {
    let (tx, rx) = mpsc::channel();
    let ended = tx.clone();
    std::thread::spawn(move || {
        let mut r = FrameReader::new(BufReader::new(input));
        loop {
            let ev = match r.read() {
                Ok(Some(f)) => Event::Frame(f),
                Ok(None) => Event::End,
                Err(e) => Event::Broken(e.to_string()),
            };
            let last = !matches!(ev, Event::Frame(_));
            if tx.send(ev).is_err() || last {
                break;
            }
        }
    });
    let mut s = match Serve::new(cfg, output) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("sleipnir serve: {e}");
            return 2;
        }
    };
    s.events = Some(ended);
    s.cleanup();
    loop {
        match rx.recv_timeout(TICK) {
            Ok(Event::Frame(f)) => {
                s.last_frame = Instant::now();
                s.heard(&f);
                if s.handle(f) == Next::Stop {
                    return 0;
                }
            }
            Ok(Event::Fetched(r, result)) => {
                if s.fetched(&r, result) == Next::Stop {
                    return 0;
                }
            }
            // an end without `bye` is the hub's link-lost; the attempts run on in their units
            Ok(Event::End) | Err(mpsc::RecvTimeoutError::Disconnected) => return 0,
            Ok(Event::Broken(e)) => {
                eprintln!("sleipnir serve: the channel: {e}");
                return 1;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        if s.tick() == Next::Stop {
            return 0;
        }
    }
}

impl<W: Write> Serve<W> {
    /// `serve` on this machine's platform.
    pub fn new(cfg: Config, output: W) -> Result<Serve<W>, String> {
        let exe = std::env::current_exe().map_err(|e| format!("this binary's path: {e}"))?;
        #[cfg(target_os = "linux")]
        let platform = platform::LinuxPlatform::new(&cfg, &exe)?;
        #[cfg(target_os = "macos")]
        let platform = platform::DarwinPlatform::new(&cfg, &exe)?;
        Serve::with_platform(cfg, output, Box::new(platform))
    }

    /// `serve` on PLATFORM.
    pub fn with_platform(
        cfg: Config,
        output: W,
        platform: Box<dyn Platform>,
    ) -> Result<Serve<W>, String> {
        fs::create_dir_all(attempts::jobs(&cfg.root))
            .map_err(|e| format!("{}: {e}", cfg.root.display()))?;
        let scheduler = cfg.scheduler();
        let limits = platform.limits(cfg.profile);
        let exe = std::env::current_exe().map_err(|e| format!("this binary's path: {e}"))?;
        let bin = cfg.root.join("bin");
        let bundle = exe
            .parent()
            .filter(|p| p.parent() == Some(bin.as_path()))
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let now = Instant::now();
        let mut s = Serve {
            cfg,
            w: FrameWriter::new(output),
            platform,
            limits,
            scheduler,
            bundle,
            live: BTreeMap::new(),
            hello: false,
            last_start: None,
            stop_admitting: false,
            level2_since: None,
            last_kill: None,
            paused: BTreeSet::new(),
            head: None,
            weights: BTreeMap::new(),
            p12_waiting: false,
            last_ready: now,
            last_ping: now,
            last_frame: now,
            last_units: now,
            events: None,
            images: BTreeSet::new(),
            heartbeat: Default::default(),
            heartbeat_written: None,
            sent_preempting: false,
            sent_idle: None,
        };
        s.load_running();
        Ok(s)
    }

    /// This hub's attempts in the folder.
    fn ours(&self) -> Vec<attempts::Found> {
        attempts::scan(&self.cfg.root, &|u| self.platform.active(u))
            .into_iter()
            .filter(|f| f.meta.hub_id == self.cfg.hub_id)
            .collect()
    }

    /// Takes on this hub's running attempts (another `serve` started them), so admission counts them.
    /// Its last start too: the gap between starts holds across `serve` processes.
    fn load_running(&mut self) {
        for f in self.ours() {
            self.last_start = self.last_start.max(f.meta.started);
            if f.state == AttemptState::Running {
                let key = (f.meta.r.job.clone(), f.meta.r.attempt);
                self.live.entry(key).or_insert(Live::new(f.dir, f.meta));
            }
        }
    }

    fn send(&mut self, f: &Frame) -> Next {
        match self.w.write(f) {
            Ok(()) => Next::Go,
            Err(e) => {
                eprintln!("sleipnir serve: the channel: {e}");
                Next::Stop
            }
        }
    }

    fn handle(&mut self, f: Frame) -> Next {
        match f {
            Frame::Hello { version, hub_id } => self.hello(version, &hub_id),
            Frame::Ping { at } => self.send(&Frame::Pong { at }),
            Frame::Bye { .. } => {
                let _ = self.send(&Frame::Bye {
                    why: "the hub said bye".into(),
                });
                Next::Stop
            }
            Frame::Pong { .. } | Frame::Unknown => Next::Go,
            _ if !self.hello => {
                let _ = self.send(&Frame::Bye {
                    why: "hello first".into(),
                });
                Next::Stop
            }
            Frame::Probe => self.probe_result(),
            Frame::Offer {
                r,
                spec,
                priority,
                expected,
                input_key,
                ..
            } => self.offer(r, *spec, priority, expected, input_key),
            Frame::SyncHave {
                r,
                repo,
                commit,
                manifest,
                ..
            } => self.sync_have(r, repo, commit, manifest),
            Frame::Blob {
                r,
                sha256,
                offset,
                total,
                bytes,
            } => self.blob(&r, sha256, offset, total, &bytes),
            Frame::Bundle {
                r,
                offset,
                total,
                sha256,
                bytes,
                ..
            } => self.bundle(&r, offset, total, sha256, &bytes),
            Frame::OriginFetch {
                r, repo, url, cred, ..
            } => self.origin_fetch(r, repo, url, cred),
            Frame::Start {
                r,
                image,
                env,
                net_hosts,
                pins,
                parser,
            } => self.start(&r, image, env, (net_hosts, pins), &parser),
            Frame::Attach { r, log_offset } => self.attach(&r, log_offset),
            Frame::Cancel { r } => self.cancel(&r),
            Frame::Head { at, mem_mib, cpu } => {
                self.head = (at > 0).then_some(admit::HeadHere {
                    need: forseti::Need { mem_mib, cpu },
                    at,
                });
                Next::Go
            }
            Frame::Done { r } => self.done(&r),
            Frame::Key(k) => self.key(k),
            other => {
                if let Some(line) = other.loggable() {
                    eprintln!("sleipnir serve: not handled here: {line}");
                }
                Next::Go
            }
        }
    }

    fn hello(&mut self, version: u32, hub_id: &str) -> Next {
        if hub_id != self.cfg.hub_id {
            let _ = self.send(&Frame::Bye {
                why: format!("this serve is hub {}'s, not {hub_id}'s", self.cfg.hub_id),
            });
            return Next::Stop;
        }
        if version != PROTO_VERSION {
            eprintln!(
                "sleipnir serve: the hub speaks version {version}, this runner {PROTO_VERSION}"
            );
        }
        self.hello = true;
        self.load_running();
        let missing = self.platform.contract().err().unwrap_or_default();
        let attempts = self.ours().iter().map(attempts::Found::info).collect();
        let ok = Frame::HelloOk {
            version: PROTO_VERSION,
            bundle: self.bundle.clone(),
            hub_id: self.cfg.hub_id.clone(),
            runner_id: self.cfg.name.clone(),
            boot_id: self.platform.boot_id(),
            linger: self.platform.survives_link(),
            attempts,
            missing,
        };
        if self.send(&ok) == Next::Stop {
            return Next::Stop;
        }
        self.ready()
    }

    fn probe_result(&mut self) -> Next {
        let (facts, missing) = match self.platform.contract() {
            Ok(f) => (Some(f), vec![]),
            Err(m) => (None, m),
        };
        let (limits, features) = self.platform.job_runner();
        self.send(&Frame::ProbeResult {
            facts,
            missing,
            limits,
            features,
        })
    }

    /// Our running attempts as `forseti` counts them.
    fn running_jobs(&self) -> Vec<RunningJob> {
        self.live
            .values()
            .filter_map(|l| {
                let started = l.meta.started?;
                Some(RunningJob {
                    id: JobId(l.meta.r.job.clone()),
                    priority: l.meta.priority,
                    started,
                    reserve_mib: l.meta.grant.reserve_mib,
                    current_mib: self.platform.current_mib(&l.meta.r.job).unwrap_or(0),
                    cores: l.meta.grant.cores,
                    expected: l
                        .meta
                        .expected
                        .unwrap_or_else(|| admit::unknown(&l.meta.spec)),
                    restartable: l.meta.spec.restartable,
                    evicted_once: false,
                    // the ladder pauses builds and evicts the rest
                    long_build: l.meta.spec.kind == Kind::Build,
                })
            })
            .collect()
    }

    fn ready(&mut self) -> Next {
        self.last_ready = Instant::now();
        let mut m = match self.platform.machine(now_s(), &self.limits) {
            Ok(m) => m,
            Err(e) => {
                eprintln!("sleipnir serve: the machine can't be read: {e}");
                return self.send(&Frame::Ready {
                    free_mib: 0,
                    free_cpu: 0.0,
                    psi: Default::default(),
                    running: vec![],
                    slots: vec![],
                    images: vec![],
                });
            }
        };
        m.running = self.running_jobs();
        let b = forseti::budget(&m, &self.limits);
        let running = self
            .live
            .values()
            .filter(|l| l.meta.started.is_some())
            .map(|l| l.meta.r.clone())
            .collect();
        self.ladder(&m);
        self.grow(&m.running);
        self.weigh(&m.running);
        // what makes a start warm here: the job's slot, and its image
        let images = self.images.iter().cloned().collect();
        self.send(&Frame::Ready {
            free_mib: b.mem_mib,
            free_cpu: b.cpu,
            psi: m.psi,
            running,
            slots: slot::present(&self.cfg.root),
            images,
        })
    }

    /// The runner-wide ladder on our slice tree: tight stops admissions; at pressure and danger the scheduler
    /// holding the most memory evicts (dedicated) or kills our newest (workstation), writing the reason first.
    fn ladder(&mut self, m: &forseti::MachineState) {
        let level = forseti::ladder_level(m, &self.limits);
        self.stop_admitting = level != Level::Normal;
        if level < Level::Pressure {
            self.level2_since = None;
            // the pressure is gone: the paused builds go on
            for id in std::mem::take(&mut self.paused) {
                if let Err(e) = self.platform.unpause(&id) {
                    eprintln!("sleipnir serve: {e}");
                }
            }
            return;
        }
        let since = *self.level2_since.get_or_insert_with(Instant::now);
        if !forseti::ladder_acts(&self.scheduler, &m.running, &m.others) {
            return;
        }
        let acts = forseti::ladder_actions(
            level,
            self.cfg.profile,
            &m.running,
            since.elapsed().as_secs(),
            self.last_kill.map(|k| k.elapsed().as_secs()),
        );
        for a in acts {
            let (id, reason) = match &a {
                Action::Evict(id) => (id, jobexec::EVICTED.to_string()),
                Action::Kill(id) => (id, format!("infra: {}", infra::KILLED)),
                // a long build pauses (dedicated only); it is disturbed, so its red is suspect
                Action::Pause(id) if self.cfg.profile == Profile::Dedicated => {
                    self.pause(&id.0);
                    continue;
                }
                Action::Pause(_) | Action::StopAdmitting => continue,
            };
            if let Some(l) = self.live.values().find(|l| l.meta.r.job == id.0) {
                eprintln!("sleipnir serve: the ladder at {level:?}: {reason} {}", id.0);
                if matches!(a, Action::Evict(_)) {
                    let _ = jobexec::disturbed(&l.dir, "evicted");
                }
                self.kill(&l.dir.clone(), &l.meta.r.job.clone(), &reason);
                self.last_kill = Some(Instant::now());
            }
        }
    }

    /// Pauses job ID once, marking its attempt disturbed first.
    fn pause(&mut self, id: &str) {
        let Some(l) = self.live.values().find(|l| l.meta.r.job == id) else {
            return;
        };
        if self.paused.contains(id) {
            return;
        }
        let _ = jobexec::disturbed(&l.dir, "paused");
        match self.platform.pause(id) {
            Ok(()) => {
                eprintln!("sleipnir serve: the ladder pauses {id}");
                self.paused.insert(id.to_string());
            }
            Err(e) => eprintln!("sleipnir serve: {e}"),
        }
    }

    /// Grows each running job near its cap while the machine has room ([`admit::grow`]; the platform says which are
    /// near, [`Platform::grow_candidate`]). The grown grant is recorded in the attempt's folder.
    fn grow(&mut self, ours: &[RunningJob]) {
        let keys: Vec<(String, u32)> = self
            .live
            .iter()
            .filter(|(_, l)| l.meta.started.is_some() && !l.dir.join(RESULT).exists())
            .map(|(k, _)| k.clone())
            .collect();
        for key in keys {
            let Some(l) = self.live.get(&key) else {
                continue;
            };
            let id = l.meta.r.job.clone();
            if self.paused.contains(&id) {
                continue;
            }
            let Some(job) = self.platform.grow_candidate(
                &id,
                l.meta.grant.mem_cap_mib,
                l.meta.spec.mem_mib.max,
            ) else {
                continue;
            };
            let g = admit::Grow {
                job,
                reservation: admit::reservation_job(&id, l.meta.r.attempt),
                head: self.head,
            };
            match admit::grow(
                &*self.platform,
                &self.limits,
                &self.scheduler,
                ours,
                now_s(),
                &g,
                |r| self.platform.resize(r),
            ) {
                Ok(Some(r)) => {
                    eprintln!(
                        "sleipnir serve: {id} grows from {} to {} MiB",
                        r.from_mib, r.to_mib
                    );
                    if let Some(l) = self.live.get_mut(&key) {
                        l.meta.grant.mem_cap_mib = r.to_mib;
                        l.meta.grant.reserve_mib += r.delta_mib();
                        if let Err(e) = attempts::write_meta(&l.dir, &l.meta) {
                            eprintln!("sleipnir serve: {id}'s grown grant: {e}");
                        }
                    }
                }
                Ok(None) => {}
                Err(e) => eprintln!("sleipnir serve: {id} can't grow: {}", e.why),
            }
        }
    }

    /// Running P4–P5 jobs yield CPU while a P1–P2 offer was refused for CPU since the last `ready`
    /// ([`resize::weights`]); a weight is set only when it changes.
    fn weigh(&mut self, ours: &[RunningJob]) {
        let running: Vec<(String, forseti::Priority)> = ours
            .iter()
            .filter_map(|r| Some((self.platform.weight_unit(&r.id.0)?, r.priority)))
            .collect();
        let want = resize::weights(&running, std::mem::take(&mut self.p12_waiting));
        self.weights.retain(|u, _| want.iter().any(|(w, _)| w == u));
        for (unit, w) in want {
            if self
                .weights
                .get(&unit)
                .copied()
                .unwrap_or(resize::WEIGHT_NORMAL)
                == w
            {
                continue;
            }
            match self.platform.set_weight(&unit, w) {
                Ok(()) => {
                    self.weights.insert(unit, w);
                }
                Err(e) => eprintln!("sleipnir serve: {e}"),
            }
        }
    }

    /// Writes REASON in DIR, then kills job ID's command: job-exec sees it end and writes the verdict the reason
    /// names.
    fn kill(&self, dir: &Path, id: &str, reason: &str) {
        if let Err(e) = jobexec::kill_reason(dir, reason) {
            eprintln!("sleipnir serve: the kill reason of {id}: {e}");
        }
        if let Err(e) = self.platform.kill(id) {
            eprintln!("sleipnir serve: {e}");
        }
    }

    fn refuse(&mut self, r: JobRef, why: impl Into<String>) -> Next {
        self.send(&Frame::Refuse {
            r,
            why: why.into(),
            reason: None,
        })
    }

    fn offer(
        &mut self,
        r: JobRef,
        spec: forseti::JobSpec,
        priority: forseti::Priority,
        expected: Option<forseti::Expected>,
        input_key: String,
    ) -> Next {
        if r.job.is_empty() || !r.job.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return self.refuse(r, "a job id is letters and digits");
        }
        // a slot moves to new inputs only once no running job reads it at others (a writer reads its own copy)
        let slot = SlotKey::of(&spec).id();
        let busy = !input_key.is_empty()
            && self.live.values().any(|l| {
                l.meta.started.is_some()
                    && !l.meta.spec.writes_tree
                    && l.meta.slot.as_deref() == Some(slot.as_str())
                    && l.meta.input_key != input_key
                    && !l.dir.join(RESULT).exists()
            });
        if busy {
            return self.refuse(r, "its checkout slot is in use by a job at other inputs");
        }
        let dir = attempts::dir(&self.cfg.root, &r.job, r.attempt);
        if let Ok(meta) = attempts::read_meta(&dir) {
            // the same offer again (a lost answer): the same answer; anything else in that folder stays
            if meta.hub_id == self.cfg.hub_id && meta.r == r {
                return self.send(&Frame::Admit {
                    r,
                    grant: meta.grant,
                });
            }
            return self.refuse(
                r,
                "this runner already holds that job's attempt from another placement",
            );
        }
        if self.stop_admitting {
            return self.refuse(r, "the runner's memory ladder stops admissions");
        }
        let offer = admit::Offer {
            id: &r.job,
            attempt: r.attempt,
            spec: &spec,
            priority,
            expected,
        };
        let ours = self.running_jobs();
        match admit::admit(
            &*self.platform,
            &self.limits,
            &self.scheduler,
            &ours,
            self.last_start,
            now_s(),
            &offer,
        ) {
            Err(no) => {
                // a P1–P2 job waiting for CPU: the running P4–P5 jobs yield at the next `ready`
                if no.reason == Some(forseti::WaitReason::Threads)
                    && matches!(priority, forseti::Priority::P1 | forseti::Priority::P2)
                {
                    self.p12_waiting = true;
                }
                self.send(&Frame::Refuse {
                    r,
                    why: no.why,
                    reason: no.reason,
                })
            }
            Ok(grant) => {
                let meta = Meta {
                    hub_id: self.cfg.hub_id.clone(),
                    r: r.clone(),
                    spec,
                    priority,
                    grant,
                    expected,
                    bundle: self.bundle.clone(),
                    unit: None,
                    admitted: now_s(),
                    started: None,
                    input_key,
                    slot: None,
                };
                let made = ["src", "target"]
                    .iter()
                    .try_for_each(|d| fs::create_dir_all(dir.join(d)))
                    .and_then(|()| attempts::write_meta(&dir, &meta));
                if let Err(e) = made {
                    self.unreserve(&r);
                    return self.refuse(r, format!("the attempt's folder: {e}"));
                }
                self.live
                    .insert((r.job.clone(), r.attempt), Live::new(dir, meta));
                self.send(&Frame::Admit { r, grant })
            }
        }
    }

    fn unreserve(&self, r: &JobRef) {
        let _ = self
            .platform
            .reservations()
            .remove(&self.scheduler, &admit::reservation_job(&r.job, r.attempt));
    }

    /// The live attempt R names, nonce and hub included.
    fn find(&self, r: &JobRef) -> Option<&Live> {
        self.live
            .get(&(r.job.clone(), r.attempt))
            .filter(|l| l.meta.r == *r)
    }

    fn start(
        &mut self,
        r: &JobRef,
        image: Option<String>,
        env: Vec<(String, String)>,
        (net_hosts, pins): (Vec<String>, Pins),
        parser: &str,
    ) -> Next {
        let Some(l) = self.find(r) else {
            eprintln!("sleipnir serve: start for an attempt not admitted here: {r:?}");
            return Next::Go;
        };
        if l.meta.started.is_some() || l.fetching {
            return Next::Go;
        }
        let (dir, mut meta) = (l.dir.clone(), l.meta.clone());
        // synced inputs: the attempt reads its slot (or a private copy of it); none: an empty source
        let src = match &l.sync {
            Some(s) => self.checkout(&dir, &meta, s).map(|(src, id)| {
                meta.slot = Some(id);
                src
            }),
            None => Ok(dir.join("src")),
        };
        let ran_in = image.clone();
        let launched = src.and_then(|src| {
            self.platform.launch(&LaunchReq {
                dir: &dir,
                meta: &meta,
                src: &src,
                image,
                env: &env,
                net_hosts: &net_hosts,
                pins,
                parser,
            })
        });
        match launched {
            Ok((unit, pid)) => {
                let at = now_s();
                meta.unit = Some(unit.clone());
                meta.started = Some(at);
                if let Err(e) = attempts::write_meta(&dir, &meta) {
                    eprintln!("sleipnir serve: the attempt's record: {e}");
                }
                self.hand_reservation(&meta, pid);
                self.last_start = Some(at);
                self.images.extend(ran_in);
                if let Some(l) = self.live.get_mut(&(r.job.clone(), r.attempt)) {
                    l.meta = meta;
                    l.pump = Some(0);
                }
                self.send(&Frame::Started {
                    r: r.clone(),
                    unit,
                    at,
                })
            }
            Err(why) => {
                // never run some other way: the attempt ends `infra: setup`, with the reason in its log
                self.setup_failed(&dir, &meta, &why);
                if let Some(l) = self.live.get_mut(&(r.job.clone(), r.attempt)) {
                    l.pump = Some(0);
                }
                Next::Go
            }
        }
    }

    /// Moves the attempt's slot to its synced inputs S (the slot's update lock held meanwhile): the source it runs on,
    /// the slot itself (read-only) or a private copy of it in DIR for a job that writes the tree, and the slot's id.
    fn checkout(&self, dir: &Path, meta: &Meta, s: &SyncIn) -> Result<(PathBuf, String), String> {
        let root = &self.cfg.root;
        let key = SlotKey::of(&meta.spec);
        let p = slot::paths(root, &key);
        let sync_err = |e: crate::sync::SyncError| format!("the checkout: {e}");
        let m = Mirror::ensure(root, &s.repo).map_err(sync_err)?;
        let store = Store::open(root).map_err(|e| format!("the blob store: {e}"))?;
        {
            let locks = slot::Locks::of(&p);
            let _held = locks.update().map_err(sync_err)?;
            let overlay = Overlay {
                entries: &s.manifest,
                extras: &[],
                blobs: &store,
            };
            slot::update(&p, &m.git_dir, &s.commit, &overlay).map_err(sync_err)?;
        }
        let src = if meta.spec.writes_tree {
            let copy = dir.join("tree");
            slot::private_copy(&p, &copy).map_err(sync_err)?;
            // what the job's changes are read against at its end: the slot as it is now, which another attempt may
            // move meanwhile (a reflink where the file system has them)
            if !meta.spec.writes.is_empty() {
                slot::private_copy(&p, &dir.join(BASE)).map_err(sync_err)?;
            }
            copy
        } else {
            p.slot
        };
        Ok((src, key.id()))
    }

    /// The attempt's reservation passes to its job-exec (PID), which outlives this `serve`.
    fn hand_reservation(&self, meta: &Meta, pid: u32) {
        let Ok(start_time) = self.platform.start_time(pid) else {
            eprintln!(
                "sleipnir serve: {}'s job-exec pid {pid}: its reservation stays with this serve",
                meta.r.job
            );
            return;
        };
        let r = Reservation {
            scheduler: self.scheduler.clone(),
            pid,
            boot_id: self.platform.boot_id(),
            start_time,
            job: admit::reservation_job(&meta.r.job, meta.r.attempt),
            reserve_mib: meta.grant.reserve_mib,
            current_mib: 0,
            expires: now_s() + meta.spec.timeout_s + admit::RESERVATION_SLACK_S,
        };
        if let Err(e) = self.platform.reservations().put(&r) {
            eprintln!("sleipnir serve: the reservation of {}: {e}", meta.r.job);
        }
    }

    /// Ends an attempt that couldn't start: `infra: setup`, the reason in its log.
    fn setup_failed(&self, dir: &Path, meta: &Meta, why: &str) {
        eprintln!("sleipnir serve: {}: {why}", meta.r.job);
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join(LOG))
            .and_then(|mut f| writeln!(f, "sleipnir serve: the attempt can't start: {why}"));
        self.write_result(dir, meta, Verdict::Infra(infra::SETUP.into()));
    }

    fn write_result(&self, dir: &Path, meta: &Meta, verdict: Verdict) {
        let infra = match &verdict {
            Verdict::Infra(why) => Some(format!("infra: {why}")),
            _ => None,
        };
        let r = ResultJson {
            verdict,
            infra,
            counts: Default::default(),
            rows: vec![],
            failing: vec![],
            machine: self.cfg.name.clone(),
            grant: meta.grant,
            wall_s: 0.0,
            cpu_s: 0.0,
            mem_peak_mib: 0,
            disturbed: false,
            log: dir.join(LOG).display().to_string(),
        };
        if let Err(e) = r.write(dir) {
            eprintln!("sleipnir serve: {}'s result: {e}", meta.r.job);
        }
    }

    fn attach(&mut self, r: &JobRef, offset: u64) -> Next {
        let key = (r.job.clone(), r.attempt);
        if !self.live.contains_key(&key) {
            // a finished attempt of ours, from an earlier serve
            let dir = attempts::dir(&self.cfg.root, &r.job, r.attempt);
            match attempts::read_meta(&dir) {
                Ok(meta) if meta.hub_id == self.cfg.hub_id && meta.r == *r => {
                    self.live.insert(key.clone(), Live::new(dir, meta));
                }
                _ => {
                    eprintln!(
                        "sleipnir serve: attach for an attempt this runner doesn't hold: {r:?}"
                    );
                    return Next::Go;
                }
            }
        }
        match self.live.get_mut(&key) {
            Some(l) if l.meta.r == *r => l.pump = Some(offset),
            _ => eprintln!("sleipnir serve: attach with another nonce: {r:?}"),
        }
        Next::Go
    }

    fn cancel(&mut self, r: &JobRef) -> Next {
        let Some(l) = self.find(r) else {
            return Next::Go;
        };
        let (dir, meta) = (l.dir.clone(), l.meta.clone());
        let _ = fs::write(dir.join(CANCELLED), b"");
        if meta.started.is_some() {
            self.kill(&dir, &meta.r.job, "cancelled");
        } else {
            self.unreserve(r);
            self.write_result(&dir, &meta, Verdict::Cancelled);
            if let Some(l) = self.live.get_mut(&(r.job.clone(), r.attempt)) {
                l.pump = Some(0);
            }
        }
        Next::Go
    }

    fn done(&mut self, r: &JobRef) -> Next {
        let dir = attempts::dir(&self.cfg.root, &r.job, r.attempt);
        match attempts::read_meta(&dir) {
            Ok(meta) if meta.hub_id == self.cfg.hub_id && meta.r == *r => {
                let _ = fs::write(dir.join(COLLECTED), b"");
                self.live.remove(&(r.job.clone(), r.attempt));
                self.cleanup();
            }
            _ => eprintln!("sleipnir serve: done for an attempt this runner doesn't hold: {r:?}"),
        }
        Next::Go
    }

    /// A key for a started attempt of ours goes to its job helper, now or once the helper listens; it is never
    /// written, logged or kept past the attempt. Only its name is ever said.
    fn key(&mut self, k: Key) -> Next {
        let key = (k.r.job.clone(), k.r.attempt);
        match self.live.get_mut(&key) {
            Some(l) if l.meta.r == k.r && l.meta.started.is_some() => {
                l.keys.push(k);
                self.hand_keys(&key);
            }
            // before `start`: the deploy key of the origin fetch that follows, never the job's
            Some(l) if l.meta.r == k.r && l.sync.is_some() && !l.fetching => {
                l.origin_cred = Some(k);
            }
            _ => eprintln!(
                "sleipnir serve: key {} for {:?}: not a started attempt of this hub's",
                k.name, k.r
            ),
        }
        Next::Go
    }

    /// Hands the attempt's waiting keys to its helper; a key stays while the helper isn't listening yet, and goes
    /// once the helper took or refused it.
    fn hand_keys(&mut self, key: &(String, u32)) {
        let Some(l) = self.live.get_mut(key) else {
            return;
        };
        let platform = &self.platform;
        let dir = l.dir.clone();
        l.keys.retain(
            |k| match platform.hand_key(&dir, &k.name, k.value.expose().as_bytes()) {
                Ok(()) => false,
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) =>
                {
                    true
                }
                Err(e) => {
                    eprintln!("sleipnir serve: key {} for {}: {e}", k.name, k.r.job);
                    false
                }
            },
        );
    }

    /// Sends the attempt's new `key-use` lines (names and times only) as `key-use` frames, each once.
    fn send_key_uses(&mut self, dir: &Path, r: &JobRef) -> Next {
        let Ok(text) = fs::read_to_string(dir.join(KEY_USE)) else {
            return Next::Go;
        };
        let sent: usize = fs::read_to_string(dir.join(KEY_USE_SENT))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0);
        let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
        for (i, line) in lines.iter().enumerate().skip(sent) {
            let v: serde_json::Value = serde_json::from_str(line).unwrap_or_default();
            let frame = Frame::KeyUse {
                r: r.clone(),
                name: v["name"].as_str().unwrap_or_default().to_string(),
                at: v["at"].as_u64().unwrap_or(0),
            };
            if self.send(&frame) == Next::Stop {
                return Next::Stop;
            }
            let _ = fs::write(dir.join(KEY_USE_SENT), (i + 1).to_string());
        }
        Next::Go
    }

    /// The admitted attempt R that hasn't started yet, by its folder's key, nonce and hub included.
    fn syncing(&self, r: &JobRef) -> Option<(String, u32)> {
        let key = (r.job.clone(), r.attempt);
        self.live
            .get(&key)
            .filter(|l| l.meta.r == *r && l.meta.started.is_none() && !l.dir.join(RESULT).exists())
            .map(|_| key)
    }

    /// The hub's `sync-have` for attempt R: the repository whose mirror is REPO, COMMIT and the overlay MANIFEST. The
    /// answer says what the runner lacks.
    fn sync_have(
        &mut self,
        r: JobRef,
        repo: String,
        commit: String,
        manifest: Vec<ManifestEntry>,
    ) -> Next {
        let Some(key) = self.syncing(&r) else {
            eprintln!("sleipnir serve: sync-have for an attempt not waiting here: {r:?}");
            return Next::Go;
        };
        if let Err(e) = mirror::check_id(&repo) {
            return self.sync_failed(&key, &format!("the repository id: {e}"));
        }
        if let Some(l) = self.live.get_mut(&key) {
            l.sync = Some(SyncIn {
                repo,
                commit,
                manifest: manifest.into_iter().map(entry).collect(),
            });
        }
        self.sync_need(&r)
    }

    /// Says what attempt R still lacks of its inputs: the overlay's blobs the store hasn't, whether the mirror lacks
    /// the commit, and the commits the mirror's refs hold.
    fn sync_need(&mut self, r: &JobRef) -> Next {
        let Some(key) = self.syncing(r) else {
            return Next::Go;
        };
        let Some(s) = self.live.get(&key).and_then(|l| l.sync.as_ref()) else {
            return Next::Go;
        };
        let root = &self.cfg.root;
        let need = (|| -> crate::sync::Result<(Vec<Sha256>, bool, Vec<String>)> {
            let m = Mirror::ensure(root, &s.repo)?;
            let store = Store::open(root)?;
            let shas: Vec<[u8; 32]> = s
                .manifest
                .iter()
                .filter_map(|e| match e {
                    Entry::File { sha256, .. } => Some(*sha256),
                    Entry::Deleted { .. } => None,
                })
                .collect();
            let blobs = store.missing(&shas).into_iter().map(Sha256).collect();
            Ok((blobs, !m.has_commit(&s.commit)?, m.ref_tips()?))
        })();
        match need {
            Ok((blobs, commit, refs)) => self.send(&Frame::SyncNeed {
                r: r.clone(),
                blobs,
                commit,
                refs,
            }),
            Err(e) => self.sync_failed(&key, &e.to_string()),
        }
    }

    /// One chunk of blob SHA for attempt R, at OFFSET of TOTAL bytes (0: the bytes are the whole blob). A blob is
    /// kept only whole and when its bytes hash to its name; a chunk that doesn't fit is dropped, and the next
    /// `sync-need` asks for the blob again.
    fn blob(&mut self, r: &JobRef, sha: Sha256, offset: u64, total: u64, bytes: &[u8]) -> Next {
        if self.syncing(r).is_none() {
            eprintln!("sleipnir serve: a blob for an attempt not waiting here: {r:?}");
            return Next::Go;
        }
        let root = &self.cfg.root;
        let kept = (|| -> crate::sync::Result<()> {
            let store = Store::open(root)?;
            if total == 0 || (offset == 0 && bytes.len() as u64 == total) {
                return store.put(&sha.0, bytes);
            }
            let part = root
                .join("blobs")
                .join(format!(".{}.part", crate::sync::hex(&sha.0)));
            let mut f = if offset == 0 {
                fs::File::create(&part)?
            } else {
                fs::OpenOptions::new().append(true).open(&part)?
            };
            let end = offset + bytes.len() as u64;
            if f.metadata()?.len() != offset || end > total {
                let _ = fs::remove_file(&part);
                return Err(crate::sync::refused(
                    part.as_os_str().as_encoded_bytes(),
                    "a blob's chunk out of order",
                ));
            }
            f.write_all(bytes)?;
            if end == total {
                let whole = fs::read(&part);
                let _ = fs::remove_file(&part);
                store.put(&sha.0, &whole?)?;
            }
            Ok(())
        })();
        if let Err(e) = kept {
            eprintln!("sleipnir serve: {}'s blob: {e}", r.job);
        }
        Next::Go
    }

    /// A chunk of the bundle (by its hash SHA) at OFFSET of TOTAL for attempt R: appended to the partial file, which
    /// a dropped link leaves to resume from; the whole bundle is checked and fetched into the mirror, then the attempt
    /// says again what it lacks.
    fn bundle(
        &mut self,
        r: &JobRef,
        offset: u64,
        total: u64,
        sha: Option<Sha256>,
        bytes: &[u8],
    ) -> Next {
        let Some(key) = self.syncing(r) else {
            eprintln!("sleipnir serve: a bundle for an attempt not waiting here: {r:?}");
            return Next::Go;
        };
        let root = self.cfg.root.clone();
        let Some(l) = self.live.get_mut(&key) else {
            return Next::Go;
        };
        let (Some(sha), Some(repo)) = (sha, l.sync.as_ref().map(|s| s.repo.clone())) else {
            eprintln!("sleipnir serve: a bundle chunk without its hash or its inputs: {r:?}");
            return Next::Go;
        };
        if l.bundle.as_ref().is_none_or(|(s, _)| *s != sha) {
            let want = BundleRef {
                sha256: sha.0,
                size: total,
            };
            match Receiver::open(&root, &repo, want) {
                Ok(rx) => l.bundle = Some((sha, rx)),
                Err(e) => return self.sync_failed(&key, &format!("the bundle: {e}")),
            }
        }
        let Some((_, rx)) = l.bundle.as_mut() else {
            return Next::Go;
        };
        let held = rx.offset();
        if offset > held {
            // a gap: this chunk is dropped; the hub sends the bundle again from its start, and what is held is skipped
            eprintln!("sleipnir serve: a bundle chunk at {offset}, past the {held} bytes held");
            return Next::Go;
        }
        let skip = (held - offset) as usize;
        if skip < bytes.len()
            && let Err(e) = rx.append(&bytes[skip..])
        {
            l.bundle = None;
            return self.sync_failed(&key, &format!("the bundle: {e}"));
        }
        if rx.offset() < total {
            return Next::Go;
        }
        let Some((_, rx)) = l.bundle.take() else {
            return Next::Go;
        };
        match rx.finish() {
            Ok(()) => self.sync_need(r),
            Err(e) => self.sync_failed(&key, &format!("the bundle: {e}")),
        }
    }

    /// The hub's `origin-fetch` for attempt R: the mirror REPO fetches from URL in a thread of its own (pings go on
    /// meanwhile); its end comes back to the loop ([`Serve::fetched`]).
    fn origin_fetch(&mut self, r: JobRef, repo: String, url: String, cred: Option<String>) -> Next {
        let Some(key) = self.syncing(&r) else {
            eprintln!("sleipnir serve: origin-fetch for an attempt not waiting here: {r:?}");
            return Next::Go;
        };
        let Some(l) = self.live.get_mut(&key) else {
            return Next::Go;
        };
        if l.sync.as_ref().is_none_or(|s| s.repo != repo) {
            return self.sync_failed(&key, "an origin fetch for another repository");
        }
        if l.fetching {
            return Next::Go;
        }
        // the credential the fetch names came in the `key` frame before it; it goes with the fetch
        let held = l.origin_cred.take();
        let cred = match (cred, held) {
            (None, _) => None,
            (Some(name), Some(k)) if k.name == name => Some(origin_cred(&url, k)),
            (Some(name), _) => {
                let why = format!("the origin fetch names the key {name}, which didn't come");
                return self.sync_failed(&key, &why);
            }
        };
        let Some(l) = self.live.get_mut(&key) else {
            return Next::Go;
        };
        l.fetching = true;
        let root = self.cfg.root.clone();
        let fetch = move || {
            Mirror::ensure(&root, &repo)
                .and_then(|m| m.fetch_origin(&url, cred))
                .map_err(|e| e.to_string())
        };
        match self.events.clone() {
            Some(tx) => {
                std::thread::spawn(move || {
                    let _ = tx.send(Event::Fetched(r, fetch()));
                });
                Next::Go
            }
            None => {
                let done = fetch();
                self.fetched(&r, done)
            }
        }
    }

    /// Attempt R's origin fetch ended: the attempt says again what it lacks, or ends `infra: setup` saying why.
    fn fetched(&mut self, r: &JobRef, result: Result<(), String>) -> Next {
        let key = (r.job.clone(), r.attempt);
        if let Some(l) = self.live.get_mut(&key) {
            l.fetching = false;
        }
        match result {
            Ok(()) => self.sync_need(r),
            Err(e) => match self.syncing(r) {
                Some(key) => self.sync_failed(&key, &format!("the origin fetch: {e}")),
                None => Next::Go,
            },
        }
    }

    /// The attempt at KEY can't get its inputs: it ends `infra: setup`, with WHY in its log; its result goes to the
    /// hub as any other.
    fn sync_failed(&mut self, key: &(String, u32), why: &str) -> Next {
        let Some(l) = self.live.get(key) else {
            return Next::Go;
        };
        let (dir, meta) = (l.dir.clone(), l.meta.clone());
        self.setup_failed(&dir, &meta, &format!("its inputs: {why}"));
        if let Some(l) = self.live.get_mut(key) {
            l.pump = Some(0);
            l.bundle = None;
        }
        Next::Go
    }

    fn cleanup(&self) {
        let owner = cleanup::Owner {
            hub_id: &self.cfg.hub_id,
            prefix: &self.cfg.prefix,
            own_bundle: &self.bundle,
        };
        self.platform.cleanup(&self.cfg.root, &owner);
    }

    /// A frame from the hub: with `--watchdog`, the heartbeat the watchdog reads (`contact` at every frame, `offer` at
    /// every offer), written at most every 5 s unless an offer came.
    fn heard(&mut self, f: &Frame) {
        if self.cfg.watchdog.is_none() {
            return;
        }
        let now = now_s();
        self.heartbeat.contact = now;
        let offer = matches!(f, Frame::Offer { .. });
        if offer {
            self.heartbeat.offer = now;
        }
        let due = self
            .heartbeat_written
            .is_none_or(|t| t.elapsed() >= crate::watchdog::POLL);
        if !offer && !due {
            return;
        }
        let path = self.cfg.root.join(crate::watchdog::HEARTBEAT);
        let tmp = self
            .cfg
            .root
            .join(format!(".{}.tmp", crate::watchdog::HEARTBEAT));
        let body = serde_json::to_vec(&self.heartbeat).unwrap_or_default();
        match fs::write(&tmp, body).and_then(|()| fs::rename(&tmp, &path)) {
            Ok(()) => self.heartbeat_written = Some(Instant::now()),
            Err(e) => eprintln!("sleipnir serve: the heartbeat {}: {e}", path.display()),
        }
    }

    /// With `--watchdog`: what it noticed, sent up once each: the provider's notice as `preempting {at}`, the idle
    /// time as `idle {since}` (GCP, where the hub ends the machine).
    fn watchdog_news(&mut self) -> Next {
        let Some(dir) = self.cfg.watchdog.clone() else {
            return Next::Go;
        };
        let read = |name: &str| -> Option<u64> {
            crate::watchdog::read_small(&dir.join(name))?
                .trim()
                .parse()
                .ok()
        };
        if !self.sent_preempting
            && let Some(at) = read(crate::watchdog::PREEMPTING)
        {
            self.sent_preempting = true;
            if self.send(&Frame::Preempting { at }) == Next::Stop {
                return Next::Stop;
            }
        }
        let idle = read(crate::watchdog::IDLE);
        if idle != self.sent_idle {
            self.sent_idle = idle;
            if let Some(since) = idle {
                return self.send(&Frame::Idle { since });
            }
        }
        Next::Go
    }

    fn tick(&mut self) -> Next {
        if self.last_frame.elapsed() >= LINK_LOST_AFTER {
            eprintln!(
                "sleipnir serve: no frame for {} s: the link is lost",
                LINK_LOST_AFTER.as_secs()
            );
            return Next::Stop;
        }
        if !self.hello {
            return Next::Go;
        }
        if self.last_ping.elapsed() >= PING_EVERY {
            self.last_ping = Instant::now();
            if self.send(&Frame::Ping { at: now_s() }) == Next::Stop {
                return Next::Stop;
            }
        }
        let check_units = self.last_units.elapsed() >= READY_EVERY;
        if check_units {
            self.last_units = Instant::now();
            if self.watchdog_news() == Next::Stop {
                return Next::Stop;
            }
        }
        let keys: Vec<(String, u32)> = self.live.keys().cloned().collect();
        let mut ended = false;
        for key in keys {
            match self.pump(&key, check_units) {
                Ok(true) => ended = true,
                Ok(false) => {}
                Err(()) => return Next::Stop,
            }
        }
        if ended {
            self.cleanup();
            return self.ready();
        }
        if self.last_ready.elapsed() >= READY_EVERY {
            return self.ready();
        }
        Next::Go
    }

    /// Sends what the attempt's log has past its offset; once it has a result and the log is all sent, its rows and
    /// `finished`. True when it finished; an error when the channel broke.
    fn pump(&mut self, key: &(String, u32), check_unit: bool) -> Result<bool, ()> {
        let Some(l) = self.live.get(key) else {
            return Ok(false);
        };
        let (dir, meta) = (l.dir.clone(), l.meta.clone());
        let has_result = dir.join(RESULT).exists();
        if !has_result && check_unit && meta.started.is_some() {
            let up = meta
                .unit
                .as_deref()
                .is_some_and(|u| self.platform.active(u));
            // the unit ended without job-exec's result: killed from outside
            if !up && !dir.join(RESULT).exists() {
                let _ = fs::OpenOptions::new()
                    .append(true)
                    .open(dir.join(LOG))
                    .and_then(|mut f| {
                        writeln!(
                            f,
                            "sleipnir serve: the attempt's unit ended without a result"
                        )
                    });
                self.write_result(&dir, &meta, Verdict::Infra(infra::KILLED.into()));
            }
        }
        if self.live.get(key).is_some_and(|l| !l.keys.is_empty()) {
            self.hand_keys(key);
        }
        let Some(mut offset) = self.live.get(key).and_then(|l| l.pump) else {
            return Ok(false);
        };
        if self.send_key_uses(&dir, &meta.r) == Next::Stop {
            return Err(());
        }
        let has_result = dir.join(RESULT).exists();
        let mut sent = 0;
        let mut at_end = false;
        if let Ok(mut f) = fs::File::open(dir.join(LOG)) {
            let len = f.metadata().map(|m| m.len()).unwrap_or(0);
            while sent < CHUNKS_PER_TICK {
                let want = len.saturating_sub(offset).min(MAX_CHUNK as u64) as usize;
                if want == 0 {
                    at_end = true;
                    break;
                }
                let mut buf = vec![0u8; want];
                let n = f
                    .seek(SeekFrom::Start(offset))
                    .and_then(|_| read_some(&mut f, &mut buf))
                    .unwrap_or(0);
                if n == 0 {
                    at_end = true;
                    break;
                }
                buf.truncate(n);
                let frame = Frame::Log {
                    r: meta.r.clone(),
                    offset,
                    bytes: buf,
                };
                if self.send(&frame) == Next::Stop {
                    return Err(());
                }
                offset += n as u64;
                sent += 1;
            }
        } else {
            at_end = true;
        }
        if let Some(l) = self.live.get_mut(key) {
            l.pump = Some(offset);
        }
        if !(has_result && at_end) {
            return Ok(false);
        }
        self.finish(key, &dir, &meta).map(|()| true)
    }

    fn finish(&mut self, key: &(String, u32), dir: &Path, meta: &Meta) -> Result<(), ()> {
        let mut result: serde_json::Value = fs::read(dir.join(RESULT))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(serde_json::Value::Null);
        if dir.join(CANCELLED).exists()
            && let Some(o) = result.as_object_mut()
        {
            // the hub's own cancel: whatever the kill made of it
            o.insert("verdict".into(), serde_json::json!("Cancelled"));
            o.insert("infra".into(), serde_json::Value::Null);
            let _ = fs::write(
                dir.join(RESULT),
                serde_json::to_vec_pretty(&result).unwrap_or_default(),
            );
        }
        if self.give_back(&meta.r, dir, &meta.spec) == Next::Stop {
            return Err(());
        }
        let rows = result["rows"].as_array().cloned().unwrap_or_default();
        for row in rows {
            let frame = Frame::Row {
                r: meta.r.clone(),
                name: row["name"].as_str().unwrap_or_default().to_string(),
                verdict: row["verdict"].as_str().unwrap_or_default().to_string(),
            };
            if self.send(&frame) == Next::Stop {
                return Err(());
            }
        }
        self.unreserve(&meta.r);
        self.live.remove(key);
        if self.send(&Frame::Finished {
            r: meta.r.clone(),
            result,
        }) == Next::Stop
        {
            return Err(());
        }
        Ok(())
    }
}

/// The pristine copy of the slot a job that writes the tree is compared with at its end, in the attempt's folder.
const BASE: &str = "base";
/// A returned patch larger than this stays on the runner, for a `fetch` (the hub's limit too).
pub const PATCH_MAX: u64 = 16 << 20;
/// Returned outputs larger than this stay on the runner, for a `fetch`.
pub const OUTPUTS_MAX: u64 = 256 << 20;

impl<W: Write> Serve<W> {
    /// What attempt R of a job that wrote its private copy gives back, before its `finished`: its changes to SPEC's
    /// `writes` as a patch, and its `outputs` and `reports/` as an archive (`sync::returned`), each written beside
    /// the attempt (`returned.patch`, `returned.tar`, for a `fetch`) and sent in `returned` pieces; one over its limit
    /// is only named (`kept`). Nothing for a job that writes nothing.
    fn give_back(&mut self, r: &JobRef, dir: &Path, spec: &forseti::JobSpec) -> Next {
        use crate::sync::returned;
        if !spec.writes_tree {
            return Next::Go;
        }
        let copy = dir.join("tree");
        let unread = |e: io::Error| {
            (
                Vec::new(),
                vec![(String::new(), format!("could not be read: {e}"))],
            )
        };
        let mut parts = Vec::new();
        if !spec.writes.is_empty() {
            let c = returned::changes(&dir.join(BASE), &copy, &spec.writes)
                .map_or_else(unread, |c| (c.patch, c.left));
            parts.push(("patch", "returned.patch", PATCH_MAX, c));
        }
        let o = returned::outputs(&copy, &spec.outputs).map_or_else(unread, |o| (o.tar, o.left));
        parts.push(("outputs", "returned.tar", OUTPUTS_MAX, o));
        for (what, file, max, (bytes, left)) in parts {
            if let Err(e) = fs::write(dir.join(file), &bytes) {
                eprintln!("sleipnir serve: {}: {e}", dir.join(file).display());
            }
            let total = bytes.len() as u64;
            let kept = total > max;
            let sha256 = Sha256(crate::sync::sha256(&bytes));
            let mut offset = 0usize;
            let mut left = Some(left);
            loop {
                let end = if kept {
                    0
                } else {
                    (offset + MAX_CHUNK).min(bytes.len())
                };
                let frame = Frame::Returned {
                    r: r.clone(),
                    what: what.into(),
                    offset: offset as u64,
                    total,
                    sha256,
                    left: left.take().unwrap_or_default(),
                    kept,
                    bytes: if kept {
                        Vec::new()
                    } else {
                        bytes[offset..end].to_vec()
                    },
                };
                if self.send(&frame) == Next::Stop {
                    return Next::Stop;
                }
                if kept || end >= bytes.len() {
                    break;
                }
                offset = end;
            }
        }
        Next::Go
    }
}

/// One read into BUF, retried on an interrupt.
fn read_some(f: &mut fs::File, buf: &mut [u8]) -> io::Result<usize> {
    loop {
        match f.read(buf) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            other => return other,
        }
    }
}

/// The grant a test fixture uses.
/// Names a job's proxy resolves to a fixed address (`Frame::Start`'s `pins`).
pub type Pins = Vec<(String, std::net::IpAddr)>;

#[cfg(test)]
pub(crate) fn tests_spec() -> forseti::JobSpec {
    use forseti::{Expect, JobTrust, Kind, Lane, Range, Weight};
    forseti::JobSpec {
        os: Default::default(),
        name: "t".into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::from("/src/p"),
        cwd: PathBuf::from("."),
        command: vec!["true".into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 1 },
        mem_mib: Range { min: 128, max: 256 },
        disk_gib: 0,
        timeout_s: 60,
        restartable: true,
        writes_tree: false,
        priority: None,
        for_user: None,
        gate: None,
        expect: Expect::default(),
        outputs: vec![],
        state: vec![],
        on: None,
        lane: Lane::Work,
        fresh: false,
        stop_on_red: false,
        project: "p".into(),
        trust: JobTrust::Private,
        keys: vec![],
        local_only: false,
        writes: vec![],
    }
}

#[cfg(all(test, target_os = "linux"))]
mod caps_tests {
    use super::platform::job_caps;
    use super::*;
    use crate::proto::Nonce;

    /// Pattern D.  The pins the hub sends with a start reach the job's caps, which its proxy pins by; a start from an
    /// older hub, which has no `pins`, still reads, with none.
    #[test]
    fn a_starts_pins_reach_the_jobs_caps() {
        let pins: Pins = vec![("registry.corp".into(), "10.0.0.5".parse().unwrap())];
        let grant = forseti::Grant {
            cores: 1,
            mem_cap_mib: 256,
            reserve_mib: 128,
        };
        assert_eq!(job_caps(&grant, "img".into(), pins.clone()).pins, pins);
        let start = Frame::Start {
            r: JobRef {
                job: "a3f".into(),
                attempt: 1,
                nonce: Nonce([1; 16]),
            },
            image: None,
            env: vec![],
            net_hosts: vec![],
            pins,
            parser: String::new(),
        };
        let mut v = serde_json::to_value(&start).unwrap();
        v.as_object_mut().unwrap().remove("pins");
        let old: Frame = serde_json::from_value(v).unwrap();
        assert!(matches!(old, Frame::Start { pins, .. } if pins.is_empty()));
    }
}

#[cfg(all(test, target_os = "linux"))]
mod net_tests {
    use super::platform::net_helper;
    use crate::linux::jobexec::HelperSpec;
    use crate::linux::podman::RunnerArgs;

    /// [D] Under Q8 a networked job's `job.json` names its relay: the sidecar `<prefix>-px-<id>` labelled with the hub
    /// and the job, and the `podman run` that starts it from the relay image, for the helper; it reads back whole.
    #[test]
    fn job_json_names_the_sidecar() {
        let ra = RunnerArgs::runner("run", "hub1", "drgnx-runner-work-x1a.slice");
        let (net, argv) = net_helper(&ra, "x1a", "localhost/drgnx-px:0011aabb", false).unwrap();
        assert_eq!(net.sidecar, "run-px-x1a");
        assert!(!argv.iter().any(|a| a == "--keys"), "{argv:?}");
        // a keyed job's sidecar listens for its keys too
        let (_, keyed) = net_helper(&ra, "x1a", "localhost/drgnx-px:0011aabb", true).unwrap();
        assert_eq!(keyed[keyed.len() - 2..], ["--keys", "drgnx-key"]);
        assert_eq!(&argv[..2], ["run", "-i"]);
        assert!(
            argv.contains(&"run-px-x1a".to_string())
                || argv.iter().any(|a| a == "--name=run-px-x1a"),
            "{argv:?}"
        );
        assert!(
            argv.iter().any(|a| a.contains("drgnx.runner=hub1")),
            "{argv:?}"
        );
        assert!(argv.iter().any(|a| a.contains("drgnx.job=x1a")), "{argv:?}");
        assert!(
            argv.contains(&"localhost/drgnx-px:0011aabb".to_string()),
            "{argv:?}"
        );
        let h = HelperSpec {
            hub_allow: Some("/r/jobs/x1a/net-allow".into()),
            net: Some(net.clone()),
            sidecar_argv: argv.clone(),
            ..HelperSpec::default()
        };
        let back: HelperSpec = serde_json::from_str(&serde_json::to_string(&h).unwrap()).unwrap();
        assert_eq!(back, h);
        // a helper spec from before the relay still reads, with none
        let old: HelperSpec = serde_json::from_str(r#"{"root":"/r","keys":[]}"#).unwrap();
        assert_eq!((old.net, old.sidecar_argv.len()), (None, 0));
    }
}
