//! Container jobs (Task 11b): the hub runs `podman run` from a fixed spec.
//!
//! The `podman run` line comes from the one builder shared with the runners, `sleipnir::linux::podman::argv`
//! ([`argv`] here, with the hub's own placement): an agent's request carries an image *name* and a command; everything
//! else is fixed there or comes from settings ([`Caps`]): no capabilities, no new privileges, a read-only root with a
//! tmpfs `/tmp`, the worktree as the only mount, no network unless the matrix granted one, swap equal to memory, OOM
//! score 1000 and the container killed whole.  The command goes after the image, where podman stops reading options.
//! The image is the allow-list's reference pinned by digest; the hub pulls it ([`ensure_image`]), the job never does
//! (`--pull=never`).

use crate::shell_env::ShellEnv;
use gleipnir::{Refusal, Rule};
use sleipnir::linux::podman;
use std::ffi::OsString;
use std::path::Path;
use std::time::Duration;

pub use sleipnir::linux::podman::{
    CONTROLLERS, Caps, ContainerReq, JobNet, NetNames, PIDS, WORK, limits_enforced, net_names,
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

/// The placement of the hub's own jobs: `drgnx-job-<id>`, no parent slice, labelled with the hub's OWNER tag.
pub fn placement(owner: &str) -> podman::RunnerArgs {
    podman::RunnerArgs::local(owner)
}

/// This hub's tag in container names and labels: the 8 hex of its socket's name (`hub-<tag>.sock`), which the hash of
/// its data dir makes.
pub fn owner_tag() -> String {
    tag_of(&runstav::paths::socket_path(&runstav::paths::Env::process()))
}

/// The tag in the hub's socket name SOCKET (`hub-<tag>.sock`); `00000000` for a name of another shape.
pub fn tag_of(socket: &Path) -> String {
    socket
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.strip_prefix("hub-")?.strip_suffix(".sock"))
        .unwrap_or("00000000")
        .to_string()
}

