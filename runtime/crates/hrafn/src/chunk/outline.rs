//! Org and Markdown: the heading tree. A chunk's header is its outline path; source blocks stay whole under the
//! budget; property drawers and logbooks stay out of `embed_text`; a table that is split repeats its header rows in
//! `embed_text`.

use super::merge::{self, Unit};
use super::text::windows;
use super::{Chunk, Header, Lines, Nws, Symbol, build_chunk};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Flavor {
    Org,
    Markdown,
}

struct Section {
    start: usize,
    end: usize,
    /// The outline path: `A > B > C`; none before the first heading.
    path: Option<String>,
}

/// The lines of `text` as `(start, end-with-newline)`.
fn line_spans(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < text.len() {
        let end = text[at..].find('\n').map_or(text.len(), |i| at + i + 1);
        out.push((at, end));
        at = end;
    }
    out
}

fn block_start(flavor: Flavor, line: &str) -> Option<()> {
    let t = line.trim_start();
    match flavor {
        Flavor::Org => t.to_ascii_lowercase().starts_with("#+begin_").then_some(()),
        Flavor::Markdown => (t.starts_with("```") || t.starts_with("~~~")).then_some(()),
    }
}

fn block_end(flavor: Flavor, line: &str, opened_with: &str) -> bool {
    let t = line.trim_start();
    match flavor {
        Flavor::Org => t.to_ascii_lowercase().starts_with("#+end_"),
        Flavor::Markdown => t.starts_with(&opened_with.trim_start()[..3]),
    }
}

/// `(level, title)` of a heading line.
fn heading(flavor: Flavor, line: &str) -> Option<(usize, String)> {
    let line = line.trim_end();
    match flavor {
        Flavor::Org => {
            let stars = line.bytes().take_while(|b| *b == b'*').count();
            if stars == 0 || !line[stars..].starts_with(' ') {
                return None;
            }
            let mut t = line[stars..].trim();
            // drop trailing tags: " :a:b:"
            if let Some((head, tags)) = t.rsplit_once(' ')
                && tags.len() > 2
                && tags.starts_with(':')
                && tags.ends_with(':')
            {
                t = head.trim();
            }
            Some((stars, t.to_string()))
        }
        Flavor::Markdown => {
            let hashes = line.bytes().take_while(|b| *b == b'#').count();
            if hashes == 0 || hashes > 6 || !line[hashes..].starts_with(' ') {
                return None;
            }
            Some((
                hashes,
                line[hashes..]
                    .trim()
                    .trim_end_matches('#')
                    .trim()
                    .to_string(),
            ))
        }
    }
}

