//! The report tools: hello, report_edit, report_test, ask_user, and list_agents (Task 7).  Each is the Lisp tool of
//! the same name in `core/drgnx-coord-mcp.el`, ported exactly: the same rules, answers and error texts, except where
//! the identity now comes from the socket (docs/develop/coordination.md, "The tools in Ratatoskr").
//!
//! The four reports count against the report limit ([`super::guard::REPORT_RATE`]).  Every write tells the hub
//! (`Hub::notify`) after its commit.  Answers are JSON in the Lisp's key order (structs, not maps), so an agent reads
//! the same text from either server.

use std::ffi::{OsStr, OsString};
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use mimir::BoxFuture;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::guard::{CoordTool, guarded, line, lisp_trim, text_cut};
use super::{Coord, Ctx, Identity};
use crate::read::agents::{Agent, agent};
use crate::read::tasks::{task_row, tasks};
use crate::store::CoordError;
use crate::write::agents::{AgentField, AgentRegister, agent_register, agent_seen_best_effort};
use crate::write::event::{DATA_MAX, Event, EventKind, event, event_add_best_effort};
use crate::write::messages::{Send as SendMessage, SendResult, send};
use crate::write::meta;
use crate::write::tasks::set_status;

/// This file's tools.
pub fn tools() -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    vec![
        guarded(ListAgents),
        guarded(Hello),
        guarded(ReportEdit),
        guarded(ReportTest),
        guarded(AskUser),
    ]
}

/// A store error as the tool's error text.
fn err(e: CoordError) -> String {
    e.to_string()
}

/// An answer as JSON text (`drgnx-mcp--json`).
fn json_text<T: Serialize>(v: &T) -> String {
    serde_json::to_string(v).expect("an answer is JSON")
}

/// The answer of a report the busy store did not record.
#[derive(Serialize)]
struct Busy {
    ok: bool,
    busy: &'static str,
}

const BUSY: Busy = Busy {
    ok: false,
    busy: "the store was busy: not recorded, go on",
};

/// The decision log's version (`drgnx-coord-version`).
async fn version(coord: &Coord) -> Result<u64, String> {
    coord.db().read(meta::version).await.map_err(err)
}

/// ME's row, or `None` (`drgnx-coord-agent`).
async fn agent_row(coord: &Coord, me: &str) -> Result<Option<Agent>, CoordError> {
    let me = me.to_owned();
    coord.db().read(move |c| agent(c, &me)).await
}

/// ME is alive: its row is stamped (`drgnx-coord-agent-seen`; a busy store is no error).
async fn seen(coord: &Coord, who: &Identity, me: &str) -> Result<(), String> {
    agent_seen_best_effort(
        coord.db(),
        who.tx_meta("mcp:agent-seen"),
        me.to_owned(),
        coord.now(),
    )
        .await
        .map(drop)
        .map_err(err)
}

// ---- list_agents ----

#[derive(Deserialize, JsonSchema)]
struct NoArgs {}

/// A row of `list_agents`: a hub session, or a job's task that has an agent.
#[derive(Serialize)]
#[serde(untagged)]
enum AgentListed {
    Session {
        agent: String,
        task: Option<String>,
        name: Option<String>,
    },
    Task {
        agent: String,
        task: String,
    },
}

/// A list as the Lisp writes it: an empty list is nil, so `null`.
fn list_text<T: Serialize>(rows: &[T]) -> String {
    if rows.is_empty() {
        "null".into()
    } else {
        json_text(&rows)
    }
}

struct ListAgents;

impl CoordTool for ListAgents {
    type Args = NoArgs;
    const NAME: &'static str = "list_agents";
    const DESCRIPTION: &'static str = "The agents working on this job, with their tasks";

    /// `drgnx-coord-mcp--agents`: the hub's sessions of the caller's job (all of them for a caller with no job),
    /// else the job's tasks that have an agent.
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        _: NoArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(list_agents(coord, who))
    }
}

