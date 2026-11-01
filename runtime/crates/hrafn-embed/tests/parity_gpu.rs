//! The real shaders against reference vectors, on the adapter `DRGNX_TEST_ADAPTER` names: llvmpipe in `$CARGO`, a real GPU
//! through the GPU script. Parity is the test: a wrong sign, window or norm order moves the cosine visibly.
//! llvmpipe does about 68 tokens/s on gte, so these use the sweep and short texts only, and share one embedder per model:
//! parallel loads overrun the test container's memory cap. The full 20 chunks are `#[ignore]` rows for a real GPU.

use hrafn_embed::{
    Device, EmbedFail, LoadError, LocalEmbedder, MODELS, ModelSpec, TOKEN_CAP, Tuning, adapters,
};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, OnceLock};

const GTE: &str = "gte-modernbert-base";
const GRANITE: &str = "granite-embedding-small-english-r2";

fn fixture(id: &str) -> Value {
    let text = match id {
        GTE => include_str!("fixtures/gte-modernbert-base.json"),
        GRANITE => include_str!("fixtures/granite-embedding-small-english-r2.json"),
        other => panic!("{other}"),
    };
    serde_json::from_str(text).unwrap()
}

fn sweep(id: &str) -> Vec<(Vec<u32>, Vec<f32>)> {
    fixture(id)["sweep"]
        .as_array()
        .unwrap()
        .iter()
        .map(row)
        .collect()
}

fn row(v: &Value) -> (Vec<u32>, Vec<f32>) {
    let ids = v["ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_u64().unwrap() as u32)
        .collect();
    (ids, vector(&v["vector"]))
}

fn vector(v: &Value) -> Vec<f32> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap() as f32)
        .collect()
}

fn spec(id: &str) -> &'static ModelSpec {
    MODELS.iter().find(|m| m.id == id).unwrap()
}

fn dir(id: &str) -> PathBuf {
    PathBuf::from(
        std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS names the model volume"),
    )
    .join(id)
}

fn device() -> Device {
    Device::Gpu {
        adapter: std::env::var("DRGNX_TEST_ADAPTER").expect("DRGNX_TEST_ADAPTER names the adapter"),
    }
}

fn embedder(
    cell: &'static OnceLock<Mutex<LocalEmbedder>>,
    id: &str,
) -> MutexGuard<'static, LocalEmbedder> {
    let held = cell
        .get_or_init(|| Mutex::new(LocalEmbedder::load(spec(id), &dir(id), &device()).unwrap()));
    held.lock().unwrap_or_else(|e| e.into_inner())
}

fn gte() -> MutexGuard<'static, LocalEmbedder> {
    static CELL: OnceLock<Mutex<LocalEmbedder>> = OnceLock::new();
    embedder(&CELL, GTE)
}

fn granite() -> MutexGuard<'static, LocalEmbedder> {
    static CELL: OnceLock<Mutex<LocalEmbedder>> = OnceLock::new();
    embedder(&CELL, GRANITE)
}

fn cos(a: &[f32], b: &[f32]) -> f32 {
    let (x, y): (f32, f32) = (a.iter().map(|v| v * v).sum(), b.iter().map(|v| v * v).sum());
    a.iter().zip(b).map(|(p, q)| p * q).sum::<f32>() / (x * y).sqrt()
}

fn length_sweep(model: &mut LocalEmbedder, id: &str) {
    let mut worst = 1f32;
    for (ids, want) in sweep(id) {
        let got = model.embed_ids(std::slice::from_ref(&ids)).unwrap();
        let c = cos(&got.vectors[0], &want);
        println!(
            "PARITY {id} length {} cosine {c:.6} worst submit {:?}",
            ids.len(),
            got.worst_submit
        );
        assert!(c >= 0.999, "{id} at {} tokens: {c}", ids.len());
        worst = worst.min(c);
    }
    println!("PARITY {id} sweep min {worst:.6}");
}

#[test]
fn length_sweep_gte() {
    length_sweep(&mut gte(), GTE);
}

#[test]
fn length_sweep_granite() {
    length_sweep(&mut granite(), GRANITE);
}

#[test]
fn queries_match_the_fixture() {
    for (mut model, id) in [(gte(), GTE), (granite(), GRANITE)] {
        for q in fixture(id)["queries"].as_array().unwrap() {
            let got = model
                .embed_query(q["text"].as_str().unwrap(), None)
                .unwrap();
            let c = cos(&got, &vector(&q["vector"]));
            println!("PARITY {id} query cosine {c:.6}");
            assert!(c >= 0.999, "{id}: {c}");
        }
    }
}

#[test]
fn batched_equals_alone() {
    let mut model = gte();
    let batch: Vec<Vec<u32>> = sweep(GTE)
        .into_iter()
        .map(|(ids, _)| ids)
        .filter(|ids| ids.len() <= 130)
        .collect();
    let together = model.embed_ids(&batch).unwrap().vectors;
    for (ids, got) in batch.iter().zip(&together) {
        let alone = model.embed_ids(std::slice::from_ref(ids)).unwrap().vectors;
        let c = cos(&alone[0], got);
        println!("PARITY batched length {} cosine {c:.6}", ids.len());
        assert!(c >= 0.99999, "{} tokens: {c}", ids.len());
    }
}

