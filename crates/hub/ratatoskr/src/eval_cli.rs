//! `ratatoskr search eval …`: the eval that ships with drgnx (`hrafn::eval`), run from a terminal. It needs no hub: it
//! indexes the project into a store of its own, embeds the chunks with one built-in model in this process, and asks
//! the frozen questions. Nothing here runs by itself.
//!
//! - `eval gen ROOT [--out DIR]`: the questions of ROOT's history, written once to `DIR/dev.jsonl` and `DIR/test.jsonl`
//!   (default `crates/hub/hrafn/eval/<name of ROOT>`); an existing set is never overwritten.
//! - `eval run ROOT [--model ID] [--set dev|test] [--rows FILE] [--device cpu|gpu:ADAPTER] [--models DIR] [--state DIR]
//!   [--out FILE] [--map TOKENS] [--source SRC] [--query-source SRC]`: embeds ROOT with the model (or with a server:
//!   SRC is `builtin`, `tei:URL`, `ollama:URL:MODEL` or `llama:URL`, talked to directly, with no hub or gateway), asks
//!   the set and prints the numbers and writes the run as JSON. `--query-source` embeds the questions with another
//!   source (the same model on another machine); with `--state DIR` the vectors already in DIR's cache (`DIR/vectors/`,
//!   one writer: a hub on the same state is refused) are reused.
//!   With `--map`, also the repo map's yield at that budget: the share of each question's target definitions and
//!   files that the global map shows, that the top 5 hits followed by the map focused on their files show, and that
//!   search hits packed in rank order show (each in the same token estimate).
//! - `eval compare [--by chunk|file|floor] A.json B.json`: B against A, paired. The restated gate (2026-11-10): `chunk` (the
//!   default) passes when the chunk-level MRR@10 difference is at least 0, `file` (fair to a chunker that gives a language
//!   no symbols) when the upper bound of the file MRR@10 difference is; strata are printed, never gating. `floor` is the
//!   non-regression check of an unchanged language (lower bound -0.01 overall, -0.03 per stratum of 30 rows or more).
//!   Exit 0 when B passes, 1 when it does not.

use crate::clock;
use crate::embed_direct::{Api, Direct};
use hrafn::eval::{self, EvalRow, Report};
use hrafn::{Answer, CodeStore, Config, GitCli, Lag, Query, VectorCache};
use hrafn_embed::{Device, LocalEmbedder, MODELS, ModelSpec, default_model};
use http::Uri;
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Where `eval run` gets its vectors from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceArg {
    Builtin,
    Tei { url: String },
    Ollama { url: String, model: String },
    Llama { url: String },
}

impl SourceArg {
    /// `builtin`, `tei:URL`, `ollama:URL:MODEL` or `llama:URL`; a URL is `http://HOST[:PORT]` (TLS is not spoken).
    pub fn parse(s: &str) -> villa::Result<SourceArg> {
        let url = |kind: &str, u: &str| -> villa::Result<String> {
            match u.strip_prefix("http://") {
                Some(rest) if !rest.is_empty() => Ok(u.trim_end_matches('/').to_owned()),
                _ => Err(villa::Error::invalid(format!(
                    "{kind}: needs an http://HOST[:PORT] URL, not {u:?}"
                ))),
            }
        };
        if s == "builtin" {
            return Ok(SourceArg::Builtin);
        }
        if let Some(u) = s.strip_prefix("tei:") {
            return Ok(SourceArg::Tei {
                url: url("tei", u).map_err(|e| villa::Error::invalid(e.to_string()))?,
            });
        }
        if let Some(u) = s.strip_prefix("llama:") {
            return Ok(SourceArg::Llama {
                url: url("llama", u).map_err(|e| villa::Error::invalid(e.to_string()))?,
            });
        }
        if let Some(rest) = s.strip_prefix("ollama:") {
            let no_model = || {
                villa::Error::invalid(format!(
                    "ollama: needs ollama:http://HOST[:PORT]:MODEL, not {s:?}"
                ))
            };
            let after = rest.strip_prefix("http://").ok_or_else(no_model)?;
            // the model may hold colons of its own (`qwen3-embedding:0.6b`): a port is the digits right after the host
            let mut parts = after.splitn(3, ':');
            let host = parts.next().unwrap_or_default();
            let (host_port, model) = match (parts.next(), parts.next()) {
                (Some(p), Some(m)) if !p.is_empty() && p.bytes().all(|c| c.is_ascii_digit()) => {
                    (format!("{host}:{p}"), m.to_owned())
                }
                (Some(p), None) if p.bytes().all(|c| c.is_ascii_digit()) => return Err(no_model()),
                (Some(a), Some(b)) => (host.to_owned(), format!("{a}:{b}")),
                (Some(a), None) => (host.to_owned(), a.to_owned()),
                (None, _) => return Err(no_model()),
            };
            if host.is_empty() || model.is_empty() {
                return Err(no_model());
            }
            return Ok(SourceArg::Ollama {
                url: format!("http://{host_port}"),
                model,
            });
        }
        Err(villa::Error::invalid(format!(
            "--source is builtin, tei:URL, ollama:URL:MODEL or llama:URL, not {s:?}"
        )))
    }
}

