//! The `runners/*` methods: the handlers over the hub's [`Registry`] (docs/develop/hub.md, "Runners: the registry"),
//! and the job keys' handover and audit (`runners/keys`, `runners/keys-held`, `runners/audit`; "Runners: keys").
//! All are the user's alone (the method registry's classes) but `runners/disk`, which an agent may read; the disk's
//! (`runners/disk`, `runners/reclaim`, `runners/pin`) go to the queue's disk register ("Runners: the disk"). A change
//! sends `runners-changed` with the whole list and tells the machine registry which runners there are.

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Empty;
use runstav::methods::jobs_q::{Project, ProjectAddParams, ProjectRemoveParams, Projects};
use runstav::methods::runners::{
    AddParams, Audit, AuditParams, ByName, DiskClass, DiskEntry, DiskParams, Disks, FeatureParams,
    KeyNames, KeysParams, MachineDisk, PinParams, ProbeParams, Probed, ReclaimParams, Reclaimed,
    RemoveParams, Removed, Runner, Runners, SetParams, TelemetryHistory, TelemetryRange,
    TelemetrySubscribe, TelemetryWatching,
};
use runstav::wire::{Error, ErrorCode};
#[cfg(all(unix, not(target_os = "android")))]
use serde_json::json;

fn error(code: ErrorCode, message: impl ToString) -> Error {
    Error {
        code,
        message: message.to_string(),
        path: None,
    }
}

/// The wire's view of a registered project.
fn project_view(p: crate::runners::projects::Project) -> Project {
    Project {
        id: p.id.0,
        name: p.name,
        origin: p.origin,
        roots: p.roots,
    }
}

/// `jobs/project-add`: the repository at the path registered (the user's alone; refusals are `invalid-params` at
/// `path` with the reason and its fix).
pub async fn project_add(f: &Front, _: &Caller, p: ProjectAddParams) -> Result<Project, Error> {
    let projects = crate::exec::projects(f).await?;
    let name = p.name.map(|n| n.into_inner());
    let r = saman::lock(projects).add(std::path::Path::new(p.path.as_str()), name.as_deref());
    r.map(project_view).map_err(|e| invalid_at(e, "path"))
}

/// A refused input as the wire says it: `invalid-params` at PATH, with the reason and its fix.
fn invalid_at(e: villa::Error, path: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: e.message().to_string(),
        path: Some(path.into()),
    }
}

/// `jobs/project-list`: every registered project.
pub async fn project_list(f: &Front, _: &Caller, _: Empty) -> Result<Projects, Error> {
    let projects = crate::exec::projects(f).await?;
    let list = saman::lock(projects).list();
    Ok(Projects {
        projects: list.into_iter().map(project_view).collect(),
    })
}

/// `jobs/project-remove`: a project and its clones' mappings removed.
pub async fn project_remove(f: &Front, _: &Caller, p: ProjectRemoveParams) -> Result<bool, Error> {
    let projects = crate::exec::projects(f).await?;
    let id = forseti::ProjectId(p.id.into_inner());
    let r = saman::lock(projects).remove(&id);
    r.map(|()| true).map_err(|e| invalid_at(e, "id"))
}

