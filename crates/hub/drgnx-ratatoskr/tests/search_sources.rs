//! Tier 2 as a chain of sources per fingerprint (Hrafn redesign Tasks 14 and 15): the cache first, lookup sources that
//! get keys only, the first embedder that answers, the same batch falling through on a failure, a backoff per source, the
//! built-in model only while the main chain idles, open files first, and the battery rule.
//!
//! The chain, the cache, the store and the project are the real ones. What stands in is what is outside them: a remote
//! (`Fake`: a source the test steers and records) and TEI (`ratatoskr-mock embed`, through the gateway).
//!
//! test-pattern: pure (D): time is the `now` each call is given, nothing sleeps.
#![cfg(feature = "test-hooks")]

use crate::search_prefer::{Server, gate, tei};
use drgnx_ratatoskr::embed::is_loopback;
use drgnx_ratatoskr::search::caches::Caches;
use drgnx_ratatoskr::search::project::{Project, ProjectSpec};
use drgnx_ratatoskr::search::sources::{
    DocSource, FillOutcome, Item, Slot, Source, SourceChain, SourceKind, run_pass,
};
use drgnx_ratatoskr::search::{DocEmbedder, EMBED_TEXT_VERSION, TEST_TINY};
use hrafn::{CodeStore, KeyKind, QuantRow, VectorCache};
use hrafn_embed::fingerprint::{Identity, builtin_record};
use serde_json::json;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::time::Instant;
use urdr::graph::search::{BoxFuture, EmbedError};

const DIMS: usize = 8;

fn t0() -> Instant {
    Instant::from_std(skuld::origin())
}

/// An identity of the tiny test model under another name: its own fingerprint, 8 dims.
fn ident(model: &str) -> Identity {
    let mut r = builtin_record(&TEST_TINY, EMBED_TEXT_VERSION);
    r.model_id = model.into();
    Identity::new(r, model)
}

/// A source the test steers: up or down, and what reached it is recorded.
struct Fake {
    id: String,
    kind: SourceKind,
    ident: Option<Identity>,
    may_text: bool,
    batch: usize,
    up: AtomicBool,
    /// The texts of each `embed` call, whether it answered or not.
    embeds: Mutex<Vec<Vec<String>>>,
    /// Each `lookup` call: the kind and how many keys (a lookup has no text to carry).
    lookups: Mutex<Vec<(KeyKind, usize)>>,
    /// What a lookup answers from.
    remote: Option<Arc<VectorCache>>,
}

impl Fake {
    fn new(id: &str, kind: SourceKind, ident: Option<Identity>) -> Fake {
        Fake {
            id: id.into(),
            kind,
            ident,
            may_text: matches!(
                kind,
                SourceKind::Embed | SourceKind::LocalEngine | SourceKind::Builtin
            ),
            batch: 8,
            up: AtomicBool::new(true),
            embeds: Mutex::new(Vec::new()),
            lookups: Mutex::new(Vec::new()),
            remote: None,
        }
    }

    fn embedder(id: &str, ident: &Identity) -> Arc<Fake> {
        Arc::new(Fake::new(id, SourceKind::Embed, Some(ident.clone())))
    }

    fn down(self: Arc<Self>) -> Arc<Self> {
        self.up.store(false, Ordering::SeqCst);
        self
    }

    fn set_up(&self, up: bool) {
        self.up.store(up, Ordering::SeqCst);
    }

    fn embeds(&self) -> Vec<Vec<String>> {
        self.embeds.lock().unwrap().clone()
    }

    fn lookups(&self) -> Vec<(KeyKind, usize)> {
        self.lookups.lock().unwrap().clone()
    }
}

