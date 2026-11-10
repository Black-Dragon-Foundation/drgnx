//! Hrafn's budgets on the hub side (Task 15): the index time of a checkout, one saved file, and the query on synthetic
//! stores of 50,000 and 100,000 chunks. Each row is `#[ignore = "timing: …"]`: it runs by itself on the pinned
//! island of the desktop (`cargo test -p drgnx-ratatoskr --test timing --release -- --ignored --nocapture
//! --test-threads 1`), prints its figures, and asserts the constants below, which are the budget table's.
//!
//! The embedding rows (tokens per second, one question's embedding, VRAM, the stall) are `hrafn-embed/tests/timing.rs`.

use hrafn::{Class, CodeStore, Lang, Listed, Query, Scope, missing, put_vectors, refresh, search};
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The first tier of a project the size of drgnx, in full, without vectors.
const TIER1_FULL_INDEX: Duration = Duration::from_secs(60);
/// A saved file found again by keyword and symbol, after the debounce.
const ONE_FILE_SEARCHABLE: Duration = Duration::from_secs(1);
/// `search/query`, warm (95th percentile): at 50,000 chunks, and at 100,000.
const QUERY_P95: Duration = Duration::from_millis(100);
const QUERY_P95_100K: Duration = Duration::from_millis(200);

const MODEL: &str = "granite-embedding-small-english-r2";
const DIMS: usize = 384;
/// Functions per synthetic file; about 5 fit one chunk at the default budget, so a file is 2 chunks.
const FNS: usize = 10;

const VERBS: [&str; 12] = [
    "parse", "render", "retry", "flush", "resolve", "encode", "split", "merge", "probe", "gather",
    "release", "verify",
];
const NOUNS: [&str; 16] = [
    "request", "buffer", "socket", "session", "token", "header", "frame", "window", "project",
    "symbol", "manifest", "timer", "channel", "record", "snapshot", "queue",
];

/// Calls each synthetic function makes to others, with `refs`: 10 functions a file, 2 chunks, so 20 references a
/// chunk, about 1,000,000 at 50,000 chunks.
const CALLS: usize = 4;

/// The name of synthetic file F's function I.
fn fn_name(f: usize, i: usize) -> String {
    let v = VERBS[(f * 7 + i) % VERBS.len()];
    let n = NOUNS[(f * 3 + i * 5) % NOUNS.len()];
    format!("{v}_{n}_{f}_{i}")
}

/// The CALLS functions synthetic function (F, I) calls, of FILES files' functions: drawn Zipf-like (the probability of
/// the function of rank g goes as 1/(g + 1)), the same for the same function.
fn callees(f: usize, i: usize, files: usize) -> Vec<String> {
    let all = (files * FNS) as f64;
    let mut x = ((f * FNS + i) as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..CALLS)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let u = (x >> 11) as f64 / (1u64 << 53) as f64;
            let g = (all.powf(u) as usize)
                .saturating_sub(1)
                .min(files * FNS - 1);
            fn_name(g / FNS, g % FNS)
        })
        .collect()
}

/// The text of synthetic file F: functions of the shapes the fixture's chunks have (a doc line, a signature, a body);
/// with `Some(files)`, each body also calls [`CALLS`] of those files' functions.
fn file_text(f: usize, refs: Option<usize>) -> String {
    let mut s = String::new();
    for i in 0..FNS {
        let v = VERBS[(f * 7 + i) % VERBS.len()];
        let m = NOUNS[(f + i * 11) % NOUNS.len()];
        let name = fn_name(f, i);
        let n = name.split('_').nth(1).unwrap_or_default();
        let calls: String = refs
            .map(|files| {
                callees(f, i, files)
                    .iter()
                    .map(|c| format!("    let _ = {c}(input, limit);\n"))
                    .collect()
            })
            .unwrap_or_default();
        s.push_str(&format!(
            "/// {v} the {n} of the {m} and report what was {v}ed.\nfn {name}(input: &str, limit: usize) -> Result<Vec<String>, Error> {{\n{calls}    let mut out = Vec::new();\n    for part in input.split(',') {{\n        if part.len() > limit {{ return Err(Error::Long(part.to_string())); }}\n        out.push(format!(\"{{}}-{{}}\", part, {i}));\n    }}\n    Ok(out)\n}}\n\n"
        ));
    }
    s
}

fn listed(path: String, text: &str) -> Listed {
    Listed {
        blob: format!("b{}", text.len()),
        path,
        class: Class::Code,
        lang: Lang::Rust,
        generated: false,
        size: text.len() as u64,
    }
}

