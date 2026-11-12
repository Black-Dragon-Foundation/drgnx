//! A session inside a port block (spec §21). Under macOS's Seatbelt a session's adapter and program may use only
//! its block's loopback ports ([`super::ports`]), and the adapters' launch modes bind ephemeral ports of their own.
//! So a launch configuration becomes an attach the hub sets up itself:
//!
//! - **debugpy:** the adapter listens for the client on the block's first port; the attach has
//!   `listen: {host, port: second}`, and the hub starts the program as
//!   `python -m debugpy --connect 127.0.0.1:SECOND --configure-subProcess BOOL (PROGRAM | -m MODULE) ARGS…` once the
//!   adapter listens there (debugpy connects once, without retrying). Children connect to the same port.
//! - **js-debug:** the hub starts `node RUNTIME-ARGS… --inspect-brk=127.0.0.1:SECOND PROGRAM ARGS…`, which waits at
//!   its first line, and the attach names that port. Children call `inspector.open(0)`: the preload
//!   (`etc/debug-node-preload.js`, first in `NODE_OPTIONS`) maps it to the block's remaining ports, each claimed
//!   with an O_EXCL file under the session's tmp, so the block's size caps the children (six). js-debug's
//!   bootloader reaches the program only after the attach, while it runs: the preload makes a child started before
//!   that wait for it (`DRGNX_DEBUG_WAIT_BOOTLOADER`).
//! - Every other adapter is refused here (lldb-dap runs outside the sandbox on macOS; delve needs ptrace).
//!
//! TMPDIR is the session's tmp for the program, so js-debug's inspector socket lands there.

use super::adapters::{self, Adapter, Env, Found};
use super::ports::Block;
use super::session::{NoProc, Proc, Request, Sig};
use super::{BoxFut, Connected, Launcher};
use draugr::Spec;
use serde_json::{Map, Value, json};
use std::ffi::OsString;
use std::future::Future;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The program the hub starts beside the adapter.
#[derive(Clone, Debug, PartialEq)]
pub struct Debuggee {
    pub argv: Vec<String>,
    /// Added to the session's environment.
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
    /// Start it only once this port listens (the adapter's listener for it); `None`: before the adapter.
    pub after_listen: Option<u16>,
}

/// How a session runs inside its block.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    /// The adapter's command line; it listens for the hub on `port`.
    pub adapter: Vec<String>,
    pub port: u16,
    pub request: Request,
    /// The attach's arguments.
    pub arguments: Value,
    pub debuggee: Debuggee,
}

/// The block's ports for the program's children (js-debug's preload).
pub const CLAIMS_DIR: &str = "drgnx-debug-ports";

fn strs(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn env_of(config: &Value) -> Vec<(String, String)> {
    config
        .get("env")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                .collect()
        })
        .unwrap_or_default()
}

/// CONFIG without KEYS (the program's, which the attach does not take), with REQUEST set.
fn attach_args(config: &Value, keys: &[&str]) -> Map<String, Value> {
    let mut m = match super::launch::adapter_arguments(config) {
        Value::Object(m) => m,
        _ => Map::new(),
    };
    for k in keys {
        m.remove(*k);
    }
    m.insert("request".into(), json!("attach"));
    m
}

