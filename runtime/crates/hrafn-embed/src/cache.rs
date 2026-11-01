//! The model cache: what is on disk for a pinned model, and whether it is exactly what the table says.
//!
//! `<file>.part` is a download or import in progress; a file under its real name has passed its sum, so `Ready` means
//! every byte was hashed. Hashing a 300 MB model takes about a second, and only `state`, `verify` and `import` do it.

use crate::models::{ModelFile, ModelSpec, download_bytes};
use sha2::{Digest, Sha256};
use std::fmt;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelState {
    Missing,
    Partial { have: u64, total: u64 },
    Ready,
    Corrupt { file: String },
}

#[derive(Debug)]
pub enum CacheError {
    Missing(String),
    Corrupt(String),
    Io(String),
}

impl fmt::Display for CacheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CacheError::Missing(file) => write!(f, "{file} is missing"),
            CacheError::Corrupt(file) => write!(f, "{file} does not match its sum"),
            CacheError::Io(e) => write!(f, "model cache: {e}"),
        }
    }
}

impl std::error::Error for CacheError {}

/// `<root>/<id>-<revision[..12]>/`: two revisions of a model never share a directory.
pub fn model_dir(cache_root: &Path, spec: &ModelSpec) -> PathBuf {
    cache_root.join(format!("{}-{}", spec.id, &spec.revision[..12]))
}

/// The hex sha256 of a file.
pub fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        match file.read(&mut buf)? {
            0 => break,
            n => hash.update(&buf[..n]),
        }
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn part_path(dir: &Path, file: &ModelFile) -> PathBuf {
    dir.join(format!("{}.part", file.name))
}

/// What the cache holds for `spec`. A file of the wrong size or sum is `Corrupt`, and a directory with only some files, or
/// with `.part` files, is `Partial`.
pub fn state(spec: &ModelSpec, dir: &Path) -> ModelState {
    let (mut have, mut complete, mut any) = (0, true, false);
    for file in spec.files {
        match fs::metadata(dir.join(file.name)) {
            Ok(m) if m.len() == file.bytes => {
                have += file.bytes;
                any = true;
            }
            Ok(_) => {
                return ModelState::Corrupt {
                    file: file.name.to_string(),
                };
            }
            Err(_) => {
                complete = false;
                if let Ok(m) = fs::metadata(part_path(dir, file)) {
                    have += m.len().min(file.bytes);
                    any = true;
                }
            }
        }
    }
    if !any {
        return ModelState::Missing;
    }
    if !complete {
        return ModelState::Partial {
            have,
            total: download_bytes(spec),
        };
    }
    match verify(spec, dir) {
        Ok(()) => ModelState::Ready,
        Err(CacheError::Corrupt(file)) => ModelState::Corrupt { file },
        Err(CacheError::Missing(file)) | Err(CacheError::Io(file)) => ModelState::Corrupt { file },
    }
}

/// Every file of `spec` is there and matches its sum.
pub fn verify(spec: &ModelSpec, dir: &Path) -> Result<(), CacheError> {
    for file in spec.files {
        let path = dir.join(file.name);
        if !path.exists() {
            return Err(CacheError::Missing(file.name.to_string()));
        }
        let sum = sha256_file(&path).map_err(|e| CacheError::Io(format!("{}: {e}", file.name)))?;
        if sum != file.sha256 {
            return Err(CacheError::Corrupt(file.name.to_string()));
        }
    }
    Ok(())
}

/// Copies a model from `from` (same layout, for an air-gapped machine) into `dir`. Each file lands under its real name only
/// after its sum passes, so a bad source leaves nothing that could load.
pub fn import(spec: &ModelSpec, from: &Path, dir: &Path) -> Result<(), CacheError> {
    let io_err = |e: io::Error| CacheError::Io(e.to_string());
    for file in spec.files {
        let source = from.join(file.name);
        if !source.exists() {
            return Err(CacheError::Missing(file.name.to_string()));
        }
        let dest = dir.join(file.name);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(io_err)?;
        }
        let part = part_path(dir, file);
        fs::copy(&source, &part).map_err(io_err)?;
        if sha256_file(&part).map_err(io_err)? != file.sha256 {
            fs::remove_file(&part).map_err(io_err)?;
            return Err(CacheError::Corrupt(file.name.to_string()));
        }
        fs::rename(&part, &dest).map_err(io_err)?;
    }
    Ok(())
}
