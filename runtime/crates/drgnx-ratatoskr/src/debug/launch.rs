//! launch.json (spec §9.2): read as JSONC (comments and trailing commas, nothing looser), listed in the picker's order,
//! a platform section merged over its base, and VS Code's `${…}` variables substituted in two passes.
//!
//! - **Pass one** ([`needs`]) finds what must be asked first: `${input:id}` (its `promptString` / `pickString`
//!   declaration) and `${command:pickProcess}`. The editor asks in the palette and calls again with the answers.
//! - **Pass two** ([`substitute`]) replaces every variable in every string, left to right, in one scan: what a
//!   variable gives (an answer, an environment value) is never read for variables again, and a string is never split
//!   (an `args` item stays one argument). An unknown variable, setting or folder is an error that names it.
//!
//! Paths are given by their true names (symlinks resolved), as VS Code does.

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};

/// launch.json's parts drgnx reads.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LaunchFile {
    pub configs: Vec<Value>,
    pub inputs: Vec<Value>,
    pub compounds: Vec<Value>,
}

/// A syntax error, where it is (1-based).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub line: usize,
    pub col: usize,
    pub message: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}: {}", self.line, self.col, self.message)
    }
}

/// Read launch.json's TEXT.
pub fn parse(text: &str) -> Result<LaunchFile, ParseError> {
    let opts = jsonc_parser::ParseOptions {
        allow_comments: true,
        allow_trailing_commas: true,
        allow_loose_object_property_names: false,
        allow_missing_commas: false,
        allow_single_quoted_strings: false,
        allow_hexadecimal_numbers: false,
        allow_unary_plus_numbers: false,
        allow_bare_decimal_point_numbers: false,
        allow_extended_string_escapes: false,
        allow_non_finite_numbers: false,
    };
    let v: Value = jsonc_parser::parse_to_serde_value(text, &opts).map_err(|e| ParseError {
        line: e.line_display(),
        col: e.column_display(),
        message: e.kind().to_string(),
    })?;
    let Value::Object(top) = v else {
        return Err(ParseError {
            line: 1,
            col: 1,
            message: "launch.json is not an object".into(),
        });
    };
    let list = |k: &str| match top.get(k) {
        Some(Value::Array(a)) => a.iter().filter(|c| c.is_object()).cloned().collect(),
        _ => vec![],
    };
    Ok(LaunchFile {
        configs: list("configurations"),
        inputs: list("inputs"),
        compounds: list("compounds"),
    })
}

/// The configs the picker shows, as indices into CONFIGS: by `presentation.group`, then `order` (none: last), then
/// the file's order; `hidden` ones left out.
pub fn listed(configs: &[Value]) -> Vec<usize> {
    let mut v: Vec<(String, i64, usize)> = configs
        .iter()
        .enumerate()
        .filter(|(_, c)| c.pointer("/presentation/hidden").and_then(Value::as_bool) != Some(true))
        .map(|(i, c)| {
            let group = c
                .pointer("/presentation/group")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let order = c
                .pointer("/presentation/order")
                .and_then(Value::as_i64)
                .unwrap_or(i64::MAX);
            (group, order, i)
        })
        .collect();
    v.sort();
    v.into_iter().map(|(_, _, i)| i).collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Linux,
    Macos,
    Windows,
}

impl Os {
    pub fn this() -> Os {
        if cfg!(target_os = "macos") {
            Os::Macos
        } else {
            Os::Linux
        }
    }
    fn key(self) -> &'static str {
        match self {
            Os::Linux => "linux",
            Os::Macos => "osx",
            Os::Windows => "windows",
        }
    }
}

/// CONFIG with its section for OS merged over it (objects such as `env` key by key) and every platform section
/// removed.
pub fn for_platform(config: &Value, os: Os) -> Value {
    let Some(base) = config.as_object() else {
        return config.clone();
    };
    let mut out: Map<String, Value> = base
        .iter()
        .filter(|(k, _)| !matches!(k.as_str(), "linux" | "osx" | "windows"))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    if let Some(Value::Object(sec)) = base.get(os.key()) {
        for (k, v) in sec {
            match (out.get_mut(k), v) {
                (Some(Value::Object(have)), Value::Object(add)) => {
                    for (k2, v2) in add {
                        have.insert(k2.clone(), v2.clone());
                    }
                }
                _ => {
                    out.insert(k.clone(), v.clone());
                }
            }
        }
    }
    Value::Object(out)
}

