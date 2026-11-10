//! `ratatoskr search …`: Hrafn from a terminal and for agents outside drgnx. A user client of the running hub (`ensure`d
//! first), so the checks are the hub's. `bin/drgnx search` runs it with the same arguments.
//!
//! - `search index ROOT [--rebuild] [--now]`: `search/index`.
//! - `search query ROOT QUESTION… [-k N] [--scope code|tests|docs|all] [--json]`: `search/query`, printed as the MCP
//!   tool prints it, or as the method's answer with `--json`.
//! - `search symbols ROOT NAME [--match auto|exact|prefix|contains|regex] [--kind K]… [--path GLOB] [--scope S] [-k N]
//!   [--json]`: `search/symbols`, printed as the MCP `symbols` tool prints it.
//! - `search outline ROOT PATH [--no-docs] [--json]`: `search/outline`, printed as the MCP `outline` tool prints it.
//! - `search map ROOT [--budget N] [--focus PATH]… [--name ID]… [--scope code|all] [--json]`: `search/map`, printed as
//!   the MCP `repo_map` tool prints it.
//! - `search usages ROOT NAME [--scope S] [-k N] [--json]`: `search/usages`, printed as the MCP `find_usages` tool
//!   prints it.
//! - `search mcp [ROOT]`: the MCP search tools on stdio, pinned to ROOT (the working folder by default); their questions
//!   go to the hub. Outside agents run it (`docs/guide/agents.md`).
//!
//! Exit 0 when the hub did what was asked, 1 when it answered with an error (its text on stderr), 2 for arguments that do
//! not parse.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use runstav::methods::search as w;
use runstav::paths::Env;
use serde_json::json;

use crate::cli::ENSURE_TIMEOUT;
use crate::client::Client;
use crate::search::mcp::{
    Backend, SearchCtx, render, render_map, render_outline, render_symbols, render_usages,
};

/// How long one call to the hub may take: a first query builds the index.
const CALL: Duration = Duration::from_secs(120);

#[derive(Debug, PartialEq, Eq)]
pub enum SearchCommand {
    Index {
        root: PathBuf,
        rebuild: bool,
        now: bool,
    },
    Query {
        root: PathBuf,
        text: String,
        scope: Option<String>,
        k: Option<u32>,
        json: bool,
    },
    Mcp {
        root: Option<PathBuf>,
    },
    Symbols {
        root: PathBuf,
        name: String,
        mode: Option<String>,
        kinds: Vec<String>,
        path: Option<String>,
        scope: Option<String>,
        k: Option<u32>,
        json: bool,
    },
    Outline {
        root: PathBuf,
        path: String,
        docs: bool,
        json: bool,
    },
    Map {
        root: PathBuf,
        budget: Option<u32>,
        focus: Vec<String>,
        names: Vec<String>,
        scope: Option<String>,
        json: bool,
    },
    Usages {
        root: PathBuf,
        name: String,
        scope: Option<String>,
        k: Option<u32>,
        json: bool,
    },
    /// `eval gen|run|compare` (`crate::eval_cli`): needs no hub.
    Eval(crate::eval_cli::EvalCommand),
}