impl std::fmt::Display for SourceArg {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SourceArg::Builtin => f.write_str("builtin"),
            SourceArg::Tei { url } => write!(f, "tei:{url}"),
            SourceArg::Ollama { url, model } => write!(f, "ollama:{url}:{model}"),
            SourceArg::Llama { url } => write!(f, "llama:{url}"),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum EvalCommand {
    Gen {
        root: PathBuf,
        out: Option<PathBuf>,
    },
    Run {
        root: PathBuf,
        model: Option<String>,
        set: String,
        rows: Option<PathBuf>,
        device: String,
        models: Option<PathBuf>,
        state: Option<PathBuf>,
        out: Option<PathBuf>,
        /// Also measure the repo map's yield at this many tokens.
        map: Option<usize>,
        /// Boxed: the variant is otherwise far larger than the others.
        source: Box<SourceArg>,
        query_source: Option<Box<SourceArg>>,
        /// Index only, then write this many of the project's chunk texts (as tier 2 would embed them, evenly spread)
        /// to `--out` as `{"texts": [...]}`: the engine's parity check embeds them elsewhere. No model is opened.
        dump_chunks: Option<usize>,
    },
    Compare {
        a: PathBuf,
        b: PathBuf,
        by: eval::Gate,
    },
}

/// The arguments after `search eval`.
pub fn parse(args: Vec<OsString>) -> villa::Result<EvalCommand> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| villa::Error::invalid(e.to_string());
    let name = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(villa::Error::invalid(other.unexpected().to_string())),
        None => {
            return Err(villa::Error::invalid(
                "search eval needs a subcommand: gen, run or compare",
            ));
        }
    };
    if !["gen", "run", "compare"].contains(&name.as_str()) {
        return Err(villa::Error::invalid(format!(
            "unknown search eval subcommand {name:?}"
        )));
    }
    let (mut model, mut set, mut rows, mut device) =
        (None, "dev".to_string(), None, "cpu".to_string());
    let (mut models, mut state, mut out, mut map) = (None, None, None, None);
    let (mut source, mut query_source) = (Box::new(SourceArg::Builtin), None);
    let mut dump_chunks = None;
    let mut by = eval::Gate::Chunk;
    let mut words: Vec<PathBuf> = Vec::new();
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("out") => out = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("by") if name == "compare" => {
                by = match p.value().map_err(e)?.string().map_err(e)?.as_str() {
                    "chunk" => eval::Gate::Chunk,
                    "file" => eval::Gate::File,
                    "floor" => eval::Gate::Floor,
                    other => {
                        return Err(villa::Error::invalid(format!(
                            "--by is chunk, file or floor, not {other:?}"
                        )));
                    }
                }
            }
            Long("model") if name == "run" => {
                model = Some(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("set") if name == "run" => {
                set = p.value().map_err(e)?.string().map_err(e)?;
                if !["dev", "test"].contains(&set.as_str()) {
                    return Err(villa::Error::invalid(format!(
                        "--set is dev or test, not {set:?}"
                    )));
                }
            }
            Long("rows") if name == "run" => rows = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("device") if name == "run" => {
                device = p.value().map_err(e)?.string().map_err(e)?;
                if device != "cpu" && !device.starts_with("gpu:") {
                    return Err(villa::Error::invalid(format!(
                        "--device is cpu or gpu:ADAPTER, not {device:?}"
                    )));
                }
            }
            Long("models") if name == "run" => models = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("state") if name == "run" => state = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("source") if name == "run" => {
                source = Box::new(SourceArg::parse(
                    &p.value().map_err(e)?.string().map_err(e)?,
                )?)
            }
            Long("query-source") if name == "run" => {
                query_source = Some(Box::new(SourceArg::parse(
                    &p.value().map_err(e)?.string().map_err(e)?,
                )?))
            }
            Long("map") if name == "run" => {
                let v = p.value().map_err(e)?.string().map_err(e)?;
                match v.parse::<usize>() {
                    Ok(n) if (256..=32000).contains(&n) => map = Some(n),
                    _ => {
                        return Err(villa::Error::invalid(format!(
                            "--map is a token budget, 256 to 32000, not {v:?}"
                        )));
                    }
                }
            }
            Long("dump-chunks") if name == "run" => {
                let v = p.value().map_err(e)?.string().map_err(e)?;
                match v.parse::<usize>() {
                    Ok(n) if (1..=10000).contains(&n) => dump_chunks = Some(n),
                    _ => {
                        return Err(villa::Error::invalid(format!(
                            "--dump-chunks is a count, 1 to 10000, not {v:?}"
                        )));
                    }
                }
            }
            Word(v) => words.push(PathBuf::from(v)),
            other => return Err(villa::Error::invalid(other.unexpected().to_string())),
        }
    }
    let mut words = words.into_iter();
    let mut next = |what: &str| {
        words
            .next()
            .ok_or(format!("search eval {name} needs {what}"))
    };
    Ok(match name.as_str() {
        "gen" => EvalCommand::Gen {
            root: next("a project root").map_err(|e| villa::Error::invalid(e.to_string()))?,
            out,
        },
        "run" => EvalCommand::Run {
            root: next("a project root").map_err(|e| villa::Error::invalid(e.to_string()))?,
            model,
            set,
            rows,
            device,
            models,
            state,
            out,
            map,
            source,
            query_source,
            dump_chunks,
        },
        _ => EvalCommand::Compare {
            a: next("two reports").map_err(|e| villa::Error::invalid(e.to_string()))?,
            b: next("two reports").map_err(|e| villa::Error::invalid(e.to_string()))?,
            by,
        },
    })
}

/// Progress of one phase of a run: a line to stderr every EVERY items, with the slowest item since the last line, and
/// the latencies kept for the report.
struct Tally {
    what: &'static str,
    total: usize,
    every: usize,
    times: Vec<f64>,
    since: Vec<f64>,
}

/// Latency percentiles of one phase, in seconds.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Latency {
    n: usize,
    p50: f64,
    p95: f64,
    max: f64,
}

impl Tally {
    fn new(what: &'static str, total: usize, every: usize) -> Tally {
        Tally {
            what,
            total,
            every,
            times: Vec::new(),
            since: Vec::new(),
        }
    }

    /// One item took SECS: the progress line when one is due.
    fn note(&mut self, secs: f64) -> Option<String> {
        self.times.push(secs);
        self.since.push(secs);
        if !self.times.len().is_multiple_of(self.every) && self.times.len() != self.total {
            return None;
        }
        let line = format!(
            "{} {}/{}: {:.1}s since the last line, slowest {:.2}s",
            self.what,
            self.times.len(),
            self.total,
            self.since.iter().sum::<f64>(),
            self.since.iter().copied().fold(0.0, f64::max)
        );
        self.since.clear();
        Some(line)
    }

    fn stats(&self) -> Latency {
        let mut v = self.times.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            v.get(((v.len() as f64 - 1.0) * q).round() as usize)
                .copied()
                .unwrap_or(0.0)
        };
        Latency {
            n: v.len(),
            p50: at(0.5),
            p95: at(0.95),
            max: v.last().copied().unwrap_or(0.0),
        }
    }
}

/// What `eval run` writes.
#[derive(Serialize, Deserialize)]
struct RunFile {
    model: String,
    set: String,
    device: String,
    chunks_embedded: u64,
    embed_seconds: f64,
    /// The `--source` the run used (`builtin` for a report from before sources).
    #[serde(default)]
    source: String,
    /// `embed_seconds` over `chunks_embedded`; 0 when the vectors were already in `--state`.
    #[serde(default)]
    embed_seconds_per_chunk: f64,
    /// What one question cost (embedding it and searching), in seconds.
    query_latency: Latency,
    report: Report,
    /// With `--map`: the yield of each context per stratum (`all` too), by variant (`map`, `map-around-search`,
    /// `search`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    map_yield: Option<MapYields>,
}

