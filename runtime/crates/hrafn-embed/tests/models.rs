//! The model table, the cache checks, the weights and the tokeniser, on the pinned files of the read-only model volume.
//! `DRGNX_TEST_MODELS` must be set: a test that needs the volume fails without it, it never skips.

use hrafn_embed::cache::{self, CacheError, ModelState};
use hrafn_embed::tokens::Tokens;
use hrafn_embed::weights::Weights;
use hrafn_embed::{Arch, MODELS, ModelConfig, ModelFile, ModelSpec, default_model, download_bytes};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

fn volume() -> PathBuf {
    PathBuf::from(
        std::env::var("DRGNX_TEST_MODELS").expect("DRGNX_TEST_MODELS names the model volume"),
    )
}

fn dir_of(spec: &ModelSpec) -> PathBuf {
    volume().join(spec.id)
}

fn spec(id: &str) -> &'static ModelSpec {
    MODELS
        .iter()
        .find(|m| m.id == id)
        .expect("a model of the table")
}

/// A small model of our own, for the cache's flows: its sums are computed, so a test can break them.
fn tiny(dir: &Path) -> ModelSpec {
    let mut files = Vec::new();
    for (name, body) in [
        ("config.json", "{}"),
        ("sub/data.bin", "some bytes of a model"),
    ] {
        let path = dir.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, body).unwrap();
        let sha256: &'static str = cache::sha256_file(&path).unwrap().leak();
        files.push(ModelFile {
            name,
            sha256,
            bytes: body.len() as u64,
        });
    }
    ModelSpec {
        id: "tiny",
        repo: "test/tiny",
        revision: "0123456789abcdef0123456789abcdef01234567",
        files: Vec::leak(files),
        dims: 8,
        max_tokens: 16,
        query_prefix: "",
        doc_prefix: "",
        arch: Arch::ModernBert,
        licence: "MIT",
    }
}

#[test]
fn table_matches_each_config() {
    assert_eq!(default_model().id, "granite-embedding-small-english-r2");
    assert!(
        MODELS.iter().any(|m| m.id == "gte-modernbert-base"),
        "the first default stays selectable"
    );
    for spec in MODELS {
        let config = ModelConfig::read(&dir_of(spec)).unwrap();
        assert_eq!(config.hidden, spec.dims, "{}", spec.id);
        assert_eq!(config.hidden % config.heads, 0, "{}", spec.id);
        let raw: serde_json::Value =
            serde_json::from_slice(&fs::read(dir_of(spec).join("config.json")).unwrap()).unwrap();
        let arch = match raw["model_type"].as_str().unwrap() {
            "modernbert" => Arch::ModernBert,
            "nomic_bert" => Arch::NomicBert,
            other => panic!("{other}"),
        };
        assert_eq!(spec.arch, arch, "{}", spec.id);
        assert_eq!(spec.max_tokens, 1024, "{}", spec.id);
    }
    let gte = ModelConfig::read(&dir_of(spec("gte-modernbert-base"))).unwrap();
    assert_eq!(
        (gte.heads, gte.layers, gte.intermediate, gte.vocab),
        (12, 22, 1152, 50368)
    );
    assert_eq!((gte.global_every, gte.local_window), (3, 128));
    assert_eq!((gte.local_theta, gte.global_theta), (10000.0, 160000.0));
    let granite = ModelConfig::read(&dir_of(spec("granite-embedding-small-english-r2"))).unwrap();
    assert_eq!((granite.heads, granite.layers), (12, 12));
    assert_eq!(granite.global_theta, 80000.0);
}

#[test]
fn tables_name_no_onnx_or_gguf() {
    for spec in MODELS {
        let names: Vec<&str> = spec.files.iter().map(|f| f.name).collect();
        assert_eq!(
            names,
            [
                "model.safetensors",
                "tokenizer.json",
                "config.json",
                "1_Pooling/config.json"
            ],
            "{}",
            spec.id
        );
        assert_eq!(
            download_bytes(spec),
            spec.files.iter().map(|f| f.bytes).sum::<u64>()
        );
    }
}

