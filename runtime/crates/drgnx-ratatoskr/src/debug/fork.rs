//! What-if forks (spec §19.3, D2): a recorded run replayed in a sealed copy, changed at a point, and run on.
//!
//! - [`check`]: what can be forked: a launch (never an attach) of debugpy or js-debug, on Linux; delve and lldb-dap
//!   are refused with the reason (Gleipnir always denies ptrace, Q16); a fork whose point came over 60 s after the
//!   launch asks first. The fork point is a breakpoint stop (the hub counts the line's hits to N itself, capped at
//!   [`HIT_CAP`]; `hitCondition`'s syntax is the adapter's own) or a step stop (the last breakpoint stop before it,
//!   then the recorded steps again).
//! - [`for_tree`]: the resolved configuration moved into the fork's tree (every string that names the project).
//! - [`drive`]: the session in the sandbox, from the launch to the fork point, the change (`setExpression` when the
//!   adapter has it and the value an `evaluateName`, else `setVariable`), and on to the chosen end; the probes' hits
//!   on both sides of the point, for [`super::compare`].
//!
//! - [`watch`]: a plain run in a tree of the caller's (D5's predicates), to the program's end: where a watched
//!   exception stops, or a probe's values, within a time box.
//!
//! The tree, the sandbox and the protocol are in [`super::fork_hub`].

use super::probes::{log_message, parse, thread_expr};
use super::record::{RunHit, RunInfo, RunProbe};
use super::session::{self, Handle, Op, Request, SourceBps, Start, Stop, Update};
use super::{Connected, Launcher};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// The most hits of the fork line the hub counts through.
pub const HIT_CAP: u32 = 10_000;
/// A fork whose point came later than this after the launch asks first.
pub const ASK_AFTER_MS: u64 = 60_000;

/// Where the fork stops: a stop of the run (its `index`), or the N-th pass of a line.
#[derive(Clone, Debug, PartialEq)]
pub enum At {
    Stop(u64),
    Hit { path: String, line: u32, hit: u32 },
}

/// What the fork changes at its point.
#[derive(Clone, Debug, PartialEq)]
pub enum Change {
    /// Nothing: the run again (or a past stop's missing values).
    Nothing,
    /// A value, by its name path in the stopped frame's scopes (`["item", "reserve"]`), set to an expression.
    Value { path: Vec<String>, text: String },
    /// The code: the tree was edited before the launch.
    Code,
}

/// Where the fork ends.
#[derive(Clone, Debug, PartialEq)]
pub enum Until {
    /// The next stop: the run's later breakpoint lines.
    NextStop,
    /// The program's end.
    Exit,
    /// The next hit of this probe after the point.
    Probe(String),
    /// The point itself: the fork ends there (a replay to a stop, D3's trace).
    Here,
}

/// The fork point as the session reaches it: the breakpoint at PATH:LINE stopped HIT times, then STEPS.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub path: String,
    pub line: u32,
    pub hit: u32,
    pub steps: Vec<String>,
    /// The run's event order of the point: its hits before it are the ones compared.
    pub seq: Option<u64>,
    /// How many probe hits the run had before it reached the line's pass (when it stopped there): where the adapter
    /// counts the passes, the fork's landing must have had as many.
    pub before: Option<usize>,
    /// The run's breakpoint stop at the line's pass (when it stopped there).
    pub landing: Option<u64>,
    /// What the run recorded at that stop (its capture: frames, scopes), which the adapter's landing must match.
    pub recorded: Option<Value>,
}

/// RUN's probe hits before its event INDEX.
fn hits_before(run: &RunInfo, index: u64) -> usize {
    run.hits.iter().filter(|h| h.seq < index).count()
}

/// Why a fork is not made, or what it asks first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refused {
    No(String),
    /// Ask the user (the run reached its point after a minute): the question.
    Ask(String),
}

/// The adapter of type TY, as forks know it: `debugpy`, `js-debug`, or the reason there is no fork.
pub fn fork_adapter(ty: &str) -> Result<&'static str, String> {
    match ty {
        "debugpy" | "python" => Ok("debugpy"),
        "pwa-node" | "node" => Ok("js-debug"),
        "go" => Err(
            "Go runs under delve, which needs ptrace, and the sandbox always denies it: Go forks wait for rr".into(),
        ),
        "lldb-dap" | "lldb-vscode" | "lldb" | "gdb" | "cppdbg" => Err(
            "native code runs under a debugger that needs ptrace, and the sandbox always denies it: native forks wait for rr"
                .into(),
        ),
        other => Err(format!(
            "forks replay Python (debugpy) and JavaScript (js-debug) runs; \"{other}\" is neither"
        )),
    }
}

