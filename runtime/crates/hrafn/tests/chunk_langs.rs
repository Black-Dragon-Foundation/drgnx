//! The tree-sitter languages beyond Lisp, Rust, C and shell: each fixture's chunks give back the file, its definitions
//! come with their kind, lines and first doc line, members nest inside what holds them, an oversized class is cut
//! before its members, and files are classified by extension and `#!` line.
//!
//! test-pattern: pure (D).

use hrafn::chunk::{BUDGET, Chunk, Symbol, chunk_file};
use hrafn::{Class, Lang, classify};

fn fixture(name: &str) -> String {
    let p = format!("{}/tests/fixtures/langs/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{p}: {e}"))
}

/// The chunks put together give back the text.
fn covers(cs: &[Chunk], text: &str) {
    let mut at = 0usize;
    for c in cs {
        assert_eq!(c.start as usize, at);
        at = c.end as usize;
    }
    assert_eq!(at, text.len());
}

/// NAME's chunks and symbols, its language from its extension.
fn run(name: &str, budget: usize) -> (String, Vec<Chunk>, Vec<Symbol>) {
    let text = fixture(name);
    let (lang, _) = classify(name, text.as_bytes());
    let (cs, syms) = chunk_file(name, lang, false, &text, budget);
    covers(&cs, &text);
    (text, cs, syms)
}

/// `(name, kind, first line, last line)` of each symbol, in file order.
fn shapes(syms: &[Symbol]) -> Vec<(String, String, u32, u32)> {
    let mut v: Vec<_> = syms
        .iter()
        .map(|s| (s.name.clone(), s.kind.clone(), s.line_start, s.line_end))
        .collect();
    v.sort_by_key(|s| (s.2, std::cmp::Reverse(s.3)));
    v
}

fn want(rows: &[(&str, &str, u32, u32)]) -> Vec<(String, String, u32, u32)> {
    rows.iter()
        .map(|(n, k, a, b)| (n.to_string(), k.to_string(), *a, *b))
        .collect()
}

fn doc1<'a>(syms: &'a [Symbol], name: &str, line: u32) -> Option<&'a str> {
    syms.iter()
        .find(|s| s.name == name && s.line_start == line)
        .unwrap_or_else(|| panic!("no {name} at line {line}"))
        .doc1
        .as_deref()
}

#[test]
fn python_functions_classes_methods_and_docstrings() {
    let (_, _, syms) = run("shapes.py", BUDGET);
    assert_eq!(
        shapes(&syms),
        want(&[
            ("area", "function", 9, 14),
            ("Circle", "class", 17, 26),
            ("__init__", "method", 20, 21),
            ("area", "method", 23, 26),
            ("Square", "class", 29, 34),
            ("area", "method", 33, 34),
        ])
    );
    assert_eq!(doc1(&syms, "area", 9), Some("Return the area of SHAPE."));
    assert_eq!(
        doc1(&syms, "Circle", 17),
        Some("A circle of a given radius.")
    );
    assert_eq!(doc1(&syms, "area", 23), Some("The circle's area."));
    assert_eq!(doc1(&syms, "Square", 29), None);
    let f = syms.iter().find(|s| s.line_start == 9).unwrap();
    assert_eq!(f.sig, "def area(shape):");
}

#[test]
fn typescript_declarations_exports_members_and_jsdoc() {
    let (_, _, syms) = run("client.ts", BUDGET);
    assert_eq!(
        shapes(&syms),
        want(&[
            ("ClientOptions", "interface", 4, 7),
            ("Handler", "type", 9, 9),
            ("State", "enum", 11, 14),
            ("open", "function", 20, 22),
            ("close", "function", 24, 26),
            ("Client", "class", 28, 41),
            ("constructor", "method", 31, 31),
            ("send", "method", 34, 36),
            ("stop", "method", 38, 40),
            ("Base", "class", 43, 45),
            ("run", "method", 44, 44),
            ("Util", "module", 47, 51),
            ("pad", "function", 48, 50),
        ])
    );
    assert_eq!(
        doc1(&syms, "ClientOptions", 4),
        Some("The options a client takes.")
    );
    assert_eq!(doc1(&syms, "open", 20), Some("Opens a client on HOST."));
    assert_eq!(doc1(&syms, "send", 34), Some("Sends one message."));
    assert_eq!(doc1(&syms, "stop", 38), None);
    let open = syms.iter().find(|s| s.name == "open").unwrap();
    assert_eq!(
        open.sig,
        "export function open(opts: ClientOptions): Client"
    );
}

#[test]
fn tsx_parses_jsx_and_default_exports() {
    let (_, _, syms) = run("view.tsx", BUDGET);
    assert_eq!(
        shapes(&syms),
        want(&[
            ("Props", "type", 3, 3),
            ("TitleBar", "function", 6, 8),
            ("Page", "class", 10, 14),
            ("render", "method", 11, 13),
        ])
    );
    assert_eq!(doc1(&syms, "TitleBar", 6), Some("The title bar."));
    let bar = syms.iter().find(|s| s.name == "TitleBar").unwrap();
    assert_eq!(bar.sig, "export function TitleBar({ title }: Props)");
}

#[test]
fn javascript_functions_function_values_and_classes() {
    let (_, _, syms) = run("server.js", BUDGET);
    assert_eq!(
        shapes(&syms),
        want(&[
            ("start", "function", 8, 10),
            ("handle", "function", 12, 14),
            ("Router", "class", 18, 27),
            ("constructor", "method", 19, 21),
            ("add", "method", 24, 26),
        ])
    );
    assert_eq!(doc1(&syms, "start", 8), Some("Starts the server on PORT."));
    assert_eq!(doc1(&syms, "add", 24), Some("Adds a route."));
}

