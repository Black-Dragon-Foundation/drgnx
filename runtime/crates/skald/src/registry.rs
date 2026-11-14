//! The grammars the hub parses with (language packs Task 6a): the libraries the pack job built, found through the lock
//! (`:grammars`), checked against its `:lib-sha256`, loaded once and never dropped. A `Language`, a cached `Tree` or a
//! compiled `Query` may point into a library, so a loaded one stays until the process ends.
//!
//! The registry is the only way hub code gets a grammar. A grammar that is not built, does not match the lock or does
//! not load is a [`Missing`] naming the reason; the caller reads the file as text. Nothing here crashes or blocks:
//! a later call looks again, so a grammar built after the hub started is found without a restart.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use huginn::read::{Limits, read_all};
use huginn::value::{Datum, Node};
use tree_sitter::Language;

use crate::job::{LIB_EXT, file_sha256, load};

/// The lowest ABI the hub parses with (the editor's own floor: Emacs 31's pins are ABI 14).
pub const MIN_ABI: usize = 14;

/// A grammar the lock names: where its library is and the hash the lock holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub lib: PathBuf,
    pub sha256: String,
}

/// Why a grammar is not available.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Missing {
    pub name: String,
    pub reason: String,
}

impl fmt::Display for Missing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "grammar {} is not built: {}", self.name, self.reason)
    }
}

impl std::error::Error for Missing {}

#[derive(Default)]
struct State {
    entries: HashMap<String, Entry>,
    loaded: HashMap<String, Language>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

/// Before anything is installed the registry reads `DRGNX_PACK_LOCK` (a lock file) and `DRGNX_PACK_GRAMMARS` (the
/// `grammars/` folder) when both are set: how a test run points at libraries built beforehand
/// (`test/packs/hub-grammars.sh`). The hub installs its own at start and never reads these.
fn from_env() -> State {
    let (Some(lock), Some(grammars)) = (
        std::env::var_os("DRGNX_PACK_LOCK"),
        std::env::var_os("DRGNX_PACK_GRAMMARS"),
    ) else {
        return State::default();
    };
    let entries = std::fs::read(&lock)
        .ok()
        .and_then(|b| from_lock(&b, Path::new(&grammars)).ok())
        .unwrap_or_default();
    State {
        entries: entries.into_iter().map(|e| (e.name.clone(), e)).collect(),
        loaded: HashMap::new(),
    }
}

fn with<T>(f: impl FnOnce(&mut State) -> T) -> T {
    let mut g = STATE.lock().unwrap_or_else(PoisonError::into_inner);
    f(g.get_or_insert_with(from_env))
}

fn text(n: &Node) -> Option<&str> {
    match &n.datum {
        Datum::Sym(s) | Datum::Str(s) => Some(s),
        _ => None,
    }
}

fn items(n: &Node) -> Option<&[Node]> {
    match &n.datum {
        Datum::List(v) => Some(v),
        Datum::Sym(s) if s == "nil" => Some(&[]),
        _ => None,
    }
}

fn plist_get<'a>(items: &'a [Node], key: &str) -> Option<&'a Node> {
    items
        .chunks(2)
        .find(|c| c.len() == 2 && matches!(&c[0].datum, Datum::Sym(s) if s == key))
        .map(|c| &c[1])
}

/// The grammars of the lock LOCK (its `:grammars` list, `((NAME :commit C :lib-sha256 S …)…)`), with the libraries
/// in GRAMMARS (`<data>/grammars/NAME/COMMIT/libtree-sitter-NAME.so`). A lock with no such list names none.
pub fn from_lock(lock: &[u8], grammars: &Path) -> Result<Vec<Entry>, String> {
    let limits = Limits {
        max_bytes: 8 << 20,
        ..Limits::default()
    };
    let forms = read_all(lock, limits).map_err(|e| e.to_string())?;
    let root = forms.first().and_then(items).ok_or("it holds no plist")?;
    let Some(list) = plist_get(root, ":grammars").and_then(items) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for e in list {
        let parts = items(e).ok_or("a grammar entry is not a list")?;
        let name = parts
            .first()
            .and_then(text)
            .ok_or("a grammar entry has no name")?
            .to_owned();
        let rest = &parts[1..];
        let (Some(commit), Some(sha)) = (
            plist_get(rest, ":commit").and_then(text),
            plist_get(rest, ":lib-sha256").and_then(text),
        ) else {
            continue;
        };
        out.push(Entry {
            lib: grammars
                .join(&name)
                .join(commit)
                .join(format!("libtree-sitter-{name}.{LIB_EXT}")),
            name,
            sha256: sha.to_owned(),
        });
    }
    Ok(out)
}

/// A pack `active.eld` names: its manifest file and the folders of its grammars that are built.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivePack {
    pub name: String,
    pub manifest: PathBuf,
    /// `(LANG, DIR)`: the folder `<data>/grammars/LANG/COMMIT/` holding the library.
    pub grammars: Vec<(String, PathBuf)>,
}

