//! `ratatoskr search eval run --source …`: the eval takes its vectors from a server (TEI, Ollama, llama.cpp) without the
//! hub or the gateway, and `--query-source` embeds the questions with another one. The servers are `ratatoskr-mock
//! embed`, the stand-in for what is outside drgnx; the eval binary, the chunker, the store and the scoring are real.
//!
//! test-pattern: handshake (C): the mock prints its port, a run is over when the process exits, and what the mock saw
//! is read from its log after that.
#![cfg(feature = "test-hooks")]

use hrafn::Scope;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

fn mock_bin() -> PathBuf {
    let bin = skuld::workspace_bin("ratatoskr-mock", None, Some("RATATOSKR_MOCK"));
    assert!(
        bin.exists(),
        "{} is missing: build it first (cargo build -p domr --bin ratatoskr-mock) or name it in RATATOSKR_MOCK",
        bin.display()
    );
    bin
}

/// `ratatoskr-mock embed`: TEI's `/embed`, Ollama's `/api/embed` and llama.cpp's `/v1/embeddings` on 127.0.0.1, logging
/// every request.
struct Server {
    child: Child,
    port: u16,
    log: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Server {
    fn start(dir: &Path, name: &str) -> Server {
        let log = dir.join(format!("{name}.log"));
        let mut child = Command::new(mock_bin())
            .args(["embed", "--dims", "8", "--log"])
            .arg(&log)
            .arg("--parent")
            .arg(std::process::id().to_string())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let port = line
            .trim()
            .strip_prefix("MOCK-EMBED-PORT ")
            .unwrap()
            .parse()
            .unwrap();
        Server { child, port, log }
    }

    fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    /// What reached the server: `(path, body)`, in order.
    fn requests(&self) -> Vec<(String, Value)> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|v| v.get("request").cloned())
            .map(|r| {
                (
                    r["path"].as_str().unwrap().to_owned(),
                    serde_json::from_str(r["body"].as_str().unwrap()).unwrap(),
                )
            })
            .collect()
    }

    /// Every text sent, in order, whatever the API: TEI's `inputs`, Ollama's and llama.cpp's `input`.
    fn texts(&self) -> Vec<String> {
        self.requests()
            .iter()
            .flat_map(|(_, b)| {
                let v = if b.get("inputs").is_some() {
                    &b["inputs"]
                } else {
                    &b["input"]
                };
                match v {
                    Value::String(s) => vec![s.clone()],
                    Value::Array(a) => a.iter().map(|t| t.as_str().unwrap().to_owned()).collect(),
                    other => panic!("no texts in {other}"),
                }
            })
            .collect()
    }
}

fn git(dir: &Path, args: &[&str]) {
    let st = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

const QUESTIONS: [&str; 2] = [
    "where does the greeting get built",
    "how are two numbers added together",
];

/// A two-file Python project in a git repo, and the two questions asked of it.
fn fixture(dir: &Path) -> (PathBuf, PathBuf) {
    let root = dir.join("proj");
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q"]);
    std::fs::write(
        root.join("greet.py"),
        "def build_greeting(name):\n    return 'hello ' + name\n",
    )
    .unwrap();
    std::fs::write(
        root.join("math_ops.py"),
        "def add_numbers(a, b):\n    return a + b\n",
    )
    .unwrap();
    git(&root, &["add", "-A"]);
    git(&root, &["commit", "-q", "-m", "one"]);
    let rows = dir.join("test.jsonl");
    let row = |id: &str, q: &str, path: &str, sym: &str| {
        json!({"id": id, "stratum": "symbol", "query": q, "targets": [[path, sym]],
               "age_days": 0, "dir": ".", "half": "test"})
        .to_string()
    };
    std::fs::write(
        &rows,
        format!(
            "{}\n{}\n",
            row("000000000001", QUESTIONS[0], "greet.py", "build_greeting"),
            row("000000000002", QUESTIONS[1], "math_ops.py", "add_numbers")
        ),
    )
    .unwrap();
    (root, rows)
}

/// `ratatoskr search eval run ROOT …` with a home of its own; its JSON report.
fn eval_run(dir: &Path, root: &Path, rows: &Path, tag: &str, extra: &[&str]) -> Value {
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let out = dir.join(format!("{tag}.json"));
    let run = Command::new(env!("CARGO_BIN_EXE_ratatoskr"))
        .args(["search", "eval", "run"])
        .arg(root)
        .arg("--rows")
        .arg(rows)
        .args(["--set", "test", "--models"])
        .arg(dir.join("no-models"))
        .arg("--out")
        .arg(&out)
        .args(extra)
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env("XDG_DATA_HOME", home.join("data"))
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env("XDG_CACHE_HOME", home.join("cache"))
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "{tag}: {}\n{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    serde_json::from_slice(&std::fs::read(&out).unwrap()).unwrap()
}

fn query_text(q: &str) -> String {
    format!("Instruct: {}\nQuery:{q}", Scope::All.instruction())
}

/// Pattern C. A TEI source embeds every chunk once, plain, and every question with the `Instruct:` prefix.
#[test]
fn server_source_embeds_every_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let (root, rows) = fixture(dir.path());
    let tei = Server::start(dir.path(), "tei");
    let source = format!("tei:{}", tei.url());
    let report = eval_run(dir.path(), &root, &rows, "run", &["--source", &source]);
    assert_eq!(report["source"], source.as_str());
    assert!(report["embed_seconds_per_chunk"].is_number(), "{report}");
    let chunks = report["chunks_embedded"].as_u64().unwrap() as usize;
    assert!(chunks >= 2, "{report}");

    let seen = tei.texts();
    let (asked, docs): (Vec<&String>, Vec<&String>) =
        seen.iter().partition(|t| t.starts_with("Instruct: "));
    // a path's vector rides along with its chunks (Wave 4): its text is `hrafn::path_text` of a listed path, so it is
    // told from a chunk's text by what it is, never by count
    let path_texts: BTreeSet<String> = ["greet.py", "math_ops.py"]
        .iter()
        .map(|p| hrafn::path_text(p))
        .collect();
    let (paths, docs): (Vec<&String>, Vec<&String>) =
        docs.into_iter().partition(|t| path_texts.contains(*t));
    assert_eq!(
        paths.iter().collect::<BTreeSet<_>>().len(),
        paths.len(),
        "no path twice: {paths:?}"
    );
    assert!(
        paths.iter().any(|t| t.starts_with("greet.py\n")),
        "the path vectors are embedded too: {paths:?}"
    );
    assert_eq!(docs.len(), chunks, "every chunk once: {docs:?}");
    assert_eq!(
        docs.iter().collect::<BTreeSet<_>>().len(),
        chunks,
        "no chunk twice: {docs:?}"
    );
    assert!(docs.iter().any(|t| t.contains("def build_greeting")));
    assert!(docs.iter().any(|t| t.contains("def add_numbers")));
    for q in QUESTIONS {
        assert!(
            asked.iter().any(|t| **t == query_text(q)),
            "{q:?} reached the server without its instruction: {asked:?}"
        );
        assert!(!seen.iter().any(|t| t == q), "{q:?} went plain");
    }
}

