//! Container jobs (Task 11b): the hub runs `podman run` from a fixed spec.
//!
//! [`argv`] is the **only** builder of a `podman run` line.  An agent's request carries an image *name* and a command;
//! everything else is fixed here or comes from settings ([`Caps`]): no capabilities, no new privileges, a read-only
//! root with a tmpfs `/tmp`, the worktree as the only mount, no network unless the matrix granted one.  The command goes
//! after the image, where podman stops reading options.  The image is the allow-list's reference pinned by digest; the
//! hub pulls it ([`ensure_image`]), the job never does (`--pull=never`).

use crate::agents::launch::NetCell;
use crate::settings::ContainerImage;
use gleipnir::{Refusal, Rule};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Where the worktree appears inside the container.
pub const WORK: &str = "/work";

/// What the settings and the hub fix for every container job.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Caps {
    /// `agents-container-images`: the only images a job may name.
    pub images: Vec<ContainerImage>,
    /// `agents-job-memory`, like `4G`.
    pub memory: String,
    /// `agents-job-cpus`.
    pub cpus: u32,
    pub pids: u32,
    /// What a job that was granted network reaches the proxy through ([`Proxy`]); none: a grant is refused.
    pub proxy: Option<Proxy>,
    /// `agents-net-hosts`: the hosts (`host:port`) a granted network reaches, by tier name.
    pub net_hosts: Vec<(String, Vec<String>)>,
}

/// A granted network is not a network: the job keeps `--network=none`, and two files are bind-mounted read-only into
/// it, the job's Gleipnir proxy socket and the forwarder ([`FORWARDER`]) that gives the job's own loopback a port in
/// front of that socket.  The only route out is the proxy, by construction.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Proxy {
    /// The job's proxy socket on the host.
    pub socket: PathBuf,
    /// The `drgnx-fwd` binary on the host.
    pub forwarder: PathBuf,
}

/// Where the proxy socket and the forwarder appear inside the container.
pub const PROXY_SOCKET: &str = "/run/drgnx/proxy.sock";
pub const FORWARDER: &str = "/run/drgnx/fwd";

/// The extra flags a granted network adds: the two mounts, the proxy variables and the forwarder as entrypoint.
#[cfg(test)]
const NET_FLAGS: usize = 2 + 2 + 8 + 2;
/// The arguments the entrypoint takes before the job's command: the port, the socket, `--`.
pub const FORWARDER_ARGS: usize = 3;

/// The process limit of a container job.
pub const PIDS: u32 = 512;

/// What a job asks: an image name from the allow-list, a command, the folder it works in, the network granted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContainerReq {
    pub image: String,
    pub argv: Vec<String>,
    pub worktree: PathBuf,
    /// The folder inside the worktree the command runs in (relative; empty: the worktree itself).
    pub subdir: PathBuf,
    /// The job's id; the container is named [`name_of`] it, so the hub can find (and remove) what a dead client left.
    pub job: String,
    /// The matrix's Network cell, when it grants one; none: no network at all.
    pub net: Option<NetCell>,
}

fn refuse(message: impl Into<String>) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: None,
        message: message.into(),
    }
}

/// What every hub-owned container is named before its job id.
pub const NAME_PREFIX: &str = "drgnx-job-";

/// How long the hub waits for an image pull before refusing the job.
pub const PULL_TIMEOUT: Duration = Duration::from_secs(600);

/// The container name of job ID (an id of `[a-z0-9]`, as the runner makes them).
pub fn name_of(id: &str) -> Result<String, Refusal> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(refuse("a container job's id is letters and digits"));
    }
    Ok(format!("{NAME_PREFIX}{id}"))
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
fn mount_source(worktree: &Path) -> Result<String, Refusal> {
    let s = worktree
        .to_str()
        .filter(|s| worktree.is_absolute() && !s.contains([':', ',', '\n', '\0']))
        .ok_or_else(|| refuse("the worktree must be an absolute path without ':' or ','"))?;
    Ok(s.to_string())
}

