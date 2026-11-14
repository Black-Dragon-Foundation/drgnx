//! The `notebook/*` methods (runstav `methods::notebook`): each is one call on the hub's [`Notebooks`], answered in the contract's types.
//! The notebooks live as long as the hub; they are made on the first call, with the session's private folder for the kernels'
//! connection files and sockets (under `$XDG_RUNTIME_DIR`, else a folder of the user's in `/tmp`).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use runstav::methods::Params;
use runstav::methods::notebook::{
    NotebookCell, NotebookCellText, NotebookEnded, NotebookKernel, NotebookKernels, NotebookOpened,
    NotebookOutput, NotebookSkipped, NotebookStarted, NotebookTail, NotebookViewName,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};

use super::book::{CellInfo, CellSync};
use super::hub::Notebooks;
use super::kernel::{Exit, Timeouts};
use super::spec::{self, Interrupt};
use super::views::{NbViews, WatchSink};
use crate::dispatch::Caller;
use crate::front::Front;
use hrafn::notebook::Kind;

/// The hub's notebooks, made when first asked for (an error is not kept: the next call tries again).
#[derive(Default)]
pub struct Hub {
    nb: Mutex<Option<Arc<Notebooks>>>,
    /// The notebooks' Sjá views.
    pub views: Arc<NbViews>,
}

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// The folder the notebooks' private folder is made in: XDG_RUNTIME_DIR when it is an absolute path, else FALLBACK (the user's own
/// folder in /tmp), which must itself be ours, private and not a link.
pub(crate) fn runtime_dir(xdg: Option<PathBuf>, fallback: &Path) -> Result<PathBuf, String> {
    match xdg.filter(|p| p.is_absolute()) {
        Some(p) => Ok(p),
        None => spec::private_folder(fallback),
    }
}

fn make(front: &Front, views: &Arc<NbViews>) -> Result<Notebooks, String> {
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let runtime = runtime_dir(
        std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from),
        Path::new(&format!("/tmp/drgnx-{uid}")),
    )?;
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
        Arc::new(WatchSink {
            inner: front.editors.clone(),
            views: views.clone(),
        }),
        folder,
        dirs,
        Timeouts::default(),
    ))
}

impl Hub {
    fn get(&self, front: &Front) -> Result<Arc<Notebooks>, Error> {
        let nb = self.get_with(|| make(front, &self.views))?;
        self.views.attach(&nb, front.core.views.front_weak());
        Ok(nb)
    }

    /// The notebooks, made by MAKE the first time it works: an error is not kept.
    pub(crate) fn get_with(
        &self,
        make: impl FnOnce() -> Result<Notebooks, String>,
    ) -> Result<Arc<Notebooks>, Error> {
        let mut slot = self
            .nb
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(nb) = &*slot {
            return Ok(nb.clone());
        }
        let nb = Arc::new(make().map_err(|e| err(format!("notebooks are not available: {e}")))?);
        *slot = Some(nb.clone());
        Ok(nb)
    }

