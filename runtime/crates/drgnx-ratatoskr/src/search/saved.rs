//! The Search view's recent and saved searches, per project root: the hub's state (`<state>/hub/search/<key>.json`),
//! and the project's shared ones in `.drgnx/searches.eld`, read as data only (huginn's reader: strings, numbers,
//! symbols and lists; nothing is evaluated).

use huginn::read::{Limits, read_all};
use huginn::value::{Datum, Node};
use runstav::methods::search::{FindQuery, SavedSearch, ScopeKind, SearchScope, SearchSpec};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;
use tokio::time::Instant; // the hub clock's (`crate::clock::now`)

/// How many recent searches a project keeps.
pub const RECENT_MAX: usize = 50;
/// How long a search must stand before it is recorded: the Search view's typing delay.
pub const PAUSE: Duration = Duration::from_millis(250);
/// The project's shared searches, relative to its root.
pub const PROJECT_FILE: &str = ".drgnx/searches.eld";
/// How many projects stay in memory; past it, those with no search waiting are dropped (they are on disk).
const PROJECTS_MAX: usize = 64;

/// What the hub keeps of one project.
#[derive(Debug, Default, Clone, PartialEq, Deserialize, Serialize)]
struct Stored {
    #[serde(default)]
    recent: Vec<SearchSpec>,
    #[serde(default)]
    saved: Vec<Kept>,
}

/// One of the hub's saved searches.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
struct Kept {
    name: String,
    search: SearchSpec,
    #[serde(default)]
    pinned: bool,
}

/// One project in memory: what is stored, and each view's latest search, not yet recorded.
#[derive(Default)]
struct Project {
    stored: Stored,
    pending: HashMap<String, (SearchSpec, Instant)>,
}

impl Project {
    /// Record every waiting search that stood for [`PAUSE`] by NOW; whether the recent list changed (a search recorded
    /// again while it is the newest does not change it).
    fn commit_due(&mut self, now: Instant) -> bool {
        let due: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, (_, at))| now.saturating_duration_since(*at) >= PAUSE)
            .map(|(view, _)| view.clone())
            .collect();
        let mut due: Vec<(SearchSpec, Instant)> = due
            .iter()
            .filter_map(|view| self.pending.remove(view))
            .collect();
        if due.is_empty() {
            return false;
        }
        due.sort_by_key(|(_, at)| *at);
        let before = self.stored.recent.clone();
        for (spec, _) in &due {
            self.stored.recent.retain(|s| s != spec);
            self.stored.recent.insert(0, spec.clone());
        }
        self.stored.recent.truncate(RECENT_MAX);
        self.stored.recent != before
    }
}

/// Why sharing a saved search did not write.
#[derive(Debug, PartialEq)]
pub enum ShareError {
    /// No saved search of that name.
    NoSuch,
    /// The project's file holds something the reader refused; the user fixes it first.
    Refused(String),
    Io(String),
}

impl std::fmt::Display for ShareError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            ShareError::NoSuch => f.write_str("no saved search of that name"),
            ShareError::Refused(why) => write!(f, "{PROJECT_FILE} was not read: {why}"),
            ShareError::Io(e) => f.write_str(e),
        }
    }
}

/// The recent and saved searches of every project the hub was asked about, kept under DIR.
pub struct Saved {
    dir: PathBuf,
    projects: Mutex<HashMap<PathBuf, Project>>,
    /// Held by a flush while it writes.
    flushing: Mutex<()>,
}

impl Saved {
    /// Searches stored under DIR (`<state>/hub/search`).
    pub fn new(dir: PathBuf) -> Saved {
        Saved {
            dir,
            projects: Mutex::default(),
            flushing: Mutex::default(),
        }
    }

    /// ROOT's file under the hub's folder: a digest of the root's path names it.
    fn file(&self, root: &Path) -> PathBuf {
        let digest = Sha256::digest(root.as_os_str().as_bytes());
        let key: String = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
        self.dir.join(format!("{key}.json"))
    }

    /// F on ROOT's project, read from disk the first time; what it stored is written back when F says it changed.
    fn with<R>(
        &self,
        root: &Path,
        f: impl FnOnce(&mut Project) -> (R, bool),
    ) -> std::io::Result<R> {
        let (r, body) = self.with_body(root, f)?;
        if let Some(body) = body {
            self.write(root, &body)?;
        }
        Ok(r)
    }

