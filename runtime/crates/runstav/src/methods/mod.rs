//! Every method of the hub protocol, one definition each, grouped as the hub's parts are: the hub itself
//! ([`hub`]), the gateway, its provider table and spend ([`gateway`]), agent sessions ([`agents`]), jobs ([`jobs`]), coordination
//! ([`coord`]), the graph store ([`graph`]), the settings' history ([`settings`]), the tracker for the editor
//! ([`tasks`]) and the coordination tools' sockets ([`mcp`]); the agent core's (agent system part 1): jobs
//! ([`exec`]), the permissions matrix ([`matrix`]), plans, briefs and reports ([`plans`]), records ([`records`]) and
//! time, budgets and the supervisor ([`timeline`]).  [`crate::registry`] puts them in one sorted table.

pub mod agents;
pub mod config;
pub mod coord;
pub mod exec;
pub mod gateway;
pub mod graph;
pub mod hub;
pub mod jobs;
pub mod matrix;
pub mod mcp;
pub mod plans;
pub mod records;
pub mod settings;
pub mod tasks;
pub mod timeline;

use crate::registry::Method;
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Params of a method that takes none: any keys are dropped (and listed in `ignored`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct Empty {}

/// A params check's refusal at PATH.
pub(crate) fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// One method's definition (`registry::Method`): the params and result types give its schemas, its typed decode
/// (wrapped in `Params::$variant`) and its result check.  `home: Front` marks a method the front serves itself (the
/// default is the backend's); `check:` adds a check of meaning after the decode.
macro_rules! method {
    (@home) => { $crate::registry::Home::Backend };
    (@home $home:ident) => { $crate::registry::Home::$home };
    (
        $name:literal, $variant:ident($params:ty) -> $result:ty,
        classes: [$($class:ident),+], writes: $writes:expr, $(home: $home:ident,)? doc: $doc:literal
        $(, check: $check:expr)? $(,)?
    ) => {
        $crate::registry::Method {
            name: $name,
            classes: &[$($crate::registry::Class::$class),+],
            writes: $writes,
            home: $crate::methods::method!(@home $($home)?),
            doc: $doc,
            params: $crate::registry::schema_of::<$params>,
            result: $crate::registry::schema_of::<$result>,
            decode: |v| {
                let (p, ignored) = $crate::registry::decode_params::<$params>(v)?;
                $( let check: fn(&$params) -> Result<(), $crate::wire::Error> = $check; check(&p)?; )?
                Ok(($crate::methods::Params::$variant(p), ignored))
            },
            check_result: $crate::registry::check_as::<$result>,
        }
    };
}
pub(crate) use method;

/// The params of every method, decoded: the variant names the method.  No `Debug`: params may hold keys and prompts.
macro_rules! params {
    ($($variant:ident($ty:ty)),+ $(,)?) => {
        pub enum Params {
            $($variant($ty)),+
        }

        impl Params {
            /// The params re-encoded (what the front forwards to the backend): optional values that were absent or
            /// `null` are left out.
            pub fn to_value(&self) -> Value {
                match self {
                    $(Params::$variant(p) => serde_json::to_value(p)),+
                }
                .expect("params encode as JSON")
            }
        }

        /// The params as `to_value` has them, written straight into the line the front sends the backend (keys are
        /// exposed only while that line is serialised).
        impl Serialize for Params {
            fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                match self {
                    $(Params::$variant(p) => p.serialize(s)),+
                }
            }
        }
    };
}