/// RUN forked at AT on this machine (LINUX: forks run on Linux only for now); CONFIRMED: the user said yes to a slow
/// replay.
pub fn check(run: &RunInfo, at: &At, linux: bool, confirmed: bool) -> Result<Target, Refused> {
    if run.request == "attach" {
        return Err(Refused::No(
            "an attach session cannot be replayed: the hub did not start its program".into(),
        ));
    }
    fork_adapter(&run.adapter_id).map_err(Refused::No)?;
    if !linux {
        return Err(Refused::No(
            "forks run in Gleipnir's full tier on Linux; on macOS they wait for the adapters' port blocks in Seatbelt"
                .into(),
        ));
    }
    if run.snapshot.is_none() {
        return Err(Refused::No(
            "the run has no launch snapshot, so the files that ran are not known".into(),
        ));
    }
    let (target, t_ms) = match at {
        At::Hit { path, line, hit } => {
            if *hit == 0 || *hit > HIT_CAP {
                return Err(Refused::No(format!(
                    "a fork counts hits 1 to {HIT_CAP}; hit {hit} is out of range"
                )));
            }
            // the run's stop at that hit, when it stopped there: its time and order
            let stop = run.stops.iter().find(|s| {
                s.path == *path && s.line == *line && s.bp_hit == Some(*hit) && s.steps.is_empty()
            });
            (
                Target {
                    path: path.clone(),
                    line: *line,
                    hit: *hit,
                    steps: vec![],
                    seq: stop.map(|s| s.index),
                    before: stop.map(|s| hits_before(run, s.index)),
                    landing: stop.map(|s| s.index),
                    recorded: None,
                },
                stop.map(|s| s.t_ms),
            )
        }
        At::Stop(index) => {
            let k = run
                .stops
                .iter()
                .position(|s| s.index == *index)
                .ok_or_else(|| Refused::No(format!("the run has no stop {index}")))?;
            let stop = &run.stops[k];
            // the breakpoint stop it was reached from
            let from = run.stops[..=k]
                .iter()
                .rev()
                .find(|s| s.bp_hit.is_some())
                .ok_or_else(|| {
                    Refused::No("no breakpoint stop comes before this stop to replay to".into())
                })?;
            (
                Target {
                    path: from.path.clone(),
                    line: from.line,
                    hit: from.bp_hit.unwrap_or(1),
                    steps: stop.steps.clone(),
                    seq: Some(stop.index),
                    before: Some(hits_before(run, from.index)),
                    landing: Some(from.index),
                    recorded: None,
                },
                Some(stop.t_ms),
            )
        }
    };
    if !confirmed && let Some(ms) = t_ms.or(run.to_stop_ms).filter(|ms| *ms > ASK_AFTER_MS) {
        return Err(Refused::Ask(format!(
            "the run took {} s to reach this point; replaying it takes about as long",
            ms / 1000
        )));
    }
    Ok(target)
}

/// PATH moved from ROOT into TREE (unchanged when it is not under ROOT).
pub fn into_tree(path: &str, root: &Path, tree: &Path) -> String {
    let root = root.to_string_lossy();
    let root = root.trim_end_matches('/');
    match path.strip_prefix(root) {
        Some("") => tree.to_string_lossy().into_owned(),
        Some(rest) if rest.starts_with('/') => format!("{}{rest}", tree.to_string_lossy()),
        _ => path.to_owned(),
    }
}

/// PATH moved back from TREE into ROOT.
pub fn from_tree(path: &str, root: &Path, tree: &Path) -> String {
    into_tree(path, tree, root)
}

