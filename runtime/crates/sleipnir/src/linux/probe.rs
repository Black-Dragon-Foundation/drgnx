//! The machine probe: what a scheduler needs to know about this machine, read from `/proc`, `/sys` and the cgroup
//! files, and the runner contract a host must meet before it runs a job.
//!
//! Every reader takes its roots from [`Probe`], so the tests point them at fixture trees; [`Probe::system`] is the
//! real machine.

use super::reserve::{self, Reservations};
use super::run;
use forseti::{Limits, MachineState, Profile, Psi};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Test builds only: the file in the runner folder whose figures stand in for the host's in [`Probe::machine`].
#[cfg(feature = "test-hooks")]
pub const TEST_MACHINE: &str = "test-machine.json";

/// Where the probe reads, and who it reads for.
#[derive(Clone, Debug)]
pub struct Probe {
    /// The machine's name in a `MachineState`.
    pub name: String,
    /// `/proc`.
    pub proc_root: PathBuf,
    /// `/sys`.
    pub sys_root: PathBuf,
    /// The user manager's cgroup directory (`/sys/fs/cgroup/user.slice/user-U.slice/user@U.service`): our slices
    /// live under it.
    pub manager: PathBuf,
    /// `$XDG_RUNTIME_DIR`: the reservation files, and a graphical session's sockets.
    pub runtime_dir: PathBuf,
    /// The runner folder; its filesystem's free space is the disk the jobs use.
    pub folder: PathBuf,
    /// The slice root (`drgnx-runner`): our slices are `<root>.slice` and `<root>-*.slice`.
    pub slice_root: String,
    /// The scheduler this probe reads for; its own reservations are not "others".
    pub scheduler: String,
    pub profile: Profile,
}