/// The map's yield at one budget: the global map (M0), the top 5 search hits then the map focused on their files in
/// the budget left (M1), and search hits packed in rank order (S).
#[derive(Serialize, Deserialize)]
struct MapYields {
    budget: usize,
    variants: BTreeMap<String, BTreeMap<String, eval::YieldSummary>>,
    /// The global map's own size.
    map_tokens: usize,
    map_files: usize,
}

/// Characters of lines START to END (1-based, inclusive) of TEXT, newlines counted.
fn chunk_chars(text: &str, start: u32, end: u32) -> usize {
    text.split_inclusive('\n')
        .skip(start.saturating_sub(1) as usize)
        .take((end + 1).saturating_sub(start) as usize)
        .map(str::len)
        .sum()
}

/// How many search hits the baseline may pack (more than fit in any budget allowed).
const PACK_HITS: u32 = 100;

/// The `(path, symbol)` of the definitions MAP shows.
fn shown(map: &hrafn::map::RepoMap) -> Vec<(String, String)> {
    map.files
        .iter()
        .flat_map(|f| f.defs.iter().map(|d| (f.path.clone(), d.name.clone())))
        .collect()
}

/// The three contexts' yields for every question at BUDGET tokens. ASK searches; TEXT gives a file as it is now.
fn map_yields(
    rt: &saman::Executor,
    store: &CodeStore,
    questions: &[EvalRow],
    budget: usize,
    ask: &dyn Fn(&Query) -> Answer,
    text: &dyn Fn(&str) -> Option<String>,
) -> villa::Result<MapYields> {
    use hrafn::map::{MapAsk, repo_map};
    let map_of = |focus: Vec<String>, budget: usize| {
        rt.block_on(repo_map(
            store,
            hrafn::View::Base,
            &MapAsk {
                budget,
                focus,
                names: Vec::new(),
                all: true,
            },
        ))
        .map_err(|e| villa::Error::invalid(e.to_string()))
    };
    let global = map_of(Vec::new(), budget)?;
    let global_shown = shown(&global);
    let files: RefCell<HashMap<String, Option<String>>> = RefCell::new(HashMap::new());
    let chars = |h: &hrafn::Hit| {
        files
            .borrow_mut()
            .entry(h.path.clone())
            .or_insert_with(|| text(&h.path))
            .as_deref()
            .map_or(0, |t| chunk_chars(t, h.line_start, h.line_end))
    };
    let mut rows: BTreeMap<&str, Vec<(String, eval::MapYield)>> = BTreeMap::new();
    let mut tally = Tally::new("map yield", questions.len(), 25);
    for r in questions {
        let started = clock::real_now();
        let hits = ask(&Query {
            text: r.query.clone(),
            scope: hrafn::Scope::All,
            k: PACK_HITS,
            path_weight: hrafn::query::PATH_WEIGHT,
            dir_weight: hrafn::query::DIR_WEIGHT,
        })
        .hits;
        let top = &hits[..hits.len().min(5)];
        let mut around = eval::pack(top, budget, &chars);
        let used: usize = top[..around.len()]
            .iter()
            .map(|h| format!("{}:{}-{}\n", h.path, h.line_start, h.line_end).len() + chars(h))
            .sum::<usize>()
            .div_ceil(4);
        let mut focus: Vec<String> = Vec::new();
        for h in &top[..around.len()] {
            if !focus.contains(&h.path) {
                focus.push(h.path.clone());
            }
        }
        if budget.saturating_sub(used) >= 256 {
            around.extend(shown(&map_of(focus, budget - used)?));
        }
        let packed = eval::pack(&hits, budget, &chars);
        for (variant, got) in [
            ("map", &global_shown),
            ("map-around-search", &around),
            ("search", &packed),
        ] {
            rows.entry(variant)
                .or_default()
                .push((r.stratum.clone(), eval::map_yield(&r.targets, got)));
        }
        if let Some(line) = tally.note(started.elapsed().as_secs_f64()) {
            crate::soft::err_line(&line.to_string());
        }
    }
    Ok(MapYields {
        budget,
        variants: rows
            .into_iter()
            .map(|(v, r)| (v.to_string(), eval::summarize_yield(&r)))
            .collect(),
        map_tokens: global.tokens,
        map_files: global.files.len(),
    })
}

fn yield_table(y: &MapYields) -> String {
    let mut s = format!(
        "map yield at {} tokens (the global map: {} files, ~{} tokens)\n\
         | stratum | n | variant | def-yield (95 % CI) | file-yield (95 % CI) |\n|---|---|---|---|---|\n",
        y.budget, y.map_files, y.map_tokens
    );
    let strata: Vec<&String> = y
        .variants
        .values()
        .next()
        .map(|m| m.keys().collect())
        .unwrap_or_default();
    for st in strata {
        for (v, m) in &y.variants {
            let x = &m[st];
            s.push_str(&format!(
                "| {st} | {} | {v} | {:.3} ({:.3} to {:.3}, {}) | {:.3} ({:.3} to {:.3}) |\n",
                x.n, x.def, x.def_ci.0, x.def_ci.1, x.def_n, x.file, x.file_ci.0, x.file_ci.1
            ));
        }
    }
    s
}

fn project_name(root: &Path) -> String {
    root.canonicalize()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "project".into())
}

fn runtime() -> villa::Result<saman::Executor> {
    saman::Executor::new(1)
}

/// A tier-1 index of ROOT's files in STATE, with the caches that tier 2 will fill. The listed files come back.
async fn index(
    store: &CodeStore,
    root: &Path,
    models: &[&VectorCache],
) -> villa::Result<Vec<hrafn::Listed>> {
    let listed = hrafn::list(root, &GitCli, &Config::default(), &|_| true)
        .map_err(|e| villa::Error::invalid(format!("listing {}: {e}", root.display())))?;
    let base = root.to_path_buf();
    hrafn::refresh(
        store,
        &listed,
        &move |p| std::fs::read(base.join(p)),
        models,
    )
    .await
    .map_err(|e| villa::Error::io(e.to_string()))?;
    Ok(listed)
}

