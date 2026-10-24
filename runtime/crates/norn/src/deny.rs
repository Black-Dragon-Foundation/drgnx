//! The personal-notes deny-list (Task 9; storage §5.6, calls 8 and 19): everything under `HOME/org/` except
//! `HOME/org/board.org`, compared after `canonicalize`. A hard tier no opt-in lifts; a soft tier the user's per-file
//! opt-ins (`<config>/personal-notes-allow.json`) lift. The user adds files, folders and globs to the hard tier in
//! `<config>/personal-notes-deny.json` (question 5). Every door checks every path a record carries ([`paths_of`],
//! [`DenyList::check_record`]). `load` is the only constructor, and nothing sets a list's contents.
//!
//! Pure Rust over `std::fs` (no `/proc`): the same on Linux, macOS and Android.

use std::borrow::Cow;
use std::fs;
use std::io::{ErrorKind, Read};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, RwLock};

use serde_json::Value;

/// The hub's current list, replaced whole by a reload (Task 9b) and read as a snapshot (`Coord::deny`).
pub type SharedDeny = Arc<RwLock<Arc<DenyList>>>;

/// Call 19's hard tier besides `HOME/org/notes.org`: under `HOME/org/` at any depth, a file whose name (case folded)
/// starts with one of these, or a file under a directory so named. Data: an answer to question 5 changes only this.
pub const HARD_PATTERNS: &[&str] = &["notes", "journal", "diary", "personal"];

/// The user's per-file opt-ins (call 8): `{"version": 1, "paths": [...]}`, mode 0600.
pub const ALLOW_FILE: &str = "personal-notes-allow.json";

/// The user's own hard entries (question 5): `{"version": 1, "entries": [{"kind": "file"|"folder"|"glob", "path":
/// "…"}]}`, mode 0600.
pub const DENY_FILE: &str = "personal-notes-deny.json";

/// Either file larger than this is refused unread.
const MAX_FILE: u64 = 1 << 20;

/// Links followed while resolving one path (Linux's own limit).
const MAX_LINKS: u32 = 40;

/// Which tier denied a path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    /// Never lifted.
    Hard,
    /// Lifted per file by an opt-in.
    Soft,
}

/// A path's verdict.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Allowed,
    /// Exactly `HOME/org/board.org`.
    Board,
    /// A soft-tier file the user opted in.
    OptedIn,
    /// WHY never names the path, so it may be shown to an agent.
    Denied {
        why: String,
        tier: Tier,
    },
}

/// A project root's verdict (door 3, the indexers).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RootVerdict {
    Allowed,
    /// The root lies inside the denied root.
    Denied {
        why: String,
    },
    /// The root contains denied paths (e.g. `HOME` itself): the indexer skips them. A glob entry lists the names it
    /// matches now; an indexer that follows links still checks each file with [`DenyList::check`].
    Contains {
        denied: Vec<PathBuf>,
    },
}

/// Where a record came from: put-parsed's typed source, or schema 6's source strings (`"spec /path"`, a path,
/// `"commit"`, `"branch"`, `"recorded"`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    File(PathBuf),
    Spec(PathBuf),
    Commit,
    Branch,
    Recorded,
}

impl Source {
    /// Schema 6's source string; `None` for a form that is none of the known ones (a door denies it: "unknown source
    /// form", never a relative path).
    pub fn parse(s: &str) -> Option<Source> {
        match s {
            "commit" => Some(Source::Commit),
            "branch" => Some(Source::Branch),
            "recorded" => Some(Source::Recorded),
            _ => match s.strip_prefix("spec ") {
                Some(rest) if Path::new(rest).is_absolute() => {
                    Some(Source::Spec(PathBuf::from(rest)))
                }
                Some(_) => None,
                None if Path::new(s).is_absolute() => Some(Source::File(PathBuf::from(s))),
                None => None,
            },
        }
    }
}

/// The kind of a user-added hard entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Folder,
    /// `*` and `?` in the last part only; it also denies everything under a folder it matches.
    Glob,
}

/// A user-added hard entry as loaded: PATH resolved (for a glob, its folder resolved and the pattern as the last
/// part). A file or folder entry denies PATH and everything under it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserEntry {
    pub kind: EntryKind,
    pub path: PathBuf,
}

/// The deny-list as loaded; no setter.
#[derive(Debug)]
pub struct DenyList {
    org: PathBuf,
    board: PathBuf,
    notes: PathBuf,
    opt_ins: Vec<PathBuf>,
    user: Vec<UserEntry>,
    warnings: Vec<String>,
}

impl DenyList {
    /// The list for HOME, with the user's hard entries from `CONFIG_DIR/personal-notes-deny.json` and the opt-ins of
    /// `CONFIG_DIR/personal-notes-allow.json`.
    /// - Missing files mean none.
    /// - The opt-in file: unreadable, malformed or group/other-writable means none, with a warning; an entry that is
    ///   not an existing regular file under the denied root is ignored, with a warning; an entry in the hard tier is
    ///   kept (it opens nothing) with a warning.
    /// - The deny file: unreadable or malformed means the built-ins only; group/other-writable still applies its
    ///   entries; a bad entry is ignored. Each of these warns and also drops every opt-in (fail closed: what the user
    ///   meant to keep out is not known).
    pub fn load(home: &Path, config_dir: &Path) -> DenyList {
        let literal = home.join("org");
        let org = resolve(&literal).unwrap_or(literal);
        let mut list = DenyList {
            board: org.join("board.org"),
            notes: org.join("notes.org"),
            org,
            opt_ins: Vec::new(),
            user: Vec::new(),
            warnings: Vec::new(),
        };
        if list.load_user_entries(home, config_dir) {
            if config_dir.join(ALLOW_FILE).exists() {
                list.warnings.push(format!(
                    "{ALLOW_FILE}: not applied while {DENY_FILE} has problems; no file is opened"
                ));
            }
        } else {
            list.load_opt_ins(home, config_dir);
        }
        list
    }

