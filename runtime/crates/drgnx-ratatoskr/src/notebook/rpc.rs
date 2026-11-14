//! The `notebook/*` methods (runstav `methods::notebook`): each is one call on the hub's [`Notebooks`], answered in the contract's types.
//! The notebooks live as long as the hub; they are made on the first call, with the session's private folder for the kernels'
//! connection files and sockets (under `$XDG_RUNTIME_DIR`, else a folder of the user's in `/tmp`).

use std::path::PathBuf;
use std::sync::OnceLock;

use runstav::methods::Params;
use runstav::methods::notebook::{
    NotebookCell, NotebookCellText, NotebookEnded, NotebookKernel, NotebookKernels, NotebookOpened,
    NotebookOutput, NotebookSkipped, NotebookStarted, NotebookTail,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};

use super::book::{CellInfo, CellSync};
use super::hub::Notebooks;
use super::kernel::{Exit, Timeouts};
use super::spec::{self, Interrupt};
use crate::dispatch::Caller;
use crate::front::Front;
use hrafn::notebook::Kind;

/// The hub's notebooks, made when first asked for.
#[derive(Default)]
pub struct Hub(OnceLock<Result<Notebooks, String>>);

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

fn make(front: &Front) -> Result<Notebooks, String> {
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(format!("/tmp/drgnx-{uid}")));
    let folder = spec::private_folder(&runtime.join("drgnx-notebooks"))?;
    // connection files of kernels that are gone: this hub has none running yet
    spec::sweep(&folder, &[]);
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let dirs = spec::standard_dirs(
        &home,
        std::env::var("JUPYTER_PATH").ok().as_deref(),
        std::env::var("XDG_DATA_DIRS").ok().as_deref(),
    );
    Ok(Notebooks::new(
        front.editors.clone(),
        folder,
        dirs,
        Timeouts::default(),
    ))
}

impl Hub {
    fn get(&self, front: &Front) -> Result<&Notebooks, Error> {
        self.0
            .get_or_init(|| make(front))
            .as_ref()
            .map_err(|e| err(format!("notebooks are not available: {e}")))
    }
}

fn kind_name(k: Kind) -> &'static str {
    match k {
        Kind::Code => "code",
        Kind::Markdown => "markdown",
        Kind::Raw => "raw",
    }
}

fn cell(c: CellInfo) -> NotebookCell {
    NotebookCell {
        id: c.id,
        ty: kind_name(c.kind).into(),
        source: c.source,
        execution_count: c.execution_count,
    }
}

fn syncs(c: Vec<NotebookCellText>) -> Vec<CellSync> {
    c.into_iter()
        .map(|c| CellSync {
            id: c.id,
            kind: match c.ty.as_str() {
                "markdown" => Kind::Markdown,
                "raw" => Kind::Raw,
                _ => Kind::Code,
            },
            source: c.source,
        })
        .collect()
}

fn tail(v: Value) -> Result<NotebookTail, Error> {
    serde_json::from_value(v).map_err(|e| err(format!("a tail the contract does not hold: {e}")))
}

fn ended(e: Exit) -> NotebookEnded {
    NotebookEnded {
        code: e.code,
        signal: e.signal,
        stderr: e.stderr,
    }
}

/// P served by the notebook methods, or handed back.
pub async fn serve(
    front: &Front,
    caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    let nb = match front.notebooks.get(front) {
        Ok(nb) => nb,
        Err(e) => return Ok(Err(e)),
    };
    let ok = |r: Result<(), String>| r.map(|()| json!(true)).map_err(err);
    Ok(match p {
        Params::NotebookOpen(p) => match nb
            .open(caller.conn_id, std::path::Path::new(&p.path), p.text)
            .await
        {
            Ok(o) => (|| {
                Ok(json!(NotebookOpened {
                    id: o.id,
                    cells: o.cells.into_iter().map(cell).collect(),
                    kernelspec: o.kernelspec,
                    language: o.language,
                    tails: o.tails.into_iter().map(tail).collect::<Result<_, _>>()?,
                }))
            })(),
            Err(e) => Err(err(e)),
        },
        Params::NotebookSync(p) => ok(nb.sync(&p.id, &syncs(p.cells)).await),
        Params::NotebookExecute(p) => ok(nb.execute(&p.id, &syncs(p.cells)).await),
        Params::NotebookSave(p) => {
            let cells = p.cells.map(syncs);
            ok(nb.save(&p.id, cells.as_deref()).await)
        }
        Params::NotebookKernels(_) => {
            let (specs, skipped) = nb.kernels_with_skips();
            Ok(json!(NotebookKernels {
                kernels: specs
                    .into_iter()
                    .map(|k| NotebookKernel {
                        name: k.name,
                        display_name: k.display_name,
                        language: k.language,
                        interrupt: match k.interrupt {
                            Interrupt::Signal => "signal",
                            Interrupt::Message => "message",
                        }
                        .into(),
                    })
                    .collect(),
                skipped: skipped
                    .into_iter()
                    .map(|s| NotebookSkipped {
                        name: s.name,
                        why: s.why
                    })
                    .collect(),
            }))
        }
        // the editor is the user's: never a sealed session's launch plan
        Params::NotebookStart(p) => nb
            .start(&p.id, p.kernel.as_deref(), None)
            .await
            .map(|kernel| json!(NotebookStarted { kernel }))
            .map_err(err),
        Params::NotebookRestart(p) => nb
            .restart(&p.id)
            .await
            .map(|kernel| json!(NotebookStarted { kernel }))
            .map_err(err),
        Params::NotebookShutdown(p) => nb
            .shutdown(&p.id)
            .await
            .map(|e| json!(ended(e)))
            .map_err(err),
        Params::NotebookInterrupt(p) => ok(nb.interrupt(&p.id).await),
        Params::NotebookInput(p) => ok(nb.input(&p.id, &p.request, &p.value).await),
        Params::NotebookTail(p) => match nb.tail(&p.id, &p.cell).await {
            Ok(v) => tail(v).map(|t| json!(t)),
            Err(e) => Err(err(e)),
        },
        Params::NotebookOutput(p) => nb
            .output(&p.id, &p.cell)
            .await
            .map(|outputs| json!(NotebookOutput { outputs }))
            .map_err(err),
        Params::NotebookClear(p) => ok(nb.clear(&p.id, p.cell.as_deref()).await),
        Params::NotebookClose(p) => {
            nb.close(&p.id).await;
            Ok(json!(true))
        }
        other => return Err(Box::new(other)),
    })
}
