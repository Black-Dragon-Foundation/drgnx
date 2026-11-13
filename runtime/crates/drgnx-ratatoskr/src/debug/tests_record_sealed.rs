//! Recorded runs sealed at rest (spec §19.2, the user's Q18 ruling): nothing the program held is readable from the
//! files on disk, a run reads back after a restart with the keyring's key, a locked or absent keyring leaves recording
//! off and says why, and with the key gone the runs say they cannot be read while retention still works.
use super::Debug;
use super::record::{Launch, Opts, Runs};
use super::runkey::{KeyStore, Memory, MemoryState};
use super::session::{Op, Request, Start};
use super::tests_record::{Events, Mocks, NoTerms, Store, until};
use serde_json::json;
use std::path::Path;
use std::sync::{Arc, Mutex};

const MARKER: &str = "PLAINTEXT-MARKER-7f3a9c";

fn memory(f: impl FnOnce(&mut MemoryState)) -> Arc<Memory> {
    let m = Memory::default();
    f(&mut m.state.lock().unwrap());
    Arc::new(m)
}

/// One run of a mock program that stops once with MARKER in a variable and in its launch's environment, recorded
/// under DIR with KEY: the events, the debugger, the run's id (none recorded: "").
async fn record_one(dir: &Path, key: Arc<dyn KeyStore>) -> (Arc<Events>, Debug, String) {
    record_into(dir, key, Arc::new(Store::default())).await
}

/// [`record_one`], its records put into STORE (the graph).
async fn record_into(
    dir: &Path,
    key: Arc<dyn KeyStore>,
    store: Arc<Store>,
) -> (Arc<Events>, Debug, String) {
    let project = dir.join("proj");
    std::fs::create_dir_all(&project).unwrap();
    let file = project.join("app.py");
    std::fs::write(&file, "x = 1\n").unwrap();
    let root = project.to_string_lossy().into_owned();
    let path = file.to_string_lossy().into_owned();
    let ev = Arc::new(Events::default());
    let dbg = Debug::new(ev.clone(), Arc::new(NoTerms));
    let mut opts = Opts::new(dir.join("runs"), dir.join("checkpoints"));
    opts.key = key;
    opts.store = store;
    dbg.record_into(opts);
    let script = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
        json!({"event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}}),
        json!({"expect": "threads", "ok": {"threads": [{"id": 1, "name": "main"}]}}),
        json!({"expect": "stackTrace", "ok": {"stackFrames": [{"id": 5, "name": "f", "line": 1, "column": 1, "source": {"path": path}}]}}),
        json!({"expect": "scopes", "ok": {"scopes": [{"name": "Locals", "variablesReference": 9}]}}),
        json!({"expect": "variables", "ok": {"variables": [{"name": "token", "value": MARKER, "variablesReference": 0}]}}),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ];
    let mocks = Arc::new(Mocks {
        scripts: Mutex::new(vec![script].into()),
        ..Mocks::default()
    });
    let start = Start {
        name: "Python: app".into(),
        adapter_id: "debugpy".into(),
        request: Request::Launch,
        arguments: json!({"program": path, "env": {"API_TOKEN": MARKER}}),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let launch = Launch {
        start: json!({"root": root, "config": "launch:0", "inputs": [{"id": "token", "value": MARKER}]}),
        ..Launch::default()
    };
    let id = dbg
        .start_with(7, &root, start, mocks.clone(), launch)
        .await
        .unwrap();
    until("the stop", || dbg.stop_of(&id).is_some()).await;
    dbg.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    let running = std::mem::take(&mut *mocks.running.lock().unwrap());
    for m in running {
        m.finish().await.unwrap();
    }
    let rec = dbg.records().unwrap();
    // its stops and its end are recorded off the workers: all of them now
    rec.written().await;
    let run = rec
        .list(&root)
        .first()
        .map(|m| m.id.clone())
        .unwrap_or_default();
    (ev, dbg, run)
}

/// Every file under DIR, its bytes.
fn files(dir: &Path) -> Vec<(String, Vec<u8>)> {
    let mut out = vec![];
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(files(&p));
        } else {
            out.push((p.display().to_string(), std::fs::read(&p).unwrap()));
        }
    }
    out
}

