//! Rust, C, shell, Python, JavaScript, TypeScript, TSX, Go and Java: top-level items from the tree-sitter grammars,
//! merged and split like Lisp forms.

use super::definers::Def;
use super::merge::{self, Form};
use super::{Chunk, Symbol};
use tree_sitter::Node;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Rust,
    C,
    Shell,
    Python,
    JavaScript,
    TypeScript,
    Tsx,
    Go,
    Java,
}

impl Kind {
    fn language(self) -> tree_sitter::Language {
        match self {
            Kind::Rust => tree_sitter_rust::LANGUAGE.into(),
            Kind::C => tree_sitter_c::LANGUAGE.into(),
            Kind::Shell => tree_sitter_bash::LANGUAGE.into(),
            Kind::Python => tree_sitter_python::LANGUAGE.into(),
            Kind::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            Kind::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Kind::Tsx => tree_sitter_typescript::LANGUAGE_TSX.into(),
            Kind::Go => tree_sitter_go::LANGUAGE.into(),
            Kind::Java => tree_sitter_java::LANGUAGE.into(),
        }
    }

    /// The line-comment marker whose lines directly above a definition are its documentation.
    fn doc_marker(self) -> &'static str {
        match self {
            Kind::Rust => "///",
            Kind::C | Kind::JavaScript | Kind::TypeScript | Kind::Tsx | Kind::Go | Kind::Java => {
                "//"
            }
            Kind::Shell | Kind::Python => "#",
        }
    }

    /// Whether its docs are `/** … */` comments.
    fn block_docs(self) -> bool {
        matches!(
            self,
            Kind::JavaScript | Kind::TypeScript | Kind::Tsx | Kind::Java
        )
    }
}

/// What a Go top-level declaration defines. A declaration of several specs (`var ( … )`) gives each its own span.
fn go_defs(n: Node, text: &str, out: &mut Vec<Def>) {
    let mut add = |name: Node, kind: &'static str, span: Option<Node>| {
        out.push(Def {
            name: text_of(name, text).to_string(),
            kind,
            span: span.map(|s| (s.start_byte(), s.end_byte())),
            doc1: None,
        })
    };
    match n.kind() {
        "function_declaration" | "method_declaration" => {
            if let Some(name) = n.child_by_field_name("name") {
                let kind = if n.kind() == "method_declaration" {
                    "method"
                } else {
                    "function"
                };
                add(name, kind, None);
            }
        }
        "type_declaration" | "const_declaration" | "var_declaration" => {
            // the specs, also inside a `var_spec_list`
            let mut specs = Vec::new();
            let mut stack = vec![n];
            while let Some(m) = stack.pop() {
                let mut cursor = m.walk();
                for c in m.named_children(&mut cursor) {
                    match c.kind() {
                        "type_spec" | "type_alias" | "const_spec" | "var_spec" => specs.push(c),
                        "var_spec_list" | "const_spec_list" => stack.push(c),
                        _ => {}
                    }
                }
            }
            specs.sort_by_key(|s| s.start_byte());
            let own = specs.len() > 1;
            for s in specs {
                let span = own.then_some(s);
                let kind = match s.kind() {
                    "type_spec" => match s.child_by_field_name("type").map(|t| t.kind()) {
                        Some("struct_type") => "struct",
                        Some("interface_type") => "interface",
                        _ => "type",
                    },
                    "type_alias" => "type",
                    "const_spec" => "constant",
                    _ => "variable",
                };
                let mut cursor = s.walk();
                for name in s.children_by_field_name("name", &mut cursor) {
                    add(name, kind, span);
                }
            }
        }
        _ => {}
    }
}

/// What a Java declaration defines; a type's methods, constructors and nested types are members.
fn java_defs(n: Node, text: &str, out: &mut Vec<Def>, depth: usize) {
    let kind = match n.kind() {
        "class_declaration" => "class",
        "interface_declaration" | "annotation_type_declaration" => "interface",
        "enum_declaration" => "enum",
        "record_declaration" => "record",
        "method_declaration" => "method",
        "constructor_declaration" => "constructor",
        _ => return,
    };
    let member = depth > 0;
    if let Some(name) = n.child_by_field_name("name") {
        out.push(Def {
            name: text_of(name, text).to_string(),
            kind,
            span: member.then(|| (n.start_byte(), n.end_byte())),
            doc1: if member {
                block_doc_before(text, n.start_byte()).map(|d| d.0)
            } else {
                None
            },
        });
    }
    if matches!(kind, "class" | "interface" | "enum" | "record")
        && depth < 4
        && let Some(body) = n.child_by_field_name("body")
    {
        let mut cursor = body.walk();
        for child in body.named_children(&mut cursor) {
            if child.kind() == "enum_body_declarations" {
                let mut c2 = child.walk();
                for m in child.named_children(&mut c2) {
                    java_defs(m, text, out, depth + 1);
                }
            } else {
                java_defs(child, text, out, depth + 1);
            }
        }
    }
}

/// The declaration a wrapper holds: `export …`, a decorated Python definition, a TypeScript `namespace` statement.
fn inner(n: Node) -> Node {
    match n.kind() {
        "export_statement" => n
            .child_by_field_name("declaration")
            .or_else(|| n.child_by_field_name("value"))
            .unwrap_or(n),
        "decorated_definition" => n.child_by_field_name("definition").unwrap_or(n),
        "expression_statement" => match n.named_child(0) {
            Some(c)
                if n.named_child_count() == 1
                    && matches!(c.kind(), "internal_module" | "module") =>
            {
                c
            }
            _ => n,
        },
        _ => n,
    }
}