/// `list_agents` (`drgnx-coord-mcp--agents`).
async fn list_agents(coord: &Coord, who: &Identity) -> Result<String, String> {
    let job = who.job();
    let rows: Vec<AgentListed> = match coord.hub().sessions().await {
        Some(sessions) => sessions
            .into_iter()
            .filter(|s| job.is_none() || s.job.as_deref() == job)
            .map(|s| AgentListed::Session {
                agent: s.id,
                task: s.task,
                name: s.name,
            })
            .collect(),
        None => {
            let job = job.map(str::to_owned);
            let list = match job {
                Some(job) => coord
                    .db()
                    .read(move |c| tasks(c, &job))
                    .await
                    .map_err(err)?,
                None => Vec::new(),
            };
            list.into_iter()
                .filter_map(|t| {
                    t.row.agent.map(|agent| AgentListed::Task {
                        agent,
                        task: t.row.id,
                    })
                })
                .collect()
        }
    };
    Ok(list_text(&rows))
}

// ---- paths (`drgnx-coord-mcp--local`, `--under-p`, `--worktree`, `--home`, `--too-wide-p`) ----

/// `file-name-handler-alist`-free `expand-file-name`'s lexical part: `.` and repeated slashes dropped.
fn normal(path: &Path) -> PathBuf {
    path.components()
        .filter(|c| !matches!(c, Component::CurDir))
        .collect()
}

/// `file-truename` with no file handler: links resolved as far as the path exists, the rest kept as written.
fn truename(path: &Path) -> PathBuf {
    let path = normal(path);
    let mut existing = path.clone();
    let mut rest: Vec<OsString> = Vec::new();
    loop {
        if let Ok(mut real) = std::fs::canonicalize(&existing) {
            real.extend(rest.iter().rev());
            return real;
        }
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_owned());
                existing = parent.to_path_buf();
            }
            _ => return path,
        }
    }
}

/// `$HOME` as a truename, when set.
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(|h| truename(Path::new(&h)))
}

/// PATH made absolute against BASE (`expand-file-name`, `~` included).
fn expand(path: &str, base: &Path) -> PathBuf {
    let p = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => home_dir()
            .unwrap_or_else(|| PathBuf::from("/"))
            .join(rest.trim_start_matches('/')),
        _ => PathBuf::from(path),
    };
    normal(&if p.is_absolute() { p } else { base.join(p) })
}

/// `prin1` of a string: quoted, `"` and `\` escaped.
fn lisp_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn is_control(c: char) -> bool {
    runstav::text::CONTROL.iter().any(|r| r.contains(&c))
}

/// PATH, relative to BASE, as a local truename (`drgnx-coord-mcp--local`).  Refused: a blank name, a control
/// character, a remote (TRAMP) name — refused before anything looks at it, so nothing connects — and a `..`.
fn local(path: &str, base: &Path) -> Result<PathBuf, String> {
    if path.chars().all(char::is_whitespace) || path.chars().any(is_control) {
        return Err(format!("Not a path: {}", lisp_quote(path)));
    }
    if let Some(rest) = path.strip_prefix('/')
        && rest
            .split('/')
            .next()
            .is_some_and(|first| first.contains(':'))
    {
        return Err(format!("{path} is not a local path"));
    }
    if path.split(['/', '\\']).any(|part| part == "..") {
        return Err(format!(
            "{path} has a `..': name it from the folder you work in"
        ));
    }
    Ok(truename(&expand(path, base)))
}

/// PATH as a directory name (`file-name-as-directory`).
fn as_dir(path: &Path) -> String {
    let mut s = path.to_string_lossy().into_owned();
    if !s.ends_with('/') {
        s.push('/');
    }
    s
}

/// Whether FILE is DIR or inside it, both truenames (`drgnx-coord-mcp--under-p`).
fn under(file: &Path, dir: &Path) -> bool {
    let (f, d) = (as_dir(file), as_dir(dir));
    // macOS compares ignoring case, as its file systems do; Linux and Android do not.
    if cfg!(target_os = "macos") {
        f.to_lowercase().starts_with(&d.to_lowercase())
    } else {
        f.starts_with(&d)
    }
}

/// FILE (under ROOT) relative to ROOT (`file-relative-name`): `.` for ROOT itself.
fn relative(file: &Path, root: &Path) -> String {
    let (f, r) = (as_dir(file), as_dir(root));
    match f.get(r.len()..) {
        Some(rest) if !rest.is_empty() => rest.trim_end_matches('/').to_owned(),
        _ => ".".into(),
    }
}

