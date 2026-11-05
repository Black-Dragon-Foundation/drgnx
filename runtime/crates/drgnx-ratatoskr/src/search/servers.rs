//! The wizard's backend: TEI and Ollama as embedders, started only on a confirmed request.
//!
//! Nothing here runs by itself. The hub's idle paths, timers and tiers never reach [`start`]; the three methods
//! (`search/server-plan`, `-start`, `-stop`) are the user's, and a start needs `confirm: true`. The host is a value
//! ([`Host`], probed once per request by [`Host::probe`]) and the tools are a trait ([`Run`]), so a test builds the host
//! and records the commands instead of running them.
//!
//! - **TEI** (Linux with podman and a systemd user session; not inside a container): a Quadlet unit
//!   `$XDG_CONFIG_HOME/containers/systemd/drgnx-tei.container` with the CPU image, or the GPU tag of the card when the
//!   NVIDIA CDI device is present; the container's memory is capped (4 GiB CPU, 2 GiB GPU host side), the port is
//!   published on `127.0.0.1` only, the model cache is a named volume. No `[Install]`: it never starts at login.
//! - **Ollama** (where `ollama` is on the PATH): its own service is started only when it does not answer, then the
//!   embedding model is pulled.
//!
//! The hub writes no settings. A start answers the provider entry; the editor's settings writer adds it.

use runstav::methods::search as w;
use runstav::methods::search::ServerKind;
use runstav::paths::Env;
use std::path::{Path, PathBuf};

const TEI_IMAGE: &str = "ghcr.io/huggingface/text-embeddings-inference";
const TEI_VERSION: &str = "1.9";
const TEI_MODEL: &str = "Qwen/Qwen3-Embedding-0.6B";
/// What the weights weigh (bf16, about).
const TEI_BYTES: u64 = 1_190_000_000;
const TEI_PORT: u16 = 8087;
const TEI_UNIT: &str = "drgnx-tei.service";
const OLLAMA_MODEL: &str = "qwen3-embedding:0.6b";
const OLLAMA_BYTES: u64 = 639_000_000;
const OLLAMA_PORT: u16 = 11434;
const OLLAMA_LABEL: &str = "com.ollama.ollama";

/// What the host offers.
#[derive(Clone, Debug)]
pub struct Host {
    pub config_home: PathBuf,
    pub macos: bool,
    pub uid: u32,
    pub in_container: bool,
    /// A systemd user session answers (its private socket exists).
    pub systemd_user: bool,
    pub podman: bool,
    /// The CDI spec for NVIDIA devices is installed.
    pub cdi_nvidia: bool,
    /// The card's compute capability, e.g. `8.6`.
    pub gpu_compute: Option<String>,
    /// `ollama` on the PATH.
    pub ollama: Option<PathBuf>,
    pub ollama_running: bool,
}

fn on_path(env: &Env, name: &str) -> Option<PathBuf> {
    env.vars
        .get("PATH")?
        .split(':')
        .map(|d| Path::new(d).join(name))
        .find(|p| p.is_file())
}

impl Host {
    /// This machine, read-only: files, the PATH and one loopback connect. A start would run nothing yet.
    pub fn probe(env: &Env) -> Host {
        let var = |k: &str| env.vars.get(k).filter(|v| !v.is_empty());
        let config_home = var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| var("HOME").map(|h| Path::new(h).join(".config")))
            .unwrap_or_default();
        let cdi_nvidia = [
            "/etc/cdi/nvidia.yaml",
            "/var/run/cdi/nvidia.yaml",
            "/run/cdi/nvidia.yaml",
        ]
        .iter()
        .any(|p| Path::new(p).exists());
        let gpu_compute = if cdi_nvidia {
            on_path(env, "nvidia-smi").and_then(|smi| {
                let out = std::process::Command::new(smi)
                    .args(["--query-gpu=compute_cap", "--format=csv,noheader"])
                    .output()
                    .ok()?;
                String::from_utf8_lossy(&out.stdout)
                    .lines()
                    .next()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty())
            })
        } else {
            None
        };
        Host {
            config_home,
            macos: cfg!(target_os = "macos"),
            uid: env.uid,
            in_container: Path::new("/run/.containerenv").exists()
                || Path::new("/.dockerenv").exists(),
            systemd_user: var("XDG_RUNTIME_DIR")
                .is_some_and(|r| Path::new(r).join("systemd/private").exists()),
            podman: on_path(env, "podman").is_some(),
            cdi_nvidia,
            gpu_compute,
            ollama: on_path(env, "ollama"),
            ollama_running: std::net::TcpStream::connect_timeout(
                &std::net::SocketAddr::from(([127, 0, 0, 1], OLLAMA_PORT)),
                std::time::Duration::from_millis(200),
            )
            .is_ok(),
        }
    }
}

