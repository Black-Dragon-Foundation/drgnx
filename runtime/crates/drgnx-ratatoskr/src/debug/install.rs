//! Debug: Install Adapter (spec §9.3, tier 2): an adapter's `:install` entry in the table, carried out.
//!
//! - **An archive** (`:url` and `:sha256`, or one such pin per platform under `:platforms`): downloaded over https
//!   through the browser installer's client (its proxy and certificate settings), checked against the pinned sha256,
//!   and unpacked, a tar.gz or a zip (`.vsix`), with only regular files and folders allowed (an entry that is absolute,
//!   climbs out or links fails the whole install). The new folder replaces `tools/INTO` whole (only the archive's
//!   `:root` folder, when given). Any failure leaves the tools folder as it was.
//! - **debugpy** (`:pip` and `:hash`): into the tools venv (made first if missing) with `pip install --require-hashes
//!   --no-deps`, so only the pinned file is accepted.
//! - **A system package** (`:system`): never run; the error says the command.

use crate::browser::install::{InstallError, Limits, fetch, unpack};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

/// What an `:install` entry asks for, on this platform.
#[derive(Clone, Debug, PartialEq)]
pub enum Plan {
    Archive {
        url: String,
        sha256: String,
        /// The folder under the tools folder it becomes.
        into: String,
        /// The archive's folder that becomes it (none: the whole archive).
        root: Option<String>,
    },
    Pip {
        requirement: String,
        hash: String,
    },
    System(String),
}

/// Where archives come from.
#[derive(Clone, Debug)]
pub enum Source {
    /// The pinned https URL.
    Https,
    /// Tests: the file named as the URL's last part, in this folder.
    Dir(PathBuf),
}

/// This machine as the pins name platforms (`linux-x64`, `darwin-arm64`, …).
pub fn platform_key() -> String {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        other => other,
    };
    format!("{os}-{arch}")
}

fn field(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_owned)
}

/// The table's `:install` entry INSTALL on PLATFORM.
pub fn plan(install: &Value, platform: &str) -> Result<Plan, String> {
    if let Some(c) = field(install, "system") {
        return Ok(Plan::System(c));
    }
    if let Some(requirement) = field(install, "pip") {
        let hash = field(install, "hash").ok_or("an :install with :pip needs its :hash")?;
        return Ok(Plan::Pip { requirement, hash });
    }
    let into = field(install, "into").ok_or("an archive :install needs :into")?;
    let pin = match install.get("platforms").and_then(Value::as_array) {
        Some(pins) => pins
            .iter()
            .find(|p| field(p, "platform").as_deref() == Some(platform))
            .ok_or_else(|| format!("{into} has no download for this platform ({platform})"))?,
        None => install,
    };
    let url = field(pin, "url").ok_or("an archive :install needs :url")?;
    let sha256 = field(pin, "sha256").ok_or("an archive :install needs :sha256")?;
    let safe = |s: &str| {
        let p = Path::new(s);
        !s.is_empty() && p.components().all(|c| matches!(c, Component::Normal(_)))
    };
    let root = field(install, "root");
    if !safe(&into) || root.as_deref().is_some_and(|r| !safe(r)) {
        return Err(format!("{into}: :into and :root are folder names"));
    }
    Ok(Plan::Archive {
        url,
        sha256,
        into,
        root,
    })
}

/// Debugpy's commands: the venv's creation with PYTHON, the hash-checked pip install, and the requirements file's
/// text (it goes to `TOOLS/venv/drgnx-requirements.txt`).
pub fn pip_commands(
    plan: &Plan,
    tools: &Path,
    python: &str,
) -> Result<(Vec<String>, Vec<String>, String), String> {
    let Plan::Pip { requirement, hash } = plan else {
        return Err("not a pip install".into());
    };
    let venv = tools.join("venv");
    let show = |p: &Path| p.to_string_lossy().into_owned();
    Ok((
        vec![python.into(), "-m".into(), "venv".into(), show(&venv)],
        vec![
            show(&venv.join("bin/python3")),
            "-m".into(),
            "pip".into(),
            "install".into(),
            "--require-hashes".into(),
            "--no-deps".into(),
            "-r".into(),
            show(&venv.join("drgnx-requirements.txt")),
        ],
        format!("{requirement} --hash={hash}\n"),
    ))
}

/// Removes a path when dropped.
struct Gone(PathBuf);

impl Drop for Gone {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
        let _ = fs::remove_file(&self.0);
    }
}

fn io_err(p: &Path, e: io::Error) -> String {
    format!("{}: {e}", p.display())
}