impl Source for Fake {
    fn id(&self) -> &str {
        &self.id
    }
    fn kind(&self) -> SourceKind {
        self.kind
    }
    fn identity(&self) -> Option<Identity> {
        self.ident.clone()
    }
    fn may_send_text(&self) -> bool {
        self.may_text
    }
    fn max_batch(&self) -> usize {
        self.batch
    }
    fn lookup<'a>(
        &'a self,
        kind: KeyKind,
        keys: &'a [[u8; 32]],
    ) -> BoxFuture<'a, Result<Vec<Option<QuantRow>>, EmbedError>> {
        self.lookups.lock().unwrap().push((kind, keys.len()));
        Box::pin(async move {
            if !self.up.load(Ordering::SeqCst) {
                return Err(EmbedError(format!("{} is down", self.id)));
            }
            let Some(remote) = &self.remote else {
                return Ok(vec![None; keys.len()]);
            };
            let rows = remote
                .get(kind, keys)
                .await
                .map_err(|e| EmbedError(e.to_string()))?;
            Ok(keys
                .iter()
                .map(|k| rows.iter().find(|r| r.key == *k).cloned())
                .collect())
        })
    }
    fn embed<'a>(
        &'a self,
        items: &'a [Item],
        _overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>> {
        self.embeds
            .lock()
            .unwrap()
            .push(items.iter().map(|(_, _, t)| t.clone()).collect());
        let up = self.up.load(Ordering::SeqCst);
        Box::pin(async move {
            if !up {
                return Err(EmbedError(format!("{} is down", self.id)));
            }
            Ok(vec![vec![0.5; DIMS]; items.len()])
        })
    }
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>> {
        Box::pin(async move {
            self.ident
                .clone()
                .ok_or_else(|| EmbedError("no identity".into()))
        })
    }
}

fn items(range: std::ops::Range<u8>) -> Vec<Item> {
    range
        .map(|i| (KeyKind::Chunk, [i; 32], format!("text{i}")))
        .collect()
}

fn chain(id: &Identity, sources: &[&Arc<Fake>]) -> SourceChain {
    SourceChain::new(
        id.fp,
        sources
            .iter()
            .map(|s| Arc::clone(*s) as Arc<dyn Source>)
            .collect(),
    )
}

async fn has_all(cache: &VectorCache, range: std::ops::Range<u8>) -> bool {
    let keys: Vec<[u8; 32]> = range.map(|i| [i; 32]).collect();
    cache
        .has(KeyKind::Chunk, &keys)
        .await
        .unwrap()
        .iter()
        .all(|h| *h)
}

/// Pattern D. A key the cache has is neither looked up nor embedded: no source is asked.
#[tokio::test]
async fn cache_hit_sends_nothing() {
    let state = tempfile::tempdir().unwrap();
    let id = ident("hit");
    let cache = Caches::shared(state.path()).get(&id).await.unwrap();
    cache
        .put(KeyKind::Chunk, DIMS as u32, &[([1; 32], vec![0.5; DIMS])])
        .await
        .unwrap();
    let (look, e) = (
        Arc::new(Fake::new("look", SourceKind::Lookup, None)),
        Fake::embedder("e", &id),
    );
    let mut c = chain(&id, &[&look, &e]);
    let out = c.fill(&cache, &items(1..2), t0()).await;
    assert_eq!(
        out,
        FillOutcome::Filled {
            n: 1,
            from: "cache".into()
        }
    );
    assert!(e.embeds().is_empty() && look.lookups().is_empty());
}

/// Pattern C. Lookup sources are asked first, with keys; only the keys they miss reach the embedder, as texts. TEI is
/// `ratatoskr-mock embed` through the gateway.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn lookup_before_embed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path());
    let g = gate(
        dir.path(),
        json!([tei(&format!("http://127.0.0.1:{}", server.port))]),
    )
    .await;
    let e = g.embedders(&[]).unwrap().remove(0);
    let id = DocEmbedder::probe(&e).await.unwrap();
    let state = tempfile::tempdir().unwrap();
    let cache = Caches::shared(state.path()).get(&id).await.unwrap();
    // the remote holds the first two keys
    let theirs = tempfile::tempdir().unwrap();
    let remote = Caches::shared(theirs.path()).get(&id).await.unwrap();
    remote
        .put(
            KeyKind::Chunk,
            DIMS as u32,
            &[([0; 32], vec![0.25; DIMS]), ([1; 32], vec![0.75; DIMS])],
        )
        .await
        .unwrap();
    let mut look = Fake::new("look", SourceKind::Lookup, None);
    look.remote = Some(remote);
    let look = Arc::new(look);
    let provider: Arc<dyn Source> = Arc::new(DocSource::new(Arc::new(e)));
    let mut c = SourceChain::new(id.fp, vec![look.clone(), provider]);
    let out = c.fill(&cache, &items(0..3), t0()).await;
    assert_eq!(
        out,
        FillOutcome::Filled {
            n: 3,
            from: "tei".into()
        }
    );
    assert!(has_all(&cache, 0..3).await);
    assert_eq!(look.lookups(), [(KeyKind::Chunk, 3)], "keys, asked once");
    // the server saw the one text the remote could not answer, and none of the others
    let sent: Vec<String> = server
        .embeds()
        .iter()
        .flat_map(|(_, b)| b["inputs"].as_array().cloned().unwrap_or_default())
        .map(|t| t.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(sent, ["text2"], "{sent:?}");
}

