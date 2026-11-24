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
//! | `outside/{bind,unbind,bindings}` | [`crate::outside`] |
//! | `machines/{report,list}` | [`crate::work::machines`] |
//! | `comments/{add,reply,list,resolve}` | [`crate::work::comments`] |
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
    /// The other CLIs' past sessions ([`crate::agents::past`]).
    pub past: std::sync::Arc<crate::agents::past::History>,
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
    /// The terminals' workers and where their patches go ([`crate::term`]).
    pub terms: crate::term::Terms,
    /// The outside bridges attached now: every gate and scope lookup of an `ext:` caller asks it ([`crate::outside`]).
    pub outside: crate::outside::Bound,
}

fn answer<T: Serialize>(r: Result<T, Error>) -> Result<Value, Error> {
    r.map(|v| json!(v))
}

pub(crate) type Served<'a> =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value, Error>> + Send + 'a>>;

/// The future MK makes, on the heap.  Never inlined: the arm's future (10 KB and more) is built in this frame, which is
/// gone before the arm is awaited.  Built in [`serve`]'s own frame, a debug build gives every arm's future a stack
/// slot of its own (the slots do not overlap), 700 KB for the match: a hub with a request on a 2 MB worker stack
/// (every request under `--test-sequencer`, which serves it inside the connection's own task) overflowed it.
#[inline(never)]
pub(crate) fn boxed<'a, F, Fut>(mk: F) -> Served<'a>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<Value, Error>> + Send + 'a,
{
    Box::pin(mk())
}

