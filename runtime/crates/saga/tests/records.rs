use saga::table::Block;
use saga::{board_md, deferred, org};
use std::time::Instant;

const DEFERRED: &str = include_str!("fixtures/deferred-a.md");
const BOARD: &str = include_str!("fixtures/board-a.md");
const ORG: &str = include_str!("fixtures/board-a.org");

const ODD: [&str; 7] = [
    "",
    "no table",
    "| a | b |\n|---|---|",
    "| # | Area | Item | Status |\r\n|---|---|---|---|\r\n| 1 | a | b | c |\r\n",
    "| # | Area | Item | Status |\n|---|---|---|---|\n| 1 | a | b | c |",
    "* \n** x\n",
    "text\n* A :t:\r\nbody",
];

#[test]
fn render_of_parse_is_identity() {
    assert_eq!(deferred::render(&deferred::parse(DEFERRED)), DEFERRED);
    assert_eq!(board_md::render(&board_md::parse(BOARD)), BOARD);
    assert_eq!(org::render(&org::parse(ORG)), ORG);
    for t in ODD.into_iter().chain([DEFERRED, BOARD, ORG]) {
        assert_eq!(deferred::render(&deferred::parse(t)), t);
        assert_eq!(board_md::render(&board_md::parse(t)), t);
        assert_eq!(org::render(&org::parse(t)), t);
    }
}

#[test]
fn deferred_rows_parse() {
    let d = deferred::parse(DEFERRED);
    let rows = d.rows();
    let prose: Vec<&str> = d
        .pieces
        .iter()
        .filter_map(|p| match p {
            deferred::DeferredPiece::Prose(s) => Some(s.as_str()),
            _ => None,
        })
        .collect();
    assert!(prose[0].ends_with("|---|---|---|---|\n"));
    assert!(prose[1].starts_with("\nClosing note"));
    assert!(prose[1].contains("| 1 | build | done |"));
    let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, ["M1-1", "M1-2", "M2-1"]);
    assert_eq!(rows[0].area, "harness");
    assert_eq!(rows[0].status, "fixed in M2");
    assert_eq!(rows[2].status, "closed: not needed");
    // a row of two lines is one row, kept as written
    assert!(rows[1].raw.contains("\n  and the note continues"));
    assert_eq!(rows[1].status, "open");
    assert_eq!(&DEFERRED[rows[1].span.clone()], rows[1].raw);
}

#[test]
fn escaped_pipes_survive() {
    let d = deferred::parse(DEFERRED);
    let rows = d.rows();
    assert!(rows[0].text.contains(r"`a\|b`"));
    assert!(rows[2].text.starts_with(r"Pipes \| in prose"));
    let b = board_md::parse(BOARD);
    assert_eq!(b.tables()[0].rows[1].cells[3], r"review `x\|y`");
    assert_eq!(b.tables()[0].rows[1].cells.len(), 4);
}

#[test]
fn board_tables_and_prose_are_kept() {
    let mut b = board_md::parse(BOARD);
    assert_eq!(
        b.tables().len(),
        2,
        "the fenced pseudo table is not a table"
    );
    assert_eq!(b.tables()[0].header.cells, ["#", "What", "Model", "State"]);
    let t = b.table_mut("#").unwrap();
    t.rows.pop();
    let out = board_md::render(&b);
    assert!(!out.contains("Renderer"));
    assert!(out.contains("Invented numbers.") && out.contains("| not | a | table |"));
    assert!(matches!(b.blocks[0], Block::Text(_)));
}

#[test]
fn org_keywords_and_properties_parse() {
    let d = org::parse(ORG);
    assert!(d.preamble.starts_with("#+TITLE"));
    let it = &d.items;
    assert_eq!(it.len(), 4);
    assert_eq!((it[0].level, it[0].keyword.as_deref()), (1, Some("TODO")));
    assert_eq!(it[0].title, "[#A] Write the parser");
    assert_eq!(it[0].tags, ["code", "parser"]);
    assert_eq!(
        it[0].properties,
        [
            ("ID".into(), "t-001".into()),
            ("EFFORT".into(), "2h".into())
        ]
    );
    assert_eq!(
        (it[1].level, it[1].keyword.as_deref()),
        (2, Some("BLOCKED"))
    );
    assert_eq!(it[1].properties, [("ID".into(), "t-002".into())]);
    assert_eq!(it[2].keyword, None);
    assert_eq!(it[2].title, "Plain heading");
    assert_eq!(it[3].keyword.as_deref(), Some("SHIPPED"));
    assert!(it[3].body.is_empty());
}

#[test]
fn unknown_org_syntax_is_kept_as_body() {
    let d = org::parse(ORG);
    let b = &d.items[1].body;
    assert!(b.contains("SCHEDULED: <2026-10-30 Fri>") && b.contains("#+begin_src sh\necho hi"));
    let plain = &d.items[2].body;
    assert!(plain.starts_with("| a | b |\n:LOGBOOK:"));
    assert!(d.items[2].properties.is_empty());
}

#[test]
fn a_1600_row_table_parses_under_50_ms() {
    let mut text = String::from("# Deferred\n\n| # | Area | Item | Status |\n|---|---|---|---|\n");
    for i in 0..1600 {
        text.push_str(&format!(
            "| M{i}-1 | area{} | Item {i} with `code`, a \\| pipe and a longer description of the thing | open |\n",
            i % 7
        ));
    }
    let start = Instant::now();
    let d = deferred::parse(&text);
    let out = deferred::render(&d);
    let b = board_md::parse(&text);
    let elapsed = start.elapsed();
    assert_eq!(d.rows().len(), 1600);
    assert_eq!(out, text);
    assert_eq!(b.tables()[0].rows.len(), 1600);
    assert!(elapsed.as_millis() < 50, "took {elapsed:?}");
}
