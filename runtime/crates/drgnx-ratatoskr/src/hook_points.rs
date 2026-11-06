//! The hook points (`docs/develop/plugins.md`, "The hook points"; `docs/guide/plugins.md`, "Before a tool call"):
//! where the hub runs `norn::hooks` on a step, and what it keeps of each run.
//!
//! - **Before a tool call** ([`before_tool`]), at three sites ([`At`]): the permission seam (`agents/session.rs`,
//!   the agent's own tools), the hub's own servers ([`at_hub_server`]: the coordination tools, the plugins'
//!   abilities; kind `drgnx`, the only site that takes a `change`), and the adapter's `_drgnx/before_tool` (the panel
//!   extension). The seam's order: the fast path ([`prepare`]: nothing subscribes, nothing runs), then the matrix's
//!   `dry`, then [`run`], then `decide` only when no hook denied.
//! - **One row per point run** ([`write_row`]), a `status` event `{"hook": true, …}` written by the hub's own hook
//!   writer (tx actor `hub:hooks`, [`crate::coord::HOOKS_METHOD`]), budgeted to stay whole ([`record_data`]). A step's
//!   provenance ([`provenance`], `timeline/get`) reads only those rows: an `events/add` row is never provenance.
//! - **What the agent is told:** a deny's reason is steered into its running turn in the hub's words, the hook's
//!   quoted ([`refusal`]); an annotation is a `note` entry under the step.
//!
//! After an edit, before a commit and at review use [`record_data`] and [`write_row`] too.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use norn::hooks::{self, Decision, HookInput, Outcome, Point, Record, Rule, Source, Verdict};
use norn::matrix::{Cell, Verdict as Matrix};
use norn::store::{CoordError, Tx};
use norn::write::event::{DATA_MAX, Event, EventKind, event};
use serde_json::{Map, Value, json};

use crate::dispatch::Caller;
use crate::front::Front;
use crate::plugins::{Plugin, Plugins};

/// Where a `before-tool` point runs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum At {
    /// The permission seam: the agent asks before its own tool runs.
    #[default]
    Seam,
    /// The hub's own server (`drgnx`, `drgnx-plugins`): the tool is the hub's, and its body checks the arguments.
    HubServer,
    /// The adapter's `_drgnx/before_tool`: a step the agent would allow itself.
    Adapter,
}

impl At {
    /// Whether a hook may change the call here: only at the hub's servers, whose tools check changed arguments
    /// against their schema again.
    pub fn accepts_change(self) -> bool {
        self == At::HubServer
    }

    pub fn word(self) -> &'static str {
        match self {
            At::Seam => "seam",
            At::HubServer => "hub-server",
            At::Adapter => "adapter",
        }
    }
}

/// The step's place: the site, and the session's facts the hook's input and the row carry.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Site {
    pub at: At,
    pub session: String,
    /// The Urdr project id: which plugin list and rules apply (none: the global ones).
    pub project: Option<String>,
    /// The session's folder: a step's paths inside it are given relative to it.
    pub root: Option<PathBuf>,
    pub role: Option<String>,
    pub profile: Option<String>,
    pub job: Option<String>,
    pub task: Option<String>,
}

/// A tool call as the hooks see it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ToolCallInfo {
    /// The normalised kind (`norn::hooks::acp_kind`), or `drgnx` at the hub's servers.
    pub kind: String,
    /// The tool's full name (`Bash`, `mcp__drgnx__merge`).
    pub name: Option<String>,
    pub title: Option<String>,
    /// The raw input (an agent's tool) or the arguments (a hub tool).
    pub input: Value,
    /// As the agent gave them.
    pub paths: Vec<PathBuf>,
    pub command: Option<String>,
    /// The session's step it belongs to (`step.seq`).
    pub step: Option<i64>,
}

/// The input keys that name a path.
const PATH_KEYS: [&str; 3] = ["file_path", "path", "notebook_path"];

fn input_paths(input: &Value) -> Vec<PathBuf> {
    PATH_KEYS
        .iter()
        .filter_map(|k| input.get(*k).and_then(Value::as_str))
        .map(PathBuf::from)
        .collect()
}