/// The `podman run` arguments (without the program) for REQ under CAPS: the shared builder with the hub's own
/// placement ([`placement`] of OWNER).
pub fn argv(req: &ContainerReq, caps: &Caps, owner: &str) -> Result<Vec<OsString>, Refusal> {
    podman::argv(req, caps, &placement(owner)).map_err(|r| refuse(r.message))
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

/// Refuse the job unless PODMAN enforces its caps ([`limits_enforced`]), asked within LIMIT; answers the parsed
/// `podman info`, for the networked job's checks (`sleipnir::linux::netcheck`).
pub fn check_limits(
    shell: &ShellEnv,
    podman: &Path,
    limit: Duration,
) -> Result<serde_json::Value, Refusal> {
    podman::check_limits(podman, &podman_env(shell), limit).map_err(setup)
}

/// At hub start: remove what this hub (OWNER, its tag) left behind (a podman client killed with the hub leaves its
/// container): the containers labelled `drgnx.owner=<OWNER>` whose `drgnx.job` is not in RUNNING, the jobs' before
/// the sidecars (S11; `podman::leftovers`, shared with the runners), then the relay images other than PX_CURRENT.  A
/// sibling hub's containers carry another tag and are never touched; ones made before the labels are left (they are
/// `--rm`).  Answers how many containers it removed.
pub fn remove_leftovers(
    shell: &ShellEnv,
    podman: &Path,
    owner: &str,
    running: &std::collections::HashSet<String>,
    px_current: Option<&str>,
) -> usize {
    let limit = Duration::from_secs(30);
    let label = format!("label=drgnx.owner={owner}");
    let json = |args: &[&str]| {
        run_limited(shell, podman, args, limit)
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
    };
    let mut n = 0;
    if let Some(ps) = json(&["ps", "-a", "--filter", &label, "--format", "json"]) {
        let left = podman::leftovers(&ps, None, ("drgnx.owner", owner), running);
        for name in left.jobs.iter().chain(&left.sidecars) {
            if run_limited(shell, podman, &["rm", "-f", name], limit)
                .is_ok_and(|o| o.status.success())
            {
                n += 1;
            }
        }
    }
    if let Some(current) = px_current
        && let Some(images) = json(&[
            "images",
            "--filter",
            "reference=localhost/drgnx-px",
            "--format",
            "json",
        ])
    {
        for tag in podman::old_px_tags(&images, current) {
            // an image a sibling hub's sidecar still runs from stays: `rmi` without force refuses it
            let _ = run_limited(shell, podman, &["rmi", &tag], limit);
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::launch::NetCell;
    use crate::settings::ContainerImage;
    use std::path::PathBuf;

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
            proxy: Some(JobNet {
                sidecar: "drgnx-px-0a1b2c3d-x1a".into(),
            }),
            pins: vec![],
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
        let a = strs(argv(&req(&["make", "test"]), &caps(), "0a1b2c3d").unwrap());
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
        assert_eq!(
            argv(&r, &caps(), "0a1b2c3d").unwrap_err().rule,
            Rule::Malformed
        );
        assert_eq!(resolve(&caps(), "tools").unwrap(), REF);
    }

    #[test]
    fn the_owner_tag_is_the_sockets_hash() {
        assert_eq!(
            tag_of(Path::new("/run/user/1000/drgnx/hub-1a2b3c4d.sock")),
            "1a2b3c4d"
        );
        assert_eq!(
            tag_of(Path::new("/run/user/1000/drgnx/other.sock")),
            "00000000"
        );
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
        let a = strs(argv(&req(&["ls"]), &c, "0a1b2c3d").unwrap());
        assert!(a.windows(2).any(|w| w == ["--memory", "512M"]));
        assert!(a.windows(2).any(|w| w == ["--cpus", "3"]));
        // a limit podman would misread is refused
        v.agents_job_memory = "4G --privileged".into();
        let c = crate::settings::containers::caps(&v);
        assert!(argv(&req(&["ls"]), &c, "0a1b2c3d").is_err());
        // the job's proxy pins what the setting pins
        v.sandbox_proxy_pins = vec![("registry.corp".into(), "10.0.0.5".parse().unwrap())];
        assert_eq!(
            crate::settings::containers::caps(&v).pins,
            v.sandbox_proxy_pins
        );
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
    use std::path::PathBuf;

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
        let ps = r#"[{"Names":["drgnx-job-dead"],"Labels":{"drgnx.owner":"aaaa1111","drgnx.job":"dead"}},
{"Names":["drgnx-px-aaaa1111-dead"],"Labels":{"drgnx.owner":"aaaa1111","drgnx.job":"dead"}},
{"Names":["drgnx-job-live"],"Labels":{"drgnx.owner":"aaaa1111","drgnx.job":"live"}},
{"Names":["drgnx-job-sib"],"Labels":{"drgnx.owner":"bbbb2222","drgnx.job":"sib"}},
{"Names":["other"],"Labels":{}}]"#;
        let images =
            r#"[{"Names":["localhost/drgnx-px:00aa"]},{"Names":["localhost/drgnx-px:11bb"]}]"#;
        let p = script(
            d.path(),
            &format!(
                "echo \"$@\" >> {}\nif [ \"$1\" = ps ]; then echo '{ps}'; fi\nif [ \"$1\" = images ]; then echo '{images}'; fi",
                log.display()
            ),
        );
        let running = ["live".to_string()].into_iter().collect();
        let n = remove_leftovers(
            &ShellEnv::default(),
            &p,
            "aaaa1111",
            &running,
            Some("localhost/drgnx-px:11bb"),
        );
        assert_eq!(n, 2);
        let said = std::fs::read_to_string(&log).unwrap();
        assert!(
            said.contains("ps -a --filter label=drgnx.owner=aaaa1111"),
            "{said}"
        );
        let (j, s) = (
            said.find("rm -f drgnx-job-dead")
                .expect("the dead job goes"),
            said.find("rm -f drgnx-px-aaaa1111-dead")
                .expect("its sidecar goes"),
        );
        assert!(j < s, "the job's container before its sidecar: {said}");
        assert!(
            !said.contains("rm -f drgnx-job-live") && !said.contains("rm -f drgnx-job-sib"),
            "{said}"
        );
        assert!(
            said.contains("rmi localhost/drgnx-px:00aa")
                && !said.contains("rmi localhost/drgnx-px:11bb"),
            "{said}"
        );
    }
}
