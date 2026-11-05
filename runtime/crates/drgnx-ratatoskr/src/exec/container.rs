//! Container jobs (Task 11b): the hub runs `podman run` from a fixed spec.
//!
//! The `podman run` line comes from the one builder shared with the runners, `sleipnir::linux::podman::argv`
//! ([`argv`] here, with the hub's own placement): an agent's request carries an image *name* and a command; everything
//! else is fixed there or comes from settings ([`Caps`]): no capabilities, no new privileges, a read-only root with a
//! tmpfs `/tmp`, the worktree as the only mount, no network unless the matrix granted one, swap equal to memory, OOM
//! score 1000 and the container killed whole.  The command goes after the image, where podman stops reading options.
//! The image is the allow-list's reference pinned by digest; the hub pulls it ([`ensure_image`]), the job never does
//! (`--pull=never`).

use crate::agents::launch::NetCell;
use crate::shell_env::ShellEnv;
use gleipnir::{Refusal, Rule};
use sleipnir::linux::podman;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub use sleipnir::linux::podman::{
    CONTROLLERS, Caps, ContainerReq, FORWARDER, FORWARDER_ARGS, PIDS, PROXY_SOCKET, Proxy, WORK,
    limits_enforced,
};

fn refuse(message: impl Into<String>) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: None,
        message: message.into(),
    }
}

fn setup(message: impl Into<String>) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message: message.into(),
    }
}

/// What every hub-owned container is named before its job id.
pub const NAME_PREFIX: &str = podman::LOCAL_PREFIX;

/// How long the hub waits for an image pull before refusing the job.
pub const PULL_TIMEOUT: Duration = Duration::from_secs(600);

/// The environment of every podman the hub runs (the image check and pull, the job's `podman run`, the leftovers'
/// cleanup): one list, so all of them use one image store.  Rootless podman keeps its store under `XDG_DATA_HOME` (else
/// `~/.local/share`) and reads its configuration from `XDG_CONFIG_HOME` and the `CONTAINERS_*` files; a job that saw
/// fewer of these than the pull did looked in another store and found no image.  `DBUS_SESSION_BUS_ADDRESS` is how
/// podman reaches the user's systemd, which applies the job's limits ([`check_limits`]) when `XDG_RUNTIME_DIR` is not
/// the session's own.
pub fn podman_env(shell: &ShellEnv) -> Vec<(OsString, OsString)> {
    shell.build(
        &[
            "PATH",
            "HOME",
            "USER",
            "LOGNAME",
            "LANG",
            "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS",
            "XDG_DATA_HOME",
            "XDG_CONFIG_HOME",
            "CONTAINERS_CONF",
            "CONTAINERS_STORAGE_CONF",
            "CONTAINERS_REGISTRIES_CONF",
        ],
        &[],
        &[],
    )
}

/// The container name of job ID (an id of `[a-z0-9]`, as the runner makes them).
pub fn name_of(id: &str) -> Result<String, Refusal> {
    podman::name_of(NAME_PREFIX, id).map_err(|r| refuse(r.message))
}

/// The reference pinned by digest that the allow-list holds for NAME.
pub fn resolve<'a>(caps: &'a Caps, name: &str) -> Result<&'a str, Refusal> {
    podman::resolve(caps, name).map_err(|r| refuse(r.message))
}

/// The `podman run` arguments (without the program) for REQ under CAPS: the shared builder with the hub's own
/// placement (`drgnx-job-<id>`, no parent slice, no runner label).
pub fn argv(req: &ContainerReq, caps: &Caps) -> Result<Vec<OsString>, Refusal> {
    podman::argv(req, caps, &podman::RunnerArgs::local()).map_err(|r| refuse(r.message))
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
    shell: &ShellEnv,
    podman: &Path,
    args: &[&str],
    limit: Duration,
) -> Result<std::process::Output, Refusal> {
    podman::run_limited(podman, args, &podman_env(shell), limit).map_err(setup)
}