// test-pattern: D (pure). CI fetches the volume from this list (.github/ci/models.sh), so it is the table, line for line.
#[test]
fn the_ci_model_list_is_the_table() {
    let list = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.github/ci/models.txt"),
    )
    .unwrap();
    let listed: Vec<&str> = list
        .lines()
        .filter(|l| !l.trim_start().starts_with('#') && !l.trim().is_empty())
        .collect();
    let table: Vec<String> = MODELS
        .iter()
        .flat_map(|m| {
            m.files
                .iter()
                .map(|f| format!("{} {} {} {} {}", m.id, m.repo, m.revision, f.name, f.sha256))
        })
        .collect();
    assert_eq!(listed, table);
}

#[test]
fn every_model_on_the_volume_is_ready() {
    for spec in MODELS {
        assert_eq!(
            cache::state(spec, &dir_of(spec)),
            ModelState::Ready,
            "{}",
            spec.id
        );
    }
}

#[test]
fn f16_and_bf16_weights_read_as_f32() {
    use safetensors::tensor::{Dtype, TensorView, serialize_to_file};
    let dir = tempfile::tempdir().unwrap();
    let values = [1.5f32, -2.25, 0.5, 0.0];
    let f16: Vec<u8> = values
        .iter()
        .flat_map(|v| half::f16::from_f32(*v).to_le_bytes())
        .collect();
    let bf16: Vec<u8> = values
        .iter()
        .flat_map(|v| half::bf16::from_f32(*v).to_le_bytes())
        .collect();
    let f32: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    let mut tensors = HashMap::new();
    tensors.insert(
        "model.a".to_string(),
        TensorView::new(Dtype::F16, vec![4], &f16).unwrap(),
    );
    tensors.insert(
        "b".to_string(),
        TensorView::new(Dtype::BF16, vec![4], &bf16).unwrap(),
    );
    tensors.insert(
        "c".to_string(),
        TensorView::new(Dtype::F32, vec![4], &f32).unwrap(),
    );
    serialize_to_file(&tensors, None, &dir.path().join("model.safetensors")).unwrap();

    let w = Weights::read(dir.path()).unwrap();
    for name in ["a", "b", "c"] {
        assert_eq!(w.f32(name).unwrap(), values, "{name}");
        assert_eq!(w.f16_bytes(name).unwrap(), f16, "{name}");
    }

    let real = Weights::read(&dir_of(spec("gte-modernbert-base"))).unwrap();
    assert!(real.names().all(|n| !n.starts_with("model.")));
    assert_eq!(
        real.shape("embeddings.tok_embeddings.weight").unwrap(),
        [50368, 768]
    );
    assert_eq!(real.f32("final_norm.weight").unwrap().len(), 768);

    let granite = Weights::read(&dir_of(spec("granite-embedding-small-english-r2"))).unwrap();
    let norm = granite.f32("final_norm.weight").unwrap();
    assert_eq!(norm.len(), 384);
    assert!(norm.iter().all(|x| x.is_finite() && x.abs() < 1e3));
    let back: Vec<f32> = granite
        .f16_bytes("final_norm.weight")
        .unwrap()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| half::f16::from_le_bytes(*b).to_f32())
        .collect();
    assert!(
        norm.iter()
            .zip(&back)
            .all(|(a, b)| (a - b).abs() <= a.abs() * 1e-3 + 1e-6)
    );
}

#[test]
fn transposed_weight_matches_the_source() {
    let w = Weights::read(&dir_of(spec("gte-modernbert-base"))).unwrap();
    let name = "layers.3.attn.Wqkv.weight";
    let [outputs, inputs] = *w.shape(name).unwrap() else {
        panic!()
    };
    assert_eq!((outputs, inputs), (2304, 768));
    let (source, turned) = (w.f32(name).unwrap(), w.f32_transposed(name).unwrap());
    let (raw, turned16) = (w.f16_bytes(name).unwrap(), w.f16_transposed(name).unwrap());
    assert_eq!(turned.len(), source.len());
    assert_eq!(turned16.len(), raw.len());
    for (r, c) in [
        (0, 0),
        (0, 767),
        (1, 0),
        (2303, 0),
        (2303, 767),
        (1000, 321),
    ] {
        assert_eq!(turned[c * outputs + r], source[r * inputs + c], "({r},{c})");
        assert_eq!(
            turned16[(c * outputs + r) * 2],
            raw[(r * inputs + c) * 2],
            "({r},{c})"
        );
        assert_eq!(
            turned16[(c * outputs + r) * 2 + 1],
            raw[(r * inputs + c) * 2 + 1],
            "({r},{c})"
        );
    }
}

