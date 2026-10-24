//! The supervisor (Task 23; `docs/guide/agents.md`): rules per session and job with thresholds per kind of work —
//! `silent`, `repeat`, `no-progress`, `dead-wait`, `lease`, `refusals`, `unrecorded`, `manager-context` — each
//! pausing the agent after its tool call and making a `supervisor` card with fixes (and the `supervisor` event).
//! No model call.  Not the hub's own `ensure`/`stop` ([`crate::supervise`]).

/// The rules' state per session and job (Task 23 fills it).
#[derive(Default)]
pub struct Supervisor {}
