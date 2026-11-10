//! The MCP search tools (runtime design §5.8): a session's `search.sock` serves them, outside the sandbox and pinned to
//! the job's root, and `ratatoskr search mcp [ROOT]` serves them on stdio for an agent outside drgnx. Each tool is a
//! front method with the root fixed: the agent names no root, so it cannot ask about another project, and the paths it
//! names are relative and stay inside it. `search` is `search/query`; `symbols` and `outline` are `search/symbols` and
//! `search/outline`, which answer from the index alone.
//!
//! - **Arguments:** `query` (a question or a name), `scope` (`code` by default, `tests`, `docs`, `all`), `k` (1 to 50,
//!   10 by default).
//! - **The text answer** lists each hit as `path:first-last  symbol  [routes]` with a few lines of the chunk, and ends
//!   with the lag line, e.g. "vectors: 12 files behind (…); keyword and symbol results are current".

use crate::front::Front;
use mimir::{ArgsError, BoxFuture, Tool, ToolResult};
use runstav::methods::search as w;
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};

/// Where a question goes: the hub itself, or (for `search mcp`) the hub's socket.
pub trait Backend: Send + Sync {
    fn query<'a>(
        &'a self,
        root: &'a Path,
        text: &'a str,
        scope: Option<w::Scope>,
        k: Option<u32>,
    ) -> BoxFuture<'a, Result<w::QueryAnswer, String>>;

    /// A structural question: the hub method METHOD (`search/symbols`, `search/outline`) with PARAMS, which name the
    /// pinned root; its answer as data.
    fn call<'a>(
        &'a self,
        method: &'static str,
        params: Value,
    ) -> BoxFuture<'a, Result<Value, String>>;
}

/// The hub in this process.
pub struct HubBackend(pub Weak<Front>);

impl HubBackend {
    async fn structural(&self, method: &str, params: Value) -> Result<Value, String> {
        let front = self.0.upgrade().ok_or("the hub is ending")?;
        let s = &front.search;
        let answer = match method {
            "search/symbols" => {
                let p = serde_json::from_value(params).map_err(|e| e.to_string())?;
                s.symbols(&front, p).await.map(|a| json!(a))
            }
            "search/outline" => {
                let p = serde_json::from_value(params).map_err(|e| e.to_string())?;
                s.outline(&front, p).await.map(|a| json!(a))
            }
            other => return Err(format!("no tool method {other}")),
        };
        answer.map_err(|e| match e.path {
            Some(p) => format!("{p}: {}", e.message),
            None => e.message,
        })
    }
}

impl Backend for HubBackend {
    fn call<'a>(
        &'a self,
        method: &'static str,
        params: Value,
    ) -> BoxFuture<'a, Result<Value, String>> {
        Box::pin(self.structural(method, params))
    }

    fn query<'a>(
        &'a self,
        root: &'a Path,
        text: &'a str,
        scope: Option<w::Scope>,
        k: Option<u32>,
    ) -> BoxFuture<'a, Result<w::QueryAnswer, String>> {
        Box::pin(async move {
            let front = self.0.upgrade().ok_or("the hub is ending")?;
            let scope = match scope {
                Some(w::Scope::Tests) => hrafn::Scope::Tests,
                Some(w::Scope::Docs) => hrafn::Scope::Docs,
                Some(w::Scope::All) => hrafn::Scope::All,
                _ => hrafn::Scope::Code,
            };
            front
                .search
                .query(&front, root, text, scope, k.unwrap_or(10), false)
                .await
                .map_err(|e| e.message)
        })
    }
}

/// What the tool runs with: the root it is pinned to, and where its questions go.
pub struct SearchCtx {
    pub root: PathBuf,
    pub backend: Arc<dyn Backend>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    query: String,
    #[serde(default)]
    scope: Option<w::Scope>,
    #[serde(default)]
    k: Option<u32>,
}

fn decode(args: &Value) -> Result<Args, ArgsError> {
    let a: Args = serde_path_to_error::deserialize(args).map_err(|e| {
        let path = e.path().to_string();
        ArgsError {
            path: if path == "." {
                "arguments".to_string()
            } else {
                path
            },
            message: e.into_inner().to_string(),
        }
    })?;
    if a.query.trim().is_empty() || a.query.len() > 2000 {
        return Err(ArgsError {
            path: "query".into(),
            message: "a question of 1 to 2000 characters".into(),
        });
    }
    if a.k.is_some_and(|k| !(1..=50).contains(&k)) {
        return Err(ArgsError {
            path: "k".into(),
            message: "1 to 50".into(),
        });
    }
    Ok(a)
}

/// The tool's text answer.
pub fn render(a: &w::QueryAnswer) -> String {
    let mut out = String::new();
    if a.hits.is_empty() {
        out.push_str("no results\n");
    }
    for h in &a.hits {
        out.push_str(&format!(
            "{}:{}-{}{}  [{}]{}\n",
            h.path,
            h.line_start,
            h.line_end,
            h.symbol
                .as_ref()
                .map_or(String::new(), |s| format!("  {s}")),
            h.routes.join(", "),
            if h.reanchored { "  (moved)" } else { "" }
        ));
        for line in h.preview.lines().take(4) {
            out.push_str("    ");
            out.push_str(line);
            out.push('\n');
        }
    }
    out.push('\n');
    out.push_str(&a.lag_line);
    out.push('\n');
    out
}