/// A unit-ish vector from SEED, the same for the same seed.
fn vector(seed: u64) -> Vec<f32> {
    let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..DIMS)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 40) as f32 / (1u64 << 23) as f32 - 1.0
        })
        .collect()
}

/// A store of about CHUNKS chunks (files of synthetic functions) with a vector for each key; with REFS, the functions
/// call each other ([`callees`]).
async fn synthetic(dir: &Path, chunks: usize, refs: bool) -> CodeStore {
    let store = CodeStore::open(&dir.join("code.db")).unwrap();
    let files = chunks / 2;
    // `refresh` drops the files it is not given: each batch is given all the earlier ones too, as unchanged
    let mut all: Vec<Listed> = Vec::new();
    for from in (0..files).step_by(2_000) {
        let to = (from + 2_000).min(files);
        let texts: HashMap<String, String> = (from..to)
            .map(|f| (format!("src/m{f}.rs"), file_text(f, refs.then_some(files))))
            .collect();
        all.extend(texts.iter().map(|(p, t)| listed(p.clone(), t)));
        refresh(
            &store,
            &all,
            &|p: &str| {
                texts
                    .get(p)
                    .map(|t| t.as_bytes().to_vec())
                    .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
            },
            &[(MODEL, DIMS)],
        )
        .await
        .unwrap();
    }
    let mut seed = 1u64;
    loop {
        let keys = missing(&store, MODEL, 5_000).await.unwrap();
        if keys.is_empty() {
            break;
        }
        let rows: Vec<([u8; 32], Vec<f32>)> = keys
            .into_iter()
            .map(|(k, _)| {
                seed += 1;
                (k, vector(seed))
            })
            .collect();
        put_vectors(&store, MODEL, &rows).await.unwrap();
    }
    store
}

const QUESTIONS: [&str; 10] = [
    "where do we retry a failed request",
    "how is the session token verified",
    "parse the header of a frame",
    "flush the buffer before the socket closes",
    "resolve_window_3_4",
    "release the queue of a project",
    "what merges a snapshot with the manifest",
    "encode the record for the channel",
    "gather every timer symbol",
    "probe_socket_12_7",
];

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    sorted[((sorted.len() as f64 * p).ceil() as usize).clamp(1, sorted.len()) - 1]
}

/// Ask every question ROUNDS times (after one warming round); the sorted times.
async fn ask(store: &CodeStore, view: hrafn::View, vectors: bool, rounds: usize) -> Vec<Duration> {
    let now = |_: &str| None;
    let mut times = Vec::new();
    for round in 0..=rounds {
        for (i, text) in QUESTIONS.iter().enumerate() {
            let q = Query {
                text: (*text).to_string(),
                scope: Scope::Code,
                k: 10,
            };
            let v = vector(10_000 + i as u64);
            let started = Instant::now();
            let a = search(
                store,
                &q,
                view,
                vectors.then_some((MODEL, v.as_slice())),
                &now,
            )
            .await
            .unwrap();
            let took = started.elapsed();
            assert!(!a.hits.is_empty(), "{text}");
            if round > 0 {
                times.push(took);
            }
        }
    }
    times.sort();
    times
}

