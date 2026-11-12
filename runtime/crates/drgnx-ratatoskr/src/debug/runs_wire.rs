//! The recorded runs' and probes' methods (runstav `methods::debug_runs`), and the hub's records: the runs folder
//! (`<state>/debug/runs`), the launch snapshots in the checkpoints folder (`<state>/hub/checkpoints`), each run's Urdr
//! record (kind `debug_run`, written in order on one task), and whether a run's task is still open.

use super::probes::{self, Lang, Op as ProbeOp};
use super::record::{Opts, RunMeta, RunSink};
use crate::coord::Writer;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug_runs::{
    DebugPastStop, DebugProbeOp, DebugProbes, DebugRunGet, DebugRunPin, DebugRunStop, DebugRunView,
    DebugRuns, DebugRunsList,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::mpsc;

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: None,
    }
}

/// The Urdr records, written in the order put, on one task.
struct Graph(mpsc::UnboundedSender<(String, Option<RunMeta>)>);

impl RunSink for Graph {
    fn put(&self, meta: &RunMeta) {
        let _ = self.0.send((meta.id.clone(), Some(meta.clone())));
    }
    fn gone(&self, id: &str) {
        let _ = self.0.send((id.to_owned(), None));
    }
}

fn graph(writer: Writer) -> Arc<Graph> {
    let (tx, mut rx) = mpsc::unbounded_channel::<(String, Option<RunMeta>)>();
    crate::clock::spawn("debug:run-records", async move {
        while let Some((id, meta)) = rx.recv().await {
            let tm = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "debug/run");
            let r = writer
                .db
                .write(tm, move |tx| match meta {
                    Some(m) => {
                        let data = serde_json::to_value(&m).unwrap_or(Value::Null);
                        norn::write::debug::put(tx, &id, &m.name, m.ended.is_some(), data, None)
                            .map(drop)
                    }
                    None => norn::write::debug::gone(tx, &id),
                })
                .await;
            if let Err(e) = r {
                tracing::warn!(target: "drgnx::debug", "run record: {e:?}");
            }
        }
    });
    Arc::new(Graph(tx))
}

/// The task an agent works on in ROOT, if any (a run there is kept while it is open).
pub(super) fn task_of(front: &Front, root: &str) -> Option<String> {
    front
        .core
        .agents
        .snapshots()
        .into_iter()
        .find(|s| s.cwd.as_deref() == Some(root))
        .and_then(|s| s.task)
}

/// The records' options for the hub behind FRONT.
pub(super) fn opts(front: &Front) -> Opts {
    let state = runstav::paths::state_dir(&front.shell_env.paths_env());
    let mut o = Opts::new(
        state.join("debug").join("runs"),
        state.join("hub").join("checkpoints"),
    );
    o.probes = Some(state.join("debug-probes"));
    o.store = graph(front.writer.clone());
    let writer = front.writer.clone();
    o.task_open = Arc::new(move |task: String| {
        let w = writer.clone();
        Box::pin(async move {
            w.db.read(move |c| {
                Ok::<_, norn::store::CoordError>(
                    urdr::graph::entity::by_id(c, &task)
                        .ok()
                        .flatten()
                        .is_some_and(|e| {
                            e.retired_tx.is_none()
                                && !e
                                    .status
                                    .as_deref()
                                    .is_some_and(|s| norn::tracker::CLOSED.contains(&s))
                        }),
                )
            })
            .await
            .unwrap_or(true)
        })
    });
    o
}

fn lang_of(language: Option<&str>, path: &str) -> Lang {
    let by_ext = |p: &str| match p.rsplit('.').next() {
        Some("py") => "debugpy",
        Some("js" | "mjs" | "cjs" | "ts") => "pwa-node",
        Some("go") => "go",
        Some("c" | "cc" | "cpp" | "rs") => "lldb-dap",
        _ => "",
    };
    let ty = match language {
        Some("python") => "debugpy",
        Some("javascript" | "typescript") => "pwa-node",
        Some("go") => "go",
        Some("c" | "c++" | "rust") => "lldb-dap",
        _ => by_ext(path),
    };
    probes::lang(ty)
}