impl Probe {
    /// The real machine, for scheduler SCHEDULER with its slices under SLICE_ROOT and its jobs' disk at FOLDER.
    pub fn system(
        name: &str,
        scheduler: &str,
        slice_root: &str,
        folder: &Path,
        profile: Profile,
    ) -> io::Result<Probe> {
        let uid = rustix::process::getuid().as_raw();
        let own = fs::read_to_string("/proc/self/cgroup").unwrap_or_default();
        let manager = manager_cgroup(&own, uid);
        let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(format!("/run/user/{uid}")));
        Ok(Probe {
            name: name.to_string(),
            proc_root: "/proc".into(),
            sys_root: "/sys".into(),
            manager: Path::new("/sys/fs/cgroup").join(manager),
            runtime_dir,
            folder: folder.to_path_buf(),
            slice_root: slice_root.to_string(),
            scheduler: scheduler.to_string(),
            profile,
        })
    }

    /// The reservation files of this machine.
    pub fn reservations(&self) -> Reservations {
        Reservations::at(&self.runtime_dir)
    }

    /// The machine at NOW, under LIMITS (which say whether the user's apps' pressure is read apart). What runs is the
    /// scheduler's to fill in (`running`, `last_start`, `features`); `others` holds the live reservations of the other
    /// schedulers: this boot, process alive.
    pub fn machine(&self, now: u64, limits: &Limits) -> io::Result<MachineState> {
        let mem = self.memory()?;
        let disk = self.disk()?;
        let boot_id = self.boot_id()?;
        let some = |what: &str| self.pressure(what).map(|p| p.some.avg10);
        let psi = Psi {
            mem_some10: some("memory")?,
            cpu_some10: some("cpu")?,
            io_full10: self.pressure("io")?.full.map(|f| f.avg10).unwrap_or(0.0),
            app_mem_some10: match limits.psi.app_mem_some10 {
                Some(_) => Some(self.app_pressure()?.some.avg10),
                None => None,
            },
        };
        let others = self
            .reservations()
            .read_others(&self.scheduler)
            .into_iter()
            .filter(|r| {
                r.boot_id == boot_id && reserve::alive_in(&self.proc_root, r.pid, r.start_time)
            })
            .collect();
        let m = MachineState {
            name: self.name.clone(),
            profile: self.profile,
            now,
            boot_id,
            mem_total_mib: mem.total_mib,
            mem_available_mib: mem.available_mib,
            psi,
            disk_free_gb: disk.free_gb,
            disk_total_gb: disk.size_gb,
            on_ac: self.power().on_ac,
            last_start: None,
            running: vec![],
            features: vec![],
            reachable: true,
            others,
        };
        #[cfg(feature = "test-hooks")]
        let m = self.test_machine(m)?;
        Ok(m)
    }

    /// The runner folder's disk as [`Probe::machine`] sees it: [`Probe::disk`], or in a test build the
    /// [`TEST_MACHINE`] file's figures when there is one.
    pub fn disk_seen(&self) -> io::Result<Disk> {
        #[allow(unused_mut)]
        let mut d = self.disk()?;
        #[cfg(feature = "test-hooks")]
        if self.folder.join(TEST_MACHINE).exists() {
            let mut m = MachineState {
                name: String::new(),
                profile: self.profile,
                now: 0,
                boot_id: String::new(),
                mem_total_mib: 0,
                mem_available_mib: 0,
                psi: Psi::default(),
                disk_free_gb: d.free_gb,
                disk_total_gb: d.size_gb,
                on_ac: true,
                last_start: None,
                running: vec![],
                features: vec![],
                reachable: true,
                others: vec![],
            };
            m = self.test_machine(m)?;
            d.free_gb = m.disk_free_gb;
            d.size_gb = m.disk_total_gb;
        }
        Ok(d)
    }

    /// Test builds only: a fake runner shares its host's `/proc/pressure`, `/proc/meminfo`, disk and
    /// `/sys/class/power_supply`, so the folder's [`TEST_MACHINE`] file, when there is one, sets the machine's
    /// pressure, disk, available memory and mains power. A file that can't be read as one is an error, never the
    /// host's figures.
    #[cfg(feature = "test-hooks")]
    fn test_machine(&self, mut m: MachineState) -> io::Result<MachineState> {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Facts {
            psi: Option<Psi>,
            disk_free_gb: Option<u64>,
            disk_total_gb: Option<u64>,
            mem_available_mib: Option<u64>,
            on_ac: Option<bool>,
        }
        let path = self.folder.join(TEST_MACHINE);
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(m),
            Err(e) => return Err(e),
        };
        let f: Facts = serde_json::from_str(&text).map_err(|e| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{}: {e}", path.display()),
            )
        })?;
        m.psi = f.psi.unwrap_or(m.psi);
        m.disk_free_gb = f.disk_free_gb.unwrap_or(m.disk_free_gb);
        m.disk_total_gb = f.disk_total_gb.unwrap_or(m.disk_total_gb);
        m.mem_available_mib = f.mem_available_mib.unwrap_or(m.mem_available_mib);
        m.on_ac = f.on_ac.unwrap_or(m.on_ac);
        Ok(m)
    }

    /// The cgroup directory of SLICE (one of ours, under the user manager).
    pub fn slice_dir(&self, slice: &str) -> PathBuf {
        self.manager.join(slice_path(slice))
    }

    /// Memory, CPU and pressure of SLICE.
    pub fn cgroup(&self, slice: &str) -> io::Result<CgroupStat> {
        CgroupStat::read(&self.slice_dir(slice))
    }

    /// `/proc/meminfo`.
    pub fn memory(&self) -> io::Result<Mem> {
        Ok(parse_meminfo(&fs::read_to_string(
            self.proc_root.join("meminfo"),
        )?))
    }

    /// `/proc/pressure/WHAT` (`cpu`, `memory`, `io`).
    pub fn pressure(&self, what: &str) -> io::Result<Pressure> {
        parse_pressure(&fs::read_to_string(
            self.proc_root.join("pressure").join(what),
        )?)
    }

    /// The pressure of the user's own work: `app.slice` under the user manager (a workstation's yardstick).
    pub fn app_pressure(&self) -> io::Result<Pressure> {
        parse_pressure(&fs::read_to_string(
            self.manager.join("app.slice/memory.pressure"),
        )?)
    }

    /// `/proc/sys/kernel/random/boot_id`.
    pub fn boot_id(&self) -> io::Result<String> {
        Ok(
            fs::read_to_string(self.proc_root.join("sys/kernel/random/boot_id"))?
                .trim()
                .to_string(),
        )
    }

    /// The power supplies: whether one is a battery, and whether the machine is on mains power (true with no supply
    /// at all, as a desktop is).
    pub fn power(&self) -> Power {
        let mut p = Power {
            battery: false,
            on_ac: true,
        };
        let mut mains_online = false;
        let Ok(dir) = fs::read_dir(self.sys_root.join("class/power_supply")) else {
            return p;
        };
        for e in dir.flatten() {
            let read = |f: &str| fs::read_to_string(e.path().join(f)).map(|s| s.trim().to_string());
            match read("type").as_deref() {
                Ok("Battery") => p.battery = true,
                Ok("Mains") | Ok("USB") => mains_online |= read("online").is_ok_and(|s| s == "1"),
                _ => {}
            }
        }
        // with a battery, mains power counts only when a supply says it is online
        p.on_ac = !p.battery || mains_online;
        p
    }

    /// The CPUs online, as the kernel lists them (`0-7,16`).
    pub fn cpus_online(&self) -> io::Result<Vec<u32>> {
        parse_cpu_list(&fs::read_to_string(
            self.sys_root.join("devices/system/cpu/online"),
        )?)
    }

    /// The CPUs our jobs may use: the user manager's `cpuset.cpus.effective`, which is narrower than the CPUs online
    /// when the machine (a container, a pinned session) is itself confined; the CPUs online when it can't be read.
    pub fn cpus_usable(&self) -> io::Result<Vec<u32>> {
        match fs::read_to_string(self.manager.join("cpuset.cpus.effective")) {
            Ok(s) if !s.trim().is_empty() => parse_cpu_list(&s),
            _ => self.cpus_online(),
        }
    }

    /// Free space of the runner folder's filesystem, in whole GB (10⁹ bytes), and its size.
    pub fn disk(&self) -> io::Result<Disk> {
        let s = rustix::fs::statvfs(&self.folder)?;
        let free = s.f_bavail.saturating_mul(s.f_frsize);
        let size = s.f_blocks.saturating_mul(s.f_frsize);
        Ok(Disk {
            free_gb: free / 1_000_000_000,
            size_gb: size / 1_000_000_000,
        })
    }

    /// A graphical session of this user: a Wayland socket in the runtime dir, or an X display.
    pub fn graphical(&self) -> bool {
        let has = |dir: &Path, prefix: &str| {
            fs::read_dir(dir).is_ok_and(|d| {
                d.flatten().any(|e| {
                    e.file_name().to_string_lossy().starts_with(prefix)
                        && !e.file_name().to_string_lossy().ends_with(".lock")
                })
            })
        };
        has(&self.runtime_dir, "wayland-") || has(Path::new("/tmp/.X11-unix"), "X")
    }

    /// Whether a unit of ours can be given `memory.swap.max` (swap accounting on the user manager's tree).
    pub fn swap_max_settable(&self) -> bool {
        self.manager.join("memory.swap.max").exists()
    }

    /// The other schedulers holding a live reservation on this machine (this boot, process alive), by name.
    pub fn others_present(&self) -> Vec<String> {
        let boot = self.boot_id().unwrap_or_default();
        let mut names: Vec<String> = self
            .reservations()
            .read_others(&self.scheduler)
            .into_iter()
            .filter(|r| {
                r.boot_id == boot && reserve::alive_in(&self.proc_root, r.pid, r.start_time)
            })
            .map(|r| r.scheduler)
            .collect();
        names.sort();
        names.dedup();
        names
    }

    /// The facts the contract reports, read from the files (no tools run).
    pub fn file_facts(&self) -> FileFacts {
        let mem = self.memory().unwrap_or_default();
        FileFacts {
            arch: std::env::consts::ARCH.to_string(),
            os: os_release(&fs::read_to_string("/etc/os-release").unwrap_or_default()),
            cores: self.cpus_usable().map(|c| c.len() as u32).unwrap_or(0),
            mem_mib: mem.total_mib,
            disk_free_gb: self.disk().map(|d| d.free_gb).unwrap_or(0),
            landlock_abi: landlock_abi(),
            graphical: self.graphical(),
            battery: self.power().battery,
            swap_max_settable: self.swap_max_settable(),
            others_present: self.others_present(),
        }
    }

    /// Whether systemd applies `AllowedCPUs` on our slices: set it on our own probe slice and read `cpuset.cpus`
    /// back. A user manager started before cpuset was delegated accepts the property and never writes the file (and
    /// `user@.service`'s `cgroup.subtree_control` still says `cpuset`), so only the read-back tells.
    pub fn cpuset_by_systemd(&self) -> Result<bool, String> {
        let first = self
            .cpus_usable()
            .map_err(|e| format!("the CPUs usable: {e}"))?
            .first()
            .copied()
            .ok_or("no CPU usable")?;
        let slice = format!("{}-probe.slice", self.slice_root);
        run::systemctl_ok(&["start", &slice])?;
        let set = run::systemctl_ok(&[
            "set-property",
            "--runtime",
            &slice,
            &format!("AllowedCPUs={first}"),
        ]);
        let read = fs::read_to_string(self.slice_dir(&slice).join("cpuset.cpus"))
            .map(|s| s.trim().to_string());
        let _ = run::systemctl(&["set-property", "--runtime", &slice, "AllowedCPUs="]);
        let _ = run::systemctl(&["stop", &slice]);
        set?;
        Ok(read.is_ok_and(|s| parse_cpu_list(&s).is_ok_and(|c| c == [first])))
    }
}

