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
}

impl LinuxPlatform {
    pub fn new(cfg: &Config, exe: &Path) -> Result<LinuxPlatform, String> {
        let probe = Probe::system(
            &cfg.name,
            &cfg.scheduler(),
            SLICE_ROOT,
            &cfg.root,
            cfg.profile,
        )
        .map_err(|e| format!("the probe: {e}"))?;
        Ok(LinuxPlatform {
            probe,
            prefix: cfg.prefix.clone(),
            hub_id: cfg.hub_id.clone(),
            profile: cfg.profile,
            root: cfg.root.clone(),
            name: cfg.name.clone(),
            exe: exe.to_path_buf(),
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
        }
    }

    /// Job ID's container.
    fn container(&self, id: &str) -> String {
        format!("{}-{id}", self.prefix)
    }

    /// The relay sidecar's image, imported from the bundle's `drgnx-px-<arch>-linux-musl` beside this binary if it
    /// isn't there yet (tagged by content: a new bundle is a new image).
    fn px_image(&self) -> Result<String, String> {
        let arch = if std::env::consts::ARCH == "aarch64" {
            "arm64"
        } else {
            "amd64"
        };
        let dir = self.exe.parent().unwrap_or(Path::new("."));
        let bin = drgnx_px::image::binary_for(dir, arch);
        let px = fs::read(&bin).map_err(|e| {
            format!(
                "drgnx could not build its proxy image: {}: {e}",
                bin.display()
            )
        })?;
        let env: Vec<_> = std::env::vars_os().collect();
        drgnx_px::image::ensure_image(
            Path::new("podman"),
            &env,
            &drgnx_px::image::image_tar(&px),
            PX_IMAGE_LIMIT,
        )
        .map_err(|e| format!("drgnx could not build its proxy image: {e}"))
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

    /// podman's caps check (a container's memory, CPU and pid limits take), and `podman` as the feature once they do.
    fn job_runner(&self) -> (Option<String>, Vec<String>) {
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
        (limits, features)
    }

    fn reservations(&self) -> Reservations {
        self.probe.reservations()
    }

    fn start_time(&self, pid: u32) -> io::Result<u64> {
        reserve::start_time(pid)
    }

    fn current_mib(&self, id: &str) -> Option<u64> {
        let slice = slices::job_slice(SLICE_ROOT, id).ok()?;
        self.probe.cgroup(&slice).ok().map(|c| c.used_mib())
    }

    /// The attempt's job slice, its `job.json` (its container's `podman run`), `sleipnir job-exec` in a transient
    /// service.
    fn launch(&self, req: &LaunchReq) -> Result<(String, u32), String> {
        let (dir, meta) = (req.dir, req.meta);
        let id = &meta.r.job;
        if !req.env.is_empty() {
            return Err("variables for the container aren't carried yet".into());
        }
        let image = req
            .image
            .clone()
            .ok_or("a runner job is a container job: it needs an image")?;
        if let Some(why) = crate::linux::confined::refusal() {
            return Err(why);
        }
        // the job's own copy of the bundle's drgnx-key: each container relabels its mounts (`Z`)
        let own_copy = |name: &str| -> Result<PathBuf, String> {
            let from = self.exe.with_file_name(name);
            let to = dir.join(name);
            fs::copy(&from, &to)
                .map(|_| to)
                .map_err(|e| format!("{name} from the bundle ({}): {e}", from.display()))
        };
        let keys = if meta.spec.keys.is_empty() {
            None
        } else {
            Some(podman::KeyMounts {
                helper: own_copy("drgnx-key")?,
                vars: meta
                    .spec
                    .keys
                    .iter()
                    .map(|k| (k.clone(), k.clone()))
                    .collect(),
            })
        };
        let hub_allow = if req.net_hosts.is_empty() {
            None
        } else {
            let text = req.net_hosts.join("\n") + "\n";
            crate::helper::net::allow_list(&text)?;
            let f = dir.join(NET_ALLOW);
            fs::write(&f, text).map_err(|e| format!("{NET_ALLOW}: {e}"))?;
            Some(f)
        };
        let parser: Parser =
            serde_json::from_value(serde_json::Value::String(if req.parser.is_empty() {
                "exit".into()
            } else {
                req.parser.to_string()
            }))
            .map_err(|_| format!("no row parser {:?}", req.parser))?;
        slices::ensure_tree(SLICE_ROOT, self.profile)?;
        let slice = slices::job_slice(SLICE_ROOT, id)?;
        let ra = RunnerArgs::runner(&self.prefix, &self.hub_id, &slice);
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
            image: "job".into(),
            argv: meta.spec.command.clone(),
            worktree: req.src.to_path_buf(),
            subdir: if meta.spec.cwd == Path::new(".") {
                PathBuf::new()
            } else {
                meta.spec.cwd.clone()
            },
            job: id.clone(),
            net: hub_allow.is_some(),
            runner: Some(RunnerMounts {
                writes_tree: meta.spec.writes_tree,
                target: dir.join("target"),
                caches: vec![],
                keys,
            }),
        };
        let container = podman::name_of(&ra.name_prefix, id).map_err(|r| r.message)?;
        let mut argv = vec!["podman".to_string()];
        for a in podman::argv(&creq, &caps, &ra).map_err(|r| r.message)? {
            argv.push(
                a.into_string()
                    .map_err(|_| "a podman argument is not UTF-8")?,
            );
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
            // every runner job has its helper: the disk watch, and its keys and proxy when it has them
            helper: Some(HelperSpec {
                root: self.root.clone(),
                keys: meta.spec.keys.clone(),
                hub_allow,
                net: relay.as_ref().map(|r| r.0.clone()),
                sidecar_argv: relay.map(|r| r.1).unwrap_or_default(),
                container: Some(container),
            }),
        }
        .write(dir)
        .map_err(|e| format!("job.json: {e}"))?;
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

    fn kill(&self, id: &str) -> Result<(), String> {
        let name = self.container(id);
        run::limited(
            Path::new("podman"),
            &["kill", &name],
            &[],
            run::SYSTEMCTL_LIMIT,
        )
        .map(|_| ())
        .map_err(|e| format!("podman kill {name}: {e}"))
    }

    fn pause(&self, id: &str) -> Result<(), String> {
        resize::pause(&self.container(id))
    }

    fn unpause(&self, id: &str) -> Result<(), String> {
        resize::unpause(&self.container(id))
    }

    /// The slice's `memory.current` (its container and job-exec) sorts out the jobs well under the cap; the
    /// container's own reading is what a grow judges.
    fn grow_candidate(&self, id: &str, cap_mib: u64, max_mib: u64) -> Option<Sized> {
        let near = slices::job_slice(SLICE_ROOT, id)
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

    fn resize(&self, r: &Resize) -> Result<(), String> {
        resize::apply(r)
    }

    fn weight_unit(&self, id: &str) -> Option<String> {
        slices::job_slice(SLICE_ROOT, id).ok()
    }

    fn set_weight(&self, unit: &str, w: u32) -> Result<(), String> {
        resize::set_weight(unit, w)
    }

    fn hand_key(&self, dir: &Path, name: &str, value: &[u8]) -> io::Result<()> {
        crate::helper::keys::hand(&dir.join(HELPER_SOCK), name, value)
    }

    fn cleanup(&self, root: &Path, owner: &cleanup::Owner) {
        let seen = cleanup::Seen {
            containers: cleanup::containers(&self.prefix, &self.hub_id),
            units: cleanup::units(&self.prefix),
            folders: attempts::scan(root, &unit::active),
            bundles: cleanup::bundles(root),
        };
        cleanup::apply(root, &cleanup::plan(owner, &seen));
    }
}

/// A networked job's relay as its `job.json` names it: the sidecar ([`podman::JobNet`]) and the sidecar's `podman`
/// arguments for the helper, for job ID under RA from the relay image IMAGE.
pub(in crate::serve) fn net_helper(
    ra: &RunnerArgs,
    id: &str,
    image: &str,
    keyed: bool,
) -> Result<(podman::JobNet, Vec<String>), String> {
    let names = podman::net_names(ra, id).map_err(|r| r.message)?;
    let argv = podman::sidecar_argv(&names, ra, image, keyed)
        .map_err(|r| r.message)?
        .into_iter()
        .map(|a| {
            a.into_string()
                .map_err(|_| "a sidecar argument is not UTF-8".to_string())
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
