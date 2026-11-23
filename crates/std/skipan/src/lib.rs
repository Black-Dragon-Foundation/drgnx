//! skipan (*skipan*, arrangement, order): the one settings schema (docs/develop/standards/settings.md).
//!
//! A setting is defined once, with a [`Kind`], a default and a doc. Its value comes from the stack of [`Level`]s,
//! the most specific last: built-in, user, machine, project, stream, language, document, pane. Any value answers
//! "why do I have this?" with its [`Provenance`]: the level and, for a file, the file and line. The user, machine and
//! project levels live in `.eld` files (read by huginn, written only through [`Settings::set`], which replaces the
//! file atomically through eitri); the others live in memory, keyed by the stream, language, document or pane they
//! belong to.
//!
//! A command reads one [`SettingsSnapshot`]: a reload or a `set` while it runs never changes what it sees.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use serde_json::Value;

mod theme;
pub use theme::{THEME_KEY, ThemeSwitch};

/// The head of a settings file: `(drgnx-settings :version 1 (KEY VALUE)…)`.
pub const FILE_HEAD: &str = "drgnx-settings";

/// A level of the stack, the least specific first.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum Level {
    BuiltIn,
    User,
    Machine,
    Project,
    Stream,
    Language,
    Document,
    Pane,
}

impl Level {
    pub const ALL: [Level; 8] = [
        Level::BuiltIn,
        Level::User,
        Level::Machine,
        Level::Project,
        Level::Stream,
        Level::Language,
        Level::Document,
        Level::Pane,
    ];

    /// The WIT name of the level (`built-in`, `user`, …).
    pub fn name(self) -> &'static str {
        match self {
            Level::BuiltIn => "built-in",
            Level::User => "user",
            Level::Machine => "machine",
            Level::Project => "project",
            Level::Stream => "stream",
            Level::Language => "language",
            Level::Document => "document",
            Level::Pane => "pane",
        }
    }

    pub fn from_name(name: &str) -> Option<Level> {
        Level::ALL.into_iter().find(|l| l.name() == name)
    }

    /// Whether the level can live in a file: user, machine and project.
    pub fn is_file(self) -> bool {
        matches!(self, Level::User | Level::Machine | Level::Project)
    }

    /// Whether a value at this level belongs to one stream, language, document or pane.
    pub fn is_scoped(self) -> bool {
        matches!(
            self,
            Level::Stream | Level::Language | Level::Document | Level::Pane
        )
    }
}

impl fmt::Display for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// What a setting holds.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Bool,
    Int,
    Float,
    Str,
    /// A list of strings.
    List,
}

impl Kind {
    /// V as this kind's value (an integer is a float where a float is wanted), or None.
    fn fit(self, v: &Value) -> Option<Value> {
        match (self, v) {
            (Kind::Bool, Value::Bool(_)) | (Kind::Str, Value::String(_)) => Some(v.clone()),
            (Kind::Int, Value::Number(n)) if n.is_i64() => Some(v.clone()),
            (Kind::Float, Value::Number(n)) => n.as_f64().map(Value::from),
            (Kind::List, Value::Array(a)) if a.iter().all(Value::is_string) => Some(v.clone()),
            _ => None,
        }
    }
}

/// A Rust type a setting is read as.
pub trait SettingValue: Sized {
    fn from_value(v: &Value) -> Option<Self>;
}

impl SettingValue for bool {
    fn from_value(v: &Value) -> Option<Self> {
        v.as_bool()
    }
}

impl SettingValue for i64 {
    fn from_value(v: &Value) -> Option<Self> {
        v.as_i64()
    }
}

impl SettingValue for f64 {
    fn from_value(v: &Value) -> Option<Self> {
        v.as_f64()
    }
}

impl SettingValue for String {
    fn from_value(v: &Value) -> Option<Self> {
        v.as_str().map(str::to_string)
    }
}

impl SettingValue for Vec<String> {
    fn from_value(v: &Value) -> Option<Self> {
        v.as_array()?
            .iter()
            .map(|s| s.as_str().map(str::to_string))
            .collect()
    }
}

