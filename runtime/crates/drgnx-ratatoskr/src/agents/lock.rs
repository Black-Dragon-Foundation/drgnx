//! Provider locks (Task 9; `docs/guide/security.md`, "What each provider obeys"): `lock::plan(profile, role,
//! effective) -> LaunchPlan` — the argv, environment, session `_meta` and read-only protected paths that make a
//! provider's CLI ask the hub for every permission (Claude ported from `drgnx-agents-job-claude-options`, Codex's
//! `-c` overrides, Gemini's `--approval-mode default`), `Enforced::{Yes, No(why)}`, and `lock::verify` at session
//! start (a lock that does not hold kills the session).

use serde_json::Value;
use std::ffi::OsString;
use std::path::PathBuf;

/// Whether the provider's CLI is made to obey the hub (Task 9 fills the reasons).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Enforced {
    Yes,
    No(String),
}

/// What a provider's lock yields for one launch (Task 9 fills `lock::plan`; Task 10 reads it). `login_dir` is the one
/// place under the home the CLI keeps its login token (`~/.claude`, `~/.codex`, …): the sandbox binds it for this CLI
/// alone (Task 10 needs it; Task 9 sets it from the profile's provider).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub argv: Vec<OsString>,
    pub env: Vec<(String, String)>,
    pub session_meta: Option<Value>,
    pub protected_ro: Vec<PathBuf>,
    pub login_dir: Option<PathBuf>,
    pub enforced: Enforced,
}
