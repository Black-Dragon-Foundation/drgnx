//! The runners' methods (runners plan, Task 19; `docs/guide/runners.md`, `docs/develop/hub.md`, "Runners: the
//! registry"): the machines that run the hub's jobs, kept in the hub's registry.  Every method is the user's but
//! `runners/disk`, which an agent may read: an agent can't add, bench or remove a machine, reclaim its disk or pin an
//! item there.  The event `runners-changed` carries the list again when it changed.

use super::{Empty, invalid, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Id, KeyName, RunnerKeys, null_as_empty};
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// What a runner may see of the user's work.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Trust {
    /// The user's own machine: every job, every key.
    Mine,
    /// A machine drgnx starts in the user's cloud account: private code and only its listed keys.
    MyCloud,
    /// Somebody else's: public code only.
    Shared,
}

/// Whether somebody sits at the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Profile {
    Dedicated,
    Workstation,
}

/// Which jobs a runner takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Accept {
    All,
    Heavy,
}

/// `runners/add`'s params.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AddParams {
    /// The host as the user's ssh knows it (`ssh <host>`).
    pub host: Bounded<String, 255>,
    pub trust: Trust,
    /// The runner's name (default: the host's first label).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<Id>,
    /// Default `dedicated`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Profile>,
    /// Default `all`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accept: Option<Accept>,
    /// The one folder drgnx keeps on the runner (default `~/.drgnx-runner`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<AbsPath>,
    /// What the runner's units and containers are named after (default `drgnx-`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefix: Option<Bounded<String, 32>>,
    /// A Mac: run as an account other than `drgnx-runner` (`--allow-own-account`). Its home, keychain and privacy (TCC)
    /// grants are reachable by file permissions; the sandbox still applies to every job.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub allow_own_account: bool,
    /// A Mac: run as an administrator (`--allow-admin`; Linux takes one without it). The account can gain root through
    /// sudo with its password, and on a Mac through admin authorisation prompts; the sandbox still applies to every job.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub allow_admin: bool,
    /// A workstation's reserve for its user, MiB (`--reserve-mib`, at least 1024; default the profile's 4096).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reserve_mib: Option<u64>,
}

/// `runners/probe-host`'s params.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProbeParams {
    pub host: Bounded<String, 255>,
}

/// A runner by name (`runners/check`, `bench`, `unbench`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ByName {
    pub name: Id,
}

/// `runners/set`'s params: what changes.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SetParams {
    pub name: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trust: Option<Trust>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Profile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accept: Option<Accept>,
    /// A workstation's reserve for its user, MiB (at least 1024). A new profile without it takes the profile's; a
    /// profile or reserve change reconnects the runner, so it applies at once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reserve_mib: Option<u64>,
    /// The timing island (`--island`): a CPU list of whole L3 groups (`0-5,12-17`) timing jobs run on; empty removes
    /// it. A change reconnects the runner, whose `serve` checks it against the machine's caches.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub island: Option<Bounded<String, 64>>,
}

/// `runners/feature`'s params: an opt-in container feature (`sandbox`, `udmabuf`, `render`, `kvm`) switched on or off
/// for the jobs of one project on one runner. Only the user does this; a runner offers it to a job only while it is a
/// `mine` runner.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FeatureParams {
    pub name: Id,
    /// The project whose jobs get the feature (the job's project key).
    pub project: Bounded<String, 128>,
    pub feature: Bounded<String, 32>,
    pub on: bool,
}

/// `runners/remove`'s params: `confirm` must be true.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoveParams {
    pub name: Id,
    pub confirm: bool,
}

/// What reaches a host over ssh under the generated config (`ssh -G`): shown before the user adds it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Effective {
    pub forward_agent: bool,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub forwards: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<String>,
}

/// What a host is, once it meets the runner contract.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HostFacts {
    pub arch: String,
    pub os: String,
    pub cores: u32,
    pub mem_mib: u64,
    pub disk_free_gb: u64,
    pub podman: String,
    pub linger: bool,
    pub landlock_abi: u32,
    pub battery: bool,
}

/// One thing a host lacks, and what the user runs there to fix it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Missing {
    pub what: String,
    pub fix: String,
}

/// `runners/probe-host`'s answer: what applies to the connection, and the host's facts or what it lacks.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Probed {
    pub effective: Effective,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub facts: Option<HostFacts>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub missing: Vec<Missing>,
}

