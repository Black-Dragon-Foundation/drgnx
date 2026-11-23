//! The model download against `ratatoskr-mock hf`, the stand-in for the model host (`runtime/conformance/src/bin/`). The mock
//! is found at `RATATOSKR_MOCK`, else beside this test's binary: build it first (`cargo build -p domr --bin ratatoskr-mock`).
//! The engine's rows serve a llama.cpp release archive from the same host; `no_download_on_an_idle_path` runs the real
//! hub with the built-in model of the model volume (`DRGNX_TEST_MODELS`).

use crate::support::{self, FAILED_AFTER};
use bifrost::Uri;
use hrafn_embed::cache::{self, ModelState, model_dir};
use hrafn_embed::{Arch, EngineAsset, ModelFile, ModelSpec, download_bytes};
use ratatoskr::search::engine_install;
use ratatoskr::search::{Consent, DownloadError, download, model_base};
use ratatoskr::settings;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use tempfile::TempDir;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;

const FILES: [(&str, usize); 4] = [
    ("model.safetensors", 300_000),
    ("tokenizer.json", 2_000),
    ("config.json", 100),
    ("1_Pooling/config.json", 50),
];
const CUT_AT: usize = 100_000;

fn mock_bin() -> PathBuf {
    let bin = skuld::workspace_bin("ratatoskr-mock", None, Some("RATATOSKR_MOCK"));
    assert!(
        bin.exists(),
        "{} is missing: build it first (cargo build -p domr --bin ratatoskr-mock) or name it in RATATOSKR_MOCK",
        bin.display()
    );
    bin
}

fn bytes_of(name: &str, size: usize) -> Vec<u8> {
    let seed = name.len();
    (0..size).map(|i| ((i * 7 + seed) % 251) as u8).collect()
}

/// A model row of leaked strings, whose files sit in the mock's directory beside one that is not in the row.
struct Rig {
    spec: &'static ModelSpec,
    root: TempDir,
    served: TempDir,
    mock: Child,
    base: Uri,
    log: PathBuf,
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = self.mock.kill();
        let _ = self.mock.wait();
    }
}

fn rig(flags: &[&str]) -> Rig {
    let (root, served) = (TempDir::new().unwrap(), TempDir::new().unwrap());
    let mut files = Vec::new();
    for (name, size) in FILES {
        let (path, bytes) = (served.path().join(name), bytes_of(name, size));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        let sum: String = Sha256::digest(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        files.push(ModelFile {
            name,
            sha256: Box::leak(sum.into_boxed_str()),
            bytes: size as u64,
        });
    }
    std::fs::write(served.path().join("model.onnx"), b"not ours").unwrap();
    let spec = Box::leak(Box::new(ModelSpec {
        id: "tiny",
        repo: "org/tiny",
        revision: "0123456789abcdef0123456789abcdef01234567",
        files: Box::leak(files.into_boxed_slice()),
        dims: 8,
        max_tokens: 16,
        query_prefix: "",
        doc_prefix: "",
        arch: Arch::ModernBert,
        licence: "Apache-2.0",
    }));
    let log = root.path().join("mock.log");
    let mut mock = Command::new(mock_bin())
        .arg("hf")
        .arg("--dir")
        .arg(served.path())
        .arg("--log")
        .arg(&log)
        .args(flags)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut lines = BufReader::new(mock.stdout.take().unwrap()).lines();
    let first = lines.next().unwrap().unwrap();
    let port = first.strip_prefix("MOCK-HF-PORT ").unwrap();
    assert!(
        lines
            .next()
            .unwrap()
            .unwrap()
            .starts_with("MOCK-HF-CDN-PORT")
    );
    let base = format!("http://127.0.0.1:{port}").parse().unwrap();
    Rig {
        spec,
        root,
        served,
        mock,
        base,
        log,
    }
}

impl Rig {
    fn consent(&self) -> Consent {
        Consent {
            model: self.spec.id.to_string(),
            bytes: download_bytes(self.spec),
            at: 1.0,
        }
    }

    async fn run(&self) -> Result<(), DownloadError> {
        self.run_from(&self.base).await
    }

    async fn run_from(&self, base: &Uri) -> Result<(), DownloadError> {
        let root = self.root.path();
        download(self.spec, root, base, &self.consent(), &|_, _| {}).await
    }

    fn dir(&self) -> PathBuf {
        model_dir(self.root.path(), self.spec)
    }

    fn state(&self) -> ModelState {
        cache::state(self.spec, &self.dir())
    }

    fn requests(&self, server: &str) -> Vec<Value> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap())
            .filter(|v| v["server"] == server)
            .collect()
    }
}

