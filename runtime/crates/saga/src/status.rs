//! Record statuses: the graph's vocabulary (`open running needs-input in-review blocked waiting done dropped`) against
//! the words the record files use (a DEFERRED row's free text, an Org keyword, a plan task's ticks).  [`normalize`]
//! maps a file's word to the graph's; [`status_of`] reads a piece's status from its text; [`with_status`] writes a
//! graph status back into a piece's text, so a graph-only change reaches the view (Task 14b).  The raw text stays in
//! the piece's body: nothing here is lossy for a piece whose status did not change.

use crate::table;

/// The graph's statuses.
pub const STATUSES: [&str; 8] = [
    "open",
    "running",
    "needs-input",
    "in-review",
    "blocked",
    "waiting",
    "done",
    "dropped",
];

/// RAW (a file's status word or phrase) as one of [`STATUSES`].  Unknown words are `open`.
pub fn normalize(raw: &str) -> String {
    let t = raw
        .trim()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_lowercase();
    let has = |ws: &[&str]| ws.iter().any(|w| t.starts_with(w));
    let s = if has(&[
        "done", "closed", "complete", "fixed", "merged", "resolved", "shipped", "landed",
    ]) {
        "done"
    } else if has(&[
        "dropped",
        "cancel",
        "wontfix",
        "won't",
        "superseded",
        "rejected",
        "obsolete",
        "abandon",
    ]) {
        "dropped"
    } else if has(&["blocked"]) {
        "blocked"
    } else if has(&["waiting", "hold", "on hold", "paused"]) {
        "waiting"
    } else if has(&["in review", "in-review", "review"]) {
        "in-review"
    } else if has(&["needs", "need ", "input"]) {
        "needs-input"
    } else if has(&[
        "in progress",
        "in-progress",
        "started",
        "running",
        "doing",
        "wip",
        "active",
        "partial",
    ]) {
        "running"
    } else {
        "open"
    };
    s.to_string()
}

/// RAW (the first word of a DEFERRED row's status cell or entry bullet) as one of [`STATUSES`]: `open` is open;
/// `fixed closed done decided mitigated` are done; `dropped moot` dropped; any other word is open (an item is never
/// hidden by a word this does not know).
pub fn normalize_deferred(raw: &str) -> String {
    let w = raw
        .split_whitespace()
        .next()
        .unwrap_or("")
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_lowercase();
    match w.as_str() {
        "fixed" | "closed" | "done" | "decided" | "mitigated" => "done",
        "dropped" | "moot" => "dropped",
        _ => "open",
    }
    .to_string()
}

fn is_step_line(l: &str) -> Option<bool> {
    let t = l.trim_start();
    let t = t.strip_prefix(['-', '*', '+'])?.strip_prefix(' ')?;
    if t.starts_with("[ ]") {
        Some(false)
    } else if t.starts_with("[x]") || t.starts_with("[X]") {
        Some(true)
    } else {
        None
    }
}

/// The status PIECE (an entity of KIND with ROLE and raw text BODY) says in its text, when the text says one.
pub fn status_of(kind: &str, role: &str, body: &str) -> Option<String> {
    match (kind, role) {
        ("todo", "row") => {
            let first: String = body.lines().next().unwrap_or("").into();
            // a row of several lines: the cells of the lines joined
            let joined = body.replace('\n', " ");
            let cells = table::split_cells(if first.trim_end().ends_with('|') {
                &first
            } else {
                &joined
            });
            cells.get(3).map(|c| normalize_deferred(c))
        }
        ("todo", "entry") => {
            let w = crate::deferred::status_word(body).map_or("", |r| &body[r]);
            Some(normalize_deferred(w))
        }
        ("task", "item") => {
            let line = body.lines().next().unwrap_or("");
            let rest = line.trim_start_matches('*').trim_start();
            let word = rest.split_whitespace().next()?;
            crate::org::is_default_keyword(word).then(|| normalize(word))
        }
        ("task", "task") => {
            let steps: Vec<bool> = body.lines().filter_map(is_step_line).collect();
            Some(if !steps.is_empty() && steps.iter().all(|d| *d) {
                "done".into()
            } else {
                "open".into()
            })
        }
        _ => None,
    }
}

fn org_keyword(status: &str) -> &'static str {
    match status {
        "done" => "DONE",
        "dropped" => "CANCELLED",
        "running" => "STARTED",
        "waiting" | "blocked" | "needs-input" => "WAITING",
        "in-review" => "REVIEW",
        _ => "TODO",
    }
}

/// BODY with its status set to STATUS, when the piece's text can say it (a DEFERRED row's status cell, an Org
/// keyword, a plan task's ticks) and the text does not already.  `None`: nothing to change.
pub fn with_status(kind: &str, role: &str, body: &str, status: &str) -> Option<String> {
    if status_of(kind, role, body).as_deref() == Some(status) {
        return None;
    }
    match (kind, role) {
        ("todo", "row") => {
            if body.lines().count() != 1 {
                return None;
            }
            let (text, nl) = match body.strip_suffix('\n') {
                Some(t) => (t, "\n"),
                None => (body, ""),
            };
            let trimmed = text.trim_end();
            let tail = &text[trimmed.len()..];
            let inner = trimmed.strip_suffix('|').unwrap_or(trimmed);
            let closed = inner.len() != trimmed.len();
            // the last unescaped pipe before the status cell
            let mut cut = None;
            let mut esc = false;
            for (i, c) in inner.char_indices() {
                if c == '|' && !esc {
                    cut = Some(i);
                }
                esc = c == '\\' && !esc;
            }
            let cut = cut?;
            Some(format!(
                "{}| {status}{}{tail}{nl}",
                &inner[..cut],
                if closed { " |" } else { "" }
            ))
        }
        ("todo", "entry") => {
            let r = crate::deferred::status_word(body)?;
            Some(format!("{}{status}{}", &body[..r.start], &body[r.end..]))
        }
        ("task", "item") => {
            let (first, rest) = match body.split_once('\n') {
                Some((f, r)) => (f, format!("\n{r}")),
                None => (body, String::new()),
            };
            let stars = first.len() - first.trim_start_matches('*').len();
            let after = first[stars..].trim_start();
            let has_kw = after
                .split_whitespace()
                .next()
                .is_some_and(crate::org::is_default_keyword);
            // a keyword of the file's own (`#+TODO: … BLOCKED`) is not ours to rewrite
            if !has_kw
                && after
                    .split_whitespace()
                    .next()
                    .is_some_and(|w| w.len() > 1 && w.chars().all(|c| c.is_ascii_uppercase()))
            {
                return None;
            }
            let title = if has_kw {
                after.split_once(char::is_whitespace).map_or("", |x| x.1)
            } else {
                after
            };
            let kw = org_keyword(status);
            let sp = if title.is_empty() { "" } else { " " };
            Some(format!("{} {kw}{sp}{title}{rest}", &first[..stars]))
        }
        ("task", "task") => {
            let done = status == "done";
            let now_done = status_of(kind, role, body).as_deref() == Some("done");
            if done == now_done {
                return None;
            }
            let out: Vec<String> = body
                .split_inclusive('\n')
                .map(|l| match is_step_line(l) {
                    Some(d) if d != done => {
                        if done {
                            l.replacen("[ ]", "[x]", 1)
                        } else {
                            l.replacen("[x]", "[ ]", 1).replacen("[X]", "[ ]", 1)
                        }
                    }
                    _ => l.to_string(),
                })
                .collect();
            Some(out.concat())
        }
        _ => None,
    }
}