/// Pattern D. A lookup source never receives a text, even when it claims it may: the wrapper refuses before the source
/// is reached, and the chain ends with nothing to send to.
#[tokio::test]
async fn lookup_only_source_never_sees_text() {
    let state = tempfile::tempdir().unwrap();
    let id = ident("lookup-only");
    let cache = Caches::shared(state.path()).get(&id).await.unwrap();
    let mut look = Fake::new("look", SourceKind::Lookup, None);
    look.may_text = true;
    let look = Arc::new(look);
    let mut c = chain(&id, &[&look]);
    assert_eq!(
        c.fill(&cache, &items(0..2), t0()).await,
        FillOutcome::AllDown
    );
    assert_eq!(look.lookups(), [(KeyKind::Chunk, 2)]);
    assert!(look.embeds().is_empty(), "text reached a lookup source");
    // and a source that may not send text (a remote not marked trusted) gets none either
    let mut shy = Fake::new("shy", SourceKind::Embed, Some(id.clone()));
    shy.may_text = false;
    let shy = Arc::new(shy);
    let mut c = chain(&id, &[&shy]);
    assert_eq!(
        c.fill(&cache, &items(0..2), t0()).await,
        FillOutcome::AllDown
    );
    assert!(shy.embeds().is_empty(), "text reached an untrusted source");
}

/// Pattern D. A source that fails marks itself down and the same batch, in the same order, goes to the next one.
#[tokio::test]
async fn failure_falls_through_same_batch() {
    let state = tempfile::tempdir().unwrap();
    let id = ident("fall");
    let cache = Caches::shared(state.path()).get(&id).await.unwrap();
    let (e1, e2) = (Fake::embedder("e1", &id).down(), Fake::embedder("e2", &id));
    let mut c = chain(&id, &[&e1, &e2]);
    let out = c.fill(&cache, &items(0..3), t0()).await;
    assert_eq!(
        out,
        FillOutcome::Filled {
            n: 3,
            from: "e2".into()
        }
    );
    let texts: Vec<String> = ["text0", "text1", "text2"].map(String::from).to_vec();
    assert_eq!(
        e1.embeds(),
        std::slice::from_ref(&texts),
        "asked once, and it failed"
    );
    assert_eq!(
        e2.embeds(),
        std::slice::from_ref(&texts),
        "the same batch, the same order"
    );
    assert!(has_all(&cache, 0..3).await);
}

/// Pattern D (virtual clock: the `now` each fill is given). Each source waits its own 1, 5 and 30 minutes; the one that
/// answers is never held back by the one that is down.
#[tokio::test]
async fn backoff_per_source_on_virtual_clock() {
    let state = tempfile::tempdir().unwrap();
    let id = ident("backoff");
    let cache = Caches::shared(state.path()).get(&id).await.unwrap();
    let (e1, e2) = (Fake::embedder("e1", &id).down(), Fake::embedder("e2", &id));
    let mut c = chain(&id, &[&e1, &e2]);
    let s = Duration::from_secs;
    let mut next = 0u8;
    let mut fill = async |at: Duration| {
        let batch = items(next..next + 1);
        next += 1;
        c.fill(&cache, &batch, t0() + at).await
    };
    fill(s(0)).await;
    assert_eq!((e1.embeds().len(), e2.embeds().len()), (1, 1));
    fill(s(30)).await;
    assert_eq!(
        (e1.embeds().len(), e2.embeds().len()),
        (1, 2),
        "e1 waits its minute, e2 goes on"
    );
    fill(s(61)).await;
    assert_eq!(e1.embeds().len(), 2, "asked again after a minute");
    fill(s(61 + 299)).await;
    assert_eq!(e1.embeds().len(), 2, "its second wait is five minutes");
    fill(s(61 + 301)).await;
    assert_eq!(e1.embeds().len(), 3);
    // it answers again once its wait is over, and takes the first place back
    e1.set_up(true);
    fill(s(61 + 301 + 30 * 60 - 1)).await;
    assert_eq!(e1.embeds().len(), 3, "its third wait is thirty minutes");
    let out = fill(s(61 + 301 + 30 * 60 + 1)).await;
    assert_eq!(
        out,
        FillOutcome::Filled {
            n: 1,
            from: "e1".into()
        }
    );
}

