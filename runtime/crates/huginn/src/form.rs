//! Settings files: one `(HEAD :version 1 META… ENTRY… SECTION…)` form, read into entries and problems (Task 3).

use crate::read::{Limits, Refusal};
use crate::span::Span;
use crate::value::Node;

/// A settings file as read: its head, its meta (`:version`, `:roots`, `:project`), its entries in file order, and
/// the entries that could not be read (the rest of the file stands).
#[derive(Debug, Clone, PartialEq)]
pub struct SettingsFile {
    pub head: String,
    pub meta: Vec<(String, Node)>,
    pub entries: Vec<Entry>,
    pub problems: Vec<Problem>,
}

/// `(VAR VALUE)` or `(VAR VALUE :merge KIND)`, where it sits (the sections around it) and its span. An `:eval`
/// section is an entry with `var` `":eval"`, only in a `drgnx-workspace-settings` file.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub var: String,
    pub value: Node,
    pub merge: Option<String>,
    pub scope: Vec<ScopeStep>,
    pub span: Span,
}

/// One section around an entry: `(:mode MODE …)` or `(:dir "D/" …)`; a `:mode` may sit inside a `:dir`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScopeStep {
    Mode(String),
    Dir(String),
}

/// An entry that could not be read, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub span: Span,
    pub message: String,
}

/// The settings file in `bytes`, whose one top-level form must have head `expect_head` and `:version 1`.
pub fn parse_settings(
    bytes: &[u8],
    expect_head: &str,
    limits: Limits,
) -> Result<SettingsFile, Refusal> {
    let _ = (bytes, expect_head, limits);
    todo!("Task 3")
}
