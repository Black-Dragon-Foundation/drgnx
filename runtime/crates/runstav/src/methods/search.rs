//! Hrafn's methods (code search; docs/develop/runtime.md, "Hrafn"): the query, the index and its status, the embedders
//! the wizard and the doctor show, the consented model download, and the typing signal that holds the vectors back.
//!
//! All are the user's: they take the caller's `root`. An agent has no search method; its way in is the MCP search
//! tools (`search`, `symbols`, `outline`, `repo_map`, `find_usages`) on its session's `search.sock`, pinned to its job's root (runtime design §5.8).

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AbsPath, Id, Prompt};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Which files a query looks in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    /// Code, and tests below it.
    Code,
    Tests,
    Docs,
    All,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct QueryParams {
    /// The project's root: any checkout of it.
    pub root: AbsPath,
    pub text: Prompt,
    /// Default `code`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    /// How many hits, 1 to 100; default 10.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub k: Option<u32>,
    /// True: answer from the base (the main checkout's rows) even when `root` is a linked worktree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<bool>,
}

/// Which view answered: the base, or a linked worktree's rows over it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct QueryView {
    /// The worktree's key (history's worktree id); absent in the base view.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    /// The paths where the worktree differs from the base (tombstones too); 0 in the base view.
    pub differing_files: u32,
    /// `base`; or the tree's `seeding` (the base answered meanwhile), `live`, `stale` or `unwatched` (the stored rows
    /// answered and a check runs).
    pub state: String,
}

/// One hit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Hit {
    pub path: String,
    pub line_start: u32,
    pub line_end: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    pub score: f64,
    pub preview: String,
    /// The routes that found it: `symbol`, `name`, `path`, `keyword`, `vector`.
    pub routes: Vec<String>,
    /// Its lines were found again in the file as it is now.
    pub reanchored: bool,
}

/// How far behind the vectors are.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Lag {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub chunks_total: u32,
    pub chunks_behind: u32,
    pub files_behind: u32,
    pub dirty_files: u32,
    pub built_from: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct QueryAnswer {
    pub hits: Vec<Hit>,
    pub lag: Lag,
    /// The model whose vectors took part; none when the answer is keyword, symbol and path results only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Why there are no vectors, or what else the reader should know.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
    /// The line that ends a text answer, e.g. "vectors: 12 files behind (…); keyword and symbol results are current".
    pub lag_line: String,
    pub view: QueryView,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RootParams {
    pub root: AbsPath,
}

/// Files and chunks of one class.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ClassCount {
    pub class: String,
    pub files: u64,
    pub chunks: u64,
}

/// The device the built-in worker runs on, as it said first.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Device {
    /// `gpu` or `cpu`.
    pub kind: String,
    pub name: String,
    pub why: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WorkerStatus {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<Device>,
    /// Set when a lost GPU sent the work to the CPU path: the reason.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<String>,
    pub spawns: u32,
    pub crashes: u32,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StatusAnswer {
    pub files: u64,
    pub chunks: u64,
    pub per_class: Vec<ClassCount>,
    /// Classes with listed files and no chunks, and non-empty files with none (storage design §12A.3 item 9).
    pub coverage_errors: Vec<String>,
    pub lag: Lag,
    /// Models that have vectors here: the model, and how many.
    pub models: Vec<ModelCount>,
    pub worker: WorkerStatus,
    /// `stopped`, `idle`, `running`, `typing`, `battery` or `failed`.
    pub tier2: String,
    /// Vectors tier 2 wrote since the hub opened the project.
    pub embedded: u64,
    /// The project's worktree overlays.
    pub trees: Vec<TreeInfo>,
    pub watch: SearchWatch,
}

/// One worktree overlay.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TreeInfo {
    /// History's worktree id.
    pub worktree: String,
    pub root: String,
    /// `seeding`, `live`, `stale` or `unwatched`.
    pub state: String,
    /// The git door: `cli`, or `gix` for a tree an agent's sandbox touched.
    pub door: String,
    pub differing_files: u32,
    /// Whether the project's watcher serves it (else a query checks it, at most every 5 s).
    pub watched: bool,
}

