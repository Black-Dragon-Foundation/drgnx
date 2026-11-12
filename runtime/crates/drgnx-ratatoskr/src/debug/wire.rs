//! The `debug/*` methods (runstav `methods::debug`): the picker's configurations, starting one (inputs and trust first),
//! the controls, frame selection and trust; the adapters started over stdio or TCP, or reached at `debugServer`; and
//! `runInTerminal`'s terminals through the hub's [`crate::term::Terms`].

use super::adapters::{self, Adapter, Table, Transport};
use super::breakpoints::Op as BpOp;
use super::launch::{self, LaunchFile, Need, Os, Vars};
use super::session::{NoProc, Op, Request, Start};
use super::{BoxFut, Connected, Debug, Launcher, Opened, Terminals};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug::{
    DebugBreakpointOp, DebugBreakpoints, DebugBreakpointsView, DebugConfig, DebugConfigList,
    DebugConfigs, DebugControl, DebugFileError, DebugInstall, DebugMissing, DebugRunToCursor,
    DebugSelect, DebugSource, DebugSourceText, DebugStart, DebugStarted, DebugTrust,
};
use runstav::types::JsonObject;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::ffi::OsString;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

/// The largest launch.json read, in bytes.
pub const LAUNCH_MAX: u64 = 1 << 20;
/// How long a TCP adapter has to start listening.
pub const LISTEN_WITHIN: Duration = Duration::from_secs(5);

/// The debug state the front keeps: the sessions (made on first use), the trusted roots, each root's last start.
#[derive(Default)]
pub struct Hub {
    debug: OnceLock<Debug>,
    trusted: Mutex<BTreeSet<String>>,
    last: Mutex<HashMap<String, String>>,
    /// The what-if forks (`fork_wire`), made on first use.
    pub(super) forks: OnceLock<super::fork_hub::Forks>,
    /// The bisects over the edit history (`debug/bisect*`).
    pub(super) bisects: super::bisect_wire::Bisects,
    /// The origin trails (`debug/origin`).
    pub(super) origins: super::origin_wire::Origins,
}

impl Hub {
    pub(crate) fn debug(&self, front: &Front) -> &Debug {
        self.debug.get_or_init(|| {
            let d = Debug::with_store(
                front.editors.clone(),
                Arc::new(TermDoor {
                    terms: front.core.terms.clone(),
                    base: front.shell_env.vars_os(),
                }),
                Some(
                    runstav::paths::state_dir(&front.shell_env.paths_env())
                        .join("debug-breakpoints"),
                ),
            );
            // every session is recorded (spec §19.2)
            d.record_into(super::runs_wire::opts(front));
            d
        })
    }

    /// The front, once it is in its `Arc`: a bisect's jobs outlive the call that started it.
    pub fn bind(&self, front: &Arc<Front>) {
        self.bisects.bind(front);
        // a project that starts debugging: its agents get the debugger's tools in their running sessions
        let weak = Arc::downgrade(front);
        self.debug(front).on_state(Arc::new(move |roots| {
            if let Some(f) = weak.upgrade() {
                crate::clock::spawn("sessions:debug-tools", async move {
                    f.mcp.debug_seen(roots).await;
                });
            }
        }));
        self.origins
            .set_replay(Arc::new(super::origin_wire::ForkReplay {
                front: Arc::downgrade(front),
            }));
    }

    /// The roots that debug (a live session's or a recorded run's), for the agents' tool lists.
    pub fn debugged_roots(&self, front: &Front) -> Vec<String> {
        self.debug(front).debugged_roots()
    }

    pub(super) fn is_trusted(&self, root: &str) -> bool {
        self.trusted.lock().expect("debug trust").contains(root)
    }

    /// The hub is stopping: every session stops (children first).
    pub async fn shutdown(&self) {
        if let Some(d) = self.debug.get() {
            d.shutdown().await;
        }
    }
}

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

