//! The fingerprint of an embedding model: what makes two vectors comparable (redesign design §5, MP-2).
//!
//! A vector carries the fingerprint of the model, pooling and prompt that made it, and a search mixes only vectors of one
//! fingerprint. The fingerprint is the sha256 of a canonical record ([`FingerprintRecord::canonical`]). The engine that
//! ran the model (llama.cpp on Vulkan or Metal, a TEI server, the built-in forward pass) is **not** a field: vectors of
//! one record agree closely whichever engine made them, and must be interchangeable.
//!
//! A label (`Identity::label`) is for display only. It is never a key and never reaches a store.

use crate::models::ModelSpec;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// The version of the canonical encoding; it is the first field of [`FingerprintRecord::canonical`], so a change to the
/// encoding moves every fingerprint.
pub const FP_RECORD_VERSION: u32 = 1;

/// How a model reduces its token vectors to one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pooling {
    Cls,
    Mean,
    Last,
    /// A server that does not say.
    Unknown,
}

impl Pooling {
    /// `cls`, `mean`, `last` or `unknown`.
    pub fn as_str(self) -> &'static str {
        match self {
            Pooling::Cls => "cls",
            Pooling::Mean => "mean",
            Pooling::Last => "last",
            Pooling::Unknown => "unknown",
        }
    }

    /// The pooling a name stands for: `cls`, `mean`, `last` (also `last-token` and `last_token`); else `Unknown`.
    pub fn parse(s: &str) -> Pooling {
        match s.to_ascii_lowercase().as_str() {
            "cls" => Pooling::Cls,
            "mean" => Pooling::Mean,
            "last" | "last-token" | "last_token" => Pooling::Last,
            _ => Pooling::Unknown,
        }
    }
}

/// What is hashed into a fingerprint: every field changes the vectors a model makes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FingerprintRecord {
    /// `Qwen/Qwen3-Embedding-0.6B`.
    pub model_id: String,
    /// The weights file's sha256 (GGUF or safetensors); a server's revision or digest when that is all it proves.
    pub weights_sha256: String,
    /// `Q8_0`, `F16`, `float16`.
    pub quant: String,
    pub pooling: Pooling,
    pub normalized: bool,
    pub dims: u32,
    pub max_tokens: u32,
    pub doc_prefix: String,
    /// `Instruct: {task}\nQuery:{query}`.
    pub query_template: String,
    pub embed_text_version: u32,
}

/// The JSON keys of a record, in the canonical order (the engine is not among them).
pub const RECORD_KEYS: [&str; 10] = [
    "model_id",
    "weights_sha256",
    "quant",
    "pooling",
    "normalized",
    "dims",
    "max_tokens",
    "doc_prefix",
    "query_template",
    "embed_text_version",
];

fn field(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(bytes);
}

impl FingerprintRecord {
    /// The canonical bytes: [`FP_RECORD_VERSION`], then each field in [`RECORD_KEYS`]'s order, every one length-prefixed
    /// (a `u32` little-endian length, then the bytes: text as UTF-8, numbers as `u32` little-endian, the flag as one byte,
    /// the pooling as its name).
    pub fn canonical(&self) -> Vec<u8> {
        let mut out = FP_RECORD_VERSION.to_le_bytes().to_vec();
        field(&mut out, self.model_id.as_bytes());
        field(&mut out, self.weights_sha256.as_bytes());
        field(&mut out, self.quant.as_bytes());
        field(&mut out, self.pooling.as_str().as_bytes());
        field(&mut out, &[u8::from(self.normalized)]);
        field(&mut out, &self.dims.to_le_bytes());
        field(&mut out, &self.max_tokens.to_le_bytes());
        field(&mut out, self.doc_prefix.as_bytes());
        field(&mut out, self.query_template.as_bytes());
        field(&mut out, &self.embed_text_version.to_le_bytes());
        out
    }

    /// The sha256 of [`canonical`](Self::canonical).
    pub fn fingerprint(&self) -> Fingerprint {
        Fingerprint(Sha256::digest(self.canonical()).into())
    }