/// A runner as the registry lists it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Runner {
    pub name: String,
    pub host: String,
    pub trust: Trust,
    pub profile: Profile,
    pub accept: Accept,
    pub root: String,
    pub prefix: String,
    pub arch: String,
    pub os: String,
    pub cores: u32,
    pub mem_mib: u64,
    pub disk_free_gb: u64,
    pub podman: String,
    pub linger: bool,
    pub landlock_abi: u32,
    /// What the host has that a job may ask for (a GPU, ...).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub features: Vec<String>,
    /// Its bench: how many times the reference workload's speed (absent: not benched).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<f64>,
    /// `ready`, `benched: why (times)`, `needs a login: cmd`, `unreachable`, ...: the reason a runner is out of
    /// rotation is the state itself.
    pub state: String,
    pub strikes: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_strike: Option<String>,
    /// Jobs running there now.
    pub jobs: u32,
    /// When it was last checked (seconds since the epoch).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked: Option<f64>,
    /// A workstation's reserve for its user, MiB, when the user set one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reserve_mib: Option<u64>,
    /// Why the runner gets no job: its floor and reserve leave no room in the memory it has, with the numbers and the
    /// ways out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub no_room: Option<String>,
}

/// `runners/list`'s answer, and the data of `runners-changed`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Runners {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub runners: Vec<Runner>,
}

/// `runners/remove`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Removed {
    pub name: String,
}

/// `runners/keys`' params: the job keys the editor read from the user's store. No `Debug`: it holds keys.
#[derive(Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct KeysParams {
    pub keys: RunnerKeys,
}

/// The names of the job keys the hub holds or needs, never a value: `runners/keys-held`'s answer, and the data of the
/// event `runners/need-keys`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct KeyNames {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub names: Vec<KeyName>,
}

/// `runners/audit`'s params: the rows of one job, one key, or every row.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AuditParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<KeyName>,
}

/// What an audit row records.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum AuditKind {
    /// The hub sent the key to the attempt (what the hub knows for sure).
    Sent,
    /// The job read the key, as its runner reports it.
    Use,
}

/// One `key_sent` or `key_use` record: the key's name, never its value.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AuditRow {
    pub kind: AuditKind,
    pub job: String,
    pub attempt: u32,
    pub key: KeyName,
    pub runner: String,
    /// Seconds since the epoch.
    pub at: u64,
    /// The runner said so; the hub can't check it (every `use` row).
    #[serde(default)]
    pub runner_reported: bool,
}

/// `runners/audit`'s answer, oldest first.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Audit {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub rows: Vec<AuditRow>,
}

/// `runners/disk`'s params: one machine's disk, or every machine's.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DiskParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<Id>,
}

/// One kind's use of a machine's disk.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DiskClass {
    /// `job-folder`, `output`, `artifact`, `build-dir`, `slot`, `cache`, `image`, … (`forseti::disk::ItemKind`).
    pub kind: String,
    pub items: u32,
    pub bytes: u64,
    /// What may go now (past its age, not pinned or in use).
    pub evictable_bytes: u64,
}

/// One item on a machine's disk.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DiskEntry {
    pub id: String,
    pub kind: String,
    pub owner: String,
    pub bytes: u64,
    /// Seconds since the epoch.
    pub last_used: u64,
    /// `active`, `idle`, `evictable` or `pinned`.
    pub state: String,
}

/// One machine's disk, as its runner last reported it (bytes; GB is 10⁹).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MachineDisk {
    pub name: String,
    pub free: u64,
    pub total: u64,
    /// What drgnx keeps there.
    pub ours: u64,
    /// The owner's cap there, when one is set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quota: Option<u64>,
    /// btrfs's unallocated bytes, on a btrfs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub btrfs_unallocated: Option<u64>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub classes: Vec<DiskClass>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub items: Vec<DiskEntry>,
}

/// `runners/disk`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Disks {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub machines: Vec<MachineDisk>,
}

/// `runners/reclaim`'s params.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReclaimParams {
    pub name: Id,
    /// List what would go; remove nothing.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dry_run: bool,
}

/// `runners/reclaim`'s answer: the items ordered removed (or, dry, that would be), in order.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Reclaimed {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ids: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dry_run: bool,
}

/// `runners/pin`'s params: item ID on runner NAME kept (ON) or let go.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PinParams {
    pub name: Id,
    pub id: Bounded<String, 512>,
    pub on: bool,
}

/// The levels a series is about, from the whole machine down to one job (`sleipnir::proto::telemetry::Level`).
pub const TELEMETRY_LEVELS: [&str; 4] = ["runner", "slot", "reservation", "job"];
/// The widest span `runners/telemetry/range` answers.
pub const TELEMETRY_SPAN_MS: u64 = 366 * 86_400_000;

/// `runners/telemetry/subscribe`'s params: this connection hears LEVEL's samples of runner RUNNER (IDS: only those
/// ids, none: all) every EVERY_MS at most (0: the runner's store rate; never below its `live_min_ms`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetrySubscribe {
    pub runner: Id,
    pub level: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ids: Vec<String>,
    #[serde(default)]
    pub every_ms: u64,
}

