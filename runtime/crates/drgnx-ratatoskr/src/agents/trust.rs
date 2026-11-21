//! The folders the user trusted (`trusted-folders.eld`, in the state dir; the editor's Trust This Folder writes it,
//! docs/guide/security.md), as the hub reads them: a chat's `git status` and its kin count as reads only inside one.
//! Git runs what the repository's own config names (`core.fsmonitor`, `diff.external`, textconv drivers, the pager),
//! so outside a trusted folder it stays an edit.
//!
//! Fail closed: a file that is missing, cannot be read, does not parse or was written by a newer drgnx trusts
//! nothing, and says why once per change of the file ([`Answer::problem`]).  Folders are compared by canonical path
//! (a symlink or `..` cannot climb into a trusted root); `/`, the home folder, the temp dirs and their ancestors are
//! never trusted, as the editor's `drgnx-trust--broad-p` has it; a root the user untrusted although a trusted one
//! holds it (`:untrusted`) is not trusted.  The file is read again when its modification time changes.

use huginn::read::{Limits, read_all};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::SystemTime;

/// The newest version of the file this hub reads (`drgnx-trust-folders-version`).
const VERSION: i64 = 2;

/// Folders anyone may write to, whatever the temp dir is (`drgnx-trust--shared-dirs`).
const SHARED: [&str; 3] = ["/tmp", "/var/tmp", "/dev/shm"];

/// The file's form: `(:version 2 :folders (…) :allowed … :denied … :untrusted (…))`.  The workspace-trust lists are
/// the editor's own; the hub needs the folders and the untrusted roots.
#[derive(Deserialize)]
struct Raw {
    #[serde(default)]
    version: Option<i64>,
    folders: Vec<String>,
    #[serde(default)]
    untrusted: Vec<String>,
    #[serde(default)]
    allowed: Option<serde_json::Value>,
    #[serde(default)]
    denied: Option<serde_json::Value>,
}

/// What the file trusts: canonical roots.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Trusted {
    folders: Vec<PathBuf>,
    untrusted: Vec<PathBuf>,
}

/// `name` as an absolute path: `~` and `~/…` from HOME; a relative or remote name is none.
fn absolute(name: &str, home: &Path) -> Option<PathBuf> {
    if name == "~" {
        Some(home.to_path_buf())
    } else if let Some(rest) = name.strip_prefix("~/") {
        Some(home.join(rest))
    } else if name.starts_with('/') {
        Some(PathBuf::from(name))
    } else {
        None
    }
}

/// Whether DIR is `/`, the home folder, a temp dir or an ancestor of one of them: never trusted as a whole.
fn broad(dir: &Path, home: &Path) -> bool {
    std::iter::once(home.to_path_buf())
        .chain(SHARED.iter().map(PathBuf::from))
        .chain(std::env::temp_dir().canonicalize().ok())
        .any(|d| d.canonicalize().unwrap_or(d).starts_with(dir))
}

impl Trusted {
    /// The file's BYTES, HOME the user's home; an error says what is wrong with the file.
    pub fn parse(bytes: &[u8], home: &Path) -> Result<Trusted, String> {
        let nodes =
            read_all(bytes, Limits::default()).map_err(|r| format!("does not read: {r:?}"))?;
        let node = match nodes.as_slice() {
            [] => return Ok(Trusted::default()),
            [one] => one,
            _ => return Err("holds more than one form".into()),
        };
        let raw: Raw = huginn::de::from_node(node).map_err(|e| format!("has a mistake: {e}"))?;
        let _ = (&raw.allowed, &raw.denied);
        if raw.version.is_some_and(|v| v > VERSION) {
            return Err("was written by a newer drgnx".into());
        }
        if raw.version.is_some_and(|v| v < 1) {
            return Err("names a version that does not exist".into());
        }
        let roots = |names: &[String]| -> Vec<PathBuf> {
            names
                .iter()
                .filter_map(|n| absolute(n, home))
                .filter_map(|p| p.canonicalize().ok())
                .collect()
        };
        let folders = roots(&raw.folders)
            .into_iter()
            .filter(|f| !broad(f, home))
            .collect();
        Ok(Trusted {
            folders,
            untrusted: roots(&raw.untrusted),
        })
    }

    /// Whether DIR (its canonical path) is inside a trusted folder and no untrusted root.
    pub fn trusts(&self, dir: &Path) -> bool {
        let Ok(dir) = dir.canonicalize() else {
            return false;
        };
        self.folders.iter().any(|f| dir.starts_with(f))
            && !self.untrusted.iter().any(|u| dir.starts_with(u))
    }
}

/// What the file said last (read when its modification time was STAMP), and whether its problem was told.
struct Cached {
    stamp: Option<SystemTime>,
    read: Result<Trusted, String>,
    told: bool,
}

static FILES: LazyLock<Mutex<HashMap<PathBuf, Cached>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The answer for one folder: whether it is trusted, and the file's problem when it is new since the last answer.
#[derive(Debug, PartialEq, Eq)]
pub struct Answer {
    pub trusted: bool,
    pub problem: Option<String>,
}

