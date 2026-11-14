//! The `lsp-command` start kind (language packs Task 10j; design `docs/specs/drgnx/2026-11-14-lsp-command-adapters.md`):
//! an adapter that lives inside a language server. The hub starts the server (java-debug in jdtls), talks LSP to it
//! ([`super::lsp_client`]), runs the pack's `:debug-command`, whose answer is the TCP port of a DAP server the server
//! opened, and connects DAP there. Before the DAP `launch` goes out, the pack's `:fill` steps ask the server for what the
//! launch needs (`mainClass`, `classPaths`, …) and write the answers into the launch arguments.
//!
//! Everything here is data from the pack and substitution: no step runs a shell, a value is never read for variables
//! again, and an answer that is not a plain string or a list of plain strings is refused.
//!
//! The server and everything it starts are one process group (its pid), ended together; the check that the listener
//! belongs to that group is [`super::blocked::wait_owned`]'s, as for every TCP adapter.

use super::lsp_client::{Client, Failure};
use super::session::{Proc, Sig};
use super::{BoxFut, Connected, Launcher};
use serde_json::{Map, Value, json};
use skald::manifest::{Fill, LspCommand};
use std::ffi::OsString;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// How long the server has to answer `initialize`, to become ready (the first start imports the project), to answer
/// the debug command and each fill command, and how long the DAP server has to listen once its port is known.
#[derive(Clone, Copy, Debug)]
pub struct Within {
    pub init: Duration,
    pub ready: Duration,
    pub command: Duration,
    pub port: Duration,
}

impl Default for Within {
    fn default() -> Within {
        Within {
            init: Duration::from_secs(60),
            ready: Duration::from_secs(120),
            command: Duration::from_secs(60),
            port: Duration::from_secs(30),
        }
    }
}
/// What a filled-in value may be at most: a string's length, a list's length.
const MAX_STRING: usize = 4096;
const MAX_LIST: usize = 8192;

/// What the templates of one session can name.
#[derive(Clone, Debug)]
pub struct Vars {
    /// The folder of the pinned downloads.
    pub tools: PathBuf,
    /// The launch's project folder.
    pub root: PathBuf,
    /// The session's own working folder (jdtls' `-data`).
    pub session: PathBuf,
    /// The current file (`${file}`).
    pub file: Option<PathBuf>,
}

/// `file:///…` for PATH, with what a URI cannot hold written as `%XX`.
pub fn file_uri(p: &Path) -> String {
    let mut out = String::from("file://");
    for b in p.to_string_lossy().bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// S with `{tools}`, `{root}`, `{root-uri}`, `{session}`, `{os}`, `{arch-suffix}` and `{glob:DIR/PATTERN}` (relative to the
/// tools folder, one `*` in the last part, exactly one match) filled in. Another brace word is an error naming it.
pub fn expand(s: &str, v: &Vars) -> Result<String, String> {
    let mut out = String::new();
    let mut rest = s;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let tail = &rest[open + 1..];
        let close = tail
            .find('}')
            .ok_or_else(|| format!("{s:?}: a {{ without its }}"))?;
        let name = &tail[..close];
        out.push_str(&match name {
            "tools" => v.tools.to_string_lossy().into_owned(),
            "root" => v.root.to_string_lossy().into_owned(),
            "root-uri" => file_uri(&v.root),
            "session" => v.session.to_string_lossy().into_owned(),
            "os" => (if cfg!(target_os = "macos") {
                "mac"
            } else {
                "linux"
            })
            .into(),
            "arch-suffix" => (if cfg!(target_arch = "aarch64") {
                "_arm"
            } else {
                ""
            })
            .into(),
            g if g.starts_with("glob:") => glob(&v.tools, &g[5..])?,
            other => return Err(format!("{s:?}: unknown {{{other}}}")),
        });
        rest = &tail[close + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// The one file `REL` (a path under TOOLS whose last part may hold one `*`) names.
fn glob(tools: &Path, rel: &str) -> Result<String, String> {
    let rel = Path::new(rel);
    if rel
        .components()
        .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err(format!(
            "{{glob:{}}}: a path under the tools folder",
            rel.display()
        ));
    }
    let (dir, pat) = (
        tools.join(rel.parent().unwrap_or(Path::new(""))),
        rel.file_name().and_then(|n| n.to_str()).unwrap_or_default(),
    );
    let (pre, post) = pat
        .split_once('*')
        .ok_or_else(|| format!("{{glob:{}}}: the last part holds a *", rel.display()))?;
    let mut hits: Vec<String> = std::fs::read_dir(&dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.len() >= pre.len() + post.len() && n.starts_with(pre) && n.ends_with(post))
        .collect();
    hits.sort();
    match hits.as_slice() {
        [one] => Ok(dir.join(one).to_string_lossy().into_owned()),
        [] => Err(format!(
            "{{glob:{}}} matches nothing in {}",
            rel.display(),
            dir.display()
        )),
        many => Err(format!(
            "{{glob:{}}} matches {} files",
            rel.display(),
            many.len()
        )),
    }
}

/// VALUE with every string in it filled in by [`expand`].
fn expand_value(value: &Value, v: &Vars) -> Result<Value, String> {
    Ok(match value {
        Value::String(s) => Value::String(expand(s, v)?),
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| expand_value(x, v))
                .collect::<Result<_, _>>()?,
        ),
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, x)| Ok((k.clone(), expand_value(x, v)?)))
                .collect::<Result<Map<_, _>, String>>()?,
        ),
        other => other.clone(),
    })
}

