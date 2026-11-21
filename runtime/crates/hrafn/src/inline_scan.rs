//! The tree walk of inline values (debugger spec §8): which names a stopped line's function shows values for. The
//! debugger parses the frame's file with its grammar and asks [`scan`]; a fetched pack's grammar is not loaded in the hub, so
//! its parse worker runs the same function (`chunk::worker`) and sends back the names.
//!
//! The innermost function holding the stopped row is found (none: the file's top level), and its identifiers are read from its
//! first row to the stopped row, and to the end of the outermost loop around it, whose later rows ran on earlier passes. A
//! called name, a function's own name and a field after a dot are not values.

use serde::{Deserialize, Serialize};
use tree_sitter::{Node, Tree};

/// The node kinds that mean something here, a pack's `:inline`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lists {
    /// Function nodes.
    pub functions: Vec<String>,
    /// Loop nodes.
    pub loops: Vec<String>,
    /// Identifier nodes.
    pub names: Vec<String>,
}

fn has(kinds: &[String], kind: &str) -> bool {
    kinds.iter().any(|k| k == kind)
}

/// Whether N names no value: a call's callee, a macro's name, a function's (or its declarator's) name, a field after a
/// dot.
fn not_a_value(n: Node, lists: &Lists) -> bool {
    let Some(p) = n.parent() else { return false };
    let is = |field: &str| {
        p.child_by_field_name(field)
            .is_some_and(|c| c.id() == n.id())
    };
    let kind = p.kind();
    (kind.contains("call") || kind.contains("invocation")) && (is("function") || is("name"))
        || kind == "macro_invocation" && is("macro")
        || kind == "attribute" && is("attribute")
        || kind == "function_declarator" && is("declarator")
        || has(&lists.functions, kind) && is("name")
}

/// The innermost node of KINDS holding ROW under NODE.
fn innermost<'t>(node: Node<'t>, row: usize, kinds: &[String]) -> Option<Node<'t>> {
    let mut found = None;
    let mut cur = node.walk();
    let mut n = node;
    loop {
        if has(kinds, n.kind()) {
            found = Some(n);
        }
        let next = n
            .children(&mut cur)
            .find(|c| c.start_position().row <= row && row <= c.end_position().row);
        match next {
            Some(c) => n = c,
            None => return found,
        }
    }
}

/// The outermost loop under FUNCTION holding ROW.
fn outer_loop<'t>(function: Node<'t>, row: usize, loops: &[String]) -> Option<Node<'t>> {
    let mut cur = function.walk();
    let mut n = function;
    loop {
        let next = n
            .children(&mut cur)
            .find(|c| c.start_position().row <= row && row <= c.end_position().row)?;
        if has(loops, next.kind()) {
            return Some(next);
        }
        n = next;
    }
}

/// The name nodes under NODE on rows FROM to TO: (row, column, name).
fn names(
    node: Node,
    text: &str,
    from: usize,
    to: usize,
    lists: &Lists,
    out: &mut Vec<(usize, usize, String)>,
) {
    if node.end_position().row < from || node.start_position().row > to {
        return;
    }
    if has(&lists.names, node.kind()) && !not_a_value(node, lists) {
        let p = node.start_position();
        if let Ok(s) = node.utf8_text(text.as_bytes()) {
            out.push((p.row, p.column, s.to_owned()));
        }
        return;
    }
    let mut cur = node.walk();
    for c in node.children(&mut cur) {
        names(c, text, from, to, lists, out);
    }
}

/// The names (row, column, text) a stop at ROW (from 0) of TEXT, parsed as TREE, shows values for.
pub fn scan(tree: &Tree, text: &str, row: usize, lists: &Lists) -> Vec<(usize, usize, String)> {
    let root = tree.root_node();
    let function = innermost(root, row, &lists.functions).unwrap_or(root);
    let from = if function.id() == root.id() {
        0
    } else {
        function.start_position().row
    };
    let to = outer_loop(function, row, &lists.loops).map_or(row, |l| l.end_position().row.max(row));
    let mut found = vec![];
    names(function, text, from, to, lists, &mut found);
    found
}
