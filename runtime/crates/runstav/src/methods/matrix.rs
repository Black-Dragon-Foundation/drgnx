//! The permissions matrix's vocabulary and its methods (agent system part 1, Task 0; `docs/guide/security.md`, "The
//! permissions matrix").  The words are the wire's: `norn::matrix` (Task 3) builds presets, combination and narrowing
//! on these types, the hub's gate (Task 12) checks with them, and the editor's `agents-matrix` setting (Task 13)
//! names actions by [`Action::id`], exactly as the schema in `methods.json` spells them.

use super::graph::ParsedId;
use super::{invalid, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Hex64, Text, null_as_empty};
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A row of the matrix: one thing an agent may do.  `unsandboxed` and `user.private` are Never in every column of
/// every preset and no override changes them.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
pub enum Action {
    #[serde(rename = "agents.start")]
    AgentsStart,
    #[serde(rename = "agents.model")]
    AgentsModel,
    #[serde(rename = "agents.control")]
    AgentsControl,
    #[serde(rename = "graph.change")]
    GraphChange,
    #[serde(rename = "task.done")]
    TaskDone,
    #[serde(rename = "spend")]
    Spend,
    #[serde(rename = "spend.over")]
    SpendOver,
    #[serde(rename = "code.read")]
    CodeRead,
    #[serde(rename = "code.edit")]
    CodeEdit,
    #[serde(rename = "commit")]
    Commit,
    #[serde(rename = "merge.integration")]
    MergeIntegration,
    #[serde(rename = "push.ci")]
    PushCi,
    #[serde(rename = "push.main")]
    PushMain,
    #[serde(rename = "code.ci-config")]
    CodeCiConfig,
    #[serde(rename = "machines")]
    Machines,
    #[serde(rename = "job.container")]
    JobContainer,
    #[serde(rename = "network")]
    Network,
    #[serde(rename = "unsandboxed")]
    Unsandboxed,
    #[serde(rename = "settings.change")]
    SettingsChange,
    #[serde(rename = "user.private")]
    UserPrivate,
    #[serde(rename = "user.emacs")]
    UserEmacs,
    #[serde(rename = "chat.project-read")]
    ChatProjectRead,
}

impl Action {
    /// Every action, in the matrix's row order.
    pub const ALL: [Action; 22] = [
        Action::AgentsStart,
        Action::AgentsModel,
        Action::AgentsControl,
        Action::GraphChange,
        Action::TaskDone,
        Action::Spend,
        Action::SpendOver,
        Action::CodeRead,
        Action::CodeEdit,
        Action::Commit,
        Action::MergeIntegration,
        Action::PushCi,
        Action::PushMain,
        Action::CodeCiConfig,
        Action::Machines,
        Action::JobContainer,
        Action::Network,
        Action::Unsandboxed,
        Action::SettingsChange,
        Action::UserPrivate,
        Action::UserEmacs,
        Action::ChatProjectRead,
    ];

    /// The action's id, as the wire and the `agents-matrix` setting spell it.
    pub fn id(self) -> &'static str {
        match self {
            Action::AgentsStart => "agents.start",
            Action::AgentsModel => "agents.model",
            Action::AgentsControl => "agents.control",
            Action::GraphChange => "graph.change",
            Action::TaskDone => "task.done",
            Action::Spend => "spend",
            Action::SpendOver => "spend.over",
            Action::CodeRead => "code.read",
            Action::CodeEdit => "code.edit",
            Action::Commit => "commit",
            Action::MergeIntegration => "merge.integration",
            Action::PushCi => "push.ci",
            Action::PushMain => "push.main",
            Action::CodeCiConfig => "code.ci-config",
            Action::Machines => "machines",
            Action::JobContainer => "job.container",
            Action::Network => "network",
            Action::Unsandboxed => "unsandboxed",
            Action::SettingsChange => "settings.change",
            Action::UserPrivate => "user.private",
            Action::UserEmacs => "user.emacs",
            Action::ChatProjectRead => "chat.project-read",
        }
    }

    /// The action whose id is ID.
    pub fn from_id(id: &str) -> Option<Action> {
        Action::ALL.into_iter().find(|a| a.id() == id)
    }
}

/// A cell's verdict, ordered `Allow < Ask < Never`: combining columns takes the greatest.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Allow,
    Ask,
    Never,
}

