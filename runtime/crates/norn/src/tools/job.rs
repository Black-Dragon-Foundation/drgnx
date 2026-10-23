//! Task 8's writing tools: messages, decisions, tasks (`drgnx-coord-mcp--job-tools`, `core/drgnx-coord-mcp.el`).
//!
//! Each write is `drgnx-coord-mcp--write`: the store's answer as the tool's text (a held write says so first, with
//! the changes), the agent's held count noted in the same transaction, then the hub told.  Answers that are plists
//! in the Lisp (`(:ok t …)`, `(:taken A)`, `(:error M)`) are JSON objects, keys in the Lisp's order; an empty list
//! is `null`.

use mimir::BoxFuture;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use urdr::graph::entity::{self, Origin};
use urdr::graph::link;

use super::guard::{CoordTool, guarded, text_cut};
use super::{Coord, Ctx, Identity};
use crate::read::decisions::{Decision, decisions_since};
use crate::read::tasks::tasks;
use crate::store::{CoordError, WTx};
use crate::write::decisions::{Decide, DecideResult, decide};
use crate::write::messages::{Send as SendMessage, SendResult, send};
use crate::write::meta::note_held;
use crate::write::tasks::{ClaimResult, claim, set_status};

/// This file's tools.
pub fn tools() -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    vec![
        guarded(SendMessageTool),
        guarded(RecordDecision),
        guarded(ClaimTask),
        guarded(UpdateTask),
        guarded(CompleteTask),
        guarded(Escalate),
    ]
}

/// A store error as the tool's error text.
pub(super) fn err(e: CoordError) -> String {
    e.to_string()
}

/// An answer as JSON text (`drgnx-mcp--json`).
pub(super) fn json_text<T: Serialize>(v: &T) -> String {
    serde_json::to_string(v).expect("an answer is JSON")
}

/// A decision as the Lisp's `drgnx-coord--decision-plist` gives it (keys in its order).
#[derive(Serialize)]
pub(super) struct DecisionOut {
    n: i64,
    kind: Option<String>,
    subject: Option<String>,
    task: Option<String>,
    paths: Option<String>,
    reason: Option<String>,
    author: Option<String>,
    status: Option<String>,
    job: Option<String>,
    replaces: Option<i64>,
    at: Option<f64>,
    ver: Option<i64>,
}

impl From<&Decision> for DecisionOut {
    fn from(d: &Decision) -> Self {
        DecisionOut {
            n: d.n,
            kind: d.kind.clone(),
            subject: d.subject.clone(),
            task: d.task.clone(),
            paths: d.paths.clone(),
            reason: d.reason.clone(),
            author: d.author.clone(),
            status: d.status.clone(),
            job: d.job.clone(),
            replaces: d.replaces,
            at: d.at,
            ver: d.ver,
        }
    }
}

/// A list of decisions as the Lisp's `--jsonable` writes it: an empty list is `null`.
pub(super) fn decisions_out(ds: &[Decision]) -> Option<Vec<DecisionOut>> {
    (!ds.is_empty()).then(|| ds.iter().map(DecisionOut::from).collect())
}

#[derive(Serialize)]
struct HeldBody {
    version: u64,
    changes: Option<Vec<DecisionOut>>,
}

/// The answer of a held write (`drgnx-coord-mcp--answer`): nothing was written; the changes since the version the
/// agent read.  An empty `changes` is `null`, as the Lisp's `--jsonable` has it (it cannot occur: every version bump
/// inserts a decision).
fn held_text(version: u64, changes: &[Decision]) -> String {
    format!(
        "HELD: the decision log moved on — read these changes, then retry with seen_version {version}.\n{}",
        json_text(&HeldBody {
            version,
            changes: decisions_out(changes),
        })
    )
}

// ---- send_message ----

#[derive(Deserialize, JsonSchema)]
struct SendArgs {
    /// The recipient
    to: String,
    /// The message
    text: String,
    /// The decision-log version you last read (read_decisions)
    seen_version: u64,
}

#[derive(Serialize)]
struct SendOk {
    ok: bool,
    id: i64,
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    cut: Option<usize>,
}

struct SendMessageTool;