/// Where a value was set.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Source {
    /// The definition's default.
    Default,
    /// A line of a settings file.
    File { path: PathBuf, line: u32 },
    /// An extension's override.
    Extension(String),
    /// Set by code at run time, for a level that has no file.
    Runtime,
}

/// Why a setting has its value: the level it came from, and where.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Provenance {
    pub level: Level,
    pub source: Source,
}

impl fmt::Display for Provenance {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.source {
            Source::Default => write!(f, "{} default", self.level),
            Source::File { path, line } => write!(f, "{} {}:{line}", self.level, path.display()),
            Source::Extension(id) => write!(f, "{} by extension {id}", self.level),
            Source::Runtime => write!(f, "{} (set in this session)", self.level),
        }
    }
}

/// What the scoped levels are read for: the stream, language, document and pane the caller is in.
#[derive(Clone, Default, Debug)]
pub struct Scope {
    pub stream: Option<String>,
    pub language: Option<String>,
    pub document: Option<String>,
    pub pane: Option<String>,
}

impl Scope {
    fn tag(&self, level: Level) -> Option<&str> {
        match level {
            Level::Stream => self.stream.as_deref(),
            Level::Language => self.language.as_deref(),
            Level::Document => self.document.as_deref(),
            Level::Pane => self.pane.as_deref(),
            _ => Some(""),
        }
    }
}

#[derive(Clone)]
struct Def {
    kind: Kind,
    default: Value,
}

#[derive(Clone)]
struct Entry {
    value: Value,
    source: Source,
}

/// One consistent view of every setting: it never changes after it is made.
#[derive(Clone, Default)]
pub struct SettingsSnapshot {
    defs: BTreeMap<String, Def>,
    /// (key, level, tag): the tag is the scope id of a scoped level, else empty
    entries: BTreeMap<(String, Level, String), Entry>,
    generation: u64,
}

impl SettingsSnapshot {
    /// How many times the settings changed before this snapshot.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    fn resolve(&self, key: &str, scope: &Scope) -> villa::Result<(Value, Provenance)> {
        let def = self
            .defs
            .get(key)
            .ok_or_else(|| villa::Error::not_found(format!("There is no setting `{key}`.")))?;
        for level in Level::ALL.into_iter().rev() {
            if level == Level::BuiltIn {
                break;
            }
            let Some(tag) = scope.tag(level) else {
                continue;
            };
            if let Some(e) = self.entries.get(&(key.to_string(), level, tag.to_string())) {
                return Ok((
                    e.value.clone(),
                    Provenance {
                        level,
                        source: e.source.clone(),
                    },
                ));
            }
        }
        Ok((
            def.default.clone(),
            Provenance {
                level: Level::BuiltIn,
                source: Source::Default,
            },
        ))
    }

    /// The setting as T, outside any stream, language, document or pane.
    pub fn get<T: SettingValue>(&self, key: &str) -> villa::Result<T> {
        self.get_in(key, &Scope::default())
    }

    /// The setting as T, for SCOPE.
    pub fn get_in<T: SettingValue>(&self, key: &str, scope: &Scope) -> villa::Result<T> {
        let (v, _) = self.resolve(key, scope)?;
        T::from_value(&v).ok_or_else(|| {
            villa::Error::invalid(format!("The setting `{key}` is not of that type."))
        })
    }

    /// The setting's value as JSON.
    pub fn value_in(&self, key: &str, scope: &Scope) -> villa::Result<Value> {
        Ok(self.resolve(key, scope)?.0)
    }

    /// Why the setting has its value.
    pub fn provenance(&self, key: &str) -> villa::Result<Provenance> {
        Ok(self.resolve(key, &Scope::default())?.1)
    }

    pub fn provenance_in(&self, key: &str, scope: &Scope) -> villa::Result<Provenance> {
        Ok(self.resolve(key, scope)?.1)
    }
}

/// A setting changed: what a watcher is told.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Changed {
    pub key: String,
    pub generation: u64,
}

struct Inner {
    cur: Arc<SettingsSnapshot>,
    files: BTreeMap<Level, PathBuf>,
    watchers: Vec<Sender<Changed>>,
}

