//! Other agent CLIs' past sessions (Claude Code, Gemini CLI, Codex): found in the CLIs' own folders, read read-only
//! through `minni`, indexed in `<state>/hub/history.db` (mode 0600, apart from work.db) with the transcripts' text in
//! an FTS5 table after the transcript redaction, and shown as rows: the History list (`agents/history/subscribe`) and
//! a session's transcript (`agents/history/open`, view `agent-history/PROVIDER:ID`), drawn by the panel's own row
//! builder.  Resume here (`agents/history/resume`) starts a drgnx session attached to the CLI's own session id; the
//! jail gets a copy of that one file, or, chosen per resume, read-write access to that one original file
//! ([`grant`], read by `sandbox::login_grants`).
//!
//! Privacy: the hub only ever reads those folders (opened read-only, never following a link); the user's words stay
//! here (no model, no other index); the methods are the user's alone, and no agent tool reaches them.

use crate::agents::session::rows;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::Key;
use drgnx_rows::{Row, RowBuilder};
use minni::{Provider, Reader};
use runstav::methods::agents::{Entry, EntryType};
use runstav::methods::past::{
    PastDrift, PastHit, PastHits, PastOpened, PastProvider, PastRef, PastResume, PastResumed,
    PastRoute, PastScanned, PastSearch, PastSession, PastStatus, PastSubscribe,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use urdr::Connection;

/// The index's file name in `<state>/hub`.
pub const DB: &str = "history.db";
/// A session file larger than this is not read.
const MAX_FILE: u64 = 512 << 20;
/// The readers kept for reading on from an offset (the files changed last).
const READERS: usize = 32;
/// The transcripts kept open as views.
const OPEN: usize = 16;
/// The rows of the list, at most.
const LIST: usize = 2000;
/// The view prefix of a past session's transcript.
pub const VIEW: &str = "agent-history/";

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn err(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: None,
    }
}

fn internal(message: impl Into<String>) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.into(),
        path: None,
    }
}

pub fn provider_of(p: PastProvider) -> Provider {
    match p {
        PastProvider::Claude => Provider::Claude,
        PastProvider::Gemini => Provider::Gemini,
        PastProvider::Codex => Provider::Codex,
    }
}

fn past_of(p: Provider) -> PastProvider {
    match p {
        Provider::Claude => PastProvider::Claude,
        Provider::Gemini => PastProvider::Gemini,
        Provider::Codex => PastProvider::Codex,
    }
}

/// The CLIs' folders, by the rules the editor's config uses: Claude `$CLAUDE_CONFIG_DIR`, else `~/.claude`; Codex
/// `$CODEX_HOME`, else `~/.codex`; Gemini `.gemini` under `$GEMINI_CLI_HOME`, else `~/.gemini`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Roots {
    pub claude: Option<PathBuf>,
    pub gemini: Option<PathBuf>,
    pub codex: Option<PathBuf>,
    /// Files whose change time is older than this many days are not read (0: no cap).
    pub days: u32,
}

/// A session file found: its CLI, path, size and change time (ns).
#[derive(Clone, Debug, PartialEq)]
pub struct Found {
    pub provider: Provider,
    pub path: PathBuf,
    pub size: u64,
    pub mtime: i64,
}

impl Roots {
    pub fn of(home: &Path, var: impl Fn(&str) -> Option<String>) -> Roots {
        let dir = |v: &str| var(v).filter(|s| !s.is_empty()).map(PathBuf::from);
        Roots {
            claude: Some(dir("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude"))),
            codex: Some(dir("CODEX_HOME").unwrap_or_else(|| home.join(".codex"))),
            gemini: Some(
                dir("GEMINI_CLI_HOME")
                    .map(|h| h.join(".gemini"))
                    .unwrap_or_else(|| home.join(".gemini")),
            ),
            days: 0,
        }
    }

    /// Only the CLIs NAMES lists ("claude", "gemini", "codex"; `drgnx-agents-history-providers`).
    pub fn only(mut self, names: &[String]) -> Roots {
        let on = |n: &str| names.iter().any(|x| x == n);
        if !on("claude") {
            self.claude = None;
        }
        if !on("gemini") {
            self.gemini = None;
        }
        if !on("codex") {
            self.codex = None;
        }
        self
    }

    /// Only files changed within the last DAYS days (`drgnx-agents-history-days`; 0 reads all).
    pub fn within(mut self, days: u32) -> Roots {
        self.days = days;
        self
    }

    /// The root PROVIDER's files live under.
    pub fn root(&self, p: Provider) -> Option<&Path> {
        match p {
            Provider::Claude => self.claude.as_deref(),
            Provider::Gemini => self.gemini.as_deref(),
            Provider::Codex => self.codex.as_deref(),
        }
    }

    /// Every session file under the roots (never through a link): Claude's `projects/*/*.jsonl`, Gemini's
    /// `tmp/*/chats/session-*.json{l,}`, Codex's `sessions/YYYY/MM/DD/rollout-*.jsonl` and `archived_sessions/*.jsonl`.
    pub fn files(&self) -> Vec<Found> {
        let mut out = self.walk(&mut Walk::default()).fresh;
        out.sort_by_key(|f| std::cmp::Reverse(f.mtime));
        out
    }

    /// The walk W remembers: a folder of files none of which changed within the last hour is read again only when its
    /// own change time moved or on every 30th walk (a file appended to in an old folder is then seen within a minute at
    /// 2 s polling); a folder with a recent file is read every walk.  Only the folders read are in `fresh`.
    pub fn walk(&self, w: &mut Walk) -> Walked {
        w.round += 1;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos() as i64);
        let ctx = Ctx {
            recheck: w.round % COLD_ROUNDS == 1,
            hot_after: now - HOT_NS,
            cutoff: (self.days > 0).then(|| now - i64::from(self.days) * 86_400 * 1_000_000_000),
        };
        let mut out = Walked::default();
        let mut leaf = |dir: &Path, p: Provider, want: &dyn Fn(&str) -> bool| {
            leaf_in(dir, p, want, w, &ctx, &mut out)
        };
        if let Some(r) = &self.claude {
            for d in dirs_in(&r.join("projects")) {
                leaf(&d, Provider::Claude, &|n| n.ends_with(".jsonl"));
            }
        }
        if let Some(r) = &self.gemini {
            for d in dirs_in(&r.join("tmp")) {
                leaf(&d.join("chats"), Provider::Gemini, &|n| {
                    n.starts_with("session-") && (n.ends_with(".jsonl") || n.ends_with(".json"))
                });
            }
        }
        if let Some(r) = &self.codex {
            let rollout = |n: &str| n.starts_with("rollout-") && n.ends_with(".jsonl");
            for y in dirs_in(&r.join("sessions")) {
                for m in dirs_in(&y) {
                    for d in dirs_in(&m) {
                        leaf(&d, Provider::Codex, &rollout);
                    }
                }
            }
            leaf(&r.join("archived_sessions"), Provider::Codex, &rollout);
        }
        out
    }
}

