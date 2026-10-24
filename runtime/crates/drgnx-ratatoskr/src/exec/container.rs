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
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caps {
    /// `agents-container-images`: the only images a job may name.
    pub images: Vec<ContainerImage>,
    /// `agents-job-memory`, like `4G`.
    pub memory: String,
    /// `agents-job-cpus`.
    pub cpus: u32,
    pub pids: u32,
    /// The podman network whose only route is the Gleipnir proxy ([`proxy_network`]); none until one exists.
    pub proxy_network: Option<String>,
}

/// The process limit of a container job.
pub const PIDS: u32 = 512;

/// What a job asks: an image name from the allow-list, a command, the folder it works in, the network granted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContainerReq {
    pub image: String,
    pub argv: Vec<String>,
    pub worktree: PathBuf,
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
    let network = match req.net {
        None => "--network=none".to_string(),
        Some(_) => format!(
            "--network={}",
            caps.proxy_network.as_deref().ok_or_else(|| refuse(
                "this job was granted network access, but no proxy network is set up for containers yet"
            ))?
        ),
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
    a.push(network.into());
    a.push("-v".into());
    a.push(format!("{source}:{WORK}:Z").into());
    a.push("-w".into());
    a.push(WORK.into());
    a.push(image.into());
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

/// The podman network whose only route is the Gleipnir proxy, created on first use.  Not built yet: a container
/// that is granted network access is refused until it is (the argv side, [`argv`], already takes its name).
pub fn proxy_network(_sid: &str) -> Result<String, Refusal> {
    Err(refuse(
        "a network for container jobs is not set up yet (its only route would be the Gleipnir proxy)",
    ))
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

    fn caps() -> Caps {
        Caps {
            images: vec![ContainerImage {
                name: "tools".into(),
                image: REF.into(),
            }],
            memory: "4G".into(),
            cpus: 2,
            pids: PIDS,
            proxy_network: Some("drgnx-proxy".into()),
        }
    }

    fn req(argv: &[&str]) -> ContainerReq {
        ContainerReq {
            image: "tools".into(),
            argv: argv.iter().map(|s| s.to_string()).collect(),
            worktree: "/work/tree".into(),
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
        assert!(a.contains(&"--network=drgnx-proxy".to_string()));
        assert!(!a.contains(&"--network=none".to_string()));
        // a grant with no proxy network is refused, never turned into the host's network
        let c = Caps {
            proxy_network: None,
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