/// The settings: share it by reference; every method takes `&self`.
pub struct Settings {
    inner: Mutex<Inner>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings::new()
    }
}

fn fs_error(path: &Path, e: eitri::FsError) -> villa::Error {
    let kind = match &e {
        eitri::FsError::Io(io) if io.kind() == std::io::ErrorKind::NotFound => {
            villa::Kind::NotFound
        }
        eitri::FsError::TooLarge { .. } => villa::Kind::Invalid,
        eitri::FsError::Link { .. } | eitri::FsError::Escapes | eitri::FsError::NotRegular => {
            villa::Kind::Refused
        }
        _ => villa::Kind::Io,
    };
    villa::Error::new(
        kind,
        format!("The settings file {} could not be used.", path.display()),
    )
    .with_detail(e.to_string())
}

fn read_file(path: &Path) -> villa::Result<Option<Vec<u8>>> {
    use std::os::fd::AsFd;
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(villa::Error::invalid("A settings path names no file.")
            .with_detail(path.display().to_string()));
    };
    let dir = match eitri::open_path(parent, eitri::Kind::Dir) {
        Ok(d) => d,
        Err(eitri::FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(fs_error(path, e)),
    };
    match eitri::read_regular(dir.fd.as_fd(), Path::new(name), 1 << 20) {
        Ok(b) => Ok(Some(b)),
        Err(eitri::FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(fs_error(path, e)),
    }
}

fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn render_value(v: &Value) -> String {
    match v {
        Value::Bool(true) => "t".into(),
        Value::Bool(false) | Value::Null => "nil".into(),
        Value::Number(n) => {
            if n.is_f64() && n.as_f64().is_some_and(|f| f.fract() == 0.0) {
                format!("{:.1}", n.as_f64().unwrap_or_default())
            } else {
                n.to_string()
            }
        }
        Value::String(s) => quote(s),
        Value::Array(a) if a.is_empty() => "nil".into(),
        Value::Array(a) => format!(
            "({})",
            a.iter().map(render_value).collect::<Vec<_>>().join(" ")
        ),
        Value::Object(_) => "nil".into(),
    }
}

/// The file text for LEVEL's entries (no scope tag), and each key's line.
fn render(snap: &SettingsSnapshot, level: Level) -> (String, BTreeMap<String, u32>) {
    let mut text = format!("({FILE_HEAD} :version 1");
    let mut lines = BTreeMap::new();
    let mut line = 1;
    for ((key, l, tag), e) in &snap.entries {
        if *l == level && tag.is_empty() {
            line += 1;
            lines.insert(key.clone(), line);
            text.push_str(&format!("\n ({key} {})", render_value(&e.value)));
        }
    }
    text.push_str(")\n");
    (text, lines)
}

fn node_value(kind: Kind, n: &huginn::value::Node) -> Option<Value> {
    use huginn::value::Datum;
    match (kind, &n.datum) {
        (Kind::Bool, Datum::Sym(s)) if s == "t" => Some(Value::Bool(true)),
        (Kind::Bool, Datum::Sym(s)) if s == "nil" => Some(Value::Bool(false)),
        (Kind::Int, Datum::Int(i)) => Some(Value::from(*i)),
        (Kind::Float, Datum::Float(f)) => Some(Value::from(*f)),
        (Kind::Float, Datum::Int(i)) => Some(Value::from(*i as f64)),
        (Kind::Str, Datum::Str(s)) => Some(Value::String(s.clone())),
        (Kind::List, Datum::Sym(s)) if s == "nil" => Some(Value::Array(Vec::new())),
        (Kind::List, Datum::List(items)) => items
            .iter()
            .map(|i| match &i.datum {
                Datum::Str(s) => Some(Value::String(s.clone())),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()
            .map(Value::Array),
        _ => None,
    }
}

impl Settings {
    pub fn new() -> Settings {
        Settings {
            inner: Mutex::new(Inner {
                cur: Arc::new(SettingsSnapshot::default()),
                files: BTreeMap::new(),
                watchers: Vec::new(),
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        saman::lock(&self.inner)
    }

    /// Define a setting: its key, kind and default. The default must fit the kind.
    pub fn define(&self, key: &str, kind: Kind, default: Value) -> villa::Result<()> {
        let Some(default) = kind.fit(&default) else {
            return Err(villa::Error::invalid(format!(
                "The default of `{key}` does not fit its kind."
            )));
        };
        let mut g = self.lock();
        if g.cur.defs.contains_key(key) {
            return Err(villa::Error::conflict(format!(
                "The setting `{key}` is already defined."
            )));
        }
        let mut next = (*g.cur).clone();
        next.defs.insert(key.to_string(), Def { kind, default });
        g.cur = Arc::new(next);
        Ok(())
    }

    /// Where LEVEL's file is (user, machine or project). It is read by [`Settings::reload`] and written by `set`.
    pub fn attach(&self, level: Level, path: impl Into<PathBuf>) -> villa::Result<()> {
        if !level.is_file() {
            return Err(villa::Error::invalid(format!(
                "The {level} level has no file."
            )));
        }
        self.lock().files.insert(level, path.into());
        Ok(())
    }

    /// The settings as they are now. Hold it for a command: nothing changes it.
    pub fn snapshot(&self) -> Arc<SettingsSnapshot> {
        Arc::clone(&self.lock().cur)
    }

    pub fn get<T: SettingValue>(&self, key: &str) -> villa::Result<T> {
        self.snapshot().get(key)
    }

    pub fn provenance(&self, key: &str) -> villa::Result<Provenance> {
        self.snapshot().provenance(key)
    }

    /// Changes are announced here; the receiver never blocks the sender.
    pub fn watch(&self) -> Receiver<Changed> {
        let (tx, rx) = channel();
        self.lock().watchers.push(tx);
        rx
    }

    fn announce(inner: &mut Inner, keys: Vec<String>, generation: u64) {
        inner.watchers.retain(|w| {
            keys.iter().all(|k| {
                w.send(Changed {
                    key: k.clone(),
                    generation,
                })
                .is_ok()
            })
        });
    }

    /// Set KEY at LEVEL (user, machine, project: the file, atomically; built-in is refused). A level of a stream,
    /// language, document or pane is set with [`Settings::set_scoped`].
    pub fn set(&self, key: &str, value: Value, level: Level) -> villa::Result<()> {
        if level.is_scoped() {
            return Err(villa::Error::invalid(format!(
                "The {level} level needs the id it applies to: use set_scoped."
            )));
        }
        self.set_at(key, value, level, "", Source::Runtime)
    }

    /// Set KEY at a scoped LEVEL, for the stream, language, document or pane named SCOPE_ID.
    pub fn set_scoped(
        &self,
        key: &str,
        value: Value,
        level: Level,
        scope_id: &str,
    ) -> villa::Result<()> {
        if !level.is_scoped() || scope_id.is_empty() {
            return Err(villa::Error::invalid(format!(
                "The {level} level takes no scope id, or the id is empty."
            )));
        }
        self.set_at(key, value, level, scope_id, Source::Runtime)
    }

    /// An extension's override of KEY at a scoped LEVEL, for the stream, language, document or pane named SCOPE_ID (in
    /// memory; its provenance names the extension). An extension never sets a level the user's files hold, nor the
    /// built-in one: that is refused.
    pub fn set_by_extension(
        &self,
        extension: &str,
        key: &str,
        value: Value,
        level: Level,
        scope_id: &str,
    ) -> villa::Result<()> {
        if !level.is_scoped() {
            return Err(villa::Error::refused(
                "An extension does not set the user's levels or the built-in one.",
            ));
        }
        if scope_id.is_empty() {
            return Err(villa::Error::invalid("The scope id is empty."));
        }
        self.set_at(
            key,
            value,
            level,
            scope_id,
            Source::Extension(extension.to_string()),
        )
    }

    fn set_at(
        &self,
        key: &str,
        value: Value,
        level: Level,
        tag: &str,
        source: Source,
    ) -> villa::Result<()> {
        if level == Level::BuiltIn {
            return Err(villa::Error::refused("Built-in settings are fixed."));
        }
        let mut g = self.lock();
        let Some(def) = g.cur.defs.get(key) else {
            return Err(villa::Error::not_found(format!(
                "There is no setting `{key}`."
            )));
        };
        let Some(value) = def.kind.fit(&value) else {
            return Err(villa::Error::invalid(format!(
                "The value does not fit the setting `{key}`."
            )));
        };
        let mut next = (*g.cur).clone();
        next.entries.insert(
            (key.to_string(), level, tag.to_string()),
            Entry { value, source },
        );
        // a file level is written first: a failed write leaves memory as it was
        if level.is_file()
            && tag.is_empty()
            && let Some(path) = g.files.get(&level).cloned()
        {
            let (text, lines) = render(&next, level);
            eitri::replace_file(&path, text.as_bytes()).map_err(|e| fs_error(&path, e))?;
            for ((k, l, t), e) in &mut next.entries {
                if *l == level && t.is_empty() {
                    e.source = Source::File {
                        path: path.clone(),
                        line: lines.get(k).copied().unwrap_or(1),
                    };
                }
            }
        }
        next.generation += 1;
        let generation = next.generation;
        g.cur = Arc::new(next);
        Self::announce(&mut g, vec![key.to_string()], generation);
        Ok(())
    }

    /// Read every attached file again (a missing file is an empty level). A file that cannot be read keeps its level as
    /// it was and is reported; so is each entry that could not be read. Watchers hear of every key that changed.
    pub fn reload(&self) -> villa::Result<Vec<String>> {
        let mut g = self.lock();
        let mut next = (*g.cur).clone();
        let mut problems = Vec::new();
        for (level, path) in g.files.clone() {
            let bytes = match read_file(&path) {
                Ok(b) => b,
                Err(e) => {
                    problems.push(format!("{}: {e}", path.display()));
                    continue;
                }
            };
            let mut fresh: BTreeMap<(String, Level, String), Entry> = BTreeMap::new();
            if let Some(bytes) = bytes {
                let file = match huginn::form::parse_settings(
                    &bytes,
                    FILE_HEAD,
                    huginn::read::Limits::default(),
                ) {
                    Ok(f) => f,
                    Err(r) => {
                        let line =
                            huginn::span::line_col(&String::from_utf8_lossy(&bytes), r.span.start)
                                .0;
                        problems.push(format!("{}:{line}: {}", path.display(), r.message));
                        continue;
                    }
                };
                let text = String::from_utf8_lossy(&bytes).into_owned();
                let line_of = |at: usize| huginn::span::line_col(&text, at).0;
                for p in &file.problems {
                    problems.push(format!(
                        "{}:{}: {}",
                        path.display(),
                        line_of(p.span.start),
                        p.message
                    ));
                }
                for e in &file.entries {
                    let line = line_of(e.span.start);
                    let Some(def) = next.defs.get(&e.var) else {
                        problems.push(format!(
                            "{}:{line}: there is no setting `{}`",
                            path.display(),
                            e.var
                        ));
                        continue;
                    };
                    if !e.scope.is_empty() {
                        problems.push(format!(
                            "{}:{line}: sections are not supported: `{}`",
                            path.display(),
                            e.var
                        ));
                        continue;
                    }
                    let Some(value) = node_value(def.kind, &e.value) else {
                        problems.push(format!(
                            "{}:{line}: the value of `{}` does not fit its kind",
                            path.display(),
                            e.var
                        ));
                        continue;
                    };
                    fresh.insert(
                        (e.var.clone(), level, String::new()),
                        Entry {
                            value,
                            source: Source::File {
                                path: path.clone(),
                                line,
                            },
                        },
                    );
                }
            }
            next.entries
                .retain(|(_, l, t), _| !(*l == level && t.is_empty()));
            next.entries.extend(fresh);
        }
        let mut changed: Vec<String> = Vec::new();
        for key in next.defs.keys() {
            let was = g.cur.resolve(key, &Scope::default()).ok();
            let now = next.resolve(key, &Scope::default()).ok();
            if was != now {
                changed.push(key.clone());
            }
        }
        if !changed.is_empty() {
            next.generation += 1;
            let generation = next.generation;
            g.cur = Arc::new(next);
            Self::announce(&mut g, changed, generation);
        }
        Ok(problems)
    }
}