    /// PATH's verdict, resolved first (`..`, `//`, links); the hard tier before the opt-ins. PATH is denied when its
    /// resolved form is, and also when the name it was given by is (a link in `~/org` to a file elsewhere). A relative
    /// path is denied.
    pub fn check(&self, path: &Path) -> Verdict {
        if !path.is_absolute() {
            return denied("not an absolute path", Tier::Hard);
        }
        let Some(real) = resolve(path) else {
            return denied("the path cannot be resolved", Tier::Hard);
        };
        let resolved = self.verdict(&real);
        let named = self.verdict(&lexical(path));
        if strictness(&named) > strictness(&resolved) {
            named
        } else {
            resolved
        }
    }

    /// A record's verdict: denied when any path it carries ([`paths_of`]) is, the hard tier first; otherwise
    /// `Allowed`. A door that has only a source string denies the record when [`Source::parse`] answers `None`.
    pub fn check_record(&self, source: &Source, id: &str, data: &Value) -> Verdict {
        let mut worst = Verdict::Allowed;
        for path in paths_of(source, id, data) {
            match self.check(&path) {
                v @ Verdict::Denied {
                    tier: Tier::Hard, ..
                } => return v,
                v @ Verdict::Denied { .. } if worst == Verdict::Allowed => worst = v,
                _ => {}
            }
        }
        worst
    }

    /// A project root's verdict: a root inside the denied root (or a user entry) is refused, even an opted-in file.
    pub fn check_root(&self, root: &Path) -> RootVerdict {
        match self.check(root) {
            Verdict::Denied { why, .. } => return RootVerdict::Denied { why },
            Verdict::Board | Verdict::OptedIn => {
                return RootVerdict::Denied {
                    why: "personal notes (under ~/org)".into(),
                };
            }
            Verdict::Allowed => {}
        }
        let real = resolve(root).unwrap_or_else(|| root.to_path_buf());
        let inside = |p: &Path| fold(p).starts_with(&*fold(&real));
        let mut denied = Vec::new();
        if inside(&self.org) {
            denied.push(self.org.clone());
        }
        for entry in &self.user {
            match entry.kind {
                EntryKind::File | EntryKind::Folder => {
                    if inside(&entry.path) {
                        denied.push(entry.path.clone());
                    }
                }
                EntryKind::Glob => {
                    if let (Some(dir), Some(pattern)) =
                        (entry.path.parent(), entry.path.file_name())
                        && inside(dir)
                    {
                        denied.extend(glob_matches(dir, &pattern.to_string_lossy()));
                    }
                }
            }
        }
        denied.sort();
        denied.dedup();
        if denied.is_empty() {
            RootVerdict::Allowed
        } else {
            RootVerdict::Contains { denied }
        }
    }

    /// The opt-ins kept, canonical (a kept hard-tier entry opens nothing; its warning says so).
    pub fn opt_ins(&self) -> &[PathBuf] {
        &self.opt_ins
    }

    /// The user's hard entries kept.
    pub fn user_entries(&self) -> &[UserEntry] {
        &self.user
    }

