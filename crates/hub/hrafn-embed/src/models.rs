//! The pinned models, and the shape of each from its own `config.json`.
//!
//! A row lists exactly what a download fetches: the safetensors, the tokeniser and two configs, at a pinned revision and
//! sum. There is no ONNX file and no GGUF. All three models pool on CLS, so there is no pooling field.
//!
//! The llama.cpp engine's rows are separate: [`ENGINES`] (the pinned `llama-server` release assets) and
//! [`GGUF_MODELS`] (the GGUF it runs, with the fingerprint record of its vectors).

use crate::fingerprint::{FingerprintRecord, Pooling};
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

/// The built-in model: Granite small r2, which the eval on drgnx's own queries ruled better overall and 2.7 times
/// faster to embed than gte-modernbert-base (which stays in the table, selectable by id).
pub fn default_model() -> &'static ModelSpec {
    MODELS
        .iter()
        .find(|m| m.id == "granite-embedding-small-english-r2")
        .expect("the table holds the default model")
}

/// The size the wizard states.
pub fn download_bytes(spec: &ModelSpec) -> u64 {
    spec.files.iter().map(|f| f.bytes).sum()
}

/// A second archive an engine asset needs beside its own (the CUDA runtime libraries of an NVIDIA build), unpacked
/// into the same engine folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeFile {
    pub url: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
}

impl RuntimeFile {
    /// The archive's file name (the URL's last segment).
    pub fn file_name(&self) -> &'static str {
        self.url.rsplit('/').next().unwrap_or(self.url)
    }

    /// The folder the archive unpacks into (its name without `.tar.gz`), beside the server's own.
    pub fn dir_name(&self) -> &'static str {
        let n = self.file_name();
        n.strip_suffix(".tar.gz")
            .or_else(|| n.strip_suffix(".zip"))
            .unwrap_or(n)
    }
}

/// One pinned llama.cpp release asset (MP-20, revised 2026-11-23): upstream's own build, pinned by sha256. CUDA for
/// NVIDIA (Linux x64 and arm64), ROCm for AMD (Linux x64), Metal on macOS, Vulkan for Intel and for every GPU the
/// vendor build cannot drive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineAsset {
    /// The release tag, `b12200`.
    pub tag: &'static str,
    /// `linux`, `windows` or `macos` (as `std::env::consts::OS`).
    pub os: &'static str,
    /// `x86_64` or `aarch64` (as `std::env::consts::ARCH`).
    pub arch: &'static str,
    /// `vulkan`, `metal`, `cuda` or `rocm`.
    pub backend: &'static str,
    /// The vendor runtime's version in the build (`13.5`, `12.8`, `10.0`), empty for Vulkan and Metal.
    pub variant: &'static str,
    /// The least NVIDIA driver (major version) the build runs on; 0 where the backend has no such floor.
    pub min_driver: u32,
    pub url: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
    /// The path of `llama-server` inside the archive.
    pub binary: &'static str,
    /// The archive of runtime libraries that goes with it, when the build bundles none.
    pub runtime: Option<RuntimeFile>,
}

impl EngineAsset {
    /// `llama.cpp-b12200-linux-x86_64-vulkan`: the name its folder goes by (`...-cuda-13.5` for a build with a
    /// runtime version).
    pub fn id(&self) -> String {
        let mut id = format!(
            "llama.cpp-{}-{}-{}-{}",
            self.tag, self.os, self.arch, self.backend
        );
        if !self.variant.is_empty() {
            id.push('-');
            id.push_str(self.variant);
        }
        id
    }

    /// The archive's file name (the URL's last segment).
    pub fn file_name(&self) -> &'static str {
        self.url.rsplit('/').next().unwrap_or(self.url)
    }

    /// What its download costs: the archive and its runtime archive.
    pub fn total_bytes(&self) -> u64 {
        self.bytes + self.runtime.map_or(0, |r| r.bytes)
    }
}

/// The llama.cpp release every machine runs (the plan's P4: the newest release at least two weeks old).
pub const ENGINE_TAG: &str = "b12200";

macro_rules! release {
    ($file:literal) => {
        concat!(
            "https://github.com/ggml-org/llama.cpp/releases/download/b12200/",
            $file
        )
    };
}

