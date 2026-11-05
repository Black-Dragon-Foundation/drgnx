//! `drgnx browser install`: a Chrome for Testing headless shell, downloaded over HTTPS, checked against a digest that
//! drgnx ships, unpacked safely and moved into place whole.
//!
//! Chrome for Testing publishes download URLs and no digests, so drgnx carries its own table (`pins.json`: a version,
//! its release date and a sha256 per platform) and installs only a version in it.  The table is refreshed with each
//! drgnx release.  Nothing runs this but the command: no hub path, no timer, no prompt.
//!
//! The install is atomic: everything happens in `<data>/browsers/V.partial/`, which is replaced when it is found, and a
//! failure of any kind removes it.  `V/` appears only by a rename of a complete `V.partial/` that holds
//! `installed.json`.

use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use bifrost::upstream::{Upstream, UpstreamOpts};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::resolve::{InstalledFile, browsers_dir, version_key};

/// The shipped table.
const PINS: &str = include_str!("pins.json");

/// The headless shell's file inside the archive's one folder.
const BINARY: &str = "chrome-headless-shell";

/// How long the server may stay silent mid-download.
const STALL: Duration = Duration::from_secs(60);

/// One pinned version.
#[derive(Clone, Debug, Deserialize)]
pub struct Pin {
    pub version: String,
    /// The day it was released (`YYYY-MM-DD`): the doctor's age warning counts from here.
    pub released: String,
    pub platforms: BTreeMap<String, PlatformPin>,
}

/// One platform's download.  A null digest means the platform is not pinned yet: it cannot be installed.
#[derive(Clone, Debug, Deserialize)]
pub struct PlatformPin {
    pub url: String,
    pub sha256: Option<String>,
}

/// The shipped pins (test builds: `DRGNX_TEST_PINS` names a file that replaces them).
pub fn pins() -> Vec<Pin> {
    #[cfg(feature = "test-hooks")]
    if let Some(path) = std::env::var_os("DRGNX_TEST_PINS") {
        let text = fs::read_to_string(path).expect("DRGNX_TEST_PINS is readable");
        return serde_json::from_str(&text).expect("DRGNX_TEST_PINS is a pin table");
    }
    serde_json::from_str(PINS).expect("pins.json is a pin table")
}

/// This machine's key in the table, when drgnx has one for it.
pub fn platform_key() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => Some("linux64"),
        ("linux", "aarch64") => Some("linux-arm64"),
        ("macos", "aarch64") => Some("mac-arm64"),
        ("macos", "x86_64") => Some("mac-x64"),
        _ => None,
    }
}

/// What an install does not go past.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Limits {
    /// Bytes of the download.
    pub download: u64,
    /// Bytes of one unpacked file.
    pub entry: u64,
    /// Bytes of everything unpacked.
    pub unpacked: u64,
    pub entries: usize,
}

impl Default for Limits {
    fn default() -> Self {
        const MIB: u64 = 1 << 20;
        Limits {
            download: 512 * MIB,
            entry: 1024 * MIB,
            unpacked: 2048 * MIB,
            entries: 4096,
        }
    }
}

/// Where the archive comes from.
#[derive(Clone, Debug)]
pub(crate) enum Base {
    /// The pin's URL, which must be https.
    Pinned,
    /// Tests and test builds: `<dir>/<version>/<platform>/<file name of the URL>` on disk.
    #[cfg(any(test, feature = "test-hooks"))]
    Dir(PathBuf),
    /// Tests: the pin's URL with any scheme (a local server).
    #[cfg(test)]
    PlainHttp,
}

/// A finished install.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Installed {
    pub version: String,
    pub released: String,
    pub dir: PathBuf,
    pub binary: PathBuf,
    pub sha256: String,
    /// It was there already; nothing was downloaded.
    pub already: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum InstallError {
    /// V is not in the table.
    NotPinned {
        asked: String,
        pinned: Vec<String>,
    },
    /// The platform has no digest yet (or drgnx has no key for this machine).
    PlatformNotPinned(String),
    NotHttps(String),
    Network(String),
    TooLarge(String),
    DigestMismatch {
        expected: String,
        got: String,
    },
    /// An archive entry that is absolute, climbs, links, or is neither a file nor a folder.
    Unsafe(String),
    Archive(String),
    Io(String),
}

