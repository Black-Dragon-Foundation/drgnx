//! `comment_reply`: an agent's answer in a paragraph comment's thread (docs/develop/hub.md, "Paragraph comments").
//! The hub steered the comment to one session, the writer of its record; only that session may answer it.

use mimir::{BoxFuture, Tool};
use schemars::JsonSchema;
use serde::Deserialize;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReplyArgs {
    /// The comment's id, as the steer names it (comment:N)
    pub comment: String,
    /// Your answer: what you changed, or why not
    pub text: String,
}

pub struct CommentReply;

impl CoordTool for CommentReply {
    type Args = ReplyArgs;
    const NAME: &'static str = "comment_reply";
    const DESCRIPTION: &'static str = "Answer a comment the user left on a paragraph of a document you are writing (only one sent to you).";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReplyArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let Identity::Session { sid, .. } = who else {
                return Err("comments are answered by agents drgnx runs".into());
            };
            coord
                .hub()
                .comment_reply(sid, args.comment, args.text)
                .await
        })
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(CommentReply)]
}
