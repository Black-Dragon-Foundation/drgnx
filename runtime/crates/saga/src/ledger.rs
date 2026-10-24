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
