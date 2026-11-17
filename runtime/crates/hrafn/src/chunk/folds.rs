//! Fold ranges of a file (minimap and folding design §7.4, the hub's source): the pack's `queries/folds.scm`, or, for
//! a pack without one, its `tags.scm` definitions. A capture `@fold` is a block, `@fold.KIND` one of [`KINDS`]; in a
//! `tags.scm`, `@definition.function` (method, macro, constructor) is a function, a class, struct, interface, module,
//! enum, union, trait, impl, namespace or type a class, any other definition a block. A node folds from its first line
//! to its last (a node ending at a line's start ends on the line before); a node within one line is no range, and of
//! the nodes starting on one line the largest stays, on a tie the more specific kind (the higher number): the rule of
//! Nidhogg's line model for the editor's own parser, so both sources give one file the same ranges.

use super::ts::Kind;
use super::{registry, worker};
use crate::Lang;
use serde::{Deserialize, Serialize};
use std::sync::{Mutex, PoisonError};
use tree_sitter::{CaptureQuantifier, Query, QueryCursor, StreamingIterator, Tree};

/// The fold kinds, at their numbers in the line model (`@fold` is `block`).
pub const KINDS: [&str; 9] = [
    "block", "function", "class", "comment", "import", "test", "region", "cell", "heading",
];

/// One fold range: its first and last line (from 0) and its kind (an index of [`KINDS`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fold {
    pub first: u32,
    pub last: u32,
    pub kind: u8,
}

/// The kind of a `folds.scm` capture NAME: `fold` a block, `fold.KIND` its kind; none for another capture.
fn fold_kind(name: &str) -> Option<u8> {
    match name {
        "fold" => Some(0),
        _ => {
            let k = name.strip_prefix("fold.")?;
            KINDS.iter().position(|x| *x == k).map(|i| i as u8)
        }
    }
}

/// The kind of a `tags.scm` capture NAME: a `definition.*` one's (see the module's doc); none for another capture.
fn definition_kind(name: &str) -> Option<u8> {
    Some(match name.strip_prefix("definition.")? {
        "function" | "method" | "macro" | "constructor" => 1,
        "class" | "struct" | "interface" | "module" | "enum" | "union" | "trait" | "impl"
        | "namespace" | "type" => 2,
        _ => 0,
    })
}

/// A compiled fold query: the query and each capture's kind (none for a capture that is no range, such as `@_name`).
pub struct FoldQuery {
    query: Query,
    kinds: Vec<Option<u8>>,
}

impl FoldQuery {
    /// SCM, a `folds.scm`, compiled against LANGUAGE: a capture is `@fold`, `@fold.KIND` or `@_NAME` (a predicate's
    /// argument), and the predicates are the text ones Nidhogg's runner reads too (`#eq?`, `#not-eq?`, `#any-of?`,
    /// `#match?`, `#not-match?`; tree-sitter evaluates those itself, so any other is in `general_predicates`).
    pub fn folds(language: &tree_sitter::Language, scm: &str) -> Result<FoldQuery, String> {
        let query = Query::new(language, scm).map_err(|e| e.to_string())?;
        let kinds: Vec<Option<u8>> = query.capture_names().iter().map(|c| fold_kind(c)).collect();
        if let Some(c) = query
            .capture_names()
            .iter()
            .zip(&kinds)
            .find(|(c, k)| k.is_none() && !c.starts_with('_'))
        {
            return Err(format!(
                "@{}: not a fold capture (@fold, @fold.KIND or @_NAME)",
                c.0
            ));
        }
        for p in 0..query.pattern_count() {
            if let Some(g) = query.general_predicates(p).first() {
                return Err(format!("#{}: not a fold query's predicate", g.operator));
            }
            if !query.property_settings(p).is_empty() || !query.property_predicates(p).is_empty() {
                return Err("#set!, #is? and #is-not?: not a fold query's predicates".into());
            }
        }
        Ok(FoldQuery { query, kinds })
    }

