//! What a session's entries look like on the wire to an editor, and how a tool call's raw input is fetched.
//!
//! The hub keeps a tool call's whole `rawInput` (a `Write` carries the file); an editor never gets it in an event.
//! It sees the entry without it (a string `url` in the input stays, as the editor's browser view reads it), and asks
//! `agents/tool-input` for the input when it needs it, capped at [`TOOL_INPUT_CAP`] bytes.

use runstav::methods::agents::Entry;
use serde_json::Value;

/// The most bytes of a tool call's raw input `agents/tool-input` returns (its JSON text).
pub const TOOL_INPUT_CAP: usize = 256 * 1024;

/// ENTRY as an editor sees it.
pub fn public_entry(entry: &Entry) -> Entry {
    let mut e = entry.clone();
    if let Some(raw) = e.rest.remove("rawInput")
        && let Some(url) = raw.get("url").filter(|u| u.is_string())
    {
        e.rest.insert("url".into(), url.clone());
    }
    e
}

/// RAW, a tool call's raw input, within [`TOOL_INPUT_CAP`]: the input itself, or its JSON text cut short (a string)
/// with `true` when it was cut.
pub fn capped_tool_input(raw: &Value) -> (Value, bool) {
    let text = raw.to_string();
    if text.len() <= TOOL_INPUT_CAP {
        return (raw.clone(), false);
    }
    let mut end = TOOL_INPUT_CAP;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (Value::String(text[..end].to_string()), true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tool(raw: Value) -> Entry {
        serde_json::from_value(json!({
            "type": "tool", "id": "t1", "title": "Write", "kind": "edit", "status": "pending", "rawInput": raw,
        }))
        .unwrap()
    }

    /// [D] The editor's entry has no `rawInput`, and keeps what else it had.
    #[test]
    fn an_editors_entry_has_no_raw_input() {
        let big = "x".repeat(1 << 20);
        let e = public_entry(&tool(json!({"file_path": "/a", "content": big})));
        let line = serde_json::to_string(&e).unwrap();
        assert!(!line.contains("rawInput"), "{line}");
        assert!(line.len() < 1024, "{} bytes", line.len());
        assert_eq!(e.rest.get("title"), Some(&json!("Write")));
        assert_eq!(e.rest.get("id"), Some(&json!("t1")));
    }

    /// [D] A string `url` of the input stays, as `url`.
    #[test]
    fn a_url_of_the_input_stays() {
        let e = public_entry(&tool(json!({"url": "http://localhost:3000/"})));
        assert_eq!(e.rest.get("url"), Some(&json!("http://localhost:3000/")));
        assert!(e.rest.get("rawInput").is_none());
    }

    /// [D] A raw input within the cap comes back whole; a larger one comes back cut, and said so.
    #[test]
    fn tool_input_is_capped() {
        let small = json!({"command": "ls"});
        assert_eq!(capped_tool_input(&small), (small.clone(), false));
        let big = json!({"content": "é".repeat(TOOL_INPUT_CAP)});
        let (v, truncated) = capped_tool_input(&big);
        assert!(truncated);
        let text = v.as_str().expect("a cut input is its JSON text");
        assert!(text.len() <= TOOL_INPUT_CAP, "{} bytes", text.len());
        assert!(text.starts_with(r#"{"content":"é"#));
    }
}
