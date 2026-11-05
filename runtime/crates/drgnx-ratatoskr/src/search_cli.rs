//! `ratatoskr search …`: Hrafn from a terminal and for agents outside drgnx. A user client of the running hub (`ensure`d
//! first), so the checks are the hub's. `bin/drgnx search` runs it with the same arguments.
//!
//! - `search index ROOT [--rebuild] [--now]`: `search/index`.
//! - `search query ROOT QUESTION… [-k N] [--scope code|tests|docs|all] [--json]`: `search/query`, printed as the MCP
//!   tool prints it, or as the method's answer with `--json`.
//! - `search mcp [ROOT]`: the MCP `search` tool on stdio, pinned to ROOT (the working folder by default); its questions
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
use crate::search::mcp::{Backend, SearchCtx, render};

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
    if !["index", "query", "mcp"].contains(&name.as_str()) {
        return Err(format!("unknown search subcommand {name:?}"));
    }
    let (mut rebuild, mut now, mut json, mut scope, mut k) = (false, false, false, None, None);
    let mut words: Vec<String> = Vec::new();
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("rebuild") if name == "index" => rebuild = true,
            Long("now") if name == "index" => now = true,
            Long("json") if name == "query" => json = true,
            Long("scope") if name == "query" => {
                let s = p.value().map_err(e)?.string().map_err(e)?;
                if !["code", "tests", "docs", "all"].contains(&s.as_str()) {
                    return Err(format!("--scope is code, tests, docs or all, not {s:?}"));
                }
                scope = Some(s);
            }
            Short('k') if name == "query" => {
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
            tokio::task::spawn_blocking(move || {
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
    };
    let answer =
        Client::user(env, Duration::from_secs(5)).and_then(|mut c| c.call(method, params, CALL));
    match answer {
        Ok(a) if json => {
            println!("{a}");
            0
        }
        Ok(a) => match serde_json::from_value::<w::QueryAnswer>(a) {
            Ok(q) => {
                print!("{}", render(&q));
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
}
