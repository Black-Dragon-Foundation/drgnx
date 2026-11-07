//! The agent core's methods, routed: every method of the agent system, and `agents/*` and `job/*` (which the hub now
//! serves itself), go to the function of the module that serves it.  A module fills its own functions and state
//! ([`Core`]'s field), never this match.
//!
//! | Methods | Module |
//! |---|---|
//! | `agents/{list,start,get,stop,kill,permission,do}` | [`crate::agents::session`] |
//! | `agents/send` | [`crate::agents::session`] |
//! | `agents/move` | [`crate::agents::session`] |
//! | `agents/probe` | [`crate::agents::probe`] |
//! | `messages/retract` | [`crate::agents::deliver`] |
//! | `agents/role`, `agents/slice` | [`crate::manager`] |
//! | `exec/*` | [`crate::exec`] |
//! | `job/{propose,start-task,approve,order,block,unblock,stop,status}` | [`crate::runner`] |
//! | `job/{card,reply,dismiss,reassign,resume}` | [`crate::runner`] |
//! | `matrix/*`, `presence/set` | [`crate::matrix_gate`] |
//! | `plans/*`, `reports/get`, `decisions/effects` | [`crate::runner::effects`] |
//! | `brief/*` | [`crate::brief`] |
//! | `timeline/get` | [`crate::timeline`] |
//! | `budget/*`, `pace/get` | [`crate::budget`] |
//! | `forecast/*` | [`crate::forecast`] |
//! | `say/*` | [`crate::say`] |
//! | `records/{import,status}` | [`crate::records`] |
//! | `records/{proposals,decide}` | [`crate::records`] |
//! | `machines/{report,list}` | [`crate::work::machines`] |
//! | `runners/*` | [`crate::runners::methods`] |
//! | `plugins/*` | [`crate::plugins`] |
//! | `work/conclusions` | [`crate::work::conclusions`] |
//! | `agents/presence/{subscribe,get}` | [`crate::work::presence`] |
//! | `agents/buffer/{watch,unwatch}` | [`crate::editor`] |
//! | `work/{files,hunks,file-at}` | [`crate::work::edits`] |
//! | `work/map/{subscribe,set,close}` | [`crate::work::map`] |

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::wire::Error;
use serde::Serialize;
use serde_json::{Value, json};

/// The agent core's state, one part per module; each task fills its own part (its `Default` stays the way the
/// front makes it: a part that needs the store or the settings takes them from the [`Front`] its functions get).
#[derive(Default)]
pub struct Core {
    pub agents: crate::agents::Hub,
    pub exec: crate::exec::Runner,
    pub runs: crate::runner::Runs,
    pub matrix: crate::matrix_gate::MatrixGate,
    pub timeline: crate::timeline::Timeline,
    pub budgets: crate::budget::Budgets,
    pub supervisor: crate::supervisor::Supervisor,
    pub briefs: crate::brief::Briefs,
    pub manager: crate::manager::Managers,
    pub records: crate::records::Views,
    pub machines: crate::work::machines::Machines,
    /// The runners' registry ([`crate::runners::methods`]).
    pub runners: crate::runners::methods::Hub,
    /// The installed plugins and the user's approvals ([`crate::plugins`]).
    pub plugins: crate::plugins::Plugins,
    /// The sessions' current asks and what links to them ([`crate::work::asks`]).
    pub asks: crate::work::asks::Asks,
    /// The conclusions' step stamps ([`crate::work::conclusions`]).
    pub stamps: std::sync::Arc<crate::work::conclusions::Stamps>,
    /// Who is in which file now ([`crate::work::presence`]).
    pub presence: std::sync::Arc<crate::work::presence::Live>,
    /// The Work map's views and the model behind them ([`crate::work::map`]).
    pub map: std::sync::Arc<crate::work::map::Map>,
    /// The trail and Timeline views ([`crate::work::trail`]).
    pub trails: crate::work::trail::Trails,
    /// The editors' buffer views: the agents in each watched buffer ([`crate::editor`]).
    pub buffers: std::sync::Arc<crate::editor::Buffers>,
    /// The files shell steps opened, from Gleipnir's tracer ([`crate::work::trace`]).
    pub traces: std::sync::Arc<crate::work::trace::Traces>,
    /// The conflict predictor: two worktrees' changes to one file merged ahead of time ([`crate::runner::predict`]).
    pub predict: std::sync::Arc<crate::runner::predict::Live>,
    /// The huddles: two agents' positions on a clash, for the user ([`crate::runner::huddle`]).
    pub huddles: std::sync::Arc<crate::runner::huddle::Huddles>,
    /// The edit history of each open project ([`crate::history`]).
    pub history: std::sync::Arc<crate::history::wire::Hubs>,
    /// The planning sessions of Say it and the channel to their shell ([`crate::say`]).
    pub say: crate::say::Say,
    /// The editors' view environments and the rows each (view, class) was sent ([`crate::view`]).
    pub views: crate::view::Views,
}