/// What the editor knows at Start, for the variables.
#[derive(Clone, Debug, Default)]
pub struct Vars {
    /// The workspace's folders, by name; the first is `${workspaceFolder}`.
    pub roots: Vec<(String, PathBuf)>,
    pub file: Option<PathBuf>,
    pub line: Option<u32>,
    pub col: Option<u32>,
    pub selection: Option<String>,
    pub home: PathBuf,
    pub exec_path: PathBuf,
    pub default_build_task: Option<String>,
    /// The environment `${env:…}` reads.
    pub env: HashMap<String, String>,
    /// drgnx's settings `${config:…}` reads, by drgnx name.
    pub config: HashMap<String, Value>,
}

/// VS Code's setting names that mean a drgnx setting.
pub const CONFIG_NAMES: &[(&str, &str)] = &[
    ("python.defaultInterpreterPath", "debug-python-interpreter"),
    ("python.pythonPath", "debug-python-interpreter"),
    ("go.alternateTools.dlv", "debug-dlv-program"),
    ("lldb.executable", "debug-lldb-program"),
];

/// Something to ask before a start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Need {
    /// `${input:id}`: `promptString` (with `password`) or `pickString` (with `options`).
    Input {
        id: String,
        kind: String,
        description: String,
        default: Option<String>,
        options: Vec<String>,
        password: bool,
    },
    /// `${command:pickProcess}`: a process of this user; its answer is under `pickProcess`.
    PickProcess,
}

/// The `${…}` names in every string of V, in order.
fn names(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::String(s) => {
            let mut rest = s.as_str();
            while let Some(i) = rest.find("${") {
                let after = &rest[i + 2..];
                let Some(j) = after.find('}') else { break };
                out.push(after[..j].to_owned());
                rest = &after[j + 1..];
            }
        }
        Value::Array(a) => a.iter().for_each(|x| names(x, out)),
        Value::Object(m) => m.values().for_each(|x| names(x, out)),
        _ => {}
    }
}

fn input_decl<'a>(inputs: &'a [Value], id: &str) -> Option<&'a Value> {
    inputs
        .iter()
        .find(|i| i.get("id").and_then(Value::as_str) == Some(id))
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_owned)
}

/// Pass one: what CONFIG needs that ANSWERS lack, each once, in order. An input with no declaration is an error.
pub fn needs(
    config: &Value,
    inputs: &[Value],
    answers: &HashMap<String, String>,
) -> Result<Vec<Need>, String> {
    let mut all = vec![];
    names(config, &mut all);
    let mut out: Vec<Need> = vec![];
    for n in all {
        if let Some(id) = n.strip_prefix("input:") {
            let d = input_decl(inputs, id)
                .ok_or_else(|| format!("${{input:{id}}}: no input \"{id}\" in launch.json"))?;
            let need = Need::Input {
                id: id.to_owned(),
                kind: s(d, "type").unwrap_or_else(|| "promptString".into()),
                description: s(d, "description").unwrap_or_default(),
                default: s(d, "default"),
                options: d
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(|o| o.as_str().map(str::to_owned).or_else(|| s(o, "value")))
                            .collect()
                    })
                    .unwrap_or_default(),
                password: d.get("password").and_then(Value::as_bool).unwrap_or(false),
            };
            if !answers.contains_key(id) && !out.contains(&need) {
                out.push(need);
            }
        } else if matches!(n.as_str(), "command:pickProcess" | "command:PickProcess")
            && !answers.contains_key("pickProcess")
            && !out.contains(&Need::PickProcess)
        {
            out.push(Need::PickProcess);
        }
    }
    Ok(out)
}

