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
