//! The one builder of a `podman run` line, shared by the hub's local container jobs and the runners.
//!
//! A request carries an image *name* and a command; everything else is fixed here or comes from the caps: no
//! capabilities, no new privileges, a read-only root with a tmpfs `/tmp`, no network unless one was granted, swap equal
//! to memory, the container first in line for the OOM killer and killed whole. The command goes after the image, where
//! podman stops reading options. The image is the allow-list's reference pinned by digest; the caller pulls it, the job
//! never does (`--pull=never`).
//!
//! Locally the worktree is the one mount. On a runner ([`RunnerArgs::runner`]) the container lands in its job's slice
//! (`--cgroup-parent`), carries the runner's label and name prefix, and gets exactly the mount set of [`RunnerMounts`].

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::run::Output;

/// Why a container job is not run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub message: String,
}

fn refuse(message: impl Into<String>) -> Refusal {
    Refusal {
        message: message.into(),
    }
}

/// Where the source (the worktree, a slot, a private copy) appears inside the container.
pub const WORK: &str = "/work";
/// Where a runner job's target dir appears; `CARGO_TARGET_DIR` names it.
pub const TARGET: &str = "/target";
/// Where `drgnx-key` appears.
pub const KEY_HELPER: &str = "/run/drgnx/key";
/// The abstract socket name a keyed job's sidecar listens on for `drgnx-key`, in the namespace the job joins.
pub const KEY_NAME: &str = "drgnx-key";
/// The port the relay sidecar listens on, on the loopback of the namespace it shares with its job.
pub const PROXY_PORT: u16 = 3128;
/// The sidecar's limits (design §5.2): its worst case is about 50 MiB.
const SIDECAR_PIDS: &str = "32";
const SIDECAR_MEMORY: &str = "128m";
/// The user the sidecar runs as (`nobody` in its image).
const SIDECAR_USER: &str = "65534:65534";
/// The process limit of a container job.
pub const PIDS: u32 = 512;
/// The name prefix of the hub's own (local) containers.
pub const LOCAL_PREFIX: &str = "drgnx-job-";
/// A container's OOM score: first in line, before the job's own processes (900) and everything of the user's.
pub const OOM_SCORE: u32 = 1000;

/// One entry of the image allow-list: a name and its reference pinned by digest.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ContainerImage {
    pub name: String,
    pub image: String,
}

/// What the settings fix for every container job.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Caps {
    /// The only images a job may name.
    pub images: Vec<ContainerImage>,
    /// `--memory`, like `4G`; `--memory-swap` is the same, so a job never swaps.
    pub memory: String,
    pub cpus: u32,
    pub pids: u32,
    /// The relay sidecar a job that was granted network, or has keys, shares its network namespace with; none: such
    /// a job is refused.
    pub proxy: Option<JobNet>,
    /// The hosts (`host:port`) a granted network reaches, by tier name.
    pub net_hosts: Vec<(String, Vec<String>)>,
    /// Names the job's proxy resolves to a fixed address instead of asking DNS (a pinned name may lead to a private
    /// address; it must still be in `net_hosts`).  Absent in an older peer's caps: none.
    #[serde(default)]
    pub pins: Vec<(String, std::net::IpAddr)>,
}

/// A granted network is a relay sidecar, not a network: the sidecar runs with `--network=none`, and the job joins its
/// network namespace (`--network=container:`), so the job has a loopback and nothing else, and reaches the owner's
/// proxy through the relay at `127.0.0.1:3128`.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct JobNet {
    /// The sidecar's container name ([`net_names`]).
    pub sidecar: String,
}

/// What a job asks: an image name from the allow-list, a command, its source, the network granted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContainerReq {
    pub image: String,
    pub argv: Vec<String>,
    /// The source: the session's worktree locally; the slot, or a writer's private copy, on a runner.
    pub worktree: PathBuf,
    /// The folder inside the source the command runs in (relative; empty: the source itself).
    pub subdir: PathBuf,
    /// The job's id (letters and digits); the container is named after it.
    pub job: String,
    /// The matrix granted a network (through the proxy).
    pub net: bool,
    /// A keyed job's `drgnx-key` and keys, here or on a runner; none: a job without keys.
    pub keys: Option<KeyMounts>,
    /// A runner job's mounts besides the source; none: a local job.
    pub runner: Option<RunnerMounts>,
    /// The opt-in features the job needs (`sandbox`, `udmabuf`, `render`, `kvm`), each mapped to its podman argument only
    /// when the runner allows it ([`RunnerArgs::allowed`]); otherwise the job is refused.
    pub features: Vec<Feature>,
}

/// A runner job's mount set, exactly: the source `ro,z` (`rw,Z` for a `writes_tree` copy), the slot's
/// target dir `rw,Z` and one mount per declared cache `rw,Z` (and a keyed job's `drgnx-key` `ro,Z`, as anywhere).
/// Nothing else.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerMounts {
    /// The source is the job's private copy, which it may write.
    pub writes_tree: bool,
    /// The slot's target dir.
    pub target: PathBuf,
    pub caches: Vec<CacheMount>,
    /// A `git = "ro"` job's read-only git dir, outside the slot: mounted `ro` at [`GIT_DIR_INSIDE`], with `GIT_DIR` and
    /// `GIT_WORK_TREE` naming it.
    pub git_ro: Option<PathBuf>,
    /// The machine's jobserver fifo, for a job that takes part: bind-mounted at [`JOBSERVER_INSIDE`], with `MAKEFLAGS`
    /// and `CARGO_MAKEFLAGS` naming it.
    pub jobserver: Option<PathBuf>,
}

/// Where a `git = "ro"` job sees its git dir.
pub const GIT_DIR_INSIDE: &str = "/gitdir";

/// Where a job that takes part in the jobserver sees its fifo (`crate::linux::jobserver::INSIDE`).
pub const JOBSERVER_INSIDE: &str = "/jobserver";

/// A cache the job's suite declares: a folder under the runner's `cache/<project>/<trust>/`, at its path inside.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheMount {
    pub host: PathBuf,
    pub inside: String,
}

/// The job's own copy of the `drgnx-key` binary on the host, and the keys it reads: each `(key name, variable)`. The
/// command then runs as `drgnx-key exec NAME=VAR… -- CMD`, so podman's argv and stored config hold the names only,
/// never a value. `drgnx-key` reads them from the job's sidecar (`@drgnx-key` in the namespace the job joins).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyMounts {
    pub helper: PathBuf,
    pub vars: Vec<(String, String)>,
}

/// A key name `drgnx-key` asks for, and a variable a shell can name.
fn key_var_ok(name: &str, var: &str) -> bool {
    let name_ok = !name.is_empty()
        && name.len() <= 128
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b));
    let var_ok = var
        .bytes()
        .next()
        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && var.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    name_ok && var_ok
}

/// Where the container goes and what it is called: the hub's own jobs, or a runner's.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerArgs {
    /// `--cgroup-parent`: the job's slice (a runner only; without it podman puts the container under `user.slice`).
    pub cgroup_parent: Option<String>,
    /// `--label drgnx.runner=<hub id>` (a runner only): the runner removes only containers with its label and prefix.
    pub label: Option<String>,
    /// The name is this followed by the job id.
    pub name_prefix: String,
    /// Who owns the containers: the data-dir tag of a hub (8 hex), or `<prefix>/<hub id>` on a runner. A hub's
    /// containers carry it as `drgnx.owner`, and its sidecar's name.
    pub owner: String,
    /// The job container carries the owner's labels (`drgnx.owner` or `drgnx.runner`, and `drgnx.job`), so a sweep
    /// finds exactly its own.
    pub job_labels: bool,
    /// The features this runner allows the job's project (the user's opt-in, per runner and per project).
    pub allowed: Vec<Feature>,
    /// The render node a `render` job gets (`/dev/dri/renderD128`): the one the probe found; none: `render` is refused.
    pub render_node: Option<String>,
}

/// The variable that holds a job's deadline, in epoch seconds.
pub const DEADLINE_ENV: &str = "DRGNX_JOB_DEADLINE";

impl RunnerArgs {
    /// The hub's own container jobs: `drgnx-job-<id>`, no parent slice, labelled with OWNER_TAG.
    pub fn local(owner_tag: &str) -> RunnerArgs {
        RunnerArgs {
            cgroup_parent: None,
            label: None,
            name_prefix: LOCAL_PREFIX.to_string(),
            owner: owner_tag.to_string(),
            job_labels: true,
            allowed: vec![],
            render_node: None,
        }
    }

    /// A runner's: `<prefix>-<id>` in SLICE, labelled with HUB_ID.
    pub fn runner(prefix: &str, hub_id: &str, slice: &str) -> RunnerArgs {
        RunnerArgs {
            cgroup_parent: Some(slice.to_string()),
            label: Some(hub_id.to_string()),
            name_prefix: format!("{prefix}-"),
            owner: format!("{prefix}/{hub_id}"),
            job_labels: true,
            allowed: vec![],
            render_node: None,
        }
    }
}

/// A word podman reads as one value: letters, digits, `-`, `_` and `.`, not starting with `-`.
fn plain(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

/// The container name of job ID under PREFIX (an id of `[a-z0-9]`, as the runner makes them).
pub fn name_of(prefix: &str, id: &str) -> Result<String, Refusal> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(refuse("a container job's id is letters and digits"));
    }
    if !plain(prefix) {
        return Err(refuse(format!(
            "the container prefix {prefix:?} is not a plain name"
        )));
    }
    Ok(format!("{prefix}{id}"))
}

