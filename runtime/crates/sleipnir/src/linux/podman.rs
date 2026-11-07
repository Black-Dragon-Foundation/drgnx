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
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

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
/// Where the key socket and `drgnx-key` appear.
pub const KEY_SOCKET: &str = "/run/drgnx/key.sock";
pub const KEY_HELPER: &str = "/run/drgnx/key";
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
    /// The relay sidecar a job that was granted network shares its network namespace with; none: a grant is refused.
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
    /// A runner job's mounts besides the source; none: a local job.
    pub runner: Option<RunnerMounts>,
}

/// A runner job's mount set, exactly: the source `ro,z` (`rw,Z` for a `writes_tree` copy), the slot's
/// target dir `rw,Z`, one mount per declared cache `rw,Z`, and the key socket and `drgnx-key` `ro,Z`. Nothing else.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerMounts {
    /// The source is the job's private copy, which it may write.
    pub writes_tree: bool,
    /// The slot's target dir.
    pub target: PathBuf,
    pub caches: Vec<CacheMount>,
    pub keys: Option<KeyMounts>,
}

/// A cache the job's suite declares: a folder under the runner's `cache/<project>/<trust>/`, at its path inside.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheMount {
    pub host: PathBuf,
    pub inside: String,
}

/// The job's key socket and its own copy of the `drgnx-key` binary on the host, and the keys it reads: each
/// `(key name, variable)`. The command then runs as `drgnx-key exec NAME=VAR… -- CMD`, so podman's argv and stored
/// config hold the names only, never a value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyMounts {
    pub socket: PathBuf,
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
}