/// An arm that awaits: its future is made in [`boxed`], not in [`serve`]'s frame.
macro_rules! arm {
    ($e:expr) => {
        $crate::agent_core::boxed(move || async move { $e }).await
    };
}
pub(crate) use arm;

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
        Params::AgentsList(p) => arm!(answer(agents::session::list(f, c, p).await)),
        Params::AgentsStart(p) => arm!(answer(agents::session::start(f, c, p).await)),
        Params::AgentsGet(p) => arm!(answer(agents::session::get(f, c, p).await)),
        Params::AgentsSend(p) => arm!(answer(agents::session::send(f, c, p).await)),
        Params::AgentsStop(p) => arm!(answer(agents::session::stop(f, c, p).await)),
        Params::AgentsKill(p) => arm!(answer(agents::session::kill(f, c, p).await)),
        Params::AgentsPermission(p) => arm!(answer(agents::session::permission(f, c, p).await)),
        Params::AgentsDo(p) => arm!(answer(agents::session::do_op(f, c, p).await)),
        Params::AgentsMove(p) => arm!(answer(agents::session::move_to(f, c, p).await)),
        Params::AgentsProbe(p) => arm!(answer(agents::probe::probe(f, c, p).await)),
        Params::MessagesRetract(p) => arm!(answer(agents::deliver::retract(f, c, p).await)),
        Params::AgentsRole(p) => arm!(answer(manager::role(f, c, p).await)),
        Params::AgentsSlice(p) => arm!(answer(manager::slice(f, c, p).await)),
        Params::AgentsEntriesSubscribe(p) => answer(agents::session::entries_subscribe(f, c, p)),
        Params::AgentsEntriesUnsubscribe(p) => {
            answer(agents::session::entries_unsubscribe(f, c, p))
        }
        Params::AgentsToolInput(p) => answer(agents::session::tool_input(f, c, p)),
        Params::AgentsToolOutput(p) => answer(agents::session::tool_output(f, c, p)),
        Params::AgentsPause(p) => answer(agents::session::pause(f, c, p)),
        Params::AgentsBackgroundCancel(p) => {
            arm!(answer(
                agents::session::panel::background_cancel(f, c, p).await
            ))
        }
        Params::AgentsBackgroundOutput(p) => {
            answer(agents::session::panel::background_output(f, c, p))
        }
        Params::AgentsContextDrop(p) => {
            arm!(answer(agents::session::panel::context_drop(f, c, p).await))
        }
        Params::AgentsContextPin(p) => {
            arm!(answer(agents::session::panel::context_pin(f, c, p).await))
        }
        Params::AgentsConfig(p) => arm!(answer(agents::session::panel::config(f, c, p).await)),
        Params::AgentsExplain(p) => arm!(answer(agents::session::panel::explain(f, c, p).await)),
        Params::AgentsCompactPreview(p) => {
            arm!(answer(
                agents::session::panel::compact_preview(f, c, p).await
            ))
        }
        Params::AgentsHuddleStart(p) => arm!(answer(crate::runner::huddle::start(f, c, p).await)),
        Params::AgentsHuddleGet(p) => arm!(answer(crate::runner::huddle::get(f, c, p).await)),
        Params::AgentsGrants(p) => answer(f.core.agents.grants(c, p.id.as_str())),
        Params::AgentsGrantsRevoke(p) => {
            arm!(answer(
                f.core.agents.revoke_grant(c, p.id.as_str(), &p.grant).await
            ))
        }
        Params::AgentsWheelTake(p) => answer(agents::session::wheel_take(f, c, p)),
        Params::AgentsWheelGive(p) => arm!(answer(agents::session::wheel_give(f, c, p).await)),
        Params::AgentsWheelSaved(p) => answer(agents::session::wheel_saved(f, c, p)),
        Params::AgentsPair(p) => arm!(answer(agents::session::pair(f, c, p).await)),
        Params::AgentsFollow(p) => answer(crate::editor::follow(f, c, p)),
        Params::AgentsUnfollow(p) => answer(crate::editor::unfollow(f, c, p)),
        Params::ExecStart(p) => arm!(answer(exec::start(f, c, p).await)),
        Params::ExecGet(p) => arm!(answer(exec::get(f, c, p).await)),
        Params::ExecList(p) => arm!(answer(exec::list(f, c, p).await)),
        Params::ExecStop(p) => arm!(answer(exec::stop(f, c, p).await)),
        Params::ExecLog(p) => arm!(answer(exec::log(f, c, p).await)),
        Params::ExecBump(p) => arm!(answer(exec::bump(f, c, p).await)),
        Params::JobPropose(p) => arm!(answer(runner::propose(f, c, p).await)),
        Params::JobStartTask(p) => arm!(answer(runner::start_task(f, c, p).await)),
        Params::JobApprove(p) => arm!(answer(runner::approve(f, c, p).await)),
        Params::JobOrder(p) => arm!(answer(runner::order(f, c, p).await)),
        Params::JobBlock(p) => arm!(answer(runner::block(f, c, p).await)),
        Params::JobUnblock(p) => arm!(answer(runner::unblock(f, c, p).await)),
        Params::JobStop(p) => arm!(answer(runner::stop(f, c, p).await)),
        Params::JobStatus(p) => arm!(answer(runner::status(f, c, p).await)),
        Params::JobCard(p) => arm!(answer(runner::card(f, c, p).await)),
        Params::JobReply(p) => arm!(answer(runner::reply(f, c, p).await)),
        Params::JobDismiss(p) => arm!(answer(runner::dismiss(f, c, p).await)),
        Params::JobReassign(p) => arm!(answer(runner::reassign(f, c, p).await)),
        Params::JobResume(p) => arm!(answer(runner::resume(f, c, p).await)),
        Params::MatrixGet(p) => arm!(answer(matrix_gate::get(f, c, p).await)),
        Params::MatrixCheck(p) => arm!(answer(matrix_gate::check_method(f, c, p).await)),
        Params::PresenceSet(p) => arm!(answer(matrix_gate::presence(f, c, p).await)),
        Params::PlansGet(p) => arm!(answer(runner::effects::plans_get(f, c, p).await)),
        Params::PlansWrite(p) => arm!(answer(runner::effects::plans_write(f, c, p).await)),
        Params::ReportsGet(p) => arm!(answer(runner::effects::reports_get(f, c, p).await)),
        Params::DecisionsEffects(p) => {
            arm!(answer(runner::effects::decision_effects(f, c, p).await))
        }
        Params::BriefBuild(p) => arm!(answer(brief::build_method(f, c, p).await)),
        Params::BriefSet(p) => arm!(answer(brief::set(f, c, p).await)),
        Params::TimelineGet(p) => arm!(answer(timeline::get(f, c, p).await)),
        Params::BudgetGet(p) => arm!(answer(budget::get(f, c, p).await)),
        Params::BudgetTreePage(p) => arm!(answer(budget::tree(f, c, p).await)),
        Params::BudgetSet(p) => arm!(answer(budget::set(f, c, p).await)),
        Params::BudgetRaise(p) => arm!(answer(budget::raise(f, c, p).await)),
        Params::PaceGet(p) => arm!(answer(budget::pace(f, c, p).await)),
        Params::ForecastGet(p) => arm!(answer(forecast::get(f, c, p).await)),
        Params::ForecastPlan(p) => arm!(answer(forecast::plan(f, p).await)),
        Params::ForecastStart(p) => arm!(answer(forecast::start(f, c, p).await)),
        Params::ForecastSession(p) => arm!(answer(forecast::session(f, p).await)),
        Params::ForecastAccuracy(p) => arm!(answer(forecast::accuracy(f, p).await)),
        Params::SayStart(p) => arm!(answer(say::start(f, c, p).await)),
        Params::SayRevise(p) => arm!(answer(say::revise(f, c, p).await)),
        Params::SayEnd(p) => arm!(answer(say::end(f, c, p).await)),
        Params::RecordsImport(p) => arm!(answer(records::import(f, c, p).await)),
        Params::PastSubscribe(p) => arm!(answer(crate::agents::past::subscribe(f, c, p).await)),
        Params::PastSearch(p) => arm!(answer(crate::agents::past::search(f, c, p).await)),
        Params::PastOpen(p) => arm!(answer(crate::agents::past::open(f, c, p).await)),
        Params::PastResume(p) => arm!(answer(crate::agents::past::resume(f, c, p).await)),
        Params::PastStatus(p) => arm!(answer(crate::agents::past::status(f, c, p).await)),
        Params::PastRescan(p) => arm!(answer(crate::agents::past::rescan(f, c, p).await)),
        Params::RecordsStatus(p) => arm!(answer(records::status(f, c, p).await)),
        Params::RecordsConflict(p) => arm!(answer(records::conflict(f, c, p).await)),
        Params::RecordsResolve(p) => arm!(answer(records::resolve(f, c, p).await)),
        Params::RecordsWrite(p) => arm!(answer(records::write::records_write(f, c, p).await)),
        Params::RecordsRead(p) => arm!(answer(records::read::records_read(f, c, p).await)),
        Params::RecordsForgetRoot(p) => arm!(answer(records::forget_root(f, c, p).await)),
        Params::OutsideBind(p) => arm!(answer(crate::outside::bind(f, c, p).await)),
        Params::OutsideUnbind(p) => arm!(answer(crate::outside::unbind(f, c, p).await)),
        Params::OutsideBindings(p) => arm!(answer(crate::outside::list(f, c, p).await)),
        Params::MachinesReport(p) => arm!(answer(work::machines::report(f, c, p).await)),
        Params::MachinesMove(p) => arm!(answer(work::machines::move_to(f, c, p).await)),
        Params::CommentsAdd(p) => arm!(answer(work::comments::add(f, c, p).await)),
        Params::CommentsReply(p) => arm!(answer(work::comments::reply(f, c, p).await)),
        Params::CommentsList(p) => arm!(answer(work::comments::list(f, c, p).await)),
        Params::CommentsResolve(p) => arm!(answer(work::comments::resolve(f, c, p).await)),
        Params::MachinesList(p) => arm!(answer(work::machines::list(f, c, p).await)),
        Params::RunnersList(p) => arm!(answer(runners::methods::list(f, c, p).await)),
        Params::RunnersProbeHost(p) => arm!(answer(runners::methods::probe_host(f, c, p).await)),
        Params::RunnersAdd(p) => arm!(answer(runners::methods::add(f, c, p).await)),
        Params::RunnersCheck(p) => arm!(answer(runners::methods::check(f, c, p).await)),
        Params::RunnersBench(p) => arm!(answer(runners::methods::bench(f, c, p).await)),
        Params::RunnersSet(p) => arm!(answer(runners::methods::set(f, c, p).await)),
        Params::HistoryRegister(p) => arm!(answer(crate::history::wire::register(f, c, p).await)),
        Params::HistoryBatch(p) => arm!(answer(crate::history::wire::batch(f, c, p).await)),
        Params::HistoryResync(p) => arm!(answer(crate::history::wire::resync(f, c, p).await)),
        Params::HistoryUnregister(p) => {
            arm!(answer(crate::history::wire::unregister(f, c, p).await))
        }
        Params::HistoryRevertPreview(p) => {
            arm!(answer(crate::history::revert::preview(f, c, p).await))
        }
        Params::HistoryRevertApply(p) => {
            arm!(answer(crate::history::revert::apply(f, c, p).await))
        }
        Params::HistoryFork(p) => arm!(answer(crate::history::branches::fork(f, c, p).await)),
        Params::HistoryForkDrop(p) => {
            arm!(answer(crate::history::branches::drop_fork(f, c, p).await))
        }
        Params::HistoryCompare(p) => arm!(answer(crate::history::branches::compare(f, c, p).await)),
        Params::HistoryBlame(p) => arm!(answer(crate::history::views::blame(f, c, p).await)),
        Params::HistoryHunks(p) => arm!(answer(crate::history::views::hunks(f, c, p).await)),
        Params::GitBlame(p) => arm!(answer(crate::history::views::git_blame(f, c, p).await)),
        Params::GitBlameLine(p) => {
            arm!(answer(crate::history::views::git_blame_line(f, c, p).await))
        }
        Params::HistoryEolFit(p) => arm!(answer(crate::history::views::eol_fit(f, c, p).await)),
        Params::HistoryLinePositions(p) => {
            arm!(answer(crate::history::views::line_positions(f, c, p).await))
        }
        Params::GitStageHunk(p) => arm!(answer(crate::history::views::stage_hunk(f, c, p).await)),
        Params::HistoryHunksHead(p) => {
            arm!(answer(crate::history::views::hunks_head(f, c, p).await))
        }
        Params::HistoryTake(p) => arm!(answer(crate::history::branches::take(f, c, p).await)),
        Params::HistoryRedo(p) => arm!(answer(crate::history::branches::redo(f, c, p).await)),
        Params::HistoryOpHunks(p) => arm!(answer(crate::history::hunk::op_hunks(f, c, p).await)),
        Params::HistoryProvenance(p) => {
            arm!(answer(crate::history::hunk::provenance(f, c, p).await))
        }
        Params::HistoryRevertHunk(p) => {
            arm!(answer(crate::history::hunk::revert_hunk(f, c, p).await))
        }
        Params::RunnersUnbench(p) => arm!(answer(runners::methods::unbench(f, c, p).await)),
        Params::RunnersFeature(p) => arm!(answer(runners::methods::feature(f, c, p).await)),
        Params::JobsProjectAdd(p) => arm!(answer(runners::methods::project_add(f, c, p).await)),
        Params::JobsProjectList(p) => arm!(answer(runners::methods::project_list(f, c, p).await)),
        Params::JobsProjectRemove(p) => {
            arm!(answer(runners::methods::project_remove(f, c, p).await))
        }
        Params::RunnersRemove(p) => arm!(answer(runners::methods::remove(f, c, p).await)),
        Params::PluginsList(p) => arm!(answer(crate::plugins::list(f, c, p).await)),
        Params::PluginsApprove(p) => arm!(answer(crate::plugins::approve(f, c, p).await)),
        Params::PluginsDisable(p) => arm!(answer(crate::plugins::disable(f, c, p).await)),
        Params::RunnersKeys(p) => arm!(answer(runners::methods::keys(f, c, p).await)),
        Params::RunnersKeysHeld(p) => arm!(answer(runners::methods::keys_held(f, c, p).await)),
        Params::RunnersAudit(p) => arm!(answer(runners::methods::audit(f, c, p).await)),
        Params::RunnersDisk(p) => arm!(answer(runners::methods::disk(f, c, p).await)),
        Params::RunnersReclaim(p) => arm!(answer(runners::methods::reclaim(f, c, p).await)),
        Params::RunnersPin(p) => arm!(answer(runners::methods::pin(f, c, p).await)),
        Params::RunnersTelemetrySubscribe(p) => {
            arm!(answer(runners::methods::telemetry_subscribe(f, c, p).await))
        }
        Params::RunnersTelemetryRange(p) => {
            arm!(answer(runners::methods::telemetry_range(f, c, p).await))
        }
        Params::WorkConclusions(p) => arm!(answer(work::conclusions::get(f, c, p).await)),
        Params::ReviewEffects(p) => arm!(answer(work::task_effects::effects(f, c, p).await)),
        Params::AgentsPresenceSubscribe(p) => {
            arm!(answer(work::presence::subscribe(f, c, p).await))
        }
        Params::AgentsPresenceGet(p) => arm!(answer(work::presence::get(f, c, p).await)),
        Params::AgentsBufferWatch(p) => arm!(answer(crate::editor::watch(f, c, p).await)),
        Params::AgentsBufferUnwatch(p) => answer(crate::editor::unwatch(f, c, p)),
        Params::WorkMapSubscribe(p) => arm!(answer(work::map::subscribe(f, c, p).await)),
        Params::WorkMapSet(p) => answer(work::map::set(f, c, p)),
        Params::WorkTargetSet(p) => arm!(answer(work::map::target_set(f, c, p).await)),
        Params::WorkMapClose(p) => answer(work::map::close(f, c, p)),
        Params::WorkTrailSubscribe(p) => arm!(answer(work::trail::subscribe(f, c, p).await)),
        Params::WorkTrailClose(p) => answer(work::trail::close(f, c, p)),
        Params::WorkBoardSubscribe(p) => {
            arm!(answer(work::trail::board_subscribe(f, c, p).await))
        }
        Params::WorkTrailSet(p) => arm!(answer(work::trail::set(f, c, p).await)),
        Params::WorkScheduleSubscribe(p) => {
            arm!(answer(work::trail::schedule_subscribe(f, c, p).await))
        }
        Params::WorkScheduleSet(p) => arm!(answer(work::trail::schedule_set(f, c, p).await)),
        Params::WorkFlowSubscribe(p) => arm!(answer(work::trail::flow_subscribe(f, c, p).await)),
        Params::WorkFiles(p) => arm!(answer(work::edits::files(f, c, p).await)),
        Params::WorkHunks(p) => arm!(answer(work::edits::hunks(f, c, p).await)),
        Params::WorkFileAt(p) => arm!(answer(work::edits::file_at(f, c, p).await)),
        other => return Err(Box::new(other)),
    })
}
