//! The user's doors to the work the hub holds (`card`, `message`, `task`, `plan`): what the editor did and an outside
//! agent may never do, from a terminal.  A user client of the running hub, `ensure`d first: each subcommand is one
//! hub method or two (`cards/settle`; `messages/send`; `graph/entity` then `tasks/write`; `plans/get` then
//! `plans/write`), so the checks, the validation and the refusals are the hub's, never this process's.
//!
//! - `card list [--open]` reads the cards (`graph/sql`), `card settle CARD CHOICE` answers one (`cards/settle`).
//! - `message send TO TEXT` and `message reply ID TEXT` write as the user (`messages/send`).
//! - `task list`, `task ready` and `task show ID` read the tracker (`tasks/find`, `tasks/ready`, `graph/entity`).
//! - `task status ID STATUS` sets a tracker task's status (`tasks/write update`, at the version just read).
//! - `plan status PLAN TASK STATUS` sets a plan task's status (`plans/write`), the one way into a task of an imported
//!   plan file; `done` ticks the task's steps too, so the file and the graph agree.
//! - `records status [PATH]` lists the record view files and their conflicts, `records conflict ID` shows a conflicted
//!   record's file text and graph version, `records resolve ID --keep file|graph` keeps one (`records/status|conflict|resolve`).
//!
//! A status is any word of the tracker's status set: this side checks only its shape, and the hub names the set when it
//! refuses one, so a new status needs no change here.
//!
//! Output is text, or the last answer as one JSON line with `--json`.  Exit 0 when the command did what was asked,
//! 1 when it did not (an error, a card that was not open, a conflict), 2 for arguments that do not parse.

use std::ffi::OsString;
use std::time::Duration;

use runstav::paths::Env;
use serde_json::{Value, json};

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;

const CALL: Duration = Duration::from_secs(30);

pub const USAGE: &str = "usage: ratatoskr card list [--open] [--json]\n\
    \x20      ratatoskr card settle CARD CHOICE [--json]\n\
    \x20      ratatoskr message send TO TEXT [--json]\n\
    \x20      ratatoskr message reply ID TEXT [--json]\n\
    \x20      ratatoskr task list [--query WORDS] [--status S] [--assignee A] [--label L]... [--project P] [--cursor N] [--json]\n\
    \x20      ratatoskr task ready [--label L]... [--project P] [--limit N] [--json]\n\
    \x20      ratatoskr task show ID [--history] [--json]\n\
    \x20      ratatoskr task status ID STATUS [--reason TEXT] [--json]\n\
    \x20      ratatoskr plan status PLAN TASK STATUS [--reason TEXT] [--json]\n\
    \x20      ratatoskr records status [PATH] [--json]\n\
    \x20      ratatoskr records conflict ID [--json]\n\
    \x20      ratatoskr records resolve ID --keep file|graph [--json]";