/// The project's file watches.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchWatch {
    /// Directories under watch.
    pub used: u64,
    /// What Hrafn allows itself: half of `limit`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<u64>,
    /// `fs.inotify.max_user_watches`, where there is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u64>,
    /// Trees that run unwatched.
    pub unwatched: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ModelCount {
    pub model: String,
    pub vectors: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct IndexParams {
    pub root: AbsPath,
    /// Drop the index and build it again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rebuild: Option<bool>,
    /// Overrides the battery gate: tier 2 runs until nothing is missing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub now: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Started {
    pub started: bool,
}

/// The built-in model.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BuiltinInfo {
    pub model: String,
    /// `missing`, `partial`, `downloading`, `ready` or `corrupt`.
    pub state: String,
    /// What the download is, in bytes.
    pub bytes: u64,
    /// Bytes held (all of them when ready).
    pub downloaded: u64,
    /// Why the last download failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<Device>,
}

/// A server that can embed (the `tei` and `ollama` providers).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ServerInfo {
    pub kind: String,
    pub url: String,
    pub model: String,
    pub answering: bool,
    /// The address family that answered the probe: `ipv4` or `ipv6`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EmbeddersAnswer {
    pub builtin: BuiltinInfo,
    pub servers: Vec<ServerInfo>,
    /// The model a query uses when every project is fully indexed: a server that answers, else the built-in model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefer: Option<String>,
}

/// The user agreed to the download of this size.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConsentParam {
    pub bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct DownloadParams {
    pub model: Id,
    pub consent: ConsentParam,
}

/// A server the wizard can start on request.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ServerKind {
    Tei,
    Ollama,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ServerKindParams {
    pub kind: ServerKind,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ServerStartParams {
    pub kind: ServerKind,
    /// The user agreed to what `search/server-plan` showed; a start without it is refused.
    pub confirm: bool,
}

/// What a start would do, shown before the user agrees. A plan runs and writes nothing.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ServerPlan {
    pub available: bool,
    /// Why not, when it is not available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    /// The GPU image would run.
    pub gpu: bool,
    /// The memory cap of the container (TEI) as podman writes it, e.g. `4g`; empty for Ollama.
    pub memory_cap: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    pub model: String,
    /// About what the model weighs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    /// The Quadlet file a start writes (TEI).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_path: Option<String>,
    /// The commands a start runs, in order.
    pub commands: Vec<String>,
}

/// An entry for the settings' provider table; the editor's settings writer adds it, the hub never does.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProviderEntry {
    pub id: String,
    pub kind: String,
    pub base: String,
    pub auth: String,
    pub caps: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ServerStarted {
    pub started: bool,
    /// The service that runs it.
    pub unit: String,
    pub provider: ProviderEntry,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ServerStopped {
    pub stopped: bool,
}

/// Which files a text search and the ranked file query look in (the setting `drgnx-search-ignore-rules`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum GrepIgnore {
    /// The index's filters: no dot paths, no secret-looking names.
    Index,
    /// Only what `.gitignore` files and the globs name.
    Real,
}

/// `search/grep`: search ROOT's files for TEXT and send the matches to VIEW as rows (the event `view-patch`): a reset
/// at once, then each file's header and matches as it is complete. A newer search of the same view stops this one.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepParams {
    /// The hub-fed view that shows the rows (`view/env`).
    pub view: String,
    pub root: AbsPath,
    pub text: String,
    /// Search this one file only (globs then do not apply).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<AbsPath>,
    /// Match case; default off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub case: Option<bool>,
    /// Whole words only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word: Option<bool>,
    /// TEXT is a regular expression.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub regexp: Option<bool>,
    /// Globs; each string may hold several, comma-separated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub include: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude: Option<Vec<String>>,
    /// Default: the setting `drgnx-search-ignore-rules`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignore: Option<GrepIgnore>,
    /// The replacement the rows preview (old struck out, new beside it); a regexp search's `\1` are the groups.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replace: Option<String>,
}

/// `search/grep`'s answer: QUERY numbers the search (the event `search-grep-done` names it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepStarted {
    pub query: u64,
}

/// `search/grep-replace`: VIEW's rows preview REPLACE now (no new search).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepReplaceParams {
    pub view: String,
    pub replace: String,
}

/// `search/grep-skipped`: VIEW's search lists only the matches Replace All skipped, each with why (after the
/// match's text); the rest go and the search stops.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepSkippedParams {
    pub view: String,
    pub skipped: Vec<GrepSkip>,
}

/// One skipped match: its node id (`m:FILE:LINE:COL`) and why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepSkip {
    pub id: String,
    pub why: String,
}