/// The pinned assets. Each sum is the one GitHub publishes for the release's asset (checked 2026-11-24; the Vulkan and
/// Metal ones also against a download on 2026-11-23).
pub const ENGINES: &[EngineAsset] = &[
    EngineAsset {
        tag: ENGINE_TAG,
        os: "linux",
        arch: "x86_64",
        backend: "vulkan",
        variant: "",
        min_driver: 0,
        url: release!("llama-b12200-bin-ubuntu-vulkan-x64.tar.gz"),
        sha256: "cb394dcf28580fca94830ddb499d9ffe989bc3a8ec4b8f9da772394cd71f067c",
        bytes: 35_882_938,
        binary: "llama-b12200/llama-server",
        runtime: None,
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "linux",
        arch: "aarch64",
        backend: "vulkan",
        variant: "",
        min_driver: 0,
        url: release!("llama-b12200-bin-ubuntu-vulkan-arm64.tar.gz"),
        sha256: "d6f7c3e2292244908072656cb613351ccfc4deee779bd4ab785ca88225827033",
        bytes: 29_192_932,
        binary: "llama-b12200/llama-server",
        runtime: None,
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "linux",
        arch: "x86_64",
        backend: "cuda",
        variant: "13.5",
        min_driver: 580,
        url: release!("llama-b12200-bin-ubuntu-cuda-13.5-x64.tar.gz"),
        sha256: "65293b49f0fd5f1f16ee5f779cbf1f4338c83170216be90e0ea5da46f87254c8",
        bytes: 169_752_937,
        binary: "llama-b12200/llama-server",
        runtime: Some(RuntimeFile {
            url: release!("cudart-llama-b12200-bin-ubuntu-cuda-13.5-x64.tar.gz"),
            sha256: "de6484ea3186062ed8817a89d0b9cda6a71cedd7d9acd7fe05cfd0373cbaff4e",
            bytes: 444_078_707,
        }),
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "linux",
        arch: "x86_64",
        backend: "cuda",
        variant: "12.8",
        min_driver: 570,
        url: release!("llama-b12200-bin-ubuntu-cuda-12.8-x64.tar.gz"),
        sha256: "394fcb916373cf3ea2c239976b41305fe7f338cba8918a90da98aa6953c9c86f",
        bytes: 188_145_475,
        binary: "llama-b12200/llama-server",
        runtime: Some(RuntimeFile {
            url: release!("cudart-llama-b12200-bin-ubuntu-cuda-12.8-x64.tar.gz"),
            sha256: "96a72bb7639df8af0ba4ca6209fba15b1e4015a4cc208c743054926f744055e1",
            bytes: 594_370_432,
        }),
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "linux",
        arch: "aarch64",
        backend: "cuda",
        variant: "13.5",
        min_driver: 580,
        url: release!("llama-b12200-bin-ubuntu-cuda-13.5-arm64.tar.gz"),
        sha256: "4a311982d256ddb2956b0de7afb12c7255a689e803469f8c0454c6cdfdb558b0",
        bytes: 164_772_167,
        binary: "llama-b12200/llama-server",
        runtime: Some(RuntimeFile {
            url: release!("cudart-llama-b12200-bin-ubuntu-cuda-13.5-arm64.tar.gz"),
            sha256: "ad2f38b89fab3aec3132e3358a0da320b7eab732bf1da9d077a7fd8d9c4bab4a",
            bytes: 559_874_053,
        }),
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "linux",
        arch: "x86_64",
        backend: "rocm",
        variant: "10.0",
        min_driver: 0,
        url: release!("llama-b12200-bin-ubuntu-rocm-10.0-x64.tar.gz"),
        sha256: "196df0e1de5847249f6079828a9a2175b8c645d1122ab7ef0501b24c600e664a",
        bytes: 255_529_060,
        binary: "llama-b12200/llama-server",
        runtime: None,
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "windows",
        arch: "x86_64",
        backend: "vulkan",
        variant: "",
        min_driver: 0,
        url: release!("llama-b12200-bin-win-vulkan-x64.zip"),
        sha256: "ef1e842d94184f7f4c949535b489b64162d59fddc490a371e5497c982344e1af",
        bytes: 37_715_401,
        binary: "llama-server.exe",
        runtime: None,
    },
    EngineAsset {
        tag: ENGINE_TAG,
        os: "macos",
        arch: "aarch64",
        backend: "metal",
        variant: "",
        min_driver: 0,
        url: release!("llama-b12200-bin-macos-arm64.tar.gz"),
        sha256: "5e7be50755d8016cee3c4c1ebba8321fe260a6323b61141a2dc7c50ee3d77cce",
        bytes: 16_708_425,
        binary: "llama-b12200/llama-server",
        runtime: None,
    },
];

/// The assets of a machine of OS and ARCH (`std::env::consts`), the newest runtime first within a backend.
pub fn engines_for(os: &str, arch: &str) -> impl Iterator<Item = &'static EngineAsset> {
    let (os, arch) = (os.to_owned(), arch.to_owned());
    ENGINES.iter().filter(move |e| e.os == os && e.arch == arch)
}

/// The asset of BACKEND (`vulkan`, `cuda`, `rocm`, `metal`) for a machine of OS and ARCH whose runtime floor DRIVER
/// meets (the newest such build); none where drgnx pins no such build.
pub fn engine_of(os: &str, arch: &str, backend: &str, driver: u32) -> Option<&'static EngineAsset> {
    engines_for(os, arch).find(|e| e.backend == backend && e.min_driver <= driver)
}

/// The portable asset (Vulkan, Metal) of a machine of OS and ARCH (`std::env::consts`): what runs without a vendor
/// runtime, and the CPU engine's build.
pub fn engine_for(os: &str, arch: &str) -> Option<&'static EngineAsset> {
    engines_for(os, arch).find(|e| matches!(e.backend, "vulkan" | "metal"))
}