#[tokio::test]
async fn no_consent_never_connects() {
    let r = rig(&[]);
    let root = r.root.path();
    let wrong_size = Consent {
        bytes: 1,
        ..r.consent()
    };
    let wrong_model = Consent {
        model: "other".into(),
        ..r.consent()
    };
    for consent in [wrong_size, wrong_model] {
        let got = download(r.spec, root, &r.base, &consent, &|_, _| {}).await;
        assert_eq!(got, Err(DownloadError::NoConsent));
    }
    assert!(r.requests("resolve").is_empty());
    assert_eq!(r.state(), ModelState::Missing);
}

#[tokio::test]
async fn download_verifies_and_renames() {
    let r = rig(&[]);
    let seen = Mutex::new(Vec::new());
    let progress = |have, total| seen.lock().unwrap().push((have, total));
    let root = r.root.path();
    download(r.spec, root, &r.base, &r.consent(), &progress)
        .await
        .unwrap();
    assert_eq!(r.state(), ModelState::Ready);
    for (name, _) in FILES {
        assert!(!r.dir().join(format!("{name}.part")).exists(), "{name}");
    }
    let seen = seen.into_inner().unwrap();
    let total = download_bytes(r.spec);
    assert!(seen.iter().all(|(_, t)| *t == total));
    assert!(seen.windows(2).all(|w| w[0].0 <= w[1].0), "only forward");
    assert_eq!(seen.last().unwrap().0, total);

    // a second run has nothing to do
    r.run().await.unwrap();
    assert_eq!(r.requests("resolve").len(), FILES.len());
}

#[tokio::test]
async fn fetches_only_the_tables_files() {
    let r = rig(&[]);
    r.run().await.unwrap();
    let mut got: Vec<String> = r
        .requests("resolve")
        .iter()
        .map(|v| v["path"].as_str().unwrap().to_string())
        .collect();
    got.sort();
    let mut want: Vec<String> = FILES
        .iter()
        .map(|(name, _)| format!("/{}/resolve/{}/{name}", r.spec.repo, r.spec.revision))
        .collect();
    want.sort();
    assert_eq!(got, want);
}

#[tokio::test]
async fn follows_the_redirect_to_another_host() {
    let r = rig(&[]);
    r.run().await.unwrap();
    let cdn = r.requests("cdn");
    assert_eq!(
        cdn.len(),
        FILES.len(),
        "each file came from the second host"
    );
    assert!(
        cdn.iter()
            .all(|v| v["path"].as_str().unwrap().contains("?sig=1"))
    );
    for row in r.requests("resolve").iter().chain(&cdn) {
        assert_eq!(row["credentials"], false, "{row}");
    }
}

#[tokio::test]
async fn refuses_a_redirect_to_plain_http() {
    let r = rig(&["--location", "http://cdn.invalid/f"]);
    assert_eq!(r.run().await, Err(DownloadError::Http(302)));
    assert_eq!(r.state(), ModelState::Missing);
}

#[tokio::test]
async fn gives_up_after_three_redirects() {
    let r = rig(&["--location", "/again"]);
    assert_eq!(r.run().await, Err(DownloadError::Http(302)));
    assert_eq!(
        r.requests("resolve").len(),
        4,
        "the request and 3 redirects"
    );
}