/// Whether DIR is inside a folder FILE (the editor's `trusted-folders.eld`) trusts, HOME the user's home.  A missing
/// file trusts nothing and says nothing; any other problem is in `problem` once per change of the file.
pub fn trusts(file: &Path, home: &Path, dir: &Path) -> Answer {
    let stamp = std::fs::metadata(file).and_then(|m| m.modified()).ok();
    let mut files = FILES.lock().unwrap_or_else(PoisonError::into_inner);
    let fresh = files.get(file).is_some_and(|c| c.stamp == stamp);
    if !fresh {
        let read = match std::fs::read(file) {
            Ok(bytes) => Trusted::parse(&bytes, home),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Trusted::default()),
            Err(e) => Err(format!("cannot be read: {e}")),
        };
        files.insert(
            file.to_path_buf(),
            Cached {
                stamp,
                read,
                told: false,
            },
        );
    }
    let Some(cached) = files.get_mut(file) else {
        return Answer {
            trusted: false,
            problem: None,
        };
    };
    match &cached.read {
        Ok(t) => Answer {
            trusted: t.trusts(dir),
            problem: None,
        },
        Err(why) => {
            let problem = (!cached.told).then(|| format!("{} {why}", file.display()));
            cached.told = true;
            Answer {
                trusted: false,
                problem,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The file as the editor writes it (`drgnx-trust-update`; the ERT `drgnx-trust/the-file-the-hub-reads` writes
    /// it with the editor's own writer and compares it with this one).
    const FIXTURE: &str = include_str!("../../../../../test/fixtures/trusted-folders.eld");

    fn dirs() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let home = d.path().join("home");
        let proj = home.join("proj");
        std::fs::create_dir_all(proj.join("sub")).unwrap();
        (d, home, proj)
    }

    fn file(d: &Path, text: &str) -> PathBuf {
        let f = d.join("trusted-folders.eld");
        std::fs::write(&f, text).unwrap();
        f
    }

    #[test]
    fn the_editors_file_reads() {
        let t = Trusted::parse(FIXTURE.as_bytes(), Path::new("/home/u")).unwrap();
        // the fixture's folders do not exist here, so none canonicalises: the file reads, trusting nothing
        assert_eq!(t, Trusted::default());
        // the same text with real folders
        let (d, home, proj) = dirs();
        let text = FIXTURE
            .replace("/srv/a/", &format!("{}/", proj.display()))
            .replace("/srv/b/", &format!("{}/", home.join("other").display()));
        std::fs::create_dir_all(home.join("other")).unwrap();
        let t = Trusted::parse(text.as_bytes(), &home).unwrap();
        assert!(t.trusts(&proj) && t.trusts(&proj.join("sub")) && t.trusts(&home.join("other")));
        assert!(
            !t.trusts(&home),
            "the home folder as a whole is never trusted"
        );
        drop(d);
    }

    #[test]
    fn a_folder_is_trusted_by_its_canonical_path() {
        let (d, home, proj) = dirs();
        let t = Trusted::parse(
            format!("(:version 2 :folders (\"{}/\"))", proj.display()).as_bytes(),
            &home,
        )
        .unwrap();
        assert!(t.trusts(&proj.join("sub")));
        // `..` out of the root, and a symlink that leads out of it
        assert!(!t.trusts(&proj.join("sub/../..")));
        let outside = d.path().join("outside");
        std::fs::create_dir(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, proj.join("link")).unwrap();
        assert!(!t.trusts(&proj.join("link")));
        // a folder that is not there is not trusted; a symlink into the root is
        assert!(!t.trusts(&proj.join("missing")));
        std::os::unix::fs::symlink(proj.join("sub"), d.path().join("in")).unwrap();
        assert!(t.trusts(&d.path().join("in")));
    }

    #[test]
    fn broad_roots_and_untrusted_roots_are_not_trusted() {
        let (d, home, proj) = dirs();
        let text = format!(
            "(:version 2 :folders (\"/\" \"{}/\" \"/tmp/\" \"{}/\") :untrusted (\"{}/\"))",
            home.display(),
            proj.display(),
            proj.join("sub").display()
        );
        let t = Trusted::parse(text.as_bytes(), &home).unwrap();
        assert!(t.trusts(&proj));
        assert!(!t.trusts(&proj.join("sub")), "an untrusted root");
        assert!(!t.trusts(&home));
        assert!(!t.trusts(d.path()));
        assert!(!t.trusts(Path::new("/tmp")));
        assert!(!t.trusts(Path::new("/")));
    }

    #[test]
    fn a_file_the_hub_cannot_use_trusts_nothing_and_says_so_once() {
        let (d, home, proj) = dirs();
        for (text, why) in [
            ("(:version 2 :folders", "does not read"),
            ("(:version 9 :folders (\"/x/\"))", "newer"),
            ("(:version 2 :folders \"/x/\")", "mistake"),
            ("(:version 2)", "mistake"),
            ("(:version 2 :folders ()) (:version 2)", "more than one"),
        ] {
            let f = file(d.path(), text);
            let a = trusts(&f, &home, &proj);
            assert!(!a.trusted, "{text}");
            assert!(
                a.problem.as_deref().is_some_and(|p| p.contains(why)),
                "{text}: {a:?}"
            );
            // told once for this state of the file
            assert_eq!(
                trusts(&f, &home, &proj),
                Answer {
                    trusted: false,
                    problem: None
                }
            );
        }
        // no file: nothing trusted, nothing said
        let none = d.path().join("none.eld");
        assert_eq!(
            trusts(&none, &home, &proj),
            Answer {
                trusted: false,
                problem: None
            }
        );
    }

    #[test]
    fn the_file_is_read_again_when_it_changes() {
        let (d, home, proj) = dirs();
        let f = file(d.path(), "(:version 2 :folders ())");
        assert!(!trusts(&f, &home, &proj).trusted);
        std::fs::write(
            &f,
            format!("(:version 2 :folders (\"{}/\"))", proj.display()),
        )
        .unwrap();
        // a write within the same clock tick keeps the stamp: move it on, as an editor's later write does
        let later = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(4_000_000_000);
        std::fs::File::options()
            .write(true)
            .open(&f)
            .unwrap()
            .set_modified(later)
            .unwrap();
        assert!(trusts(&f, &home, &proj).trusted);
    }
}