/// A fill argument that is exactly `${config:KEY?}`: the launch's string KEY, or null when the launch has none.
pub(super) fn optional_config(s: &str, arguments: &Value) -> Option<Result<Value, String>> {
    let key = s.strip_prefix("${config:")?.strip_suffix("?}")?;
    Some(match arguments.get(key) {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(v) if v.is_string() => Ok(v.clone()),
        // a key the launch has, of another type, is the same error `${config:KEY}` gives
        Some(_) => Err(format!(
            "the launch has no string {key} for ${{config:{key}}}"
        )),
    })
}

/// A fill argument: `${config:KEY}` (a string key of the launch arguments), `${file}`, then [`expand`]'s braces. A value
/// put in is never read for variables again.
fn fill_arg(s: &str, arguments: &Value, v: &Vars) -> Result<Value, String> {
    let mut out = String::new();
    let mut rest = s;
    while let Some(at) = rest.find("${") {
        out.push_str(&expand(&rest[..at], v)?);
        let tail = &rest[at + 2..];
        let close = tail
            .find('}')
            .ok_or_else(|| format!("{s:?}: a ${{ without its }}"))?;
        let name = &tail[..close];
        match name {
            "file" => out.push_str(
                &v.file
                    .as_ref()
                    .ok_or("there is no current file for ${file}")?
                    .to_string_lossy(),
            ),
            n if n.starts_with("config:") => {
                let key = &n[7..];
                out.push_str(arguments.get(key).and_then(Value::as_str).ok_or_else(|| {
                    format!("the launch has no string {key} for ${{config:{key}}}")
                })?);
            }
            other => return Err(format!("{s:?}: unknown ${{{other}}}")),
        }
        rest = &tail[close + 1..];
    }
    out.push_str(&expand(rest, v)?);
    Ok(Value::String(out))
}

/// What a server's answer may put into the launch arguments: a plain string, or a list of plain strings, none holding a
/// variable (`${`), none past its cap. An object, a number, a list in a list or a variable is refused with its key.
pub fn plain(key: &str, value: &Value) -> Result<Value, String> {
    let ok_string = |s: &str| {
        if s.len() > MAX_STRING {
            return Err(format!(
                "{key}: a string of {} bytes, over {MAX_STRING}",
                s.len()
            ));
        }
        if s.contains("${") {
            return Err(format!(
                "{key}: an answer holding a variable (${{…}}) is refused"
            ));
        }
        Ok(())
    };
    match value {
        Value::String(s) => {
            ok_string(s)?;
            Ok(value.clone())
        }
        Value::Array(list) => {
            if list.len() > MAX_LIST {
                return Err(format!(
                    "{key}: a list of {} items, over {MAX_LIST}",
                    list.len()
                ));
            }
            for item in list {
                let Value::String(s) = item else {
                    return Err(format!(
                        "{key}: the answer is not a string or a list of strings"
                    ));
                };
                ok_string(s)?;
            }
            Ok(value.clone())
        }
        _ => Err(format!(
            "{key}: the answer is not a string or a list of strings"
        )),
    }
}

