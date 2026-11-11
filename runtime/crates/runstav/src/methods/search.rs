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

/// `search/run`: run SEARCH over ROOT and send its matches to VIEW as rows (the event `view-patch`): a reset at once,
/// then each file's header and matches as it is complete. A newer search of the same view stops this one. The rows
/// preview SEARCH's `replace` (old struck out, new beside it; a regexp search's `\1` are the groups). Text mode with
/// the scopes Project and File (`scope.files`, the one file), so far; Symbol (a name's definitions, then its uses) and
/// Meaning (the chunks a question finds, each with its symbol and score) ask the index, all their files at once, and
/// are read-only: a `replace` is refused.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RunParams {
    /// The hub-fed view that shows the rows (`view/env`).
    pub view: String,
    pub root: AbsPath,
    pub search: SearchSpec,
    /// Default: the setting `drgnx-search-ignore-rules`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ignore: Option<GrepIgnore>,
    /// The match ids of the view's last run the user unticked: a match of this run that is the same match (its file,
    /// columns and the text around it) comes back unticked, named in `search-run-done`'s `off`, when exactly one match
    /// has it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub off: Option<Vec<String>>,
    /// A dim label row above the first match of each definition (the innermost one around it), from one parse of the
    /// file; none at the top level or for a language without definitions. Default true (the setting
    /// `drgnx-search-context`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<bool>,
    /// Only the totals (`search-run-done`): no rows, no model, and the search is not recorded as recent. For a search
    /// the user did not type: a pinned saved search's live count. Default false.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<bool>,
}

/// `search/run`'s answer: RUN numbers the search (its match ids are `m:RUN:N`; the event `search-run-done` names it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RunStarted {
    pub run: u64,
}

/// `search/buffer`: the editor's buffer of PATH holds unsaved edits: VIEW's searches search TEXT in place of the file
/// from now on, and the current one takes its matches at once. A buffer over the editor's large-file threshold sends
/// `large` and no text: the file is searched on disk, its header saying the buffer is open in chunks. Neither: the
/// buffer was saved or killed, and the next search reads the file again.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BufferParams {
    pub view: String,
    pub path: AbsPath,
    /// The buffer's `buffer-chars-modified-tick`.
    #[serde(default)]
    pub tick: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub large: Option<bool>,
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

/// One skipped match: its node id (`m:RUN:N`) and why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrepSkip {
    pub id: String,
    pub why: String,
}

/// What made a change set.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ChangeOrigin {
    ReplaceAll,
    EditResults,
    Undo,
}

/// One edit the caller names itself (the language server's rename, Replace This of Emacs's own rows): its file, its
/// first line (from 1), its character columns (from 0) and the text it expects there (`old`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GivenEdit {
    pub path: AbsPath,
    pub line: u32,
    pub col: u32,
    /// Default: `line`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
    pub end_col: u32,
    pub old: String,
    pub new: String,
}

/// `search/edits`: the edit set of VIEW's search. IDS names the matches to write; without it, every match of the run
/// but those OFF names (the user's unticks). EDITS are edits the caller names itself, in place of the run's matches.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditsParams {
    pub view: String,
    /// The project the given EDITS are in (their files are written only inside it); the run's own root otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub off: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edits: Option<Vec<GivenEdit>>,
    /// The replacement, when the view's fields have one the search has not been told yet (`search/grep-replace`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replace: Option<String>,
    /// Lines of an Edit Results buffer the user changed (`search/edit-doc`), in place of the run's matches; their
    /// files are written only inside the run's root.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<EditedLine>>,
}

/// One line of an Edit Results buffer as the user left it: its id (`l:K`, from `search/edit-doc`), its file, its first
/// line (from 1) and the text it expects there (OLD: several lines once an earlier save split it), and what it becomes
/// (NEW: one string per line; none: the line is deleted). EOL: a newline ends the line in the file (false: the file's
/// last line, which a delete empties).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditedLine {
    pub line_id: String,
    pub path: AbsPath,
    pub line: u32,
    pub old: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new: Option<Vec<String>>,
    #[serde(default = "yes")]
    pub eol: bool,
}

fn yes() -> bool {
    true
}

/// `search/edit-doc`: the lines of VIEW's search for an Edit Results buffer, CONTEXT lines (0 to 3) around each match
/// line; refused (none, OVER) past MAX lines (default 20,000).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditDocParams {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<u32>,
}

/// What an Edit Results line is: a line with a match, or a line of context around one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum EditLineKind {
    Match,
    Context,
}

