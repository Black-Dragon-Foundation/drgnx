//! A networked container job's relay (design §5): the job runs with no network of its own (`lo` only, joined to its
//! sidecar's namespace), the sidecar `drgnx-px` listens on `127.0.0.1:3128` inside it and carries each connection over
//! its stdio to the hub, and the hub's proxy for the job answers them with the job's allow-list.
//!
//! [`prepare_net`] starts the sidecar and the proxy before the job; [`JobNetwork::end`] takes them down after it, in
//! the order podman needs (the job container first, then the sidecar).  When the relay ends before the job, the job
//! ends `infra: proxy` with [`end_reason`]'s text.

use super::container::{self, NetNames};
use crate::agents::launch::NetCell;
use crate::shell_env::ShellEnv;
use drgnx_px::owner::{self, End, Sidecar};
use gleipnir::{Refusal, Rule};
use sleipnir::linux::podman;
use std::ffi::OsString;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::task::JoinHandle;

/// What a job's `why` file starts with when the hub's relay, not the job, ended it.
pub const INFRA: &str = "infra: proxy";
/// The reason of a networked job a graceful hub stop ends (channel review S9).
pub const HUB_STOPPED: &str = "the hub stopped";
/// The reason of a networked job a restarted hub finds (relay review B3).
pub const HUB_RESTARTED: &str = "the hub restarted, and a networked job can't keep its relay";
/// Where the sidecar listens inside the job's namespace (its `READY` names it).
pub const LISTEN: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 3128);
/// How long the sidecar's image check or import may take.
const IMAGE_LIMIT: Duration = Duration::from_secs(60);

fn setup(message: impl Into<String>) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message: message.into(),
    }
}

pub use drgnx_px::owner::{end_reason, exit_meaning};

/// The job's proxy: the allow-list ALLOW and the pins PINS under the job policy on WEB (`host.drgnx.internal:PORT`
/// by its `browser.private` grants and the never-set, everything else by the list), and at most twice the relay's
/// streams open at once (S4's backstop; the sidecar holds the 65th connection until one closes).
pub fn proxy_config(
    allow: Vec<gleipnir::net::host::Target>,
    pins: &[(String, IpAddr)],
    web: std::sync::Arc<gleipnir::net::proxy::WebState>,
) -> gleipnir::net::proxy::ProxyConfig {
    gleipnir::net::proxy::ProxyConfig {
        allow,
        pinned: pins.to_vec(),
        max_conns: 2 * drgnx_px::frame::MAX_STREAMS,
        policy: gleipnir::net::proxy::Policy::Job(web),
        ..Default::default()
    }
}

/// The job's web state: the hub's host addresses and never-set (NEVERS; fresh empty ones without), no grants yet
/// (`browser.web` stays off).  On a Mac the machine's control ports are read into the never-set first (B4).
pub fn job_web(
    nevers: Option<&crate::browser::nevers::Nevers>,
) -> std::sync::Arc<gleipnir::net::proxy::WebState> {
    use std::sync::{Arc, RwLock};
    let (host_addrs, never) = match nevers {
        Some(n) => {
            n.never.read_machine();
            (n.host_addrs.shared(), n.never.shared())
        }
        None => (
            Arc::new(RwLock::new(Default::default())),
            Arc::new(RwLock::new(Default::default())),
        ),
    };
    Arc::new(gleipnir::net::proxy::WebState::new(host_addrs, never))
}

/// The podman machine connection drgnx names on a Mac (S8): from `podman system connection list --format json`, the
/// default when it is rootless, else the first rootless machine connection.  A rootful default is no reason to refuse;
/// a machine without a rootless connection is (design §6).
pub fn rootless_connection(list: &serde_json::Value) -> Result<String, String> {
    let rows = list.as_array().cloned().unwrap_or_default();
    let rootless = |r: &serde_json::Value| {
        let uri = r["URI"].as_str().unwrap_or("");
        !uri.starts_with("ssh://root@") && !uri.is_empty()
    };
    let name = |r: &serde_json::Value| r["Name"].as_str().unwrap_or("").to_string();
    let machine = rows.iter().filter(|r| r["IsMachine"] != false);
    if let Some(r) = machine
        .clone()
        .find(|r| r["Default"] == true && rootless(r))
    {
        return Ok(name(r));
    }
    if let Some(r) = machine.clone().find(|r| rootless(r)) {
        return Ok(name(r));
    }
    let m = machine
        .map(name)
        .next()
        .map(|n| n.trim_end_matches("-root").to_string())
        .unwrap_or_else(|| "podman-machine-default".into());
    Err(format!(
        "drgnx runs containers rootless, and podman machine `{m}` has no rootless connection: re-create the machine, \
         or add one with `podman system connection add`."
    ))
}

