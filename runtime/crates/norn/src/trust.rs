//! Trust marking (Task 10; storage §5.5): every text field with its author; agent and outside-agent text is untrusted
//! data wherever an agent reads it, the caller's own included, and is fenced.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 10 removes this line.

use serde::{Deserialize, Serialize};
use urdr::graph::Class;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Trust {
    /// User-class and parsed text.
    User,
    /// Classes `agent` and `ext`.
    Untrusted,
}

/// A text field with its author, from `field_tx` → `tx`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Authored {
    pub text: String,
    pub by: String,
    pub class: Class,
    pub tx: i64,
    pub project: Option<String>,
    pub trust: Trust,
}

/// `<untrusted-data by="BY" project="PROJECT">TEXT</untrusted-data>`, every case-insensitive `</untrusted-data` in
/// TEXT escaped as `<\/untrusted-data`; BY and PROJECT one line of 80, `"` escaped.
pub fn fence(text: &str, by: &str, project: &str) -> String {
    todo!("Task 10")
}
