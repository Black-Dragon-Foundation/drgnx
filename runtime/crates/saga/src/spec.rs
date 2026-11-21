//! Specs and decision records (ADRs): one record per file.  Its title is the first `# ` heading, its status the
//! word after a `**Status:**` / `Status:` line or a front-matter `status:` (MADR), and its headings are kept as
//! anchors, so the editor can open the file at one.  The text is kept whole: the record's body is the file.

use crate::md;

/// A spec or ADR as read.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpecDoc {
    pub title: Option<String>,
    /// The status word as written (`approved`, `accepted`, `draft 1`…), before `status::normalize`.
    pub status: Option<String>,
    /// Every heading: (its text, its byte offset), in order.
    pub anchors: Vec<(String, usize)>,
    pub text: String,
}

/// The status word of a `status:` front-matter line (between `---` lines at the top) of TEXT.
fn front_matter_status(text: &str) -> Option<String> {
    let rest = text.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    rest[..end].lines().find_map(|l| {
        l.strip_prefix("status:")
            .map(|v| v.trim().trim_matches(['"', '\'']).to_string())
            .filter(|v| !v.is_empty())
    })
}

/// The status of a `**Status:**` or `Status:` line of TEXT (the first one, outside code fences).
fn line_status(text: &str) -> Option<String> {
    let mut fenced = false;
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let rest = t
            .strip_prefix("**Status:**")
            .or_else(|| t.strip_prefix("**Status**:"))
            .or_else(|| t.strip_prefix("Status:"));
        if let Some(r) = rest {
            let word: String = r
                .trim()
                .trim_start_matches(['*', '_'])
                .split(['.', ',', ';', '('])
                .next()
                .unwrap_or("")
                .trim()
                .trim_end_matches(['*', '_'])
                .to_string();
            if !word.is_empty() {
                return Some(word);
            }
        }
    }
    None
}

pub fn parse(text: &str) -> SpecDoc {
    let heads = md::headings(text);
    let title = heads
        .iter()
        .find(|h| h.level == 1)
        .map(|h| h.text.trim().to_string())
        .filter(|t| !t.is_empty());
    SpecDoc {
        title,
        status: front_matter_status(text).or_else(|| line_status(text)),
        anchors: heads
            .iter()
            .map(|h| (h.text.trim().to_string(), h.start))
            .collect(),
        text: text.to_string(),
    }
}