#[derive(Debug, PartialEq, Eq)]
pub struct DoorCommand {
    pub sub: Sub,
    pub json: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Sub {
    CardList {
        open: bool,
    },
    CardSettle {
        card: u64,
        choice: String,
    },
    MessageSend {
        to: String,
        text: String,
    },
    MessageReply {
        id: u64,
        text: String,
    },
    /// Tracker tasks by words, status, assignee, labels and project (`tasks/find`), a page.
    TaskList {
        query: Option<String>,
        status: Option<String>,
        assignee: Option<String>,
        labels: Vec<String>,
        project: Option<String>,
        cursor: Option<u64>,
    },
    /// The ready tracker tasks (`tasks/ready`).
    TaskReady {
        labels: Vec<String>,
        project: Option<String>,
        limit: Option<u64>,
    },
    /// One entity with its links and notes (`graph/entity`).
    TaskShow {
        id: String,
        history: bool,
    },
    TaskStatus {
        id: String,
        status: String,
        reason: Option<String>,
    },
    PlanStatus {
        plan: String,
        task: String,
        status: String,
        reason: Option<String>,
    },
    /// The record files and where they stand (`records/status`).
    RecordsStatus {
        path: Option<String>,
    },
    /// A conflicted record, both versions (`records/conflict`).
    RecordsConflict {
        id: String,
    },
    /// The file's or the graph's version stays (`records/resolve`).
    RecordsResolve {
        id: String,
        keep: String,
    },
}

/// A status word, as the registry's `Status` type takes it (lowercase letters and `-`, a letter first, at most 32).
fn status_word(s: &str) -> villa::Result<String> {
    let ok = s.len() <= 32
        && s.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && s.chars().all(|c| c.is_ascii_lowercase() || c == '-');
    if ok {
        Ok(s.to_owned())
    } else {
        Err(villa::Error::invalid(format!(
            "a status is lowercase letters and -, a letter first, not {s:?}"
        )))
    }
}

/// The flags of `task list|ready` that take a value.
const TASK_OPTS: [&str; 7] = [
    "query", "status", "assignee", "label", "project", "cursor", "limit",
];

/// The value of the flag NAME given once (the last wins), taken out of OPTS.
fn take_opt(opts: &mut Vec<(String, String)>, name: &str) -> Option<String> {
    let all = take_all(opts, name);
    all.into_iter().next_back()
}

/// Every value of the flag NAME, in order, taken out of OPTS.
fn take_all(opts: &mut Vec<(String, String)>, name: &str) -> Vec<String> {
    let (mine, rest): (Vec<_>, Vec<_>) = opts.drain(..).partition(|(n, _)| n == name);
    *opts = rest;
    mine.into_iter().map(|(_, v)| v).collect()
}

fn whole(v: &str, what: &str) -> villa::Result<u64> {
    v.parse::<u64>()
        .map_err(|_| villa::Error::invalid(format!("{what} takes a whole number, not {v:?}")))
}

/// The arguments after GROUP (`card`, `message`, `task`, `plan` or `records`).
pub fn parse(group: &str, args: impl IntoIterator<Item = OsString>) -> villa::Result<DoorCommand> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| villa::Error::invalid(e.to_string());
    let (mut json, mut open) = (false, false);
    let mut words: Vec<String> = Vec::new();
    let mut reason: Option<String> = None;
    let mut keep: Option<String> = None;
    let mut opts: Vec<(String, String)> = Vec::new();
    let mut history = false;
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("json") => json = true,
            Long(name) if group == "task" && TASK_OPTS.contains(&name) => {
                opts.push((name.to_owned(), p.value().map_err(e)?.string().map_err(e)?))
            }
            Long("history") if group == "task" => history = true,
            Long("open") if group == "card" => open = true,
            Long("reason") if group == "plan" || group == "task" => {
                reason = Some(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("keep") if group == "records" => {
                keep = Some(p.value().map_err(e)?.string().map_err(e)?)
            }
            Word(v) => words.push(v.string().map_err(e)?),
            other => return Err(villa::Error::invalid(other.unexpected().to_string())),
        }
    }
    let w: Vec<&str> = words.iter().map(String::as_str).collect();
    let id_num = |v: &str, what: &str| {
        v.parse::<u64>()
            .map_err(|_| villa::Error::invalid(format!("{what} takes a whole number, not {v:?}")))
    };
    let sub = match (group, w.as_slice()) {
        ("card", ["list"]) => Sub::CardList { open },
        ("card", ["settle", card, choice]) => Sub::CardSettle {
            card: id_num(card, "a card")?,
            choice: (*choice).into(),
        },
        ("message", ["send", to, text]) => Sub::MessageSend {
            to: (*to).into(),
            text: (*text).into(),
        },
        ("message", ["reply", id, text]) => Sub::MessageReply {
            id: id_num(id, "a message")?,
            text: (*text).into(),
        },
        ("task", ["list"]) => Sub::TaskList {
            query: take_opt(&mut opts, "query"),
            status: take_opt(&mut opts, "status")
                .map(|s| status_word(&s))
                .transpose()?,
            assignee: take_opt(&mut opts, "assignee"),
            labels: take_all(&mut opts, "label"),
            project: take_opt(&mut opts, "project"),
            cursor: take_opt(&mut opts, "cursor")
                .map(|c| whole(&c, "--cursor"))
                .transpose()?,
        },
        ("task", ["ready"]) => Sub::TaskReady {
            labels: take_all(&mut opts, "label"),
            project: take_opt(&mut opts, "project"),
            limit: take_opt(&mut opts, "limit")
                .map(|l| whole(&l, "--limit"))
                .transpose()?,
        },
        ("task", ["show", id]) => Sub::TaskShow {
            id: (*id).into(),
            history: std::mem::take(&mut history),
        },
        ("task", ["status", id, status]) => Sub::TaskStatus {
            id: (*id).into(),
            status: status_word(status)?,
            reason: reason.take(),
        },
        ("plan", ["status", plan, task, status]) => Sub::PlanStatus {
            plan: (*plan).into(),
            task: (*task).into(),
            status: status_word(status)?,
            reason: reason.take(),
        },
        ("records", ["status"]) => Sub::RecordsStatus { path: None },
        ("records", ["status", path]) => Sub::RecordsStatus {
            path: Some((*path).into()),
        },
        ("records", ["conflict", id]) => Sub::RecordsConflict { id: (*id).into() },
        ("records", ["resolve", id]) => match keep.take().as_deref() {
            Some(k @ ("file" | "graph")) => Sub::RecordsResolve {
                id: (*id).into(),
                keep: k.into(),
            },
            _ => {
                return Err(villa::Error::invalid(
                    "records resolve needs --keep file|graph",
                ));
            }
        },
        _ => {
            return Err(villa::Error::invalid(format!(
                "{group}: not a command of this kind\n{USAGE}"
            )));
        }
    };
    if keep.is_some() {
        return Err(villa::Error::invalid("--keep goes with records resolve"));
    }
    if let Some((name, _)) = opts.first() {
        return Err(villa::Error::invalid(format!(
            "--{name} does not go with this command"
        )));
    }
    if history {
        return Err(villa::Error::invalid("--history goes with task show"));
    }
    if open && !matches!(sub, Sub::CardList { .. }) {
        return Err(villa::Error::invalid("--open goes with card list"));
    }
    Ok(DoorCommand { sub, json })
}