/// The fingerprint `eval run` keys its cache by (hex, record): the source as named (MODEL_ID) and its DIMS, with the
/// embed text's version. Not a model's own fingerprint (`hrafn_embed::fingerprint`): the eval names its sources, and
/// its state is its own.
fn eval_fingerprint(model_id: &str, dims: usize) -> (String, String) {
    use sha2::{Digest, Sha256};
    let record = serde_json::json!({
        "eval_source": model_id,
        "dims": dims,
        "embed_text_version": hrafn::chunk::EMBED_TEXT_VERSION,
    })
    .to_string();
    let hex = Sha256::digest(record.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    (hex, record)
}

/// A scratch folder of this process under the temporary directory.
fn scratch(what: &str) -> PathBuf {
    std::env::temp_dir().join(format!("hrafn-eval-{what}-{}", std::process::id()))
}

fn gen_sets(root: &Path, out: Option<PathBuf>) -> villa::Result<String> {
    let rt = runtime()?;
    let state = scratch("gen");
    std::fs::create_dir_all(&state).map_err(|e| villa::Error::io(e.to_string()))?;
    let store =
        CodeStore::open(&state.join("code.db")).map_err(|e| villa::Error::io(e.to_string()))?;
    let rows = rt.block_on(async {
        index(&store, root, &[]).await?;
        eval::generate(root, &GitCli, &store)
            .await
            .map_err(|e| villa::Error::invalid(e.to_string()))
    });
    store.shutdown();
    crate::soft::done(std::fs::remove_dir_all(&state), "std::fs::remove_dir_all");
    let rows = rows?;
    let dir =
        out.unwrap_or_else(|| PathBuf::from("crates/hub/hrafn/eval").join(project_name(root)));
    eval::write_sets(&dir, &rows).map_err(|e| villa::Error::io(e.to_string()))?;
    let mut per: std::collections::BTreeMap<&str, usize> = Default::default();
    for r in &rows {
        *per.entry(r.stratum.as_str()).or_default() += 1;
    }
    let dev = rows.iter().filter(|r| r.half == "dev").count();
    Ok(format!(
        "{} questions ({} dev, {} test) written to {}; strata {per:?}",
        rows.len(),
        dev,
        rows.len() - dev,
        dir.display()
    ))
}

/// What `eval run` embeds with: a model in this process or a server over HTTP. The id names the vectors in the store.
trait DocSource {
    fn id(&self) -> String;
    fn dims(&mut self) -> villa::Result<usize>;
    /// Documents go plain.
    fn embed_docs(&mut self, texts: &[String]) -> villa::Result<Vec<Vec<f32>>>;
    /// The vector of the question Q of its scope.
    fn embed_query(&mut self, q: &Query) -> villa::Result<Vec<f32>>;
}

/// The built-in model, in this process.
struct LocalSource {
    spec: &'static ModelSpec,
    embedder: LocalEmbedder,
}

impl DocSource for LocalSource {
    fn id(&self) -> String {
        self.spec.id.to_string()
    }

    fn dims(&mut self) -> villa::Result<usize> {
        Ok(self.spec.dims)
    }

    fn embed_docs(&mut self, texts: &[String]) -> villa::Result<Vec<Vec<f32>>> {
        self.embedder
            .embed_docs(texts)
            .map_err(|e| villa::Error::invalid(format!("embedding: {e:?}")))
    }

    fn embed_query(&mut self, q: &Query) -> villa::Result<Vec<f32>> {
        self.embedder
            .embed_query(&q.text, None)
            .map_err(|e| villa::Error::invalid(format!("embedding a question: {e:?}")))
    }
}

/// A server, through [`Direct`]. Its questions carry `Instruct: <task>\nQuery:<q>`, as the hub's do.
struct ServerSource<'a> {
    id: String,
    direct: Direct,
    rt: &'a saman::Executor,
    dims: Option<usize>,
}

impl DocSource for ServerSource<'_> {
    fn id(&self) -> String {
        self.id.clone()
    }

    fn dims(&mut self) -> villa::Result<usize> {
        if let Some(d) = self.dims {
            return Ok(d);
        }
        // one question-shaped text, so that what the server sees as documents is exactly the chunks
        let probe = Query {
            text: "dimension probe".into(),
            scope: hrafn::Scope::All,
            k: 1,
            path_weight: hrafn::query::PATH_WEIGHT,
            dir_weight: hrafn::query::DIR_WEIGHT,
        };
        let d = self.embed_query(&probe)?.len();
        self.dims = Some(d);
        Ok(d)
    }

    fn embed_docs(&mut self, texts: &[String]) -> villa::Result<Vec<Vec<f32>>> {
        self.rt
            .block_on(self.direct.embed(texts))
            .map_err(|e| villa::Error::unavailable(e.0))
    }

    fn embed_query(&mut self, q: &Query) -> villa::Result<Vec<f32>> {
        let text = format!("Instruct: {}\nQuery:{}", q.scope.instruction(), q.text);
        let mut v = self
            .rt
            .block_on(self.direct.embed(&[text]))
            .map_err(|e| e.0)
            .map_err(|e| villa::Error::invalid(e.to_string()))?;
        v.pop()
            .ok_or_else(|| villa::Error::invalid("the server answered no vector"))
    }
}

/// The source ARG names. A built-in model loads from MODELS on DEVICE; a server needs nothing loaded.
fn open_source<'a>(
    arg: &SourceArg,
    spec: &'static ModelSpec,
    models: &Path,
    device: &Device,
    rt: &'a saman::Executor,
) -> villa::Result<Box<dyn DocSource + 'a>> {
    let server = |api: Api, url: &str| -> villa::Result<Box<dyn DocSource + 'a>> {
        let base: Uri = url
            .parse()
            .map_err(|e| villa::Error::invalid(format!("{url}: {e}")))?;
        Ok(Box::new(ServerSource {
            id: arg.to_string(),
            direct: Direct::new(api, base),
            rt,
            dims: None,
        }))
    };
    match arg {
        SourceArg::Builtin => {
            let embedder = LocalEmbedder::load(spec, &models.join(spec.id), device)
                .map_err(|e| villa::Error::invalid(format!("loading {}: {e:?}", spec.id)))?;
            Ok(Box::new(LocalSource { spec, embedder }))
        }
        SourceArg::Tei { url } => server(Api::Tei, url),
        SourceArg::Ollama { url, model } => server(Api::Ollama(model.clone()), url),
        SourceArg::Llama { url } => server(Api::Llama, url),
    }
}

/// The vector score's path and directory weights for this run: `HRAFN_EVAL_PATH_WEIGHT` and `HRAFN_EVAL_DIR_WEIGHT`
/// when set (how the eval tunes them on the dev halves), else the query's own. Only `eval run` reads them; the hub
/// never does.
fn eval_weights() -> (f32, f32) {
    let read = |name: &str, default: f32| {
        std::env::var(name)
            .ok()
            .and_then(|v| v.trim().parse::<f32>().ok())
            .unwrap_or(default)
    };
    (
        read("HRAFN_EVAL_PATH_WEIGHT", hrafn::query::PATH_WEIGHT),
        read("HRAFN_EVAL_DIR_WEIGHT", hrafn::query::DIR_WEIGHT),
    )
}

