//! Other agent CLIs' past sessions (Claude Code, Gemini CLI, Codex): listed, searched, opened read-only as transcripts
//! and resumed (`docs/guide/agents.md`, "Past sessions").  The hub reads the CLIs' own files read-only and indexes
//! them in `history.db`; these methods are the user's alone, and no agent tool reaches them.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The CLI that wrote a session.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "kebab-case")]
pub enum PastProvider {
    Claude,
    Gemini,
    Codex,
}

/// One past session as its row shows it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastSession {
    pub provider: PastProvider,
    /// The CLI's own session id (what its resume command takes).
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated: Option<String>,
    pub turns: u64,
    /// A drgnx session resumed from it, when one runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live: Option<String>,
}

/// `agents/history/subscribe`: the caller's VIEW shows the past sessions as rows, the workspace's first, narrowed by
/// QUERY (titles and the whole transcripts' text).  With LIMIT the rows are a section of another list (the Agents
/// list's): a header, at most LIMIT sessions, and a last row that says how many more Past Sessions shows.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PastSubscribe {
    pub view: Bounded<String, 256>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<Bounded<String, 512>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PastSearch {
    pub query: Bounded<String, 512>,
}

/// One search hit: its session and a piece of the text that matched.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastHit {
    pub session: PastSession,
    pub snippet: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastHits {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub hits: Vec<PastHit>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PastRef {
    pub provider: PastProvider,
    pub id: Bounded<String, 256>,
}

/// `agents/history/open`'s answer: the view that shows the transcript (`agent-history/PROVIDER:ID`) and the session.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastOpened {
    pub view: String,
    pub session: PastSession,
    /// The command that resumes it in a terminal, as argv (never a shell string), run in the session's cwd.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub argv: Vec<String>,
    /// Whether Resume here can run: an agent profile for the provider exists.
    pub resume_here: bool,
}

/// How a resume runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum PastRoute {
    /// A drgnx session on a copy of the session file, in the jail's own folder (the user's CLI does not see it).
    Copy,
    /// A drgnx session that may write that one original session file (the user's CLI sees the continuation).
    Original,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PastResume {
    pub provider: PastProvider,
    pub id: Bounded<String, 256>,
    pub route: PastRoute,
    /// The agent profile (default: the provider's own).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Bounded<String, 128>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastResumed {
    /// The drgnx session now running.
    pub session: String,
    pub route: PastRoute,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastScanned {
    /// The sessions indexed now.
    pub sessions: u64,
}

/// One CLI whose session files read with many lines this build does not know.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastDrift {
    pub provider: PastProvider,
    /// Files at 20% unknown lines or more, over at least 10 lines.
    pub files: u64,
    /// The share of unknown lines over those files, in percent.
    pub unknown_pct: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PastStatus {
    pub on: bool,
    pub sessions: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub drift: Vec<PastDrift>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/history/search", PastSearch(PastSearch) -> PastHits,
            classes: [User], writes: false,
            doc: "past sessions whose title or transcript holds every word of the query, best first, with a snippet",
        ),
        method!(
            "agents/history/open", PastOpen(PastRef) -> PastOpened,
            classes: [User], writes: false,
            doc: "a past session's transcript as a read-only view, and how it resumes",
        ),
        method!(
            "agents/history/resume", PastResume(PastResume) -> PastResumed,
            classes: [User], writes: true,
            doc: "a past session continued as a drgnx agent through its provider's ACP adapter: on a copy, or writing that one original file",
        ),
        method!(
            "agents/history/rescan", PastRescan(super::Empty) -> PastScanned,
            classes: [User], writes: false,
            doc: "the CLIs' folders read again for past sessions (read-only)",
        ),
        method!(
            "agents/history/status", PastStatus(super::Empty) -> PastStatus,
            classes: [User], writes: false,
            doc: "whether past sessions are on, how many are indexed, and the CLIs whose files read with many unknown lines (format drift)",
        ),
    ]
}