/// How a command reaches the hub: one method call, its answer or the hub's error.
pub type Hub<'a> = dyn FnMut(&str, Value) -> villa::Result<Value> + 'a;

const CARDS: &str = "select id, kind, state, title, job, task from card";

/// The method and params of a read-only `graph/sql` over the hub's store.
fn sql(text: &str, params: Value) -> (&'static str, Value) {
    ("graph/sql", json!({"sql": text, "params": params}))
}

/// Runs the command through HUB: its text, its last answer, and whether it did what was asked.
pub fn execute(sub: &Sub, hub: &mut Hub<'_>) -> villa::Result<(String, Value, bool)> {
    match sub {
        Sub::CardList { open } => {
            let text = format!(
                "{CARDS}{} order by id desc",
                if *open { " where state = 'open'" } else { "" }
            );
            let (m, p) = sql(&text, json!([]));
            let a = hub(m, p)?;
            let mut out = String::new();
            for r in a["rows"].as_array().into_iter().flatten() {
                let cell = |i: usize| match &r[i] {
                    Value::Null => String::new(),
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                out.push_str(&format!(
                    "{}  {}  {}  {}\n",
                    cell(0),
                    cell(2),
                    cell(1),
                    cell(3)
                ));
            }
            if out.is_empty() {
                out.push_str("no cards\n");
            }
            Ok((out, a, true))
        }
        Sub::CardSettle { card, choice } => {
            let a = hub("cards/settle", json!({"card": card, "choice": choice}))?;
            let ok = a["settled"] == true;
            let t = if ok {
                format!("card {card}: settled with {choice}\n")
            } else {
                format!("card {card}: not open (nothing happens twice)\n")
            };
            Ok((t, a, ok))
        }
        Sub::MessageSend { to, text } => {
            let a = hub("messages/send", json!({"recipient": to, "text": text}))?;
            Ok(sent(&a))
        }
        Sub::MessageReply { id, text } => {
            let (m, p) = sql("select sender, job from message where id = ?1", json!([id]));
            let row = hub(m, p)?;
            let Some(r) = row["rows"].get(0) else {
                return Err(villa::Error::not_found(format!("no message {id}")));
            };
            let Some(to) = r[0].as_str() else {
                return Err(villa::Error::invalid(format!(
                    "message {id} has no sender to answer"
                )));
            };
            let mut p = json!({"recipient": to, "text": text, "answers": id});
            if let Some(j) = r[1].as_str() {
                p["job"] = json!(j);
            }
            let a = hub("messages/send", p)?;
            Ok(sent(&a))
        }
        Sub::TaskList {
            query,
            status,
            assignee,
            labels,
            project,
            cursor,
        } => {
            let mut p = json!({});
            for (k, v) in [
                ("query", query),
                ("status", status),
                ("assignee", assignee),
                ("project", project),
            ] {
                if let Some(v) = v {
                    p[k] = json!(v);
                }
            }
            if !labels.is_empty() {
                p["labels"] = json!(labels);
            }
            if let Some(c) = cursor {
                p["cursor"] = json!(c);
            }
            let a = hub("tasks/find", p)?;
            Ok((task_rows(&a), a, true))
        }
        Sub::TaskReady {
            labels,
            project,
            limit,
        } => {
            let mut p = json!({});
            if !labels.is_empty() {
                p["labels"] = json!(labels);
            }
            if let Some(v) = project {
                p["project"] = json!(v);
            }
            if let Some(l) = limit {
                p["limit"] = json!(l);
            }
            let a = hub("tasks/ready", p)?;
            Ok((task_rows(&a), a, true))
        }
        Sub::TaskShow { id, history } => {
            let mut include = vec!["links", "notes"];
            if *history {
                include.push("history");
            }
            let a = hub("graph/entity", json!({"id": id, "include": include}))?;
            Ok((entity_text(id, &a), a, true))
        }
        Sub::TaskStatus { id, status, reason } => {
            let e = hub("graph/entity", json!({"id": id}))?;
            let Some(ver) = e["entity"]["ver"].as_i64() else {
                return Err(villa::Error::not_found(format!("no task {id}")));
            };
            let a = hub(
                "tasks/write",
                json!({"op": "update", "id": id, "ver": ver, "status": status}),
            )?;
            let done = task_answer(id, status, a);
            // the reason is a note on the task, written after the status took
            match reason {
                Some(r) if done.2 => {
                    hub("tasks/write", json!({"op": "note", "id": id, "note": r}))?;
                    Ok(done)
                }
                _ => Ok(done),
            }
        }
        Sub::PlanStatus {
            plan,
            task,
            status,
            reason,
        } => {
            let view = hub("plans/get", json!({"plan": plan}))?;
            let Some(t) = view["tasks"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|t| t["number"] == json!(task))
            else {
                return Err(villa::Error::not_found(format!(
                    "{plan} has no task {task}"
                )));
            };
            let mut w = json!({"number": task, "status": status});
            if let Some(r) = reason {
                w["reason"] = json!(r);
            }
            // a task whose steps are all ticked is done in the file: done ticks them, so the two agree
            if status == "done" && t["steps"].as_array().is_some_and(|s| !s.is_empty()) {
                w["steps"] = Value::Array(
                    t["steps"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|s| json!({"done": true, "text": s["text"]}))
                        .collect(),
                );
            }
            let a = hub(
                "plans/write",
                json!({"plan": plan, "base_version": view["version"], "tasks": [w]}),
            )?;
            Ok((format!("{plan} task {task}: {status}\n"), a, true))
        }
        Sub::RecordsStatus { path } => {
            let a = hub(
                "records/status",
                path.as_ref()
                    .map_or_else(|| json!({}), |p| json!({"path": p})),
            )?;
            let mut out = String::new();
            let mut ok = true;
            for v in a["views"].as_array().into_iter().flatten() {
                let conflicts: Vec<&str> = v["conflicts"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .collect();
                ok &= conflicts.is_empty();
                out.push_str(&format!(
                    "{}  {}{}{}\n",
                    v["path"].as_str().unwrap_or("?"),
                    v["entity"].as_str().unwrap_or("?"),
                    if v["changed"] == true {
                        "  changed"
                    } else {
                        ""
                    },
                    if conflicts.is_empty() {
                        String::new()
                    } else {
                        format!("  conflicts: {}", conflicts.join(", "))
                    }
                ));
            }
            if out.is_empty() {
                out.push_str("no record views\n");
            }
            Ok((out, a, ok))
        }
        Sub::RecordsConflict { id } => {
            let a = hub("records/conflict", json!({"id": id}))?;
            let t = format!(
                "{} ({})\n--- file\n{}\n--- graph\n{}\n",
                a["id"].as_str().unwrap_or(id),
                a["path"].as_str().unwrap_or("?"),
                a["file"].as_str().unwrap_or(""),
                a["graph"].as_str().unwrap_or("")
            );
            Ok((t, a, true))
        }
        Sub::RecordsResolve { id, keep } => {
            let a = hub("records/resolve", json!({"id": id, "keep": keep}))?;
            let t = format!(
                "{}: kept the {keep} version ({})\n",
                a["id"].as_str().unwrap_or(id),
                a["path"].as_str().unwrap_or("?")
            );
            Ok((t, a, true))
        }
    }
}

fn sent(a: &Value) -> (String, Value, bool) {
    if a["held"] == true {
        let t = "held: the decision log moved on; read what changed and send again\n".to_owned();
        (t, a.clone(), false)
    } else {
        let t = format!(
            "message {} {}\n",
            a["id"],
            a["state"].as_str().unwrap_or("sent")
        );
        (t, a.clone(), true)
    }
}

/// A page of tasks as lines `ID  STATUS  TITLE  @ASSIGNEE`, and where the next page starts.
fn task_rows(a: &Value) -> String {
    let mut out = String::new();
    for t in a["tasks"].as_array().into_iter().flatten() {
        let word = |k: &str| t[k].as_str().unwrap_or("");
        out.push_str(&format!(
            "{}  {}  {}",
            word("id"),
            word("status"),
            word("title")
        ));
        if let Some(who) = t["assignee"].as_str() {
            out.push_str(&format!("  @{who}"));
        }
        out.push('\n');
    }
    if out.is_empty() {
        out.push_str("no tasks\n");
    }
    if let Some(c) = a["cursor"].as_u64() {
        out.push_str(&format!("more: --cursor {c}\n"));
    }
    out
}

/// One entity as text: its header, body, links, notes and history, each of the last three one JSON line an item.
fn entity_text(id: &str, a: &Value) -> String {
    let e = &a["entity"];
    let word = |k: &str| e[k].as_str().unwrap_or("");
    let mut out = format!(
        "{}  {}  {}  {}\n",
        e["id"].as_str().unwrap_or(id),
        word("kind"),
        word("status"),
        word("title")
    );
    out.push_str(&format!(
        "project {}  ver {}\n",
        word("project"),
        e["ver"].as_i64().unwrap_or(0)
    ));
    if let Some(b) = e["body"].as_str().filter(|b| !b.is_empty()) {
        out.push_str(&format!("{b}\n"));
    }
    for name in ["links", "notes", "history"] {
        if let Some(items) = a[name].as_array().filter(|i| !i.is_empty()) {
            out.push_str(&format!("{name}:\n"));
            for i in items {
                out.push_str(&format!("  {i}\n"));
            }
        }
    }
    out
}

fn task_answer(id: &str, status: &str, a: Value) -> (String, Value, bool) {
    if a.get("conflict").is_some() {
        let t = format!("{id}: changed since it was read; run the command again\n");
        return (t, a, false);
    }
    if let Some(c) = a["proposed"]["card"].as_u64() {
        let t =
            format!("{id}: a close card ({c}) was raised instead; settle it with `card settle`\n");
        return (t, a, false);
    }
    (format!("{id}: {status}\n"), a, true)
}

/// `card|message|task|plan|records …`: the exit code.
pub fn run(env: &Env, cmd: DoorCommand) -> i32 {
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    let mut client = match Client::user(env, Duration::from_secs(5)) {
        Ok(c) => c,
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr: {e}"));
            return 1;
        }
    };
    let mut call = |m: &str, p: Value| client.call(m, p, CALL);
    match execute(&cmd.sub, &mut call) {
        Ok((text, answer, ok)) => {
            if cmd.json {
                crate::soft::out_line(&answer.to_string());
            } else {
                crate::soft::out_text(&text);
            }
            i32::from(!ok)
        }
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr: {e}"));
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(group: &str, args: &[&str]) -> villa::Result<DoorCommand> {
        parse(group, args.iter().map(OsString::from))
    }

    type Calls = Vec<(String, Value)>;
    type Done = villa::Result<(String, Value, bool)>;

    /// SUB run against a hub that records the calls and answers from ANSWERS in order (an `Err` text is the hub's
    /// refusal, as the client hands it over).
    fn run_fake(sub: &Sub, mut answers: Vec<Result<Value, String>>) -> (Done, Calls) {
        let mut seen = Calls::new();
        answers.reverse();
        let r = {
            let mut hub = |m: &str, p: Value| {
                seen.push((m.to_owned(), p));
                answers
                    .pop()
                    .expect("one answer per call")
                    .map_err(villa::Error::refused)
            };
            execute(sub, &mut hub)
        };
        (r, seen)
    }

    #[test]
    fn card_and_message_commands_call_the_hubs_methods() {
        let c = p("card", &["settle", "7", "yes"]).unwrap();
        let (r, seen) = run_fake(&c.sub, vec![Ok(json!({"settled": true}))]);
        assert_eq!(
            seen,
            [("cards/settle".into(), json!({"card": 7, "choice": "yes"}))]
        );
        assert!(r.unwrap().2);
        // a card that was not open exits non-zero
        let (r, _) = run_fake(&c.sub, vec![Ok(json!({"settled": false}))]);
        assert!(!r.unwrap().2);
        // the method's own refusal is the command's error, whole
        let (r, _) = run_fake(&c.sub, vec![Err("invalid-params: unknown choice".into())]);
        assert_eq!(r.unwrap_err().to_string(), "invalid-params: unknown choice");
        let l = p("card", &["list", "--open", "--json"]).unwrap();
        assert!(l.json);
        let (r, seen) = run_fake(
            &l.sub,
            vec![Ok(
                json!({"rows": [[3, "ask", "open", "which?", null, null]]}),
            )],
        );
        assert_eq!(seen[0].0, "graph/sql");
        assert!(
            seen[0].1["sql"]
                .as_str()
                .unwrap()
                .contains("state = 'open'")
        );
        assert_eq!(r.unwrap().0, "3  open  ask  which?\n");
        let (r, _) = run_fake(
            &Sub::CardList { open: false },
            vec![Ok(json!({"rows": []}))],
        );
        assert_eq!(r.unwrap().0, "no cards\n");
        let m = p("message", &["send", "agent:s-1", "go on"]).unwrap();
        let (r, seen) = run_fake(
            &m.sub,
            vec![Ok(json!({"ok": true, "id": 4, "state": "queued"}))],
        );
        assert_eq!(
            seen,
            [(
                "messages/send".into(),
                json!({"recipient": "agent:s-1", "text": "go on"})
            )]
        );
        assert!(r.unwrap().2);
        let (r, _) = run_fake(&m.sub, vec![Ok(json!({"held": true, "version": 3}))]);
        assert!(!r.unwrap().2);
        // a reply goes to the question's sender, naming the question
        let rp = p("message", &["reply", "9", "yes"]).unwrap();
        let (r, seen) = run_fake(
            &rp.sub,
            vec![
                Ok(json!({"rows": [["agent:s-2", "job-1"]]})),
                Ok(json!({"ok": true, "id": 10, "state": "queued"})),
            ],
        );
        assert!(r.unwrap().2);
        assert_eq!(
            seen[1],
            (
                "messages/send".into(),
                json!({"recipient": "agent:s-2", "text": "yes", "answers": 9, "job": "job-1"})
            )
        );
        let (r, _) = run_fake(&rp.sub, vec![Ok(json!({"rows": []}))]);
        assert_eq!(r.unwrap_err().to_string(), "no message 9");
    }

    #[test]
    fn records_commands_call_the_hubs_methods() {
        let st = p("records", &["status"]).unwrap();
        let (r, seen) = run_fake(
            &st.sub,
            vec![Ok(json!({"views": [
                {"path": "/w/a.md", "entity": "plan:a-1", "changed": true, "conflicts": []},
                {"path": "/w/b.md", "entity": "spec:b-1", "changed": false, "conflicts": ["spec:b-1"]}]}))],
        );
        assert_eq!(seen, [("records/status".into(), json!({}))]);
        let (t, _, ok) = r.unwrap();
        // a conflicted view is not a clean status
        assert!(
            !ok && t.contains("/w/a.md  plan:a-1  changed") && t.contains("conflicts: spec:b-1"),
            "{t}"
        );
        let one = p("records", &["status", "/w/a.md"]).unwrap();
        let (r, seen) = run_fake(&one.sub, vec![Ok(json!({"views": []}))]);
        assert_eq!(
            seen,
            [("records/status".into(), json!({"path": "/w/a.md"}))]
        );
        assert_eq!(r.unwrap().0, "no record views\n");
        let c = p("records", &["conflict", "spec:b-1"]).unwrap();
        let (r, seen) = run_fake(
            &c.sub,
            vec![Ok(
                json!({"id": "spec:b-1", "path": "/w/b.md", "file": "F", "graph": "G", "at": 1.0}),
            )],
        );
        assert_eq!(
            seen,
            [("records/conflict".into(), json!({"id": "spec:b-1"}))]
        );
        let t = r.unwrap().0;
        assert!(t.contains("--- file\nF\n--- graph\nG"), "{t}");
        for keep in ["file", "graph"] {
            let r = p(
                "records",
                &["resolve", "spec:b-1", "--keep", keep, "--json"],
            )
            .unwrap();
            assert!(r.json);
            let (res, seen) = run_fake(
                &r.sub,
                vec![Ok(
                    json!({"id": "spec:b-1", "keep": keep, "path": "/w/b.md"}),
                )],
            );
            assert_eq!(
                seen,
                [(
                    "records/resolve".into(),
                    json!({"id": "spec:b-1", "keep": keep})
                )]
            );
            assert!(res.unwrap().2);
        }
        let (r, _) = run_fake(
            &Sub::RecordsResolve {
                id: "x".into(),
                keep: "file".into(),
            },
            vec![Err("not-allowed: no such conflict".into())],
        );
        assert_eq!(r.unwrap_err().to_string(), "not-allowed: no such conflict");
        for bad in [
            &["resolve", "spec:b-1"][..],
            &["resolve", "spec:b-1", "--keep", "both"],
            &["conflict"],
            &["status", "a", "b"],
        ] {
            assert!(p("records", bad).is_err(), "{bad:?} should not parse");
        }
        assert!(p("task", &["status", "task:a", "done", "--keep", "file"]).is_err());
    }

    #[test]
    fn task_and_plan_status_go_through_the_hubs_writes() {
        let t = p("task", &["status", "task:aa-00001", "dropped"]).unwrap();
        let (r, seen) = run_fake(
            &t.sub,
            vec![
                Ok(json!({"entity": {"ver": 5}})),
                Ok(json!({"id": "task:aa-00001", "title": "x", "ver": 6})),
            ],
        );
        assert!(r.unwrap().2);
        assert_eq!(
            seen[0],
            ("graph/entity".into(), json!({"id": "task:aa-00001"}))
        );
        assert_eq!(
            seen[1],
            (
                "tasks/write".into(),
                json!({"op": "update", "id": "task:aa-00001", "ver": 5, "status": "dropped"})
            )
        );
        // a conflict, and a close card, are not success
        let (r, _) = run_fake(
            &t.sub,
            vec![
                Ok(json!({"entity": {"ver": 5}})),
                Ok(json!({"conflict": {"ver": 7}})),
            ],
        );
        assert!(!r.unwrap().2);
        let (r, _) = run_fake(
            &t.sub,
            vec![
                Ok(json!({"entity": {"ver": 5}})),
                Ok(json!({"proposed": {"card": 3}})),
            ],
        );
        assert!(!r.unwrap().2);
        // the hub's refusal of a task that comes from a file reaches the user whole
        let (r, _) = run_fake(
            &t.sub,
            vec![
                Ok(json!({"entity": {"ver": 5}})),
                Err("not-allowed: this comes from /w/p.md; add a note".into()),
            ],
        );
        assert!(
            r.unwrap_err()
                .to_string()
                .contains("this comes from /w/p.md")
        );
        let (r, _) = run_fake(&t.sub, vec![Ok(json!({"entity": null}))]);
        assert_eq!(r.unwrap_err().to_string(), "no task task:aa-00001");

        // done ticks every step; another status leaves the steps as they are
        let view = json!({"version": 12, "tasks": [
            {"number": "1", "steps": [{"done": false, "text": "a"}, {"done": true, "text": "b"}]}]});
        let d = p("plan", &["status", "plan:aa-1", "1", "done"]).unwrap();
        let (r, seen) = run_fake(
            &d.sub,
            vec![Ok(view.clone()), Ok(json!({"plan": "plan:aa-1"}))],
        );
        assert!(r.unwrap().2);
        assert_eq!(seen[0], ("plans/get".into(), json!({"plan": "plan:aa-1"})));
        assert_eq!(
            seen[1],
            (
                "plans/write".into(),
                json!({"plan": "plan:aa-1", "base_version": 12, "tasks": [
                    {"number": "1", "status": "done",
                     "steps": [{"done": true, "text": "a"}, {"done": true, "text": "b"}]}]})
            )
        );
        let o = p("plan", &["status", "plan:aa-1", "1", "blocked"]).unwrap();
        let (_, seen) = run_fake(&o.sub, vec![Ok(view.clone()), Ok(json!({}))]);
        assert_eq!(
            seen[1].1["tasks"],
            json!([{"number": "1", "status": "blocked"}])
        );
        let (r, _) = run_fake(&o.sub, vec![Ok(json!({"version": 1, "tasks": []}))]);
        assert_eq!(r.unwrap_err().to_string(), "plan:aa-1 has no task 1");
    }

    #[test]
    fn plan_status_carries_its_reason_to_plans_write() {
        let c = p(
            "plan",
            &["status", "plan:aa-1", "2", "parked", "--reason", "after B1"],
        )
        .unwrap();
        let view = json!({"version": 3, "tasks": [{"number": "2", "steps": []}]});
        let (r, seen) = run_fake(&c.sub, vec![Ok(view), Ok(json!({"plan": "plan:aa-1"}))]);
        assert!(r.unwrap().2);
        assert_eq!(
            seen[1].1,
            json!({"plan": "plan:aa-1", "base_version": 3, "tasks": [
                {"number": "2", "status": "parked", "reason": "after B1"}]})
        );
        // a tracker task keeps it as a note, written after the status
        let t = p("task", &["status", "task:aa-1", "parked", "--reason", "x"]).unwrap();
        let (r, seen) = run_fake(
            &t.sub,
            vec![
                Ok(json!({"entity": {"ver": 2}})),
                Ok(json!({"id": "task:aa-1"})),
                Ok(json!({})),
            ],
        );
        assert!(r.unwrap().2);
        assert_eq!(
            seen[2],
            (
                "tasks/write".into(),
                json!({"op": "note", "id": "task:aa-1", "note": "x"})
            )
        );
    }

    #[test]
    fn task_readers_call_the_hubs_methods() {
        // list: only what was asked goes to tasks/find
        let l = p(
            "task",
            &[
                "list", "--query", "doors", "--status", "open", "--label", "a", "--label", "b",
                "--cursor", "50",
            ],
        )
        .unwrap();
        let page = json!({"tasks": [
            {"id": "task:aa-1", "title": "first", "status": "open", "assignee": "agent:s-1"},
            {"id": "task:aa-2", "title": "second", "status": "open", "assignee": null}],
            "cursor": 100});
        let (r, seen) = run_fake(&l.sub, vec![Ok(page)]);
        assert_eq!(
            seen,
            [(
                "tasks/find".into(),
                json!({"query": "doors", "status": "open", "labels": ["a", "b"], "cursor": 50})
            )]
        );
        let (t, _, ok) = r.unwrap();
        assert_eq!(
            t,
            "task:aa-1  open  first  @agent:s-1\ntask:aa-2  open  second\nmore: --cursor 100\n"
        );
        assert!(ok);
        let bare = p("task", &["list"]).unwrap();
        let (r, seen) = run_fake(&bare.sub, vec![Ok(json!({"tasks": []}))]);
        assert_eq!(seen, [("tasks/find".into(), json!({}))]);
        assert_eq!(r.unwrap().0, "no tasks\n");
        // ready
        let rd = p(
            "task",
            &["ready", "--label", "x", "--project", "proj", "--limit", "5"],
        )
        .unwrap();
        let (r, seen) = run_fake(
            &rd.sub,
            vec![Ok(
                json!({"tasks": [{"id": "task:aa-3", "title": "go", "status": "open"}]}),
            )],
        );
        assert_eq!(
            seen,
            [(
                "tasks/ready".into(),
                json!({"labels": ["x"], "project": "proj", "limit": 5})
            )]
        );
        assert_eq!(r.unwrap().0, "task:aa-3  open  go\n");
        // show: the entity with its links and notes; --history asks for the versions too
        let s = p("task", &["show", "task:aa-1"]).unwrap();
        let ent = json!({"entity": {"id": "task:aa-1", "kind": "task", "status": "open", "title": "first",
            "project": "proj", "ver": 3, "body": "do it"},
            "by": {}, "links": [{"kind": "blocks", "src": "task:aa-1", "dst": "task:aa-2"}],
            "notes": [{"text": "hello"}]});
        let (r, seen) = run_fake(&s.sub, vec![Ok(ent.clone())]);
        assert_eq!(
            seen,
            [(
                "graph/entity".into(),
                json!({"id": "task:aa-1", "include": ["links", "notes"]})
            )]
        );
        let (t, _, ok) = r.unwrap();
        assert!(ok);
        for want in [
            "task:aa-1  task  open  first\n",
            "project proj  ver 3\n",
            "do it\n",
            "links:\n  {\"kind\":\"blocks\",\"src\":\"task:aa-1\",\"dst\":\"task:aa-2\"}\n",
            "notes:\n  {\"text\":\"hello\"}\n",
        ] {
            assert!(t.contains(want), "{want:?} in {t:?}");
        }
        let h = p("task", &["show", "task:aa-1", "--history"]).unwrap();
        let (_, seen) = run_fake(&h.sub, vec![Ok(ent)]);
        assert_eq!(seen[0].1["include"], json!(["links", "notes", "history"]));
    }

    #[test]
    fn task_reader_flags_go_with_their_commands() {
        for (g, bad) in [
            ("task", &["list", "--cursor", "x"][..]),
            ("task", &["list", "--limit", "5"]),
            ("task", &["ready", "--query", "x"]),
            ("task", &["ready", "--limit", "-1"]),
            ("task", &["list", "--history"]),
            ("task", &["show"]),
            ("task", &["show", "a", "b"]),
            ("task", &["status", "t", "done", "--label", "x"]),
            ("card", &["list", "--query", "x"]),
        ] {
            assert!(p(g, bad).is_err(), "{g} {bad:?} should not parse");
        }
    }

    #[test]
    fn bad_lines_are_usage_errors_and_any_status_word_parses() {
        for (g, bad) in [
            ("card", &["settle", "x", "yes"][..]),
            ("card", &["settle", "1"]),
            ("card", &["list", "extra"]),
            ("card", &[]),
            ("message", &["send", "agent:s-1"]),
            ("message", &["reply", "one", "t"]),
            ("task", &["status", "t", "Done"]),
            ("task", &["status", "t", "9done"]),
            ("task", &["status", "t"]),
            ("plan", &["status", "p", "1"]),
            ("task", &["status", "t", "done", "--open"]),
        ] {
            assert!(p(g, bad).is_err(), "{g} {bad:?} should not parse");
        }
        // the status set is the hub's: a word the tracker may gain later parses
        for s in [
            "done",
            "dropped",
            "in-review",
            "accepted",
            "parked",
            "superseded",
        ] {
            assert!(p("task", &["status", "t", s]).is_ok(), "{s}");
        }
    }
}
