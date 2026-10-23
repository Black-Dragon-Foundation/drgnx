//! The graph store's methods the front serves (Urdr Task 15a; docs/develop/store.md, "Parsed entities"): the tracker
//! scan's door `graph/put-parsed` and `graph/record`, each one request of the graph writer, applied by
//! [`norn::parsed`] with the deny-list in force at the call.
//!
//! - **Projects** are resolved before the write (git, on a blocking thread, never under the writer's lock): the
//!   folders of the entities that are new or have none ([`norn::parsed::dirs`], read from the pool), and a record's
//!   repository. The write registers the new ones.
//! - **Who:** a put is `scan:<root>` (class `system`, tool `scan`); a record is the caller's (`coord::tx_meta`), keyed by
//!   its `collected` key, so a repeat answers the first answer and writes nothing.
//! - **Errors** as the front's other writes: a refusal is `invalid-params` with its text, a newer file `schema`, the
//!   rest `internal`.

use std::path::PathBuf;
use std::sync::Arc;

use crate::coord::{self, Writer};
use crate::dispatch::Caller;
use norn::deny::DenyList;
use norn::parsed;
use norn::project::ProjectCache;
use norn::tools::{Coord, GraphStore};
use runstav::methods::graph as api;
use runstav::wire::{Error, ErrorCode};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use urdr::graph::{Class as TxClass, Tx, TxMeta, WriteError, WriterHandle, Written};

fn internal(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// A graph writer's error as the method answers it.
fn fail(e: WriteError) -> Error {
    let (code, message) = match &e {
        WriteError::Refused(text) => (ErrorCode::InvalidParams, text.clone()),
        WriteError::Conflict(_) => (ErrorCode::InvalidParams, e.to_string()),
        WriteError::ReadOnly { .. } => (ErrorCode::Schema, e.to_string()),
        WriteError::Retryable(_) => (ErrorCode::Internal, "work.db is busy; retry".into()),
        WriteError::NotReady(text) => (ErrorCode::Internal, text.clone()),
        WriteError::Closed | WriteError::Sql(_) => {
            tracing::warn!("a graph write failed: {e}");
            (ErrorCode::Internal, e.to_string())
        }
    };
    Error {
        code,
        message,
        path: None,
    }
}

/// The hub's graph store and the deny-list in force now.
fn store(tools: &Coord) -> Result<(GraphStore, Arc<DenyList>), Error> {
    let g = tools
        .graph()
        .cloned()
        .ok_or_else(|| internal("the graph store is not open"))?;
    let deny = tools
        .deny()
        .ok_or_else(|| internal("the graph store is not open"))?;
    Ok((g, deny))
}

/// DIRS resolved to projects (git), on a blocking thread.
async fn resolve(dirs: Vec<PathBuf>) -> ProjectCache {
    if dirs.is_empty() {
        return ProjectCache::default();
    }
    tokio::task::spawn_blocking(move || {
        let mut cache = ProjectCache::default();
        for d in &dirs {
            cache.fill(d);
        }
        cache
    })
    .await
    .unwrap_or_default()
}

/// F in one request of WRITER after its `tx` row from META; a writer that is not open runs its tick (the opening
/// rule again) first, as the coordination store does.
async fn write<R, F>(writer: &WriterHandle, meta: TxMeta, f: F) -> Result<Written<R>, Error>
where
    R: Serialize + DeserializeOwned + Send + 'static,
    F: for<'t, 'c> FnOnce(&'t mut Tx<'c>) -> Result<R, WriteError> + Send + 'static,
{
    if !writer.status().open {
        writer.tick().await;
    }
    writer.write(meta, f).await.map_err(fail)
}

/// `graph/put-parsed`.
pub async fn put_parsed(
    w: &Writer,
    tools: &Coord,
    p: api::PutParsedParams,
) -> Result<Value, Error> {
    let (g, deny) = store(tools)?;
    let req = Arc::new(p);
    let (d, r) = (deny.clone(), req.clone());
    let dirs = g
        .pool
        .with(move |conn| parsed::dirs(conn, &d, &r))
        .await
        .map_err(|e| internal(e.to_string()))?
        .map_err(|e| internal(e.to_string()))?;
    let mut projects = resolve(dirs.into_iter().collect()).await;
    let req = Arc::try_unwrap(req).unwrap_or_else(|r| (*r).clone());
    let actor = match &req.root {
        Some(root) => format!("scan:{}", root.as_str()),
        None => "scan".into(),
    };
    let meta = TxMeta::new(actor, TxClass::System, "scan");
    let written = write(&g.writer, meta, move |tx| {
        parsed::put_with(tx, &deny, &mut projects, req)
    })
    .await?;
    w.signals.wrote();
    Ok(json!(written.value))
}

/// `graph/record`.
pub async fn record(
    w: &Writer,
    tools: &Coord,
    caller: &Caller,
    p: api::RecordParams,
) -> Result<Value, Error> {
    let (g, deny) = store(tools)?;
    let mut projects = resolve(parsed::record_dir(&deny, &p).into_iter().collect()).await;
    let mut meta = coord::tx_meta(caller, "graph/record");
    meta.req = p.collected.as_ref().map(|k| k.to_string());
    let written = write(&g.writer, meta, move |tx| {
        parsed::record(tx, &deny, &mut projects, p)
    })
    .await?;
    if !written.replayed {
        w.signals.wrote();
    }
    Ok(json!(written.value))
}