/// The arguments after `search`.
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<SearchCommand, String> {
    use lexopt::Arg::{Long, Short, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let name = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("search needs a subcommand: index, query, mcp or eval".into()),
    };
    if name == "eval" {
        return crate::eval_cli::parse(p.raw_args().map_err(e)?.collect()).map(SearchCommand::Eval);
    }
    if ![
        "index", "query", "mcp", "symbols", "outline", "map", "usages",
    ]
    .contains(&name.as_str())
    {
        return Err(format!("unknown search subcommand {name:?}"));
    }
    let (mut rebuild, mut now, mut json, mut scope, mut k) = (false, false, false, None, None);
    let (mut mode, mut kinds, mut glob, mut docs) = (None, Vec::new(), None, true);
    let (mut budget, mut focus, mut names) = (None, Vec::new(), Vec::new());
    let asks = matches!(name.as_str(), "query" | "symbols" | "usages");
    let mut words: Vec<String> = Vec::new();
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("rebuild") if name == "index" => rebuild = true,
            Long("now") if name == "index" => now = true,
            Long("json") if asks || name == "outline" || name == "map" => json = true,
            Long("budget") if name == "map" => {
                let b: u32 = p.value().map_err(e)?.parse().map_err(e)?;
                if !(256..=32_000).contains(&b) {
                    return Err("--budget is 256 to 32000 tokens".into());
                }
                budget = Some(b);
            }
            Long("focus") if name == "map" => {
                focus.push(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("name") if name == "map" => names.push(p.value().map_err(e)?.string().map_err(e)?),
            Long("scope") if name == "map" => {
                let s = p.value().map_err(e)?.string().map_err(e)?;
                if !["code", "all"].contains(&s.as_str()) {
                    return Err(format!("--scope is code or all, not {s:?}"));
                }
                scope = Some(s);
            }
            Long("match") if name == "symbols" => {
                let m = p.value().map_err(e)?.string().map_err(e)?;
                if !["auto", "exact", "prefix", "contains", "regex"].contains(&m.as_str()) {
                    return Err(format!(
                        "--match is auto, exact, prefix, contains or regex, not {m:?}"
                    ));
                }
                mode = Some(m);
            }
            Long("kind") if name == "symbols" => {
                kinds.push(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("path") if name == "symbols" => {
                glob = Some(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("no-docs") if name == "outline" => docs = false,
            Long("scope") if asks => {
                let s = p.value().map_err(e)?.string().map_err(e)?;
                if !["code", "tests", "docs", "all"].contains(&s.as_str()) {
                    return Err(format!("--scope is code, tests, docs or all, not {s:?}"));
                }
                scope = Some(s);
            }
            Short('k') if asks => {
                let n: u32 = p.value().map_err(e)?.parse().map_err(e)?;
                if !(1..=100).contains(&n) {
                    return Err("-k is 1 to 100".into());
                }
                k = Some(n);
            }
            Word(v) => words.push(v.string().map_err(e)?),
            other => return Err(other.unexpected().to_string()),
        }
    }
    let mut words = words.into_iter();
    Ok(match name.as_str() {
        "index" => {
            let root = words.next().ok_or("search index needs a project root")?;
            if let Some(extra) = words.next() {
                return Err(format!("search index: unexpected argument {extra:?}"));
            }
            SearchCommand::Index {
                root: root.into(),
                rebuild,
                now,
            }
        }
        "query" => {
            let root = words.next().ok_or("search query needs a project root")?;
            let text = words.collect::<Vec<_>>().join(" ");
            if text.trim().is_empty() {
                return Err("search query needs a question".into());
            }
            SearchCommand::Query {
                root: root.into(),
                text,
                scope,
                k,
                json,
            }
        }
        "symbols" => {
            let root = words.next().ok_or("search symbols needs a project root")?;
            let name = words.next().ok_or("search symbols needs a name")?;
            if let Some(extra) = words.next() {
                return Err(format!("search symbols: unexpected argument {extra:?}"));
            }
            SearchCommand::Symbols {
                root: root.into(),
                name,
                mode,
                kinds,
                path: glob,
                scope,
                k,
                json,
            }
        }
        "outline" => {
            let root = words.next().ok_or("search outline needs a project root")?;
            let path = words.next().ok_or("search outline needs a file")?;
            if let Some(extra) = words.next() {
                return Err(format!("search outline: unexpected argument {extra:?}"));
            }
            SearchCommand::Outline {
                root: root.into(),
                path,
                docs,
                json,
            }
        }
        "map" => {
            let root = words.next().ok_or("search map needs a project root")?;
            if let Some(extra) = words.next() {
                return Err(format!("search map: unexpected argument {extra:?}"));
            }
            SearchCommand::Map {
                root: root.into(),
                budget,
                focus,
                names,
                scope,
                json,
            }
        }
        "usages" => {
            let root = words.next().ok_or("search usages needs a project root")?;
            let name = words.next().ok_or("search usages needs a name")?;
            if let Some(extra) = words.next() {
                return Err(format!("search usages: unexpected argument {extra:?}"));
            }
            SearchCommand::Usages {
                root: root.into(),
                name,
                scope,
                k,
                json,
            }
        }
        _ => {
            let root = words.next();
            if let Some(extra) = words.next() {
                return Err(format!("search mcp: unexpected argument {extra:?}"));
            }
            SearchCommand::Mcp {
                root: root.map(PathBuf::from),
            }
        }
    })
}

fn absolute(cwd: &Path, p: &Path) -> String {
    cwd.join(p).to_string_lossy().into_owned()
}

/// The hub's answers over its socket, one blocking call at a time off the runtime's threads.
struct ClientBackend {
    env: Env,
}

impl Backend for ClientBackend {
    fn query<'a>(
        &'a self,
        root: &'a Path,
        text: &'a str,
        scope: Option<w::Scope>,
        k: Option<u32>,
    ) -> mimir::BoxFuture<'a, Result<w::QueryAnswer, String>> {
        Box::pin(async move {
            let (env, root, text) = (self.env.clone(), root.to_path_buf(), text.to_string());
            crate::clock::blocking(move || {
                let mut params = json!({"root": root, "text": text});
                if let Some(s) = scope {
                    params["scope"] = json!(s);
                }
                if let Some(k) = k {
                    params["k"] = json!(k);
                }
                let v = Client::user(&env, Duration::from_secs(5))
                    .and_then(|mut c| c.call("search/query", params, CALL))?;
                serde_json::from_value(v).map_err(|e| e.to_string())
            })
            .await
            .map_err(|e| e.to_string())?
        })
    }

    fn call<'a>(
        &'a self,
        method: &'static str,
        params: serde_json::Value,
    ) -> mimir::BoxFuture<'a, Result<serde_json::Value, String>> {
        Box::pin(async move {
            let env = self.env.clone();
            crate::clock::blocking(move || {
                Client::user(&env, Duration::from_secs(5))
                    .and_then(|mut c| c.call(method, params, CALL))
            })
            .await
            .map_err(|e| e.to_string())?
        })
    }
}