#[tokio::test]
async fn a_missing_file_is_the_hosts_answer() {
    let r = rig(&[]);
    std::fs::remove_file(r.served.path().join("config.json")).unwrap();
    assert_eq!(r.run().await, Err(DownloadError::Http(404)));
}

#[tokio::test]
async fn resume_after_cut() {
    let cut_at = CUT_AT.to_string();
    let r = rig(&["--cut", "model.safetensors", &cut_at]);
    assert_eq!(r.run().await, Err(DownloadError::Offline));
    assert!(matches!(r.state(), ModelState::Partial { .. }));
    let part = r.dir().join("model.safetensors.part");
    let kept = std::fs::metadata(&part).unwrap().len();
    assert!(kept > 0 && kept <= CUT_AT as u64, "{kept}");

    r.run().await.unwrap();
    assert_eq!(r.state(), ModelState::Ready);
    let asked = |server: &str, name: &str| {
        let rows = r.requests(server);
        let hits = rows
            .iter()
            .filter(|v| v["path"].as_str().unwrap().contains(name));
        hits.cloned().collect::<Vec<_>>()
    };
    assert_eq!(
        asked("resolve", "model.safetensors").len(),
        2,
        "a fresh target"
    );
    let cdn = asked("cdn", "model.safetensors");
    assert_eq!(cdn.len(), 2);
    assert_eq!(cdn[0]["range"], Value::Null);
    assert_eq!(cdn[1]["range"], format!("bytes={kept}-"));
}

#[tokio::test]
async fn a_host_that_ignores_range_starts_the_file_over() {
    let cut_at = CUT_AT.to_string();
    let r = rig(&["--cut", "model.safetensors", &cut_at, "--no-range"]);
    assert_eq!(r.run().await, Err(DownloadError::Offline));
    r.run().await.unwrap();
    assert_eq!(r.state(), ModelState::Ready);
}

#[tokio::test]
async fn a_part_past_the_files_size_is_thrown_away() {
    let r = rig(&[]);
    std::fs::create_dir_all(r.dir()).unwrap();
    std::fs::write(r.dir().join("config.json.part"), vec![0u8; 500]).unwrap();
    r.run().await.unwrap();
    assert_eq!(r.state(), ModelState::Ready);
}

#[tokio::test]
async fn bad_sum_never_loads() {
    let r = rig(&["--bad", "config.json"]);
    let got = r.run().await;
    assert_eq!(got, Err(DownloadError::Corrupt("config.json".into())));
    assert_ne!(r.state(), ModelState::Ready);
    assert!(!r.dir().join("config.json").exists());
    assert!(
        !r.dir().join("config.json.part").exists(),
        "not resumed from"
    );
}

