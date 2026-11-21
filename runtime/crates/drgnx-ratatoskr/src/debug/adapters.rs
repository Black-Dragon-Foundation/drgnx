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
    /// An adapter inside a language server ([`super::lsp_command`]).
    #[serde(default)]
    pub lsp_command: Option<skald::manifest::LspCommand>,
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

impl From<&skald::manifest::Adapter> for Adapter {
    fn from(a: &skald::manifest::Adapter) -> Adapter {
        Adapter {
            id: a.id.clone(),
            name: a.name.clone(),
            types: a.types.clone(),
            languages: a.languages.clone(),
            tested: a.tested,
            find: a.find.as_ref().map(|f| Find {
                path: f.path.clone(),
                python_module: f.python_module.clone(),
                tools: f.tools.clone(),
            }),
            start: a.start.as_ref().map(|s| StartHow {
                stdio: s.stdio.clone(),
                tcp: s.tcp.clone(),
                lsp_command: s.lsp_command.clone(),
            }),
            defaults: a.defaults.clone(),
            install: a.install.as_ref().map(skald::manifest::Install::to_json),
            not_built_in: a.not_built_in,
        }
    }
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

    /// drgnx's own table: the adapters of `etc/debug-adapters.eld` (the ones no pack owns), then those of the
    /// built-in packs.
    pub fn builtin() -> Table {
        let mut t = Table::read(BUILTIN.as_bytes()).expect("etc/debug-adapters.eld reads");
        for m in skald::builtin::manifests() {
            t = t.with_pack(m);
        }
        t
    }

    /// This table and the adapters PACK's manifest names (an installed pack's, or a fixture's): a launch type another
    /// entry serves stays with the first.
    pub fn with_pack(mut self, pack: &skald::Manifest) -> Table {
        for a in &pack.adapters {
            if !a
                .types
                .iter()
                .any(|t| self.0.iter().any(|x| x.types.contains(t)))
                && self.by_id(&a.id).is_none()
            {
                self.0.push(Adapter::from(a));
            }
        }
        self
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
        (None, None) if start.lsp_command.is_some() => {
            return Err(format!(
                "{}: started through its language server, not a command line",
                adapter.id
            ));
        }
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

/// One download an adapter needs and what is installed of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PartStatus {
    /// The folder under the tools folder (`jdk`, `jdtls`, `java-debug`).
    pub part: String,
    /// The version the table pins.
    pub pinned: Option<String>,
    /// The version installed: none when the part is not there.
    pub installed: Option<String>,
}

/// The downloads of ADAPTER's `:install` (its `:parts`, or the one archive), each with the version pinned and the one
/// installed under TOOLS (`.drgnx-installed`, written by the install; `unknown` for a folder from an older install).
pub fn parts(adapter: &Adapter, tools: &Path) -> Vec<PartStatus> {
    let Some(install) = &adapter.install else {
        return Vec::new();
    };
    let one = |v: &Value| -> Option<PartStatus> {
        let part = v.get("into")?.as_str()?.to_owned();
        let installed = tools.join(&part).is_dir().then(|| {
            std::fs::read_to_string(tools.join(&part).join(super::install::INSTALLED_MARKER))
                .ok()
                .and_then(|t| t.lines().next().map(str::to_owned))
                .unwrap_or_else(|| "unknown".into())
        });
        Some(PartStatus {
            part,
            pinned: v.get("version").and_then(Value::as_str).map(str::to_owned),
            installed,
        })
    };
    match install.get("parts").and_then(Value::as_array) {
        Some(list) => list.iter().filter_map(one).collect(),
        None => one(install).into_iter().collect(),
    }
}

/// A free port on 127.0.0.1 (the hub's pick for a TCP adapter; another local process could take it before the
/// adapter does: the hub connects only to the adapter's own listener, `wire::Spawned`).
pub fn free_port() -> std::io::Result<u16> {
    Ok(std::net::TcpListener::bind(("127.0.0.1", 0))?
        .local_addr()?
        .port())
}

#[cfg(test)]
mod pack_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// The adapters the table had before the language ones moved into the packs.
    const OLD_IDS: &[&str] = &[
        "debugpy",
        "js-debug",
        "delve",
        "lldb-dap",
        "gdb",
        "bash-debug",
        "rdbg",
        "netcoredbg",
        "cpptools",
        "codelldb",
        "java",
        "flutter",
        "godot",
        "xdebug",
        "ocamlearlybird",
    ];

    #[test]
    fn the_table_holds_every_adapter_it_held_before_the_packs() {
        let table = Table::builtin();
        let mut ids: Vec<&str> = table.0.iter().map(|a| a.id.as_str()).collect();
        ids.sort_unstable();
        let mut old = OLD_IDS.to_vec();
        old.sort_unstable();
        assert_eq!(ids, old);
        // the language ones come from their packs, the rest from the file
        for (id, pack) in [
            ("debugpy", "python"),
            ("js-debug", "javascript"),
            ("delve", "go"),
            ("xdebug", "php"),
            ("java", "java"),
            ("netcoredbg", "csharp"),
        ] {
            let m = skald::builtin::get(pack).unwrap();
            assert!(
                m.adapters.iter().any(|a| a.id == id),
                "{id} is in the {pack} pack"
            );
            assert!(
                !BUILTIN.contains(&format!(":id \"{id}\"")),
                "{id} left etc/debug-adapters.eld"
            );
        }
        // what the picker and the installer read is unchanged
        let debugpy = table.by_id("debugpy").unwrap();
        assert_eq!(debugpy.types, ["debugpy", "python"]);
        assert_eq!(debugpy.install.as_ref().unwrap()["pip"], "debugpy==1.8.22");
        assert!(
            debugpy.install.as_ref().unwrap()["hash"]
                .as_str()
                .unwrap()
                .starts_with("sha256:")
        );
        let js = table.by_id("js-debug").unwrap();
        assert_eq!(js.install.as_ref().unwrap()["root"], "js-debug");
        assert_eq!(table.defaults_for("go").len(), 1);
    }

    const FIXTURE: &str = r#"(:pack "fixturelang" :schema 1 :version "1" :name "Fixture" :summary "s" :license "MIT"
 :adapters ((:id "fixture-dap" :name "Fixture (dap)" :types ("fixturedbg") :languages ("fixturelang")
             :find (:path "fixture-dap") :start (:stdio ("{program}" "--dap")))
            (:id "stolen" :name "Stolen" :types ("python") :find (:path "x") :start (:stdio ("x")))))"#;

    #[test]
    fn an_adapter_only_in_a_fixture_pack_is_found_and_started() {
        let pack = skald::read(FIXTURE.as_bytes()).unwrap();
        let table = Table::builtin().with_pack(&pack);
        // a launch type another entry serves stays with the first
        assert!(table.by_id("stolen").is_none());
        assert_eq!(table.for_type("python").unwrap().id, "debugpy");
        let adapter = table.for_type("fixturedbg").unwrap();
        assert_eq!(adapter.id, "fixture-dap");
        let dir = std::env::temp_dir().join(format!("fixture-dap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let prog = dir.join("fixture-dap");
        std::fs::write(&prog, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&prog, std::fs::Permissions::from_mode(0o755)).unwrap();
        let env = Env {
            path: vec![dir.clone()],
            tools: dir.join("tools"),
        };
        let found = find(adapter, &env).expect("found on PATH");
        assert_eq!(found, Found::Program(prog.clone()));
        let (how, argv) = command(adapter, &found, &env, None).unwrap();
        assert_eq!(
            (how, argv),
            (
                Transport::Stdio,
                vec![prog.display().to_string(), "--dap".to_string()]
            )
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