fn bad(path: &str, message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// ROOT's `.vscode/launch.json`: none when there is none; a syntax error with its place.
fn read_launch(root: &str) -> (Option<LaunchFile>, Option<DebugFileError>) {
    let path = Path::new(root).join(".vscode/launch.json");
    let shown = path.display().to_string();
    let text = match std::fs::metadata(&path) {
        Err(_) => return (None, None),
        Ok(m) if m.len() > LAUNCH_MAX => {
            return (
                None,
                Some(DebugFileError {
                    path: shown,
                    line: 1,
                    col: 1,
                    message: format!("launch.json is larger than {LAUNCH_MAX} bytes"),
                }),
            );
        }
        Ok(_) => match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                return (
                    None,
                    Some(DebugFileError {
                        path: shown,
                        line: 1,
                        col: 1,
                        message: e.to_string(),
                    }),
                );
            }
        },
    };
    match launch::parse(&text) {
        Ok(f) => (Some(f), None),
        Err(e) => (
            None,
            Some(DebugFileError {
                path: shown,
                line: e.line as u32,
                col: e.col as u32,
                message: e.message,
            }),
        ),
    }
}

/// The user's adapters (ADAPTERS, in the table's fields), then drgnx's.
pub(super) fn table(user: &[JsonObject]) -> Result<Table, Error> {
    let mut all = Vec::with_capacity(user.len());
    for (i, a) in user.iter().enumerate() {
        let a: Adapter = serde_json::from_value(Value::Object(a.clone().into_inner()))
            .map_err(|e| bad(&format!("adapters/{i}"), e.to_string()))?;
        all.push(a);
    }
    all.extend(Table::builtin().0);
    Ok(Table(all))
}

fn text(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("").to_owned()
}

fn entry(id: String, source: &str, c: &Value, needs_trust: bool) -> DebugConfig {
    DebugConfig {
        id,
        name: text(c, "name"),
        source: source.into(),
        ty: text(c, "type"),
        request: text(c, "request"),
        needs_trust,
        missing: None,
    }
}

/// Where adapters are looked for: the shell's `PATH` and drgnx's tools folder.
fn adapter_env(front: &Front) -> adapters::Env {
    let path = front
        .shell_env
        .vars_os()
        .iter()
        .find(|(k, _)| k == "PATH")
        .map(|(_, v)| std::env::split_paths(v).collect())
        .unwrap_or_default();
    adapters::Env {
        path,
        tools: tools_dir(front),
    }
}

/// CONFIG's adapter when TABLE has it and it is not found in ENV (a `debugServer` configuration needs none here), with
/// how drgnx installs it.
fn missing_of(table: &Table, env: &adapters::Env, config: &Value) -> Option<DebugMissing> {
    if matches!(launch::debug_server(config), Ok(Some(_))) {
        return None;
    }
    let a = table.for_type(&text(config, "type")).ok()?;
    if adapters::find(a, env).is_some() {
        return None;
    }
    let plan = a
        .install
        .as_ref()
        .filter(|_| !a.not_built_in)
        .and_then(|i| super::install::plan(i, &super::install::platform_key()).ok());
    let (install, command) = match plan {
        Some(super::install::Plan::System(c)) => ("system", Some(c)),
        Some(super::install::Plan::Pip { .. }) => ("pip", None),
        Some(super::install::Plan::Archive { .. }) => ("download", None),
        None => ("none", None),
    };
    Some(DebugMissing {
        adapter: a.id.clone(),
        name: a.name.clone(),
        install: install.into(),
        command,
    })
}

async fn configs(front: &Front, p: DebugConfigs) -> Result<DebugConfigList, Error> {
    let needs_trust = !front.debug.is_trusted(&p.root);
    let (file, error) = read_launch(&p.root);
    let mut out = vec![];
    // an adapter not found marks its rows (the picker offers its install); a table that does not read marks none
    let found = table(&p.adapters).ok().map(|t| (t, adapter_env(front)));
    let mark = |mut e: DebugConfig, c: &Value| {
        if let Some((t, env)) = &found {
            e.missing = missing_of(t, env, c);
        }
        e
    };
    if let Some(f) = &file {
        for i in launch::listed(&f.configs) {
            out.push(mark(
                entry(format!("launch:{i}"), "launch", &f.configs[i], needs_trust),
                &f.configs[i],
            ));
        }
        for i in launch::listed(&f.compounds) {
            out.push(entry(
                format!("compound:{i}"),
                "compound",
                &f.compounds[i],
                needs_trust,
            ));
        }
    }
    for (i, c) in p.user.iter().enumerate() {
        let c = Value::Object(c.clone().into_inner());
        out.push(mark(
            entry(format!("user:{i}"), "user", &c, needs_trust),
            &c,
        ));
    }
    if let Some(lang) = &p.language {
        for (i, c) in table(&p.adapters)?.defaults_for(lang).iter().enumerate() {
            out.push(mark(
                entry(format!("default:{i}"), "default", c, needs_trust),
                c,
            ));
        }
    }
    let last = front
        .debug
        .last
        .lock()
        .expect("debug last")
        .get(&p.root)
        .cloned();
    Ok(DebugConfigList {
        configs: out,
        last,
        error,
    })
}

