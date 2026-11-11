//! The runners' methods (runners plan, Task 19; `docs/guide/runners.md`, `docs/develop/hub.md`, "Runners: the
//! registry"): the machines that run the hub's jobs, kept in the hub's registry.  Every method is the user's: an
//! agent can't add, bench or remove a machine.  The event `runners-changed` carries the list again when it changed.

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
