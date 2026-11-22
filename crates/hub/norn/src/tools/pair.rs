//! The edit tools of a chat in your project (pair mode; docs/guide/pair-mode.md): `read_file`, `edit_file` and
//! `write_file`.  The checkout is read-only to the agent's own tools and commands; these go through the hub's door,
//! which applies each write in the editor that has the file open ([`super::Hub::pair_read`],
//! [`super::Hub::pair_write`]).  Every project chat has them from its start; with pair mode off the edit tools answer
//! "pair mode is off; ask the user to turn it on".

use mimir::{BoxFuture, Tool};
use schemars::JsonSchema;
use serde::Deserialize;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

/// The tools of a chat in a project, in this order.
pub const PAIR_TOOLS: [&str; 3] = ["read_file", "edit_file", "write_file"];

/// A pair write as the hub's door takes it.
#[derive(Clone, Debug, PartialEq)]
pub enum PairWrite {
    /// Replace the one occurrence of `old` in the editor's text with `new`.
    Edit {
        path: String,
        old: String,
        new: String,
    },
    /// The whole text of the file.
    Whole { path: String, content: String },
}

fn session(who: &Identity) -> Result<&str, String> {
    match who {
        Identity::Session { sid, .. } => Ok(sid),
        _ => Err("only a chat drgnx runs edits your checkout".into()),
    }
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ReadArgs {
    /// The file's absolute path, inside your project
    pub path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditArgs {
    /// The file's absolute path, inside your project
    pub path: String,
    /// The exact text to replace: it must occur exactly once in the file as the editor has it
    pub old: String,
    /// The text that replaces it
    pub new: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WriteArgs {
    /// The file's absolute path, inside your project
    pub path: String,
    /// The file's whole new text (an existing file must have been read with read_file first)
    pub content: String,
}

pub struct ReadFile;

impl CoordTool for ReadFile {
    type Args = ReadArgs;
    const NAME: &'static str = "read_file";
    const DESCRIPTION: &'static str = "Read a file of your project as the user's editor has it (unsaved edits \
        included). Read a file with this before you write_file it.";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReadArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move { coord.hub().pair_read(session(who)?, args.path).await })
    }
}

pub struct EditFile;

impl CoordTool for EditFile {
    type Args = EditArgs;
    const NAME: &'static str = "edit_file";
    const DESCRIPTION: &'static str = "Edit a file of your project in the user's editor: replace the one \
        occurrence of old with new. Your own edit tools and commands cannot write the project; this can, with pair \
        mode on. A refusal says why; nothing of a refused edit is applied.";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: EditArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let w = PairWrite::Edit {
                path: args.path,
                old: args.old,
                new: args.new,
            };
            coord.hub().pair_write(session(who)?, w).await
        })
    }
}

pub struct WriteFile;

impl CoordTool for WriteFile {
    type Args = WriteArgs;
    const NAME: &'static str = "write_file";
    const DESCRIPTION: &'static str = "Write a file of your project in the user's editor: its whole new text. An \
        existing file must have been read with read_file first. Your own edit tools and commands cannot write the \
        project; this can, with pair mode on.";
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: WriteArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let w = PairWrite::Whole {
                path: args.path,
                content: args.content,
            };
            coord.hub().pair_write(session(who)?, w).await
        })
    }
}

/// This file's tools, in [`PAIR_TOOLS`]' order.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ReadFile), guarded(EditFile), guarded(WriteFile)]
}
