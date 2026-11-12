//! The `debug/fork*` methods and `debug/compare` (runstav `methods::debug_fork`): a fork's configuration is the run's
//! `debug/start`, resolved again now (inputs whose values were not kept are asked again, as `debug/start`'s `needs`),
//! then handed to the hub's [`Forks`].

use super::fork::{At, Change, Until};
use super::fork_hub::{Ask, Forks, Made};
use super::fork_run::{RunInfo, Runs};
use super::fork_seal::{DirTrees, Sealed};
use super::launch::{self, Os};
use super::wire::{config_of, need_json, table, tools_dir, vars};
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::debug::DebugStart;
use runstav::methods::debug_fork::{
    DebugCompare, DebugFork, DebugForkId, DebugForkUntil, DebugForked,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;

/// The recorded runs forks are made of, until the recorder's store is wired in: none.
struct NoRuns;

impl Runs for NoRuns {
    fn run(&self, _: &str) -> Option<RunInfo> {
        None
    }
}

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
        Forks::new(
            front.editors.clone(),
            Arc::new(NoRuns),
            Arc::new(DirTrees::new(
                crate::sandbox::runs_root(&env).join("debug-forks"),
            )),
            Arc::new(Sealed {
                env,
                path,
                tools: tools_dir(front),
            }),
            cfg!(target_os = "linux"),
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
    p: &DebugFork,
) -> Result<Result<Value, DebugForked>, Error> {
    let mut start: DebugStart = serde_json::from_value(run.start.clone())
        .map_err(|e| err(format!("the run's start cannot be read: {e}")))?;
    if !p.inputs.is_empty() {
        start.inputs = p.inputs.clone();
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
    let resolved = match resolve(front, &run, &p)? {
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

fn answer<T: serde::Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.and_then(|v| serde_json::to_value(v).map_err(|e| err(e.to_string())))
}

/// The fork methods' answers (the front hands only these here).
pub async fn serve(front: &Front, params: Params) -> Result<Value, Error> {
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
