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
    /// The title, the status line and the text before the first level-2 heading outside code fences.
    pub head: String,
    /// One per level-2 heading; deeper headings stay in their section.
    pub sections: Vec<SpecSection>,
}

/// One `## ` section of a spec: the raw heading line and the text up to the next level-2 heading.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpecSection {
    /// The raw line, with its terminator.
    pub heading: String,
    pub title: String,
    pub slug: String,
    pub body: String,
}

/// What `records/write` changes in a spec's text.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpecEdits {
    pub title: Option<String>,
    /// A status word as the file says it (`approved`, `proposed`…).
    pub status: Option<String>,
    pub sections: Vec<SectionEdit>,
    /// Section keys (`section <slug>`) to drop.
    pub remove: Vec<String>,
}

/// One section written: with a key it replaces that section, without it is new (after `after`, else last).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SectionEdit {
    pub key: Option<String>,
    /// The heading text, with no `#` marks and no line break.
    pub heading: String,
    pub body: String,
    pub after: Option<String>,
}

/// TITLE as a section key's slug: lower-case ASCII letters and digits, every other run one `-`, trimmed; `section`
/// when nothing is left.
pub fn slug(title: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            if gap && !out.is_empty() {
                out.push('-');
            }
            gap = false;
            out.push(c.to_ascii_lowercase());
        } else {
            gap = true;
        }
    }
    if out.is_empty() {
        "section".into()
    } else {
        out
    }
}

/// The key of every section of SECTIONS: `section <slug>`, a repeat getting ` #2`, ` #3`.
pub fn section_keys(sections: &[SpecSection]) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    for s in sections {
        let base = format!("section {}", s.slug);
        let key = if keys.contains(&base) {
            (2..)
                .map(|n| format!("{base} #{n}"))
                .find(|k| !keys.contains(k))
                .expect("unbounded")
        } else {
            base
        };
        keys.push(key);
    }
    keys
}

/// The text of D: its head and every section, as parsed (`render(parse(t)) == t`).
pub fn render(d: &SpecDoc) -> String {
    let mut out = d.head.clone();
    for s in &d.sections {
        out.push_str(&s.heading);
        out.push_str(&s.body);
    }
    out
}

/// Where the word of a `**Status:**` / `Status:` line is: (the line's start, the label's end, the line's end without
/// its terminator), the first such line outside code fences.
fn status_line(text: &str) -> Option<(usize, usize, usize)> {
    let mut fenced = false;
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        let t = line.trim_start();
        if t.starts_with("```") {
            fenced = !fenced;
        } else if !fenced {
            let indent = line.len() - t.len();
            for label in ["**Status:**", "**Status**:", "Status:"] {
                if t.starts_with(label) {
                    let end = at + line.trim_end_matches(['\n', '\r']).len();
                    return Some((at, at + indent + label.len(), end));
                }
            }
        }
        at += line.len();
    }
    None
}

/// Whether TEXT has a status line `with_status` can rewrite.
pub fn has_status_line(text: &str) -> bool {
    status_line(text).is_some()
}

/// HEAD with the word of its first `**Status:**` / `Status:` line set to WORD, or `**Status:** WORD` inserted after
/// the title line.
pub fn with_status(head: &str, word: &str) -> String {
    if let Some((_, label_end, end)) = status_line(head) {
        let rest = &head[label_end..end];
        // what follows the word (`approved (2026-11-22)`) stays
        let tail = rest.find(['.', ',', ';', '(']).map_or("", |i| &rest[i..]);
        return format!("{} {word}{tail}{}", &head[..label_end], &head[end..]);
    }
    match md::headings(head).into_iter().find(|h| h.level == 1) {
        Some(h) => {
            let mut out = head[..h.line_end].to_string();
            if !out.ends_with('\n') {
                out.push('\n');
            }
            out.push_str(&format!("\n**Status:** {word}\n"));
            out.push_str(&head[h.line_end..]);
            out
        }
        None => format!("**Status:** {word}\n\n{head}"),
    }
}

/// A section as written: its heading line and body, the body ending in a line break (a blank line when another
/// section follows).
fn section_text(heading: &str, body: &str, last: bool) -> (String, String) {
    let mut b = body.to_string();
    if !b.ends_with('\n') {
        b.push('\n');
    }
    if !last && !b.ends_with("\n\n") {
        b.push('\n');
    }
    (format!("## {heading}\n"), format!("\n{b}"))
}

fn check_heading(h: &str) -> villa::Result<()> {
    if h.trim().is_empty() || h.contains(['\n', '\r']) || h.trim_start().starts_with('#') {
        return Err(villa::Error::invalid(format!(
            "a section heading is one line of text with no `#` ({h:?})"
        )));
    }
    Ok(())
}