impl RunnerArgs {
    /// The hub's own container jobs: `drgnx-job-<id>`, no parent slice, labelled with OWNER_TAG.
    pub fn local(owner_tag: &str) -> RunnerArgs {
        RunnerArgs {
            cgroup_parent: None,
            label: None,
            name_prefix: LOCAL_PREFIX.to_string(),
            owner: owner_tag.to_string(),
            job_labels: true,
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
/// all, the loopback its job shares, and nothing but the relay's flags after the image.
pub fn sidecar_argv(n: &NetNames, ra: &RunnerArgs, image: &str) -> Result<Vec<OsString>, Refusal> {
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
    let sidecar = match req.net {
        false => None,
        true => {
            let p = caps.proxy.as_ref().ok_or_else(|| {
                refuse("this job was granted network access, but it has no proxy to go through")
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
    a.push(
        match sidecar {
            Some(s) => format!("--network=container:{s}"),
            None => "--network=none".to_string(),
        }
        .into(),
    );
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
            if let Some(k) = &m.keys {
                a.push("-v".into());
                a.push(format!("{}:{KEY_SOCKET}:ro,Z", mount_source(&k.socket)?).into());
                a.push("-v".into());
                a.push(format!("{}:{KEY_HELPER}:ro,Z", mount_source(&k.helper)?).into());
            }
        }
    }
    a.push("-w".into());
    a.push(if req.subdir.as_os_str().is_empty() {
        OsString::from(WORK)
    } else {
        Path::new(WORK).join(&req.subdir).into_os_string()
    });
    if sidecar.is_some() {
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
    let keyed: Vec<OsString> = match req.runner.as_ref().and_then(|m| m.keys.as_ref()) {
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
) -> Result<Output, String> {
    let mut child = Command::new(podman)
        .args(args)
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("podman: {e}"))?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().map_err(|e| format!("podman: {e}")),
            Ok(None) if start.elapsed() < limit => std::thread::sleep(Duration::from_millis(25)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "podman {} took longer than {}s; the job is refused",
                    args.first().copied().unwrap_or(""),
                    limit.as_secs()
                ));
            }
            Err(e) => return Err(format!("podman: {e}")),
        }
    }
}

/// The cgroup controllers a job's caps use: `--memory`, `--pids-limit`, `--cpus`.
pub const CONTROLLERS: [&str; 3] = ["memory", "pids", "cpu"];

/// Whether the podman that `podman info --format json` described (INFO) enforces a job's caps; the reason when it
/// does not. Rootless podman applies limits only on cgroup v2 through the systemd cgroup manager, with the controllers
/// delegated to the user. Without a systemd user session it falls back to `cgroupfs`, where a rootless container may
/// get no cgroup of its own and its limits are dropped with no more than a warning.
pub fn limits_enforced(info: &serde_json::Value) -> Result<(), String> {
    let host = &info["host"];
    let version = host["cgroupVersion"].as_str().unwrap_or("unknown");
    let manager = host["cgroupManager"].as_str().unwrap_or("unknown");
    if version != "v2" {
        return Err(format!(
            "podman runs on cgroup {version}, and the caps need cgroup v2"
        ));
    }
    if manager != "systemd" {
        return Err(format!(
            "podman's cgroup manager is {manager}, which cannot enforce a rootless container's caps: \
             it needs a systemd user session (log in, or `loginctl enable-linger`) and the hub its \
             XDG_RUNTIME_DIR or DBUS_SESSION_BUS_ADDRESS"
        ));
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
        return Err(format!(
            "the cgroup controllers {} are not delegated to this user, so podman cannot enforce the caps",
            missing.join(", ")
        ));
    }
    Ok(())
}

/// The reason container jobs are refused here unless PODMAN (run with ENV) enforces their caps
/// ([`limits_enforced`]), asked within LIMIT.
pub fn check_limits(
    podman: &Path,
    env: &[(OsString, OsString)],
    limit: Duration,
) -> Result<(), String> {
    let refused = |m: String| format!("container jobs are refused here: {m}");
    let out = run_limited(podman, &["info", "--format", "json"], env, limit)?;
    if !out.status.success() {
        return Err(refused(format!(
            "podman info failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let info: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| refused(format!("podman info is not JSON: {e}")))?;
    limits_enforced(&info).map_err(refused)
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
            image: "tools".into(),
            argv: argv.iter().map(|s| s.to_string()).collect(),
            worktree: "/work/tree".into(),
            subdir: PathBuf::new(),
            job: "x1a".into(),
            net: false,
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
                keys: Some(KeyMounts {
                    socket: "/r/jobs/x1a.1/key.sock".into(),
                    helper: "/r/bin/0.1.0/drgnx-key".into(),
                    vars: vec![],
                }),
            }),
            ..req(argv)
        }
    }

    /// [D] A keyed job's command runs as `drgnx-key exec NAME=VAR… -- CMD`: drgnx-key is the entrypoint; the argv holds
    /// the names only, and a name podman or a shell would misread is refused.
    #[test]
    fn a_keyed_job_runs_under_drgnx_key_exec_with_names_only() {
        let mut r = runner_req(&["cargo", "publish"]);
        r.runner.as_mut().unwrap().keys.as_mut().unwrap().vars = vec![
            ("CRATES_IO".into(), "CARGO_REGISTRY_TOKEN".into()),
            ("gh-token".into(), "GH_TOKEN".into()),
        ];
        let a = on_runner(&r, &caps()).unwrap();
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
            r.runner.as_mut().unwrap().keys.as_mut().unwrap().vars =
                vec![(name.into(), var.into())];
            assert!(on_runner(&r, &caps()).is_err(), "{name:?} {var:?}");
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
                on_runner(&runner_req(&["ls"]), &c).unwrap(),
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
        let a = on_runner(&runner_req(&["make"]), &caps()).unwrap();
        assert_eq!(
            mounts(&a),
            [
                "/r/slots/k1:/work:ro,z",
                "/r/slots/k1-target:/target:rw,Z",
                "/r/cache/p/public/cargo:/cache/cargo:rw,Z",
                "/r/jobs/x1a.1/key.sock:/run/drgnx/key.sock:ro,Z",
                "/r/bin/0.1.0/drgnx-key:/run/drgnx/key:ro,Z",
            ]
        );
        assert!(
            a.windows(2)
                .any(|w| w == ["-e", "CARGO_TARGET_DIR=/target"])
        );
        assert!(!a.iter().any(|s| s.starts_with("--mount")
            || s.starts_with("--volume")
            || s.starts_with("--device")));
        // a writer gets its private copy read-write; no keys, no caches: those mounts go
        let mut r = runner_req(&["make"]);
        let m = r.runner.as_mut().unwrap();
        m.writes_tree = true;
        m.keys = None;
        m.caches.clear();
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
            assert!(on_runner(&r, &caps()).is_err(), "{inside}");
        }
        // a slice or hub id podman would read as more than one value is refused
        for (slice, hub) in [
            ("x.slice --privileged", "h"),
            ("x", "h"),
            ("x.slice", "h,i"),
            ("x.slice", "-h"),
        ] {
            assert!(
                argv(
                    &runner_req(&["ls"]),
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
            (on_runner(&runner_req(&nasty), &caps()).unwrap(), 5),
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
        want.retain(|s| s != "-e" && !s.contains("PROXY") && !s.contains("_proxy"));
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
        assert_eq!(b.len() + 4, a.len());
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
        r.runner.as_mut().unwrap().keys.as_mut().unwrap().vars =
            vec![("CRATES_IO".into(), "CARGO_REGISTRY_TOKEN".into())];
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
        sidecar_argv(&n, ra, "localhost/drgnx-px:0123456789abcdef").map(strs)
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
            assert!(sidecar_argv(&n, &ra, bad).is_err(), "{bad:?}");
        }
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
        assert_eq!(limits_enforced(&info("v2", "systemd", &all)), Ok(()));
        let e = limits_enforced(&info("v2", "cgroupfs", &all)).unwrap_err();
        assert!(e.contains("cgroupfs") && e.contains("enable-linger"), "{e}");
        let e = limits_enforced(&info("v1", "systemd", &all)).unwrap_err();
        assert!(e.contains("cgroup v1"), "{e}");
        let e = limits_enforced(&info("v2", "systemd", &["cpu", "memory"])).unwrap_err();
        assert!(e.contains("pids"), "{e}");
        assert!(limits_enforced(&serde_json::json!({})).is_err());
    }

    /// [D]
    #[test]
    fn podman_info_that_fails_refuses_the_job() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("podman");
        std::fs::write(&p, "#!/bin/sh\necho 'no session' >&2; exit 125\n").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        let e = check_limits(&p, &[], Duration::from_secs(10)).unwrap_err();
        assert!(e.contains("no session") && e.contains("refused"), "{e}");
    }
}