/// ARGUMENTS (the launch arguments, an object) with every step of FILLS applied, in order, against CLIENT.
pub async fn fill_arguments(
    client: &Client,
    fills: &[Fill],
    mut arguments: Value,
    v: &Vars,
    within: Duration,
) -> Result<Value, String> {
    if !arguments.is_object() {
        return Ok(arguments);
    }
    for step in fills {
        if let Some(k) = &step.when_missing
            && arguments.get(k).is_some_and(|x| !x.is_null())
        {
            continue;
        }
        let args = step
            .args
            .iter()
            .map(|a| match optional_config(a, &arguments) {
                Some(x) => x,
                None => fill_arg(a, &arguments, v),
            })
            .collect::<Result<Vec<_>, _>>()?;
        let started = crate::clock::now();
        let answer = loop {
            let answer = client
                .command(
                    &step.command,
                    json!({"command": step.command, "arguments": args}),
                    within,
                )
                .await
                .map_err(|f| format!("{}: {f}", step.command))?;
            let empty = answer.as_array().is_some_and(Vec::is_empty);
            match step.retry_empty {
                Some(secs) if empty && started.elapsed() < Duration::from_secs(secs) => {
                    crate::clock::sleep(Duration::from_millis(500)).await;
                }
                _ => break answer,
            }
        };
        let picked = match &step.select {
            Some(sel) => {
                let want = fill_arg(&sel.equals, &arguments, v)?;
                let want = want.as_str().unwrap_or_default();
                answer
                    .as_array()
                    .and_then(|l| {
                        l.iter()
                            .find(|o| o.get(&sel.field).and_then(Value::as_str) == Some(want))
                    })
                    .cloned()
                    .ok_or_else(|| {
                        let listed: Vec<String> = answer
                            .as_array()
                            .map(|l| {
                                l.iter()
                                    .take(5)
                                    .map(|o| o.get(&sel.field).map_or("-".into(), ToString::to_string))
                                    .collect()
                            })
                            .unwrap_or_default();
                        format!(
                            "{}: nothing for {} = {want} (the server listed {} item(s) [{}]; it announced {:?}; it logged {:?})",
                            step.command,
                            sel.field,
                            answer.as_array().map_or(0, Vec::len),
                            listed.join(", "),
                            client.statuses(),
                            client.log_tail().iter().rev().take(3).collect::<Vec<_>>(),
                        )
                    })?
            }
            None => answer,
        };
        for put in &step.into {
            let value = match (&put.field, put.index) {
                (Some(f), _) => picked.get(f),
                (None, Some(i)) => picked.get(i),
                (None, None) => Some(&picked),
            }
            .filter(|v| !v.is_null());
            let Some(value) = value else {
                if put.optional {
                    continue;
                }
                return Err(format!("{}: the answer has no {}", step.command, put.key));
            };
            let value = plain(&put.key, value)?;
            if let Some(o) = arguments.as_object_mut() {
                o.insert(put.key.clone(), value);
            }
        }
    }
    Ok(arguments)
}

/// A folder of the session's own, removed when dropped.
struct Work(PathBuf);

