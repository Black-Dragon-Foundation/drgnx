use saga::import::{AnyDoc, ops, parse, source_key};
use saga::view::{ViewModel, file_text, render, strip_header};
use std::path::Path;

const CASES: [(&str, &str); 5] = [
    ("plan", include_str!("fixtures/plan-h2.md")),
    ("ledger", include_str!("fixtures/ledger-a.md")),
    ("deferred", include_str!("fixtures/deferred-a.md")),
    ("board-md", include_str!("fixtures/board-a.md")),
    ("org", include_str!("fixtures/board-a.org")),
];

fn pieces(doc: &AnyDoc, p: &Path) -> ViewModel {
    ViewModel {
        parts: ops(doc, p).into_iter().map(|o| o.body).collect(),
    }
}

#[test]
fn pieces_concatenate_to_the_file() {
    for (kind, text) in CASES {
        let doc = parse(kind, text).unwrap();
        assert_eq!(render(&pieces(&doc, Path::new("/x/f"))), text, "{kind}");
    }
}

#[test]
fn ids_are_stable_and_sequenced() {
    let doc = parse("plan", CASES[0].1).unwrap();
    let (a, b) = (
        ops(&doc, Path::new("/x/f.md")),
        ops(&doc, Path::new("/x/f.md")),
    );
    assert_eq!(a, b);
    assert!(a.iter().enumerate().all(|(i, o)| o.seq as usize == i));
    assert!(
        a.iter()
            .all(|o| o.source == source_key(Path::new("/x/f.md")))
    );
    assert_ne!(a[0].id, ops(&doc, Path::new("/y/f.md"))[0].id);
}

#[test]
fn the_header_is_stripped_on_the_way_back() {
    for (path, kind, text) in [
        ("/a/b.md", "deferred", CASES[2].1),
        ("/a/b.org", "org", CASES[4].1),
    ] {
        let p = Path::new(path);
        let written = file_text(p, &pieces(&parse(kind, text).unwrap(), p));
        assert_ne!(written, text);
        assert_eq!(strip_header(&written), text);
    }
}
