//! Record statuses: the graph's vocabulary (`open running needs-input in-review blocked waiting done dropped accepted
//! parked superseded`) against
//! the words the record files use (a DEFERRED row's free text, an Org keyword, a plan task's ticks).  [`normalize`]
//! maps a file's word to the graph's; [`status_of`] reads a piece's status from its text; [`with_status`] writes a
//! graph status back into a piece's text, so a graph-only change reaches the view (Task 14b).  The raw text stays in
//! the piece's body: nothing here is lossy for a piece whose status did not change.

use crate::table;

/// The graph's statuses.
pub const STATUSES: [&str; 11] = [
    "open",
    "running",
    "needs-input",
    "in-review",
    "blocked",
    "waiting",
    "done",
    "dropped",
    "accepted",
    "parked",
    "superseded",
];

/// A plan task's `**Status:** <state> — <reason>` line: the first non-blank line under its heading.
struct Line {
    /// The line with its terminator.
    start: usize,
    end: usize,
    /// The state as written, and the reason after the dash (empty when none).
    word: String,
    reason: String,
}

const LABEL: &str = "**Status:**";

/// The status line of the task piece RAW (its heading, then its body), when it has one.
fn status_line(raw: &str) -> Option<Line> {
    let mut at = 0;
    for (i, l) in raw.split_inclusive('\n').enumerate() {
        let end = at + l.len();
        if i > 0 && !l.trim().is_empty() {
            let rest = l.trim_end().strip_prefix(LABEL)?.trim();
            let (word, reason) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
            let reason = reason
                .trim()
                .trim_start_matches(['—', '–', '-'])
                .trim()
                .to_owned();
            return Some(Line {
                start: at,
                end,
                word: word.to_owned(),
                reason,
            });
        }
        at = end;
    }
    None
}

/// The tasks of the plan TEXT whose status line holds a word that is no status: (task number, the word).  Their text
/// stays as it is and the ticks decide; the import reports them.
pub fn unknown_status_words(text: &str) -> Vec<(String, String)> {
    crate::plan::parse(text)
        .tasks
        .iter()
        .filter_map(|t| {
            let l = status_line(&format!("{}{}", t.heading, t.body))?;
            let known = STATUSES.contains(&l.word.to_lowercase().as_str());
            (!known).then(|| (t.number.clone(), l.word))
        })
        .collect()
}

/// RAW with its status line set to WORD and REASON, or removed (`None`).  A new line goes right under the heading.
fn with_line(raw: &str, to: Option<(&str, &str)>) -> String {
    let text = to.map(|(w, r)| {
        if r.is_empty() {
            format!("{LABEL} {w}\n")
        } else {
            format!("{LABEL} {w} — {r}\n")
        }
    });
    match (status_line(raw), text) {
        (Some(l), Some(t)) => format!("{}{t}{}", &raw[..l.start], &raw[l.end..]),
        (Some(l), None) => format!("{}{}", &raw[..l.start], &raw[l.end..]),
        (None, Some(t)) => {
            let at = raw.find('\n').map_or(raw.len(), |i| i + 1);
            let (head, tail) = raw.split_at(at);
            let nl = if head.ends_with('\n') { "" } else { "\n" };
            let gap = if tail.is_empty() || tail.starts_with('\n') {
                ""
            } else {
                "\n"
            };
            format!("{head}{nl}{t}{gap}{tail}")
        }
        (None, None) => raw.to_owned(),
    }
}

/// RAW with every step ticked (DONE) or unticked.
fn with_ticks(raw: &str, done: bool) -> String {
    raw.split_inclusive('\n')
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
        .collect()
}

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
        ("spec" | "decision", "head") => crate::spec::parse(body)
            .status
            .map(|w| crate::import::spec_status(&w)),
        ("task", "task") => {
            // the status line wins over the ticks; a word that is no status stays text and the ticks decide
            if let Some(l) = status_line(body) {
                let w = l.word.to_lowercase();
                if STATUSES.contains(&w.as_str()) {
                    return Some(w);
                }
            }
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

/// The plan task piece RAW with its status set to STATUS and, when REASON is given, the line's reason; `None`: the text
/// already says it, or STATUS is no graph status.  A status a tick cannot say goes into the line, its reason kept
/// (REASON replaces it); `open` and `done` (with steps to tick) go back to the ticks.
pub fn task_with_status(raw: &str, status: &str, reason: Option<&str>) -> Option<String> {
    if !STATUSES.contains(&status)
        || (reason.is_none() && status_of("task", "task", raw).as_deref() == Some(status))
    {
        return None;
    }
    let old = status_line(raw).map(|l| l.reason).unwrap_or_default();
    let reason = reason.unwrap_or(&old);
    let steps: Vec<bool> = raw.lines().filter_map(is_step_line).collect();
    let out = match status {
        "open" => {
            let bare = with_line(raw, None);
            if !steps.is_empty() && steps.iter().all(|d| *d) {
                with_ticks(&bare, false)
            } else {
                bare
            }
        }
        "done" if !steps.is_empty() => with_ticks(&with_line(raw, None), true),
        s => with_line(raw, Some((s, reason))),
    };
    (out != raw).then_some(out)
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
        ("spec" | "decision", "head") => {
            // a head with no status line of its own (front matter, or none) is left alone
            if !crate::spec::has_status_line(body) {
                return None;
            }
            let word = match (status, kind) {
                ("done", "spec") => "approved",
                ("done", _) => "accepted",
                ("dropped", _) => "superseded",
                _ => "proposed",
            };
            Some(crate::spec::with_status(body, word))
        }
        ("task", "task") => task_with_status(body, status, None),
        _ => None,
    }
}
