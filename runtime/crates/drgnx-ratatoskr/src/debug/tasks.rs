//! tasks.json (spec §9.2, tier 2): what a configuration's `preLaunchTask` runs before the session starts, and its
//! `postDebugTask` once the session has ended.
//!
//! - Read as launch.json is (JSONC), each task with its platform section merged over it.
//! - `shell` tasks run their command line in `/bin/sh -c` (each `args` item quoted for the shell), `process` tasks
//!   run `command` and `args` as the argument vector, never split. A task without `type` is a shell task.
//! - `dependsOn` (a label or a list) runs first, depth first in the order given, each task once; a cycle or an
//!   unknown label is an error naming it. `isBackground` tasks (watchers that never exit) are refused: drgnx would
//!   wait on them for ever.
//! - `${defaultBuildTask}` is the label of the task whose `group` is `{"kind": "build", "isDefault": true}`.
//! - The steps run one at a time; the first that fails stops the rest and the start, with its exit status and the
//!   end of its output.

use super::launch::{self, Os, ParseError};
use serde_json::Value;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// One task, ready to run.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    pub label: String,
    pub argv: Vec<String>,
    pub cwd: PathBuf,
    /// Added to the hub's environment (`options.env`).
    pub env: Vec<(String, String)>,
}

/// tasks.json's TEXT: its tasks.
pub fn parse(text: &str) -> Result<Vec<Value>, ParseError> {
    let v = launch::jsonc(text)?;
    Ok(match v.get("tasks") {
        Some(Value::Array(a)) => a.iter().filter(|t| t.is_object()).cloned().collect(),
        _ => vec![],
    })
}

fn label(t: &Value) -> Option<&str> {
    t.get("label").and_then(Value::as_str)
}

/// The label of TASKS' default build task, if one is marked.
pub fn default_build_task(tasks: &[Value]) -> Option<String> {
    tasks
        .iter()
        .find(|t| {
            t.get("group").is_some_and(|g| {
                g.get("kind").and_then(Value::as_str) == Some("build")
                    && g.get("isDefault").and_then(Value::as_bool) == Some(true)
            })
        })
        .and_then(label)
        .map(str::to_owned)
}

/// ARG as one word for `/bin/sh`.
fn quoted(arg: &str) -> String {
    let plain = !arg.is_empty()
        && arg
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_./:=@%+,-".contains(&b));
    if plain {
        arg.to_owned()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}

fn strings(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::String(s)) => vec![s.clone()],
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect(),
        _ => vec![],
    }
}

fn step(t: &Value, root: &Path) -> Result<Step, String> {
    let name = label(t).unwrap_or_default().to_owned();
    let command = t
        .get("command")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("task {name}: no command"))?;
    let args = strings(t.get("args"));
    let argv = match t.get("type").and_then(Value::as_str).unwrap_or("shell") {
        "process" => std::iter::once(command.to_owned()).chain(args).collect(),
        "shell" => {
            let line = std::iter::once(command.to_owned())
                .chain(args.iter().map(|a| quoted(a)))
                .collect::<Vec<_>>()
                .join(" ");
            vec!["/bin/sh".into(), "-c".into(), line]
        }
        other => return Err(format!("task {name}: type {other} is not shell or process")),
    };
    let options = t.get("options");
    let cwd = match options.and_then(|o| o.get("cwd")).and_then(Value::as_str) {
        Some(c) => root.join(c),
        None => root.to_path_buf(),
    };
    let env = options
        .and_then(|o| o.get("env"))
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                .collect()
        })
        .unwrap_or_default();
    Ok(Step {
        label: name,
        argv,
        cwd,
        env,
    })
}

/// The steps that run LABEL of TASKS on OS: its `dependsOn` first (see the module's doc). Relative working
/// directories are under the current directory; [`before_launch`] gives the root.
pub fn order(tasks: &[Value], label_: &str, os: Os) -> Result<Vec<Step>, String> {
    order_in(tasks, label_, os, Path::new(""))
}