fn check_body(b: &str) -> villa::Result<()> {
    if md::headings(b).iter().any(|h| h.level == 2) {
        return Err(villa::Error::invalid(
            "a section body holds no level-2 heading (`## `) outside a code fence: write it as its own section",
        ));
    }
    Ok(())
}

/// TEXT with EDITS applied; an unknown key, a bad heading or a body holding a level-2 heading is an error.
pub fn edit(text: &str, e: &SpecEdits) -> villa::Result<String> {
    let doc = parse(text);
    let keys = section_keys(&doc.sections);
    let known = |k: &str| keys.iter().position(|x| x == k);
    // (original key, heading text, body) in order
    let mut items: Vec<(Option<String>, String, String)> = doc
        .sections
        .iter()
        .zip(&keys)
        .map(|(s, k)| (Some(k.clone()), s.heading.clone(), s.body.clone()))
        .collect();
    for k in &e.remove {
        known(k).ok_or_else(|| villa::Error::not_found(format!("no section {k:?} to remove")))?;
    }
    for w in &e.sections {
        check_heading(&w.heading)?;
        check_body(&w.body)?;
    }
    let mut head = doc.head.clone();
    if let Some(t) = &e.title {
        check_heading(t)?;
        match md::headings(&head).into_iter().find(|h| h.level == 1) {
            Some(h) => head.replace_range(h.start..h.line_end, &format!("# {t}\n")),
            None => head = format!("# {t}\n\n{head}"),
        }
    }
    if let Some(st) = &e.status {
        head = with_status(&head, st);
    }
    let mut inserts: Vec<(usize, String, String)> = Vec::new(); // (after index, heading, body)
    let mut append: Vec<(String, String)> = Vec::new();
    for w in &e.sections {
        match (&w.key, &w.after) {
            (Some(k), _) => {
                let i =
                    known(k).ok_or_else(|| villa::Error::not_found(format!("no section {k:?}")))?;
                let (h, b) = section_text(&w.heading, &w.body, true);
                items[i].1 = h;
                items[i].2 = b;
            }
            (None, Some(a)) => {
                let i = known(a).ok_or_else(|| {
                    villa::Error::not_found(format!("no section {a:?} to put it after"))
                })?;
                inserts.push((i, w.heading.clone(), w.body.clone()));
            }
            (None, None) => append.push((w.heading.clone(), w.body.clone())),
        }
    }
    let mut out: Vec<(String, String)> = Vec::new();
    for (i, (key, h, b)) in items.iter().enumerate() {
        let gone = key.as_ref().is_some_and(|k| e.remove.contains(k));
        if !gone {
            out.push((h.clone(), b.clone()));
        }
        for (_, ih, ib) in inserts.iter().filter(|(at, _, _)| *at == i) {
            let (h, b) = section_text(ih, ib, true);
            out.push((h, b));
        }
    }
    for (h, b) in &append {
        let (h, b) = section_text(h, b, true);
        out.push((h, b));
    }
    let n = out.len();
    let mut s = head;
    for (i, (h, b)) in out.iter().enumerate() {
        s.push_str(h);
        let mut b = b.clone();
        if i + 1 < n && !b.ends_with("\n\n") {
            if !b.ends_with('\n') {
                b.push('\n');
            }
            b.push('\n');
        }
        s.push_str(&b);
    }
    Ok(s)
}

/// A new spec: a title, a status line and SECTIONS as (heading, body).
pub fn new_text(title: &str, status: &str, sections: &[(String, String)]) -> String {
    let mut s = format!("# {title}\n\n**Status:** {status}\n");
    let n = sections.len();
    for (i, (h, b)) in sections.iter().enumerate() {
        let (h, b) = section_text(h, b, i + 1 == n);
        if i == 0 {
            s.push('\n');
        }
        s.push_str(&h);
        s.push_str(&b);
    }
    s
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
    let h2: Vec<&md::Heading> = heads.iter().filter(|h| h.level == 2).collect();
    let head = text[..h2.first().map_or(text.len(), |h| h.start)].to_string();
    let sections: Vec<SpecSection> = h2
        .iter()
        .enumerate()
        .map(|(i, h)| {
            let end = h2.get(i + 1).map_or(text.len(), |n| n.start);
            SpecSection {
                heading: text[h.start..h.line_end].to_string(),
                title: h.text.trim().to_string(),
                slug: slug(&h.text),
                body: text[h.line_end..end].to_string(),
            }
        })
        .collect();
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
        head,
        sections,
    }
}