/// The configuration ID names, and the inputs it may use.
pub(super) fn config_of(p: &DebugStart, table: &Table) -> Result<(Value, Vec<Value>), Error> {
    let (kind, n) = p
        .config
        .split_once(':')
        .ok_or_else(|| bad("config", "launch:N, user:N, default:N or compound:N"))?;
    let n: usize = n
        .parse()
        .map_err(|_| bad("config", "launch:N, user:N, default:N or compound:N"))?;
    let gone = || bad("config", format!("no configuration {}", p.config));
    match kind {
        "launch" => {
            let (file, error) = read_launch(&p.root);
            if let Some(e) = error {
                return Err(err(format!(
                    "{}:{}:{}: {}",
                    e.path, e.line, e.col, e.message
                )));
            }
            let f = file.ok_or_else(gone)?;
            let c = f.configs.get(n).cloned().ok_or_else(gone)?;
            Ok((c, f.inputs))
        }
        "user" => p
            .user
            .get(n)
            .map(|c| (Value::Object(c.clone().into_inner()), vec![]))
            .ok_or_else(gone),
        "default" => {
            let lang = p.language.as_deref().ok_or_else(gone)?;
            table
                .defaults_for(lang)
                .get(n)
                .cloned()
                .map(|c| (c, vec![]))
                .ok_or_else(gone)
        }
        _ => Err(gone()),
    }
}

pub(super) fn need_json(n: &Need) -> Value {
    match n {
        Need::Input {
            id,
            kind,
            description,
            default,
            options,
            password,
        } => json!({"input": {
            "id": id, "kind": kind, "description": description, "default": default,
            "options": options, "password": password,
        }}),
        Need::PickProcess => json!("pickProcess"),
    }
}

pub(super) fn vars(front: &Front, p: &DebugStart) -> Vars {
    let root = PathBuf::from(&p.root);
    let name = root
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let env: HashMap<String, String> = front
        .shell_env
        .vars_os()
        .into_iter()
        .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
        .collect();
    let home = env.get("HOME").map(PathBuf::from).unwrap_or_default();
    let config = launch::CONFIG_NAMES
        .iter()
        .filter_map(|(_, d)| {
            front
                .settings
                .effective(d, Some(&p.root))
                .map(|(v, _)| ((*d).to_owned(), v))
        })
        .collect();
    Vars {
        roots: vec![(name, root)],
        file: p.file.as_ref().map(PathBuf::from),
        line: p.line,
        col: p.col,
        selection: p.selection.clone(),
        home,
        exec_path: std::env::current_exe().unwrap_or_default(),
        default_build_task: std::fs::read_to_string(Path::new(&p.root).join(".vscode/tasks.json"))
            .ok()
            .and_then(|t| super::tasks::parse(&t).ok())
            .and_then(|t| super::tasks::default_build_task(&t)),
        env,
        config,
    }
}

/// Where the adapters drgnx installs live: `<data>/debug-adapters` (its Python venv is `venv/`).
pub(super) fn tools_dir(front: &Front) -> PathBuf {
    runstav::paths::data_dir(&front.shell_env.paths_env()).join("debug-adapters")
}