/// The plan for CONFIG (a resolved `launch` configuration) of ADAPTER (found at FOUND, tools in ENV) inside the block
/// PORTS (at least 3), with the session's TMP and the Node PRELOAD file.
pub fn plan(
    adapter: &Adapter,
    found: &Found,
    env: &Env,
    config: &Value,
    ports: &[u16],
    tmp: &Path,
    preload: &Path,
) -> Result<Plan, String> {
    if config.get("request").and_then(Value::as_str) != Some("launch") {
        return Err(format!(
            "{} inside a port block runs a launch configuration only (an attach to a running process cannot be moved into the sandbox)",
            adapter.name
        ));
    }
    let [a, b, children @ ..] = ports else {
        return Err("a port block needs at least three ports".into());
    };
    let cwd = config
        .get("cwd")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or_default();
    let mut denv = env_of(config);
    denv.retain(|(k, _)| k != "TMPDIR");
    denv.push(("TMPDIR".into(), tmp.display().to_string()));
    let s = |k: &str| config.get(k).and_then(Value::as_str);
    match adapter.id.as_str() {
        "debugpy" => {
            let Found::Python(py) = found else {
                return Err("debugpy: its Python was not found".into());
            };
            let py = py.display().to_string();
            let target: Vec<String> = match (s("program"), s("module")) {
                (Some(p), _) => vec![p.to_owned()],
                (None, Some(m)) => vec!["-m".into(), m.to_owned()],
                (None, None) => {
                    return Err(
                        "debugpy inside a port block needs a program or a module to start".into(),
                    );
                }
            };
            let python = match config.get("python") {
                Some(Value::String(p)) => vec![p.clone()],
                Some(Value::Array(_)) => strs(config.get("python")),
                _ => vec![py.clone()],
            };
            let sub = config
                .get("subProcess")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let mut argv = python;
            argv.extend([
                "-m".into(),
                "debugpy".into(),
                "--connect".into(),
                format!("127.0.0.1:{b}"),
                "--configure-subProcess".into(),
                sub.to_string(),
            ]);
            argv.extend(target);
            argv.extend(strs(config.get("args")));
            let mut args = attach_args(
                config,
                &[
                    "program",
                    "module",
                    "args",
                    "python",
                    "console",
                    "env",
                    "envFile",
                    "stopOnEntry",
                    "sudo",
                ],
            );
            args.insert("listen".into(), json!({"host": "127.0.0.1", "port": b}));
            args.insert("subProcess".into(), json!(sub));
            // what the program prints comes back as output events (nobody reads its stdout)
            args.entry("redirectOutput").or_insert(json!(true));
            Ok(Plan {
                adapter: vec![
                    py,
                    "-m".into(),
                    "debugpy.adapter".into(),
                    "--host".into(),
                    "127.0.0.1".into(),
                    "--port".into(),
                    a.to_string(),
                ],
                port: *a,
                request: Request::Attach,
                arguments: Value::Object(args),
                debuggee: Debuggee {
                    argv,
                    env: denv,
                    cwd,
                    after_listen: Some(*b),
                },
            })
        }
        "js-debug" => {
            let program = s("program").ok_or("js-debug inside a port block needs a program")?;
            let (_, adapter_argv) = adapters::command(adapter, found, env, Some(*a))?;
            let mut argv = vec![s("runtimeExecutable").unwrap_or("node").to_owned()];
            argv.extend(strs(config.get("runtimeArgs")));
            argv.push(format!("--inspect-brk=127.0.0.1:{b}"));
            argv.push(program.to_owned());
            argv.extend(strs(config.get("args")));
            let theirs = denv
                .iter()
                .position(|(k, _)| k == "NODE_OPTIONS")
                .map(|i| denv.remove(i).1);
            let mut options = format!("--require {}", preload.display());
            if let Some(o) = theirs.filter(|o| !o.is_empty()) {
                options = format!("{options} {o}");
            }
            denv.push(("NODE_OPTIONS".into(), options));
            denv.push((
                "DRGNX_DEBUG_PORTS".into(),
                children
                    .iter()
                    .map(u16::to_string)
                    .collect::<Vec<_>>()
                    .join(","),
            ));
            denv.push((
                "DRGNX_DEBUG_CLAIMS".into(),
                tmp.join(CLAIMS_DIR).display().to_string(),
            ));
            let auto = config
                .get("autoAttachChildProcesses")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            if auto {
                // js-debug writes its bootloader into the program's NODE_OPTIONS only once attached (100-200 ms on
                // the macOS runner) and answers the attach only after configurationDone, so the program already
                // runs: the preload makes a child started before that wait for it
                denv.push(("DRGNX_DEBUG_WAIT_BOOTLOADER".into(), "1".into()));
            }
            let mut args = attach_args(
                config,
                &[
                    "program",
                    "args",
                    "runtimeExecutable",
                    "runtimeArgs",
                    "runtimeVersion",
                    "env",
                    "envFile",
                    "console",
                    "outputCapture",
                    "stopOnEntry",
                    "killBehavior",
                ],
            );
            args.insert("address".into(), json!("127.0.0.1"));
            args.insert("port".into(), json!(b));
            args.insert("autoAttachChildProcesses".into(), json!(auto));
            args.insert("continueOnAttach".into(), json!(true));
            Ok(Plan {
                adapter: adapter_argv,
                port: *a,
                request: Request::Attach,
                arguments: Value::Object(args),
                debuggee: Debuggee {
                    argv,
                    env: denv,
                    cwd,
                    after_listen: None,
                },
            })
        }
        _ => Err(format!(
            "{} does not run inside a port block (lldb-dap runs outside the sandbox on macOS; delve needs ptrace)",
            adapter.name
        )),
    }
}

