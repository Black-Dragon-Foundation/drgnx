//! The cleanup `serve` runs when it starts and at every job end. It removes only what is this hub's: containers with
//! both its prefix and its `drgnx.runner=<hub id>` label whose attempt has ended, its job folders that are collected
//! or older than 24 h, its own units that no longer run; and bundle versions nothing runs from. Anything of another
//! hub, another prefix or another scheduler stays, whatever it looks like.

use super::attempts::Found;
use crate::linux::run;
use crate::proto::AttemptState;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// A job folder older than this goes even if its result was never collected.
pub const FOLDER_MAX_AGE_S: u64 = 24 * 3600;

/// A unit as `systemctl --user list-units` shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unit {
    pub name: String,
    pub active: bool,
}

/// What the cleanup reads.
#[derive(Clone, Debug, Default)]
pub struct Seen {
    /// `podman ps -a --format json` of the containers labelled with this hub (`linux::podman::leftovers` reads it).
    pub containers: serde_json::Value,
    pub units: Vec<Unit>,
    /// Every attempt folder under the root, of any hub.
    pub folders: Vec<Found>,
    pub bundles: Vec<Bundle>,
}

/// A `bin/<name>` folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bundle {
    pub name: String,
    /// A running process's executable is in it.
    pub in_use: bool,
    /// When it was put there.
    pub mtime: SystemTime,
}

/// What the cleanup removes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Remove {
    Container(String),
    Folder(PathBuf),
    /// A unit that ended but is still loaded (failed): reset so it unloads.
    Unit(String),
    Bundle(String),
}

/// Who is cleaning: the hub, its container prefix, the bundle this `serve` runs from.
pub struct Owner<'a> {
    pub hub_id: &'a str,
    pub prefix: &'a str,
    pub own_bundle: &'a str,
}

/// The removals for OWNER over SEEN, in a fixed order: containers, units, folders, bundles.
pub fn plan(owner: &Owner, seen: &Seen) -> Vec<Remove> {
    let ours = |f: &&Found| f.meta.hub_id == owner.hub_id;
    let running = |f: &&Found| f.state == AttemptState::Running;
    let pfx = format!("{}-", owner.prefix);
    let mut out = vec![];
    // a container (the job's, or its sidecar) is the attempt's while its unit runs: the shared sweep picks those of our
    // label whose job isn't running, the job's containers before the sidecars (S11), and only names of our prefix go
    let live: std::collections::HashSet<String> = seen
        .folders
        .iter()
        .filter(ours)
        .filter(running)
        .map(|f| f.meta.r.job.clone())
        .collect();
    let left = crate::linux::podman::leftovers(
        &seen.containers,
        None,
        ("drgnx.runner", owner.hub_id),
        &live,
    );
    for name in left.jobs.into_iter().chain(left.sidecars) {
        if name.starts_with(&pfx) {
            out.push(Remove::Container(name));
        }
    }
    // a unit is ours only when one of our folders names it
    for u in &seen.units {
        let named = seen
            .folders
            .iter()
            .filter(ours)
            .any(|f| f.meta.unit.as_deref() == Some(u.name.as_str()));
        if named && !u.active && u.name.starts_with(&pfx) {
            out.push(Remove::Unit(u.name.clone()));
        }
    }
    for f in seen.folders.iter().filter(ours) {
        if f.state != AttemptState::Running && (f.collected || f.age_s >= FOLDER_MAX_AGE_S) {
            out.push(Remove::Folder(f.dir.clone()));
        }
    }
    // only bundles put there before our own go (a newer one is a hub's update, about to serve), and only while
    // nothing runs from them and no running attempt (any hub's) started from them
    let own = seen.bundles.iter().find(|b| b.name == owner.own_bundle);
    for b in &seen.bundles {
        let held = b.in_use
            || seen
                .folders
                .iter()
                .any(|f| f.meta.bundle == b.name && f.state == AttemptState::Running);
        let older = own.is_some_and(|o| b.mtime < o.mtime);
        if b.name != owner.own_bundle && older && !held {
            out.push(Remove::Bundle(b.name.clone()));
        }
    }
    out
}

