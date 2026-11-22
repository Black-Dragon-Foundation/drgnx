use super::*;

const RUST: &str = "use std::fmt;\n\
\n\
struct P {\n\
    x: i32,\n\
}\n\
\n\
impl P {\n\
    fn new() -> P {\n\
        P { x: 0 }\n\
    }\n\
\n\
    fn get(&self) -> i32 {\n\
        self.x\n\
    }\n\
}\n\
\n\
const TOP: i32 = 1;\n";

fn name_at(d: &Defs, line: u32) -> Option<(String, Vec<String>)> {
    d.at(line).map(|d| (d.name.clone(), d.path.clone()))
}

#[test]
fn a_match_gets_the_innermost_definition_and_the_names_around_it() {
    let d = defs("src/p.rs", RUST).expect("rust has definitions");
    let (name, path) = name_at(&d, 13).unwrap();
    assert_eq!(name, "get");
    assert_eq!(path.last().map(String::as_str), Some("get"));
    assert!(path.len() >= 2, "the impl around it: {path:?}");
    assert_eq!(name_at(&d, 9).unwrap().0, "new");
    assert_eq!(name_at(&d, 4).unwrap().0, "P");
}

#[test]
fn a_top_level_line_has_no_context() {
    let d = defs("src/p.rs", RUST).unwrap();
    assert_eq!(d.at(1), None);
    assert_eq!(d.at(2), None);
    assert_eq!(d.at(500), None);
}

#[test]
fn elisp_definitions_are_found() {
    let src = ";;; x.el\n(defun drgnx-gateway--queue (p)\n  \"Queue P.\"\n  (push p drgnx-gateway--pending))\n\n(defvar drgnx-x 1)\n";
    let d = defs("lisp/x.el", src).unwrap();
    assert_eq!(name_at(&d, 4).unwrap().0, "drgnx-gateway--queue");
    assert_eq!(d.at(1), None);
}

#[test]
fn text_org_and_markdown_have_no_context() {
    assert!(defs("notes.txt", "fn x() {}\n").is_none());
    assert!(defs("README.md", "# Title\n\ntext\n").is_none());
    assert!(defs("notes.org", "* Heading\ntext\n").is_none());
}

#[test]
fn a_file_over_two_megabytes_has_no_context() {
    let mut big = String::from("fn f() {\n");
    while big.len() <= MAX_BYTES {
        big.push_str("    let x = 1;\n");
    }
    big.push_str("}\n");
    assert!(defs("big.rs", &big).is_none());
}
