//! Arbitrary bytes through huginn's reader, under the default limits and under tight ones (so depth and size
//! refusals are reached): it never panics; a refusal's span lies inside the input; every span of a read lies inside
//! the input, on character boundaries, nested inside its parent's; nothing nests deeper than the limit; and the
//! source of each top-level datum reads alone to the same datum.
#![no_main]

use huginn::read::{Limits, read_all};
use huginn::value::{Datum, Node};
use libfuzzer_sys::fuzz_target;

/// The datum without spans, floats by their bits (a NaN equals itself).
fn shape(d: &Datum, out: &mut String) {
    let all = |items: &[Node], out: &mut String| {
        for n in items {
            shape(&n.datum, out);
            out.push(' ');
        }
    };
    match d {
        Datum::Int(i) => out.push_str(&format!("i{i}")),
        Datum::Float(f) => out.push_str(&format!("f{:x}", f.to_bits())),
        Datum::Str(s) => out.push_str(&format!("s{s:?}")),
        Datum::Sym(s) => out.push_str(&format!("y{s:?}")),
        Datum::List(items) => {
            out.push('(');
            all(items, out);
            out.push(')');
        }
        Datum::Cons(items, tail) => {
            out.push('(');
            all(items, out);
            out.push_str(". ");
            shape(&tail.datum, out);
            out.push(')');
        }
        Datum::Vec(items) => {
            out.push('[');
            all(items, out);
            out.push(']');
        }
    }
}

/// The deepest nesting of containers under `node` (an atom is 0).
fn depth(node: &Node) -> usize {
    match &node.datum {
        Datum::List(items) | Datum::Vec(items) => 1 + items.iter().map(depth).max().unwrap_or(0),
        Datum::Cons(items, tail) => {
            1 + items
                .iter()
                .chain(Some(&**tail))
                .map(depth)
                .max()
                .unwrap_or(0)
        }
        _ => 0,
    }
}

/// Every child lies inside its parent, and every node inside the input.
fn within(node: &Node, parent: (usize, usize), text: &str) {
    let (s, e) = (node.span.start, node.span.end);
    assert!(
        parent.0 <= s && s <= e && e <= parent.1,
        "{s}..{e} outside {parent:?}"
    );
    assert!(
        text.is_char_boundary(s) && text.is_char_boundary(e),
        "{s}..{e} is not on character boundaries"
    );
    match &node.datum {
        Datum::List(items) | Datum::Vec(items) => {
            items.iter().for_each(|n| within(n, (s, e), text))
        }
        Datum::Cons(items, tail) => items
            .iter()
            .chain(Some(&**tail))
            .for_each(|n| within(n, (s, e), text)),
        _ => {}
    }
}

fn run(data: &[u8], limits: Limits) {
    match read_all(data, limits) {
        Err(r) => assert!(
            r.span.start <= r.span.end && r.span.end <= data.len(),
            "{:?}",
            r.span
        ),
        Ok(nodes) => {
            let text = std::str::from_utf8(data).expect("a read file is UTF-8");
            for node in &nodes {
                within(node, (0, data.len()), text);
                assert!(depth(node) <= limits.max_depth, "deeper than the limit");
                let again = read_all(text[node.span.start..node.span.end].as_bytes(), limits)
                    .expect("the source of a datum reads alone");
                assert_eq!(again.len(), 1);
                let (mut a, mut b) = (String::new(), String::new());
                shape(&node.datum, &mut a);
                shape(&again[0].datum, &mut b);
                assert_eq!(a, b);
            }
        }
    }
}

fuzz_target!(|data: &[u8]| {
    run(data, Limits::default());
    run(
        data,
        Limits {
            max_bytes: 512,
            max_depth: 6,
        },
    );
});
