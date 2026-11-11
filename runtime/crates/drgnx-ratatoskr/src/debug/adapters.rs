//! The adapter table (spec §9.4): `etc/debug-adapters.eld`, read with huginn's reader as data only (strings, numbers,
//! symbols and lists; nothing is evaluated), maps a launch.json `type` to an adapter, says how to find it (a program
//! on `PATH`, a file in drgnx's tools folder, a Python module in the tools venv) and how to start it (stdio, or TCP on
//! a free port on 127.0.0.1 the hub picks).

use huginn::read::{Limits, read_all};
use serde::Deserialize;
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// The table drgnx ships.
pub const BUILTIN: &str = include_str!("../../../../../etc/debug-adapters.eld");

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Find {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub python_module: Option<String>,
    #[serde(default)]
    pub tools: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StartHow {
    #[serde(default)]
    pub stdio: Option<Vec<String>>,
    #[serde(default)]
    pub tcp: Option<Vec<String>>,
}

/// One adapter.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Adapter {
    pub id: String,
    pub name: String,
    pub types: Vec<String>,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub tested: bool,
    #[serde(default)]
    pub find: Option<Find>,
    #[serde(default)]
    pub start: Option<StartHow>,
    #[serde(default)]
    pub defaults: Vec<Value>,
    #[serde(default)]
    pub install: Option<Value>,
    #[serde(default)]
    pub not_built_in: bool,
}

/// The table.
#[derive(Clone, Debug, PartialEq)]
pub struct Table(pub Vec<Adapter>);

impl Table {
    /// The table in BYTES (an `.eld` list of plists).
    pub fn read(bytes: &[u8]) -> Result<Table, String> {
        let nodes =
            read_all(bytes, Limits::default()).map_err(|r| format!("the adapter table: {r:?}"))?;
        let [node] = nodes.as_slice() else {
            return Err("the adapter table: one list of adapters".into());
        };
        let list: Vec<Adapter> =
            huginn::de::from_node(node).map_err(|e| format!("the adapter table: {e}"))?;
        Ok(Table(list))
    }

    /// drgnx's own table.
    pub fn builtin() -> Table {
        Table::read(BUILTIN.as_bytes()).expect("etc/debug-adapters.eld reads")
    }

    pub fn by_id(&self, id: &str) -> Option<&Adapter> {
        self.0.iter().find(|a| a.id == id)
    }

    /// The adapter for the launch.json type TY; an unknown or not built-in type says what to do.
    pub fn for_type(&self, ty: &str) -> Result<&Adapter, String> {
        match self.0.iter().find(|a| a.types.iter().any(|t| t == ty)) {
            Some(a) if a.not_built_in => Err(format!(
                "the debug type \"{ty}\" ({}) is not built in: add its adapter in the setting debug.adapters",
                a.name
            )),
            Some(a) => Ok(a),
            None => {
                let known: Vec<&str> = self
                    .0
                    .iter()
                    .filter(|a| !a.not_built_in)
                    .flat_map(|a| a.types.iter().map(String::as_str))
                    .collect();
                Err(format!(
                    "no debug adapter for the type \"{ty}\"; drgnx knows {} (debugpy among them); add one in the setting debug.adapters",
                    known.join(", ")
                ))
            }
        }
    }

    /// The default configurations for a file of LANGUAGE.
    pub fn defaults_for(&self, language: &str) -> Vec<Value> {
        self.0
            .iter()
            .filter(|a| a.languages.iter().any(|l| l == language))
            .flat_map(|a| a.defaults.iter().cloned())
            .collect()
    }
}

/// Where adapters are looked for.
#[derive(Clone, Debug, Default)]
pub struct Env {
    /// `PATH`, in order.
    pub path: Vec<PathBuf>,
    /// drgnx's tools folder (its venv is `venv/`).
    pub tools: PathBuf,
}

/// What finding an adapter gave.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Found {
    /// A program or script (`{program}`).
    Program(PathBuf),
    /// The Python that has the adapter's module (`{python}`).
    Python(PathBuf),
}

fn executable(p: &Path) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Where ADAPTER is, or `None` when it is not installed.
pub fn find(adapter: &Adapter, env: &Env) -> Option<Found> {
    let f = adapter.find.as_ref()?;
    if let Some(prog) = &f.path {
        return env
            .path
            .iter()
            .map(|d| d.join(prog))
            .find(|p| executable(p))
            .map(Found::Program);
    }
    if let Some(rel) = &f.tools {
        let p = env.tools.join(rel);
        return p.is_file().then_some(Found::Program(p));
    }
    if let Some(module) = &f.python_module {
        let py = env.tools.join("venv/bin/python3");
        if !executable(&py) {
            return None;
        }
        let lib = std::fs::read_dir(env.tools.join("venv/lib")).ok()?;
        let has = lib
            .flatten()
            .any(|d| d.path().join("site-packages").join(module).is_dir());
        return has.then_some(Found::Python(py));
    }
    None
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    Stdio,
    Tcp,
}

/// ADAPTER's command line, with `{program}`, `{python}`, `{tools}` and `{port}` filled in (a TCP adapter needs PORT).
pub fn command(
    adapter: &Adapter,
    found: &Found,
    env: &Env,
    port: Option<u16>,
) -> Result<(Transport, Vec<String>), String> {
    let start = adapter
        .start
        .as_ref()
        .ok_or_else(|| format!("{}: no way to start it", adapter.id))?;
    let (how, argv) = match (&start.stdio, &start.tcp) {
        (Some(a), _) => (Transport::Stdio, a),
        (None, Some(a)) => (Transport::Tcp, a),
        (None, None) => return Err(format!("{}: no way to start it", adapter.id)),
    };
    if how == Transport::Tcp && port.is_none() {
        return Err(format!("{}: a TCP adapter needs a port", adapter.id));
    }
    let (program, python) = match found {
        Found::Program(p) => (p.display().to_string(), "python3".to_owned()),
        Found::Python(p) => (p.display().to_string(), p.display().to_string()),
    };
    let tools = env.tools.display().to_string();
    let port = port.map(|p| p.to_string()).unwrap_or_default();
    let argv = argv
        .iter()
        .map(|a| {
            a.replace("{program}", &program)
                .replace("{python}", &python)
                .replace("{tools}", &tools)
                .replace("{port}", &port)
        })
        .collect();
    Ok((how, argv))
}

/// A free port on 127.0.0.1 (the hub's pick for a TCP adapter; another local process could take it before the
/// adapter does, which the debugging guide documents).
pub fn free_port() -> std::io::Result<u16> {
    Ok(std::net::TcpListener::bind(("127.0.0.1", 0))?
        .local_addr()?
        .port())
}
