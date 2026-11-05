//! Finding the browser an agent session gets, in the order of the design (§6.2): the `drgnx-agents-browser-program`
//! setting, a system headless shell, a system Chromium or Chrome, then the newest download of `drgnx browser install`.
//! Pure lookups on the file system: nothing is started but the setting's own program, once, for `--version`.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::settings::RuntimeValues;

/// The headless shell packages put here (Fedora's `chromium-headless`).
const SYSTEM_SHELL: &str = "/usr/lib64/chromium-browser/headless_shell";
/// The shell's name on PATH (Chrome for Testing's, and some distros').
const SHELL_ON_PATH: &str = "chrome-headless-shell";
/// Full browsers, in order.
const SYSTEM_FULL: [&str; 3] = [
    "/usr/lib64/chromium-browser/chromium-browser",
    "/usr/lib/chromium/chromium",
    "/opt/google/chrome/chrome",
];
/// How long the setting's `--version` may take.
const VERSION_TIMEOUT: Duration = Duration::from_secs(5);

/// A headless shell has no UI and needs no `--headless`; a full Chromium or Chrome does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    HeadlessShell,
    Full,
}

/// Where a found browser came from.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    /// `drgnx-agents-browser-program`.
    Setting,
    /// A distro package.
    System,
    /// `drgnx browser install`; RELEASED is the pin's release date (the doctor's age warning counts from it).
    Downloaded { released: String },
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Found {
    pub path: PathBuf,
    pub kind: Kind,
    /// Known for the setting's program (its `--version`) and for a download; not for a system package.
    pub version: Option<String>,
    pub source: Source,
}

/// No browser anywhere; FIX says what to do about it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotFound {
    pub fix: String,
}

impl std::fmt::Display for NotFound {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no browser for agent sessions: {}", self.fix)
    }
}

const FIX: &str = "install a distro package (Fedora: `dnf install chromium-headless`), set \
`drgnx-agents-browser-program`, or run `drgnx browser install`";

/// Where the system paths live: `/` for real, a fixture folder in tests.
struct Roots {
    prefix: PathBuf,
    path: Vec<PathBuf>,
}

/// The browser for a session: see the module comment.  DATA_DIR is drgnx's data folder.
pub fn resolve(values: &RuntimeValues, data_dir: &Path) -> Result<Found, NotFound> {
    let path = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    resolve_in(
        values.agents_browser_program.as_deref(),
        &Roots {
            prefix: PathBuf::from("/"),
            path,
        },
        data_dir,
    )
}

fn resolve_in(setting: Option<&str>, roots: &Roots, data_dir: &Path) -> Result<Found, NotFound> {
    if let Some(program) = setting {
        let path = PathBuf::from(program);
        // an explicit choice that cannot run is not silently replaced
        if !runnable(&path) {
            return Err(NotFound {
                fix: format!(
                    "`drgnx-agents-browser-program` names {program}, which is not an executable file"
                ),
            });
        }
        let text = version_output(&path);
        let kind = if text
            .as_deref()
            .is_some_and(|t| t.contains("HeadlessChrome"))
        {
            Kind::HeadlessShell
        } else {
            Kind::Full
        };
        return Ok(Found {
            path,
            kind,
            version: text.as_deref().and_then(version_of),
            source: Source::Setting,
        });
    }
    let system = |path: PathBuf, kind| {
        usable(roots, &path).map(|path| Found {
            path,
            kind,
            version: None,
            source: Source::System,
        })
    };
    if let Some(f) = system(roots.under(SYSTEM_SHELL), Kind::HeadlessShell) {
        return Ok(f);
    }
    for dir in &roots.path {
        if let Some(f) = system(dir.join(SHELL_ON_PATH), Kind::HeadlessShell) {
            return Ok(f);
        }
    }
    for p in SYSTEM_FULL {
        if let Some(f) = system(roots.under(p), Kind::Full) {
            return Ok(f);
        }
    }
    if let Some(f) = downloaded(data_dir) {
        return Ok(f);
    }
    Err(NotFound { fix: FIX.into() })
}

impl Roots {
    fn under(&self, absolute: &str) -> PathBuf {
        self.prefix.join(absolute.trim_start_matches('/'))
    }
}

/// A regular file with an execute bit.
fn runnable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// PATH (a candidate under ROOTS) when it runs and is not a snap: a snap's browser cannot be confined by us.
fn usable(roots: &Roots, path: &Path) -> Option<PathBuf> {
    let logical = |p: &Path| -> String {
        p.strip_prefix(&roots.prefix)
            .map(|r| format!("/{}", r.display()))
            .unwrap_or_else(|_| p.display().to_string())
    };
    if !runnable(path) || logical(path).starts_with("/snap/") {
        return None;
    }
    if let Ok(real) = std::fs::canonicalize(path) {
        let prefix = std::fs::canonicalize(&roots.prefix).unwrap_or_else(|_| roots.prefix.clone());
        let real = real
            .strip_prefix(&prefix)
            .map_or(real.clone(), |r| Path::new("/").join(r));
        if real.starts_with("/snap/") {
            return None;
        }
    }
    Some(path.to_path_buf())
}