#[cfg(all(unix, not(target_os = "android")))]
mod on {
    use super::*;
    use crate::runners::registry::{Cfg, RegError, Registry, UrdrStore};
    use crate::runners::transport::OpensshTransport;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, OnceLock};

    /// This machine's boot id, as a runner's `serve` reports its own: `runner add` of the hub's machine is refused.
    /// Linux's `/proc/sys/kernel/random/boot_id`; a Mac's `kern.bootsessionuuid`. Empty when unreadable (no refusal).
    pub(crate) fn hub_boot_id() -> String {
        #[cfg(target_os = "macos")]
        {
            let mut buf = [0u8; 64];
            let mut len = buf.len();
            // SAFETY: a NUL-terminated name, a buffer of LEN bytes and its length; no new value
            let rc = unsafe {
                libc::sysctlbyname(
                    c"kern.bootsessionuuid".as_ptr(),
                    buf.as_mut_ptr().cast(),
                    &mut len,
                    std::ptr::null_mut(),
                    0,
                )
            };
            if rc != 0 {
                return String::new();
            }
            String::from_utf8_lossy(&buf[..len])
                .trim_end_matches('\0')
                .trim()
                .to_string()
        }
        #[cfg(not(target_os = "macos"))]
        {
            crate::fsio::read_to_string("/proc/sys/kernel/random/boot_id")
                .map(|s| s.trim().to_string())
                .unwrap_or_default()
        }
    }

    #[cfg(test)]
    #[test]
    fn the_hub_boot_id_is_read() {
        let id = hub_boot_id();
        assert!(id.len() >= 32 && id.contains('-'), "{id:?}");
    }

    /// The hub's registry, made on first use.
    #[derive(Default)]
    pub struct Hub {
        reg: OnceLock<Arc<Registry>>,
    }

    impl Hub {
        pub(super) fn get(&self, f: &Front) -> Result<Arc<Registry>, Error> {
            if let Some(r) = self.reg.get() {
                return Ok(r.clone());
            }
            let queue = crate::exec::queue(f)?;
            let runtime_dir =
                link_dir(std::env::var_os(stig::SYSTEM_RUNTIME_VAR).map(PathBuf::from))?;
            let boot_id = hub_boot_id();
            let settings = f.settings.clone();
            let pins = f.settings.clone();
            let cfg = Cfg {
                transport: Arc::new(OpensshTransport::new(runtime_dir.clone())),
                store: Arc::new(UrdrStore(f.writer.db.clone())),
                queue,
                hub_id: "hub".into(),
                hub_boot_id: boot_id,
                runtime_dir,
                bundles: bundles(),
                images: Arc::new(move || {
                    settings
                        .effective("drgnx-runners-image", None)
                        .and_then(|(v, _)| v.as_str().map(String::from))
                        .filter(|s| !s.is_empty())
                        .into_iter()
                        .collect()
                }),
                toolchains: Arc::new(move || {
                    let mut all: Vec<String> = pins
                        .values_everywhere("drgnx-runners-mac-toolchains")
                        .into_iter()
                        .filter_map(|v| serde_json::from_value::<Vec<String>>(v).ok())
                        .flatten()
                        .collect();
                    all.sort();
                    all.dedup();
                    all
                }),
            };
            Ok(self
                .reg
                .get_or_init(|| Arc::new(Registry::new(cfg)))
                .clone())
        }
    }

    /// Where the runners' ssh masters keep their sockets: under the runtime folder, whose paths must stay inside a Unix
    /// socket's 108 bytes with the runner's name and ssh's own suffix (~65 bytes) after them. A longer one (or none)
    /// gives a private folder under the temporary one, as the hub's own socket does; under `/tmp` when the temporary
    /// one is long too (macOS's `/var/folders/…/T/`).
    pub(super) fn link_dir(run: Option<PathBuf>) -> Result<PathBuf, Error> {
        link_dir_in(run, &std::env::temp_dir())
    }

    /// [`link_dir`] with TMP as the temporary folder.
    pub(super) fn link_dir_in(run: Option<PathBuf>, tmp: &Path) -> Result<PathBuf, Error> {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        if let Some(r) = run.filter(|r| r.as_os_str().len() <= 24) {
            return Ok(r);
        }
        let name = format!("drgnx-hub-{}", rustix::process::getuid().as_raw());
        let dir = Some(tmp.join(&name))
            .filter(|d| d.as_os_str().len() <= 24)
            .unwrap_or_else(|| Path::new("/tmp").join(&name));
        let fail = |e: std::io::Error| {
            error(
                ErrorCode::Internal,
                format!("runners: {}: {e}", dir.display()),
            )
        };
        std::fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&dir)
            .map_err(fail)?;
        let m = std::fs::symlink_metadata(&dir).map_err(fail)?;
        if !m.is_dir() || m.uid() != rustix::process::getuid().as_raw() || m.mode() & 0o077 != 0 {
            return Err(error(
                ErrorCode::Internal,
                format!("runners: {} is not a private folder of ours", dir.display()),
            ));
        }
        Ok(dir)
    }

    /// Where the built bundles are: `DRGNX_RUNNER_BUNDLES`, else `bundle/` beside the hub's own build folder
    /// (`runtime/target/bundle`, where `drgnx build runner-bundle` puts them).
    fn bundles() -> PathBuf {
        if let Some(p) = std::env::var_os("DRGNX_RUNNER_BUNDLES") {
            return p.into();
        }
        std::env::current_exe()
            .ok()
            .and_then(|e| e.parent()?.parent().map(|d| d.join("bundle")))
            .unwrap_or_else(|| PathBuf::from("bundle"))
    }

    pub(super) fn map(e: RegError) -> Error {
        match e {
            RegError::Refused(m) => error(ErrorCode::InvalidParams, m),
            RegError::Failed(m) => error(ErrorCode::Internal, m),
        }
    }

    /// The runners linked at the hub's start, in the background: a slow or unreachable runner never delays serving.
    pub fn start(f: &Arc<Front>) {
        let f = f.clone();
        crate::clock::spawn("runners:connect", async move {
            // the registry's first making reads the disk (the link folder made and checked, the boot id, the
            // executable's path): off the hub's workers, before any method asks for it
            let g = f.clone();
            let Ok(Ok(reg)) = crate::clock::blocking(move || g.core.runners.get(&g)).await else {
                return;
            };
            reg.connect_all().await;
            super::changed(&f).await;
            reg.redial_lost().await;
        });
    }
}

