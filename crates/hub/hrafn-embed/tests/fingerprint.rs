//! The fingerprint record: its canonical bytes, what moves the fingerprint, and the built-in model's record.
//!
//! test-pattern: pure (D).

use hrafn_embed::fingerprint::{
    FP_RECORD_VERSION, Fingerprint, FingerprintRecord, Identity, Pooling, RECORD_KEYS,
    builtin_record,
};
use hrafn_embed::{MODELS, default_model};

fn qwen() -> FingerprintRecord {
    FingerprintRecord {
        model_id: "Qwen/Qwen3-Embedding-0.6B".into(),
        weights_sha256: "ab".repeat(32),
        quant: "Q8_0".into(),
        pooling: Pooling::Last,
        normalized: true,
        dims: 1024,
        max_tokens: 32768,
        doc_prefix: String::new(),
        query_template: "Instruct: {task}\nQuery:{query}".into(),
        embed_text_version: 1,
    }
}

/// A fixed record has a fixed fingerprint: a change to the canonical encoding moves every stored vector's key, so it
/// shows here first (and then `FP_RECORD_VERSION` moves with it).
#[test]
fn canonical_is_stable() {
    assert_eq!(FP_RECORD_VERSION, 1);
    let fp = qwen().fingerprint();
    assert_eq!(
        fp.hex(),
        "22d66a3886b0a9e6f3938c62b19081da265c8b03f1474f38a2271f97b449f629"
    );
    assert_eq!(fp.hex16(), "22d66a3886b0a9e6");
    assert_eq!(&qwen().canonical()[..4], FP_RECORD_VERSION.to_le_bytes());
    // the hex parses back, in either case; nothing else does
    assert_eq!(Fingerprint::parse(&fp.hex()), Some(fp));
    assert_eq!(Fingerprint::parse(&fp.hex().to_uppercase()), Some(fp));
    for bad in [
        "",
        "tei:tei",
        &fp.hex()[..63],
        &format!("{}0", fp.hex()),
        &"g".repeat(64),
    ] {
        assert_eq!(Fingerprint::parse(bad), None, "{bad:?}");
    }
    // the JSON round trip keeps the fingerprint
    let r = FingerprintRecord::from_json(&qwen().to_json()).unwrap();
    assert_eq!(r, qwen());
    assert_eq!(r.fingerprint(), fp);
    let id = Identity::new(r, "Qwen3 0.6B");
    assert_eq!((id.fp, id.label.as_str()), (fp, "Qwen3 0.6B"));
}

/// Changing any one field changes the fingerprint.
#[test]
fn every_field_moves_the_fingerprint() {
    let base = qwen().fingerprint();
    type Edit = Box<dyn Fn(&mut FingerprintRecord)>;
    let edits: Vec<(&str, Edit)> = vec![
        ("model_id", Box::new(|r| r.model_id.push('x'))),
        (
            "weights_sha256",
            Box::new(|r| r.weights_sha256 = "cd".repeat(32)),
        ),
        ("quant", Box::new(|r| r.quant = "F16".into())),
        ("pooling", Box::new(|r| r.pooling = Pooling::Mean)),
        ("normalized", Box::new(|r| r.normalized = false)),
        ("dims", Box::new(|r| r.dims = 512)),
        ("max_tokens", Box::new(|r| r.max_tokens = 8192)),
        (
            "doc_prefix",
            Box::new(|r| r.doc_prefix = "passage: ".into()),
        ),
        (
            "query_template",
            Box::new(|r| r.query_template = "{query}".into()),
        ),
        ("embed_text_version", Box::new(|r| r.embed_text_version = 2)),
    ];
    assert_eq!(edits.len(), RECORD_KEYS.len(), "a field without a row here");
    for (name, edit) in edits {
        let mut r = qwen();
        edit(&mut r);
        assert_ne!(
            r.fingerprint(),
            base,
            "{name} does not move the fingerprint"
        );
    }
    // the four poolings differ among themselves
    let all: Vec<_> = [Pooling::Cls, Pooling::Mean, Pooling::Last, Pooling::Unknown]
        .into_iter()
        .map(|p| {
            FingerprintRecord {
                pooling: p,
                ..qwen()
            }
            .fingerprint()
        })
        .collect();
    for (i, a) in all.iter().enumerate() {
        assert!(all.iter().skip(i + 1).all(|b| a != b));
    }
}

/// No field names an engine or a backend: the record's JSON keys are exactly the listed ones.
#[test]
fn engine_is_not_a_field() {
    let v: serde_json::Value = serde_json::from_str(&qwen().to_json()).unwrap();
    let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    let mut want = RECORD_KEYS.to_vec();
    want.sort_unstable();
    assert_eq!(keys, want);
    assert_eq!(
        want,
        [
            "dims",
            "doc_prefix",
            "embed_text_version",
            "max_tokens",
            "model_id",
            "normalized",
            "pooling",
            "quant",
            "query_template",
            "weights_sha256"
        ]
    );
    // a record with a field of an engine is refused, not ignored
    let with_engine = qwen().to_json().replacen('{', "{\"engine\":\"vulkan\",", 1);
    assert!(FingerprintRecord::from_json(&with_engine).is_err());
}

/// The built-in model's record is its table row: CLS, normalised, the row's dims, token limit and prefixes, the
/// weights' pinned sum.
#[test]
fn builtin_record_matches_the_table() {
    for spec in MODELS {
        let r = builtin_record(spec, 1);
        assert_eq!(r.model_id, spec.id);
        assert_eq!(r.pooling, Pooling::Cls);
        assert!(r.normalized);
        assert_eq!(
            (r.dims as usize, r.max_tokens as usize),
            (spec.dims, spec.max_tokens)
        );
        assert_eq!(r.doc_prefix, spec.doc_prefix);
        assert_eq!(r.query_template, format!("{}{{query}}", spec.query_prefix));
        let weights = spec
            .files
            .iter()
            .find(|f| f.name == "model.safetensors")
            .unwrap();
        assert_eq!(r.weights_sha256, weights.sha256);
        assert_eq!(r.embed_text_version, 1);
        assert_ne!(r.fingerprint(), builtin_record(spec, 2).fingerprint());
    }
    // the models differ
    let fps: Vec<_> = MODELS
        .iter()
        .map(|m| builtin_record(m, 1).fingerprint())
        .collect();
    assert!(fps.windows(2).all(|w| w[0] != w[1]));
    assert_eq!(
        builtin_record(default_model(), 1).model_id,
        default_model().id
    );
}