fn launcher(
    front: &Front,
    root: &str,
    config: &Value,
    adapter: &Adapter,
) -> Result<Arc<dyn Launcher>, String> {
    if let Some(addr) = launch::debug_server(config)? {
        return Ok(Arc::new(Server { addr }));
    }
    let env_os = front.shell_env.vars_os();
    let env = adapter_env(front);
    let found = adapters::find(adapter, &env).ok_or_else(|| {
        format!(
            "{} is not installed: install it with Debug: Install Adapter, or put it on PATH",
            adapter.name
        )
    })?;
    let tcp = adapter.start.as_ref().is_some_and(|s| s.stdio.is_none());
    let port = if tcp {
        Some(adapters::free_port().map_err(|e| format!("no free port: {e}"))?)
    } else {
        None
    };
    let (how, argv) = adapters::command(adapter, &found, &env, port)?;
    Ok(Arc::new(Spawned {
        argv,
        env: env_os,
        cwd: PathBuf::from(root),
        port: (how == Transport::Tcp).then_some(port).flatten(),
    }))
}

async fn start(front: &Front, caller: &Caller, p: DebugStart) -> Result<DebugStarted, Error> {
    if !front.debug.is_trusted(&p.root) {
        return Ok(DebugStarted {
            needs: Some(json!("trust")),
            ..DebugStarted::default()
        });
    }
    if let Some(n) = p.config.strip_prefix("compound:") {
        let n = n.to_owned();
        return Box::pin(start_compound(front, caller, p, &n)).await;
    }
    let table = table(&p.adapters)?;
    let (config, inputs) = config_of(&p, &table)?;
    let config = launch::for_platform(&config, Os::this());
    let answers: HashMap<String, String> = p
        .inputs
        .iter()
        .map(|a| (a.id.clone(), a.value.clone()))
        .collect();
    let needs = launch::needs(&config, &inputs, &answers).map_err(err)?;
    if !needs.is_empty() {
        return Ok(DebugStarted {
            needs: Some(Value::Array(needs.iter().map(need_json).collect())),
            ..DebugStarted::default()
        });
    }
    launch::check_answers(&config, &inputs, &answers).map_err(|e| bad("inputs", e))?;
    let vars = vars(front, &p);
    let config = launch::substitute(&config, &vars, &answers).map_err(err)?;
    let config_hash = super::record::config_hash(&config);
    let ty = text(&config, "type");
    let adapter = table.for_type(&ty).map_err(err)?;
    let subst = |s: &str| match launch::substitute(&Value::String(s.to_owned()), &vars, &answers)? {
        Value::String(s) => Ok(s),
        _ => Ok(s.to_owned()),
    };
    // preLaunchTask: its steps run to the end first; a failure is the start's error. postDebugTask's are checked now,
    // so a wrong name stops the start too
    let root = Path::new(&p.root);
    let steps = super::tasks::before_launch(root, &config, Os::this(), &subst).map_err(err)?;
    let after = super::tasks::after_debug(root, &config, Os::this(), &subst).map_err(err)?;
    run_tasks(front, caller.conn_id, p.terminal, &steps)
        .await
        .map_err(err)?;
    // after the tasks: a TCP adapter's free port is picked just before it starts
    let launcher = launcher(front, &p.root, &config, adapter).map_err(err)?;
    let start = Start {
        name: text(&config, "name"),
        adapter_id: ty,
        request: if text(&config, "request") == "attach" {
            Request::Attach
        } else {
            Request::Launch
        },
        arguments: launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    // the run keeps the start as sent, without the answers to its inputs
    let mut sent = json!(p);
    if let Some(o) = sent.as_object_mut() {
        o.remove("inputs");
    }
    let rec = super::record::Launch {
        config_hash: Some(config_hash),
        start: sent,
        unsaved: p.unsaved.clone(),
        task: super::runs_wire::task_of(front, &p.root),
        ..super::record::Launch::default()
    };
    let id = front
        .debug
        .debug(front)
        .start_with(caller.conn_id, &p.root, start, launcher, rec)
        .await
        .map_err(err)?;
    if !after.is_empty() {
        let d = front.debug.debug(front).clone();
        let env = front.shell_env.vars_os();
        let id = id.clone();
        crate::clock::spawn("debug:post-debug-task", async move {
            d.wait_end(&id).await;
            if let Err(e) = super::tasks::run(&after, &env).await {
                tracing::warn!(target: "drgnx::debug", "postDebugTask of {id}: {e}");
                d.console_say(&id, &format!("postDebugTask failed: {e}"), "important");
            }
        });
    }
    front
        .debug
        .last
        .lock()
        .expect("debug last")
        .insert(p.root, p.config);
    Ok(DebugStarted {
        session: Some(id),
        ..DebugStarted::default()
    })
}

/// Start launch.json's compound N: the inputs of all its members are asked first, its own `preLaunchTask` runs once,
/// then each member starts as `launch:I` (with its own tasks), in the compound's order. A member that fails stops the
/// ones started. With `stopAll`, the end of one stops the others.
async fn start_compound(
    front: &Front,
    caller: &Caller,
    p: DebugStart,
    n: &str,
) -> Result<DebugStarted, Error> {
    let gone = || bad("config", format!("no configuration {}", p.config));
    let n: usize = n.parse().map_err(|_| gone())?;
    let (file, error) = read_launch(&p.root);
    if let Some(e) = error {
        return Err(err(format!(
            "{}:{}:{}: {}",
            e.path, e.line, e.col, e.message
        )));
    }
    let f = file.ok_or_else(gone)?;
    let compound = f.compounds.get(n).cloned().ok_or_else(gone)?;
    let members = launch::compound_members(&compound, &f.configs).map_err(err)?;
    let answers: HashMap<String, String> = p
        .inputs
        .iter()
        .map(|a| (a.id.clone(), a.value.clone()))
        .collect();
    let mut needs: Vec<Value> = vec![];
    for &i in &members {
        let config = launch::for_platform(&f.configs[i], Os::this());
        for need in launch::needs(&config, &f.inputs, &answers).map_err(err)? {
            let j = need_json(&need);
            if !needs.contains(&j) {
                needs.push(j);
            }
        }
    }
    if !needs.is_empty() {
        return Ok(DebugStarted {
            needs: Some(Value::Array(needs)),
            ..DebugStarted::default()
        });
    }
    let vars = vars(front, &p);
    let subst = |s: &str| match launch::substitute(&Value::String(s.to_owned()), &vars, &answers)? {
        Value::String(s) => Ok(s),
        _ => Ok(s.to_owned()),
    };
    let steps = super::tasks::before_launch(Path::new(&p.root), &compound, Os::this(), &subst)
        .map_err(err)?;
    run_tasks(front, caller.conn_id, p.terminal, &steps)
        .await
        .map_err(err)?;
    let d = front.debug.debug(front).clone();
    let mut ids: Vec<String> = vec![];
    for &i in &members {
        let one = DebugStart {
            config: format!("launch:{i}"),
            ..p.clone()
        };
        match Box::pin(start(front, caller, one)).await {
            Ok(DebugStarted {
                session: Some(id), ..
            }) => ids.push(id),
            other => {
                for id in &ids {
                    let _ = d
                        .control(
                            id,
                            Op::Stop {
                                kill_debuggee: None,
                            },
                        )
                        .await;
                }
                return match other {
                    Err(e) => Err(e),
                    Ok(_) => Err(err(format!(
                        "compound {}: {} did not start",
                        text(&compound, "name"),
                        text(&f.configs[i], "name")
                    ))),
                };
            }
        }
    }
    if launch::stop_all(&compound) && ids.len() > 1 {
        let ids = ids.clone();
        crate::clock::spawn("debug:compound-stop-all", async move {
            let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(ids.len());
            for id in &ids {
                let (d, id, tx) = (d.clone(), id.clone(), tx.clone());
                crate::clock::spawn("debug:compound-member", async move {
                    d.wait_end(&id).await;
                    let _ = tx.send(()).await;
                });
            }
            drop(tx);
            // the first to end stops the rest
            if rx.recv().await.is_some() {
                for id in &ids {
                    let _ = d
                        .control(
                            id,
                            Op::Stop {
                                kill_debuggee: None,
                            },
                        )
                        .await;
                }
            }
        });
    }
    front
        .debug
        .last
        .lock()
        .expect("debug last")
        .insert(p.root.clone(), p.config.clone());
    Ok(DebugStarted {
        session: ids.first().cloned(),
        sessions: ids,
        ..DebugStarted::default()
    })
}

async fn control(front: &Front, p: DebugControl) -> Result<bool, Error> {
    let d = front.debug.debug(front);
    let t = p.thread;
    let op = match p.op.as_str() {
        "continue" => Op::Continue { thread: t },
        "pause" => Op::Pause { thread: t },
        "next" => Op::Next { thread: t },
        "step-in" => Op::StepIn { thread: t },
        "step-out" => Op::StepOut { thread: t },
        "restart" => Op::Restart,
        "stop" => Op::Stop {
            kill_debuggee: None,
        },
        "stop-and-kill" => Op::Stop {
            kill_debuggee: Some(true),
        },
        "disconnect" => Op::Disconnect,
        other => return Err(bad("op", format!("no control {other}"))),
    };
    d.control(&p.session, op).await.map_err(err)?;
    Ok(true)
}

async fn select(front: &Front, p: DebugSelect) -> Result<bool, Error> {
    let d = front.debug.debug(front);
    d.control(
        &p.session,
        Op::Select {
            thread: p.thread,
            frame: p.frame,
        },
    )
    .await
    .map_err(err)?;
    Ok(true)
}

async fn trust(front: &Front, p: DebugTrust) -> Result<bool, Error> {
    if p.trusted {
        front
            .debug
            .trusted
            .lock()
            .expect("debug trust")
            .insert(p.root);
        return Ok(true);
    }
    front
        .debug
        .trusted
        .lock()
        .expect("debug trust")
        .remove(&p.root);
    let d = front.debug.debug(front);
    for id in d.in_root(&p.root) {
        let _ = d
            .control(
                &id,
                Op::Stop {
                    kill_debuggee: None,
                },
            )
            .await;
    }
    Ok(true)
}

fn bp_op(o: DebugBreakpointOp) -> Result<BpOp, Error> {
    let id = |o: &DebugBreakpointOp| o.id.ok_or_else(|| bad("op.id", "required"));
    Ok(match o.op.as_str() {
        "add" => BpOp::Add {
            path: o.path.clone().unwrap_or_default(),
            line: o.line.unwrap_or(1),
            enabled: o.enabled.unwrap_or(true),
            condition: o.condition,
            hit: o.hit,
            log: o.log,
        },
        "remove" => BpOp::Remove { id: id(&o)? },
        "edit" => BpOp::Edit {
            id: id(&o)?,
            enabled: o.enabled,
            condition: o.condition,
            hit: o.hit,
            log: o.log,
        },
        "move" => BpOp::Move {
            id: id(&o)?,
            line: o.line.unwrap_or(1),
        },
        "add-function" => BpOp::AddFunction {
            name: o.name.unwrap_or_default(),
            condition: o.condition,
        },
        "remove-function" => BpOp::RemoveFunction {
            name: o.name.unwrap_or_default(),
        },
        other => return Err(bad("op.op", format!("no breakpoint operation {other}"))),
    })
}

async fn breakpoints(
    front: &Front,
    mut p: DebugBreakpoints,
) -> Result<DebugBreakpointsView, Error> {
    let d = front.debug.debug(front);
    // the Run and Debug view's ops over many breakpoints; the answer is PATH's view as for no op
    match p.op.as_ref().map(|o| o.op.as_str()) {
        Some("filter") => {
            if let Some(o) = p.op.take() {
                let (adapter, name) = (o.adapter.unwrap_or_default(), o.name.unwrap_or_default());
                d.set_filter(&p.root, &adapter, &name, o.enabled.unwrap_or(true))
                    .await;
            }
        }
        Some("enable-all") => {
            let on = p.op.take().and_then(|o| o.enabled).unwrap_or(true);
            d.all_breakpoints(&p.root, false, on).await;
        }
        Some("remove-all") => {
            p.op = None;
            d.all_breakpoints(&p.root, true, false).await;
        }
        _ => {}
    }
    let op = p.op.map(bp_op).transpose()?;
    let v = d.breakpoints(&p.root, op, p.path.as_deref()).await;
    serde_json::from_value(v).map_err(|e| err(e.to_string()))
}

async fn run_to_cursor(front: &Front, p: DebugRunToCursor) -> Result<bool, Error> {
    front
        .debug
        .debug(front)
        .run_to_cursor(&p.session, &p.path, p.line)
        .await
        .map_err(err)?;
    Ok(true)
}

/// A frame's source with no file: its text from the adapter.
async fn source(front: &Front, p: DebugSource) -> Result<DebugSourceText, Error> {
    let v = front
        .debug
        .debug(front)
        .source(&p.session, p.reference)
        .await
        .map_err(err)?;
    serde_json::from_value(v).map_err(|e| err(e.to_string()))
}

/// Debug: Install Adapter: P's adapter from its `:install` entry, into the tools folder.
async fn install_adapter(front: &Front, p: DebugInstall) -> Result<String, Error> {
    let table = table(&p.adapters)?;
    let a = table
        .by_id(&p.adapter)
        .ok_or_else(|| bad("adapter", format!("no adapter {}", p.adapter)))?;
    let entry = a.install.as_ref().ok_or_else(|| {
        err(format!(
            "drgnx cannot install {}: add it yourself (the setting debug.adapters)",
            a.name
        ))
    })?;
    let plan = super::install::plan(entry, &super::install::platform_key()).map_err(err)?;
    super::install::install(
        &plan,
        &tools_dir(front),
        &super::install::Source::Https,
        &front.shell_env.vars_os(),
    )
    .await
    .map_err(err)
}

fn answer<T: serde::Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.map(|v| json!(v))
}