/// This host's podman architecture name.
fn podman_arch() -> &'static str {
    if std::env::consts::ARCH == "aarch64" {
        "arm64"
    } else {
        "amd64"
    }
}

/// The relay image the binary in PX_DIR makes (its content tag), or none without the binary.
pub fn px_image_ref(px_dir: &Path) -> Option<String> {
    let px = std::fs::read(drgnx_px::image::binary_for(px_dir, podman_arch())).ok()?;
    Some(drgnx_px::image::image_ref(&drgnx_px::image::image_tar(&px)))
}

/// A networked job's relay while it runs: its proxy, its sidecar and the channel between them.
pub struct JobNetwork {
    _proxy: gleipnir::net::proxy::ProxyHandle,
    /// The job policy's state: the grants a host-port card opens go here (`set_grants`).
    web: std::sync::Arc<gleipnir::net::proxy::WebState>,
    sidecar: Option<Sidecar>,
    names: NetNames,
    job: String,
    channel: JoinHandle<End>,
    log: JoinHandle<()>,
    /// The proxy's events (its refusals), until [`JobNetwork::take_events`] takes them.
    events: Option<tokio::sync::mpsc::Receiver<gleipnir::net::proxy::ProxyEvent>>,
    /// The loop that turns them into cards ([`super::hostgrants`]), ended with the relay.
    asker: Option<JoinHandle<()>>,
    podman: PathBuf,
    env: Vec<(OsString, OsString)>,
}

impl JobNetwork {
    /// How the channel ended; waits while it runs (cancel-safe, so a `select!` arm; await it once).
    pub async fn ended(&mut self) -> End {
        (&mut self.channel).await.unwrap_or(End::Eof)
    }

    /// The job policy's state, for live grants.
    pub fn web(&self) -> &std::sync::Arc<gleipnir::net::proxy::WebState> {
        &self.web
    }

    /// The proxy's events, once: a session's job hands them to its card loop ([`JobNetwork::set_asker`]); dropped,
    /// they are not sent.
    pub fn take_events(
        &mut self,
    ) -> Option<tokio::sync::mpsc::Receiver<gleipnir::net::proxy::ProxyEvent>> {
        self.events.take()
    }

    /// The card loop, which [`JobNetwork::end`] ends with the relay.
    pub fn set_asker(&mut self, task: JoinHandle<()>) {
        self.asker = Some(task);
    }

    /// The sidecar's container name (the job's meta records it as `relay`).
    pub fn sidecar_name(&self) -> &str {
        &self.names.sidecar
    }

    /// The sidecar's stderr so far: read it before [`JobNetwork::end`] (which stops the sidecar).
    pub fn stderr(&self) -> String {
        self.sidecar
            .as_ref()
            .map(Sidecar::stderr)
            .unwrap_or_default()
    }

    /// Takes the relay down after the job (S11): `podman rm -f -t 0` the job's container first (podman records the
    /// job's dependency on the sidecar; its client had its grace already), then end the channel, which closes the
    /// sidecar's stdin so it exits by itself, then stop the sidecar.  Answers the sidecar's exit code.
    pub async fn end(mut self) -> Option<i32> {
        if let Some(a) = &self.asker {
            a.abort();
        }
        let _ = tokio::process::Command::new(&self.podman)
            .args(["rm", "-f", "-t", "0", &self.job])
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;
        // the channel task owns the sidecar's stdio: dropped (awaited after the abort), the sidecar reads its EOF; a
        // channel that ended already ([`JobNetwork::ended`]) dropped it then
        if !self.channel.is_finished() {
            self.channel.abort();
            let _ = (&mut self.channel).await;
        }
        let code = match self.sidecar {
            Some(s) => s.stop(&self.podman, &self.names.sidecar, &self.env).await,
            None => None,
        };
        self.log.abort();
        code
    }
}