    /// The editor on connection CONN is gone: its notebooks close and their kernels end.
    pub fn gone(&self, conn: u64) {
        self.views.gone(conn);
        let nb = self
            .nb
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        if let Some(nb) = nb {
            crate::clock::spawn("notebook:gone", async move { nb.gone(conn).await });
        }
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
    let conn = caller.conn_id;
    let ok = |r: Result<(), String>| r.map(|()| json!(true)).map_err(err);
    let views = &front.notebooks.views;
    Ok(match p {
        Params::NotebookOpen(p) => match nb.open(conn, std::path::Path::new(&p.path), p.text).await
        {
            Ok(o) => (|| {
                Ok(json!(NotebookOpened {
                    id: o.id,
                    cells: o.cells.into_iter().map(cell).collect(),
                    kernelspec: o.kernelspec,
                    language: o.language,
                    tails: o.tails.into_iter().map(tail).collect::<Result<_, _>>()?,
                    more_tails: o.more_tails as u32,
                }))
            })(),
            Err(e) => Err(err(e)),
        },
        Params::NotebookSync(p) => {
            let r = nb.sync(conn, &p.id, &syncs(p.cells)).await;
            views.changed(conn, &p.id);
            ok(r)
        }
        Params::NotebookExecute(p) => {
            let r = nb.execute(conn, &p.id, &syncs(p.cells)).await;
            views.changed(conn, &p.id);
            ok(r)
        }
        Params::NotebookSave(p) => {
            let cells = p.cells.map(syncs);
            let r = nb.save(conn, &p.id, cells.as_deref()).await;
            views.changed(conn, &p.id);
            ok(r)
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
            .start(conn, &p.id, p.kernel.as_deref(), None)
            .await
            .map(|kernel| json!(NotebookStarted { kernel }))
            .map_err(err),
        Params::NotebookRestart(p) => nb
            .restart(conn, &p.id)
            .await
            .map(|kernel| json!(NotebookStarted { kernel }))
            .map_err(err),
        Params::NotebookShutdown(p) => nb
            .shutdown(conn, &p.id)
            .await
            .map(|e| json!(ended(e)))
            .map_err(err),
        Params::NotebookInterrupt(p) => ok(nb.interrupt(conn, &p.id).await),
        Params::NotebookInput(p) => ok(nb.input(conn, &p.id, &p.request, &p.value).await),
        Params::NotebookTail(p) => match nb.tail(conn, &p.id, &p.cell).await {
            Ok(v) => tail(v).map(|t| json!(t)),
            Err(e) => Err(err(e)),
        },
        Params::NotebookOutput(p) => nb
            .output(conn, &p.id, &p.cell)
            .await
            .map(|outputs| json!(NotebookOutput { outputs }))
            .map_err(err),
        Params::NotebookClear(p) => {
            let r = nb.clear(conn, &p.id, p.cell.as_deref()).await;
            views.changed(conn, &p.id);
            ok(r)
        }
        Params::NotebookView(p) => {
            if nb.owns(conn, &p.id) {
                views
                    .register(conn, &p.id, p.kind, p.cell.as_deref())
                    .map(|view| json!(NotebookViewName { view }))
                    .map_err(err)
            } else {
                Err(err(format!("no open notebook {}", p.id)))
            }
        }
        Params::NotebookClose(p) => {
            nb.close(conn, &p.id).await;
            views.closed(conn, &p.id);
            Ok(json!(true))
        }
        other => return Err(Box::new(other)),
    })
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn the_fallback_folder_must_be_the_users_own_private_one_and_a_runtime_folder_is_taken_as_it_is()
     {
        let t = tempfile::tempdir().unwrap();
        let fallback = t.path().join("drgnx-1000");
        // made 0700 when missing
        let made = runtime_dir(None, &fallback).unwrap();
        assert_eq!(
            std::fs::metadata(&made).unwrap().permissions().mode() & 0o777,
            0o700
        );
        // a loose one, or a link, is refused
        std::fs::set_permissions(&fallback, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(runtime_dir(None, &fallback).unwrap_err().contains("0700"));
        let link = t.path().join("link");
        std::os::unix::fs::symlink(&made, &link).unwrap();
        assert!(runtime_dir(None, &link).unwrap_err().contains("link"));
        // a runtime folder is not looked at, a relative one is not used
        assert_eq!(
            runtime_dir(Some(PathBuf::from("/run/user/1000")), &fallback).unwrap(),
            PathBuf::from("/run/user/1000")
        );
        assert!(
            runtime_dir(Some(PathBuf::from("relative")), &link).is_err(),
            "falls to the fallback, which is refused"
        );
    }

    #[test]
    fn a_failure_to_make_the_notebooks_is_not_kept() {
        let hub = Hub::default();
        let t = tempfile::tempdir().unwrap();
        let sink = std::sync::Arc::new(crate::settings::agents::Editors::default());
        assert!(hub.get_with(|| Err("no folder yet".into())).is_err());
        let made = hub.get_with(|| {
            Ok(Notebooks::new(
                sink.clone(),
                t.path().to_path_buf(),
                vec![],
                Timeouts::default(),
            ))
        });
        assert!(made.is_ok(), "the next call tries again");
        // and once made it is the same one
        let again = hub.get_with(|| Err("not asked".into())).unwrap();
        assert!(std::sync::Arc::ptr_eq(&made.unwrap(), &again));
    }
}