fn spec_of(id: Option<&str>) -> villa::Result<&'static ModelSpec> {
    match id {
        None => Ok(default_model()),
        Some(id) => MODELS
            .iter()
            .find(|m| m.id == id)
            .ok_or_else(|| villa::Error::invalid(format!("no model {id:?}"))),
    }
}

/// Up to LIMIT definitions with a name of their own (`(name, path, first symbol of the chunk)`), spread evenly through
/// the code files.
async fn sample_names(
    store: &CodeStore,
    limit: usize,
) -> villa::Result<Vec<(String, String, String)>> {
    let all: Vec<(String, String, String, String)> = store
        .handle()
        .read(|c| {
            // one pass over the table; the uniqueness is counted here (a `name in (select … group by name having …)`
            // ran for minutes on a 16,000-chunk project)
            let mut q = c.prepare(
                "select s.name, s.path, f.class, coalesce(c.symbol, '') from symbol s
                 join file f on f.tree = 0 and f.path = s.path and f.blob = s.blob
                 join chunk c on c.id = s.chunk",
            )?;
            let rows = q
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(|e| villa::Error::invalid(e.to_string()))?;
    Ok(spread(unique_code_names(all), limit))
}

/// The line each embed batch prints: how many chunks are in and since when, so a slow embedder (TEI on the CPU) can be
/// told from a stuck run.
fn embed_progress(embedded: u64, secs: f64) -> String {
    format!("embedded {embedded} chunks, {secs:.0}s")
}

/// The definitions of code files whose name is at least 4 characters and defined once in the whole project, by name.
fn unique_code_names(all: Vec<(String, String, String, String)>) -> Vec<(String, String, String)> {
    let mut count: HashMap<&str, u32> = HashMap::new();
    for (name, _, _, _) in &all {
        *count.entry(name.as_str()).or_default() += 1;
    }
    let mut out: Vec<(String, String, String)> = all
        .iter()
        .filter(|(n, _, class, sym)| {
            class == "code" && n.chars().count() >= 4 && count[n.as_str()] == 1 && !sym.is_empty()
        })
        .map(|(n, p, _, s)| (n.clone(), p.clone(), s.clone()))
        .collect();
    out.sort();
    out
}

/// `eval run ROOT --dump-chunks N --out FILE`: index ROOT into STATE (or a scratch folder), then write N of its chunk
/// texts, evenly spread over the project, to FILE as `{"texts": [...]}`. The texts are what tier 2 embeds (documents
/// plain). No model is opened: the cache is keyed by a fingerprint of its own.
fn dump_chunks(
    root: &Path,
    n: usize,
    state: Option<PathBuf>,
    out: Option<PathBuf>,
) -> villa::Result<String> {
    let out = out.ok_or_else(|| villa::Error::invalid("--dump-chunks needs --out FILE"))?;
    let rt = runtime()?;
    let state_dir = state.unwrap_or_else(|| scratch("dump"));
    std::fs::create_dir_all(&state_dir).map_err(|e| villa::Error::io(e.to_string()))?;
    let store =
        CodeStore::open(&state_dir.join("code.db")).map_err(|e| villa::Error::io(e.to_string()))?;
    let (fp, record) = eval_fingerprint("dump-chunks", 0);
    let cache = VectorCache::open_writer(&state_dir.join("vectors"), &fp, &record)
        .map_err(|e| villa::Error::invalid(e.to_string()))?;
    rt.block_on(index(&store, root, &[&cache]))?;
    let texts: Vec<String> = rt
        .block_on(hrafn::missing_with(&store, &cache, u32::MAX, false))
        .map_err(|e| villa::Error::invalid(e.to_string()))?
        .into_iter()
        .filter(|(kind, _, _)| *kind == hrafn::KeyKind::Chunk)
        .map(|(_, _, t)| t)
        .collect();
    let all = texts.len();
    let texts = spread(texts, n);
    let json = serde_json::json!({ "texts": texts }).to_string();
    crate::fsio::write(&out, json)
        .map_err(|e| villa::Error::io(format!("{}: {e}", out.display())))?;
    Ok(format!(
        "{} of {all} chunk texts written to {}",
        texts.len(),
        out.display()
    ))
}

/// Up to LIMIT of ITEMS, evenly spread.
fn spread<T>(items: Vec<T>, limit: usize) -> Vec<T> {
    let step = (items.len() / limit.max(1)).max(1);
    items.into_iter().step_by(step).take(limit).collect()
}

#[allow(clippy::too_many_arguments)]
fn run_set(
    root: &Path,
    model: Option<String>,
    set: &str,
    rows: Option<PathBuf>,
    device: &str,
    models: PathBuf,
    state: Option<PathBuf>,
    out: Option<PathBuf>,
    map: Option<usize>,
    source: SourceArg,
    query_source: Option<SourceArg>,
) -> villa::Result<String> {
    let spec = spec_of(model.as_deref())?;
    let rows_path = rows.unwrap_or_else(|| {
        PathBuf::from("crates/hub/hrafn/eval")
            .join(project_name(root))
            .join(format!("{set}.jsonl"))
    });
    let questions: Vec<EvalRow> = eval::read_set(&rows_path)
        .map_err(|e| villa::Error::invalid(format!("{}: {e}", rows_path.display())))?;
    if questions.is_empty() {
        return Err(villa::Error::invalid(format!(
            "{} holds no questions",
            rows_path.display()
        )));
    }
    let dev = match device.strip_prefix("gpu:") {
        Some(a) => Device::Gpu {
            adapter: a.to_string(),
        },
        None => Device::Cpu {
            threads: std::thread::available_parallelism().map_or(1, |n| (n.get() / 2).max(1)),
        },
    };
    let rt = runtime()?;
    let mut docs = open_source(&source, spec, &models, &dev, &rt)?;
    let mut queries = query_source
        .as_ref()
        .map(|a| open_source(a, spec, &models, &dev, &rt))
        .transpose()?;
    let model_id = docs.id();
    let dims = docs.dims()?;
    if let Some(q) = queries.as_mut()
        && q.dims()? != dims
    {
        return Err(villa::Error::invalid(format!(
            "--query-source gives {} dimensions, --source {dims}: they are not one model",
            q.dims()?
        )));
    }
    let state_dir = state.clone().unwrap_or_else(|| scratch("run"));
    std::fs::create_dir_all(&state_dir).map_err(|e| villa::Error::io(e.to_string()))?;
    let store =
        CodeStore::open(&state_dir.join("code.db")).map_err(|e| villa::Error::io(e.to_string()))?;
    // the vectors in STATE's cache, the source's own (a second writer, a hub on the same state, is refused)
    let (fp, record) = eval_fingerprint(&model_id, dims);
    let cache = VectorCache::open_writer(&state_dir.join("vectors"), &fp, &record)
        .map_err(|e| villa::Error::invalid(e.to_string()))?;
    crate::soft::err_line(&format!(
        "indexing {} into {}",
        root.display(),
        state_dir.display()
    ));
    let began = clock::real_now();
    let listed = rt.block_on(index(&store, root, &[&cache]))?;
    crate::soft::err_line(&format!(
        "indexed {} files in {:.0}s",
        listed.len(),
        began.elapsed().as_secs_f64()
    ));

    // tier 2, in this process: every chunk and path the model lacks (directories too when their weight counts)
    let (path_weight, dir_weight) = eval_weights();
    let begun = clock::real_now();
    let mut embedded = 0u64;
    loop {
        let todo = rt
            .block_on(hrafn::missing_with(&store, &cache, 256, dir_weight > 0.0))
            .map_err(|e| villa::Error::invalid(e.to_string()))?;
        if todo.is_empty() {
            break;
        }
        let texts: Vec<String> = todo.iter().map(|(_, _, t)| t.clone()).collect();
        let vectors = docs.embed_docs(&texts)?;
        let dims = vectors.first().map_or(0, |v| v.len() as u32);
        let (chunks, paths): (Vec<_>, Vec<_>) = todo
            .iter()
            .zip(vectors)
            .partition(|((kind, _, _), _)| *kind == hrafn::KeyKind::Chunk);
        for (kind, rows) in [
            (hrafn::KeyKind::Chunk, chunks),
            (hrafn::KeyKind::Path, paths),
        ] {
            let put: Vec<_> = rows.into_iter().map(|((_, k, _), v)| (*k, v)).collect();
            if !put.is_empty() {
                rt.block_on(cache.put(kind, dims, &put))
                    .map_err(|e| villa::Error::invalid(e.to_string()))?;
            }
        }
        // the chunks (what the report's `chunks_embedded` says); the path vectors ride along
        embedded += todo
            .iter()
            .filter(|(kind, _, _)| *kind == hrafn::KeyKind::Chunk)
            .count() as u64;
        crate::soft::err_line(&embed_progress(embedded, begun.elapsed().as_secs_f64()));
    }
    let embed_seconds = begun.elapsed().as_secs_f64();

    crate::soft::err_line(&format!(
        "embedded {embedded} chunks in {embed_seconds:.0}s; sampling names"
    ));
    let names = rt.block_on(sample_names(&store, 300))?;
    let docs = RefCell::new(docs);
    let queries = queries.map(RefCell::new);
    let base = root.to_path_buf();
    let phase = RefCell::new(Tally::new("scoring", questions.len(), 25));
    let ask = |q: &Query| -> Answer {
        let q = &Query {
            path_weight,
            dir_weight,
            ..q.clone()
        };
        let none = || Answer {
            hits: Vec::new(),
            lag: Lag::default(),
            model: None,
            notice: None,
        };
        let asked = match &queries {
            Some(src) => src.borrow_mut().embed_query(q),
            None => docs.borrow_mut().embed_query(q),
        };
        let Ok(v) = asked else {
            return none();
        };
        let now = |p: &str| crate::fsio::read_to_string(base.join(p)).ok();
        rt.block_on(hrafn::search(
            &store,
            q,
            hrafn::View::Base,
            Some((&cache, v.as_slice())),
            &now,
        ))
        .unwrap_or_else(|_| none())
    };
    let answer = |q: &Query| -> Answer {
        let started = clock::real_now();
        let a = ask(q);
        if let Some(line) = phase.borrow_mut().note(started.elapsed().as_secs_f64()) {
            crate::soft::err_line(&line.to_string());
        }
        a
    };
    let mut report = eval::run(&questions, &answer);
    let query_latency = phase
        .replace(Tally::new("exact-symbol", names.len(), 50))
        .stats();
    let (floor, misses) = eval::exact_symbol_floor(&names, &answer);
    for m in &misses {
        crate::soft::err_line(&format!("exact-symbol miss: {m}"));
    }
    report.exact_symbol_r1 = Some(floor);
    crate::soft::err_line("coverage check");
    let per_file: HashMap<String, u32> = rt
        .block_on(store.handle().read(|c| {
            let mut q = c.prepare(
                "select c.path, count(*) from chunk c
                 join file f on f.tree = 0 and f.path = c.path and f.blob = c.blob group by c.path",
            )?;
            let rows = q
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?)))?
                .collect::<Result<HashMap<_, _>, _>>()?;
            Ok(rows)
        }))
        .map_err(|e| villa::Error::invalid(e.to_string()))?;
    report.coverage_errors = hrafn::coverage(&listed, &per_file)
        .iter()
        .map(|e| format!("{e:?}"))
        .collect();

    let mut text = summary(&model_id, set, &report, embedded, embed_seconds);
    text.push_str(&format!(
        "vector score weights: path {path_weight}, directories {dir_weight}\n"
    ));
    // a target the rules (the defaults and the root's `.drgnx/search.toml`) leave out of the list is a rule bug: the
    // wave gate wants 0
    let kept: std::collections::HashSet<&str> = listed.iter().map(|l| l.path.as_str()).collect();
    let hidden: std::collections::BTreeSet<&str> = questions
        .iter()
        .flat_map(|q| q.targets.iter().map(|t| t.0.as_str()))
        .filter(|p| !kept.contains(p))
        .collect();
    text.push_str(&format!(
        "eval targets the default rules ignore: {}{}\n",
        hidden.len(),
        hidden
            .iter()
            .take(5)
            .map(|p| format!(" {p}"))
            .collect::<String>()
    ));
    text.push_str(&format!(
        "one question (embed + search), {} asked: p50 {:.3}s, p95 {:.3}s, max {:.3}s\n",
        query_latency.n, query_latency.p50, query_latency.p95, query_latency.max
    ));
    let map_yield = match map {
        Some(budget) => {
            crate::soft::err_line(&format!("map yield at {budget} tokens"));
            let file = |p: &str| crate::fsio::read_to_string(base.join(p)).ok();
            let y = map_yields(&rt, &store, &questions, budget, &ask, &file)?;
            text.push_str(&yield_table(&y));
            Some(y)
        }
        None => None,
    };
    let file = RunFile {
        model: model_id.clone(),
        source: source.to_string(),
        embed_seconds_per_chunk: if embedded == 0 {
            0.0
        } else {
            embed_seconds / embedded as f64
        },
        set: set.to_string(),
        device: device.to_string(),
        chunks_embedded: embedded,
        embed_seconds,
        query_latency,
        report,
        map_yield,
    };
    if let Some(out) = out {
        let json = serde_json::to_string_pretty(&file)
            .map_err(|e| villa::Error::invalid(e.to_string()))?;
        crate::fsio::write(&out, json)
            .map_err(|e| villa::Error::io(format!("{}: {e}", out.display())))?;
    }
    Ok(text)
}