/// ANSWERS against CONFIG's inputs: a `pickString` answer must be one of its options.
pub fn check_answers(
    config: &Value,
    inputs: &[Value],
    answers: &HashMap<String, String>,
) -> Result<(), String> {
    for n in needs(config, inputs, &HashMap::new())? {
        if let Need::Input {
            id, kind, options, ..
        } = n
            && kind == "pickString"
            && let Some(a) = answers.get(&id)
            && !options.contains(a)
        {
            return Err(format!(
                "{a} is not one of {id}'s options ({})",
                options.join(", ")
            ));
        }
    }
    Ok(())
}

fn true_name(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

fn base(p: &Path) -> String {
    p.file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn show(p: &Path) -> String {
    p.display().to_string()
}

impl Vars {
    fn root(&self) -> Result<PathBuf, String> {
        self.roots
            .first()
            .map(|(_, p)| true_name(p))
            .ok_or_else(|| "no workspace folder".to_owned())
    }

    fn file(&self, name: &str) -> Result<PathBuf, String> {
        self.file
            .as_deref()
            .map(true_name)
            .ok_or_else(|| format!("${{{name}}} needs a file: no file is current"))
    }

    /// The root that holds the current file (else the first).
    fn file_root(&self) -> Result<PathBuf, String> {
        let f = self.file("fileWorkspaceFolder")?;
        self.roots
            .iter()
            .map(|(_, p)| true_name(p))
            .find(|r| f.starts_with(r))
            .map_or_else(|| self.root(), Ok)
    }

    /// The value of the variable NAME (`${NAME}`).
    fn value(&self, name: &str, answers: &HashMap<String, String>) -> Result<String, String> {
        if let Some(id) = name.strip_prefix("input:") {
            return answers
                .get(id)
                .cloned()
                .ok_or_else(|| format!("${{input:{id}}} was not answered"));
        }
        if let Some(cmd) = name.strip_prefix("command:") {
            return match cmd {
                "pickProcess" | "PickProcess" => answers
                    .get("pickProcess")
                    .cloned()
                    .ok_or_else(|| "no process was picked".to_owned()),
                _ => Err(format!(
                    "${{command:{cmd}}}: drgnx runs no VS Code command but pickProcess"
                )),
            };
        }
        if let Some(var) = name.strip_prefix("env:") {
            return Ok(self.env.get(var).cloned().unwrap_or_default());
        }
        if let Some(key) = name.strip_prefix("config:") {
            let drgnx = CONFIG_NAMES
                .iter()
                .find(|(v, _)| *v == key)
                .map_or(key, |(_, d)| *d);
            return match self.config.get(drgnx) {
                Some(Value::String(s)) => Ok(s.clone()),
                Some(v) => Ok(v.to_string()),
                None => Err(format!(
                    "${{config:{key}}}: no drgnx setting by that name (known VS Code names: {})",
                    CONFIG_NAMES
                        .iter()
                        .map(|(v, _)| *v)
                        .collect::<Vec<_>>()
                        .join(", ")
                )),
            };
        }
        if let Some(folder) = name.strip_prefix("workspaceFolder:") {
            return self
                .roots
                .iter()
                .find(|(n, _)| n == folder)
                .map(|(_, p)| show(&true_name(p)))
                .ok_or_else(|| {
                    format!("${{workspaceFolder:{folder}}}: no workspace folder named {folder}")
                });
        }
        let rel = |f: &Path, r: &Path| {
            f.strip_prefix(r)
                .map(Path::to_path_buf)
                .unwrap_or_else(|_| f.to_path_buf())
        };
        Ok(match name {
            "workspaceFolder" | "workspaceRoot" | "cwd" => show(&self.root()?),
            "workspaceFolderBasename" => base(&self.root()?),
            "file" => show(&self.file(name)?),
            "fileWorkspaceFolder" => show(&self.file_root()?),
            "relativeFile" => show(&rel(&self.file(name)?, &self.file_root()?)),
            "relativeFileDirname" => {
                let f = self.file(name)?;
                show(&rel(f.parent().unwrap_or(&f), &self.file_root()?))
            }
            "fileBasename" => base(&self.file(name)?),
            "fileBasenameNoExtension" => {
                let f = self.file(name)?;
                f.file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default()
            }
            "fileExtname" => {
                let f = self.file(name)?;
                f.extension()
                    .map(|e| format!(".{}", e.to_string_lossy()))
                    .unwrap_or_default()
            }
            "fileDirname" => {
                let f = self.file(name)?;
                show(f.parent().unwrap_or(&f))
            }
            "fileDirnameBasename" => {
                let f = self.file(name)?;
                base(f.parent().unwrap_or(&f))
            }
            "lineNumber" => self
                .line
                .map(|l| l.to_string())
                .ok_or("${lineNumber}: no line is current")?,
            "columnNumber" => self
                .col
                .map(|c| c.to_string())
                .ok_or("${columnNumber}: no column is current")?,
            "selectedText" => self.selection.clone().unwrap_or_default(),
            "execPath" => show(&self.exec_path),
            "pathSeparator" | "/" => "/".to_owned(),
            "userHome" => show(&self.home),
            "defaultBuildTask" => self
                .default_build_task
                .clone()
                .ok_or("${defaultBuildTask}: tasks.json has no default build task")?,
            _ => return Err(format!("${{{name}}} is not a variable drgnx knows")),
        })
    }
}

/// Pass two: CONFIG with every variable replaced (see the module's doc).
pub fn substitute(
    config: &Value,
    vars: &Vars,
    answers: &HashMap<String, String>,
) -> Result<Value, String> {
    Ok(match config {
        Value::String(text) => {
            let mut out = String::with_capacity(text.len());
            let mut rest = text.as_str();
            while let Some(i) = rest.find("${") {
                let after = &rest[i + 2..];
                let Some(j) = after.find('}') else { break };
                out.push_str(&rest[..i]);
                out.push_str(&vars.value(&after[..j], answers)?);
                rest = &after[j + 1..];
            }
            out.push_str(rest);
            Value::String(out)
        }
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| substitute(x, vars, answers))
                .collect::<Result<_, _>>()?,
        ),
        Value::Object(m) => Value::Object(
            m.iter()
                .map(|(k, v)| Ok((k.clone(), substitute(v, vars, answers)?)))
                .collect::<Result<_, String>>()?,
        ),
        v => v.clone(),
    })
}