#[cfg(all(test, unix, not(target_os = "android")))]
mod link_dir_tests {
    use super::on::{link_dir, link_dir_in};
    use std::path::PathBuf;

    // [D] pure
    #[test]
    fn a_long_runtime_folder_gets_a_short_private_one_and_a_short_one_stays() {
        assert_eq!(
            link_dir(Some("/run/user/1000".into())).unwrap(),
            PathBuf::from("/run/user/1000")
        );
        let long = PathBuf::from("/tmp/a-runtime-folder-far-too-long-for-ssh-sockets");
        let d = link_dir(Some(long.clone())).unwrap();
        assert_ne!(d, long);
        assert!(d.as_os_str().len() <= 24, "{d:?}");
    }

    // [D] pure: a long temporary folder (macOS's /var/folders/…/T/) is passed over for /tmp
    #[test]
    fn a_long_temporary_folder_gives_one_under_tmp() {
        let long = std::path::Path::new("/var/folders/5n/5t77mfb93jd7q8v9s6f0dn0m0000gn/T");
        let d = link_dir_in(None, long).unwrap();
        assert!(d.starts_with("/tmp") && d.as_os_str().len() <= 24, "{d:?}");
    }
}

#[cfg(not(all(unix, not(target_os = "android"))))]
mod on {
    use super::*;
    use std::sync::Arc;

    #[derive(Default)]
    pub struct Hub;

    pub(super) struct Registry;

    impl Hub {
        pub(super) fn get(&self, _: &Front) -> Result<Arc<Registry>, Error> {
            Err(error(
                ErrorCode::Internal,
                "runners are reached over OpenSSH, which this platform doesn't have",
            ))
        }
    }

    pub fn start(_: &Arc<Front>) {}
}

pub use on::{Hub, start};

