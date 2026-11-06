//! The `runners/*` methods: the handlers over the hub's [`Registry`] (docs/develop/hub.md, "Runners: the registry"),
//! and the job keys' handover and audit (`runners/keys`, `runners/keys-held`, `runners/audit`; "Runners: keys").
//! All are the user's alone (the method registry's classes). A change sends `runners-changed` with the whole list and
//! tells the machine registry which runners there are.

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Empty;
use runstav::methods::runners::{
    AddParams, Audit, AuditParams, ByName, KeyNames, KeysParams, ProbeParams, Probed, RemoveParams,
    Removed, Runner, Runners, SetParams,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::json;

fn error(code: ErrorCode, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
        path: None,
    }
}

#[cfg(all(unix, not(target_os = "android")))]
mod on {
    use super::*;
    use crate::runners::registry::{Cfg, RegError, Registry, UrdrStore};
    use crate::runners::transport::OpensshTransport;
    use std::path::PathBuf;
    use std::sync::{Arc, OnceLock};

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
            let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .ok_or_else(|| error(ErrorCode::Internal, "runners: XDG_RUNTIME_DIR is not set"))?;
            let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            let settings = f.settings.clone();
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
            };
            Ok(self
                .reg
                .get_or_init(|| Arc::new(Registry::new(cfg)))
                .clone())
        }
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
            let Ok(reg) = f.core.runners.get(&f) else {
                return;
            };
            reg.connect_all().await;
            super::changed(&f).await;
        });
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

/// The runners now, sent as `runners-changed` and given to the machine registry.
#[cfg(all(unix, not(target_os = "android")))]
async fn changed(f: &Front) {
    if let Ok(reg) = f.core.runners.get(f)
        && let Ok(list) = reg.list().await
    {
        crate::work::machines::set_runners(f, list.iter().map(|r| r.name.clone()).collect());
        f.broadcast("runners-changed", json!(Runners { runners: list }));
    }
}

#[cfg(not(all(unix, not(target_os = "android"))))]
async fn changed(_: &Front) {}

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
pub async fn remove(f: &Front, _: &Caller, p: RemoveParams) -> Result<Removed, Error> {
    reg!(f).remove(p.name.as_str()).await.map_err(on::map)?;
    changed(f).await;
    Ok(Removed {
        name: p.name.as_str().to_string(),
    })
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
    pub async fn remove(f: &Front, _: &Caller, _: RemoveParams) -> Result<Removed, Error> {
        Err(no(f))
    }
}

#[cfg(not(all(unix, not(target_os = "android"))))]
pub use off::*;