fn has(bytes: &[u8], needle: &str) -> bool {
    bytes.windows(needle.len()).any(|w| w == needle.as_bytes())
}

#[tokio::test(start_paused = true)]
async fn a_run_is_sealed_on_disk_and_reads_back_after_a_restart() {
    let d = tempfile::tempdir().unwrap();
    let key = memory(|_| {});
    let store = Arc::new(Store::default());
    let (_, dbg, run) = record_into(d.path(), key.clone(), store.clone()).await;
    assert!(!run.is_empty(), "the run was recorded");
    // the graph's records hold no start
    let put = store.0.lock().unwrap().clone();
    assert!(!put.is_empty());
    for m in put {
        assert!(
            !has(&serde_json::to_vec(&m).unwrap(), MARKER),
            "the graph got {m:?}"
        );
    }
    assert_eq!(
        key.state.lock().unwrap().made,
        1,
        "the key is made on the first recording"
    );
    let rec = dbg.records().unwrap();
    let stop = rec.run(&run).unwrap().stops[0].index;
    assert_eq!(
        rec.past_stop(&run, stop, None).unwrap()["capture"]["scopes"][0]["variables"][0]["value"],
        MARKER
    );
    // nothing on disk holds it: not the run file, its index, nor the run's record
    let on_disk = files(&d.path().join("runs"));
    assert!(
        on_disk.len() >= 3,
        "{:?}",
        on_disk.iter().map(|f| &f.0).collect::<Vec<_>>()
    );
    for (name, bytes) in &on_disk {
        assert!(!has(bytes, MARKER), "{name} holds the marker in plain text");
    }
    // a restarted hub, the same keyring: the run reads back
    let ev2 = Arc::new(Events::default());
    let dbg2 = Debug::new(ev2, Arc::new(NoTerms));
    let mut opts = Opts::new(d.path().join("runs"), d.path().join("checkpoints"));
    opts.key = key.clone();
    let rec2 = dbg2.record_into(opts);
    rec2.unlock().await.unwrap();
    let info = rec2.run(&run).unwrap();
    assert_eq!(info.start["inputs"][0]["value"], MARKER);
    assert_eq!(
        rec2.past_stop(&run, stop, None).unwrap()["capture"]["scopes"][0]["variables"][0]["value"],
        MARKER
    );
    assert_eq!(key.state.lock().unwrap().made, 1, "no second key");
}

#[tokio::test(start_paused = true)]
async fn a_locked_keyring_leaves_recording_off_and_says_why() {
    let d = tempfile::tempdir().unwrap();
    let key = memory(|s| s.locked = true);
    let (ev, _, run) = record_one(d.path(), key.clone()).await;
    assert_eq!(run, "", "nothing recorded");
    let off = ev.named("debug-recording-off");
    assert_eq!(off.len(), 1, "said once: {off:?}");
    assert!(
        off[0]["why"].as_str().unwrap().contains("locked"),
        "{off:?}"
    );
    assert_eq!(
        key.state.lock().unwrap().made,
        0,
        "no key made in a locked keyring"
    );
    assert!(
        files(&d.path().join("runs")).is_empty(),
        "nothing written without the key"
    );
}

#[tokio::test(start_paused = true)]
async fn no_keyring_leaves_recording_off_and_says_why() {
    let d = tempfile::tempdir().unwrap();
    let (ev, _, run) = record_one(d.path(), memory(|s| s.absent = true)).await;
    assert_eq!(run, "");
    let off = ev.named("debug-recording-off");
    assert!(
        off[0]["why"].as_str().unwrap().contains("no keyring"),
        "{off:?}"
    );
}