impl ToolCallInfo {
    /// The tool call TOOL of a permission request (ACP's `toolCall`), with what the session folded of the same
    /// `toolCallId`: FOLDED_KIND (a request with no `kind` takes it: Kimi Code, DeepSeek Harness) and FOLDED_NAME.
    /// The name is the adapter's `_meta.claudeCode.toolName`, else the folded one, else a one-word title.
    pub fn from_acp(
        tool: Option<&Value>,
        folded_kind: Option<&str>,
        folded_name: Option<&str>,
        step: Option<i64>,
    ) -> ToolCallInfo {
        let s = |p: &str| tool.and_then(|t| t.pointer(p)).and_then(Value::as_str);
        let title = s("/title");
        let name = s("/_meta/claudeCode/toolName")
            .or(folded_name)
            .or_else(|| title.filter(|t| !t.is_empty() && !t.contains(char::is_whitespace)));
        let kind = hooks::acp_kind(s("/kind").or(folded_kind), name);
        let input = tool
            .and_then(|t| t.get("rawInput"))
            .cloned()
            .unwrap_or(Value::Null);
        let mut paths: Vec<PathBuf> = tool
            .and_then(|t| t.get("locations"))
            .and_then(Value::as_array)
            .map(|l| {
                l.iter()
                    .filter_map(|p| p.get("path").and_then(Value::as_str))
                    .map(PathBuf::from)
                    .collect()
            })
            .unwrap_or_default();
        for p in input_paths(&input) {
            if !paths.contains(&p) {
                paths.push(p);
            }
        }
        let command = input
            .get("command")
            .and_then(Value::as_str)
            .or(title.filter(|_| kind == "execute"))
            .map(str::to_owned);
        ToolCallInfo {
            kind: kind.to_owned(),
            name: name.map(str::to_owned),
            title: title.map(str::to_owned),
            input,
            paths,
            command,
            step,
        }
    }

    /// The call of TOOL on the hub's server SERVER with ARGS.
    pub fn hub_tool(server: &str, tool: &str, args: Value) -> ToolCallInfo {
        ToolCallInfo {
            kind: "drgnx".into(),
            name: Some(format!("mcp__{server}__{tool}")),
            title: None,
            paths: input_paths(&args),
            command: args
                .get("command")
                .and_then(Value::as_str)
                .map(str::to_owned),
            input: args,
            step: None,
        }
    }

    /// What the step is called in the agent's and the user's words: its tool, else its title, else its kind.
    pub fn step_name(&self) -> &str {
        self.name
            .as_deref()
            .or(self.title.as_deref())
            .unwrap_or(&self.kind)
    }
}

/// Whether NAME is one of the hub's own tools, hooked at its server rather than at the seam (`drgnx-search` is not:
/// it is read-only and its steps are hooked at the seam as `other`).
pub fn hub_tool_name(name: Option<&str>) -> bool {
    name.is_some_and(|n| n.starts_with("mcp__drgnx__") || n.starts_with("mcp__drgnx-plugins__"))
}

/// PATH relative to ROOT when inside it (as given, or with ROOT's links resolved), else as it is.
fn relative(root: Option<&Path>, path: &Path) -> PathBuf {
    let Some(root) = root.filter(|_| path.is_absolute()) else {
        return path.to_path_buf();
    };
    if let Ok(r) = path.strip_prefix(root) {
        return r.to_path_buf();
    }
    std::fs::canonicalize(root)
        .ok()
        .and_then(|c| path.strip_prefix(c).ok().map(Path::to_path_buf))
        .unwrap_or_else(|| path.to_path_buf())
}

/// The most of a tool's input a hook gets; a larger one is replaced by `{"truncated": true}` (the host refuses an
/// input over 256 KiB, which would fail the hook).
const MAX_TOOL_INPUT: usize = 192 * 1024;

fn cell_word(cell: Option<Cell>) -> Value {
    match cell.map(|c| c.verdict) {
        Some(Matrix::Allow) => json!("allow"),
        Some(Matrix::Ask) => json!("ask"),
        Some(Matrix::Never) => json!("never"),
        None => Value::Null,
    }
}