/// The Node preload, written into each session's tmp (the program reads it there, inside the sandbox).
pub const PRELOAD: &str = include_str!("../../../../../etc/debug-node-preload.js");
/// Its name in the session's tmp.
pub const PRELOAD_NAME: &str = "drgnx-debug-preload.js";
/// How long the hub waits for debugpy's listener before it gives up and stops the adapter.
pub const DEBUGGEE_LISTEN_WITHIN: Duration = Duration::from_secs(30);

/// A session's adapter and program inside its block. The block is held for the launcher's life (the session's).
pub struct Blocked {
    plan: Plan,
    /// The session's environment, under the plan's additions.
    base: Vec<(OsString, OsString)>,
    cwd: PathBuf,
    _block: Option<Block>,
}

impl Blocked {
    /// A launcher for PLAN with the environment BASE in CWD (the plan's own `cwd` wins), holding BLOCK.
    pub fn new(
        plan: Plan,
        base: Vec<(OsString, OsString)>,
        cwd: PathBuf,
        block: Option<Block>,
    ) -> Blocked {
        Blocked {
            plan,
            base,
            cwd,
            _block: block,
        }
    }

    fn spec(&self, argv: &[String], add: &[(String, String)], cwd: &Path) -> Result<Spec, String> {
        let (program, args) = argv.split_first().ok_or("an empty command line")?;
        let mut env: Vec<(OsString, OsString)> = self
            .base
            .iter()
            .filter(|(k, _)| !add.iter().any(|(a, _)| k.as_os_str() == a.as_str()))
            .cloned()
            .collect();
        env.extend(add.iter().map(|(k, v)| (k.into(), v.into())));
        Ok(Spec {
            program: PathBuf::from(program),
            args: args.iter().map(OsString::from).collect(),
            env,
            cwd: Some(cwd.to_path_buf()),
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        })
    }

    fn debuggee_spec(&self) -> Result<Spec, String> {
        let d = &self.plan.debuggee;
        let cwd = if d.cwd.as_os_str().is_empty() {
            self.cwd.clone()
        } else {
            d.cwd.clone()
        };
        self.spec(&d.argv, &d.env, &cwd)
    }
}

/// The program, started; nobody reads its stdout (the adapters send what it prints as output events): drained.
async fn start_debuggee(spec: Spec) -> Result<draugr::Child, String> {
    let shown = spec.program.display().to_string();
    let mut child = draugr::spawn(spec)
        .await
        .map_err(|e| format!("{shown}: {e}"))?;
    if let Some(mut out) = child.take_stdout() {
        crate::clock::spawn("debug:debuggee-stdout", async move {
            let _ = tokio::io::copy(&mut out, &mut tokio::io::sink()).await;
        });
    }
    Ok(child)
}