/// The `podman run` arguments (without the program) for REQ under CAPS.
pub fn argv(req: &ContainerReq, caps: &Caps) -> Result<Vec<OsString>, Refusal> {
    if req.argv.is_empty() || req.argv[0].is_empty() {
        return Err(refuse("a container job needs a command"));
    }
    let image = resolve(caps, &req.image)?;
    let source = mount_source(&req.worktree)?;
    let ok_memory = !caps.memory.is_empty()
        && caps.memory.trim_end_matches(['K', 'M', 'G', 'T']).len() + 1 >= caps.memory.len()
        && caps
            .memory
            .trim_end_matches(['K', 'M', 'G', 'T'])
            .bytes()
            .all(|b| b.is_ascii_digit())
        && !caps.memory.starts_with('0');
    if !ok_memory || caps.cpus == 0 || caps.pids == 0 {
        return Err(refuse(
            "agents-job-memory, agents-job-cpus: a limit that fits podman",
        ));
    }
    let proxy = match req.net {
        None => None,
        Some(_) => {
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
        &name_of(&req.job)?,
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
    a.push("--cpus".into());
    a.push(caps.cpus.to_string().into());
    a.push("--network=none".into());
    a.push("-v".into());
    a.push(format!("{source}:{WORK}:Z").into());
    a.push("-w".into());
    a.push(if req.subdir.as_os_str().is_empty() {
        OsString::from(WORK)
    } else {
        Path::new(WORK).join(&req.subdir).into_os_string()
    });
    if let Some((socket, forwarder)) = &proxy {
        // The socket is this job's alone (`Z`: private label); so is the forwarder, the job's own copy.
        a.push("-v".into());
        a.push(format!("{socket}:{PROXY_SOCKET}:ro,Z").into());
        a.push("-v".into());
        a.push(format!("{forwarder}:{FORWARDER}:ro,Z").into());
        let url = format!("http://127.0.0.1:{}", crate::sandbox::PROXY_PORT);
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
        a.push(crate::sandbox::PROXY_PORT.to_string().into());
        a.push(PROXY_SOCKET.into());
        a.push("--".into());
    }
    a.extend(req.argv.iter().map(OsString::from));
    Ok(a)
}

/// The refusal for a hub that found no `podman` on its PATH at start.
pub fn podman_missing() -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message: "container jobs need podman on the PATH; run `drgnx doctor` for what to install"
            .into(),
    }
}

/// A job's proxy: the listener on its socket, the socket (removed when the job ends) and the forwarder's copy.
pub struct JobProxy {
    _handle: gleipnir::net::proxy::ProxyHandle,
    pub mounts: Proxy,
}

impl Drop for JobProxy {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.mounts.socket);
    }
}

/// Where a job's proxy socket lives: a short path (a Unix socket's path holds 108 bytes) under the user's runtime dir.
pub fn socket_for(job: &str, run_dir: &Path) -> PathBuf {
    run_dir.join("drgnx-jobs").join(format!("{job}.sock"))
}

/// Makes job JOB's proxy: its own copy of FORWARDER in DIR (the job's folder; the copy is what gets relabelled, never
/// the installed binary) and its proxy on a socket under RUN_DIR with the allow-list of NET under HOSTS.  An error means the job
/// was granted a network it cannot be given.
pub fn prepare_proxy(
    job: &str,
    dir: &Path,
    run_dir: &Path,
    forwarder: &Path,
    net: NetCell,
    hosts: &[(String, Vec<String>)],
) -> Result<JobProxy, Refusal> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let copy = dir.join("fwd");
    std::fs::copy(forwarder, &copy)
        .and_then(|_| std::fs::set_permissions(&copy, std::fs::Permissions::from_mode(0o755)))
        .map_err(|e| {
            refuse(format!(
                "this job was granted network access, but the forwarder {} cannot be copied: {e}",
                forwarder.display()
            ))
        })?;
    let socket = socket_for(job, run_dir);
    if let Some(parent) = socket.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|e| refuse(format!("{}: {e}", parent.display())))?;
    }
    let handle = start_proxy(&socket, net, hosts)?;
    Ok(JobProxy {
        _handle: handle,
        mounts: Proxy {
            socket,
            forwarder: copy,
        },
    })
}

