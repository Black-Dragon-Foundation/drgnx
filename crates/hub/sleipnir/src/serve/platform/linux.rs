//! [`LinuxPlatform`]: transient systemd user units in job slices, containers under rootless podman, cgroups and PSI.

use super::super::attempts::{self, LOG};
use super::super::cleanup;
use super::super::{Config, NET_ALLOW, Pins, SLICE_ROOT, UNIT_SLACK_S};
use super::{LaunchReq, Platform};
use crate::linux::jobexec::{HELPER_SOCK, HelperSpec, JobExec};
use crate::linux::parse::Parser;
use crate::linux::podman::{self, Caps, ContainerImage, ContainerReq, RunnerArgs, RunnerMounts};
use crate::linux::probe::{self, Probe};
use crate::linux::reserve::{self, Reservations};
use crate::linux::resize::{self, Resize, Sized};
use crate::linux::{run, slices, unit};
use crate::proto::{Facts, Missing};
use forseti::{JobId, Limits, MachineState, Profile};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::time::Duration;

/// How long the relay sidecar's image check or import may take.
const PX_IMAGE_LIMIT: Duration = Duration::from_secs(60);

/// Linux: transient systemd user units in job slices, rootless podman containers, cgroups and PSI.
pub struct LinuxPlatform {
    probe: Probe,
    prefix: String,
    hub_id: String,
    profile: Profile,
    root: PathBuf,
    name: String,
    /// The `sleipnir` that runs job-exec, and whose folder holds the bundle's other binaries.
    exe: PathBuf,
    /// The opt-in container features the user allowed here, per project.
    features: Vec<(String, podman::Feature)>,
    /// The projects its own `runner.conf` lets use `/dev/kvm`.
    kvm_projects: Vec<String>,
    /// The owner's disk cap its own `runner.conf` sets, GB (`[disk] quota_gb`).
    disk_quota_gb: Option<u64>,
    /// The most instances one slot family may have (`[slots] max_slots`).
    max_slots: u32,
    /// What the disk can move, MiB/s (`[io] device_mbps`).
    io_device_mbps: Option<f64>,
    /// The timing slice's partition fallback was said (once per runner).
    partition_said: AtomicBool,
}

impl LinuxPlatform {
    pub fn new(cfg: &Config, exe: &Path) -> villa::Result<LinuxPlatform> {
        let probe = Probe::system(
            &cfg.name,
            &cfg.scheduler(),
            SLICE_ROOT,
            &cfg.root,
            cfg.profile,
        )
        .map_err(|e| villa::Error::unavailable(format!("the probe: {e}")))?;
        let conf = crate::fsio::read_to_string(cfg.root.join("runner.conf")).unwrap_or_default();
        Ok(LinuxPlatform {
            probe,
            prefix: cfg.prefix.clone(),
            hub_id: cfg.hub_id.clone(),
            profile: cfg.profile,
            root: cfg.root.clone(),
            name: cfg.name.clone(),
            features: cfg
                .features
                .iter()
                .filter_map(|s| {
                    let (p, f) = s.split_once(':')?;
                    Some((p.to_string(), podman::Feature::parse(f)?))
                })
                .collect(),
            kvm_projects: podman::kvm_projects(&conf),
            disk_quota_gb: super::disk_quota_gb(&conf),
            max_slots: super::max_slots(&conf),
            io_device_mbps: super::io_device_mbps(&conf),
            exe: exe.to_path_buf(),
            partition_said: AtomicBool::new(false),
        })
    }

    /// The platform on the fixture machine PROBE (`admit`'s rows).
    #[cfg(test)]
    pub(crate) fn from_probe(probe: Probe) -> LinuxPlatform {
        LinuxPlatform {
            name: probe.name.clone(),
            profile: probe.profile,
            root: probe.folder.clone(),
            probe,
            prefix: "t".into(),
            hub_id: "hubA".into(),
            exe: PathBuf::from("/nonexistent/sleipnir"),
            kvm_projects: vec![],
            disk_quota_gb: None,
            max_slots: crate::sync::slot::DEFAULT_MAX_SLOTS,
            io_device_mbps: None,
            features: vec![],
            partition_said: AtomicBool::new(false),
        }
    }

    /// Job ID's slice: under the timing slice for a timing job (its slice is there), else under the work slice.
    fn slice_of(&self, id: &str) -> villa::Result<String> {
        let timing = slices::timing_job_slice(SLICE_ROOT, id)?;
        if self.probe.slice_dir(&timing).is_dir() {
            return Ok(timing);
        }
        slices::job_slice(SLICE_ROOT, id)
    }

