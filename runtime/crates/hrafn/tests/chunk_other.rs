use hrafn::Lang;
use hrafn::chunk::{BUDGET, Chunk, Symbol, chunk_file};

fn run(lang: Lang, text: &str, budget: usize) -> (Vec<Chunk>, Vec<Symbol>) {
    chunk_file("src/sample", lang, false, text, budget)
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

fn sym<'a>(syms: &'a [Symbol], name: &str, kind: &str) -> &'a Symbol {
    syms.iter()
        .find(|s| s.name == name && s.kind == kind)
        .unwrap_or_else(|| {
            panic!(
                "{name} ({kind}) in {:?}",
                syms.iter().map(|s| (&s.name, &s.kind)).collect::<Vec<_>>()
            )
        })
}

const RUST: &str = "/// Adds two numbers.
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

struct P {
    x: i32,
}

impl P {
    /// Makes one.
    fn new() -> P {
        P { x: 0 }
    }

    fn get(&self) -> i32 {
        self.x
    }
}
";

#[test]
fn rust_impl_and_fns_are_units() {
    let (cs, syms) = run(Lang::Rust, RUST, BUDGET);
    covers(&cs, RUST);
    let add = sym(&syms, "add", "function");
    assert_eq!(add.doc1.as_deref(), Some("Adds two numbers."));
    sym(&syms, "P", "struct");
    sym(&syms, "P", "impl");
    let new = sym(&syms, "new", "method");
    assert_eq!(new.doc1.as_deref(), Some("Makes one."));
    assert!(RUST[new.start as usize..].starts_with("fn new"));
    // a small budget makes the functions units of their own, and the impl splits between its methods
    let (cs, syms) = run(Lang::Rust, RUST, 40);
    covers(&cs, RUST);
    assert_ne!(
        sym(&syms, "new", "method").chunk,
        sym(&syms, "get", "method").chunk
    );
    assert_ne!(
        sym(&syms, "add", "function").chunk,
        sym(&syms, "P", "struct").chunk
    );
    let part = &cs[sym(&syms, "get", "method").chunk as usize];
    assert!(part.header.contains("part "), "{}", part.header);
    assert!(part.header.contains("impl P {"), "{}", part.header);
}

#[test]
fn c_function_is_unit() {
    let text = "int add(int a, int b)\n{\n    return a + b;\n}\n\nstruct pt { int x; int y; };\n\n#define TWICE(x) ((x) * 2)\n";
    let (cs, syms) = run(Lang::C, text, 30);
    covers(&cs, text);
    let add = sym(&syms, "add", "function");
    sym(&syms, "pt", "struct");
    sym(&syms, "TWICE", "macro");
    let c = &cs[add.chunk as usize];
    assert!(c.fts.body.contains("return a + b;"));
    assert!(!c.fts.body.contains("struct pt"));
}

#[test]
fn shell_function_is_unit() {
    let text = "#!/usr/bin/env bash\n# Say hi.\nhello() {\n  echo hi\n}\n\nhello\n";
    let (cs, syms) = run(Lang::Shell, text, BUDGET);
    covers(&cs, text);
    let hello = sym(&syms, "hello", "function");
    assert_eq!(hello.doc1.as_deref(), Some("Say hi."));
}

#[test]
fn org_header_is_outline_path() {
    let text = "* A\n** B\nbody text\n* C\nmore text\n";
    let (cs, syms) = run(Lang::Org, text, BUDGET);
    covers(&cs, text);
    assert!(syms.is_empty());
    assert_eq!(cs.len(), 2);
    assert!(cs[0].header.contains("section: A > B"), "{}", cs[0].header);
    assert!(cs[1].header.contains("section: C"), "{}", cs[1].header);
    assert!(cs[0].fts.body.contains("body text"));
    assert!(!cs[0].fts.body.contains("more text"));
}

#[test]
fn org_logbook_not_embedded() {
    let text = "* TODO t\n:PROPERTIES:\n:ID: abc\n:END:\n:LOGBOOK:\n- State \"DONE\" from \"TODO\"\n:END:\ntext here\n";
    let (cs, _) = run(Lang::Org, text, BUDGET);
    assert_eq!(cs.len(), 1);
    assert!(cs[0].embed_text.contains("text here"));
    assert!(!cs[0].embed_text.contains(":ID:"));
    assert!(!cs[0].embed_text.contains("State"));
    assert!(cs[0].fts.body.contains(":LOGBOOK:"));
}