impl fmt::Display for InstallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotPinned { asked, pinned } => write!(
                f,
                "version {asked} is not one drgnx knows a digest for (pinned: {})",
                pinned.join(", ")
            ),
            Self::PlatformNotPinned(p) => write!(
                f,
                "this platform ({p}) has no pinned download yet; install a distro package or set \
`drgnx-agents-browser-program`"
            ),
            Self::NotHttps(u) => write!(f, "refusing a download that is not https: {u}"),
            Self::Network(m) => write!(f, "download failed: {m}"),
            Self::TooLarge(m) => write!(f, "too large: {m}"),
            Self::DigestMismatch { expected, got } => write!(
                f,
                "the download's sha256 is {got}, the pin says {expected}; nothing was installed"
            ),
            Self::Unsafe(m) => write!(f, "unsafe archive, nothing was installed: {m}"),
            Self::Archive(m) => write!(f, "bad archive: {m}"),
            Self::Io(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for InstallError {}

fn io_err(what: &Path, e: io::Error) -> InstallError {
    InstallError::Io(format!("{}: {e}", what.display()))
}

/// Removes a folder when dropped, unless [`Partial::keep`] was called.
struct Partial {
    dir: PathBuf,
    armed: bool,
}

impl Partial {
    fn keep(mut self) {
        self.armed = false;
    }
}

impl Drop for Partial {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
}

/// Install the newest pinned version, or VERSION when it is pinned, under DATA_DIR.  LOG gets one line before the
/// download starts.
pub async fn install(
    data_dir: &Path,
    version: Option<&str>,
    log: &dyn Fn(&str),
) -> Result<Installed, InstallError> {
    #[cfg(feature = "test-hooks")]
    let base = std::env::var_os("DRGNX_TEST_CFT_BASE")
        .and_then(|b| b.into_string().ok())
        .map_or(Base::Pinned, |b| {
            Base::Dir(PathBuf::from(b.strip_prefix("file://").unwrap_or(&b)))
        });
    #[cfg(not(feature = "test-hooks"))]
    let base = Base::Pinned;
    install_with(data_dir, &pins(), version, &base, Limits::default(), log).await
}

pub(crate) async fn install_with(
    data_dir: &Path,
    pins: &[Pin],
    version: Option<&str>,
    base: &Base,
    limits: Limits,
    log: &dyn Fn(&str),
) -> Result<Installed, InstallError> {
    let platform =
        platform_key().ok_or_else(|| InstallError::PlatformNotPinned("this one".into()))?;
    let pin = choose(pins, version)?;
    let plat = pin
        .platforms
        .get(platform)
        .ok_or_else(|| InstallError::PlatformNotPinned(platform.into()))?;
    let expected = plat
        .sha256
        .as_deref()
        .map(str::to_ascii_lowercase)
        .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or_else(|| InstallError::PlatformNotPinned(platform.into()))?;
    let root = browsers_dir(data_dir);
    let dir = root.join(&pin.version);
    let installed_json = dir.join("installed.json");
    if let Ok(text) = fs::read_to_string(&installed_json)
        && let Ok(file) = serde_json::from_str::<InstalledFile>(&text)
    {
        return Ok(Installed {
            binary: dir.join(&file.binary),
            version: file.version,
            released: file.released,
            dir,
            sha256: file.sha256,
            already: true,
        });
    }

    fs::create_dir_all(&root).map_err(|e| io_err(&root, e))?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).map_err(|e| io_err(&root, e))?;
    let partial = root.join(format!("{}.partial", pin.version));
    // a leftover of an earlier try is ours to replace (a link is removed, never followed)
    match fs::symlink_metadata(&partial) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(&partial).map_err(|e| io_err(&partial, e))?,
        Ok(_) => fs::remove_file(&partial).map_err(|e| io_err(&partial, e))?,
        Err(_) => {}
    }
    fs::create_dir(&partial).map_err(|e| io_err(&partial, e))?;
    let guard = Partial {
        dir: partial.clone(),
        armed: true,
    };

    log(&format!(
        "downloading chrome-headless-shell {} for {platform}",
        pin.version
    ));
    let zip_path = partial.join("download.zip");
    let got = download(&plat.url, &pin.version, platform, base, &zip_path, limits).await?;
    if got != expected {
        return Err(InstallError::DigestMismatch { expected, got });
    }
    unpack(&zip_path, &partial, limits)?;
    fs::remove_file(&zip_path).map_err(|e| io_err(&zip_path, e))?;

    let folder = file_stem(&plat.url);
    let binary_rel = format!("{folder}/{BINARY}");
    let binary = partial.join(&binary_rel);
    match fs::symlink_metadata(&binary) {
        Ok(m) if m.is_file() => {}
        _ => {
            return Err(InstallError::Archive(format!(
                "the archive has no {binary_rel}"
            )));
        }
    }
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755))
        .map_err(|e| io_err(&binary, e))?;
    let file = InstalledFile {
        version: pin.version.clone(),
        released: pin.released.clone(),
        sha256: expected.clone(),
        at: crate::clock::wall()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs()),
        binary: binary_rel.clone(),
    };
    let text = serde_json::to_string_pretty(&file).expect("installed.json serializes");
    let marker = partial.join("installed.json");
    // the archive may not carry the marker: only a finished install has one
    if fs::symlink_metadata(&marker).is_ok() {
        return Err(InstallError::Unsafe(
            "the archive has an installed.json".into(),
        ));
    }
    fs::write(&marker, text).map_err(|e| io_err(&marker, e))?;
    // a folder without a marker is an earlier crash's; it is not an install
    if fs::symlink_metadata(&dir).is_ok() {
        fs::remove_dir_all(&dir).map_err(|e| io_err(&dir, e))?;
    }
    fs::rename(&partial, &dir).map_err(|e| io_err(&dir, e))?;
    guard.keep();
    Ok(Installed {
        binary: dir.join(binary_rel),
        version: pin.version.clone(),
        released: pin.released.clone(),
        dir,
        sha256: expected,
        already: false,
    })
}