/// The adapter and the program the hub started: both get the session's signals; once the adapter is gone the
/// program goes too (the hub started it for this session alone).
struct Pair {
    adapter: draugr::Child,
    debuggee: Arc<Mutex<Option<draugr::Child>>>,
    starter: Option<tokio::task::JoinHandle<()>>,
}

impl Proc for Pair {
    fn signal(&mut self, sig: Sig) {
        Proc::signal(&mut self.adapter, sig);
        if let Some(d) = self
            .debuggee
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_mut()
        {
            Proc::signal(d, sig);
        }
    }
    fn wait(&mut self) -> Pin<Box<dyn Future<Output = ()> + Send + '_>> {
        Box::pin(async move {
            Proc::wait(&mut self.adapter).await;
            if let Some(s) = self.starter.take() {
                s.abort();
            }
            let d = self
                .debuggee
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .take();
            if let Some(mut d) = d {
                Proc::signal(&mut d, Sig::Kill);
                Proc::wait(&mut d).await;
            }
        })
    }
    fn stderr_tail(&self) -> String {
        self.adapter.stderr_tail()
    }
}

impl Drop for Pair {
    fn drop(&mut self) {
        if let Some(s) = self.starter.take() {
            s.abort();
        }
    }
}

fn local(port: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], port))
}

impl Launcher for Blocked {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let slot: Arc<Mutex<Option<draugr::Child>>> = Arc::default();
            // js-debug's program waits at its first line for the attach: it starts first
            if self.plan.debuggee.after_listen.is_none() {
                let d = start_debuggee(self.debuggee_spec()?).await?;
                *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(d);
            }
            let adapter = draugr::spawn(self.spec(&self.plan.adapter, &[], &self.cwd)?)
                .await
                .map_err(|e| format!("{}: {e}", self.plan.adapter[0]))?;
            let adapter_pid = adapter.id();
            let mut pair = Pair {
                adapter,
                debuggee: slot.clone(),
                starter: None,
            };
            let s = match super::wire::connect_tcp(local(self.plan.port)).await {
                Ok(s) => s,
                Err(e) => {
                    pair.signal(Sig::Kill);
                    pair.wait().await;
                    return Err(e);
                }
            };
            // debugpy's program connects once, without retrying: it starts when the adapter listens for it (after
            // the attach); a connection that only probes is dropped by debugpy and it goes on listening
            if let Some(port) = self.plan.debuggee.after_listen {
                let spec = self.debuggee_spec()?;
                let slot = slot.clone();
                pair.starter = Some(crate::clock::spawn("debug:debuggee-start", async move {
                    match super::wire::connect_tcp_within(local(port), DEBUGGEE_LISTEN_WITHIN).await
                    {
                        Ok(probe) => drop(probe),
                        Err(e) => {
                            tracing::debug!(target: "drgnx::debug", "the program was not started: {e}");
                            let _ = draugr::Signaller::kill(
                                &draugr::RealSignaller,
                                -adapter_pid,
                                libc::SIGTERM,
                            );
                            return;
                        }
                    }
                    match start_debuggee(spec).await {
                        Ok(d) => *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(d),
                        Err(e) => {
                            tracing::debug!(target: "drgnx::debug", "the program did not start: {e}");
                            let _ = draugr::Signaller::kill(
                                &draugr::RealSignaller,
                                -adapter_pid,
                                libc::SIGTERM,
                            );
                        }
                    }
                }));
            }
            Ok(super::wire::over_tcp(s, Box::new(pair)))
        })
    }

    /// js-debug's children (`startDebugging`) are second connections to the adapter's port.
    fn child(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            Ok(super::wire::over_tcp(
                super::wire::connect_tcp(local(self.plan.port)).await?,
                Box::new(NoProc),
            ))
        })
    }
}
