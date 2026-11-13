//! The `debug/fork*` methods and `debug/compare` (runstav `methods::debug_fork`): a fork's configuration is the run's
//! `debug/start`, resolved again now (inputs whose values were not kept are asked again, as `debug/start`'s `needs`),
//! then handed to the hub's [`Forks`].

use super::fork::{At, Change, RunEnd, Until, Watch};
use super::fork_hub::{Ask, Forks, Made, TraceTree};
use super::fork_seal::{DirTrees, Sealed, forks_root, slots_root};
use super::launch::{self, Os};
use super::record::RunInfo;
use super::wire::{config_of, need_json, table, tools_dir, vars};
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug::{DebugAnswer, DebugStart};
use runstav::methods::debug_fork::{
    DebugCompare, DebugFork, DebugForkId, DebugForkUntil, DebugForked,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

/// The hub's forks, made on first use.
pub(super) fn forks(front: &Front) -> &Forks {
    front.debug.forks.get_or_init(|| {
        let env = front.shell_env.paths_env();
        let path = front
            .shell_env
            .vars_os()
            .iter()
            .find(|(k, _)| k == "PATH")
            .map(|(_, v)| std::env::split_paths(v).collect())
            .unwrap_or_default();
        // the hub records every session (`Debug::record_into` when the debugger starts): forks are of those runs
        let runs = front
            .debug
            .debug(front)
            .records()
            .expect("the debugger records its sessions");
        Forks::new(
            front.editors.clone(),
            runs,
            Arc::new(DirTrees::new(forks_root(&env))),
            Arc::new(Sealed {
                env,
                path,
                tools: tools_dir(front),
            }),
            super::fork::SEALS_HERE,
        )
    })
}

fn at_of(p: &DebugFork) -> At {
    match (p.at.stop, &p.at.path) {
        (Some(s), _) => At::Stop(s),
        (None, path) => At::Hit {
            path: path.clone().unwrap_or_default(),
            line: p.at.line.unwrap_or(1),
            hit: p.at.hit.unwrap_or(1),
        },
    }
}

fn change_of(p: &DebugFork) -> Change {
    match &p.change {
        Some(c) if c.code => Change::Code,
        Some(c) => match &c.value {
            Some(v) => Change::Value {
                path: v.path.clone(),
                text: v.text.clone(),
            },
            None => Change::Nothing,
        },
        None => Change::Nothing,
    }
}

fn until_of(p: &DebugFork) -> Until {
    match &p.until {
        Some(DebugForkUntil::End(s)) if s == "exit" => Until::Exit,
        Some(DebugForkUntil::Probe { probe }) => Until::Probe(probe.clone()),
        _ => Until::NextStop,
    }
}

/// RUN's configuration resolved now, with ANSWERS; or what must be asked first.
fn resolve(
    front: &Front,
    run: &RunInfo,
    given: &[DebugAnswer],
) -> Result<Result<Value, DebugForked>, Error> {
    let mut start: DebugStart = serde_json::from_value(run.start.clone())
        .map_err(|e| err(format!("the run's start cannot be read: {e}")))?;
    if !given.is_empty() {
        start.inputs = given.to_vec();
    }
    if !front.debug.is_trusted(&start.root) {
        return Ok(Err(DebugForked {
            fork: None,
            ask: None,
            needs: Some(serde_json::json!("trust")),
        }));
    }
    let table = table(&start.adapters)?;
    let (config, inputs) = config_of(&start, &table)?;
    let config = launch::for_platform(&config, Os::this());
    let answers: HashMap<String, String> = start
        .inputs
        .iter()
        .map(|a| (a.id.clone(), a.value.clone()))
        .collect();
    let needs = launch::needs(&config, &inputs, &answers).map_err(err)?;
    if !needs.is_empty() {
        return Ok(Err(DebugForked {
            fork: None,
            ask: None,
            needs: Some(Value::Array(needs.iter().map(need_json).collect())),
        }));
    }
    launch::check_answers(&config, &inputs, &answers).map_err(err)?;
    launch::substitute(&config, &vars(front, &start), &answers)
        .map(Ok)
        .map_err(err)
}

async fn fork(front: &Front, p: DebugFork) -> Result<DebugForked, Error> {
    let f = forks(front);
    let run = f
        .recorded(&p.run)
        .ok_or_else(|| err(format!("no recorded run {}", p.run)))?;
    let resolved = match resolve(front, &run, &p.inputs)? {
        Ok(v) => v,
        Err(first) => return Ok(first),
    };
    let made = f
        .fork(Ask {
            run: p.run.clone(),
            at: at_of(&p),
            change: change_of(&p),
            until: until_of(&p),
            confirm: p.confirm,
            anyway: p.anyway,
            resolved,
        })
        .map_err(err)?;
    Ok(match made {
        Made::Fork(id) => DebugForked {
            fork: Some(id),
            ask: None,
            needs: None,
        },
        Made::Ask(q) => DebugForked {
            fork: None,
            ask: Some(q),
            needs: None,
        },
    })
}

/// RUN's configuration resolved now as `debug/fork` resolves it, for a use without the user (no inputs asked).
pub(super) fn resolved_for(front: &Front, run: &RunInfo) -> Result<Value, String> {
    match resolve(front, run, &[]).map_err(|e| e.message)? {
        Ok(v) => Ok(v),
        Err(first) if first.needs == Some(serde_json::json!("trust")) => {
            Err(format!("the project of run {} is not trusted", run.id))
        }
        Err(first) => {
            let ids: Vec<String> = first
                .needs
                .as_ref()
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|n| {
                    n.pointer("/input/id")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .or_else(|| Some(n.to_string()))
                })
                .collect();
            Err(format!("run {} needs input {}", run.id, ids.join(", ")))
        }
    }
}