params! {
    Hello(hub::HelloParams),
    Ping(Empty),
    Status(Empty),
    Restart(Empty),
    Shutdown(Empty),
    Subscribe(Empty),
    EventsSince(hub::EventsSinceParams),
    EnvSet(hub::EnvSetParams),
    CoordNotify(Empty),
    CardsSettle(coord::SettleParams),
    MessagesSend(coord::SendParams),
    MessagesMark(coord::MarkParams),
    EventsAdd(coord::AddEventParams),
    ReviewMark(coord::ReviewMarkParams),
    CoordJobCreate(coord::JobCreateParams),
    CoordJobSet(coord::JobSetParams),
    CoordTaskStatus(coord::TaskStatusParams),
    CoordLeases(coord::LeasesParams),
    CoordDecide(coord::DecideParams),
    CoordAgent(coord::AgentParams),
    CoordCardCreate(coord::CardCreateParams),
    CoordCardSet(coord::CardSetParams),
    CoordHeld(coord::HeldParams),
    CoordPrune(Empty),
    GraphPutParsed(graph::PutParsedParams),
    GraphRecord(graph::RecordParams),
    GraphEntity(graph::EntityParams),
    GraphNeighbors(graph::NeighborsParams),
    GraphPath(graph::PathParams),
    GraphHistory(graph::HistoryParams),
    GraphRevert(graph::RevertParams),
    GraphExcise(graph::ExciseParams),
    GraphGrants(graph::GrantsParams),
    GraphProposed(graph::ProposedParams),
    GraphSql(graph::SqlParams),
    GraphExport(graph::ExportParams),
    GraphImport(graph::ImportParams),
    GraphBackup(Empty),
    GraphCompact(graph::CompactParams),
    GraphScrub(Empty),
    GraphSettings(graph::SettingsParams),
    GraphPrivacy(graph::PrivacyParams),
    SettingsRecord(settings::RecordParams),
    SettingsConfirm(settings::ConfirmParams),
    SettingsExplained(settings::ExplainedParams),
    TasksReady(tasks::ReadyParams),
    TasksFind(tasks::FindParams),
    TasksWrite(tasks::WriteParams),
    McpSession(mcp::SessionParams),
    McpSessionClose(mcp::SessionCloseParams),
    McpAttach(mcp::AttachParams),
    Spend(gateway::SpendParams),
    GatewayRegister(gateway::RegisterParams),
    GatewayUnregister(gateway::UnregisterParams),
    GatewayKeys(gateway::KeysParams),
    GatewaySetBudget(gateway::SetBudgetParams),
    ConfigSettings(config::SettingsParams),
    ConfigChanged(Empty),
    GatewayEditorToken(Empty),
    GatewayKeysHeld(Empty),
    AgentsList(Empty),
    AgentsStart(agents::StartParams),
    AgentsGet(agents::ById),
    AgentsSend(agents::SendParams),
    AgentsStop(agents::ById),
    AgentsKill(agents::ById),
    AgentsPermission(agents::PermissionParams),
    AgentsDo(agents::DoParams),
    JobPropose(jobs::ProposeParams),
    JobStartTask(jobs::StartTaskParams),
    JobReassign(jobs::ReassignParams),
    JobBlock(jobs::BlockParams),
    JobUnblock(jobs::ByTask),
    JobOrder(jobs::OrderParams),
    JobApprove(jobs::WithBudget),
    JobStop(agents::ById),
    JobResume(jobs::WithBudget),
    JobCard(jobs::CardParams),
    JobReply(jobs::ReplyParams),
    JobDismiss(jobs::ByMessage),
    JobStatus(jobs::StatusParams),
    AgentsMove(agents::MoveParams),
    AgentsRole(agents::RoleParams),
    AgentsSlice(agents::SliceParams),
    ExecStart(exec::StartParams),
    ExecGet(exec::ById),
    ExecList(exec::ListParams),
    ExecStop(exec::ById),
    ExecLog(exec::LogParams),
    MatrixGet(matrix::GetParams),
    MatrixCheck(matrix::CheckParams),
    PresenceSet(matrix::PresenceParams),
    MessagesRetract(coord::RetractParams),
    PlansGet(plans::ByPlan),
    PlansWrite(plans::WriteParams),
    BriefBuild(plans::ByTask),
    BriefSet(plans::BriefSetParams),
    ReportsGet(plans::ReportsParams),
    DecisionsEffects(plans::EffectsParams),
    TimelineGet(timeline::TimelineParams),
    BudgetGet(timeline::BudgetGetParams),
    BudgetSet(timeline::BudgetSetParams),
    PaceGet(timeline::PaceParams),
    RecordsImport(records::ImportParams),
    RecordsStatus(records::ByPath),
    RecordsProposals(records::ByPath),
    RecordsDecide(records::DecideParams),
}

/// Every method, in no order.
pub(crate) fn all() -> Vec<Method> {
    let mut v = hub::methods();
    v.extend(coord::methods());
    v.extend(graph::methods());
    v.extend(settings::methods());
    v.extend(config::methods());
    v.extend(tasks::methods());
    v.extend(mcp::methods());
    v.extend(gateway::methods());
    v.extend(agents::methods());
    v.extend(jobs::methods());
    v.extend(exec::methods());
    v.extend(matrix::methods());
    v.extend(plans::methods());
    v.extend(timeline::methods());
    v.extend(records::methods());
    v
}

#[cfg(test)]
mod tests {
    use crate::registry::find;
    use serde_json::json;

    #[test]
    fn params_serialize_as_to_value_has_them() {
        for (method, params) in [
            ("gateway/keys", json!({"keys": {"openrouter": "sk-x"}})),
            ("job/stop", json!({"id": "j", "x": 1})),
            ("spend", json!({})),
        ] {
            let (p, _) = (find(method).unwrap().decode)(&params).unwrap();
            assert_eq!(serde_json::to_value(&p).unwrap(), p.to_value(), "{method}");
        }
    }
}
