//! What a tool call read, searched or fetched, from the provider's own fields (agent system part 2, Task 2).
//!
//! Classified by tool name, never by ACP kind alone: Claude's `WebSearch` is kind `fetch`, like `WebFetch`.  A
//! provider that sends no tool name (Codex's parsed calls, Gemini) is classified by kind, and Gemini's values, which
//! come only from the title, are labelled `acp-title`.  Content is never kept, and no field is longer than
//! [`FIELD_MAX`] bytes.  Pure: the caller takes the call's fields once the call completes, because `rawInput` is
//! refined while it streams.  An edit's lines come from its `diff` content and the file's text ([`edit_lines_now`],
//! the one reader of a file here), never from `rawInput`.

use norn::write::work::StepDetail;
use serde_json::Value;

/// The longest any text field of a detail is kept.
pub const FIELD_MAX: usize = 4096;

fn cap(s: &str) -> String {
    if s.len() <= FIELD_MAX {
        return s.to_string();
    }
    let mut end = FIELD_MAX;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

/// The wire form of a stored detail.
pub fn wire(d: &StepDetail) -> runstav::methods::timeline::StepDetail {
    let line = |n: Option<i64>| n.and_then(|n| u32::try_from(n).ok());
    runstav::methods::timeline::StepDetail {
        tool: d.tool.clone(),
        kind: d.kind.clone(),
        path: d.path.clone(),
        line_start: line(d.line_start),
        line_end: line(d.line_end),
        query: d.query.clone(),
        url: d.url.clone(),
        title: d.title.clone(),
        parent_tool: d.parent_tool.clone(),
        origin: d.origin.clone(),
    }
}

fn text<'a>(v: Option<&'a Value>, keys: &[&str]) -> Option<&'a str> {
    let v = v?;
    keys.iter()
        .find_map(|k| v.get(*k).and_then(Value::as_str))
        .filter(|s| !s.is_empty())
}

fn num(v: Option<&Value>, key: &str) -> Option<i64> {
    v?.get(key).and_then(Value::as_i64).filter(|n| *n >= 0)
}

fn first_location(locations: &[Value]) -> (Option<String>, Option<i64>) {
    let l = locations.first();
    (
        l.and_then(|l| l.get("path").and_then(Value::as_str))
            .map(cap),
        l.and_then(|l| l.get("line").and_then(Value::as_i64)),
    )
}

/// A quoted or backticked span of TITLE, else the text after its last `: `, else the title.
fn query_of_title(title: &str) -> String {
    for q in ['"', '`', '\''] {
        if let Some(a) = title.find(q)
            && let Some(len) = title[a + 1..].find(q)
            && len > 0
        {
            return cap(&title[a + 1..a + 1 + len]);
        }
    }
    cap(title.rsplit(": ").next().unwrap_or(title).trim())
}

fn url_of_title(title: &str) -> Option<String> {
    title
        .split_whitespace()
        .find(|w| w.starts_with("http://") || w.starts_with("https://"))
        .map(cap)
}

/// Codex's `rawInput.action`: its variant name (lower case) and the object that holds the variant's fields.
fn action_of(raw: Option<&Value>) -> Option<(String, Value)> {
    match raw?.get("action")? {
        Value::String(s) => Some((s.to_lowercase(), Value::Null)),
        Value::Object(o) => {
            if let Some(t) = o.get("type").and_then(Value::as_str) {
                return Some((t.to_lowercase(), Value::Object(o.clone())));
            }
            let (k, v) = o.iter().next()?;
            Some((k.to_lowercase(), v.clone()))
        }
        _ => None,
    }
}

fn base(tool: Option<&str>, kind: &str, origin: &str) -> StepDetail {
    StepDetail {
        tool: tool.map(cap),
        kind: Some(kind.to_string()),
        origin: origin.to_string(),
        ..StepDetail::default()
    }
}