/// Carries PLAN out under TOOLS, archives from SOURCE; ENV is the user's environment (pip's PATH). What it did, in a
/// sentence.
pub async fn install(
    plan: &Plan,
    tools: &Path,
    source: &Source,
    env: &[(OsString, OsString)],
) -> Result<String, String> {
    match plan {
        Plan::System(c) => Err(format!(
            "this adapter comes from a system package: install it with `{c}`"
        )),
        Plan::Pip { requirement, .. } => {
            let (venv, pip, req) = pip_commands(plan, tools, "python3")?;
            let step = |label: &str, argv: Vec<String>| super::tasks::Step {
                label: label.into(),
                argv,
                cwd: tools.to_path_buf(),
                env: vec![],
                background: None,
            };
            fs::create_dir_all(tools).map_err(|e| io_err(tools, e))?;
            let mut steps = vec![];
            if !tools.join("venv/bin/python3").exists() {
                steps.push(step("python3 -m venv", venv));
            }
            super::tasks::run(&steps, env).await?;
            let file = tools.join("venv/drgnx-requirements.txt");
            fs::write(&file, req).map_err(|e| io_err(&file, e))?;
            super::tasks::run(&[step("pip install", pip)], env).await?;
            Ok(format!(
                "{requirement} installed in {}",
                tools.join("venv").display()
            ))
        }
        Plan::Archive {
            url,
            sha256,
            into,
            root,
        } => {
            fs::create_dir_all(tools).map_err(|e| io_err(tools, e))?;
            let download = tools.join(format!(".{into}.download"));
            let partial = tools.join(format!(".{into}.partial"));
            let old = tools.join(format!(".{into}.old"));
            for p in [&download, &partial, &old] {
                drop(Gone(p.clone()));
            }
            let _d = Gone(download.clone());
            let _p = Gone(partial.clone());
            let limits = Limits::default();
            let got = match source {
                Source::Https => fetch(url, &download, limits)
                    .await
                    .map_err(|e| e.to_string())?,
                Source::Dir(dir) => {
                    let name = url.rsplit('/').next().unwrap_or(url);
                    copy_hashed(&dir.join(name), &download)?
                }
            };
            if &got != sha256 {
                return Err(InstallError::DigestMismatch {
                    expected: sha256.clone(),
                    got,
                }
                .to_string());
            }
            fs::create_dir(&partial).map_err(|e| io_err(&partial, e))?;
            let dl = download.clone();
            let to = partial.clone();
            let tarball = url.ends_with(".tar.gz") || url.ends_with(".tgz");
            crate::clock::blocking(move || {
                if tarball {
                    unpack_tgz(&dl, &to, limits)
                } else {
                    unpack(&dl, &to, limits)
                }
            })
            .await
            .map_err(|e| e.to_string())?
            .map_err(|e| e.to_string())?;
            let made = match root {
                Some(r) => partial.join(r),
                None => partial.clone(),
            };
            if !made.is_dir() {
                return Err(format!(
                    "the archive has no folder {}",
                    root.as_deref().unwrap_or_default()
                ));
            }
            let dest = tools.join(into);
            let _o = Gone(old.clone());
            if dest.exists() {
                fs::rename(&dest, &old).map_err(|e| io_err(&dest, e))?;
            }
            if let Err(e) = fs::rename(&made, &dest) {
                let _ = fs::rename(&old, &dest);
                return Err(io_err(&dest, e));
            }
            Ok(format!("{into} installed in {}", dest.display()))
        }
    }
}

/// FROM copied to the new file TO: its sha256.
fn copy_hashed(from: &Path, to: &Path) -> Result<String, String> {
    let mut src = File::open(from).map_err(|e| io_err(from, e))?;
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(to)
        .map_err(|e| io_err(to, e))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = src.read(&mut buf).map_err(|e| io_err(from, e))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        io::Write::write_all(&mut out, &buf[..n]).map_err(|e| io_err(to, e))?;
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// The tar.gz TGZ into DEST, by the zip unpacker's rules: only regular files and folders, no entry absolute or
/// climbing, no name twice, files created new, sizes counted as written.
fn unpack_tgz(tgz: &Path, dest: &Path, limits: Limits) -> Result<(), InstallError> {
    let file = File::open(tgz).map_err(|e| InstallError::Io(format!("{}: {e}", tgz.display())))?;
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(file));
    let entries = archive
        .entries()
        .map_err(|e| InstallError::Archive(e.to_string()))?;
    let mut seen = std::collections::HashSet::new();
    let (mut total, mut count) = (0u64, 0usize);
    for entry in entries {
        let mut entry = entry.map_err(|e| InstallError::Archive(e.to_string()))?;
        count += 1;
        if count > limits.entries {
            return Err(InstallError::TooLarge(format!(
                "the archive has over {} entries",
                limits.entries
            )));
        }
        let raw = String::from_utf8_lossy(&entry.path_bytes()).into_owned();
        let unsafe_name = || InstallError::Unsafe(format!("entry {raw:?}"));
        if raw.starts_with('/') || raw.split('/').any(|c| c == "..") {
            return Err(unsafe_name());
        }
        let name = PathBuf::from(raw.trim_end_matches('/'));
        if name.as_os_str().is_empty()
            || name
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
        {
            return Err(unsafe_name());
        }
        let target = dest.join(&name);
        let kind = entry.header().entry_type();
        if kind.is_dir() {
            fs::create_dir_all(&target)
                .map_err(|e| InstallError::Io(format!("{}: {e}", target.display())))?;
            continue;
        }
        if kind.is_symlink() || kind.is_hard_link() {
            return Err(InstallError::Unsafe(format!("entry {raw:?} is a link")));
        }
        if !kind.is_file() {
            return Err(InstallError::Unsafe(format!(
                "entry {raw:?} is not a file or a folder"
            )));
        }
        if !seen.insert(name.clone()) {
            return Err(InstallError::Unsafe(format!("entry {raw:?} appears twice")));
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| InstallError::Io(format!("{}: {e}", parent.display())))?;
        }
        let mode = entry.header().mode().unwrap_or(0o644);
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(if mode & 0o111 != 0 { 0o755 } else { 0o644 })
            .open(&target)
            .map_err(|e| InstallError::Io(format!("{}: {e}", target.display())))?;
        let allowed = limits.entry.min(limits.unpacked - total);
        let n = io::copy(&mut (&mut entry).take(allowed + 1), &mut out)
            .map_err(|e| InstallError::Archive(format!("{raw}: {e}")))?;
        if n > allowed {
            return Err(InstallError::TooLarge(format!(
                "entry {raw:?} passes the unpack limits"
            )));
        }
        total += n;
    }
    Ok(())
}