    /// What the doctor shows (ignored entries, an unsafe file).
    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }

    /// The verdict of an absolute path already resolved or normalised.
    fn verdict(&self, path: &Path) -> Verdict {
        let p = fold(path);
        if self.user_hit(&p) {
            return denied("personal notes (your deny list)", Tier::Hard);
        }
        let Ok(rel) = p.strip_prefix(&*fold(&self.org)) else {
            return Verdict::Allowed;
        };
        if *p == *fold(&self.board) {
            return Verdict::Board;
        }
        if *p == *fold(&self.notes) || rel.components().any(hard_name) {
            return denied("personal notes (always kept out)", Tier::Hard);
        }
        if self.opt_ins.iter().any(|o| *fold(o) == *p) {
            return Verdict::OptedIn;
        }
        denied("personal notes (under ~/org)", Tier::Soft)
    }

    /// Whether a user entry covers P (folded).
    fn user_hit(&self, p: &Path) -> bool {
        self.user.iter().any(|entry| {
            let e = fold(&entry.path);
            match entry.kind {
                EntryKind::File | EntryKind::Folder => p.starts_with(&*e),
                EntryKind::Glob => {
                    if let (Some(dir), Some(pattern)) = (e.parent(), e.file_name())
                        && let Ok(rel) = p.strip_prefix(dir)
                        && let Some(Component::Normal(first)) = rel.components().next()
                    {
                        wildcard(&pattern.to_string_lossy(), &first.to_string_lossy())
                    } else {
                        false
                    }
                }
            }
        })
    }

    /// Reads DENY_FILE; true when it has a problem (opt-ins are then dropped).
    fn load_user_entries(&mut self, home: &Path, config_dir: &Path) -> bool {
        let (json, loose) = match read_json(&config_dir.join(DENY_FILE)) {
            Config::Missing => return false,
            Config::Bad(why) => {
                self.warnings.push(format!(
                    "{DENY_FILE}: {why}; only the built-in list applies"
                ));
                return true;
            }
            Config::Read { json, loose } => (json, loose),
        };
        let mut trouble = false;
        if loose {
            self.warnings.push(format!(
                "{DENY_FILE} is writable by group or others; its entries still apply"
            ));
            trouble = true;
        }
        let entries = match versioned(&json, "entries") {
            Some(entries) => entries,
            None => {
                self.warnings.push(format!(
                    "{DENY_FILE}: not {{\"version\": 1, \"entries\": [...]}}; only the built-in list applies"
                ));
                return true;
            }
        };
        for value in entries {
            match user_entry(home, value) {
                Ok((entry, warning)) => {
                    if let Some(warning) = warning {
                        self.warnings.push(format!("{DENY_FILE}: {warning}"));
                        trouble = true;
                    }
                    if !self.user.contains(&entry) {
                        self.user.push(entry);
                    }
                }
                Err(why) => {
                    self.warnings.push(format!("{DENY_FILE}: {why}: ignored"));
                    trouble = true;
                }
            }
        }
        trouble
    }

    /// Reads ALLOW_FILE (after the user entries, so a hard-tier opt-in is seen as one).
    fn load_opt_ins(&mut self, home: &Path, config_dir: &Path) {
        let json = match read_json(&config_dir.join(ALLOW_FILE)) {
            Config::Missing => return,
            Config::Bad(why) => {
                self.warnings
                    .push(format!("{ALLOW_FILE}: {why}; no file is opened"));
                return;
            }
            Config::Read { loose: true, .. } => {
                self.warnings.push(format!(
                    "{ALLOW_FILE} is writable by group or others; no file is opened"
                ));
                return;
            }
            Config::Read { json, .. } => json,
        };
        let Some(paths) = versioned(&json, "paths") else {
            self.warnings.push(format!(
                "{ALLOW_FILE}: not {{\"version\": 1, \"paths\": [...]}}; no file is opened"
            ));
            return;
        };
        for value in paths {
            let Some(raw) = value.as_str() else {
                self.warnings
                    .push(format!("{ALLOW_FILE}: {value} is not a path: ignored"));
                continue;
            };
            match self.opt_in(home, raw) {
                Ok(path) => {
                    if !self.opt_ins.contains(&path) {
                        self.opt_ins.push(path);
                    }
                }
                Err(why) => self
                    .warnings
                    .push(format!("{ALLOW_FILE}: {raw}: {why}: ignored")),
            }
        }
    }

    /// One opt-in entry, canonical, or why it is ignored.
    fn opt_in(&mut self, home: &Path, raw: &str) -> Result<PathBuf, String> {
        if raw.contains(['*', '?', '[']) {
            return Err("a glob opens nothing (name one file)".into());
        }
        let path = expand(home, raw);
        if !path.is_absolute() {
            return Err("not an absolute or ~ path".into());
        }
        let real = resolve(&path).ok_or("cannot be resolved")?;
        match fs::metadata(&real) {
            Ok(meta) if meta.is_file() => {}
            Ok(_) => return Err("not a regular file (a folder opens nothing)".into()),
            Err(_) => return Err("no such file".into()),
        }
        match self.verdict(&real) {
            Verdict::Allowed => Err("outside ~/org (nothing to open)".into()),
            Verdict::Board => Err("the board is always read".into()),
            Verdict::Denied {
                tier: Tier::Hard, ..
            } => {
                self.warnings.push(format!(
                    "{ALLOW_FILE}: {raw}: in the hard tier: stays kept out"
                ));
                Ok(real)
            }
            Verdict::Denied { .. } | Verdict::OptedIn => Ok(real),
        }
    }
}

/// Every path a record carries: SOURCE's path, the path inside a path-form ID (`spec:/…`, `plan:/…`, `task:/…#n`,
/// `step:/…`, `ruling:/…`, `todo:/…`, `file:/…`), and `DATA.path`. A path-form id that is not absolute (`~/…`, a
/// relative path) is returned as it is, and `check` denies it.
pub fn paths_of(source: &Source, id: &str, data: &Value) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Source::File(path) | Source::Spec(path) = source {
        paths.push(path.clone());
    }
    for path in id_paths(id) {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    if let Some(path) = data.get("path").and_then(Value::as_str).map(PathBuf::from)
        && !paths.contains(&path)
    {
        paths.push(path);
    }
    paths
}

/// Door 2 for `graph/import`: whether an imported record (its source string, id and data) may come in. An unknown
/// source form may not.
pub fn may_import(deny: &DenyList, source: Option<&str>, id: &str, data: &Value) -> bool {
    record_passes(deny, source, id, data)
}

/// Door 5 for `graph/export`: whether a stored entity may leave the store. It is checked again at each export,
/// because the list may have grown since the entity came in (a new entry in the user's deny file).
pub fn may_export(deny: &DenyList, source: Option<&str>, id: &str, data: &Value) -> bool {
    record_passes(deny, source, id, data)
}

