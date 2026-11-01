//! Emacs Lisp: top-level forms from `tree-sitter-elisp`, the definer table for symbols, greedy merging within a
//! section and splitting of oversized forms at their child forms.

use super::definers::{self, Atom, Def};
use super::merge::{self, Unit};
use super::{Chunk, Header, Lines, Nws, Symbol, build_chunk};

/// A top-level form: its span, and what it defines.
struct Form {
    start: usize,
    end: usize,
    head: String,
    defs: Vec<Def>,
    doc: Option<(String, String)>,
    heavy: bool,
}

/// The byte spans of the file's top-level forms, in order (the Emacs reader's spans, which the tests hold it to).
pub fn top_level_forms(text: &str) -> Vec<(usize, usize)> {
    let mut parser = tree_sitter::Parser::new();
    if parser
        .set_language(&tree_sitter_elisp::LANGUAGE.into())
        .is_err()
    {
        return Vec::new();
    }
    let Some(tree) = parser.parse(text, None) else {
        return Vec::new();
    };
    let root = tree.root_node();
    let mut cursor = root.walk();
    root.children(&mut cursor)
        .filter(|n| n.kind() != "comment")
        .map(|n| (n.start_byte(), n.end_byte()))
        .collect()
}

fn analyse(text: &str, start: usize, end: usize) -> Form {
    let mut form = Form {
        start,
        end,
        head: String::new(),
        defs: Vec::new(),
        doc: None,
        heavy: false,
    };
    let head_atoms = definers::atoms(text, start, end, 1);
    let Some(h) = head_atoms.first() else {
        return form;
    };
    let head = &text[h.start..h.end];
    let Some(d) = definers::definer(head) else {
        return form;
    };
    // The cl-defstruct and the keyword docs need every atom; the rest need the first five.
    let all = definers::atoms(text, start, end, usize::MAX);
    form.head = head.to_string();
    form.defs = definers::defined(d, text, &all);
    form.doc = definers::doc_of(d, text, &all);
    form.heavy = definers::data_heavy(d, text, &all);
    form
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

/// A section heading on a line of its own at column 0: three or more semicolons, a space, text.
fn heading_in(text: &str, a: usize, b: usize) -> Option<String> {
    let mut found = None;
    let mut line_start = a;
    // a unit may start mid-line; only whole lines count
    if a > 0 && text.as_bytes()[a - 1] != b'\n' {
        line_start = text[a..b].find('\n').map_or(b, |i| a + i + 1);
    }
    while line_start < b {
        let line_end = text[line_start..b].find('\n').map_or(b, |i| line_start + i);
        let line = &text[line_start..line_end];
        let semis = line.bytes().take_while(|c| *c == b';').count();
        if semis >= 3 && line[semis..].starts_with(' ') {
            let h = line[semis..].trim();
            if !h.is_empty() {
                found = Some(h.to_string());
            }
        }
        line_start = line_end + 1;
    }
    found
}

/// The file's title: its first line when that is a `;;;` line, with the file name and the dashes dropped.
fn title_of(text: &str) -> Option<String> {
    let line = text.lines().next()?;
    if !line.starts_with(";;;") {
        return None;
    }
    let t = line.trim_start_matches(';').trim();
    let t = t.split_once("---").map_or(t, |(_, rest)| rest.trim());
    let t = t
        .strip_suffix("-*- lexical-binding: t; -*-")
        .unwrap_or(t)
        .trim();
    (!t.is_empty()).then(|| t.to_string())
}

pub(super) fn chunk(
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> (Vec<Chunk>, Vec<Symbol>) {
    if text.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let nws = Nws::new(text);
    let lines = Lines::new(text);
    let title = title_of(text);

    // Units: a form with the comments right above it, and a gap between forms that ends in a blank line.
    let mut units: Vec<Unit> = Vec::new();
    let mut forms: Vec<Option<Form>> = Vec::new();
    let mut prev = 0;
    for (fs, fe) in top_level_forms(text) {
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
        let form = analyse(text, fs, fe);
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

    // Sections: a heading inside a unit starts one; the unit after the heading carries its name.
    let mut section_of: Vec<Option<String>> = Vec::with_capacity(units.len());
    let mut current: Option<String> = None;
    for u in units.iter_mut() {
        if let Some(h) = heading_in(text, u.start, u.end) {
            u.boundary = true;
            current = Some(h);
        }
        section_of.push(current.clone());
    }

    let mut chunks: Vec<Chunk> = Vec::new();
    let mut symbols: Vec<Symbol> = Vec::new();
    for group in merge::merge(&units, &nws, budget) {
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
            title: title.as_deref(),
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
            let parts = split_parts(text, &nws, (start, end), form, budget);
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
        // A symbol belongs to the chunk that holds its form's start; set below, once the chunks are all known.
        for f in &group_forms {
            for d in &f.defs {
                symbols.push(Symbol {
                    name: d.name.clone(),
                    kind: d.kind.to_string(),
                    start: f.start as u32,
                    end: f.end as u32,
                    chunk: 0,
                    definer: f.head.clone(),
                    doc1: f.doc.as_ref().map(|d| d.0.clone()),
                });
            }
        }
    }
    for s in &mut symbols {
        let i = chunks
            .partition_point(|c| c.start <= s.start)
            .saturating_sub(1);
        s.chunk = i as u32;
    }
    (chunks, symbols)
}

/// Split an oversized form at its child forms: the head (up to the docstring) stays with the first part, and a part
/// ends before the child form that would take it over the budget.
fn split_parts(
    text: &str,
    nws: &Nws,
    (start, end): (usize, usize),
    form: &Form,
    budget: usize,
) -> Vec<(usize, usize)> {
    let atoms: Vec<Atom> = definers::atoms(text, form.start, form.end, usize::MAX);
    let doc_at = |i: usize| {
        atoms
            .get(i)
            .is_some_and(|a| text[a.start..].starts_with('"'))
    };
    let body_from = if doc_at(3) { 4 } else { 3 };
    let mut parts = Vec::new();
    let mut ps = start;
    for a in atoms.iter().skip(body_from) {
        if nws.count(ps, a.end) <= budget {
            continue;
        }
        let mut cut = a.start;
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
