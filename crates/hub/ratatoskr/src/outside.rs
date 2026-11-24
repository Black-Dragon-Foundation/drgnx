//! Outside agents in the matrix (`docs/develop/coordination.md`, "Agents outside drgnx"): the user's bindings
//! (`outside/bind`, `outside/unbind`, `outside/bindings`), the table of attached bridges every gate and scope lookup
//! asks ([`Bound`]), and who an outside caller is ([`who_for`]).
//!
//! An outside caller inside the hub is `Caller { class: Agent, sid: Some("ext:KIND:PID-HASH") }`.  The hub mints
//! session ids as `s-…`, so the `ext:` prefix names an outside agent, and it is honoured only through [`Bound`]: an
//! `ext:` id no attached bridge holds is refused, never read as a worker.  Its role is the user's binding for its kind
//! and root read again at every call ([`norn::bindings::role_for`]); the role read at `mcp/attach` only picks the tool
//! list.

use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::matrix_gate::ActionCtx;
use crate::runner::effects::Scope;
use norn::bindings;
use norn::matrix::Who;
use norn::store::{CoordError, Tx};
use norn::tools::Identity;
use runstav::methods::Empty;
use runstav::methods::outside::{BindParams, BindingRow, Bindings, UnbindParams};
use runstav::registry::Class;
use runstav::wire::{Error, ErrorCode};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// The methods an outside actor reaches through the tools' `Hub::exec` (every other is refused there).
pub(crate) const OUTSIDE_METHODS: [&str; 4] =
    ["plans/get", "plans/write", "records/read", "records/write"];

/// The refusal of an outside caller with no live binding (or no attached bridge).
pub(crate) const NOT_BOUND: &str = "this outside agent is not bound here";

/// Whether SID names an outside agent (`ext:KIND:PID-HASH`): only ever honoured through [`Bound`].
pub(crate) fn is_ext(sid: &str) -> bool {
    sid.starts_with("ext:")
}

fn refuse(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: msg.into(),
        path: None,
    }
}

fn invalid(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: msg.into(),
        path: Some("root".into()),
    }
}

fn internal(msg: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: msg.into(),
        path: None,
    }
}

/// An attached outside bridge: its id, kind, the project's top-level its folder is in, that project's id, the folder
/// its hello named and the bridge's own process (the connection's peer), whose working directory must be that folder
/// ([`folder_check`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutsideActor {
    pub id: String,
    pub kind: String,
    pub root: PathBuf,
    pub project: Option<String>,
    pub home: PathBuf,
    pub peer: i32,
}

#[derive(Default)]
struct Bridges {
    /// Agent id → its attached bridges, oldest first, each with its guard's ticket.
    by_id: HashMap<String, Vec<(u64, OutsideActor)>>,
    next: u64,
}

type Table = Arc<Mutex<Bridges>>;

/// The outside bridges attached now, by id (one agent may run several bridges).
#[derive(Default)]
pub struct Bound {
    live: Table,
}

/// One bridge's place in [`Bound`]: its drop detaches it.
pub struct BoundGuard {
    live: Table,
    id: String,
    ticket: u64,
}

impl Drop for BoundGuard {
    fn drop(&mut self) {
        let mut live = self.live.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(list) = live.by_id.get_mut(&self.id) {
            list.retain(|(t, _)| *t != self.ticket);
            if list.is_empty() {
                live.by_id.remove(&self.id);
            }
        }
    }
}

impl Bound {
    /// A attaches (the latest bridge still attached is the agent's); the guard detaches it.
    pub fn attach(&self, a: OutsideActor) -> BoundGuard {
        let id = a.id.clone();
        let mut live = self.live.lock().unwrap_or_else(|e| e.into_inner());
        live.next += 1;
        let ticket = live.next;
        live.by_id.entry(id.clone()).or_default().push((ticket, a));
        BoundGuard {
            live: self.live.clone(),
            id,
            ticket,
        }
    }

    /// The attached bridge ID (its latest one still attached), if one is.
    pub fn get(&self, id: &str) -> Option<OutsideActor> {
        self.live
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .by_id
            .get(id)
            .and_then(|l| l.last())
            .map(|(_, a)| a.clone())
    }
}

/// Whether the bridge process PEER works in HOME, the folder its hello named (both as truenames): `Err` names both
/// folders.  Where the system cannot tell a process's folder (`Unsupported`), the claimed folder is kept.
pub(crate) fn folder_check(peer: i32, home: &Path) -> Result<(), String> {
    let real = match crate::peer::cwd_of(peer) {
        Ok(p) => p,
        Err(e) if e.kind() == std::io::ErrorKind::Unsupported => return Ok(()),
        Err(e) => {
            return Err(format!(
                "this outside agent's bridge (pid {peer}) has no folder the hub can read ({e}); its hello named {}",
                home.display()
            ));
        }
    };
    // a folder that is gone (or a deleted one, `/proc`'s " (deleted)") has no truename: compared as it is, it differs
    let truename = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    let (claimed, actual) = (truename(home), truename(&real));
    if claimed == actual {
        Ok(())
    } else {
        Err(format!(
            "this outside agent's bridge works in {}, not in {}, the folder its hello named: start the bridge in the \
             project's folder",
            actual.display(),
            claimed.display()
        ))
    }
}