/// Starts job ID's relay before the job (design §5.2, under Q8): the sidecar's image, then the sidecar **joined with**
/// the host checks (`check_limits`, `net_ready`) and the job's image REFERENCE, then the sidecar's `READY`, then the
/// proxy on its streams with NET's allow-list under HOSTS and the pins PINS.  The sidecar's relay lines go to LOG (the
/// job's log).  Answers the relay and what the job's argv needs of it; a check that fails refuses the job with §6's
/// text, and nothing is left running.
#[allow(clippy::too_many_arguments)]
pub async fn prepare_net(
    id: &str,
    shell: &ShellEnv,
    podman: &Path,
    px_dir: &Path,
    owner_tag: &str,
    net: NetCell,
    hosts: &[(String, Vec<String>)],
    pins: &[(String, IpAddr)],
    reference: &str,
    log: &Path,
    web: std::sync::Arc<gleipnir::net::proxy::WebState>,
) -> Result<(JobNetwork, container::JobNet), Refusal> {
    use gleipnir::net::{host, proxy};
    let allow = crate::sandbox::allowed_hosts(net, hosts)
        .iter()
        .map(|h| host::parse_target(h))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| setup(format!("the allow-list: {e:?}")))?;
    let ra = container::placement(owner_tag);
    let names = container::net_names(&ra, id).map_err(|r| setup(r.message))?;
    let env = container::podman_env(shell);
    let binary = drgnx_px::image::binary_for(px_dir, podman_arch());
    let (p, e) = (podman.to_path_buf(), env.clone());
    let image = crate::clock::blocking(move || {
        let px = std::fs::read(&binary).map_err(|err| {
            format!(
                "drgnx could not build its proxy image: {}: {err}",
                binary.display()
            )
        })?;
        drgnx_px::image::ensure_image(&p, &e, &drgnx_px::image::image_tar(&px), IMAGE_LIMIT)
            .map_err(|err| format!("drgnx could not build its proxy image: {err}"))
    })
    .await
    .map_err(|e| setup(format!("the proxy image: {e}")))?
    .map_err(setup)?;
    let argv = podman::sidecar_argv(&names, &ra, &image).map_err(|r| setup(r.message))?;
    let (p, reference) = (podman.to_path_buf(), reference.to_string());
    let checks_shell = shell.clone();
    let (started, checked) = tokio::join!(
        Sidecar::start(podman, argv, &env),
        crate::clock::blocking(move || -> Result<(), Refusal> {
            let info = container::check_limits(&checks_shell, &p, Duration::from_secs(30))?;
            sleipnir::linux::netcheck::net_ready(&info).map_err(setup)?;
            container::ensure_image(&checks_shell, &p, &reference, container::PULL_TIMEOUT)
        })
    );
    let mut sidecar = started.map_err(|e| setup(format!("the job's proxy: {e}")))?;
    let refused = match checked {
        Err(e) => Some(setup(format!("pulling the image: {e}"))),
        Ok(Err(r)) => Some(r),
        Ok(Ok(())) => None,
    };
    if let Some(r) = refused {
        sidecar.stop(podman, &names.sidecar, &env).await;
        return Err(r);
    }
    let Some((inp, mut out)) = sidecar.take_io() else {
        unreachable!("a sidecar just started has its stdio")
    };
    if let Err(e) = owner::wait_ready(&mut out, LISTEN, owner::READY_LIMIT).await {
        let stderr = sidecar.stderr();
        sidecar.stop(podman, &names.sidecar, &env).await;
        let why = match e {
            End::Ready(r) => r,
            other => format!("{other:?}"),
        };
        return Err(setup(format!(
            "The job's proxy did not start within 10 s: {why}: {}",
            stderr.trim()
        )));
    }
    let (streams_tx, streams_rx) = tokio::sync::mpsc::channel(owner::STREAMS_ROOM);
    let (events_tx, mut events_rx) = tokio::sync::mpsc::channel(16);
    let job = id.to_string();
    tokio::spawn(async move {
        while let Some(e) = events_rx.recv().await {
            tracing::warn!("job {job}: the relay reports {e:?}");
        }
    });
    let (ptx, prx) = tokio::sync::mpsc::channel(16);
    let handle = proxy::start(
        proxy_config(allow, pins, web.clone()),
        std::sync::Arc::new(proxy::SystemResolver),
        ptx,
    );
    handle.listen(proxy::Listener::Streams(streams_rx), 1);
    let px_log = drgnx_px::shell::Log::default();
    let log_file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .await;
    let drained = px_log.clone();
    let log = tokio::spawn(async move {
        if let Ok(f) = log_file {
            drained.drain_to(f).await;
        }
    });
    let channel = tokio::spawn(owner::run(
        out,
        inp,
        streams_tx,
        events_tx,
        owner::BEAT,
        drgnx_px::shell::STALL,
        px_log,
    ));
    let job_net = container::JobNet {
        sidecar: names.sidecar.clone(),
    };
    Ok((
        JobNetwork {
            _proxy: handle,
            web,
            sidecar: Some(sidecar),
            names,
            job: container::name_of(id)?,
            channel,
            log,
            events: Some(prx),
            asker: None,
            podman: podman.to_path_buf(),
            env,
        },
        job_net,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_end_text_names_the_sidecars_exit_code() {
        let t = end_reason(&End::Eof, Some(4), "drgnx-px: bad frame\n");
        assert!(t.contains("exited 4: the channel broke a rule"), "{t}");
        assert!(t.contains("bad frame"), "{t}");
        let t = end_reason(&End::Stalled, Some(5), "");
        assert!(
            t.contains("stopped reading") && t.contains("exited 5: its writes to the hub stalled"),
            "{t}"
        );
        let t = end_reason(&End::Eof, Some(137), "");
        assert!(
            t.contains("exited 137: killed, most likely at its memory limit"),
            "{t}"
        );
    }

    /// A stopped job owes its container no grace past the stop's own (its client was signalled already): the job is
    /// removed `-t 0`, and the sidecar's stdin closes before the sidecar is stopped, so it exits by itself rather than
    /// waiting out `STOP_LIMIT`.  The stand-in `podman run` exits when its stdin closes, like drgnx-px.
    #[cfg(unix)]
    #[tokio::test]
    async fn the_end_removes_the_job_at_once_and_lets_the_sidecar_exit() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let (podman, rms) = (dir.path().join("podman"), dir.path().join("rm"));
        std::fs::write(
            &podman,
            format!(
                "#!/bin/sh\ncase \"$1\" in\nrun) cat >/dev/null; exit 0 ;;\nrm) echo \"$*\" >> {} ;;\nesac\n",
                rms.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&podman, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut sidecar = Sidecar::start(&podman, vec!["run".into()], &[])
            .await
            .expect("the stand-in starts");
        let io = sidecar.take_io().expect("its stdio");
        let (ptx, prx) = tokio::sync::mpsc::channel(16);
        let net = JobNetwork {
            _proxy: gleipnir::net::proxy::start(
                proxy_config(vec![], &[], job_web(None)),
                std::sync::Arc::new(gleipnir::net::proxy::SystemResolver),
                ptx,
            ),
            web: job_web(None),
            sidecar: Some(sidecar),
            names: container::net_names(&container::placement("ffffffff"), "x1").unwrap(),
            job: container::name_of("x1").unwrap(),
            // the channel holds the sidecar's stdio while the relay runs
            channel: tokio::spawn(async move {
                let _io = io;
                std::future::pending::<End>().await
            }),
            log: tokio::spawn(async {}),
            events: Some(prx),
            asker: None,
            podman,
            env: vec![],
        };
        let job = net.job.clone();
        assert_eq!(net.end().await, Some(0), "the sidecar exits by itself");
        let rms = std::fs::read_to_string(&rms).unwrap();
        assert_eq!(
            rms.lines().next(),
            Some(format!("rm -f -t 0 {job}").as_str()),
            "{rms}"
        );
    }

    #[test]
    fn the_jobs_proxy_cap_is_twice_the_streams() {
        let c = proxy_config(vec![], &[], job_web(None));
        assert_eq!(c.max_conns, 128);
        assert!(matches!(c.policy, gleipnir::net::proxy::Policy::Job(_)));
    }

    #[test]
    fn the_rootless_connection_is_chosen() {
        let list = serde_json::json!([
            {"Name": "podman-machine-default-root", "URI": "ssh://root@127.0.0.1:50000/run/podman/podman.sock",
             "IsMachine": true, "Default": true},
            {"Name": "podman-machine-default", "URI": "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock",
             "IsMachine": true, "Default": false}
        ]);
        assert_eq!(
            rootless_connection(&list).unwrap(),
            "podman-machine-default"
        );
        let none = serde_json::json!([
            {"Name": "podman-machine-default-root", "URI": "ssh://root@127.0.0.1:50000/run/podman/podman.sock",
             "IsMachine": true, "Default": true}
        ]);
        let e = rootless_connection(&none).unwrap_err();
        assert!(
            e.contains("podman machine `podman-machine-default` has no rootless connection"),
            "{e}"
        );
    }
}