/// A `/** … */` comment directly above `start` (at most one line break between), as `(first line, whole text)`.
fn block_doc_before(text: &str, start: usize) -> Option<(String, String)> {
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

/// A Python definition's docstring: the string its body starts with.
fn py_docstring(d: Node, text: &str) -> Option<(String, String)> {
    let first = d.child_by_field_name("body")?.named_child(0)?;
    let s = first.named_child(0)?;
    if first.kind() != "expression_statement" || s.kind() != "string" {
        return None;
    }
    let raw = text_of(s, text)
        .trim_start_matches(|c: char| c.is_ascii_alphabetic())
        .trim_matches(|c| c == '"' || c == '\'');
    let lines: Vec<&str> = raw.lines().map(str::trim).collect();
    let first = lines.iter().find(|l| !l.is_empty())?.to_string();
    Some((first, lines.join("\n").trim().to_string()))
}

/// What a Python statement defines; a class's methods are members.
fn py_defs(n: Node, text: &str, in_class: bool, out: &mut Vec<Def>, depth: usize) {
    let d = inner(n);
    let kind = match d.kind() {
        "function_definition" if in_class => "method",
        "function_definition" => "function",
        "class_definition" => "class",
        _ => return,
    };
    let member = depth > 0;
    if let Some(name) = d.child_by_field_name("name") {
        out.push(Def {
            name: text_of(name, text).to_string(),
            kind,
            span: member.then(|| (n.start_byte(), n.end_byte())),
            doc1: if member {
                py_docstring(d, text).map(|d| d.0)
            } else {
                None
            },
        });
    }
    if kind == "class"
        && depth < 4
        && let Some(body) = d.child_by_field_name("body")
    {
        let mut cursor = body.walk();
        for child in body.named_children(&mut cursor) {
            py_defs(child, text, true, out, depth + 1);
        }
    }
}

/// A JavaScript or TypeScript function value: what a `const` holding it defines.
fn js_function_value(v: Node) -> bool {
    matches!(
        v.kind(),
        "arrow_function" | "function_expression" | "function" | "generator_function"
    )
}

/// What a JavaScript or TypeScript statement defines; a class's methods and a namespace's declarations are members.
fn js_defs(n: Node, text: &str, out: &mut Vec<Def>, depth: usize) {
    let d = inner(n);
    let member = depth > 0;
    let mut push = |name: Node, kind: &'static str| {
        out.push(Def {
            name: text_of(name, text).to_string(),
            kind,
            span: member.then(|| (n.start_byte(), n.end_byte())),
            doc1: if member {
                block_doc_before(text, n.start_byte()).map(|d| d.0)
            } else {
                None
            },
        })
    };
    let kind = match d.kind() {
        "function_declaration" | "generator_function_declaration" | "function_signature" => {
            "function"
        }
        "class_declaration" | "abstract_class_declaration" | "class" => "class",
        "method_definition" | "abstract_method_signature" | "method_signature" => "method",
        "interface_declaration" => "interface",
        "type_alias_declaration" => "type",
        "enum_declaration" => "enum",
        "internal_module" | "module" => "module",
        "lexical_declaration" | "variable_declaration" => {
            let mut cursor = d.walk();
            for v in d.named_children(&mut cursor) {
                if v.kind() == "variable_declarator"
                    && let Some(name) = v.child_by_field_name("name")
                    && name.kind() == "identifier"
                    && v.child_by_field_name("value")
                        .is_some_and(js_function_value)
                {
                    push(name, "function");
                }
            }
            return;
        }
        _ => return,
    };
    if let Some(name) = d.child_by_field_name("name") {
        push(name, kind);
    }
    if matches!(kind, "class" | "module")
        && depth < 4
        && let Some(body) = d.child_by_field_name("body")
    {
        let mut cursor = body.walk();
        for child in body.named_children(&mut cursor) {
            js_defs(child, text, out, depth + 1);
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
        Kind::Python => {
            let mut defs = Vec::new();
            py_defs(n, text, false, &mut defs, 0);
            form.defs = defs;
        }
        Kind::JavaScript | Kind::TypeScript | Kind::Tsx => {
            let mut defs = Vec::new();
            js_defs(n, text, &mut defs, 0);
            form.defs = defs;
        }
        Kind::Go => go_defs(n, text, &mut form.defs),
        Kind::Java => java_defs(n, text, &mut form.defs, 0),
    }
    if !form.defs.is_empty() {
        form.doc = match kind {
            Kind::Python => py_docstring(inner(n), text),
            k if k.block_docs() => block_doc_before(text, n.start_byte()),
            _ => None,
        }
        .or_else(|| doc_before(text, n.start_byte(), kind.doc_marker()));
    }
    form
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
/// TypeScript, a callback's body when the statement has none).
fn cuts(kind: Kind, n: Node) -> Vec<(usize, usize)> {
    let body = match inner(n).child_by_field_name("body") {
        Some(b) => Some(b),
        None if matches!(kind, Kind::JavaScript | Kind::TypeScript | Kind::Tsx) => callback_body(n),
        None => None,
    };
    let Some(body) = body else {
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
        cuts: &|f| node_at(f.start).map(|n| cuts(kind, n)).unwrap_or_default(),
    }))
}
