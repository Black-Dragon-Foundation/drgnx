//! Structural search: a code pattern with metavariables (ast-grep's syntax: `$NAME` one node, `$$$NAME` any number,
//! `$_` one node unnamed; the same name twice matches the same text) found in a file's syntax tree, and a rewrite
//! template that uses the same names. The engine is `ast-grep-core`, fed Hrafn's own grammars; it stays behind this
//! module, so a bump or a swap touches nothing else.

use crate::files::Lang;
use ast_grep_core::matcher::PatternBuilder;
use ast_grep_core::matcher::PatternNode;
use ast_grep_core::meta_var::MetaVariable;
use ast_grep_core::replacer::{Replacer, TemplateFix};
use ast_grep_core::tree_sitter::{LanguageExt, StrDoc, TSLanguage};
use ast_grep_core::{AstGrep, Language, PatternError as AgError};
use std::borrow::Cow;
use std::collections::BTreeMap;

/// One of Hrafn's grammars as ast-grep's language: its tree-sitter language and the character a metavariable's `$`
/// becomes before the pattern is parsed (`µ` where `$` cannot start a name).
#[derive(Clone)]
pub struct Grammar {
    lang: Lang,
    ts: TSLanguage,
    expando: char,
}

impl Grammar {
    /// LANG's grammar; none for Org, Markdown and text.
    pub fn of(lang: Lang) -> Option<Grammar> {
        let (ts, expando): (TSLanguage, char) = match lang {
            Lang::Elisp => (tree_sitter_elisp::LANGUAGE.into(), '$'),
            Lang::Rust => (tree_sitter_rust::LANGUAGE.into(), 'µ'),
            Lang::C => (tree_sitter_c::LANGUAGE.into(), 'µ'),
            Lang::Shell => (tree_sitter_bash::LANGUAGE.into(), 'µ'),
            Lang::Python => (tree_sitter_python::LANGUAGE.into(), 'µ'),
            Lang::JavaScript => (tree_sitter_javascript::LANGUAGE.into(), '$'),
            Lang::TypeScript => (tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(), '$'),
            Lang::Tsx => (tree_sitter_typescript::LANGUAGE_TSX.into(), '$'),
            Lang::Go => (tree_sitter_go::LANGUAGE.into(), 'µ'),
            Lang::Java => (tree_sitter_java::LANGUAGE.into(), '$'),
            Lang::Org | Lang::Markdown | Lang::Text => return None,
        };
        Some(Grammar { lang, ts, expando })
    }
}

impl Language for Grammar {
    /// A metavariable's `$` (`$A`, `$$$A`, `$_`) as the expando character, one for one, so columns stay the user's.
    fn pre_process_pattern<'q>(&self, query: &'q str) -> Cow<'q, str> {
        if self.expando == '$' {
            return Cow::Borrowed(query);
        }
        let mut out = String::with_capacity(query.len());
        let mut dollars = 0;
        for c in query.chars() {
            if c == '$' {
                dollars += 1;
                continue;
            }
            let sigil = if c.is_ascii_uppercase() || c == '_' {
                self.expando
            } else {
                '$'
            };
            out.extend(std::iter::repeat_n(sigil, dollars));
            dollars = 0;
            out.push(c);
        }
        out.extend(std::iter::repeat_n('$', dollars));
        Cow::Owned(out)
    }
    fn expando_char(&self) -> char {
        self.expando
    }
    fn kind_to_id(&self, kind: &str) -> u16 {
        self.ts.id_for_node_kind(kind, true)
    }
    fn field_to_id(&self, field: &str) -> Option<u16> {
        self.ts.field_id_for_name(field).map(|f| f.get())
    }
    fn build_pattern(&self, builder: &PatternBuilder) -> Result<ast_grep_core::Pattern, AgError> {
        builder.build(|src| StrDoc::try_new(src, self.clone()))
    }
}

impl LanguageExt for Grammar {
    fn get_ts_language(&self) -> TSLanguage {
        self.ts.clone()
    }
}

/// Why a pattern is refused: its language has no grammar, or it does not parse in it (COL, from 0 in characters, where
/// the first error is; none when nothing parsed at all).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PatternError {
    pub lang: Lang,
    pub col: Option<usize>,
    no_grammar: bool,
}

