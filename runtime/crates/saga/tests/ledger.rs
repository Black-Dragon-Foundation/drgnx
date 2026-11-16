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

#[test]
fn done_marks_name_tasks_and_commits() {
    let text = "# SDD ledger — plan: p.md\nTask 1: complete (commit a5813f7, tests: 114/114)\nTask 2-3: complete (commits 0e61612..5ceabdc, tests ok)\nTask 22b: complete\nTask 4: Ruling: not a mark\nTask 5: pending\n";
    let m = saga::ledger::done_marks(text);
    assert_eq!(m.len(), 3);
    assert_eq!(
        (m[0].tasks.clone(), m[0].commits.clone()),
        (vec!["1".to_string()], vec!["a5813f7".to_string()])
    );
    assert_eq!(m[1].tasks, ["2", "3"]);
    assert_eq!(m[1].commits, ["0e61612", "5ceabdc"]);
    assert_eq!(
        (m[2].tasks.clone(), m[2].commits.is_empty()),
        (vec!["22b".to_string()], true)
    );
}
