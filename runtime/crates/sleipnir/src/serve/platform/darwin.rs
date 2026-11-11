//! [`DarwinPlatform`]: a Mac runner. Host jobs (no containers, no keys) under Seatbelt, each attempt's job-exec in a
//! session of its own with a pid file (`darwin::attempt`: launchd can't take a job from an ssh login, spike S1). No
//! pause, grow or CPU weights; memory is watched, not kernel-enforced (the watchdog, M6).

use super::super::Config;
use super::super::attempts::{self, LOG};
use super::super::cleanup;
use super::{LaunchReq, Platform};
use crate::darwin::{attempt, jobexec, probe, sandbox};
use crate::linux::jobexec::JobExec;
use crate::linux::parse::Parser;
use crate::linux::reserve::{self, Reservations};
use crate::linux::resize::{Resize, Sized};
use crate::proto::{Facts, Missing};
use forseti::{Limits, MachineState, Profile};
use std::cell::RefCell;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// A Mac runner, in its own standard account.
pub struct DarwinPlatform {
    root: PathBuf,
    hub_id: String,
    name: String,
    profile: Profile,
    /// The `sleipnir` that runs job-exec.
    exe: PathBuf,
    /// The machine as last read (`hello`, `probe`, each `ready`'s re-read of the tools).
    raw: RefCell<probe::Raw>,
}

impl DarwinPlatform {
    pub fn new(cfg: &Config, exe: &Path) -> Result<DarwinPlatform, String> {
        Ok(DarwinPlatform {
            root: cfg.root.clone(),
            hub_id: cfg.hub_id.clone(),
            name: cfg.name.clone(),
            profile: cfg.profile,
            exe: exe.to_path_buf(),
            raw: RefCell::new(probe::read(&cfg.root)),
        })
    }

    fn scheduler(&self) -> String {
        format!("drgnx-{}", self.hub_id)
    }

    /// The attempt folders of job ID.
    fn dirs_of(&self, id: &str) -> Vec<PathBuf> {
        let Ok(rd) = fs::read_dir(attempts::jobs(&self.root)) else {
            return vec![];
        };
        rd.flatten()
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .rsplit_once('.')
                    .is_some_and(|(j, n)| j == id && n.parse::<u32>().is_ok())
            })
            .map(|e| e.path())
            .collect()
    }
}

/// Memory still free for new work, MiB: `kern.memorystatus_level` (the percentage available) of TOTAL.
fn available_mib(total: u64) -> u64 {
    let mut level: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>();
    // SAFETY: a NUL-terminated name and an int-sized buffer
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.memorystatus_level".as_ptr(),
            (&mut level as *mut libc::c_int).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return 0;
    }
    total * level.clamp(0, 100) as u64 / 100
}