/// One source line of an Edit Results buffer, once however many matches or context windows name it: its id, its file,
/// its line (from 1), its text (no newline), what it is, and whether a newline ends it in the file.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditLine {
    pub line_id: String,
    pub path: String,
    pub line: u32,
    pub text: String,
    pub kind: EditLineKind,
    pub eol: bool,
}

/// `search/edit-doc`'s answer: the lines by file and line, how many there are, OVER when they are more than the max
/// (then no lines: the user narrows the search), and the files left out with why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditDocAnswer {
    pub lines: Vec<EditLine>,
    pub total: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub over: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<EditSkip>,
}

/// Who a Search view's hand-off goes to: a new worker of PROFILE in a worktree of its own, or the live session ID
/// (a chat, a worker, a paired chat in this checkout).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase", deny_unknown_fields)]
pub enum HandoffTo {
    New { profile: String },
    Session { id: Id },
}

/// `search/handoff`: hand VIEW's matches to an agent with INSTRUCTION: the matches IDS names (else all but OFF), to TO.
/// Paths the index never reads (dot paths, secret-looking names) are left out unless HIDDEN. The handed-off rows show
/// MARK.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HandoffParams {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub off: Option<Vec<String>>,
    pub instruction: Prompt,
    pub to: HandoffTo,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mark: Option<HandoffMark>,
}

/// The mark the handed-off rows show: the agent's colour (a face name) and its glyph (one column), as the editor gives
/// them (the agents' identity scheme).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HandoffMark {
    pub face: String,
    pub glyph: String,
}

/// `search/handoff`'s answer: the hand-off's id, the session it went to (and the worktree of a new worker), the match
/// ids handed off, how many lines the brief holds and how many more `search_results` serves, and the hidden paths
/// left out.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HandoffAnswer {
    pub handoff: String,
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    pub ids: Vec<String>,
    pub sent: u32,
    pub more: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hidden: Vec<String>,
}

/// `search/handoff-state`: where hand-off HANDOFF is.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HandoffStateParams {
    pub handoff: String,
}

/// Where a hand-off is: sent (no edit yet), editing (the agent edits), done (the agent stopped after editing).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum HandoffPhase {
    Sent,
    Editing,
    Done,
}

/// `search-handoff-state` (and `search/handoff-state`'s answer): hand-off HANDOFF of VIEW, to SESSION, at PHASE: the
/// handed-off matches its agent's edits took out (DONE), those still there (LEFT: skipped once it is done), and those
/// whose line moved where it cannot be found again (UNKNOWN, never counted done).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HandoffState {
    pub handoff: String,
    pub view: String,
    pub session: String,
    pub phase: HandoffPhase,
    pub done: Vec<String>,
    pub left: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unknown: Vec<String>,
}

/// One edit of a file: its id (a match's `m:RUN:N`, `e:K` for the K-th given edit), its range
/// as lines (from 1) and character columns (from 0) for the editor and as UTF-8 byte offsets for the hub, the text it
/// expects there and the text it puts in.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchEdit {
    pub id: String,
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
    #[serde(default)]
    pub byte_start: u64,
    #[serde(default)]
    pub byte_end: u64,
    pub old: String,
    pub new: String,
}

/// An edit (or a whole file: no id) left out, and why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditSkip {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub path: String,
    pub why: String,
}

/// Where a file's text came from: its file on disk, or the editor's buffer of it (`search/buffer`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum EditSource {
    Disk,
    Buffer,
}

/// One file of an edit set: its edits in order (none overlap).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FileEdits {
    pub path: String,
    pub source: EditSource,
    pub edits: Vec<SearchEdit>,
}

/// `search/edits`' answer: the change set it made (`search/apply` writes it), its files and what it left out.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditsAnswer {
    pub change: u64,
    pub files: Vec<FileEdits>,
    pub skipped: Vec<EditSkip>,
}

/// `search/apply`: write change set CHANGE (from `search/edits`). OPEN lists the files the asking editor has open:
/// those (and the ones any editor told the hub it has, `pair/open`) are written by their editor (`search-apply`), the
/// rest by the hub on disk. The end is the event `search-change`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ApplyParams {
    pub view: String,
    pub change: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub open: Vec<String>,
}

/// `search/undo`: put back every file change set CHANGE wrote, leaving alone a file edited since; a new change set
/// (origin `undo`), ended by `search-change`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct UndoParams {
    pub view: String,
    pub change: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub open: Vec<String>,
}