/// Pattern C. A second run over the first's `--state`, with another `--query-source`, sends no document text to the
/// first server, and every question goes to the second.
#[test]
fn query_source_reuses_state_vectors() {
    let dir = tempfile::tempdir().unwrap();
    let (root, rows) = fixture(dir.path());
    let state = dir.path().join("state-dir");
    let docs_source = Server::start(dir.path(), "docs");
    let asks = Server::start(dir.path(), "asks");
    let source = format!("tei:{}", docs_source.url());
    let state_arg = state.to_str().unwrap();
    let first = eval_run(
        dir.path(),
        &root,
        &rows,
        "first",
        &["--source", &source, "--state", state_arg],
    );
    assert!(first["chunks_embedded"].as_u64().unwrap() >= 2);
    let before = docs_source.texts().len();

    let query_source = format!("tei:{}", asks.url());
    let second = eval_run(
        dir.path(),
        &root,
        &rows,
        "second",
        &[
            "--source",
            &source,
            "--query-source",
            &query_source,
            "--state",
            state_arg,
        ],
    );
    assert_eq!(
        second["chunks_embedded"], 0,
        "the vectors in --state are reused"
    );
    let later = docs_source.texts().split_off(before);
    assert!(
        later.iter().all(|t| t.starts_with("Instruct: ")),
        "document text went to the first server again: {later:?}"
    );
    let asked = asks.texts();
    assert!(!asked.is_empty());
    for q in QUESTIONS {
        assert!(
            asked.iter().any(|t| *t == query_text(q)),
            "{q:?}: {asked:?}"
        );
    }
    assert!(
        asked.iter().all(|t| t.starts_with("Instruct: ")),
        "the query source saw a document: {asked:?}"
    );
}

/// Pattern C. Ollama and llama.cpp are spoken to in their own APIs: Ollama's `/api/embed` with the model, no truncation
/// and a context size, llama.cpp's `/v1/embeddings`.
#[test]
fn ollama_and_llama_sources_speak_their_apis() {
    let dir = tempfile::tempdir().unwrap();
    let (root, rows) = fixture(dir.path());
    let ollama = Server::start(dir.path(), "ollama");
    let llama = Server::start(dir.path(), "llama");
    let o = format!("ollama:{}:qwen3-embedding:0.6b", ollama.url());
    eval_run(dir.path(), &root, &rows, "o", &["--source", &o]);
    let seen = ollama.requests();
    assert!(!seen.is_empty());
    for (path, body) in &seen {
        assert_eq!(path, "/api/embed");
        assert_eq!(body["model"], "qwen3-embedding:0.6b");
        assert_eq!(body["truncate"], false, "{body}");
        assert!(
            body["options"]["num_ctx"].as_u64().unwrap() >= 2048,
            "{body}"
        );
    }
    let l = format!("llama:{}", llama.url());
    eval_run(dir.path(), &root, &rows, "l", &["--source", &l]);
    let seen = llama.requests();
    assert!(!seen.is_empty());
    assert!(seen.iter().all(|(p, _)| p == "/v1/embeddings"), "{seen:?}");
}