/// Whether ROOT is too wide to report about: a file system root, the home folder or one above it.
fn too_wide(root: &Path) -> bool {
    root == Path::new("/") || home_dir().is_some_and(|home| under(&home, root))
}

/// How long a git command may take before it is given up (`drgnx-coord-mcp--git-timeout`).
const GIT_TIMEOUT: Duration = Duration::from_secs(3);

/// The variables git keeps from the hub's environment (call 10: `draugr::env::build`'s minimal environment).
const GIT_ENV: [&str; 6] = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"];

/// git ARGS in DIR: the first line of its output, or `None` when git fails or takes over [`GIT_TIMEOUT`] (it is
/// killed) (`drgnx-coord-mcp--git`).  Manager's call 10: the root-owned git with `draugr::git`'s overrides (no
/// fsmonitor, no hook, no pager, no `ext::`, `--no-optional-locks`), no terminal, stdin closed, a minimal
/// environment.
async fn git(dir: &Path, args: &[&str]) -> Option<String> {
    use draugr::git::{GitCall, Place, command, git_program};
    let program = git_program().ok()?;
    let (argv, extra) = command(&GitCall {
        place: Place::Trusted { read_only: true },
        allow_protocols: Vec::new(),
        args: args.iter().map(OsString::from).collect(),
    })
    .ok()?;
    let set: Vec<(&str, &OsStr)> = extra
        .iter()
        .filter_map(|(k, v)| Some((k.to_str()?, v.as_os_str())))
        .collect();
    let env = draugr::env::build(&GIT_ENV, &[], &set);
    let child = tokio::process::Command::new(&program.path)
        .args(&argv)
        .current_dir(dir)
        .env_clear()
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let out = tokio::time::timeout(GIT_TIMEOUT, child.wait_with_output())
        .await
        .ok()?
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .split('\n')
        .find(|l| !l.is_empty())
        .map(str::to_owned)
}

/// The git worktree DIR is in (its truename), or `None` — `None` too for the home folder itself: a repository of
/// dotfiles holds no project (`drgnx-coord-mcp--worktree`).
async fn worktree(dir: &Path) -> Option<PathBuf> {
    let top = truename(Path::new(
        &git(dir, &["rev-parse", "--show-toplevel"]).await?,
    ));
    if home_dir().as_ref() == Some(&top) {
        None
    } else {
        Some(top)
    }
}

/// The folder the agent started in, as a truename (the Lisp server's `default-directory`).
fn start_dir(who: &Identity) -> Result<PathBuf, String> {
    who.home().map(truename).ok_or_else(|| {
        "No folder is known for you: the bridge that reached this server named none".to_string()
    })
}

/// The folder the agent may report about (`drgnx-coord-mcp--home`): the git worktree of the folder it started in,
/// else that folder.  Returns (start, home).
async fn home(who: &Identity) -> Result<(PathBuf, PathBuf), String> {
    let start = start_dir(who)?;
    let home = worktree(&start).await.unwrap_or_else(|| start.clone());
    Ok((start, home))
}

/// ME's row when ME is one of drgnx's job agents (a job, and the row's kind `job` with a cwd), else `None`: its
/// cwd, worktree, branch and base are the hub's to set (`drgnx-coord-mcp--job-row`).
async fn job_row(coord: &Coord, who: &Identity, me: &str) -> Option<Agent> {
    who.job()?;
    agent_row(coord, me)
        .await
        .ok()
        .flatten()
        .filter(|row| row.kind.as_deref() == Some("job") && row.cwd.is_some())
}

/// (CWD, ROOT) for ME's reports (`drgnx-coord-mcp--where`): a job agent's from the hub's row, else the cwd and
/// worktree its hello registered when they lie in its home, else the folder it started in and its home.
async fn where_(coord: &Coord, who: &Identity, me: &str) -> Result<(PathBuf, PathBuf), String> {
    if let Some(row) = job_row(coord, who, me).await {
        let cwd = PathBuf::from(row.cwd.unwrap_or_default());
        let root = row.worktree.map_or_else(|| cwd.clone(), PathBuf::from);
        return Ok((cwd, root));
    }
    let (start, home) = home(who).await?;
    Ok(where_registered(coord, me, start, home).await)
}