/// `search/grep-look`: VIEW's rows of its search go on. A search sends a view its first 200 rows (a file's header and
/// its matches, in order), and the totals in `search-grep-done`; the hub keeps every match, and Sjá's model holds them.
/// The editor asks for more when its window nears the end of the rows (`more`), or when it goes to a match beyond them
/// (`upto`: the row's key, and 100 rows after it come too). A match more than 400 rows past the rows sent comes with
/// the 100 rows before it too, after a gap row (key `gap`); `fill` (the gap row in sight) sends the 200 rows before
/// it, and the gap row goes when they meet the rows after it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepLookParams {
    pub view: String,
    /// One more window (200 rows).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub more: Option<bool>,
    /// The key of a row to reach (`f:FILE`, `m:FILE:LINE:COL`); over `more`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upto: Option<String>,
    /// The rows before the gap row, one window more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<bool>,
}

/// `search-grep-done`: search QUERY of VIEW ended with FILES files holding MATCHES matches; ERROR is why it could not
/// run. A search a newer one stopped says nothing.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepDone {
    pub view: String,
    pub query: u64,
    pub files: u64,
    pub matches: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// `search/files`: rank ROOT's file names for QUERY and send VIEW the N best as rows (the event `view-patch`), one row
/// per file, keyed by its path relative to ROOT, the query's words marked. A repository's names are what git lists
/// (nothing is read), elsewhere a walk that follows no link and applies `.gitignore` files; binary, large and linked
/// files are listed. A newer query of the same view stops this one, and its rows are never sent.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FilesParams {
    /// The hub-fed view that shows the rows (`view/env`).
    pub view: String,
    pub root: AbsPath,
    /// Words, each of which a path must hold (case-insensitive); empty: every file.
    pub query: String,
    /// How many rows, 1 to 1000; default 100.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<u32>,
    /// Default: the setting `drgnx-search-ignore-rules`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignore: Option<GrepIgnore>,
}

/// `search/symbol-at`: the name of the innermost symbol that FILE (relative to ROOT, read from disk) defines around
/// LINE, from Hrafn's outline of it; what the editor's agent line shows for a buffer that is saved.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SymbolAtParams {
    pub root: AbsPath,
    /// Relative to ROOT, inside it.
    pub file: String,
    /// From 1.
    pub line: u32,
}

/// `search/symbol-at`'s answer: NAME is absent when no symbol holds the line (or the file is not read: missing, larger
/// than 2 MB).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SymbolAt {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// How `search/symbols` matches a name.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum NameMatch {
    /// Exact, else prefix, else contains; the answer says which matched.
    Auto,
    /// Equal, case and all.
    Exact,
    /// Starts with it, ignoring case.
    Prefix,
    /// Holds it, ignoring case.
    Contains,
    /// A regular expression (Rust's `regex` syntax) over the names.
    Regex,
}

/// `search/symbols`: where names are defined, in ROOT's view.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SymbolsParams {
    pub root: AbsPath,
    /// A name, a prefix, part of a name or a regular expression, 1 to 200 characters.
    pub name: String,
    /// Default `auto`.
    #[serde(default, rename = "match", skip_serializing_if = "Option::is_none")]
    pub mode: Option<NameMatch>,
    /// Only these kinds (`function`, `method`, `struct`, `class`, `macro`, `variable`, …), at most 12.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<Vec<String>>,
    /// Only files this glob (relative to ROOT) matches.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// Default `all`; tests are listed after code.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    /// 1 to 100; default 20.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub k: Option<u32>,
    /// True: the base's rows even when ROOT is a linked worktree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<bool>,
}

/// One definition.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SymbolHit {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub line_start: u32,
    pub line_end: u32,
    /// The definition's head (its lines up to the one that names it, before a `{`).
    pub sig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doc1: Option<String>,
    /// The definition around it in the same file (a method's impl or class).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    /// `code`, `test` or `docs`.
    pub class: String,
}

/// How current a structural answer is: the files tier 1 has still to index, and the view that answered.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Fresh {
    pub files_pending: u32,
    pub view: QueryView,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SymbolsAnswer {
    /// The match that answered (never `auto`).
    pub matched: NameMatch,
    pub symbols: Vec<SymbolHit>,
    pub fresh: Fresh,
}

/// `search/outline`: one file's definitions, in ROOT's view.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineParams {
    pub root: AbsPath,
    /// Relative to ROOT, inside it.
    pub path: String,
    /// Each definition's first doc line; default true.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docs: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<bool>,
}