fn order_in(tasks: &[Value], first: &str, os: Os, root: &Path) -> Result<Vec<Step>, String> {
    let tasks: Vec<Value> = tasks.iter().map(|t| launch::for_platform(t, os)).collect();
    let mut done: Vec<String> = vec![];
    let mut out = vec![];
    let mut path: Vec<String> = vec![];
    visit(&tasks, first, root, &mut path, &mut done, &mut out)?;
    Ok(out)
}

fn visit(
    tasks: &[Value],
    name: &str,
    root: &Path,
    path: &mut Vec<String>,
    done: &mut Vec<String>,
    out: &mut Vec<Step>,
) -> Result<(), String> {
    if done.iter().any(|d| d == name) {
        return Ok(());
    }
    if path.iter().any(|p| p == name) {
        let mut cycle = path.clone();
        cycle.push(name.to_owned());
        return Err(format!(
            "tasks.json: dependsOn goes round: {}",
            cycle.join(" → ")
        ));
    }
    let t = tasks
        .iter()
        .find(|t| label(t) == Some(name))
        .ok_or_else(|| format!("tasks.json has no task {name}"))?;
    if t.get("isBackground").and_then(Value::as_bool) == Some(true) {
        return Err(format!(
            "task {name} is isBackground (it never ends): drgnx runs only tasks that finish; start it yourself"
        ));
    }
    path.push(name.to_owned());
    for d in strings(t.get("dependsOn")) {
        visit(tasks, &d, root, path, done, out)?;
    }
    path.pop();
    out.push(step(t, root)?);
    done.push(name.to_owned());
    Ok(())
}

fn each_string(v: &Value, f: &dyn Fn(&str) -> Result<String, String>) -> Result<Value, String> {
    Ok(match v {
        Value::String(s) => Value::String(f(s)?),
        Value::Array(a) => Value::Array(
            a.iter()
                .map(|x| each_string(x, f))
                .collect::<Result<_, _>>()?,
        ),
        Value::Object(m) => Value::Object(
            m.iter()
                .map(|(k, x)| Ok((k.clone(), each_string(x, f)?)))
                .collect::<Result<_, String>>()?,
        ),
        v => v.clone(),
    })
}

/// The steps CONFIG's `preLaunchTask` runs, from ROOT's `.vscode/tasks.json`, each string through SUBST (the
/// variables, as in the configuration); none without a `preLaunchTask`.
pub fn before_launch(
    root: &Path,
    config: &Value,
    os: Os,
    subst: &dyn Fn(&str) -> Result<String, String>,
) -> Result<Vec<Step>, String> {
    steps_for("preLaunchTask", root, config, os, subst)
}

/// The steps CONFIG's `postDebugTask` runs once its session has ended, as [`before_launch`].
pub fn after_debug(
    root: &Path,
    config: &Value,
    os: Os,
    subst: &dyn Fn(&str) -> Result<String, String>,
) -> Result<Vec<Step>, String> {
    steps_for("postDebugTask", root, config, os, subst)
}

fn steps_for(
    field: &str,
    root: &Path,
    config: &Value,
    os: Os,
    subst: &dyn Fn(&str) -> Result<String, String>,
) -> Result<Vec<Step>, String> {
    let Some(name) = config.get(field).and_then(Value::as_str) else {
        return Ok(vec![]);
    };
    let path = root.join(".vscode/tasks.json");
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("{field} {name}: {}: {e}", path.display()))?;
    let tasks = parse(&text).map_err(|e| format!("{}:{e}", path.display()))?;
    let tasks = tasks
        .iter()
        .map(|t| each_string(t, subst))
        .collect::<Result<Vec<_>, _>>()?;
    order_in(&tasks, name, os, root)
}

/// The end of a task's output kept for its error.
const TAIL: usize = 2000;