/// The first line `PROGRAM --version` prints, or none (it did not run, or took too long).  Its environment is empty.
fn version_output(program: &Path) -> Option<String> {
    let mut child = Command::new(program)
        .arg("--version")
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    // a blocking wait on a program outside the hub: real time, which a virtual clock would never end
    let deadline = crate::clock::real_now() + VERSION_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if crate::clock::real_now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().next().map(|l| l.trim().to_string())
}

/// The version number in a `--version` line ("HeadlessChrome 157.0.8103.38", "Chromium 120.0.1 fedora").
fn version_of(line: &str) -> Option<String> {
    line.split_whitespace()
        .find(|w| w.starts_with(|c: char| c.is_ascii_digit()) && w.contains('.'))
        .map(String::from)
}

/// A version as numbers, for ordering; none for a name that is not one (a `.partial` folder, anything else).
pub(crate) fn version_key(name: &str) -> Option<Vec<u64>> {
    let parts: Option<Vec<u64>> = name.split('.').map(|p| p.parse().ok()).collect();
    parts.filter(|p| p.len() == 4)
}

/// What `installed.json` of a finished install holds.
#[derive(serde::Serialize, serde::Deserialize)]
pub(crate) struct InstalledFile {
    pub version: String,
    pub released: String,
    pub sha256: String,
    /// Seconds since the epoch.
    pub at: u64,
    /// The browser's path inside the version's folder.
    pub binary: String,
}

/// The folder of the downloads.
pub(crate) fn browsers_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("browsers")
}

/// The finished installs, newest first: a folder named by a version that holds `installed.json`.  A `.partial` folder
/// is never one of them.
pub(crate) fn installed(data_dir: &Path) -> Vec<(PathBuf, InstalledFile)> {
    let Ok(read) = std::fs::read_dir(browsers_dir(data_dir)) else {
        return Vec::new();
    };
    let mut found: Vec<(Vec<u64>, PathBuf, InstalledFile)> = read
        .flatten()
        .filter_map(|e| {
            let key = version_key(e.file_name().to_str()?)?;
            let dir = e.path();
            let text = std::fs::read_to_string(dir.join("installed.json")).ok()?;
            let file: InstalledFile = serde_json::from_str(&text).ok()?;
            Some((key, dir, file))
        })
        .collect();
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, d, f)| (d, f)).collect()
}