async fn query_row(chunks: usize, budget: Duration) {
    let dir = tempfile::tempdir().unwrap();
    let built = Instant::now();
    let store = synthetic(dir.path(), chunks, false).await;
    println!("{chunks} chunks built in {:?}", built.elapsed());
    let keyword = ask(&store, hrafn::View::Base, false, 6).await;
    let full = ask(&store, hrafn::View::Base, true, 6).await;
    for (what, t) in [
        ("keyword and symbol only", &keyword),
        ("with vectors", &full),
    ] {
        println!(
            "{chunks} chunks, {what}: p50 {:?} p95 {:?} max {:?}",
            percentile(t, 0.5),
            percentile(t, 0.95),
            t.last().unwrap()
        );
    }
    assert!(
        percentile(&full, 0.95) <= budget,
        "p95 {:?} over {budget:?}",
        percentile(&full, 0.95)
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "timing: search/query p95 at 50,000 chunks"]
async fn query_p95_at_50k_chunks() {
    query_row(50_000, QUERY_P95).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "timing: search/query p95 at 100,000 chunks"]
async fn query_p95_at_100k_chunks() {
    query_row(100_000, QUERY_P95_100K).await;
}

/// The agent tools at 50,000 chunks with references (the plan's estimates; the ledger has the measurements):
/// `search/symbols` and `search/outline` p95, `search/usages` p95, the map cold (graph built) and warm, the graph cache.
const SYMBOLS_P95: Duration = Duration::from_millis(20);
const OUTLINE_P95: Duration = Duration::from_millis(10);
const USAGES_P95: Duration = Duration::from_millis(50);
const MAP_COLD: Duration = Duration::from_millis(1_000);
const MAP_WARM_P95: Duration = Duration::from_millis(150);
const GRAPH_CACHE_BYTES: usize = 64 << 20;

/// Times of F over ROUNDS calls (after one warming call), sorted.
async fn timed<F, Fut>(rounds: usize, mut f: F) -> Vec<Duration>
where
    F: FnMut(usize) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    f(0).await;
    let mut t = Vec::with_capacity(rounds);
    for r in 1..=rounds {
        let started = Instant::now();
        f(r).await;
        t.push(started.elapsed());
    }
    t.sort();
    t
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "timing: repo map, usages, symbols and outline at 50,000 chunks"]
async fn agent_tools_at_50k_chunks() {
    use hrafn::map::{MapAsk, repo_map, usages};
    use hrafn::symbols::{Find, Match, find, outline};
    let dir = tempfile::tempdir().unwrap();
    let built = Instant::now();
    let store = synthetic(dir.path(), 50_000, true).await;
    let files = 25_000;
    let refs: i64 = store
        .handle()
        .read(|c| Ok(c.query_row("select sum(n) from ref", [], |r| r.get(0))?))
        .await
        .unwrap();
    println!(
        "50000 chunks with {refs} references built in {:?}",
        built.elapsed()
    );
    let view = hrafn::View::Base;
    let ask = |budget: usize, focus: Vec<String>| MapAsk {
        budget,
        focus,
        names: vec![],
        all: false,
    };

    let started = Instant::now();
    let m = repo_map(&store, view, &ask(2_000, vec![])).await.unwrap();
    let cold = started.elapsed();
    assert!(m.built && !m.files.is_empty());
    println!(
        "map cold: {cold:?} ({} files, ~{} tokens)",
        m.files.len(),
        m.tokens
    );
    let cache = hrafn::graph::cache_bytes(&store);
    println!("graph cache: {:.1} MB", cache as f64 / (1 << 20) as f64);

    let budgets = [1_000, 2_000, 4_000, 8_000];
    let warm = timed(20, |r| {
        let a = ask(
            budgets[r % 4],
            vec![format!("src/m{}.rs", (r * 997) % files)],
        );
        let s = &store;
        async move {
            let m = repo_map(s, view, &a).await.unwrap();
            assert!(!m.built && m.tokens <= a.budget);
        }
    })
    .await;
    let used = timed(20, |r| {
        let name = fn_name((r * r * 31) % 200, r % FNS);
        let s = &store;
        async move {
            usages(s, view, &name, Scope::All, 20).await.unwrap();
        }
    })
    .await;
    let syms = timed(40, |r| {
        let (name, mode) = if r % 2 == 0 {
            (fn_name((r * 613) % files, r % FNS), Match::Exact)
        } else {
            (
                format!("{}_{}", VERBS[r % 12], NOUNS[r % 16]),
                Match::Prefix,
            )
        };
        let s = &store;
        async move {
            let f = Find {
                name,
                mode,
                kinds: vec![],
                glob: None,
                scope: Scope::All,
                k: 20,
            };
            find(s, view, &f).await.unwrap();
        }
    })
    .await;
    let outlined = timed(40, |r| {
        let path = format!("src/m{}.rs", (r * 389) % files);
        let s = &store;
        async move {
            assert_eq!(outline(s, view, &path).await.unwrap().entries.len(), FNS);
        }
    })
    .await;
    for (what, t) in [
        ("map warm", &warm),
        ("usages", &used),
        ("symbols", &syms),
        ("outline", &outlined),
    ] {
        println!(
            "{what}: p50 {:?} p95 {:?} max {:?}",
            percentile(t, 0.5),
            percentile(t, 0.95),
            t.last().unwrap()
        );
    }
    let over: Vec<String> = [
        ("map cold", cold, MAP_COLD),
        ("map warm p95", percentile(&warm, 0.95), MAP_WARM_P95),
        ("usages p95", percentile(&used, 0.95), USAGES_P95),
        ("symbols p95", percentile(&syms, 0.95), SYMBOLS_P95),
        ("outline p95", percentile(&outlined, 0.95), OUTLINE_P95),
    ]
    .iter()
    .filter(|(_, t, b)| t > b)
    .map(|(w, t, b)| format!("{w} {t:?} over {b:?}"))
    .chain(
        (cache > GRAPH_CACHE_BYTES)
            .then(|| format!("graph cache {cache} over {GRAPH_CACHE_BYTES}")),
    )
    .collect();
    assert!(over.is_empty(), "{over:?}");
}

