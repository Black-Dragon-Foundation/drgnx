//! The agent core's methods, routed (agent system part 1, Task 0): every method the plan adds, and `agents/*` and
//! `job/*` (which the hub now serves itself), go to the function of the module whose task fills it.  Until then each
//! answers `internal`, "not yet".  This file's arms are Task 0's: a task fills its own module's functions and state
//! ([`Core`]'s field), never this match.
//!
//! | Methods | Module | Task |
//! |---|---|---|
//! | `agents/{list,start,get,stop,kill,permission,do}` | [`crate::agents::session`] | 8a |
//! | `agents/send` | [`crate::agents::session`] | 8b |
//! | `agents/move` | [`crate::agents::session`] | 26 |
//! | `messages/retract` | [`crate::agents::deliver`] | 24 |
//! | `agents/role`, `agents/slice` | [`crate::manager`] | 25 |
//! | `exec/*` | [`crate::exec`] | 11 |
//! | `job/{propose,start-task,approve,order,block,unblock,stop,status}` | [`crate::runner`] | 16a |
//! | `job/{card,reply,dismiss,reassign,resume}` | [`crate::runner`] | 16b |
//! | `matrix/*`, `presence/set` | [`crate::matrix_gate`] | 12 |
//! | `plans/*`, `reports/get`, `decisions/effects` | [`crate::runner::effects`] | 21 |
//! | `brief/*` | [`crate::brief`] | 22 |
//! | `timeline/get` | [`crate::timeline`] | 19 |
//! | `budget/*`, `pace/get` | [`crate::budget`] | 20 |
//! | `records/{import,status}` | [`crate::records`] | 14 |
//! | `records/{proposals,decide}` | [`crate::records`] | 14b |

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
    use crate::{agents, brief, budget, exec, manager, matrix_gate, records, runner, timeline};
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
        Params::MessagesRetract(p) => answer(agents::deliver::retract(f, c, p).await),
        Params::AgentsRole(p) => answer(manager::role(f, c, p).await),
        Params::AgentsSlice(p) => answer(manager::slice(f, c, p).await),
        Params::ExecStart(p) => answer(exec::start(f, c, p).await),
        Params::ExecGet(p) => answer(exec::get(f, c, p).await),
        Params::ExecList(p) => answer(exec::list(f, c, p).await),
        Params::ExecStop(p) => answer(exec::stop(f, c, p).await),
        Params::ExecLog(p) => answer(exec::log(f, c, p).await),
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
        Params::RecordsImport(p) => answer(records::import(f, c, p).await),
        Params::RecordsStatus(p) => answer(records::status(f, c, p).await),
        Params::RecordsProposals(p) => answer(records::proposals(f, c, p).await),
        Params::RecordsDecide(p) => answer(records::decide(f, c, p).await),
        other => return Err(Box::new(other)),
    })
}

#[cfg(test)]
mod tests {
    use runstav::registry::{Home, registry};

    /// Every method the front serves that is not one of the older parts' is routed here: the agent core's families.
    #[test]
    fn every_agent_core_method_is_a_front_method() {
        let core = [
            "agents/",
            "exec/",
            "job/",
            "matrix/",
            "plans/",
            "brief/",
            "reports/",
            "timeline/",
            "budget/",
            "records/",
        ];
        for m in registry() {
            if core.iter().any(|p| m.name.starts_with(p))
                || [
                    "presence/set",
                    "messages/retract",
                    "decisions/effects",
                    "pace/get",
                ]
                .contains(&m.name)
            {
                assert_eq!(m.home, Home::Front, "{}", m.name);
            }
        }
    }
}