/// What the Work map shows of runner R: its icon (a cloud machine, a dedicated host, a machine somebody sits at), its
/// state as the list says it and its jobs.
fn map_fact(r: &runstav::methods::runners::Runner) -> vegvisir::RunnerFact {
    use runstav::methods::runners::{Profile, Trust};
    let (trust, icon) = match (r.trust, r.profile) {
        (Trust::MyCloud, _) => ("my-cloud", "cloud"),
        (Trust::Mine, Profile::Workstation) => ("mine", "monitor"),
        (Trust::Shared, Profile::Workstation) => ("shared", "monitor"),
        (Trust::Mine, Profile::Dedicated) => ("mine", "server"),
        (Trust::Shared, Profile::Dedicated) => ("shared", "server"),
    };
    vegvisir::RunnerFact {
        trust: trust.into(),
        state: r.state.clone(),
        jobs: r.jobs,
        icon: icon.into(),
        cost: None,
        mac: r.os.starts_with("macos"),
    }
}

/// The runners now, sent as `runners-changed` and given to the machine registry.
#[cfg(all(unix, not(target_os = "android")))]
async fn changed(f: &Front) {
    if let Ok(reg) = f.core.runners.get(f)
        && let Ok(list) = reg.list().await
    {
        crate::work::machines::set_runners(
            f,
            list.iter()
                .map(|r| (r.name.clone(), map_fact(r), r.cores))
                .collect(),
        );
        f.broadcast("runners-changed", json!(Runners { runners: list }));
    }
}