/// Runs a tool. A failure is the text to show.
pub trait Run {
    fn run(&self, prog: &str, args: &[String]) -> Result<(), String>;
}

/// Why a request did not go ahead.
#[derive(Debug)]
pub enum Refused {
    /// `confirm` was not true.
    Confirm,
    /// This host cannot run it; the reason.
    Unavailable(String),
    /// A command failed; its text.
    Failed(String),
}

/// A command as the plan shows it and a start runs it.
type Cmd = Vec<String>;

fn cmd(parts: &[&str]) -> Cmd {
    parts.iter().map(|s| (*s).to_string()).collect()
}

/// The GPU image tag of a compute capability, none when no image fits the card.
fn gpu_tag(compute: &str) -> Option<&'static str> {
    Some(match compute {
        "7.5" => "75-",
        "8.0" => "",
        "8.6" => "86-",
        "8.9" => "89-",
        "9.0" => "hopper-",
        _ => return None,
    })
}

struct TeiShape {
    gpu: bool,
    memory: &'static str,
    image: String,
}

fn tei_shape(host: &Host) -> TeiShape {
    let tag = host
        .cdi_nvidia
        .then(|| host.gpu_compute.as_deref().and_then(gpu_tag))
        .flatten();
    match tag {
        Some(t) => TeiShape {
            gpu: true,
            memory: "2g",
            image: format!("{TEI_IMAGE}:{t}{TEI_VERSION}"),
        },
        None => TeiShape {
            gpu: false,
            memory: "4g",
            image: format!("{TEI_IMAGE}:cpu-{TEI_VERSION}"),
        },
    }
}

fn tei_unit_path(host: &Host) -> PathBuf {
    host.config_home
        .join("containers/systemd/drgnx-tei.container")
}

fn tei_unit(host: &Host) -> String {
    let s = tei_shape(host);
    let device = if s.gpu {
        "AddDevice=nvidia.com/gpu=all\n"
    } else {
        ""
    };
    format!(
        "[Unit]\nDescription=drgnx text embeddings (TEI)\n\n\
         [Container]\nImage={}\nContainerName=drgnx-tei\n{device}\
         PodmanArgs=--memory={}\nPublishPort=127.0.0.1:{TEI_PORT}:80\nVolume=drgnx-tei-cache:/data\n\
         Exec=--model-id {TEI_MODEL} --port 80\n\n\
         [Service]\nRestart=on-failure\nTimeoutStartSec=900\n",
        s.image, s.memory
    )
}

fn tei_unavailable(host: &Host) -> Option<String> {
    if host.macos {
        Some("TEI runs on Linux only; use Ollama".into())
    } else if host.in_container {
        Some("this is inside a container: a Quadlet service needs the host's systemd".into())
    } else if !host.podman {
        Some("podman is not installed".into())
    } else if !host.systemd_user {
        Some("there is no systemd user session to run the service".into())
    } else {
        None
    }
}

fn ollama_unavailable(host: &Host) -> Option<String> {
    host.ollama
        .is_none()
        .then(|| "ollama is not installed (not on the PATH)".into())
}

fn unavailable(host: &Host, kind: ServerKind) -> Option<String> {
    match kind {
        ServerKind::Tei => tei_unavailable(host),
        ServerKind::Ollama => ollama_unavailable(host),
    }
}

/// The commands a start runs, in order.
fn commands(host: &Host, kind: ServerKind) -> Vec<Cmd> {
    match kind {
        ServerKind::Tei => vec![
            cmd(&["systemctl", "--user", "daemon-reload"]),
            cmd(&["systemctl", "--user", "start", TEI_UNIT]),
        ],
        ServerKind::Ollama => {
            let mut v = Vec::new();
            if !host.ollama_running {
                v.push(if host.macos {
                    cmd(&["launchctl", "start", OLLAMA_LABEL])
                } else {
                    cmd(&["systemctl", "--user", "start", "ollama.service"])
                });
            }
            let bin = host
                .ollama
                .as_deref()
                .map_or_else(|| "ollama".to_string(), |p| p.display().to_string());
            v.push(vec![bin, "pull".into(), OLLAMA_MODEL.into()]);
            v
        }
    }
}