/// The MCP `search` tool on stdio, pinned to ROOT.
fn serve_mcp(env: &Env, root: PathBuf) -> i32 {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("ratatoskr search: no runtime: {e}");
            return 1;
        }
    };
    let ctx = Arc::new(SearchCtx {
        root,
        backend: Arc::new(ClientBackend { env: env.clone() }),
    });
    let end = rt.block_on(mimir::serve(
        ctx,
        crate::search::mcp::tools(),
        mimir::ServerInfo::default(),
        tokio::io::stdin(),
        tokio::io::stdout(),
        mimir::Limits::default(),
    ));
    tracing::debug!(?end, "search mcp ended");
    0
}

/// METHOD's answer A as the MCP tool prints it (`search/index`'s as data); PARAMS are the call's.
fn text(
    method: &str,
    params: &serde_json::Value,
    a: serde_json::Value,
) -> Result<String, serde_json::Error> {
    Ok(match method {
        "search/query" => render(&serde_json::from_value(a)?),
        "search/symbols" => render_symbols(&serde_json::from_value(a)?),
        "search/outline" => render_outline(&serde_json::from_value(a)?),
        "search/map" => render_map(&serde_json::from_value(a)?),
        "search/usages" => render_usages(
            params["name"].as_str().unwrap_or_default(),
            &serde_json::from_value(a)?,
        ),
        _ => format!("{a}\n"),
    })
}