/// `drgnx-coord-mcp--where-registered`.
async fn where_registered(
    coord: &Coord,
    me: &str,
    start: PathBuf,
    home: PathBuf,
) -> (PathBuf, PathBuf) {
    let row = agent_row(coord, me).await.ok().flatten();
    let cwd = row.as_ref().and_then(|r| r.cwd.clone()).map(PathBuf::from);
    let root = row
        .and_then(|r| r.worktree)
        .map(PathBuf::from)
        .or_else(|| cwd.clone());
    match (cwd, root) {
        (Some(cwd), Some(root)) if under(&cwd, &home) && under(&root, &home) => (cwd, root),
        _ => (start, home),
    }
}

/// TASK (a label an agent gives) when it may be the agent's: an outside agent may not name a job's task
/// (`drgnx-coord-mcp--own-task`).
async fn own_task(
    coord: &Coord,
    who: &Identity,
    task: Option<&str>,
) -> Result<Option<String>, String> {
    let Some(task) = line(task, 200) else {
        return Ok(None);
    };
    let t = task.clone();
    if coord
        .db()
        .read(move |c| task_row(c, &t))
        .await
        .map_err(err)?
        .is_some()
    {
        who.not_outside(&format!("task {task}"))?;
    }
    Ok(Some(task))
}

// ---- hello ----

#[derive(Deserialize, JsonSchema)]
struct HelloArgs {
    /// A name for you the user sees (e.g. "claude · drgnx")
    name: Option<String>,
    /// The folder you work in (default: where you started this server)
    cwd: Option<String>,
    /// Your git branch (default: the cwd's)
    branch: Option<String>,
    /// The plan you work from
    plan: Option<String>,
    /// The task you work on (your own label; a drgnx job's tasks are not yours to name)
    task: Option<String>,
}

#[derive(Serialize)]
struct HelloAnswer<'a> {
    agent: &'a str,
    version: u64,
    cwd: Option<String>,
    worktree: Option<String>,
    base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<&'static str>,
}

fn path_text(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

struct Hello;

impl CoordTool for Hello {
    type Args = HelloArgs;
    const NAME: &'static str = "hello";
    const DESCRIPTION: &'static str = "Say who you are and where you work, first: answers your identity (from your process: never an argument) and the decision log's version.  The cwd must be inside the folder you started this server in.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: HelloArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(hello(coord, who, args))
    }
}

/// `hello`: a report.  A job agent's row is the hub's: hello changes nothing of it, runs no git, and answers the
/// hub's values (`drgnx-coord-mcp--hello`).
async fn hello(coord: &Coord, who: &Identity, args: HelloArgs) -> Result<String, String> {
    let me = who.me()?;
    if let Some(held) = coord.held_report(me, who.job()).await {
        return Ok(held);
    }
    if let Some(row) = job_row(coord, who, me).await {
        seen(coord, who, me).await?;
        return Ok(json_text(&HelloAnswer {
            agent: me,
            version: version(coord).await?,
            cwd: row.cwd,
            worktree: row.worktree,
            base: row.base,
            note: None,
        }));
    }
    hello_register(coord, who, me, args).await
}