/// The pin to install: the newest, or the one named VERSION.
fn choose<'a>(pins: &'a [Pin], version: Option<&str>) -> Result<&'a Pin, InstallError> {
    let pinned = || pins.iter().map(|p| p.version.clone()).collect::<Vec<_>>();
    match version {
        Some(v) => pins
            .iter()
            .find(|p| p.version == v)
            .ok_or_else(|| InstallError::NotPinned {
                asked: v.into(),
                pinned: pinned(),
            }),
        None => pins
            .iter()
            .filter_map(|p| Some((version_key(&p.version)?, p)))
            .max_by(|a, b| a.0.cmp(&b.0))
            .map(|(_, p)| p)
            .ok_or_else(|| InstallError::NotPinned {
                asked: "newest".into(),
                pinned: pinned(),
            }),
    }
}

/// The last segment of URL without `.zip`: the archive's one top folder.
fn file_stem(url: &str) -> String {
    let name = url.rsplit('/').next().unwrap_or(url);
    name.strip_suffix(".zip").unwrap_or(name).to_string()
}

/// Writes the archive to PATH and hashes it as it comes; the sha256 as lower-case hex.
struct Sink {
    file: File,
    hasher: Sha256,
    written: u64,
    max: u64,
}

impl Sink {
    fn push(&mut self, chunk: &[u8]) -> Result<(), InstallError> {
        self.written += chunk.len() as u64;
        if self.written > self.max {
            return Err(InstallError::TooLarge(format!(
                "the download passed {} bytes",
                self.max
            )));
        }
        self.hasher.update(chunk);
        self.file
            .write_all(chunk)
            .map_err(|e| InstallError::Io(format!("writing the download: {e}")))
    }

    fn finish(self) -> String {
        self.hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
}

async fn download(
    url: &str,
    version: &str,
    platform: &str,
    base: &Base,
    to: &Path,
    limits: Limits,
) -> Result<String, InstallError> {
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(to)
        .map_err(|e| io_err(to, e))?;
    let mut sink = Sink {
        file,
        hasher: Sha256::new(),
        written: 0,
        max: limits.download,
    };
    let _ = (version, platform);
    #[cfg(any(test, feature = "test-hooks"))]
    if let Base::Dir(dir) = base {
        let path = dir
            .join(version)
            .join(platform)
            .join(url.rsplit('/').next().unwrap_or(url));
        let mut src = File::open(&path).map_err(|e| io_err(&path, e))?;
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = src.read(&mut buf).map_err(|e| io_err(&path, e))?;
            if n == 0 {
                break;
            }
            sink.push(&buf[..n])?;
        }
    } else {
        over_http(url, plain(base), &mut sink, limits).await?;
    }
    #[cfg(not(any(test, feature = "test-hooks")))]
    over_http(url, plain(base), &mut sink, limits).await?;
    sink.file
        .sync_all()
        .map_err(|e| InstallError::Io(format!("writing the download: {e}")))?;
    Ok(sink.finish())
}