/// P served by the debug methods, or handed back (not one of theirs).
pub async fn serve(
    front: &Front,
    caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match p {
        Params::DebugConfigs(p) => answer(configs(front, p).await),
        Params::DebugStart(p) => answer(start(front, caller, p).await),
        Params::DebugControl(p) => answer(control(front, p).await),
        Params::DebugSelect(p) => answer(select(front, p).await),
        Params::DebugTrust(p) => answer(trust(front, p).await),
        Params::DebugInstall(p) => answer(install_adapter(front, p).await),
        Params::DebugSource(p) => answer(source(front, p).await),
        Params::DebugBreakpoints(p) => answer(breakpoints(front, p).await),
        Params::DebugRunToCursor(p) => answer(run_to_cursor(front, p).await),
        other => return Err(Box::new(other)),
    })
}

/// A TCP connection to ADDR, waiting up to [`LISTEN_WITHIN`] for the adapter to listen.
pub(super) async fn connect_tcp(addr: SocketAddr) -> Result<tokio::net::TcpStream, String> {
    connect_tcp_within(addr, LISTEN_WITHIN).await
}

/// A TCP connection to ADDR, waiting up to WITHIN for something to listen.
async fn connect_tcp_within(
    addr: SocketAddr,
    within: Duration,
) -> Result<tokio::net::TcpStream, String> {
    let deadline = crate::clock::now() + within;
    loop {
        match tokio::net::TcpStream::connect(addr).await {
            Ok(s) => return Ok(s),
            Err(e) if crate::clock::now() >= deadline => {
                return Err(format!("the adapter did not listen on {addr}: {e}"));
            }
            Err(_) => crate::clock::sleep(Duration::from_millis(50)).await,
        }
    }
}