/// The names a networked job's sidecar goes by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetNames {
    /// The sidecar's container name: `drgnx-px-<tag>-<job>` locally, `<prefix>-px-<job>` on a runner.
    pub sidecar: String,
    /// The labels of the sidecar and the job, as `key=value`: `drgnx.owner=<tag>` (a hub) or `drgnx.runner=<hub id>`
    /// (a runner), then `drgnx.job=<job>`.
    pub labels: Vec<String>,
}

/// The sidecar's name and the labels of JOB under RA. A runner whose prefix could make its names those of the hub's
/// (`drgnx-job-…`, `drgnx-px-…`) or of another runner's sidecars (`…-px`) is refused.
pub fn net_names(ra: &RunnerArgs, job: &str) -> Result<NetNames, Refusal> {
    name_of(&ra.name_prefix, job)?;
    let sidecar = match &ra.label {
        None => {
            if !plain(&ra.owner) {
                return Err(refuse(format!(
                    "the owner tag {:?} is not a plain name",
                    ra.owner
                )));
            }
            format!("drgnx-px-{}-{job}", ra.owner)
        }
        Some(_) => {
            let p = &ra.name_prefix;
            if p.starts_with(LOCAL_PREFIX)
                || p.starts_with("drgnx-px-")
                || p.trim_end_matches('-').ends_with("-px")
                || p == "px-"
            {
                return Err(refuse(format!(
                    "the runner prefix {p:?} would give its containers the names of a hub's or another runner's sidecars"
                )));
            }
            format!("{p}px-{job}")
        }
    };
    Ok(NetNames {
        sidecar,
        labels: labels(ra, job)?,
    })
}

/// `drgnx.owner=<tag>` (a hub) or `drgnx.runner=<hub id>` (a runner), then `drgnx.job=<job>`.
fn labels(ra: &RunnerArgs, job: &str) -> Result<Vec<String>, Refusal> {
    let first = match &ra.label {
        Some(hub) => {
            if !plain(hub) {
                return Err(refuse(format!("the hub id {hub:?} is not a plain name")));
            }
            format!("drgnx.runner={hub}")
        }
        None => {
            if !plain(&ra.owner) {
                return Err(refuse(format!(
                    "the owner tag {:?} is not a plain name",
                    ra.owner
                )));
            }
            format!("drgnx.owner={}", ra.owner)
        }
    };
    Ok(vec![first, format!("drgnx.job={job}")])
}

/// `--cgroup-parent=SLICE` of a runner's containers.
fn slice_arg(slice: &str) -> Result<OsString, Refusal> {
    if !plain(slice) || !slice.ends_with(".slice") {
        return Err(refuse(format!(
            "the job's slice {slice:?} is not a slice name"
        )));
    }
    Ok(format!("--cgroup-parent={slice}").into())
}

/// The `podman run` arguments (without the program) for the relay sidecar N names, from IMAGE
/// (`localhost/drgnx-px:<hash>`): attached with `-i` (the channel is its stdin and stdout, never a tty), no network at
/// all, the loopback its job shares, no core dump (`--ulimit core=1`: a piped `core_pattern` honours 1, not 0), and
/// nothing but the relay's flags after the image; KEYS (a keyed job) adds `--keys drgnx-key`, its keys' listener.
pub fn sidecar_argv(
    n: &NetNames,
    ra: &RunnerArgs,
    image: &str,
    keys: bool,
) -> Result<Vec<OsString>, Refusal> {
    if image.is_empty() || image.starts_with('-') || image.contains(char::is_whitespace) {
        return Err(refuse(format!(
            "the sidecar's image {image:?} is not an image name"
        )));
    }
    let mut a: Vec<OsString> = [
        "run",
        "-i",
        "--rm",
        "--pull=never",
        "--log-driver=none",
        "--detach-keys=",
        "--user",
        SIDECAR_USER,
        "--cap-drop=all",
        "--security-opt=no-new-privileges",
        "--read-only",
        "--pids-limit",
        SIDECAR_PIDS,
        "--memory",
        SIDECAR_MEMORY,
        "--memory-swap",
        SIDECAR_MEMORY,
        "--cpus",
        "1",
        "--ulimit",
        "core=1",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    if let Some(slice) = &ra.cgroup_parent {
        a.push(slice_arg(slice)?);
    }
    for l in &n.labels {
        a.push("--label".into());
        a.push(l.into());
    }
    a.extend(["--network=none", "--name"].map(OsString::from));
    a.push((&n.sidecar).into());
    a.push(image.into());
    a.extend(
        [
            "--listen".to_string(),
            format!("127.0.0.1:{PROXY_PORT}"),
            "--job-ip".to_string(),
            "127.0.0.1".to_string(),
        ]
        .map(OsString::from),
    );
    if keys {
        a.extend(["--keys", KEY_NAME].map(OsString::from));
    }
    Ok(a)
}

/// The reference pinned by digest that the allow-list holds for NAME.
pub fn resolve<'a>(caps: &'a Caps, name: &str) -> Result<&'a str, Refusal> {
    let found = caps.images.iter().find(|i| i.name == name).ok_or_else(|| {
        let known: Vec<&str> = caps.images.iter().map(|i| i.name.as_str()).collect();
        refuse(format!(
            "image {name:?} is not on agents-container-images (allowed: {})",
            if known.is_empty() {
                "none".to_string()
            } else {
                known.join(", ")
            }
        ))
    })?;
    if !found.image.contains("@sha256:") || found.image.starts_with('-') {
        return Err(refuse(format!(
            "image {name:?} on agents-container-images is not pinned by digest"
        )));
    }
    Ok(&found.image)
}

/// A mount source podman reads as one path (a `:` or `,` would add mount options).
fn mount_source(path: &Path) -> Result<String, Refusal> {
    let s = path
        .to_str()
        .filter(|s| path.is_absolute() && !s.contains([':', ',', '\n', '\0']))
        .ok_or_else(|| {
            refuse(format!(
                "a mount must be an absolute path without ':' or ',': {}",
                path.display()
            ))
        })?;
    Ok(s.to_string())
}

/// A size podman reads: digits, then at most one of `K M G T`, not starting with 0.
fn ok_memory(m: &str) -> bool {
    let digits = m.trim_end_matches(['K', 'M', 'G', 'T']);
    !m.is_empty()
        && digits.len() + 1 >= m.len()
        && !digits.is_empty()
        && digits.bytes().all(|b| b.is_ascii_digit())
        && !m.starts_with('0')
}

/// An opt-in feature of a runner's container (runners design D2): a thing a job may ask for that the user must have
/// allowed, per runner and per project. The names are the placement features.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize, serde::Deserialize,
)]
#[serde(rename_all = "kebab-case")]
pub enum Feature {
    /// `--security-opt=unmask=ALL`: bwrap and other namespace sandboxes run inside the job.
    Sandbox,
    /// `--device=/dev/udmabuf`.
    Udmabuf,
    /// `--device=<the render node>`.
    Render,
    /// Network for an artifact build (Task 16): never on a `podman run`.
    BuildNet,
    /// `--device=/dev/kvm`.
    Kvm,
}

impl Feature {
    pub fn parse(s: &str) -> Option<Feature> {
        Some(match s {
            "sandbox" => Feature::Sandbox,
            "udmabuf" => Feature::Udmabuf,
            "render" => Feature::Render,
            "build-net" => Feature::BuildNet,
            "kvm" => Feature::Kvm,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Feature::Sandbox => "sandbox",
            Feature::Udmabuf => "udmabuf",
            Feature::Render => "render",
            Feature::BuildNet => "build-net",
            Feature::Kvm => "kvm",
        }
    }
}

/// What a runner allows a job of PROJECT: the hub's `--feature` rows for PROJECT or for every project (`*`, a `mine`
/// runner's `kvm` fact), except that a `kvm` row for PROJECT alone also needs the runner's own opt-in, `KVM_PROJECTS`
/// (its `runner.conf`, [`kvm_projects`]): a shared or my-cloud machine's owner says which projects may have `/dev/kvm`.
pub fn allowed_for(
    project: &str,
    rows: &[(String, Feature)],
    kvm_projects: &[String],
) -> Vec<Feature> {
    let mut out: Vec<Feature> = vec![];
    for (p, f) in rows {
        let ok = match (p.as_str(), f) {
            ("*", _) => true,
            (p, Feature::Kvm) => p == project && kvm_projects.iter().any(|k| k == project),
            (p, _) => p == project,
        };
        if ok && !out.contains(f) {
            out.push(*f);
        }
    }
    out
}

/// The projects a runner's own config lets use `/dev/kvm`: the `kvm = ["a", "b"]` line under `[features]` of its
/// `runner.conf`. Only that one shape is read (a TOML subset); anything else is ignored.
pub fn kvm_projects(text: &str) -> Vec<String> {
    let mut in_features = false;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_features = line == "[features]";
        } else if in_features
            && let Some(list) = line
                .strip_prefix("kvm")
                .map(str::trim_start)
                .and_then(|r| r.strip_prefix('='))
                .map(str::trim)
                .and_then(|r| r.strip_prefix('['))
                .and_then(|r| r.strip_suffix(']'))
        {
            return list
                .split(',')
                .map(|p| p.trim().trim_matches('"'))
                .filter(|p| {
                    !p.is_empty()
                        && p.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
                })
                .map(str::to_string)
                .collect();
        }
    }
    vec![]
}

