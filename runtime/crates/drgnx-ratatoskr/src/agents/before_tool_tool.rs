//! The `drgnx` server's `before_tool` tool (`docs/develop/hub.md`, "The `before_tool` tool"): what Codex's managed
//! PreToolUse hook (an `mcp_tool` handler, in the lock's read-only `/etc/codex/config.toml`) calls before each tool
//! Codex runs, the ones its own policy would run without asking included.
//!
//! - It runs the session's `before-tool` hooks and rules at the adapter's site (`hook_points::At::Adapter`, which
//!   takes no `change`), and answers in the hook's shape: a deny is `permissionDecision: "deny"` with the hub's words;
//!   anything else is `{}`, so Codex's own approvals still decide (never an `allow`, which would skip them).
//! - It is exempt from the hooks it runs: it is not behind the server's hook wrapper, a step named after a hub tool
//!   (itself included) is answered `{}` (hooked at the hub's server), and the seam records nothing for it.
//! - It is offered only to a Codex session whose hooks subscribe to a kind (`Sessions::mark_before_tool`).
//! - Codex fails the hook open on a timeout or an error, so this is a narrowing seam beside the approvals, which
//!   fail closed; the snapshot says so (`hooked.by_adapter`).

use std::path::PathBuf;
use std::sync::Weak;

use mimir::{ArgsError, BoxFuture, Tool, ToolResult};
use norn::hooks::{Decision, Outcome};
use norn::tools::{Ctx, Identity};
use serde_json::{Value, json};

use crate::front::Front;
use crate::hook_points::{self, At, Site, ToolCallInfo};

pub use super::lock::BEFORE_TOOL;

/// The kind of Codex's tool NAME as the hooks see it: its shell (reads and searches go through it too), its patch, its
/// image viewer, its plan; anything else (MCP tools among them) is `other`.
pub fn kind_of(name: &str) -> &'static str {
    match name {
        "exec_command" | "shell" | "local_shell" | "unified_exec" | "write_stdin" => "execute",
        "apply_patch" => "edit",
        "view_image" => "read",
        "update_plan" => "think",
        "web_search" => "fetch",
        _ => "other",
    }
}

/// The step the hook's ARGS (`tool_name`, `tool_input`, `tool_use_id`) describe; `None` for a hub tool, hooked at its
/// server (this tool among them).
pub fn call_info(args: &Value) -> Option<ToolCallInfo> {
    let name = args.get("tool_name")?.as_str()?;
    if hook_points::hub_tool_name(Some(name)) {
        return None;
    }
    let input = args.get("tool_input").cloned().unwrap_or(Value::Null);
    let command = input
        .get("cmd")
        .or_else(|| input.get("command"))
        .and_then(|c| {
            c.as_str().map(str::to_owned).or_else(|| {
                c.as_array().map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" ")
                })
            })
        });
    let paths: Vec<PathBuf> = ["path", "file_path"]
        .iter()
        .filter_map(|k| input.get(*k).and_then(Value::as_str))
        .map(PathBuf::from)
        .collect();
    Some(ToolCallInfo {
        kind: kind_of(name).to_owned(),
        name: Some(name.to_owned()),
        title: None,
        input,
        paths,
        command,
        step: None,
    })
}

/// The hook's answer for STEP's OUTCOME: a deny in PreToolUse's shape, else `{}`.
pub fn answer(step: &str, out: &Outcome) -> Value {
    match &out.decision {
        Decision::Deny(_) => json!({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": hook_points::refusal(step, out).unwrap_or_default(),
        }}),
        Decision::Proceed { .. } | Decision::Ask { .. } => json!({}),
    }
}

/// Session SID's step ARGS through its hooks at the adapter's site: the hook's answer.
pub async fn run(front: &Front, sid: &str, args: &Value) -> Value {
    let Some(mut call) = call_info(args) else {
        return json!({});
    };
    let session = front.core.agents.find(sid).ok();
    let site = match &session {
        Some(s) => s.hook_site(At::Adapter).await,
        None => Site {
            at: At::Adapter,
            session: sid.to_owned(),
            ..Site::default()
        },
    };
    call.step = session.as_ref().and_then(|s| s.current_step());
    // advice before the gate: a code commit before the task's red
    if let Some(s) = &session
        && let Some(reason) = crate::orch::advice::at_seam(front, &site, &call, s.cwd()).await
    {
        return json!({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }});
    }
    let out = hook_points::before_tool(front, &site, &call, None).await;
    answer(call.step_name(), &out)
}