fn summary(model: &str, set: &str, r: &Report, chunks: u64, secs: f64) -> String {
    let mut s = format!(
        "{model} on the {set} set: {chunks} chunks embedded in {secs:.0}s\n\
         | stratum | n | MRR@10 (95 % CI) | nDCG@10 | recall@5 | recall@10 | file MRR@10 (95 % CI) |\n\
         |---|---|---|---|---|---|---|\n"
    );
    let line = |name: &str, x: &eval::Summary| {
        format!(
            "| {name} | {} | {:.3} ({:.3} to {:.3}) | {:.3} | {:.3} | {:.3} | {:.3} ({:.3} to {:.3}) |\n",
            x.n,
            x.mrr,
            x.mrr_ci.0,
            x.mrr_ci.1,
            x.ndcg,
            x.recall5,
            x.recall10,
            x.file_mrr,
            x.file_mrr_ci.0,
            x.file_mrr_ci.1
        )
    };
    s.push_str(&line("all", &r.overall));
    for (name, x) in &r.strata {
        s.push_str(&line(name, x));
    }
    s.push_str(&format!(
        "exact-symbol recall@1: {:?}; coverage errors: {}\n",
        r.exact_symbol_r1,
        r.coverage_errors.len()
    ));
    s
}

fn compare_files(a: &Path, b: &Path, by: eval::Gate) -> villa::Result<(String, bool)> {
    let load = |p: &Path| -> villa::Result<RunFile> {
        let text = crate::fsio::read_to_string(p)
            .map_err(|e| villa::Error::io(format!("{}: {e}", p.display())))?;
        serde_json::from_str(&text).map_err(|e| villa::Error::io(format!("{}: {e}", p.display())))
    };
    let (fa, fb) = (load(a)?, load(b)?);
    let v = eval::compare_on(&fa.report, &fb.report, by)
        .map_err(|e| villa::Error::invalid(e.to_string()))?;
    let label = match by {
        eval::Gate::Chunk | eval::Gate::Floor => "MRR@10",
        eval::Gate::File => "file MRR@10",
    };
    let mut s = format!(
        "{} (B) against {} (A): overall {label} difference {:+.4} (95 % CI {:+.4} to {:+.4}, {} queries)\n",
        fb.model, fa.model, v.overall.mean, v.overall.lo, v.overall.hi, v.overall.n
    );
    for (name, d) in &v.strata {
        s.push_str(&format!(
            "  {name}: {:+.4} ({:+.4} to {:+.4}, {})\n",
            d.mean, d.lo, d.hi, d.n
        ));
    }
    s.push_str(if v.pass { "PASS\n" } else { "FAIL\n" });
    for r in &v.reasons {
        s.push_str(&format!("  - {r}\n"));
    }
    Ok((s, v.pass))
}