async fn probe_op(front: &Front, p: DebugProbeOp) -> Result<DebugProbes, Error> {
    let d = front.debug.debug(front);
    let rec = d.records().ok_or_else(|| err("runs are not recorded"))?;
    let mut changed = None;
    let mut added = None;
    if let Some(o) = p.op {
        let op = match o.op.as_str() {
            "add" => ProbeOp::Add {
                path: o.path.unwrap_or_default(),
                line: o.line.unwrap_or(1),
                expr: o.expr.unwrap_or_default(),
            },
            "result" => {
                let path = o.path.unwrap_or_default();
                ProbeOp::Result {
                    lang: lang_of(o.language.as_deref(), &path),
                    path,
                    line: o.line.unwrap_or(1),
                    expr: o.expr.unwrap_or_default(),
                    text: o.text.unwrap_or_default(),
                }
            }
            "remove" => ProbeOp::Remove {
                id: o.id.unwrap_or_default(),
            },
            _ => ProbeOp::Edit {
                id: o.id.unwrap_or_default(),
                expr: o.expr,
                enabled: o.enabled,
                line: o.line,
            },
        };
        let (path, id) = rec.probes(&p.root, |s| s.apply(op)).map_err(err)?;
        d.probes_changed(&p.root, &path).await;
        changed = Some(path);
        added = id;
    }
    let probes = rec.probes(&p.root, |s| {
        s.list()
            .iter()
            .map(|x| serde_json::to_value(x).unwrap_or(Value::Null))
            .collect()
    });
    Ok(DebugProbes {
        root: p.root,
        probes,
        path: changed,
        added,
    })
}

fn records(front: &Front) -> Result<Arc<super::record::Records>, Error> {
    front
        .debug
        .debug(front)
        .records()
        .ok_or_else(|| err("runs are not recorded"))
}

fn list(front: &Front, p: DebugRunsList) -> Result<DebugRuns, Error> {
    let runs = records(front)?
        .list(&p.root)
        .into_iter()
        .map(|mut m| {
            // the list is the summary: the start parameters stay with the run
            m.start = Value::Null;
            serde_json::to_value(m).unwrap_or(Value::Null)
        })
        .collect();
    Ok(DebugRuns { runs })
}

fn get(front: &Front, p: DebugRunGet) -> Result<DebugRunView, Error> {
    let mut v = records(front)?
        .get(&p.run, p.from as usize, p.count as usize)
        .map_err(err)?;
    v["strip"] = json!(super::strip::rows(&v, p.from as usize, p.current));
    serde_json::from_value(v).map_err(|e| err(e.to_string()))
}

fn past(front: &Front, p: DebugRunStop) -> Result<DebugPastStop, Error> {
    let v = records(front)?
        .past_stop(&p.run, p.stop, p.file.as_deref())
        .map_err(err)?;
    serde_json::from_value(v).map_err(|e| err(e.to_string()))
}

fn pin(front: &Front, p: DebugRunPin) -> Result<bool, Error> {
    records(front)?.pin(&p.run, p.pinned).map_err(err)?;
    Ok(true)
}

fn answer<T: serde::Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.map(|v| json!(v))
}

/// P served by the runs' methods, or handed back.
pub async fn serve(
    front: &Front,
    _caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match p {
        Params::DebugProbeOp(p) => answer(probe_op(front, p).await),
        Params::DebugRunsList(p) => answer(list(front, p)),
        Params::DebugRunGet(p) => answer(get(front, p)),
        Params::DebugRunStop(p) => answer(past(front, p)),
        Params::DebugRunPin(p) => answer(pin(front, p)),
        other => return Err(Box::new(other)),
    })
}
