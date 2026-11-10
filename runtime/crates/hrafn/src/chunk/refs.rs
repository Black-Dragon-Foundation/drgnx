//! References: the names a file uses, from the tree the chunker already parsed (no second parse).
//!
//! - **tree-sitter languages** run a tags query and keep the matches with a `@reference.*` capture, whose `@name` is
//!   the name: the grammar crate's own `TAGS_QUERY` for Rust, Python, JavaScript, Go and Java; TypeScript's (types,
//!   `new`) with the calls added; small ones of our own for C (calls; its query has definitions only) and shell
//!   (commands; bash ships none).
//! - **Emacs Lisp** takes the symbol atoms of each top-level form, minus the name the form defines, keywords, `&`
//!   markers, `t`, `nil` and the special forms and core macros ([`LISP_SKIP`]).
//! - Org, Markdown and text have none. A name shorter than 2 characters is dropped.

use super::definers;
use super::ts::Kind;
use std::collections::BTreeMap;
use std::sync::OnceLock;
use tree_sitter::{Node, Query, QueryCursor, StreamingIterator, Tree};

/// How many first lines a reference keeps.
pub const LINES: usize = 8;

/// One name a file uses: how often, and the first [`LINES`] lines (from 1) it is used on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ref {
    pub name: String,
    pub n: u32,
    pub lines: Vec<u32>,
}

/// C: calls (the crate's tags query has definitions only).
const C_REFS: &str = "(call_expression function: (identifier) @name) @reference.call";
/// TypeScript and TSX: calls, added to the crate's query (types and `new`), as JavaScript's query has them.
const TS_CALLS: &str = "
(call_expression function: (identifier) @name) @reference.call
(call_expression function: (member_expression property: (property_identifier) @name)) @reference.call
";
/// Shell: the commands run (bash ships no tags query).
const SH_REFS: &str = "(command name: (command_name (word) @name)) @reference.call";

/// Special forms and core macros, which a Lisp form uses but no project defines.
const LISP_SKIP: &[&str] = &[
    "and",
    "catch",
    "cond",
    "condition-case",
    "dolist",
    "dotimes",
    "function",
    "if",
    "interactive",
    "lambda",
    "let",
    "let*",
    "or",
    "pcase",
    "prog1",
    "prog2",
    "progn",
    "quote",
    "save-current-buffer",
    "save-excursion",
    "save-restriction",
    "setq",
    "setq-default",
    "unless",
    "unwind-protect",
    "when",
    "while",
];

/// KIND's reference query, compiled once; none when it does not compile against the grammar (a test pins that each
/// one does).
fn query(kind: Kind) -> Option<&'static Query> {
    static QUERIES: OnceLock<Vec<Option<Query>>> = OnceLock::new();
    let all = QUERIES.get_or_init(|| {
        Kind::ALL
            .iter()
            .map(|k| {
                let src = match k {
                    Kind::Rust => tree_sitter_rust::TAGS_QUERY.to_string(),
                    Kind::C => C_REFS.to_string(),
                    Kind::Shell => SH_REFS.to_string(),
                    Kind::Python => tree_sitter_python::TAGS_QUERY.to_string(),
                    Kind::JavaScript => tree_sitter_javascript::TAGS_QUERY.to_string(),
                    Kind::TypeScript | Kind::Tsx => {
                        format!("{}\n{TS_CALLS}", tree_sitter_typescript::TAGS_QUERY)
                    }
                    Kind::Go => tree_sitter_go::TAGS_QUERY.to_string(),
                    Kind::Java => tree_sitter_java::TAGS_QUERY.to_string(),
                };
                Query::new(&k.language(), &src).ok()
            })
            .collect()
    });
    all[Kind::ALL.iter().position(|k| *k == kind)?].as_ref()
}

/// Names and their lines, counted.
#[derive(Default)]
struct Tally(BTreeMap<String, (u32, Vec<u32>)>);

impl Tally {
    fn add(&mut self, name: &str, line: u32) {
        if name.chars().count() < 2 {
            return;
        }
        let (n, lines) = self.0.entry(name.to_string()).or_default();
        *n += 1;
        if lines.len() < LINES && !lines.contains(&line) {
            lines.push(line);
        }
    }

    fn done(self) -> Vec<Ref> {
        self.0
            .into_iter()
            .map(|(name, (n, lines))| Ref { name, n, lines })
            .collect()
    }
}

fn line_of(n: Node) -> u32 {
    n.start_position().row as u32 + 1
}

/// The references of TREE, a KIND file's parse of TEXT.
pub(super) fn of_tree(kind: Kind, tree: &Tree, text: &str) -> Vec<Ref> {
    let Some(q) = query(kind) else {
        return Vec::new();
    };
    let Some(name_ix) = q.capture_index_for_name("name") else {
        return Vec::new();
    };
    let is_ref: Vec<bool> = q
        .capture_names()
        .iter()
        .map(|c| c.starts_with("reference"))
        .collect();
    let mut tally = Tally::default();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(q, tree.root_node(), text.as_bytes());
    while let Some(m) = matches.next() {
        if !m.captures.iter().any(|c| is_ref[c.index as usize]) {
            continue;
        }
        for c in m.captures.iter().filter(|c| c.index == name_ix) {
            if let Ok(name) = c.node.utf8_text(text.as_bytes()) {
                tally.add(name, line_of(c.node));
            }
        }
    }
    tally.done()
}

/// The references of an Emacs Lisp file: TREE is its parse of TEXT.
pub(super) fn of_lisp(tree: &Tree, text: &str) -> Vec<Ref> {
    let mut tally = Tally::default();
    let root = tree.root_node();
    let mut forms = root.walk();
    for form in root.children(&mut forms) {
        let head = definers::atoms(text, form.start_byte(), form.end_byte(), 2);
        let own = match head.as_slice() {
            [h, name, ..] if definers::definer(&text[h.start..h.end]).is_some() => {
                Some(&text[name.start..name.end])
            }
            _ => None,
        };
        let mut stack = vec![form];
        while let Some(n) = stack.pop() {
            if n.kind() == "symbol" {
                let s = &text[n.start_byte()..n.end_byte()];
                let skip = s.starts_with(':')
                    || s.starts_with('&')
                    || matches!(s, "t" | "nil")
                    || Some(s) == own
                    || LISP_SKIP.contains(&s)
                    || definers::definer(s).is_some();
                if !skip {
                    tally.add(s, line_of(n));
                }
                continue;
            }
            let mut c = n.walk();
            // reversed, so the stack hands them out in source order
            let kids: Vec<Node> = n.named_children(&mut c).collect();
            stack.extend(kids.into_iter().rev());
        }
    }
    tally.done()
}