/// Runs STEPS one after another with the hub's ENV plus each step's own; the first that fails is an error with its
/// exit status and the end of its output, and the rest do not run.
pub async fn run(steps: &[Step], env: &[(OsString, OsString)]) -> Result<(), String> {
    use tokio::io::AsyncReadExt;
    for s in steps {
        let (program, args) = s
            .argv
            .split_first()
            .ok_or_else(|| format!("task {}: an empty command", s.label))?;
        let mut all: Vec<(OsString, OsString)> = env
            .iter()
            .filter(|(k, _)| !s.env.iter().any(|(a, _)| k.as_os_str() == a.as_str()))
            .cloned()
            .collect();
        all.extend(s.env.iter().map(|(k, v)| (k.into(), v.into())));
        let mut child = draugr::spawn(draugr::Spec {
            program: PathBuf::from(program),
            args: args.iter().map(OsString::from).collect(),
            env: all,
            cwd: Some(s.cwd.clone()),
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        })
        .await
        .map_err(|e| format!("task {}: {program}: {e}", s.label))?;
        let mut out = child.take_stdout();
        let read = async {
            let mut tail = Vec::new();
            if let Some(o) = out.as_mut() {
                let mut buf = [0u8; 4096];
                while let Ok(n) = o.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    tail.extend_from_slice(&buf[..n]);
                    if tail.len() > TAIL {
                        tail.drain(..tail.len() - TAIL);
                    }
                }
            }
            tail
        };
        let (tail, status) = tokio::join!(read, child.wait());
        let status = status.map_err(|e| format!("task {}: {e}", s.label))?;
        let ok = status.is_some_and(|st| st.success());
        if !ok {
            let how = match status.and_then(|st| st.code()) {
                Some(c) => format!("exit {c}"),
                None => "killed".to_owned(),
            };
            let mut text = String::from_utf8_lossy(&tail).into_owned();
            text.push_str(&child.stderr_tail());
            return Err(format!(
                "task {} failed ({how}):\n{}",
                s.label,
                text.trim_end()
            ));
        }
    }
    Ok(())
}

/// [`run`] with each step in a terminal tab of connection CONN's editor (TERMS): the start waits for its exit 0; a
/// failing step's tab stays open, and the error carries its status and the end of its text.
/// A step's tab, in `sh -c TAB_WRAP drgnx-task ARGV…`: it waits for the hub's go (a line), runs ARGV, marks its end
/// with the status (OSC 133 `D`) and, when that is not 0, keeps the tab open until Enter.
const TAB_WRAP: &str = r#"IFS= read -r _; printf '\033]133;C\007'; "$@"; s=$?; printf '\033]133;D;%d\007' "$s"; if [ "$s" -ne 0 ]; then printf '\n%s' 'Enter closes this tab.'; IFS= read -r _; fi; exit "$s""#;

/// The wrapper's last line in a failed tab: not the task's output.
const TAB_CLOSE: &str = "Enter closes this tab.";

/// SHOW is told of each tab as it opens.
pub async fn run_in(
    steps: &[Step],
    terms: &dyn super::Terminals,
    conn: u64,
    show: &(dyn Fn(&Step, &super::Opened) + Send + Sync),
) -> Result<(), String> {
    for s in steps {
        let mut args: Vec<String> = vec![
            "/bin/sh".into(),
            "-c".into(),
            TAB_WRAP.into(),
            "drgnx-task".into(),
        ];
        args.extend(s.argv.iter().cloned());
        let cwd = s.cwd.to_string_lossy().into_owned();
        let o = terms
            .open(conn, cwd, args, s.env.clone())
            .await
            .map_err(|e| format!("task {}: {e}", s.label))?;
        show(s, &o);
        match terms.run_task(o.term.clone()).await {
            (Some(0), _) => {}
            (Some(c), text) => {
                let text = text.trim_end();
                let text = text.strip_suffix(TAB_CLOSE).unwrap_or(text).trim();
                let mut cut = text.len().saturating_sub(TAIL);
                while !text.is_char_boundary(cut) {
                    cut += 1;
                }
                return Err(format!(
                    "task {} failed (exit {c}):\n{}",
                    s.label,
                    &text[cut..]
                ));
            }
            (None, _) => {
                return Err(format!(
                    "task {}: its tab closed before the task ended",
                    s.label
                ));
            }
        }
    }
    Ok(())
}