impl Drop for Work {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn work_dir(base: &Path) -> Result<Work, String> {
    use std::os::unix::fs::DirBuilderExt;
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(base)
        .map_err(|e| format!("{}: {e}", base.display()))?;
    let dir = base.join(format!(
        "s{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?;
    Ok(Work(dir))
}

/// The server's process: its group is signalled, its session folder removed with it.
struct LspProc {
    child: draugr::Child,
    _work: Work,
    /// The server was waited for: its group is gone, so a drop signals nobody.
    ended: bool,
}

impl Drop for LspProc {
    /// A server nobody waited for (the session was dropped, a test failed) must not outlive its owner.
    fn drop(&mut self) {
        if !self.ended {
            Proc::signal(&mut self.child, Sig::Kill);
        }
    }
}

impl Proc for LspProc {
    fn signal(&mut self, sig: Sig) {
        Proc::signal(&mut self.child, sig);
    }
    fn wait(&mut self) -> Pin<Box<dyn std::future::Future<Output = ()> + Send + '_>> {
        Box::pin(async move {
            Proc::wait(&mut self.child).await;
            self.ended = true;
        })
    }
    fn stderr_tail(&self) -> String {
        Proc::stderr_tail(&self.child)
    }
}

/// What a started server leaves behind for the session.
struct Live {
    client: Arc<Client>,
    port: u16,
    /// The server's process (and group) id: a child session checks the port is still its.
    pid: i32,
    /// This session's folder: what `{session}` means in `:fill`, as it does in `:server`.
    session: PathBuf,
}

/// The launcher of an `lsp-command` adapter.
pub struct LspLauncher {
    pub spec: LspCommand,
    pub tools: PathBuf,
    pub root: PathBuf,
    pub file: Option<PathBuf>,
    /// Where session folders are made.
    pub work_base: PathBuf,
    pub env: Vec<(OsString, OsString)>,
    pub within: Within,
    live: Mutex<Option<Live>>,
}

impl LspLauncher {
    pub fn new(
        spec: LspCommand,
        tools: PathBuf,
        root: PathBuf,
        file: Option<PathBuf>,
        work_base: PathBuf,
        env: Vec<(OsString, OsString)>,
    ) -> LspLauncher {
        LspLauncher {
            spec,
            tools,
            root,
            file,
            work_base,
            env,
            within: Within::default(),
            live: Mutex::new(None),
        }
    }

    /// The DAP port of the running server, if one is running.
    pub fn port(&self) -> Option<u16> {
        self.live().map(|(_, p)| p)
    }

    fn live(&self) -> Option<(Arc<Client>, u16)> {
        self.live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|l| (l.client.clone(), l.port))
    }

    /// The server's process id and this session's folder.
    fn live_proc(&self) -> Option<(i32, PathBuf)> {
        self.live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|l| (l.pid, l.session.clone()))
    }

    async fn start(&self) -> Result<Connected, String> {
        let work = work_dir(&self.work_base)?;
        let vars = Vars {
            tools: self.tools.clone(),
            root: self.root.clone(),
            session: work.0.clone(),
            file: self.file.clone(),
        };
        let argv: Vec<String> = self
            .spec
            .server
            .iter()
            .map(|a| expand(a, &vars))
            .collect::<Result<_, _>>()?;
        let (program, args) = argv.split_first().ok_or("an empty server command")?;
        if !Path::new(program).is_file() {
            return Err(format!(
                "{program} is not installed: install the adapter with Debug: Install Adapter"
            ));
        }
        let mut child = draugr::spawn(draugr::Spec {
            program: PathBuf::from(program),
            args: args.iter().map(OsString::from).collect(),
            env: self.env.clone(),
            cwd: Some(self.root.clone()),
            stdin_null: false,
            pass_fds: vec![],
            new_session: false,
        })
        .await
        .map_err(|e| format!("{program}: {e}"))?;
        let (Some(stdin), Some(stdout)) = (child.take_stdin(), child.take_stdout()) else {
            return Err(format!("{program}: no stdio"));
        };
        let client = Client::new(stdout, stdin);
        let mut proc = LspProc {
            child,
            _work: work,
            ended: false,
        };
        match self.bootstrap(&client, &vars, &proc).await {
            Ok((port, stream)) => {
                *self.live.lock().unwrap_or_else(PoisonError::into_inner) = Some(Live {
                    client,
                    port,
                    pid: proc.child.id(),
                    session: vars.session.clone(),
                });
                Ok(super::wire::over_tcp(stream, Box::new(proc)))
            }
            Err(e) => {
                Proc::signal(&mut proc, Sig::Kill);
                Proc::wait(&mut proc).await;
                let log = client.log_tail();
                let tail = Proc::stderr_tail(&proc);
                let mut msg = e;
                if let Some(last) = log.last() {
                    msg.push_str(&format!(" (the server said: {last})"));
                }
                let tail = tail.trim();
                if !tail.is_empty() {
                    msg.push_str(&format!(
                        " (stderr: {})",
                        tail.lines().last().unwrap_or(tail)
                    ));
                }
                Err(msg)
            }
        }
    }