struct Search;

impl Tool<SearchCtx> for Search {
    fn name(&self) -> &'static str {
        "search"
    }

    fn description(&self) -> &'static str {
        "Search this project's code with a question or a name: keyword, symbol, path and vector results, ranked together. \
         The answer ends with what lags (vectors that are behind); keyword and symbol results are always current."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "a question, or the name of a function, macro or variable"},
                "scope": {"type": "string", "enum": ["code", "tests", "docs", "all"], "description": "which files; code by default (tests rank below it)"},
                "k": {"type": "integer", "minimum": 1, "maximum": 50, "description": "how many results; 10 by default"}
            },
            "required": ["query"],
            "additionalProperties": false
        })
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        decode(args).map(drop)
    }

    fn call<'a>(&'a self, ctx: &'a SearchCtx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let a = match decode(&args) {
                Ok(a) => a,
                Err(e) => return ToolResult::Err(e.to_string()),
            };
            match ctx.backend.query(&ctx.root, &a.query, a.scope, a.k).await {
                Ok(answer) => ToolResult::Ok {
                    text: render(&answer),
                    structured: serde_json::to_value(&answer).ok(),
                },
                Err(e) => ToolResult::Err(e),
            }
        })
    }
}

/// The last line of a structural answer: which view answered and whether tier 1 has files still to index.
pub fn fresh_line(f: &w::Fresh) -> String {
    let view = match &f.view.worktree {
        Some(_) => format!(
            "worktree: {} files differ from the base; ",
            f.view.differing_files
        ),
        None => String::new(),
    };
    let index = match f.files_pending {
        0 => "index: current".to_string(),
        n => format!("index: {n} files waiting to be indexed"),
    };
    format!("{view}{index}")
}

/// `search/symbols`' text answer: a head line when the match was not exact, then each definition's place, kind,
/// name, the definition around it and its doc line, with its signature below.
pub fn render_symbols(a: &w::SymbolsAnswer) -> String {
    let mut out = String::new();
    if a.matched != w::NameMatch::Exact {
        let m = serde_json::to_value(a.matched)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        out.push_str(&format!("matched: {m}\n"));
    }
    if a.symbols.is_empty() {
        out.push_str("no definitions\n");
    }
    for s in &a.symbols {
        out.push_str(&format!(
            "{}:{}-{}  {}  {}{}{}\n",
            s.path,
            s.line_start,
            s.line_end,
            s.kind,
            s.name,
            s.container
                .as_ref()
                .map_or(String::new(), |c| format!("  in {c}")),
            s.doc1
                .as_ref()
                .map_or(String::new(), |d| format!("  — {d}"))
        ));
        if !s.sig.is_empty() {
            out.push_str(&format!("    {}\n", s.sig));
        }
    }
    out.push('\n');
    out.push_str(&fresh_line(&a.fresh));
    out.push('\n');
    out
}

/// `search/outline`'s text answer: the path and language, then a line per definition, indented by its depth.
pub fn render_outline(a: &w::OutlineAnswer) -> String {
    let mut out = format!("{} ({})\n", a.path, a.lang);
    if a.entries.is_empty() {
        out.push_str("no definitions\n");
    }
    for e in &a.entries {
        out.push_str(&format!(
            "{}{}-{}  {}  {}{}\n",
            "  ".repeat(e.depth as usize),
            e.line_start,
            e.line_end,
            e.kind,
            if e.sig.is_empty() { &e.name } else { &e.sig },
            e.doc1
                .as_ref()
                .map_or(String::new(), |d| format!("  — {d}"))
        ));
    }
    out.push('\n');
    out.push_str(&fresh_line(&a.fresh));
    out.push('\n');
    out
}

fn arg_err(path: &str, message: &str) -> ArgsError {
    ArgsError {
        path: path.into(),
        message: message.into(),
    }
}

fn decode_as<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, ArgsError> {
    serde_path_to_error::deserialize(args).map_err(|e| {
        let path = e.path().to_string();
        ArgsError {
            path: if path == "." {
                "arguments".to_string()
            } else {
                path
            },
            message: e.into_inner().to_string(),
        }
    })
}