/// The tool on a Codex session's socket.
pub struct BeforeTool {
    pub front: Weak<Front>,
}

impl Tool<Ctx> for BeforeTool {
    fn name(&self) -> &'static str {
        BEFORE_TOOL
    }

    fn description(&self) -> &'static str {
        "Called by Codex's managed PreToolUse hook, not by the agent: runs drgnx's before-tool hooks and rules on the \
         step about to run, and answers {} or a deny."
    }

    fn input_schema(&self) -> Value {
        json!({"type": "object", "properties": {
            "tool_name": {"type": "string"}, "tool_input": {}, "tool_use_id": {"type": "string"}},
            "required": ["tool_name"]})
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        match args.get("tool_name") {
            Some(Value::String(_)) => Ok(()),
            _ => Err(ArgsError {
                path: "tool_name".into(),
                message: "the hook's tool_name, a string".into(),
            }),
        }
    }

    fn call<'a>(&'a self, ctx: &'a Ctx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let Identity::Session { sid, .. } = &ctx.1 else {
                return ToolResult::Err("before_tool is a session's tool".into());
            };
            let Some(front) = self.front.upgrade() else {
                return ToolResult::Err("the hub is stopping".into());
            };
            ToolResult::Ok {
                text: run(&front, sid, &args).await.to_string(),
                structured: None,
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure: the names Codex's PreToolUse gives its tools, as the hooks' kinds.
    #[test]
    fn codex_tool_names_map_to_kinds() {
        for (name, kind) in [
            ("exec_command", "execute"),
            ("shell", "execute"),
            ("apply_patch", "edit"),
            ("view_image", "read"),
            ("update_plan", "think"),
            ("web_search", "fetch"),
            ("mcp__github__issue_read", "other"),
            ("something_new", "other"),
        ] {
            assert_eq!(kind_of(name), kind, "{name}");
        }
        let c = call_info(&json!({"tool_name": "exec_command", "tool_input": {"cmd": "rm -rf x"}}))
            .unwrap();
        assert_eq!(
            (c.kind.as_str(), c.command.as_deref()),
            ("execute", Some("rm -rf x"))
        );
        let c = call_info(&json!({"tool_name": "shell", "tool_input": {"command": ["ls", "-la"]}}))
            .unwrap();
        assert_eq!(c.command.as_deref(), Some("ls -la"));
        // a hub tool is hooked at its server, this one too
        assert!(call_info(&json!({"tool_name": "mcp__drgnx__before_tool"})).is_none());
        assert!(call_info(&json!({"tool_name": "mcp__drgnx__record_decision"})).is_none());
    }

    fn outcome(decision: Decision) -> Outcome {
        Outcome {
            decision,
            decided_by: None,
            annotations: Vec::new(),
            provenance: Vec::new(),
        }
    }

    // [D] pure: a deny answers in the PreToolUse hook's shape with the hub's words; anything else leaves the step to
    // Codex's own approvals (never an `allow`, which would skip them, and never a changed input: the adapter's site
    // takes none).
    #[test]
    fn a_deny_answers_in_the_hooks_shape() {
        let a = answer("exec_command", &outcome(Decision::Deny("no rm".into())));
        assert_eq!(a["hookSpecificOutput"]["hookEventName"], "PreToolUse");
        assert_eq!(a["hookSpecificOutput"]["permissionDecision"], "deny");
        let why = a["hookSpecificOutput"]["permissionDecisionReason"]
            .as_str()
            .unwrap();
        assert!(
            why.contains("drgnx refused exec_command") && why.contains("«no rm»"),
            "{why}"
        );
        for d in [
            Decision::Proceed { changed: None },
            Decision::Ask {
                changed: Some(json!({"x": 1})),
            },
        ] {
            assert_eq!(answer("exec_command", &outcome(d)), json!({}));
        }
    }
}