/// The `podman run` arguments for the features REQ asks for: each only when RA allows it, else a refusal.
fn feature_args(req: &ContainerReq, ra: &RunnerArgs) -> Result<Vec<OsString>, Refusal> {
    let mut a: Vec<OsString> = vec![];
    for f in &req.features {
        if !ra.allowed.contains(f) {
            return Err(refuse(format!(
                "this job needs {:?}, which this runner does not allow for its project",
                f.name()
            )));
        }
        a.push(match f {
            Feature::Sandbox => "--security-opt=unmask=ALL".into(),
            Feature::Udmabuf => "--device=/dev/udmabuf".into(),
            Feature::Kvm => "--device=/dev/kvm".into(),
            Feature::Render => {
                let node = ra
                    .render_node
                    .as_deref()
                    .filter(|n| {
                        n.strip_prefix("/dev/dri/renderD")
                            .is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
                    })
                    .ok_or_else(|| refuse("this runner has no render node to give"))?;
                format!("--device={node}").into()
            }
            Feature::BuildNet => {
                return Err(refuse(
                    "build-net is for an artifact build, never a container job",
                ));
            }
        });
    }
    Ok(a)
}

/// The `podman run` arguments (without the program) for REQ under CAPS, placed by RA.
pub fn argv(req: &ContainerReq, caps: &Caps, ra: &RunnerArgs) -> Result<Vec<OsString>, Refusal> {
    if req.argv.is_empty() || req.argv[0].is_empty() {
        return Err(refuse("a container job needs a command"));
    }
    let image = resolve(caps, &req.image)?;
    let source = mount_source(&req.worktree)?;
    if !ok_memory(&caps.memory) || caps.cpus == 0 || caps.pids == 0 {
        return Err(refuse(
            "agents-job-memory, agents-job-cpus: a limit that fits podman",
        ));
    }
    // a keyed job reads its keys through its sidecar, networked or not
    let keyed = req.keys.is_some();
    let sidecar = match req.net || keyed {
        false => None,
        true => {
            let p = caps.proxy.as_ref().ok_or_else(|| {
                refuse(if req.net {
                    "this job was granted network access, but it has no proxy to go through"
                } else {
                    "this job has keys, but no sidecar to read them through"
                })
            })?;
            // the sidecar is this job's own: a name from anywhere else is never joined
            if p.sidecar != net_names(ra, &req.job)?.sidecar {
                return Err(refuse(format!(
                    "this job's sidecar {:?} is not the one named for it",
                    p.sidecar
                )));
            }
            Some(p.sidecar.as_str())
        }
    };
    let mut a: Vec<OsString> = [
        "run",
        "--rm",
        "--name",
        &name_of(&ra.name_prefix, &req.job)?,
        "--pull=never",
        "--userns=keep-id",
        "--cap-drop=all",
        "--security-opt=no-new-privileges",
        "--read-only",
        "--tmpfs",
        "/tmp",
        "--pids-limit",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    a.push(caps.pids.to_string().into());
    a.push("--memory".into());
    a.push(caps.memory.clone().into());
    a.push("--memory-swap".into());
    a.push(caps.memory.clone().into());
    a.push("--cpus".into());
    a.push(caps.cpus.to_string().into());
    a.push(format!("--oom-score-adj={OOM_SCORE}").into());
    a.push("--cgroup-conf=memory.oom.group=1".into());
    if let Some(slice) = &ra.cgroup_parent {
        a.push(slice_arg(slice)?);
    }
    if ra.job_labels {
        for l in labels(ra, &req.job)? {
            a.push("--label".into());
            a.push(l.into());
        }
    } else if let Some(hub) = &ra.label {
        if !plain(hub) {
            return Err(refuse(format!("the hub id {hub:?} is not a plain name")));
        }
        a.push("--label".into());
        a.push(format!("drgnx.runner={hub}").into());
    }
    a.extend(feature_args(req, ra)?);
    a.push(
        match sidecar {
            Some(s) => format!("--network=container:{s}"),
            None => "--network=none".to_string(),
        }
        .into(),
    );
    // a job never fetches an object a git dir lacks: no network, and a lazy fetch would only wait
    a.push("-e".into());
    a.push("GIT_NO_LAZY_FETCH=1".into());
    // a job's deadline passes through from the podman client's environment (job-exec's, the hub's job), so a harness
    // can dump its state before its time box ends (design §5.7)
    if ra.job_labels {
        a.push("-e".into());
        a.push(DEADLINE_ENV.into());
    }
    match &req.runner {
        None => {
            a.push("-v".into());
            a.push(format!("{source}:{WORK}:Z").into());
        }
        Some(m) => {
            a.push("-v".into());
            // the slot is shared by the jobs of one slot key: `z` (shared label) and read-only; a private copy is the
            // job's own
            a.push(
                if m.writes_tree {
                    format!("{source}:{WORK}:rw,Z")
                } else {
                    format!("{source}:{WORK}:ro,z")
                }
                .into(),
            );
            a.push("-v".into());
            a.push(format!("{}:{TARGET}:rw,Z", mount_source(&m.target)?).into());
            a.push("-e".into());
            a.push(format!("CARGO_TARGET_DIR={TARGET}").into());
            if let Some(g) = &m.git_ro {
                a.push("-v".into());
                a.push(format!("{}:{GIT_DIR_INSIDE}:ro,z", mount_source(g)?).into());
                a.push("-e".into());
                a.push(format!("GIT_DIR={GIT_DIR_INSIDE}").into());
                a.push("-e".into());
                a.push(format!("GIT_WORK_TREE={WORK}").into());
            }
            if let Some(j) = &m.jobserver {
                a.push("-v".into());
                a.push(format!("{}:{JOBSERVER_INSIDE}:rw,Z", mount_source(j)?).into());
                for var in ["MAKEFLAGS", "CARGO_MAKEFLAGS"] {
                    a.push("-e".into());
                    a.push(format!("{var}=--jobserver-auth=fifo:{JOBSERVER_INSIDE}").into());
                }
            }
            for c in &m.caches {
                let inside = &c.inside;
                if !inside.starts_with('/')
                    || inside.contains([':', ',', '\n', '\0'])
                    || inside.split('/').any(|p| p == "..")
                    || [WORK, TARGET, "/run/drgnx", "/tmp"]
                        .iter()
                        .any(|t| inside == t || inside.starts_with(&format!("{t}/")))
                {
                    return Err(refuse(format!(
                        "a cache's path inside the container is not a plain absolute path of its own: {inside:?}"
                    )));
                }
                a.push("-v".into());
                a.push(format!("{}:{inside}:rw,Z", mount_source(&c.host)?).into());
            }
        }
    }
    if let Some(k) = &req.keys {
        a.push("-v".into());
        a.push(format!("{}:{KEY_HELPER}:ro,Z", mount_source(&k.helper)?).into());
    }
    a.push("-w".into());
    a.push(if req.subdir.as_os_str().is_empty() {
        OsString::from(WORK)
    } else {
        Path::new(WORK).join(&req.subdir).into_os_string()
    });
    if sidecar.is_some() && req.net {
        // the job shares the sidecar's loopback, where the relay listens
        let url = format!("http://127.0.0.1:{PROXY_PORT}");
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            a.push("-e".into());
            a.push(format!("{k}={url}").into());
        }
        for k in ["NO_PROXY", "no_proxy"] {
            a.push("-e".into());
            a.push(format!("{k}=localhost,127.0.0.1,::1").into());
        }
    }
    // a keyed job's command runs under drgnx-key, which reads each key from the socket into its own environment and
    // execs the command; the job's request has no field to put anything around it
    let keyed: Vec<OsString> = match &req.keys {
        Some(k) if !k.vars.is_empty() => {
            let mut w: Vec<OsString> = vec![KEY_HELPER.into(), "exec".into()];
            for (name, var) in &k.vars {
                if !key_var_ok(name, var) {
                    return Err(refuse(format!(
                        "a key's name or variable is not a plain name: {name:?} {var:?}"
                    )));
                }
                w.push(format!("{name}={var}").into());
            }
            w.push("--".into());
            w
        }
        _ => vec![],
    };
    if !keyed.is_empty() {
        a.push("--entrypoint".into());
        a.push(KEY_HELPER.into());
    }
    a.push(image.into());
    // the entrypoint is drgnx-key itself
    a.extend(keyed.into_iter().skip(1));
    a.extend(req.argv.iter().map(OsString::from));
    Ok(a)
}

