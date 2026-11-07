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

/// What the sidecar's exit CODE means (the plan's exit codes of `drgnx-px`).
pub fn exit_meaning(code: i32) -> &'static str {
    match code {
        0 => "its input ended",
        2 => "it could not bind its port",
        3 => "it lost the hub's heartbeat",
        4 => "the channel broke a rule",
        5 => "its writes to the hub stalled",
        6 => "its stream ids ran out",
        137 => "killed, most likely at its memory limit",
        _ => "an unexpected exit",
    }
}

/// The reason a job ends `infra: proxy` when its relay channel ended (END) before it: how the channel ended, the
/// sidecar's exit CODE and its meaning (channel review N3), and the last line of its STDERR.
pub fn end_reason(end: &End, code: Option<i32>, stderr: &str) -> String {
    let how = match end {
        End::Eof => "the sidecar exited".to_string(),
        End::Violation(v) => format!("a channel violation ({v})"),
        End::Ready(r) => format!("the relay never got ready ({r})"),
        End::Stalled => "the job's relay stopped reading".to_string(),
        End::IdsUsedUp => "the job used up its relay's 2³⁰ connections".to_string(),
    };
    let code = match code {
        Some(c) => format!("; the sidecar exited {c}: {}", exit_meaning(c)),
        None => "; the sidecar did not exit when asked".to_string(),
    };
    let last = stderr.lines().rev().find(|l| !l.trim().is_empty());
    match last {
        Some(l) => format!("{how}{code} ({})", l.trim()),
        None => format!("{how}{code}"),
    }
}

/// The job's proxy: the allow-list ALLOW and the pins PINS, and at most twice the relay's streams open at once (S4's
/// backstop; the sidecar holds the 65th connection until one closes).
pub fn proxy_config(
    allow: Vec<gleipnir::net::host::Target>,
    pins: &[(String, IpAddr)],
) -> gleipnir::net::proxy::ProxyConfig {
    gleipnir::net::proxy::ProxyConfig {
        allow,
        pinned: pins.to_vec(),
        max_conns: 2 * drgnx_px::frame::MAX_STREAMS,
        ..Default::default()
    }
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
    sidecar: Option<Sidecar>,
    names: NetNames,
    job: String,
    channel: JoinHandle<End>,
    log: JoinHandle<()>,
    podman: PathBuf,
    env: Vec<(OsString, OsString)>,
}

impl JobNetwork {
    /// How the channel ended; waits while it runs (cancel-safe, so a `select!` arm; await it once).
    pub async fn ended(&mut self) -> End {
        (&mut self.channel).await.unwrap_or(End::Eof)
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

    /// Takes the relay down after the job (S11): `podman rm -f` the job's container first (podman records the job's
    /// dependency on the sidecar), then stop the sidecar.  Answers the sidecar's exit code.
    pub async fn end(self) -> Option<i32> {
        let _ = tokio::process::Command::new(&self.podman)
            .args(["rm", "-f", &self.job])
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;
        let code = match self.sidecar {
            Some(s) => s.stop(&self.podman, &self.names.sidecar, &self.env).await,
            None => None,
        };
        self.channel.abort();
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
    let (ptx, mut prx) = tokio::sync::mpsc::channel(16);
    // nobody is asked about a denied host here; the channel only has to stay drained
    tokio::spawn(async move { while prx.recv().await.is_some() {} });
    let handle = proxy::start(
        proxy_config(allow, pins),
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
            sidecar: Some(sidecar),
            names,
            job: container::name_of(id)?,
            channel,
            log,
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

    #[test]
    fn the_jobs_proxy_cap_is_twice_the_streams() {
        assert_eq!(proxy_config(vec![], &[]).max_conns, 128);
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