pub(super) fn over_tcp(s: tokio::net::TcpStream, proc: Box<dyn super::session::Proc>) -> Connected {
    let (r, w) = s.into_split();
    let (client, incoming) = vor::Client::new(r, w);
    Connected {
        client,
        incoming,
        proc,
    }
}

/// An adapter the hub starts: on stdio, or listening on PORT.
pub(super) struct Spawned {
    pub(super) argv: Vec<String>,
    pub(super) env: Vec<(OsString, OsString)>,
    pub(super) cwd: PathBuf,
    pub(super) port: Option<u16>,
}

impl Launcher for Spawned {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let (program, args) = self.argv.split_first().ok_or("an empty command line")?;
            let mut child = draugr::spawn(draugr::Spec {
                program: PathBuf::from(program),
                args: args.iter().map(OsString::from).collect(),
                env: self.env.clone(),
                cwd: Some(self.cwd.clone()),
                stdin_null: self.port.is_some(),
                pass_fds: vec![],
                new_session: false,
            })
            .await
            .map_err(|e| format!("{program}: {e}"))?;
            if let Some(port) = self.port {
                let s = connect_tcp(SocketAddr::from(([127, 0, 0, 1], port))).await;
                return match s {
                    Ok(s) => Ok(over_tcp(s, Box::new(child))),
                    Err(e) => {
                        super::session::Proc::signal(&mut child, super::session::Sig::Kill);
                        let _ = child.wait().await;
                        Err(e)
                    }
                };
            }
            let (Some(stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
                return Err(format!("{program}: no stdio"));
            };
            let (client, incoming) = vor::Client::new(stdout, stdin);
            Ok(Connected {
                client,
                incoming,
                proc: Box::new(child),
            })
        })
    }

    /// A TCP adapter's child sessions are second connections to its port.
    fn child(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            match self.port {
                Some(port) => Ok(over_tcp(
                    connect_tcp(SocketAddr::from(([127, 0, 0, 1], port))).await?,
                    Box::new(NoProc),
                )),
                None => self.connect().await,
            }
        })
    }
}