    /// TAGS, a `tags.scm`, compiled against LANGUAGE as a fold query: its definitions, every other pattern off.
    pub fn from_tags(language: &tree_sitter::Language, tags: &str) -> Result<FoldQuery, String> {
        let mut query = Query::new(language, tags).map_err(|e| e.to_string())?;
        let kinds: Vec<Option<u8>> = query
            .capture_names()
            .iter()
            .map(|c| definition_kind(c))
            .collect();
        for p in 0..query.pattern_count() {
            let used = query.capture_quantifiers(p);
            if !kinds
                .iter()
                .enumerate()
                .any(|(i, k)| k.is_some() && used[i] != CaptureQuantifier::Zero)
            {
                query.disable_pattern(p);
            }
        }
        Ok(FoldQuery { query, kinds })
    }

    /// The fold ranges of TREE, parsed from TEXT, in order.
    pub fn ranges(&self, tree: &Tree, text: &str) -> Vec<Fold> {
        let mut out = Vec::new();
        let mut cursor = QueryCursor::new();
        let mut matches = cursor.matches(&self.query, tree.root_node(), text.as_bytes());
        while let Some(m) = matches.next() {
            for c in m.captures() {
                let Some(kind) = self.kinds[c.index as usize] else {
                    continue;
                };
                let (s, e) = (c.node.start_position(), c.node.end_position());
                // a node ending at a line's start ends on the line before
                let last = if e.column == 0 && e.row > s.row {
                    e.row - 1
                } else {
                    e.row
                };
                if last > s.row {
                    out.push(Fold {
                        first: s.row as u32,
                        last: last as u32,
                        kind,
                    });
                }
            }
        }
        one_a_line(out)
    }
}

/// Of FOLDS, the largest starting on each line (on a tie, the higher kind), in order.
pub fn one_a_line(mut folds: Vec<Fold>) -> Vec<Fold> {
    folds.sort_by_key(|f| {
        (
            f.first,
            std::cmp::Reverse(f.last),
            std::cmp::Reverse(f.kind),
        )
    });
    folds.dedup_by_key(|f| f.first);
    folds
}

/// The `queries/folds.scm` of each built-in kind's pack.
fn folds_source(kind: Kind) -> &'static str {
    macro_rules! folds {
        ($p:literal) => {
            include_str!(concat!("../../../../../packs/", $p, "/queries/folds.scm"))
        };
    }
    match kind {
        Kind::Rust => folds!("rust"),
        Kind::C => folds!("c"),
        Kind::Cpp => folds!("cpp"),
        Kind::Shell => folds!("shell"),
        Kind::Python => folds!("python"),
        Kind::JavaScript => folds!("javascript"),
        Kind::TypeScript => folds!("typescript"),
        Kind::Tsx => folds!("tsx"),
        Kind::Go => folds!("go"),
        Kind::Java => folds!("java"),
        Kind::Csharp => folds!("csharp"),
    }
}

/// KIND's fold query, built on first use once its grammar is there (none while it is not; a pack whose `folds.scm` does
/// not compile against its grammar is said once and folds by indentation).
fn query(kind: Kind) -> Option<&'static FoldQuery> {
    static QUERIES: Mutex<Vec<(Kind, &'static FoldQuery)>> = Mutex::new(Vec::new());
    let mut all = QUERIES.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some((_, q)) = all.iter().find(|(k, _)| *k == kind) {
        return Some(q);
    }
    let language = registry::language(kind)?;
    match FoldQuery::folds(&language, folds_source(kind)) {
        Ok(q) => {
            let q: &'static FoldQuery = Box::leak(Box::new(q));
            all.push((kind, q));
            Some(q)
        }
        Err(e) => {
            registry::say_pack(
                registry::pack_name(kind),
                &format!("its folds.scm does not build: {e}"),
            );
            None
        }
    }
}

/// Every built-in kind's fold query compiled (a test checks each against its grammar), or why not.
pub fn check_all() -> Vec<(&'static str, Result<(), String>)> {
    Kind::ALL
        .iter()
        .map(|k| {
            let r = match registry::language(*k) {
                None => Err("its grammar is not built".to_owned()),
                Some(l) => FoldQuery::folds(&l, folds_source(*k)).map(|_| ()),
            };
            (registry::pack_name(*k), r)
        })
        .collect()
}

