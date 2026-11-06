//! Rust, C and shell: top-level items from the tree-sitter grammars, merged and split like Lisp forms.

use super::definers::Def;
use super::merge::{self, Form};
use super::{Chunk, Symbol};
use tree_sitter::Node;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Rust,
    C,
    Shell,
}

impl Kind {
    fn language(self) -> tree_sitter::Language {
        match self {
            Kind::Rust => tree_sitter_rust::LANGUAGE.into(),
            Kind::C => tree_sitter_c::LANGUAGE.into(),
            Kind::Shell => tree_sitter_bash::LANGUAGE.into(),
        }
    }

    /// The line-comment marker whose lines directly above a definition are its documentation.
    fn doc_marker(self) -> &'static str {
        match self {
            Kind::Rust => "///",
            Kind::C => "//",
            Kind::Shell => "#",
        }
    }
}

fn text_of<'a>(n: Node, text: &'a str) -> &'a str {
    &text[n.start_byte()..n.end_byte()]
}

/// The comment lines directly above `start`, as `(first line, whole text)`.
fn doc_before(text: &str, start: usize, marker: &str) -> Option<(String, String)> {
    let mut lines: Vec<&str> = Vec::new();
    let mut end = text[..start].rfind('\n')?; // the end of the line above the item's line
    loop {
        let ls = text[..end].rfind('\n').map_or(0, |i| i + 1);
        let line = text[ls..end].trim();
        if !line.starts_with(marker) || line.starts_with("#!") {
            break;
        }
        lines.push(line.trim_start_matches(marker).trim());
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

/// The name a C declarator ends in.
fn c_declarator_name<'a>(n: Node, text: &'a str) -> Option<&'a str> {
    let mut n = n.child_by_field_name("declarator")?;
    loop {
        if matches!(
            n.kind(),
            "identifier" | "field_identifier" | "type_identifier"
        ) {
            return Some(text_of(n, text));
        }
        n = n.child_by_field_name("declarator")?;
    }
}

fn rust_kind(k: &str) -> Option<&'static str> {
    Some(match k {
        "function_item" | "function_signature_item" => "function",
        "struct_item" => "struct",
        "enum_item" => "enum",
        "union_item" => "union",
        "trait_item" => "trait",
        "mod_item" => "module",
        "macro_definition" => "macro",
        "type_item" => "type",
        "const_item" => "constant",
        "static_item" => "static",
        "impl_item" => "impl",
        _ => return None,
    })
}

/// What a Rust item defines, and (inside an `impl`, a trait or a module) what its members do.
fn rust_defs(n: Node, text: &str, container: Option<&str>, out: &mut Vec<Def>, depth: usize) {
    let Some(mut kind) = rust_kind(n.kind()) else {
        return;
    };
    let name = if n.kind() == "impl_item" {
        n.child_by_field_name("type")
    } else {
        n.child_by_field_name("name")
    };
    if let Some(name) = name {
        if kind == "function" && matches!(container, Some("impl_item" | "trait_item")) {
            kind = "method";
        }
        let doc1 = doc_before(text, n.start_byte(), "///").map(|d| d.0);
        out.push(Def {
            name: text_of(name, text).to_string(),
            kind,
            span: container.map(|_| (n.start_byte(), n.end_byte())),
            doc1,
        });
    }
    if matches!(n.kind(), "impl_item" | "trait_item" | "mod_item")
        && depth < 4
        && let Some(body) = n.child_by_field_name("body")
    {
        let mut cursor = body.walk();
        for child in body.named_children(&mut cursor) {
            rust_defs(child, text, Some(n.kind()), out, depth + 1);
        }
    }
}

fn analyse(kind: Kind, n: Node, text: &str) -> Form {
    let mut form = Form::plain(n.start_byte(), n.end_byte());
    form.head = n.kind().to_string();
    let mut mk = |name: &str, k: &'static str| {
        form.defs.push(Def {
            name: name.to_string(),
            kind: k,
            span: None,
            doc1: None,
        })
    };
    match kind {
        Kind::Rust => {
            let mut defs = Vec::new();
            rust_defs(n, text, None, &mut defs, 0);
            form.defs = defs;
        }
        Kind::C => match n.kind() {
            "function_definition" => {
                if let Some(name) = c_declarator_name(n, text) {
                    mk(name, "function");
                }
            }
            "preproc_def" | "preproc_function_def" => {
                if let Some(name) = n.child_by_field_name("name") {
                    mk(text_of(name, text), "macro");
                }
            }
            "struct_specifier" | "union_specifier" | "enum_specifier" | "declaration"
            | "type_definition" => {
                let mut cursor = n.walk();
                let spec = if n.kind().ends_with("_specifier") {
                    Some(n)
                } else {
                    n.named_children(&mut cursor)
                        .find(|c| c.kind().ends_with("_specifier"))
                };
                if let Some(s) = spec
                    && s.child_by_field_name("body").is_some()
                    && let Some(name) = s.child_by_field_name("name")
                {
                    let k = match s.kind() {
                        "union_specifier" => "union",
                        "enum_specifier" => "enum",
                        _ => "struct",
                    };
                    mk(text_of(name, text), k);
                }
                if n.kind() == "type_definition"
                    && let Some(d) = n.child_by_field_name("declarator")
                {
                    mk(text_of(d, text), "type");
                }
            }
            _ => {}
        },
        Kind::Shell => {
            if n.kind() == "function_definition"
                && let Some(name) = n.child_by_field_name("name")
            {
                mk(text_of(name, text), "function");
            }
        }
    }
    if !form.defs.is_empty() {
        form.doc = doc_before(text, n.start_byte(), kind.doc_marker());
    }
    form
}

/// An oversized item is cut before the members of its body.
fn cuts(n: Node) -> Vec<(usize, usize)> {
    let Some(body) = n.child_by_field_name("body") else {
        return Vec::new();
    };
    let mut cursor = body.walk();
    body.named_children(&mut cursor)
        .filter(|c| !c.kind().contains("comment"))
        .map(|c| (c.start_byte(), c.end_byte()))
        .collect()
}

pub(super) fn chunk(
    kind: Kind,
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> Option<(Vec<Chunk>, Vec<Symbol>)> {
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&kind.language()).ok()?;
    let tree = parser.parse(text, None)?;
    let root = tree.root_node();
    let mut cursor = root.walk();
    let nodes: Vec<Node> = root
        .children(&mut cursor)
        .filter(|n| !n.kind().contains("comment"))
        .collect();
    let node_at = |start: usize| {
        nodes
            .binary_search_by_key(&start, |n| n.start_byte())
            .ok()
            .map(|i| nodes[i])
    };
    Some(merge::assemble(merge::Input {
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
            Some(n) => analyse(kind, n, text),
            None => Form::plain(s, e),
        },
        heading: &|_, _| None,
        cuts: &|f| node_at(f.start).map(cuts).unwrap_or_default(),
    }))
}
