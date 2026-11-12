//! Probes (spec §19.2): a logpoint whose message carries a marker, so its output becomes a recorded hit and stays out
//! of the console. The hub sends `logMessage` = `"\u{1e}drgnx:<probe>:{<thread-expr>}:{<value-expr>}"`; DAP's
//! `output` event has no thread, so the thread is in the message where the language has an expression for it.
//!
//! - [`Probes`]: a project's probes (one table per root, saved like the breakpoints), with "Probe the result"
//!   ([`next_line`]: a logpoint fires before its line runs, so a probe of a name assigned on line N goes on the next
//!   executed line).
//! - [`Rate`]: the per-adapter rate cap and its thinning (none in forks). delve and lldb-dap stop, evaluate and resume
//!   at every hit, so their cap is lower and the lane says so ([`stops_to_probe`]).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::Duration;

/// What starts a probe's output.
pub const MARK: &str = "\u{1e}drgnx:";

/// The language family of an adapter's `type`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lang {
    Python,
    Js,
    Go,
    Native,
    Other,
}

/// The family of ADAPTER_ID (launch.json's `type`).
pub fn lang(adapter_id: &str) -> Lang {
    match adapter_id {
        "debugpy" | "python" => Lang::Python,
        "pwa-node" | "node" | "node-terminal" | "pwa-chrome" | "chrome" | "pwa-msedge" => Lang::Js,
        "go" => Lang::Go,
        "lldb-dap" | "lldb-vscode" | "lldb" | "cppdbg" | "codelldb" => Lang::Native,
        _ => Lang::Other,
    }
}

/// The expression for the current thread in ADAPTER_ID's language, or "" where there is none (the hit's thread is
/// then unknown).
pub fn thread_expr(adapter_id: &str) -> &'static str {
    match lang(adapter_id) {
        // the program may not import `threading`: reach it through `__import__`
        Lang::Python => "__import__('threading').get_ident()",
        _ => "",
    }
}

/// PROBE's marker message with THREAD_EXPR (may be empty) and EXPR, each interpolated by the adapter (`{…}`).
pub fn marker(probe: &str, thread_expr: &str, expr: &str) -> String {
    let thread = if thread_expr.is_empty() {
        String::new()
    } else {
        format!("{{{thread_expr}}}")
    };
    format!("{MARK}{probe}:{thread}:{{{expr}}}")
}

/// The `logMessage` of PROBE recording EXPR for ADAPTER_ID: Python's value is its `repr`, others the adapter's own
/// text of the value (js-debug's preview, delve's and lldb's summaries).
pub fn log_message(adapter_id: &str, probe: &str, expr: &str) -> String {
    let value = match lang(adapter_id) {
        Lang::Python => format!("repr({expr})"),
        _ => expr.to_owned(),
    };
    marker(probe, thread_expr(adapter_id), &value)
}

/// A probe's hit out of one line of output: (probe, thread, value); the thread is "" when the language has none.
pub fn parse(output: &str) -> Option<(String, String, String)> {
    let rest = output.strip_prefix(MARK)?;
    let rest = rest.strip_suffix('\n').unwrap_or(rest);
    let rest = rest.strip_suffix('\r').unwrap_or(rest);
    let (probe, rest) = rest.split_once(':')?;
    let (thread, value) = rest.split_once(':')?;
    if probe.is_empty()
        || !probe
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return None;
    }
    Some((probe.to_owned(), thread.to_owned(), value.to_owned()))
}

/// Every hit in an `output` event's text (an adapter may send several lines at once), and the text that is not a
/// hit (for the console; empty when every line was one).
pub fn split(output: &str) -> (Vec<(String, String, String)>, String) {
    if !output.contains(MARK) {
        return (vec![], output.to_owned());
    }
    let mut hits = vec![];
    let mut rest = String::new();
    for line in output.split_inclusive('\n') {
        match parse(line) {
            Some(h) => hits.push(h),
            None => rest.push_str(line),
        }
    }
    (hits, rest)
}

/// The rate cap of ADAPTER_ID's probes, hits a second.
pub fn cap(adapter_id: &str) -> u32 {
    if stops_to_probe(adapter_id) {
        200
    } else {
        2000
    }
}

