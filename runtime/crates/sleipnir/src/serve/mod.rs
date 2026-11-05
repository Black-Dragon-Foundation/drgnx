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
//! machine's admission lock ([`admit`]); a `start` runs the attempt as a transient unit running `sleipnir job-exec`;
//! logs are read from the attempt's log file by offset, never from a pipe; `finished` carries `result.json`. The
//! cleanup ([`cleanup`]) runs at start and at every job end, and touches only this hub's prefixed and labelled items.
//!
//! Blocking and threaded, no async runtime: one thread reads frames, the main loop handles them and ticks.

pub mod admit;
pub mod attempts;
pub mod cleanup;

use crate::linux::jobexec::{self, JobExec};
use crate::linux::parse::Parser;
use crate::linux::podman::{self, Caps, ContainerImage, ContainerReq, RunnerArgs, RunnerMounts};
use crate::linux::probe::{self, Probe};
use crate::linux::reserve::{self, Reservation};
use crate::linux::result::{RESULT, ResultJson};
use crate::linux::{run, slices, unit};
use crate::proto::{
    AttemptState, Frame, FrameReader, FrameWriter, JobRef, MAX_CHUNK, PROTO_VERSION,
};
use attempts::{CANCELLED, COLLECTED, LOG, Meta};
use forseti::classify::infra;
use forseti::safety::Level;
use forseti::{Action, JobId, Limits, Profile, RunningJob, Verdict};
use std::collections::BTreeMap;
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
    /// `--root DIR --prefix P --hub-id H --profile dedicated|workstation`.
    pub fn parse(args: &[&str]) -> Result<Config, String> {
        let (mut root, mut prefix, mut hub_id, mut profile) = (None, None, None, None);
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

/// Whether linger is on for this user (logind's live answer), so its jobs outlive the link.
fn linger() -> bool {
    let uid = rustix::process::getuid().as_raw().to_string();
    run::limited(
        Path::new("loginctl"),
        &["show-user", &uid, "--property=Linger", "--value"],
        &[],
        run::SYSTEMCTL_LIMIT,
    )
    .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "yes")
}

/// An attempt this `serve` knows: admitted here, or found running in the folder.
struct Live {
    dir: PathBuf,
    meta: Meta,
    /// The log offset sent up to; none until the hub attaches (a new attempt attaches at 0).
    pump: Option<u64>,
}

enum Event {
    Frame(Frame),
    End,
    Broken(String),
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
    probe: Probe,
    limits: Limits,
    scheduler: String,
    /// The `sleipnir` that runs job-exec: this one.
    exe: PathBuf,
    /// The `bin/<name>` folder this one runs from (empty outside a bundle).
    bundle: String,
    live: BTreeMap<(String, u32), Live>,
    hello: bool,
    last_start: Option<u64>,
    stop_admitting: bool,
    level2_since: Option<Instant>,
    last_kill: Option<Instant>,
    last_ready: Instant,
    last_ping: Instant,
    last_frame: Instant,
    last_units: Instant,
}

