//! A search match's context: the innermost definition around its line (the Search view's label rows, `ctx` on a match
//! node). The definitions are Hrafn's symbols of the file, from one parse of the text the search read (as
//! `search/symbol-at` finds them); code languages only (no context for text, Org or Markdown), none past 2 MB.

use hrafn::Lang;
use hrafn::chunk::{BUDGET, chunk_file};

/// A file larger than this gets no context.
pub const MAX_BYTES: usize = 2 << 20;

/// One definition: its name and kind, its lines (from 1, inclusive), its bytes, and the names of the definitions
/// around it, outermost first, ending with its own.
#[derive(Debug, Clone, PartialEq)]
pub struct Def {
    pub name: String,
    pub kind: String,
    pub line_start: u32,
    pub line_end: u32,
    pub start: u32,
    pub end: u32,
    pub path: Vec<String>,
}

/// A file's definitions, by first line (an outer one before the ones it holds), each knowing the one around it.
#[derive(Debug, Default)]
pub struct Defs {
    defs: Vec<Def>,
    parent: Vec<Option<usize>>,
}

/// The definitions of the file PATH whose text is TEXT; none for a language with no definitions or a file too large.
pub fn defs(path: &str, text: &str) -> Option<Defs> {
    if text.len() > MAX_BYTES {
        return None;
    }
    let (lang, _) = hrafn::classify(path, text.as_bytes());
    if matches!(lang, Lang::Text | Lang::Org | Lang::Markdown) {
        return None;
    }
    let (_, symbols) = chunk_file(path, lang, false, text, BUDGET);
    let mut defs: Vec<Def> = symbols
        .into_iter()
        .map(|s| Def {
            name: s.name,
            kind: s.kind,
            line_start: s.line_start,
            line_end: s.line_end,
            start: s.start,
            end: s.end,
            path: Vec::new(),
        })
        .collect();
    // outer first: by start, the longer before the shorter
    defs.sort_by(|a, b| a.start.cmp(&b.start).then(b.end.cmp(&a.end)));
    let mut parent = Vec::with_capacity(defs.len());
    let mut open: Vec<usize> = Vec::new();
    for i in 0..defs.len() {
        while let Some(&o) = open.last() {
            if defs[o].end >= defs[i].end && defs[o].start <= defs[i].start {
                break;
            }
            open.pop();
        }
        let p = open.last().copied();
        let mut path = p.map(|p| defs[p].path.clone()).unwrap_or_default();
        path.push(defs[i].name.clone());
        defs[i].path = path;
        parent.push(p);
        open.push(i);
    }
    Some(Defs { defs, parent })
}

impl Defs {
    /// The innermost definition holding LINE (from 1); none at the top level. The last definition starting at or before
    /// LINE, or the nearest one around it that reaches LINE.
    pub fn at(&self, line: u32) -> Option<&Def> {
        let n = self.defs.partition_point(|d| d.line_start <= line);
        let mut i = n.checked_sub(1)?;
        loop {
            let d = &self.defs[i];
            if d.line_end >= line {
                return Some(d);
            }
            i = self.parent[i]?;
        }
    }
}

#[cfg(test)]
mod tests;
