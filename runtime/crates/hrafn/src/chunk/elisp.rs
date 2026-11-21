//! Emacs Lisp: top-level forms from `tree-sitter-elisp`, the definer table for symbols, greedy merging within a
//! section and splitting of oversized forms at their child forms.

use super::definers;
use super::merge::{self, Form};
use super::refs::{self, Ref};
use super::{Chunk, Symbol};

fn parse(text: &str) -> Option<tree_sitter::Tree> {
    let mut parser = tree_sitter::Parser::new();
    parser
        .set_language(&tree_sitter_elisp::LANGUAGE.into())
        .ok()?;
    parser.parse(text, None)
}

fn forms_of(tree: &tree_sitter::Tree) -> Vec<(usize, usize)> {
    let root = tree.root_node();
    let mut cursor = root.walk();
    root.children(&mut cursor)
        .filter(|n| n.kind() != "comment")
        .map(|n| (n.start_byte(), n.end_byte()))
        .collect()
}

/// The byte spans of the file's top-level forms, in order (the Emacs reader's spans, which the tests hold it to).
pub fn top_level_forms(text: &str) -> Vec<(usize, usize)> {
    parse(text).map(|t| forms_of(&t)).unwrap_or_default()
}

fn analyse(text: &str, start: usize, end: usize) -> Form {
    let mut form = Form::plain(start, end);
    let head_atoms = definers::atoms(text, start, end, 1);
    let Some(h) = head_atoms.first() else {
        return form;
    };
    let head = &text[h.start..h.end];
    let Some(d) = definers::definer(head) else {
        return form;
    };
    // The cl-defstruct and the keyword docs need every atom.
    let all = definers::atoms(text, start, end, usize::MAX);
    form.head = head.to_string();
    form.defs = definers::defined(d, text, &all);
    form.doc = definers::doc_of(d, text, &all);
    form.heavy = definers::data_heavy(d, text, &all);
    form
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

/// The child forms an oversized form may be cut before: its atoms after the head, name, arguments and docstring.
fn cuts(text: &str, form: &Form) -> Vec<(usize, usize)> {
    let atoms = definers::atoms(text, form.start, form.end, usize::MAX);
    let has_doc = atoms
        .get(3)
        .is_some_and(|a| text[a.start..].starts_with('"'));
    let body_from = if has_doc { 4 } else { 3 };
    atoms
        .iter()
        .skip(body_from)
        .map(|a| (a.start, a.end))
        .collect()
}

pub(super) fn chunk(
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> (Vec<Chunk>, Vec<Symbol>, Vec<Ref>) {
    let title = title_of(text);
    let tree = parse(text);
    let (chunks, symbols) = merge::assemble(merge::Input {
        path,
        generated,
        text,
        budget,
        title: title.as_deref(),
        spans: tree.as_ref().map(forms_of).unwrap_or_default(),
        analyse: &|s, e| analyse(text, s, e),
        heading: &|a, b| heading_in(text, a, b),
        cuts: &|f| cuts(text, f),
    });
    let refs = tree.map(|t| refs::of_lisp(&t, text)).unwrap_or_default();
    (chunks, symbols, refs)
}