/// A worktree's search (H16 overlay design §7): p95 ≤ 50 ms, and ≤ 1.15× the same query in the base view.
const WORKTREE_P95: Duration = Duration::from_millis(50);
const WORKTREE_RATIO: f64 = 1.15;

/// TREE's version of synthetic file F on LINE: the base's text with a line's own change.
fn line_text(f: usize, line: usize) -> String {
    format!(
        "{}// line {line}: {}\n",
        file_text(f, None),
        VERBS[(f + line) % VERBS.len()]
    )
}

/// Report-only (§11 `worktree-search-p95`): §7's fixture, 50,000 base chunks and 10 resident trees on 2 lines, each
/// differing in about 32 % of the base's files (the measured p50 share), siblings sharing their line's content; the
/// same questions in the base view and in a tree's. It prints both and the ratio, and never fails on them; the
/// pinned island judges it. It also shows what `chunk.blob` after `embed_text` costs a row read by id.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "timing: search/query p95 in a worktree's view, report only"]
async fn worktree_search_p95() {
    let dir = tempfile::tempdir().unwrap();
    let built = Instant::now();
    let store = synthetic(dir.path(), 50_000, false).await;
    let files = 25_000;
    let mut trees = Vec::new();
    for n in 0..10 {
        let line = n / 5;
        let t = store
            .tree_open(
                &format!("wt-{n}"),
                &format!("/w/{n}"),
                "/g",
                hrafn::DoorKind::Cli,
            )
            .await
            .unwrap();
        for f in (0..files).filter(|f| (f * 31 + line * 17) % 100 < 32) {
            let text = line_text(f, line);
            let path = format!("src/m{f}.rs");
            let (chunks, symbols) =
                hrafn::chunk::chunk_file(&path, Lang::Rust, false, &text, hrafn::chunk::BUDGET);
            let chunks = chunks
                .into_iter()
                .map(|c| hrafn::ChunkIn {
                    start: c.start,
                    end: c.end,
                    line_start: c.line_start,
                    line_end: c.line_end,
                    symbol: c.symbol,
                    key: hrafn::vec_key(hrafn::chunk::CHUNKER_VERSION, &c.embed_text),
                    embed: c.embed,
                    embed_text: c.embed_text,
                    symbols: c.fts.symbols,
                    doc: c.fts.doc,
                    body: c.fts.body,
                })
                .collect();
            let symbols = symbols
                .into_iter()
                .map(|y| hrafn::SymbolIn {
                    name: y.name,
                    kind: y.kind,
                    start: y.start,
                    end: y.end,
                    chunk: y.chunk as usize,
                    definer: y.definer,
                    doc1: y.doc1,
                    line_start: y.line_start,
                    line_end: y.line_end,
                    sig: y.sig,
                })
                .collect();
            let row = hrafn::FileRow {
                path,
                blob: Some(format!("l{line}-{f}")),
                class: "code".into(),
                lang: "rust".into(),
                generated: false,
                size: text.len() as u64,
                indexed_at: 1,
            };
            store
                .write_file(hrafn::View::Tree(t), row, chunks, symbols)
                .await
                .unwrap();
        }
        trees.push(t);
    }
    let mut seed = 1_000_000u64;
    loop {
        let keys = missing(&store, MODEL, 5_000).await.unwrap();
        if keys.is_empty() {
            break;
        }
        let rows: Vec<([u8; 32], Vec<f32>)> = keys
            .into_iter()
            .map(|(k, _)| {
                seed += 1;
                (k, vector(seed))
            })
            .collect();
        put_vectors(&store, MODEL, &rows).await.unwrap();
    }
    println!("50,000 chunks and 10 trees built in {:?}", built.elapsed());
    let base = ask(&store, hrafn::View::Base, true, 6).await;
    let tree = ask(&store, hrafn::View::Tree(trees[7]), true, 6).await;
    let (b, t) = (percentile(&base, 0.95), percentile(&tree, 0.95));
    println!(
        "base view: p50 {:?} p95 {b:?}; worktree view: p50 {:?} p95 {t:?}; ratio {:.2} (targets {WORKTREE_P95:?}, \
         {WORKTREE_RATIO})",
        percentile(&base, 0.5),
        percentile(&tree, 0.5),
        t.as_secs_f64() / b.as_secs_f64()
    );
}

