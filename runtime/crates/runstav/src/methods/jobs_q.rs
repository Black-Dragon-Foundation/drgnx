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
    ]
}
