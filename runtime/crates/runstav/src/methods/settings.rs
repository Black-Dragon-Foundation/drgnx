//! The settings' methods (unified-settings design §12; docs/develop/hub.md, "Settings history"):
//!
//! - `settings/record`: the editor reports a change of a settings file (the UI's, a hand edit's, your Lisp's effect)
//!   and the hub records it as one user-class transaction on entities of kind `option` (`norn::write::options`).
//!   The file stays the truth; the store keeps its history. A repository's `.drgnx/settings.el` comes in through
//!   `graph/put-parsed` instead (the scan's door).

use super::method;
use crate::registry::Method;
use crate::types::{Bounded, Text};
use crate::wire::{Error, ErrorCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// An option's id (`option:global:<var>`, `option:shared/<project>:…`; norn checks the grammar).
pub type OptionIdText = Bounded<String, 1024>;

/// One setting's change.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct OptionChange {
    pub id: OptionIdText,
    /// The new value as printed Lisp; `null` when the setting was removed. One that looks like a secret is recorded
    /// as a change with no value (`redacted`).
    #[serde(default)]
    pub value: Option<Text>,
    /// The file it is in (`settings.el`, a workspace file).
    pub file: Bounded<String, 4096>,
    /// Its line there (none for a removed setting).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct RecordParams {
    /// The changes of one write of one file (one project: the ids').
    pub changes: Bounded<Vec<OptionChange>, 1000>,
    /// `ui:settings`, `file:<name>` (a change drgnx did not make) or `lisp:<file>` (your Lisp's effect).
    pub tool: Bounded<String, 256>,
    /// The request's key (a hash of the file's stamp): a repeat answers the first answer and writes nothing.
    pub req: Bounded<String, 256>,
    /// The tx this change undoes (per-setting undo).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reverts: Option<u64>,
}

/// `settings/record`'s answer: the transaction.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordAnswer {
    pub tx: i64,
}

/// No whitespace or control character in S (a tool's name, a key).
fn plain(s: &str) -> bool {
    !s.is_empty() && !s.chars().any(|c| c.is_whitespace() || c.is_control())
}

/// Whether TOOL names one of the editor's doors: `ui:settings`, `file:<name>` or `lisp:<file>`.
pub fn is_record_tool(tool: &str) -> bool {
    tool == "ui:settings"
        || ["file:", "lisp:"]
            .iter()
            .any(|p| tool.strip_prefix(p).is_some_and(plain))
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

fn check_record(p: &RecordParams) -> Result<(), Error> {
    if !is_record_tool(&p.tool) {
        return Err(invalid(
            "tool",
            "the tool is ui:settings, file:<name> or lisp:<file>",
        ));
    }
    if !plain(&p.req) {
        return Err(invalid(
            "req",
            "a request key: no whitespace or control character",
        ));
    }
    if p.changes.is_empty() {
        return Err(invalid("changes", "a record holds at least one change"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![method!(
        "settings/record", SettingsRecord(RecordParams) -> RecordAnswer,
        classes: [User], writes: true, home: Front,
        doc: "one write of a settings file recorded as one user-class tx on kind option (data {value, file, line}; null value: removed; a value that looks like a secret is never stored: no value, redacted true), its tool the editor's door (ui:settings, file:<name>, lisp:<file>), keyed by req so a retry is one tx; the project from the ids",
        check: check_record,
    )]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::find;
    use serde_json::json;

    #[test]
    fn the_tool_is_one_of_the_editors_doors() {
        for t in [
            "ui:settings",
            "file:settings.el",
            "file:workspaces/x.el",
            "lisp:config.el",
        ] {
            assert!(is_record_tool(t), "{t}");
        }
        for t in [
            "",
            "ui:",
            "ui:other",
            "file:",
            "lisp:",
            "file:a b",
            "lisp:x\n",
            "scan",
            "import",
            "mcp:settings_change",
            "proto:settings/record",
        ] {
            assert!(!is_record_tool(t), "{t:?}");
        }
        let m = find("settings/record").unwrap();
        let ok = json!({"changes": [{"id": "option:global:fill-column", "value": "80", "file": "settings.el", "line": 3}],
                        "tool": "ui:settings", "req": "r1"});
        assert!((m.decode)(&ok).is_ok());
        let removed = json!({"changes": [{"id": "option:global:x", "value": null, "file": "settings.el"}],
                             "tool": "file:settings.el", "req": "r2", "reverts": 7});
        assert!((m.decode)(&removed).is_ok());
        for (key, bad, path) in [
            ("tool", json!("scan"), "tool"),
            ("req", json!("a b"), "req"),
            ("req", json!(""), "req"),
            ("changes", json!([]), "changes"),
        ] {
            let mut p = ok.clone();
            p[key] = bad;
            assert_eq!(
                (m.decode)(&p).err().unwrap().path.as_deref(),
                Some(path),
                "{key}"
            );
        }
    }
}