#[test]
fn query_prefix_applied() {
    let code = spec("CodeRankEmbed");
    let tokens = Tokens::load(code, &dir_of(code)).unwrap();
    let plain = tokens.encode_doc("find a timer");
    let query = tokens.encode_query("find a timer", None);
    let prefixed = tokens.encode_doc(&format!("{}find a timer", code.query_prefix));
    assert_eq!(query, prefixed);
    assert!(query.len() > plain.len());
    assert_eq!(tokens.encode_query("find a timer", Some("")), plain);

    let gte = spec("gte-modernbert-base");
    let tokens = Tokens::load(gte, &dir_of(gte)).unwrap();
    assert_eq!(
        tokens.encode_query("find a timer", None),
        tokens.encode_doc("find a timer")
    );
}

#[test]
fn truncates_long_input() {
    let gte = spec("gte-modernbert-base");
    let tokens = Tokens::load(gte, &dir_of(gte)).unwrap();
    let ids = tokens.encode_doc(&"defun ".repeat(4000));
    assert_eq!(ids.len(), gte.max_tokens);
    assert_eq!(
        tokens.encode_query(&"defun ".repeat(4000), None).len(),
        gte.max_tokens
    );
}

#[test]
fn never_pads() {
    let gte = spec("gte-modernbert-base");
    let tokens = Tokens::load(gte, &dir_of(gte)).unwrap();
    let (short, long) = (tokens.encode_doc("a"), tokens.encode_doc("a b c d e f g"));
    assert!(short.len() < long.len());
    let pad = 50283; // the config's pad_token_id
    assert!(!short.contains(&pad) && !long.contains(&pad));
}

#[test]
fn corrupt_file_refuses_load() {
    let dir = tempfile::tempdir().unwrap();
    let spec = tiny(dir.path());
    assert_eq!(cache::state(&spec, dir.path()), ModelState::Ready);
    cache::verify(&spec, dir.path()).unwrap();

    // same size, one byte changed: only the sum can tell
    let path = dir.path().join("sub/data.bin");
    let mut body = fs::read(&path).unwrap();
    body[0] ^= 1;
    fs::write(&path, &body).unwrap();
    assert_eq!(
        cache::state(&spec, dir.path()),
        ModelState::Corrupt {
            file: "sub/data.bin".into()
        }
    );
    assert!(
        matches!(cache::verify(&spec, dir.path()), Err(CacheError::Corrupt(f)) if f == "sub/data.bin")
    );

    fs::write(&path, b"short").unwrap();
    assert_eq!(
        cache::state(&spec, dir.path()),
        ModelState::Corrupt {
            file: "sub/data.bin".into()
        }
    );
}

#[test]
fn partial_and_missing_are_told_apart() {
    let dir = tempfile::tempdir().unwrap();
    let spec = tiny(dir.path());
    let empty = tempfile::tempdir().unwrap();
    assert_eq!(cache::state(&spec, empty.path()), ModelState::Missing);
    fs::remove_file(dir.path().join("sub/data.bin")).unwrap();
    fs::write(dir.path().join("sub/data.bin.part"), "some").unwrap();
    let total = download_bytes(&spec);
    assert_eq!(
        cache::state(&spec, dir.path()),
        ModelState::Partial { have: 2 + 4, total }
    );
}

#[test]
fn import_verifies_sums() {
    let source = tempfile::tempdir().unwrap();
    let spec = tiny(source.path());
    let root = tempfile::tempdir().unwrap();
    let dir = cache::model_dir(root.path(), &spec);
    assert!(dir.ends_with("tiny-0123456789ab"));
    cache::import(&spec, source.path(), &dir).unwrap();
    assert_eq!(cache::state(&spec, &dir), ModelState::Ready);

    // a bad source: nothing lands under a real name
    fs::write(source.path().join("sub/data.bin"), "some bytes of a m0del").unwrap();
    let other = root.path().join("other");
    assert!(matches!(
        cache::import(&spec, source.path(), &other),
        Err(CacheError::Corrupt(_))
    ));
    assert!(!other.join("sub/data.bin").exists() && !other.join("sub/data.bin.part").exists());
    assert!(!matches!(cache::state(&spec, &other), ModelState::Ready));
}
