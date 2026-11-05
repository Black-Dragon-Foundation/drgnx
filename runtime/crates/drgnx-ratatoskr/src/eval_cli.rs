//! `ratatoskr search eval …`: the eval that ships with drgnx (`hrafn::eval`), run from a terminal. It needs no hub: it
//! indexes the project into a store of its own, embeds the chunks with one built-in model in this process, and asks
//! the frozen questions. Nothing here runs by itself.
//!
//! - `eval gen ROOT [--out DIR]`: the questions of ROOT's history, written once to `DIR/dev.jsonl` and `DIR/test.jsonl`
//!   (default `runtime/crates/hrafn/eval/<name of ROOT>`); an existing set is never overwritten.
//! - `eval run ROOT [--model ID] [--set dev|test] [--rows FILE] [--device cpu|gpu:ADAPTER] [--models DIR] [--state DIR]
//!   [--out FILE]`: embeds ROOT with the model, asks the set, prints the numbers and writes the run as JSON.
//! - `eval compare A.json B.json`: B against A, paired; exit 0 when B passes the gate, 1 when it does not.

use crate::clock;
use hrafn::eval::{self, EvalRow, Report};
use hrafn::{Answer, CodeStore, Config, GitCli, Lag, Query};
use hrafn_embed::{Device, LocalEmbedder, MODELS, ModelSpec, default_model};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

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
    },
    Compare {
        a: PathBuf,
        b: PathBuf,
    },
}

/// The arguments after `search eval`.
pub fn parse(args: Vec<OsString>) -> Result<EvalCommand, String> {
    use lexopt::Arg::{Long, Value as Word};
    use lexopt::ValueExt;
    let mut p = lexopt::Parser::from_args(args);
    let e = |e: lexopt::Error| e.to_string();
    let name = match p.next().map_err(e)? {
        Some(Word(v)) => v.string().map_err(e)?,
        Some(other) => return Err(other.unexpected().to_string()),
        None => return Err("search eval needs a subcommand: gen, run or compare".into()),
    };
    if !["gen", "run", "compare"].contains(&name.as_str()) {
        return Err(format!("unknown search eval subcommand {name:?}"));
    }
    let (mut model, mut set, mut rows, mut device) =
        (None, "dev".to_string(), None, "cpu".to_string());
    let (mut models, mut state, mut out) = (None, None, None);
    let mut words: Vec<PathBuf> = Vec::new();
    while let Some(arg) = p.next().map_err(e)? {
        match arg {
            Long("out") => out = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("model") if name == "run" => {
                model = Some(p.value().map_err(e)?.string().map_err(e)?)
            }
            Long("set") if name == "run" => {
                set = p.value().map_err(e)?.string().map_err(e)?;
                if !["dev", "test"].contains(&set.as_str()) {
                    return Err(format!("--set is dev or test, not {set:?}"));
                }
            }
            Long("rows") if name == "run" => rows = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("device") if name == "run" => {
                device = p.value().map_err(e)?.string().map_err(e)?;
                if device != "cpu" && !device.starts_with("gpu:") {
                    return Err(format!("--device is cpu or gpu:ADAPTER, not {device:?}"));
                }
            }
            Long("models") if name == "run" => models = Some(PathBuf::from(p.value().map_err(e)?)),
            Long("state") if name == "run" => state = Some(PathBuf::from(p.value().map_err(e)?)),
            Word(v) => words.push(PathBuf::from(v)),
            other => return Err(other.unexpected().to_string()),
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
            root: next("a project root")?,
            out,
        },
        "run" => EvalCommand::Run {
            root: next("a project root")?,
            model,
            set,
            rows,
            device,
            models,
            state,
            out,
        },
        _ => EvalCommand::Compare {
            a: next("two reports")?,
            b: next("two reports")?,
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
    /// What one question cost (embedding it and searching), in seconds.
    query_latency: Latency,
    report: Report,
}

fn project_name(root: &Path) -> String {
    root.canonicalize()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "project".into())
}

fn runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("no runtime: {e}"))
}

/// A tier-1 index of ROOT's files in STATE, with the models that will fill it. The listed files come back.
async fn index(
    store: &CodeStore,
    root: &Path,
    models: &[(&str, usize)],
) -> Result<Vec<hrafn::Listed>, String> {
    let listed = hrafn::list(root, &GitCli, &Config::default(), &|_| true)
        .map_err(|e| format!("listing {}: {e}", root.display()))?;
    let base = root.to_path_buf();
    hrafn::refresh(
        store,
        &listed,
        &move |p| std::fs::read(base.join(p)),
        models,
    )
    .await
    .map_err(|e| e.to_string())?;
    Ok(listed)
}

