//! Every method of the hub protocol, one definition each, grouped as the hub's parts are: the hub itself
//! ([`hub`]), the gateway, its provider table and spend ([`gateway`]), agent sessions ([`agents`]), jobs ([`jobs`]), coordination
//! ([`coord`]), the graph store ([`graph`]), the settings' history ([`settings`]), the tracker for the editor
//! ([`tasks`]) and the coordination tools' sockets ([`mcp`]); the agent core's (agent system part 1): jobs
//! ([`exec`]), the permissions matrix ([`matrix`]), plans, briefs and reports ([`plans`]), records ([`records`]) and
//! time, budgets and the supervisor ([`timeline`]); the Extensions view's catalog ([`extensions`]).  [`crate::registry`] puts them in one sorted table.

pub mod agents;
pub mod config;
pub mod coord;
pub mod editor;
pub mod exec;
pub mod extensions;
pub mod forecast;
pub mod gateway;
pub mod graph;
pub mod history;
pub mod hub;
pub mod jobs;
pub mod matrix;
pub mod mcp;
pub mod pair;
pub mod plans;
pub mod plugins;
pub mod records;
pub mod runners;
pub mod say;
pub mod search;
pub mod settings;
pub mod tasks;
pub mod timeline;
pub mod view;
pub mod work;

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
/// (wrapped in `Params::$variant`) and its result check.  `check:` adds a check of meaning after the decode.
macro_rules! method {
    (
        $name:literal, $variant:ident($params:ty) -> $result:ty,
        classes: [$($class:ident),+], writes: $writes:expr, doc: $doc:literal
        $(, check: $check:expr)? $(,)?
    ) => {
        $crate::registry::Method {
            name: $name,
            classes: &[$($crate::registry::Class::$class),+],
            writes: $writes,
            variant: stringify!($variant),
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
            /// Every variant's name, one per method (`registry::Method::variant`).
            pub const VARIANTS: &'static [&'static str] = &[$(stringify!($variant)),+];

            /// This variant's name.
            pub fn variant(&self) -> &'static str {
                match self {
                    $(Params::$variant(_) => stringify!($variant)),+
                }
            }

            /// The params re-encoded: optional values that were absent or `null` are left out.
            pub fn to_value(&self) -> Value {
                match self {
                    $(Params::$variant(p) => serde_json::to_value(p)),+
                }
                .expect("params encode as JSON")
            }
        }

        /// The params as `to_value` has them (keys are exposed only while they are serialised).
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
    BrowserCheck(Empty),
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
    AgentsEntriesSubscribe(agents::SessionRef),
    AgentsEntriesUnsubscribe(agents::SessionRef),
    AgentsToolInput(agents::ToolInputParams),
    AgentsToolOutput(agents::ToolOutputParams),
    AgentsPause(agents::ById),
    AgentsHuddleStart(agents::HuddleStart),
    AgentsHuddleGet(agents::ById),
    AgentsWheelTake(agents::ById),
    AgentsWheelGive(agents::ById),
    AgentsWheelSaved(agents::WheelSaved),
    AgentsProbe(agents::ProbeParams),
    AgentsContextDrop(agents::ContextDropParams),
    AgentsContextPin(agents::ContextPinParams),
    AgentsCompactPreview(agents::ById),
    AgentsConfig(agents::ConfigParams),
    AgentsExplain(agents::ExplainParams),
    ExecStart(exec::StartParams),
    ExecGet(exec::ById),
    ExecList(exec::ListParams),
    ExecStop(exec::ById),
    ExecLog(exec::LogParams),
    ExecBump(exec::ById),
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
    ForecastGet(forecast::ForecastParams),
    ForecastSession(forecast::SessionForecastParams),
    ForecastAccuracy(forecast::AccuracyParams),
    SayStart(say::SayStart),
    SayRevise(say::SayRevise),
    SayEnd(say::SayById),
    RecordsImport(records::ImportParams),
    RecordsStatus(records::ByPath),
    RecordsProposals(records::ByPath),
    RecordsDecide(records::DecideParams),
    MachinesReport(work::MachineReport),
    MachinesList(Empty),
    WorkConclusions(work::ConclusionsParams),
    AgentsPresenceSubscribe(work::PresenceSubscribe),
    AgentsPresenceGet(work::PresenceGet),
    AgentsBufferWatch(editor::BufferWatch),
    AgentsBufferUnwatch(editor::BufferUnwatch),
    WorkMapSubscribe(work::MapSubscribe),
    WorkMapSet(work::MapSet),
    WorkMapClose(work::MapClose),
    WorkTrailSubscribe(work::TrailSubscribe),
    WorkTrailClose(work::TrailClose),
    WorkFiles(work::EditedFiles),
    WorkHunks(work::HunksParams),
    WorkFileAt(work::FileAtParams),
    ViewEnv(view::ViewEnv),
    ViewResync(view::ViewResync),
    ViewGlyphs(view::ViewGlyphs),
    ViewMeasured(view::ViewMeasured),
    ViewClose(view::ViewClose),
    SearchQuery(search::QueryParams),
    SearchStatus(search::RootParams),
    SearchIndex(search::IndexParams),
    SearchEmbedders(Empty),
    SearchModelDownload(search::DownloadParams),
    SearchTyping(Empty),
    SearchServerPlan(search::ServerKindParams),
    SearchServerStart(search::ServerStartParams),
    SearchServerStop(search::ServerKindParams),
    RunnersList(Empty),
    RunnersProbeHost(runners::ProbeParams),
    RunnersAdd(runners::AddParams),
    RunnersCheck(runners::ByName),
    RunnersBench(runners::ByName),
    RunnersSet(runners::SetParams),
    HistoryRegister(history::RegisterParams),
    HistoryBatch(history::BatchParams),
    HistoryResync(history::ResyncParams),
    HistoryUnregister(history::UnregisterParams),
    HistoryRevertPreview(history::RevertPreviewParams),
    HistoryRevertApply(history::RevertApplyParams),
    HistoryFork(history::ForkParams),
    HistoryForkDrop(history::ForkDropParams),
    HistoryCompare(history::CompareParams),
    HistoryBlame(history::BlameParams),
    HistoryHunks(history::BranchHunksParams),
    HistoryTake(history::TakeParams),
    HistoryRedo(history::RedoParams),
    HistoryOpHunks(history::OpHunksParams),
    HistoryRevertHunk(history::RevertHunkParams),
    RunnersUnbench(runners::ByName),
    RunnersRemove(runners::RemoveParams),
    ExtensionsSearch(extensions::SearchParams),
    ExtensionsDetails(extensions::DetailsParams),
    ExtensionsRows(extensions::RowsParams),
    ExtensionsModules(extensions::ModulesParams),
    PluginsList(Empty),
    PluginsApprove(plugins::ApproveParams),
    PluginsDisable(plugins::DisableParams),
    RunnersKeys(runners::KeysParams),
    RunnersKeysHeld(Empty),
    RunnersAudit(runners::AuditParams),
    PairAnswer(pair::PairAnswer),
    PairReadAnswer(pair::PairReadAnswer),
    PairOpen(pair::OpenParams),
    PairClosed(pair::ClosedParams),
    PairOpenSet(pair::OpenSetParams),
    AgentsPair(pair::PairToggle),
    AgentsFollow(editor::FollowParams),
    AgentsUnfollow(editor::UnfollowParams),
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
    v.extend(forecast::methods());
    v.extend(say::methods());
    v.extend(records::methods());
    v.extend(work::methods());
    v.extend(view::methods());
    v.extend(editor::methods());
    v.extend(search::methods());
    v.extend(runners::methods());
    v.extend(extensions::methods());
    v.extend(plugins::methods());
    v.extend(history::methods());
    v.extend(pair::methods());
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
