//! Chunking: a file becomes chunks (what is embedded and searched) and symbols (what the file defines).
//!
//! A file's chunks put together give back the file, byte for byte. Offsets are byte offsets into the text. The
//! header (path, title line, section, defined symbols and kinds) goes into `embed_text` and the FTS `path` and
//! `symbols` columns, never into `body`.

mod definers;
mod elisp;
mod merge;
mod outline;
mod text;
mod ts;

use crate::files::Lang;

pub use definers::{Definer, definer};
pub use elisp::top_level_forms;

/// The chunk budget, in non-whitespace characters (the eval tunes it).
pub const BUDGET: usize = 1800;

/// Bump it when chunking changes: the content key of every vector changes with it.
pub const CHUNKER_VERSION: u32 = 2;

/// Bump it when what a parse derives besides the chunks changes (a symbol's lines or signature, a new language, the
/// references): tier 1 parses every stored file again, and the chunks keep their content keys, so no vector changes.
pub const PARSE_VERSION: u32 = 1;

/// The text of a chunk's FTS columns. `symbols` is raw: the store encodes it (`encode_symbol`) on write.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FtsCols {
    pub path: String,
    pub symbols: String,
    pub doc: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chunk {
    pub start: u32,
    pub end: u32,
    pub line_start: u32,
    pub line_end: u32,
    /// The first symbol the chunk defines.
    pub symbol: Option<String>,
    /// The header lines (without the body).
    pub header: String,
    pub embed_text: String,
    pub fts: FtsCols,
    pub embed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Symbol {
    pub name: String,
    pub kind: String,
    pub start: u32,
    pub end: u32,
    /// Index into the chunks `chunk_file` returned.
    pub chunk: u32,
    pub definer: String,
    pub doc1: Option<String>,
    /// The lines (from 1) of `start` and of the last byte before `end`.
    pub line_start: u32,
    pub line_end: u32,
    /// The definition's head: its lines up to the one that names it (at most three), cut before a `{` body.
    pub sig: String,
}

/// The longest signature, in characters.
const SIG_MAX: usize = 200;

/// The head of the definition NAME at `text[start..end]`: its lines joined up to the first that holds the name (the
/// first line alone when none of the first three does), cut before an opening brace, at most [`SIG_MAX`] characters.
pub(crate) fn signature(text: &str, start: usize, end: usize, name: &str) -> String {
    let lines: Vec<&str> = text[start..end].lines().take(3).collect();
    let upto = lines.iter().position(|l| l.contains(name)).unwrap_or(0);
    let mut sig = lines[..lines.len().min(upto + 1)]
        .iter()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if let Some(i) = sig.find('{') {
        sig.truncate(i);
    }
    let sig = sig.trim_end();
    match sig.char_indices().nth(SIG_MAX) {
        Some((i, _)) => sig[..i].to_string(),
        None => sig.to_string(),
    }
}

/// Chunks and symbols of one file.
pub fn chunk_file(
    path: &str,
    lang: Lang,
    generated: bool,
    text: &str,
    budget: usize,
) -> (Vec<Chunk>, Vec<Symbol>) {
    let tree_sitter = |kind| ts::chunk(kind, path, generated, text, budget);
    match lang {
        Lang::Elisp => Some(elisp::chunk(path, generated, text, budget)),
        Lang::Rust => tree_sitter(ts::Kind::Rust),
        Lang::C => tree_sitter(ts::Kind::C),
        Lang::Shell => tree_sitter(ts::Kind::Shell),
        Lang::Org => Some(outline::chunk(
            outline::Flavor::Org,
            path,
            generated,
            text,
            budget,
        )),
        Lang::Markdown => Some(outline::chunk(
            outline::Flavor::Markdown,
            path,
            generated,
            text,
            budget,
        )),
        Lang::Text => None,
    }
    .unwrap_or_else(|| text::chunk(path, generated, text, budget))
}

/// The name of the innermost symbol PATH's TEXT defines that holds LINE (from 1), or none: the language from the
/// path (and a `#!` line), the symbols as [`chunk_file`] finds them.
pub fn symbol_at_line(path: &str, text: &str, line: u32) -> Option<String> {
    let (lang, _) = crate::files::classify(path, text.as_bytes());
    let (_, symbols) = chunk_file(path, lang, false, text, BUDGET);
    symbol_at(text, &symbols, line)
}

/// The innermost of SYMBOLS (byte spans of TEXT, as [`chunk_file`] gives them) that holds LINE (from 1): of those whose
/// span reaches into the line, the shortest; none when the line is outside every one.
pub fn symbol_at(text: &str, symbols: &[Symbol], line: u32) -> Option<String> {
    let line = line.max(1) as usize;
    let mut starts = std::iter::once(0).chain(text.match_indices('\n').map(|(i, _)| i + 1));
    let from = starts.nth(line - 1)?;
    let to = text[from..].find('\n').map_or(text.len(), |i| from + i);
    symbols
        .iter()
        .filter(|s| (s.start as usize) <= to && (s.end as usize) > from)
        .min_by_key(|s| s.end - s.start)
        .map(|s| s.name.clone())
}

/// Prefix counts of non-whitespace characters by byte offset.
pub(crate) struct Nws(Vec<u32>);

impl Nws {
    pub(crate) fn new(text: &str) -> Nws {
        let mut v = Vec::with_capacity(text.len() + 1);
        let mut n = 0u32;
        v.push(0);
        for c in text.chars() {
            let before = n;
            if !c.is_whitespace() {
                n += 1;
            }
            // inside a character the count is the one before it
            let len = c.len_utf8();
            for k in 1..=len {
                v.push(if k == len { n } else { before });
            }
        }
        Nws(v)
    }

    pub(crate) fn count(&self, a: usize, b: usize) -> usize {
        (self.0[b] - self.0[a]) as usize
    }
}

/// Line numbers (1-based) by byte offset.
pub(crate) struct Lines(Vec<usize>);

impl Lines {
    pub(crate) fn new(text: &str) -> Lines {
        let mut starts = vec![0];
        starts.extend(text.match_indices('\n').map(|(i, _)| i + 1));
        Lines(starts)
    }

    pub(crate) fn line_of(&self, offset: usize) -> u32 {
        self.0.partition_point(|s| *s <= offset) as u32
    }
}

/// What a chunk's header says.
pub(crate) struct Header<'a> {
    pub path: &'a str,
    pub title: Option<&'a str>,
    pub section: Option<&'a str>,
    /// `(name, kind)` of what the chunk defines.
    pub defs: Vec<(String, String)>,
    /// Docstrings of what it defines (first lines for the header, whole for FTS).
    pub docs: Vec<String>,
    /// `(i, n)` of a part of an oversized form, with the form's signature line.
    pub part: Option<(usize, usize, String)>,
}