pub fn run(env: &runstav::paths::Env, cmd: EvalCommand) -> i32 {
    let done = |r: villa::Result<String>| match r {
        Ok(text) => {
            crate::soft::out_text(&text);
            if !text.ends_with('\n') {
                crate::soft::out_line("");
            }
            0
        }
        Err(e) => {
            crate::soft::err_line(&format!("ratatoskr search eval: {}", e.message()));
            1
        }
    };
    match cmd {
        EvalCommand::Gen { root, out } => done(gen_sets(&root, out)),
        EvalCommand::Run {
            root,
            state,
            out,
            dump_chunks: Some(n),
            ..
        } => done(dump_chunks(&root, n, state, out)),
        EvalCommand::Run {
            root,
            model,
            set,
            rows,
            device,
            models,
            state,
            out,
            map,
            source,
            query_source,
            dump_chunks: None,
        } => {
            let models = models.unwrap_or_else(|| crate::search::models_root(env));
            done(run_set(
                &root,
                model,
                &set,
                rows,
                &device,
                models,
                state,
                out,
                map,
                *source,
                query_source.map(|q| *q),
            ))
        }
        EvalCommand::Compare { a, b, by } => match compare_files(&a, &b, by) {
            Ok((text, pass)) => {
                crate::soft::out_text(&text);
                i32::from(!pass)
            }
            Err(e) => {
                crate::soft::err_line(&format!("ratatoskr search eval: {e}"));
                1
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> villa::Result<EvalCommand> {
        parse(args.iter().map(OsString::from).collect())
    }

    /// Pattern D. A phase says how far it is every EVERY items, with the slowest item since the last line, so a slow
    /// phase can be told from a stuck one; the figures at the end are percentiles of every item.
    #[test]
    fn a_phase_logs_progress_and_keeps_its_latencies() {
        let mut t = Tally::new("scoring", 6, 3);
        let lines: Vec<Option<String>> = [0.1, 0.5, 0.2, 0.1, 0.1, 4.0]
            .iter()
            .map(|s| t.note(*s))
            .collect();
        assert_eq!(lines[0], None);
        assert_eq!(lines[1], None);
        assert_eq!(
            lines[2].as_deref(),
            Some("scoring 3/6: 0.8s since the last line, slowest 0.50s")
        );
        assert_eq!(
            lines[5].as_deref(),
            Some("scoring 6/6: 4.2s since the last line, slowest 4.00s")
        );
        let s = t.stats();
        assert_eq!((s.n, s.max), (6, 4.0));
        assert_eq!(s.p50, 0.2);
        assert_eq!(s.p95, 4.0);
    }

    /// Pattern D. Every embed batch (256 keys) prints where the run is, not one in 2,048 chunks: a CPU embedder takes
    /// minutes over 2,048 chunks, which the slot guard read as a hang.
    #[test]
    fn every_embed_batch_says_how_far_it_is() {
        assert_eq!(embed_progress(256, 31.4), "embedded 256 chunks, 31s");
        assert_eq!(embed_progress(15239, 259.0), "embedded 15239 chunks, 259s");
    }

    /// Pattern D. The exact-symbol sample is names defined once, in code files, of 4 characters or more, spread evenly.
    #[test]
    fn the_symbol_sample_is_unique_code_names() {
        let row = |n: &str, p: &str, c: &str, s: &str| {
            (n.to_string(), p.to_string(), c.to_string(), s.to_string())
        };
        let names = unique_code_names(vec![
            row("alpha-one", "a.el", "code", "alpha-one"),
            row("dup-name", "a.el", "code", "dup-name"),
            row("dup-name", "b.el", "code", "dup-name"),
            row("abc", "a.el", "code", "abc"),
            row("in-tests", "t.el", "test", "in-tests"),
            row("beta-two", "b.el", "code", "alpha-one"),
            row("no-chunk-symbol", "b.el", "code", ""),
        ]);
        // each with the first symbol of the chunk that defines it (the chunk's name in a hit)
        assert_eq!(
            names,
            [
                ("alpha-one".into(), "a.el".into(), "alpha-one".into()),
                ("beta-two".into(), "b.el".into(), "alpha-one".into())
            ]
        );
        assert_eq!(spread((0..10).collect::<Vec<_>>(), 5), [0, 2, 4, 6, 8]);
        assert_eq!(spread((0..3).collect::<Vec<_>>(), 5), [0, 1, 2]);
    }

    #[test]
    fn the_three_eval_subcommands_parse() {
        assert_eq!(
            p(&["gen", "/r", "--out", "/o"]).unwrap(),
            EvalCommand::Gen {
                root: "/r".into(),
                out: Some("/o".into())
            }
        );
        let EvalCommand::Run {
            device, set, model, ..
        } = p(&[
            "run",
            "/r",
            "--device",
            "gpu:RX 7900",
            "--set",
            "test",
            "--model",
            "m",
        ])
        .unwrap()
        else {
            panic!()
        };
        assert_eq!(
            (device.as_str(), set.as_str(), model.as_deref()),
            ("gpu:RX 7900", "test", Some("m"))
        );
        assert_eq!(
            p(&["compare", "a.json", "b.json"]).unwrap(),
            EvalCommand::Compare {
                a: "a.json".into(),
                b: "b.json".into(),
                by: eval::Gate::Chunk
            }
        );
        assert_eq!(
            p(&["compare", "--by", "file", "a.json", "b.json"]).unwrap(),
            EvalCommand::Compare {
                a: "a.json".into(),
                b: "b.json".into(),
                by: eval::Gate::File
            }
        );
        assert!(p(&["compare", "--by", "symbol", "a.json", "b.json"]).is_err());
        assert!(p(&["run", "/r", "--by", "file"]).is_err());
        assert!(p(&[]).is_err());
        assert!(p(&["run", "/r", "--device", "tpu"]).is_err());
        assert!(p(&["compare", "a.json"]).is_err());
    }

    #[test]
    fn run_takes_a_map_budget() {
        let map_of = |args: &[&str]| match p(args).unwrap() {
            EvalCommand::Run { map, .. } => map,
            other => panic!("{other:?}"),
        };
        assert_eq!(map_of(&["run", "/r"]), None);
        assert_eq!(map_of(&["run", "/r", "--map", "8000"]), Some(8000));
        assert!(p(&["run", "/r", "--map", "255"]).is_err());
        assert!(p(&["run", "/r", "--map", "lots"]).is_err());
        assert!(p(&["compare", "--map", "8000", "a.json", "b.json"]).is_err());
    }

    #[test]
    fn run_takes_a_chunk_dump_count() {
        let dump_of = |args: &[&str]| match p(args).unwrap() {
            EvalCommand::Run { dump_chunks, .. } => dump_chunks,
            other => panic!("{other:?}"),
        };
        assert_eq!(dump_of(&["run", "/r"]), None);
        assert_eq!(dump_of(&["run", "/r", "--dump-chunks", "200"]), Some(200));
        assert!(p(&["run", "/r", "--dump-chunks", "0"]).is_err());
        assert!(p(&["compare", "--dump-chunks", "5", "a.json", "b.json"]).is_err());
    }

    /// The lines of a chunk, by the hit's range, counted as the search baseline packs them.
    #[test]
    fn a_hit_is_measured_by_its_lines() {
        let text = "one\ntwo\nthree\nfour\n";
        assert_eq!(chunk_chars(text, 2, 3), "two\nthree\n".len());
        assert_eq!(chunk_chars(text, 4, 9), "four\n".len());
        assert_eq!(chunk_chars(text, 7, 9), 0);
    }

    /// The `--source` forms, and what the parser refuses.
    #[test]
    fn parse_source_args() {
        let url = "http://127.0.0.1:8087";
        assert_eq!(SourceArg::parse("builtin"), Ok(SourceArg::Builtin));
        assert_eq!(
            SourceArg::parse(&format!("tei:{url}")),
            Ok(SourceArg::Tei { url: url.into() })
        );
        assert_eq!(
            SourceArg::parse("llama:http://127.0.0.1:8013"),
            Ok(SourceArg::Llama {
                url: "http://127.0.0.1:8013".into()
            })
        );
        // the model name may hold colons of its own
        assert_eq!(
            SourceArg::parse("ollama:http://127.0.0.1:11434:qwen3-embedding:0.6b"),
            Ok(SourceArg::Ollama {
                url: "http://127.0.0.1:11434".into(),
                model: "qwen3-embedding:0.6b".into()
            })
        );
        assert_eq!(
            SourceArg::parse("ollama:http://gpu-box:qwen3-embedding:0.6b"),
            Ok(SourceArg::Ollama {
                url: "http://gpu-box".into(),
                model: "qwen3-embedding:0.6b".into()
            })
        );
        for text in [
            "builtin",
            "tei:http://127.0.0.1:8087",
            "llama:http://h:8013",
            "ollama:http://h:11434:m:1",
        ] {
            assert_eq!(SourceArg::parse(text).unwrap().to_string(), text);
        }
        for bad in [
            "tei",
            "tei:",
            "llama:",
            "tei:127.0.0.1:8087",
            "ollama:http://h:11434",
            "ollama:http://h:11434:",
            "nope:http://h:1",
            "",
        ] {
            assert!(SourceArg::parse(bad).is_err(), "{bad:?} must not parse");
        }
        let EvalCommand::Run {
            source,
            query_source,
            ..
        } = p(&[
            "run",
            "/r",
            "--source",
            "tei:http://h:1",
            "--query-source",
            "llama:http://h:2",
        ])
        .unwrap()
        else {
            panic!()
        };
        assert_eq!(
            *source,
            SourceArg::Tei {
                url: "http://h:1".into()
            }
        );
        assert_eq!(
            query_source.map(|q| *q),
            Some(SourceArg::Llama {
                url: "http://h:2".into()
            })
        );
        assert!(p(&["run", "/r", "--source", "tei:"]).is_err());
        assert!(p(&["compare", "--source", "builtin", "a.json", "b.json"]).is_err());
    }
}