impl std::fmt::Display for PatternError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.no_grammar {
            return write!(f, "no grammar for {} files", self.lang.as_str());
        }
        write!(f, "pattern is not valid {}", lang_name(self.lang))?;
        match self.col {
            Some(c) => write!(f, " at col {c}"),
            None => Ok(()),
        }
    }
}

impl std::error::Error for PatternError {}

/// LANG as people write it.
pub fn lang_name(lang: Lang) -> &'static str {
    match lang {
        Lang::Elisp => "Emacs Lisp",
        Lang::Rust => "Rust",
        Lang::C => "C",
        Lang::Shell => "shell",
        Lang::Python => "Python",
        Lang::JavaScript => "JavaScript",
        Lang::TypeScript => "TypeScript",
        Lang::Tsx => "TSX",
        Lang::Go => "Go",
        Lang::Java => "Java",
        Lang::Org => "Org",
        Lang::Markdown => "Markdown",
        Lang::Text => "text",
    }
}

/// Why a file is not searched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Skip {
    /// Its bytes are not UTF-8 (the grammars read text).
    NotUtf8,
    /// The parser gave no tree.
    NoTree,
}

impl Skip {
    pub fn reason(&self) -> &'static str {
        match self {
            Skip::NotUtf8 => "not UTF-8",
            Skip::NoTree => "the parser gave no tree",
        }
    }
}

/// One match: bytes `[start, end)` of the file; LINE and END_LINE from 1, COL and END_COL characters of their lines
/// from 0; each named metavariable's text; and the template's expansion when the pattern has one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    pub start: usize,
    pub end: usize,
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
    pub captures: BTreeMap<String, String>,
    pub replacement: Option<String>,
}

/// A pattern parsed in one language, with its rewrite template.
pub struct Pattern {
    grammar: Grammar,
    pattern: ast_grep_core::Pattern,
    rewrite: Option<TemplateFix>,
    literals: Vec<String>,
}

impl Pattern {
    /// PATTERN parsed as LANG, with the template REWRITE.
    pub fn new(lang: Lang, pattern: &str, rewrite: Option<&str>) -> Result<Pattern, PatternError> {
        let refused = |col| PatternError {
            lang,
            col,
            no_grammar: false,
        };
        let Some(grammar) = Grammar::of(lang) else {
            return Err(PatternError {
                lang,
                col: None,
                no_grammar: true,
            });
        };
        let processed = grammar.pre_process_pattern(pattern).into_owned();
        if let Some(col) = first_error(&grammar, &processed) {
            return Err(refused(Some(col)));
        }
        let compiled =
            ast_grep_core::Pattern::try_new(pattern, grammar.clone()).map_err(|_| refused(None))?;
        let rewrite = rewrite.map(|r| match TemplateFix::try_new(r, &grammar) {
            Ok(t) => t,
            Err(e) => match e {},
        });
        let mut literals = Vec::new();
        names(&grammar, &compiled.node, &mut literals);
        Ok(Pattern {
            grammar,
            pattern: compiled,
            rewrite,
            literals,
        })
    }

    pub fn lang(&self) -> Lang {
        self.grammar.lang
    }

    /// The pattern's names that are not metavariables (identifiers and symbols, not keywords, strings or punctuation),
    /// each once, in order: a file that matches holds every one as written, so a search reads only files holding them
    /// (none: every file of the language is read).
    pub fn literals(&self) -> &[String] {
        &self.literals
    }