/// The `before-tool` input of CALL at SITE under CELL (design addendum §4.2): `run` adds `v`, `point`, `session`,
/// `step` and `previous`.
pub fn hook_input(site: &Site, call: &ToolCallInfo, cell: Option<Cell>) -> HookInput {
    let root = site.root.as_deref();
    let paths: Vec<PathBuf> = call.paths.iter().map(|p| relative(root, p)).collect();
    let input = if call.input.to_string().len() > MAX_TOOL_INPUT {
        json!({"truncated": true})
    } else {
        call.input.clone()
    };
    let detail = json!({
        "role": site.role, "profile": site.profile, "project": site.root, "job": site.job, "task": site.task,
        "cell": cell_word(cell),
        "tool": {"kind": call.kind, "name": call.name, "title": call.title, "input": input,
                 "paths": paths, "command": call.command},
    });
    HookInput {
        point: Point::BeforeTool,
        session: Some(site.session.clone()),
        step: call.step,
        tool_kind: Some(call.kind.clone()),
        tool: call.name.clone(),
        paths,
        command: call.command.clone(),
        detail,
    }
}

/// Re-reads a `before-tool` input's `paths` and `command` from its `tool.input` once a change is written in.
fn refresh_tool(root: Option<PathBuf>) -> impl Fn(&mut HookInput) + Sync {
    move |input: &mut HookInput| {
        let i = &input.detail["tool"]["input"];
        let command = i.get("command").and_then(Value::as_str).map(str::to_owned);
        let paths: Vec<PathBuf> = input_paths(i)
            .iter()
            .map(|p| relative(root.as_deref(), p))
            .collect();
        input.command = command;
        input.paths = paths;
    }
}

/// The rules and plugins that look at a step.
pub struct Prepared {
    pub rules: Vec<Rule>,
    pub plugins: Vec<Arc<Plugin>>,
}

/// The fast path: the rules and enabled plugins of SITE's project, when at least one looks at CALL; `None` when
/// nothing subscribes (the point is then what it was before hooks: no `dry`, no row).
pub fn prepare(plugins: &Plugins, site: &Site, call: &ToolCallInfo) -> Option<Prepared> {
    let project = site.project.as_deref();
    let rules = plugins.rules_for(project);
    let enabled = plugins.enabled_for(project);
    if rules.is_empty() && enabled.is_empty() {
        return None;
    }
    let input = hook_input(site, call, None);
    hooks::subscribed(&input, &rules, &enabled).then_some(Prepared {
        rules,
        plugins: enabled,
    })
}

/// The `before-tool` kinds the rules and enabled plugins of PROJECT subscribe to, sorted: a rule or a hook that
/// names no kind subscribes to all of them. What a session's lock makes ask about, at its launch.
pub fn subscribed_kinds(plugins: &Plugins, project: Option<&str>) -> Vec<String> {
    let all = || brokkr::TOOL_KINDS.iter().map(|k| (*k).to_owned());
    let mut kinds: Vec<String> = Vec::new();
    for r in plugins
        .rules_for(project)
        .iter()
        .filter(|r| r.point == Point::BeforeTool)
    {
        if r.tool_kinds.is_empty() {
            kinds.extend(all());
        } else {
            kinds.extend(r.tool_kinds.iter().cloned());
        }
    }
    for p in plugins.enabled_for(project) {
        for h in p
            .manifest
            .hooks
            .iter()
            .filter(|h| h.point == Point::BeforeTool)
        {
            match h.filter.as_ref().filter(|f| !f.tool_kinds.is_empty()) {
                Some(f) => kinds.extend(f.tool_kinds.iter().cloned()),
                None => kinds.extend(all()),
            }
        }
    }
    kinds.sort();
    kinds.dedup();
    kinds
}

/// What runs the hooks when no plugin is loaded: the rules alone, without starting the plugin host.
struct NoPlugins;

impl hooks::HookHost for NoPlugins {
    type Plugin = brokkr::Plugin;

    async fn run_hook(
        &self,
        _: &brokkr::Plugin,
        _: Point,
        _: Value,
        _: Duration,
    ) -> Result<Verdict, String> {
        Err("no plugin host".to_string())
    }

    fn refresh(&self, _: &mut HookInput) {}
}

/// The plugins that loaded, and the ones that did not, with why.
type Loaded = (Vec<Arc<brokkr::Plugin>>, Vec<(Arc<Plugin>, String)>);

/// PLUGINS loaded into the host (compiled once per approved hash; a first load reads, hashes and compiles off the
/// hub's workers when they are a pool), and the ones that would not load, with why.
fn load(plugins: &Plugins, list: &[Arc<Plugin>]) -> Loaded {
    let multi = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let loaded = if multi {
        tokio::task::block_in_place(|| plugins.loaded(list))
    } else {
        plugins.loaded(list)
    };
    let (mut ok, mut failed) = (Vec::new(), Vec::new());
    for (p, l) in list.iter().zip(loaded) {
        match l {
            Ok(l) => ok.push(l),
            Err((_, why)) => failed.push((p.clone(), why)),
        }
    }
    (ok, failed)
}

