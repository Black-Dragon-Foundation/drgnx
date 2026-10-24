//! One session: started on a profile with its lock and sandbox, its permissions answered by the user (or the matrix),
//! its snapshot and entries in records-2 shapes (`runstav::methods::agents::{Snapshot, Entry}`) so the mirror and
//! the cockpit read them unchanged (Task 8a); prompts that queue or steer, never cancel, redacted transcripts and the
//! step stream (Task 8b); `agents/move` (Task 26).

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Empty;
use runstav::methods::agents::{
    ById, DoParams, MoveParams, PermissionParams, SendParams, Sessions, StartParams, Started,
    Transcript,
};
use runstav::wire::Error;

pub async fn list(_: &Front, _: &Caller, _: Empty) -> Result<Sessions, Error> {
    Err(not_yet("agents/list", "8a"))
}

pub async fn start(_: &Front, _: &Caller, _: StartParams) -> Result<Started, Error> {
    Err(not_yet("agents/start", "8a"))
}

pub async fn get(_: &Front, _: &Caller, _: ById) -> Result<Transcript, Error> {
    Err(not_yet("agents/get", "8a"))
}

pub async fn send(_: &Front, _: &Caller, _: SendParams) -> Result<bool, Error> {
    Err(not_yet("agents/send", "8b"))
}

pub async fn stop(_: &Front, _: &Caller, _: ById) -> Result<bool, Error> {
    Err(not_yet("agents/stop", "8a"))
}

pub async fn kill(_: &Front, _: &Caller, _: ById) -> Result<bool, Error> {
    Err(not_yet("agents/kill", "8a"))
}

pub async fn permission(_: &Front, _: &Caller, _: PermissionParams) -> Result<bool, Error> {
    Err(not_yet("agents/permission", "8a"))
}

pub async fn do_op(_: &Front, _: &Caller, _: DoParams) -> Result<bool, Error> {
    Err(not_yet("agents/do", "8a"))
}

pub async fn move_to(_: &Front, _: &Caller, _: MoveParams) -> Result<Started, Error> {
    Err(not_yet("agents/move", "26"))
}