/// Starts a proxy listening on the Unix socket SOCKET with the allow-list of NET under HOSTS (`agents-net-hosts`).  Dropping the handle closes the
/// listener and every connection.
pub fn start_proxy(
    socket: &Path,
    net: NetCell,
    hosts: &[(String, Vec<String>)],
) -> Result<gleipnir::net::proxy::ProxyHandle, Refusal> {
    use gleipnir::net::{host, proxy};
    let allow = crate::sandbox::allowed_hosts(net, hosts)
        .iter()
        .map(|h| host::parse_target(h))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| refuse(format!("the allow-list: {e:?}")))?;
    let _ = std::fs::remove_file(socket);
    let listener = tokio::net::UnixListener::bind(socket)
        .map_err(|e| refuse(format!("the proxy socket {}: {e}", socket.display())))?;
    let (tx, mut rx) = tokio::sync::mpsc::channel(16);
    // nobody is asked about a denied host here; the channel only has to stay drained
    tokio::spawn(async move { while rx.recv().await.is_some() {} });
    let handle = proxy::start(
        proxy::ProxyConfig {
            allow,
            ..Default::default()
        },
        std::sync::Arc::new(proxy::SystemResolver),
        tx,
    );
    handle.listen(proxy::Listener::Unix(listener), 1);
    Ok(handle)
}

/// Run `podman ARGS`; kill it and say so when it outlives LIMIT.
fn run_limited(
    podman: &Path,
    args: &[&str],
    limit: Duration,
) -> Result<std::process::Output, Refusal> {
    let setup = |m: String| Refusal {
        rule: Rule::Setup,
        path: None,
        message: m,
    };
    let mut child = std::process::Command::new(podman)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| setup(format!("podman: {e}")))?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|e| setup(format!("podman: {e}")));
            }
            Ok(None) if start.elapsed() < limit => std::thread::sleep(Duration::from_millis(25)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(setup(format!(
                    "podman {} took longer than {}s; the job is refused",
                    args.first().copied().unwrap_or(""),
                    limit.as_secs()
                )));
            }
            Err(e) => return Err(setup(format!("podman: {e}"))),
        }
    }
}

/// Make sure REF (an image pinned by digest) is in the local store: the hub pulls it, a job never does.  A pull that
/// takes longer than LIMIT ([`PULL_TIMEOUT`]) refuses the job.
pub fn ensure_image(podman: &Path, reference: &str, limit: Duration) -> Result<(), Refusal> {
    if run_limited(podman, &["image", "exists", reference], limit)?
        .status
        .success()
    {
        return Ok(());
    }
    let pull = run_limited(podman, &["pull", "--quiet", reference], limit)?;
    if pull.status.success() {
        return Ok(());
    }
    Err(Refusal {
        rule: Rule::Setup,
        path: None,
        message: format!(
            "podman could not pull {reference}: {}",
            String::from_utf8_lossy(&pull.stderr).trim()
        ),
    })
}

