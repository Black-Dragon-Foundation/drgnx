//! Rust, C, shell, Python, JavaScript, TypeScript, TSX, Go, Java and C#: top-level items from the tree-sitter grammars,
//! merged and split like Lisp forms.

use super::engine::Spec;
use super::merge::{self, Form};
use super::refs::{self, Ref};
use super::{Chunk, Nws, Symbol};
use tree_sitter::Node;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Rust,
    C,
    Cpp,
    Shell,
    Python,
    JavaScript,
    TypeScript,
    Tsx,
    Go,
    Java,
    Csharp,
}

impl Kind {
    pub(super) const ALL: [Kind; 11] = [
        Kind::Rust,
        Kind::C,
        Kind::Cpp,
        Kind::Shell,
        Kind::Python,
        Kind::JavaScript,
        Kind::TypeScript,
        Kind::Tsx,
        Kind::Go,
        Kind::Java,
        Kind::Csharp,
    ];
}

/// A `/** … */` comment directly above `start` (at most one line break between), as `(first line, whole text)`.
pub(super) fn block_doc_before(text: &str, start: usize) -> Option<(String, String)> {
    let before = &text[..start];
    let t = before.trim_end();
    if !t.ends_with("*/") || before[t.len()..].matches('\n').count() > 1 {
        return None;
    }
    let open = t.rfind("/**")?;
    let body = t.get(open + 3..t.len() - 2)?;
    let lines: Vec<&str> = body
        .lines()
        .map(|l| l.trim().trim_start_matches('*').trim())
        .collect();
    let first = lines.iter().find(|l| !l.is_empty())?.to_string();
    Some((first, lines.join("\n").trim().to_string()))
}

/// A docstring's `(first line, whole text)`: the string node's text without its prefix and quotes.
pub(super) fn py_docstring_of(s: Node, text: &str) -> Option<(String, String)> {
    let raw = text_of(s, text)
        .trim_start_matches(|c: char| c.is_ascii_alphabetic())
        .trim_matches(|c| c == '"' || c == '\'');
    let lines: Vec<&str> = raw.lines().map(str::trim).collect();
    let first = lines.iter().find(|l| !l.is_empty())?.to_string();
    Some((first, lines.join("\n").trim().to_string()))
}

pub(super) fn text_of<'a>(n: Node, text: &'a str) -> &'a str {
    &text[n.start_byte()..n.end_byte()]
}

/// The comment lines directly above `start`, as `(first line, whole text)`.
pub(super) fn doc_before(text: &str, start: usize, marker: &str) -> Option<(String, String)> {
    let mut lines: Vec<&str> = Vec::new();
    let mut end = text[..start].rfind('\n')?; // the end of the line above the item's line
    loop {
        let ls = text[..end].rfind('\n').map_or(0, |i| i + 1);
        let line = text[ls..end].trim();
        if !line.starts_with(marker) || line.starts_with("#!") {
            break;
        }
        let body = line.trim_start_matches(marker);
        // `///` and `//!` are doc comments of the `//` languages (C, C++, Go, Java, JavaScript, Rust's own marker is `///`)
        let body = if marker == "//" {
            body.strip_prefix(['/', '!']).unwrap_or(body)
        } else {
            body
        };
        lines.push(body.trim());
        if ls == 0 {
            break;
        }
        end = ls - 1;
    }
    lines.reverse();
    let full = lines.join("\n");
    let first = lines.iter().find(|l| !l.is_empty())?.to_string();
    Some((first, full))
}

/// The name a C or C++ declarator ends in: an identifier, a destructor's `~Name`, an `operator+`, the last part of a
/// `Class::member`. A reference declarator (`T& f()`) has no `declarator` field: its first named child is the next.
pub(super) fn c_declarator_name<'a>(n: Node<'a>, text: &'a str) -> Option<&'a str> {
    let next = |n: Node<'a>| {
        n.child_by_field_name("declarator")
            .or_else(|| n.named_child(0))
    };
    let mut n = next(n)?;
    loop {
        match n.kind() {
            "identifier" | "field_identifier" | "type_identifier" | "destructor_name"
            | "operator_name" => return Some(text_of(n, text)),
            "qualified_identifier" | "template_function" => n = n.child_by_field_name("name")?,
            _ => n = next(n)?,
        }
    }
}

/// The body of a JavaScript or TypeScript statement that has none of its own: the last callback's in the call it holds
/// (`describe("…", function () { … })`), looked for a few levels down.
fn callback_body(n: Node) -> Option<Node> {
    let mut level = vec![n];
    for _ in 0..5 {
        let mut next = Vec::new();
        for m in level {
            let mut cursor = m.walk();
            next.extend(m.named_children(&mut cursor));
        }
        let found = next.iter().rev().find_map(|c| {
            matches!(
                c.kind(),
                "arrow_function" | "function_expression" | "function"
            )
            .then(|| c.child_by_field_name("body"))
            .flatten()
            .filter(|b| b.kind() == "statement_block")
        });
        if found.is_some() {
            return found;
        }
        level = next;
    }
    None
}

