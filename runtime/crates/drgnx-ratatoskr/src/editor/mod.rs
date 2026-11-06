//! Agents in the editor: the follow feed ([`follow`]; docs/develop/hub.md, "The follow feed").

pub mod follow;

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::editor::{FollowParams, UnfollowParams};
use runstav::registry::Class;
use runstav::wire::Error;

/// `agents/follow`: the connection's view follows a session (the user's).
pub fn follow(f: &Front, c: &Caller, p: FollowParams) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(crate::agents::session::refuse(
            "only the user follows an agent",
        ));
    }
    f.core.agents.find(p.session.as_str())?;
    f.follows
        .follow(c.conn_id, p.view.0, p.session.as_str().to_string());
    Ok(true)
}

/// `agents/unfollow`: the connection's view follows nothing any more.
pub fn unfollow(f: &Front, c: &Caller, p: UnfollowParams) -> Result<bool, Error> {
    Ok(f.follows.unfollow(c.conn_id, p.view.0))
}
