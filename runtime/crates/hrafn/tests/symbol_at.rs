//! The symbol at a line: what the editor's agent line names (`search/symbol-at`).

use hrafn::chunk::symbol_at_line;

const RUST: &str = "/// Adds two numbers.
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

struct P {
    x: i32,
}

impl P {
    fn new() -> P {
        P { x: 0 }
    }

    fn get(&self) -> i32 {
        self.x
    }
}
";

#[test]
fn symbol_at_line_innermost_wins() {
    let at = |line| symbol_at_line("src/p.rs", RUST, line);
    assert_eq!(at(3).as_deref(), Some("add"));
    assert_eq!(at(16).as_deref(), Some("get"), "a method inside its impl");
    assert_eq!(at(12).as_deref(), Some("new"));
    assert_eq!(
        at(14).as_deref(),
        Some("P"),
        "between the methods: the impl"
    );
}

#[test]
fn symbol_at_line_outside_any_is_none() {
    let at = |line| symbol_at_line("src/p.rs", RUST, line);
    assert_eq!(at(5), None, "the blank line between two items");
    assert_eq!(at(40), None, "past the end");
    assert_eq!(
        symbol_at_line("notes.txt", "a\nb\n", 1),
        None,
        "plain text defines nothing"
    );
}