/// A record passes when its source parses (no source: `Recorded`) and no path it carries is denied.
fn record_passes(deny: &DenyList, source: Option<&str>, id: &str, data: &Value) -> bool {
    let source = match source {
        None => Some(Source::Recorded),
        Some(s) => Source::parse(s),
    };
    source.is_some_and(|s| !matches!(deny.check_record(&s, id, data), Verdict::Denied { .. }))
}

/// The id kinds whose id is `KIND:PATH`, and those whose id is `KIND:PATH#SUFFIX`.
const WHOLE_PATH_IDS: &[&str] = &["spec", "plan", "file"];
const SUFFIXED_PATH_IDS: &[&str] = &["task", "step", "ruling", "todo"];

/// The paths inside a path-form ID. A suffixed id gives the path before its first and before its last `#` (a file
/// name may hold a `#`); a job task (`task:JOB#N`) or a tracker task (`task:abc-1x2y3`) gives none.
fn id_paths(id: &str) -> Vec<PathBuf> {
    let Some((kind, rest)) = id.split_once(':') else {
        return Vec::new();
    };
    let suffixed = SUFFIXED_PATH_IDS.contains(&kind);
    if !(suffixed || WHOLE_PATH_IDS.contains(&kind)) {
        return Vec::new();
    }
    if !(rest.starts_with(['/', '~', '.']) || rest.contains('/')) {
        return Vec::new();
    }
    let mut paths = Vec::new();
    if suffixed {
        for cut in [rest.find('#'), rest.rfind('#')] {
            let path = PathBuf::from(&rest[..cut.unwrap_or(rest.len())]);
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    } else {
        paths.push(PathBuf::from(rest));
    }
    paths
}

fn denied(why: &str, tier: Tier) -> Verdict {
    Verdict::Denied {
        why: why.into(),
        tier,
    }
}

/// Hard over soft over the rest.
fn strictness(v: &Verdict) -> u8 {
    match v {
        Verdict::Denied {
            tier: Tier::Hard, ..
        } => 2,
        Verdict::Denied {
            tier: Tier::Soft, ..
        } => 1,
        _ => 0,
    }
}

/// Whether a part of a path under `~/org` is in call 19's hard tier (names fold case on every system).
fn hard_name(part: Component<'_>) -> bool {
    let Component::Normal(name) = part else {
        return false;
    };
    let name = name.to_string_lossy().to_lowercase();
    HARD_PATTERNS.iter().any(|p| name.starts_with(p))
}

/// macOS volumes fold case by default (`cfg(target_os = "macos")`); Linux and Android compare bytes.
#[cfg(target_os = "macos")]
fn fold(path: &Path) -> Cow<'_, Path> {
    Cow::Owned(PathBuf::from(path.to_string_lossy().to_lowercase()))
}

/// macOS volumes fold case by default (`cfg(target_os = "macos")`); Linux and Android compare bytes.
#[cfg(not(target_os = "macos"))]
fn fold(path: &Path) -> Cow<'_, Path> {
    Cow::Borrowed(path)
}

/// PATH with every link resolved (`std::fs::canonicalize`). For a path that does not exist, the nearest existing
/// parent is canonicalized and the rest appended, a dangling link followed to its target. `None` for a link loop.
fn resolve(path: &Path) -> Option<PathBuf> {
    resolve_at(path, 0)
}

fn resolve_at(path: &Path, links: u32) -> Option<PathBuf> {
    if links > MAX_LINKS {
        return None;
    }
    if let Ok(real) = fs::canonicalize(path) {
        return Some(real);
    }
    let mut cur = PathBuf::new();
    for part in path.components() {
        match part {
            Component::Prefix(_) | Component::RootDir => cur.push(part.as_os_str()),
            Component::CurDir => {}
            // CUR is canonical, or canonical plus parts that do not exist: neither ends in a link.
            Component::ParentDir => {
                cur.pop();
            }
            Component::Normal(name) => {
                let next = cur.join(name);
                cur = match fs::canonicalize(&next) {
                    Ok(real) => real,
                    Err(_) => match fs::read_link(&next) {
                        Ok(target) => resolve_at(&cur.join(target), links + 1)?,
                        Err(_) => next,
                    },
                };
            }
        }
    }
    Some(cur)
}

/// PATH with `.`, `..` and doubled slashes removed by text alone (the name a path was given by).
fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            _ => out.push(part.as_os_str()),
        }
    }
    out
}

/// `~` and `~/…` are HOME; anything else is taken as written.
fn expand(home: &Path, raw: &str) -> PathBuf {
    match raw.strip_prefix('~') {
        Some("") => home.to_path_buf(),
        Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
        _ => PathBuf::from(raw),
    }
}