/// What `mcp/attach` hands the connection on with: the identity (its role as the binding says now) and its place in
/// [`Bound`] for the connection's life.
pub struct Attached {
    pub who: Identity,
    pub guard: Option<BoundGuard>,
}

/// The binding's role for KIND in ROOT, read now.
async fn role_now(f: &Front, kind: &str, root: &Path) -> Result<Option<norn::matrix::Role>, Error> {
    let (kind, root) = (kind.to_owned(), root.to_path_buf());
    f.writer
        .db
        .read(move |c| Ok(bindings::role_for(c, &kind, &root)?))
        .await
        .map_err(fail)
}

/// An outside bridge WHO attaches over a connection whose peer is the bridge process PEER: its folder's project (a
/// worktree's main repository) and the role the user bound there.  A bridge in no project has no role and no place
/// in [`Bound`]; one whose process does not work in the folder its hello named has no role ([`folder_check`]; every
/// later call is refused with both folders named).
pub(crate) async fn attach(f: &Front, who: Identity, peer: i32) -> Attached {
    let (Some(id), Some(kind), Some(home)) = (who.id(), who.outside_kind(), who.home()) else {
        return Attached { who, guard: None };
    };
    let in_folder = match folder_check(peer, home) {
        Ok(()) => true,
        Err(why) => {
            tracing::warn!(identity = id, "an outside agent's folder: {why}");
            false
        }
    };
    let found = match crate::graph::project_of(home).await {
        Ok(Some(p)) => p,
        Ok(None) => return Attached { who, guard: None },
        Err(e) => {
            tracing::warn!(identity = id, "an outside agent's project: {e}");
            return Attached { who, guard: None };
        }
    };
    let actor = OutsideActor {
        id: id.to_owned(),
        kind: kind.to_owned(),
        root: found.root,
        project: Some(found.id),
        home: home.to_path_buf(),
        peer,
    };
    let role = match role_now(f, &actor.kind, &actor.root).await {
        Ok(r) => r.filter(|_| in_folder),
        Err(e) => {
            tracing::warn!(identity = id, "an outside agent's binding: {}", e.message);
            None
        }
    };
    let guard = f.core.outside.attach(actor);
    Attached {
        who: who.with_role(role),
        guard: Some(guard),
    }
}

/// The attached outside actor SID with its role as the binding says now: refused when no bridge holds SID, its
/// bridge no longer works in the folder its hello named ([`folder_check`]), or the user's binding for its kind and
/// root is gone.
pub(crate) async fn actor_for(
    f: &Front,
    sid: &str,
) -> Result<(OutsideActor, norn::matrix::Role), Error> {
    let a = f.core.outside.get(sid).ok_or_else(|| refuse(NOT_BOUND))?;
    folder_check(a.peer, &a.home).map_err(refuse)?;
    let role = role_now(f, &a.kind, &a.root)
        .await?
        .ok_or_else(|| refuse(NOT_BOUND))?;
    Ok((a, role))
}

/// Who caller C is to the matrix, and what it acts in.  A session: its columns (the worker column when the hub does
/// not hold it) and its run's plan and project.  An outside agent (`ext:`): only through [`Bound`] and the binding
/// read now; its role's column and `Agent("ext:KIND")`, its project, no plan.
pub(crate) async fn who_for(f: &Front, c: &Caller) -> Result<(Who, ActionCtx), Error> {
    match c.sid.as_deref() {
        Some(sid) if is_ext(sid) => {
            let (a, role) = actor_for(f, sid).await?;
            Ok((
                Who {
                    role: Some(role),
                    agent: Some(format!("ext:{}", a.kind)),
                    provider: None,
                },
                ActionCtx {
                    project: a.project,
                    session: Some(sid.to_owned()),
                    own_record: false,
                    ..ActionCtx::default()
                },
            ))
        }
        Some(sid) => Ok((
            f.core.agents.who(sid).unwrap_or(Who {
                role: Some(norn::matrix::Role::Worker),
                ..Who::default()
            }),
            ActionCtx::of_session(&f.core.runs.scopes(), sid),
        )),
        None => Ok((
            Who {
                role: Some(norn::matrix::Role::Worker),
                ..Who::default()
            },
            ActionCtx::default(),
        )),
    }
}