    /// ROOT's stored searches written as BODY.
    fn write(&self, root: &Path, body: &[u8]) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        write_atomic(&self.file(root), body, 0o600)
    }

    /// F on ROOT's project, read from disk the first time, and what it stored as the file's body when F says it changed
    /// (not written).
    fn with_body<R>(
        &self,
        root: &Path,
        f: impl FnOnce(&mut Project) -> (R, bool),
    ) -> std::io::Result<(R, Option<Vec<u8>>)> {
        let mut map = self.projects.lock().unwrap_or_else(|e| e.into_inner());
        if !map.contains_key(root) {
            if map.len() >= PROJECTS_MAX {
                map.retain(|_, p| !p.pending.is_empty());
            }
            let stored = std::fs::read(self.file(root))
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
                .unwrap_or_default();
            map.insert(
                root.to_path_buf(),
                Project {
                    stored,
                    pending: HashMap::new(),
                },
            );
        }
        let p = map.get_mut(root).expect("inserted above");
        let (r, changed) = f(p);
        let body = if changed {
            Some(serde_json::to_vec(&p.stored).map_err(std::io::Error::other)?)
        } else {
            None
        };
        Ok((r, body))
    }

    /// VIEW searched ROOT for SPEC at AT. The view's previous search is recorded if it stood for [`PAUSE`] or more;
    /// SPEC waits until it has (an empty search is never recorded). The files of File and Open are not kept. Nothing
    /// is written here (a search's path): true when the recent list changed and [`Saved::flush`] is due.
    pub fn offer(&self, root: &Path, view: &str, mut spec: SearchSpec, at: Instant) -> bool {
        if let Some(scope) = spec.scope.as_mut() {
            scope.files = None;
        }
        self.with_body(root, |p| {
            let changed = p.commit_due(at);
            p.pending.remove(view);
            if !spec.query.typed().trim().is_empty() {
                p.pending.insert(view.to_owned(), (spec, at));
            }
            ((), changed)
        })
        .is_ok_and(|(_, body)| body.is_some())
    }

    /// Write ROOT's searches as they are now. One flush at a time: a later one writes what is newer.
    pub fn flush(&self, root: &Path) -> std::io::Result<()> {
        let _one = self.flushing.lock().unwrap_or_else(|e| e.into_inner());
        let ((), body) = self.with_body(root, |_| ((), true))?;
        match body {
            Some(body) => self.write(root, &body),
            None => Ok(()),
        }
    }

    /// ROOT's recent searches at NOW, newest first.
    pub fn recent(&self, root: &Path, now: Instant) -> Vec<SearchSpec> {
        self.with(root, |p| {
            let changed = p.commit_due(now);
            (p.stored.recent.clone(), changed)
        })
        .unwrap_or_default()
    }

    /// ROOT's saved searches, the hub's then the project's, and the forms of the project's file that were refused.
    /// A hub search the user shared is listed once, as the hub's (its pin is the user's), marked shared.
    pub fn list(&self, root: &Path) -> (Vec<SavedSearch>, Vec<String>) {
        let (project, problems) = match std::fs::read(root.join(PROJECT_FILE)) {
            Ok(bytes) => read_project(&bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (Vec::new(), Vec::new()),
            Err(e) => (Vec::new(), vec![format!("{PROJECT_FILE}: {e}")]),
        };
        let mine = self
            .with(root, |p| (p.stored.saved.clone(), false))
            .unwrap_or_default();
        let mut out: Vec<SavedSearch> = mine
            .iter()
            .map(|k| SavedSearch {
                name: k.name.clone(),
                search: k.search.clone(),
                pinned: k.pinned,
                project: false,
                shared: project.iter().any(|(n, _)| *n == k.name),
            })
            .collect();
        out.extend(
            project
                .into_iter()
                .filter(|(n, _)| !mine.iter().any(|k| k.name == *n))
                .map(|(name, search)| SavedSearch {
                    name,
                    search,
                    pinned: false,
                    project: true,
                    shared: false,
                }),
        );
        (out, problems)
    }

    /// Save SEARCH as NAME in ROOT, replacing one of that name.
    pub fn put(
        &self,
        root: &Path,
        name: &str,
        mut search: SearchSpec,
        pinned: bool,
    ) -> std::io::Result<()> {
        if let Some(scope) = search.scope.as_mut() {
            scope.files = None;
        }
        self.with(root, |p| {
            let kept = Kept {
                name: name.to_owned(),
                search,
                pinned,
            };
            match p.stored.saved.iter_mut().find(|k| k.name == name) {
                Some(k) => *k = kept,
                None => p.stored.saved.push(kept),
            }
            ((), true)
        })
    }

    /// Delete ROOT's saved search NAME; false when there is none.
    pub fn delete(&self, root: &Path, name: &str) -> std::io::Result<bool> {
        self.with(root, |p| {
            let before = p.stored.saved.len();
            p.stored.saved.retain(|k| k.name != name);
            let gone = p.stored.saved.len() != before;
            (gone, gone)
        })
    }

    /// Write ROOT's saved search NAME into the project's file, atomically: a form of that name is replaced where it
    /// stands, else the form is appended; every other byte (comments, other forms) stays as it was.
    pub fn share(&self, root: &Path, name: &str) -> Result<PathBuf, ShareError> {
        let io = |e: std::io::Error| ShareError::Io(e.to_string());
        let kept = self
            .with(root, |p| {
                (
                    p.stored.saved.iter().find(|k| k.name == name).cloned(),
                    false,
                )
            })
            .map_err(io)?
            .ok_or(ShareError::NoSuch)?;
        let path = root.join(PROJECT_FILE);
        let (old, mode) = match std::fs::read(&path) {
            Ok(b) => {
                use std::os::unix::fs::PermissionsExt;
                let mode = std::fs::metadata(&path).map_err(io)?.permissions().mode() & 0o7777;
                (b, mode)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (Vec::new(), 0o644),
            Err(e) => return Err(io(e)),
        };
        let nodes =
            read_all(&old, Limits::default()).map_err(|r| ShareError::Refused(r.to_string()))?;
        let form = print_form(name, &kept.search);
        let at = nodes
            .iter()
            .find(|n| form_name(n).as_deref() == Some(name))
            .map(|n| n.span);
        let mut new = Vec::with_capacity(old.len() + form.len() + 2);
        match at {
            Some(span) => {
                new.extend_from_slice(&old[..span.start]);
                new.extend_from_slice(form.as_bytes());
                new.extend_from_slice(&old[span.end..]);
            }
            None => {
                new.extend_from_slice(&old);
                if !old.is_empty() && !old.ends_with(b"\n") {
                    new.push(b'\n');
                }
                new.extend_from_slice(form.as_bytes());
                new.push(b'\n');
            }
        }
        std::fs::create_dir_all(path.parent().expect("a file under .drgnx")).map_err(io)?;
        write_atomic(&path, &new, mode).map_err(io)?;
        Ok(path)
    }
}

/// BODY to PATH whole or not at all: a temporary file beside it with MODE, synced, then renamed over it.
fn write_atomic(path: &Path, body: &[u8], mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let tmp = path.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    let result = (|| {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&tmp)?;
        f.write_all(body)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// The `:name` of form N, when it is a list that has one.
fn form_name(n: &Node) -> Option<String> {
    let Datum::List(items) = &n.datum else {
        return None;
    };
    items.chunks(2).find_map(|kv| match kv {
        [k, v] if matches!(&k.datum, Datum::Sym(s) if s == ":name") => match &v.datum {
            Datum::Str(s) => Some(s.clone()),
            _ => None,
        },
        _ => None,
    })
}

/// The searches a project's file holds, and a message for each form refused.
pub fn read_project(text: &[u8]) -> (Vec<(String, SearchSpec)>, Vec<String>) {
    let nodes = match read_all(text, Limits::default()) {
        Ok(n) => n,
        Err(r) => return (Vec::new(), vec![format!("{PROJECT_FILE}: {r}")]),
    };
    let mut got = Vec::new();
    let mut problems = Vec::new();
    for (i, n) in nodes.iter().enumerate() {
        match parse_form(n) {
            Ok(s) => got.push(s),
            Err(why) => problems.push(format!("{PROJECT_FILE}, form {}: {why}", i + 1)),
        }
    }
    (got, problems)
}

/// A boolean: `t` or `nil`.
fn flag(key: &str, v: &Node) -> Result<bool, String> {
    match &v.datum {
        Datum::Sym(s) if s == "t" => Ok(true),
        Datum::Sym(s) if s == "nil" => Ok(false),
        _ => Err(format!("{key} takes t or nil")),
    }
}

fn string(key: &str, v: &Node) -> Result<String, String> {
    match &v.datum {
        Datum::Str(s) => Ok(s.clone()),
        _ => Err(format!("{key} takes a string")),
    }
}

/// Globs: a string or a list of strings.
fn strings(key: &str, v: &Node) -> Result<Vec<String>, String> {
    match &v.datum {
        Datum::Str(s) => Ok(vec![s.clone()]),
        Datum::List(items) => items.iter().map(|i| string(key, i)).collect(),
        _ => Err(format!("{key} takes a string or a list of strings")),
    }
}

fn symbol<'a>(key: &str, v: &'a Node) -> Result<&'a str, String> {
    match &v.datum {
        Datum::Sym(s) => Ok(s),
        _ => Err(format!("{key} takes a symbol")),
    }
}

/// One form: a plist of the keys below, as data.
fn parse_form(n: &Node) -> Result<(String, SearchSpec), String> {
    let Datum::List(items) = &n.datum else {
        return Err("not a list of keys and values".into());
    };
    if items.len() % 2 != 0 {
        return Err("a key without a value".into());
    }
    let mut seen: Vec<&str> = Vec::new();
    let (mut name, mut mode, mut query) = (None, "text".to_owned(), None);
    let (mut case, mut word, mut regexp) = (None, None, None);
    let mut spec = SearchSpec {
        query: FindQuery::Meaning {
            question: String::new(),
        },
        replace: None,
        scope: None,
        include: None,
        exclude: None,
    };
    let (mut kind, mut base, mut changed_lines) = (None, None, None);
    for kv in items.chunks(2) {
        let key = match &kv[0].datum {
            Datum::Sym(s) if s.starts_with(':') => s.as_str(),
            _ => return Err("a key is a keyword (:name, :query, …)".into()),
        };
        if seen.contains(&key) {
            return Err(format!("{key} twice"));
        }
        seen.push(key);
        let v = &kv[1];
        match key {
            ":name" => name = Some(string(key, v)?),
            ":mode" => mode = symbol(key, v)?.to_owned(),
            ":query" => query = Some(string(key, v)?),
            ":case" => case = Some(flag(key, v)?),
            ":word" => word = Some(flag(key, v)?),
            ":regexp" => regexp = Some(flag(key, v)?),
            ":replace" => spec.replace = Some(string(key, v)?),
            ":scope" => {
                kind = Some(match symbol(key, v)? {
                    "project" => ScopeKind::Project,
                    "file" => ScopeKind::File,
                    "open" => ScopeKind::Open,
                    "changed" => ScopeKind::Changed,
                    "staged" => ScopeKind::Staged,
                    "branch" => ScopeKind::Branch,
                    other => return Err(format!("no scope {other}")),
                })
            }
            ":base" => base = Some(string(key, v)?),
            ":changed-lines" => changed_lines = Some(flag(key, v)?),
            ":include" => spec.include = Some(strings(key, v)?),
            ":exclude" => spec.exclude = Some(strings(key, v)?),
            other => return Err(format!("unknown key {other}")),
        }
    }
    let name = name.ok_or("no :name")?;
    let query = query.ok_or("no :query")?;
    spec.query = match mode.as_str() {
        "text" => FindQuery::Text {
            text: query,
            case,
            word,
            regexp,
        },
        "symbol" if word.is_none() && regexp.is_none() => FindQuery::Symbol {
            name: query,
            case,
            kinds: None,
        },
        "meaning" if case.is_none() && word.is_none() && regexp.is_none() => {
            FindQuery::Meaning { question: query }
        }
        "symbol" | "meaning" => return Err(format!("a {mode} search takes no such toggle")),
        other => return Err(format!("no mode {other}")),
    };
    if kind.is_some() || base.is_some() || changed_lines.is_some() {
        spec.scope = Some(SearchScope {
            kind: kind.ok_or(":base and :changed-lines need a :scope")?,
            base,
            changed_lines,
            files: None,
        });
    }
    Ok((name, spec))
}

/// S as an Emacs Lisp string.
fn quoted(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// NAME and SPEC as the form `.drgnx/searches.eld` holds.
pub fn print_form(name: &str, spec: &SearchSpec) -> String {
    let mut out = format!("(:name {}", quoted(name));
    let flag = |out: &mut String, key: &str, v: Option<bool>| {
        if let Some(v) = v {
            out.push_str(&format!(" {key} {}", if v { "t" } else { "nil" }));
        }
    };
    match &spec.query {
        FindQuery::Text {
            text,
            case,
            word,
            regexp,
        } => {
            out.push_str(&format!(" :mode text :query {}", quoted(text)));
            flag(&mut out, ":case", *case);
            flag(&mut out, ":word", *word);
            flag(&mut out, ":regexp", *regexp);
        }
        // the kind chips are the view's filter of the moment: a saved search keeps the name and its case
        FindQuery::Symbol { name, case, .. } => {
            out.push_str(&format!(" :mode symbol :query {}", quoted(name)));
            flag(&mut out, ":case", *case);
        }
        FindQuery::Meaning { question } => {
            out.push_str(&format!(" :mode meaning :query {}", quoted(question)));
        }
    }
    if let Some(r) = &spec.replace {
        out.push_str(&format!(" :replace {}", quoted(r)));
    }
    if let Some(s) = &spec.scope {
        let kind = match s.kind {
            ScopeKind::Project => "project",
            ScopeKind::File => "file",
            ScopeKind::Open => "open",
            ScopeKind::Changed => "changed",
            ScopeKind::Staged => "staged",
            ScopeKind::Branch => "branch",
        };
        out.push_str(&format!(" :scope {kind}"));
        if let Some(b) = &s.base {
            out.push_str(&format!(" :base {}", quoted(b)));
        }
        flag(&mut out, ":changed-lines", s.changed_lines);
    }
    for (key, globs) in [(":include", &spec.include), (":exclude", &spec.exclude)] {
        if let Some(g) = globs {
            let list: Vec<String> = g.iter().map(|s| quoted(s)).collect();
            out.push_str(&format!(" {key} ({})", list.join(" ")));
        }
    }
    out.push(')');
    out
}

#[cfg(test)]
mod tests;