    /// Job ID's container.
    fn container(&self, id: &str) -> String {
        format!("{}-{id}", self.prefix)
    }

    /// The relay sidecar's image, imported from the bundle's `drgnx-px-<arch>-linux-musl` beside this binary if it
    /// isn't there yet (tagged by content: a new bundle is a new image).
    fn px_image(&self) -> villa::Result<String> {
        let arch = if std::env::consts::ARCH == "aarch64" {
            "arm64"
        } else {
            "amd64"
        };
        let dir = self.exe.parent().unwrap_or(Path::new("."));
        let bin = ferja::image::binary_for(dir, arch);
        let px = fs::read(&bin).map_err(|e| {
            villa::Error::unavailable(format!(
                "drgnx could not build its proxy image: {}: {e}",
                bin.display()
            ))
        })?;
        let env: Vec<_> = std::env::vars_os().collect();
        ferja::image::ensure_image(
            Path::new("podman"),
            &env,
            &ferja::image::image_tar(&px),
            PX_IMAGE_LIMIT,
        )
        .map_err(|e| {
            villa::Error::unavailable(format!("drgnx could not build its proxy image: {e}"))
        })
    }
}

impl Platform for LinuxPlatform {
    fn machine(&self, now: u64, limits: &Limits) -> io::Result<MachineState> {
        self.probe.machine(now, limits)
    }

    fn limits(&self, profile: Profile) -> Limits {
        let mem = self.probe.memory().map(|m| m.total_mib).unwrap_or(0);
        let cores = self
            .probe
            .cpus_usable()
            .map(|c| c.len() as u32)
            .unwrap_or(1);
        Limits::for_profile(profile, mem, cores)
    }

    fn boot_id(&self) -> String {
        self.probe.boot_id().unwrap_or_default()
    }

    fn contract(&self) -> Result<Facts, Vec<Missing>> {
        probe::contract(&self.probe, Path::new("podman"))
    }