/// Whether BASE lets the download use any scheme (a test's local server).
fn plain(base: &Base) -> bool {
    #[cfg(test)]
    {
        matches!(base, Base::PlainHttp)
    }
    #[cfg(not(test))]
    {
        let _ = base;
        false
    }
}

/// URL's body into SINK, over https (or http when PLAIN), through the same client the gateway uses (so the proxy
/// variables and the platform's certificate store apply).
async fn over_http(
    url: &str,
    plain: bool,
    sink: &mut Sink,
    limits: Limits,
) -> Result<(), InstallError> {
    if !url.starts_with("https://") && !plain {
        return Err(InstallError::NotHttps(url.into()));
    }
    let uri: bifrost::Uri = url
        .parse()
        .map_err(|_| InstallError::Network(format!("not a URL: {url}")))?;
    let up = Upstream::new(UpstreamOpts::default())
        .map_err(|e| InstallError::Network(format!("{e:?}")))?;
    let req = http::Request::get(uri)
        .header("user-agent", "drgnx-browser-install")
        .body(Full::new(Bytes::new()))
        .map_err(|e| InstallError::Network(e.to_string()))?;
    let resp = up
        .send(req)
        .await
        .map_err(|e| InstallError::Network(format!("{e:?}")))?;
    if resp.status() != http::StatusCode::OK {
        return Err(InstallError::Network(format!(
            "the server said {}",
            resp.status()
        )));
    }
    if let Some(len) = resp
        .headers()
        .get(http::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        && len > limits.download
    {
        return Err(InstallError::TooLarge(format!(
            "the server announces {len} bytes"
        )));
    }
    let mut body = resp.into_body();
    loop {
        let frame = crate::clock::timeout(STALL, body.frame())
            .await
            .map_err(|_| InstallError::Network("the server stopped sending".into()))?;
        match frame {
            None => return Ok(()),
            Some(Err(e)) => return Err(InstallError::Network(e.to_string())),
            Some(Ok(f)) => {
                if let Ok(data) = f.into_data() {
                    sink.push(&data)?;
                }
            }
        }
    }
}

/// ZIP into DEST.  Only regular files and folders are made; an entry that is absolute, climbs out, links, or repeats a
/// name fails the whole unpack.  Files are created new (never over anything), and sizes are counted as they are
/// written, not as the archive declares them.
fn unpack(zip: &Path, dest: &Path, limits: Limits) -> Result<(), InstallError> {
    let file = File::open(zip).map_err(|e| io_err(zip, e))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| InstallError::Archive(e.to_string()))?;
    if archive.len() > limits.entries {
        return Err(InstallError::TooLarge(format!(
            "the archive has {} entries",
            archive.len()
        )));
    }
    let mut seen = HashSet::new();
    let mut total = 0u64;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| InstallError::Archive(e.to_string()))?;
        let raw = String::from_utf8_lossy(entry.name_raw()).into_owned();
        let unsafe_name = || InstallError::Unsafe(format!("entry {raw:?}"));
        // judged on the name as written: the library may normalise an absolute name into a relative one
        if raw.starts_with('/') || raw.split('/').any(|c| c == "..") {
            return Err(unsafe_name());
        }
        let name = entry.enclosed_name().ok_or_else(unsafe_name)?;
        if name.as_os_str().is_empty()
            || name
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
        {
            return Err(unsafe_name());
        }
        let mode = entry.unix_mode().unwrap_or(0);
        match mode & 0o170000 {
            0 | 0o100000 | 0o040000 => {}
            0o120000 => return Err(InstallError::Unsafe(format!("entry {raw:?} is a link"))),
            _ => {
                return Err(InstallError::Unsafe(format!(
                    "entry {raw:?} is not a file or a folder"
                )));
            }
        }
        let target = dest.join(&name);
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|e| io_err(&target, e))?;
            continue;
        }
        if !seen.insert(name.clone()) {
            return Err(InstallError::Unsafe(format!("entry {raw:?} appears twice")));
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
        }
        let perm = if mode & 0o111 != 0 { 0o755 } else { 0o644 };
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(perm)
            .open(&target)
            .map_err(|e| io_err(&target, e))?;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A zip of the entries (name, bytes, unix mode).
    fn zip_of(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
        let mut w = zip::ZipWriter::new(io::Cursor::new(Vec::new()));
        for (name, bytes, mode) in entries {
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored)
                .unix_permissions(*mode);
            if *mode == 0o120777 {
                w.add_symlink(*name, std::str::from_utf8(bytes).unwrap(), opts)
                    .unwrap();
                continue;
            }
            w.start_file(*name, opts).unwrap();
            w.write_all(bytes).unwrap();
        }
        w.finish().unwrap().into_inner()
    }

    fn sha(bytes: &[u8]) -> String {
        Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    const V: &str = "100.0.0.1";

    /// A fixture folder holding ZIP for version V, and the pin table that names its digest (DIGEST).
    fn fixture(root: &Path, zip: &[u8], digest: &str) -> (Base, Vec<Pin>) {
        let platform = platform_key().unwrap();
        let dir = root.join("cft").join(V).join(platform);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("chrome-headless-shell-x.zip"), zip).unwrap();
        let pin: Pin = serde_json::from_value(serde_json::json!({
            "version": V, "released": "2026-01-02",
            "platforms": { platform: {
                "url": "https://example.invalid/chrome-headless-shell-x.zip", "sha256": digest } }
        }))
        .unwrap();
        (Base::Dir(root.join("cft")), vec![pin])
    }

    fn good_zip() -> Vec<u8> {
        zip_of(&[
            (
                "chrome-headless-shell-x/chrome-headless-shell",
                b"#!/bin/sh\necho hi\n",
                0o644,
            ),
            ("chrome-headless-shell-x/lib/data.bin", b"data", 0o644),
        ])
    }

    async fn run(
        root: &Path,
        pins: &[Pin],
        base: &Base,
        version: Option<&str>,
    ) -> Result<Installed, InstallError> {
        install_with(
            &root.join("data"),
            pins,
            version,
            base,
            Limits::default(),
            &|_| {},
        )
        .await
    }

    fn leftovers(root: &Path) -> Vec<String> {
        fs::read_dir(browsers_dir(&root.join("data")))
            .map(|r| {
                r.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn the_shipped_table_is_sound() {
        let pins = pins();
        assert!(!pins.is_empty());
        for p in &pins {
            assert!(version_key(&p.version).is_some(), "{}", p.version);
            assert_eq!(p.released.len(), 10);
            for (name, plat) in &p.platforms {
                assert!(
                    plat.url
                        .starts_with("https://storage.googleapis.com/chrome-for-testing-public/")
                );
                assert!(
                    plat.url.contains(&format!("/{}/{name}/", p.version)),
                    "{name}"
                );
                if let Some(s) = &plat.sha256 {
                    assert!(
                        s.len() == 64
                            && s.bytes()
                                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                    );
                }
            }
            assert!(p.platforms["linux64"].sha256.is_some());
        }
    }

    #[tokio::test]
    async fn an_install_lands_whole() {
        let tmp = tempfile::tempdir().unwrap();
        let zip = good_zip();
        let (base, pins) = fixture(tmp.path(), &zip, &sha(&zip));
        let done = run(tmp.path(), &pins, &base, None).await.unwrap();
        assert!(!done.already);
        assert_eq!(done.version, V);
        assert_eq!(
            fs::metadata(&done.binary).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert_eq!(
            fs::read(done.dir.join("chrome-headless-shell-x/lib/data.bin")).unwrap(),
            b"data"
        );
        assert!(!done.dir.join("download.zip").exists());
        assert_eq!(leftovers(tmp.path()), [V]);
        let marker: InstalledFile =
            serde_json::from_str(&fs::read_to_string(done.dir.join("installed.json")).unwrap())
                .unwrap();
        assert_eq!(
            (marker.version.as_str(), marker.sha256.as_str()),
            (V, sha(&zip).as_str())
        );
        // again: nothing is downloaded
        let again = run(
            tmp.path(),
            &pins,
            &Base::Dir(tmp.path().join("nowhere")),
            None,
        )
        .await
        .unwrap();
        assert!(again.already);
        assert_eq!(again.binary, done.binary);
    }

    #[tokio::test]
    async fn digest_mismatch_leaves_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let (base, pins) = fixture(tmp.path(), &good_zip(), &"ab".repeat(32));
        let err = run(tmp.path(), &pins, &base, None).await.unwrap_err();
        assert!(matches!(err, InstallError::DigestMismatch { .. }), "{err}");
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new());
    }

    #[tokio::test]
    async fn zip_slip_and_symlinks_are_refused() {
        let outside = tempfile::tempdir().unwrap();
        let target = outside.path().join("evil");
        let abs = target.to_str().unwrap().to_string();
        let link_mode = 0o120777;
        let cases: Vec<(&str, Vec<u8>)> = vec![
            ("climbs", zip_of(&[("../../evil", b"x", 0o644)])),
            ("absolute", {
                // the writer strips a leading slash: write an X and turn it into one in the bytes
                let named = format!("X{}", &abs[1..]);
                let mut z = zip_of(&[(&named, b"x", 0o644)]);
                let at: Vec<usize> = (0..z.len() - named.len())
                    .filter(|i| &z[*i..*i + named.len()] == named.as_bytes())
                    .collect();
                assert_eq!(
                    at.len(),
                    2,
                    "the name is in the local header and the directory"
                );
                for i in at {
                    z[i] = b'/';
                }
                z
            }),
            (
                "symlink",
                zip_of(&[("d/ok", b"x", 0o644), ("d/link", abs.as_bytes(), link_mode)]),
            ),
            (
                "a file over a folder",
                zip_of(&[("d", b"x", 0o644), ("d/f", b"y", 0o644)]),
            ),
            ("the same name twice", {
                // the writer refuses a repeated name: make two of the same length, then rename one in the bytes
                let mut z = zip_of(&[("d/f", b"x", 0o644), ("d/g", b"y", 0o644)]);
                let at: Vec<usize> = (0..z.len() - 2)
                    .filter(|i| &z[*i..*i + 3] == b"d/g")
                    .collect();
                assert_eq!(
                    at.len(),
                    2,
                    "the name is in the local header and the directory"
                );
                for i in at {
                    z[i + 2] = b'f';
                }
                z
            }),
        ];
        for (what, zip) in cases {
            let tmp = tempfile::tempdir().unwrap();
            let (base, pins) = fixture(tmp.path(), &zip, &sha(&zip));
            let err = run(tmp.path(), &pins, &base, None).await.unwrap_err();
            assert!(
                matches!(
                    err,
                    InstallError::Unsafe(_) | InstallError::Io(_) | InstallError::Archive(_)
                ),
                "{what}: {err}"
            );
            if what != "a file over a folder" && what != "the same name twice" {
                assert!(matches!(err, InstallError::Unsafe(_)), "{what}: {err}");
            }
            assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "{what}");
            assert!(!target.exists(), "{what}: wrote outside");
        }
    }

    #[tokio::test]
    async fn an_archive_without_the_binary_or_over_the_limits_fails_clean() {
        let tmp = tempfile::tempdir().unwrap();
        let zip = zip_of(&[("chrome-headless-shell-x/other", b"x", 0o755)]);
        let (base, pins) = fixture(tmp.path(), &zip, &sha(&zip));
        let err = run(tmp.path(), &pins, &base, None).await.unwrap_err();
        assert!(matches!(err, InstallError::Archive(_)), "{err}");
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new());
        // an entry larger than the limit, however it is declared
        let zip = good_zip();
        let (base, pins) = fixture(tmp.path(), &zip, &sha(&zip));
        let small = Limits {
            entry: 8,
            ..Limits::default()
        };
        let err = install_with(&tmp.path().join("data"), &pins, None, &base, small, &|_| {})
            .await
            .unwrap_err();
        assert!(matches!(err, InstallError::TooLarge(_)), "{err}");
        let small = Limits {
            download: 10,
            ..Limits::default()
        };
        let err = install_with(&tmp.path().join("data"), &pins, None, &base, small, &|_| {})
            .await
            .unwrap_err();
        assert!(matches!(err, InstallError::TooLarge(_)), "{err}");
        let small = Limits {
            entries: 1,
            ..Limits::default()
        };
        let err = install_with(&tmp.path().join("data"), &pins, None, &base, small, &|_| {})
            .await
            .unwrap_err();
        assert!(matches!(err, InstallError::TooLarge(_)), "{err}");
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new());
    }

    #[tokio::test]
    async fn a_partial_install_is_ignored_and_replaced() {
        let tmp = tempfile::tempdir().unwrap();
        let data = tmp.path().join("data");
        // an earlier try died halfway: a partial folder with junk, and a link where a folder would go
        let partial = browsers_dir(&data).join(format!("{V}.partial"));
        fs::create_dir_all(partial.join("chrome-headless-shell-x")).unwrap();
        fs::write(
            partial.join("chrome-headless-shell-x/chrome-headless-shell"),
            "half",
        )
        .unwrap();
        fs::write(partial.join("download.zip"), "half").unwrap();
        fs::write(partial.join("junk"), "x").unwrap();
        assert_eq!(
            super::super::resolve::installed(&data).len(),
            0,
            "a partial folder is not an install"
        );
        let zip = good_zip();
        let (base, pins) = fixture(tmp.path(), &zip, &sha(&zip));
        let done = run(tmp.path(), &pins, &base, None).await.unwrap();
        assert_eq!(fs::read(&done.binary).unwrap(), b"#!/bin/sh\necho hi\n");
        assert!(!done.dir.join("junk").exists());
        assert_eq!(leftovers(tmp.path()), [V]);
        assert_eq!(super::super::resolve::installed(&data).len(), 1);
        // and a version folder with no marker (a crash between the steps) is replaced too
        fs::remove_file(done.dir.join("installed.json")).unwrap();
        fs::write(done.dir.join("junk"), "x").unwrap();
        let done = run(tmp.path(), &pins, &base, None).await.unwrap();
        assert!(!done.already && !done.dir.join("junk").exists());
    }

    #[tokio::test]
    async fn only_pinned_versions_install() {
        let tmp = tempfile::tempdir().unwrap();
        let zip = good_zip();
        let (base, mut pins) = fixture(tmp.path(), &zip, &sha(&zip));
        let err = run(tmp.path(), &pins, &base, Some("1.2.3.4"))
            .await
            .unwrap_err();
        assert!(
            matches!(&err, InstallError::NotPinned { asked, .. } if asked == "1.2.3.4"),
            "{err}"
        );
        let err = run(tmp.path(), &pins, &base, Some("../../x"))
            .await
            .unwrap_err();
        assert!(matches!(err, InstallError::NotPinned { .. }), "{err}");
        // a platform without a digest cannot be installed
        pins[0].platforms.values_mut().for_each(|p| p.sha256 = None);
        let err = run(tmp.path(), &pins, &base, None).await.unwrap_err();
        assert!(matches!(err, InstallError::PlatformNotPinned(_)), "{err}");
        // a pin whose URL is not https is refused before any request
        let (_, mut pins) = fixture(tmp.path(), &zip, &sha(&zip));
        pins[0]
            .platforms
            .values_mut()
            .for_each(|p| p.url = "http://example.invalid/a.zip".into());
        let err = run(tmp.path(), &pins, &Base::Pinned, None)
            .await
            .unwrap_err();
        assert!(matches!(err, InstallError::NotHttps(_)), "{err}");
        assert_eq!(leftovers(tmp.path()), Vec::<String>::new());
        // the newest of several wins
        let (base, mut two) = fixture(tmp.path(), &zip, &sha(&zip));
        let mut older = two[0].clone();
        older.version = "99.0.0.1".into();
        two.insert(0, older);
        assert_eq!(run(tmp.path(), &two, &base, None).await.unwrap().version, V);
    }

    /// The network path, against a local plain-HTTP server.
    #[tokio::test]
    async fn a_download_over_http_streams_and_is_checked() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let zip = good_zip();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let body = zip.clone();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let mut buf = [0u8; 2048];
                let _ = s.read(&mut buf).await;
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes()).await;
                let _ = s.write_all(&body).await;
            }
        });
        for (digest, ok) in [(sha(&zip), true), ("cd".repeat(32), false)] {
            let tmp = tempfile::tempdir().unwrap();
            let (_, mut pins) = fixture(tmp.path(), &zip, &digest);
            pins[0].platforms.values_mut().for_each(|p| {
                p.url = format!("http://127.0.0.1:{port}/chrome-headless-shell-x.zip")
            });
            let got = run(tmp.path(), &pins, &Base::PlainHttp, None).await;
            assert_eq!(got.is_ok(), ok, "{got:?}");
            assert_eq!(
                leftovers(tmp.path()),
                if ok { vec![V.to_string()] } else { vec![] }
            );
        }
    }
}