/// Runs the prepared rules and hooks on CALL at SITE under CELL (none: a hub tool whose matrix checks are in its
/// body, read as Allow), records the run, adds its notes under the step and steers a refusal into the turn.
///
/// Fail closed: a plugin that would not load, an I/O that could not be made and a hook that fails are each a deny
/// "hook NAME failed: …" (a note when the hook is advisory), never an allow.
pub async fn run(
    front: &Front,
    site: &Site,
    call: &ToolCallInfo,
    prepared: Prepared,
    cell: Option<Cell>,
) -> Outcome {
    let input = hook_input(site, call, cell);
    let budget = Duration::from_millis(u64::from(Point::BeforeTool.budget_ms()));
    let accepts = site.at.accepts_change();
    let (loaded, mut failed) = load(&front.core.plugins, &prepared.plugins);
    let mut records = if loaded.is_empty() {
        hooks::run(&input, budget, accepts, &prepared.rules, &[], &NoPlugins).await
    } else {
        let manifests: Vec<&brokkr::Manifest> = loaded.iter().map(|p| p.manifest()).collect();
        let io = crate::plugins::host_io(
            front,
            Some((
                crate::plugins::io::IoCtx::Session(site.session.clone()),
                crate::agents::session::SESSION_NET,
            )),
            &manifests,
        );
        match (front.core.plugins.host(), io) {
            (Ok(host), Ok(io)) => {
                let h = hooks::PluginHooks {
                    host,
                    io,
                    refresh: refresh_tool(site.root.clone()),
                };
                hooks::run(&input, budget, accepts, &prepared.rules, &loaded, &h).await
            }
            (host, io) => {
                let why = host
                    .err()
                    .or(io.err().map(|e| e.message))
                    .unwrap_or_default();
                let by_name = |n: &str| {
                    prepared
                        .plugins
                        .iter()
                        .find(|p| p.manifest.name.as_str() == n)
                };
                failed.extend(
                    loaded
                        .iter()
                        .filter_map(|l| by_name(l.name()).map(|p| (p.clone(), why.clone()))),
                );
                hooks::run(&input, budget, accepts, &prepared.rules, &[], &NoPlugins).await
            }
        }
    };
    // a plugin that could not run its matching hook fails it, after the others (the first deny still decides)
    for (p, why) in failed {
        if !hooks::subscribed(&input, &[], std::slice::from_ref(&p)) {
            continue;
        }
        let m = &p.manifest;
        let advisory = m
            .hooks
            .iter()
            .find(|h| h.point == Point::BeforeTool)
            .is_some_and(|h| h.advisory);
        records.push(Record {
            source: Source::Plugin {
                name: m.name.as_str().to_owned(),
                version: m.version.clone(),
                hash: p.hash,
            },
            verdict: None,
            ms: 0,
            error: Some(format!("hook {} failed: {why}", m.name.as_str())),
            advisory,
        });
    }
    let outcome = hooks::combine(cell, accepts, &records);
    let ctx = RowCtx {
        session: Some(site.session.clone()),
        step: call.step,
        job: site.job.clone(),
        task: site.task.clone(),
        tool: Some(call.step_name().to_owned()),
        at: Some(site.at.word()),
    };
    write_row(&front.writer, Point::BeforeTool, &ctx, &outcome).await;
    if let Ok(s) = front.core.agents.find(&site.session) {
        for (source, text) in notes(&outcome) {
            s.hook_note(call.step, source, text);
        }
        if let Some(text) = refusal(call.step_name(), &outcome) {
            s.steer_in(text);
        }
    }
    outcome
}

/// The rules and hooks of SITE's project on CALL under CELL: [`prepare`] then [`run`]. With nothing subscribed, the
/// matrix's cell alone decides, and nothing is recorded.
pub async fn before_tool(
    front: &Front,
    site: &Site,
    call: &ToolCallInfo,
    cell: Option<Cell>,
) -> Outcome {
    match prepare(&front.core.plugins, site, call) {
        Some(p) => run(front, site, call, p, cell).await,
        None => hooks::combine(cell, site.at.accepts_change(), &[]),
    }
}