/// An oversized item is cut before the members of its body (a wrapper's declaration's body; in JavaScript and
/// TypeScript, a callback's body when the statement has none), and inside a member that is over the budget itself, or
/// that does not begin a line (Go's `statement_list`, a `{` on the header's line), before the forms nested in it.
fn cuts(
    kind: Kind,
    spec: &Spec,
    root: Node,
    n: Node,
    text: &str,
    nws: &Nws,
    budget: usize,
) -> Vec<(usize, usize)> {
    let body = match spec.inner(root, n, text).child_by_field_name("body") {
        Some(b) => Some(b),
        None if matches!(kind, Kind::JavaScript | Kind::TypeScript | Kind::Tsx) => callback_body(n),
        None => None,
    };
    let mut out = Vec::new();
    if let Some(body) = body {
        nested_cuts(body, text, nws, budget, &mut out);
    }
    out
}

/// The cut points inside N: each child that begins a line and fits the budget, the cut points inside the others.
fn nested_cuts(n: Node, text: &str, nws: &Nws, budget: usize, out: &mut Vec<(usize, usize)>) {
    let mut cursor = n.walk();
    for c in n
        .named_children(&mut cursor)
        .filter(|c| !c.kind().contains("comment"))
    {
        let (s, e) = (c.start_byte(), c.end_byte());
        let begins_line = text[..s]
            .rfind('\n')
            .map_or(&text[..s], |nl| &text[nl + 1..s])
            .trim()
            .is_empty();
        if begins_line && (nws.count(s, e) <= budget || c.named_child_count() == 0) {
            out.push((s, e));
        } else {
            nested_cuts(c, text, nws, budget, out);
        }
    }
}

pub(super) fn chunk(
    kind: Kind,
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> Option<(Vec<Chunk>, Vec<Symbol>, Vec<Ref>)> {
    let spec = super::registry::spec(kind)?;
    let mut parser = tree_sitter::Parser::new();
    parser
        .set_language(&super::registry::language(kind)?)
        .ok()?;
    let tree = parser.parse(text, None)?;
    let root = tree.root_node();
    let mut cursor = root.walk();
    let nodes: Vec<Node> = root
        .children(&mut cursor)
        .filter(|n| !n.kind().contains("comment"))
        .collect();
    let nws = Nws::new(text);
    let node_at = |start: usize| {
        nodes
            .binary_search_by_key(&start, |n| n.start_byte())
            .ok()
            .map(|i| nodes[i])
    };
    let (chunks, symbols) = merge::assemble(merge::Input {
        path,
        generated,
        text,
        budget,
        title: None,
        spans: nodes
            .iter()
            .map(|n| (n.start_byte(), n.end_byte()))
            .collect(),
        analyse: &|s, e| match node_at(s) {
            Some(n) => analyse(spec, root, n, text),
            None => Form::plain(s, e),
        },
        heading: &|_, _| None,
        cuts: &|f| {
            node_at(f.start)
                .map(|n| cuts(kind, spec, root, n, text, &nws, budget))
                .unwrap_or_default()
        },
    });
    Some((chunks, symbols, refs::of_tree(kind, &tree, text)))
}

/// What the engine finds in the top-level node N of the tree rooted at ROOT (the pack's `chunks.scm`).
fn analyse(spec: &Spec, root: Node, n: Node, text: &str) -> Form {
    let mut form = Form::plain(n.start_byte(), n.end_byte());
    form.head = n.kind().to_string();
    let (defs, doc) = spec.analyse(root, n, text);
    form.defs = defs;
    form.doc = doc;
    form
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The grammar a kind asks the registry for is the first one its pack owns: the pack is the one place the name lives.
    #[test]
    fn a_kinds_grammar_is_its_packs() {
        for k in Kind::ALL {
            let m =
                skald::builtin::get(super::super::registry::pack_name(k)).expect("a built-in pack");
            let first = m
                .grammars
                .iter()
                .find(|g| g.repo.is_some())
                .expect("it owns one");
            assert_eq!(first.name, super::super::registry::grammar_name(k));
        }
    }

    #[test]
    fn every_pack_queries_compile_against_its_grammar() {
        for (kind, r) in super::super::registry::build_all() {
            assert!(
                r.is_ok(),
                "{}: {:?}",
                Kind::ALL.iter().position(|k| *k == kind).unwrap(),
                r
            );
        }
    }
}