#[test]
fn md_table_split_repeats_header() {
    let mut text = String::from("# Rates\n\n| name | value |\n|------|-------|\n");
    for i in 0..30 {
        text.push_str(&format!("| row{i} | {i} |\n"));
    }
    let (cs, _) = run(Lang::Markdown, &text, 120);
    covers(&cs, &text);
    assert!(cs.len() > 2);
    for c in &cs {
        assert!(c.header.contains("section: Rates"), "{}", c.header);
    }
    // every piece after the one that starts the table repeats the header rows in embed_text, not in its span
    let later: Vec<&Chunk> = cs
        .iter()
        .filter(|c| c.fts.body.contains("| row") && !c.fts.body.contains("| name | value |"))
        .collect();
    assert!(!later.is_empty());
    for c in later {
        assert!(
            c.embed_text.contains("| name | value |"),
            "{}",
            c.embed_text
        );
        assert!(c.embed_text.contains("|------|-------|"));
        // the repeated rows are not part of the span
        assert!(!c.fts.body.contains("| name | value |"));
    }
}

#[test]
fn src_block_kept_whole() {
    let text = "* H\n\nfirst paragraph here\nwith two lines\n\n#+begin_src elisp\n(defun a () 1)\n(defun b () 2)\n#+end_src\n\nlast paragraph here\nwith two lines too\n";
    let (cs, _) = run(Lang::Org, text, 70);
    covers(&cs, text);
    assert!(cs.len() > 1);
    let holder: Vec<&Chunk> = cs
        .iter()
        .filter(|c| c.fts.body.contains("#+begin_src"))
        .collect();
    assert_eq!(holder.len(), 1);
    assert!(holder[0].fts.body.contains("#+end_src"));
    assert!(holder[0].fts.body.contains("(defun b () 2)"));
}

#[test]
fn text_windows_cover_file() {
    let mut text = String::new();
    for i in 0..50 {
        text.push_str(&format!("line number {i:03} of text\n"));
    }
    text.push_str(&"x".repeat(450));
    text.push('\n');
    let (cs, syms) = run(Lang::Text, &text, 100);
    covers(&cs, &text);
    assert!(syms.is_empty());
    assert!(cs.len() > 10);
    for c in &cs {
        let n = c.fts.body.chars().filter(|ch| !ch.is_whitespace()).count();
        assert!(n <= 100, "{n}");
        assert_eq!(c.symbol, None);
    }
}

/// Pattern D. A chunk's `line_start` is the line its text begins on, not the line before: chunks are cut where the
/// previous one ended (on its last newline), and a hit opens at `line_start`. Two real shapes: a `#[derive]` above a
/// struct after a comment banner, and constants after a doc comment.
#[test]
fn a_chunk_starts_on_its_first_line_of_text() {
    let derive = "use serde::Deserialize;\n\n// ---------------- task_write\n\n#[derive(Deserialize, JsonSchema)]\nstruct TaskWriteArgs {\n    /// create, update, claim\n    op: String,\n    id: Option<String>,\n}\n\nfn valid_req() {}\n";
    let consts = "pub const CARD_CHOICES: [&str; 3] = [\"once\", \"session\", \"refuse\"];\n\n/// The longest value and name taken.\nconst MAX_VALUE: usize = 16_384;\nconst MAX_NAME: usize = 256;\n/// The most names one `settings_get` asks for.\nconst MAX_NAMES: usize = 64;\n\n/// This file's tools.\npub fn tools() {}\n";
    for text in [derive, consts] {
        let lines: Vec<&str> = text.lines().collect();
        let (cs, _) = run(Lang::Rust, text, 60);
        assert!(cs.len() > 2, "{} chunks", cs.len());
        for c in &cs {
            let first = c.fts.body.lines().find(|l| !l.trim().is_empty()).unwrap();
            assert_eq!(
                lines[c.line_start as usize - 1].trim_end(),
                first.trim_end(),
                "chunk at line {} of {text:?}",
                c.line_start
            );
        }
    }
}