    /// The record as JSON: the keys of [`RECORD_KEYS`].
    pub fn to_json(&self) -> String {
        json!({
            "model_id": self.model_id,
            "weights_sha256": self.weights_sha256,
            "quant": self.quant,
            "pooling": self.pooling.as_str(),
            "normalized": self.normalized,
            "dims": self.dims,
            "max_tokens": self.max_tokens,
            "doc_prefix": self.doc_prefix,
            "query_template": self.query_template,
            "embed_text_version": self.embed_text_version,
        })
        .to_string()
    }

    /// A record from [`to_json`](Self::to_json)'s text: every key present, no other.
    pub fn from_json(text: &str) -> villa::Result<FingerprintRecord> {
        let bad = |what: String| {
            villa::Error::invalid("The fingerprint record is not valid.").with_detail(what)
        };
        let v: Value = serde_json::from_str(text).map_err(|e| bad(format!("not JSON: {e}")))?;
        let obj = v
            .as_object()
            .ok_or_else(|| bad("a record is a JSON object".into()))?;
        if let Some(k) = obj.keys().find(|k| !RECORD_KEYS.contains(&k.as_str())) {
            return Err(bad(format!("a record has no field {k:?}")));
        }
        let text_of = |k: &str| -> villa::Result<String> {
            obj.get(k)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| bad(format!("field {k:?} is missing or not text")))
        };
        let num_of = |k: &str| -> villa::Result<u32> {
            obj.get(k)
                .and_then(Value::as_u64)
                .and_then(|n| u32::try_from(n).ok())
                .ok_or_else(|| bad(format!("field {k:?} is missing or not a number")))
        };
        Ok(FingerprintRecord {
            model_id: text_of("model_id")?,
            weights_sha256: text_of("weights_sha256")?,
            quant: text_of("quant")?,
            pooling: Pooling::parse(&text_of("pooling")?),
            normalized: obj
                .get("normalized")
                .and_then(Value::as_bool)
                .ok_or_else(|| bad("field \"normalized\" is missing or not a flag".into()))?,
            dims: num_of("dims")?,
            max_tokens: num_of("max_tokens")?,
            doc_prefix: text_of("doc_prefix")?,
            query_template: text_of("query_template")?,
            embed_text_version: num_of("embed_text_version")?,
        })
    }
}

/// A fingerprint: 32 bytes, 64 hex characters. It is the `model` of every stored vector.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Fingerprint(pub [u8; 32]);

impl Fingerprint {
    /// 64 lowercase hex characters.
    pub fn hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// The first 16 hex characters: a file name, a log line.
    pub fn hex16(&self) -> String {
        self.hex()[..16].to_owned()
    }

    /// The fingerprint of 64 hex characters (either case); none for anything else.
    pub fn parse(s: &str) -> Option<Fingerprint> {
        if s.len() != 64 || !s.is_ascii() {
            return None;
        }
        let mut out = [0u8; 32];
        for (i, b) in out.iter_mut().enumerate() {
            *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()?;
        }
        Some(Fingerprint(out))
    }
}

/// A model's identity as an embedder states it: the fingerprint, the record it came from, and a label for the screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub fp: Fingerprint,
    pub record: FingerprintRecord,
    /// For display only; never a key.
    pub label: String,
}

impl Identity {
    /// The identity of RECORD, shown as LABEL.
    pub fn new(record: FingerprintRecord, label: impl Into<String>) -> Identity {
        Identity {
            fp: record.fingerprint(),
            record,
            label: label.into(),
        }
    }
}

/// The record of the built-in model SPEC (CLS pooling, normalised, the table's dims, token limit and prefixes), at the
/// embed-text version EMBED_TEXT_VERSION. Its weights are the table's pinned `.safetensors` sum, and the engine computes
/// in `f32`.
pub fn builtin_record(spec: &ModelSpec, embed_text_version: u32) -> FingerprintRecord {
    let weights = spec
        .files
        .iter()
        .find(|f| f.name.ends_with(".safetensors"))
        .map_or("", |f| f.sha256);
    FingerprintRecord {
        model_id: spec.id.to_owned(),
        weights_sha256: weights.to_owned(),
        quant: "f32".to_owned(),
        pooling: Pooling::Cls,
        normalized: true,
        dims: spec.dims as u32,
        max_tokens: spec.max_tokens as u32,
        doc_prefix: spec.doc_prefix.to_owned(),
        query_template: format!("{}{{query}}", spec.query_prefix),
        embed_text_version,
    }
}