/// The headings of the file, with their outline paths. Lines inside source blocks or fences are not headings.
fn sections(flavor: Flavor, text: &str, lines: &[(usize, usize)]) -> Vec<Section> {
    let mut out: Vec<Section> = vec![Section {
        start: 0,
        end: text.len(),
        path: None,
    }];
    let mut stack: Vec<(usize, String)> = Vec::new();
    let mut open: Option<&str> = None;
    for &(s, e) in lines {
        let line = &text[s..e];
        if let Some(o) = open {
            if block_end(flavor, line, o) {
                open = None;
            }
            continue;
        }
        if block_start(flavor, line).is_some() {
            open = Some(line);
            continue;
        }
        if let Some((level, title)) = heading(flavor, line) {
            while stack.last().is_some_and(|(l, _)| *l >= level) {
                stack.pop();
            }
            stack.push((level, title));
            let path = stack
                .iter()
                .map(|(_, t)| t.as_str())
                .collect::<Vec<_>>()
                .join(" > ");
            out.last_mut().expect("preamble").end = s;
            out.push(Section {
                start: s,
                end: text.len(),
                path: Some(path),
            });
        }
    }
    if out[0].start == out[0].end {
        out.remove(0);
    }
    out
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum BlockKind {
    Para,
    Src,
    Drawer,
    Table,
}

/// The blocks of a stretch: source blocks and drawers are whole, a table is a run of `|` lines, the rest is paragraphs.
/// Blank lines belong to the block before them, so the blocks cover the stretch.
fn blocks(
    flavor: Flavor,
    text: &str,
    lines: &[(usize, usize)],
    (a, b): (usize, usize),
) -> Vec<(usize, usize, BlockKind)> {
    let mine: Vec<(usize, usize)> = lines
        .iter()
        .copied()
        .filter(|(s, _)| *s >= a && *s < b)
        .collect();
    let mut out: Vec<(usize, usize, BlockKind)> = Vec::new();
    let mut i = 0;
    while i < mine.len() {
        let (s, e) = mine[i];
        let line = &text[s..e];
        let (kind, mut j) = if block_start(flavor, line).is_some() {
            let mut j = i + 1;
            while j < mine.len() && !block_end(flavor, &text[mine[j].0..mine[j].1], line) {
                j += 1;
            }
            (BlockKind::Src, (j + 1).min(mine.len()))
        } else if flavor == Flavor::Org
            && matches!(
                line.trim().to_ascii_uppercase().as_str(),
                ":PROPERTIES:" | ":LOGBOOK:"
            )
        {
            let mut j = i + 1;
            while j < mine.len() && text[mine[j].0..mine[j].1].trim() != ":END:" {
                j += 1;
            }
            (BlockKind::Drawer, (j + 1).min(mine.len()))
        } else if line.trim_start().starts_with('|') {
            let mut j = i + 1;
            while j < mine.len() && text[mine[j].0..mine[j].1].trim_start().starts_with('|') {
                j += 1;
            }
            (BlockKind::Table, j)
        } else {
            let mut j = i + 1;
            while j < mine.len() && !text[mine[j].0..mine[j].1].trim().is_empty() {
                j += 1;
            }
            (BlockKind::Para, j)
        };
        // trailing blank lines stay with the block
        while j < mine.len() && text[mine[j].0..mine[j].1].trim().is_empty() {
            j += 1;
        }
        out.push((s, mine[j - 1].1, kind));
        i = j;
    }
    out
}

/// A table's header rows: the first row, and the rule line after it when there is one.
fn table_header(text: &str, (a, b): (usize, usize)) -> String {
    let mut rows = text[a..b].lines();
    let mut head = rows.next().unwrap_or("").to_string();
    if let Some(rule) = rows.next()
        && (rule.trim_start().starts_with("|-") || rule.contains("---"))
    {
        head.push('\n');
        head.push_str(rule);
    }
    head
}

/// Spans for a stretch that is over the budget: whole blocks packed up to it; a table over it splits by rows, any
/// other block over it by lines. The second element is the table header to repeat for a later piece of a table.
fn split_section(
    flavor: Flavor,
    text: &str,
    nws: &Nws,
    lines: &[(usize, usize)],
    span: (usize, usize),
    budget: usize,
) -> Vec<((usize, usize), Option<String>)> {
    let mut out = Vec::new();
    let mut cur = span.0;
    for (s, e, kind) in blocks(flavor, text, lines, span) {
        if nws.count(cur, e) <= budget {
            continue;
        }
        if s > cur {
            out.push(((cur, s), None));
            cur = s;
        }
        if nws.count(s, e) <= budget {
            continue;
        }
        // a block over the budget on its own
        let pieces = windows(text, nws, (s, e), budget);
        let head = (kind == BlockKind::Table).then(|| table_header(text, (s, e)));
        for (k, p) in pieces.into_iter().enumerate() {
            out.push((p, if k > 0 { head.clone() } else { None }));
        }
        cur = e;
    }
    if cur < span.1 {
        out.push(((cur, span.1), None));
    }
    out
}

/// Drawers (`:PROPERTIES:`, `:LOGBOOK:`) removed from an Org chunk's text.
fn without_drawers(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut skipping = false;
    for line in body.split_inclusive('\n') {
        let t = line.trim().to_ascii_uppercase();
        if skipping {
            if t == ":END:" {
                skipping = false;
            }
            continue;
        }
        if t == ":PROPERTIES:" || t == ":LOGBOOK:" {
            skipping = true;
            continue;
        }
        out.push_str(line);
    }
    out
}

pub(super) fn chunk(
    flavor: Flavor,
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> (Vec<Chunk>, Vec<Symbol>) {
    if text.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let nws = Nws::new(text);
    let line_index = Lines::new(text);
    let lines = line_spans(text);
    let secs = sections(flavor, text, &lines);

    // A heading with nothing under it joins the next one.
    let mut units: Vec<Unit> = Vec::with_capacity(secs.len());
    let mut prev_bare = false;
    for s in &secs {
        let body_empty = {
            let first_end = text[s.start..s.end]
                .find('\n')
                .map_or(s.end, |i| s.start + i + 1);
            s.path.is_some() && nws.count(first_end, s.end) == 0
        };
        units.push(Unit {
            start: s.start,
            end: s.end,
            boundary: !prev_bare,
            solo: false,
        });
        prev_bare = body_empty;
    }

    let mut chunks = Vec::new();
    for group in merge::merge(&units, &nws, budget) {
        let (start, end) = (units[group.start].start, units[group.end - 1].end);
        // the outline path of the last section in the group is the deepest and holds the others as its prefix
        let section = secs[group.end - 1].path.as_deref();
        let header = Header {
            path,
            title: None,
            section,
            defs: Vec::new(),
            docs: Vec::new(),
            part: None,
        };
        let spans = if nws.count(start, end) > budget {
            split_section(flavor, text, &nws, &lines, (start, end), budget)
        } else {
            vec![((start, end), None)]
        };
        for (span, table_head) in spans {
            let embed = !generated && nws.count(span.0, span.1) > 0;
            let body = &text[span.0..span.1];
            let mut over: Option<String> = match flavor {
                Flavor::Org => {
                    let w = without_drawers(body);
                    (w != body).then_some(w)
                }
                Flavor::Markdown => None,
            };
            if let Some(h) = table_head {
                over = Some(format!("{h}\n{}", over.as_deref().unwrap_or(body)));
            }
            chunks.push(build_chunk(
                text,
                &line_index,
                span,
                &header,
                over.as_deref(),
                embed,
            ));
        }
    }
    (chunks, Vec::new())
}