impl Platform for DarwinPlatform {
    fn machine(&self, now: u64, _limits: &Limits) -> io::Result<MachineState> {
        let raw = self.raw.borrow();
        let total = raw.memsize.trim().parse::<u64>().unwrap_or(0) / (1024 * 1024);
        let boot_id = raw.boot_session.clone();
        let disk = rustix::fs::statvfs(&self.root).map_err(io::Error::from)?;
        let gb = |blocks: u64| blocks * disk.f_frsize / 1_000_000_000;
        let batt = std::process::Command::new("/usr/bin/pmset")
            .args(["-g", "batt"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        let others = self
            .reservations()
            .read_others(&self.scheduler())
            .into_iter()
            .filter(|r| r.boot_id == boot_id && reserve::alive(r.pid, r.start_time))
            .collect();
        Ok(MachineState {
            name: self.name.clone(),
            profile: self.profile,
            now,
            boot_id,
            mem_total_mib: total,
            mem_available_mib: available_mib(total),
            psi: Default::default(),
            disk_free_gb: gb(disk.f_bavail),
            disk_total_gb: gb(disk.f_blocks),
            on_ac: probe::on_ac(&batt),
            last_start: None,
            running: vec![],
            features: vec![],
            reachable: true,
            others,
        })
    }

    fn limits(&self, profile: Profile) -> Limits {
        let raw = self.raw.borrow();
        let mem = raw.memsize.trim().parse::<u64>().unwrap_or(0) / (1024 * 1024);
        let cores = raw.ncpu.trim().parse::<u32>().unwrap_or(1);
        Limits::for_profile(profile, mem, cores)
    }

    fn boot_id(&self) -> String {
        self.raw.borrow().boot_session.clone()
    }

    fn contract(&self) -> Result<Facts, Vec<Missing>> {
        *self.raw.borrow_mut() = probe::read(&self.root);
        let others = self
            .reservations()
            .read_others(&self.scheduler())
            .into_iter()
            .map(|r| r.scheduler)
            .collect();
        probe::contract(&self.raw.borrow(), others)
    }

    /// Always: an attempt runs in a session of its own, which outlives the link.
    fn survives_link(&self) -> bool {
        true
    }

    fn job_runner(&self) -> (Option<String>, Vec<String>) {
        (None, probe::features(&self.raw.borrow()))
    }

    /// Under the runner root (a Mac has no `$XDG_RUNTIME_DIR`).
    fn reservations(&self) -> Reservations {
        Reservations::at(&self.root.join("run"))
    }

    fn start_time(&self, pid: u32) -> io::Result<u64> {
        reserve::start_time(pid)
    }

    fn current_mib(&self, _id: &str) -> Option<u64> {
        None
    }

    fn launch(&self, req: &LaunchReq) -> Result<(String, u32), String> {
        let (dir, meta) = (req.dir, req.meta);
        let id = &meta.r.job;
        if req.image.is_some() {
            return Err("a Mac runner runs host jobs: no container image".into());
        }
        if !meta.spec.keys.is_empty() {
            return Err("a Mac runner never gets keys".into());
        }
        if !req.env.is_empty() || !req.net_hosts.is_empty() {
            return Err("a Mac job has no extra variables and no network yet".into());
        }
        let parser: Parser =
            serde_json::from_value(serde_json::Value::String(if req.parser.is_empty() {
                "exit".into()
            } else {
                req.parser.to_string()
            }))
            .map_err(|_| format!("no row parser {:?}", req.parser))?;
        let (home, tmp) = sandbox::home_tmp(dir);
        for d in [&home, &tmp] {
            fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
        }
        let marker = format!("{}/{id}/{}", self.hub_id, meta.r.attempt);
        let spec = sandbox::spec(&sandbox::Job {
            dir,
            src: req.src,
            cwd: &meta.spec.cwd,
            writes_tree: meta.spec.writes_tree,
            marker: &marker,
        });
        let env = spec.env.clone();
        let ctx = gleipnir::Context {
            home: std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default(),
            closed: vec![],
            open_inside_closed: vec![],
            user_sockets: vec![],
            run_parents: vec![],
            program_dirs: sandbox::PATH.split(':').map(PathBuf::from).collect(),
            env_deny: vec![],
        };
        let valid = gleipnir::validate(spec, &ctx, gleipnir::spec::Target::Macos)
            .map_err(|r| format!("the job's sandbox: {}", r.message))?;
        let developer_dir = fs::canonicalize(probe_developer_dir(&self.raw.borrow())).ok();
        let profile = gleipnir::sbpl::profile(
            &valid,
            &gleipnir::sbpl::MacContext {
                developer_dir,
                ..Default::default()
            },
        )
        .map_err(|r| format!("the job's profile: {}", r.message))?;
        let sb = dir.join("job.sb");
        fs::write(&sb, profile).map_err(|e| format!("job.sb: {e}"))?;
        let mut argv = vec![
            jobexec::SANDBOX_EXEC.to_string(),
            "-f".into(),
            sb.display().to_string(),
        ];
        argv.extend(meta.spec.command.iter().cloned());
        JobExec {
            id: id.clone(),
            attempt: meta.r.attempt,
            machine: self.name.clone(),
            slice: String::new(),
            argv,
            env,
            cwd: Some(valid.spec().chdir.clone()),
            log: dir.join(LOG),
            state_logs: vec![],
            keyed: false,
            parser,
            expect: meta.spec.expect,
            grant: meta.grant,
            timeout_s: meta.spec.timeout_s,
            helper: None,
        }
        .write(dir)
        .map_err(|e| format!("job.json: {e}"))?;
        let pid = attempt::launch(
            dir,
            &self.exe,
            &[std::ffi::OsStr::new("job-exec"), dir.as_os_str()],
        )
        .map_err(|e| format!("job-exec: {e}"))?;
        Ok((dir.display().to_string(), pid))
    }

    fn active(&self, unit: &str) -> bool {
        attempt::active(Path::new(unit))
    }

    fn kill(&self, id: &str) -> Result<(), String> {
        for d in self.dirs_of(id) {
            attempt::kill(&d).map_err(|e| format!("{}: {e}", d.display()))?;
        }
        Ok(())
    }

    fn pause(&self, _id: &str) -> Result<(), String> {
        Err("a Mac runner doesn't pause jobs".into())
    }

    fn unpause(&self, _id: &str) -> Result<(), String> {
        Err("a Mac runner doesn't pause jobs".into())
    }

    fn grow_candidate(&self, _id: &str, _cap_mib: u64, _max_mib: u64) -> Option<Sized> {
        None
    }

    fn resize(&self, _r: &Resize) -> Result<(), String> {
        Err("a Mac runner doesn't resize jobs".into())
    }

    fn weight_unit(&self, _id: &str) -> Option<String> {
        None
    }

    fn set_weight(&self, _unit: &str, _w: u32) -> Result<(), String> {
        Err("a Mac runner has no CPU weights".into())
    }

    fn hand_key(&self, _dir: &Path, _name: &str, _value: &[u8]) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "a Mac runner never gets keys",
        ))
    }

    /// Attempt folders that ended, and bundles no longer used (no units or containers on a Mac).
    fn cleanup(&self, root: &Path, owner: &cleanup::Owner) {
        let seen = cleanup::Seen {
            containers: serde_json::Value::Array(vec![]),
            units: vec![],
            folders: attempts::scan(root, &|unit: &str| attempt::active(Path::new(unit))),
            bundles: cleanup::bundles(root),
        };
        cleanup::apply(root, &cleanup::plan(owner, &seen));
    }
}

/// The developer dir `xcode-select` names (none: the system roots only).
fn probe_developer_dir(raw: &probe::Raw) -> PathBuf {
    PathBuf::from(raw.developer_dir.trim())
}