    /// Whether linger is on for this user (logind's live answer), so its jobs outlive the link.
    fn survives_link(&self) -> bool {
        let uid = rustix::process::getuid().as_raw().to_string();
        run::limited(
            Path::new("loginctl"),
            &["show-user", &uid, "--property=Linger", "--value"],
            &[],
            run::SYSTEMCTL_LIMIT,
        )
        .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "yes")
    }

    /// podman's caps check (a container's memory, CPU and pid limits take), and `podman` as the feature once they do;
    /// then `gpu` and `kvm` where this user can open them ([`Probe::devices`]), and `account:admin` for an
    /// administrator's login.
    fn job_runner(&self) -> (Option<String>, Vec<String>) {
        let env: Vec<(std::ffi::OsString, std::ffi::OsString)> = [
            "PATH",
            stig::HOME_VAR,
            stig::SYSTEM_RUNTIME_VAR,
            "DBUS_SESSION_BUS_ADDRESS",
        ]
        .iter()
        .filter_map(|k| Some((k.into(), std::env::var_os(k)?)))
        .collect();
        let limits = podman::check_limits(Path::new("podman"), &env, run::SYSTEMCTL_LIMIT)
            .err()
            .map(|e| e.to_string());
        let mut features = if limits.is_none() {
            vec!["podman".to_string()]
        } else {
            vec![]
        };
        features.extend(self.probe.devices(Path::new("/dev")));
        // the projects its own config lets use kvm, for the hub to read with the device (D2)
        features.extend(self.kvm_projects.iter().map(|p| format!("kvm-for:{p}")));
        // an administrator's login is taken as any other; the runner list shows what that exposes
        if probe::is_admin(&probe::own_groups()) {
            features.push("account:admin".into());
        }
        (limits, features)
    }

    fn reservations(&self) -> Reservations {
        self.probe.reservations()
    }

    fn start_time(&self, pid: u32) -> io::Result<u64> {
        reserve::start_time(pid)
    }

    fn current_mib(&self, id: &str) -> Option<u64> {
        let slice = self.slice_of(id).ok()?;
        self.probe.cgroup(&slice).ok().map(|c| c.used_mib())
    }

    /// The attempt's job slice, its `job.json` (its container's `podman run`), `sleipnir job-exec` in a transient
    /// service.
    fn launch(&self, req: &LaunchReq) -> villa::Result<(String, u32)> {
        let (dir, meta) = (req.dir, req.meta);
        let id = &meta.r.job;
        if !req.env.is_empty() {
            return Err(villa::Error::unavailable(
                "variables for the container aren't carried yet",
            ));
        }
        let mut ra0 = RunnerArgs::runner(&self.prefix, &self.hub_id, "job.slice");
        ra0.allowed = podman::allowed_for(
            meta.spec.project.as_str(),
            &self.features,
            &self.kvm_projects,
        );
        let plan = super::artifacts::prepare(
            &self.root,
            dir,
            req.src,
            &meta.spec,
            &meta.grant,
            &format!("{id}.{}", meta.r.attempt),
            &ra0,
        )?;
        let image = match (&plan, req.image.clone()) {
            (super::artifacts::Plan::Host { .. }, i) => i.unwrap_or_default(),
            (_, Some(i)) => i,
            (_, None) => {
                return Err(villa::Error::invalid(
                    "a runner job is a container job: it needs an image",
                ));
            }
        };
        if let Some(why) = crate::linux::confined::refusal() {
            return Err(villa::Error::refused(why));
        }
        // the job's own copy of the bundle's drgnx-key: each container relabels its mounts (`Z`); the container runs it,
        // so its write descriptor is kept out of the runner's other forks (hlaup)
        let own_copy = |name: &str| -> villa::Result<PathBuf> {
            let from = self.exe.with_file_name(name);
            let to = dir.join(name);
            hlaup::copy(&from, &to).map(|_| to).map_err(|e| {
                villa::Error::unavailable(format!(
                    "{name} from the bundle ({}): {e}",
                    from.display()
                ))
            })
        };
        let keys = if meta.spec.keys.is_empty() {
            None
        } else {
            Some(podman::KeyMounts {
                helper: own_copy("drgnx-key")?,
                vars: match &plan {
                    super::artifacts::Plan::Run(r) if !r.key_vars.is_empty() => r.key_vars.clone(),
                    _ => meta
                        .spec
                        .keys
                        .iter()
                        .map(|k| (k.clone(), k.clone()))
                        .collect(),
                },
            })
        };
        let hub_allow = if req.net_hosts.is_empty() {
            None
        } else {
            let text = req.net_hosts.join("\n") + "\n";
            crate::net::allow_list(&text)?;
            let f = dir.join(NET_ALLOW);
            crate::fsio::write(&f, text)
                .map_err(|e| villa::Error::unavailable(format!("{NET_ALLOW}: {e}")))?;
            Some(f)
        };
        let parser =
            Parser::from_name(req.parser).map_err(|e| villa::Error::unavailable(e.message()))?;
        slices::ensure_tree(SLICE_ROOT, self.profile)?;
        // a timing job runs on the island: its slice is under the timing slice, out of the work slice's CPUs
        let slice = if matches!(meta.spec.lane, forseti::Lane::Timing { pinned: Some(_) }) {
            slices::timing_job_slice(SLICE_ROOT, id)?
        } else {
            slices::job_slice(SLICE_ROOT, id)?
        };
        // the job's slice throttles past its reservation and is killed at its cap, whatever runs in it (§3 #3)
        slices::set(
            &slice,
            &slices::job_props(meta.grant.reserve_mib, meta.grant.mem_cap_mib),
        )?;
        let mut ra = RunnerArgs::runner(&self.prefix, &self.hub_id, &slice);
        // the opt-ins the user gave this job's project here (D2)
        ra.allowed = podman::allowed_for(
            meta.spec.project.as_str(),
            &self.features,
            &self.kvm_projects,
        );
        ra.render_node = self.probe.render_node(Path::new("/dev"));
        // a networked or keyed job's relay: the sidecar's image from the bundle's binary, its name and its argv for the
        // helper (a keyed job reads its keys through it)
        let relay = if hub_allow.is_none() && keys.is_none() {
            None
        } else {
            Some(net_helper(&ra, id, &self.px_image()?, keys.is_some())?)
        };
        let proxy = relay.as_ref().map(|r| r.0.clone());
        let caps = Caps {
            proxy,
            ..job_caps(&meta.grant, image, req.pins.clone())
        };
        let keyed = keys.is_some();
        let creq = ContainerReq {
            features: meta
                .spec
                .features
                .iter()
                .filter_map(|f| podman::Feature::parse(f))
                .collect(),
            image: match &plan {
                super::artifacts::Plan::Run(r) => r.image.clone(),
                super::artifacts::Plan::Host { .. } => "job".into(),
            },
            argv: match &plan {
                super::artifacts::Plan::Run(r) => r.argv.clone(),
                super::artifacts::Plan::Host { .. } => vec![],
            },
            worktree: req.src.to_path_buf(),
            subdir: if meta.spec.cwd == Path::new(".") {
                PathBuf::new()
            } else {
                meta.spec.cwd.clone()
            },
            job: id.clone(),
            net: hub_allow.is_some(),
            keys,
            runner: Some(RunnerMounts {
                writes_tree: meta.spec.writes_tree,
                target: dir.join("target"),
                caches: match &plan {
                    super::artifacts::Plan::Run(r) => r.caches.clone(),
                    _ => vec![],
                },
                git_ro: req.git_ro.map(Path::to_path_buf),
                jobserver: req.jobserver.map(Path::to_path_buf),
                uses: match &plan {
                    super::artifacts::Plan::Run(r) => r.uses.clone(),
                    _ => vec![],
                },
                out: match &plan {
                    super::artifacts::Plan::Run(r) => r.out.clone(),
                    _ => None,
                },
                env: match &plan {
                    super::artifacts::Plan::Run(r) => r.env.clone(),
                    _ => vec![],
                },
            }),
        };
        let container =
            podman::name_of(&ra.name_prefix, id).map_err(|r| villa::Error::invalid(r.message))?;
        let mut argv = vec!["podman".to_string()];
        if let super::artifacts::Plan::Host { argv: host } = &plan {
            argv = host.clone();
        } else {
            for a in
                podman::argv(&creq, &caps, &ra).map_err(|r| villa::Error::invalid(r.message))?
            {
                argv.push(
                    a.into_string()
                        .map_err(|_| villa::Error::invalid("a podman argument is not UTF-8"))?,
                );
            }
        }
        let log = dir.join(LOG);
        JobExec {
            id: id.clone(),
            attempt: meta.r.attempt,
            machine: self.name.clone(),
            slice: slice.clone(),
            argv,
            env: vec![],
            cwd: None,
            log: log.clone(),
            state_logs: vec![],
            keyed,
            parser,
            expect: meta.spec.expect,
            grant: meta.grant,
            timeout_s: meta.spec.timeout_s,
            stall_s: meta.spec.derived.stall_s,
            silent_s: meta.spec.derived.silent_s,
            // every runner job has its helper: the disk watch, and its keys and proxy when it has them
            helper: Some(HelperSpec {
                root: self.root.clone(),
                keys: meta.spec.keys.clone(),
                hub_allow,
                net: relay.as_ref().map(|r| r.0.clone()),
                sidecar_argv: relay.map(|r| r.1).unwrap_or_default(),
                container: Some(container),
                ..HelperSpec::default()
            }),
        }
        .write(dir)
        .map_err(|e| villa::Error::unavailable(format!("job.json: {e}")))?;
        let name = format!("{}-{id}-{}", self.prefix, meta.r.attempt);
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

    fn active(&self, unit: &str) -> bool {
        unit::active(unit)
    }

    fn kill(&self, id: &str) -> villa::Result<()> {
        let name = self.container(id);
        run::limited(
            Path::new("podman"),
            &["kill", &name],
            &[],
            run::SYSTEMCTL_LIMIT,
        )
        .map(|_| ())
        .map_err(|e| villa::Error::unavailable(format!("podman kill {name}: {e}")))
    }

    fn pause(&self, id: &str) -> villa::Result<()> {
        resize::pause(&self.container(id))
    }

    fn unpause(&self, id: &str) -> villa::Result<()> {
        resize::unpause(&self.container(id))
    }

    /// The slice's `memory.current` (its container and job-exec) sorts out the jobs well under the cap; the
    /// container's own reading is what a grow judges.
    fn grow_candidate(&self, id: &str, cap_mib: u64, max_mib: u64) -> Option<Sized> {
        let near = self
            .slice_of(id)
            .ok()
            .and_then(|s| self.probe.cgroup(&s).ok())
            .is_some_and(|c| c.current / (1024 * 1024) * 100 > cap_mib * resize::GROW_AT_PCT);
        if !near {
            return None;
        }
        let container = self.container(id);
        let current_mib = resize::container_cgroup(&container)
            .and_then(|cg| resize::current_mib(&cg))
            .ok()?;
        Some(Sized {
            job: JobId(id.to_string()),
            container,
            machine: self.name.clone(),
            cap_mib,
            current_mib,
            max_mib,
        })
    }

    fn resize(&self, r: &Resize) -> villa::Result<()> {
        resize::apply(r)
    }

    fn weight_unit(&self, id: &str) -> Option<String> {
        self.slice_of(id).ok()
    }

    fn set_weight(&self, unit: &str, w: u32) -> villa::Result<()> {
        resize::set_weight(unit, w)
    }

    fn set_io_weight(&self, unit: &str, w: u32) -> villa::Result<()> {
        crate::linux::slices::set(unit, &[("IOWeight", w.to_string())])
    }

    fn io_cap(&self, id: &str, mbps: Option<f64>) -> villa::Result<()> {
        let mountinfo = crate::fsio::read_to_string("/proc/self/mountinfo").unwrap_or_default();
        let sys = crate::linux::io::Sys {
            mountinfo: &mountinfo,
            sysfs: Path::new("/sys"),
            cgroup: Path::new("/sys/fs/cgroup"),
        };
        let dev = crate::linux::io::device_of(&sys, &self.root).ok_or_else(|| {
            villa::Error::unavailable("the runner's folder is on no block device".to_string())
        })?;
        let (max, _) = crate::linux::io::files(&resize::container_cgroup(&self.container(id))?);
        let line = match mbps {
            Some(m) => crate::linux::io::max_line(&dev, m),
            None => crate::linux::io::lift_line(&dev),
        };
        crate::fsio::write_in_place(&max, line)
            .map_err(|e| villa::Error::io(format!("{}: {e}", max.display())))
    }

    fn hand_key(&self, dir: &Path, name: &str, value: &[u8]) -> io::Result<()> {
        crate::helper::keys::hand(&dir.join(HELPER_SOCK), name, value)
    }

    fn island_check(&self, island: &str) -> villa::Result<()> {
        slices::island_whole_l3(Path::new("/sys/devices/system/cpu"), island)?;
        let usable = self
            .probe
            .cpus_usable()
            .map_err(|e| villa::Error::unavailable(format!("the usable CPUs: {e}")))?;
        let cpus = probe::parse_cpu_list(island)?;
        if let Some(c) = cpus.iter().find(|c| !usable.contains(c)) {
            return Err(villa::Error::invalid(format!(
                "the island {island} has CPU {c}, which this runner may not use"
            )));
        }
        if cpus.len() >= usable.len() {
            return Err(villa::Error::invalid(format!(
                "the island {island} leaves no CPU for work"
            )));
        }
        Ok(())
    }

    fn island(&self, on: Option<&str>) -> villa::Result<()> {
        let by_systemd = self.probe.cpuset_by_systemd()?;
        let rest = match on {
            None => String::new(),
            Some(island) => {
                let usable = self
                    .probe
                    .cpus_usable()
                    .map_err(|e| villa::Error::unavailable(format!("the usable CPUs: {e}")))?;
                let isl = probe::parse_cpu_list(island)?;
                let rest: Vec<u32> = usable.into_iter().filter(|c| !isl.contains(c)).collect();
                slices::cpu_list(&rest)
            }
        };
        slices::island_on(
            &self.probe.manager,
            SLICE_ROOT,
            on.map(|i| (i, rest.as_str())),
            by_systemd,
            &self.partition_said,
        )
        .map(|_| ())
    }

    fn cleanup(&self, root: &Path, owner: &cleanup::Owner) {
        let seen = cleanup::Seen {
            containers: cleanup::containers(&self.prefix, &self.hub_id),
            units: cleanup::units(&self.prefix),
            folders: attempts::scan(root, &unit::active),
            bundles: cleanup::bundles(root),
            slices: cleanup::slices(crate::serve::SLICE_ROOT),
        };
        cleanup::apply(root, &cleanup::plan(owner, &seen));
    }

    fn df(&self, root: &Path) -> io::Result<crate::sync::guard::Df> {
        // a test build's facts file sets the disk the guard sees, as it does the machine's
        #[cfg(feature = "test-hooks")]
        if self.probe.folder.join(probe::TEST_MACHINE).exists() {
            let d = self.probe.disk_seen()?;
            let gb = crate::sync::guard::GB;
            return Ok(crate::sync::guard::Df {
                total: d.size_gb.saturating_mul(gb),
                avail: d.free_gb.saturating_mul(gb),
            });
        }
        crate::sync::guard::df(root)
    }

    fn btrfs_unallocated(&self, root: &Path) -> Option<u64> {
        let mountinfo = crate::fsio::read_to_string("/proc/self/mountinfo").ok()?;
        let (fstype, source) = mount_of(&mountinfo, root)?;
        if fstype != "btrfs" {
            return None;
        }
        // a mapper name (`/dev/mapper/luks-…`) is a link to its `dm-N`, which sysfs lists
        let dev = fs::canonicalize(&source).unwrap_or_else(|_| PathBuf::from(&source));
        let name = dev.file_name()?.to_str()?;
        unallocated(Path::new("/sys/fs/btrfs"), name)
    }

    fn disk_quota_gb(&self) -> Option<u64> {
        self.disk_quota_gb
    }

    fn artifact_done(
        &self,
        dir: &Path,
        spec: &forseti::JobSpec,
        passed: bool,
    ) -> villa::Result<()> {
        super::artifacts::done(&self.root, dir, spec, passed)
    }

    fn max_slots(&self) -> u32 {
        self.max_slots
    }

    fn io_device_mbps(&self) -> Option<f64> {
        self.io_device_mbps
    }
}