#[cfg(all(unix, not(target_os = "android")))]
macro_rules! reg {
    ($f:expr) => {
        $f.core.runners.get($f)?
    };
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn list(f: &Front, _: &Caller, _: Empty) -> Result<Runners, Error> {
    let runners = reg!(f).list().await.map_err(on::map)?;
    Ok(Runners { runners })
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn probe_host(f: &Front, _: &Caller, p: ProbeParams) -> Result<Probed, Error> {
    reg!(f).probe_host(p.host.as_str()).await.map_err(on::map)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn add(f: &Front, _: &Caller, p: AddParams) -> Result<Runner, Error> {
    let r = reg!(f).add(p).await.map_err(on::map)?;
    changed(f).await;
    Ok(r)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn check(f: &Front, _: &Caller, p: ByName) -> Result<Runner, Error> {
    let r = reg!(f).check(p.name.as_str()).await.map_err(on::map)?;
    changed(f).await;
    Ok(r)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn bench(f: &Front, _: &Caller, p: ByName) -> Result<Runner, Error> {
    let r = reg!(f).bench(p.name.as_str()).await.map_err(on::map)?;
    changed(f).await;
    Ok(r)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn set(f: &Front, _: &Caller, p: SetParams) -> Result<Runner, Error> {
    let r = reg!(f).set(p).await.map_err(on::map)?;
    changed(f).await;
    Ok(r)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn unbench(f: &Front, _: &Caller, p: ByName) -> Result<Runner, Error> {
    let r = reg!(f).unbench(p.name.as_str()).await.map_err(on::map)?;
    changed(f).await;
    Ok(r)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn feature(f: &Front, _: &Caller, p: FeatureParams) -> Result<Runner, Error> {
    let r = reg!(f).feature(p).await.map_err(on::map)?;
    changed(f).await;
    Ok(r)
}

#[cfg(all(unix, not(target_os = "android")))]
pub async fn remove(f: &Front, _: &Caller, p: RemoveParams) -> Result<Removed, Error> {
    reg!(f).remove(p.name.as_str()).await.map_err(on::map)?;
    changed(f).await;
    Ok(Removed {
        name: p.name.as_str().to_string(),
    })
}

/// A disk error as the wire says it.
fn disk_error(e: villa::Error) -> Error {
    let code = match e.kind() {
        villa::Kind::NotFound | villa::Kind::Refused | villa::Kind::Invalid => {
            ErrorCode::InvalidParams
        }
        _ => ErrorCode::Internal,
    };
    error(code, e.message())
}

/// `runners/disk`: each runner's disk as it last reported it (the disk register, editing-model design §4.8).
pub async fn disk(f: &Front, _: &Caller, p: DiskParams) -> Result<Disks, Error> {
    let q = crate::exec::queue(f)?;
    let now = crate::clock::wall_secs() as u64;
    let machines = q
        .disk_view(p.name.as_ref().map(|n| n.as_str()), now)
        .into_iter()
        .map(|v| MachineDisk {
            name: v.machine,
            free: v.free,
            total: v.total,
            ours: v.ours,
            quota: v.quota,
            btrfs_unallocated: v.btrfs_unallocated,
            classes: v
                .classes
                .iter()
                .map(|c| DiskClass {
                    kind: c.kind.name().into(),
                    items: c.items,
                    bytes: c.bytes,
                    evictable_bytes: c.evictable_bytes,
                })
                .collect(),
            items: v
                .items
                .iter()
                .map(|(i, s)| DiskEntry {
                    id: i.id.clone(),
                    kind: i.kind.name().into(),
                    owner: i.owner.clone(),
                    bytes: i.bytes,
                    last_used: i.last_used,
                    state: crate::runners::disk::state_word(*s).into(),
                })
                .collect(),
        })
        .collect();
    Ok(Disks { machines })
}

/// `runners/reclaim`: a runner's items past their age, not pinned or in use, ordered removed (or listed, dry).
pub async fn reclaim(f: &Front, _: &Caller, p: ReclaimParams) -> Result<Reclaimed, Error> {
    let q = crate::exec::queue(f)?;
    let now = crate::clock::wall_secs() as u64;
    let plan = q
        .disk_reclaim(p.name.as_str(), p.dry_run, now)
        .map_err(disk_error)?;
    Ok(Reclaimed {
        ids: plan.into_iter().map(|e| e.id).collect(),
        dry_run: p.dry_run,
    })
}

/// `runners/pin`: an item on a runner's disk kept or let go; the runner hears its pins again.
pub async fn pin(f: &Front, _: &Caller, p: PinParams) -> Result<bool, Error> {
    let q = crate::exec::queue(f)?;
    q.disk_pin(p.name.as_str(), p.id.as_str(), p.on)
        .map_err(disk_error)?;
    Ok(true)
}

/// The level a wire word names (the registry's check has refused any other).
fn telemetry_level(word: &str) -> Result<sleipnir::proto::telemetry::Level, Error> {
    sleipnir::proto::telemetry::Level::parse(word)
        .ok_or_else(|| error(ErrorCode::InvalidParams, format!("no level {word}")))
}

/// `runners/telemetry/subscribe`: the caller's connection hears RUNNER's LEVEL samples as `runners-telemetry` events
/// until it goes; the runner keeps one sampler for all its viewers, at the fastest rate any of them asked.
pub async fn telemetry_subscribe(
    f: &Front,
    c: &Caller,
    p: TelemetrySubscribe,
) -> Result<TelemetryWatching, Error> {
    let q = crate::exec::queue(f)?;
    let level = telemetry_level(&p.level)?;
    let editors = f.editors.clone();
    let conn = c.conn_id;
    let sink: crate::runners::telemetry::Sink =
        Box::new(move |data| editors.send_to(conn, "runners-telemetry", data));
    let watch = q
        .telemetry_watch(p.runner.as_str(), level, p.ids.clone(), p.every_ms, sink)
        .map_err(disk_error)?;
    Ok(TelemetryWatching {
        watch,
        runner: p.runner,
        level: p.level,
        every_ms: p.every_ms,
    })
}

/// How long a runner has to answer a range.
const RANGE_WITHIN: std::time::Duration = std::time::Duration::from_secs(30);

/// `runners/telemetry/range`: RUNNER's stored history, asked of the runner (it keeps it).
pub async fn telemetry_range(
    f: &Front,
    _: &Caller,
    p: TelemetryRange,
) -> Result<TelemetryHistory, Error> {
    let q = crate::exec::queue(f)?;
    let level = telemetry_level(&p.level)?;
    let rx = q
        .telemetry_range(
            p.runner.as_str(),
            sleipnir::proto::telemetry::Range {
                level,
                ids: p.ids,
                from: p.from,
                to: p.to,
                step_ms: p.step_ms,
            },
        )
        .map_err(disk_error)?;
    match stund::timeout(RANGE_WITHIN, rx).await {
        Ok(Ok(h)) => Ok(h),
        Ok(Err(_)) => Err(error(
            ErrorCode::Internal,
            format!("the link to {} ended before it answered", p.runner.as_str()),
        )),
        Err(_) => Err(error(
            ErrorCode::Internal,
            format!("{} did not answer within 30 s", p.runner.as_str()),
        )),
    }
}

/// `runners/keys`: job keys to the hub's memory, nowhere else (refused, taking nothing, while the hub can't keep other
/// processes out of its memory); the started attempts waiting for one get it now.
pub async fn keys(f: &Front, _: &Caller, p: KeysParams) -> Result<bool, Error> {
    f.gate.protects_keys()?;
    let q = crate::exec::queue(f)?;
    q.take_keys(p.keys.into_pairs(), crate::clock::wall_secs() as u64);
    Ok(true)
}

/// `runners/keys-held`: the names of the job keys the hub holds, never a value.
pub async fn keys_held(f: &Front, _: &Caller, _: Empty) -> Result<KeyNames, Error> {
    Ok(crate::exec::queue(f)?.keys().held())
}

/// `runners/audit`: the graph's `key_sent` and `key_use` rows (the hub's memory of them when the graph can't be read),
/// of one job or one key when asked.
pub async fn audit(f: &Front, _: &Caller, p: AuditParams) -> Result<Audit, Error> {
    let job = p.job.as_ref().map(|j| j.as_str());
    let key = p.key.as_ref().map(|k| k.as_str());
    let rows = match crate::runners::keys::graph_audit(&f.writer.db).await {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!("runners: the key audit in the graph: {e}");
            crate::exec::queue(f)?.keys().audit(None, None)
        }
    };
    Ok(Audit {
        rows: rows
            .into_iter()
            .filter(|r| job.is_none_or(|j| r.job == j) && key.is_none_or(|k| r.key.as_str() == k))
            .collect(),
    })
}

#[cfg(not(all(unix, not(target_os = "android"))))]
mod off {
    use super::*;

    fn no(f: &Front) -> Error {
        f.core.runners.get(f).err().unwrap_or_else(|| {
            error(
                ErrorCode::Internal,
                "runners are not available on this platform",
            )
        })
    }

    pub async fn list(f: &Front, _: &Caller, _: Empty) -> Result<Runners, Error> {
        Err(no(f))
    }
    pub async fn probe_host(f: &Front, _: &Caller, _: ProbeParams) -> Result<Probed, Error> {
        Err(no(f))
    }
    pub async fn add(f: &Front, _: &Caller, _: AddParams) -> Result<Runner, Error> {
        Err(no(f))
    }
    pub async fn check(f: &Front, _: &Caller, _: ByName) -> Result<Runner, Error> {
        Err(no(f))
    }
    pub async fn bench(f: &Front, _: &Caller, _: ByName) -> Result<Runner, Error> {
        Err(no(f))
    }
    pub async fn set(f: &Front, _: &Caller, _: SetParams) -> Result<Runner, Error> {
        Err(no(f))
    }
    pub async fn unbench(f: &Front, _: &Caller, _: ByName) -> Result<Runner, Error> {
        Err(no(f))
    }
    pub async fn feature(f: &Front, _: &Caller, _: FeatureParams) -> Result<Runner, Error> {
        Err(no(f))
    }
    pub async fn remove(f: &Front, _: &Caller, _: RemoveParams) -> Result<Removed, Error> {
        Err(no(f))
    }
}

#[cfg(not(all(unix, not(target_os = "android"))))]
pub use off::*;