/// Whether ADAPTER_ID runs a logpoint by stopping, evaluating and resuming (its timing changes the program).
pub fn stops_to_probe(adapter_id: &str) -> bool {
    matches!(lang(adapter_id), Lang::Go | Lang::Native)
}

/// A rate cap over one-second windows: hits above it are thinned (counted, not kept). A fork has none.
#[derive(Clone, Debug)]
pub struct Rate {
    cap: Option<u32>,
    window: Option<Duration>,
    n: u32,
    /// Hits thinned so far.
    pub thinned: u64,
}

impl Rate {
    /// A cap of CAP hits a second (`None`: every hit is kept, as in a fork).
    pub fn new(cap: Option<u32>) -> Rate {
        Rate {
            cap,
            window: None,
            n: 0,
            thinned: 0,
        }
    }

    /// Whether a hit at AT (time since the run started) is kept.
    pub fn admit(&mut self, at: Duration) -> bool {
        let Some(cap) = self.cap else { return true };
        let second = Duration::from_secs(at.as_secs());
        if self.window != Some(second) {
            self.window = Some(second);
            self.n = 0;
        }
        if self.n < cap {
            self.n += 1;
            true
        } else {
            self.thinned += 1;
            false
        }
    }
}

/// The line a probe of what line LINE (1-based) of TEXT assigns goes on: the next line that runs after it (past the
/// statement's continuation lines, blank lines and comments). None past the end.
pub fn next_line(text: &str, line: u32, lang: Lang) -> Option<u32> {
    let lines: Vec<&str> = text.lines().collect();
    let mut i = usize::try_from(line).ok()?.checked_sub(1)?;
    if i >= lines.len() {
        return None;
    }
    // the statement's own lines: until its brackets close and no line ends in a backslash
    let mut depth: i32 = 0;
    loop {
        let code = strip_comment(lines[i], lang);
        depth += bracket_delta(code);
        let cont = code.trim_end().ends_with('\\');
        if depth <= 0 && !cont {
            break;
        }
        i += 1;
        if i >= lines.len() {
            return None;
        }
    }
    for (j, l) in lines.iter().enumerate().skip(i + 1) {
        let code = strip_comment(l, lang).trim();
        if code.is_empty() || matches!(code, "}" | "};" | ")" | "end") {
            continue;
        }
        return u32::try_from(j + 1).ok();
    }
    None
}

/// LINE without its comment (outside strings).
fn strip_comment(line: &str, lang: Lang) -> &str {
    let mut quote: Option<char> = None;
    let mut prev = '\0';
    for (k, c) in line.char_indices() {
        match quote {
            Some(q) => {
                if c == q && prev != '\\' {
                    quote = None;
                }
            }
            None => match c {
                '"' | '\'' | '`' => quote = Some(c),
                '#' if lang == Lang::Python => return &line[..k],
                '/' if lang != Lang::Python && line[k..].starts_with("//") => return &line[..k],
                _ => {}
            },
        }
        prev = if prev == '\\' { '\0' } else { c };
    }
    line
}

/// Opening minus closing brackets in CODE (outside strings).
fn bracket_delta(code: &str) -> i32 {
    let mut quote: Option<char> = None;
    let mut prev = '\0';
    let mut d = 0;
    for c in code.chars() {
        match quote {
            Some(q) => {
                if c == q && prev != '\\' {
                    quote = None;
                }
            }
            None => match c {
                '"' | '\'' | '`' => quote = Some(c),
                '(' | '[' | '{' => d += 1,
                ')' | ']' | '}' => d -= 1,
                _ => {}
            },
        }
        prev = if prev == '\\' { '\0' } else { c };
    }
    d
}

/// One probe: where it runs and what it records.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Probe {
    /// `p<N>`: what its marker carries.
    pub id: String,
    pub path: String,
    pub line: u32,
    pub expr: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// The agent session that added it (D4: the editor rings it); none for the user's own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

fn yes() -> bool {
    true
}

