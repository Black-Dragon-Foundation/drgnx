//! `huddle_reply`: an agent's position in a huddle (docs/develop/coordination.md, "Huddles").  The hub quotes it to
//! the other agent as that agent's text, never as an instruction, and it never answers a card; at most two replies
//! each.  Agreement (both propose the same decision) becomes a card for the user; nothing is recorded until the user
//! decides.

use mimir::{BoxFuture, Tool};
use schemars::JsonSchema;
use serde::Deserialize;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReplyArgs {
    /// The huddle's id, as its brief names it
    pub huddle: String,
    /// Your position: what you changed or decided and why, in a few lines
    pub text: String,
    /// The decision you propose to the user, if any (the same words as the other agent's mean you agree)
    #[serde(default)]
    pub proposal: Option<String>,
}

pub struct HuddleReply;

impl CoordTool for HuddleReply {
    type Args = ReplyArgs;
    const NAME: &'static str = "huddle_reply";
    const DESCRIPTION: &'static str = "State your position in a huddle the hub opened with another agent about a \
        clash between your work and theirs (at most two replies). The user decides; an agreement is only proposed.";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReplyArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let Identity::Session { sid, .. } = who else {
                return Err("huddles are for agents drgnx runs".into());
            };
            coord
                .hub()
                .huddle_reply(sid, args.huddle, args.text, args.proposal)
                .await
        })
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(HuddleReply)]
}
