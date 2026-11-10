//! Greedy merging of adjacent units into chunks, and the pipeline that turns a file's top-level forms into chunks
//! and symbols (shared by Lisp and the tree-sitter languages).

use super::definers::Def;
use super::{Chunk, Header, Lines, Nws, Symbol, build_chunk, signature};
use std::ops::Range;

/// A stretch of the file that is not split further unless it is over the budget on its own.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Unit {
    pub start: usize,
    pub end: usize,
    /// A section starts here: the chunk before it ends.
    pub boundary: bool,
    /// Stands alone whatever its size (data-heavy forms).
    pub solo: bool,
}

/// Groups of consecutive units, each within `budget` non-whitespace characters, or a single unit that is over it or
/// stands alone. A group never crosses a `boundary`.
pub(crate) fn merge(units: &[Unit], nws: &Nws, budget: usize) -> Vec<Range<usize>> {
    let mut out: Vec<Range<usize>> = Vec::new();
    let mut open: Option<usize> = None; // first unit of the group being filled
    for (i, u) in units.iter().enumerate() {
        let alone = u.solo || nws.count(u.start, u.end) > budget;
        if alone {
            if let Some(a) = open.take() {
                out.push(a..i);
            }
            out.push(i..i + 1);
            continue;
        }
        match open {
            Some(a) if !u.boundary && nws.count(units[a].start, u.end) <= budget => {}
            Some(a) => {
                out.push(a..i);
                open = Some(i);
            }
            None => open = Some(i),
        }
    }
    if let Some(a) = open {
        out.push(a..units.len());
    }
    out
}

/// A top-level form: its span, and what it defines.
pub(crate) struct Form {
    pub start: usize,
    pub end: usize,
    pub head: String,
    pub defs: Vec<Def>,
    /// `(first line, whole docstring)`.
    pub doc: Option<(String, String)>,
    /// A literal table: over the budget it embeds only its head and docstring.
    pub heavy: bool,
}

impl Form {
    pub(crate) fn plain(start: usize, end: usize) -> Form {
        Form {
            start,
            end,
            head: String::new(),
            defs: Vec::new(),
            doc: None,
            heavy: false,
        }
    }
}

/// What a language gives the pipeline.
pub(crate) struct Input<'a> {
    pub path: &'a str,
    pub generated: bool,
    pub text: &'a str,
    pub budget: usize,
    pub title: Option<&'a str>,
    /// The byte spans of the top-level forms, in order.
    pub spans: Vec<(usize, usize)>,
    pub analyse: &'a dyn Fn(usize, usize) -> Form,
    /// A section heading inside `text[a..b]`.
    pub heading: &'a dyn Fn(usize, usize) -> Option<String>,
    /// Where an oversized form may be cut: the spans of its child forms after its head.
    pub cuts: &'a dyn Fn(&Form) -> Vec<(usize, usize)>,
}

/// The start of the part of the gap `[a, b)` that belongs to the next form: after the last blank line.
fn after_last_blank_line(text: &str, a: usize, b: usize) -> usize {
    let mut p = a;
    let mut ls = None::<usize>; // the start of the current line, once a newline has been seen
    for (i, c) in text[a..b].char_indices() {
        let i = a + i;
        if c == '\n' {
            if let Some(s) = ls
                && text[s..i].trim().is_empty()
            {
                p = i + 1;
            }
            ls = Some(i + 1);
        }
    }
    p
}