/// `drgnx-coord-mcp--hello-register`: register ME; a new start (never seen, or now in another worktree) takes the
/// base from HEAD and adds a `start` event.
async fn hello_register(
    coord: &Coord,
    who: &Identity,
    me: &str,
    args: HelloArgs,
) -> Result<String, String> {
    let (start, home) = home(who).await?;
    // not given: the one an earlier hello registered (when still valid), else where the agent started
    let cwd = match args.cwd.as_deref() {
        Some(given) => local(given, &start)?,
        None => where_registered(coord, me, start, home.clone()).await.0,
    };
    if !under(&cwd, &home) {
        return Err(format!(
            "{} is outside {}, the folder this server was started in",
            cwd.display(),
            home.display()
        ));
    }
    if !cwd.is_dir() {
        return Err(format!("{} is not a folder", cwd.display()));
    }
    let kind = who.outside_kind().map(str::to_owned);
    let task = own_task(coord, who, args.task.as_deref()).await?;
    let worktree = worktree(&cwd).await.as_deref().map(path_text);
    let old = agent_row(coord, me).await.map_err(err)?;
    let fresh = match &old {
        None => true,
        Some(old) => old.base.is_none() || old.worktree != worktree,
    };
    let base = if fresh {
        match worktree {
            Some(_) => git(&cwd, &["rev-parse", "HEAD"]).await,
            None => None,
        }
    } else {
        old.as_ref().and_then(|o| o.base.clone())
    };
    let branch = match line(args.branch.as_deref(), 200) {
        Some(b) => Some(b),
        None if worktree.is_some() => git(&cwd, &["branch", "--show-current"]).await,
        None => None,
    };
    let name = line(args.name.as_deref(), 80)
        .or_else(|| old.as_ref().and_then(|o| o.name.clone()))
        .or_else(|| kind.clone())
        .unwrap_or_else(|| me.to_owned());
    let mut clear = Vec::new();
    if fresh && worktree.is_none() {
        clear.push(AgentField::Worktree);
    }
    if fresh && base.is_none() {
        clear.push(AgentField::Base);
    }
    let cwd = path_text(&cwd);
    let reg = AgentRegister {
        id: me.to_owned(),
        kind: kind.clone(),
        name: Some(name.clone()),
        cwd: Some(cwd.clone()),
        worktree: worktree.clone(),
        branch: branch.clone(),
        base: base.clone(),
        plan: line(args.plan.as_deref(), 200),
        task,
        pid: who.pid(),
        clear,
    };
    let start_event = fresh.then(|| {
        let mut data = serde_json::Map::new();
        for (k, v) in [
            ("kind", &kind),
            ("cwd", &Some(cwd.clone())),
            ("branch", &branch),
            ("base", &base),
        ] {
            if let Some(v) = v {
                data.insert(k.into(), Value::String(v.clone()));
            }
        }
        Event {
            at: coord.now(),
            agent: Some(me.to_owned()),
            job: who.job().map(str::to_owned),
            task: who.task().map(str::to_owned),
            kind: EventKind::Start,
            summary: format!(
                "{name} started in {cwd}{}",
                branch
                    .as_deref()
                    .map(|b| format!(" ({b})"))
                    .unwrap_or_default()
            ),
            data: Some(Value::Object(data)),
            turn: false,
        }
    });
    let now = coord.now();
    let version = coord
        .db()
        .write(who.tx_meta("mcp:hello"), move |tx| {
            agent_register(tx, reg, now)?;
            if let Some(e) = start_event {
                event(tx, e)?;
            }
            meta::version(tx.sql())
        })
        .await
        .map_err(err)?;
    if fresh {
        coord.hub().notify();
    }
    Ok(json_text(&HelloAnswer {
        agent: me,
        version,
        cwd: Some(cwd),
        worktree,
        base,
        note: who.note(),
    }))
}

// ---- report_edit ----

/// The most paths one report_edit may name; more are refused unread (`drgnx-coord-mcp--paths-max`).
const PATHS_MAX: usize = 1000;
/// The most paths an edit event keeps.
const PATHS_KEPT: usize = 100;

/// Several strings: best an array; a string takes one per line (or, for paths with no newline, comma-separated).
#[derive(Deserialize, JsonSchema)]
#[serde(untagged)]
enum Strings {
    List(Vec<String>),
    Text(String),
}

#[derive(Deserialize, JsonSchema)]
struct ReportEditArgs {
    /// The files (at most 1000), relative to your cwd or absolute: best an array of strings; a string takes one per line, or, with no newline, separated by commas
    paths: Strings,
    /// What you changed, one line
    summary: Option<String>,
}

/// `split-string` with OMIT-NULLS and TRIM `[ \t\r]+`.
fn split_trimmed(s: &str, sep: char) -> Vec<String> {
    s.split(sep)
        .map(|p| p.trim_matches([' ', '\t', '\r']))
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect()
}

/// An edit event's data: ROOT, PATHS (relative), and MORE paths left out when above 0
/// (`drgnx-coord-mcp--edit-data`).
fn edit_data(root: &str, paths: &[String], more: usize) -> Value {
    let mut data = json!({"root": root, "paths": paths});
    if more > 0 {
        data["more"] = json!(more);
    }
    data
}