/// `debugServer`: an adapter the user runs, on a port of this machine.
pub(super) struct Server {
    pub(super) addr: SocketAddr,
}

impl Launcher for Server {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move { Ok(over_tcp(connect_tcp(self.addr).await?, Box::new(NoProc))) })
    }
}

/// `runInTerminal` in a drgnx terminal: the shell's environment with the adapter's ENV over it.
struct TermDoor {
    terms: crate::term::Terms,
    base: Vec<(OsString, OsString)>,
}

impl Terminals for TermDoor {
    fn open(
        &self,
        conn: u64,
        cwd: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>> {
        Box::pin(async move {
            let mut all: Vec<(String, String)> = self
                .base
                .iter()
                .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v.to_str()?.to_owned())))
                .filter(|(k, _)| !env.iter().any(|(e, _)| e == k))
                .collect();
            all.extend(env);
            let rec = self
                .terms
                .spawn(
                    conn,
                    self.terms.session_of(conn),
                    crate::term::Spawn {
                        cwd,
                        command: args,
                        env: all,
                        cols: 80,
                        rows: 24,
                        cell_px: (8, 16),
                        window: 10_000,
                        class: "gui".into(),
                        limits: drgnx_term::scope::Limits {
                            memory_max: None,
                            tasks_max: None,
                        },
                        config: vec![],
                        place: Some("panel".into()),
                        remote: None,
                    },
                )
                .await?;
            Ok(Opened {
                term: rec.id,
                view: rec.view,
                pid: rec.shell_pid.map_or(0, i64::from),
                editor: rec.session,
            })
        })
    }

    fn run_task(&self, term: String) -> BoxFut<'_, (Option<i32>, String)> {
        // waiting before the go: the task cannot end unseen
        let exit = self.terms.wait_exit(&term);
        Box::pin(async move {
            let go = drgnx_term::proto::In::Text { text: "\r".into() };
            if !self.terms.send(&term, &go) {
                return (None, String::new());
            }
            let code = exit.await;
            let mut text = String::new();
            if code.is_some_and(|c| c != 0) {
                let range = |req| drgnx_term::proto::In::TextRange {
                    req,
                    from_key: None,
                    to_key: None,
                };
                if let Ok(drgnx_term::proto::Out::Answer { result, .. }) =
                    self.terms.ask(&term, range, LISTEN_WITHIN).await
                {
                    text = result["text"].as_str().unwrap_or_default().to_owned();
                }
            }
            (code, text)
        })
    }
}

/// A start's task STEPS: with a frame (TAB) each in a terminal tab of connection CONN's editor, shown to it
/// (`debug-terminal`); else captured.  Either runs with the user's rights and the shell's environment, as before.
async fn run_tasks(
    front: &Front,
    conn: u64,
    tab: bool,
    steps: &[super::tasks::Step],
) -> Result<(), String> {
    if !tab || steps.is_empty() {
        return super::tasks::run(steps, &front.shell_env.vars_os()).await;
    }
    let door = TermDoor {
        terms: front.core.terms.clone(),
        base: front.shell_env.vars_os(),
    };
    let editors = front.editors.clone();
    super::tasks::run_in(steps, &door, conn, &move |s, o| {
        super::show_terminal(
            &*editors,
            conn,
            json!({"term": o.term, "view": o.view, "task": s.label, "editor": o.editor}),
        );
    })
    .await
}