/// What a limit counts.  Limits compare only in the same unit.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "kebab-case")]
pub enum Unit {
    /// A number of things (agents started, jobs).
    Count,
    /// US dollars the gateway measured (exact).
    Usd,
    /// US dollars at API prices from reported usage (an estimate).
    UsdEst,
    Tokens,
    /// A share of a subscription's limit window, 0 to 1 (an estimate).
    LimitShare,
}

/// An amount in a unit.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Limit {
    pub amount: f64,
    pub unit: Unit,
}

/// A matrix cell: a verdict, with an optional limit (an amount over it is decided by `spend.over`).
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Cell {
    pub verdict: Verdict,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<Limit>,
}

/// A session's role: what its matrix column is.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Manager,
    Worker,
    Chat,
}

/// A matrix column: a role, a named agent (profile) or a provider.  The most restrictive of every matching column
/// wins; specificity never widens.
#[derive(
    Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum Column {
    Role(Role),
    Agent(Bounded<String, 128>),
    Provider(Bounded<String, 64>),
}

/// The three shipped presets.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum Preset {
    Cautious,
    Balanced,
    Autonomous,
}

/// When a time preset applies: while the user is away, or between two minutes of the day (`[from, to)`, local time;
/// `from > to` wraps past midnight).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum When {
    Away,
    Between(u16, u16),
}

/// A preset that replaces the base one at some times.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TimePreset {
    pub when: When,
    pub preset: Preset,
}

/// One cell of a layer: ACTION in COLUMN.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CellRow {
    pub action: Action,
    pub column: Column,
    pub verdict: Verdict,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<Limit>,
}

/// Who acts: the columns that match it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WhoParam {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    /// The agent profile's name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<Bounded<String, 128>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<Bounded<String, 64>>,
}

/// Facts the hub derived for a card (never an agent's text).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Facts {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Text>,
    #[serde(default)]
    pub paths: Bounded<Vec<AbsPath>, 64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_hash: Option<Hex64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct GetParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ParsedId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<ParsedId>,
    /// With WHO, the answer has the effective verdict of every action for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub who: Option<WhoParam>,
}

/// One action's effective cell for a caller.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EffectiveRow {
    pub action: Action,
    pub verdict: Verdict,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<Limit>,
}

/// The matrix as it stands: the base preset, the one in force now, the layers' cells, and (asked with `who`) the
/// effective verdicts.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MatrixView {
    pub preset: Preset,
    /// The preset in force now (a time preset may replace the base).
    pub active: Preset,
    pub away: bool,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub time_presets: Vec<TimePreset>,
    /// The preset's cells with the user's, the project's and the plan's overrides applied.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub cells: Vec<CellRow>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub effective: Vec<EffectiveRow>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct CheckParams {
    pub action: Action,
    pub who: WhoParam,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<ParsedId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<ParsedId>,
    /// The amount the action would spend or start, in the cell's unit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub amount: Option<f64>,
}

/// What the matrix decides, and why when it is not Allow (no card is made by a check).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CheckAnswer {
    pub verdict: Verdict,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct PresenceParams {
    pub away: bool,
}

fn check_check(p: &CheckParams) -> Result<(), Error> {
    match p.amount {
        Some(a) if !(a.is_finite() && a >= 0.0) => {
            Err(invalid("amount", "an amount: a finite number, 0 or more"))
        }
        _ => Ok(()),
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "matrix/get", MatrixGet(GetParams) -> MatrixView,
            classes: [User], writes: false, home: Front,
            doc: "the permissions matrix: the preset, the one in force, the layers' cells, and the effective verdicts for who",
        ),
        method!(
            "matrix/check", MatrixCheck(CheckParams) -> CheckAnswer,
            classes: [User], writes: false, home: Front,
            doc: "what the matrix decides for who doing action (no card is made)",
            check: check_check,
        ),
        method!(
            "presence/set", PresenceSet(PresenceParams) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "the editor says the user is away or back (never an agent): the time presets follow from the next action",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_ids_are_the_wire_names() {
        for a in Action::ALL {
            assert_eq!(serde_json::to_value(a).unwrap(), a.id());
            assert_eq!(Action::from_id(a.id()), Some(a));
        }
        assert!(Verdict::Never > Verdict::Ask && Verdict::Ask > Verdict::Allow);
        assert_eq!(
            serde_json::to_value(Unit::LimitShare).unwrap(),
            "limit-share"
        );
        assert_eq!(
            serde_json::to_value(Column::Role(Role::Manager)).unwrap(),
            serde_json::json!({"role": "manager"})
        );
    }
}