fn read_detail(
    tool: Option<&str>,
    title: Option<&str>,
    locations: &[Value],
    raw: Option<&Value>,
) -> StepDetail {
    let (lpath, _) = first_location(locations);
    let rpath = text(raw, &["file_path", "path", "absolute_path"]).map(cap);
    let mut d = base(tool, "read", "acp");
    d.path = lpath.or(rpath);
    if d.path.is_none()
        && let Some(t) = title
    {
        d.path = t.split_whitespace().last().map(cap);
        d.origin = "acp-title".into();
    }
    let n32 = |k: &str| num(raw, k).and_then(|n| u32::try_from(n).ok());
    let limit = n32("limit").filter(|l| *l > 0);
    // Claude's end line comes only from `limit`
    if let Some((start, end)) = crate::work::edit_lines::of_read(locations, n32("offset"), limit) {
        d.line_start = Some(i64::from(start));
        d.line_end = limit.map(|_| i64::from(end));
    }
    d
}

fn search_detail(
    tool: Option<&str>,
    title: Option<&str>,
    locations: &[Value],
    raw: Option<&Value>,
) -> StepDetail {
    let mut d = base(tool, "search", "acp");
    d.query = text(raw, &["pattern", "query", "regex"]).map(cap);
    d.path = first_location(locations)
        .0
        .or_else(|| text(raw, &["path", "dir_path"]).map(cap));
    if d.query.is_none()
        && let Some(t) = title
    {
        d.query = Some(query_of_title(t));
        d.origin = "acp-title".into();
    }
    d
}

fn fetch_detail(tool: Option<&str>, title: Option<&str>, raw: Option<&Value>) -> StepDetail {
    let mut d = base(tool, "fetch", "acp");
    let action = action_of(raw);
    let (name, inner) = action.unwrap_or_default();
    d.url = text(Some(&inner), &["url"])
        .or_else(|| text(raw, &["url"]))
        .map(cap);
    d.query = text(Some(&inner), &["query"])
        .or_else(|| text(raw, &["query"]))
        .map(cap);
    if name == "search" || (d.url.is_none() && d.query.is_some()) {
        d.kind = Some("search".into());
    }
    if d.url.is_none()
        && d.query.is_none()
        && let Some(t) = title
    {
        d.origin = "acp-title".into();
        match url_of_title(t) {
            Some(u) => d.url = Some(u),
            None => {
                d.query = Some(query_of_title(t));
                d.kind = Some("search".into());
            }
        }
    }
    d
}

fn edit_detail(tool: Option<&str>, locations: &[Value], raw: Option<&Value>) -> StepDetail {
    let mut d = base(tool, "edit", "acp");
    d.path = first_location(locations)
        .0
        .or_else(|| text(raw, &["file_path", "path"]).map(cap));
    d
}

/// The largest file an edit's lines are looked for in (a larger one is shown on the file only).
pub const EDIT_TEXT_MAX: u64 = 8 << 20;

/// An edit's lines, recorded in D (its `line_start` / `line_end`): where its `diff` items DIFFS (path, oldText,
/// newText; their paths as the agent gave them, DIR: the session's folder) land in its file as the file is now
/// ([`crate::work::edit_lines::of_call`]); the range, or none (not an edit, no item in its file, found nowhere once,
/// or the file is larger than [`EDIT_TEXT_MAX`]). The one function here that reads a file: call it off the async
/// threads.
pub fn edit_lines_now(
    d: &mut StepDetail,
    dir: &std::path::Path,
    diffs: Vec<(String, Option<String>, String)>,
) -> Option<crate::work::edit_lines::EditRange> {
    use crate::work::presence::place;
    if d.kind.as_deref() != Some("edit") {
        return None;
    }
    let file = place(dir, d.path.as_deref()?);
    let items: Vec<(Option<String>, String)> = diffs
        .into_iter()
        .filter(|(p, _, _)| place(dir, p) == file)
        .map(|(_, o, n)| (o, n))
        .collect();
    if items.is_empty() {
        return None;
    }
    let text = match std::fs::metadata(&file) {
        Ok(m) if m.len() > EDIT_TEXT_MAX => return None,
        Ok(_) => std::fs::read_to_string(&file).ok()?,
        // not there yet: a new file
        Err(_) => String::new(),
    };
    let r = crate::work::edit_lines::of_call(&text, &items)?;
    d.line_start = Some(i64::from(r.line));
    d.line_end = Some(i64::from(r.line_end));
    Some(r)
}