/// `runners/telemetry/subscribe`'s answer: the stream's id, which every `runners-telemetry` event carries.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryWatching {
    pub watch: u64,
    pub runner: Id,
    pub level: String,
    pub every_ms: u64,
}

/// `runners/telemetry/range`'s params: runner RUNNER's stored history of LEVEL (IDS, none: all) from FROM to TO (epoch
/// ms), in STEP_MS points (0: as stored).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryRange {
    pub runner: Id,
    pub level: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub ids: Vec<String>,
    pub from: u64,
    pub to: u64,
    #[serde(default)]
    pub step_ms: u64,
}

/// One metric's value in a reading.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryValue {
    /// `cpu`, `mem_mib`, `psi_mem`, `headroom_mib`, …
    pub metric: String,
    pub value: f64,
}

/// One reading: the values of one id at one level at one instant.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetrySample {
    pub at_ms: u64,
    pub level: String,
    pub id: String,
    pub values: Vec<TelemetryValue>,
}

/// A moment on the timeline: `admitted`, `waited`, `paused`, `resumed`, `killed`, `stage-start`, `stage-end`, `evicted`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryMarker {
    pub at_ms: u64,
    pub id: String,
    pub kind: String,
    pub detail: String,
}

/// One stored point: the window starting at T, with every sample's extremes kept.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryPoint {
    pub t: u64,
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    pub last: f64,
}

/// One metric of one id over time.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetrySeries {
    pub level: String,
    pub id: String,
    pub metric: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub points: Vec<TelemetryPoint>,
}

/// `runners/telemetry/range`'s answer.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryHistory {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub series: Vec<TelemetrySeries>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub markers: Vec<TelemetryMarker>,
}

/// The event `runners-telemetry`: a batch of a stream's samples and markers.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TelemetryBatch {
    pub watch: u64,
    pub runner: Id,
    /// The rate the runner settled on.
    pub every_ms: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub samples: Vec<TelemetrySample>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub markers: Vec<TelemetryMarker>,
}

fn check_level(level: &str) -> Result<(), Error> {
    if TELEMETRY_LEVELS.contains(&level) {
        Ok(())
    } else {
        Err(invalid("level", "runner, slot, reservation or job"))
    }
}

fn check_telemetry_subscribe(p: &TelemetrySubscribe) -> Result<(), Error> {
    check_level(&p.level)?;
    if p.every_ms > 3_600_000 {
        return Err(invalid("every_ms", "at most an hour"));
    }
    if p.ids.len() > 256 {
        return Err(invalid("ids", "at most 256 ids"));
    }
    Ok(())
}

fn check_telemetry_range(p: &TelemetryRange) -> Result<(), Error> {
    check_level(&p.level)?;
    if p.from >= p.to {
        return Err(invalid("to", "after from"));
    }
    if p.to - p.from > TELEMETRY_SPAN_MS {
        return Err(invalid("to", "at most 366 days after from"));
    }
    if p.ids.len() > 256 {
        return Err(invalid("ids", "at most 256 ids"));
    }
    Ok(())
}