pub fn run(env: &Env, cmd: SearchCommand) -> i32 {
    let cwd = match std::env::current_dir() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ratatoskr search: no working directory: {e}");
            return 1;
        }
    };
    if let SearchCommand::Eval(e) = cmd {
        return crate::eval_cli::run(env, e);
    }
    let hub = crate::supervise::ensure_quiet(env, ENSURE_TIMEOUT);
    if hub != 0 {
        return hub;
    }
    let (method, params, json) = match &cmd {
        SearchCommand::Mcp { root } => {
            let root = root.as_ref().map_or(cwd.clone(), |r| cwd.join(r));
            return serve_mcp(env, root);
        }
        SearchCommand::Eval(_) => unreachable!("handled above"),
        SearchCommand::Index { root, rebuild, now } => {
            let mut p = json!({"root": absolute(&cwd, root)});
            if *rebuild {
                p["rebuild"] = json!(true);
            }
            if *now {
                p["now"] = json!(true);
            }
            ("search/index", p, true)
        }
        SearchCommand::Query {
            root,
            text,
            scope,
            k,
            json,
        } => {
            let mut p = json!({"root": absolute(&cwd, root), "text": text});
            if let Some(s) = scope {
                p["scope"] = json!(s);
            }
            if let Some(k) = k {
                p["k"] = json!(k);
            }
            ("search/query", p, *json)
        }
        SearchCommand::Symbols {
            root,
            name,
            mode,
            kinds,
            path,
            scope,
            k,
            json,
        } => {
            let mut p = json!({"root": absolute(&cwd, root), "name": name});
            if let Some(m) = mode {
                p["match"] = json!(m);
            }
            if !kinds.is_empty() {
                p["kind"] = json!(kinds);
            }
            if let Some(g) = path {
                p["path"] = json!(g);
            }
            if let Some(s) = scope {
                p["scope"] = json!(s);
            }
            if let Some(k) = k {
                p["k"] = json!(k);
            }
            ("search/symbols", p, *json)
        }
        SearchCommand::Outline {
            root,
            path,
            docs,
            json,
        } => (
            "search/outline",
            json!({"root": absolute(&cwd, root), "path": path, "docs": docs}),
            *json,
        ),
        SearchCommand::Map {
            root,
            budget,
            focus,
            names,
            scope,
            json,
        } => {
            let mut p = json!({"root": absolute(&cwd, root)});
            if let Some(b) = budget {
                p["budget"] = json!(b);
            }
            if !focus.is_empty() {
                p["focus"] = json!(focus);
            }
            if !names.is_empty() {
                p["names"] = json!(names);
            }
            if let Some(s) = scope {
                p["scope"] = json!(s);
            }
            ("search/map", p, *json)
        }
        SearchCommand::Usages {
            root,
            name,
            scope,
            k,
            json,
        } => {
            let mut p = json!({"root": absolute(&cwd, root), "name": name});
            if let Some(s) = scope {
                p["scope"] = json!(s);
            }
            if let Some(k) = k {
                p["k"] = json!(k);
            }
            ("search/usages", p, *json)
        }
    };
    let answer = Client::user(env, Duration::from_secs(5))
        .and_then(|mut c| c.call(method, params.clone(), CALL));
    match answer {
        Ok(a) if json => {
            println!("{a}");
            0
        }
        Ok(a) => match text(method, &params, a) {
            Ok(t) => {
                print!("{t}");
                0
            }
            Err(e) => {
                eprintln!("ratatoskr search: {e}");
                1
            }
        },
        Err(e) => {
            eprintln!("ratatoskr search: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<SearchCommand, String> {
        parse(args.iter().map(OsString::from))
    }

    #[test]
    fn the_three_subcommands_parse() {
        assert_eq!(
            p(&["index", "/r", "--rebuild"]).unwrap(),
            SearchCommand::Index {
                root: "/r".into(),
                rebuild: true,
                now: false
            }
        );
        assert_eq!(
            p(&["query", "/r", "where", "is", "it", "-k", "5"]).unwrap(),
            SearchCommand::Query {
                root: "/r".into(),
                text: "where is it".into(),
                scope: None,
                k: Some(5),
                json: false
            }
        );
        assert_eq!(p(&["mcp"]).unwrap(), SearchCommand::Mcp { root: None });
        assert!(p(&[]).is_err());
        assert!(p(&["query", "/r"]).is_err());
        assert!(p(&["index"]).is_err());
        assert!(p(&["query", "/r", "x", "--scope", "everything"]).is_err());
    }

    #[test]
    fn symbols_and_outline_parse() {
        assert_eq!(
            p(&[
                "symbols", "/r", "make_", "--match", "prefix", "--kind", "function", "--kind",
                "method", "--path", "src/*.rs", "-k", "3", "--json"
            ])
            .unwrap(),
            SearchCommand::Symbols {
                root: "/r".into(),
                name: "make_".into(),
                mode: Some("prefix".into()),
                kinds: vec!["function".into(), "method".into()],
                path: Some("src/*.rs".into()),
                scope: None,
                k: Some(3),
                json: true
            }
        );
        assert_eq!(
            p(&["outline", "/r", "src/a.rs", "--no-docs"]).unwrap(),
            SearchCommand::Outline {
                root: "/r".into(),
                path: "src/a.rs".into(),
                docs: false,
                json: false
            }
        );
        assert!(p(&["symbols", "/r"]).is_err());
        assert!(p(&["symbols", "/r", "x", "--match", "fuzzy"]).is_err());
        assert!(p(&["outline", "/r"]).is_err());
        assert!(p(&["outline", "/r", "a.rs", "--match", "exact"]).is_err());
    }

    #[test]
    fn map_and_usages_parse() {
        assert_eq!(
            p(&[
                "map",
                "/r",
                "--budget",
                "4000",
                "--focus",
                "src/a.rs",
                "--focus",
                "src/b.rs",
                "--name",
                "make_widget",
                "--scope",
                "all",
                "--json"
            ])
            .unwrap(),
            SearchCommand::Map {
                root: "/r".into(),
                budget: Some(4000),
                focus: vec!["src/a.rs".into(), "src/b.rs".into()],
                names: vec!["make_widget".into()],
                scope: Some("all".into()),
                json: true
            }
        );
        assert_eq!(
            p(&["usages", "/r", "make_widget", "--scope", "code", "-k", "5"]).unwrap(),
            SearchCommand::Usages {
                root: "/r".into(),
                name: "make_widget".into(),
                scope: Some("code".into()),
                k: Some(5),
                json: false
            }
        );
        assert!(p(&["map"]).is_err());
        assert!(p(&["map", "/r", "--budget", "100"]).is_err(), "under 256");
        assert!(
            p(&["map", "/r", "--scope", "tests"]).is_err(),
            "code or all"
        );
        assert!(p(&["map", "/r", "extra"]).is_err());
        assert!(p(&["usages", "/r"]).is_err());
        assert!(p(&["usages", "/r", "x", "--focus", "a.rs"]).is_err());
    }
}