/// At hub start: remove the `drgnx-job-*` containers whose job is not in RUNNING (a podman client killed with the
/// hub leaves its container behind).  Only names under [`NAME_PREFIX`] are looked at; answers how many it removed.
pub fn remove_leftovers(podman: &Path, running: &std::collections::HashSet<String>) -> usize {
    let limit = Duration::from_secs(30);
    let Ok(list) = run_limited(
        podman,
        &[
            "ps",
            "-a",
            "--filter",
            "name=drgnx-job-",
            "--format",
            "{{.Names}}",
        ],
        limit,
    ) else {
        return 0;
    };
    let mut n = 0;
    for name in String::from_utf8_lossy(&list.stdout).lines() {
        let name = name.trim();
        let Some(id) = name.strip_prefix(NAME_PREFIX) else {
            continue;
        };
        if running.contains(id) || name_of(id).is_err() {
            continue;
        }
        if run_limited(podman, &["rm", "-f", name], limit).is_ok_and(|o| o.status.success()) {
            n += 1;
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    const REF: &str = "registry.example/tools@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn test_hosts() -> Vec<(String, Vec<String>)> {
        vec![("packages".into(), vec!["crates.io:443".into()])]
    }

    fn caps() -> Caps {
        Caps {
            images: vec![ContainerImage {
                name: "tools".into(),
                image: REF.into(),
            }],
            memory: "4G".into(),
            cpus: 2,
            pids: PIDS,
            net_hosts: test_hosts(),
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
            net: None,
        }
    }

    fn strs(v: Vec<OsString>) -> Vec<String> {
        v.into_iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn argv_has_exactly_the_fixed_flags() {
        let a = strs(argv(&req(&["make", "test"]), &caps()).unwrap());
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
            "--cpus",
            "2",
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
    }

    #[test]
    fn only_the_worktree_is_mounted() {
        let a = strs(argv(&req(&["ls"]), &caps()).unwrap());
        assert_eq!(a.iter().filter(|s| *s == "-v").count(), 1);
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--mount") || s.starts_with("--volume"))
        );
        assert!(
            !a.iter()
                .any(|s| s == "--privileged" || s.starts_with("--device"))
        );
        // a path that would add mount options, or a relative one, is refused
        for bad in ["/a:/etc:rw", "/a,b", "rel/path"] {
            let mut r = req(&["ls"]);
            r.worktree = bad.into();
            assert!(argv(&r, &caps()).is_err(), "{bad}");
        }
    }

    #[test]
    fn image_off_the_list_refused() {
        let mut r = req(&["ls"]);
        r.image = "evil".into();
        let e = argv(&r, &caps()).unwrap_err();
        assert!(
            e.message.contains("agents-container-images"),
            "{}",
            e.message
        );
        // a raw reference is not a name on the list
        r.image = REF.into();
        assert!(argv(&r, &caps()).is_err());
        // an entry that is not pinned by digest is not run
        let mut c = caps();
        c.images[0].image = "registry.example/tools:latest".into();
        assert!(argv(&req(&["ls"]), &c).is_err());
        assert!(
            argv(
                &req(&["ls"]),
                &Caps {
                    images: vec![],
                    ..caps()
                }
            )
            .is_err()
        );
    }

    #[test]
    fn argv_after_the_image_never_reaches_podman_options() {
        let nasty = ["--privileged", "-v", "/:/host", "--network=host", "--rm"];
        let a = strs(argv(&req(&nasty), &caps()).unwrap());
        let at = a.iter().position(|s| s == REF).unwrap();
        assert_eq!(a[at + 1..], nasty.map(String::from));
        // every flag podman sees comes before the image, and none is the agent's
        assert!(
            a[..at]
                .iter()
                .all(|s| !s.contains("host") && s != "--privileged")
        );
        assert_eq!(a[..at].iter().filter(|s| *s == "-v").count(), 1);
        assert!(argv(&req(&[]), &caps()).is_err());
    }

    #[test]
    fn network_none_unless_granted() {
        let a = strs(argv(&req(&["ls"]), &caps()).unwrap());
        assert!(a.contains(&"--network=none".to_string()));
        let mut r = req(&["ls"]);
        r.net = Some(NetCell::ProviderAndPackages);
        let a = strs(argv(&r, &caps()).unwrap());
        // still no podman network: the proxy comes in as files
        assert!(a.contains(&"--network=none".to_string()));
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--network=") && s != "--network=none")
        );
        // a grant with no proxy is refused, never turned into the host's network
        let c = Caps {
            proxy: None,
            ..caps()
        };
        assert!(argv(&r, &c).is_err());
        r.net = Some(NetCell::Open);
        assert!(
            !strs(argv(&r, &caps()).unwrap())
                .iter()
                .any(|s| s.contains("host"))
        );
    }

    #[test]
    fn a_grant_adds_exactly_two_ro_mounts_the_proxy_env_and_the_entrypoint() {
        let plain = strs(argv(&req(&["ls", "-l"]), &caps()).unwrap());
        let mut r = req(&["ls", "-l"]);
        r.net = Some(NetCell::ProviderAndPackages);
        let a = strs(argv(&r, &caps()).unwrap());
        // the fixed flags before the extras are untouched
        let at = plain.iter().position(|s| s == REF).unwrap();
        assert_eq!(a[..at], plain[..at]);
        let image = a.iter().position(|s| s == REF).unwrap();
        assert_eq!(image - at, NET_FLAGS);
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
        // the command stays last, after the forwarder's own arguments
        assert_eq!(
            a[image + 1..],
            ["3128", "/run/drgnx/proxy.sock", "--", "ls", "-l"]
        );
        // a mount source that podman would read as options is refused
        let c = Caps {
            proxy: Some(Proxy {
                socket: "/a:b/s".into(),
                forwarder: "/f".into(),
            }),
            ..caps()
        };
        assert!(argv(&r, &c).is_err());
    }

    #[tokio::test]
    async fn every_mount_source_lies_in_the_jobs_own_dirs() {
        let d = tempfile::tempdir().unwrap();
        let (job_dir, run_dir, installed) = (
            d.path().join("job"),
            d.path().join("run"),
            d.path().join("bin-drgnx-fwd"),
        );
        std::fs::create_dir_all(&job_dir).unwrap();
        std::fs::write(&installed, b"binary").unwrap();
        let jp = prepare_proxy(
            "j1",
            &job_dir,
            &run_dir,
            &installed,
            NetCell::ProviderAndPackages,
            &test_hosts(),
        )
        .unwrap();
        // the socket path stays short; the copy is the job's own; the installed file is never a mount source
        assert!(jp.mounts.socket.starts_with(&run_dir));
        assert!(jp.mounts.socket.as_os_str().len() < 108);
        assert_eq!(jp.mounts.forwarder, job_dir.join("fwd"));
        assert_eq!(std::fs::read(&jp.mounts.forwarder).unwrap(), b"binary");
        let c = Caps {
            proxy: Some(jp.mounts.clone()),
            ..caps()
        };
        let mut r = req(&["ls"]);
        r.worktree = d.path().join("tree");
        r.net = Some(NetCell::ProviderAndPackages);
        let a = strs(argv(&r, &c).unwrap());
        let sources: Vec<&str> = a
            .windows(2)
            .filter(|w| w[0] == "-v")
            .map(|w| w[1].split(':').next().unwrap())
            .collect();
        assert_eq!(sources.len(), 3);
        for s in sources {
            let p = Path::new(s);
            assert!(
                p.starts_with(d.path().join("tree"))
                    || p.starts_with(&job_dir)
                    || p.starts_with(&run_dir),
                "{s}"
            );
            assert_ne!(p, installed);
        }
        assert!(a.iter().all(|s| !s.ends_with(":ro,z")));
        let sock = jp.mounts.socket.clone();
        drop(jp);
        assert!(!sock.exists());
        // a forwarder that is not there refuses the job instead of running it without a network
        assert!(
            prepare_proxy(
                "j2",
                &job_dir,
                &run_dir,
                &d.path().join("none"),
                NetCell::Open,
                &test_hosts()
            )
            .is_err()
        );
    }

    #[test]
    fn no_grant_adds_no_proxy_flag() {
        let a = strs(argv(&req(&["ls"]), &caps()).unwrap());
        assert!(!a.iter().any(|s| s.contains("proxy") || s == "--entrypoint"));
        assert_eq!(a.len(), 22 + 1 + 1);
    }

    #[tokio::test]
    async fn the_job_proxy_listens_on_its_socket() {
        let d = tempfile::tempdir().unwrap();
        let sock = d.path().join("proxy.sock");
        let handle = start_proxy(&sock, NetCell::ProviderAndPackages, &test_hosts()).unwrap();
        // not on the allow-list: refused by the proxy itself
        let mut c = tokio::net::UnixStream::connect(&sock).await.unwrap();
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        c.write_all(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            .await
            .unwrap();
        let mut buf = [0u8; 12];
        let n = c.read(&mut buf).await.unwrap_or(0);
        assert!(!buf[..n].starts_with(b"HTTP/1.1 200"), "{:?}", &buf[..n]);
        drop(handle);
    }

    #[test]
    fn caps_from_settings() {
        let mut v = crate::settings::RuntimeValues {
            agents_job_memory: "512M".into(),
            agents_job_cpus: 3,
            agents_container_images: caps().images,
            ..Default::default()
        };
        let c = crate::settings::containers::caps(&v);
        assert_eq!((c.memory.as_str(), c.cpus, c.pids), ("512M", 3, PIDS));
        let a = strs(argv(&req(&["ls"]), &c).unwrap());
        assert!(a.windows(2).any(|w| w == ["--memory", "512M"]));
        assert!(a.windows(2).any(|w| w == ["--cpus", "3"]));
        // a limit podman would misread is refused
        v.agents_job_memory = "4G --privileged".into();
        let c = crate::settings::containers::caps(&v);
        assert!(argv(&req(&["ls"]), &c).is_err());
    }

    /// AS1-NET-HOSTS-1: the hosts a granted network reaches are the setting's, per tier; the shipped default is the
    /// package registries.
    #[test]
    fn net_hosts_are_the_settings_per_tier() {
        let d = crate::settings::defaults();
        assert!(d.problems.is_empty(), "{:?}", d.problems);
        let hosts =
            crate::sandbox::allowed_hosts(NetCell::ProviderAndPackages, &d.values.agents_net_hosts);
        assert_eq!(hosts.len(), 6);
        assert!(
            hosts.contains(&"crates.io:443".to_string())
                && hosts.contains(&"pypi.org:443".to_string())
        );
        assert_eq!(
            crate::sandbox::allowed_hosts(NetCell::Open, &d.values.agents_net_hosts),
            hosts
        );
        assert!(
            crate::sandbox::allowed_hosts(NetCell::ProviderOnly, &d.values.agents_net_hosts)
                .is_empty()
        );
        // the user's list replaces it
        let mine = vec![("packages".to_string(), vec!["example.org:443".to_string()])];
        assert_eq!(
            crate::sandbox::allowed_hosts(NetCell::ProviderAndPackages, &mine),
            vec!["example.org:443".to_string()]
        );
        let v = crate::settings::RuntimeValues {
            agents_net_hosts: mine.clone(),
            ..Default::default()
        };
        assert_eq!(crate::settings::containers::caps(&v).net_hosts, mine);
    }

    #[test]
    fn podman_absent_is_refused_with_a_doctor_hint() {
        assert!(podman_missing().message.contains("drgnx doctor"));
    }
}

#[cfg(test)]
mod name_and_pull_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &Path, body: &str) -> PathBuf {
        let p = dir.join("podman");
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    #[test]
    fn the_name_is_the_prefix_and_a_plain_id() {
        assert_eq!(name_of("x1a2").unwrap(), "drgnx-job-x1a2");
        for bad in ["", "a b", "a/b", "-rm", "a,b"] {
            assert!(name_of(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_pull_past_the_timeout_refuses_the_job() {
        let d = tempfile::tempdir().unwrap();
        let p = script(
            d.path(),
            "if [ \"$1\" = image ]; then exit 1; fi\nexec sleep 30",
        );
        let t = Instant::now();
        let e = ensure_image(&p, "r@sha256:0", Duration::from_millis(300)).unwrap_err();
        assert!(e.message.contains("longer than"), "{}", e.message);
        assert!(t.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn leftovers_removal_touches_only_dead_hub_names() {
        let d = tempfile::tempdir().unwrap();
        let log = d.path().join("log");
        let p = script(
            d.path(),
            &format!(
                "echo \"$@\" >> {}\nif [ \"$1\" = ps ]; then printf 'drgnx-job-dead\\ndrgnx-job-live\\nother\\n'; fi",
                log.display()
            ),
        );
        let running = ["live".to_string()].into_iter().collect();
        assert_eq!(remove_leftovers(&p, &running), 1);
        let said = std::fs::read_to_string(&log).unwrap();
        assert!(said.contains("rm -f drgnx-job-dead"), "{said}");
        assert!(!said.contains("rm -f drgnx-job-live") && !said.contains("rm -f other"));
    }
}
