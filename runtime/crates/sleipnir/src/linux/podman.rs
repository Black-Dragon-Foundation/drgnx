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
/// Where the proxy socket and the forwarder appear.
pub const PROXY_SOCKET: &str = "/run/drgnx/proxy.sock";
pub const FORWARDER: &str = "/run/drgnx/fwd";
/// Where the key socket and `drgnx-key` appear.
pub const KEY_SOCKET: &str = "/run/drgnx/key.sock";
pub const KEY_HELPER: &str = "/run/drgnx/key";
/// The port the forwarder opens on the job's own loopback, in front of the proxy socket.
pub const PROXY_PORT: u16 = 3128;
/// The arguments the forwarder takes before the job's command: the port, the socket, `--`.
pub const FORWARDER_ARGS: usize = 3;
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
    /// What a job that was granted network reaches the proxy through; none: a grant is refused.
    pub proxy: Option<Proxy>,
    /// The hosts (`host:port`) a granted network reaches, by tier name.
    pub net_hosts: Vec<(String, Vec<String>)>,
}

/// A granted network is not a network: the job keeps `--network=none`, and two files are bind-mounted read-only into
/// it, the job's proxy socket and the forwarder that gives the job's own loopback a port in front of that socket.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Proxy {
    /// The job's proxy socket on the host.
    pub socket: PathBuf,
    /// The job's own copy of `drgnx-fwd` on the host.
    pub forwarder: PathBuf,
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
/// target dir `rw,Z`, one mount per declared cache `rw,Z`, the key socket and `drgnx-key` `ro,Z`, and the proxy socket
/// and `drgnx-fwd` `ro,Z` (from [`Caps::proxy`]). Nothing else.
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

/// The job's key socket and the `drgnx-key` binary on the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyMounts {
    pub socket: PathBuf,
    pub helper: PathBuf,
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
}

impl RunnerArgs {
    /// The hub's own container jobs: `drgnx-job-<id>`, no parent slice, no label.
    pub fn local() -> RunnerArgs {
        RunnerArgs {
            cgroup_parent: None,
            label: None,
            name_prefix: LOCAL_PREFIX.to_string(),
        }
    }

    /// A runner's: `<prefix>-<id>` in SLICE, labelled with HUB_ID.
    pub fn runner(prefix: &str, hub_id: &str, slice: &str) -> RunnerArgs {
        RunnerArgs {
            cgroup_parent: Some(slice.to_string()),
            label: Some(hub_id.to_string()),
            name_prefix: format!("{prefix}-"),
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
    let proxy = match req.net {
        false => None,
        true => {
            let p = caps.proxy.as_ref().ok_or_else(|| {
                refuse("this job was granted network access, but it has no proxy to go through")
            })?;
            Some((mount_source(&p.socket)?, mount_source(&p.forwarder)?))
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
        if !plain(slice) || !slice.ends_with(".slice") {
            return Err(refuse(format!(
                "the job's slice {slice:?} is not a slice name"
            )));
        }
        a.push(format!("--cgroup-parent={slice}").into());
    }
    if let Some(hub) = &ra.label {
        if !plain(hub) {
            return Err(refuse(format!("the hub id {hub:?} is not a plain name")));
        }
        a.push("--label".into());
        a.push(format!("drgnx.runner={hub}").into());
    }
    a.push("--network=none".into());
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
    if let Some((socket, forwarder)) = &proxy {
        // the socket is this job's alone (`Z`: private label); so is the forwarder, the job's own copy
        a.push("-v".into());
        a.push(format!("{socket}:{PROXY_SOCKET}:ro,Z").into());
        a.push("-v".into());
        a.push(format!("{forwarder}:{FORWARDER}:ro,Z").into());
        let url = format!("http://127.0.0.1:{PROXY_PORT}");
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            a.push("-e".into());
            a.push(format!("{k}={url}").into());
        }
        a.push("--entrypoint".into());
        a.push(FORWARDER.into());
    }
    a.push(image.into());
    if proxy.is_some() {
        // the entrypoint binds the port, then runs the command in its place
        a.push(PROXY_PORT.to_string().into());
        a.push(PROXY_SOCKET.into());
        a.push("--".into());
    }
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
            proxy: Some(Proxy {
                socket: "/run/h/job.sock".into(),
                forwarder: "/opt/drgnx-fwd".into(),
            }),
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
                }),
            }),
            ..req(argv)
        }
    }

    fn strs(v: Vec<OsString>) -> Vec<String> {
        v.into_iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect()
    }

    fn local(r: &ContainerReq, c: &Caps) -> Result<Vec<String>, Refusal> {
        argv(r, c, &RunnerArgs::local()).map(strs)
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
    /// target, each cache, the key socket and helper; the proxy pair only with a grant. No other `-v`.
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
        let a = on_runner(&r, &caps()).unwrap();
        assert_eq!(
            mounts(&a),
            [
                "/r/slots/k1:/work:rw,Z",
                "/r/slots/k1-target:/target:rw,Z",
                "/run/h/job.sock:/run/drgnx/proxy.sock:ro,Z",
                "/opt/drgnx-fwd:/run/drgnx/fwd:ro,Z",
            ]
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
        assert!(a.contains(&"--network=none".to_string()));
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--network=") && s != "--network=none")
        );
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

    /// [D]
    #[test]
    fn a_grant_adds_exactly_two_ro_mounts_the_proxy_env_and_the_entrypoint() {
        let plain = local(&req(&["ls", "-l"]), &caps()).unwrap();
        let mut r = req(&["ls", "-l"]);
        r.net = true;
        let a = local(&r, &caps()).unwrap();
        let at = plain.iter().position(|s| s == REF).unwrap();
        assert_eq!(a[..at], plain[..at]);
        let image = a.iter().position(|s| s == REF).unwrap();
        assert_eq!(image - at, 2 + 2 + 8 + 2);
        let extra = &a[at..image];
        assert_eq!(
            extra[..4],
            [
                "-v",
                "/run/h/job.sock:/run/drgnx/proxy.sock:ro,Z",
                "-v",
                "/opt/drgnx-fwd:/run/drgnx/fwd:ro,Z"
            ]
        );
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            let want = format!("{k}=http://127.0.0.1:3128");
            assert!(
                extra.windows(2).any(|w| w[0] == "-e" && w[1] == want),
                "{k}"
            );
        }
        assert_eq!(extra[12..], ["--entrypoint", "/run/drgnx/fwd"]);
        assert_eq!(
            a[image + 1..],
            ["3128", "/run/drgnx/proxy.sock", "--", "ls", "-l"]
        );
        assert_eq!(a[image + 1..].len() - 2, FORWARDER_ARGS);
        let c = Caps {
            proxy: Some(Proxy {
                socket: "/a:b/s".into(),
                forwarder: "/f".into(),
            }),
            ..caps()
        };
        assert!(local(&r, &c).is_err());
    }

    /// [D]
    #[test]
    fn no_grant_adds_no_proxy_flag() {
        let a = local(&req(&["ls"]), &caps()).unwrap();
        assert!(!a.iter().any(|s| s.contains("proxy") || s == "--entrypoint"));
        assert_eq!(a.len(), 26 + 1 + 1);
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