/// `debugServer`: a port on this machine (a number, or `localhost:N` / `127.0.0.1:N`); other hosts are refused.
pub fn debug_server(config: &Value) -> Result<Option<SocketAddr>, String> {
    let port = match config.get("debugServer") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Number(n)) => n.as_u64(),
        Some(Value::String(s)) => {
            let (host, port) = s.rsplit_once(':').unwrap_or(("localhost", s.as_str()));
            if !matches!(host, "localhost" | "127.0.0.1" | "[::1]" | "::1") {
                return Err(format!(
                    "debugServer {s}: drgnx connects to this machine only, not {host}"
                ));
            }
            port.parse().ok()
        }
        Some(v) => return Err(format!("debugServer {v}: a port number")),
    };
    match port {
        Some(p) if (1..=65535).contains(&p) => {
            Ok(Some(SocketAddr::from((Ipv4Addr::LOCALHOST, p as u16))))
        }
        _ => Err("debugServer: a port from 1 to 65535".into()),
    }
}

/// The fields drgnx reads itself, which the adapter never sees.
pub const DRGNX_FIELDS: &[&str] = &[
    "presentation",
    "preLaunchTask",
    "postDebugTask",
    "debugServer",
    "internalConsoleOptions",
    "serverReadyAction",
];

/// CONFIG as the adapter's `launch` / `attach` arguments: everything but [`DRGNX_FIELDS`].
pub fn adapter_arguments(config: &Value) -> Value {
    match config {
        Value::Object(m) => Value::Object(
            m.iter()
                .filter(|(k, _)| !DRGNX_FIELDS.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        ),
        v => v.clone(),
    }
}