#[tokio::test]
async fn offline_is_reported_once() {
    let r = rig(&[]);
    // nothing listens here any more
    let port = {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        l.local_addr().unwrap().port()
    };
    let dead: Uri = format!("http://127.0.0.1:{port}").parse().unwrap();
    assert_eq!(r.run_from(&dead).await, Err(DownloadError::Offline));

    // a host that hangs up: one connection, no second try
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    static SEEN: AtomicUsize = AtomicUsize::new(0);
    tokio::spawn(async move {
        while let Ok((mut s, _)) = l.accept().await {
            SEEN.fetch_add(1, Ordering::SeqCst);
            let _ = s.shutdown().await;
        }
    });
    let hangs_up: Uri = format!("http://127.0.0.1:{port}").parse().unwrap();
    assert_eq!(r.run_from(&hangs_up).await, Err(DownloadError::Offline));
    assert_eq!(SEEN.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn mirror_setting_used() {
    let r = rig(&[]);
    let config = TempDir::new().unwrap();
    let file = config.path().join("settings.el");
    std::fs::write(
        &file,
        format!(
            "(drgnx-settings\n :version 1\n (drgnx-search-model-mirror \"{}\"))\n",
            r.base
        ),
    )
    .unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let loaded = settings::load::load(config.path(), &Default::default());
    assert_eq!(loaded.problems, []);
    let mirror = loaded.values.search_model_mirror.as_deref();
    let base = model_base(mirror).unwrap();
    assert_eq!(base.to_string(), r.base.to_string());
    r.run_from(&base).await.unwrap();
    assert_eq!(r.state(), ModelState::Ready);
}

#[test]
fn import_dir_counts_as_ready() {
    let r = rig(&[]);
    cache::import(r.spec, r.served.path(), &r.dir()).unwrap();
    assert_eq!(r.state(), ModelState::Ready);
}

// ------------------------------------------------------------------------------------------ the engine's asset

/// A tar.gz of ENTRIES (name, bytes, mode), each name written as given: `..` too, which `tar::Header::set_path` refuses.
fn tgz(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
    let gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    let mut b = tar::Builder::new(gz);
    for (name, data, mode) in entries {
        let mut h = tar::Header::new_old();
        h.as_old_mut().name[..name.len()].copy_from_slice(name.as_bytes());
        h.set_size(data.len() as u64);
        h.set_mode(*mode);
        h.set_entry_type(tar::EntryType::Regular);
        h.set_cksum();
        b.append(&h, *data).unwrap();
    }
    b.into_inner().unwrap().finish().unwrap()
}

const SERVER: &[u8] = b"#!/bin/sh\nexit 0\n";

/// A release archive as llama.cpp's Linux assets are: one folder, the server in it.
fn release() -> Vec<u8> {
    tgz(&[
        ("llama-b1/llama-server", SERVER, 0o755),
        ("llama-b1/libllama.so", b"lib", 0o755),
    ])
}

/// The archive ARCHIVE served by R's host as `engine.tar.gz`, and an asset row for it (leaked) at its sum.
fn asset(r: &Rig, archive: &[u8]) -> &'static EngineAsset {
    std::fs::write(r.served.path().join("engine.tar.gz"), archive).unwrap();
    let sum: String = Sha256::digest(archive)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let base = r.base.to_string();
    let url = format!(
        "{}/ggml-org/llama.cpp/resolve/b1/engine.tar.gz",
        base.trim_end_matches('/')
    );
    Box::leak(Box::new(EngineAsset {
        tag: "b1",
        os: "linux",
        arch: "x86_64",
        backend: "vulkan",
        url: Box::leak(url.into_boxed_str()),
        sha256: Box::leak(sum.into_boxed_str()),
        bytes: archive.len() as u64,
        binary: "llama-b1/llama-server",
    }))
}

fn engine_consent(a: &EngineAsset) -> Consent {
    Consent {
        model: a.id(),
        bytes: a.bytes,
        at: 1.0,
    }
}

#[tokio::test]
async fn engine_download_needs_consent_for_its_bytes() {
    let r = rig(&[]);
    let a = asset(&r, &release());
    let dir = r.root.path().join("engines").join(a.id());
    let short = Consent {
        bytes: a.bytes - 1,
        ..engine_consent(a)
    };
    let other = Consent {
        model: "llama.cpp-b0-linux-x86_64-vulkan".into(),
        ..engine_consent(a)
    };
    for consent in [short, other] {
        let got = engine_install::install(a, &consent, &dir).await;
        assert_eq!(got, Err(DownloadError::NoConsent));
    }
    assert!(r.requests("resolve").is_empty(), "nothing asked");
    assert_eq!(engine_install::installed(a, &dir), None);

    let exe = engine_install::install(a, &engine_consent(a), &dir)
        .await
        .unwrap();
    assert_eq!(std::fs::read(&exe).unwrap(), SERVER);
    let mode = std::fs::metadata(&exe).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0o111, "llama-server runs: {mode:o}");
    assert_eq!(engine_install::installed(a, &dir), Some(exe));
    assert!(dir.join("bin/llama-b1/libllama.so").is_file());
    assert!(
        !dir.join("engine.tar.gz").exists() && !dir.join("engine.tar.gz.part").exists(),
        "the archive goes once unpacked"
    );
}

