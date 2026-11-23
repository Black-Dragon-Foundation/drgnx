//! Vector packs in the hub (Hrafn redesign §9): STUB, the wave's red run.

use super::caches::Caches;
use hrafn::{CodeStore, ExportScope, StoreError};
use hrafn_embed::fingerprint::Fingerprint;
use std::path::{Path, PathBuf};

/// What the answer to an export says first.
pub const WARNING: &str = "";

#[derive(Debug)]
pub enum PackError {
    Refused(String),
    Store(StoreError),
}

impl std::fmt::Display for PackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PackError::Refused(m) => f.write_str(m),
            PackError::Store(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for PackError {}

impl From<StoreError> for PackError {
    fn from(e: StoreError) -> Self {
        PackError::Store(e)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Exported {
    pub path: PathBuf,
    pub sha256: String,
    pub keys: u64,
    pub fingerprint: String,
    pub label: String,
}

pub async fn export(
    _caches: &Caches,
    _store: &CodeStore,
    _scope: ExportScope,
    _out: &Path,
    _created_at: i64,
    _repo: (Option<String>, Option<String>),
) -> Result<Exported, PackError> {
    unimplemented!()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    pub fingerprint: String,
    pub label: String,
    pub keys_in_pack: u64,
    pub kept: u64,
    pub skipped_unreferenced: u64,
    pub already_had: u64,
}

impl Imported {
    pub fn summary(&self) -> String {
        unimplemented!()
    }
}

/// An open repo store and its checkout.
pub struct HeldStore<'a> {
    pub store: &'a CodeStore,
    pub root: &'a Path,
}

pub async fn import(
    _caches: &Caches,
    _file: &Path,
    _open: &[HeldStore<'_>],
    _known: &[Fingerprint],
    _keep_all: bool,
    _now_ms: i64,
) -> Result<Imported, PackError> {
    unimplemented!()
}
