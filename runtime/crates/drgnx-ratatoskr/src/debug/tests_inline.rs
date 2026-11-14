//! Inline values (spec §8): which names, where, how long, changed, the parse cache, and nothing for what has no grammar.
use super::inline::{Inline, Shown, Var};
use super::session::{ScopeVars, Stop};
use serde_json::json;
use std::collections::HashMap;

fn local(name: &str, value: &str) -> Var {
    Var {
        name: name.into(),
        value: value.into(),
        global: false,
    }
}

fn global(name: &str, value: &str) -> Var {
    Var {
        name: name.into(),
        value: value.into(),
        global: true,
    }
}

/// LINE's text, or none.
fn at(shown: &[Shown], line: u32) -> Option<&str> {
    shown
        .iter()
        .find(|s| s.line == line)
        .map(|s| s.text.as_str())
}

fn lines(shown: &[Shown]) -> Vec<(u32, &str)> {
    shown.iter().map(|s| (s.line, s.text.as_str())).collect()
}

const PY: &str = "\
import os

limit = 10


def add(a, b):
    s = a + b
    return s


def main(n):
    total = 0
    point = {\"x\": 1}
    for i in range(n):
        total = add(total, i)
        count = i * 2
        print(total, limit)
    late = total + 1
    return late
";

#[test]
fn a_python_stop_shows_the_names_up_to_the_line_and_the_whole_loop_body() {
    let vars = [
        local("n", "5"),
        local("total", "3"),
        local("point", "{'x': 1}"),
        local("i", "3"),
        local("count", "4"),
        global("limit", "10"),
        global("add", "<function add at 0x7f>"),
    ];
    // stopped at `total = add(total, i)` (line 15), inside the loop: `count` (line 16) and `limit` (17) ran on earlier
    // passes; `late` (18) has not run; `add` is called, not a value; each name on its last line up to the stop
    let shown = Inline::new().lines("prog.py", PY, 15, &vars, None);
    assert_eq!(
        lines(&shown),
        [
            (13, "point = {'x': 1}"),
            (14, "n = 5"),
            (15, "total = 3  i = 3"),
            (16, "count = 4"),
            (17, "limit = 10"),
        ]
    );
}

#[test]
fn only_the_innermost_function_is_read() {
    let text = "def outer():\n    x = 1\n    def inner(y):\n        z = y + 1\n        return z\n    return inner(x)\n";
    let vars = [local("y", "2"), local("z", "3"), local("x", "9")];
    let shown = Inline::new().lines("f.py", text, 4, &vars, None);
    assert_eq!(lines(&shown), [(4, "z = 3  y = 2")]);
}

#[test]
fn a_stop_outside_any_function_reads_the_top_level() {
    let text = "a = 1\nb = a + 1\nc = b\n";
    let vars = [
        global("a", "1"),
        global("b", "2"),
        global("c", "<undefined>"),
    ];
    let shown = Inline::new().lines("t.py", text, 2, &vars, None);
    assert_eq!(lines(&shown), [(2, "b = 2  a = 1")]);
}

#[test]
fn a_global_is_shown_only_when_no_local_shadows_it() {
    let text = "def f():\n    x = 1\n    return x + g\n";
    let vars = [local("x", "1"), global("x", "100"), global("g", "7")];
    let shown = Inline::new().lines("s.py", text, 3, &vars, None);
    assert_eq!(lines(&shown), [(3, "x = 1  g = 7")]);
}

#[test]
fn at_most_three_values_a_line_each_cut_at_60_and_the_line_at_120() {
    let text = "def f(a, b, c, d):\n    return a + b + c + d\n";
    let long = "y".repeat(80);
    let vars = [
        local("a", &long),
        local("b", &long),
        local("c", "3"),
        local("d", "4"),
    ];
    let shown = Inline::new().lines("m.py", text, 2, &vars, None);
    let line = at(&shown, 2).unwrap();
    let cut = format!("{}…", "y".repeat(59));
    assert!(line.starts_with(&format!("a = {cut}  b = ")), "{line}");
    assert_eq!(line.chars().count(), 120, "{line}");
    assert!(line.ends_with('…'), "{line}");
    assert!(!line.contains("d = "), "{line}");
    // a short line: three, joined by two spaces
    let vars = [
        local("a", "1"),
        local("b", "2"),
        local("c", "3"),
        local("d", "4"),
    ];
    let shown = Inline::new().lines("m.py", text, 2, &vars, None);
    assert_eq!(at(&shown, 2), Some("a = 1  b = 2  c = 3"));
    // a value of several lines is shown on one
    let vars = [local("a", "x\ny")];
    let shown = Inline::new().lines("m.py", "def f(a):\n    return a\n", 2, &vars, None);
    assert_eq!(at(&shown, 2), Some("a = x y"));
}

#[test]
fn a_changed_value_is_marked() {
    let text = "def f():\n    a = 1\n    b = 2\n    return a + b\n";
    let before: HashMap<String, String> =
        [("a".into(), "1".into()), ("b".into(), "1".into())].into();
    let vars = [local("a", "1"), local("b", "2")];
    let shown = Inline::new().lines("c.py", text, 4, &vars, Some(&before));
    let last = shown.iter().find(|s| s.line == 4).unwrap();
    assert_eq!(last.text, "a = 1  b = 2");
    // `b = 2`, in characters
    assert_eq!(last.changed, [(7, 12)]);
    // no earlier stop: nothing is changed
    let shown = Inline::new().lines("c.py", text, 4, &vars, None);
    assert!(shown.iter().all(|s| s.changed.is_empty()));
}

#[test]
fn a_file_is_parsed_once_per_digest() {
    let i = Inline::new();
    let vars = [local("a", "1")];
    let text = "def f():\n    a = 1\n    return a\n";
    i.lines("p.py", text, 3, &vars, None);
    i.lines("p.py", text, 3, &vars, None);
    i.lines("other.py", text, 2, &vars, None);
    assert_eq!(i.parses(), 1);
    i.lines("p.py", &text.replace("a = 1", "a = 2"), 3, &vars, None);
    assert_eq!(i.parses(), 2);
}

#[test]
fn a_language_without_a_grammar_gets_none() {
    let vars = [local("a", "1")];
    assert!(
        Inline::new()
            .lines("notes.md", "a\n", 1, &vars, None)
            .is_empty()
    );
    assert!(
        Inline::new()
            .lines("data.txt", "a = 1\n", 1, &vars, None)
            .is_empty()
    );
    assert!(
        Inline::new()
            .lines("x.kt", "val a = 1\n", 1, &vars, None)
            .is_empty()
    );
}

/// A grammar's case: the path, its text, the stopped line, the lines shown.
type Case<'a> = (&'a str, &'a str, u32, &'a [(u32, &'a str)]);

/// Each grammar: the innermost function around the stop, its names up to it, the loop body, nothing called.
#[test]
fn every_grammar_finds_the_function_and_its_names() {
    let vars = [local("a", "1"), local("b", "2"), local("k", "3")];
    let cases: &[Case] = &[
        (
            "f.rs",
            "fn g() {}\nfn f(a: i32) -> i32 {\n    let b = a + 1;\n    for k in 0..3 {\n        g();\n        println!(\"{}\", b);\n    }\n    b\n}\n",
            5,
            &[(3, "b = 2  a = 1"), (4, "k = 3")],
        ),
        (
            "f.c",
            "int g(void);\nint f(int a) {\n  int b = a + 1;\n  for (int k = 0; k < 3; k++) {\n    g();\n    b += k;\n  }\n  return b;\n}\n",
            5,
            &[(3, "b = 2  a = 1"), (4, "k = 3")],
        ),
        (
            "f.cpp",
            "int g();\nint f(int a) {\n  int b = a + 1;\n  for (int k : {1, 2, 3}) {\n    g();\n    b += k;\n  }\n  return b;\n}\n",
            5,
            &[(3, "b = 2  a = 1"), (4, "k = 3")],
        ),
        (
            "F.cc",
            "class F {\n public:\n  int f(int a) {\n    auto inc = [&](int x) {\n      int b = x + a;\n      return b;\n    };\n    return inc(a);\n  }\n};\n",
            5,
            // the stop is inside the lambda: only the innermost function is read, and `a` is its capture
            &[(5, "b = 2  a = 1")],
        ),
        (
            "f.go",
            "package main\n\nfunc f(a int) int {\n\tb := a + 1\n\tfor k := 0; k < 3; k++ {\n\t\tg()\n\t\tb += k\n\t}\n\treturn b\n}\n",
            6,
            &[(4, "b = 2  a = 1"), (5, "k = 3")],
        ),
        (
            "f.js",
            "function f(a) {\n  let b = a + 1;\n  for (let k = 0; k < 3; k++) {\n    g();\n    b += k;\n  }\n  return b;\n}\n",
            4,
            &[(2, "b = 2  a = 1"), (3, "k = 3")],
        ),
        (
            "f.ts",
            "const f = (a: number): number => {\n  const b = a + 1;\n  g();\n  return b;\n};\n",
            3,
            &[(2, "b = 2  a = 1")],
        ),
        (
            "F.java",
            "class F {\n  int f(int a) {\n    int b = a + 1;\n    while (b > 0) {\n      g();\n      b -= 1;\n    }\n    return b;\n  }\n}\n",
            5,
            // `b` is read again in the loop's condition (line 4), its last line up to the stop
            &[(3, "a = 1"), (4, "b = 2")],
        ),
        (
            "f.sh",
            "f() {\n  local a=1\n  local b=$((a + 1))\n  echo \"$b\"\n}\n",
            4,
            &[(3, "a = 1"), (4, "b = 2")],
        ),
    ];
    for (path, text, line, want) in cases {
        let shown = Inline::new().lines(path, text, *line, &vars, None);
        assert_eq!(lines(&shown), *want, "{path}");
    }
}

#[test]
fn a_stop_gives_its_event_with_the_changes_since_the_last_stop() {
    let dir = std::env::temp_dir().join(format!("drgnx-inline-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("s.py");
    std::fs::write(&path, "def f():\n    a = 1\n    a = 2\n    return a\n").unwrap();
    let stop = |epoch: u64, line: i64, a: &str| Stop {
        epoch,
        thread: 1,
        reason: "step".into(),
        description: None,
        all_threads: false,
        threads: vec![],
        frames: vec![json!({"id": 7, "line": line, "source": {"path": path}})],
        total_frames: None,
        frame: 7,
        scopes: vec![
            ScopeVars {
                scope: json!({"name": "Locals", "variablesReference": 1}),
                variables: Some(vec![
                    json!({"name": "a", "value": a, "variablesReference": 0}),
                ]),
            },
            // an expensive scope that was not fetched
            ScopeVars {
                scope: json!({"name": "Registers", "variablesReference": 2, "expensive": true}),
                variables: None,
            },
        ],
        exception: None,
        hit: vec![],
    };
    let i = Inline::new();
    let first = i.at_stop("d1", &stop(1, 3, "1"));
    assert_eq!(
        first,
        json!({"session": "d1", "epoch": 1, "path": path,
               "lines": [{"line": 3, "text": "a = 1", "changed": []}]})
    );
    let next = i.at_stop("d1", &stop(2, 4, "2"));
    assert_eq!(
        next["lines"],
        json!([{"line": 4, "text": "a = 2", "changed": [[0, 5]]}])
    );
    // another session has its own past
    let other = i.at_stop("d2", &stop(1, 4, "2"));
    assert_eq!(other["lines"][0]["changed"], json!([]));
    // a frame with no file, or a file gone: no lines (the editor clears its values)
    std::fs::remove_file(&path).unwrap();
    assert_eq!(i.at_stop("d1", &stop(3, 4, "2"))["lines"], json!([]));
    i.forget("d1");
}
