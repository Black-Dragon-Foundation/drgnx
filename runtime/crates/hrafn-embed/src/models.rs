//! The pinned models, and the shape of each from its own `config.json`.
//!
//! A row lists exactly what a download fetches: the safetensors, the tokeniser and two configs, at a pinned revision and
//! sum. There is no ONNX file and no GGUF. All three models pool on CLS, so there is no pooling field.

use serde_json::Value;
use std::fmt;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arch {
    ModernBert,
    NomicBert,
}

#[derive(Debug, Clone, Copy)]
pub struct ModelFile {
    pub name: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct ModelSpec {
    pub id: &'static str,
    pub repo: &'static str,
    pub revision: &'static str,
    pub files: &'static [ModelFile],
    pub dims: usize,
    pub max_tokens: usize,
    pub query_prefix: &'static str,
    pub doc_prefix: &'static str,
    pub arch: Arch,
    pub licence: &'static str,
}

const fn file(name: &'static str, sha256: &'static str, bytes: u64) -> ModelFile {
    ModelFile {
        name,
        sha256,
        bytes,
    }
}

pub const MODELS: &[ModelSpec] = &[
    ModelSpec {
        id: "gte-modernbert-base",
        repo: "Alibaba-NLP/gte-modernbert-base",
        revision: "e7f32e3c00f91d699e8c43b53106206bcc72bb22",
        files: &[
            file(
                "model.safetensors",
                "3e85899d5728cb7de79781c0c3acfb91ccef9f875f1f7e0b3c9f3dd4b6a724ba",
                298_041_568,
            ),
            file(
                "tokenizer.json",
                "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30",
                3_583_228,
            ),
            file(
                "config.json",
                "8ba54dc3d35d7194f5178a4194b649f146753e02dabd22bdca5c5cbac15069ed",
                1_184,
            ),
            file(
                "1_Pooling/config.json",
                "4bf279dd9204db673304cab6e7db8448f427412a0d87f04c3e19f1de55dd98cd",
                297,
            ),
        ],
        dims: 768,
        max_tokens: 1024,
        query_prefix: "",
        doc_prefix: "",
        arch: Arch::ModernBert,
        licence: "Apache-2.0",
    },
    ModelSpec {
        id: "granite-embedding-small-english-r2",
        repo: "ibm-granite/granite-embedding-small-english-r2",
        revision: "2ab6fa8ea2d674564defd37171ae19079b864b33",
        files: &[
            file(
                "model.safetensors",
                "dcbfaf2ee50d358763cbc0c08e5b045ecbf6aeb02dc0e86ffb910029bf9ebb5f",
                95_332_048,
            ),
            file(
                "tokenizer.json",
                "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30",
                3_583_228,
            ),
            file(
                "config.json",
                "154518e6452854eb11123ce433d165f2773437aa0f36935d2204249b2c327198",
                1_315,
            ),
            file(
                "1_Pooling/config.json",
                "7fae3727656cff4a760964a58f1e4b31695c97c75d2e26346df32a87d494bbca",
                191,
            ),
        ],
        dims: 384,
        max_tokens: 1024,
        query_prefix: "",
        doc_prefix: "",
        arch: Arch::ModernBert,
        licence: "Apache-2.0",
    },
    ModelSpec {
        id: "CodeRankEmbed",
        repo: "nomic-ai/CodeRankEmbed",
        revision: "3c4b60807d71f79b43f3c4363786d9493691f8b1",
        files: &[
            file(
                "model.safetensors",
                "827529bcd58aef0d9082e66eeff7e7d53a02f62bd005f841a26b3d3e2fb17ebe",
                546_938_168,
            ),
            file(
                "tokenizer.json",
                "91f1def9b9391fdabe028cd3f3fcc4efd34e5d1f08c3bf2de513ebb5911a1854",
                711_649,
            ),
            file(
                "config.json",
                "5ff856a41d0f53ef2d74520627d464bd75c2efd8f26f381bd528654895c29b6c",
                1_525,
            ),
            file(
                "1_Pooling/config.json",
                "d02ebf56344d20f773449b15d0c10ee9a86a9178f3b3c9bfecb8b87d4350ce38",
                296,
            ),
        ],
        dims: 768,
        max_tokens: 1024,
        query_prefix: "Represent this query for searching relevant code: ",
        doc_prefix: "",
        arch: Arch::NomicBert,
        licence: "MIT",
    },
];

/// gte-modernbert-base, until the eval rules on drgnx's own queries.
pub fn default_model() -> &'static ModelSpec {
    &MODELS[0]
}