impl CoordTool for SendMessageTool {
    type Args = SendArgs;
    const NAME: &'static str = "send_message";
    const DESCRIPTION: &'static str =
        "Send a message to another agent (or \"user\"); it is queued and never interrupts them";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: SendArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(send_message(coord, who, args))
    }
}

/// The identity a message to TO is stored under (`drgnx-coord-mcp--resolve-recipient`): "user", an agent of this
/// job's tasks, or the id of the hub session TO names (by id or name).  The hub is asked only when the cheap checks
/// fail.
async fn resolve_recipient(coord: &Coord, who: &Identity, to: &str) -> Result<String, String> {
    if to == "user" {
        return Ok(to.to_owned());
    }
    if let Some(job) = who.job() {
        let job = job.to_owned();
        let list = coord
            .db()
            .read(move |c| tasks(c, &job))
            .await
            .map_err(err)?;
        if list.iter().any(|t| t.row.agent.as_deref() == Some(to)) {
            return Ok(to.to_owned());
        }
    }
    let sessions = coord.hub().sessions().await;
    if let Some(list) = &sessions
        && let Some(s) = list
            .iter()
            .find(|s| s.id == to || s.name.as_deref() == Some(to))
    {
        return Ok(s.id.clone());
    }
    Err(format!(
        "No agent \"{to}\" (list_agents names them; \"user\" is the user){}",
        if sessions.is_some() {
            ""
        } else {
            " - no hub answered, so only the job's task agents are known"
        }
    ))
}

/// `send_message`: an outside agent's messages count as its reports (the same limit); the recipient is resolved;
/// the store holds the write when the log moved on.
async fn send_message(coord: &Coord, who: &Identity, args: SendArgs) -> Result<String, String> {
    if who.outside_kind().is_some()
        && let Some(held) = coord.held_report(who.me()?, who.job()).await
    {
        return Ok(held);
    }
    let (text, cut) = text_cut(Some(args.text.as_str()), "text")?;
    let to = resolve_recipient(coord, who, &args.to).await?;
    let me = who.me()?.to_owned();
    let message = SendMessage {
        job: who.job().map(str::to_owned),
        sender: Some(me.clone()),
        recipient: to,
        text,
        seen: Some(args.seen_version),
        answers: None,
        question: false,
    };
    send_text(coord, who, message, (cut > 0).then_some(cut)).await
}