/// CONFIG with every string that names ROOT (or a path under it) naming the same place in TREE: the program, its
/// cwd, its arguments.
pub fn for_tree(config: &Value, root: &Path, tree: &Path) -> Value {
    match config {
        Value::String(s) => {
            let r = root.to_string_lossy();
            let r = r.trim_end_matches('/');
            // a path in a longer string (`--config=/p/x`) moves too, on a whole-component match
            let mut out = String::with_capacity(s.len());
            let mut rest = s.as_str();
            while let Some(i) = rest.find(r) {
                let after = &rest[i + r.len()..];
                let starts = i == 0 || !rest[..i].ends_with(|c: char| c.is_alphanumeric());
                let ends = after.is_empty() || after.starts_with(['/', ' ', '"', '\'', ':', ',']);
                out.push_str(&rest[..i]);
                if starts && ends {
                    out.push_str(&tree.to_string_lossy());
                } else {
                    out.push_str(r);
                }
                rest = after;
            }
            out.push_str(rest);
            Value::String(out)
        }
        Value::Array(a) => Value::Array(a.iter().map(|x| for_tree(x, root, tree)).collect()),
        Value::Object(m) => Value::Object(
            m.iter()
                .map(|(k, v)| (k.clone(), for_tree(v, root, tree)))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// The fork's breakpoints: the probes as logpoints, their messages as the run recorded them for ADAPTER_ID (the
/// configuration's type), and the fork line's plain breakpoint (a probe on that line is read at each of its stops
/// instead), plus STOP_AT's lines; paths as given.
pub fn breakpoints(
    adapter_id: &str,
    probes: &[RunProbe],
    fork_line: Option<(&str, u32)>,
    stop_at: &[(String, u32)],
) -> Vec<SourceBps> {
    let mut by_path: Vec<SourceBps> = vec![];
    let mut put = |path: &str, bp: Value| match by_path.iter_mut().find(|s| s.path == path) {
        Some(s) => {
            let line = bp.get("line").cloned();
            if !s.breakpoints.iter().any(|b| b.get("line") == line.as_ref()) {
                s.breakpoints.push(bp);
            }
        }
        None => by_path.push(SourceBps {
            path: path.to_owned(),
            breakpoints: vec![bp],
        }),
    };
    if let Some((path, line)) = fork_line {
        put(path, json!({"line": line}));
    }
    for (path, line) in stop_at {
        put(path, json!({"line": line}));
    }
    for p in probes {
        put(
            &p.path,
            json!({"line": p.line, "logMessage": log_message(adapter_id, &p.id, &p.expr)}),
        );
    }
    by_path
}

/// How a fork ended.
#[derive(Clone, Debug, PartialEq)]
pub enum End {
    /// Stopped at PATH:LINE (the next stop), with the top frame's first scope's variables.
    Stop {
        path: String,
        line: u32,
        reason: String,
        locals: Vec<Value>,
    },
    /// The probe's next hit came.
    Probe { probe: String, value: String },
    /// The program ended (its exit code when the adapter said).
    Exit { code: Option<i64> },
}

/// What [`drive`] found.
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    /// The probes' hits before the point (in the order they came) and after it.
    pub before: Vec<RunHit>,
    pub after: Vec<RunHit>,
    /// The stopping thread's thread-expression value, at the point.
    pub thread: Option<String>,
    /// The changed value as the adapter showed it.
    pub applied: Option<String>,
    /// The stop at the point: path and line.
    pub at: (String, u32),
    pub end: End,
}

/// A fork's session: started with START through LAUNCHER, driven to TARGET, CHANGE applied, run on UNTIL.
pub struct Drive {
    pub launcher: Arc<dyn Launcher>,
    pub start: Start,
    pub adapter: String,
    pub target: Target,
    pub probes: Vec<RunProbe>,
    pub change: Change,
    pub until: Until,
    /// The run's breakpoint lines after the point, for [`Until::NextStop`].
    pub later: Vec<(String, u32)>,
}

/// One session of the fork (the root and js-debug's children): its handle and whether it is configured.
struct Sess {
    handle: Handle,
    caps: Value,
    ended: bool,
}

/// The sessions and their merged updates.
struct Tree {
    sessions: Vec<Sess>,
    tx: mpsc::UnboundedSender<(usize, Update)>,
    rx: mpsc::UnboundedReceiver<(usize, Update)>,
    seq: u64,
    hits: Vec<RunHit>,
    /// The breakpoints as they are now: a child session starts with them.
    bps: Vec<SourceBps>,
}

impl Tree {
    fn add(&mut self, start: Start, c: Connected) -> usize {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let handle = session::spawn(start, c.client, c.incoming, c.proc, tx);
        let i = self.sessions.len();
        self.sessions.push(Sess {
            handle,
            caps: Value::Null,
            ended: false,
        });
        let out = self.tx.clone();
        crate::clock::spawn("debug:fork-updates", async move {
            while let Some(u) = rx.recv().await {
                if out.send((i, u)).is_err() {
                    return;
                }
            }
        });
        i
    }

    fn hit(&mut self, output: &str) -> Option<RunHit> {
        let (probe, thread, value) = parse(output)?;
        let h = RunHit {
            probe,
            thread,
            value,
            seq: self.seq,
            t_ms: 0,
        };
        self.seq += 1;
        self.hits.push(h.clone());
        Some(h)
    }
}

/// What the next update brought, as the driver needs it.
enum Next {
    Stopped(usize, Stop),
    Hit(RunHit),
    /// The root session ended (its exit code).
    Ended(Option<i64>),
}

/// The top frame of STOP: (path, line).
fn top(stop: &Stop) -> (String, u32) {
    let f = stop.frames.first();
    (
        f.and_then(|f| f.pointer("/source/path"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        f.and_then(|f| f.get("line"))
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
    )
}

impl Drive {
    /// The next update that matters (see [`next_of`]).
    async fn next(&self, t: &mut Tree) -> Result<Next, String> {
        next_of(&self.start, &self.launcher, t).await
    }
}

/// The next update of T that matters, handling the rest (children started like START through LAUNCHER, caps, ends
/// of children).
async fn next_of(
    start0: &Start,
    launcher: &Arc<dyn Launcher>,
    t: &mut Tree,
) -> Result<Next, String> {
    loop {
        let Some((i, u)) = t.rx.recv().await else {
            return Err("the fork's session is gone".into());
        };
        match u {
            Update::Caps(c) => t.sessions[i].caps = c,
            Update::Stopped(s) => return Ok(Next::Stopped(i, s)),
            Update::Event { event, body } if event == "output" => {
                if let Some(h) = body
                    .get("output")
                    .and_then(Value::as_str)
                    .and_then(|o| t.hit(o))
                {
                    return Ok(Next::Hit(h));
                }
            }
            Update::StartDebugging { arguments, reply } => {
                let mut start = start0.clone();
                start.breakpoints = t.bps.clone();
                start.arguments = arguments
                    .get("configuration")
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                start.request =
                    if arguments.get("request").and_then(Value::as_str) == Some("attach") {
                        Request::Attach
                    } else {
                        Request::Launch
                    };
                match launcher.child().await {
                    Ok(c) => {
                        t.add(start, c);
                        let _ = reply.send(Ok(()));
                    }
                    Err(e) => {
                        let _ = reply.send(Err(e));
                    }
                }
            }
            Update::RunInTerminal { reply, .. } => {
                let _ = reply.send(Err("a fork has no terminal".into()));
            }
            Update::Ended(end) => {
                t.sessions[i].ended = true;
                if i == 0 {
                    return Ok(Next::Ended(end.exit_code));
                }
            }
            _ => {}
        }
    }
}

impl Drive {
    /// Every configured session gets PATH's breakpoints BPS.
    /// Whether a probe sits on the fork line (read at each pass, so the fork stops at each).
    fn probe_on_line(&self) -> bool {
        self.probes
            .iter()
            .any(|p| p.path == self.target.path && p.line == self.target.line)
    }

    /// The breakpoint field that stops at the target's pass, and its text. js-debug counts a `hitCondition` by
    /// pausing at every pass (about 30 ms each in a fork); a condition with a counter runs inside V8 without a pause.
    fn pass_condition(&self) -> (&'static str, String) {
        let n = self.target.hit;
        if super::probes::lang(&self.start.adapter_id) == super::probes::Lang::Js {
            (
                "condition",
                // a registered symbol as the key: no name of the program's own can clash with it, and it is not
                // enumerated by `Object.keys(globalThis)` or `for … in`
                format!(
                    "(globalThis[Symbol.for('drgnx.forkPass')] = (globalThis[Symbol.for('drgnx.forkPass')] || 0) + 1) === {n}"
                ),
            )
        } else {
            ("hitCondition", n.to_string())
        }
    }

    /// Whether the adapter with CAPS counts the fork line's passes (the field of [`Self::pass_condition`]).
    fn adapter_counts(&self, caps: &Value) -> bool {
        let cap = match self.pass_condition().0 {
            "condition" => "supportsConditionalBreakpoints",
            _ => "supportsHitConditionalBreakpoints",
        };
        self.target.hit > 1
            && !self.probe_on_line()
            && caps.get(cap).and_then(Value::as_bool).unwrap_or(false)
    }

    /// The adapter's count landed the fork: it must have had the run's probe hits before that pass.
    /// The adapter's count landed the fork at STOP: it must have had the run's probe hits before that pass, the
    /// run's stack there (names and lines), and, where no probe hit says which pass it is, the run's plain locals.
    fn landed(&self, t: &Tree, stop: &Stop) -> Result<(), String> {
        let not = |why: String| {
            Err(format!(
                "the adapter stopped at pass {} of line {} by its own count, but that is not the run's pass: {why}",
                self.target.hit, self.target.line
            ))
        };
        if let Some(want) = self.target.before
            && t.hits.len() != want
        {
            return not(format!(
                "the run had {want} probe hits before it, the fork {}",
                t.hits.len()
            ));
        }
        let Some(rec) = &self.target.recorded else {
            return Ok(());
        };
        let stack = |frames: &[Value]| -> Vec<String> {
            frames
                .iter()
                .map(|f| {
                    format!(
                        "{}:{}",
                        f.get("name").and_then(Value::as_str).unwrap_or("?"),
                        f.get("line").and_then(Value::as_u64).unwrap_or(0)
                    )
                })
                .collect()
        };
        let then = stack(
            rec.get("frames")
                .and_then(Value::as_array)
                .map_or(&[][..], |v| v),
        );
        let now = stack(&stop.frames);
        let n = then.len().min(now.len());
        if then[..n] != now[..n] {
            return not(format!(
                "the run's stack there was {}, the fork's {}",
                then[..n].join(" < "),
                now[..n].join(" < ")
            ));
        }
        if !t.hits.is_empty() || self.target.before.is_some_and(|b| b > 0) {
            return Ok(());
        }
        // no probe hit tells the passes apart: the plain locals the run recorded must be the fork's
        let plain = |vars: &[Value]| -> Vec<(String, String)> {
            vars.iter()
                .filter(|v| {
                    v.get("variablesReference")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        == 0
                })
                .filter_map(|v| {
                    Some((
                        v.get("name")?.as_str()?.to_owned(),
                        v.get("value")?.as_str()?.to_owned(),
                    ))
                })
                .collect()
        };
        let recorded_vars: Vec<Value> = rec
            .get("scopes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find_map(|s| s.get("variables").and_then(Value::as_array).cloned())
            .unwrap_or_default();
        let fork_vars = plain(&locals(stop));
        for (name, was) in plain(&recorded_vars) {
            if let Some((_, is)) = fork_vars.iter().find(|(n, _)| *n == name)
                && *is != was
            {
                return not(format!(
                    "{name} was {was} in the run there, {is} in the fork"
                ));
            }
        }
        Ok(())
    }

    async fn set_bps(&self, t: &mut Tree, all: &[SourceBps]) {
        t.bps = all.to_vec();
        for s in t.sessions.iter().filter(|s| !s.ended && !s.caps.is_null()) {
            for sb in all {
                let args = json!({"source": {"path": sb.path},
                                  "breakpoints": super::breakpoints::fit(&sb.breakpoints, &s.caps)});
                if let Err(e) = s.handle.request("setBreakpoints", args).await {
                    tracing::debug!(target: "drgnx::debug", "fork setBreakpoints {}: {e}", sb.path);
                }
            }
        }
    }

    /// The probe on PATH:LINE read in STOP's top frame of session I, as a hit (a probe on the fork line, whose
    /// logpoint gives way to the plain breakpoint).
    async fn read_probe(&self, t: &mut Tree, i: usize, stop: &Stop, path: &str, line: u32) {
        let Some(p) = self
            .probes
            .iter()
            .find(|p| p.path == path && p.line == line)
        else {
            return;
        };
        let frame = stop.frames.first().and_then(|f| f.get("id")).cloned();
        let eval = |e: String| {
            let h = t.sessions[i].handle.clone();
            let frame = frame.clone();
            async move {
                h.request(
                    "evaluate",
                    json!({"expression": e, "frameId": frame, "context": "watch"}),
                )
                .await
                .ok()
                .and_then(|b| b.get("result").and_then(Value::as_str).map(str::to_owned))
            }
        };
        let thread = match thread_expr(&self.start.adapter_id) {
            // no thread in the language: the run's hits name none either
            "" => Some(String::new()),
            e => eval(e.to_owned()).await,
        };
        let value = eval(p.expr.clone()).await;
        if let (Some(thread), Some(value)) = (thread, value) {
            let h = RunHit {
                probe: p.id.clone(),
                thread,
                value,
                seq: t.seq,
                t_ms: 0,
            };
            t.seq += 1;
            t.hits.push(h);
        }
    }

    /// Ends the fork's sessions, children before their root (the program goes with them).
    async fn finish(t: &mut Tree) {
        for s in t.sessions.iter().rev().filter(|s| !s.ended) {
            let _ = s
                .handle
                .op(Op::Stop {
                    kill_debuggee: Some(true),
                })
                .await;
        }
    }
}

/// The value at PATH in STOP's scopes of session H: (its container's reference, the variable).
async fn find_var(h: &Handle, stop: &Stop, path: &[String]) -> Result<(i64, Value), String> {
    let (first, rest) = path.split_first().ok_or("no value named")?;
    let mut found = None;
    for s in &stop.scopes {
        let reference = s
            .scope
            .get("variablesReference")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let vars = match &s.variables {
            Some(v) => v.clone(),
            None => h.variables(stop.epoch, reference).await.unwrap_or_default(),
        };
        if let Some(v) = vars
            .into_iter()
            .find(|v| v.get("name").and_then(Value::as_str) == Some(first))
        {
            found = Some((reference, v));
            break;
        }
    }
    let (mut parent, mut var) =
        found.ok_or_else(|| format!("no value {first} at the fork point"))?;
    for name in rest {
        let reference = var
            .get("variablesReference")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if reference == 0 {
            return Err(format!("{} has no member {name}", path.join(".")));
        }
        let vars = h.variables(stop.epoch, reference).await?;
        var = vars
            .into_iter()
            .find(|v| v.get("name").and_then(Value::as_str) == Some(name.as_str()))
            .ok_or_else(|| format!("no value {name} in {}", path.join(".")))?;
        parent = reference;
    }
    Ok((parent, var))
}

/// The change at the point: `setExpression` when CAPS have it and the value an `evaluateName`, else `setVariable`;
/// the new value as the adapter shows it.
async fn apply(
    h: &Handle,
    caps: &Value,
    stop: &Stop,
    path: &[String],
    text: &str,
) -> Result<String, String> {
    let (parent, var) = find_var(h, stop, path).await?;
    let frame = stop.frames.first().and_then(|f| f.get("id")).cloned();
    let expr = var.get("evaluateName").and_then(Value::as_str);
    let body = match expr {
        Some(e) if caps.get("supportsSetExpression").and_then(Value::as_bool) == Some(true) => {
            h.request(
                "setExpression",
                json!({"expression": e, "value": text, "frameId": frame}),
            )
            .await?
        }
        _ if caps.get("supportsSetVariable").and_then(Value::as_bool) == Some(true) => {
            h.request(
                "setVariable",
                json!({"variablesReference": parent, "name": var.get("name"), "value": text}),
            )
            .await?
        }
        _ => return Err("the adapter cannot set values".into()),
    };
    Ok(body
        .get("value")
        .and_then(Value::as_str)
        .unwrap_or(text)
        .to_owned())
}

/// Runs D: the launch, the point (hit N of its line, then the steps), the change, the end.
pub async fn drive(d: Drive) -> Result<Outcome, String> {
    let (tx, rx) = mpsc::unbounded_channel();
    let mut t = Tree {
        sessions: vec![],
        tx,
        rx,
        seq: 0,
        hits: vec![],
        bps: vec![],
    };
    let mut start = d.start.clone();
    start.breakpoints = breakpoints(
        &d.start.adapter_id,
        &d.probes,
        Some((&d.target.path, d.target.line)),
        &[],
    );
    // the adapter counts the passes where it can and no probe needs reading at each (fit drops the field where the
    // adapter cannot; the fork then counts)
    if d.target.hit > 1 && !d.probe_on_line() {
        let (field, text) = d.pass_condition();
        for s in start
            .breakpoints
            .iter_mut()
            .filter(|s| s.path == d.target.path)
        {
            for b in s.breakpoints.iter_mut() {
                if b.get("line") == Some(&json!(d.target.line)) && b.get("logMessage").is_none() {
                    b[field] = json!(text);
                }
            }
        }
    }
    t.bps = start.breakpoints.clone();
    let c = d.launcher.connect().await?;
    t.add(start, c);
    let r = reach_and_run(&d, &mut t).await;
    Drive::finish(&mut t).await;
    r
}

async fn reach_and_run(d: &Drive, t: &mut Tree) -> Result<Outcome, String> {
    // 1. hit N of the fork line, counted by the hub
    let mut count = 0u32;
    let (mut si, mut stop) = loop {
        match d.next(t).await? {
            Next::Hit(_) => {}
            Next::Ended(_) => {
                return Err(format!(
                    "the fork ended after {count} of {} hits of line {}",
                    d.target.hit, d.target.line
                ));
            }
            Next::Stopped(i, s) => {
                let (path, line) = top(&s);
                if path == d.target.path && line == d.target.line {
                    if d.adapter_counts(&t.sessions[i].caps) {
                        d.landed(t, &s)?;
                        break (i, s);
                    }
                    count += 1;
                    d.read_probe(t, i, &s, &path, line).await;
                    if count >= d.target.hit {
                        break (i, s);
                    }
                    if count >= HIT_CAP {
                        return Err(format!(
                            "line {} passed {HIT_CAP} times without hit {}",
                            d.target.line, d.target.hit
                        ));
                    }
                }
                // any other stop (an entry, an exception filter) runs on
                t.sessions[i]
                    .handle
                    .op(Op::Continue {
                        thread: Some(s.thread),
                    })
                    .await?;
            }
        }
    };
    // 2. the recorded steps again
    for step in &d.target.steps {
        let thread = Some(stop.thread);
        let op = match step.as_str() {
            "in" => Op::StepIn { thread },
            "out" => Op::StepOut { thread },
            _ => Op::Next { thread },
        };
        t.sessions[si].handle.op(op).await?;
        (si, stop) = loop {
            match d.next(t).await? {
                Next::Hit(_) => {}
                Next::Stopped(i, s) => break (i, s),
                Next::Ended(_) => return Err("the fork ended during the recorded steps".into()),
            }
        };
    }
    let at = top(&stop);
    let before = std::mem::take(&mut t.hits);
    // the stopping thread, named as the probes name it
    let frame = stop.frames.first().and_then(|f| f.get("id")).cloned();
    let thread = match thread_expr(&d.start.adapter_id) {
        "" => Some(String::new()),
        e => t.sessions[si]
            .handle
            .request(
                "evaluate",
                json!({"expression": e, "frameId": frame, "context": "watch"}),
            )
            .await
            .ok()
            .and_then(|b| b.get("result").and_then(Value::as_str).map(str::to_owned)),
    };
    // 3. the change
    let applied = match &d.change {
        Change::Value { path, text } => Some(
            apply(
                &t.sessions[si].handle,
                &t.sessions[si].caps,
                &stop,
                path,
                text,
            )
            .await?,
        ),
        Change::Nothing | Change::Code => None,
    };
    if d.until == Until::Here {
        let (path, line) = at.clone();
        return Ok(Outcome {
            before,
            after: vec![],
            thread,
            applied,
            end: End::Stop {
                path,
                line,
                reason: stop.reason.clone(),
                locals: locals(&stop),
            },
            at,
        });
    }
    // 4. on to the end: the fork line's breakpoint goes (the run's later lines come for a next stop)
    let later: &[(String, u32)] = if d.until == Until::NextStop {
        &d.later
    } else {
        &[]
    };
    let mut bps = breakpoints(&d.start.adapter_id, &d.probes, None, later);
    if !bps.iter().any(|s| s.path == d.target.path) {
        bps.push(SourceBps {
            path: d.target.path.clone(),
            breakpoints: vec![],
        });
    }
    d.set_bps(t, &bps).await;
    t.sessions[si]
        .handle
        .op(Op::Continue {
            thread: Some(stop.thread),
        })
        .await?;
    let end = loop {
        match d.next(t).await? {
            Next::Hit(h) => {
                if let Until::Probe(p) = &d.until
                    && h.probe == *p
                {
                    break End::Probe {
                        probe: h.probe,
                        value: h.value,
                    };
                }
            }
            Next::Ended(code) => break End::Exit { code },
            Next::Stopped(i, s) => {
                if d.until == Until::Exit || matches!(d.until, Until::Probe(_)) {
                    // an exception on the way out is where it ended
                    if s.reason == "exception" {
                        let (path, line) = top(&s);
                        break End::Stop {
                            path,
                            line,
                            reason: s.reason.clone(),
                            locals: locals(&s),
                        };
                    }
                    t.sessions[i]
                        .handle
                        .op(Op::Continue {
                            thread: Some(s.thread),
                        })
                        .await?;
                    continue;
                }
                let (path, line) = top(&s);
                break End::Stop {
                    path,
                    line,
                    reason: s.reason.clone(),
                    locals: locals(&s),
                };
            }
        }
    };
    Ok(Outcome {
        before,
        after: std::mem::take(&mut t.hits),
        thread,
        applied,
        at,
        end,
    })
}

/// The first scope's variables of STOP's selected frame.
fn locals(stop: &Stop) -> Vec<Value> {
    stop.scopes
        .iter()
        .find_map(|s| s.variables.clone())
        .unwrap_or_default()
}

/// What a plain run watches (D5's predicates), its path in the tree it runs in.
#[derive(Clone, Debug, PartialEq)]
pub enum Watch {
    /// An exception stopping at PATH:LINE.
    Exception { path: String, line: u32 },
    /// EXPR's value each time PATH:LINE runs.
    Probe {
        path: String,
        line: u32,
        expr: String,
    },
}

/// How a watched run ended.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RunEnd {
    /// The watched exception's place, when it stopped there (paths as the watch named them).
    pub exception_at: Option<(String, u32)>,
    /// The probe's values, in the order they came.
    pub probe_values: Vec<String>,
    /// The program's exit code, when it ended and the adapter said.
    pub exit: Option<i64>,
    /// The time box ran out first (the session was stopped).
    pub timed_out: bool,
}

/// A plain run: started with START through LAUNCHER, ADAPTER's language, WATCH watched, LIMIT the time box.
pub struct Watched {
    pub launcher: Arc<dyn Launcher>,
    pub start: Start,
    pub adapter: String,
    pub watch: Watch,
    pub limit: Duration,
}

/// The exception filter that stops at every raised exception, in ADAPTER's names.
fn raised_filter(adapter: &str) -> &'static str {
    match adapter {
        "js-debug" | "pwa-node" | "node" => "all",
        _ => "raised",
    }
}

/// W's run to the program's end (or the watched exception, or the time box), its sessions stopped after.
pub async fn watch(w: Watched) -> Result<RunEnd, String> {
    let (tx, rx) = mpsc::unbounded_channel();
    let mut t = Tree {
        sessions: vec![],
        tx,
        rx,
        seq: 0,
        hits: vec![],
        bps: vec![],
    };
    let probes = match &w.watch {
        Watch::Probe { path, line, expr } => vec![RunProbe {
            id: "watch".into(),
            path: path.clone(),
            line: *line,
            expr: expr.clone(),
        }],
        Watch::Exception { .. } => vec![],
    };
    let mut start = w.start.clone();
    start.breakpoints = breakpoints(&w.start.adapter_id, &probes, None, &[]);
    if matches!(w.watch, Watch::Exception { .. }) {
        start.exception_filters = Some(vec![raised_filter(&w.adapter).to_owned()]);
    }
    t.bps = start.breakpoints.clone();
    let c = w.launcher.connect().await?;
    t.add(start.clone(), c);
    let r = crate::clock::timeout(w.limit, watch_run(&w, &start, &mut t)).await;
    Drive::finish(&mut t).await;
    let values = |t: &Tree| t.hits.iter().map(|h| h.value.clone()).collect::<Vec<_>>();
    match r {
        Ok(Ok(mut end)) => {
            end.probe_values = values(&t);
            Ok(end)
        }
        Ok(Err(e)) => Err(e),
        Err(_) => Ok(RunEnd {
            probe_values: values(&t),
            timed_out: true,
            ..RunEnd::default()
        }),
    }
}

async fn watch_run(w: &Watched, start: &Start, t: &mut Tree) -> Result<RunEnd, String> {
    loop {
        match next_of(start, &w.launcher, t).await? {
            Next::Hit(_) => {}
            Next::Ended(exit) => {
                return Ok(RunEnd {
                    exit,
                    ..RunEnd::default()
                });
            }
            Next::Stopped(i, s) => {
                if let Watch::Exception { path, line } = &w.watch
                    && s.reason == "exception"
                    && top(&s) == (path.clone(), *line)
                {
                    return Ok(RunEnd {
                        exception_at: Some((path.clone(), *line)),
                        ..RunEnd::default()
                    });
                }
                // any other stop (another exception, an entry) runs on
                t.sessions[i]
                    .handle
                    .op(Op::Continue {
                        thread: Some(s.thread),
                    })
                    .await?;
            }
        }
    }
}
