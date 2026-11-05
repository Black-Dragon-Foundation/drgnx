//! The MCP `search` tool (runtime design §5.8): a session's `search.sock` serves it, outside the sandbox and pinned to the
//! job's root, and `ratatoskr search mcp [ROOT]` serves it on stdio for an agent outside drgnx. The tool is the
//! front's `search/query` with the root fixed: the agent names no path, so it cannot ask about another project.
//!
//! - **Arguments:** `query` (a question or a name), `scope` (`code` by default, `tests`, `docs`, `all`), `k` (1 to 50,
//!   10 by default).
//! - **The text answer** lists each hit as `path:first-last  symbol  [routes]` with a few lines of the chunk, and ends
//!   with the lag line, e.g. "vectors: 12 files behind (…); keyword and symbol results are current".

use super::methods::wire_answer;
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
}

/// The hub in this process.
pub struct HubBackend(pub Weak<Front>);

impl Backend for HubBackend {
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
                .query(&front, root, text, scope, k.unwrap_or(10))
                .await
                .map(|a| wire_answer(&a))
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

/// The tools of a search socket: `search` alone.
pub fn tools() -> Arc<[Box<dyn Tool<SearchCtx>>]> {
    let list: Vec<Box<dyn Tool<SearchCtx>>> = vec![Box::new(Search)];
    list.into()
}