/// The containers podman lists with our prefix and HUB's label, whatever their state, as `podman ps -a --format json`.
pub fn containers(prefix: &str, hub: &str) -> serde_json::Value {
    let out = run::limited(
        Path::new("podman"),
        &[
            "ps",
            "-a",
            "--filter",
            &format!("name=^{prefix}-"),
            "--filter",
            &format!("label=drgnx.runner={hub}"),
            "--format",
            "json",
        ],
        &[],
        run::SYSTEMCTL_LIMIT,
    );
    let out = match out {
        Ok(o) if o.status.success() => o,
        Ok(o) => {
            eprintln!(
                "sleipnir serve: podman ps: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            return serde_json::Value::Null;
        }
        Err(e) => {
            eprintln!("sleipnir serve: podman ps: {e}");
            return serde_json::Value::Null;
        }
    };
    serde_json::from_slice(&out.stdout).unwrap_or(serde_json::Value::Null)
}

/// Our prefix's units, loaded or not.
pub fn units(prefix: &str) -> Vec<Unit> {
    crate::linux::unit::list(&format!("{prefix}-"))
        .into_iter()
        .map(|u| Unit {
            active: matches!(u.active.as_str(), "active" | "activating" | "reloading"),
            name: u.unit,
        })
        .collect()
}

/// The folders under `<root>/bin`, each with whether a running process's executable is in it.
pub fn bundles(root: &Path) -> Vec<Bundle> {
    let bin = root.join("bin");
    let Ok(rd) = fs::read_dir(&bin) else {
        return vec![];
    };
    let exes: Vec<PathBuf> = fs::read_dir("/proc")
        .map(|d| {
            d.flatten()
                .filter_map(|e| fs::read_link(e.path().join("exe")).ok())
                .collect()
        })
        .unwrap_or_default();
    let mut out: Vec<Bundle> = rd
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let dir = bin.join(&name);
            Bundle {
                in_use: exes.iter().any(|x| x.starts_with(&dir)),
                mtime: e
                    .metadata()
                    .and_then(|m| m.modified())
                    .unwrap_or(SystemTime::UNIX_EPOCH),
                name,
            }
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Carries out PLAN; what can't be removed is reported on stderr and left.
pub fn apply(root: &Path, plan: &[Remove]) {
    for r in plan {
        let done = match r {
            Remove::Container(name) => run::limited(
                Path::new("podman"),
                &["rm", "-f", "-t", "0", name],
                &[],
                run::SYSTEMCTL_LIMIT,
            )
            .map(|_| ()),
            Remove::Unit(name) => run::systemctl_ok(&["reset-failed", name]).map(|_| ()),
            Remove::Folder(dir) => fs::remove_dir_all(dir).map_err(|e| e.to_string()),
            Remove::Bundle(name) => {
                fs::remove_dir_all(root.join("bin").join(name)).map_err(|e| e.to_string())
            }
        };
        if let Err(e) = done {
            eprintln!("sleipnir serve: cleanup {r:?}: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{JobRef, Nonce};
    use crate::serve::attempts::Meta;
    use forseti::{Grant, Priority};

    fn folder(hub: &str, job: &str, state: AttemptState, collected: bool, age_s: u64) -> Found {
        Found {
            dir: PathBuf::from(format!("/r/jobs/{hub}-{job}.1")),
            meta: Meta {
                hub_id: hub.into(),
                r: JobRef {
                    job: job.into(),
                    attempt: 1,
                    nonce: Nonce([1; 16]),
                },
                spec: crate::serve::tests_spec(),
                priority: Priority::P3,
                grant: Grant {
                    cores: 1,
                    mem_cap_mib: 256,
                    reserve_mib: 128,
                },
                expected: None,
                bundle: "v1".into(),
                unit: Some(format!("run-{job}-1")),
                admitted: 0,
                started: Some(0),
                input_key: String::new(),
                slot: None,
            },
            state,
            log_len: 0,
            age_s,
            collected,
        }
    }

    fn bundle(name: &str, in_use: bool, at_s: u64) -> Bundle {
        Bundle {
            name: name.into(),
            in_use,
            mtime: SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(at_s),
        }
    }

    /// A container as `podman ps --format json` lists it: HUB's `drgnx.runner` label and the job id its name ends
    /// with as `drgnx.job`.
    fn ctr(name: &str, hub: Option<&str>) -> serde_json::Value {
        let job = name.rsplit('-').next().unwrap_or("");
        match hub {
            Some(h) => {
                serde_json::json!({"Names": [name], "Labels": {"drgnx.runner": h, "drgnx.job": job}})
            }
            None => serde_json::json!({"Names": [name], "Labels": {}}),
        }
    }

    /// [D] Only what carries this hub's id and prefix goes: another hub's ended container, its collected and old
    /// folders, its failed unit, a container of ours with another label or none, and one of another prefix all
    /// stay; a running attempt keeps its container, folder and bundle.
    #[test]
    fn cleanup_matches_prefix_and_label_only() {
        let seen = Seen {
            containers: serde_json::json!([
                ctr("run-a1", Some("hubA")),    // A's, running
                ctr("run-a2", Some("hubA")),    // A's, ended
                ctr("run-b1", Some("hubB")),    // B's, ended
                ctr("run-x9", None),            // our prefix, no label
                ctr("run-a3", Some("hubB")),    // our prefix and an A job's name, B's label
                ctr("other-a2", Some("hubA")),  // another prefix
                ctr("run-px-a2", Some("hubA")), // A's ended job's sidecar
                ctr("run-px-a1", Some("hubA")), // A's running job's sidecar
            ]),
            units: vec![
                Unit {
                    name: "run-a2-1".into(),
                    active: false,
                },
                Unit {
                    name: "run-b1-1".into(),
                    active: false,
                },
                Unit {
                    name: "run-a1-1".into(),
                    active: true,
                },
                Unit {
                    name: "run-zz-1".into(),
                    active: false,
                },
            ],
            folders: vec![
                folder("hubA", "a1", AttemptState::Running, false, 90_000),
                folder("hubA", "a2", AttemptState::Finished, true, 10),
                folder("hubA", "a4", AttemptState::Finished, false, 90_000),
                folder("hubA", "a5", AttemptState::Lost, false, 10),
                folder("hubB", "b1", AttemptState::Finished, true, 90_000),
                folder("hubB", "b2", AttemptState::Lost, false, 90_000),
            ],
            bundles: vec![
                bundle("v0", true, 0),
                bundle("v1", false, 1),
                bundle("v2", false, 2),
                bundle("v3", false, 3),
                // put there after v3: a hub's update about to serve
                bundle("v4", false, 4),
            ],
        };
        let owner = Owner {
            hub_id: "hubA",
            prefix: "run",
            own_bundle: "v3",
        };
        assert_eq!(
            plan(&owner, &seen),
            vec![
                Remove::Container("run-a2".into()),
                Remove::Container("run-px-a2".into()),
                Remove::Unit("run-a2-1".into()),
                Remove::Folder("/r/jobs/hubA-a2.1".into()),
                Remove::Folder("/r/jobs/hubA-a4.1".into()),
                Remove::Bundle("v2".into()),
            ]
        );
        // hub B, same prefix and root: only B's
        let b = Owner {
            hub_id: "hubB",
            prefix: "run",
            own_bundle: "v3",
        };
        assert_eq!(
            plan(&b, &seen),
            vec![
                Remove::Container("run-a3".into()),
                Remove::Container("run-b1".into()),
                Remove::Unit("run-b1-1".into()),
                Remove::Folder("/r/jobs/hubB-b1.1".into()),
                Remove::Folder("/r/jobs/hubB-b2.1".into()),
                Remove::Bundle("v2".into()),
            ]
        );
        // another prefix of the same hub sees none of these containers or units; serving from v1, it removes no
        // bundle: v0 is in use, and every other one came after v1
        let other = Owner {
            hub_id: "hubA",
            prefix: "flt",
            own_bundle: "v1",
        };
        let p = plan(&other, &seen);
        assert!(p.iter().all(|r| matches!(r, Remove::Folder(_))), "{p:?}");
        // a serve outside a bundle removes no bundle at all
        let loose = Owner {
            hub_id: "hubA",
            prefix: "run",
            own_bundle: "",
        };
        assert!(
            !plan(&loose, &seen)
                .iter()
                .any(|r| matches!(r, Remove::Bundle(_)))
        );
    }
}