/// The detail of a completed tool call, or none when it names nothing to show.  TOOL_NAME is the provider's (Claude's
/// `_meta.claudeCode.toolName`); KIND, TITLE, LOCATIONS and RAW_INPUT are the ACP fields.
pub fn of(
    tool_name: Option<&str>,
    kind: Option<&str>,
    title: Option<&str>,
    locations: &[Value],
    raw_input: Option<&Value>,
) -> Option<StepDetail> {
    let d = match tool_name {
        Some("Read" | "read_file") => read_detail(tool_name, title, locations, raw_input),
        Some("Grep" | "Glob" | "grep_search" | "glob") => {
            search_detail(tool_name, title, locations, raw_input)
        }
        Some("WebFetch" | "web_fetch") => {
            let mut d = fetch_detail(tool_name, title, raw_input);
            d.kind = Some("fetch".into());
            d
        }
        Some("WebSearch" | "google_web_search") => {
            let mut d = fetch_detail(tool_name, title, raw_input);
            d.kind = Some("search".into());
            d
        }
        Some("Edit" | "Write" | "MultiEdit" | "write_file" | "replace") => {
            edit_detail(tool_name, locations, raw_input)
        }
        // a shell call's reads are the shell-read layers' (they write `command` and `opened` details)
        Some("Bash") => return None,
        Some(_) | None => match kind? {
            "read" => read_detail(tool_name, title, locations, raw_input),
            "search" => search_detail(tool_name, title, locations, raw_input),
            "fetch" => fetch_detail(tool_name, title, raw_input),
            "edit" | "delete" | "move" => edit_detail(tool_name, locations, raw_input),
            _ => return None,
        },
    };
    let empty = d.path.is_none() && d.query.is_none() && d.url.is_none();
    if empty { None } else { Some(d) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Pattern D (pure): the fields in, the detail out.
    #[test]
    fn claude_read_has_path_and_lines() {
        let locs = [json!({"path": "/w/src/a.rs", "line": 10})];
        let raw = json!({"file_path": "/w/src/a.rs", "offset": 10, "limit": 5});
        let d = of(
            Some("Read"),
            Some("read"),
            Some("Read a.rs"),
            &locs,
            Some(&raw),
        )
        .unwrap();
        assert_eq!(
            (
                d.path.as_deref(),
                d.line_start,
                d.line_end,
                d.origin.as_str()
            ),
            (Some("/w/src/a.rs"), Some(10), Some(14), "acp")
        );
        // no limit: the start only; no offset: line 1 from the location
        let locs = [json!({"path": "/w/b.rs", "line": 1})];
        let d = of(
            Some("Read"),
            Some("read"),
            None,
            &locs,
            Some(&json!({"file_path": "/w/b.rs"})),
        )
        .unwrap();
        assert_eq!((d.line_start, d.line_end), (Some(1), None));
    }

    #[test]
    fn claude_grep_has_pattern_from_raw_input() {
        let raw = json!({"pattern": "fn main", "path": "/w/src"});
        let d = of(
            Some("Grep"),
            Some("search"),
            Some("grep \"fn main\" /w/src"),
            &[],
            Some(&raw),
        )
        .unwrap();
        assert_eq!(
            (
                d.kind.as_deref(),
                d.query.as_deref(),
                d.path.as_deref(),
                d.origin.as_str()
            ),
            (Some("search"), Some("fn main"), Some("/w/src"), "acp")
        );
    }

    #[test]
    fn claude_websearch_is_a_search_though_kind_fetch() {
        let raw = json!({"query": "rust 1.88 release"});
        let s = of(
            Some("WebSearch"),
            Some("fetch"),
            Some("rust 1.88 release"),
            &[],
            Some(&raw),
        )
        .unwrap();
        assert_eq!(
            (s.kind.as_deref(), s.query.as_deref(), s.url),
            (Some("search"), Some("rust 1.88 release"), None)
        );
        let raw = json!({"url": "https://example.test/a"});
        let f = of(
            Some("WebFetch"),
            Some("fetch"),
            Some("Fetch https://example.test/a"),
            &[],
            Some(&raw),
        )
        .unwrap();
        assert_eq!(
            (f.kind.as_deref(), f.url.as_deref()),
            (Some("fetch"), Some("https://example.test/a"))
        );
    }

    #[test]
    fn codex_web_search_reads_action() {
        let raw =
            json!({"query": "tokio select", "action": {"type": "search", "query": "tokio select"}});
        let d = of(
            None,
            Some("fetch"),
            Some("Searching the web"),
            &[],
            Some(&raw),
        )
        .unwrap();
        assert_eq!(
            (d.kind.as_deref(), d.query.as_deref(), d.origin.as_str()),
            (Some("search"), Some("tokio select"), "acp")
        );
        let raw = json!({"action": {"OpenPage": {"url": "https://example.test/p"}}});
        let d = of(None, Some("fetch"), Some("Opening"), &[], Some(&raw)).unwrap();
        assert_eq!(
            (d.kind.as_deref(), d.url.as_deref()),
            (Some("fetch"), Some("https://example.test/p"))
        );
    }

    #[test]
    fn codex_parsed_read_has_no_line() {
        let locs = [json!({"path": "/w/c.rs"})];
        let d = of(None, Some("read"), Some("Read c.rs"), &locs, None).unwrap();
        assert_eq!(
            (d.path.as_deref(), d.line_start, d.line_end),
            (Some("/w/c.rs"), None, None)
        );
    }

    #[test]
    fn gemini_details_come_from_the_title() {
        let d = of(
            None,
            Some("search"),
            Some("grep_search: \"needle\" in src"),
            &[],
            None,
        )
        .unwrap();
        assert_eq!(
            (d.query.as_deref(), d.origin.as_str()),
            (Some("needle"), "acp-title")
        );
        let d = of(
            None,
            Some("fetch"),
            Some("web_fetch https://example.test/x"),
            &[],
            None,
        )
        .unwrap();
        assert_eq!(
            (d.url.as_deref(), d.origin.as_str()),
            (Some("https://example.test/x"), "acp-title")
        );
        // a read with locations is the provider's own field
        let locs = [json!({"path": "/w/d.rs"})];
        let d = of(Some("read_file"), Some("read"), Some("d.rs"), &locs, None).unwrap();
        assert_eq!(
            (d.path.as_deref(), d.origin.as_str()),
            (Some("/w/d.rs"), "acp")
        );
    }

    #[test]
    fn a_write_keeps_no_content() {
        let big = "x".repeat(10 * 1024 * 1024);
        let raw = json!({"file_path": "/w/e.rs", "content": big});
        let d = of(
            Some("Write"),
            Some("edit"),
            Some("Write e.rs"),
            &[],
            Some(&raw),
        )
        .unwrap();
        assert_eq!(d.path.as_deref(), Some("/w/e.rs"));
        let json = serde_json::to_value(&d).unwrap();
        for (k, v) in json.as_object().unwrap() {
            if let Some(s) = v.as_str() {
                assert!(s.len() <= FIELD_MAX, "{k}");
            }
        }
        assert!(d.query.is_none() && d.url.is_none() && d.title.is_none());
        // a path over the cap is cut, on a character boundary
        let long = "é".repeat(FIELD_MAX);
        let d = of(
            Some("Edit"),
            Some("edit"),
            None,
            &[json!({"path": long})],
            None,
        )
        .unwrap();
        assert!(d.path.unwrap().len() <= FIELD_MAX);
    }

    #[test]
    fn detail_is_taken_at_completion() {
        // the call opens with a partial input and completes with the refined one: the caller passes the last
        let early = json!({"file_path": "/w/f.rs"});
        let late = json!({"file_path": "/w/f.rs", "offset": 40, "limit": 10});
        let a = of(Some("Read"), Some("read"), None, &[], Some(&early)).unwrap();
        let b = of(Some("Read"), Some("read"), None, &[], Some(&late)).unwrap();
        assert_eq!(
            (a.line_start, b.line_start, b.line_end),
            (None, Some(40), Some(49))
        );
    }

    #[test]
    fn a_shell_call_and_a_thought_have_no_detail() {
        assert!(
            of(
                Some("Bash"),
                Some("execute"),
                Some("ls"),
                &[],
                Some(&json!({"command": "ls"}))
            )
            .is_none()
        );
        assert!(of(None, Some("think"), None, &[], None).is_none());
    }
}