/// The file system type and source of the mount FOLDER is on, from MOUNTINFO (`/proc/self/mountinfo`): the longest
/// mount point that holds it.
pub(in crate::serve) fn mount_of(mountinfo: &str, folder: &Path) -> Option<(String, String)> {
    let mut best: Option<(usize, String, String)> = None;
    for line in mountinfo.lines() {
        let Some((left, right)) = line.split_once(" - ") else {
            continue;
        };
        let mut r = right.split(' ');
        let (Some(point), Some(fstype), Some(source)) =
            (left.split(' ').nth(4), r.next(), r.next())
        else {
            continue;
        };
        // mountinfo escapes a space and the like as octal
        let point = point.replace("\\040", " ");
        if folder.starts_with(&point) && best.as_ref().is_none_or(|(n, _, _)| point.len() > *n) {
            best = Some((point.len(), fstype.to_string(), source.to_string()));
        }
    }
    best.map(|(_, t, s)| (t, s))
}

/// The bytes no chunk holds yet on the btrfs whose device is DEV (a name under `/sys/class/block`), from sysfs at
/// BTRFS (`/sys/fs/btrfs`): the devices' sizes less what each allocation class takes on disk (`disk_total`).
pub(in crate::serve) fn unallocated(btrfs: &Path, dev: &str) -> Option<u64> {
    let read =
        |p: PathBuf| -> Option<u64> { crate::fsio::read_to_string(p).ok()?.trim().parse().ok() };
    for fs_dir in fs::read_dir(btrfs).ok()?.flatten() {
        let devices = fs_dir.path().join("devices");
        if !devices.join(dev).exists() {
            continue;
        }
        let mut size = 0u64;
        for d in fs::read_dir(&devices).ok()?.flatten() {
            // a block device's size is in 512-byte sectors
            size = size.saturating_add(read(d.path().join("size"))?.saturating_mul(512));
        }
        let mut taken = 0u64;
        for class in ["data", "metadata", "system"] {
            taken = taken.saturating_add(
                read(
                    fs_dir
                        .path()
                        .join("allocation")
                        .join(class)
                        .join("disk_total"),
                )
                .unwrap_or(0),
            );
        }
        return Some(size.saturating_sub(taken));
    }
    None
}

