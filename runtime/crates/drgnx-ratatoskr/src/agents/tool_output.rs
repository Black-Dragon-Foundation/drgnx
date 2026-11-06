//! A tool call's output, served by byte range (`agents/tool-output`).
//!
//! The session's entries keep a tool call's output as ACP `content` text parts.  Past [`KEEP_HEAD`] + [`KEEP_TAIL`]
//! bytes the fold keeps only the first and the last part of it and records the whole size (`outputBytes`); an editor
//! is sent far less ([`EVENT_HEAD`] + [`EVENT_TAIL`]) and pages the rest by range.  Serving borrows the kept parts and
//! copies only the answer, never more than [`PAGE_CAP`] bytes.

use serde_json::{Value, json};

/// The most bytes one answer holds.
pub const PAGE_CAP: usize = 256 * 1024;
/// How much of a tool output's start and end the session keeps.
pub const KEEP_HEAD: usize = 8 * 1024 * 1024;
pub const KEEP_TAIL: usize = 8 * 1024 * 1024;
/// How much of it an `agent-entries` event carries.
pub const EVENT_HEAD: usize = 32 * 1024;
pub const EVENT_TAIL: usize = 32 * 1024;
/// Each side of the answer for a range beyond what is kept.
pub const EDGE: usize = 128 * 1024;

/// One answer of `agents/tool-output`.
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    pub text: String,
    pub total_bytes: u64,
    /// The answer holds less than was asked for: the page cap, or bytes that are not kept.
    pub truncated: bool,
}

/// The text parts of a tool entry's `content`.
pub fn text_parts(content: &Value) -> Vec<&str> {
    let Some(items) = content.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter(|i| i.get("type").and_then(Value::as_str) == Some("content"))
        .filter_map(|i| {
            let c = i.get("content")?;
            (c.get("type").and_then(Value::as_str) == Some("text"))
                .then(|| c.get("text").and_then(Value::as_str))
                .flatten()
        })
        .collect()
}

fn is_text(item: &Value) -> bool {
    item.get("type").and_then(Value::as_str) == Some("content")
        && item.pointer("/content/type").and_then(Value::as_str) == Some("text")
}

fn text_item(text: &str) -> Value {
    json!({"type": "content", "content": {"type": "text", "text": text}})
}

/// CONTENT with its text cut to HEAD bytes at the start and TAIL at the end, when it is longer: the whole size.
pub fn fold(content: &mut Value, head: usize, tail: usize) -> Option<u64> {
    let parts = text_parts(content);
    let total: usize = parts.iter().map(|p| p.len()).sum();
    if total <= head + tail {
        return None;
    }
    let all: String = parts.concat();
    let mut h = head;
    while !all.is_char_boundary(h) {
        h -= 1;
    }
    let mut t = all.len() - tail;
    while !all.is_char_boundary(t) {
        t += 1;
    }
    let (head_text, tail_text) = (all[..h].to_string(), all[t..].to_string());
    let items = content.as_array_mut()?;
    items.retain(|i| !is_text(i));
    items.push(text_item(&head_text));
    items.push(text_item(&tail_text));
    Some(total as u64)
}

