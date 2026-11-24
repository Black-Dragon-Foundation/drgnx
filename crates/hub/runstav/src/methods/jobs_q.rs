//! The job system's methods (`docs/guide/jobs.md`): the projects registered with the hub. Only the user registers or
//! removes a project, or lists them; an agent's connection is refused.

use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, null_as_empty};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `jobs/project-add`'s params: the repository (any folder in it) and its display name (default: its top folder's).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProjectAddParams {
    pub path: AbsPath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<Bounded<String, 128>>,
}

/// `jobs/project-remove`'s params.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProjectRemoveParams {
    pub id: Bounded<String, 64>,
}

/// A registered project: the hub's id, its display name, its origin URL (empty: none) and its root commits.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub origin: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub roots: Vec<String>,
}

/// `jobs/project-list`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Projects {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub projects: Vec<Project>,
}

/// `jobs/allow`'s params: PROJECT's CLASS allow-list (`image`, `tool`, `host` or `fetch`). With a `value` it is added
/// (`on`) or removed; without one the list is only read.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AllowParams {
    /// The project's id (`jobs/project-list`).
    pub project: Bounded<String, 128>,
    pub class: Bounded<String, 16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<Bounded<String, 256>>,
    #[serde(default = "yes")]
    pub on: bool,
}

fn yes() -> bool {
    true
}

/// `jobs/allow`'s answer: the list as it is now.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Allowed {
    pub project: String,
    pub class: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub values: Vec<String>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "jobs/project-add", JobsProjectAdd(ProjectAddParams) -> Project,
            classes: [User], writes: true,
            doc: "a repository registered as a project: its root commits and origin recorded; every clone and worktree of it maps to its id. A shallow clone, or the same repository registered again, is refused",
        ),
        method!(
            "jobs/project-list", JobsProjectList(Empty) -> Projects,
            classes: [User], writes: false,
            doc: "the registered projects",
        ),
        method!(
            "jobs/project-remove", JobsProjectRemove(ProjectRemoveParams) -> bool,
            classes: [User], writes: true,
            doc: "a project removed from the registry, with the clones mapped to it",
        ),
        method!(
            "jobs/allow", JobsAllow(AllowParams) -> Allowed,
            classes: [User], writes: true,
            doc: "what a project's jobs may pull or run: a value added to or removed from its image, tool, host or fetch allow-list, or the list read; only the user's own connection may, an agent is refused",
        ),
    ]
}