/// The `before-tool` hooks of session SID's call of TOOL on the hub's server SERVER with ARGS (kind `drgnx`, the full
/// name `mcp__SERVER__TOOL`): `Ok` with the arguments that run (ARGS, or the last accepted change's), `Err` with the
/// refusal the tool answers. The tool's own matrix checks, in its body, read what runs.
pub async fn at_hub_server(
    front: &Front,
    sid: &str,
    server: &'static str,
    tool: &str,
    args: Value,
) -> Result<Value, String> {
    let session = front.core.agents.find(sid).ok();
    let site = match &session {
        Some(s) => s.hook_site(At::HubServer).await,
        None => Site {
            at: At::HubServer,
            session: sid.to_owned(),
            ..Site::default()
        },
    };
    let mut call = ToolCallInfo::hub_tool(server, tool, args.clone());
    call.step = session.as_ref().and_then(|s| s.current_step());
    let Some(prepared) = prepare(&front.core.plugins, &site, &call) else {
        return Ok(args);
    };
    let out = run(front, &site, &call, prepared, None).await;
    match out.decision {
        Decision::Deny(_) => Err(refusal(call.step_name(), &out).unwrap_or_default()),
        Decision::Proceed { changed } | Decision::Ask { changed } => Ok(changed
            .and_then(|c| c.get("arguments").cloned())
            .unwrap_or(args)),
    }
}

/// A hub tool's step reached the seam: its hooks run at the hub's server, not here. When something there looks at
/// it, the seam's row says so ("hooked at the hub's server"); the matrix still checks the step here.
pub async fn hub_tool_at_the_seam(front: &Front, site: &Site, call: &ToolCallInfo) {
    let at_server = Site {
        at: At::HubServer,
        ..site.clone()
    };
    let server_call = ToolCallInfo {
        kind: "drgnx".into(),
        ..call.clone()
    };
    if prepare(&front.core.plugins, &at_server, &server_call).is_none() {
        return;
    }
    let mut data = envelope(
        Point::BeforeTool,
        &RowCtx {
            session: Some(site.session.clone()),
            step: call.step,
            job: site.job.clone(),
            task: site.task.clone(),
            tool: Some(call.step_name().to_owned()),
            at: Some(At::Seam.word()),
        },
    );
    data.insert("records".into(), json!([]));
    data.insert("outcome".into(), json!("at-server"));
    data.insert("why".into(), json!("hooked at the hub's server"));
    let summary = format!("hook: {} is hooked at the hub's server", call.step_name());
    write(
        &front.writer,
        site.session.clone(),
        site.job.clone(),
        site.task.clone(),
        summary,
        Value::Object(data),
    )
    .await;
}

/// Who decided OUTCOME, in the refusal's words.
fn who(outcome: &Outcome) -> String {
    match outcome.decided_by.and_then(|i| outcome.provenance.get(i)) {
        Some(Record {
            source: Source::Rule { id: Some(id), .. },
            ..
        }) => format!("the rule {id}"),
        Some(Record {
            source: Source::Rule { id: None, index },
            ..
        }) => format!("the rule {index}"),
        Some(Record {
            source: Source::Plugin { name, .. },
            ..
        }) => format!("the hook {name}"),
        None => "the permissions matrix".into(),
    }
}

/// What the agent is told of a refused STEP: the hub's words, the rule's or hook's quoted as data.
/// `None` when OUTCOME does not refuse.
pub fn refusal(step: &str, outcome: &Outcome) -> Option<String> {
    let Decision::Deny(reason) = &outcome.decision else {
        return None;
    };
    Some(format!(
        "drgnx refused {step}; {} said: «{reason}»",
        who(outcome)
    ))
}

/// OUTCOME's notes with the source each came from (as `combine` made them: annotations, then an advisory hook's
/// failure, in run order; the "+N more" line has none).
fn notes(outcome: &Outcome) -> Vec<(Option<String>, String)> {
    let sources: Vec<String> = outcome
        .provenance
        .iter()
        .filter(|r| match (&r.verdict, &r.error) {
            (_, Some(_)) => r.advisory,
            (Some(Verdict::Annotate(_)), None) => true,
            _ => false,
        })
        .map(|r| r.source.to_string())
        .collect();
    outcome
        .annotations
        .iter()
        .enumerate()
        .map(|(i, text)| {
            let more = i == hooks::MAX_ANNOTATIONS && text.starts_with('+');
            (
                (!more).then(|| sources.get(i).cloned()).flatten(),
                text.clone(),
            )
        })
        .collect()
}