/// A networked job's relay as its `job.json` names it: the sidecar ([`podman::JobNet`]) and the sidecar's `podman`
/// arguments for the helper, for job ID under RA from the relay image IMAGE.
pub(in crate::serve) fn net_helper(
    ra: &RunnerArgs,
    id: &str,
    image: &str,
    keyed: bool,
) -> villa::Result<(podman::JobNet, Vec<String>)> {
    let names = podman::net_names(ra, id).map_err(|r| villa::Error::invalid(r.message))?;
    let argv = podman::sidecar_argv(&names, ra, image, keyed)
        .map_err(|r| villa::Error::invalid(r.message))?
        .into_iter()
        .map(|a| {
            a.into_string()
                .map_err(|_| villa::Error::invalid("a sidecar argument is not UTF-8"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok((
        podman::JobNet {
            sidecar: names.sidecar,
        },
        argv,
    ))
}

/// The caps of a container job in IMAGE under GRANT, its proxy pinning PINS.
pub(in crate::serve) fn job_caps(grant: &forseti::Grant, image: String, pins: Pins) -> Caps {
    Caps {
        images: vec![ContainerImage {
            name: "job".into(),
            image,
        }],
        memory: format!("{}M", grant.mem_cap_mib.max(6)),
        cpus: grant.cores.max(1),
        pids: podman::PIDS,
        proxy: None,
        net_hosts: vec![],
        pins,
    }
}