/// `search-apply`: the editor that has PATH open writes these edits of change set CHANGE into its buffer, each only
/// where its `old` text is, one undo group, saving unless the buffer held unsaved edits; it answers `search/applied`
/// within `ttl_ms` of the event's arrival, else the hub skips the file. TICK (an undo's) is the buffer's
/// `buffer-chars-modified-tick` after the write it undoes: a buffer edited since is left alone.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchApply {
    pub view: String,
    pub change: u64,
    pub path: String,
    pub edits: Vec<SearchEdit>,
    pub ttl_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tick: Option<u64>,
}

/// `search/applied`: the editor's answer to `search-apply`: the edits it APPLIED and SKIPPED (each with why), the
/// INVERSE edits that put the buffer back (in the buffer's coordinates after the write), its TICK after it, whether it
/// SAVED; NOT_OPEN when no buffer visits PATH any more (the hub then writes the file on disk).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AppliedParams {
    pub change: u64,
    pub path: String,
    #[serde(default)]
    pub applied: Vec<String>,
    #[serde(default)]
    pub skipped: Vec<GrepSkip>,
    #[serde(default)]
    pub inverse: Vec<SearchEdit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tick: Option<u64>,
    #[serde(default)]
    pub saved: bool,
    #[serde(default)]
    pub not_open: bool,
}

/// `search-change`: change set CHANGE (ORIGIN; UNDOES the change set an undo puts back) of VIEW is final: WRITTEN
/// edits in FILES files, the SKIPPED (each with why), and LEFT the files an undo left alone (edited since).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ChangeDone {
    pub view: String,
    pub change: u64,
    pub origin: ChangeOrigin,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undoes: Option<u64>,
    pub written: u64,
    pub files: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<EditSkip>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub left: Vec<String>,
}

/// `search/preview`: one file's changes of VIEW's search as a diff (the Search view's preview tile). The matches as
/// `search/edits` takes them (all but `off`; `replace` when the fields have one the run was not told yet), of PATH only.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PreviewParams {
    pub view: String,
    pub path: AbsPath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub off: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replace: Option<String>,
}

/// A regexp match's groups (`\1` …, at most 8, each at most 200 characters): `None` for one that matched nothing.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MatchGroups {
    pub id: String,
    pub groups: Vec<Option<String>>,
}

/// One hunk of a preview: its ranges (lines from 1, as the diff's `@@` line), the ids of the matches in it and, for a
/// regexp search, their groups.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PreviewHunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub captures: Vec<MatchGroups>,
    /// The definition the hunk's first match is in, as the Search view's context label shows it (`ƒ name`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// The lines (the old file's) of the unticked matches inside the hunk: they stay as they are.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kept: Vec<u32>,
}

/// `search/preview`'s answer: the file's unified diff (3 lines of context), its lines added and removed, the hunks in
/// the diff's order and the matches skipped, each with why (an empty diff: none of its matches would be written).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PreviewAnswer {
    pub path: String,
    pub diff: String,
    pub plus: u32,
    pub minus: u32,
    pub hunks: Vec<PreviewHunk>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<EditSkip>,
}

/// `search/grep-look`: VIEW's rows of its search go on. A search sends a view its first 200 rows (a file's header and
/// its matches, in order), and the totals in `search-run-done`; the hub keeps every match, and Sjá's model holds them.
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
    /// The key of a row to reach (`f:FILE`, `m:RUN:N`); over `more`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upto: Option<String>,
    /// The rows before the gap row, one window more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<bool>,
}

/// `search-run-done`: search RUN of VIEW ended with FILES files holding MATCHES matches; ERROR is why it could not
/// run; OFF the matches that come back unticked (`search/run`'s `off`); SCOPE what a git scope searched. A search a
/// newer one stopped says nothing.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RunDone {
    pub view: String,
    pub run: u64,
    pub files: u64,
    pub matches: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub off: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<ScopeDone>,
}

/// What a git scope (Changed, Staged, Branch) searched: FILES files of the repository (before the globs), the
/// SUBMODULES and DELETED files it skipped, Branch's BASE, why it is empty (WHY_EMPTY), or why Branch has no base to
/// take (NEEDS_BASE: the view asks, `search/scope-bases`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScopeDone {
    pub files: u64,
    #[serde(default)]
    pub submodules: u64,
    #[serde(default)]
    pub deleted: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why_empty: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs_base: Option<String>,
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
    /// A level's indent on a graphical display, in logical px (the density's `tree-indent`); default 12.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub indent: Option<u32>,
    /// Names never listed, at most 256: exact names or globs (`*` any run, `?` one character); default `.git`,
    /// `.hg`, `.svn`, `.DS_Store`, `__pycache__` and `.#*`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude: Option<Vec<String>>,
    /// Find: list only these files (at most 5000) under the roots, each with the folders above it open; nothing is
    /// read from disk and nothing watched.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub only: Option<Vec<AbsPath>>,
    /// How many entries the model and the rows hold, 50 to 20000 (what the editor shows and a margin; `view/window`
    /// moves it); default 20000.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<u32>,
    /// An entry the window must hold once listed (a reveal): when it falls outside, the window moves to hold it a
    /// quarter of the way down.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub around: Option<AbsPath>,
}