/// The write of a message and its answer text; CUT is how many characters the text lost.
async fn send_text(
    coord: &Coord,
    who: &Identity,
    message: SendMessage,
    cut: Option<usize>,
) -> Result<String, String> {
    let (me, now) = (who.me()?.to_owned(), coord.now());
    let (sent, changes) = coord
        .db()
        .write(who.tx_meta("mcp:send_message"), move |tx| {
            let sent = send(tx, message, now)?;
            let (held, changes) = match &sent {
                SendResult::Held { version, seen } => {
                    (Some(*version), decisions_since(tx.sql(), *seen, None)?)
                }
                SendResult::Ok { .. } => (None, Vec::new()),
            };
            note_held(tx, &me, held)?;
            Ok((sent, changes))
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    Ok(match sent {
        SendResult::Ok { id, state } => json_text(&SendOk {
            ok: true,
            id,
            state,
            cut,
        }),
        SendResult::Held { version, .. } => held_text(version, &changes),
    })
}

// ---- record_decision ----

#[derive(Deserialize, JsonSchema)]
struct RecordDecisionArgs {
    /// build, wait, wont-build or replaces
    kind: String,
    /// What it is about
    subject: String,
    /// The task it concerns
    task: Option<String>,
    /// Files or paths it covers
    paths: Option<String>,
    /// Why
    reason: String,
    /// The decision it replaces
    replaces: Option<i64>,
    /// The decision-log version you last read (read_decisions)
    seen_version: u64,
    /// Entities it is about (ids): `about` links from the decision
    about: Option<Vec<String>>,
}

#[derive(Serialize)]
struct DecideOk {
    ok: bool,
    n: i64,
    status: String,
    version: u64,
}

struct RecordDecision;

impl CoordTool for RecordDecision {
    type Args = RecordDecisionArgs;
    const NAME: &'static str = "record_decision";
    const DESCRIPTION: &'static str = "Record a decision: build, wait, wont-build or replaces.  Inside your own task it is current; about anything else it is proposed (the reviewer and the user decide)";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: RecordDecisionArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(record_decision(coord, who, args))
    }
}

/// `record_decision`: an agent's decision is current inside its own claimed task, else proposed.
async fn record_decision(
    coord: &Coord,
    who: &Identity,
    args: RecordDecisionArgs,
) -> Result<String, String> {
    who.not_outside("record_decision")?;
    let me = who.me()?.to_owned();
    let d = Decide {
        kind: args.kind,
        subject: args.subject,
        task: args.task,
        paths: args.paths,
        reason: Some(args.reason),
        author: me.clone(),
        seen: Some(args.seen_version),
        replaces: args.replaces,
        job: who.job().map(str::to_owned),
    };
    let now = coord.now();
    let about = args.about.unwrap_or_default();
    // with `about`, the decision belongs to the caller's project and each target must be in its scope
    let caller = if about.is_empty() {
        None
    } else {
        Some(super::tracker::caller_of(coord, who, true).await?)
    };
    let meta = match &caller {
        Some(c) => c.tx_meta("mcp:record_decision"),
        None => who.tx_meta("mcp:record_decision"),
    };
    let result = coord
        .db()
        .write(meta, move |tx| {
            let r = decide(tx, d, now)?;
            let held = match &r {
                DecideResult::Held(h) => Some(h.version),
                _ => None,
            };
            note_held(tx, &me, held)?;
            if let (DecideResult::Ok { n, .. }, Some(caller)) = (&r, &caller) {
                let from = entity::by_id(tx.sql(), &format!("decision:{n}"))?;
                for id in &about {
                    let (target, _) = crate::tracker::visible(tx, caller, id, "entity")?;
                    if let Some(from) = &from {
                        link::add(tx, from.n, "about", target.n, None, Origin::Recorded, None)?;
                    }
                }
            }
            Ok(r)
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    Ok(match result {
        DecideResult::Ok { n, status, version } => json_text(&DecideOk {
            ok: true,
            n,
            status,
            version,
        }),
        DecideResult::Held(h) => held_text(h.version, &h.changes),
        DecideResult::Error(m) => json!({"error": m}).to_string(),
    })
}

// ---- claim_task, update_task, complete_task ----

/// A claim's or status change's answer (`drgnx-coord-claim`, `drgnx-coord-set-status`).
fn claim_text(r: &ClaimResult) -> String {
    match r {
        ClaimResult::Ok => json!({"ok": true}).to_string(),
        ClaimResult::Held(h) => held_text(h.version, &h.changes),
        ClaimResult::Taken(a) => json!({"taken": a}).to_string(),
        ClaimResult::NotReady(deps) => {
            let deps = if deps.is_empty() {
                Value::Null
            } else {
                json!(deps)
            };
            json!({"not-ready": deps}).to_string()
        }
        ClaimResult::Error(m) => json!({"error": m}).to_string(),
    }
}

/// A task write by ME: F's answer, the held count noted, the hub told.
async fn task_write(
    coord: &Coord,
    who: &Identity,
    tool: &str,
    f: impl FnOnce(&mut WTx<'_>, f64) -> Result<ClaimResult, CoordError> + Send + 'static,
) -> Result<String, String> {
    let (me, now) = (who.me()?.to_owned(), coord.now());
    let result = coord
        .db()
        .write(who.tx_meta(tool), move |tx| {
            let r = f(tx, now)?;
            let held = match &r {
                ClaimResult::Held(h) => Some(h.version),
                _ => None,
            };
            note_held(tx, &me, held)?;
            Ok(r)
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    Ok(claim_text(&result))
}

#[derive(Deserialize, JsonSchema)]
struct ClaimArgs {
    /// The task's id
    task: String,
    /// The decision-log version you last read (read_decisions)
    seen_version: u64,
}

struct ClaimTask;

impl CoordTool for ClaimTask {
    type Args = ClaimArgs;
    const NAME: &'static str = "claim_task";
    const DESCRIPTION: &'static str = "Claim a ready task (a lease, kept while you work on it)";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ClaimArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(claim_task(coord, who, args))
    }
}

async fn claim_task(coord: &Coord, who: &Identity, args: ClaimArgs) -> Result<String, String> {
    who.not_outside("claim_task")?;
    let me = who.me()?.to_owned();
    let (task, seen, agent) = (args.task, args.seen_version, me.clone());
    task_write(coord, who, "mcp:claim_task", move |tx, now| {
        claim(tx, &task, &agent, Some(seen), now)
    })
    .await
}

#[derive(Deserialize, JsonSchema)]
struct UpdateArgs {
    /// The task's id
    task: String,
    /// The new status
    status: String,
    /// The decision-log version you last read (read_decisions)
    seen_version: u64,
}

struct UpdateTask;

impl CoordTool for UpdateTask {
    type Args = UpdateArgs;
    const NAME: &'static str = "update_task";
    const DESCRIPTION: &'static str = "Set your task's status: running, needs-input, in-review or failed (in a job: running, needs-input or in-review)";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: UpdateArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(update_task(coord, who, args))
    }
}

/// `update_task`: in a job a task is done when its review passed and it is merged, never by its agent's word;
/// outside one an agent may also fail it, and `complete_task` finishes it.
async fn update_task(coord: &Coord, who: &Identity, args: UpdateArgs) -> Result<String, String> {
    who.not_outside("update_task")?;
    let job = who.job().is_some();
    let allowed = matches!(
        args.status.as_str(),
        "running" | "needs-input" | "in-review"
    ) || (!job && args.status == "failed");
    if !allowed {
        let says = if job {
            "In a job, a task's status is running, needs-input or in-review (complete_task); review and merge make it done"
        } else {
            "A task's status is running, needs-input, in-review or failed (complete_task finishes it)"
        };
        return Err(says.into());
    }
    set_task_status(coord, who, args.task, args.status, args.seen_version).await
}

async fn set_task_status(
    coord: &Coord,
    who: &Identity,
    task: String,
    status: String,
    seen: u64,
) -> Result<String, String> {
    let me = who.me()?.to_owned();
    let agent = me.clone();
    task_write(coord, who, "mcp:update_task", move |tx, now| {
        set_status(tx, &task, &agent, &status, Some(seen), now)
    })
    .await
}

struct CompleteTask;

impl CoordTool for CompleteTask {
    type Args = ClaimArgs;
    const NAME: &'static str = "complete_task";
    const DESCRIPTION: &'static str =
        "Your task is done (in a job: it goes to review, then is merged)";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ClaimArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            who.not_outside("complete_task")?;
            let status = if who.job().is_some() {
                "in-review"
            } else {
                "done"
            };
            set_task_status(coord, who, args.task, status.into(), args.seen_version).await
        })
    }
}

// ---- escalate ----

#[derive(Deserialize, JsonSchema)]
struct EscalateArgs {
    /// What it is about
    subject: String,
    /// What needs deciding
    text: String,
    /// The decision-log version you last read (read_decisions)
    seen_version: u64,
}

struct Escalate;

impl CoordTool for Escalate {
    type Args = EscalateArgs;
    const NAME: &'static str = "escalate";
    const DESCRIPTION: &'static str = "Ask the user to decide something (a clash, a question): queued for them (the job window shows it); go on with what does not depend on it";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: EscalateArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(escalate(coord, who, args))
    }
}

/// `escalate`: a question to the user (its text starts `[escalation]`, which makes the store's event a question).
async fn escalate(coord: &Coord, who: &Identity, args: EscalateArgs) -> Result<String, String> {
    if who.outside_kind().is_some() {
        return Err("escalate is for drgnx's own job agents: ask the user with ask_user".into());
    }
    let me = who.me()?.to_owned();
    let (subject, _) = text_cut(Some(args.subject.as_str()), "subject")?;
    let (text, _) = text_cut(Some(args.text.as_str()), "text")?;
    let message = SendMessage {
        job: who.job().map(str::to_owned),
        sender: Some(me.clone()),
        recipient: "user".into(),
        text: format!("[escalation] {subject}: {text}"),
        seen: Some(args.seen_version),
        answers: None,
        question: false,
    };
    send_text(coord, who, message, None).await
}
