//! Ledgers (`<plan>.ledger.md`): a header and `##` sections, each tied to a task when its heading names one
//! (`## Task 0 (manager)`, `## Library evaluation (Task 5 step 1)`).  Byte-exact like plans.

use crate::md;
use crate::plan::split;

/// `heading` is the raw heading line with its terminator, `body` everything after it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerSection {
    pub task: Option<String>,
    pub heading: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerDoc {
    /// Everything before the first section (the title and intro, level-1 headings included).
    pub header: String,
    pub sections: Vec<LedgerSection>,
}

pub fn parse(text: &str) -> LedgerDoc {
    let mut cuts = split(text, |t| md::task_heading(t).is_some());
    let leading = cuts.iter().take_while(|(h, _)| h.level == 1).count();
    cuts.drain(..leading);
    let header_end = cuts.first().map_or(text.len(), |(h, _)| h.start);
    let sections = cuts
        .into_iter()
        .map(|(h, span)| LedgerSection {
            task: md::task_mentioned(&h.text).map(str::to_string),
            heading: text[h.start..h.line_end].to_string(),
            body: text[h.line_end..span.end].to_string(),
        })
        .collect();
    LedgerDoc {
        header: text[..header_end].to_string(),
        sections,
    }
}

pub fn render(doc: &LedgerDoc) -> String {
    let mut out = doc.header.clone();
    for s in &doc.sections {
        out.push_str(&s.heading);
        out.push_str(&s.body);
    }
    out
}

/// A line of a ledger that says tasks are done: `Task 7: complete (commits a1b2c3d..e4f5a6b, tests: ...)`,
/// `Task 3-5: complete (commit 1234567 ...)`, `Task 22b: complete`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoneMark {
    /// The task numbers it covers, in order (`3-5` → 3, 4, 5; `22b` → one).
    pub tasks: Vec<String>,
    /// The commits it names, as written: a range's two ends, or the one commit.
    pub commits: Vec<String>,
}

/// The tasks a ledger's text marks complete.
pub fn done_marks(text: &str) -> Vec<DoneMark> {
    text.lines().filter_map(done_mark).collect()
}

fn is_sha(s: &str) -> bool {
    (4..=40).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn done_mark(line: &str) -> Option<DoneMark> {
    let rest = line.strip_prefix("Task ")?;
    let (head, tail) = rest.split_once(": complete")?;
    let tasks = match head.split_once('-') {
        Some((a, b))
            if a.bytes().all(|c| c.is_ascii_digit()) && b.bytes().all(|c| c.is_ascii_digit()) =>
        {
            let (a, b): (u32, u32) = (a.parse().ok()?, b.parse().ok()?);
            (a..=b.max(a)).map(|n| n.to_string()).collect()
        }
        _ if !head.is_empty() && head.bytes().all(|c| c.is_ascii_alphanumeric()) => {
            vec![head.to_string()]
        }
        _ => return None,
    };
    let mut commits = Vec::new();
    if let Some(at) = tail.find("commit") {
        let after = tail[at..].trim_start_matches(|c: char| c.is_ascii_alphabetic());
        let word: String = after
            .trim_start()
            .chars()
            .take_while(|c| c.is_ascii_hexdigit() || *c == '.')
            .collect();
        commits.extend(word.split("..").filter(|s| is_sha(s)).map(str::to_string));
    }
    Some(DoneMark { tasks, commits })
}
