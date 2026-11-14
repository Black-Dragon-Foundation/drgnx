//! Orchestration in the hub (`docs/develop/orchestration.md`): a task's evidence, the rule pack, waivers and the
//! Flow lens's feed.

use super::method;
use crate::registry::Method;
use crate::types::TaskRef;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A task.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ByTask {
    pub task: TaskRef,
}

/// A task's evidence, oldest first: each record as `vordr::evidence::Evidence` (`kind`, `task`, `job`, `facts`,
/// `rows`, `truncated`, `at`, `note`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EvidenceList {
    pub evidence: Vec<Value>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![method!(
        "orch/evidence", OrchEvidence(ByTask) -> EvidenceList,
        classes: [User], writes: false,
        doc: "a task's evidence (its jobs' rows on their facts, the gates' findings), oldest first",
    )]
}
