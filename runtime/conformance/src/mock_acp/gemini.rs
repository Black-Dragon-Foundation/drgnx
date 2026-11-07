//! The Gemini personality (gemini --acp): `loadSession` only.  No list, fork, resume or close (they answer -32601),
//! no usage or rate-limit notices.  An `--admin-policy FILE` is checked as Gemini CLI 0.67's loader checks it, and
//! logged as loaded or dropped (Gemini runs on either way).

use serde_json::{Value, json};

pub fn session_caps() -> Value {
    json!({})
}

pub fn after_turn(_sid: &str, _turn: u64, _prompt_len: usize) -> Vec<(&'static str, Value)> {
    Vec::new()
}

/// What `session/new` and `session/load` log for Gemini: nothing the CLI reads is advertised; `admin_policy` is
/// `loaded`, `dropped: WHY` or null (no `--admin-policy`).
pub fn note(argv: &[String]) -> Value {
    let policy = argv.windows(2).find(|w| w[0] == "--admin-policy").map(|w| {
        match std::fs::read_to_string(&w[1]) {
            Ok(text) => match problem(&text) {
                None => "loaded".to_string(),
                Some(why) => format!("dropped: {why}"),
            },
            // a missing file is no policy at all, silently (`toml-loader.ts:177-180`)
            Err(e) => format!("dropped: {e}"),
        }
    });
    json!({"gemini": "loadSession only", "admin_policy": policy})
}

/// What drgnx's Gemini fork (`--panel-policy engine|short`; none: the stock adapter) adds to `initialize`'s
/// `agentCapabilities._meta["_drgnx/panel"]` for a client whose PARAMS offer `_drgnx/panel` version 1
/// (`packages/cli/src/acp/acpDrgnxPanel.ts:92-106`): `adminPolicy {loaded, rules}`, the rules Gemini holds from the
/// `--admin-policy` files, a file dropped by its loader holding none (`acpDrgnxPanel.ts:74-86`); `short` reports one
/// rule fewer.  Each `[[rule]]` counts once: the hub's rules name one tool each.
pub fn panel(argv: &[String], params: &Value) -> Option<Value> {
    let how = argv.windows(2).find(|w| w[0] == "--panel-policy")?[1].clone();
    if params.pointer("/clientCapabilities/_meta/_drgnx~1panel/version") != Some(&json!(1)) {
        return None;
    }
    let mut rules: u64 = argv
        .windows(2)
        .filter(|w| w[0] == "--admin-policy")
        .filter_map(|w| std::fs::read_to_string(&w[1]).ok())
        .filter(|text| problem(text).is_none())
        .map(|text| text.lines().filter(|l| l.trim() == "[[rule]]").count() as u64)
        .sum();
    if how == "short" {
        rules = rules.saturating_sub(1);
    }
    Some(
        json!({"version": 1, "features": [], "adminPolicy": {"loaded": rules > 0, "rules": rules}}),
    )
}

/// Why Gemini CLI 0.67's loader drops the policy TEXT, if it does.  Its schema (`packages/core/src/policy/
/// toml-loader.ts:39-70`) needs on every `[[rule]]`: `toolName`, a string or an array of strings (`:40`; an empty one
/// is refused too, `:419-430`), `decision` one of `allow`, `deny`, `ask_user` (`:46`, `types.ts:10-14`), and
/// `priority` an integer in 0..=999 (`:52-62`); a file that fails is dropped whole (`:376-389`).  Only the TOML the
/// hub writes is read: `[[rule]]` tables of `key = value` lines.
fn problem(text: &str) -> Option<String> {
    let mut rules: Vec<Vec<(String, String)>> = Vec::new();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line == "[[rule]]" {
            rules.push(Vec::new());
        } else if let (Some(rule), Some((k, v))) = (rules.last_mut(), line.split_once('=')) {
            rule.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    for (i, rule) in rules.iter().enumerate() {
        let get = |k: &str| {
            rule.iter()
                .find(|(key, _)| key == k)
                .map(|(_, v)| v.as_str())
        };
        let n = i + 1;
        match get("toolName") {
            None => return Some(format!("rule {n}: toolName is required")),
            Some("\"\"") => return Some(format!("rule {n}: toolName cannot be empty")),
            Some(v) if !(v.starts_with('"') || v.starts_with('[')) => {
                return Some(format!("rule {n}: toolName must be a string or an array"));
            }
            _ => {}
        }
        if !matches!(
            get("decision"),
            Some("\"allow\"" | "\"deny\"" | "\"ask_user\"")
        ) {
            return Some(format!(
                "rule {n}: decision must be allow, deny or ask_user"
            ));
        }
        if !get("priority")
            .and_then(|p| p.parse::<i64>().ok())
            .is_some_and(|p| (0..=999).contains(&p))
        {
            return Some(format!("rule {n}: priority must be an integer in 0..=999"));
        }
    }
    None
}

/// The `tool_call` fields of an edit of PATH: a title, a kind and `locations`, and no `rawInput`.
pub fn edit_shape(path: &str) -> Value {
    json!({"title": path, "kind": "edit", "locations": [{"path": path}]})
}

/// The `tool_call` fields Gemini CLI sends for WHAT (see the Claude personality): a title, a kind and, for files,
/// `locations`; no tool name and no `rawInput`, so the query or URL is only in the title.
pub fn tool_shape(what: &str, arg: &str) -> Option<Value> {
    let file = arg.split_whitespace().next().unwrap_or("");
    Some(match what {
        "read" => json!({"title": file, "kind": "read", "locations": [{"path": file}]}),
        "grep" => json!({"title": format!("grep_search: \"{arg}\""), "kind": "search"}),
        "web-search" => json!({"title": format!("google_web_search: \"{arg}\""), "kind": "fetch"}),
        "web-fetch" => json!({"title": format!("web_fetch {arg}"), "kind": "fetch"}),
        "write" => json!({"title": arg, "kind": "edit", "locations": [{"path": arg}]}),
        _ => return None,
    })
}
