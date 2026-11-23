//! Vector packs (Hrafn redesign §9): STUB, the wave's red run.

use crate::cache::QuantRow;
use crate::store::{CodeStore, KeyKind, StoreError};
use crate::tree::View;
use std::path::Path;

pub const PACK_FORMAT: u32 = 1;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PackHeader {
    pub format: u32,
    pub record: String,
    pub created_at: i64,
    pub tool_version: String,
    pub repo_url: Option<String>,
    pub commit: Option<String>,
}

pub struct PackReader {
    _private: (),
}

impl PackReader {
    pub fn len(&self) -> u64 {
        unimplemented!()
    }

    pub fn is_empty(&self) -> bool {
        unimplemented!()
    }

    pub fn keys(&self, _kind: KeyKind) -> Result<Vec<[u8; 32]>, StoreError> {
        unimplemented!()
    }

    pub fn rows(&self, _kind: KeyKind, _keys: &[[u8; 32]]) -> Result<Vec<QuantRow>, StoreError> {
        unimplemented!()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExportScope {
    View(View),
    AllTrees,
}

pub async fn export_keys(
    _store: &CodeStore,
    _scope: ExportScope,
) -> Result<Vec<(KeyKind, [u8; 32])>, StoreError> {
    unimplemented!()
}

pub fn write_pack(
    _out: &Path,
    _header: &PackHeader,
    _rows: impl Iterator<Item = (KeyKind, QuantRow)>,
) -> Result<[u8; 32], StoreError> {
    unimplemented!()
}

pub fn read_pack(_path: &Path) -> Result<(PackHeader, PackReader), StoreError> {
    unimplemented!()
}
