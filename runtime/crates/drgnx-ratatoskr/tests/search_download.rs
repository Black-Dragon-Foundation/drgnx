//! The model download against `ratatoskr-mock hf`, the stand-in for the model host (`runtime/conformance/src/bin/`). The mock
//! is found at `RATATOSKR_MOCK`, else beside this test's binary: build it first (`cargo build -p domr --bin ratatoskr-mock`).

use bifrost::Uri;
use drgnx_ratatoskr::search::{Consent, DownloadError, download, model_base};
use drgnx_ratatoskr::settings;
use hrafn_embed::cache::{self, ModelState, model_dir};
use hrafn_embed::{Arch, ModelFile, ModelSpec, download_bytes};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
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
    if let Some(path) = std::env::var_os("RATATOSKR_MOCK") {
        return path.into();
    }
    let exe = std::env::current_exe().unwrap();
    let bin = exe
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .join("ratatoskr-mock");
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