/// The user manager's cgroup, relative to `/sys/fs/cgroup`, from a process's `/proc/self/cgroup` (OWN): the path
/// through `user@U.service` when the process runs under it, else the standard place for uid UID.
pub fn manager_cgroup(own: &str, uid: u32) -> PathBuf {
    let want = format!("user@{uid}.service");
    for line in own.lines() {
        let Some(path) = line.strip_prefix("0::") else {
            continue;
        };
        let mut out = PathBuf::new();
        for c in path.split('/').filter(|c| !c.is_empty()) {
            out.push(c);
            if c == want {
                return out;
            }
        }
    }
    PathBuf::from(format!("user.slice/user-{uid}.slice/user@{uid}.service"))
}

/// Where systemd puts SLICE under its manager: each `-` opens a level (`a-b-c.slice` is
/// `a.slice/a-b.slice/a-b-c.slice`).
pub fn slice_path(slice: &str) -> PathBuf {
    let stem = slice.strip_suffix(".slice").unwrap_or(slice);
    let mut out = PathBuf::new();
    let mut acc = String::new();
    for (i, part) in stem.split('-').enumerate() {
        if i > 0 {
            acc.push('-');
        }
        acc.push_str(part);
        out.push(format!("{acc}.slice"));
    }
    out
}

/// `/proc/meminfo`'s two lines a scheduler reads, in MiB.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mem {
    pub total_mib: u64,
    pub available_mib: u64,
}