/// `explorer/subscribe`'s answer: LISTING numbers the listing.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExplorerStarted {
    pub listing: u64,
}

/// What the Search view's Find means: the mode and what was typed, with the mode's toggles.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(tag = "mode", rename_all = "lowercase", deny_unknown_fields)]
pub enum FindQuery {
    /// Text or a regular expression (`hrafn::grep`).
    Text {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        case: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        word: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        regexp: Option<bool>,
    },
    /// Definitions and uses of a name, from the index (by name only).
    Symbol {
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        case: Option<bool>,
    },
    /// A question about what the code does (Hrafn's hybrid query).
    Meaning { question: String },
}

impl FindQuery {
    /// What was typed: the text, the name or the question.
    pub fn typed(&self) -> &str {
        match self {
            FindQuery::Text { text, .. } => text,
            FindQuery::Symbol { name, .. } => name,
            FindQuery::Meaning { question } => question,
        }
    }
}

/// Which files a search looks in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ScopeKind {
    /// The root, the ignore rules as set.
    Project,
    /// One file: the view's origin buffer.
    File,
    /// The files normal buffers visit under the root.
    Open,
    /// The working tree's modified, added and untracked files.
    Changed,
    /// The files whose index entry differs from HEAD (their working-tree text is searched).
    Staged,
    /// The files changed since the merge base of HEAD and BASE, and the working tree's changes.
    Branch,
}

/// A search's scope: its kind, Branch's base (none: the upstream, else `main`, else `master`), whether only matches
/// in changed lines count (Changed, Staged, Branch), and the files of File and Open (the editor's state, never saved).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchScope {
    pub kind: ScopeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed_lines: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<Vec<AbsPath>>,
}

/// A search as the user made it: what recent and saved searches keep, and what a click runs again.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SearchSpec {
    pub query: FindQuery,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<SearchScope>,
    /// Globs; each string may hold several, comma-separated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub include: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude: Option<Vec<String>>,
}

/// One saved search: its NAME, the search, whether it is PINNED to the view's header (a live count), whether it comes
/// from the project's `.drgnx/searches.eld` (PROJECT: read-only here) and whether the user shared it there (SHARED).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SavedSearch {
    pub name: String,
    pub search: SearchSpec,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub project: bool,
    #[serde(default)]
    pub shared: bool,
}

/// `search/recent`'s answer: ROOT's recent searches, newest first (at most 50).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecentAnswer {
    pub recent: Vec<SearchSpec>,
}

/// `search/saved/list`'s answer: the hub's saved searches of ROOT, then the project's; PROBLEMS names each form of
/// `.drgnx/searches.eld` that was refused, and why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SavedList {
    pub saved: Vec<SavedSearch>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub problems: Vec<String>,
}

/// `search/saved/put`: save SEARCH under NAME in ROOT (a search of that name is replaced).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SavedPutParams {
    pub root: AbsPath,
    pub name: String,
    pub search: SearchSpec,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
}

/// `search/saved/delete` and `search/saved/share`: ROOT's saved search NAME.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SavedNameParams {
    pub root: AbsPath,
    pub name: String,
}

/// `search/saved/share`'s answer: the file it was written to.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SavedShared {
    pub path: AbsPath,
}

