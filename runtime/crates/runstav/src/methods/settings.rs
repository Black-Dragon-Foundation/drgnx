//! The settings' methods (unified-settings design §12; docs/develop/hub.md, "Settings history"):
//!
//! - `settings/record`: the editor reports a change of a settings file (the UI's, a hand edit's, your Lisp's effect)
//!   and the hub records it as one user-class transaction on entities of kind `option` (`norn::write::options`).
//!   The file stays the truth; the store keeps its history. A repository's `.drgnx/settings.el` comes in through
//!   `graph/put-parsed` instead (the scan's door).
//! - Agents' changes (design §13; Task 32): the tools `settings_get` and `settings_change` ask the editor through two
//!   events, `settings/explain` ([`Explain`]) and `settings/proposed` ([`Proposed`]), and the editor answers with
//!   `settings/explained` and `settings/confirm`. The editor writes the file; the hub never does.

use super::method;
use crate::registry::Method;
use crate::types::{Bounded, JsonObject, Text};
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

/// Which file an agent's setting is in: `settings.el` (global), the private workspace file or the shared
/// `.drgnx/settings.el` of the session's project.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum SettingScope {
    Global,
    Private,
    Shared,
}

impl SettingScope {
    /// `global`, `private` or `shared`.
    pub fn parse(text: &str) -> Option<SettingScope> {
        match text {
            "global" => Some(SettingScope::Global),
            "private" => Some(SettingScope::Private),
            "shared" => Some(SettingScope::Shared),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            SettingScope::Global => "global",
            SettingScope::Private => "private",
            SettingScope::Shared => "shared",
        }
    }
}

/// The `settings/proposed` event (to the editor): an agent's change under a grant, recorded as the proposed tx `tx`.
/// The editor checks it again, writes it to the file SCOPE names (under ROOT for a project's), and answers
/// `settings/confirm`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Proposed {
    pub tx: i64,
    pub scope: SettingScope,
    pub name: String,
    /// The value as printed Lisp: read as data by the hub, never evaluated.
    pub value: String,
    /// The session's folder: a job's task folder, or the checkout it started in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    /// Who asks (`agent:SID`).
    pub agent: String,
    pub reason: String,
}

/// The `settings/explain` event (to the editor): an agent's `settings_get`; the editor answers `settings/explained`
/// with the same `req`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Explain {
    pub req: u64,
    pub scope: SettingScope,
    /// None: every setting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub names: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ConfirmParams {
    /// The proposed tx of `settings/proposed`.
    pub tx: u64,
    /// The editor wrote the change; false: it refused it (the tx is undone).
    pub ok: bool,
    /// Why the editor refused it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<Bounded<String, 4096>>,
}

/// What `settings/confirm` did with the proposed tx.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfirmState {
    Accepted,
    Reverted,
    /// A refusal met a later change of the same setting: nothing undone.
    Blocked,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConfirmAnswer {
    pub state: ConfirmState,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ExplainedParams {
    /// The `req` of `settings/explain`.
    pub req: u64,
    /// One object per setting (`drgnx-settings-explain`'s answer).
    pub settings: Bounded<Vec<JsonObject>, 1000>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "settings/record", SettingsRecord(RecordParams) -> RecordAnswer,
            classes: [User], writes: true, home: Front,
            doc: "one write of a settings file recorded as one user-class tx on kind option (data {value, file, line}; null value: removed; a value that looks like a secret is never stored: no value, redacted true), its tool the editor's door (ui:settings, file:<name>, lisp:<file>), keyed by req so a retry is one tx; the project from the ids",
            check: check_record,
        ),
        method!(
            "settings/confirm", SettingsConfirm(ConfirmParams) -> ConfirmAnswer,
            classes: [User], writes: true, home: Front,
            doc: "the editor's answer to settings/proposed: ok accepts the agent's proposed tx (the editor wrote the file), else it is reverted (blocked when a later change of the setting came first); the agent gets a message either way; only a proposed tx of the tool mcp:settings_change",
        ),
        method!(
            "settings/explained", SettingsExplained(ExplainedParams) -> bool,
            classes: [User], writes: false, home: Front,
            doc: "the editor's answer to settings/explain (one object per setting) for the settings_get waiting on req; false when none waits (it timed out)",
        ),
    ]
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