    /// The matches in TEXT, in order, outermost only (a match inside another is not reported).
    pub fn find(&self, text: &[u8]) -> Result<Vec<Match>, Skip> {
        let text = std::str::from_utf8(text).map_err(|_| Skip::NotUtf8)?;
        let doc = StrDoc::try_new(text, self.grammar.clone()).map_err(|_| Skip::NoTree)?;
        let root = AstGrep::doc(doc);
        let lines = LineStarts::new(text);
        let mut out = Vec::new();
        let mut last_end = 0;
        for nm in root.root().find_all(&self.pattern) {
            let r = nm.range();
            if r.start < last_end {
                continue;
            }
            last_end = r.end;
            let env = nm.get_env();
            let captures = env
                .get_matched_variables()
                .filter_map(|v| match v {
                    MetaVariable::Capture(name, _) => {
                        env.get_match(&name).map(|n| (name, n.text().into_owned()))
                    }
                    MetaVariable::MultiCapture(name) => {
                        let ns = env.get_multiple_matches(&name);
                        let text = match (ns.first(), ns.last()) {
                            (Some(a), Some(b)) => text[a.range().start..b.range().end].to_owned(),
                            _ => String::new(),
                        };
                        Some((name, text))
                    }
                    _ => None,
                })
                .collect();
            let replacement = self
                .rewrite
                .as_ref()
                .map(|t| String::from_utf8_lossy(&t.generate_replacement(&nm)).into_owned());
            let (line, col) = lines.at(text, r.start);
            let (end_line, end_col) = lines.at(text, r.end);
            out.push(Match {
                start: r.start,
                end: r.end,
                line,
                col,
                end_line,
                end_col,
                captures,
                replacement,
            });
        }
        Ok(out)
    }
}

/// The column (characters from 0) of the first error in SRC parsed by G; none when it parses. As ast-grep reads a
/// pattern, the chain of single children from the root (an error node wrapping one whole node, as an expression at a
/// Rust file's top level is, and a missing `;` after it) is not an error: only one inside the node the pattern is.
fn first_error(g: &Grammar, src: &str) -> Option<usize> {
    if src.trim().is_empty() {
        return None; // nothing to point at: the pattern is refused as empty
    }
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&g.ts).ok()?;
    let at = error_at(&mut parser, src)?;
    let line_start = src[..at].rfind('\n').map_or(0, |i| i + 1);
    Some(src[line_start..at].chars().count())
}

/// Where SRC's first error starts, past the chain of single children from the root ([`first_error`]); none when it
/// parses.
fn error_at(parser: &mut tree_sitter::Parser, src: &str) -> Option<usize> {
    let tree = parser.parse(src, None)?;
    let mut n = tree.root_node();
    loop {
        let single = match n.child_count() {
            1 => true,
            2 => n
                .child(1)
                .is_some_and(|c| c.is_missing() || c.kind().is_empty()),
            _ => false,
        };
        match n.child(0) {
            Some(c) if single => n = c,
            _ => break,
        }
    }
    error_in(n)
}

/// Where the first error node in N's tree starts (N's own, else its children's in order).
fn error_in(n: tree_sitter::Node) -> Option<usize> {
    if n.is_error() {
        return Some(n.start_byte());
    }
    if !n.has_error() {
        return None;
    }
    let mut cursor = n.walk();
    n.children(&mut cursor).find_map(error_in)
}

/// The names under N (a pattern's tree) that are not metavariables, each once, into OUT.
fn names(g: &Grammar, n: &PatternNode, out: &mut Vec<String>) {
    match n {
        PatternNode::Terminal {
            text,
            is_named,
            kind_id,
        } => {
            let kind = g.ts.node_kind_for_id(*kind_id).unwrap_or("");
            if *is_named && is_name_kind(kind) && !text.is_empty() && !out.contains(text) {
                out.push(text.clone());
            }
        }
        PatternNode::Internal { children, .. } => {
            for c in children {
                names(g, c, out);
            }
        }
        PatternNode::MetaVar { .. } => {}
    }
}

/// Whether a leaf of KIND is a name whose source text is the text a match holds (an identifier, a field or type name,
/// a Lisp symbol), not a literal written several ways (strings, numbers, characters).
fn is_name_kind(kind: &str) -> bool {
    kind == "symbol" || kind.ends_with("identifier") || kind == "variable_name" || kind == "word"
}

/// Where each line of a text starts, for byte offsets as line and character column.
struct LineStarts(Vec<usize>);

impl LineStarts {
    fn new(text: &str) -> LineStarts {
        LineStarts(
            std::iter::once(0)
                .chain(text.match_indices('\n').map(|(i, _)| i + 1))
                .collect(),
        )
    }

    /// Byte AT of TEXT as (line from 1, characters from 0).
    fn at(&self, text: &str, at: usize) -> (u32, u32) {
        let i = self.0.partition_point(|s| *s <= at) - 1;
        let col = text[self.0[i]..at].chars().count();
        (i as u32 + 1, col as u32)
    }
}
