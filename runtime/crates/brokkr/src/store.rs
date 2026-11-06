//! The installed plugins: `<data>/plugins/NAME/{plugin.json,plugin.wasm}`.
//!
//! Every file is read through `eitri`, beneath a pinned directory, so a link anywhere under the root is never
//! followed: a plugin folder that is a link is skipped, and a link where a file should be is that plugin's error.

use std::os::fd::AsFd;
use std::path::{Path, PathBuf};

use eitri::{FsError, Kind};

use crate::manifest::{MAX_MANIFEST_BYTES, Manifest, ManifestError, parse, plugin_hash};

/// The most a plugin component may hold.
pub const MAX_WASM_BYTES: u64 = 64 * 1024 * 1024;

/// A plugin as installed: where it is, what its manifest says and the hash the user approves.
#[derive(Debug, Clone)]
pub struct Installed {
    pub dir: PathBuf,
    pub manifest: Manifest,
    pub hash: [u8; 32],
}

/// Reads every plugin folder under `root`, in name order. A folder that is not a real directory (a link, a
/// stray file) is skipped; one that cannot be read or whose manifest is refused is an `Err` named by its folder.
/// A missing or unreadable root gives an empty list.
pub fn scan(root: &Path) -> Vec<Result<Installed, (String, ManifestError)>> {
    // The root's own path is the user's configuration and may pass through links; nothing beneath it may.
    let Ok(root) = root.canonicalize() else {
        return Vec::new();
    };
    let Ok(pinned) = eitri::open_path(&root, Kind::Dir) else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&root) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .collect();
    names.sort();
    let mut out = Vec::new();
    for name in names {
        match eitri::open_beneath(pinned.fd.as_fd(), Path::new(&name), Kind::Dir) {
            Ok(dir) => out.push(read_one(&root, &name, &dir).map_err(|e| (name, e))),
            Err(FsError::Link { .. } | FsError::NotDir) => {}
            Err(e) => out.push(Err((name, io_error("", &e)))),
        }
    }
    out
}

fn read_one(root: &Path, name: &str, dir: &eitri::Pinned) -> Result<Installed, ManifestError> {
    let manifest_bytes = read(dir, "plugin.json", MAX_MANIFEST_BYTES)?;
    let manifest = parse(&manifest_bytes)?;
    if manifest.name.as_str() != name {
        return Err(ManifestError {
            path: "name".into(),
            message: format!(
                "the manifest names {:?}, but its folder is {name:?}",
                manifest.name.as_str()
            ),
        });
    }
    let wasm = read(dir, "plugin.wasm", MAX_WASM_BYTES)?;
    Ok(Installed {
        dir: root.join(name),
        hash: plugin_hash(&manifest_bytes, &wasm),
        manifest,
    })
}

fn read(dir: &eitri::Pinned, file: &str, cap: u64) -> Result<Vec<u8>, ManifestError> {
    eitri::read_regular(dir.fd.as_fd(), Path::new(file), cap).map_err(|e| io_error(file, &e))
}

fn io_error(file: &str, e: &FsError) -> ManifestError {
    ManifestError {
        path: String::new(),
        message: if file.is_empty() {
            e.to_string()
        } else {
            format!("{file}: {e}")
        },
    }
}
