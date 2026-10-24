use saga::ledger;

const LEDGER: &str = include_str!("fixtures/ledger-a.md");
const PLAN: &str = include_str!("fixtures/plan-h2.md");

#[test]
fn render_of_parse_is_identity() {
    assert_eq!(ledger::render(&ledger::parse(LEDGER)), LEDGER);
    assert_eq!(ledger::render(&ledger::parse(PLAN)), PLAN);
    for odd in ["", "header only", "## a", "## Task 1\r\nx\r\n"] {
        assert_eq!(ledger::render(&ledger::parse(odd)), odd);
    }
}

#[test]
fn ledger_sections_attach_to_tasks() {
    let d = ledger::parse(LEDGER);
    assert!(d.header.starts_with("# Orchard sync"));
    let tasks: Vec<Option<&str>> = d.sections.iter().map(|s| s.task.as_deref()).collect();
    assert_eq!(
        tasks,
        [
            Some("0"),
            None,
            Some("5"),
            None,
            Some("1"),
            Some("22b"),
            None
        ]
    );
    assert_eq!(d.sections[1].body, "\n—\n\n");
    assert!(d.sections[2].body.contains("| a | yes |"));
}
