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
    // a long output goes as its head and tail with the whole size; `agents/tool-output` pages the rest
    if let Some(content) = e.rest.get_mut("content")
        && let Some(total) = super::tool_output::fold(
            content,
            super::tool_output::EVENT_HEAD,
            super::tool_output::EVENT_TAIL,
        )
    {
        e.rest
            .entry("outputBytes".to_string())
            .or_insert(Value::from(total));
    }
    e
}

/// ENTRY as history sends it: an agent message also carries its Markdown `blocks`, from a full parse of its text
/// (the live shape, `[{block, kind, spans}]`).
pub fn with_blocks(mut entry: Entry) -> Entry {
    if entry.kind == runstav::methods::agents::EntryType::Agent
        && let Some(text) = entry.rest.get("text").and_then(Value::as_str)
    {
        let blocks = super::markdown::Stream::default().update(text);
        entry
            .rest
            .insert("blocks".into(), serde_json::json!(blocks));
    }
    entry
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

/// The most `agent` snapshots a connection gets for sessions it does not show, in one window.
pub const SNAPSHOTS_PER_WINDOW: u32 = 30;
/// The window the cap counts in, on the hub's clock.
pub const SNAPSHOT_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// What one connection's pacer decided about a snapshot: the line to send now, and when to call [`Pacer::flush`].
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Offered {
    pub send: Option<std::sync::Arc<str>>,
    pub arm: Option<std::time::Duration>,
}

/// The snapshots one connection gets for sessions it does not show: at most [`SNAPSHOTS_PER_WINDOW`] a window, and
/// when the cap is reached only the latest line of each session waits for the next window.  Pure: the caller gives the
/// time and sends the lines.
#[derive(Debug, Default)]
pub struct Pacer {
    window_start: Option<tokio::time::Instant>,
    sent: u32,
    pending: std::collections::BTreeMap<String, std::sync::Arc<str>>,
    armed: bool,
}

impl Pacer {
    fn roll(&mut self, now: tokio::time::Instant) {
        if self
            .window_start
            .is_none_or(|s| now.saturating_duration_since(s) >= SNAPSHOT_WINDOW)
        {
            self.window_start = Some(now);
            self.sent = 0;
        }
    }

    fn until_next(&self, now: tokio::time::Instant) -> std::time::Duration {
        let end = self.window_start.map_or(now, |s| s + SNAPSHOT_WINDOW);
        end.saturating_duration_since(now)
    }

    /// LINE is session SID's latest snapshot, at NOW.
    pub fn offer(
        &mut self,
        now: tokio::time::Instant,
        sid: &str,
        line: std::sync::Arc<str>,
    ) -> Offered {
        self.roll(now);
        if self.pending.is_empty() && self.sent < SNAPSHOTS_PER_WINDOW {
            self.sent += 1;
            return Offered {
                send: Some(line),
                arm: None,
            };
        }
        self.pending.insert(sid.to_string(), line);
        let arm = (!self.armed).then(|| {
            self.armed = true;
            self.until_next(now)
        });
        Offered { send: None, arm }
    }

    /// The window may have opened (called when the time [`Pacer::offer`] gave is up): what goes now, and when to
    /// call again when some still wait.
    pub fn flush(
        &mut self,
        now: tokio::time::Instant,
    ) -> (Vec<std::sync::Arc<str>>, Option<std::time::Duration>) {
        self.armed = false;
        self.roll(now);
        let room = SNAPSHOTS_PER_WINDOW.saturating_sub(self.sent) as usize;
        let take: Vec<String> = self.pending.keys().take(room).cloned().collect();
        let lines: Vec<_> = take.iter().filter_map(|k| self.pending.remove(k)).collect();
        self.sent += lines.len() as u32;
        let again = (!self.pending.is_empty()).then(|| {
            self.armed = true;
            self.until_next(now)
        });
        (lines, again)
    }

    /// Session SID is shown to this connection: what waited for it is stale.
    pub fn forget(&mut self, sid: &str) {
        self.pending.remove(sid);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::time::Instant;

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

    /// [D] A history entry of an agent message carries its blocks from a full parse; other entries are unchanged.
    #[test]
    fn a_history_entry_carries_its_markdown_blocks() {
        let msg: Entry = serde_json::from_value(
            json!({"type": "agent", "text": "# Hi\n\nsome *words*\n\n```\ncode\n```\n"}),
        )
        .unwrap();
        let e = with_blocks(msg);
        let blocks = e.rest.get("blocks").and_then(Value::as_array).unwrap();
        let kinds: Vec<_> = blocks.iter().map(|b| b["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["heading", "paragraph", "code"]);
        assert_eq!(blocks[1]["block"], 1);
        assert_eq!(
            blocks[1]["spans"][1],
            json!({"text": "words", "style": "emph"})
        );
        let t = tool(json!({}));
        assert_eq!(with_blocks(t.clone()), t);
    }

    /// [D] A string `url` of the input stays, as `url`.
    #[test]
    fn a_url_of_the_input_stays() {
        let e = public_entry(&tool(json!({"url": "http://localhost:3000/"})));
        assert_eq!(e.rest.get("url"), Some(&json!("http://localhost:3000/")));
        assert!(e.rest.get("rawInput").is_none());
    }

    fn line(s: &str) -> std::sync::Arc<str> {
        std::sync::Arc::from(s)
    }

    /// [D] The 31st snapshot in a window waits, the latest of a session replaces its older one, and the window
    /// opening sends them, cap again.
    #[tokio::test(start_paused = true)]
    async fn pacer_caps_a_window_and_keeps_the_latest() {
        let mut p = Pacer::default();
        let t0 = Instant::now();
        for i in 0..SNAPSHOTS_PER_WINDOW {
            let o = p.offer(t0, &format!("s{i:02}"), line("a"));
            assert!(o.send.is_some() && o.arm.is_none());
        }
        let o = p.offer(t0, "s00", line("old"));
        assert_eq!(o.send, None);
        assert_eq!(o.arm, Some(SNAPSHOT_WINDOW));
        // the same session again: replaces, and the timer is armed once
        let o = p.offer(
            t0 + std::time::Duration::from_millis(100),
            "s00",
            line("new"),
        );
        assert_eq!(o, Offered::default());
        let _ = p.offer(t0 + std::time::Duration::from_millis(100), "s01", line("b"));
        let (lines, again) = p.flush(t0 + SNAPSHOT_WINDOW);
        assert_eq!(lines, vec![line("new"), line("b")]);
        assert_eq!(again, None);
        // a full window, then 40 waiting: 30 go when it opens, 10 wait for the one after
        let t1 = t0 + SNAPSHOT_WINDOW * 2;
        for i in 0..SNAPSHOTS_PER_WINDOW {
            assert!(p.offer(t1, &format!("u{i:02}"), line("u")).send.is_some());
        }
        for i in 0..40 {
            let _ = p.offer(t1, &format!("t{i:02}"), line("c"));
        }
        let (lines, again) = p.flush(t1 + SNAPSHOT_WINDOW);
        assert_eq!(lines.len(), SNAPSHOTS_PER_WINDOW as usize);
        assert_eq!(again, Some(SNAPSHOT_WINDOW));
    }

    /// [D] A session shown to the connection drops what waited for it.
    #[tokio::test(start_paused = true)]
    async fn pacer_forgets_a_shown_session() {
        let mut p = Pacer::default();
        let t0 = Instant::now();
        for i in 0..SNAPSHOTS_PER_WINDOW {
            let _ = p.offer(t0, &format!("s{i:02}"), line("a"));
        }
        let _ = p.offer(t0, "x", line("w"));
        p.forget("x");
        let (lines, _) = p.flush(t0 + SNAPSHOT_WINDOW);
        assert!(lines.is_empty());
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