/// Bytes FROM..TO of an output of TOTAL bytes whose kept text is PARTS: the whole of it, or (when the parts hold less
/// than TOTAL) a head part and a tail part with the middle gone.
pub fn page(parts: &[&str], total: u64, from: u64, to: u64) -> Page {
    let kept: u64 = parts.iter().map(|p| p.len() as u64).sum();
    // where each part starts in the whole output: the first at 0, the rest end at the end
    let mut starts = Vec::with_capacity(parts.len());
    let mut acc = 0u64;
    for p in parts {
        starts.push(acc);
        acc += p.len() as u64;
    }
    if kept < total {
        let mut rest = 0u64;
        for (i, p) in parts.iter().enumerate().skip(1).rev() {
            rest += p.len() as u64;
            starts[i] = total - rest;
        }
    }
    let ask_to = to.min(total);
    let from = from.min(total);
    let answer = |text: String, truncated: bool| Page {
        text,
        total_bytes: total,
        truncated,
    };
    if ask_to <= from {
        return answer(String::new(), false);
    }
    // the part FROM is in; a start in the gap has none
    let Some(first) = (0..parts.len())
        .rev()
        .find(|&i| starts[i] <= from)
        .filter(|&i| from < starts[i] + parts[i].len() as u64)
    else {
        let gone = total - kept;
        let head = parts.first().copied().unwrap_or("");
        let tail = parts.last().copied().unwrap_or("");
        let mut h = head.len().min(EDGE);
        while !head.is_char_boundary(h) {
            h -= 1;
        }
        let mut t = tail.len() - tail.len().min(EDGE);
        while !tail.is_char_boundary(t) {
            t += 1;
        }
        return answer(
            format!(
                "{}\n... {gone} bytes not kept ...\n{}",
                &head[..h],
                &tail[t..]
            ),
            true,
        );
    };
    // cut at the page cap, and where the contiguous kept bytes end
    let mut end = ask_to.min(from + PAGE_CAP as u64);
    let mut i = first;
    while i + 1 < parts.len() && starts[i] + parts[i].len() as u64 == starts[i + 1] {
        i += 1;
    }
    end = end.min(starts[i] + parts[i].len() as u64);
    // both ends snap down to a character boundary, so pages that follow each other neither overlap nor leave a gap
    let mut text = String::with_capacity((end - from) as usize);
    for k in first..=i {
        let s = starts[k];
        let lo = from.saturating_sub(s) as usize;
        let mut hi = (end.saturating_sub(s) as usize).min(parts[k].len());
        let mut lo = lo.min(parts[k].len());
        while !parts[k].is_char_boundary(lo) {
            lo -= 1;
        }
        while !parts[k].is_char_boundary(hi) {
            hi -= 1;
        }
        if hi > lo {
            text.push_str(&parts[k][lo..hi]);
        }
    }
    let truncated = (text.len() as u64) < ask_to - from;
    answer(text, truncated)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_10_mb_output_pages_without_copying() {
        let line = "0123456789abcdé\n";
        let big = line.repeat(10 * 1024 * 1024 / line.len() + 1);
        let total = big.len() as u64;
        // the parts are the output's own buffers: serving borrows them
        let parts: Vec<&str> = vec![&big[..4_000_000], &big[4_000_000..]];
        let mut got = String::new();
        let mut at = 0u64;
        let mut pages = 0;
        while at < total {
            let p = page(&parts, total, at, at + 1_000_000);
            assert!(p.text.len() <= PAGE_CAP, "{} bytes", p.text.len());
            assert_eq!(p.total_bytes, total);
            assert!(!p.text.is_empty(), "no progress at {at}");
            got.push_str(&p.text);
            at += p.text.len() as u64;
            pages += 1;
        }
        assert_eq!(got, big);
        assert!(pages >= 40, "{pages} pages");
        // a page that stops at the cap says so; the last one does not
        let first = page(&parts, total, 0, total);
        assert!(first.truncated && first.text.len() <= PAGE_CAP);
        let last = page(&parts, total, total - 10, total + 99);
        assert!(!last.truncated && last.text.len() == 10);
    }

    #[test]
    fn beyond_the_kept_part_is_head_and_tail() {
        let body: String = (0..2000).map(|i| format!("line {i:04}\n")).collect();
        let total = body.len() as u64;
        let mut content = json!([
            {"type": "content", "content": {"type": "text", "text": body}},
            {"type": "diff", "path": "a", "newText": "n"}
        ]);
        assert_eq!(fold(&mut content, 100, 100), Some(total));
        assert_eq!(fold(&mut content, 100, 100), None);
        let kept = text_parts(&content);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0], &body[..100]);
        assert_eq!(kept[1], &body[body.len() - 100..]);
        assert_eq!(content[0]["type"], "diff", "other parts stay");
        // inside the kept head and the kept tail: the real bytes
        let p = page(&kept, total, 10, 20);
        assert_eq!((p.text.as_str(), p.truncated), (&body[10..20], false));
        let p = page(&kept, total, total - 20, total);
        assert_eq!(
            (p.text.as_str(), p.truncated),
            (&body[body.len() - 20..], false)
        );
        // a range that runs out of the head is cut where the head ends
        let p = page(&kept, total, 90, 500);
        assert_eq!((p.text.as_str(), p.truncated), (&body[90..100], true));
        // a range in what is gone: the kept head and tail, the size, and the flag
        let p = page(&kept, total, 1000, 1100);
        assert!(p.truncated);
        assert_eq!(p.total_bytes, total);
        assert!(p.text.starts_with(&body[..100]), "{}", p.text);
        assert!(p.text.ends_with(&body[body.len() - 100..]), "{}", p.text);
        assert!(p.text.contains("bytes not kept"), "{}", p.text);
    }
}