/// The size the wizard states.
pub fn download_bytes(spec: &ModelSpec) -> u64 {
    spec.files.iter().map(|f| f.bytes).sum()
}

#[derive(Debug)]
pub enum LoadError {
    /// The cache does not hold this model: `Missing`, `Partial` or `Corrupt`.
    NotReady(String),
    /// A file could not be read.
    Io(String),
    /// A file is not what the table or the engine expects.
    Format(String),
    /// No device can run this model.
    Device(String),
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LoadError::NotReady(e) => write!(f, "model not ready: {e}"),
            LoadError::Io(e) => write!(f, "model read: {e}"),
            LoadError::Format(e) => write!(f, "model format: {e}"),
            LoadError::Device(e) => write!(f, "device: {e}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// The network's shape. The engines take every size from here, so a model of the same family is config only.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelConfig {
    pub hidden: usize,
    pub heads: usize,
    pub layers: usize,
    pub intermediate: usize,
    pub vocab: usize,
    /// Every n-th layer attends globally; the others attend within `local_window`.
    pub global_every: usize,
    /// Tokens on both sides together: a token sees `local_window / 2` each way.
    pub local_window: usize,
    pub local_theta: f64,
    pub global_theta: f64,
}

fn size(c: &Value, key: &str) -> Result<usize, LoadError> {
    let v = c[key]
        .as_u64()
        .ok_or_else(|| LoadError::Format(format!("config.json: no {key}")))?;
    Ok(v as usize)
}

fn real(c: &Value, key: &str) -> Result<f64, LoadError> {
    c[key]
        .as_f64()
        .ok_or_else(|| LoadError::Format(format!("config.json: no {key}")))
}

impl ModelConfig {
    /// Reads `<dir>/config.json`. A model of a family, or with a bias or activation, that no engine has is refused here.
    pub fn read(dir: &Path) -> Result<ModelConfig, LoadError> {
        let path = dir.join("config.json");
        let bytes =
            std::fs::read(&path).map_err(|e| LoadError::Io(format!("{}: {e}", path.display())))?;
        let c: Value = serde_json::from_slice(&bytes)
            .map_err(|e| LoadError::Format(format!("config.json: {e}")))?;
        match c["model_type"].as_str() {
            Some("modernbert") => {
                for key in ["attention_bias", "mlp_bias", "norm_bias"] {
                    if c[key].as_bool() != Some(false) {
                        return Err(LoadError::Format(format!(
                            "config.json: {key} is not false"
                        )));
                    }
                }
                if c["hidden_activation"].as_str() != Some("gelu") {
                    return Err(LoadError::Format(
                        "config.json: hidden_activation is not gelu".into(),
                    ));
                }
                Ok(ModelConfig {
                    hidden: size(&c, "hidden_size")?,
                    heads: size(&c, "num_attention_heads")?,
                    layers: size(&c, "num_hidden_layers")?,
                    intermediate: size(&c, "intermediate_size")?,
                    vocab: size(&c, "vocab_size")?,
                    global_every: size(&c, "global_attn_every_n_layers")?,
                    local_window: size(&c, "local_attention")?,
                    local_theta: real(&c, "local_rope_theta")?,
                    global_theta: real(&c, "global_rope_theta")?,
                })
            }
            // every layer is global, and one theta serves both
            Some("nomic_bert") => {
                let theta = real(&c, "rotary_emb_base")?;
                Ok(ModelConfig {
                    hidden: size(&c, "n_embd")?,
                    heads: size(&c, "n_head")?,
                    layers: size(&c, "n_layer")?,
                    intermediate: size(&c, "n_inner")?,
                    vocab: size(&c, "vocab_size")?,
                    global_every: 1,
                    local_window: 0,
                    local_theta: theta,
                    global_theta: theta,
                })
            }
            other => Err(LoadError::Format(format!(
                "config.json: model_type {other:?}"
            ))),
        }
    }
}