/// Runs `podman ARGS` with exactly ENV; kills it and says so when it outlives LIMIT.
pub fn run_limited(
    podman: &Path,
    args: &[&str],
    env: &[(OsString, OsString)],
    limit: Duration,
) -> villa::Result<Output> {
    let spec = draugr::Spec {
        program: podman.to_path_buf(),
        args: args.iter().map(OsString::from).collect(),
        env: env.to_vec(),
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    };
    match draugr::run(spec, limit) {
        Ok(o) => Ok(Output {
            status: o.status,
            stdout: o.stdout,
            stderr: o.stderr.into_bytes(),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::TimedOut => Err(villa::Error::timeout(format!(
            "podman {} took longer than {}s; the job is refused",
            args.first().copied().unwrap_or(""),
            limit.as_secs()
        ))
        .with_source(e)),
        Err(e) => Err(villa::Error::io(format!("podman: {e}")).with_source(e)),
    }
}

/// The cgroup controllers a job's caps use: `--memory`, `--pids-limit`, `--cpus`.
pub const CONTROLLERS: [&str; 3] = ["memory", "pids", "cpu"];

/// Whether the podman that `podman info --format json` described (INFO) enforces a job's caps; the reason when it
/// does not. Rootless podman applies limits only on cgroup v2 through the systemd cgroup manager, with the controllers
/// delegated to the user. Without a systemd user session it falls back to `cgroupfs`, where a rootless container may
/// get no cgroup of its own and its limits are dropped with no more than a warning.
pub fn limits_enforced(info: &serde_json::Value) -> villa::Result<()> {
    let host = &info["host"];
    let version = host["cgroupVersion"].as_str().unwrap_or("unknown");
    let manager = host["cgroupManager"].as_str().unwrap_or("unknown");
    if version != "v2" {
        return Err(villa::Error::unavailable(format!(
            "podman runs on cgroup {version}, and the caps need cgroup v2"
        )));
    }
    if manager != "systemd" {
        return Err(villa::Error::unavailable(format!(
            "podman's cgroup manager is {manager}, which cannot enforce a rootless container's caps: \
             it needs a systemd user session (log in, or `loginctl enable-linger`) and the hub its \
             XDG_RUNTIME_DIR or DBUS_SESSION_BUS_ADDRESS"
        )));
    }
    let have: Vec<&str> = host["cgroupControllers"]
        .as_array()
        .map(|a| a.iter().filter_map(|c| c.as_str()).collect())
        .unwrap_or_default();
    let missing: Vec<&str> = CONTROLLERS
        .iter()
        .copied()
        .filter(|c| !have.contains(c))
        .collect();
    if !missing.is_empty() {
        return Err(villa::Error::unavailable(format!(
            "the cgroup controllers {} are not delegated to this user, so podman cannot enforce the caps",
            missing.join(", ")
        )));
    }
    Ok(())
}

/// The reason container jobs are refused here unless PODMAN (run with ENV) enforces their caps
/// ([`limits_enforced`]), asked within LIMIT. Answers the parsed `podman info`, which a networked job's checks read
/// too ([`super::netcheck::net_ready`]).
pub fn check_limits(
    podman: &Path,
    env: &[(OsString, OsString)],
    limit: Duration,
) -> villa::Result<serde_json::Value> {
    let refused =
        |m: String| villa::Error::unavailable(format!("container jobs are refused here: {m}"));
    let out = run_limited(podman, &["info", "--format", "json"], env, limit)?;
    if !out.status.success() {
        return Err(refused(format!(
            "podman info failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let info: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| refused(format!("podman info is not JSON: {e}")))?;
    limits_enforced(&info).map_err(|e| refused(e.message().to_string()))?;
    Ok(info)
}

/// What a start-up sweep removes (S11): job containers, then sidecars, then networks, each a name.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Leftovers {
    pub jobs: Vec<String>,
    pub sidecars: Vec<String>,
    pub networks: Vec<String>,
}

/// The sweep's removals, shared by the hub and the runners: of `podman ps -a --format json` (PS) and, with an internal
/// network, `podman network ls --format json` (NETS; `None` under Q8), what carries the label OWNER (`drgnx.owner` and
/// this hub's tag, or `drgnx.runner` and the hub id) and a `drgnx.job` not in RUNNING.  A container without both labels
/// is left, whatever its name: a sibling hub's and one made before the labels are never touched.  A sidecar is told
/// from its job's container by its name (`drgnx-px-<tag>-<job>`, `<prefix>-px-<job>`).
pub fn leftovers(
    ps: &serde_json::Value,
    nets: Option<&serde_json::Value>,
    owner: (&str, &str),
    running: &std::collections::HashSet<String>,
) -> Leftovers {
    let mut out = Leftovers::default();
    let dead = |labels: &serde_json::Value| -> Option<String> {
        if labels.get(owner.0).and_then(|v| v.as_str()) != Some(owner.1) {
            return None;
        }
        let job = labels.get("drgnx.job")?.as_str()?;
        (!running.contains(job)).then(|| job.to_string())
    };
    for c in ps.as_array().into_iter().flatten() {
        let Some(job) = dead(&c["Labels"]) else {
            continue;
        };
        let name = match &c["Names"] {
            serde_json::Value::Array(n) => n.first().and_then(|n| n.as_str()),
            n => n.as_str(),
        };
        let Some(name) = name else { continue };
        let sidecar = name
            .strip_suffix(&format!("-{job}"))
            .is_some_and(|rest| rest.ends_with("-px") || rest.starts_with("drgnx-px-"));
        if sidecar {
            out.sidecars.push(name.to_string());
        } else {
            out.jobs.push(name.to_string());
        }
    }
    for n in nets.and_then(|n| n.as_array()).into_iter().flatten() {
        if dead(&n["labels"]).is_some()
            && let Some(name) = n["name"].as_str()
        {
            out.networks.push(name.to_string());
        }
    }
    out.jobs.sort();
    out.sidecars.sort();
    out.networks.sort();
    out
}

/// The sidecar image tags (`localhost/drgnx-px:<hex>`) of `podman images --format json` (IMAGES) other than CURRENT:
/// an older binary's images, which the sweep removes.
pub fn old_px_tags(images: &serde_json::Value, current: &str) -> Vec<String> {
    let mut out: Vec<String> = images
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|i| i["Names"].as_array().cloned().unwrap_or_default())
        .filter_map(|n| n.as_str().map(str::to_string))
        .filter(|n| n.starts_with("localhost/drgnx-px:") && n != current)
        .collect();
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod sweep_tests {
    use super::*;
    use serde_json::json;

    fn ctr(name: &str, labels: serde_json::Value) -> serde_json::Value {
        json!({"Names": [name], "Labels": labels})
    }

    fn listing() -> serde_json::Value {
        json!([
            ctr(
                "drgnx-job-a1",
                json!({"drgnx.owner": "aaaa1111", "drgnx.job": "a1"})
            ),
            ctr(
                "drgnx-px-aaaa1111-a1",
                json!({"drgnx.owner": "aaaa1111", "drgnx.job": "a1"})
            ),
            ctr(
                "drgnx-job-a2",
                json!({"drgnx.owner": "aaaa1111", "drgnx.job": "a2"})
            ),
            ctr(
                "drgnx-px-aaaa1111-a2",
                json!({"drgnx.owner": "aaaa1111", "drgnx.job": "a2"})
            ),
            ctr(
                "drgnx-job-b1",
                json!({"drgnx.owner": "bbbb2222", "drgnx.job": "b1"})
            ),
            ctr(
                "drgnx-px-bbbb2222-b1",
                json!({"drgnx.owner": "bbbb2222", "drgnx.job": "b1"})
            ),
            ctr("run-r1", json!({"drgnx.runner": "hub1", "drgnx.job": "r1"})),
            ctr("drgnx-job-old", json!({})),
        ])
    }

    #[test]
    fn sweep_takes_only_its_own_label() {
        let running = ["a1".to_string()].into_iter().collect();
        let l = leftovers(&listing(), None, ("drgnx.owner", "aaaa1111"), &running);
        assert_eq!(l.jobs, ["drgnx-job-a2"]);
        assert_eq!(l.sidecars, ["drgnx-px-aaaa1111-a2"]);
        assert!(l.networks.is_empty());
        let r = leftovers(
            &listing(),
            None,
            ("drgnx.runner", "hub1"),
            &Default::default(),
        );
        assert_eq!(r.jobs, ["run-r1"]);
    }

    #[test]
    fn a_running_jobs_sidecar_stays() {
        let running = ["a1".to_string(), "a2".to_string()].into_iter().collect();
        let l = leftovers(&listing(), None, ("drgnx.owner", "aaaa1111"), &running);
        assert_eq!(l, Leftovers::default());
    }

    #[test]
    fn jobs_go_before_sidecars_before_networks() {
        let ps = json!([
            ctr(
                "run-px-r2",
                json!({"drgnx.runner": "hub1", "drgnx.job": "r2"})
            ),
            ctr("run-r2", json!({"drgnx.runner": "hub1", "drgnx.job": "r2"})),
        ]);
        let nets =
            json!([{"name": "run-net-r2", "labels": {"drgnx.runner": "hub1", "drgnx.job": "r2"}}]);
        let l = leftovers(
            &ps,
            Some(&nets),
            ("drgnx.runner", "hub1"),
            &Default::default(),
        );
        assert_eq!(
            (l.jobs, l.sidecars, l.networks),
            (
                vec!["run-r2".to_string()],
                vec!["run-px-r2".to_string()],
                vec!["run-net-r2".to_string()]
            )
        );
    }

    #[test]
    fn old_px_tags_go() {
        let images = json!([
            {"Names": ["localhost/drgnx-px:00aa"]},
            {"Names": ["localhost/drgnx-px:11bb"]},
            {"Names": ["docker.io/library/busybox:1.36"]}
        ]);
        assert_eq!(
            old_px_tags(&images, "localhost/drgnx-px:11bb"),
            ["localhost/drgnx-px:00aa"]
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REF: &str = "registry.example/tools@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    const TAG: &str = "0a1b2c3d";

    fn caps() -> Caps {
        Caps {
            images: vec![ContainerImage {
                name: "tools".into(),
                image: REF.into(),
            }],
            memory: "4G".into(),
            cpus: 2,
            pids: PIDS,
            net_hosts: vec![("packages".into(), vec!["crates.io:443".into()])],
            proxy: Some(JobNet {
                sidecar: "drgnx-px-0a1b2c3d-x1a".into(),
            }),
            pins: vec![],
        }
    }

    /// The caps of a runner job: its sidecar is named by the runner's prefix.
    fn rcaps() -> Caps {
        Caps {
            proxy: Some(JobNet {
                sidecar: "drgnx-run-px-x1a".into(),
            }),
            ..caps()
        }
    }

    fn req(argv: &[&str]) -> ContainerReq {
        ContainerReq {
            features: vec![],
            image: "tools".into(),
            argv: argv.iter().map(|s| s.to_string()).collect(),
            worktree: "/work/tree".into(),
            subdir: PathBuf::new(),
            job: "x1a".into(),
            net: false,
            keys: None,
            runner: None,
        }
    }

    fn runner_req(argv: &[&str]) -> ContainerReq {
        ContainerReq {
            worktree: "/r/slots/k1".into(),
            runner: Some(RunnerMounts {
                writes_tree: false,
                target: "/r/slots/k1-target".into(),
                caches: vec![CacheMount {
                    host: "/r/cache/p/public/cargo".into(),
                    inside: "/cache/cargo".into(),
                }],
                git_ro: None,
                jobserver: None,
            }),
            keys: Some(KeyMounts {
                helper: "/r/bin/0.1.0/drgnx-key".into(),
                vars: vec![],
            }),
            ..req(argv)
        }
    }

    /// [D] A keyed job's command runs as `drgnx-key exec NAME=VAR… -- CMD`: drgnx-key is the entrypoint; the argv holds
    /// the names only, and a name podman or a shell would misread is refused.
    #[test]
    fn a_keyed_job_runs_under_drgnx_key_exec_with_names_only() {
        let mut r = runner_req(&["cargo", "publish"]);
        r.keys.as_mut().unwrap().vars = vec![
            ("CRATES_IO".into(), "CARGO_REGISTRY_TOKEN".into()),
            ("gh-token".into(), "GH_TOKEN".into()),
        ];
        let a = on_runner(&r, &rcaps()).unwrap();
        let image = a.iter().position(|s| s == REF).unwrap();
        assert_eq!(a[image - 2..image], ["--entrypoint", "/run/drgnx/key"]);
        assert_eq!(
            a[image + 1..],
            [
                "exec",
                "CRATES_IO=CARGO_REGISTRY_TOKEN",
                "gh-token=GH_TOKEN",
                "--",
                "cargo",
                "publish"
            ]
        );
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--env") || s.starts_with("--secret"))
        );
        for (name, var) in [
            ("A B", "V"),
            ("A", "1V"),
            ("A=B", "V"),
            ("A", "V-W"),
            ("", "V"),
            ("A", ""),
        ] {
            let mut r = runner_req(&["ls"]);
            r.keys.as_mut().unwrap().vars = vec![(name.into(), var.into())];
            assert!(on_runner(&r, &rcaps()).is_err(), "{name:?} {var:?}");
        }
    }

    /// [D] A keyed job reads its keys through its own sidecar (`@drgnx-key` in the network namespace it joins), with
    /// or without a network grant: it joins the sidecar named for it, gets the proxy variables only when granted a
    /// network, and its argv holds no key socket and no label override. A keyed job with no sidecar, or another
    /// job's, is refused.
    #[test]
    fn a_keyed_job_reads_its_keys_through_its_own_sidecar() {
        let r = runner_req(&["ls"]);
        assert!(!r.net);
        let a = on_runner(&r, &rcaps()).unwrap();
        assert!(a.contains(&"--network=container:drgnx-run-px-x1a".to_string()));
        assert!(!a.iter().any(|s| s.contains("PROXY")), "{a:?}");
        assert!(
            !a.iter()
                .any(|s| s.contains(concat!("key", ".sock")) || s.starts_with("label=")),
            "{a:?}"
        );
        let mut net = runner_req(&["ls"]);
        net.net = true;
        let a = on_runner(&net, &rcaps()).unwrap();
        assert!(a.contains(&"--network=container:drgnx-run-px-x1a".to_string()));
        assert!(a.iter().any(|s| s == "HTTPS_PROXY=http://127.0.0.1:3128"));
        let none = Caps {
            proxy: None,
            ..caps()
        };
        let e = on_runner(&r, &none).unwrap_err();
        assert!(e.message.contains("keys"), "{}", e.message);
        // caps() names the hub's sidecar for x1a, not this runner's
        assert!(on_runner(&r, &caps()).is_err());
        // an unkeyed job without a grant joins nothing
        let mut plain = runner_req(&["ls"]);
        plain.keys = None;
        let a = on_runner(&plain, &rcaps()).unwrap();
        assert!(a.contains(&"--network=none".to_string()));
    }

    /// [D] lint: no container job's keys go through a key socket file (they go over the sidecar's `@drgnx-key`): no
    /// write to the thread's socket-create attribute anywhere, and no key socket file in the sources of the runner, the
    /// hub, the relay or the sandbox but the hub's own key server for command jobs on its machine (`exec/keys.rs` and
    /// its rows), which no container mounts.
    #[test]
    fn no_source_makes_or_mounts_a_key_socket() {
        fn walk(d: &Path, out: &mut Vec<PathBuf>) {
            for e in std::fs::read_dir(d).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, out);
                } else if p.extension().is_some_and(|x| x == "rs") {
                    out.push(p);
                }
            }
        }
        let needles = [concat!("sock", "create"), concat!("key", ".sock")];
        let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let mut files = vec![];
        for c in ["sleipnir", "ratatoskr", "ferja", "gleipnir"] {
            walk(&crates.join(c).join("src"), &mut files);
            walk(&crates.join(c).join("tests"), &mut files);
        }
        assert!(files.len() > 20, "the sources: {}", files.len());
        let local_key_server = ["ratatoskr/src/exec/keys.rs", "ratatoskr/src/exec/tests.rs"];
        let mut hits = vec![];
        for f in files {
            let text = crate::fsio::read_to_string(&f).unwrap();
            let local = local_key_server.iter().any(|s| f.ends_with(s));
            for (i, l) in text.lines().enumerate() {
                if needles
                    .iter()
                    .any(|n| l.contains(n) && !(local && *n == needles[1]))
                {
                    hits.push(format!("{}:{}: {}", f.display(), i + 1, l.trim()));
                }
            }
        }
        assert!(hits.is_empty(), "{hits:#?}");
    }

    /// A keyed job of the hub's own runs as a runner's does: its copy of `drgnx-key` mounted read-only as the
    /// entrypoint, the names only in its argv, and its keys read through its own sidecar (the hub's name for it), with
    /// or without a network grant.
    #[test]
    fn a_keyed_job_here_runs_under_drgnx_key_through_its_sidecar() {
        let mut r = req(&["make", "publish"]);
        r.keys = Some(KeyMounts {
            helper: "/d/jobs/x1a/drgnx-key".into(),
            vars: vec![("CRATES_IO".into(), "CRATES_IO".into())],
        });
        let a = local(&r, &caps()).unwrap();
        assert!(a.contains(&"--network=container:drgnx-px-0a1b2c3d-x1a".to_string()));
        assert!(
            a.windows(2)
                .any(|w| w == ["-v", "/d/jobs/x1a/drgnx-key:/run/drgnx/key:ro,Z"])
        );
        assert!(!a.iter().any(|s| s.contains("PROXY")), "{a:?}");
        let image = a.iter().position(|s| s == REF).unwrap();
        assert_eq!(a[image - 2..image], ["--entrypoint", "/run/drgnx/key"]);
        assert_eq!(
            a[image + 1..],
            ["exec", "CRATES_IO=CRATES_IO", "--", "make", "publish"]
        );
        let none = Caps {
            proxy: None,
            ..caps()
        };
        assert!(local(&r, &none).unwrap_err().message.contains("keys"));
        // a runner's sidecar is never joined here
        assert!(local(&r, &rcaps()).is_err());
    }

    /// [D] No job, keyed or not, here or on a runner, carries a label override.
    #[test]
    fn no_job_carries_a_label_override() {
        let mut r = runner_req(&["ls"]);
        r.keys = None;
        for a in [
            on_runner(&runner_req(&["ls"]), &rcaps()).unwrap(),
            on_runner(&r, &caps()).unwrap(),
            local(&req(&["ls"]), &caps()).unwrap(),
        ] {
            assert!(!a.iter().any(|s| s.starts_with("label=")), "{a:?}");
        }
    }

    fn strs(v: Vec<OsString>) -> Vec<String> {
        v.into_iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect()
    }

    fn local(r: &ContainerReq, c: &Caps) -> Result<Vec<String>, Refusal> {
        argv(r, c, &RunnerArgs::local(TAG)).map(strs)
    }

    fn on_runner(r: &ContainerReq, c: &Caps) -> Result<Vec<String>, Refusal> {
        argv(
            r,
            c,
            &RunnerArgs::runner("drgnx-run", "hub1", "drgnx-runner-work-x1a.slice"),
        )
        .map(strs)
    }

    /// [D]
    #[test]
    fn argv_has_exactly_the_fixed_flags() {
        let a = local(&req(&["make", "test"]), &caps()).unwrap();
        let want: Vec<String> = [
            "run",
            "--rm",
            "--name",
            "drgnx-job-x1a",
            "--pull=never",
            "--userns=keep-id",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
            "--read-only",
            "--tmpfs",
            "/tmp",
            "--pids-limit",
            "512",
            "--memory",
            "4G",
            "--memory-swap",
            "4G",
            "--cpus",
            "2",
            "--oom-score-adj=1000",
            "--cgroup-conf=memory.oom.group=1",
            "--label",
            "drgnx.owner=0a1b2c3d",
            "--label",
            "drgnx.job=x1a",
            "--network=none",
            "-e",
            "GIT_NO_LAZY_FETCH=1",
            "-e",
            "DRGNX_JOB_DEADLINE",
            "-v",
            "/work/tree:/work:Z",
            "-w",
            "/work",
            REF,
            "make",
            "test",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(a, want);
        // on a runner: the slice, the label and the runner's name, and nothing else changes before the mounts
        let r = on_runner(&req(&["make", "test"]), &caps()).unwrap();
        let at = r.iter().position(|s| s == "--network=none").unwrap();
        let mut head = want[..21].to_vec();
        head[3] = "drgnx-run-x1a".into();
        head.extend(
            [
                "--cgroup-parent=drgnx-runner-work-x1a.slice",
                "--label",
                "drgnx.runner=hub1",
                "--label",
                "drgnx.job=x1a",
            ]
            .map(String::from),
        );
        assert_eq!(r[..at], head[..]);
    }

    /// [D] `--memory-swap` is always `--memory`: a job never swaps (a keyed job's secret never reaches swap).
    #[test]
    fn swap_equals_memory() {
        for m in ["512M", "4G", "1T"] {
            let c = Caps {
                memory: m.into(),
                ..caps()
            };
            for a in [
                local(&req(&["ls"]), &c).unwrap(),
                on_runner(
                    &runner_req(&["ls"]),
                    &Caps {
                        memory: m.into(),
                        ..rcaps()
                    },
                )
                .unwrap(),
            ] {
                assert!(a.windows(2).any(|w| w == ["--memory", m]));
                assert!(a.windows(2).any(|w| w == ["--memory-swap", m]));
                assert_eq!(a.iter().filter(|s| s.starts_with("--memory")).count(), 2);
            }
        }
        // a limit podman would misread is refused
        for bad in ["", "0G", "4G --privileged", "G", "4GG"] {
            assert!(
                local(
                    &req(&["ls"]),
                    &Caps {
                        memory: bad.into(),
                        ..caps()
                    }
                )
                .is_err(),
                "{bad:?}"
            );
        }
    }

    fn with_feature(f: Feature, allowed: &[Feature]) -> Result<Vec<String>, Refusal> {
        let mut r = req(&["ls"]);
        r.features = vec![f];
        let mut ra = RunnerArgs::local(TAG);
        ra.allowed = allowed.to_vec();
        ra.render_node = Some("/dev/dri/renderD128".into());
        argv(&r, &caps(), &ra).map(strs)
    }

    /// [D] pure: each opt-in feature a runner allows becomes its podman argument; the same feature not allowed is
    /// refused, and so is one for a node that is not a render node.
    #[test]
    fn a_feature_maps_when_allowed_and_is_refused_otherwise() {
        for (f, arg) in [
            (Feature::Sandbox, "--security-opt=unmask=ALL"),
            (Feature::Udmabuf, "--device=/dev/udmabuf"),
            (Feature::Render, "--device=/dev/dri/renderD128"),
            (Feature::Kvm, "--device=/dev/kvm"),
        ] {
            let a = with_feature(f, &[f]).unwrap();
            assert!(a.iter().any(|s| s == arg), "{f:?}: {a:?}");
            let e = with_feature(f, &[]).unwrap_err();
            assert!(e.message.contains(f.name()), "{e:?}");
            // another feature's allowance is no allowance
            let other = if f == Feature::Kvm {
                Feature::Sandbox
            } else {
                Feature::Kvm
            };
            assert!(with_feature(f, &[other]).is_err(), "{f:?}");
        }
        let mut r = req(&["ls"]);
        r.features = vec![Feature::Render];
        let mut ra = RunnerArgs::local(TAG);
        ra.allowed = vec![Feature::Render];
        for bad in [
            None,
            Some("/dev/sda"),
            Some("/dev/dri/renderD1 --privileged"),
        ] {
            ra.render_node = bad.map(str::to_string);
            assert!(argv(&r, &caps(), &ra).is_err(), "{bad:?}");
        }
        assert_eq!(Feature::parse("udmabuf"), Some(Feature::Udmabuf));
        assert_eq!(Feature::parse("gpu"), None);
        for f in [Feature::BuildNet, Feature::Sandbox] {
            assert_eq!(Feature::parse(f.name()), Some(f));
        }
    }

    /// [D] pure: the hub's rows allow a project its own features and every project's `*` rows; `kvm` for one project
    /// also needs the runner's own list naming it.
    #[test]
    fn a_runner_allows_what_the_hub_and_its_own_config_both_say() {
        let rows = |v: &[(&str, Feature)]| -> Vec<(String, Feature)> {
            v.iter().map(|(p, f)| (p.to_string(), *f)).collect()
        };
        let own = |v: &[&str]| -> Vec<String> { v.iter().map(|s| s.to_string()).collect() };
        let r = rows(&[
            ("a", Feature::Render),
            ("b", Feature::Sandbox),
            ("a", Feature::Kvm),
        ]);
        assert_eq!(allowed_for("a", &r, &[]), [Feature::Render]);
        assert_eq!(allowed_for("a", &r, &own(&["b"])), [Feature::Render]);
        assert_eq!(
            allowed_for("a", &r, &own(&["a"])),
            [Feature::Render, Feature::Kvm]
        );
        assert_eq!(allowed_for("c", &r, &own(&["c"])), []);
        // a `mine` runner's kvm for every project needs nothing of the runner's
        assert_eq!(
            allowed_for("c", &rows(&[("*", Feature::Kvm)]), &[]),
            [Feature::Kvm]
        );
    }

    /// [D] pure: `runner.conf` names the projects that may have kvm; other lines, sections and bad names are ignored.
    #[test]
    fn the_runner_conf_lists_the_kvm_projects() {
        let t = "# a runner\n[other]\nkvm = [\"x\"]\n[features]\nkvm = [\"a\", \"b-1\" , \"bad name\", \"\"]\n";
        assert_eq!(kvm_projects(t), ["a", "b-1"]);
        assert!(kvm_projects("[features]\nrender = [\"a\"]\n").is_empty());
        assert!(kvm_projects("").is_empty());
    }

    /// [D] pure: the network feature belongs to an artifact build; a container job that names it is refused even
    /// when allowed, and a job that names no feature gets no device and no unmask.
    #[test]
    fn build_net_is_never_a_container_job_feature() {
        assert!(with_feature(Feature::BuildNet, &[Feature::BuildNet]).is_err());
        let a = local(&req(&["ls"]), &caps()).unwrap();
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--device") || s.contains("unmask"))
        );
    }

    /// [D] Locally the worktree is the one mount.
    #[test]
    fn only_the_worktree_is_mounted() {
        let a = local(&req(&["ls"]), &caps()).unwrap();
        assert_eq!(a.iter().filter(|s| *s == "-v").count(), 1);
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--mount") || s.starts_with("--volume"))
        );
        assert!(
            !a.iter()
                .any(|s| s == "--privileged" || s.starts_with("--device"))
        );
        for bad in ["/a:/etc:rw", "/a,b", "rel/path"] {
            let mut r = req(&["ls"]);
            r.worktree = bad.into();
            assert!(local(&r, &caps()).is_err(), "{bad}");
        }
    }

    /// [D] (Task 10) No argv the builder makes names a build tool's job count: `{jobs}` and the jobserver size a job's
    /// parallelism, never an env var of the argv builder's own.
    #[test]
    fn no_cargo_env_in_any_argv() {
        let mut served = runner_req(&["make"]);
        let m = served.runner.as_mut().unwrap();
        m.git_ro = Some("/r/jobs/x1a.1/git".into());
        m.jobserver = Some("/r/jobserver/pool".into());
        for a in [
            on_runner(&served, &rcaps()).unwrap(),
            on_runner(&runner_req(&["make"]), &rcaps()).unwrap(),
            local(&req(&["make"]), &caps()).unwrap(),
        ] {
            assert!(!a.iter().any(|s| s.contains("CARGO_BUILD_JOBS")), "{a:?}");
        }
    }

    /// [D] (Task 9) A job without `git = "ro"` sees no git dir: no mount and no `GIT_DIR` or `GIT_WORK_TREE`, and the
    /// slot itself holds no `.git`; the job asks for one only through its pack.
    #[test]
    fn a_job_without_git_ro_sees_no_git_dir() {
        let a = on_runner(&runner_req(&["make"]), &rcaps()).unwrap();
        assert!(!a.iter().any(|s| s.contains(GIT_DIR_INSIDE)), "{a:?}");
        assert!(
            !a.iter()
                .any(|s| s.starts_with("GIT_DIR") || s.starts_with("GIT_WORK_TREE")),
            "{a:?}"
        );
        // every job stops a lazy fetch from reaching out through a git dir it was given
        assert!(
            a.windows(2).any(|w| w == ["-e", "GIT_NO_LAZY_FETCH=1"]),
            "{a:?}"
        );
    }

    /// [D] (Task 9) A `git = "ro"` job gets its git dir read-only and `GIT_DIR`, `GIT_WORK_TREE` naming it and the
    /// source; no other mount changes.
    #[test]
    fn a_git_ro_dir_is_mounted_read_only() {
        let mut r = runner_req(&["git", "describe"]);
        r.runner.as_mut().unwrap().git_ro = Some("/r/jobs/x1a.1/git".into());
        let a = on_runner(&r, &rcaps()).unwrap();
        assert!(
            a.windows(2)
                .any(|w| w == ["-v", "/r/jobs/x1a.1/git:/gitdir:ro,z"]),
            "{a:?}"
        );
        assert!(
            a.windows(2).any(|w| w == ["-e", "GIT_DIR=/gitdir"]),
            "{a:?}"
        );
        assert!(
            a.windows(2).any(|w| w == ["-e", "GIT_WORK_TREE=/work"]),
            "{a:?}"
        );
        // a path podman would read as more than one value is refused
        r.runner.as_mut().unwrap().git_ro = Some("/r/jobs/x1a.1/git:rw".into());
        assert!(on_runner(&r, &rcaps()).is_err());
    }

    /// [D] (Task 10a) A job that takes part in the jobserver gets the fifo and the flags that name it, and no other
    /// job does.
    #[test]
    fn a_jobserver_job_gets_the_fifo_and_makeflags() {
        let mut r = runner_req(&["make"]);
        r.runner.as_mut().unwrap().jobserver = Some("/r/jobserver/pool".into());
        let a = on_runner(&r, &rcaps()).unwrap();
        assert!(
            a.windows(2)
                .any(|w| w == ["-v", "/r/jobserver/pool:/jobserver:rw,Z"]),
            "{a:?}"
        );
        for var in ["MAKEFLAGS", "CARGO_MAKEFLAGS"] {
            assert!(
                a.windows(2)
                    .any(|w| w == ["-e", &format!("{var}=--jobserver-auth=fifo:/jobserver")]),
                "{var}: {a:?}"
            );
        }
        let none = on_runner(&runner_req(&["make"]), &rcaps()).unwrap();
        assert!(!none.iter().any(|s| s.contains("jobserver")), "{none:?}");
    }

    /// [D] A runner job's mounts are exactly the design's set: the source `ro,z` (`rw,Z` for a private copy), the
    /// target, each cache, the key socket and helper; a grant adds no mount. No other `-v`.
    #[test]
    fn runner_argv_mounts_exactly_the_set() {
        let mounts = |a: &[String]| -> Vec<String> {
            a.windows(2)
                .filter(|w| w[0] == "-v")
                .map(|w| w[1].clone())
                .collect()
        };
        let a = on_runner(&runner_req(&["make"]), &rcaps()).unwrap();
        assert_eq!(
            mounts(&a),
            [
                "/r/slots/k1:/work:ro,z",
                "/r/slots/k1-target:/target:rw,Z",
                "/r/cache/p/public/cargo:/cache/cargo:rw,Z",
                "/r/bin/0.1.0/drgnx-key:/run/drgnx/key:ro,Z",
            ]
        );
        assert!(
            a.windows(2)
                .any(|w| w == ["-e", "CARGO_TARGET_DIR=/target"])
        );
        // the job's deadline passes through from job-exec's environment (design §5.7)
        assert!(
            a.windows(2).any(|w| w == ["-e", "DRGNX_JOB_DEADLINE"]),
            "{a:?}"
        );
        assert!(!a.iter().any(|s| s.starts_with("--mount")
            || s.starts_with("--volume")
            || s.starts_with("--device")));
        // a writer gets its private copy read-write; no keys, no caches: those mounts go
        let mut r = runner_req(&["make"]);
        let m = r.runner.as_mut().unwrap();
        m.writes_tree = true;
        m.caches.clear();
        r.keys = None;
        r.net = true;
        let a = on_runner(&r, &rcaps()).unwrap();
        assert_eq!(
            mounts(&a),
            ["/r/slots/k1:/work:rw,Z", "/r/slots/k1-target:/target:rw,Z"]
        );
        // a cache that would shadow the source, the target or our sockets, or climb out, is refused
        for inside in [
            "/work",
            "/work/x",
            "/target",
            "/run/drgnx/x",
            "cache",
            "/a/../work",
            "/a:b",
            "/tmp",
        ] {
            let mut r = runner_req(&["make"]);
            r.runner.as_mut().unwrap().caches[0].inside = inside.into();
            assert!(on_runner(&r, &rcaps()).is_err(), "{inside}");
        }
        // a slice or hub id podman would read as more than one value is refused (unkeyed: no sidecar name to match)
        let mut unkeyed = runner_req(&["ls"]);
        unkeyed.keys = None;
        for (slice, hub) in [
            ("x.slice --privileged", "h"),
            ("x", "h"),
            ("x.slice", "h,i"),
            ("x.slice", "-h"),
        ] {
            assert!(
                argv(
                    &unkeyed,
                    &caps(),
                    &RunnerArgs::runner("drgnx-run", hub, slice)
                )
                .is_err(),
                "{slice} {hub}"
            );
        }
    }

    /// [D]
    #[test]
    fn image_off_the_list_refused() {
        let mut r = req(&["ls"]);
        r.image = "evil".into();
        let e = local(&r, &caps()).unwrap_err();
        assert!(
            e.message.contains("agents-container-images"),
            "{}",
            e.message
        );
        r.image = REF.into();
        assert!(local(&r, &caps()).is_err());
        let mut c = caps();
        c.images[0].image = "registry.example/tools:latest".into();
        assert!(local(&req(&["ls"]), &c).is_err());
        assert!(
            local(
                &req(&["ls"]),
                &Caps {
                    images: vec![],
                    ..caps()
                }
            )
            .is_err()
        );
    }

    /// [D] What follows the image is the job's command, and never a podman option, local or on a runner.
    #[test]
    fn argv_after_the_image_never_reaches_podman_options() {
        let nasty = ["--privileged", "-v", "/:/host", "--network=host", "--rm"];
        for (a, mounts) in [
            (local(&req(&nasty), &caps()).unwrap(), 1),
            (on_runner(&runner_req(&nasty), &rcaps()).unwrap(), 4),
        ] {
            let at = a.iter().position(|s| s == REF).unwrap();
            assert_eq!(a[at + 1..], nasty.map(String::from));
            assert!(
                a[..at]
                    .iter()
                    .all(|s| !s.contains("host") && s != "--privileged")
            );
            assert_eq!(a[..at].iter().filter(|s| *s == "-v").count(), mounts);
        }
        assert!(local(&req(&[]), &caps()).is_err());
    }

    /// [D]
    #[test]
    fn network_none_unless_granted() {
        let a = local(&req(&["ls"]), &caps()).unwrap();
        assert!(a.contains(&"--network=none".to_string()));
        let mut r = req(&["ls"]);
        r.net = true;
        let a = local(&r, &caps()).unwrap();
        assert!(a.contains(&"--network=container:drgnx-px-0a1b2c3d-x1a".to_string()));
        assert!(!a.contains(&"--network=none".to_string()));
        assert_eq!(a.iter().filter(|s| s.starts_with("--network")).count(), 1);
        // a sidecar that is not this job's own is never joined: another job's, another hub's, a host network
        for other in ["drgnx-px-0a1b2c3d-x1b", "drgnx-px-ffffffff-x1a", "host", ""] {
            let c = Caps {
                proxy: Some(JobNet {
                    sidecar: other.into(),
                }),
                ..caps()
            };
            assert!(local(&r, &c).is_err(), "{other:?}");
        }
        // a grant with no proxy is refused, never turned into the host's network
        assert!(
            local(
                &r,
                &Caps {
                    proxy: None,
                    ..caps()
                }
            )
            .is_err()
        );
    }

    /// The flags of a networked job in order, for NAME, the labels and the sidecar it joins.
    fn networked(name: &str, between: &[&str], labels: [&str; 2], sidecar: &str) -> Vec<String> {
        let mut v: Vec<&str> = vec![
            "run",
            "--rm",
            "--name",
            name,
            "--pull=never",
            "--userns=keep-id",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
            "--read-only",
            "--tmpfs",
            "/tmp",
            "--pids-limit",
            "512",
            "--memory",
            "4G",
            "--memory-swap",
            "4G",
            "--cpus",
            "2",
            "--oom-score-adj=1000",
            "--cgroup-conf=memory.oom.group=1",
        ];
        v.extend(between);
        v.extend(["--label", labels[0], "--label", labels[1]]);
        let net = format!("--network=container:{sidecar}");
        v.push(&net);
        v.extend([
            "-e",
            "GIT_NO_LAZY_FETCH=1",
            "-e",
            "DRGNX_JOB_DEADLINE",
            "-v",
            "/work/tree:/work:Z",
            "-w",
            "/work",
            "-e",
            "HTTP_PROXY=http://127.0.0.1:3128",
            "-e",
            "HTTPS_PROXY=http://127.0.0.1:3128",
            "-e",
            "http_proxy=http://127.0.0.1:3128",
            "-e",
            "https_proxy=http://127.0.0.1:3128",
            "-e",
            "NO_PROXY=localhost,127.0.0.1,::1",
            "-e",
            "no_proxy=localhost,127.0.0.1,::1",
            REF,
            "ls",
            "-l",
        ]);
        v.iter().map(|s| s.to_string()).collect()
    }

    /// [D] A job granted network joins its sidecar's namespace and nothing else changes: no `--dns`, no `--sysctl`,
    /// no network mount, no entrypoint, the six proxy variables on the sidecar's loopback.
    #[test]
    fn a_networked_job_has_exactly_these_flags() {
        let mut r = req(&["ls", "-l"]);
        r.net = true;
        assert_eq!(
            local(&r, &caps()).unwrap(),
            networked(
                "drgnx-job-x1a",
                &[],
                ["drgnx.owner=0a1b2c3d", "drgnx.job=x1a"],
                "drgnx-px-0a1b2c3d-x1a"
            )
        );
        assert_eq!(
            on_runner(&r, &rcaps()).unwrap(),
            networked(
                "drgnx-run-x1a",
                &["--cgroup-parent=drgnx-runner-work-x1a.slice"],
                ["drgnx.runner=hub1", "drgnx.job=x1a"],
                "drgnx-run-px-x1a"
            )
        );
        let a = local(&r, &caps()).unwrap();
        for never in [
            "--dns",
            "--dns=none",
            "--add-host",
            "--entrypoint",
            "--sysctl",
        ] {
            assert!(!a.iter().any(|s| s.starts_with(never)), "{never}");
        }
    }

    /// [D] A job without a grant is today's argv, plus the owner's labels, whether or not caps hold a sidecar.
    #[test]
    fn a_job_without_network_is_unchanged() {
        let a = local(&req(&["ls", "-l"]), &caps()).unwrap();
        let none = Caps {
            proxy: None,
            ..caps()
        };
        assert_eq!(a, local(&req(&["ls", "-l"]), &none).unwrap());
        let mut want = networked(
            "drgnx-job-x1a",
            &[],
            ["drgnx.owner=0a1b2c3d", "drgnx.job=x1a"],
            "unused",
        );
        // the proxy variables go, each with its `-e`
        let proxy = |s: &String| s.contains("PROXY") || s.contains("_proxy");
        let mut i = 0;
        while i + 1 < want.len() {
            if want[i] == "-e" && proxy(&want[i + 1]) {
                want.drain(i..i + 2);
            } else {
                i += 1;
            }
        }
        let at = want
            .iter()
            .position(|s| s.starts_with("--network"))
            .unwrap();
        want[at] = "--network=none".into();
        assert_eq!(a, want);
        // without job labels: exactly the argv from before the relay
        let mut ra = RunnerArgs::local(TAG);
        ra.job_labels = false;
        let b = argv(&req(&["ls", "-l"]), &none, &ra).map(strs).unwrap();
        assert!(!b.iter().any(|s| s.starts_with("drgnx.")));
        // no labels and no deadline
        assert_eq!(b.len() + 6, a.len());
    }

    /// [D] The proxy variables never exempt the reserved name the host's grants use: that name goes through the proxy.
    #[test]
    fn no_proxy_never_names_the_reserved_host() {
        let mut r = req(&["ls"]);
        r.net = true;
        for a in [
            local(&r, &caps()).unwrap(),
            on_runner(&r, &rcaps()).unwrap(),
        ] {
            let vars: Vec<&String> = a
                .iter()
                .filter(|s| s.starts_with("NO_PROXY=") || s.starts_with("no_proxy="))
                .collect();
            assert_eq!(vars.len(), 2);
            for v in vars {
                assert!(!v.contains("host.drgnx.internal"), "{v}");
                assert_eq!(v.split_once('=').unwrap().1, "localhost,127.0.0.1,::1");
            }
        }
    }

    /// [D] A keyed job granted network still runs `drgnx-key` as the entrypoint: nothing else sits before it.
    #[test]
    fn a_keyed_networked_job_keeps_drgnx_key_as_entrypoint() {
        let mut r = runner_req(&["cargo", "publish"]);
        r.keys.as_mut().unwrap().vars = vec![("CRATES_IO".into(), "CARGO_REGISTRY_TOKEN".into())];
        r.net = true;
        let a = on_runner(&r, &rcaps()).unwrap();
        let image = a.iter().position(|s| s == REF).unwrap();
        assert_eq!(a[image - 2..image], ["--entrypoint", "/run/drgnx/key"]);
        assert_eq!(a.iter().filter(|s| *s == "--entrypoint").count(), 1);
        assert_eq!(
            a[image + 1..],
            [
                "exec",
                "CRATES_IO=CARGO_REGISTRY_TOKEN",
                "--",
                "cargo",
                "publish"
            ]
        );
        assert!(a.contains(&"--network=container:drgnx-run-px-x1a".to_string()));
    }

    fn sidecar(ra: &RunnerArgs, job: &str) -> Result<Vec<String>, Refusal> {
        let n = net_names(ra, job)?;
        sidecar_argv(&n, ra, "localhost/drgnx-px:0123456789abcdef", false).map(strs)
    }

    /// [D] The sidecar: attached, no tty, the detach keys off (a one-byte read of the default sequence must not detach
    /// the channel), `nobody` in podman's own user namespace (no `keep-id`), no network at all, nothing mounted.
    #[test]
    fn the_sidecar_has_exactly_these_flags() {
        let tail = |name: &str| -> Vec<String> {
            [
                "--network=none",
                "--name",
                name,
                "localhost/drgnx-px:0123456789abcdef",
                "--listen",
                "127.0.0.1:3128",
                "--job-ip",
                "127.0.0.1",
            ]
            .map(String::from)
            .to_vec()
        };
        let head: Vec<String> = [
            "run",
            "-i",
            "--rm",
            "--pull=never",
            "--log-driver=none",
            "--detach-keys=",
            "--user",
            "65534:65534",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
            "--read-only",
            "--pids-limit",
            "32",
            "--memory",
            "128m",
            "--memory-swap",
            "128m",
            "--cpus",
            "1",
            "--ulimit",
            "core=1",
        ]
        .map(String::from)
        .to_vec();
        let want = |mid: &[&str], name: &str| -> Vec<String> {
            let mut v = head.clone();
            v.extend(mid.iter().map(|s| s.to_string()));
            v.extend(tail(name));
            v
        };
        assert_eq!(
            sidecar(&RunnerArgs::local(TAG), "x1a").unwrap(),
            want(
                &[
                    "--label",
                    "drgnx.owner=0a1b2c3d",
                    "--label",
                    "drgnx.job=x1a"
                ],
                "drgnx-px-0a1b2c3d-x1a"
            )
        );
        assert_eq!(
            sidecar(
                &RunnerArgs::runner("drgnx-run", "hub1", "drgnx-runner-work-x1a.slice"),
                "x1a"
            )
            .unwrap(),
            want(
                &[
                    "--cgroup-parent=drgnx-runner-work-x1a.slice",
                    "--label",
                    "drgnx.runner=hub1",
                    "--label",
                    "drgnx.job=x1a"
                ],
                "drgnx-run-px-x1a"
            )
        );
        let a = sidecar(&RunnerArgs::local(TAG), "x1a").unwrap();
        for never in [
            "-t",
            "--tty",
            "--userns=keep-id",
            "-v",
            "--dns",
            "--sysctl",
            "--entrypoint",
        ] {
            assert!(
                !a.iter().any(|s| s == never || s.starts_with(never)),
                "{never}"
            );
        }
        // an image podman would read as an option is refused
        let ra = RunnerArgs::local(TAG);
        let n = net_names(&ra, "x1a").unwrap();
        for bad in ["", "-v", "a b"] {
            assert!(sidecar_argv(&n, &ra, bad, false).is_err(), "{bad:?}");
        }
        // a keyed job's sidecar also takes its keys' listener: `--keys`, last
        let k = strs(sidecar_argv(&n, &ra, "localhost/drgnx-px:0123456789abcdef", true).unwrap());
        let mut plain = a.clone();
        plain.extend(["--keys".into(), KEY_NAME.into()]);
        assert_eq!(k, plain);
    }

    /// [D] The laptop is a hub and a runner at once, with jobs of the same id: no container name is shared, and a
    /// runner whose prefix would reach the hub's names or another runner's sidecars is refused.
    #[test]
    fn hub_and_runner_names_never_collide() {
        let hub = RunnerArgs::local(TAG);
        let run = RunnerArgs::runner("drgnx-run", "h1", "drgnx-runner-work-x1.slice");
        let mut names = vec![
            name_of(&hub.name_prefix, "x1").unwrap(),
            net_names(&hub, "x1").unwrap().sidecar,
            name_of(&run.name_prefix, "x1").unwrap(),
            net_names(&run, "x1").unwrap().sidecar,
        ];
        assert_eq!(
            names,
            [
                "drgnx-job-x1",
                "drgnx-px-0a1b2c3d-x1",
                "drgnx-run-x1",
                "drgnx-run-px-x1"
            ]
        );
        names.sort();
        names.dedup();
        assert_eq!(names.len(), 4);
        // two hubs differ by tag
        assert_ne!(
            net_names(&hub, "x1").unwrap().sidecar,
            net_names(&RunnerArgs::local("ffffffff"), "x1")
                .unwrap()
                .sidecar
        );
        // the labels tell hub and runner apart
        assert_eq!(
            net_names(&hub, "x1").unwrap().labels,
            ["drgnx.owner=0a1b2c3d", "drgnx.job=x1"]
        );
        assert_eq!(
            net_names(&run, "x1").unwrap().labels,
            ["drgnx.runner=h1", "drgnx.job=x1"]
        );
        // prefixes that would make a runner's names the hub's, or another runner's sidecars
        for prefix in ["drgnx-job", "drgnx-px-0a1b2c3d", "drgnx-run-px", "px"] {
            let ra = RunnerArgs::runner(prefix, "h1", "s.slice");
            assert!(net_names(&ra, "x1").is_err(), "{prefix}");
        }
        // a job id or an owner podman would read as more than a name
        assert!(net_names(&hub, "x 1").is_err());
        assert!(net_names(&RunnerArgs::local("a b"), "x1").is_err());
        assert!(net_names(&RunnerArgs::local("-a"), "x1").is_err());
    }

    /// [D]
    #[test]
    fn the_name_is_the_prefix_and_a_plain_id() {
        assert_eq!(name_of(LOCAL_PREFIX, "x1a2").unwrap(), "drgnx-job-x1a2");
        assert_eq!(name_of("bld-run-", "x1").unwrap(), "bld-run-x1");
        for bad in ["", "a b", "a/b", "-rm", "a,b"] {
            assert!(name_of(LOCAL_PREFIX, bad).is_err(), "{bad:?}");
        }
        assert!(name_of("-x", "a").is_err());
    }

    /// [D] The caps hold only where podman reports cgroup v2, the systemd manager and the memory, pids and cpu
    /// controllers; anything else (the cgroupfs fallback with no user session above all) is refused with the reason.
    #[test]
    fn caps_hold_only_on_v2_with_systemd_and_the_controllers() {
        let info = |v: &str, m: &str, c: &[&str]| serde_json::json!({"host": {"cgroupVersion": v, "cgroupManager": m, "cgroupControllers": c}});
        let all = ["cpuset", "cpu", "io", "memory", "pids"];
        limits_enforced(&info("v2", "systemd", &all)).unwrap();
        let e = limits_enforced(&info("v2", "cgroupfs", &all)).unwrap_err();
        assert!(
            e.message().contains("cgroupfs") && e.message().contains("enable-linger"),
            "{e}"
        );
        let e = limits_enforced(&info("v1", "systemd", &all)).unwrap_err();
        assert!(e.message().contains("cgroup v1"), "{e}");
        let e = limits_enforced(&info("v2", "systemd", &["cpu", "memory"])).unwrap_err();
        assert!(e.message().contains("pids"), "{e}");
        assert!(limits_enforced(&serde_json::json!({})).is_err());
    }

    /// [D]
    #[test]
    fn podman_info_that_fails_refuses_the_job() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("podman");
        hlaup::write(&p, "#!/bin/sh\necho 'no session' >&2; exit 125\n").unwrap();
        let e = check_limits(&p, &[], Duration::from_secs(10)).unwrap_err();
        assert!(
            e.message().contains("no session") && e.message().contains("refused"),
            "{e}"
        );
    }
}