/// Make sure REF (an image pinned by digest) is in the local store: the hub pulls it, a job never does.  A pull that
/// takes longer than LIMIT ([`PULL_TIMEOUT`]) refuses the job.
pub fn ensure_image(
    shell: &ShellEnv,
    podman: &Path,
    reference: &str,
    limit: Duration,
) -> Result<(), Refusal> {
    if run_limited(shell, podman, &["image", "exists", reference], limit)?
        .status
        .success()
    {
        return Ok(());
    }
    let pull = run_limited(shell, podman, &["pull", "--quiet", reference], limit)?;
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

/// Refuse the job unless PODMAN enforces its caps ([`limits_enforced`]), asked within LIMIT.
pub fn check_limits(shell: &ShellEnv, podman: &Path, limit: Duration) -> Result<(), Refusal> {
    podman::check_limits(podman, &podman_env(shell), limit).map_err(setup)
}

/// At hub start: remove the `drgnx-job-*` containers whose job is not in RUNNING (a podman client killed with the
/// hub leaves its container behind).  Only names under [`NAME_PREFIX`] are looked at; answers how many it removed.
pub fn remove_leftovers(
    shell: &ShellEnv,
    podman: &Path,
    running: &std::collections::HashSet<String>,
) -> usize {
    let limit = Duration::from_secs(30);
    let Ok(list) = run_limited(
        shell,
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
        if run_limited(shell, podman, &["rm", "-f", name], limit).is_ok_and(|o| o.status.success())
        {
            n += 1;
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::ContainerImage;

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
            net: false,
            runner: None,
        }
    }

    fn strs(v: Vec<OsString>) -> Vec<String> {
        v.into_iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect()
    }

    /// The hub's jobs go through the shared builder with the hub's own placement: its name prefix, no parent slice,
    /// no runner label; refusals keep their rule.  The builder's own rows are `sleipnir::linux::podman`'s tests.
    #[test]
    fn the_hub_builds_its_jobs_with_the_shared_argv() {
        let a = strs(argv(&req(&["make", "test"]), &caps()).unwrap());
        assert_eq!(a[2..4], ["--name", "drgnx-job-x1a"]);
        assert!(a.windows(2).any(|w| w == ["--memory-swap", "4G"]));
        assert!(a.contains(&"--oom-score-adj=1000".to_string()));
        assert!(
            !a.iter()
                .any(|s| s.starts_with("--cgroup-parent") || s.starts_with("drgnx.runner="))
        );
        assert_eq!(a[a.len() - 3..], [REF, "make", "test"]);
        let mut r = req(&["ls"]);
        r.image = "evil".into();
        assert_eq!(argv(&r, &caps()).unwrap_err().rule, Rule::Malformed);
        assert_eq!(resolve(&caps(), "tools").unwrap(), REF);
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
        r.net = true;
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

    /// The forwarder's port inside the job is the sandbox's proxy port.
    #[test]
    fn the_proxy_port_is_the_sandboxs() {
        assert_eq!(
            sleipnir::linux::podman::PROXY_PORT,
            crate::sandbox::PROXY_PORT
        );
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
    fn podman_info_that_fails_refuses_the_job() {
        let d = tempfile::tempdir().unwrap();
        let p = script(d.path(), "echo 'no session' >&2; exit 125");
        let e = check_limits(&ShellEnv::default(), &p, Duration::from_secs(10)).unwrap_err();
        assert_eq!(e.rule, Rule::Setup);
        assert!(e.message.contains("no session"), "{}", e.message);
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
        let e = ensure_image(
            &ShellEnv::default(),
            &p,
            "r@sha256:0",
            Duration::from_millis(300),
        )
        .unwrap_err();
        assert!(e.message.contains("longer than"), "{}", e.message);
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
        assert_eq!(remove_leftovers(&ShellEnv::default(), &p, &running), 1);
        let said = std::fs::read_to_string(&log).unwrap();
        assert!(said.contains("rm -f drgnx-job-dead"), "{said}");
        assert!(!said.contains("rm -f drgnx-job-live") && !said.contains("rm -f other"));
    }
}