pub fn parse_meminfo(text: &str) -> Mem {
    let kib = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key)?.strip_prefix(':'))
            .and_then(|v| v.split_whitespace().next()?.parse::<u64>().ok())
            .unwrap_or(0)
    };
    Mem {
        total_mib: kib("MemTotal") / 1024,
        available_mib: kib("MemAvailable") / 1024,
    }
}

/// One line of a pressure file.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PsiLine {
    pub avg10: f64,
    pub avg60: f64,
    pub avg300: f64,
    /// Microseconds stalled, in all.
    pub total: u64,
}

/// A pressure file (`/proc/pressure/*`, a cgroup's `*.pressure`): `some`, and `full` where the kernel has it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Pressure {
    pub some: PsiLine,
    pub full: Option<PsiLine>,
}

/// Reads the kernel's format: `some avg10=0.00 avg60=0.00 avg300=0.00 total=0`, then `full …`.
pub fn parse_pressure(text: &str) -> io::Result<Pressure> {
    let bad = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("not a pressure file: {text:?}"),
        )
    };
    let line = |l: &str| -> Option<PsiLine> {
        let mut p = PsiLine::default();
        for kv in l.split_whitespace().skip(1) {
            let (k, v) = kv.split_once('=')?;
            match k {
                "avg10" => p.avg10 = v.parse().ok()?,
                "avg60" => p.avg60 = v.parse().ok()?,
                "avg300" => p.avg300 = v.parse().ok()?,
                "total" => p.total = v.parse().ok()?,
                _ => {}
            }
        }
        Some(p)
    };
    let mut out = Pressure::default();
    let mut some = false;
    for l in text.lines() {
        if l.starts_with("some ") {
            out.some = line(l).ok_or_else(bad)?;
            some = true;
        } else if l.starts_with("full ") {
            out.full = Some(line(l).ok_or_else(bad)?);
        }
    }
    if some { Ok(out) } else { Err(bad()) }
}

/// A kernel CPU list (`0-3,8,10-11`).
pub fn parse_cpu_list(text: &str) -> io::Result<Vec<u32>> {
    let bad = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("not a CPU list: {text:?}"),
        )
    };
    let mut out = vec![];
    for part in text.trim().split(',').filter(|p| !p.is_empty()) {
        match part.split_once('-') {
            Some((a, b)) => {
                let (a, b): (u32, u32) =
                    (a.parse().map_err(|_| bad())?, b.parse().map_err(|_| bad())?);
                if a > b {
                    return Err(bad());
                }
                out.extend(a..=b);
            }
            None => out.push(part.parse().map_err(|_| bad())?),
        }
    }
    Ok(out)
}

/// Memory and CPU of one cgroup, in bytes and microseconds.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CgroupStat {
    /// `memory.current`.
    pub current: u64,
    /// `memory.stat`'s `file`: page cache, which a job's "used" leaves out.
    pub file: u64,
    /// `memory.peak` (0 on a kernel without it).
    pub peak: u64,
    /// `memory.events`' `oom_kill`: processes the kernel killed for this cgroup's limit, here or below.
    pub oom_kill: u64,
    /// `memory.events`' `oom_group_kill`.
    pub oom_group_kill: u64,
    /// `cpu.stat`'s `usage_usec`.
    pub cpu_usec: u64,
    /// `memory.pressure`.
    pub memory_pressure: Pressure,
}

impl CgroupStat {
    /// Reads the cgroup at DIR.
    pub fn read(dir: &Path) -> io::Result<CgroupStat> {
        let read = |f: &str| fs::read_to_string(dir.join(f));
        let num = |s: &str| s.trim().parse::<u64>().unwrap_or(0);
        let key = |text: &str, k: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(k)?.strip_prefix(' '))
                .map(num)
                .unwrap_or(0)
        };
        let events = read("memory.events").unwrap_or_default();
        let stat = read("memory.stat").unwrap_or_default();
        Ok(CgroupStat {
            current: num(&read("memory.current")?),
            file: key(&stat, "file"),
            peak: read("memory.peak").map(|s| num(&s)).unwrap_or(0),
            oom_kill: key(&events, "oom_kill"),
            oom_group_kill: key(&events, "oom_group_kill"),
            cpu_usec: key(&read("cpu.stat").unwrap_or_default(), "usage_usec"),
            memory_pressure: read("memory.pressure")
                .ok()
                .and_then(|t| parse_pressure(&t).ok())
                .unwrap_or_default(),
        })
    }

    /// What the jobs use: `memory.current` without the page cache, in MiB.
    pub fn used_mib(&self) -> u64 {
        self.current.saturating_sub(self.file) / (1024 * 1024)
    }
}

/// A PSI trigger on a pressure file: [`PsiTrigger::wait`] wakes when the stall the spec names happens.
#[derive(Debug)]
pub struct PsiTrigger {
    file: fs::File,
}

/// Arms a trigger on PATH (`/proc/pressure/memory`, a cgroup's `memory.pressure`) with SPEC, the kernel's
/// `some|full <stall µs> <window µs>` (`some 150000 1000000`).
pub fn psi_trigger(path: &Path, spec: &str) -> io::Result<PsiTrigger> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let mut bytes = spec.as_bytes().to_vec();
    bytes.push(0);
    file.write_all(&bytes)?;
    Ok(PsiTrigger { file })
}

