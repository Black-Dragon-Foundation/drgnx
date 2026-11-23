//! Outside agents (Claude Code, Codex, Zed… started outside drgnx, served through `mcp/attach`): the user's
//! bindings.  A binding says that outside agents of KIND whose connection root (the bridge's folder's git top-level,
//! a worktree's main repository) is ROOT act as ROLE under the permissions matrix.  Only the user binds, lists and
//! unbinds (`docs/develop/coordination.md`, "Agents outside drgnx").

use super::matrix::Role;
use super::{Empty, method};
use crate::registry::Method;
use crate::types::{AbsPath, AgentKind, Id};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct BindParams {
    /// The outside agents' kind (`claude`, `codex`, …), as their bridge names it.
    pub kind: AgentKind,
    /// A folder in the project: the hub binds the project's top-level (a worktree's main repository).
    pub root: AbsPath,
    pub role: Role,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct UnbindParams {
    /// The binding's id (`outside/bindings`).
    pub id: Id,
}

/// One binding.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BindingRow {
    pub id: String,
    pub kind: String,
    /// The project's top-level the binding is for.
    pub root: String,
    pub role: Role,
    /// When it was last written (seconds since the epoch).
    pub at: f64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Bindings {
    pub bindings: Vec<BindingRow>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "outside/bind", OutsideBind(BindParams) -> BindingRow,
            classes: [User], writes: true,
            doc: "the user binds outside agents of kind in root's project to role (a rebind replaces the role)",
        ),
        method!(
            "outside/unbind", OutsideUnbind(UnbindParams) -> bool,
            classes: [User], writes: true,
            doc: "the user revokes a binding: its agents' next call has no role (false: no such binding)",
        ),
        method!(
            "outside/bindings", OutsideBindings(Empty) -> Bindings,
            classes: [User], writes: false,
            doc: "the live bindings",
        ),
    ]
}