/// Pattern D. While every source is down and none is due, a step reads no store rows; when one is due it reads again.
#[tokio::test]
async fn all_down_reads_no_store_rows() {
    let state = tempfile::tempdir().unwrap();
    let id = ident("all-down");
    let cache = Caches::shared(state.path()).get(&id).await.unwrap();
    let store = CodeStore::open(&state.path().join("code.db")).unwrap();
    let e = Fake::embedder("e", &id).down();
    let mut c = chain(&id, &[&e]);
    assert_eq!(
        c.fill(&cache, &items(0..2), t0()).await,
        FillOutcome::AllDown
    );
    let mut reads = 0;
    let s = Duration::from_secs;
    let out = c
        .step(&store, &cache, &[], t0() + s(10), &mut reads)
        .await
        .unwrap();
    assert_eq!((out, reads), (FillOutcome::AllDown, 0), "down, none due");
    let out = c
        .step(&store, &cache, &[], t0() + s(61), &mut reads)
        .await
        .unwrap();
    assert_eq!(
        (out, reads),
        (FillOutcome::Nothing, 1),
        "due: the store is read"
    );
}

/// Pattern D. A remote that is not on this machine and not marked trusted never receives a text (Task 14: loopback
/// only, until Task 23's `trusted`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn untrusted_remote_never_receives_text() {
    for (base, trusted) in [
        ("http://localhost:8080", true),
        ("http://127.0.0.1:1", true),
        ("http://[::1]:5", true),
        ("https://127.0.0.2/x", true),
        ("http://tei.example:80", false),
        ("http://10.0.0.5:8", false),
        ("http://localhost.evil.example", false),
    ] {
        assert_eq!(is_loopback(base), trusted, "{base}");
    }
    let dir = tempfile::tempdir().unwrap();
    let g = gate(dir.path(), json!([tei("http://192.0.2.1:9")])).await;
    let e = g.embedders(&[]).unwrap().remove(0);
    let s = DocSource::new(Arc::new(e));
    assert_eq!((s.kind(), s.may_send_text()), (SourceKind::Embed, false));
    let dir2 = tempfile::tempdir().unwrap();
    let near = Server::start(dir2.path());
    let g = gate(
        dir2.path(),
        json!([tei(&format!("http://127.0.0.1:{}", near.port))]),
    )
    .await;
    let e = g.embedders(&[]).unwrap().remove(0);
    let s = DocSource::new(Arc::new(e));
    assert_eq!(
        (s.kind(), s.may_send_text(), s.max_batch()),
        (SourceKind::Embed, true, 8)
    );
}

// ---- Task 15: the chains of a project, one pass at a time

