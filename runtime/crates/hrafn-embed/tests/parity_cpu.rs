//! The CPU path against the reference vectors. It must agree with the GPU path, because vectors from both land in one
//! index: that's the fallback's premise, and `cpu_and_gpu_agree` in `parity_gpu.rs` holds it.

use hrafn_embed::{Device, LocalEmbedder, MODELS, ModelSpec, Tuning};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, OnceLock};

const GTE: &str = "gte-modernbert-base";
const GRANITE: &str = "granite-embedding-small-english-r2";
const CPU: Device = Device::Cpu { threads: 4 };

fn fixture(id: &str) -> Value {
    let text = match id {
        GTE => include_str!("fixtures/gte-modernbert-base.json"),
        GRANITE => include_str!("fixtures/granite-embedding-small-english-r2.json"),
        other => panic!("{other}"),
    };
    serde_json::from_str(text).unwrap()
}

fn vector(v: &Value) -> Vec<f32> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap() as f32)
        .collect()
}

fn sweep(id: &str) -> Vec<(Vec<u32>, Vec<f32>)> {
    let rows = fixture(id)["sweep"].as_array().unwrap().clone();
    let ids = |v: &Value| {
        v["ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_u64().unwrap() as u32)
            .collect()
    };
    rows.iter()
        .map(|v| (ids(v), vector(&v["vector"])))
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

fn embedder(
    cell: &'static OnceLock<Mutex<LocalEmbedder>>,
    id: &str,
) -> MutexGuard<'static, LocalEmbedder> {
    let held =
        cell.get_or_init(|| Mutex::new(LocalEmbedder::load(spec(id), &dir(id), &CPU).unwrap()));
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
    for (ids, want) in sweep(id) {
        let got = model.embed_ids(std::slice::from_ref(&ids)).unwrap();
        let c = cos(&got.vectors[0], &want);
        println!("PARITY {id} cpu length {} cosine {c:.6}", ids.len());
        assert!(c >= 0.999, "{id} at {} tokens: {c}", ids.len());
        assert!(got.worst_submit.is_zero());
    }
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
fn reference_chunks_and_queries_gte() {
    let mut model = gte();
    let f = fixture(GTE);
    for row in f["chunks"].as_array().unwrap() {
        let got = model
            .embed_docs(&[row["text"].as_str().unwrap().to_string()])
            .unwrap();
        let c = cos(&got[0], &vector(&row["vector"]));
        println!("PARITY {GTE} cpu chunk cosine {c:.6}");
        assert!(c >= 0.999, "{c}");
    }
    for row in f["queries"].as_array().unwrap() {
        let got = model
            .embed_query(row["text"].as_str().unwrap(), None)
            .unwrap();
        let c = cos(&got, &vector(&row["vector"]));
        println!("PARITY {GTE} cpu query cosine {c:.6}");
        assert!(c >= 0.999, "{c}");
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
        println!("PARITY cpu batched length {} cosine {c:.6}", ids.len());
        assert!(c >= 0.99999, "{} tokens: {c}", ids.len());
    }
}

#[test]
fn baseline_matches_avx2() {
    let tuning = Tuning {
        baseline_cpu: true,
        ..Default::default()
    };
    let mut plain = LocalEmbedder::load_tuned(spec(GRANITE), &dir(GRANITE), &CPU, tuning).unwrap();
    let mut model = granite();
    for (ids, _) in sweep(GRANITE).iter().filter(|(ids, _)| ids.len() <= 130) {
        let a = plain.embed_ids(std::slice::from_ref(ids)).unwrap().vectors;
        let b = model.embed_ids(std::slice::from_ref(ids)).unwrap().vectors;
        let c = cos(&a[0], &b[0]);
        println!(
            "PARITY baseline against dispatched length {} cosine {c:.6}",
            ids.len()
        );
        assert!(c >= 0.99999, "{} tokens: {c}", ids.len());
    }
}

#[test]
fn normalised() {
    let mut model = granite();
    let query = model
        .embed_query("where is the timer removed", None)
        .unwrap();
    assert_eq!(query.len(), 384);
    assert!((query.iter().map(|x| x * x).sum::<f32>() - 1.0).abs() < 1e-5);
}