fn check_remove(p: &RemoveParams) -> Result<(), Error> {
    if p.confirm {
        Ok(())
    } else {
        Err(invalid(
            "confirm",
            "removing a runner deletes its folder: send confirm: true",
        ))
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "runners/list", RunnersList(Empty) -> Runners,
            classes: [User], writes: false,
            doc: "the runners: each with its trust, profile, load, jobs and, when it is out of rotation, why",
        ),
        method!(
            "runners/probe-host", RunnersProbeHost(ProbeParams) -> Probed,
            classes: [User], writes: false,
            doc: "what applies to a host's connection (ssh -G under the generated config) and what the host is, or everything the runner contract finds missing, each with its fix; the host is not recorded",
        ),
        method!(
            "runners/add", RunnersAdd(AddParams) -> Runner,
            classes: [User], writes: true,
            doc: "a host made a runner: probe and the contract, the bundle for its architecture copied, images pulled, benched, recorded; the hub's own machine is refused",
        ),
        method!(
            "runners/check", RunnersCheck(ByName) -> Runner,
            classes: [User], writes: true,
            doc: "a runner's health check now: its probe and contract, a canary job, the clock",
        ),
        method!(
            "runners/bench", RunnersBench(ByName) -> Runner,
            classes: [User], writes: true,
            doc: "a runner benched again: the reference workload under the runner's caps",
        ),
        method!(
            "runners/set", RunnersSet(SetParams) -> Runner,
            classes: [User], writes: true,
            doc: "a runner's trust, profile or accept changed",
        ),
        method!(
            "runners/disk", RunnersDisk(DiskParams) -> Disks,
            classes: [User, Agent], writes: false,
            doc: "each runner's disk as it last reported it: free, total, what drgnx keeps, the owner's quota, btrfs's unallocated, the use per kind and every item with its state",
        ),
        method!(
            "runners/reclaim", RunnersReclaim(ReclaimParams) -> Reclaimed,
            classes: [User], writes: false,
            doc: "a runner's items past their age and not pinned or in use ordered removed (dry_run: only listed); each is re-checked on the runner first",
        ),
        method!(
            "runners/pin", RunnersPin(PinParams) -> bool,
            classes: [User], writes: false,
            doc: "an item on a runner's disk kept (on) or let go: a pinned item goes only to the owner's quota",
        ),
        method!(
            "runners/telemetry/subscribe", RunnersTelemetrySubscribe(TelemetrySubscribe) -> TelemetryWatching,
            classes: [User], writes: false,
            doc: "this connection hears a runner's resource samples (runner, slot, reservation or job level) as `runners-telemetry` events, every every_ms at most and never faster than the runner's live_min_ms, while it stays connected",
            check: check_telemetry_subscribe,
        ),
        method!(
            "runners/telemetry/range", RunnersTelemetryRange(TelemetryRange) -> TelemetryHistory,
            classes: [User], writes: false,
            doc: "a runner's stored resource history of one level between two times, in points that keep each window's min, max, mean and last, with the markers (admitted, waited, paused, killed, evicted) on the same timeline",
            check: check_telemetry_range,
        ),
        method!(
            "runners/feature", RunnersFeature(FeatureParams) -> Runner,
            classes: [User], writes: true,
            doc: "a container feature (sandbox, udmabuf, render, kvm) allowed or not on a runner, for one project's jobs; offered only while the runner is mine",
        ),
        method!(
            "runners/unbench", RunnersUnbench(ByName) -> Runner,
            classes: [User], writes: true,
            doc: "a runner back in rotation, with no strikes",
        ),
        method!(
            "runners/remove", RunnersRemove(RemoveParams) -> Removed,
            classes: [User], writes: true,
            doc: "a runner removed: our units and containers there stopped, its folder deleted (confirm: true)",
            check: check_remove,
        ),
        method!(
            "runners/keys", RunnersKeys(KeysParams) -> bool,
            classes: [User], writes: false,
            doc: "job keys to the hub's memory (never a file), sent to the runners' jobs that name them",
        ),
        method!(
            "runners/keys-held", RunnersKeysHeld(Empty) -> KeyNames,
            classes: [User], writes: false,
            doc: "the job keys the hub holds (names only)",
        ),
        method!(
            "runners/audit", RunnersAudit(AuditParams) -> Audit,
            classes: [User], writes: false,
            doc: "the keys sent to jobs (key_sent) and their reads as runners report them (key_use): names, jobs, attempts, runners, times",
        ),
    ]
}

#[cfg(test)]
mod telemetry_tests {
    use super::*;

    fn range(level: &str, from: u64, to: u64) -> TelemetryRange {
        TelemetryRange {
            runner: serde_json::from_value(serde_json::json!("r1")).unwrap(),
            level: level.into(),
            ids: vec![],
            from,
            to,
            step_ms: 0,
        }
    }

    /// [D] pure: a range asks for a level that exists, a span that runs forward and is at most 366 days.
    #[test]
    fn a_telemetry_range_is_checked() {
        assert!(check_telemetry_range(&range("job", 1, 2)).is_ok());
        assert!(check_telemetry_range(&range("disk", 1, 2)).is_err());
        assert!(check_telemetry_range(&range("job", 2, 2)).is_err());
        assert!(check_telemetry_range(&range("job", 0, TELEMETRY_SPAN_MS)).is_ok());
        assert!(check_telemetry_range(&range("job", 0, TELEMETRY_SPAN_MS + 1)).is_err());
    }

    /// [D] pure: a subscription asks for a level that exists and a rate within an hour.
    #[test]
    fn a_telemetry_subscription_is_checked() {
        let sub = |level: &str, every_ms: u64| TelemetrySubscribe {
            runner: serde_json::from_value(serde_json::json!("r1")).unwrap(),
            level: level.into(),
            ids: vec![],
            every_ms,
        };
        assert!(check_telemetry_subscribe(&sub("slot", 5)).is_ok());
        assert!(check_telemetry_subscribe(&sub("slot", 0)).is_ok());
        assert!(check_telemetry_subscribe(&sub("nope", 5)).is_err());
        assert!(check_telemetry_subscribe(&sub("slot", 3_600_001)).is_err());
    }
}
