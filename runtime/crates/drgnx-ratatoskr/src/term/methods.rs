//! The `term/*` methods (runstav's `methods::term`): the editor's requests, turned into the worker's messages, and the
//! `view/*` messages of a terminal's view (`term:<id>`), which go to its worker rather than the hub's own views.

use super::{Spawn, Terms};
use drgnx_term::proto::{In, Out};
use drgnx_term::scope::Limits;
use runstav::methods::Params;
use runstav::methods::term::{TermOpened, TermStatus};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::time::Duration;

/// How long a worker has to answer a request that reads its rows (a search reads every row it holds).
const ANSWER_WITHIN: Duration = Duration::from_secs(5);
/// How long `term/list` waits for each worker: one that does not answer counts as running.
const LIST_WITHIN: Duration = Duration::from_millis(200);

fn error(code: ErrorCode, message: impl Into<String>, path: Option<&str>) -> Error {
    Error {
        code,
        message: message.into(),
        path: path.map(str::to_owned),
    }
}

fn no_such(id: &str) -> Error {
    error(
        ErrorCode::InvalidParams,
        format!("no terminal {id}"),
        Some("id"),
    )
}

/// The terminal id of a terminal's view, `term:<id>`.
pub fn view_id(view: &str) -> Option<&str> {
    view.strip_prefix("term:")
}

/// Send MSG to terminal ID: true, or no such terminal.
fn tell(t: &Terms, id: &str, msg: In) -> Result<Value, Error> {
    if t.send(id, &msg) {
        Ok(json!(true))
    } else {
        Err(no_such(id))
    }
}

/// The result of an `answer` from worker ID.
async fn answer(t: &Terms, id: &str, make: impl FnOnce(u64) -> In) -> Result<Value, Error> {
    match t.ask(id, make, ANSWER_WITHIN).await {
        Ok(Out::Answer { result, .. }) => Ok(result),
        Ok(_) => Err(error(
            ErrorCode::Internal,
            "the worker answered something else",
            None,
        )),
        Err(_) if t.record(id).is_none() => Err(no_such(id)),
        Err(e) => Err(error(ErrorCode::Internal, e, None)),
    }
}

/// Serve P, a `term/*` request on connection CONN.
pub async fn serve(t: &Terms, conn: u64, p: Params) -> Result<Value, Error> {
    match p {
        Params::TermOpen(p) => {
            let spawn = Spawn {
                cwd: p.dir,
                command: p.command.unwrap_or_default(),
                env: p.env,
                cols: p.cols,
                rows: p.rows,
                cell_px: p.cell_px,
                window: p.window.map_or(10_000, |w| w as usize),
                class: p.class,
                limits: Limits {
                    memory_max: p.memory_max,
                    tasks_max: p.tasks_max,
                },
                config: p.config.into_iter().map(|(k, v)| (k, v.into())).collect(),
            };
            let rec = t
                .spawn(conn, t.session_of(conn), spawn)
                .await
                .map_err(|e| error(ErrorCode::Internal, e, None))?;
            Ok(json!(TermOpened {
                id: rec.id,
                view: rec.view,
            }))
        }
        Params::TermConfig(p) => tell(
            t,
            &p.id,
            In::Config {
                config: p.config.into_iter().map(|(k, v)| (k, v.into())).collect(),
            },
        ),
        Params::TermKey(p) => tell(
            t,
            &p.id,
            In::Key {
                key: p.key,
                mods: p.mods,
                text: p.text.unwrap_or_default(),
                unshifted: p.unshifted.unwrap_or(0),
            },
        ),
        Params::TermText(p) => tell(t, &p.id, In::Text { text: p.text }),
        Params::TermPaste(p) => tell(t, &p.id, In::Paste { text: p.text }),
        Params::TermFocus(p) => tell(t, &p.id, In::Focus { gained: p.focus_in }),
        Params::TermMouse(p) => tell(
            t,
            &p.id,
            In::Mouse {
                kind: p.kind,
                button: p.button,
                col: p.col,
                row: p.row,
                mods: p.mods,
            },
        ),
        Params::TermResize(p) => tell(
            t,
            &p.id,
            In::Resize {
                cols: p.cols,
                rows: p.rows,
                cell_px: p.cell_px,
            },
        ),
        Params::TermScroll(p) => {
            answer(t, &p.id, |req| In::Scroll {
                req,
                from: p.from,
                delta: p.delta,
                prompt_delta: p.prompt_delta,
                to: p.to,
            })
            .await
        }
        Params::TermFetch(p) => {
            answer(t, &p.id, |req| In::Fetch {
                req,
                before_key: p.before_key,
                max_bytes: p.max_bytes.map(|b| b as usize),
            })
            .await
        }
        Params::TermSearch(p) => {
            answer(t, &p.id, |req| In::Search {
                req,
                query: p.query,
                dir: p.dir,
            })
            .await
        }
        Params::TermTextRange(p) => {
            answer(t, &p.id, |req| In::TextRange {
                req,
                from_key: p.from_key,
                to_key: p.to_key,
            })
            .await
        }
        Params::TermClose(p) => Ok(json!(t.send(&p.id, &In::Close { signal: p.signal }))),
        Params::TermList(_) => {
            let list: Vec<TermStatus> = t
                .list(LIST_WITHIN)
                .await
                .into_iter()
                .map(|s| TermStatus {
                    id: s.id,
                    pid: s.pid,
                    running: s.running,
                    cwd: s.cwd,
                    title: s.title,
                    old: s.old,
                })
                .collect();
            Ok(json!(list))
        }
        Params::TermSessionEnd(_) => {
            let n = match t.session_of(conn) {
                Some(s) => t.end_session(&s),
                None => 0,
            };
            Ok(json!(n))
        }
        _ => Err(error(ErrorCode::Internal, "not a term/ method", None)),
    }
}
