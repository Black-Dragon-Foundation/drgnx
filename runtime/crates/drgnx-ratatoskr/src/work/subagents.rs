//! Claude Code's subagents under their parent (docs/develop/work-space.md, "Subagents"): a subagent's nested tool
//! calls carry `_meta.claudeCode.parentToolUseId`, the id of the parent's `Task` tool call that started it. Grouped
//! by it, each subagent is a child of the session, `agent:SID/TOOLID` on the map, with its own steps (each step keeps
//! `parent_tool`), sharing the parent's worktree; its spend is in the parent's. Without a parent id the steps stay the
//! parent's (the trail says "subagent steps not separated").
//!
//! The hub does not advertise `capabilities.subagents`: that form makes child sessions the hub did not start.

use serde_json::Value;

/// A tool call of a session as the hub folded it.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolCall {
    /// Its `toolCallId`.
    pub id: String,
    /// `_meta.claudeCode.toolName`.
    pub name: Option<String>,
    /// `_meta.claudeCode.parentToolUseId`: the `Task` call of the subagent that made it.
    pub parent: Option<String>,
    pub raw_input: Option<Value>,
}

/// One subagent.
#[derive(Clone, Debug, PartialEq)]
pub struct Child {
    pub parent_session: String,
    /// The `Task` tool call that started it.
    pub parent_tool: String,
    /// Its subagent type (`rawInput.subagent_type`), else `subagent`.
    pub name: String,
    /// What it was asked (`rawInput.description`).
    pub description: String,
    /// Its tool calls, in order.
    pub steps: Vec<String>,
}

impl Child {
    /// Its item on the map.
    pub fn item_id(&self) -> String {
        format!("agent:{}/{}", self.parent_session, self.parent_tool)
    }
}

/// SESSION's subagents among its tool CALLS (in the order they began), in the order each first appeared.
pub fn group(session: &str, calls: &[ToolCall]) -> Vec<Child> {
    let mut kids: Vec<Child> = Vec::new();
    for c in calls {
        let Some(parent) = c.parent.as_deref() else {
            continue;
        };
        if let Some(k) = kids.iter_mut().find(|k| k.parent_tool == parent) {
            k.steps.push(c.id.clone());
            continue;
        }
        let input = calls
            .iter()
            .find(|t| t.id == parent)
            .and_then(|t| t.raw_input.as_ref());
        let field = |k: &str| {
            input
                .and_then(|i| i.get(k))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        };
        kids.push(Child {
            parent_session: session.to_string(),
            parent_tool: parent.to_string(),
            name: field("subagent_type").unwrap_or("subagent").to_string(),
            description: field("description").unwrap_or_default().to_string(),
            steps: vec![c.id.clone()],
        });
    }
    kids
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn call(id: &str, name: &str, parent: Option<&str>, raw: Option<Value>) -> ToolCall {
        ToolCall {
            id: id.into(),
            name: Some(name.into()),
            parent: parent.map(str::to_string),
            raw_input: raw,
        }
    }

    /// Pattern D. Two `Task` calls, each with nested calls interleaved, make two children with their own steps, named
    /// and described from the `Task` call's input; the parent's own calls stay its own.
    #[test]
    fn nested_updates_group_by_parent_tool_use() {
        let calls = [
            call(
                "t1",
                "Task",
                None,
                Some(json!({"subagent_type": "Explore", "description": "find the cache"})),
            ),
            call("r1", "Read", Some("t1"), None),
            call(
                "t2",
                "Task",
                None,
                Some(json!({"description": "check the tests"})),
            ),
            call("g2", "Grep", Some("t2"), None),
            call("r2", "Read", Some("t1"), None),
            call("e0", "Edit", None, None),
        ];
        let kids = group("a1", &calls);
        assert_eq!(
            kids,
            [
                Child {
                    parent_session: "a1".into(),
                    parent_tool: "t1".into(),
                    name: "Explore".into(),
                    description: "find the cache".into(),
                    steps: vec!["r1".into(), "r2".into()],
                },
                Child {
                    parent_session: "a1".into(),
                    parent_tool: "t2".into(),
                    name: "subagent".into(),
                    description: "check the tests".into(),
                    steps: vec!["g2".into()],
                },
            ]
        );
        assert_eq!(kids[0].item_id(), "agent:a1/t1");
    }

    /// Pattern D. A `Task` call whose nested calls carry no parent id (an adapter that does not send it) makes no child:
    /// its steps stay the parent's.
    #[test]
    fn without_parent_id_stays_in_the_parent() {
        let calls = [
            call("t1", "Task", None, Some(json!({"description": "find it"}))),
            call("r1", "Read", None, None),
            call("r2", "Read", None, None),
        ];
        assert_eq!(group("a1", &calls), []);
        assert_eq!(group("a1", &[]), []);
    }
}