/// The first of PATHS (at most 100) that an edit event keeps whole, within [`DATA_MAX`] characters of JSON
/// (`drgnx-coord-mcp--fitting`).
fn fitting<'p>(root: &str, paths: &'p [String]) -> &'p [String] {
    let mut kept = &paths[..paths.len().min(PATHS_KEPT)];
    while !kept.is_empty()
        && edit_data(root, kept, paths.len() - kept.len())
            .to_string()
            .chars()
            .count()
            > DATA_MAX
    {
        kept = &kept[..kept.len() - 1];
    }
    kept
}

#[derive(Serialize)]
struct EditAnswer {
    ok: bool,
    event: i64,
    paths: usize,
}

struct ReportEdit;

impl CoordTool for ReportEdit {
    type Args = ReportEditArgs;
    const NAME: &'static str = "report_edit";
    const DESCRIPTION: &'static str = "Say which files you changed (paths only; inside the folder you work in): the user's Work cockpit shows them and their diff.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReportEditArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(report_edit(coord, who, args))
    }
}

/// `report_edit`, a report (`drgnx-coord-mcp--report-edit`).
async fn report_edit(
    coord: &Coord,
    who: &Identity,
    args: ReportEditArgs,
) -> Result<String, String> {
    let me = who.me()?;
    if let Some(held) = coord.held_report(me, who.job()).await {
        return Ok(held);
    }
    let (cwd, root) = where_(coord, who, me).await?;
    let given = match args.paths {
        Strings::List(v) => v,
        Strings::Text(s) => split_trimmed(&s, if s.contains('\n') { '\n' } else { ',' }),
    };
    if too_wide(&root) {
        return Err(format!(
            "The folder you work in is {} — your home folder or above it, too wide to report about: start drgnx's MCP server in the project folder (the agent's working directory there)",
            root.display()
        ));
    }
    if given.len() > PATHS_MAX {
        return Err(format!(
            "{} paths: at most {PATHS_MAX} in one report",
            given.len()
        ));
    }
    let mut paths = Vec::with_capacity(given.len());
    for p in &given {
        let file = local(p, &cwd)?;
        if !under(&file, &root) {
            return Err(format!(
                "{p} is outside {}, the folder you work in",
                root.display()
            ));
        }
        paths.push(relative(&file, &root));
    }
    if paths.is_empty() {
        return Err("paths is required: the files you changed (an array, or one per line)".into());
    }
    let root = path_text(&root);
    let kept = fitting(&root, &paths);
    let n = paths.len();
    let e = Event {
        at: coord.now(),
        agent: Some(me.to_owned()),
        job: who.job().map(str::to_owned),
        task: who.task().map(str::to_owned),
        kind: EventKind::Edit,
        summary: args
            .summary
            .unwrap_or_else(|| format!("{n} file{}", if n > 1 { "s" } else { "" })),
        data: Some(edit_data(&root, kept, n - kept.len())),
        turn: false,
    };
    let id = event_add_best_effort(coord.db(), who.tx_meta("mcp:report_edit"), e)
        .await
        .map_err(err)?;
    seen(coord, who, me).await?;
    coord.hub().notify();
    Ok(match id {
        Some(event) => json_text(&EditAnswer {
            ok: true,
            event,
            paths: n,
        }),
        None => json_text(&BUSY),
    })
}

// ---- report_test ----

#[derive(Deserialize, JsonSchema)]
struct ReportTestArgs {
    /// The test command
    command: String,
    /// Tests passed
    passed: Option<u64>,
    /// Tests failed
    failed: Option<u64>,
    /// One line
    summary: Option<String>,
}

#[derive(Serialize)]
struct TestAnswer {
    ok: bool,
    event: i64,
}

struct ReportTest;

impl CoordTool for ReportTest {
    type Args = ReportTestArgs;
    const NAME: &'static str = "report_test";
    const DESCRIPTION: &'static str =
        "Say you ran tests, and how they went: the user's status bar and cockpit show it.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReportTestArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(report_test(coord, who, args))
    }
}

