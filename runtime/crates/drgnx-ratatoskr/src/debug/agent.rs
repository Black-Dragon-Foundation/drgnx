//! The partner agent's side of the debugger (graphical debugging spec §19.5, D4): the hub's half of the `debug_*`
//! tools (`norn::tools::debug`).  Each call is gated by the matrix's `debug.*` row for the calling session (an Ask is a
//! card, and the call is refused until the user's answer; then it is made again) and then acts:
//! - `debug_read` (`debug.read`): the live sessions and their stops, a project's recorded runs, a run's stops and
//!   lanes, a past stop's values, a fork's view, a stopped session's heap graph from an expression (not kept: the
//!   recorded runs keep the user's graphs only);
//! - `debug_probe` (`debug.probe`): probes and breakpoints in the user's session, marked as the session's (the editor
//!   rings them), and only its own removed;
//! - `debug_fork` (`debug.fork`): a what-if fork, sealed (a slow replay needs the user's yes: the agent is told so);
//! - `debug_live`: an evaluate (`debug.live-eval`) or a step (`debug.drive`) in the user's live session, at the stop
//!   the agent read: a session the user moved on since refuses it, so the user's own step wins;
//! - `debug_hypothesis` (`debug.read`): a `debug_hypothesis` record, and the `debug-investigation` event;
//! - `debug_fix` (`debug.fork`): the fix's files in a fresh fork of the run, run to its end against the predicate; only
//!   a pass is offered (the `debug-investigation` event's `fix`, which the editor shows as a card).
//!
//! The edit history (`history/*`) is not reachable from here: agents act on forks.

use super::fork::{RunEnd, Watch};
use super::fork_wire::forks;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug_fork::{DebugFork, DebugForkAt, DebugForkChange, DebugForkUntil};
use runstav::methods::debug_runs::{DebugRunGet, DebugRunStop, DebugRunsList};
use runstav::methods::matrix::Action;
use serde_json::{Value, json};
use std::time::Duration;

/// The hub's hypotheses so far: a new one's number.
static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// A fix's run, at most (its predicate's time box).
pub const FIX_LIMIT: Duration = Duration::from_secs(120);

/// The matrix row that gates tool OP with ARGS.
pub fn action_of(op: &str, args: &Value) -> Option<Action> {
    Some(match op {
        "debug_read" | "debug_hypothesis" => Action::DebugRead,
        "debug_probe" => Action::DebugProbe,
        "debug_fork" | "debug_fix" => Action::DebugFork,
        "debug_live" if args.get("op").and_then(Value::as_str) == Some("evaluate") => {
            Action::DebugLiveEval
        }
        "debug_live" => Action::DebugDrive,
        _ => return None,
    })
}

/// The agent read the session at stop READ; it is at NOW (none: running or gone). The user's step wins: a session
/// that moved on refuses the agent's.
pub fn still_at(session: &str, read: u64, now: Option<u64>) -> Result<(), String> {
    match now {
        Some(e) if e == read => Ok(()),
        Some(e) => Err(format!(
            "session {session} moved on since stop {read} (it is at stop {e} now: the user's step wins); read it again"
        )),
        None => Err(format!(
            "session {session} is not stopped (the user may have continued it); read it again"
        )),
    }
}

/// What makes a fix pass: the watch its run keeps, and the probe value it must never show.
#[derive(Clone, Debug, PartialEq)]
pub struct Predicate {
    pub watch: Watch,
    pub not: Option<String>,
}

/// `debug_fix`'s predicate: `{exception: "path:line"}` or `{probe: "path:line", expr, not}`, paths relative to the
/// project.
pub fn predicate(v: &Value) -> Result<Predicate, String> {
    let place = |s: &str| -> Result<(String, u32), String> {
        let (p, l) = s
            .rsplit_once(':')
            .ok_or_else(|| format!("{s:?} is not path:line"))?;
        let line = l.parse().map_err(|_| format!("{s:?} is not path:line"))?;
        Ok((p.to_owned(), line))
    };
    let text = |k: &str| v.get(k).and_then(Value::as_str);
    if let Some(at) = text("exception") {
        let (path, line) = place(at)?;
        return Ok(Predicate {
            watch: Watch::Exception { path, line },
            not: None,
        });
    }
    if let Some(at) = text("probe") {
        let (path, line) = place(at)?;
        let expr = text("expr")
            .ok_or("a probe predicate needs expr")?
            .to_owned();
        let not = text("not").ok_or("a probe predicate needs not")?.to_owned();
        return Ok(Predicate {
            watch: Watch::Probe { path, line, expr },
            not: Some(not),
        });
    }
    Err("a predicate is {exception: \"path:line\"} or {probe: \"path:line\", expr, not}".into())
}