/// One entry of DENY_FILE, with a warning for an entry kept as it stands (fail closed).
fn user_entry(home: &Path, value: &Value) -> Result<(UserEntry, Option<String>), String> {
    let kind = match value.get("kind").and_then(Value::as_str) {
        Some("file") => EntryKind::File,
        Some("folder") => EntryKind::Folder,
        Some("glob") => EntryKind::Glob,
        _ => return Err(format!("{value}: the kind is not file, folder or glob")),
    };
    let Some(raw) = value.get("path").and_then(Value::as_str) else {
        return Err(format!("{value}: no path"));
    };
    let path = expand(home, raw);
    if !path.is_absolute() {
        return Err(format!("{raw}: not an absolute or ~ path"));
    }
    if kind == EntryKind::Glob {
        if raw.contains(['[', ']', '{', '}']) {
            return Err(format!("{raw}: only * and ? are wildcards"));
        }
        let (Some(dir), Some(pattern)) = (path.parent(), path.file_name()) else {
            return Err(format!("{raw}: no folder and pattern"));
        };
        if dir.to_string_lossy().contains(['*', '?']) {
            return Err(format!("{raw}: wildcards only in the last part"));
        }
        let dir = resolve(dir).ok_or_else(|| format!("{raw}: the folder cannot be resolved"))?;
        let path = dir.join(pattern);
        return Ok((UserEntry { kind, path }, None));
    }
    if raw.contains(['*', '?']) {
        return Err(format!("{raw}: a wildcard outside a glob entry"));
    }
    let Some(real) = resolve(&path) else {
        let warning = format!("{raw}: cannot be resolved; kept as written");
        return Ok((UserEntry { kind, path }, Some(warning)));
    };
    let warning = match (kind, fs::metadata(&real)) {
        (EntryKind::File, Ok(meta)) if meta.is_dir() => {
            Some(format!("{raw}: a folder, listed as a file"))
        }
        (EntryKind::Folder, Ok(meta)) if !meta.is_dir() => Some(format!("{raw}: not a folder")),
        _ => None,
    };
    Ok((UserEntry { kind, path: real }, warning))
}

/// The names in DIR that PATTERN matches now (DIR itself when it cannot be read).
fn glob_matches(dir: &Path, pattern: &str) -> Vec<PathBuf> {
    let pattern = fold(Path::new(pattern)).to_string_lossy().into_owned();
    match fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(Result::ok)
            .filter(|e| wildcard(&pattern, &fold(Path::new(&e.file_name())).to_string_lossy()))
            .map(|e| dir.join(e.file_name()))
            .collect(),
        Err(e) if e.kind() == ErrorKind::NotFound => Vec::new(),
        Err(_) => vec![dir.to_path_buf()],
    }
}

/// Whether NAME matches PATTERN, where `*` is any run of characters and `?` one character.
fn wildcard(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    let (mut i, mut j) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while j < n.len() {
        if i < p.len() && (p[i] == '?' || p[i] == n[j]) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == '*' {
            star = Some((i, j));
            i += 1;
        } else if let Some((si, sj)) = star {
            i = si + 1;
            j = sj + 1;
            star = Some((si, sj + 1));
        } else {
            return false;
        }
    }
    p[i..].iter().all(|&c| c == '*')
}

/// A config file as read.
enum Config {
    Missing,
    Bad(String),
    /// LOOSE: group- or other-writable.
    Read {
        json: Value,
        loose: bool,
    },
}

fn read_json(path: &Path) -> Config {
    // Checked before opening, so a FIFO in its place never blocks the hub.
    match fs::metadata(path) {
        Err(e) if e.kind() == ErrorKind::NotFound => return Config::Missing,
        Err(e) => return Config::Bad(format!("cannot be read ({e})")),
        Ok(meta) if !meta.is_file() => return Config::Bad("not a regular file".into()),
        Ok(_) => {}
    }
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(e) => return Config::Bad(format!("cannot be read ({e})")),
    };
    let meta = match file.metadata() {
        Ok(meta) if meta.is_file() => meta,
        Ok(_) => return Config::Bad("not a regular file".into()),
        Err(e) => return Config::Bad(format!("cannot be read ({e})")),
    };
    let mut text = String::new();
    if let Err(e) = file.take(MAX_FILE + 1).read_to_string(&mut text) {
        return Config::Bad(format!("cannot be read ({e})"));
    }
    if text.len() as u64 > MAX_FILE {
        return Config::Bad("larger than 1 MiB".into());
    }
    match serde_json::from_str(&text) {
        Ok(json) => Config::Read {
            json,
            loose: loose_mode(&meta),
        },
        Err(e) => Config::Bad(format!("not JSON ({e})")),
    }
}

/// JSON's KEY array when JSON is `{"version": 1, KEY: [...]}`.
fn versioned<'a>(json: &'a Value, key: &str) -> Option<&'a Vec<Value>> {
    (json.get("version").and_then(Value::as_u64) == Some(1))
        .then(|| json.get(key).and_then(Value::as_array))
        .flatten()
}

/// Group- or other-writable (Linux, macOS and Android are all `unix`).
#[cfg(unix)]
fn loose_mode(meta: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o022 != 0
}