fn git(dir: &Path, args: &[&str]) {
    let st = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

/// A project of N one-chunk Lisp files, tier 1 done; no tier 2 runs: the test steps the chains itself.
async fn project(n: usize) -> (tempfile::TempDir, tempfile::TempDir, Project) {
    let (home, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let root = home.path().join("src/proj");
    std::fs::create_dir_all(root.join("core")).unwrap();
    git(&root, &["init", "-q"]);
    for i in 0..n {
        std::fs::write(
            root.join(format!("core/f{i}.el")),
            format!(";;; f{i}.el\n(defun f{i}-run () \"Run number {i}.\" {i})\n"),
        )
        .unwrap();
    }
    git(&root, &["add", "-A"]);
    git(&root, &["commit", "-q", "-m", "one"]);
    let p = Project::open(ProjectSpec {
        root,
        state: state.path().to_path_buf(),
        home: home.path().to_path_buf(),
        config_dir: home.path().join(".config/drgnx"),
        config: hrafn::Config::default(),
        embedders: Vec::new(),
        power_root: Path::new("/nonexistent").to_path_buf(),
        base: None,
        test_permits: None,
    })
    .await
    .unwrap();
    p.refresh_now().await.unwrap();
    (home, state, p)
}

async fn slot(p: &Project, id: &Identity, sources: &[&Arc<Fake>]) -> Slot {
    Slot::new(chain(id, sources), p.cache(id).await.unwrap())
}

/// Pattern D (MP-15). The built-in model's chain runs only when the main chain has nothing to fill: while the main one
/// fills batches, the built-in one is not asked, and it starts in the pass the main one finishes in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn builtin_never_runs_while_main_has_work() {
    let (_h, _s, p) = project(20).await;
    let (main_id, own_id) = (ident("main"), ident("builtin"));
    let main = Fake::embedder("main", &main_id);
    let builtin = Arc::new(Fake::new(
        "builtin",
        SourceKind::Builtin,
        Some(own_id.clone()),
    ));
    let mut slots = vec![
        slot(&p, &main_id, &[&main]).await,
        slot(&p, &own_id, &[&builtin]).await,
    ];
    let mut reads = 0;
    let mut main_done = false;
    for pass in 0..12 {
        let before = main.embeds().len();
        let out = run_pass(&mut slots, p.store(), &[], t0(), &mut reads)
            .await
            .unwrap();
        if main.embeds().len() > before {
            assert!(
                builtin.embeds().is_empty(),
                "pass {pass}: the built-in chain ran while the main one had work"
            );
        } else {
            main_done = true;
        }
        if main_done && out.filled {
            break;
        }
    }
    assert!(main_done);
    let main_cache = p.cache(&main_id).await.unwrap();
    assert!(
        hrafn::missing(p.store(), &main_cache, 1000)
            .await
            .unwrap()
            .is_empty(),
        "the main model covers everything first"
    );
    assert!(!builtin.embeds().is_empty(), "then the built-in one fills");
}

/// Pattern D (MP-15). With the main source down, the built-in chain fills in the same pass; the main one is not asked
/// again before its backoff is over.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn builtin_fills_while_main_is_down() {
    let (_h, _s, p) = project(6).await;
    let (main_id, own_id) = (ident("main"), ident("builtin"));
    let main = Fake::embedder("main", &main_id).down();
    let builtin = Arc::new(Fake::new(
        "builtin",
        SourceKind::Builtin,
        Some(own_id.clone()),
    ));
    let mut slots = vec![
        slot(&p, &main_id, &[&main]).await,
        slot(&p, &own_id, &[&builtin]).await,
    ];
    let mut reads = 0;
    let out = run_pass(&mut slots, p.store(), &[], t0(), &mut reads)
        .await
        .unwrap();
    assert!(out.filled, "{out:?}");
    assert_eq!((main.embeds().len(), builtin.embeds().len()), (1, 1));
    run_pass(
        &mut slots,
        p.store(),
        &[],
        t0() + Duration::from_secs(5),
        &mut reads,
    )
    .await
    .unwrap();
    assert_eq!(main.embeds().len(), 1, "waits its backoff");
    assert_eq!(builtin.embeds().len(), 2);
}

/// Pattern D (MP-14). The paths named in the order come first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn open_files_first() {
    let (_h, _s, p) = project(20).await;
    let id = ident("main");
    let main = Fake::embedder("main", &id);
    let mut slots = vec![slot(&p, &id, &[&main]).await];
    let mut reads = 0;
    let order = vec!["core/f13.el".to_string()];
    run_pass(&mut slots, p.store(), &order, t0(), &mut reads)
        .await
        .unwrap();
    let first = &main.embeds()[0];
    assert!(first[0].contains("f13-run"), "{first:?}");
}

/// Pattern D (MP-15). On battery the local sources wait and the remote ones do not; `index now` lets the local ones
/// run.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn battery_holds_local_not_remote() {
    let (_h, _s, p) = project(10).await;
    let (main_id, own_id) = (ident("main"), ident("builtin"));
    let main = Fake::embedder("main", &main_id);
    let builtin = Arc::new(Fake::new(
        "builtin",
        SourceKind::Builtin,
        Some(own_id.clone()),
    ));
    let mut slots = vec![
        slot(&p, &main_id, &[&main]).await,
        slot(&p, &own_id, &[&builtin]).await,
    ];
    for s in &mut slots {
        s.chain.set_gates(true, false);
    }
    let mut reads = 0;
    // the remote fills on battery
    let out = run_pass(&mut slots, p.store(), &[], t0(), &mut reads)
        .await
        .unwrap();
    assert!(out.filled && !main.embeds().is_empty());
    // with the remote down too, only the local one could fill: it is held, and says so
    main.set_up(false);
    let mut later = t0() + Duration::from_secs(10 * 60);
    for _ in 0..4 {
        let out = run_pass(&mut slots, p.store(), &[], later, &mut reads)
            .await
            .unwrap();
        if out.held {
            break;
        }
        later += Duration::from_secs(10 * 60);
    }
    assert!(
        builtin.embeds().is_empty(),
        "the built-in model ran on battery"
    );
    // `index now`
    for s in &mut slots {
        s.chain.set_gates(true, true);
    }
    let out = run_pass(
        &mut slots,
        p.store(),
        &[],
        later + Duration::from_secs(3600),
        &mut reads,
    )
    .await
    .unwrap();
    assert!(out.filled && !builtin.embeds().is_empty(), "{out:?}");
}
