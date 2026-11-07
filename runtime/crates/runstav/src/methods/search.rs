//! Hrafn's methods (code search; docs/develop/runtime.md, "Hrafn"): the query, the index and its status, the embedders
//! the wizard and the doctor show, the consented model download, and the typing signal that holds the vectors back.
//!
//! All are the user's: they take the caller's `root`. An agent has no search method; its way in is the MCP `search`
//! tool on its session's `search.sock`, pinned to its job's root (runtime design §5.8).

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

/// `search/files`'s answer: QUERY numbers the query.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FilesStarted {
    pub query: u64,
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
            "search/grep-replace", SearchGrepReplace(GrepReplaceParams) -> bool,
            classes: [User], writes: false,
            doc: "the replacement a view's grep rows preview changed: the rows are patched, nothing is searched again; false when the view has no search",
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