/// Runs `serve` with CFG on INPUT and OUTPUT until the link ends; the exit status.
pub fn run<R: Read + Send + 'static, W: Write>(cfg: Config, input: R, output: W) -> i32 {
    let (tx, rx) = mpsc::channel();
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
    s.cleanup();
    loop {
        match rx.recv_timeout(TICK) {
            Ok(Event::Frame(f)) => {
                s.last_frame = Instant::now();
                if s.handle(f) == Next::Stop {
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
    pub fn new(cfg: Config, output: W) -> Result<Serve<W>, String> {
        fs::create_dir_all(attempts::jobs(&cfg.root))
            .map_err(|e| format!("{}: {e}", cfg.root.display()))?;
        let scheduler = cfg.scheduler();
        let probe = Probe::system(&cfg.name, &scheduler, SLICE_ROOT, &cfg.root, cfg.profile)
            .map_err(|e| format!("the probe: {e}"))?;
        let mem = probe.memory().map(|m| m.total_mib).unwrap_or(0);
        let cores = probe.cpus_usable().map(|c| c.len() as u32).unwrap_or(1);
        let limits = Limits::for_profile(cfg.profile, mem, cores);
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
            probe,
            limits,
            scheduler,
            exe,
            bundle,
            live: BTreeMap::new(),
            hello: false,
            last_start: None,
            stop_admitting: false,
            level2_since: None,
            last_kill: None,
            last_ready: now,
            last_ping: now,
            last_frame: now,
            last_units: now,
        };
        s.load_running();
        Ok(s)
    }

    /// This hub's attempts in the folder.
    fn ours(&self) -> Vec<attempts::Found> {
        attempts::scan(&self.cfg.root, &unit::active)
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
                self.live.entry(key).or_insert(Live {
                    dir: f.dir,
                    meta: f.meta,
                    pump: None,
                });
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
                ..
            } => self.offer(r, *spec, priority, expected),
            Frame::Start {
                r,
                image,
                env,
                net_hosts,
                parser,
            } => self.start(&r, image, env, net_hosts, &parser),
            Frame::Attach { r, log_offset } => self.attach(&r, log_offset),
            Frame::Cancel { r } => self.cancel(&r),
            Frame::Done { r } => self.done(&r),
            Frame::Key(k) => {
                // keys reach a job through its helper, which this runner doesn't start yet: never stored, never logged
                eprintln!(
                    "sleipnir serve: key {} for {:?}: no job helper to hand it to",
                    k.name, k.r
                );
                Next::Go
            }
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
        let missing = match probe::contract(&self.probe, Path::new("podman")) {
            Ok(_) => vec![],
            Err(m) => m,
        };
        let attempts = self.ours().iter().map(attempts::Found::info).collect();
        let ok = Frame::HelloOk {
            version: PROTO_VERSION,
            bundle: self.bundle.clone(),
            hub_id: self.cfg.hub_id.clone(),
            runner_id: self.cfg.name.clone(),
            boot_id: self.probe.boot_id().unwrap_or_default(),
            linger: linger(),
            attempts,
            missing,
        };
        if self.send(&ok) == Next::Stop {
            return Next::Stop;
        }
        self.ready()
    }

    fn probe_result(&mut self) -> Next {
        let (facts, missing) = match probe::contract(&self.probe, Path::new("podman")) {
            Ok(f) => (Some(f), vec![]),
            Err(m) => (None, m),
        };
        let env: Vec<(std::ffi::OsString, std::ffi::OsString)> = [
            "PATH",
            "HOME",
            "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS",
        ]
        .iter()
        .filter_map(|k| Some((k.into(), std::env::var_os(k)?)))
        .collect();
        let limits = podman::check_limits(Path::new("podman"), &env, run::SYSTEMCTL_LIMIT).err();
        let features = if limits.is_none() {
            vec!["podman".to_string()]
        } else {
            vec![]
        };
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
                let slice = slices::job_slice(SLICE_ROOT, &l.meta.r.job).ok()?;
                Some(RunningJob {
                    id: JobId(l.meta.r.job.clone()),
                    priority: l.meta.priority,
                    started,
                    reserve_mib: l.meta.grant.reserve_mib,
                    current_mib: self.probe.cgroup(&slice).map(|c| c.used_mib()).unwrap_or(0),
                    cores: l.meta.grant.cores,
                    expected: l
                        .meta
                        .expected
                        .unwrap_or_else(|| admit::unknown(&l.meta.spec)),
                    restartable: l.meta.spec.restartable,
                    evicted_once: false,
                    long_build: false,
                })
            })
            .collect()
    }

    fn ready(&mut self) -> Next {
        self.last_ready = Instant::now();
        let mut m = match self.probe.machine(now_s(), &self.limits) {
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
        self.send(&Frame::Ready {
            free_mib: b.mem_mib,
            free_cpu: b.cpu,
            psi: m.psi,
            running,
            slots: vec![],
            images: vec![],
        })
    }

    /// The runner-wide ladder on our slice tree: tight stops admissions; at pressure and danger the scheduler
    /// holding the most memory evicts (dedicated) or kills our newest (workstation), writing the reason first.
    fn ladder(&mut self, m: &forseti::MachineState) {
        let level = forseti::ladder_level(m, &self.limits);
        self.stop_admitting = level != Level::Normal;
        if level < Level::Pressure {
            self.level2_since = None;
            return;
        }
        let since = *self.level2_since.get_or_insert_with(Instant::now);
        let own_mib: u64 = m.running.iter().map(|r| r.current_mib).sum();
        let mut others: BTreeMap<String, u64> = BTreeMap::new();
        for r in &m.others {
            *others.entry(r.scheduler.clone()).or_default() += r.reserve_mib.max(r.current_mib);
        }
        let others: Vec<(String, u64)> = others.into_iter().collect();
        if !forseti::ladder_actor(&self.scheduler, own_mib, &others) {
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
                // pausing a long build waits for live resizing; admissions stop meanwhile
                Action::Pause(_) | Action::StopAdmitting => continue,
            };
            if let Some(l) = self.live.values().find(|l| l.meta.r.job == id.0) {
                eprintln!("sleipnir serve: the ladder at {level:?}: {reason} {}", id.0);
                self.kill(&l.dir.clone(), &l.meta.r.job.clone(), &reason);
                self.last_kill = Some(Instant::now());
            }
        }
    }

    /// Writes REASON in DIR, then kills job ID's container: job-exec sees the command end and writes the verdict the
    /// reason names.
    fn kill(&self, dir: &Path, id: &str, reason: &str) {
        if let Err(e) = jobexec::kill_reason(dir, reason) {
            eprintln!("sleipnir serve: the kill reason of {id}: {e}");
        }
        let name = format!("{}-{id}", self.cfg.prefix);
        if let Err(e) = run::limited(
            Path::new("podman"),
            &["kill", &name],
            &[],
            run::SYSTEMCTL_LIMIT,
        ) {
            eprintln!("sleipnir serve: podman kill {name}: {e}");
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
    ) -> Next {
        if r.job.is_empty() || !r.job.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return self.refuse(r, "a job id is letters and digits");
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
            &self.probe,
            &self.limits,
            &self.scheduler,
            &ours,
            self.last_start,
            now_s(),
            &offer,
        ) {
            Err(no) => self.send(&Frame::Refuse {
                r,
                why: no.why,
                reason: no.reason,
            }),
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
                };
                let made = ["src", "target"]
                    .iter()
                    .try_for_each(|d| fs::create_dir_all(dir.join(d)))
                    .and_then(|()| attempts::write_meta(&dir, &meta));
                if let Err(e) = made {
                    self.unreserve(&r);
                    return self.refuse(r, format!("the attempt's folder: {e}"));
                }
                self.live.insert(
                    (r.job.clone(), r.attempt),
                    Live {
                        dir,
                        meta,
                        pump: None,
                    },
                );
                self.send(&Frame::Admit { r, grant })
            }
        }
    }

    fn unreserve(&self, r: &JobRef) {
        let _ = self
            .probe
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
        net_hosts: Vec<String>,
        parser: &str,
    ) -> Next {
        let Some(l) = self.find(r) else {
            eprintln!("sleipnir serve: start for an attempt not admitted here: {r:?}");
            return Next::Go;
        };
        if l.meta.started.is_some() {
            return Next::Go;
        }
        let (dir, meta) = (l.dir.clone(), l.meta.clone());
        match self.launch(&dir, &meta, image, &env, &net_hosts, parser) {
            Ok((unit, pid)) => {
                let at = now_s();
                let mut meta = meta;
                meta.unit = Some(unit.clone());
                meta.started = Some(at);
                if let Err(e) = attempts::write_meta(&dir, &meta) {
                    eprintln!("sleipnir serve: the attempt's record: {e}");
                }
                self.hand_reservation(&meta, pid);
                self.last_start = Some(at);
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

    /// Starts the attempt's unit: its job slice, its `job.json`, `sleipnir job-exec` in a transient service. The
    /// unit and its main pid.
    fn launch(
        &self,
        dir: &Path,
        meta: &Meta,
        image: Option<String>,
        env: &[(String, String)],
        net_hosts: &[String],
        parser: &str,
    ) -> Result<(String, u32), String> {
        let id = &meta.r.job;
        if !net_hosts.is_empty() {
            return Err("a job with network goes through its job helper, which this runner doesn't start yet".into());
        }
        if !meta.spec.keys.is_empty() {
            return Err("a job with keys gets them from its job helper, which this runner doesn't start yet".into());
        }
        if !env.is_empty() {
            return Err("variables for the container aren't carried yet".into());
        }
        let image = image.ok_or("a runner job is a container job: it needs an image")?;
        let parser: Parser =
            serde_json::from_value(serde_json::Value::String(if parser.is_empty() {
                "exit".into()
            } else {
                parser.to_string()
            }))
            .map_err(|_| format!("no row parser {parser:?}"))?;
        slices::ensure_tree(SLICE_ROOT, self.cfg.profile)?;
        let slice = slices::job_slice(SLICE_ROOT, id)?;
        let caps = Caps {
            images: vec![ContainerImage {
                name: "job".into(),
                image,
            }],
            memory: format!("{}M", meta.grant.mem_cap_mib.max(6)),
            cpus: meta.grant.cores.max(1),
            pids: podman::PIDS,
            proxy: None,
            net_hosts: vec![],
            pins: vec![],
        };
        let req = ContainerReq {
            image: "job".into(),
            argv: meta.spec.command.clone(),
            worktree: dir.join("src"),
            subdir: if meta.spec.cwd == Path::new(".") {
                PathBuf::new()
            } else {
                meta.spec.cwd.clone()
            },
            job: id.clone(),
            net: false,
            runner: Some(RunnerMounts {
                writes_tree: meta.spec.writes_tree,
                target: dir.join("target"),
                caches: vec![],
                keys: None,
            }),
        };
        let ra = RunnerArgs::runner(&self.cfg.prefix, &self.cfg.hub_id, &slice);
        let mut argv = vec!["podman".to_string()];
        for a in podman::argv(&req, &caps, &ra).map_err(|r| r.message)? {
            argv.push(
                a.into_string()
                    .map_err(|_| "a podman argument is not UTF-8")?,
            );
        }
        let log = dir.join(LOG);
        JobExec {
            id: id.clone(),
            attempt: meta.r.attempt,
            machine: self.cfg.name.clone(),
            slice: slice.clone(),
            argv,
            env: vec![],
            cwd: None,
            log: log.clone(),
            state_logs: vec![],
            keyed: false,
            parser,
            expect: meta.spec.expect,
            grant: meta.grant,
            timeout_s: meta.spec.timeout_s,
        }
        .write(dir)
        .map_err(|e| format!("job.json: {e}"))?;
        let name = format!("{}-{id}-{}", self.cfg.prefix, meta.r.attempt);
        let unit = unit::start(&unit::UnitReq {
            unit: name,
            id: id.clone(),
            attempt: meta.r.attempt,
            slice,
            runtime_max_s: meta.spec.timeout_s + UNIT_SLACK_S,
            log,
            env: vec![],
            argv: vec![
                self.exe.display().to_string(),
                "job-exec".into(),
                dir.display().to_string(),
            ],
            binds_to: None,
        })?;
        let pid = run::systemctl_ok(&["show", "--property=MainPID", "--value", &unit])
            .ok()
            .and_then(|p| p.parse::<u32>().ok())
            .unwrap_or(0);
        Ok((unit, pid))
    }

    /// The attempt's reservation passes to its job-exec (PID), which outlives this `serve`.
    fn hand_reservation(&self, meta: &Meta, pid: u32) {
        let Ok(start_time) = reserve::start_time(pid) else {
            eprintln!(
                "sleipnir serve: {}'s job-exec pid {pid}: its reservation stays with this serve",
                meta.r.job
            );
            return;
        };
        let r = Reservation {
            scheduler: self.scheduler.clone(),
            pid,
            boot_id: self.probe.boot_id().unwrap_or_default(),
            start_time,
            job: admit::reservation_job(&meta.r.job, meta.r.attempt),
            reserve_mib: meta.grant.reserve_mib,
            current_mib: 0,
            expires: now_s() + meta.spec.timeout_s + admit::RESERVATION_SLACK_S,
        };
        if let Err(e) = self.probe.reservations().put(&r) {
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
                    self.live.insert(
                        key.clone(),
                        Live {
                            dir,
                            meta,
                            pump: None,
                        },
                    );
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

    fn cleanup(&self) {
        let seen = cleanup::Seen {
            containers: cleanup::containers(&self.cfg.prefix, &self.cfg.hub_id),
            units: cleanup::units(&self.cfg.prefix),
            folders: attempts::scan(&self.cfg.root, &unit::active),
            bundles: cleanup::bundles(&self.cfg.root),
        };
        let owner = cleanup::Owner {
            hub_id: &self.cfg.hub_id,
            prefix: &self.cfg.prefix,
            own_bundle: &self.bundle,
        };
        cleanup::apply(&self.cfg.root, &cleanup::plan(&owner, &seen));
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
            let up = meta.unit.as_deref().is_some_and(unit::active);
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
        let Some(mut offset) = self.live.get(key).and_then(|l| l.pump) else {
            return Ok(false);
        };
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
#[cfg(test)]
pub(crate) fn tests_spec() -> forseti::JobSpec {
    use forseti::{Expect, JobTrust, Kind, Lane, Range, Weight};
    forseti::JobSpec {
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