/// One definition of an outline; DEPTH counts the definitions around it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineEntry {
    pub name: String,
    pub kind: String,
    pub line_start: u32,
    pub line_end: u32,
    pub sig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doc1: Option<String>,
    pub depth: u32,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OutlineAnswer {
    pub path: String,
    /// The language the index parsed it as (`rust`, `elisp`, `text`, …).
    pub lang: String,
    pub entries: Vec<OutlineEntry>,
    pub fresh: Fresh,
}

/// What a repo map ranks: code only, or tests and docs too.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum MapScope {
    Code,
    All,
}

/// `search/map`: the most-referenced definitions of ROOT's view, cut to a token budget.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapParams {
    pub root: AbsPath,
    /// Tokens the map may take (an estimate: characters ÷ 4), 256 to 32,000; default 2,000.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget: Option<u32>,
    /// Files to centre on, relative to ROOT and inside it, at most 50; they are left out of the listing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus: Option<Vec<String>>,
    /// Identifiers whose definitions rank higher, at most 50.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub names: Option<Vec<String>>,
    /// Default `code`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<MapScope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<bool>,
}

/// One file of a map: its rank and the definitions shown.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapFile {
    pub path: String,
    pub rank: f64,
    pub defs: Vec<OutlineEntry>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapAnswer {
    /// The map as the agent reads it; its last line gives the counts and the estimate.
    pub text: String,
    pub files: Vec<MapFile>,
    /// The estimate of `text` (characters ÷ 4).
    pub tokens: u32,
    /// The files ranked.
    pub files_total: u32,
    pub fresh: Fresh,
}

/// `search/usages`: where a name is used in ROOT's view, by name only.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct UsagesParams {
    pub root: AbsPath,
    /// 1 to 200 characters.
    pub name: String,
    /// Default `all`; tests are ranked after code.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    /// 1 to 100; default 20.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub k: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<bool>,
}

/// One file's use of the name.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Usage {
    pub path: String,
    /// The first line it is used on.
    pub line: u32,
    /// The first lines it is used on, at most 8.
    pub lines: Vec<u32>,
    /// How often the file uses it.
    pub n: u32,
    /// The innermost definition holding `line`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enclosing: Option<String>,
    pub rank: f64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct UsagesAnswer {
    /// Where the name is defined (exact).
    pub defined: Vec<SymbolHit>,
    pub usages: Vec<Usage>,
    pub fresh: Fresh,
}

/// `search/files`'s answer: QUERY numbers the query.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FilesStarted {
    pub query: u64,
}

/// `explorer/subscribe`: list ROOTS, and inside them the folders of EXPANDED, for the Explorer's hub-fed VIEW: its
/// model (a `tree` of path nodes, a folder open when it is a root or in EXPANDED) and its rows (one per entry, guides
/// and chevron, the path over the row) go to every class of VIEW. Folders come first, then names in natural,
/// case-insensitive order; the names a version-control folder, `.DS_Store`, `__pycache__` and `.#…` locks never show.
/// An open folder whose only entry is a folder shares its row with it (`src/app`) unless COMPACT is false. A newer
/// subscription of the same view stops this one; ask again with the new EXPANDED to open or close a folder.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExplorerParams {
    /// The hub-fed view that shows the rows (`view/env`).
    pub view: String,
    /// The roots, 1 to 16 existing folders.
    pub roots: Vec<AbsPath>,
    /// The open folders under the roots (no trailing slash), at most 10000.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub expanded: Vec<AbsPath>,
    /// Join single-folder chains on one row; default on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compact: Option<bool>,
}