/// An outside actor SID's scope: its project's records (and those of no project it wrote itself), after the binding
/// is read again.
pub(crate) async fn scope_of(f: &Front, sid: &str) -> Result<Scope, Error> {
    let (a, _) = actor_for(f, sid).await?;
    Ok(Scope::Project {
        id: a.project,
        root: Some(a.root),
        jobs: Vec::new(),
        sessions: vec![sid.to_owned()],
    })
}

/// Whether ACTOR created every entity of NS (its `created_tx`'s actor), so a change to them is a change to its own
/// record.
pub(crate) fn own_record(conn: &Tx, ns: &[i64], actor: &str) -> Result<bool, CoordError> {
    // an id that is its pid alone (`ext:KIND:PID`, no start time) is another process's once the pid is reused: it
    // owns nothing
    let pid_alone = actor
        .rsplit(':')
        .next()
        .is_none_or(|tag| !tag.contains('-'));
    if ns.is_empty() || pid_alone {
        return Ok(false);
    }
    for n in ns {
        let by: Option<String> = conn
            .query_row(
                "select t.actor from entity e join tx t on t.id = e.created_tx where e.n = ?1",
                [n],
                |r| r.get(0),
            )
            .ok();
        if by.as_deref() != Some(actor) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn row(b: bindings::Binding) -> BindingRow {
    BindingRow {
        id: b.id,
        kind: b.kind,
        root: b.root.to_string_lossy().into_owned(),
        role: b.role,
        at: b.at,
    }
}

fn users_only(c: &Caller) -> Result<(), Error> {
    if c.class == Class::User {
        Ok(())
    } else {
        Err(refuse(bindings::BINDINGS_ARE_THE_USERS))
    }
}

/// `$HOME` as a truename.
fn home_dir() -> Option<PathBuf> {
    std::env::var_os(stig::HOME_VAR)
        .filter(|h| !h.is_empty())
        .and_then(|h| std::fs::canonicalize(h).ok())
}

/// `outside/bind`.
pub async fn bind(f: &Front, c: &Caller, p: BindParams) -> Result<BindingRow, Error> {
    bind_in(f, c, p, home_dir()).await
}

/// `outside/bind` with HOME for the home folder: ROOT's project top-level (a worktree's main repository) is bound;
/// a folder in no repository, the home folder and `/` are refused.
pub(crate) async fn bind_in(
    f: &Front,
    c: &Caller,
    p: BindParams,
    home: Option<PathBuf>,
) -> Result<BindingRow, Error> {
    users_only(c)?;
    let not_home = |r: &Path| {
        if r == Path::new("/") || home.as_deref() == Some(r) {
            Err(invalid(
                "a binding names a project's folder, never the home folder or /",
            ))
        } else {
            Ok(())
        }
    };
    let given = PathBuf::from(p.root.as_str());
    not_home(&given)?;
    let at =
        std::fs::canonicalize(&given).map_err(|e| invalid(format!("{}: {e}", given.display())))?;
    not_home(&at)?;
    let found = crate::graph::project_of(&at)
        .await
        .map_err(internal)?
        .ok_or_else(|| {
            invalid(format!(
                "{} is in no git repository: a binding names a project's folder",
                at.display()
            ))
        })?;
    not_home(&found.root)?;
    let (kind, top, role) = (p.kind.as_str().to_owned(), found.root, p.role);
    f.writer
        .write(c, "outside/bind", move |tx| {
            let b = bindings::bind(tx, &kind, &top, role)?;
            // a binding entity another writer once touched never counts (`role_for`): say so, and write nothing
            if bindings::role_for(tx.sql(), &kind, &top)? != Some(role) {
                return Err(CoordError::Refused(format!(
                    "{} was written by someone other than you and never counts: graph excise it, then bind again",
                    b.id
                )));
            }
            Ok(b)
        })
        .await
        .map(row)
        .map_err(fail)
}

/// `outside/unbind`: the binding's agents' next call has no role.
pub async fn unbind(f: &Front, c: &Caller, p: UnbindParams) -> Result<bool, Error> {
    users_only(c)?;
    let id = p.id.as_str().to_owned();
    f.writer
        .write(c, "outside/unbind", move |tx| {
            Ok(bindings::unbind(tx, &id)?)
        })
        .await
        .map_err(fail)
}

/// `outside/bindings`.
pub async fn list(f: &Front, c: &Caller, _: Empty) -> Result<Bindings, Error> {
    users_only(c)?;
    let rows = f
        .writer
        .db
        .read(|c| Ok(bindings::list(c)?))
        .await
        .map_err(fail)?;
    Ok(Bindings {
        bindings: rows.into_iter().map(row).collect(),
    })
}

#[cfg(test)]
mod tests;