/// The text files of drgnx's own checkout (this crate's workspace and the Lisp), as a project's listing.
fn checkout_files() -> Vec<(String, PathBuf)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let mut out = Vec::new();
    let mut stack: Vec<PathBuf> = [
        "core",
        "modules",
        "wb",
        "harness",
        "docs",
        "runtime/crates",
        "bin",
        "test/unit",
    ]
    .iter()
    .map(|d| root.join(d))
    .collect();
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if p.is_dir() {
                if name != "target" && !name.starts_with('.') {
                    stack.push(p);
                }
            } else if ["el", "rs", "md"]
                .iter()
                .any(|x| name.ends_with(&format!(".{x}")))
            {
                let rel = p
                    .strip_prefix(&root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned();
                out.push((rel, p));
            }
        }
    }
    out.sort();
    out
}

fn lang_of(path: &str) -> (Lang, Class) {
    match path.rsplit('.').next() {
        Some("el") => (Lang::Elisp, Class::Code),
        Some("rs") => (Lang::Rust, Class::Code),
        _ => (Lang::Markdown, Class::Docs),
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "timing: tier 1 of a drgnx checkout, and one saved file"]
async fn tier1_of_a_checkout_and_one_saved_file() {
    let files = checkout_files();
    let texts: HashMap<String, Vec<u8>> = files
        .iter()
        .filter_map(|(rel, p)| std::fs::read(p).ok().map(|b| (rel.clone(), b)))
        .collect();
    let mut list: Vec<Listed> = texts
        .iter()
        .map(|(rel, b)| {
            let (lang, class) = lang_of(rel);
            Listed {
                path: rel.clone(),
                blob: format!("b{}", b.len()),
                class,
                lang,
                generated: false,
                size: b.len() as u64,
            }
        })
        .collect();
    list.sort_by(|a, b| a.path.cmp(&b.path));
    let dir = tempfile::tempdir().unwrap();
    let store = CodeStore::open(&dir.path().join("code.db")).unwrap();
    let started = Instant::now();
    let read = |p: &str| {
        texts
            .get(p)
            .cloned()
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    };
    let r = refresh(&store, &list, &read, &[(MODEL, DIMS)])
        .await
        .unwrap();
    let full = started.elapsed();
    println!(
        "tier 1 of {} files, {} chunks: {full:?}",
        list.len(),
        r.chunks_written
    );
    assert!(
        full <= TIER1_FULL_INDEX,
        "{full:?} over {TIER1_FULL_INDEX:?}"
    );

    // one saved file: its blob changes, tier 1 reads it again, and its new name is found by symbol and keyword
    let mut texts = texts;
    let target = "core/drgnx-timer.el".to_string();
    let mut text = texts[&target].clone();
    text.extend_from_slice(
        b"\n(defun drgnx-bench-brand-new-symbol () \"A brand new function.\" 1)\n",
    );
    texts.insert(target.clone(), text);
    for l in &mut list {
        if l.path == target {
            l.blob = "changed".into();
        }
    }
    let read = |p: &str| {
        texts
            .get(p)
            .cloned()
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    };
    let started = Instant::now();
    refresh(&store, &list, &read, &[(MODEL, DIMS)])
        .await
        .unwrap();
    let a = search(
        &store,
        &Query {
            text: "drgnx-bench-brand-new-symbol".into(),
            scope: Scope::Code,
            k: 5,
        },
        hrafn::View::Base,
        None,
        &|_: &str| None,
    )
    .await
    .unwrap();
    let saved = started.elapsed();
    println!("one saved file, to its symbol found: {saved:?}");
    assert_eq!(a.hits[0].path, target);
    assert!(
        saved <= ONE_FILE_SEARCHABLE,
        "{saved:?} over {ONE_FILE_SEARCHABLE:?}"
    );

    // what the references add to the store: the pages of `ref` and its index against the rest (reported)
    let (total, refs): (i64, i64) = store
        .handle()
        .read(|c| {
            let pages: i64 = c.query_row("pragma page_count", [], |r| r.get(0))?;
            let page: i64 = c.query_row("pragma page_size", [], |r| r.get(0))?;
            let refs: i64 = c.query_row(
                "select coalesce(sum(pgsize), 0) from dbstat where name in ('ref', 'ref_name')",
                [],
                |r| r.get(0),
            )?;
            Ok((pages * page, refs))
        })
        .await
        .unwrap();
    println!(
        "store {total} bytes, of which references {refs}: +{:.1} % over the rest",
        refs as f64 * 100.0 / (total - refs) as f64
    );
}