// ------------------------------------------------------------------------------------------------- the row

/// The facts a row carries beside its records.
#[derive(Clone, Debug, Default)]
pub struct RowCtx {
    pub session: Option<String>,
    /// The session's step (`step.seq`).
    pub step: Option<i64>,
    pub job: Option<String>,
    pub task: Option<String>,
    /// The step's tool (`Bash`, `mcp__drgnx__merge`).
    pub tool: Option<String>,
    /// Where the point ran ([`At::word`]); none for the points that are not before a tool call.
    pub at: Option<&'static str>,
}

fn point_word(p: Point) -> &'static str {
    match p {
        Point::BeforeTool => "before-tool",
        Point::AfterEdit => "after-edit",
        Point::BeforeCommit => "before-commit",
        Point::AtReview => "at-review",
    }
}

fn envelope(point: Point, ctx: &RowCtx) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("hook".into(), json!(true));
    m.insert("point".into(), json!(point_word(point)));
    let mut put = |k: &str, v: Option<Value>| {
        if let Some(v) = v {
            m.insert(k.into(), v);
        }
    };
    put("session", ctx.session.as_ref().map(|v| json!(v)));
    put("step", ctx.step.map(|v| json!(v)));
    put("job", ctx.job.as_ref().map(|v| json!(v)));
    put("task", ctx.task.as_ref().map(|v| json!(v)));
    put("tool", ctx.tool.as_ref().map(|v| json!(v)));
    put("at", ctx.at.map(|v| json!(v)));
    m
}

fn outcome_word(o: &Outcome) -> &'static str {
    match &o.decision {
        Decision::Deny(_) => "deny",
        Decision::Ask { .. } => "ask",
        Decision::Proceed { changed: Some(_) } => "change",
        Decision::Proceed { changed: None } => "allow",
    }
}

fn verdict_word(r: &Record) -> &'static str {
    match (&r.verdict, &r.error) {
        (Some(v), _) => v.word(),
        (None, Some(_)) => "error",
        (None, None) => "not run",
    }
}

/// The text a record's reason keeps: a deny's reason, a note, a failure.
fn reason_of(r: &Record) -> Option<&str> {
    match (&r.verdict, &r.error) {
        (_, Some(e)) => Some(e),
        (Some(Verdict::Deny(t) | Verdict::Annotate(t)), None) => Some(t),
        _ => None,
    }
}

fn chars(v: &Value) -> usize {
    v.to_string().chars().count()
}

/// TEXT cut to at most N characters (`…` ending a cut one).
fn cut(text: &str, n: usize) -> String {
    if text.chars().count() <= n {
        return text.to_owned();
    }
    let mut s: String = text.chars().take(n.saturating_sub(1)).collect();
    s.push('…');
    s
}

/// The most of an annotation's text a row keeps: its `note` entry keeps it whole.
const ROW_NOTE_CHARS: usize = 200;