impl PsiTrigger {
    /// Waits up to TIMEOUT for the trigger to fire: true when it did. An error when the file went away (its cgroup
    /// was removed).
    pub fn wait(&self, timeout: Duration) -> io::Result<bool> {
        use rustix::event::{PollFd, PollFlags, Timespec, poll};
        let mut fds = [PollFd::new(&self.file, PollFlags::PRI)];
        let t = Timespec {
            tv_sec: timeout.as_secs() as _,
            tv_nsec: timeout.subsec_nanos() as _,
        };
        let n = poll(&mut fds, Some(&t))?;
        let r = fds[0].revents();
        if r.contains(PollFlags::ERR) || r.contains(PollFlags::NVAL) {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "the pressure file went away",
            ));
        }
        Ok(n > 0 && r.contains(PollFlags::PRI))
    }
}

/// The power supplies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Power {
    pub battery: bool,
    pub on_ac: bool,
}

/// The runner folder's filesystem, in whole GB.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Disk {
    pub free_gb: u64,
    pub size_gb: u64,
}

/// `/etc/os-release` as `ID VERSION_ID` (`fedora 45`); `linux` when it says nothing.
pub fn os_release(text: &str) -> String {
    let get = |k: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(k)?.strip_prefix('='))
            .map(|v| v.trim().trim_matches('"').to_string())
            .filter(|v| !v.is_empty())
    };
    match (get("ID"), get("VERSION_ID")) {
        (Some(id), Some(v)) => format!("{id} {v}"),
        (Some(id), None) => id,
        _ => "linux".to_string(),
    }
}

/// The kernel's Landlock ABI version; 0 without Landlock.
pub fn landlock_abi() -> u32 {
    // landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION) answers the ABI version
    let r = unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            std::ptr::null::<libc::c_void>(),
            0usize,
            1u32,
        )
    };
    if r > 0 { r as u32 } else { 0 }
}

/// The facts read from files.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileFacts {
    pub arch: String,
    pub os: String,
    pub cores: u32,
    pub mem_mib: u64,
    pub disk_free_gb: u64,
    pub landlock_abi: u32,
    pub graphical: bool,
    pub battery: bool,
    pub swap_max_settable: bool,
    pub others_present: Vec<String>,
}

/// What a host is once it meets the contract, and one thing it lacks with its fix: the protocol's types, since the
/// `probe-result` and `hello-ok` frames carry them.
pub use crate::proto::{Facts, Missing};

/// What the contract's tools answered on a host.
#[derive(Clone, Debug)]
pub struct Observed {
    /// `systemctl --user show -p Version --value`: the user manager's version, or why there is none.
    pub systemd_user: Result<String, String>,
    /// `podman info --format json`.
    pub podman_info: Result<serde_json::Value, String>,
    /// `git --version`.
    pub git: Result<String, String>,
    /// `loginctl show-user U -P Linger` said `yes`.
    pub linger: bool,
    pub cpuset_by_systemd: bool,
    pub files: FileFacts,
    /// The login's SELinux context (`/proc/self/attr/current`), none without SELinux.
    pub selinux: Option<String>,
}

/// The controllers the caps need delegated: `--memory`, `--pids-limit`, `--cpus`.
pub const CONTROLLERS: [&str; 3] = ["memory", "pids", "cpu"];