    /// `initialize`, ready, the debug command's port, the check that the listener is the server's, the connection.
    async fn bootstrap(
        &self,
        client: &Client,
        vars: &Vars,
        proc: &LspProc,
    ) -> Result<(u16, tokio::net::TcpStream), String> {
        let root = self
            .spec
            .root
            .as_deref()
            .map(|r| expand(r, vars))
            .transpose()?
            .map(PathBuf::from)
            .unwrap_or_else(|| vars.root.clone());
        let uri = file_uri(&root);
        let options = match &self.spec.init_options {
            Some(o) => expand_value(o, vars)?,
            None => Value::Null,
        };
        let step = |what: &'static str| move |f: Failure| format!("{what}: {f}");
        client
            .request(
                "initialize",
                json!({
                    "processId": std::process::id(),
                    "rootUri": uri,
                    "workspaceFolders": [{"uri": uri, "name": root.file_name().map_or_else(|| "project".into(), |n| n.to_string_lossy().into_owned())}],
                    "capabilities": {"workspace": {"executeCommand": {}, "workspaceFolders": true}},
                    "initializationOptions": options,
                }),
                self.within.init,
            )
            .await
            .map_err(step("initialize"))?;
        client
            .notify("initialized", json!({}))
            .await
            .map_err(step("initialized"))?;
        client
            .wait_ready(self.within.ready)
            .await
            .map_err(step("start"))?;
        if let (Some(open), Some(file)) = (&self.spec.open_file, &self.file) {
            // the file as it is on disk (at most 1 MiB): a server makes a lone file's project when the file is opened
            let text = std::fs::read(file)
                .ok()
                .filter(|b| b.len() <= 1 << 20)
                .map(|b| String::from_utf8_lossy(&b).into_owned())
                .unwrap_or_default();
            client
                .notify(
                    "textDocument/didOpen",
                    json!({"textDocument": {"uri": file_uri(file), "languageId": open.language_id, "version": 1, "text": text}}),
                )
                .await
                .map_err(step("didOpen"))?;
        }
        let args = self
            .spec
            .debug_args
            .iter()
            .map(|a| expand(a, vars).map(Value::String))
            .collect::<Result<Vec<_>, _>>()?;
        let answer = client
            .command(
                &self.spec.debug_command,
                json!({"command": self.spec.debug_command, "arguments": args}),
                self.within.command,
            )
            .await
            .map_err(step("the debug command"))?;
        let port = answer
            .as_u64()
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p > 0)
            .ok_or_else(|| format!("{} answered {answer}, not a port", self.spec.debug_command))?;
        super::blocked::wait_owned(port, proc.child.id(), self.within.port).await?;
        let stream = super::wire::connect_tcp(SocketAddr::from(([127, 0, 0, 1], port))).await?;
        Ok((port, stream))
    }

    fn vars(&self, session: PathBuf) -> Vars {
        Vars {
            tools: self.tools.clone(),
            root: self.root.clone(),
            session,
            file: self.file.clone(),
        }
    }
}

impl Launcher for LspLauncher {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(self.start())
    }

    /// A child session (`startDebugging`) is a second connection to the DAP server's port.
    fn child(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let (_, port) = self.live().ok_or("the language server is not running")?;
            let (pid, _) = self
                .live_proc()
                .ok_or("the language server is not running")?;
            // the port may have been freed and bound by another process since: only the server's own listener is joined
            super::blocked::wait_owned(port, pid, self.within.port).await?;
            let stream = super::wire::connect_tcp(SocketAddr::from(([127, 0, 0, 1], port))).await?;
            Ok(super::wire::over_tcp(
                stream,
                Box::new(super::session::NoProc),
            ))
        })
    }

    /// The launch arguments completed by the pack's `:fill` steps, asked of the running server.
    fn fill(&self, arguments: Value) -> BoxFut<'_, Result<Value, String>> {
        Box::pin(async move {
            if self.spec.fill.is_empty() {
                return Ok(arguments);
            }
            let (client, _) = self.live().ok_or("the language server is not running")?;
            let (_, session) = self
                .live_proc()
                .ok_or("the language server is not running")?;
            fill_arguments(
                &client,
                &self.spec.fill,
                arguments,
                &self.vars(session),
                self.within.command,
            )
            .await
        })
    }
}
