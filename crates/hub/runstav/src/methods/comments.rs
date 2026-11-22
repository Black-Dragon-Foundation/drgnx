//! Paragraph comments (docs/develop/hub.md, "Paragraph comments"): a thread on one paragraph of a spec, plan, decision
//! or task, kept as a `comment` record with a `comments_on` link whose data is its [`Anchor`].  The hub steers a new
//! comment to the record's writer (never cancelling its turn), and that agent answers with the `comment_reply` tool.

use super::method;
use crate::registry::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Where a thread sits: the paragraph under the headings HEADING, found by KEY (a digest of its text, whitespace
/// folded) and shown by QUOTE.  `state`: `here` (the paragraph is as it was), `moved` (it was rewritten: the thread
/// follows the paragraph that replaced it) or `removed` (gone: the quote is kept).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Anchor {
    /// The headings above the paragraph, outermost first.
    #[serde(default)]
    pub heading: Vec<String>,
    /// 16 hex digits; on `comments/add`, empty: the paragraph is found by `quote`.
    #[serde(default)]
    pub key: String,
    /// The paragraph's text, at most 200 characters.
    #[serde(default)]
    pub quote: String,
    #[serde(default = "here")]
    pub state: String,
}

fn here() -> String {
    "here".into()
}

/// `comments/add`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AddParams {
    /// The record commented on: `spec:ID`, `plan:ID`, `decision:N` or `task:ID`.
    pub record: String,
    /// The paragraph: its key, or its text as `quote` (the hub finds it and fills the rest).
    pub anchor: Anchor,
    pub text: String,
}

/// `comments/add`'s answer.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Added {
    pub comment: String,
    /// The session it was steered to; none: no agent is writing the record, and the thread waits for one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_to: Option<String>,
    pub anchor: Anchor,
}

/// `comments/reply`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReplyParams {
    /// Any comment of the thread.
    pub comment: String,
    pub text: String,
}

/// `comments/list`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ListParams {
    pub record: String,
}

/// `comments/resolve`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ResolveParams {
    /// Any comment of the thread.
    pub comment: String,
}

/// One comment.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Comment {
    pub id: String,
    pub text: String,
    /// `user` or the session that answered.
    pub author: String,
    pub at: f64,
}

/// A thread: its first comment, where it sits, and the replies in order.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Thread {
    pub root: Comment,
    pub anchor: Anchor,
    pub replies: Vec<Comment>,
    /// The session it was steered to; none: it waits ("no agent is writing it").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_to: Option<String>,
    #[serde(default)]
    pub resolved: bool,
}

/// Every thread of a record, oldest first.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Threads {
    pub threads: Vec<Thread>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "comments/add", CommentsAdd(AddParams) -> Added,
            classes: [User], writes: true,
            doc: "a comment on a paragraph of a spec, plan, decision or task: a new thread, steered to the agent writing the record (never cancelling its turn); with none, it waits",
        ),
        method!(
            "comments/reply", CommentsReply(ReplyParams) -> Comment,
            classes: [User], writes: true,
            doc: "the user's reply in a comment's thread, steered to the agent it was sent to",
        ),
        method!(
            "comments/list", CommentsList(ListParams) -> Threads,
            classes: [User], writes: false,
            doc: "a record's comment threads: each one's anchor (here, moved or removed), replies, and the agent it went to",
        ),
        method!(
            "comments/resolve", CommentsResolve(ResolveParams) -> bool,
            classes: [User], writes: true,
            doc: "a comment's thread marked resolved",
        ),
    ]
}