#[tokio::test]
async fn archive_entry_outside_dir_is_refused() {
    let r = rig(&[]);
    let a = asset(
        &r,
        &tgz(&[
            ("llama-b1/llama-server", SERVER, 0o755),
            ("../evil", b"escaped", 0o644),
        ]),
    );
    let engines = r.root.path().join("engines");
    let dir = engines.join(a.id());
    let got = engine_install::install(a, &engine_consent(a), &dir).await;
    assert!(
        matches!(&got, Err(DownloadError::Archive(why)) if why.contains("../evil")),
        "{got:?}"
    );
    let mut landed = Vec::new();
    for d in [r.root.path(), &engines, &dir, &dir.join("bin")] {
        if d.join("evil").exists() {
            landed.push(d.display().to_string());
        }
    }
    assert_eq!(landed, Vec::<String>::new(), "nothing outside its folder");
    assert_eq!(engine_install::installed(a, &dir), None);
}

#[tokio::test]
async fn wrong_sum_keeps_part_and_says_so() {
    let r = rig(&["--bad", "engine.tar.gz"]);
    let a = asset(&r, &release());
    let dir = r.root.path().join("engines").join(a.id());
    let got = engine_install::install(a, &engine_consent(a), &dir).await;
    let part = dir.join("engine.tar.gz.part");
    match &got {
        Err(DownloadError::Corrupt(why)) => {
            assert!(
                why.contains("engine.tar.gz") && why.contains(&part.display().to_string()),
                "it names the file and where it is kept: {why}"
            );
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        std::fs::metadata(&part).unwrap().len(),
        a.bytes,
        "kept whole"
    );
    assert_eq!(engine_install::installed(a, &dir), None);
    assert!(!dir.join("bin").exists(), "nothing unpacked");
}

/// The built-in model of the model volume, in ROOT's cache.
fn install_builtin(root: &support::Root) {
    let volume =
        std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS names the model volume");
    let models = root.dir.path().join("h/xk/drgnx/models");
    std::fs::create_dir_all(&models).unwrap();
    let spec = hrafn_embed::default_model();
    std::os::unix::fs::symlink(
        std::path::Path::new(&volume).join(spec.id),
        model_dir(&models, spec),
    )
    .unwrap();
}

/// Pattern C. With the shipped `embed` role (the engine) and no engine installed, tier 2 runs on the built-in model and
/// settles: nothing is fetched from the model host (the mirror is the test host) and no engine folder appears.
#[test]
fn no_download_on_an_idle_path() {
    let r = rig(&[]);
    let root = support::Root::new();
    let conf = root.dir.path().join("h/c");
    std::fs::create_dir_all(&conf).unwrap();
    let file = conf.join("settings.el");
    std::fs::write(
        &file,
        format!(
            "(drgnx-settings\n :version 1\n (drgnx-search-model-mirror \"{}\"))\n",
            r.base
        ),
    )
    .unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    install_builtin(&root);
    let proj = root.dir.path().join("h/proj");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("a.el"), "(defun a-thing ()\n  \"Do a thing.\")\n").unwrap();
    for args in [
        &["init", "-q"][..],
        &["add", "-A"],
        &["commit", "-q", "-m", "one"],
    ] {
        let st = Command::new("git")
            .arg("-C")
            .arg(&proj)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }
    let mut hub = support::Hub::start(&root, 1);
    let socket = root.socket();
    hub.wait_ready(&socket);
    let mut c = support::Client::open(&socket);
    c.hello(&socket);
    let mut id = 1;
    c.send(json!({"id": id, "method": "search/index", "params": {"root": proj}}));
    assert_eq!(c.answer(id).0["result"]["started"], true);
    let s = skuld::wait_until(
        "every chunk has its vector and tier 2 has settled",
        FAILED_AFTER.as_secs() * 10,
        || {
            id += 1;
            c.send(json!({"id": id, "method": "search/status", "params": {"root": proj}}));
            let s = c.answer(id).0["result"].clone();
            (s["lag"]["chunks_behind"] == 0
                && s["lag"]["chunks_total"].as_u64() > Some(0)
                && (s["tier2"] == "idle" || s["tier2"] == "failed"))
                .then_some(s)
        },
    );
    assert_eq!(s["tier2"], "idle", "{s}");
    assert_eq!(r.requests("resolve"), Vec::<Value>::new(), "no transfer");
    assert!(
        !root.dir.path().join("h/xk/drgnx/engines").exists(),
        "no engine folder"
    );
}

