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
    DebugConfigs, DebugControl, DebugFileError, DebugRunToCursor, DebugSelect, DebugStart,
    DebugStarted, DebugTrust,
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
}

impl Hub {
    fn debug(&self, front: &Front) -> &Debug {
        self.debug.get_or_init(|| {
            Debug::with_store(
                front.editors.clone(),
                Arc::new(TermDoor {
                    terms: front.core.terms.clone(),
                    base: front.shell_env.vars_os(),
                }),
                Some(
                    runstav::paths::state_dir(&front.shell_env.paths_env())
                        .join("debug-breakpoints"),
                ),
            )
        })
    }

    fn is_trusted(&self, root: &str) -> bool {
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
fn table(user: &[JsonObject]) -> Result<Table, Error> {
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
    }
}

async fn configs(front: &Front, p: DebugConfigs) -> Result<DebugConfigList, Error> {
    let needs_trust = !front.debug.is_trusted(&p.root);
    let (file, error) = read_launch(&p.root);
    let mut out = vec![];
    if let Some(f) = &file {
        for i in launch::listed(&f.configs) {
            out.push(entry(
                format!("launch:{i}"),
                "launch",
                &f.configs[i],
                needs_trust,
            ));
        }
    }
    for (i, c) in p.user.iter().enumerate() {
        out.push(entry(
            format!("user:{i}"),
            "user",
            &Value::Object(c.clone().into_inner()),
            needs_trust,
        ));
    }
    if let Some(lang) = &p.language {
        for (i, c) in table(&p.adapters)?.defaults_for(lang).iter().enumerate() {
            out.push(entry(format!("default:{i}"), "default", c, needs_trust));
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
fn config_of(p: &DebugStart, table: &Table) -> Result<(Value, Vec<Value>), Error> {
    let (kind, n) = p
        .config
        .split_once(':')
        .ok_or_else(|| bad("config", "launch:N, user:N or default:N"))?;
    let n: usize = n
        .parse()
        .map_err(|_| bad("config", "launch:N, user:N or default:N"))?;
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

fn need_json(n: &Need) -> Value {
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

fn vars(front: &Front, p: &DebugStart) -> Vars {
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
        default_build_task: None,
        env,
        config,
    }
}

/// Where the adapters drgnx installs live: `<data>/debug-adapters` (its Python venv is `venv/`).
fn tools_dir(front: &Front) -> PathBuf {
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
    let path = env_os
        .iter()
        .find(|(k, _)| k == "PATH")
        .map(|(_, v)| std::env::split_paths(v).collect())
        .unwrap_or_default();
    let env = adapters::Env {
        path,
        tools: tools_dir(front),
    };
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
            session: None,
            needs: Some(json!("trust")),
        });
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
            session: None,
            needs: Some(Value::Array(needs.iter().map(need_json).collect())),
        });
    }
    launch::check_answers(&config, &inputs, &answers).map_err(|e| bad("inputs", e))?;
    let config = launch::substitute(&config, &vars(front, &p), &answers).map_err(err)?;
    let ty = text(&config, "type");
    let adapter = table.for_type(&ty).map_err(err)?;
    let launcher = launcher(front, &p.root, &config, adapter).map_err(err)?;
    let attach = text(&config, "request") == "attach";
    let start = Start {
        name: text(&config, "name"),
        adapter_id: ty,
        request: if attach {
            Request::Attach
        } else {
            Request::Launch
        },
        hold_configuration_done: adapter.holds_configuration_done(attach),
        arguments: launch::adapter_arguments(&config),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let id = front
        .debug
        .debug(front)
        .start(caller.conn_id, &p.root, start, launcher)
        .await
        .map_err(err)?;
    front
        .debug
        .last
        .lock()
        .expect("debug last")
        .insert(p.root, p.config);
    Ok(DebugStarted {
        session: Some(id),
        needs: None,
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

async fn breakpoints(front: &Front, p: DebugBreakpoints) -> Result<DebugBreakpointsView, Error> {
    let op = p.op.map(bp_op).transpose()?;
    let v = front
        .debug
        .debug(front)
        .breakpoints(&p.root, op, p.path.as_deref())
        .await;
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
        Params::DebugBreakpoints(p) => answer(breakpoints(front, p).await),
        Params::DebugRunToCursor(p) => answer(run_to_cursor(front, p).await),
        other => return Err(Box::new(other)),
    })
}

/// A TCP connection to ADDR, waiting up to [`LISTEN_WITHIN`] for the adapter to listen.
async fn connect_tcp(addr: SocketAddr) -> Result<tokio::net::TcpStream, String> {
    let deadline = crate::clock::now() + LISTEN_WITHIN;
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

fn over_tcp(s: tokio::net::TcpStream, proc: Box<dyn super::session::Proc>) -> Connected {
    let (r, w) = s.into_split();
    let (client, incoming) = vor::Client::new(r, w);
    Connected {
        client,
        incoming,
        proc,
    }
}

/// An adapter the hub starts: on stdio, or listening on PORT.
struct Spawned {
    argv: Vec<String>,
    env: Vec<(OsString, OsString)>,
    cwd: PathBuf,
    port: Option<u16>,
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
struct Server {
    addr: SocketAddr,
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
            })
        })
    }
}