/// Whether END (the fix's run) passes P: it exited 0 in time, the watched exception never came, and the probe never
/// showed the bad value.  The reason when it does not.
pub fn passes(p: &Predicate, end: &RunEnd) -> Result<(), String> {
    if end.timed_out {
        return Err("the run did not end within its time box".into());
    }
    if let Some((path, line)) = &end.exception_at {
        return Err(format!("the exception is still raised at {path}:{line}"));
    }
    if let Some(bad) = &p.not
        && end.probe_values.iter().any(|v| v == bad)
    {
        return Err(format!("the probe still shows {bad}"));
    }
    match end.exit {
        Some(0) => Ok(()),
        Some(c) => Err(format!("the program exited with {c}")),
        None => Err("the program's exit code is unknown".into()),
    }
}

/// Whether session SID may remove a mark whose owner is OWNER (none: the user's): only its own.
pub fn may_remove(what: &str, owner: Option<&str>, sid: &str) -> Result<(), String> {
    if owner == Some(sid) {
        Ok(())
    } else {
        Err(format!("{what} is not yours: only your own are removed"))
    }
}

/// The `debug-investigation` data offering the fix ARGS (`debug_fix`'s) of session SID for ROOT, or why it is not
/// offered: only a run END that passes P is.
pub fn offer(
    p: &Predicate,
    end: &RunEnd,
    args: &Value,
    root: &str,
    sid: &str,
) -> Result<Value, String> {
    passes(p, end)?;
    Ok(
        json!({"root": root, "fix": {"hypothesis": args.get("hypothesis"), "run": args.get("run"), "agent": sid,
              "passed": true, "files": args.get("files"), "predicate": args.get("predicate"), "exit": end.exit}}),
    )
}

fn arg<'a>(args: &'a Value, k: &str) -> Result<&'a str, String> {
    args.get(k)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{k} is needed"))
}

/// The hub's side of session SID's debugger tool OP with ARGS.
pub async fn tool(f: &Front, sid: &str, op: &'static str, args: Value) -> Result<String, String> {
    let me = f.core.agents.find(sid).map_err(|e| e.message)?;
    let a = action_of(op, &args).ok_or_else(|| format!("no debugger tool {op}"))?;
    let facts = crate::manager::call_facts(op, &args);
    crate::manager::gate(f, sid, &me.who(), a, None, &facts).await?;
    let v = match op {
        "debug_read" => read(f, &args).await?,
        "debug_probe" => probe(f, sid, &args).await?,
        "debug_fork" => fork(f, sid, &args).await?,
        "debug_live" => live(f, &args).await?,
        "debug_hypothesis" => hypothesis(f, sid, &args).await?,
        "debug_fix" => fix(f, sid, &args).await?,
        _ => return Err(format!("no debugger tool {op}")),
    };
    Ok(v.to_string())
}

/// Params P served by the recorded runs' methods.
async fn runs(f: &Front, p: Params) -> Result<Value, String> {
    let caller = crate::dispatch::Caller {
        class: runstav::registry::Class::Agent,
        sid: None,
        job: None,
        conn_id: 0,
    };
    match super::runs_wire::serve(f, &caller, p).await {
        Ok(r) => r.map_err(|e| e.message),
        Err(_) => Err("not a recorded runs' method".into()),
    }
}

async fn read(f: &Front, args: &Value) -> Result<Value, String> {
    let d = f.debug.debug(f);
    match arg(args, "what")? {
        "sessions" => Ok(json!({"sessions": d.list().into_iter().map(|(id, parent)| {
            let stop = d.stop_of(&id).map(|s| json!({
                "epoch": s.epoch, "thread": s.thread, "reason": s.reason,
                "frames": s.frames.iter().take(5).collect::<Vec<_>>(),
                "locals": s.scopes.first().and_then(|v| v.variables.clone()),
            }));
            json!({"debug_session": id, "parent": parent, "root": d.root_of(&id), "stop": stop})
        }).collect::<Vec<_>>()})),
        "runs" => {
            runs(
                f,
                Params::DebugRunsList(DebugRunsList {
                    root: arg(args, "root")?.to_owned(),
                }),
            )
            .await
        }
        "run" => {
            runs(
                f,
                Params::DebugRunGet(DebugRunGet {
                    run: arg(args, "run")?.to_owned(),
                    from: 0,
                    count: 200,
                    current: None,
                }),
            )
            .await
        }
        "stop" => {
            runs(
                f,
                Params::DebugRunStop(DebugRunStop {
                    run: arg(args, "run")?.to_owned(),
                    stop: args
                        .get("stop")
                        .and_then(Value::as_u64)
                        .ok_or("stop is needed")?,
                    file: None,
                }),
            )
            .await
        }
        "fork" => forks(f).view(arg(args, "fork")?),
        "heap" => {
            let session = arg(args, "debug_session")?;
            let epoch = d.stop_of(session).map(|s| s.epoch);
            let frame = args.get("frame").and_then(Value::as_i64);
            let g = super::heap::read(&d, session, frame, arg(args, "expr")?, Default::default())
                .await?;
            Ok(json!({"debug_session": session, "epoch": epoch, "graph": g}))
        }
        w => Err(format!(
            "debug_read reads sessions, runs, run, stop, fork or heap, not {w}"
        )),
    }
}

