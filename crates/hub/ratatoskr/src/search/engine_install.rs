//! The local engine's install (MP-20): this machine's pinned llama.cpp release asset ([`hrafn_embed::ENGINES`]),
//! downloaded only with a consent that names it and its size, checked by its sum, and unpacked into a folder of its own.
//!
//! The archive lands as `<dir>/<file>.part`. A sum that does not match keeps the `.part` and says where (a download
//! that is off can be looked at; the next install fetches it over). A good archive is unpacked into `<dir>/bin.new` by
//! the hub's safe unpackers (`zip`, or `tar` and `flate2`): only files, folders and links that stay inside, no entry
//! absolute or climbing, no name twice, sizes bounded. `llama-server` is made executable, the folder becomes
//! `<dir>/bin`, the archive goes, and only then is [`MARKER`] written, so [`installed`] never sees half an install.

use super::download::{Consent, DownloadError, fetch_one};
use crate::browser::install::Limits;
use hrafn_embed::{EngineAsset, GgufSpec, ModelFile};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// The file in an engine's folder that says its asset was unpacked whole: the asset's sum.
pub const MARKER: &str = ".installed";

/// `<cache>/engines/<asset id>`.
pub fn dir_for(cache: &Path, asset: &EngineAsset) -> PathBuf {
    cache.join("engines").join(asset.id())
}

/// Where SPEC's GGUF lives under the models folder MODELS: `<models>/<id>/<file>`.
pub fn gguf_path(models: &Path, spec: &GgufSpec) -> PathBuf {
    models.join(spec.id).join(spec.file)
}

/// Whether SPEC's GGUF is in MODELS: a file lands under its real name only once its sum passed, so its size says it.
pub fn gguf_ready(models: &Path, spec: &GgufSpec) -> bool {
    std::fs::metadata(gguf_path(models, spec)).is_ok_and(|m| m.is_file() && m.len() == spec.bytes)
}

/// `llama-server` of ASSET in DIR, when the asset was installed whole there.
pub fn installed(asset: &EngineAsset, dir: &Path) -> Option<PathBuf> {
    let mark = std::fs::read_to_string(dir.join(MARKER)).ok()?;
    if mark.trim() != asset.sha256 {
        return None;
    }
    let exe = dir.join("bin").join(asset.binary);
    exe.is_file().then_some(exe)
}

/// ASSET into DIR with CONSENT (it names the asset and its bytes): the path of its `llama-server`.
pub async fn install(
    asset: &EngineAsset,
    consent: &Consent,
    dir: &Path,
) -> Result<PathBuf, DownloadError> {
    install_with(asset, consent, dir, &|_| {}).await
}

/// [`install`], PROGRESS given the archive's bytes held.
pub async fn install_with(
    asset: &EngineAsset,
    consent: &Consent,
    dir: &Path,
    progress: &(dyn Fn(u64) + Sync),
) -> Result<PathBuf, DownloadError> {
    if consent.model != asset.id() || consent.bytes != asset.bytes {
        return Err(DownloadError::NoConsent);
    }
    if let Some(exe) = installed(asset, dir) {
        progress(asset.bytes);
        return Ok(exe);
    }
    let url = asset.url.parse().map_err(|_| DownloadError::Http(400))?;
    let file = ModelFile {
        name: asset.file_name(),
        sha256: asset.sha256,
        bytes: asset.bytes,
    };
    fetch_one(url, dir, &file, true, progress).await?;
    let (asset, dir) = (*asset, dir.to_path_buf());
    crate::clock::blocking(move || unpack(&asset, &dir))
        .await
        .map_err(|e| DownloadError::Archive(e.to_string()))?
}

/// The verified archive in DIR unpacked into `DIR/bin`, its server made executable, the archive removed and the marker
/// written last.
fn unpack(asset: &EngineAsset, dir: &Path) -> Result<PathBuf, DownloadError> {
    let disk = |e: std::io::Error| {
        tracing::warn!("engine install: {e}");
        DownloadError::Disk
    };
    let archive = dir.join(asset.file_name());
    let (staging, bin) = (dir.join("bin.new"), dir.join("bin"));
    if staging.exists() {
        std::fs::remove_dir_all(&staging).map_err(disk)?;
    }
    std::fs::create_dir_all(&staging).map_err(disk)?;
    let unpacked = if asset.file_name().ends_with(".zip") {
        crate::browser::install::unpack(&archive, &staging, Limits::default())
    } else {
        crate::debug::install::unpack_tgz(&archive, &staging, Limits::default(), None)
    };
    if let Err(e) = unpacked {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(DownloadError::Archive(format!(
            "{}: {e}",
            asset.file_name()
        )));
    }
    let exe = staging.join(asset.binary);
    if !std::fs::symlink_metadata(&exe).is_ok_and(|m| m.is_file()) {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(DownloadError::Archive(format!(
            "{} holds no {}",
            asset.file_name(),
            asset.binary
        )));
    }
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).map_err(disk)?;
    let _ = std::fs::remove_file(dir.join(MARKER));
    if bin.exists() {
        std::fs::remove_dir_all(&bin).map_err(disk)?;
    }
    std::fs::rename(&staging, &bin).map_err(disk)?;
    std::fs::remove_file(&archive).map_err(disk)?;
    std::fs::write(dir.join(MARKER), asset.sha256).map_err(disk)?;
    Ok(bin.join(asset.binary))
}
