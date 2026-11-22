//! Properties of the spans: for data printed canonically, every node's span slices out source text that reads, alone,
//! to the same datum, and every child lies inside its parent.

mod common;

use common::{dump, same};
use huginn::read::{Limits, read_all};
use huginn::value::{Datum, Node};
use proptest::prelude::*;

/// A datum to print: what a settings file could hold.
#[derive(Debug, Clone)]
enum Gen {
    Int(i64),
    Float(f64),
    Str(String),
    Sym(String),
    List(Vec<Gen>),
    Dotted(Vec<Gen>, Box<Gen>),
    Vector(Vec<Gen>),
    Quote(Box<Gen>),
    Function(Box<Gen>),
}

fn print_all(items: &[Gen]) -> String {
    items.iter().map(print).collect::<Vec<_>>().join(" ")
}

/// The datum as Emacs's `prin1` would print it (floats as Rust prints them, which Emacs reads alike).
fn print(g: &Gen) -> String {
    match g {
        Gen::Int(i) => i.to_string(),
        Gen::Float(f) if f.is_nan() => "0.0e+NaN".to_owned(),
        Gen::Float(f) if f.is_infinite() && *f > 0.0 => "1.0e+INF".to_owned(),
        Gen::Float(f) if f.is_infinite() => "-1.0e+INF".to_owned(),
        Gen::Float(f) => format!("{f:?}"),
        Gen::Str(s) => format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"")),
        Gen::Sym(s) => s.clone(),
        Gen::List(items) => format!("({})", print_all(items)),
        Gen::Dotted(items, tail) => format!("({} . {})", print_all(items), print(tail)),
        Gen::Vector(items) => format!("[{}]", print_all(items)),
        Gen::Quote(g) => format!("'{}", print(g)),
        Gen::Function(g) => format!("#'{}", print(g)),
    }
}

fn leaf() -> impl Strategy<Value = Gen> {
    prop_oneof![
        any::<i64>().prop_map(Gen::Int),
        prop_oneof![
            (-1.0e6..1.0e6f64).prop_map(Gen::Float),
            any::<f64>().prop_map(Gen::Float),
            Just(Gen::Float(-0.0)),
        ],
        "[ -~\\x{a0}-\\x{2ff}\\n\\t\\x{4e00}-\\x{4e20}\\x{1f300}-\\x{1f310}]{0,8}"
            .prop_map(Gen::Str),
        "[a-z][a-z0-9*/<>=!_%&$~^-]{0,6}".prop_map(Gen::Sym),
        "[a-z]{1,3}\\\\ [a-z]{1,3}".prop_map(Gen::Sym),
        "(:[a-z]{1,6}|&[a-z]{1,6})".prop_map(Gen::Sym),
    ]
}

fn datum() -> impl Strategy<Value = Gen> {
    leaf().prop_recursive(4, 64, 6, |inner| {
        prop_oneof![
            prop::collection::vec(inner.clone(), 0..5).prop_map(Gen::List),
            (prop::collection::vec(inner.clone(), 1..4), leaf_tail())
                .prop_map(|(items, tail)| Gen::Dotted(items, Box::new(tail))),
            prop::collection::vec(inner.clone(), 0..5).prop_map(Gen::Vector),
            inner.clone().prop_map(|g| Gen::Quote(Box::new(g))),
            inner.prop_map(|g| Gen::Function(Box::new(g))),
        ]
    })
}

/// A dotted tail: an atom that is not `nil` (a list tail would read as a longer list).
fn leaf_tail() -> impl Strategy<Value = Gen> {
    prop_oneof![
        any::<i64>().prop_map(Gen::Int),
        "tail[a-z]{0,4}".prop_map(Gen::Sym),
        "[a-z ]{0,4}".prop_map(Gen::Str),
    ]
}

/// Walk the tree: the span lies inside the parent's and inside the text, and its source reads alone to the datum.
fn check(node: &Node, parent: (usize, usize), text: &str) -> Result<(), String> {
    let (start, end) = (node.span.start, node.span.end);
    if start < parent.0 || end < start || parent.1 < end {
        return Err(format!(
            "{start}..{end} lies outside its parent {}..{}",
            parent.0, parent.1
        ));
    }
    let source = text
        .get(start..end)
        .ok_or_else(|| format!("{start}..{end} is not a slice of {text:?}"))?;
    // the `quote` or `function` a `'` or `#'` stands for has that token as its span
    if !matches!(source, "'" | "#'") {
        let again = read_all(source.as_bytes(), Limits::default())
            .map_err(|r| format!("{source:?} does not read alone: {r}"))?;
        let [again] = again.as_slice() else {
            return Err(format!("{source:?} reads as {} data", again.len()));
        };
        if !same(&dump(node), &dump(again)) {
            return Err(format!(
                "{source:?}: {} vs {} read alone",
                dump(node),
                dump(again)
            ));
        }
    }
    let children: Vec<&Node> = match &node.datum {
        Datum::List(items) | Datum::Vec(items) => items.iter().collect(),
        Datum::Cons(items, tail) => items.iter().chain(std::iter::once(&**tail)).collect(),
        _ => Vec::new(),
    };
    let mut last = start;
    for child in children {
        if child.span.start < last {
            return Err(format!("{source:?}: children overlap or are out of order"));
        }
        last = child.span.end;
        check(child, (start, end), text)?;
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn every_span_rereads_to_the_same_datum(g in datum(), pad in "[ \\n]{0,3}", comment in prop::bool::ANY) {
        let lead = if comment { "; leading comment ( ` ,\n" } else { "" };
        let text = format!("{lead}{pad}{}{pad}\n", print(&g));
        let nodes = read_all(text.as_bytes(), Limits::default())
            .map_err(|r| TestCaseError::fail(format!("{text:?}: refused: {r}")))?;
        prop_assert_eq!(nodes.len(), 1, "{:?}", text);
        let all = (0, text.len());
        check(&nodes[0], all, &text).map_err(|why| TestCaseError::fail(format!("{text:?}: {why}")))?;
        // the top-level span is the printed datum, no padding and no comment
        prop_assert_eq!(&text[nodes[0].span.start..nodes[0].span.end], print(&g));
    }
}