#[test]
fn f32_weights_match_f16() {
    let tuning = Tuning {
        f32_weights: true,
        ..Default::default()
    };
    let mut f32_model =
        LocalEmbedder::load_tuned(spec(GRANITE), &dir(GRANITE), &device(), tuning).unwrap();
    let mut f16_model = granite();
    for (ids, _) in sweep(GRANITE).iter().filter(|(ids, _)| ids.len() <= 130) {
        let a = f32_model
            .embed_ids(std::slice::from_ref(ids))
            .unwrap()
            .vectors;
        let b = f16_model
            .embed_ids(std::slice::from_ref(ids))
            .unwrap()
            .vectors;
        let c = cos(&a[0], &b[0]);
        println!("PARITY f32 against f16 length {} cosine {c:.6}", ids.len());
        assert!(c >= 0.9999, "{} tokens: {c}", ids.len());
    }
}

#[test]
fn normalised() {
    let mut model = granite();
    let query = model
        .embed_query("where is the timer removed", None)
        .unwrap();
    assert_eq!(query.len(), 384);
    let docs = model
        .embed_docs(&["(defun a ())".to_string(), "(defun b (x) x)".to_string()])
        .unwrap();
    assert_eq!(docs.len(), 2);
    for v in docs.iter().chain([&query]) {
        assert!((v.iter().map(|x| x * x).sum::<f32>() - 1.0).abs() < 1e-5);
    }
}

#[test]
fn refuses_an_id_over_vocab() {
    let mut model = granite();
    let vocab = 50368;
    assert!(
        matches!(model.embed_ids(&[vec![50281, vocab]]), Err(EmbedFail::Other(m)) if m.contains("vocabulary"))
    );
    assert!(matches!(
        model.embed_ids(&[vec![]]),
        Err(EmbedFail::Other(_))
    ));
    assert!(
        matches!(model.embed_ids(&vec![vec![1; 2]; TOKEN_CAP]), Err(EmbedFail::Other(m)) if m.contains("cap"))
    );
    assert!(matches!(
        model.embed_ids(&[vec![1; 1025]]),
        Err(EmbedFail::Other(_))
    ));
    assert!(model.embed_ids(&[]).unwrap().vectors.is_empty());
}

#[test]
fn device_loss_is_reported() {
    let mut model = LocalEmbedder::load(spec(GRANITE), &dir(GRANITE), &device()).unwrap();
    model.embed_ids(&[vec![50281, 50282]]).unwrap();
    model.lose_device();
    // twice: it stays reported, and nothing panics on the dead device
    for _ in 0..2 {
        let got = model
            .embed_ids(&[vec![50281, 50282]])
            .map(|f| f.vectors.len());
        assert!(matches!(got, Err(EmbedFail::DeviceLost(_))), "{got:?}");
    }
}

#[test]
fn refuses_what_it_cannot_run() {
    let empty = tempfile::tempdir().unwrap();
    assert!(matches!(
        LocalEmbedder::load(spec(GTE), empty.path(), &device()),
        Err(LoadError::NotReady(_))
    ));
    let code = "CodeRankEmbed";
    assert!(matches!(
        LocalEmbedder::load(spec(code), &dir(code), &device()),
        Err(LoadError::Format(_))
    ));
    let nothing = Device::Gpu {
        adapter: "no such adapter".into(),
    };
    assert!(matches!(
        LocalEmbedder::load(spec(GRANITE), &dir(GRANITE), &nothing),
        Err(LoadError::Device(_))
    ));
}

#[test]
fn names_its_adapter() {
    let want = std::env::var("DRGNX_TEST_ADAPTER").unwrap();
    let all = adapters();
    println!("ADAPTERS {all:?}");
    assert!(
        all.iter().any(|a| a.name.contains(&want)),
        "{want} not in {all:?}"
    );
}

fn full_references(model: &mut LocalEmbedder, id: &str) {
    let path = PathBuf::from(std::env::var("DRGNX_TEST_MODELS").unwrap())
        .join("reference")
        .join(format!("{id}.json"));
    let r: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    for (texts, vectors) in [("chunks", "chunk_vectors"), ("queries", "query_vectors")] {
        let mut worst = 1f32;
        for (t, v) in r[texts]
            .as_array()
            .unwrap()
            .iter()
            .zip(r[vectors].as_array().unwrap())
        {
            let got = model
                .embed_docs(&[t.as_str().unwrap().to_string()])
                .unwrap();
            worst = worst.min(cos(&got[0], &vector(v)));
        }
        println!("PARITY {id} full {texts} min {worst:.6}");
        assert!(worst >= 0.999, "{id} {texts}: {worst}");
    }
}

#[test]
#[ignore = "20 chunks: a real GPU's row"]
fn full_references_gte() {
    full_references(&mut gte(), GTE);
}

#[test]
#[ignore = "20 chunks: a real GPU's row"]
fn full_references_granite() {
    full_references(&mut granite(), GRANITE);
}