#[cfg(not(unix))]
fn loose_mode(_: &fs::Metadata) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use serde_json::json;

    use super::*;

    /// A temp HOME and config dir; nothing here reaches the real `~`. Files are fixtures, never read.
    struct Home {
        _dir: tempfile::TempDir,
        home: PathBuf,
        config: PathBuf,
    }

    impl Home {
        fn new() -> Home {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().canonicalize().unwrap();
            let (home, config) = (root.join("home"), root.join("config"));
            fs::create_dir_all(&home).unwrap();
            fs::create_dir_all(&config).unwrap();
            Home {
                _dir: dir,
                home,
                config,
            }
        }

        fn sub(&self, s: &str) -> String {
            s.replace("$HOME", self.home.to_str().unwrap())
        }

        fn path(&self, s: &str) -> PathBuf {
            PathBuf::from(self.sub(s))
        }

        fn file(&self, rel: &str) {
            let path = self.home.join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "fixture\n").unwrap();
        }

        fn dir(&self, rel: &str) {
            fs::create_dir_all(self.home.join(rel)).unwrap();
        }

        fn link(&self, at: &str, to: &str) {
            let path = self.home.join(at);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            symlink(self.sub(to), path).unwrap();
        }

        fn config_file(&self, name: &str, text: &str, mode: u32) {
            let path = self.config.join(name);
            fs::write(&path, self.sub(text)).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        }

        fn allow(&self, paths: &[&str]) {
            let text = json!({"version": 1, "paths": paths}).to_string();
            self.config_file(ALLOW_FILE, &text, 0o600);
        }

        fn deny(&self, entries: Value) {
            let text = json!({"version": 1, "entries": entries}).to_string();
            self.config_file(DENY_FILE, &text, 0o600);
        }

        fn load(&self) -> DenyList {
            DenyList::load(&self.home, &self.config)
        }
    }

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures")
    }

    fn strs<'a>(case: &'a Value, key: &str) -> Vec<&'a str> {
        case.get(key)
            .and_then(Value::as_array)
            .map(|a| a.iter().map(|v| v.as_str().unwrap()).collect())
            .unwrap_or_default()
    }

    fn config_of(h: &Home, case: &Value, key: &str, name: &str) {
        let Some(spec) = case.get(key) else { return };
        let mode = spec.get("mode").and_then(Value::as_str).unwrap_or("600");
        let text = match (spec.get("json"), spec.get("raw").and_then(Value::as_str)) {
            (Some(json), _) => json.to_string(),
            (None, Some(raw)) => raw.to_string(),
            (None, None) => panic!("{key} without json or raw"),
        };
        h.config_file(name, &text, u32::from_str_radix(mode, 8).unwrap());
    }

    fn verdict_name(v: &Verdict) -> (&'static str, Option<&'static str>) {
        match v {
            Verdict::Allowed => ("allowed", None),
            Verdict::Board => ("board", None),
            Verdict::OptedIn => ("opted-in", None),
            Verdict::Denied {
                tier: Tier::Hard, ..
            } => ("denied", Some("hard")),
            Verdict::Denied {
                tier: Tier::Soft, ..
            } => ("denied", Some("soft")),
        }
    }

    /// One case of the shared table; `Err` says what differed.
    fn run_case(case: &Value) -> Result<(), String> {
        let h = Home::new();
        for rel in strs(case, "dirs") {
            h.dir(rel);
        }
        for rel in strs(case, "files") {
            h.file(rel);
        }
        for pair in case
            .get("links")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            h.link(pair[0].as_str().unwrap(), pair[1].as_str().unwrap());
        }
        config_of(&h, case, "deny", DENY_FILE);
        config_of(&h, case, "allow", ALLOW_FILE);
        let list = h.load();
        let want_verdict = case["verdict"].as_str().unwrap();
        let want_tier = case.get("tier").and_then(Value::as_str);
        let mut got = Vec::new();
        if let Some(path) = case.get("check").and_then(Value::as_str) {
            let (v, t) = verdict_name(&list.check(&h.path(path)));
            if (v, t) != (want_verdict, want_tier) {
                got.push(format!("check: {v} {t:?}"));
            }
        }
        if let Some(root) = case.get("root").and_then(Value::as_str) {
            let want: Vec<PathBuf> = strs(case, "contains").iter().map(|p| h.path(p)).collect();
            match (list.check_root(&h.path(root)), want_verdict) {
                (RootVerdict::Allowed, "allowed") | (RootVerdict::Denied { .. }, "denied") => {}
                (RootVerdict::Contains { denied }, "contains") if denied == want => {}
                (other, _) => got.push(format!("root: {other:?}")),
            }
        }
        if let Some(record) = case.get("record") {
            let source = h.sub(record["source"].as_str().unwrap());
            let id = h.sub(record["id"].as_str().unwrap());
            let data: Value =
                serde_json::from_str(&h.sub(&record.get("data").unwrap_or(&json!({})).to_string()))
                    .unwrap();
            let verdict = match Source::parse(&source) {
                None => denied("unknown source form", Tier::Hard),
                Some(source) => {
                    if let Some(n) = case.get("paths").and_then(Value::as_u64) {
                        let paths = paths_of(&source, &id, &data);
                        if paths.len() as u64 != n {
                            got.push(format!("paths_of: {paths:?}"));
                        }
                    }
                    list.check_record(&source, &id, &data)
                }
            };
            let (v, t) = verdict_name(&verdict);
            if (v, t) != (want_verdict, want_tier) {
                got.push(format!("record: {v} {t:?}"));
            }
        }
        let warnings = case.get("warnings").and_then(Value::as_u64).unwrap_or(0);
        if list.warnings().len() as u64 != warnings {
            got.push(format!("warnings: {:?}", list.warnings()));
        }
        if got.is_empty() {
            Ok(())
        } else {
            Err(got.join("; "))
        }
    }

    #[test]
    fn every_case_in_the_shared_table() {
        let text = fs::read_to_string(fixtures().join("deny-cases.json")).unwrap();
        let table: Value = serde_json::from_str(&text).unwrap();
        let mut wrong = Vec::new();
        let mut ran = 0;
        for case in table["cases"].as_array().unwrap() {
            if let Some(os) = case.get("os").and_then(Value::as_str)
                && os != std::env::consts::OS
            {
                continue;
            }
            ran += 1;
            if let Err(why) = run_case(case) {
                wrong.push(format!("{}: {why}", case["name"]));
            }
        }
        assert!(ran > 40, "only {ran} cases ran");
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    }

    #[test]
    fn an_opt_in_never_lifts_the_hard_list() {
        let h = Home::new();
        for rel in [
            "org/notes.org",
            "org/Journal-2026.org",
            "org/personal/x.md",
            "org/reading.org",
        ] {
            h.file(rel);
        }
        h.deny(json!([{"kind": "file", "path": "~/org/reading.org"}]));
        let opted = [
            "$HOME/org/notes.org",
            "$HOME/org/Journal-2026.org",
            "$HOME/org/personal/x.md",
            "$HOME/org/reading.org",
        ];
        h.allow(&opted);
        let list = h.load();
        // kept, so only the order of the checks keeps them out
        assert_eq!(list.opt_ins().len(), 4, "{:?}", list.warnings());
        assert_eq!(list.warnings().len(), 4);
        for path in opted {
            assert!(
                matches!(
                    list.check(&h.path(path)),
                    Verdict::Denied {
                        tier: Tier::Hard,
                        ..
                    }
                ),
                "{path}"
            );
        }
    }

    #[test]
    fn an_opt_in_of_a_directory_is_ignored() {
        let h = Home::new();
        h.file("org/sub/x.md");
        h.allow(&["$HOME/org/sub/", "$HOME/org/sub", "~/org/sub"]);
        let list = h.load();
        assert!(list.opt_ins().is_empty());
        assert_eq!(list.warnings().len(), 3, "{:?}", list.warnings());
        assert!(
            list.warnings()
                .iter()
                .all(|w| w.contains("not a regular file"))
        );
        assert_eq!(
            list.check(&h.path("$HOME/org/sub/x.md")),
            denied("personal notes (under ~/org)", Tier::Soft)
        );
    }

    #[test]
    fn a_glob_is_ignored() {
        let h = Home::new();
        h.file("org/reading.org");
        h.allow(&[
            "$HOME/org/*.org",
            "$HOME/org/reading.or?",
            "$HOME/org/[r]eading.org",
        ]);
        let list = h.load();
        assert!(list.opt_ins().is_empty());
        assert_eq!(list.warnings().len(), 3, "{:?}", list.warnings());
        assert!(matches!(
            list.check(&h.path("$HOME/org/reading.org")),
            Verdict::Denied {
                tier: Tier::Soft,
                ..
            }
        ));
    }

    #[test]
    fn paths_of_finds_every_path() {
        let plan = PathBuf::from("/w/proj/plan.md");
        let source = Source::File(plan.clone());
        let got = paths_of(
            &source,
            "task:/w/proj/plan.md#3",
            &json!({"path": "/w/org/x.md"}),
        );
        assert_eq!(got, vec![plan.clone(), PathBuf::from("/w/org/x.md")]);
        // a plan whose entity id names another file
        let got = paths_of(&source, "spec:/w/org/notes.org", &json!({}));
        assert_eq!(got, vec![plan.clone(), PathBuf::from("/w/org/notes.org")]);
        // the spec source and the spec id
        let spec = Source::parse("spec /w/org/s.md").unwrap();
        assert_eq!(
            paths_of(&spec, "spec:/w/org/s.md", &Value::Null),
            vec![PathBuf::from("/w/org/s.md")]
        );
        // every path-form kind; a `#` in a file name gives both cuts
        for (id, want) in [
            ("plan:/w/p.md", vec!["/w/p.md"]),
            ("file:/w/a#b.md", vec!["/w/a#b.md"]),
            ("step:/w/p.md#3.1", vec!["/w/p.md"]),
            ("ruling:/w/p.md#2", vec!["/w/p.md"]),
            ("todo:/w/org/board.org#AB-1", vec!["/w/org/board.org"]),
            ("task:/w/a#b.md#4", vec!["/w/a", "/w/a#b.md"]),
            ("spec:~/org/notes.org", vec!["~/org/notes.org"]),
            ("task:JOB#4", vec![]),
            ("task:drg-1x2y3", vec![]),
            ("decision:42", vec![]),
        ] {
            let want: Vec<PathBuf> = want.into_iter().map(PathBuf::from).collect();
            assert_eq!(paths_of(&Source::Commit, id, &json!({})), want, "{id}");
        }
        // data.path that is not a string carries no path
        assert!(paths_of(&Source::Recorded, "task:x-1", &json!({"path": 3})).is_empty());
    }

    #[test]
    fn an_unknown_source_form_is_denied() {
        assert_eq!(Source::parse("commit"), Some(Source::Commit));
        assert_eq!(Source::parse("branch"), Some(Source::Branch));
        assert_eq!(Source::parse("recorded"), Some(Source::Recorded));
        assert_eq!(
            Source::parse("spec /w/s.md"),
            Some(Source::Spec("/w/s.md".into()))
        );
        assert_eq!(
            Source::parse("/w/p.md"),
            Some(Source::File("/w/p.md".into()))
        );
        for s in [
            "",
            "notes.org",
            "org/notes.org",
            "~/org/notes.org",
            "spec org/notes.org",
            "spec ",
            "Commit",
        ] {
            assert_eq!(Source::parse(s), None, "{s:?}");
        }
        // a relative path that reaches a door anyway is denied
        let h = Home::new();
        let list = h.load();
        let source = Source::File("org/notes.org".into());
        assert!(matches!(
            list.check_record(&source, "x:1", &Value::Null),
            Verdict::Denied {
                tier: Tier::Hard,
                ..
            }
        ));
    }

    #[test]
    fn user_entries_of_each_kind_are_hard() {
        let h = Home::new();
        for rel in [
            "docs/private.txt",
            "docs/vault/a/b.txt",
            "docs/k.secret",
            "docs/plain.txt",
            "org/x.md",
        ] {
            h.file(rel);
        }
        h.deny(json!([
            {"kind": "file", "path": "~/docs/private.txt"},
            {"kind": "folder", "path": "$HOME/docs/vault"},
            {"kind": "glob", "path": "~/docs/*.secret"},
        ]));
        let list = h.load();
        assert!(list.warnings().is_empty(), "{:?}", list.warnings());
        assert_eq!(list.user_entries().len(), 3);
        for path in [
            "$HOME/docs/private.txt",
            "$HOME/docs/vault/a/b.txt",
            "$HOME/docs/k.secret",
            "$HOME/docs/new.secret",
        ] {
            assert!(
                matches!(
                    list.check(&h.path(path)),
                    Verdict::Denied {
                        tier: Tier::Hard,
                        ..
                    }
                ),
                "{path}"
            );
        }
        assert_eq!(
            list.check(&h.path("$HOME/docs/plain.txt")),
            Verdict::Allowed
        );
        assert!(matches!(
            list.check(&h.path("$HOME/org/x.md")),
            Verdict::Denied {
                tier: Tier::Soft,
                ..
            }
        ));
    }

    #[test]
    fn a_broken_deny_file_keeps_the_built_ins_and_opens_nothing() {
        let h = Home::new();
        h.file("org/notes.org");
        h.file("org/reading.org");
        h.allow(&["$HOME/org/reading.org"]);
        for text in [
            "{not json",
            r#"{"version": 2, "entries": []}"#,
            r#"{"version": 1, "entries": [{"kind": "allow", "path": "~/org/notes.org"}]}"#,
        ] {
            h.config_file(DENY_FILE, text, 0o600);
            let list = h.load();
            assert!(list.opt_ins().is_empty(), "{text}");
            assert_eq!(list.warnings().len(), 2, "{text}: {:?}", list.warnings());
            assert!(matches!(
                list.check(&h.path("$HOME/org/notes.org")),
                Verdict::Denied {
                    tier: Tier::Hard,
                    ..
                }
            ));
            assert!(matches!(
                list.check(&h.path("$HOME/org/reading.org")),
                Verdict::Denied {
                    tier: Tier::Soft,
                    ..
                }
            ));
        }
    }

    #[test]
    fn wildcards_match_one_name() {
        for (pattern, name, want) in [
            ("*.secret", "a.secret", true),
            ("*.secret", ".secret", true),
            ("*.secret", "a.secret.bak", false),
            ("diary-??", "diary-01", true),
            ("diary-??", "diary-1", false),
            ("*a*b*", "xxaybz", true),
            ("*a*b*", "xxbya", false),
            ("plain", "plain", true),
            ("plain", "plainer", false),
        ] {
            assert_eq!(wildcard(pattern, name), want, "{pattern} {name}");
        }
    }

    /// `load` is the only constructor and nothing changes a list: no public field, no `&mut self` method, no other
    /// function that answers a list, no trait that builds one.
    #[test]
    fn no_api_lifts_it() {
        let src = include_str!("deny.rs");
        let code = &src[..src.find("#[cfg(test)]").unwrap()];
        let start = code.find("pub struct DenyList {").unwrap();
        let body = &code[start + "pub struct DenyList {".len()..];
        let fields = &body[..body.find('}').unwrap()];
        assert!(!fields.contains("pub"), "a public field: {fields}");
        assert!(
            code[..start].trim_end().ends_with("#[derive(Debug)]"),
            "a derive that builds one"
        );
        assert_eq!(code.matches("impl DenyList {").count(), 1);
        assert!(
            !code.contains(&["for", "DenyList"].join(" ")),
            "a trait implemented for it"
        );
        let imp = &code[code.find("impl DenyList {").unwrap()..];
        let imp = &imp[..imp.find("\n}\n").unwrap()];
        let mut constructors = Vec::new();
        for (at, _) in imp.match_indices("pub fn ") {
            let sig = &imp[at..at + imp[at..].find('{').unwrap()];
            assert!(!sig.contains("&mut self"), "a setter: {sig}");
            if sig.contains("-> DenyList") || sig.contains("-> Self") {
                constructors.push(sig.to_string());
            }
        }
        assert_eq!(constructors.len(), 1, "{constructors:?}");
        assert!(constructors[0].starts_with("pub fn load("));
        for (at, _) in code.match_indices("pub fn ") {
            let sig = &code[at..at + code[at..].find('{').unwrap()];
            if !sig.starts_with("pub fn load(") {
                assert!(!sig.contains("-> DenyList"), "another constructor: {sig}");
            }
        }
    }
}