/// The contract on what a host answered: its facts, or every item it lacks with the fix for each.
pub fn judge(o: &Observed) -> Result<Facts, Vec<Missing>> {
    let mut missing = vec![];
    let mut miss = |what: String, fix: &str| {
        missing.push(Missing {
            what,
            fix: fix.to_string(),
        })
    };
    if let Some(ctx) = &o.selinux
        && super::confined::is_user_t(ctx)
    {
        miss(
            format!(
                "a login that may run rootless podman (this one is the confined SELinux user user_u, {ctx}: podman needs newuidmap, which the stock policy denies user_t)"
            ),
            "map the login to another SELinux user (`semanage login -m -s staff_u LOGIN`, then log in again), or give it a subuid and subgid range and a local policy module that lets user_t run newuidmap",
        );
    }
    if let Err(e) = &o.systemd_user {
        miss(
            format!("a systemd user manager ({e})"),
            "log in on the machine as this user, or run `loginctl enable-linger` there so the manager runs without a login",
        );
    }
    let mut podman_version = String::new();
    match &o.podman_info {
        Err(e) => miss(
            format!("rootless podman 5 or newer ({e})"),
            "install podman 5 or newer (`dnf install podman`, `apt install podman`) and check that `podman info` works as this user",
        ),
        Ok(info) => {
            let host = &info["host"];
            podman_version = info["version"]["Version"]
                .as_str()
                .unwrap_or("")
                .to_string();
            let major = podman_version
                .split('.')
                .next()
                .and_then(|m| m.parse::<u32>().ok())
                .unwrap_or(0);
            if major < 5 {
                miss(
                    format!(
                        "rootless podman 5 or newer (found {})",
                        if podman_version.is_empty() {
                            "no version"
                        } else {
                            &podman_version
                        }
                    ),
                    "upgrade podman to 5 or newer",
                );
            }
            if host["security"]["rootless"].as_bool() != Some(true) {
                miss(
                    "podman running rootless".into(),
                    "connect as an ordinary user, never as root",
                );
            }
            let version = host["cgroupVersion"].as_str().unwrap_or("unknown");
            if version != "v2" {
                miss(
                    format!("cgroup v2 (podman reports {version})"),
                    "boot with the unified cgroup hierarchy (`systemd.unified_cgroup_hierarchy=1`), the default on current distributions",
                );
            }
            let manager = host["cgroupManager"].as_str().unwrap_or("unknown");
            if manager != "systemd" {
                miss(
                    format!(
                        "podman on the systemd cgroup manager (it uses {manager}, which drops a rootless container's caps)"
                    ),
                    "set `cgroup_manager = \"systemd\"` under `[engine]` in ~/.config/containers/containers.conf, with a user manager running (`loginctl enable-linger`)",
                );
            }
            let have: Vec<&str> = host["cgroupControllers"]
                .as_array()
                .map(|a| a.iter().filter_map(|c| c.as_str()).collect())
                .unwrap_or_default();
            let lack: Vec<&str> = CONTROLLERS
                .iter()
                .copied()
                .filter(|c| !have.contains(c))
                .collect();
            if !lack.is_empty() {
                miss(
                    format!(
                        "the cgroup controllers {} delegated to this user",
                        lack.join(", ")
                    ),
                    "add /etc/systemd/system/user@.service.d/delegate.conf with `[Service]` and `Delegate=memory pids cpu cpuset io`, run `systemctl daemon-reload`, then log in again",
                );
            }
        }
    }
    if let Err(e) = &o.git {
        miss(
            format!("git ({e})"),
            "install git (`dnf install git`, `apt install git`)",
        );
    }
    if !missing.is_empty() {
        return Err(missing);
    }
    let f = &o.files;
    Ok(Facts {
        arch: f.arch.clone(),
        os: f.os.clone(),
        cores: f.cores,
        mem_mib: f.mem_mib,
        disk_free_gb: f.disk_free_gb,
        podman_version,
        linger: o.linger,
        landlock_abi: f.landlock_abi,
        graphical: f.graphical,
        battery: f.battery,
        swap_max_settable: f.swap_max_settable,
        cpuset_by_systemd: o.cpuset_by_systemd,
        others_present: f.others_present.clone(),
    })
}

/// How long the contract's tools may take, each.
const TOOL_LIMIT: Duration = Duration::from_secs(30);