pub(crate) fn assemble(input: Input) -> (Vec<Chunk>, Vec<Symbol>) {
    let Input {
        path,
        generated,
        text,
        budget,
        title,
        spans,
        analyse,
        heading,
        cuts,
    } = input;
    if text.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let nws = Nws::new(text);
    let lines = Lines::new(text);

    // Units: a form with the comments right above it, and a gap between forms that ends in a blank line.
    let mut units: Vec<Unit> = Vec::new();
    let mut forms: Vec<Option<Form>> = Vec::new();
    let mut prev = 0;
    for (fs, fe) in spans {
        let mut p = after_last_blank_line(text, prev, fs);
        if p > prev {
            if !text[prev..p].trim().is_empty() {
                units.push(Unit {
                    start: prev,
                    end: p,
                    boundary: false,
                    solo: false,
                });
                forms.push(None);
            } else if let Some(last) = units.last_mut() {
                // blank space belongs to the unit before it
                last.end = p;
            } else {
                p = prev;
            }
        }
        let form = analyse(fs, fe);
        units.push(Unit {
            start: p,
            end: fe,
            boundary: false,
            solo: form.heavy && nws.count(p, fe) > budget,
        });
        forms.push(Some(form));
        prev = fe;
    }
    if prev < text.len() && text[prev..].trim().is_empty() && !units.is_empty() {
        units.last_mut().expect("not empty").end = text.len();
    } else if prev < text.len() {
        units.push(Unit {
            start: prev,
            end: text.len(),
            boundary: false,
            solo: false,
        });
        forms.push(None);
    }

    // Sections: a heading inside a unit starts one; the units after the heading carry its name.
    let mut section_of: Vec<Option<String>> = Vec::with_capacity(units.len());
    let mut current: Option<String> = None;
    for u in units.iter_mut() {
        if let Some(h) = heading(u.start, u.end) {
            u.boundary = true;
            current = Some(h);
        }
        section_of.push(current.clone());
    }

    let mut chunks: Vec<Chunk> = Vec::new();
    let mut symbols: Vec<Symbol> = Vec::new();
    for group in merge(&units, &nws, budget) {
        let (start, end) = (units[group.start].start, units[group.end - 1].end);
        let group_forms: Vec<&Form> = forms[group.clone()].iter().flatten().collect();
        let defs: Vec<(String, String)> = group_forms
            .iter()
            .flat_map(|f| f.defs.iter().map(|d| (d.name.clone(), d.kind.to_string())))
            .collect();
        let docs: Vec<String> = group_forms
            .iter()
            .filter_map(|f| f.doc.as_ref().map(|d| d.1.clone()))
            .collect();
        let header = Header {
            path,
            title,
            section: section_of[group.start].as_deref(),
            defs,
            docs,
            part: None,
        };
        let embed = !generated && nws.count(start, end) > 0;
        let single = group.len() == 1 && group_forms.len() == 1;
        let heavy = single && group_forms[0].heavy && units[group.start].solo;
        if single && !heavy && nws.count(start, end) > budget {
            let form = group_forms[0];
            let parts = split_parts(&nws, (start, end), &cuts(form), budget, text);
            let n = parts.len();
            let sig = text[form.start..form.end]
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            for (i, span) in parts.into_iter().enumerate() {
                let h = Header {
                    path,
                    title: header.title,
                    section: header.section,
                    defs: header.defs.clone(),
                    docs: header.docs.clone(),
                    part: Some((i + 1, n, sig.clone())),
                };
                chunks.push(build_chunk(text, &lines, span, &h, None, embed));
            }
        } else if heavy {
            let form = group_forms[0];
            let sig = text[form.start..form.end]
                .lines()
                .next()
                .unwrap_or("")
                .trim();
            let mut short = sig.to_string();
            if let Some((_, full)) = &form.doc {
                short.push('\n');
                short.push_str(full);
            }
            chunks.push(build_chunk(
                text,
                &lines,
                (start, end),
                &header,
                Some(&short),
                embed,
            ));
        } else {
            chunks.push(build_chunk(
                text,
                &lines,
                (start, end),
                &header,
                None,
                embed,
            ));
        }
        for f in &group_forms {
            for d in &f.defs {
                let (s, e) = d.span.unwrap_or((f.start, f.end));
                symbols.push(Symbol {
                    name: d.name.clone(),
                    kind: d.kind.to_string(),
                    start: s as u32,
                    end: e as u32,
                    chunk: 0,
                    definer: f.head.clone(),
                    doc1: d
                        .doc1
                        .clone()
                        .or_else(|| f.doc.as_ref().map(|d| d.0.clone())),
                    line_start: lines.line_of(s),
                    line_end: lines.line_of(e.saturating_sub(1).max(s)),
                    sig: signature(text, s, e, &d.name),
                });
            }
        }
    }
    // A symbol belongs to the chunk that holds its start.
    for s in &mut symbols {
        let i = chunks
            .partition_point(|c| c.start <= s.start)
            .saturating_sub(1);
        s.chunk = i as u32;
    }
    (chunks, symbols)
}

/// Split an oversized unit at its child forms: a part ends before the child form that would take it over the budget.
fn split_parts(
    nws: &Nws,
    (start, end): (usize, usize),
    cuts: &[(usize, usize)],
    budget: usize,
    text: &str,
) -> Vec<(usize, usize)> {
    let mut parts = Vec::new();
    let mut ps = start;
    for &(a_start, a_end) in cuts {
        if nws.count(ps, a_end) <= budget {
            continue;
        }
        let mut cut = a_start;
        // begin the new part at its line, when only blanks precede the child form
        if let Some(nl) = text[..cut].rfind('\n')
            && nl + 1 > ps
            && text[nl + 1..cut].trim().is_empty()
        {
            cut = nl + 1;
        }
        if cut > ps {
            parts.push((ps, cut));
            ps = cut;
        }
    }
    parts.push((ps, end));
    parts
}