/// `explorer/subscribe`'s answer: LISTING numbers the listing.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExplorerStarted {
    pub listing: u64,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "search/query", SearchQuery(QueryParams) -> QueryAnswer,
            classes: [User], writes: false,
            doc: "hybrid keyword, symbol, path and vector results for a question about a project's code; every answer says which model took part and what lags",
        ),
        method!(
            "search/status", SearchStatus(RootParams) -> StatusAnswer,
            classes: [User], writes: false,
            doc: "a project's index: files and chunks per class, coverage errors, the lag, the models that have vectors, tier 2's state and the embed worker's device",
        ),
        method!(
            "search/index", SearchIndex(IndexParams) -> Started,
            classes: [User], writes: true,
            doc: "start or rebuild a project's index; now overrides the battery gate",
        ),
        method!(
            "search/embedders", SearchEmbedders(Empty) -> EmbeddersAnswer,
            classes: [User], writes: false,
            doc: "the built-in model's state and device, the servers that can embed and which answer, and the model a query prefers",
        ),
        method!(
            "search/model-download", SearchModelDownload(DownloadParams) -> Started,
            classes: [User], writes: true,
            doc: "download the built-in model after the user agreed to its size; nothing downloads without this consent",
        ),
        method!(
            "search/grep", SearchGrep(GrepParams) -> GrepStarted,
            classes: [User], writes: false,
            doc: "search a folder's files for text and stream the matches to a hub-fed view as rows (view-patch: a reset, then each file's header and matches), ending with search-grep-done; a newer search of the view stops the old one",
        ),
        method!(
            "search/files", SearchFiles(FilesParams) -> FilesStarted,
            classes: [User], writes: false,
            doc: "rank a folder's file names for a query and send a hub-fed view the best as rows (view-patch); git's list in a repository, a walk that follows no link elsewhere; a newer query of the view stops the old one",
        ),
        method!(
            "search/symbol-at", SearchSymbolAt(SymbolAtParams) -> SymbolAt,
            classes: [User], writes: false,
            doc: "the name of the innermost symbol a file (read from disk) defines around a line, from Hrafn's outline; none outside every symbol",
        ),
        method!(
            "search/symbols", SearchSymbols(SymbolsParams) -> SymbolsAnswer,
            classes: [User], writes: false,
            doc: "where names are defined in a project's view (exact, prefix, contains or a regular expression), from the index alone: lines, signature, first doc line, the definition around it; code before tests",
        ),
        method!(
            "search/outline", SearchOutline(OutlineParams) -> OutlineAnswer,
            classes: [User], writes: false,
            doc: "one indexed file's definitions in file order with their lines, signatures and nesting, from the index alone; an error for a file the view does not index",
        ),
        method!(
            "search/map", SearchMap(MapParams) -> MapAnswer,
            classes: [User], writes: false,
            doc: "a map of a project's view for a first look: the most-referenced definitions (signatures and lines) ranked by PageRank over the files' references, optionally centred on focus files and names, cut to a token budget (an estimate)",
        ),
        method!(
            "search/usages", SearchUsages(UsagesParams) -> UsagesAnswer,
            classes: [User], writes: false,
            doc: "where a name is used in a project's view, by name only (no type resolution): the files and first lines, under the definition that uses it, ranked by the using file; its definitions first",
        ),
        method!(
            "search/grep-replace", SearchGrepReplace(GrepReplaceParams) -> bool,
            classes: [User], writes: false,
            doc: "the replacement a view's grep rows preview changed: the rows are patched, nothing is searched again; false when the view has no search",
        ),
        method!(
            "search/grep-skipped", SearchGrepSkipped(GrepSkippedParams) -> bool,
            classes: [User], writes: false,
            doc: "a view's grep rows after Replace All: only the matches it skipped, each with why; the search stops; false when the view has no search",
        ),
        method!(
            "search/grep-look", SearchGrepLook(GrepLookParams) -> bool,
            classes: [User], writes: false,
            doc: "a view's grep rows go on: one more window of rows (more), or the rows up to a match beyond them and a margin (upto); false when the view has no search; a search sends only its first 200 rows until asked",
        ),
        method!(
            "explorer/subscribe", ExplorerSubscribe(ExplorerParams) -> ExplorerStarted,
            classes: [User], writes: false,
            doc: "list the Explorer's roots and open folders for a hub-fed view on a thread: its tree model (view-model) and its rows (view-patch) to every class; ask again with the new open folders to expand or collapse; a newer listing of the view stops the old one",
        ),
        method!(
            "search/typing", SearchTyping(Empty) -> Empty,
            classes: [User], writes: false,
            doc: "the editor's keystroke signal: the vectors wait between requests while typing holds",
        ),
        method!(
            "search/server-plan", SearchServerPlan(ServerKindParams) -> ServerPlan,
            classes: [User], writes: false,
            doc: "what starting TEI or Ollama would run, shown before the user agrees; runs and writes nothing",
        ),
        method!(
            "search/server-start", SearchServerStart(ServerStartParams) -> ServerStarted,
            classes: [User], writes: false,
            doc: "start TEI (a capped podman Quadlet) or Ollama after the user confirmed the plan; the hub never starts one by itself",
        ),
        method!(
            "search/server-stop", SearchServerStop(ServerKindParams) -> ServerStopped,
            classes: [User], writes: false,
            doc: "stop the server a start began",
        ),
    ]
}