/// The fold ranges of TEXT of PATH (language LANG), by its pack's grammar: here for a built-in pack, in its worker for a
/// fetched one. None for a file no tree-sitter pack parses (Lisp, Org, Markdown and plain text fold by the editor's own
/// rules) or one that does not parse.
pub fn of_file(path: &str, lang: Lang, text: &str) -> Option<Vec<Fold>> {
    let kind = match lang {
        Lang::Rust => Kind::Rust,
        Lang::C => Kind::C,
        Lang::Cpp => Kind::Cpp,
        Lang::Shell => Kind::Shell,
        Lang::Python => Kind::Python,
        Lang::JavaScript => Kind::JavaScript,
        Lang::TypeScript => Kind::TypeScript,
        Lang::Tsx => Kind::Tsx,
        Lang::Go => Kind::Go,
        Lang::Java => Kind::Java,
        Lang::Csharp => Kind::Csharp,
        Lang::Text => {
            let pack = worker::claims(path)?;
            return worker::folds(&pack, text).ok();
        }
        _ => return None,
    };
    let q = query(kind)?;
    let language = registry::language(kind)?;
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language).ok()?;
    let tree = parser.parse(text, None)?;
    Some(q.ranges(&tree, text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_names_give_the_kinds() {
        assert_eq!(fold_kind("fold"), Some(0));
        assert_eq!(fold_kind("fold.test"), Some(5));
        assert_eq!(fold_kind("fold.heading"), Some(8));
        assert_eq!(fold_kind("fold.nonsense"), None);
        assert_eq!(fold_kind("_name"), None);
        assert_eq!(definition_kind("definition.method"), Some(1));
        assert_eq!(definition_kind("definition.interface"), Some(2));
        assert_eq!(definition_kind("definition.constant"), Some(0));
        assert_eq!(definition_kind("reference.call"), None);
    }

    #[test]
    fn every_pack_folds_scm_compiles_against_its_grammar() {
        for (pack, r) in check_all() {
            assert!(r.is_ok(), "{pack}: {r:?}");
        }
    }

    #[test]
    fn a_tags_scm_folds_its_definitions() {
        let language = registry::language(Kind::Rust).expect("the Rust grammar");
        let q =
            FoldQuery::from_tags(&language, super::super::refs::tags_source(Kind::Rust)).unwrap();
        let text = "struct A {\n    x: i32,\n}\n\nfn f() {\n    g();\n}\n";
        let mut parser = tree_sitter::Parser::new();
        parser.set_language(&language).unwrap();
        let tree = parser.parse(text, None).unwrap();
        // a definition.class and a definition.function; the call (a reference) is no range
        let f = |first, last, kind| Fold { first, last, kind };
        assert_eq!(q.ranges(&tree, text), vec![f(0, 2, 2), f(4, 6, 1)]);
    }

    /// What Nidhogg's runner would read otherwise (a capture it ignores, a predicate it fails) is refused here.
    #[test]
    fn a_fold_query_keeps_to_its_captures_and_predicates() {
        let rust = registry::language(Kind::Rust).expect("the Rust grammar");
        let ok = r#"((function_item name: (identifier) @_n) @fold.test (#match? @_n "^test") (#not-eq? @_n "x"))
                    ((function_item name: (identifier) @_n) @fold (#any-of? @_n "a" "b") (#not-match? @_n "c"))"#;
        assert!(FoldQuery::folds(&rust, ok).is_ok());
        for (bad, why) in [
            ("(function_item) @name", "@name"),
            ("(function_item) @fold.lambda", "@fold.lambda"),
            ("((function_item) @fold (#is-test? @fold))", "#is-test?"),
            ("((function_item) @fold (#set! priority 1))", "#set!"),
        ] {
            let e = FoldQuery::folds(&rust, bad).err().unwrap_or_default();
            assert!(e.contains(why), "{bad}: {e}");
        }
    }

    #[test]
    fn one_range_a_line_the_largest_then_the_kind() {
        let f = |first, last, kind| Fold { first, last, kind };
        assert_eq!(
            one_a_line(vec![
                f(3, 5, 0),
                f(1, 9, 0),
                f(1, 9, 5),
                f(1, 4, 1),
                f(3, 8, 2)
            ]),
            vec![f(1, 9, 5), f(3, 8, 2)]
        );
    }
}
