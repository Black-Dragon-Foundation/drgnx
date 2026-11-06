//! History: what a revert or a fork of an agent's work restores (`docs/develop/hub.md`, "Rewind and fork").

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// How much of an agent's conversation a rewind or a fork restores: up to the step's message (Claude), up to the
/// last turn that completed at or before it (Codex), or a new conversation told a labelled summary (any other agent,
/// a fork across providers, a fork that failed).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum RestoreLevel {
    Message,
    Turn,
    Summary,
}