#[tokio::test(start_paused = true)]
async fn with_the_key_gone_runs_cannot_be_read_and_prune_still_works() {
    let d = tempfile::tempdir().unwrap();
    let (_, dbg, run) = record_one(d.path(), memory(|_| {})).await;
    let stop = dbg.records().unwrap().run(&run).unwrap().stops[0].index;
    // the keyring lost its key: a new, empty one
    let dbg2 = Debug::new(Arc::new(Events::default()), Arc::new(NoTerms));
    let mut opts = Opts::new(d.path().join("runs"), d.path().join("checkpoints"));
    opts.key = memory(|_| {});
    let rec2 = dbg2.record_into(opts);
    let _ = rec2.unlock().await;
    let root = d.path().join("proj").to_string_lossy().into_owned();
    // still listed (its record's plain fields), never read
    assert_eq!(rec2.list(&root).len(), 1);
    let e = rec2.past_stop(&run, stop, None).unwrap_err();
    assert!(e.contains("cannot be read"), "{e}");
    let e = rec2.get(&run, 0, 50).unwrap_err();
    assert!(e.contains("cannot be read"), "{e}");
    assert!(rec2.run(&run).is_none());
    // retention goes on: 15 days after its end the run goes
    let now = crate::clock::wall_secs() + 15.0 * 86400.0;
    assert_eq!(rec2.prune(now).await, [run]);
    assert!(files(&d.path().join("runs")).is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_sent_run_opens_with_its_code_read_only_under_the_other_keyring() {
    let d = tempfile::tempdir().unwrap();
    let (_, dbg, run) = record_one(&d.path().join("a"), memory(|_| {})).await;
    assert!(!run.is_empty(), "the run was recorded");
    let rec = dbg.records().unwrap();
    let out = d.path().join("run.drgnx-run");
    let sent = rec.export_run(&run, &out).await;
    assert!(sent.is_ok(), "{sent:?}");
    let sent = sent.unwrap();
    // a code of 52 base32 letters in groups of four; the file holds nothing in plain text
    assert_eq!(sent.code.replace('-', "").len(), 52, "{}", sent.code);
    assert!(!has(&std::fs::read(&out).unwrap(), MARKER));
    // another hub, another keyring, another project
    let b = d.path().join("b");
    let root_b = b.join("proj2");
    std::fs::create_dir_all(&root_b).unwrap();
    let ev2 = Arc::new(Events::default());
    let dbg2 = Debug::new(ev2, Arc::new(NoTerms));
    let mut opts = Opts::new(b.join("runs"), b.join("checkpoints"));
    opts.key = memory(|_| {});
    let rec2 = dbg2.record_into(opts);
    let root2 = root_b.to_string_lossy().into_owned();
    let wrong = rec2.import_run(&root2, &out, "AAAA").await;
    assert!(
        wrong.as_ref().is_err_and(|e| e.contains("share code")),
        "{wrong:?}"
    );
    let got = rec2
        .import_run(&root2, &out, &sent.code.to_lowercase())
        .await;
    assert!(got.is_ok(), "{got:?}");
    let id = got.unwrap();
    let info = rec2.run(&id).unwrap();
    assert_eq!(info.root, root2);
    let stop = &info.stops[0];
    // its paths are the recipient's project's
    assert_eq!(stop.path, root_b.join("app.py").display().to_string());
    assert_eq!(
        rec2.past_stop(&id, stop.index, None).unwrap()["capture"]["scopes"][0]["variables"][0]["value"],
        MARKER
    );
    let meta = rec2.list(&root2);
    assert_eq!(meta.len(), 1);
    assert!(meta[0].imported.is_some(), "{:?}", meta[0]);
    // the files that ran came along: the snapshot is the recipient's now
    let snap = info.snapshot.expect("the launch snapshot");
    assert_eq!(snap.source, root_b);
    let text =
        crate::timeline::snapshot::blob(&snap.checkpoints, &snap.source, &snap.tree, "app.py")
            .unwrap();
    assert_eq!(text, b"x = 1\n");
    // nothing of it is in plain text in the recipient's runs either
    for (name, bytes) in files(&b.join("runs")) {
        assert!(
            !has(&bytes, MARKER),
            "{name} holds the marker in plain text"
        );
    }
}