#[test]
fn go_functions_methods_types_and_package_names() {
    let (_, _, syms) = run("store.go", BUDGET);
    assert_eq!(
        shapes(&syms),
        want(&[
            ("MaxItems", "constant", 6, 6),
            ("defaultStore", "variable", 9, 9),
            ("hits", "variable", 10, 10),
            ("Store", "struct", 15, 18),
            ("Getter", "interface", 20, 22),
            ("Key", "type", 24, 24),
            ("New", "function", 27, 29),
            ("Get", "method", 32, 37),
        ])
    );
    assert_eq!(
        doc1(&syms, "MaxItems", 6),
        Some("MaxItems is how many items a store holds.")
    );
    assert_eq!(doc1(&syms, "Store", 15), Some("Store keeps items by key."));
    assert_eq!(
        doc1(&syms, "Get", 32),
        Some("Get returns the item under KEY.")
    );
    let get = syms.iter().find(|s| s.name == "Get").unwrap();
    assert_eq!(get.sig, "func (s *Store) Get(key string) (string, bool)");
}

#[test]
fn java_types_members_and_javadoc() {
    let (_, _, syms) = run("Queue.java", BUDGET);
    assert_eq!(
        shapes(&syms),
        want(&[
            ("Queue", "class", 8, 29),
            ("Queue", "constructor", 12, 12),
            ("push", "method", 17, 20),
            ("pop", "method", 22, 24),
            ("Node", "class", 26, 28),
            ("Sized", "interface", 31, 33),
            ("size", "method", 32, 32),
            ("Color", "enum", 35, 38),
            ("Point", "record", 40, 40),
        ])
    );
    assert_eq!(doc1(&syms, "Queue", 8), Some("A bounded queue."));
    assert_eq!(doc1(&syms, "Queue", 12), Some("Makes an empty queue."));
    assert_eq!(doc1(&syms, "push", 17), Some("Adds ITEM at the end."));
}

/// An exported class over the budget is cut before its members, never inside one.
#[test]
fn an_oversized_class_is_cut_before_its_members() {
    let (_, cs, _) = run("client.ts", 120);
    let inside: Vec<u32> = cs
        .iter()
        .map(|c| c.line_start)
        .filter(|l| (29..=41).contains(l))
        .collect();
    assert!(
        !inside.is_empty(),
        "{:?}",
        cs.iter().map(|c| c.line_start).collect::<Vec<_>>()
    );
    for l in &inside {
        assert!([29, 31, 33, 34, 38].contains(l), "a cut at line {l}");
    }
    // a test file is one `describe(…, function () { it(…) … })` call: cut before the callback's statements
    let (_, cs, _) = run("app.test.js", 150);
    let starts: Vec<u32> = cs.iter().map(|c| c.line_start).collect();
    assert!(starts.len() > 2, "{starts:?}");
    for l in &starts[1..] {
        assert!(
            [3, 4, 7, 8, 11, 12, 15, 16].contains(l),
            "a cut at line {l}: {starts:?}"
        );
    }
    let (_, cs, _) = run("shapes.py", 80);
    let inside: Vec<u32> = cs
        .iter()
        .map(|c| c.line_start)
        .filter(|l| (18..=26).contains(l))
        .collect();
    assert!(!inside.is_empty());
    for l in &inside {
        assert!([18, 20, 23].contains(l), "a cut at line {l}");
    }
}

#[test]
fn files_are_classified_by_extension_and_shebang() {
    for (path, head, lang) in [
        ("a/b.py", "", Lang::Python),
        ("a/b.pyi", "", Lang::Python),
        ("bin/tool", "#!/usr/bin/env python3\n", Lang::Python),
        ("a.js", "", Lang::JavaScript),
        ("a.mjs", "", Lang::JavaScript),
        ("a.cjs", "", Lang::JavaScript),
        ("a.jsx", "", Lang::JavaScript),
        ("bin/run", "#!/usr/bin/env node\n", Lang::JavaScript),
        ("a.ts", "", Lang::TypeScript),
        ("a.mts", "", Lang::TypeScript),
        ("a.cts", "", Lang::TypeScript),
        ("a.tsx", "", Lang::Tsx),
        ("a.go", "", Lang::Go),
        ("A.java", "", Lang::Java),
        ("a.h", "", Lang::C),
    ] {
        assert_eq!(classify(path, head.as_bytes()).0, lang, "{path}");
    }
    for (lang, name) in [
        (Lang::Python, "python"),
        (Lang::JavaScript, "javascript"),
        (Lang::TypeScript, "typescript"),
        (Lang::Tsx, "tsx"),
        (Lang::Go, "go"),
        (Lang::Java, "java"),
    ] {
        assert_eq!(lang.as_str(), name);
    }
    // tests are known by their directory; a test file by name alone is code (no demotion: HRAFN-TEST-NAMES-1)
    assert_eq!(classify("pkg/tests/test_io.py", b"").1, Class::Test);
    assert_eq!(classify("src/test/java/QueueTest.java", b"").1, Class::Test);
    for path in [
        "pkg/test_io.py",
        "pkg/io_test.py",
        "src/a.test.ts",
        "src/a.spec.tsx",
        "src/a.test.js",
        "pkg/store_test.go",
        "src/main/QueueTest.java",
        "src/contest.py",
    ] {
        assert_eq!(classify(path, b"").1, Class::Code, "{path}");
    }
}