/// A folder is "hot" while a file in it changed within this long.
const HOT_NS: i64 = 3_600 * 1_000_000_000;
/// Every this many walks the cold folders are read again whatever their change time says.
const COLD_ROUNDS: u64 = 30;

/// What `Roots::walk` remembers between walks: each leaf folder's change time and whether it held a recent file.
#[derive(Default)]
pub struct Walk {
    dirs: HashMap<PathBuf, Seen>,
    round: u64,
}

struct Seen {
    mtime: i64,
    hot: bool,
}

/// The files of the folders read this walk, and the folders (with their file counts) taken as they were.
#[derive(Default)]
pub struct Walked {
    pub fresh: Vec<Found>,
    /// The folders read this walk (even when empty), and the ones taken as they were.
    pub read: HashSet<PathBuf>,
    pub cached: HashSet<PathBuf>,
}

struct Ctx {
    recheck: bool,
    hot_after: i64,
    cutoff: Option<i64>,
}

fn leaf_in(
    dir: &Path,
    p: Provider,
    want: &dyn Fn(&str) -> bool,
    w: &mut Walk,
    ctx: &Ctx,
    out: &mut Walked,
) {
    let Ok(m) = std::fs::metadata(dir) else {
        w.dirs.remove(dir);
        return;
    };
    let dm = mtime_of(&m);
    if let Some(s) = w.dirs.get(dir)
        && s.mtime == dm
        && !s.hot
        && !ctx.recheck
    {
        out.cached.insert(dir.to_path_buf());
        return;
    }
    out.read.insert(dir.to_path_buf());
    let before = out.fresh.len();
    files_in(dir, p, want, &mut out.fresh);
    if let Some(c) = ctx.cutoff {
        let mut i = before;
        while i < out.fresh.len() {
            if out.fresh[i].mtime < c {
                out.fresh.swap_remove(i);
            } else {
                i += 1;
            }
        }
    }
    let hot = out.fresh[before..].iter().any(|f| f.mtime > ctx.hot_after);
    w.dirs.insert(dir.to_path_buf(), Seen { mtime: dm, hot });
}

fn parent_of(path: &str) -> PathBuf {
    Path::new(path)
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

/// The folders in DIR (not links).
fn dirs_in(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    rd.flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .collect()
}

fn files_in(dir: &Path, p: Provider, want: impl Fn(&str) -> bool, out: &mut Vec<Found>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let Ok(t) = e.file_type() else { continue };
        if !t.is_file() || !e.file_name().to_str().is_some_and(&want) {
            continue;
        }
        let Ok(m) = e.metadata() else { continue };
        out.push(Found {
            provider: p,
            path: e.path(),
            size: m.len(),
            mtime: mtime_of(&m),
        });
    }
}

fn mtime_of(m: &std::fs::Metadata) -> i64 {
    use std::os::unix::fs::MetadataExt;
    m.mtime() * 1_000_000_000 + m.mtime_nsec()
}

/// PATH opened read-only, never through a link.
fn open_ro(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
}

const SCHEMA: &str = "
create table if not exists session (
  key text primary key, provider text not null, sid text not null, path text not null unique, cwd text,
  title text not null, branch text, started text, updated text, turns integer not null, size integer not null,
  mtime integer not null, off integer not null, entries integer not null, lines integer not null,
  unknown integer not null);
create virtual table if not exists turn using fts5(key unindexed, idx unindexed, text);
";

