//! `debug/origin` (runstav `methods::debug_origin`): a trail started on a task, its levels sent as `debug-origin`
//! events with the card (`origin::rows`).  The replay is D2's sealed fork ([`Replay`], set by the forks once they
//! exist); the static candidates read the files from the run's launch snapshot (the stop's file and its stack's).

use super::origin::{self, Link, Replay};
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug_origin::{DebugOrigin, DebugOriginStarted};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

/// The hub's trails: the replay they use.
#[derive(Default)]
pub struct Origins {
    replay: OnceLock<Arc<dyn Replay>>,
    next: AtomicU64,
}

impl Origins {
    /// The replay trails use (D2's forks).
    pub fn set_replay(&self, r: Arc<dyn Replay>) {
        let _ = self.replay.set(r);
    }
}

fn err(code: ErrorCode, message: impl Into<String>) -> Error {
    Error {
        code,
        message: message.into(),
        path: None,
    }
}

/// The files the static candidates are looked for in: the stop's and those of its stack, as they ran.
fn sources(rec: &super::record::Records, run: &str, stop: u64) -> Vec<(String, String)> {
    let Ok(past) = rec.past_stop(run, stop, None) else {
        return Vec::new();
    };
    let mut paths: Vec<String> = past["source"]["path"]
        .as_str()
        .map(str::to_owned)
        .into_iter()
        .collect();
    for f in past["capture"]["frames"].as_array().into_iter().flatten() {
        if let Some(p) = f["source"]["path"].as_str()
            && p.ends_with(".py")
            && !paths.iter().any(|q| q == p)
        {
            paths.push(p.to_owned());
        }
    }
    paths
        .into_iter()
        .filter_map(|p| {
            let v = rec.past_stop(run, stop, Some(&p)).ok()?;
            let text = v["source"]["text"].as_str()?.to_owned();
            Some((p, text))
        })
        .collect()
}

async fn start(front: &Front, p: DebugOrigin) -> Result<DebugOriginStarted, Error> {
    let origins = &front.debug.origins;
    let rec = front
        .debug
        .debug(front)
        .records()
        .ok_or_else(|| err(ErrorCode::Internal, "runs are not recorded"))?;
    rec.past_stop(&p.run, p.stop, None)
        .map_err(|e| err(ErrorCode::InvalidParams, e))?;
    let n = rec
        .get(&p.run, 0, 1)
        .map_err(|e| err(ErrorCode::InvalidParams, e))?;
    let replay = origins.replay.get().cloned().ok_or_else(|| {
        err(
            ErrorCode::Internal,
            "where a value came from needs a what-if fork of the run, which this hub cannot make yet",
        )
    })?;
    let id = format!("o{}", origins.next.fetch_add(1, Ordering::Relaxed) + 1);
    let editors = front.editors.clone();
    let base = json!({"origin": id, "run": p.run, "stop": p.stop, "expr": p.expr,
                      "n": n["run"]["n"].as_u64().unwrap_or(0)});
    let send = move |mut v: Value| {
        v["rows"] = serde_json::to_value(origin::rows(&v)).unwrap_or(Value::Null);
        editors.broadcast("debug-origin", v);
    };
    let (run, stop, expr, depth) = (
        p.run.clone(),
        p.stop,
        p.expr.clone(),
        p.depth.unwrap_or(origin::DEPTH_MAX),
    );
    crate::clock::spawn("debug:origin", async move {
        let mut links: Vec<Link> = Vec::new();
        let mut level = 1u64;
        let mut first = base.clone();
        first["state"] = json!("tracing");
        first["level"] = json!(1);
        send(first);
        let src = || sources(&rec, &run, stop);
        let r = origin::trail(replay.as_ref(), &run, stop, &expr, depth, src, |found| {
            links.extend(found.iter().cloned());
            level += 1;
            let mut v = base.clone();
            v["state"] = json!("tracing");
            v["level"] = json!(level);
            v["links"] = json!(links.iter().map(origin::link_json).collect::<Vec<_>>());
            send(v);
        })
        .await;
        let mut v = base.clone();
        match r {
            Ok(t) => {
                v["state"] = json!("done");
                v["links"] = json!(t.links.iter().map(origin::link_json).collect::<Vec<_>>());
                if let Some(n) = t.note {
                    v["note"] = json!(n);
                }
            }
            Err(e) => {
                v["state"] = json!("failed");
                v["why"] = json!(e);
                v["links"] = json!(links.iter().map(origin::link_json).collect::<Vec<_>>());
            }
        }
        send(v);
    });
    Ok(DebugOriginStarted { origin: id })
}

/// P served by `debug/origin`, or handed back.
pub async fn serve(
    front: &Front,
    _caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    Ok(match p {
        Params::DebugOrigin(p) => start(front, p).await.map(|v| json!(v)),
        other => return Err(Box::new(other)),
    })
}