/// This machine's portable asset.
pub fn engine_here() -> Option<&'static EngineAsset> {
    engine_for(std::env::consts::OS, std::env::consts::ARCH)
}

/// One pinned GGUF for the engine: the file, its sum, and the record its vectors carry.
#[derive(Debug, Clone, Copy)]
pub struct GgufSpec {
    /// `qwen3-embedding-0.6b-q8_0`: what `search/model-download` and the `llama` step of the embed role name.
    pub id: &'static str,
    pub repo: &'static str,
    pub revision: &'static str,
    pub file: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
    /// The record of its vectors at an embed-text version (hrafn's, which this crate does not know).
    pub record: fn(u32) -> FingerprintRecord,
    /// The engine's self-check: `{text, vector, ...}`, one chunk of drgnx and its F16 Transformers reference vector
    /// (`data/<model>.selfcheck.json`, made by the plan's Task 19 Step 1).
    pub selfcheck: &'static str,
}

impl GgufSpec {
    /// The self-check's text and reference vector; None if the data does not read (a build mistake, caught by a test).
    pub fn selfcheck(&self) -> Option<(String, Vec<f32>)> {
        let v: serde_json::Value = serde_json::from_str(self.selfcheck).ok()?;
        let vector = v["vector"]
            .as_array()?
            .iter()
            .map(|x| x.as_f64().map(|f| f as f32))
            .collect::<Option<Vec<f32>>>()?;
        Some((v["text"].as_str()?.to_string(), vector))
    }

    /// The file as a row of the model download.
    pub fn model_file(&self) -> ModelFile {
        ModelFile {
            name: self.file,
            sha256: self.sha256,
            bytes: self.bytes,
        }
    }
}

/// The token limit of the shared fingerprint: the engine's largest context, and the longest text it embeds.
pub const QWEN3_MAX_TOKENS: u32 = 8192;

fn qwen3_q8_0(embed_text_version: u32) -> FingerprintRecord {
    FingerprintRecord {
        model_id: "Qwen/Qwen3-Embedding-0.6B".to_owned(),
        weights_sha256: GGUF_MODELS[0].sha256.to_owned(),
        quant: "Q8_0".to_owned(),
        pooling: Pooling::Last,
        normalized: true,
        dims: 1024,
        max_tokens: QWEN3_MAX_TOKENS,
        doc_prefix: String::new(),
        query_template: "Instruct: {task}\nQuery:{query}".to_owned(),
        embed_text_version,
    }
}

/// The shared default fingerprint's model (MP-3): Qwen3-Embedding-0.6B in Q8_0, last-token pooling, normalised, 1,024
/// dims (the plan's P4 pins).
pub const GGUF_MODELS: &[GgufSpec] = &[GgufSpec {
    id: "qwen3-embedding-0.6b-q8_0",
    repo: "Qwen/Qwen3-Embedding-0.6B-GGUF",
    revision: "370f27d7550e0def9b39c1f16d3fbaa13aa67728",
    file: "Qwen3-Embedding-0.6B-Q8_0.gguf",
    sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439",
    bytes: 639_150_592,
    record: qwen3_q8_0,
    selfcheck: include_str!("../data/qwen3-embedding-0.6b.selfcheck.json"),
}];

/// The engine's default model.
pub fn default_gguf() -> &'static GgufSpec {
    &GGUF_MODELS[0]
}

#[cfg(test)]
mod gguf_tests {
    use super::*;

    #[test]
    fn every_gguf_has_a_unit_selfcheck_of_its_dims() {
        for g in GGUF_MODELS {
            let (text, vector) = g.selfcheck().expect("the self-check data reads");
            assert!(!text.is_empty(), "{}", g.id);
            assert_eq!(vector.len() as u32, (g.record)(1).dims, "{}", g.id);
            let norm: f32 = vector.iter().map(|x| x * x).sum::<f32>().sqrt();
            assert!((norm - 1.0).abs() < 1e-3, "{}: norm {norm}", g.id);
        }
    }
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
    pub norm_eps: f32,
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
                    norm_eps: real(&c, "norm_eps")? as f32,
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
                    norm_eps: real(&c, "layer_norm_epsilon")? as f32,
                })
            }
            other => Err(LoadError::Format(format!(
                "config.json: model_type {other:?}"
            ))),
        }
    }

    /// The kernels lay rows out in vec4s and halve a head for its cos and sin, so these sizes must divide evenly.
    pub(crate) fn check_engine_shape(&self, dims: usize) -> Result<(), LoadError> {
        let even = self.heads > 0
            && self.hidden.is_multiple_of(self.heads)
            && (self.hidden / self.heads).is_multiple_of(8)
            && self.intermediate.is_multiple_of(4);
        if self.hidden != dims || !even || self.global_every == 0 {
            return Err(LoadError::Format(format!(
                "no engine for this shape: {self:?}"
            )));
        }
        Ok(())
    }
}