/// The packs of an `active.eld` (`(:version 1 :packs ((NAME :manifest FILE :grammars ((LANG . DIR)…) …)…))`), in its order.
/// An entry that does not read is skipped; a file that is not a plist is an error.
pub fn active_from(active: &[u8]) -> Result<Vec<ActivePack>, String> {
    let limits = Limits {
        max_bytes: 8 << 20,
        ..Limits::default()
    };
    let forms = read_all(active, limits).map_err(|e| e.to_string())?;
    let root = forms.first().and_then(items).ok_or("it holds no plist")?;
    let Some(list) = plist_get(root, ":packs").and_then(items) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for e in list {
        let Some(parts) = items(e) else { continue };
        let (Some(name), Some(manifest)) = (
            parts.first().and_then(text),
            plist_get(&parts[1..], ":manifest").and_then(text),
        ) else {
            continue;
        };
        let mut grammars = Vec::new();
        for g in plist_get(&parts[1..], ":grammars")
            .and_then(items)
            .unwrap_or(&[])
        {
            if let Datum::Cons(head, tail) = &g.datum
                && let (Some(lang), Some(dir)) = (head.first().and_then(text), text(tail))
            {
                grammars.push((lang.to_owned(), PathBuf::from(dir)));
            }
        }
        out.push(ActivePack {
            name: name.to_owned(),
            manifest: PathBuf::from(manifest),
            grammars,
        });
    }
    Ok(out)
}

/// The packs the lock says the user removed (`:removed-packs`), which an update never installs again.
pub fn removed_from_lock(lock: &[u8]) -> Vec<String> {
    let Ok(forms) = read_all(lock, Limits::default()) else {
        return Vec::new();
    };
    forms
        .first()
        .and_then(items)
        .and_then(|root| plist_get(root, ":removed-packs"))
        .and_then(items)
        .map(|l| l.iter().filter_map(text).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// Install ENTRIES as the grammars the lock names. A grammar already loaded stays loaded (its library is never
/// dropped); one whose entry changed is loaded again beside it on the next [`language`] call.
pub fn install(entries: Vec<Entry>) {
    with(|s| {
        let new: HashMap<String, Entry> =
            entries.into_iter().map(|e| (e.name.clone(), e)).collect();
        let old = std::mem::replace(&mut s.entries, new);
        let now = &s.entries;
        s.loaded.retain(|n, _| old.get(n) == now.get(n));
    });
}

/// Install what the lock in LOCK_FILE and the libraries under GRAMMARS name. A lock that is missing names nothing.
pub fn install_from(lock_file: &Path, grammars: &Path) -> Result<usize, String> {
    let entries = match std::fs::read(lock_file) {
        Ok(b) => from_lock(&b, grammars)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(format!("{}: {e}", lock_file.display())),
    };
    let n = entries.len();
    install(entries);
    Ok(n)
}

/// The grammar NAME (`rust`, `tsx`), loaded and checked on its first use. Never panics.
pub fn language(name: &str) -> Result<Language, Missing> {
    let missing = |reason: String| Missing {
        name: name.into(),
        reason,
    };
    enum Found {
        Loaded(Language),
        Entry(Entry),
        Unknown,
    }
    let entry = match with(|s| match (s.loaded.get(name), s.entries.get(name)) {
        (Some(l), _) => Found::Loaded(l.clone()),
        (None, Some(e)) => Found::Entry(e.clone()),
        (None, None) => Found::Unknown,
    }) {
        Found::Loaded(language) => return Ok(language),
        Found::Entry(e) => e,
        Found::Unknown => return Err(missing("the lock does not name it".into())),
    };
    if !entry.lib.is_file() {
        return Err(missing(format!("{} does not exist", entry.lib.display())));
    }
    let got = file_sha256(&entry.lib).map_err(|e| missing(e.to_string()))?;
    if got != entry.sha256 {
        return Err(missing(format!(
            "the library's hash is {got}, the lock's is {}",
            entry.sha256
        )));
    }
    let (library, language) = load(&entry.lib, &entry.name).map_err(|e| missing(e.to_string()))?;
    if language.abi_version() < MIN_ABI {
        return Err(missing(format!(
            "its ABI is {}, the lowest is {MIN_ABI}",
            language.abi_version()
        )));
    }
    // a Language, a Tree or a Query may point into the library: it stays until the process ends
    std::mem::forget(library);
    with(|s| s.loaded.insert(name.into(), language.clone()));
    Ok(language)
}

/// Every grammar the lock names and whether it is available: for the doctor.
pub fn status() -> Vec<(String, Result<(), Missing>)> {
    let mut names: Vec<String> = with(|s| s.entries.keys().cloned().collect());
    names.sort();
    names
        .into_iter()
        .map(|n| {
            let r = language(&n).map(|_| ());
            (n, r)
        })
        .collect()
}