/// A relative path inside the root: no leading `/`, no `..` part, 1 to 500 characters.
fn rel_ok(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= 500
        && !p.starts_with('/')
        && !p.contains('\0')
        && !p.split('/').any(|c| c == "..")
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SymbolsArgs {
    name: String,
    #[serde(default, rename = "match")]
    mode: Option<w::NameMatch>,
    #[serde(default)]
    kind: Option<Vec<String>>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    scope: Option<w::Scope>,
    #[serde(default)]
    k: Option<u32>,
}

fn decode_symbols(args: &Value) -> Result<SymbolsArgs, ArgsError> {
    let a: SymbolsArgs = decode_as(args)?;
    if a.name.trim().is_empty() || a.name.chars().count() > 200 {
        return Err(arg_err("name", "a name of 1 to 200 characters"));
    }
    if a.k.is_some_and(|k| !(1..=100).contains(&k)) {
        return Err(arg_err("k", "1 to 100"));
    }
    if a.kind.as_ref().is_some_and(|k| k.len() > 12) {
        return Err(arg_err("kind", "at most 12 kinds"));
    }
    if a.path.as_deref().is_some_and(|p| !rel_ok(p)) {
        return Err(arg_err(
            "path",
            "a glob relative to the project, inside it (no leading /, no ..)",
        ));
    }
    Ok(a)
}

struct Symbols;

impl Tool<SearchCtx> for Symbols {
    fn name(&self) -> &'static str {
        "symbols"
    }

    fn description(&self) -> &'static str {
        "Find where names are defined in this project: functions, types, macros, variables, methods. Faster and \
         exacter than search for a known name. Each answer gives the place, kind, signature and first doc line."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "name": {"type": "string", "minLength": 1, "maxLength": 200, "description": "a name, a prefix, part of a name, or a regular expression (see match)"},
                "match": {"type": "string", "enum": ["auto", "exact", "prefix", "contains", "regex"], "description": "auto (default): exact, else prefix, else contains; the answer says which matched"},
                "kind": {"type": "array", "items": {"type": "string"}, "maxItems": 12, "description": "only these kinds, e.g. function, method, struct, class, macro, variable"},
                "path": {"type": "string", "maxLength": 500, "description": "only files matching this glob, relative to the project"},
                "scope": {"type": "string", "enum": ["code", "tests", "docs", "all"], "description": "all by default; tests are listed after code"},
                "k": {"type": "integer", "minimum": 1, "maximum": 100, "description": "how many; 20 by default"}
            },
            "required": ["name"],
            "additionalProperties": false
        })
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        decode_symbols(args).map(drop)
    }

    fn call<'a>(&'a self, ctx: &'a SearchCtx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let a = match decode_symbols(&args) {
                Ok(a) => a,
                Err(e) => return ToolResult::Err(e.to_string()),
            };
            let mut params = json!({"root": ctx.root, "name": a.name});
            for (key, v) in [
                ("match", json!(a.mode)),
                ("kind", json!(a.kind)),
                ("path", json!(a.path)),
                ("scope", json!(a.scope)),
                ("k", json!(a.k)),
            ] {
                if !v.is_null() {
                    params[key] = v;
                }
            }
            match ctx.backend.call("search/symbols", params).await {
                Ok(v) => match serde_json::from_value::<w::SymbolsAnswer>(v.clone()) {
                    Ok(answer) => ToolResult::Ok {
                        text: render_symbols(&answer),
                        structured: Some(v),
                    },
                    Err(e) => ToolResult::Err(e.to_string()),
                },
                Err(e) => ToolResult::Err(e),
            }
        })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OutlineArgs {
    path: String,
    #[serde(default)]
    docs: Option<bool>,
}

fn decode_outline(args: &Value) -> Result<OutlineArgs, ArgsError> {
    let a: OutlineArgs = decode_as(args)?;
    if !rel_ok(&a.path) {
        return Err(arg_err(
            "path",
            "a file of this project, relative to its root (no leading /, no ..)",
        ));
    }
    Ok(a)
}

struct OutlineTool;

impl Tool<SearchCtx> for OutlineTool {
    fn name(&self) -> &'static str {
        "outline"
    }

    fn description(&self) -> &'static str {
        "The definitions in one file, in order, with their line ranges and nesting (methods under their class or \
         impl). Cheaper than reading the file."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": {"type": "string", "minLength": 1, "maxLength": 500, "description": "a file of this project, relative to its root"},
                "docs": {"type": "boolean", "description": "add each definition's first doc line; true by default"}
            },
            "required": ["path"],
            "additionalProperties": false
        })
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        decode_outline(args).map(drop)
    }

    fn call<'a>(&'a self, ctx: &'a SearchCtx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let a = match decode_outline(&args) {
                Ok(a) => a,
                Err(e) => return ToolResult::Err(e.to_string()),
            };
            let params = json!({"root": ctx.root, "path": a.path, "docs": a.docs.unwrap_or(true)});
            match ctx.backend.call("search/outline", params).await {
                Ok(v) => match serde_json::from_value::<w::OutlineAnswer>(v.clone()) {
                    Ok(answer) => ToolResult::Ok {
                        text: render_outline(&answer),
                        structured: Some(v),
                    },
                    Err(e) => ToolResult::Err(e.to_string()),
                },
                Err(e) => ToolResult::Err(e),
            }
        })
    }
}

/// The tools of a search socket: `search`, `symbols` and `outline`.
pub fn tools() -> Arc<[Box<dyn Tool<SearchCtx>>]> {
    let list: Vec<Box<dyn Tool<SearchCtx>>> =
        vec![Box::new(Search), Box::new(Symbols), Box::new(OutlineTool)];
    list.into()
}