/// A scratch folder of this process under the temporary directory.
fn scratch(what: &str) -> PathBuf {
    std::env::temp_dir().join(format!("hrafn-eval-{what}-{}", std::process::id()))
}

fn gen_sets(root: &Path, out: Option<PathBuf>) -> Result<String, String> {
    let rt = runtime()?;
    let state = scratch("gen");
    std::fs::create_dir_all(&state).map_err(|e| e.to_string())?;
    let store = CodeStore::open(&state.join("code.db")).map_err(|e| e.to_string())?;
    let rows = rt.block_on(async {
        index(&store, root, &[]).await?;
        eval::generate(root, &GitCli, &store).await
    });
    store.shutdown();
    let _ = std::fs::remove_dir_all(&state);
    let rows = rows?;
    let dir =
        out.unwrap_or_else(|| PathBuf::from("runtime/crates/hrafn/eval").join(project_name(root)));
    eval::write_sets(&dir, &rows).map_err(|e| e.to_string())?;
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

fn spec_of(id: Option<&str>) -> Result<&'static ModelSpec, String> {
    match id {
        None => Ok(default_model()),
        Some(id) => MODELS
            .iter()
            .find(|m| m.id == id)
            .ok_or_else(|| format!("no model {id:?}")),
    }
}

/// Up to LIMIT definitions with a name of their own (`(name, path)`), spread evenly through the code files.
async fn sample_names(store: &CodeStore, limit: usize) -> Result<Vec<(String, String)>, String> {
    let all: Vec<(String, String)> = store
        .handle()
        .read(|c| {
            let mut q = c.prepare(
                "select s.name, s.path from symbol s join file f on f.path = s.path
                 where f.class = 'code' and length(s.name) >= 4
                   and s.name in (select name from symbol group by name having count(*) = 1)
                 order by s.name",
            )?;
            let rows = q
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?;
    let step = (all.len() / limit.max(1)).max(1);
    Ok(all.into_iter().step_by(step).take(limit).collect())
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
) -> Result<String, String> {
    let spec = spec_of(model.as_deref())?;
    let rows_path = rows.unwrap_or_else(|| {
        PathBuf::from("runtime/crates/hrafn/eval")
            .join(project_name(root))
            .join(format!("{set}.jsonl"))
    });
    let questions: Vec<EvalRow> =
        eval::read_set(&rows_path).map_err(|e| format!("{}: {e}", rows_path.display()))?;
    if questions.is_empty() {
        return Err(format!("{} holds no questions", rows_path.display()));
    }
    let dev = match device.strip_prefix("gpu:") {
        Some(a) => Device::Gpu {
            adapter: a.to_string(),
        },
        None => Device::Cpu {
            threads: std::thread::available_parallelism().map_or(1, |n| (n.get() / 2).max(1)),
        },
    };
    let mut embedder = LocalEmbedder::load(spec, &models.join(spec.id), &dev)
        .map_err(|e| format!("loading {}: {e:?}", spec.id))?;
    let state_dir = state.clone().unwrap_or_else(|| scratch("run"));
    std::fs::create_dir_all(&state_dir).map_err(|e| e.to_string())?;
    let store = CodeStore::open(&state_dir.join("code.db")).map_err(|e| e.to_string())?;
    let rt = runtime()?;
    eprintln!("indexing {} into {}", root.display(), state_dir.display());
    let began = clock::real_now();
    let listed = rt.block_on(index(&store, root, &[(spec.id, spec.dims)]))?;
    eprintln!(
        "indexed {} files in {:.0}s",
        listed.len(),
        began.elapsed().as_secs_f64()
    );

    // tier 2, in this process: every chunk the model lacks
    let begun = clock::real_now();
    let mut embedded = 0u64;
    loop {
        let todo = rt
            .block_on(hrafn::missing(&store, spec.id, 256))
            .map_err(|e| e.to_string())?;
        if todo.is_empty() {
            break;
        }
        let texts: Vec<String> = todo.iter().map(|(_, t)| t.clone()).collect();
        let vectors = embedder
            .embed_docs(&texts)
            .map_err(|e| format!("embedding: {e:?}"))?;
        let put: Vec<_> = todo.iter().map(|(k, _)| *k).zip(vectors).collect();
        rt.block_on(hrafn::put_vectors(&store, spec.id, &put))
            .map_err(|e| e.to_string())?;
        embedded += put.len() as u64;
        if embedded % 2048 < 256 {
            eprintln!(
                "embedded {embedded} chunks, {:.0}s",
                begun.elapsed().as_secs_f64()
            );
        }
    }
    let embed_seconds = begun.elapsed().as_secs_f64();

    eprintln!("embedded {embedded} chunks in {embed_seconds:.0}s; sampling names");
    let names = rt.block_on(sample_names(&store, 300))?;
    let embedder = RefCell::new(embedder);
    let base = root.to_path_buf();
    let phase = RefCell::new(Tally::new("scoring", questions.len(), 25));
    let ask = |q: &Query| -> Answer {
        let none = || Answer {
            hits: Vec::new(),
            lag: Lag::default(),
            model: None,
            notice: None,
        };
        let Ok(v) = embedder.borrow_mut().embed_query(&q.text, None) else {
            return none();
        };
        let now = |p: &str| std::fs::read_to_string(base.join(p)).ok();
        rt.block_on(hrafn::search(
            &store,
            q,
            Some((spec.id, v.as_slice())),
            &now,
        ))
        .unwrap_or_else(|_| none())
    };
    let answer = |q: &Query| -> Answer {
        let started = clock::real_now();
        let a = ask(q);
        if let Some(line) = phase.borrow_mut().note(started.elapsed().as_secs_f64()) {
            eprintln!("{line}");
        }
        a
    };
    let mut report = eval::run(&questions, &answer);
    let query_latency = phase
        .replace(Tally::new("exact-symbol", names.len(), 50))
        .stats();
    report.exact_symbol_r1 = Some(eval::exact_symbol_floor(&names, &answer));
    eprintln!("coverage check");
    let per_file: HashMap<String, u32> = rt
        .block_on(store.handle().read(|c| {
            let mut q = c.prepare("select path, count(*) from chunk group by path")?;
            let rows = q
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?)))?
                .collect::<Result<HashMap<_, _>, _>>()?;
            Ok(rows)
        }))
        .map_err(|e| e.to_string())?;
    report.coverage_errors = hrafn::coverage(&listed, &per_file)
        .iter()
        .map(|e| format!("{e:?}"))
        .collect();

    let mut text = summary(spec.id, set, &report, embedded, embed_seconds);
    text.push_str(&format!(
        "one question (embed + search), {} asked: p50 {:.3}s, p95 {:.3}s, max {:.3}s\n",
        query_latency.n, query_latency.p50, query_latency.p95, query_latency.max
    ));
    let file = RunFile {
        model: spec.id.to_string(),
        set: set.to_string(),
        device: device.to_string(),
        chunks_embedded: embedded,
        embed_seconds,
        query_latency,
        report,
    };
    if let Some(out) = out {
        let json = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;
        std::fs::write(&out, json).map_err(|e| format!("{}: {e}", out.display()))?;
    }
    Ok(text)
}