/// `report_test`, a report (`drgnx-coord-mcp--report-test`).
async fn report_test(
    coord: &Coord,
    who: &Identity,
    args: ReportTestArgs,
) -> Result<String, String> {
    let me = who.me()?;
    if let Some(held) = coord.held_report(me, who.job()).await {
        return Ok(held);
    }
    let Some(command) = line(Some(args.command.as_str()), 200) else {
        return Err("command is required: the test command you ran".into());
    };
    let count = |n: Option<u64>| n.map_or_else(|| "?".to_string(), |n| n.to_string());
    let summary = args.summary.unwrap_or_else(|| {
        format!(
            "{} passed, {} failed: {command}",
            count(args.passed),
            count(args.failed)
        )
    });
    let mut data = json!({"command": command});
    if let Some(p) = args.passed {
        data["passed"] = json!(p);
    }
    if let Some(f) = args.failed {
        data["failed"] = json!(f);
    }
    let e = Event {
        at: coord.now(),
        agent: Some(me.to_owned()),
        job: who.job().map(str::to_owned),
        task: who.task().map(str::to_owned),
        kind: EventKind::Test,
        summary,
        data: Some(data),
        turn: false,
    };
    let id = event_add_best_effort(coord.db(), who.tx_meta("mcp:report_test"), e)
        .await
        .map_err(err)?;
    seen(coord, who, me).await?;
    coord.hub().notify();
    Ok(match id {
        Some(event) => json_text(&TestAnswer { ok: true, event }),
        None => json_text(&BUSY),
    })
}

// ---- ask_user ----

#[derive(Deserialize, JsonSchema)]
struct AskUserArgs {
    /// The question
    question: String,
    /// The choices: best an array of strings; a string takes one per line (none may hold a |)
    options: Option<Strings>,
    /// The task it is about
    task: Option<String>,
}

#[derive(Serialize)]
struct AskAnswer {
    ok: bool,
    id: i64,
    state: String,
    answer: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    cut: Option<usize>,
}

/// The question without its own `Options:` lines: that line is drgnx's to write.
fn drop_options_lines(question: &str) -> String {
    question
        .split_inclusive('\n')
        .filter(|l| {
            let l = l.trim_start_matches([' ', '\t']);
            !(l.len() >= 7
                && l.is_char_boundary(7)
                && l[..7].eq_ignore_ascii_case("options")
                && l[7..].trim_start_matches([' ', '\t']).starts_with(':'))
        })
        .collect()
}

struct AskUser;

impl CoordTool for AskUser {
    type Args = AskUserArgs;
    const NAME: &'static str = "ask_user";
    const DESCRIPTION: &'static str = "Ask the user a question; it waits for them in the cockpit (never a prompt).  Go on with what does not depend on it: the answer comes as a message (read_inbox).";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: AskUserArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(ask_user(coord, who, args))
    }
}