async fn probe(f: &Front, sid: &str, args: &Value) -> Result<Value, String> {
    let d = f.debug.debug(f);
    let root = arg(args, "root")?;
    let line = || {
        args.get("line")
            .and_then(Value::as_u64)
            .and_then(|l| u32::try_from(l).ok())
            .ok_or("line is needed")
    };
    match arg(args, "op")? {
        "probe" => {
            let rec = d.records().ok_or("runs are not recorded")?;
            let (path, line, expr) = (arg(args, "path")?.to_owned(), line()?, arg(args, "expr")?);
            let (path, id) = rec.probes(root, |s| {
                let (path, id) = s.apply(super::probes::Op::Add {
                    path,
                    line,
                    expr: expr.to_owned(),
                })?;
                let id = id.ok_or("no probe was added")?;
                s.mark(&id, sid)?;
                Ok::<_, String>((path, id))
            })?;
            d.probes_changed(root, &path).await;
            probes_event(f, root);
            Ok(json!({"probe": id}))
        }
        "breakpoint" => {
            let v = d
                .breakpoints(
                    root,
                    Some(super::breakpoints::Op::Add {
                        path: arg(args, "path")?.to_owned(),
                        line: line()?,
                        column: None,
                        enabled: true,
                        condition: None,
                        hit: None,
                        log: None,
                    }),
                    None,
                )
                .await;
            let id = v
                .get("added")
                .and_then(Value::as_u64)
                .ok_or("that line has a breakpoint already")?;
            d.mark_breakpoint(root, id, sid);
            Ok(json!({"breakpoint": format!("b{id}")}))
        }
        "remove" => {
            let id = arg(args, "id")?;
            if let Some(n) = id.strip_prefix('b').and_then(|n| n.parse::<u64>().ok()) {
                may_remove(
                    &format!("breakpoint {id}"),
                    d.breakpoint_owner(root, n).as_deref(),
                    sid,
                )?;
                d.breakpoints(root, Some(super::breakpoints::Op::Remove { id: n }), None)
                    .await;
                return Ok(json!({"removed": id}));
            }
            let rec = d.records().ok_or("runs are not recorded")?;
            let path = rec.probes(root, |s| {
                may_remove(
                    &format!("probe {id}"),
                    s.list()
                        .iter()
                        .find(|p| p.id == id)
                        .and_then(|p| p.agent.as_deref()),
                    sid,
                )?;
                s.apply(super::probes::Op::Remove { id: id.to_owned() })
                    .map(|(p, _)| p)
            })?;
            d.probes_changed(root, &path).await;
            probes_event(f, root);
            Ok(json!({"removed": id}))
        }
        o => Err(format!(
            "debug_probe does probe, breakpoint or remove, not {o}"
        )),
    }
}

/// ROOT's probes changed by an agent: the editors draw them again (`debug-probes`, `debug/probe/op`'s answer).
fn probes_event(f: &Front, root: &str) {
    let Some(rec) = f.debug.debug(f).records() else {
        return;
    };
    let probes: Vec<Value> = rec.probes(root, |s| {
        s.list()
            .iter()
            .map(|p| serde_json::to_value(p).unwrap_or(Value::Null))
            .collect()
    });
    f.editors
        .broadcast("debug-probes", json!({"root": root, "probes": probes}));
}

async fn fork(f: &Front, sid: &str, args: &Value) -> Result<Value, String> {
    let at: DebugForkAt = serde_json::from_value(args.get("at").cloned().unwrap_or(Value::Null))
        .map_err(|e| format!("at: {e}"))?;
    let change: Option<DebugForkChange> = match args.get("change") {
        Some(c) => Some(serde_json::from_value(c.clone()).map_err(|e| format!("change: {e}"))?),
        None => None,
    };
    if change.as_ref().is_some_and(|c| c.code) {
        return Err("an agent's code what-if is a fix: debug_fix".into());
    }
    let until: Option<DebugForkUntil> = match args.get("until") {
        Some(u) => Some(serde_json::from_value(u.clone()).map_err(|e| format!("until: {e}"))?),
        None => None,
    };
    let p = DebugFork {
        run: arg(args, "run")?.to_owned(),
        at,
        change,
        until,
        confirm: false,
        anyway: false,
        inputs: vec![],
    };
    let v = super::fork_wire::serve(f, Params::DebugFork(p))
        .await
        .map_err(|e| e.message)?;
    if let Some(id) = v.get("fork").and_then(Value::as_str) {
        forks(f).mark(id, sid);
        return Ok(
            json!({"fork": id, "then": "debug_read what=fork for its view once it is done"}),
        );
    }
    if let Some(q) = v.get("ask").and_then(Value::as_str) {
        return Err(format!("{q}: only the user can say yes to that"));
    }
    Err("the run's configuration needs an input or trust only the user can give".into())
}