/// Runs the contract on this host with PODMAN: [`judge`] over what the tools answer.
pub fn contract(probe: &Probe, podman: &Path) -> Result<Facts, Vec<Missing>> {
    let text = |out: Result<std::process::Output, String>| -> Result<String, String> {
        let out = out?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
        }
    };
    let systemd_user = run::systemctl_ok(&["show", "--property=Version", "--value"]);
    let podman_info = text(run::limited(
        podman,
        &["info", "--format", "json"],
        &[],
        TOOL_LIMIT,
    ))
    .and_then(|s| serde_json::from_str(&s).map_err(|e| format!("podman info is not JSON: {e}")));
    let git = text(run::limited(
        Path::new("git"),
        &["--version"],
        &[],
        TOOL_LIMIT,
    ));
    let uid = rustix::process::getuid().as_raw().to_string();
    let linger = text(run::limited(
        Path::new("loginctl"),
        &["show-user", &uid, "--property=Linger", "--value"],
        &[],
        TOOL_LIMIT,
    ))
    .is_ok_and(|s| s == "yes");
    let cpuset_by_systemd = systemd_user.is_ok() && probe.cpuset_by_systemd().unwrap_or(false);
    judge(&Observed {
        systemd_user,
        podman_info,
        git,
        linger,
        cpuset_by_systemd,
        files: probe.file_facts(),
        selinux: super::confined::context(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(
        version: &str,
        rootless: bool,
        cg: &str,
        manager: &str,
        controllers: &[&str],
    ) -> serde_json::Value {
        serde_json::json!({
            "host": {"cgroupVersion": cg, "cgroupManager": manager, "cgroupControllers": controllers,
                     "security": {"rootless": rootless}},
            "version": {"Version": version}
        })
    }

    fn observed(podman: Result<serde_json::Value, String>) -> Observed {
        Observed {
            systemd_user: Ok("262".into()),
            podman_info: podman,
            git: Ok("git version 2.51.0".into()),
            linger: true,
            cpuset_by_systemd: true,
            selinux: None,
            files: FileFacts {
                arch: "x86_64".into(),
                os: "fedora 45".into(),
                cores: 8,
                ..Default::default()
            },
        }
    }

    /// [D] A login confined as SELinux user_u (user_t) is refused by the contract with the cause and an admin's fix,
    /// even where podman answers; staff_u and a host without SELinux are not.
    #[test]
    fn a_user_u_login_fails_the_contract_with_the_cause() {
        let good = info("5.6.1", true, "v2", "systemd", &["cpu", "memory", "pids"]);
        let mut o = observed(Ok(good));
        o.selinux = Some("user_u:user_r:user_t:s0".into());
        let m = judge(&o).unwrap_err();
        assert_eq!(m.len(), 1, "{m:?}");
        assert!(
            m[0].what.contains("user_u") && m[0].what.contains("newuidmap"),
            "{m:?}"
        );
        assert!(
            m[0].fix.contains("semanage login") && m[0].fix.contains("subuid"),
            "{m:?}"
        );
        o.selinux = Some("staff_u:staff_r:staff_t:s0-s0:c0.c1023".into());
        assert!(judge(&o).is_ok());
        o.selinux = None;
        assert!(judge(&o).is_ok());
    }

    /// [D] A host that meets the contract reports its facts; one that lacks items gets every one of them, each with
    /// its fix, in one answer.
    #[test]
    fn contract_lists_every_missing_item_with_its_fix() {
        let good = info(
            "5.6.1",
            true,
            "v2",
            "systemd",
            &["cpuset", "cpu", "io", "memory", "pids"],
        );
        let f = judge(&observed(Ok(good))).unwrap();
        assert_eq!(
            (
                f.podman_version.as_str(),
                f.linger,
                f.cores,
                f.cpuset_by_systemd
            ),
            ("5.6.1", true, 8, true)
        );

        let mut o = observed(Ok(info(
            "4.9.4",
            false,
            "v1",
            "cgroupfs",
            &["cpu", "memory"],
        )));
        o.systemd_user = Err("Failed to connect to bus".into());
        o.git = Err("No such file or directory".into());
        let m = judge(&o).unwrap_err();
        let whats: Vec<&str> = m.iter().map(|m| m.what.as_str()).collect();
        for (want, fix) in [
            ("a systemd user manager", "enable-linger"),
            ("rootless podman 5 or newer (found 4.9.4)", "upgrade podman"),
            ("podman running rootless", "ordinary user"),
            ("cgroup v2", "unified_cgroup_hierarchy"),
            ("podman on the systemd cgroup manager", "cgroup_manager"),
            (
                "the cgroup controllers pids delegated",
                "Delegate=memory pids cpu",
            ),
            ("git", "install git"),
        ] {
            let item = m
                .iter()
                .find(|m| m.what.starts_with(want))
                .unwrap_or_else(|| panic!("{want}: {whats:?}"));
            assert!(item.fix.contains(fix), "{want}: {}", item.fix);
        }
        assert_eq!(m.len(), 7, "{whats:?}");

        // no podman at all: one item for it, with the install fix
        let m = judge(&observed(Err("podman: No such file or directory".into()))).unwrap_err();
        assert_eq!(m.len(), 1);
        assert!(
            m[0].what.contains("No such file") && m[0].fix.contains("install podman"),
            "{m:?}"
        );
        // linger is a fact, never a refusal: without it jobs end with the link, and the runner list says so
        let mut o = observed(Ok(info("5.0.0", true, "v2", "systemd", &CONTROLLERS)));
        o.linger = false;
        assert!(!judge(&o).unwrap().linger);
    }

    /// [D] The kernel's formats.
    #[test]
    fn files_parse_in_the_kernels_format() {
        let p = parse_pressure("some avg10=1.50 avg60=0.20 avg300=0.00 total=12345\nfull avg10=0.75 avg60=0.10 avg300=0.00 total=99\n").unwrap();
        assert_eq!(
            (p.some.avg10, p.some.total, p.full.unwrap().avg10),
            (1.5, 12345, 0.75)
        );
        assert!(
            parse_pressure("some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
                .unwrap()
                .full
                .is_none()
        );
        assert!(parse_pressure("garbage").is_err());
        let m = parse_meminfo(
            "MemTotal:       32768000 kB\nMemFree:  1 kB\nMemAvailable:   16384000 kB\n",
        );
        assert_eq!(
            m,
            Mem {
                total_mib: 32000,
                available_mib: 16000
            }
        );
        assert_eq!(
            parse_cpu_list("0-3,8,10-11\n").unwrap(),
            [0, 1, 2, 3, 8, 10, 11]
        );
        assert!(parse_cpu_list("3-1").is_err());
        assert_eq!(
            slice_path("drgnx-runner-work-a3f.slice"),
            Path::new(
                "drgnx.slice/drgnx-runner.slice/drgnx-runner-work.slice/drgnx-runner-work-a3f.slice"
            )
        );
        assert_eq!(slice_path("app.slice"), Path::new("app.slice"));
        assert_eq!(
            manager_cgroup(
                "0::/user.slice/user-1000.slice/user@1000.service/app.slice/x.service\n",
                1000
            ),
            Path::new("user.slice/user-1000.slice/user@1000.service")
        );
        assert_eq!(
            manager_cgroup("0::/user.slice/user-1000.slice/session-3.scope\n", 1000),
            Path::new("user.slice/user-1000.slice/user@1000.service")
        );
        assert_eq!(
            os_release("NAME=\"Fedora Linux\"\nID=fedora\nVERSION_ID=45\n"),
            "fedora 45"
        );
        assert_eq!(os_release(""), "linux");
    }

    /// [D] A cgroup's files, and the power supplies, from fixture trees.
    #[test]
    fn cgroup_and_power_read_from_fixtures() {
        let d = tempfile::tempdir().unwrap();
        let cg = d.path().join("cg");
        fs::create_dir_all(&cg).unwrap();
        for (f, s) in [
            ("memory.current", "3145728\n"),
            ("memory.stat", "anon 1048576\nfile 1048576\n"),
            ("memory.peak", "4194304\n"),
            (
                "memory.events",
                "low 0\nhigh 2\nmax 1\noom 1\noom_kill 1\noom_group_kill 1\n",
            ),
            ("cpu.stat", "usage_usec 2500000\nuser_usec 2000000\n"),
            (
                "memory.pressure",
                "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=60.00 avg60=0.00 avg300=0.00 total=5\n",
            ),
        ] {
            fs::write(cg.join(f), s).unwrap();
        }
        let s = CgroupStat::read(&cg).unwrap();
        assert_eq!(
            (
                s.current,
                s.file,
                s.peak,
                s.oom_kill,
                s.oom_group_kill,
                s.cpu_usec
            ),
            (3145728, 1048576, 4194304, 1, 1, 2500000)
        );
        assert_eq!(s.used_mib(), 2);
        assert_eq!(s.memory_pressure.full.unwrap().avg10, 60.0);

        let probe = |sys: &Path| Probe {
            name: "m".into(),
            proc_root: d.path().join("proc"),
            sys_root: sys.to_path_buf(),
            manager: d.path().join("mgr"),
            runtime_dir: d.path().join("run"),
            folder: d.path().to_path_buf(),
            slice_root: "t".into(),
            scheduler: "me".into(),
            profile: Profile::Dedicated,
        };
        let supply = |sys: &Path, name: &str, kind: &str, online: Option<&str>| {
            let p = sys.join("class/power_supply").join(name);
            fs::create_dir_all(&p).unwrap();
            fs::write(p.join("type"), format!("{kind}\n")).unwrap();
            if let Some(o) = online {
                fs::write(p.join("online"), format!("{o}\n")).unwrap();
            }
        };
        let desktop = d.path().join("sys-desktop");
        fs::create_dir_all(&desktop).unwrap();
        assert_eq!(
            probe(&desktop).power(),
            Power {
                battery: false,
                on_ac: true
            }
        );
        let laptop = d.path().join("sys-laptop");
        supply(&laptop, "BAT0", "Battery", None);
        supply(&laptop, "AC", "Mains", Some("0"));
        assert_eq!(
            probe(&laptop).power(),
            Power {
                battery: true,
                on_ac: false
            }
        );
        fs::write(laptop.join("class/power_supply/AC/online"), "1\n").unwrap();
        assert_eq!(
            probe(&laptop).power(),
            Power {
                battery: true,
                on_ac: true
            }
        );

        // the machine state: memory, pressure (the user's apps' only when the limits read them), boot, others
        let pr = d.path().join("proc");
        fs::create_dir_all(pr.join("pressure")).unwrap();
        fs::create_dir_all(pr.join("sys/kernel/random")).unwrap();
        fs::write(
            pr.join("meminfo"),
            "MemTotal: 8388608 kB\nMemAvailable: 4194304 kB\n",
        )
        .unwrap();
        fs::write(pr.join("sys/kernel/random/boot_id"), "b1\n").unwrap();
        for (f, s) in [("memory", "3.00"), ("cpu", "12.50"), ("io", "1.00")] {
            fs::write(
                pr.join("pressure").join(f),
                format!("some avg10={s} avg60=0.00 avg300=0.00 total=1\nfull avg10=0.50 avg60=0.00 avg300=0.00 total=1\n"),
            )
            .unwrap();
        }
        fs::create_dir_all(d.path().join("mgr/app.slice")).unwrap();
        fs::write(
            d.path().join("mgr/app.slice/memory.pressure"),
            "some avg10=7.00 avg60=0 avg300=0 total=0\n",
        )
        .unwrap();
        let p = probe(&laptop);
        let m = p
            .machine(1000, &Limits::for_profile(Profile::Dedicated, 8192, 4))
            .unwrap();
        assert_eq!(
            (
                m.mem_total_mib,
                m.mem_available_mib,
                m.boot_id.as_str(),
                m.now,
                m.on_ac
            ),
            (8192, 4096, "b1", 1000, true)
        );
        assert_eq!(
            (
                m.psi.mem_some10,
                m.psi.cpu_some10,
                m.psi.io_full10,
                m.psi.app_mem_some10
            ),
            (3.0, 12.5, 0.5, None)
        );
        let m = p
            .machine(1000, &Limits::for_profile(Profile::Workstation, 8192, 4))
            .unwrap();
        assert_eq!(m.psi.app_mem_some10, Some(7.0));
        assert!(m.others.is_empty() && m.running.is_empty());
    }
}