fn summary(model: &str, set: &str, r: &Report, chunks: u64, secs: f64) -> String {
    let mut s = format!(
        "{model} on the {set} set: {chunks} chunks embedded in {secs:.0}s\n\
         | stratum | n | MRR@10 (95 % CI) | nDCG@10 | recall@5 | recall@10 |\n|---|---|---|---|---|---|\n"
    );
    let line = |name: &str, x: &eval::Summary| {
        format!(
            "| {name} | {} | {:.3} ({:.3} to {:.3}) | {:.3} | {:.3} | {:.3} |\n",
            x.n, x.mrr, x.mrr_ci.0, x.mrr_ci.1, x.ndcg, x.recall5, x.recall10
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

fn compare_files(a: &Path, b: &Path) -> Result<(String, bool), String> {
    let load = |p: &Path| -> Result<RunFile, String> {
        let text = std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", p.display()))
    };
    let (fa, fb) = (load(a)?, load(b)?);
    let v = eval::compare(&fa.report, &fb.report)?;
    let mut s = format!(
        "{} (B) against {} (A): overall MRR@10 difference {:+.4} (95 % CI {:+.4} to {:+.4}, {} queries)\n",
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
    let done = |r: Result<String, String>| match r {
        Ok(text) => {
            print!("{text}");
            if !text.ends_with('\n') {
                println!();
            }
            0
        }
        Err(e) => {
            eprintln!("ratatoskr search eval: {e}");
            1
        }
    };
    match cmd {
        EvalCommand::Gen { root, out } => done(gen_sets(&root, out)),
        EvalCommand::Run {
            root,
            model,
            set,
            rows,
            device,
            models,
            state,
            out,
        } => {
            let models = models.unwrap_or_else(|| crate::search::models_root(env));
            done(run_set(
                &root, model, &set, rows, &device, models, state, out,
            ))
        }
        EvalCommand::Compare { a, b } => match compare_files(&a, &b) {
            Ok((text, pass)) => {
                print!("{text}");
                i32::from(!pass)
            }
            Err(e) => {
                eprintln!("ratatoskr search eval: {e}");
                1
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<EvalCommand, String> {
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
                b: "b.json".into()
            }
        );
        assert!(p(&[]).is_err());
        assert!(p(&["run", "/r", "--device", "tpu"]).is_err());
        assert!(p(&["compare", "a.json"]).is_err());
    }
}