/// Run RUN replayed to its stop STOP in a tree of its own and ended there (D3's origin trail): FILES (relative path,
/// bytes) written into the tree and ENV(the tree's absolute path) added to the environment before the launch. The tree
/// goes when the [`TraceTree`] does.
pub async fn trace<F>(
    front: Arc<Front>,
    run: String,
    stop: u64,
    env: F,
    files: Vec<(String, Vec<u8>)>,
) -> Result<TraceTree, String>
where
    F: FnOnce(&Path) -> Vec<(String, String)> + Send + 'static,
{
    let f = forks(&front);
    let info = f
        .recorded(&run)
        .ok_or_else(|| format!("no recorded run {run}"))?;
    let resolved = resolved_for(&front, &info)?;
    f.trace(&run, stop, resolved, env, files).await
}

/// Run RUN's configuration in TREE (one of D5's bisect slots: strictly under [`slots_root`], links resolved) to the
/// program's end, WATCH watched (paths relative to the project), LIMIT the time box (`timed_out`, not an error).
pub async fn run_in(
    front: Arc<Front>,
    run: String,
    tree: PathBuf,
    watch: Watch,
    limit: Duration,
) -> Result<RunEnd, String> {
    let tree = in_slots(&slots_root(&front.shell_env.paths_env()), &tree)?;
    let f = forks(&front);
    let info = f
        .recorded(&run)
        .ok_or_else(|| format!("no recorded run {run}"))?;
    let resolved = resolved_for(&front, &info)?;
    f.run_in(&run, resolved, tree, watch, limit).await
}

/// TREE, links resolved, when it is strictly under SLOTS (also resolved).
pub(super) fn in_slots(slots: &Path, tree: &Path) -> Result<PathBuf, String> {
    let refuse = || format!("{} is not a bisect slot of the hub's", tree.display());
    let slots = std::fs::canonicalize(slots).map_err(|_| refuse())?;
    let t = std::fs::canonicalize(tree).map_err(|_| refuse())?;
    if t != slots && t.starts_with(&slots) {
        Ok(t)
    } else {
        Err(refuse())
    }
}

fn answer<T: serde::Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.and_then(|v| serde_json::to_value(v).map_err(|e| err(e.to_string())))
}

/// The fork methods' answers (the front hands only these here).
pub async fn serve(front: &Front, params: Params) -> Result<Value, Error> {
    // a fork is of the run as recorded so far
    if let Some(r) = front.debug.debug(front).records() {
        r.written().await;
    }
    match params {
        Params::DebugFork(p) => answer(fork(front, p).await),
        Params::DebugForkRun(DebugForkId { fork }) => {
            answer(forks(front).resume(&fork).map(|()| true).map_err(err))
        }
        Params::DebugForkDrop(DebugForkId { fork }) => answer(
            forks(front)
                .drop_fork(&fork)
                .await
                .map(|()| true)
                .map_err(err),
        ),
        Params::DebugCompare(DebugCompare { run, fork }) => {
            answer(forks(front).compare(&run, &fork).map_err(err))
        }
        _ => Err(err("not a fork method")),
    }
}