/// Pattern C. An install's end reopens the open projects at once: the download drops them (their embedders are
/// formed again) and nothing but the reopen starts them again, since no call names the root afterwards. The model
/// is `test-tiny`, served by `ratatoskr-mock` from its fixtures; `search/list` reads the open flag without opening
/// anything, so the root stays open for more samples than the drop and the reopen take.
#[test]
fn an_install_end_reopens_the_open_projects() {
    let served =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/test-tiny");
    let tiny = &ratatoskr::search::TEST_TINY;
    let mut mock = Command::new(support::mock_binary())
        .arg("hf")
        .arg("--dir")
        .arg(&served)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut lines = BufReader::new(mock.stdout.take().unwrap()).lines();
    let first = lines.next().unwrap().unwrap();
    let port = first.strip_prefix("MOCK-HF-PORT ").unwrap().to_owned();
    let _mock = Kill(mock);
    let root = support::Root::new();
    let conf = root.dir.path().join("h/c");
    std::fs::create_dir_all(&conf).unwrap();
    let file = conf.join("settings.el");
    std::fs::write(
        &file,
        format!(
            "(drgnx-settings\n :version 1\n (drgnx-search-model-mirror \"http://127.0.0.1:{port}\"))\n"
        ),
    )
    .unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let proj = root.dir.path().join("h/proj");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("a.el"), "(defun a-thing ()\n  \"Do a thing.\")\n").unwrap();
    for args in [
        &["init", "-q"][..],
        &["add", "-A"],
        &["commit", "-q", "-m", "one"],
    ] {
        let st = Command::new("git")
            .arg("-C")
            .arg(&proj)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }
    let mut hub = support::Hub::start(&root, 1);
    let socket = root.socket();
    hub.wait_ready(&socket);
    let mut c = support::Client::open(&socket);
    c.hello(&socket);
    let mut id = 1u64;
    c.send(json!({"id": id, "method": "search/index", "params": {"root": proj}}));
    assert_eq!(c.answer(id).0["result"]["started"], true);
    let open = |c: &mut support::Client, id: &mut u64| {
        *id += 1;
        c.send(json!({"id": *id, "method": "search/list", "params": {}}));
        c.answer(*id).0["result"]["roots"][0]["open"] == true
    };
    assert!(
        open(&mut c, &mut id),
        "the project is open before the install"
    );
    id += 1;
    c.send(
        json!({"id": id, "method": "search/model-download", "params": {
        "model": tiny.id, "consent": {"bytes": download_bytes(tiny)}}}),
    );
    assert_eq!(c.answer(id).0["result"]["started"], true);
    let models = model_dir(&root.dir.path().join("h/xk/drgnx/models"), tiny);
    skuld::wait_until(
        "the model is installed",
        FAILED_AFTER.as_secs() * 10,
        || (cache::state(tiny, &models) == ModelState::Ready).then_some(()),
    );
    let mut streak = 0;
    skuld::wait_until(
        "the project stays open after the install",
        FAILED_AFTER.as_secs() * 10,
        || {
            streak = if open(&mut c, &mut id) { streak + 1 } else { 0 };
            (streak >= 30).then_some(())
        },
    );
}

/// A mock process that ends with the test, however it ends.
struct Kill(Child);

impl Drop for Kill {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
