//! A fetched pack's files go through the parse worker (language packs Task 6b-1): the chunker asks the installed fetched
//! packs before it reads a `Text` file as text; the worker's answer is the file's chunks, symbols and references; a worker
//! that cannot run leaves the file as text, said once; installing, changing or removing a pack moves the language stamp.
//!
//! The worker here runs in-process on two pipes (`serve` is the same code the `ratatoskr hrafn-parse` process runs), on the
//! C# grammar the pack job built, under an extension no built-in language has. The process, the sandbox and the broken
//! grammars are `drgnx-ratatoskr`'s `hrafn_parse*` tests. One test, because the installed set is the process's.
//!
//! test-pattern: pure (D).

use hrafn::chunk::worker::{self, Fetched, Init, Launch, Started, WorkerSpec, serve};
use hrafn::chunk::{BUDGET, chunk_file_refs, lang_stamp};
use hrafn::{Lang, classify};
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// Runs `serve` on two pipes instead of a process.
struct InProcess;

impl Launch for InProcess {
    fn start(&self, s: &WorkerSpec) -> Result<Started, String> {
        let (req_r, req_w) = io::pipe().map_err(|e| e.to_string())?;
        let (rep_r, rep_w) = io::pipe().map_err(|e| e.to_string())?;
        let (lib, grammar, sha) = (s.lib.clone(), s.grammar.clone(), s.sha256.clone());
        std::thread::spawn(move || {
            let (mut r, mut w) = (req_r, rep_w);
            serve(&lib, &grammar, &sha, &mut r, &mut w);
        });
        Ok(Started {
            stdin: Box::new(req_w),
            stdout: Box::new(rep_r),
            kill: Box::new(|| {}),
            stderr: Box::new(String::new),
        })
    }
}

struct Refuses;

impl Launch for Refuses {
    fn start(&self, _: &WorkerSpec) -> Result<Started, String> {
        Err("the sandbox is on its reduced tier".into())
    }
}

fn csharp_lib() -> (PathBuf, String) {
    let lock = PathBuf::from(std::env::var_os("DRGNX_PACK_LOCK").expect("DRGNX_PACK_LOCK"));
    let grammars =
        PathBuf::from(std::env::var_os("DRGNX_PACK_GRAMMARS").expect("DRGNX_PACK_GRAMMARS"));
    let e = skald::registry::from_lock(&std::fs::read(lock).unwrap(), &grammars)
        .unwrap()
        .into_iter()
        .find(|e| e.name == "c-sharp")
        .expect("c-sharp is in the lock");
    (e.lib, e.sha256)
}

fn fetched() -> Fetched {
    let (lib, sha256) = csharp_lib();
    let pack = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packs/csharp");
    let m = skald::builtin::get("csharp").unwrap();
    Fetched {
        spec: WorkerSpec {
            pack: "csharpx".into(),
            lib,
            grammar: "c-sharp".into(),
            sha256,
        },
        init: Init {
            chunks_scm: std::fs::read_to_string(pack.join("queries/chunks.scm")).unwrap(),
            tags_scm: Some(std::fs::read_to_string(pack.join("queries/tags.scm")).unwrap()),
            docs: m
                .hrafn
                .as_ref()
                .and_then(|h| h.docs.clone())
                .unwrap_or_default(),
        },
        // no built-in language has it: the file is `Text` until a fetched pack claims it
        extensions: vec!["xcs".into()],
    }
}

static SAID: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

fn said(pack: &str, why: &str) {
    SAID.lock().unwrap().push((pack.into(), why.into()));
}

#[test]
fn a_fetched_packs_files_are_chunked_by_its_worker_and_read_as_text_when_it_cannot_run() {
    hrafn::chunk::on_missing(said);
    let text = "namespace N { class Cache { void Put(int k) {} } }\n";
    let path = "src/Cache.xcs";
    // before: text, no symbols
    assert_eq!(classify(path, text.as_bytes()).0, Lang::Text);
    let before = chunk_file_refs(path, Lang::Text, false, text, BUDGET);
    assert!(before.1.is_empty());
    let stamp0 = lang_stamp();

    // installed: the worker's chunks, symbols and references, the same a built-in C# file gives
    worker::install(vec![fetched()], Arc::new(InProcess));
    assert_eq!(worker::claims(path).as_deref(), Some("csharpx"));
    assert_eq!(worker::claims("src/other.rs"), None);
    let (chunks, symbols, _) = chunk_file_refs(path, Lang::Text, false, text, BUDGET);
    let (c2, s2, _) = chunk_file_refs("Cache.cs", Lang::Csharp, false, text, BUDGET);
    let names = |v: &[hrafn::chunk::Symbol]| -> Vec<(String, String)> {
        v.iter().map(|s| (s.name.clone(), s.kind.clone())).collect()
    };
    assert_eq!(names(&symbols), names(&s2));
    assert!(names(&symbols).contains(&("Put".into(), "method".into())));
    assert_eq!(chunks.len(), c2.len());
    assert!(SAID.lock().unwrap().is_empty());
    // the stamp moved with the install: the index parses a project's files again
    let stamp1 = lang_stamp();
    assert_ne!(stamp0, stamp1);

    // a worker that cannot run: the file is text again, said once with the reason, the stamp moves again
    worker::install(vec![fetched()], Arc::new(Refuses));
    let (chunks, symbols, _) = chunk_file_refs(path, Lang::Text, false, text, BUDGET);
    assert!(symbols.is_empty());
    assert!(!chunks.is_empty(), "the file is still indexed, as text");
    let _ = chunk_file_refs(path, Lang::Text, false, text, BUDGET);
    let said_now = SAID.lock().unwrap().clone();
    assert_eq!(said_now.len(), 1, "{said_now:?}");
    assert_eq!(said_now[0].0, "csharpx");
    assert!(said_now[0].1.contains("reduced tier"), "{said_now:?}");
    assert_eq!(worker::dead().len(), 1);

    // removed: nothing claims it, and the stamp is what it was
    worker::install(vec![], Arc::new(Refuses));
    assert_eq!(worker::claims(path), None);
    assert_eq!(lang_stamp(), stamp0);
}