/// `ask_user`, a report (`drgnx-coord-mcp--ask-user`): a question to the user (`[escalation]`, a `question` event);
/// a task the agent holds (claimed or running) waits on the user (`needs-input`).
async fn ask_user(coord: &Coord, who: &Identity, args: AskUserArgs) -> Result<String, String> {
    let me = who.me()?;
    if let Some(held) = coord.held_report(me, who.job()).await {
        return Ok(held);
    }
    let (given, cut) = text_cut(Some(args.question.as_str()), "question")?;
    let question = lisp_trim(&drop_options_lines(&given)).to_owned();
    let options: Vec<String> = match &args.options {
        None => Vec::new(),
        Some(Strings::List(v)) => v
            .iter()
            .filter_map(|o| line(Some(o.as_str()), 200))
            .collect(),
        Some(Strings::Text(s)) => s
            .split('\n')
            .filter(|o| !o.is_empty())
            .filter_map(|o| line(Some(o), 200))
            .collect(),
    };
    if question.is_empty() {
        return Err("question is required".into());
    }
    if let Some(bad) = options.iter().find(|o| o.contains('|')) {
        return Err(format!(
            "An option cannot hold a `|' (it separates them): {bad}"
        ));
    }
    let task = match own_task(coord, who, args.task.as_deref()).await? {
        Some(t) => Some(t),
        None => who.task().map(str::to_owned),
    };
    let text = format!(
        "[escalation] {}{question}{}",
        task.as_deref()
            .map(|t| format!("({t}) "))
            .unwrap_or_default(),
        if options.is_empty() {
            String::new()
        } else {
            let shown: Vec<&str> = options.iter().take(20).map(String::as_str).collect();
            format!("\nOptions: {}", shown.join(" | "))
        }
    );
    let message = SendMessage {
        job: who.job().map(str::to_owned),
        sender: Some(me.to_owned()),
        recipient: "user".into(),
        text,
        seen: None,
        answers: None,
        question: true,
    };
    // one of drgnx's agents with a task it holds: the task waits on the user
    let waits = task.filter(|_| who.outside_kind().is_none());
    let (me_, now) = (me.to_owned(), coord.now());
    let sent = coord
        .db()
        .write(who.tx_meta("mcp:ask_user"), move |tx| {
            let sent = send(tx, message, now)?;
            if let Some(task) = waits
                && let Some(row) = task_row(tx.sql(), &task)?
                && row.agent.as_deref() == Some(me_.as_str())
                && matches!(row.status.as_deref(), Some("claimed" | "running"))
            {
                set_status(tx, &task, &me_, "needs-input", None, now)?;
            }
            Ok(sent)
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    let answer = "the user's answer comes as a message: read_inbox";
    Ok(match sent {
        SendResult::Ok { id, state } => json_text(&AskAnswer {
            ok: true,
            id,
            state,
            answer,
            cut: (cut > 0).then_some(cut),
        }),
        // a question carries no seen version, so the log never holds it; kept for completeness
        SendResult::Held { version, .. } => {
            json!({"held": true, "version": version, "answer": answer}).to_string()
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_local_and_relative() {
        let base = Path::new("/nonexistent-norn/repo");
        assert_eq!(
            local("src/./a.rs", base).unwrap(),
            PathBuf::from("/nonexistent-norn/repo/src/a.rs")
        );
        assert_eq!(
            local("/ssh:x:/y", base).unwrap_err(),
            "/ssh:x:/y is not a local path"
        );
        assert_eq!(
            local("/sudo::/etc", base).unwrap_err(),
            "/sudo::/etc is not a local path"
        );
        assert!(local("a/../b", base).unwrap_err().contains("has a `..'"));
        assert!(local("a\\..\\b", base).unwrap_err().contains("has a `..'"));
        assert_eq!(local("  ", base).unwrap_err(), "Not a path: \"  \"");
        assert!(
            local("a\u{202e}b", base)
                .unwrap_err()
                .starts_with("Not a path")
        );
        let root = Path::new("/nonexistent-norn/repo");
        assert_eq!(relative(&root.join("x/y.rs"), root), "x/y.rs");
        assert_eq!(relative(root, root), ".");
        assert!(under(&root.join("x"), root) && under(root, root));
        assert!(!under(Path::new("/nonexistent-norn/repo2"), root));
        assert!(too_wide(Path::new("/")));
    }

    #[test]
    fn an_edit_event_keeps_what_fits() {
        let few: Vec<String> = (0..120).map(|i| format!("f{i:03}.rs")).collect();
        assert_eq!(fitting("/r", &few).len(), PATHS_KEPT);
        let long: Vec<String> = (0..60).map(|_| "a".repeat(100)).collect();
        let kept = fitting("/r", &long);
        let size = edit_data("/r", kept, 60 - kept.len())
            .to_string()
            .chars()
            .count();
        assert!(
            size <= DATA_MAX && kept.len() < 60,
            "{} kept, {size}",
            kept.len()
        );
        let one_more = &long[..kept.len() + 1];
        assert!(
            edit_data("/r", one_more, 60 - one_more.len())
                .to_string()
                .chars()
                .count()
                > DATA_MAX
        );
    }

    #[test]
    fn options_lines_of_the_question_go() {
        assert_eq!(
            drop_options_lines("Which?\n  OPTIONS : a | b\nmore\noptions:x"),
            "Which?\nmore\n"
        );
        assert_eq!(drop_options_lines("Optionsx: y"), "Optionsx: y");
    }
}
