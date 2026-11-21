//! The embedding side of Hrafn: the pinned model table, the model cache's checks, and the built-in embedder.
//!
//! This crate is pure Rust, with no SQLite, no tree-sitter and no C, so it builds for `aarch64-linux-android`. The
//! contract: a model is a row of [`models::MODELS`], the only files it reads are that row's, at their pinned sums, and
//! the shape of the network comes from the model's own `config.json` ([`models::ModelConfig`]). [`device`] chooses
//! the device by measuring it, and [`pace`] sizes the GPU's batches from the stalls they cause.
//! See `docs/develop/runtime.md`, "Hrafn".

pub mod cache;
mod cpu;
pub mod device;
mod gpu;
mod local;
pub mod models;
pub mod pace;
pub mod tokens;
pub mod weights;

pub use gpu::{AdapterFacts, AdapterKind, adapters};
pub use local::{Device, EmbedFail, Forward, LocalEmbedder, TOKEN_CAP, Tuning};
pub use models::{
    Arch, LoadError, MODELS, ModelConfig, ModelFile, ModelSpec, default_model, download_bytes,
};