/// `search/scope-bases`'s answer: the Branch scope's menu. CURRENT is the branch (none: detached or unborn),
/// UPSTREAM its upstream, DEFAULT the base Branch uses when none is chosen (none: it must ask), RECENT the branches
/// most recently committed to.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScopeBases {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    pub recent: Vec<String>,
    pub detached: bool,
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
            "search/run", SearchRun(RunParams) -> RunStarted,
            classes: [User], writes: false,
            doc: "run the Search view's search over a folder and stream the matches to a hub-fed view as rows (view-patch: a reset, then each file's header and matches; ids m:RUN:N), ending with search-run-done; a newer search of the view stops the old one, and the matches the user unticked in it stay unticked when found again",
        ),
        method!(
            "search/buffer", SearchBuffer(BufferParams) -> bool,
            classes: [User], writes: false,
            doc: "an editor buffer with unsaved edits: the Search view's searches search its text in place of its file (the current search at once), or say the buffer is too large and is searched on disk; without text or large the file is searched again",
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
            "search/edit-doc", SearchEditDoc(EditDocParams) -> EditDocAnswer,
            classes: [User], writes: false,
            doc: "the lines of a view's search for an Edit Results buffer: each source line once (a match's, or context around one), with its id, file, line number and text; none past the max (over), files that cannot be written skipped with why",
        ),
        method!(
            "search/edits", SearchEdits(EditsParams) -> EditsAnswer,
            classes: [User], writes: false,
            doc: "the edit set of a view's search (its ticked matches, the ids named, edits the caller names, or the changed lines of an Edit Results buffer): per file the edits with lines, character columns, byte ranges, old and new text; overlapping matches, files changed since the search, large and binary files skipped with why; kept as a change set for search/apply",
        ),
        method!(
            "search/handoff", SearchHandoff(HandoffParams) -> HandoffAnswer,
            classes: [User], writes: true,
            doc: "hand a view's ticked matches to an agent: a brief (the instruction, the query, the matches grouped by file, at most 300 lines, the rest through the drgnx-search tool search_results) to a new worker in its own worktree or to a live session; hidden paths left out unless asked; its progress is search-handoff-state",
        ),
        method!(
            "search/handoff-state", SearchHandoffState(HandoffStateParams) -> HandoffState,
            classes: [User], writes: false,
            doc: "where a hand-off is: sent, editing or done, and which of its matches the agent's edits took out, which are still there and which cannot be found again",
        ),
        method!(
            "search/preview", SearchPreview(PreviewParams) -> PreviewAnswer,
            classes: [User], writes: false,
            doc: "one file's changes of a view's search as a unified diff: lines added and removed, the hunks with their matches' ids and a regexp's groups, the matches skipped with why",
        ),
        method!(
            "search/apply", SearchApply(ApplyParams) -> bool,
            classes: [User], writes: true,
            doc: "write a change set from search/edits, one file at a time in the hub's write queue (shared with pair writes): a file an editor has open by that editor (search-apply), any other on disk atomically over a check that it is as the edit set read it; ends with search-change",
        ),
        method!(
            "search/applied", SearchApplied(AppliedParams) -> bool,
            classes: [User], writes: false,
            doc: "the editor's answer to search-apply: the edits applied and skipped, their inverse, the buffer's tick and whether it saved; true when the hub was waiting for it",
        ),
        method!(
            "search/undo", SearchUndo(UndoParams) -> bool,
            classes: [User], writes: true,
            doc: "put back every file a change set wrote (the hub keeps the last 20, open files' inverse edits included), leaving alone a file edited since; ends with search-change",
        ),
        method!(
            "search/grep-look", SearchGrepLook(GrepLookParams) -> bool,
            classes: [User], writes: false,
            doc: "a view's grep rows go on: one more window of rows (more), or the rows up to a match beyond them and a margin (upto); false when the view has no search; a search sends only its first 200 rows until asked",
        ),
        method!(
            "search/recent", SearchRecent(RootParams) -> RecentAnswer,
            classes: [User], writes: false,
            doc: "a project's recent searches, newest first (the last 50): each search that stood past the typing pause and was not empty, with its mode, toggles, replacement, scope and globs",
        ),
        method!(
            "search/saved/list", SearchSavedList(RootParams) -> SavedList,
            classes: [User], writes: false,
            doc: "a project's saved searches: the hub's, then the project's .drgnx/searches.eld (read as data only, nothing evaluated; a refused form is named in problems)",
        ),
        method!(
            "search/saved/put", SearchSavedPut(SavedPutParams) -> bool,
            classes: [User], writes: true,
            doc: "save a search under a name for a project (the hub's state, not the project's files); a search of that name is replaced",
        ),
        method!(
            "search/saved/delete", SearchSavedDelete(SavedNameParams) -> bool,
            classes: [User], writes: true,
            doc: "delete a project's saved search from the hub's state; false when there is none of that name",
        ),
        method!(
            "search/saved/share", SearchSavedShare(SavedNameParams) -> SavedShared,
            classes: [User], writes: true,
            doc: "write a saved search into the project's .drgnx/searches.eld (atomically: a temporary file, then a rename; the rest of the file kept as it was), on the user's click",
        ),
        method!(
            "search/scope-bases", SearchScopeBases(RootParams) -> ScopeBases,
            classes: [User], writes: false,
            doc: "the Branch scope's menu for a folder's repository: the current branch, its upstream, the default base, the recent branches, and whether HEAD is detached",
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