fn downloaded(data_dir: &Path) -> Option<Found> {
    installed(data_dir).into_iter().find_map(|(dir, file)| {
        let path = dir.join(&file.binary);
        // `binary` comes from our own file, but a path that leaves the folder is not ours
        if file.binary.split('/').any(|c| c == ".." || c.is_empty()) || !runnable(&path) {
            return None;
        }
        Some(Found {
            path,
            kind: Kind::HeadlessShell,
            version: Some(file.version),
            source: Source::Downloaded {
                released: file.released,
            },
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn script(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn roots(root: &Path) -> Roots {
        Roots {
            prefix: root.to_path_buf(),
            path: vec![root.join("bin")],
        }
    }

    fn install(data: &Path, version: &str, released: &str) {
        let dir = browsers_dir(data).join(version);
        script(&dir.join("shell/chrome-headless-shell"), "echo x");
        let file = InstalledFile {
            version: version.into(),
            released: released.into(),
            sha256: "0".repeat(64),
            at: 1,
            binary: "shell/chrome-headless-shell".into(),
        };
        std::fs::write(
            dir.join("installed.json"),
            serde_json::to_string(&file).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn order_table() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, data) = (tmp.path().join("root"), tmp.path().join("data"));
        std::fs::create_dir_all(&root).unwrap();
        let r = roots(&root);
        // nothing anywhere
        let nf = resolve_in(None, &r, &data).unwrap_err();
        assert!(nf.fix.contains("drgnx browser install"), "{}", nf.fix);
        assert!(nf.fix.contains("dnf install chromium-headless"));
        // 4: a download (the newest, by number: 157.0.9 < 157.0.10 as text would say otherwise)
        install(&data, "157.0.9.1", "2026-10-01");
        install(&data, "157.0.10.1", "2026-11-03");
        std::fs::create_dir_all(browsers_dir(&data).join("999.0.0.1.partial")).unwrap();
        let f = resolve_in(None, &r, &data).unwrap();
        assert_eq!(f.version.as_deref(), Some("157.0.10.1"));
        assert_eq!(f.kind, Kind::HeadlessShell);
        assert_eq!(
            f.source,
            Source::Downloaded {
                released: "2026-11-03".into()
            }
        );
        // 3: a system Chromium wins over the download
        script(&root.join("usr/lib/chromium/chromium"), "echo c");
        let f = resolve_in(None, &r, &data).unwrap();
        assert_eq!((f.kind, f.source.clone()), (Kind::Full, Source::System));
        assert!(f.path.ends_with("usr/lib/chromium/chromium"));
        script(&root.join("opt/google/chrome/chrome"), "echo c");
        assert!(
            resolve_in(None, &r, &data)
                .unwrap()
                .path
                .ends_with("usr/lib/chromium/chromium")
        );
        // 2: a headless shell on PATH, then the packaged one, win over a Chromium
        script(&root.join("bin/chrome-headless-shell"), "echo s");
        let f = resolve_in(None, &r, &data).unwrap();
        assert_eq!(f.kind, Kind::HeadlessShell);
        assert!(f.path.ends_with("bin/chrome-headless-shell"));
        script(
            &root.join("usr/lib64/chromium-browser/headless_shell"),
            "echo s",
        );
        assert!(
            resolve_in(None, &r, &data)
                .unwrap()
                .path
                .ends_with("headless_shell")
        );
        // 1: the setting wins over all of them, and its kind and version come from `--version`
        let mine = root.join("mine/browser");
        script(&mine, "echo 'HeadlessChrome 12.0.1.2'");
        let f = resolve_in(mine.to_str(), &r, &data).unwrap();
        assert_eq!(f.source, Source::Setting);
        assert_eq!(f.kind, Kind::HeadlessShell);
        assert_eq!(f.version.as_deref(), Some("12.0.1.2"));
        let full = root.join("mine/full");
        script(&full, "echo 'Chromium 120.0.6099.1 fedora'");
        let f = resolve_in(full.to_str(), &r, &data).unwrap();
        assert_eq!(
            (f.kind, f.version.as_deref()),
            (Kind::Full, Some("120.0.6099.1"))
        );
        // a setting that cannot run is an error, not a silent fallback
        let nf = resolve_in(Some("/no/such/browser"), &r, &data).unwrap_err();
        assert!(
            nf.fix.contains("drgnx-agents-browser-program"),
            "{}",
            nf.fix
        );
    }

    #[test]
    fn a_snap_is_skipped() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, data) = (tmp.path().join("root"), tmp.path().join("data"));
        // a PATH entry that is a link into /snap, and a package path that is itself under /snap
        script(
            &root.join("snap/chromium/current/chrome-headless-shell"),
            "echo s",
        );
        std::fs::create_dir_all(root.join("bin")).unwrap();
        symlink(
            root.join("snap/chromium/current/chrome-headless-shell"),
            root.join("bin/chrome-headless-shell"),
        )
        .unwrap();
        let r = Roots {
            prefix: root.clone(),
            path: vec![root.join("bin"), root.join("snap/chromium/current")],
        };
        assert!(resolve_in(None, &r, &data).is_err());
        // a plain one after it is found
        script(&root.join("usr/bin2/chrome-headless-shell"), "echo s");
        let r = Roots {
            path: vec![root.join("bin"), root.join("usr/bin2")],
            ..r
        };
        assert!(
            resolve_in(None, &r, &data)
                .unwrap()
                .path
                .ends_with("usr/bin2/chrome-headless-shell")
        );
    }

    #[test]
    fn a_download_without_its_file_or_with_a_bad_path_is_skipped() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, data) = (tmp.path().join("root"), tmp.path().join("data"));
        std::fs::create_dir_all(&root).unwrap();
        let dir = browsers_dir(&data).join("1.0.0.1");
        std::fs::create_dir_all(&dir).unwrap();
        let file = InstalledFile {
            version: "1.0.0.1".into(),
            released: "x".into(),
            sha256: String::new(),
            at: 0,
            binary: "../../escape".into(),
        };
        std::fs::write(
            dir.join("installed.json"),
            serde_json::to_string(&file).unwrap(),
        )
        .unwrap();
        assert!(resolve_in(None, &roots(&root), &data).is_err());
    }

    #[test]
    fn version_lines() {
        assert_eq!(
            version_of("Google Chrome 157.0.8103.38 ").as_deref(),
            Some("157.0.8103.38")
        );
        assert_eq!(version_of("no number"), None);
        assert_eq!(version_key("157.0.8103.38"), Some(vec![157, 0, 8103, 38]));
        assert_eq!(version_key("157.0.8103.38.partial"), None);
        assert_eq!(version_key("latest"), None);
    }
}