async fn live(f: &Front, args: &Value) -> Result<Value, String> {
    let d = f.debug.debug(f);
    let session = arg(args, "debug_session")?;
    let read = args
        .get("epoch")
        .and_then(Value::as_u64)
        .ok_or("epoch is needed")?;
    let stop = d.stop_of(session);
    still_at(session, read, stop.as_ref().map(|s| s.epoch))?;
    let stop = stop.ok_or("not stopped")?;
    let t = Some(stop.thread);
    let op = match arg(args, "op")? {
        "evaluate" => {
            let h = d.session(session).ok_or("no such session")?;
            let r = h
                .request(
                    "evaluate",
                    json!({"expression": arg(args, "expr")?, "frameId": stop.frame, "context": "repl"}),
                )
                .await?;
            return Ok(json!({"result": r.get("result"), "type": r.get("type")}));
        }
        "continue" => super::session::Op::Continue { thread: t },
        "next" => super::session::Op::Next { thread: t },
        "step-in" => super::session::Op::StepIn { thread: t },
        "step-out" => super::session::Op::StepOut { thread: t },
        o => {
            return Err(format!(
                "debug_live does evaluate, continue, next, step-in or step-out, not {o}"
            ));
        }
    };
    // checked again at the last moment: a step of the user's in between wins
    still_at(session, read, d.stop_of(session).map(|s| s.epoch))?;
    d.control(session, op).await?;
    Ok(json!({"done": true}))
}

async fn hypothesis(f: &Front, sid: &str, args: &Value) -> Result<Value, String> {
    let root = arg(args, "root")?.to_owned();
    let title = arg(args, "title")?.to_owned();
    let state = arg(args, "state")?.to_owned();
    let evidence: Vec<String> = args
        .get("evidence")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| e.as_str().map(str::to_owned))
        .collect();
    let id = match args.get("id").and_then(Value::as_str) {
        Some(i) => i.to_owned(),
        None => format!(
            "{sid}-h{}",
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1
        ),
    };
    let tm = urdr::graph::TxMeta {
        session: Some(sid.to_owned()),
        ..urdr::graph::TxMeta::new(
            format!("agent:{sid}"),
            urdr::graph::Class::Agent,
            "mcp:debug_hypothesis",
        )
    };
    let (i, s, r, t, st, ev) = (
        id.clone(),
        sid.to_owned(),
        root.clone(),
        title.clone(),
        state.clone(),
        evidence.clone(),
    );
    let eid = f
        .writer
        .db
        .write(tm, move |tx| {
            norn::write::debug::hypothesis(tx, &i, &s, &r, &t, &st, &ev, None)
        })
        .await
        .map_err(|e| e.to_string())?;
    f.editors.broadcast(
        "debug-investigation",
        json!({"root": root, "hypothesis": {"id": id, "record": eid, "title": title, "state": state,
               "evidence": evidence, "agent": sid}}),
    );
    Ok(json!({"hypothesis": id}))
}

async fn fix(f: &Front, sid: &str, args: &Value) -> Result<Value, String> {
    arg(args, "hypothesis")?;
    let run = arg(args, "run")?.to_owned();
    let p = predicate(args.get("predicate").unwrap_or(&Value::Null))?;
    let files: Vec<(String, String)> = args
        .get("files")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|x| {
            Some((
                x.get("path")?.as_str()?.to_owned(),
                x.get("text")?.as_str()?.to_owned(),
            ))
        })
        .collect();
    if files.is_empty() {
        return Err("a fix changes at least one file".into());
    }
    let info = forks(f)
        .recorded(&run)
        .ok_or_else(|| format!("no recorded run {run}"))?;
    let resolved = super::fork_wire::resolved_for(f, &info)?;
    let end = forks(f)
        .check_fix(&run, resolved, &files, p.watch.clone(), FIX_LIMIT)
        .await?;
    // only a fix that passed in a fresh fork is offered: the editor shows it as a card
    match offer(&p, &end, args, &info.root, sid) {
        Err(why) => Ok(json!({"passed": false, "why": why, "offered": false})),
        Ok(data) => {
            f.editors.broadcast("debug-investigation", data);
            Ok(json!({"passed": true, "offered": true}))
        }
    }
}