impl Header<'_> {
    pub(crate) fn render(&self) -> String {
        let mut h = String::new();
        h.push_str(self.path);
        h.push('\n');
        if let Some(t) = self.title {
            h.push_str(t);
            h.push('\n');
        }
        if let Some(s) = self.section {
            h.push_str("section: ");
            h.push_str(s);
            h.push('\n');
        }
        if !self.defs.is_empty() {
            let list: Vec<String> = self
                .defs
                .iter()
                .map(|(n, k)| format!("{n} ({k})"))
                .collect();
            h.push_str("defines: ");
            h.push_str(&list.join(", "));
            h.push('\n');
        }
        if let Some((i, n, sig)) = &self.part {
            h.push_str(&format!("part {i}/{n}: {sig}\n"));
            if let Some(d) = self.docs.first().and_then(|d| d.lines().next()) {
                h.push_str(d);
                h.push('\n');
            }
        }
        h
    }
}

/// Assemble a chunk over `text[start..end]`. `embed_body` replaces the body in `embed_text` (data-heavy forms).
pub(crate) fn build_chunk(
    text: &str,
    lines: &Lines,
    (start, end): (usize, usize),
    header: &Header,
    embed_body: Option<&str>,
    embed: bool,
) -> Chunk {
    let body = &text[start..end];
    let head = header.render();
    let last = text[start..end].trim_end_matches('\n').len().max(1) + start - 1;
    // chunks are cut where the previous one ended, on its last newline: the chunk's first line is the one its first
    // non-blank character is on
    let first = body.len() - body.trim_start().len();
    let first = if first == body.len() { 0 } else { first };
    Chunk {
        start: start as u32,
        end: end as u32,
        line_start: lines.line_of(start + first),
        line_end: lines.line_of(last.min(text.len().saturating_sub(1))),
        symbol: header.defs.first().map(|(n, _)| n.clone()),
        embed_text: format!("{head}\n{}", embed_body.unwrap_or(body)),
        fts: FtsCols {
            path: header.path.to_string(),
            symbols: header
                .defs
                .iter()
                .map(|(n, _)| n.as_str())
                .collect::<Vec<_>>()
                .join(" "),
            doc: header.docs.join("\n"),
            body: body.to_string(),
        },
        header: head,
        embed,
    }
}