/// The row of one point run, within [`DATA_MAX`] so it is never replaced by `{"truncated": true}`:
/// 1. the envelope and each record's `{source, verdict, ms}`, always;
/// 2. the deciding record's reason, first claim on what is left;
/// 3. the other records' reasons, sharing the rest (an annotation at most 200 characters);
/// 4. when even the sources do not fit, the deciding record alone and `"more": N`.
pub fn record_data(point: Point, ctx: &RowCtx, outcome: &Outcome) -> Value {
    let prov = &outcome.provenance;
    let light = |r: &Record| json!({"source": r.source.to_string(), "verdict": verdict_word(r), "ms": r.ms});
    let mut v = Value::Object(envelope(point, ctx));
    v["outcome"] = json!(outcome_word(outcome));
    let mut kept: Vec<usize> = (0..prov.len()).collect();
    v["records"] = Value::Array(prov.iter().map(light).collect());
    if chars(&v) > DATA_MAX {
        kept = outcome
            .decided_by
            .or_else(|| (!prov.is_empty()).then_some(prov.len() - 1))
            .into_iter()
            .collect();
        v["records"] = Value::Array(kept.iter().map(|i| light(&prov[*i])).collect());
        v["more"] = json!(prov.len() - kept.len());
    }
    // the room a reason of LEN characters may take now, for the record at POS
    let put = |v: &mut Value, pos: usize, text: &str, cap: usize| {
        let overhead = ",\"reason\":\"\"".len();
        let room = DATA_MAX.saturating_sub(chars(v) + overhead).min(cap);
        if room == 0 {
            return;
        }
        let mut n = room;
        loop {
            v["records"][pos]["reason"] = json!(cut(text, n));
            let over = chars(v).saturating_sub(DATA_MAX);
            if over == 0 {
                return;
            }
            if n <= over {
                if let Some(o) = v["records"][pos].as_object_mut() {
                    o.remove("reason");
                }
                return;
            }
            n -= over;
        }
    };
    let deciding = outcome
        .decided_by
        .and_then(|d| kept.iter().position(|i| *i == d));
    if let (Some(pos), Some(text)) = (
        deciding,
        outcome.decided_by.and_then(|d| reason_of(&prov[d])),
    ) {
        put(&mut v, pos, text, usize::MAX);
    }
    let others: Vec<(usize, &Record)> = kept
        .iter()
        .enumerate()
        .filter(|(pos, _)| Some(*pos) != deciding)
        .map(|(pos, i)| (pos, &prov[*i]))
        .filter(|(_, r)| reason_of(r).is_some())
        .collect();
    if !others.is_empty() {
        let share = DATA_MAX.saturating_sub(chars(&v)) / others.len();
        for (pos, r) in others {
            let cap = if matches!(r.verdict, Some(Verdict::Annotate(_))) {
                ROW_NOTE_CHARS.min(share)
            } else {
                share
            };
            let text = reason_of(r).unwrap_or_default();
            put(
                &mut v,
                pos,
                text,
                cap.saturating_sub(",\"reason\":\"\"".len()),
            );
        }
    }
    v
}

fn summary_of(ctx: &RowCtx, outcome: &Outcome) -> String {
    let tool = ctx.tool.as_deref().unwrap_or("the step");
    match &outcome.decision {
        Decision::Deny(_) => {
            let by = outcome
                .decided_by
                .and_then(|i| outcome.provenance.get(i))
                .map_or("the matrix".to_owned(), |r| r.source.name());
            format!("hook: {by} refused {tool}")
        }
        _ => format!("hook: {tool}: {}", outcome_word(outcome)),
    }
}

/// The hub's hook writer: a caller whose writes are `hub:hooks` ([`crate::coord::HOOKS_METHOD`]).
fn hooks_caller() -> Caller {
    Caller {
        class: runstav::registry::Class::Service,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

async fn write(
    writer: &crate::coord::Writer,
    session: String,
    job: Option<String>,
    task: Option<String>,
    summary: String,
    data: Value,
) {
    let at = crate::clock::wall_secs();
    let r = writer
        .write(&hooks_caller(), crate::coord::HOOKS_METHOD, move |tx| {
            event(
                tx,
                Event {
                    at,
                    agent: Some(session),
                    job,
                    task,
                    kind: EventKind::Status,
                    summary,
                    data: Some(data),
                    turn: false,
                },
            )
        })
        .await;
    if let Err(e) = r {
        tracing::warn!("a hook row was not written: {e}");
    }
}

/// Writes the row of one point run at POINT ([`record_data`]), as the hub's hook writer.
pub async fn write_row(
    writer: &crate::coord::Writer,
    point: Point,
    ctx: &RowCtx,
    outcome: &Outcome,
) {
    let data = record_data(point, ctx, outcome);
    let summary = summary_of(ctx, outcome);
    write(
        writer,
        ctx.session.clone().unwrap_or_default(),
        ctx.job.clone(),
        ctx.task.clone(),
        summary,
        data,
    )
    .await;
}

/// Session SID's step STEP's provenance: the hub's hook rows for it, oldest first. Rows of any other writer
/// (`events/add` takes any data) are never read.
pub fn provenance(c: &Tx, sid: &str, step: i64) -> Result<Vec<Value>, CoordError> {
    let mut st = c.prepare(
        "select e.data from event e join tx t on t.id = e.tx \
         where t.actor = ?1 and e.kind = 'status' and e.agent = ?2 \
           and json_extract(e.data, '$.hook') = 1 and json_extract(e.data, '$.step') = ?3 \
         order by e.id",
    )?;
    let rows = st
        .query_map((crate::coord::HOOKS_ACTOR, sid, step), |r| {
            r.get::<_, Option<String>>(0)
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows
        .into_iter()
        .flatten()
        .filter_map(|t| serde_json::from_str(&t).ok())
        .collect())
}

#[cfg(test)]
mod tests;