/// A change to a project's probes.
#[derive(Clone, Debug, PartialEq)]
pub enum Op {
    /// A probe of EXPR on LINE.
    Add {
        path: String,
        line: u32,
        expr: String,
    },
    /// "Probe the result": a probe of EXPR (what LINE assigns) on the next line that runs after LINE, in TEXT (the
    /// file as the editor has it) of language LANG.
    Result {
        path: String,
        line: u32,
        expr: String,
        text: String,
        lang: Lang,
    },
    Remove {
        id: String,
    },
    Edit {
        id: String,
        expr: Option<String>,
        enabled: Option<bool>,
        line: Option<u32>,
    },
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Data {
    next: u64,
    probes: Vec<Probe>,
}

/// A project's probes, saved in a file (none: memory only).
pub struct Probes {
    file: Option<PathBuf>,
    data: Data,
}

impl Probes {
    pub fn open(file: Option<PathBuf>) -> Probes {
        let data = file
            .as_ref()
            .and_then(|f| std::fs::read_to_string(f).ok())
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Probes { file, data }
    }

    fn save(&self) {
        let Some(f) = &self.file else { return };
        if let Some(dir) = f.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let text = serde_json::to_string(&self.data).unwrap_or_default();
        if let Err(e) = crate::records::write_atomic(f, &text) {
            tracing::warn!(target: "drgnx::debug", "probes {}: {e}", f.display());
        }
    }

    /// Apply OP: the path whose probes changed and the probe it added, or why not.
    pub fn apply(&mut self, op: Op) -> Result<(String, Option<String>), String> {
        let out = match op {
            Op::Add { path, line, expr } => self.add(path, line, expr),
            Op::Result {
                path,
                line,
                expr,
                text,
                lang,
            } => {
                let at = next_line(&text, line, lang)
                    .ok_or_else(|| format!("no line runs after line {line}"))?;
                self.add(path, at, expr)
            }
            Op::Remove { id } => {
                let i = self.index(&id)?;
                let p = self.data.probes.remove(i);
                (p.path, None)
            }
            Op::Edit {
                id,
                expr,
                enabled,
                line,
            } => {
                let i = self.index(&id)?;
                let p = &mut self.data.probes[i];
                if let Some(e) = expr {
                    p.expr = e;
                }
                if let Some(e) = enabled {
                    p.enabled = e;
                }
                if let Some(l) = line.filter(|l| *l > 0) {
                    p.line = l;
                }
                (p.path.clone(), None)
            }
        };
        self.save();
        Ok(out)
    }

    fn add(&mut self, path: String, line: u32, expr: String) -> (String, Option<String>) {
        self.data.next += 1;
        let id = format!("p{}", self.data.next);
        self.data.probes.push(Probe {
            id: id.clone(),
            path: path.clone(),
            line,
            expr,
            enabled: true,
            agent: None,
        });
        (path, Some(id))
    }

    /// Probe ID is agent session AGENT's (D4).
    pub fn mark(&mut self, id: &str, agent: &str) -> Result<(), String> {
        let i = self.index(id)?;
        self.data.probes[i].agent = Some(agent.to_owned());
        self.save();
        Ok(())
    }

    fn index(&self, id: &str) -> Result<usize, String> {
        self.data
            .probes
            .iter()
            .position(|p| p.id == id)
            .ok_or_else(|| format!("no probe {id}"))
    }

    pub fn list(&self) -> &[Probe] {
        &self.data.probes
    }

    /// The paths with an enabled probe.
    pub fn paths(&self) -> Vec<String> {
        let mut v: Vec<String> = self
            .data
            .probes
            .iter()
            .filter(|p| p.enabled)
            .map(|p| p.path.clone())
            .collect();
        v.sort();
        v.dedup();
        v
    }

    /// PATH's enabled probes as `SourceBreakpoint`s for ADAPTER_ID, leaving out a line in TAKEN (a breakpoint of the
    /// user's is there: it wins). None when the adapter has no logpoints (CAPS).
    pub fn source_bps(
        &self,
        path: &str,
        adapter_id: &str,
        caps: &Value,
        taken: &[u32],
    ) -> Vec<Value> {
        if caps.get("supportsLogPoints").and_then(Value::as_bool) != Some(true) {
            return vec![];
        }
        let mut v: Vec<(u32, Value)> = self
            .data
            .probes
            .iter()
            .filter(|p| p.enabled && p.path == path && !taken.contains(&p.line))
            .map(|p| {
                (
                    p.line,
                    json!({"line": p.line, "logMessage": log_message(adapter_id, &p.id, &p.expr)}),
                )
            })
            .collect();
        v.sort_by_key(|(l, _)| *l);
        v.dedup_by_key(|(l, _)| *l);
        v.into_iter().map(|(_, b)| b).collect()
    }
}