/// What a start would do. Runs and writes nothing.
pub fn plan(host: &Host, kind: ServerKind) -> w::ServerPlan {
    let why = unavailable(host, kind);
    let shown = |c: Vec<Cmd>| c.iter().map(|c| c.join(" ")).collect::<Vec<_>>();
    if why.is_some() {
        return w::ServerPlan {
            available: false,
            why,
            gpu: false,
            memory_cap: String::new(),
            image: None,
            model: match kind {
                ServerKind::Tei => TEI_MODEL,
                ServerKind::Ollama => OLLAMA_MODEL,
            }
            .into(),
            bytes: None,
            unit_path: None,
            commands: Vec::new(),
        };
    }
    match kind {
        ServerKind::Tei => {
            let s = tei_shape(host);
            w::ServerPlan {
                available: true,
                why: None,
                gpu: s.gpu,
                memory_cap: s.memory.into(),
                image: Some(s.image),
                model: TEI_MODEL.into(),
                bytes: Some(TEI_BYTES),
                unit_path: Some(tei_unit_path(host).display().to_string()),
                commands: shown(commands(host, kind)),
            }
        }
        ServerKind::Ollama => w::ServerPlan {
            available: true,
            why: None,
            gpu: false,
            memory_cap: String::new(),
            image: None,
            model: OLLAMA_MODEL.into(),
            bytes: Some(OLLAMA_BYTES),
            unit_path: None,
            commands: shown(commands(host, kind)),
        },
    }
}

fn provider(kind: ServerKind) -> w::ProviderEntry {
    let (id, k, port) = match kind {
        ServerKind::Tei => ("tei", "tei", TEI_PORT),
        ServerKind::Ollama => ("ollama", "ollama", OLLAMA_PORT),
    };
    w::ProviderEntry {
        id: id.into(),
        kind: k.into(),
        base: format!("http://127.0.0.1:{port}"),
        auth: "none".into(),
        caps: vec!["embed".into()],
    }
}

fn run_all(run: &dyn Run, cmds: &[Cmd]) -> Result<(), Refused> {
    for c in cmds {
        run.run(&c[0], &c[1..]).map_err(Refused::Failed)?;
    }
    Ok(())
}

/// Starts the server. Refused without `confirm`, and where the host cannot run it; either way nothing is written and
/// nothing runs.
pub fn start(
    host: &Host,
    run: &dyn Run,
    kind: ServerKind,
    confirm: bool,
) -> Result<w::ServerStarted, Refused> {
    if !confirm {
        return Err(Refused::Confirm);
    }
    if let Some(why) = unavailable(host, kind) {
        return Err(Refused::Unavailable(why));
    }
    if kind == ServerKind::Tei {
        let path = tei_unit_path(host);
        let dir = path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(dir)
            .and_then(|()| std::fs::write(&path, tei_unit(host)))
            .map_err(|e| Refused::Failed(format!("{}: {e}", path.display())))?;
    }
    run_all(run, &commands(host, kind))?;
    Ok(w::ServerStarted {
        started: true,
        unit: match kind {
            ServerKind::Tei => TEI_UNIT.into(),
            ServerKind::Ollama if host.macos => OLLAMA_LABEL.into(),
            ServerKind::Ollama => "ollama.service".into(),
        },
        provider: provider(kind),
    })
}

/// Stops what a start began: the TEI service, or Ollama's embedding model (Ollama's own service is the user's).
pub fn stop(host: &Host, run: &dyn Run, kind: ServerKind) -> Result<bool, Refused> {
    if let Some(why) = unavailable(host, kind) {
        return Err(Refused::Unavailable(why));
    }
    let c = match kind {
        ServerKind::Tei => cmd(&["systemctl", "--user", "stop", TEI_UNIT]),
        ServerKind::Ollama => {
            let bin = host
                .ollama
                .as_deref()
                .map_or_else(|| "ollama".to_string(), |p| p.display().to_string());
            vec![bin, "stop".into(), OLLAMA_MODEL.into()]
        }
    };
    run_all(run, &[c])?;
    Ok(true)
}

/// The hub's runner: the real tools.
pub struct System;

impl Run for System {
    fn run(&self, prog: &str, args: &[String]) -> Result<(), String> {
        let out = std::process::Command::new(prog)
            .args(args)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("{prog}: {e}"))?;
        if out.status.success() {
            return Ok(());
        }
        let err = String::from_utf8_lossy(&out.stderr);
        let tail: String = err
            .trim()
            .chars()
            .rev()
            .take(300)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        Err(format!(
            "{prog} {} failed ({}): {tail}",
            args.join(" "),
            out.status
        ))
    }
}

/// Test-hooks runner: appends each command to FILE and runs nothing.
#[cfg(feature = "test-hooks")]
pub struct Record(pub PathBuf);

#[cfg(feature = "test-hooks")]
impl Run for Record {
    fn run(&self, prog: &str, args: &[String]) -> Result<(), String> {
        use std::io::Write;
        if let Some(d) = self.0.parent() {
            std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        }
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.0)
            .map_err(|e| e.to_string())?;
        writeln!(f, "{prog} {}", args.join(" ")).map_err(|e| e.to_string())
    }
}