/// The index at PATH, made with mode 0600 when missing (and set back to it when it is not).
pub fn open_db(path: &Path) -> Result<Connection, String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let c = Connection::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    // the index is a cache: one from before the format-drift columns is dropped and read again
    let old: bool = c
        .query_row(
            "select count(*) = 0 from pragma_table_info('session') where name = 'unknown'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?
        && c.query_row(
            "select count(*) > 0 from pragma_table_info('session')",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if old {
        c.execute_batch("drop table session; drop table turn;")
            .map_err(|e| e.to_string())?;
    }
    c.execute_batch(SCHEMA)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(c)
}

/// One indexed session's row.
#[derive(Clone, Debug, PartialEq)]
struct Indexed {
    key: String,
    path: String,
    size: u64,
    mtime: i64,
    off: u64,
    entries: u64,
}

/// What a transcript turn adds to the index: an entry's words (a tool call's title only), redacted.
fn index_text(e: &Value) -> Option<String> {
    let t = match e["type"].as_str()? {
        "user" | "agent" | "thought" | "notice" | "error" => e["text"].as_str()?,
        "tool" => e["title"].as_str()?,
        _ => return None,
    };
    let t = t.trim();
    (!t.is_empty()).then(|| crate::agents::transcript::redact(t))
}

/// A file counts as drifted from the format at this share of unknown lines, over at least this many lines.
const DRIFT_PCT: i64 = 20;
const DRIFT_LINES: i64 = 10;

/// What a shown History list asked for: its workspace, its query and, for a section of another list, its limit.
type Asked = (Option<String>, Option<String>, Option<usize>);

/// The past sessions: where the index is, what it reads, the readers kept, the list's views and the transcripts open.
#[derive(Default)]
pub struct History {
    inner: Mutex<Inner>,
    /// The list as last read from the index, newest first.
    list: Mutex<Vec<PastSession>>,
    /// (connection, view) → (workspace, query) of each History list shown.
    shown: Mutex<BTreeMap<(u64, String), Asked>>,
    /// The transcripts open, by view, oldest first.
    open: Mutex<Vec<(String, Arc<Vec<Entry>>)>>,
    /// Files opened to read since the start.
    reads: std::sync::atomic::AtomicU64,
}

#[derive(Default)]
struct Inner {
    db: Option<Connection>,
    db_path: Option<PathBuf>,
    roots: Option<Roots>,
    readers: Vec<(PathBuf, Reader)>,
    /// The indexed files by path, as the index has them (loaded once, kept current by each scan).
    known: Option<HashMap<String, Indexed>>,
    /// How many indexed files each leaf folder holds (the known ones, by their parent).
    per_dir: HashMap<PathBuf, usize>,
    walk: Walk,
    /// The list has been read from the index since it was opened.
    listed: bool,
}

impl History {
    /// Read the CLIs' folders ROOTS into the index at DB_PATH from now on.
    pub fn configure(&self, db_path: PathBuf, roots: Roots) {
        let mut i = lock(&self.inner);
        if i.db_path.as_ref() != Some(&db_path) {
            i.db = None;
            i.known = None;
            i.walk = Walk::default();
            i.listed = false;
        }
        i.db_path = Some(db_path);
        if i.roots.as_ref() != Some(&roots) {
            // other roots (or another cap): every folder is read again
            i.walk = Walk::default();
        }
        i.roots = Some(roots);
    }

    /// Past sessions turned off (`drgnx-agents-history`): nothing is read any more, and the index at DB_PATH is
    /// deleted with what it holds.
    pub fn off(&self, db_path: &Path) {
        let mut i = lock(&self.inner);
        i.db = None;
        i.known = None;
        i.walk = Walk::default();
        i.listed = false;
        i.roots = None;
        i.readers.clear();
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let mut p = db_path.as_os_str().to_owned();
            p.push(suffix);
            let _ = std::fs::remove_file(PathBuf::from(p));
        }
        drop(i);
        lock(&self.list).clear();
        lock(&self.open).clear();
    }

    pub fn roots(&self) -> Option<Roots> {
        lock(&self.inner).roots.clone()
    }

    /// The folders scanned (the indexer's deny list takes them too).
    pub fn dirs(&self) -> Vec<PathBuf> {
        let Some(r) = self.roots() else {
            return Vec::new();
        };
        [r.claude, r.gemini, r.codex]
            .into_iter()
            .flatten()
            .collect()
    }

    /// Scan the roots now (blocking): new and changed files read (an append from its offset), gone ones dropped.  The
    /// answer is how many sessions are indexed.
    pub fn scan(&self) -> Result<u64, String> {
        self.scan_changed().map(|(n, _)| n)
    }

    /// Files opened to read since the start (a scan that finds nothing new opens none).
    pub fn reads(&self) -> u64 {
        self.reads.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// `scan`, and whether the index changed.  The walk is stat-only: the files' size and change time are compared with
    /// the known ones held in memory; when nothing is new, changed or gone nothing is opened, written or listed.
    pub fn scan_changed(&self) -> Result<(u64, bool), String> {
        let mut i = lock(&self.inner);
        let Some(roots) = i.roots.clone() else {
            return Ok((0, false));
        };
        if i.db.is_none() {
            let Some(p) = i.db_path.clone() else {
                return Ok((0, false));
            };
            i.db = Some(open_db(&p)?);
            i.known = None;
            i.walk = Walk::default();
            i.listed = false;
        }
        let Inner {
            db,
            readers,
            known,
            listed,
            per_dir,
            walk,
            ..
        } = &mut *i;
        let db = db.as_mut().expect("opened above");
        if known.is_none() {
            let k = indexed(db)?;
            per_dir.clear();
            for r in k.values() {
                *per_dir.entry(parent_of(&r.path)).or_default() += 1;
            }
            *known = Some(k);
        }
        let known_map = known.as_mut().expect("loaded above");
        let walked = roots.walk(walk);
        let found = &walked.fresh;
        let todo: Vec<&Found> = found
            .iter()
            .filter(|f| {
                f.size <= MAX_FILE
                    && !known_map
                        .get(f.path.to_string_lossy().as_ref())
                        .is_some_and(|r| r.size == f.size && r.mtime == f.mtime)
            })
            .collect();
        // what is known in the folders read, against what was found there; and every folder known is still there
        let mut matched: HashMap<&Path, usize> = HashMap::new();
        for f in found {
            if known_map.contains_key(f.path.to_string_lossy().as_ref())
                && let Some(d) = f.path.parent()
            {
                *matched.entry(d).or_default() += 1;
            }
        }
        let steady = per_dir.iter().all(|(d, n)| {
            walked.cached.contains(d)
                || (walked.read.contains(d) && matched.get(d.as_path()).copied().unwrap_or(0) == *n)
        });
        if todo.is_empty() && steady && *listed {
            return Ok((known_map.len() as u64, false));
        }
        let paths: HashSet<&Path> = found.iter().map(|f| f.path.as_path()).collect();
        let gone: Vec<Indexed> = known_map
            .values()
            .filter(|k| {
                let path = Path::new(&k.path);
                let dir = path.parent().unwrap_or(path);
                if walked.cached.contains(dir) {
                    false
                } else if walked.read.contains(dir) {
                    !paths.contains(path)
                } else {
                    true
                }
            })
            .cloned()
            .collect();
        let tx = db.transaction().map_err(|e| e.to_string())?;
        for k in &gone {
            drop_session(&tx, &k.key)?;
        }
        let mut put: Vec<Indexed> = Vec::new();
        for f in todo {
            let path = f.path.to_string_lossy().into_owned();
            let row = known_map.get(&path);
            // a file read before and grown since reads on from its offset with the reader kept, else whole
            let mut reader = None;
            if let Some(r) = row
                && f.size >= r.size
                && let Some(n) = readers
                    .iter()
                    .position(|(p, rd)| *p == f.path && rd.offset() == r.off)
            {
                reader = Some(readers.remove(n).1);
            }
            let fresh = reader.is_none();
            let mut rd = reader.unwrap_or_else(|| Reader::new(f.provider));
            self.reads
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if let Err(e) = read_into(&mut rd, f) {
                tracing::debug!("past sessions: {}: {e}", f.path.display());
                continue;
            }
            let old_entries = if fresh {
                0
            } else {
                row.map_or(0, |r| r.entries)
            };
            put.push(index_one(&tx, f, &rd, row, old_entries)?);
            readers.push((f.path.clone(), rd));
            if readers.len() > READERS {
                readers.remove(0);
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
        for k in &gone {
            known_map.remove(&k.path);
            let d = parent_of(&k.path);
            if let Some(n) = per_dir.get_mut(&d) {
                *n -= 1;
                if *n == 0 {
                    per_dir.remove(&d);
                }
            }
        }
        for r in put {
            let d = parent_of(&r.path);
            if known_map.insert(r.path.clone(), r).is_none() {
                *per_dir.entry(d).or_default() += 1;
            }
        }
        let list = list_of(db)?;
        let n = known_map.len() as u64;
        *lock(&self.list) = list;
        *listed = true;
        Ok((n, true))
    }

    /// The CLIs whose files read with a share of lines this build does not know: per provider, how many files had at
    /// least `DRIFT_PCT` percent unknown lines over at least `DRIFT_LINES` lines, and the share over those files.
    pub fn drift(&self) -> Result<Vec<PastDrift>, String> {
        let i = lock(&self.inner);
        let Some(db) = i.db.as_ref() else {
            return Ok(Vec::new());
        };
        let mut st = db
            .prepare(
                "select provider, count(*), sum(unknown), sum(lines) from session
                 where lines >= ?1 and unknown * 100 >= lines * ?2 group by provider order by provider",
            )
            .map_err(|e| e.to_string())?;
        let rows = st
            .query_map((DRIFT_LINES, DRIFT_PCT), |r| {
                let provider: String = r.get(0)?;
                let (unknown, lines): (i64, i64) = (r.get(2)?, r.get(3)?);
                Ok(PastDrift {
                    provider: past_of(Provider::from_name(&provider).unwrap_or(Provider::Claude)),
                    files: r.get::<_, i64>(1)? as u64,
                    unknown_pct: (unknown * 100 / lines.max(1)) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<_, _>>().map_err(|e| e.to_string())
    }

    /// The sessions whose title or transcript hold every word of QUERY, best first.
    pub fn search(&self, query: &str) -> Result<Vec<PastHit>, String> {
        let mut i = lock(&self.inner);
        let Some(db) = i.db.as_mut() else {
            return Ok(Vec::new());
        };
        search_in(db, query)
    }

    /// The session PROVIDER:ID as the list has it, and its file.
    fn find(&self, p: PastProvider, id: &str) -> Result<(PastSession, PathBuf), String> {
        let i = lock(&self.inner);
        let db = i.db.as_ref().ok_or("no past sessions are indexed")?;
        let key = format!("{}:{id}", provider_of(p).name());
        let mut st = db
            .prepare("select path from session where key = ?1")
            .map_err(|e| e.to_string())?;
        let path: String = st
            .query_row([&key], |r| r.get(0))
            .map_err(|_| format!("no past session {key}"))?;
        let s = lock(&self.list)
            .iter()
            .find(|s| s.provider == p && s.id == id)
            .cloned()
            .ok_or_else(|| format!("no past session {key}"))?;
        Ok((s, PathBuf::from(path)))
    }

    /// The rows of the History list KEY shows, when it is one.
    pub fn build(&self, f: &Front, key: &Key) -> bool {
        if let Some(view) = key.1.strip_prefix(VIEW) {
            let entries = lock(&self.open)
                .iter()
                .find(|(v, _)| v == &key.1)
                .map(|(_, e)| e.clone());
            let Some(entries) = entries else {
                return false;
            };
            let _ = view;
            f.core
                .views
                .publish_built(f, key, |_, _| (transcript_rows(&entries), Vec::new()));
            return true;
        }
        let Some((workspace, query, limit)) =
            lock(&self.shown).get(&(key.0, key.1.clone())).cloned()
        else {
            return false;
        };
        let hits = query
            .as_deref()
            .filter(|q| !q.trim().is_empty())
            .map(|q| self.search(q).unwrap_or_default());
        let list = lock(&self.list).clone();
        f.core.views.publish_built(f, key, |_, _| {
            (
                list_rows(&list, workspace.as_deref(), hits.as_deref(), limit),
                Vec::new(),
            )
        });
        true
    }

    /// Every class of CONN's VIEW built again.
    fn build_all(&self, f: &Front, conn: Option<u64>, view: &str) {
        for key in f.core.views.keys_of(view) {
            if conn.is_none_or(|c| c == key.0) {
                self.build(f, &key);
            }
        }
    }

    /// The list views shown, built again (after a scan changed the index).
    pub fn rebuild_lists(&self, f: &Front) {
        let views: Vec<(u64, String)> = lock(&self.shown).keys().cloned().collect();
        for (c, v) in views {
            self.build_all(f, Some(c), &v);
        }
    }

    /// Connection CONN is gone: its lists are no longer shown.
    pub fn gone(&self, conn: u64) {
        lock(&self.shown).retain(|(c, _), _| *c != conn);
    }
}

fn indexed(db: &Connection) -> Result<HashMap<String, Indexed>, String> {
    let mut st = db
        .prepare("select key, path, size, mtime, off, entries from session")
        .map_err(|e| e.to_string())?;
    let rows = st
        .query_map([], |r| {
            Ok(Indexed {
                key: r.get(0)?,
                path: r.get(1)?,
                size: r.get::<_, i64>(2)? as u64,
                mtime: r.get(3)?,
                off: r.get::<_, i64>(4)? as u64,
                entries: r.get::<_, i64>(5)? as u64,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut out = HashMap::new();
    for r in rows {
        let r = r.map_err(|e| e.to_string())?;
        out.insert(r.path.clone(), r);
    }
    Ok(out)
}

fn drop_session(tx: &Connection, key: &str) -> Result<(), String> {
    tx.execute("delete from session where key = ?1", [key])
        .map_err(|e| e.to_string())?;
    tx.execute("delete from turn where key = ?1", [key])
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// F's bytes from RD's offset on, fed to RD (an old Gemini `.json` file whole).
fn read_into(rd: &mut Reader, f: &Found) -> std::io::Result<()> {
    let mut file = open_ro(&f.path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other("not a regular file"));
    }
    if f.provider == Provider::Gemini && f.path.extension().is_some_and(|e| e == "json") {
        let mut all = Vec::new();
        file.take(MAX_FILE).read_to_end(&mut all)?;
        *rd = minni::parse_whole(Provider::Gemini, &all);
        return Ok(());
    }
    file.seek(SeekFrom::Start(rd.offset()))?;
    let mut tail = Vec::new();
    file.take(MAX_FILE).read_to_end(&mut tail)?;
    rd.feed(&tail);
    Ok(())
}

/// F's session (read into RD) put in the index: its row, and its turns' text from OLD_ENTRIES on (all of them again
/// when the reader started over, or a Gemini file, whose messages change in place).
fn index_one(
    tx: &Connection,
    f: &Found,
    rd: &Reader,
    row: Option<&Indexed>,
    old_entries: u64,
) -> Result<Indexed, String> {
    let meta = rd.meta();
    let sid = meta.id.clone().unwrap_or_else(|| {
        f.path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default()
    });
    let key = format!("{}:{sid}", f.provider.name());
    let entries = rd.entries();
    let again = f.provider == Provider::Gemini
        || old_entries == 0
        || entries.len() as u64 <= old_entries
        || row.is_some_and(|r| r.key != key);
    if let Some(r) = row
        && (r.key != key || again)
    {
        drop_session(tx, &r.key)?;
    }
    if again {
        drop_session(tx, &key)?;
    }
    let from = if again { 0 } else { old_entries as usize };
    for (idx, e) in entries.iter().enumerate().skip(from) {
        if let Some(t) = index_text(e) {
            tx.execute(
                "insert into turn (key, idx, text) values (?1, ?2, ?3)",
                (&key, idx as i64, &t),
            )
            .map_err(|e| e.to_string())?;
        }
    }
    let title = meta
        .title
        .as_deref()
        .map(crate::agents::transcript::redact)
        .unwrap_or_else(|| "(untitled)".into());
    tx.execute(
        "insert into session (key, provider, sid, path, cwd, title, branch, started, updated, turns, size, mtime, off,
           entries, lines, unknown) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
         on conflict(key) do update set path = ?4, cwd = ?5, title = ?6, branch = ?7, started = ?8, updated = ?9,
           turns = ?10, size = ?11, mtime = ?12, off = ?13, entries = ?14, lines = ?15,
           unknown = ?16",
        (
            &key,
            f.provider.name(),
            &sid,
            f.path.to_string_lossy().as_ref(),
            meta.cwd.as_deref(),
            &title,
            meta.branch.as_deref(),
            meta.started.as_deref(),
            meta.updated.as_deref(),
            i64::from(meta.turns),
            f.size as i64,
            f.mtime,
            rd.offset() as i64,
            entries.len() as i64,
            rd.lines() as i64,
            rd.unknown() as i64,
        ),
    )
    .map_err(|e| e.to_string())?;
    Ok(Indexed {
        key,
        path: f.path.to_string_lossy().into_owned(),
        size: f.size,
        mtime: f.mtime,
        off: rd.offset(),
        entries: entries.len() as u64,
    })
}

const COLUMNS: &str = "provider, sid, title, cwd, branch, started, updated, turns";

fn session_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<PastSession> {
    let provider: String = r.get(0)?;
    Ok(PastSession {
        provider: past_of(Provider::from_name(&provider).unwrap_or(Provider::Claude)),
        id: r.get(1)?,
        title: r.get(2)?,
        cwd: r.get(3)?,
        branch: r.get(4)?,
        started: r.get(5)?,
        updated: r.get(6)?,
        turns: r.get::<_, i64>(7)? as u64,
        live: None,
    })
}

fn list_of(db: &Connection) -> Result<Vec<PastSession>, String> {
    let mut st = db
        .prepare(&format!(
            "select {COLUMNS} from session order by coalesce(updated, '') desc limit {LIST}"
        ))
        .map_err(|e| e.to_string())?;
    let rows = st.query_map([], session_of).map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())
}

/// QUERY as an FTS5 match: every word as a phrase (quotes doubled), the last one a prefix.  None when it has no word.
pub fn fts_query(query: &str) -> Option<String> {
    let words: Vec<String> = query
        .split_whitespace()
        .map(|w| format!("\"{}\"", w.replace('"', "\"\"")))
        .collect();
    let last = words.len().checked_sub(1)?;
    Some(
        words
            .iter()
            .enumerate()
            .map(|(n, w)| {
                if n == last {
                    format!("{w}*")
                } else {
                    w.clone()
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    )
}

fn search_in(db: &Connection, query: &str) -> Result<Vec<PastHit>, String> {
    let Some(q) = fts_query(query) else {
        return Ok(Vec::new());
    };
    let mut hits: Vec<PastHit> = Vec::new();
    let mut seen = BTreeSet::new();
    // a title that holds the query comes first
    let like = format!("%{}%", query.trim().replace(['%', '_', '\\'], ""));
    let mut st = db
        .prepare(&format!(
            "select {COLUMNS} from session where title like ?1 order by coalesce(updated, '') desc limit 200"
        ))
        .map_err(|e| e.to_string())?;
    for s in st
        .query_map([&like], session_of)
        .map_err(|e| e.to_string())?
        .flatten()
    {
        if seen.insert((s.provider, s.id.clone())) {
            let snippet = s.title.clone();
            hits.push(PastHit {
                session: s,
                snippet,
            });
        }
    }
    let cols = COLUMNS
        .split(", ")
        .map(|c| format!("s.{c}"))
        .collect::<Vec<_>>()
        .join(", ");
    let mut st = db
        .prepare(&format!(
            "select {cols}, snippet(turn, 2, '', '', '…', 16) from turn join session s on s.key = turn.key
             where turn match ?1 order by rank limit 400"
        ))
        .map_err(|e| e.to_string())?;
    let rows = st
        .query_map([&q], |r| Ok((session_of(r)?, r.get::<_, String>(8)?)))
        .map_err(|e| e.to_string())?;
    for (s, snippet) in rows.flatten() {
        if hits.len() >= 50 {
            break;
        }
        if seen.insert((s.provider, s.id.clone())) {
            hits.push(PastHit {
                session: s,
                snippet,
            });
        }
    }
    Ok(hits)
}

/// The mark a provider's rows start with.
fn mark(p: PastProvider) -> &'static str {
    match p {
        PastProvider::Claude => "Claude",
        PastProvider::Gemini => "Gemini",
        PastProvider::Codex => "Codex",
    }
}

/// Whether CWD is WORKSPACE or under it.
fn in_workspace(cwd: Option<&str>, workspace: Option<&str>) -> bool {
    let (Some(c), Some(w)) = (cwd, workspace) else {
        return false;
    };
    let w = w.trim_end_matches('/');
    c == w || c.strip_prefix(w).is_some_and(|r| r.starts_with('/'))
}

/// One past session's row: the provider's mark, the title, then the project, the date, the turns and the branch
/// dimmed (and the hit's snippet, when searched); the session's provider and id over the row.
fn session_row(s: &PastSession, snippet: Option<&str>) -> Row {
    let mut r = RowBuilder::new(format!("h:{}:{}", provider_of(s.provider).name(), s.id));
    r.push("  ", None);
    r.push(mark(s.provider), Some("drgnx-agent-panel-subtle"));
    r.push("  ", None);
    r.push(&rows::one_line(&s.title, 70), None);
    let project = s
        .cwd
        .as_deref()
        .and_then(|c| c.trim_end_matches('/').rsplit('/').next())
        .unwrap_or("");
    let mut meta = vec![project.to_owned()];
    if let Some(d) = s.updated.as_deref().or(s.started.as_deref()) {
        meta.push(d.chars().take(10).collect());
    }
    meta.push(format!(
        "{} turn{}",
        s.turns,
        if s.turns == 1 { "" } else { "s" }
    ));
    if let Some(b) = &s.branch {
        meta.push(b.clone());
    }
    let meta: Vec<String> = meta.into_iter().filter(|m| !m.is_empty()).collect();
    r.push(
        &format!("  {}", meta.join(" · ")),
        Some("drgnx-agent-panel-subtle"),
    );
    if let Some(sn) = snippet.filter(|sn| *sn != s.title) {
        r.push(
            &format!("  — {}", rows::one_line(sn, 60)),
            Some("drgnx-agent-panel-subtle"),
        );
    }
    let end = r.pos();
    r.prop(
        0,
        end,
        "drgnx-past",
        json!({"provider": provider_of(s.provider).name(), "id": s.id}),
    );
    r.finish()
}

fn header_row(key: &str, text: &str) -> Row {
    let mut r = RowBuilder::new(key);
    r.push(text, Some("drgnx-agent-panel-subtle"));
    r.finish()
}

/// The History list's rows: the workspace's sessions under one header, then the others'; with HITS (a search), the
/// hits in their order.  With LIMIT, a section of another list: a "Past sessions" header first, at most LIMIT sessions
/// (the workspace's first), and a last row saying how many more Past Sessions shows.
pub fn list_rows(
    list: &[PastSession],
    workspace: Option<&str>,
    hits: Option<&[PastHit]>,
    limit: Option<usize>,
) -> Vec<Row> {
    let Some(limit) = limit else {
        return all_rows(list, workspace, hits);
    };
    let mut out = vec![header_row("h:past", "Past sessions")];
    let rows = all_rows(list, workspace, hits);
    let sessions = rows
        .iter()
        .filter(|r| r.key.matches(':').count() >= 2)
        .count();
    let mut shown = 0;
    for r in rows {
        let session = r.key.matches(':').count() >= 2;
        if session && shown == limit {
            continue;
        }
        shown += usize::from(session);
        out.push(r);
    }
    // a header whose sessions were all cut goes too
    while out
        .last()
        .is_some_and(|r| r.key.matches(':').count() < 2 && r.key != "h:none" && r.key != "h:past")
    {
        out.pop();
    }
    if sessions > limit {
        out.push(header_row(
            "h:more",
            &format!("  {} more in Show Past Sessions", sessions - limit),
        ));
    }
    out
}

fn all_rows(list: &[PastSession], workspace: Option<&str>, hits: Option<&[PastHit]>) -> Vec<Row> {
    let shown: Vec<(&PastSession, Option<&str>)> = match hits {
        Some(h) => h
            .iter()
            .map(|h| (&h.session, Some(h.snippet.as_str())))
            .collect(),
        None => list.iter().map(|s| (s, None)).collect(),
    };
    if shown.is_empty() {
        let text = if hits.is_some() {
            "  No past session matches"
        } else {
            "  No past sessions of Claude Code, Gemini CLI or Codex"
        };
        return vec![header_row("h:none", text)];
    }
    let (here, other): (Vec<_>, Vec<_>) = shown
        .into_iter()
        .partition(|(s, _)| in_workspace(s.cwd.as_deref(), workspace));
    let mut out = Vec::new();
    if !here.is_empty() {
        out.push(header_row("h:here", "This workspace"));
        out.extend(here.iter().map(|(s, sn)| session_row(s, *sn)));
    }
    if !other.is_empty() {
        out.push(header_row(
            "h:other",
            if here.is_empty() {
                "Past sessions"
            } else {
                "Other projects"
            },
        ));
        out.extend(other.iter().map(|(s, sn)| session_row(s, *sn)));
    }
    out
}

/// A past transcript's rows: the panel's own groups and rows, every step folded as a live session's start.
pub fn transcript_rows(entries: &[Entry]) -> Vec<Row> {
    let all: Vec<(usize, &Entry)> = entries.iter().enumerate().collect();
    let look = rows::Look::default();
    let facts = BTreeMap::new();
    let cx = rows::Cx {
        look: &look,
        facts: &facts,
        always: &|_| false,
        prov: &|_| None,
        right: &|_| 0,
    };
    let mut out = Vec::new();
    for (head, thoughts) in rows::groups(&all) {
        let entry = &entries[head];
        let th: Vec<&Entry> = thoughts.iter().map(|t| &entries[*t]).collect();
        let blocks = (entry.kind == EntryType::Agent).then(|| {
            let mut md = crate::agents::markdown::Stream::default();
            md.update(entry.rest.get("text").and_then(Value::as_str).unwrap_or(""));
            md.blocks().to_vec()
        });
        out.extend(rows::group_rows(head, entry, &th, blocks.as_deref(), &cx));
    }
    out
}

/// A minni entry as the hub's transcript entry (an unknown type is a note).
pub fn entry_of(v: &Value) -> Entry {
    let mut rest = match v {
        Value::Object(m) => m.clone(),
        _ => serde_json::Map::new(),
    };
    let kind = match rest.remove("type").as_ref().and_then(Value::as_str) {
        Some("user") => EntryType::User,
        Some("agent") => EntryType::Agent,
        Some("thought") => EntryType::Thought,
        Some("tool") => EntryType::Tool,
        Some("error") => EntryType::Error,
        Some("compaction") => EntryType::Compaction,
        Some("notice") => EntryType::Notice,
        _ => EntryType::Note,
    };
    Entry { kind, rest }
}

/// The terminal's resume command of PROVIDER's session ID, as argv.
pub fn resume_argv(p: PastProvider, id: &str) -> Vec<String> {
    match p {
        PastProvider::Claude => vec!["claude".into(), "--resume".into(), id.into()],
        PastProvider::Codex => vec!["codex".into(), "resume".into(), id.into()],
        PastProvider::Gemini => vec!["gemini".into(), "--resume".into(), id.into()],
    }
}

// ---- the jail's grant for a resumed session

/// What a resumed session's jail gets of its CLI session file ([`grant`]): that file, its CLI's root, and the route.
#[derive(Clone, Debug, PartialEq)]
pub struct Grant {
    pub provider: Provider,
    pub root: PathBuf,
    pub file: PathBuf,
    pub route: PastRoute,
}

static GRANTS: Mutex<BTreeMap<String, Grant>> = Mutex::new(BTreeMap::new());

/// The grant of drgnx session SID, when it resumes a past session.
pub fn grant(sid: &str) -> Option<Grant> {
    lock(&GRANTS).get(sid).cloned()
}

/// Session SID resumes with G.
pub fn put_grant(sid: &str, g: Grant) {
    lock(&GRANTS).insert(sid.to_owned(), g);
}

/// FILE checked for a grant: a regular file (not a link), still under ROOT once its true name is read.
pub fn checked_file(root: &Path, file: &Path) -> Result<PathBuf, String> {
    let meta = file
        .symlink_metadata()
        .map_err(|e| format!("{}: {e}", file.display()))?;
    if !meta.file_type().is_file() {
        return Err(format!("{} is not a regular file", file.display()));
    }
    let real = file
        .canonicalize()
        .map_err(|e| format!("{}: {e}", file.display()))?;
    let root = root
        .canonicalize()
        .map_err(|e| format!("{}: {e}", root.display()))?;
    if !real.starts_with(&root) || real != file {
        return Err(format!(
            "{} is not under {}",
            file.display(),
            root.display()
        ));
    }
    open_ro(&real).map_err(|e| format!("{}: {e}", real.display()))?;
    Ok(real)
}

// ---- methods

/// The hub's index and roots as the settings have them: `<state>/hub/history.db` and the home's CLIs that
/// `drgnx-agents-history-providers` lists; with `drgnx-agents-history` off the index is deleted and the answer is
/// false.
fn ready(f: &Front) -> Result<bool, Error> {
    let dirs = f
        .dirs
        .get()
        .ok_or_else(|| internal("the store is not open"))?;
    let cur = f.settings.current();
    let v = &cur.loaded.values;
    let db = dirs.hub.join(DB);
    if !v.agents_history {
        f.core.past.off(&db);
        return Ok(false);
    }
    let roots = Roots::of(&dirs.home, |n| std::env::var(n).ok())
        .only(&v.agents_history_providers)
        .within(v.agents_history_days);
    if f.core.past.roots().as_ref() != Some(&roots) {
        f.core.past.configure(db, roots);
    }
    Ok(true)
}

/// The refusal while past sessions are off.
fn off() -> Error {
    err("past sessions are off (drgnx-agents-history)")
}

/// Scan on a blocking thread; the lists shown built again.
pub async fn scan_now(f: &Front) -> Result<u64, Error> {
    if !ready(f)? {
        f.core.past.rebuild_lists(f);
        return Ok(0);
    }
    let me = f.core.past.clone();
    let (n, changed) = crate::clock::blocking(move || me.scan_changed())
        .await
        .map_err(|e| internal(format!("the scan: {e}")))?
        .map_err(internal)?;
    if changed {
        f.core.past.rebuild_lists(f);
    }
    Ok(n)
}

/// The hub keeps the index current: a scan now, then one every few seconds (a scan reads only what changed).
pub async fn follow(f: Arc<Front>) {
    loop {
        if f.dirs.get().is_some() {
            let _ = scan_now(&f).await;
        }
        crate::clock::sleep(std::time::Duration::from_secs(2)).await;
    }
}

pub async fn subscribe(f: &Front, c: &Caller, p: PastSubscribe) -> Result<bool, Error> {
    let on = ready(f)?;
    let view = p.view.0.clone();
    lock(&f.core.past.shown).insert(
        (c.conn_id, view.clone()),
        (
            p.workspace
                .map(|w| w.as_str().trim_end_matches('/').to_owned()),
            p.query.map(|q| q.0),
            p.limit.map(|n| (n as usize).clamp(1, 200)),
        ),
    );
    f.core.past.build_all(f, Some(c.conn_id), &view);
    Ok(on)
}

pub async fn search(f: &Front, _: &Caller, p: PastSearch) -> Result<PastHits, Error> {
    if !ready(f)? {
        return Err(off());
    }
    Ok(PastHits {
        hits: f.core.past.search(&p.query.0).map_err(internal)?,
    })
}

pub async fn open(f: &Front, _: &Caller, p: PastRef) -> Result<PastOpened, Error> {
    if !ready(f)? {
        return Err(off());
    }
    let (session, path) = f.core.past.find(p.provider, &p.id.0).map_err(err)?;
    let provider = provider_of(p.provider);
    let entries = crate::clock::blocking(move || -> Result<Vec<Entry>, String> {
        let mut rd = Reader::new(provider);
        let found = Found {
            provider,
            path: path.clone(),
            size: 0,
            mtime: 0,
        };
        read_into(&mut rd, &found).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(rd.entries().iter().map(entry_of).collect())
    })
    .await
    .map_err(|e| internal(format!("the read: {e}")))?
    .map_err(internal)?;
    let view = format!("{VIEW}{}:{}", provider.name(), session.id);
    {
        let mut open = lock(&f.core.past.open);
        open.retain(|(v, _)| v != &view);
        open.push((view.clone(), Arc::new(entries)));
        if open.len() > OPEN {
            open.remove(0);
        }
    }
    f.core.past.build_all(f, None, &view);
    Ok(PastOpened {
        argv: resume_argv(p.provider, &session.id),
        resume_here: profile_for(f, p.provider).is_some(),
        view,
        session,
    })
}

/// The agent profile a provider's sessions resume on: the first (the user's, then the built-in ones) whose provider
/// it is.
pub fn profile_for(f: &Front, p: PastProvider) -> Option<String> {
    use crate::settings::profiles::Provider as P;
    let want = match p {
        PastProvider::Claude => P::Claude,
        PastProvider::Gemini => P::Gemini,
        PastProvider::Codex => P::Codex,
    };
    let cur = f.settings.current();
    cur.loaded
        .values
        .agents_profiles
        .iter()
        .chain(&crate::settings::defaults().profiles)
        .find(|pr| pr.provider() == Some(want))
        .map(|pr| pr.name.clone())
}

pub async fn rescan(
    f: &Front,
    _: &Caller,
    _: runstav::methods::Empty,
) -> Result<PastScanned, Error> {
    Ok(PastScanned {
        sessions: scan_now(f).await?,
    })
}

/// Whether past sessions are on, how many are indexed, and the CLIs whose files drift from the formats read.
pub async fn status(
    f: &Front,
    _: &Caller,
    _: runstav::methods::Empty,
) -> Result<PastStatus, Error> {
    if !ready(f)? {
        return Ok(PastStatus {
            on: false,
            sessions: 0,
            drift: Vec::new(),
        });
    }
    let me = f.core.past.clone();
    let drift = crate::clock::blocking(move || me.drift())
        .await
        .map_err(|e| internal(format!("the status: {e}")))?
        .map_err(internal)?;
    Ok(PastStatus {
        on: true,
        sessions: lock(&f.core.past.list).len() as u64,
        drift,
    })
}

pub async fn resume(f: &Front, c: &Caller, p: PastResume) -> Result<PastResumed, Error> {
    if !ready(f)? {
        return Err(off());
    }
    let (session, path) = f.core.past.find(p.provider, &p.id.0).map_err(err)?;
    let provider = provider_of(p.provider);
    let roots = f.core.past.roots().unwrap_or_default();
    let root = roots
        .root(provider)
        .ok_or_else(|| err("that CLI's folder is not known"))?
        .to_path_buf();
    let file = checked_file(&root, &path).map_err(err)?;
    let cwd = session
        .cwd
        .clone()
        .ok_or_else(|| err("the session's directory is not known: Resume in terminal"))?;
    let profile = match p.profile {
        Some(b) => b.0,
        None => profile_for(f, p.provider)
            .ok_or_else(|| err("no agent profile for that CLI: Resume in terminal"))?,
    };
    let sid = crate::agents::session::new_sid()?;
    put_grant(
        &sid,
        Grant {
            provider,
            root,
            file,
            route: p.route,
        },
    );
    let start: runstav::methods::agents::StartParams =
        serde_json::from_value(json!({"profile": profile, "cwd": cwd}))
            .map_err(|e| err(format!("the session's start: {e}")))?;
    let (started, _) = crate::agents::session::open_with(
        &f.core.agents,
        f,
        start,
        c,
        None,
        Some(sid.clone()),
        &crate::agents::session::Attach::Resume(session.id.clone()),
    )
    .await
    .inspect_err(|_| {
        lock(&GRANTS).remove(&sid);
    })?;
    Ok(PastResumed {
        session: started.id,
        route: p.route,
    })
}

#[cfg(test)]
mod tests;