fn answer<T: Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.map(|v| json!(v))
}

/// P served by the agent core, or handed back (not one of its methods).
pub async fn serve(
    front: &Front,
    caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    use crate::{
        agents, brief, budget, exec, forecast, manager, matrix_gate, records, runner, runners, say,
        timeline, work,
    };
    let (f, c) = (front, caller);
    Ok(match p {
        Params::AgentsList(p) => answer(agents::session::list(f, c, p).await),
        Params::AgentsStart(p) => answer(agents::session::start(f, c, p).await),
        Params::AgentsGet(p) => answer(agents::session::get(f, c, p).await),
        Params::AgentsSend(p) => answer(agents::session::send(f, c, p).await),
        Params::AgentsStop(p) => answer(agents::session::stop(f, c, p).await),
        Params::AgentsKill(p) => answer(agents::session::kill(f, c, p).await),
        Params::AgentsPermission(p) => answer(agents::session::permission(f, c, p).await),
        Params::AgentsDo(p) => answer(agents::session::do_op(f, c, p).await),
        Params::AgentsMove(p) => answer(agents::session::move_to(f, c, p).await),
        Params::AgentsProbe(p) => answer(agents::probe::probe(f, c, p).await),
        Params::MessagesRetract(p) => answer(agents::deliver::retract(f, c, p).await),
        Params::AgentsRole(p) => answer(manager::role(f, c, p).await),
        Params::AgentsSlice(p) => answer(manager::slice(f, c, p).await),
        Params::AgentsEntriesSubscribe(p) => answer(agents::session::entries_subscribe(f, c, p)),
        Params::AgentsEntriesUnsubscribe(p) => {
            answer(agents::session::entries_unsubscribe(f, c, p))
        }
        Params::AgentsToolInput(p) => answer(agents::session::tool_input(f, c, p)),
        Params::AgentsToolOutput(p) => answer(agents::session::tool_output(f, c, p)),
        Params::AgentsPause(p) => answer(agents::session::pause(f, c, p)),
        Params::AgentsContextDrop(p) => answer(agents::session::panel::context_drop(f, c, p).await),
        Params::AgentsContextPin(p) => answer(agents::session::panel::context_pin(f, c, p).await),
        Params::AgentsConfig(p) => answer(agents::session::panel::config(f, c, p).await),
        Params::AgentsExplain(p) => answer(agents::session::panel::explain(f, c, p).await),
        Params::AgentsCompactPreview(p) => {
            answer(agents::session::panel::compact_preview(f, c, p).await)
        }
        Params::AgentsHuddleStart(p) => answer(crate::runner::huddle::start(f, c, p).await),
        Params::AgentsHuddleGet(p) => answer(crate::runner::huddle::get(f, c, p).await),
        Params::AgentsWheelTake(p) => answer(agents::session::wheel_take(f, c, p)),
        Params::AgentsWheelGive(p) => answer(agents::session::wheel_give(f, c, p).await),
        Params::AgentsWheelSaved(p) => answer(agents::session::wheel_saved(f, c, p)),
        Params::AgentsPair(p) => answer(agents::session::pair(f, c, p).await),
        Params::AgentsFollow(p) => answer(crate::editor::follow(f, c, p)),
        Params::AgentsUnfollow(p) => answer(crate::editor::unfollow(f, c, p)),
        Params::ExecStart(p) => answer(exec::start(f, c, p).await),
        Params::ExecGet(p) => answer(exec::get(f, c, p).await),
        Params::ExecList(p) => answer(exec::list(f, c, p).await),
        Params::ExecStop(p) => answer(exec::stop(f, c, p).await),
        Params::ExecLog(p) => answer(exec::log(f, c, p).await),
        Params::ExecBump(p) => answer(exec::bump(f, c, p).await),
        Params::JobPropose(p) => answer(runner::propose(f, c, p).await),
        Params::JobStartTask(p) => answer(runner::start_task(f, c, p).await),
        Params::JobApprove(p) => answer(runner::approve(f, c, p).await),
        Params::JobOrder(p) => answer(runner::order(f, c, p).await),
        Params::JobBlock(p) => answer(runner::block(f, c, p).await),
        Params::JobUnblock(p) => answer(runner::unblock(f, c, p).await),
        Params::JobStop(p) => answer(runner::stop(f, c, p).await),
        Params::JobStatus(p) => answer(runner::status(f, c, p).await),
        Params::JobCard(p) => answer(runner::card(f, c, p).await),
        Params::JobReply(p) => answer(runner::reply(f, c, p).await),
        Params::JobDismiss(p) => answer(runner::dismiss(f, c, p).await),
        Params::JobReassign(p) => answer(runner::reassign(f, c, p).await),
        Params::JobResume(p) => answer(runner::resume(f, c, p).await),
        Params::MatrixGet(p) => answer(matrix_gate::get(f, c, p).await),
        Params::MatrixCheck(p) => answer(matrix_gate::check_method(f, c, p).await),
        Params::PresenceSet(p) => answer(matrix_gate::presence(f, c, p).await),
        Params::PlansGet(p) => answer(runner::effects::plans_get(f, c, p).await),
        Params::PlansWrite(p) => answer(runner::effects::plans_write(f, c, p).await),
        Params::ReportsGet(p) => answer(runner::effects::reports_get(f, c, p).await),
        Params::DecisionsEffects(p) => answer(runner::effects::decision_effects(f, c, p).await),
        Params::BriefBuild(p) => answer(brief::build_method(f, c, p).await),
        Params::BriefSet(p) => answer(brief::set(f, c, p).await),
        Params::TimelineGet(p) => answer(timeline::get(f, c, p).await),
        Params::BudgetGet(p) => answer(budget::get(f, c, p).await),
        Params::BudgetSet(p) => answer(budget::set(f, c, p).await),
        Params::PaceGet(p) => answer(budget::pace(f, c, p).await),
        Params::ForecastGet(p) => answer(forecast::get(f, c, p).await),
        Params::ForecastSession(p) => answer(forecast::session(f, p).await),
        Params::ForecastAccuracy(p) => answer(forecast::accuracy(f, p).await),
        Params::SayStart(p) => answer(say::start(f, c, p).await),
        Params::SayRevise(p) => answer(say::revise(f, c, p).await),
        Params::SayEnd(p) => answer(say::end(f, c, p).await),
        Params::RecordsImport(p) => answer(records::import(f, c, p).await),
        Params::RecordsStatus(p) => answer(records::status(f, c, p).await),
        Params::RecordsProposals(p) => answer(records::proposals(f, c, p).await),
        Params::RecordsDecide(p) => answer(records::decide(f, c, p).await),
        Params::MachinesReport(p) => answer(work::machines::report(f, c, p).await),
        Params::MachinesList(p) => answer(work::machines::list(f, c, p).await),
        Params::RunnersList(p) => answer(runners::methods::list(f, c, p).await),
        Params::RunnersProbeHost(p) => answer(runners::methods::probe_host(f, c, p).await),
        Params::RunnersAdd(p) => answer(runners::methods::add(f, c, p).await),
        Params::RunnersCheck(p) => answer(runners::methods::check(f, c, p).await),
        Params::RunnersBench(p) => answer(runners::methods::bench(f, c, p).await),
        Params::RunnersSet(p) => answer(runners::methods::set(f, c, p).await),
        Params::HistoryRegister(p) => answer(crate::history::wire::register(f, c, p).await),
        Params::HistoryBatch(p) => answer(crate::history::wire::batch(f, c, p).await),
        Params::HistoryResync(p) => answer(crate::history::wire::resync(f, c, p).await),
        Params::HistoryUnregister(p) => answer(crate::history::wire::unregister(f, c, p).await),
        Params::HistoryRevertPreview(p) => answer(crate::history::revert::preview(f, c, p).await),
        Params::HistoryRevertApply(p) => answer(crate::history::revert::apply(f, c, p).await),
        Params::HistoryFork(p) => answer(crate::history::branches::fork(f, c, p).await),
        Params::HistoryForkDrop(p) => answer(crate::history::branches::drop_fork(f, c, p).await),
        Params::HistoryCompare(p) => answer(crate::history::branches::compare(f, c, p).await),
        Params::HistoryBlame(p) => answer(crate::history::views::blame(f, c, p).await),
        Params::HistoryHunks(p) => answer(crate::history::views::hunks(f, c, p).await),
        Params::HistoryTake(p) => answer(crate::history::branches::take(f, c, p).await),
        Params::HistoryRedo(p) => answer(crate::history::branches::redo(f, c, p).await),
        Params::HistoryOpHunks(p) => answer(crate::history::hunk::op_hunks(f, c, p).await),
        Params::HistoryRevertHunk(p) => answer(crate::history::hunk::revert_hunk(f, c, p).await),
        Params::RunnersUnbench(p) => answer(runners::methods::unbench(f, c, p).await),
        Params::RunnersRemove(p) => answer(runners::methods::remove(f, c, p).await),
        Params::PluginsList(p) => answer(crate::plugins::list(f, c, p).await),
        Params::PluginsApprove(p) => answer(crate::plugins::approve(f, c, p).await),
        Params::PluginsDisable(p) => answer(crate::plugins::disable(f, c, p).await),
        Params::RunnersKeys(p) => answer(runners::methods::keys(f, c, p).await),
        Params::RunnersKeysHeld(p) => answer(runners::methods::keys_held(f, c, p).await),
        Params::RunnersAudit(p) => answer(runners::methods::audit(f, c, p).await),
        Params::WorkConclusions(p) => answer(work::conclusions::get(f, c, p).await),
        Params::AgentsPresenceSubscribe(p) => answer(work::presence::subscribe(f, c, p).await),
        Params::AgentsPresenceGet(p) => answer(work::presence::get(f, c, p).await),
        Params::AgentsBufferWatch(p) => answer(crate::editor::watch(f, c, p).await),
        Params::AgentsBufferUnwatch(p) => answer(crate::editor::unwatch(f, c, p)),
        Params::WorkMapSubscribe(p) => answer(work::map::subscribe(f, c, p).await),
        Params::WorkMapSet(p) => answer(work::map::set(f, c, p)),
        Params::WorkMapClose(p) => answer(work::map::close(f, c, p)),
        Params::WorkTrailSubscribe(p) => answer(work::trail::subscribe(f, c, p).await),
        Params::WorkTrailClose(p) => answer(work::trail::close(f, c, p)),
        Params::WorkFiles(p) => answer(work::edits::files(f, c, p).await),
        Params::WorkHunks(p) => answer(work::edits::hunks(f, c, p).await),
        Params::WorkFileAt(p) => answer(work::edits::file_at(f, c, p).await),
        other => return Err(Box::new(other)),
    })
}
