use proptest::prelude::*;
use saga::plan::{self, PlanDoc};

const FIXTURES: [&str; 3] = [
    include_str!("fixtures/plan-h2.md"),
    include_str!("fixtures/plan-h3.md"),
    include_str!("fixtures/plan-no-eol.md"),
];

fn numbers(d: &PlanDoc) -> Vec<&str> {
    d.tasks.iter().map(|t| t.number.as_str()).collect()
}

#[test]
fn render_of_parse_is_identity() {
    for f in FIXTURES {
        assert_eq!(plan::render(&plan::parse(f)), f);
    }
    for odd in [
        "",
        "\n",
        "no headings\nat all",
        "# t\r\n\r\n## Task 1: x\r\n- [ ] a\r\n",
        "## Task 1\n## Task 2\n",
    ] {
        assert_eq!(plan::render(&plan::parse(odd)), odd);
    }
}

#[test]
fn tasks_are_found_by_heading_at_both_levels() {
    let h2 = plan::parse(FIXTURES[0]);
    assert_eq!(numbers(&h2), ["0", "1", "2", "3", "3b"]);
    assert_eq!(h2.title, "Orchard sync: Implementation Plan");
    assert_eq!(h2.tasks[1].title, "`basket` — the weighing record");
    assert_eq!(h2.tasks[0].title, "(manager): base and skeletons");
    // the fenced "## Task 99" is not a task, and the h3 inside task 1 stays in its body
    assert!(h2.tasks[1].body.contains("A sub-heading inside task 1"));
    assert!(h2.preamble.iter().any(|s| s.body.contains("## Task 99")));
    // "# Wave B" ends task 2 and sits in its `after`; "Exit criteria" is the rest
    assert_eq!(h2.tasks[2].after[0].title(), "Wave B — the harvest");
    assert_eq!(h2.rest[0].title(), "Exit criteria");
    let h3 = plan::parse(FIXTURES[1]);
    assert_eq!(numbers(&h3), ["22b", "23", "24"]);
    assert_eq!(h3.tasks[0].level, 3);
    assert_eq!(h3.rest[0].title(), "Integrations");
    assert!(h3.preamble[0].body.starts_with("Preface line"));
    assert_eq!(h3.title, "Cider plan");
}

#[test]
fn checkbox_steps_parse() {
    let d = plan::parse(FIXTURES[0]);
    let t0 = &d.tasks[0];
    assert!(t0.steps.iter().all(|s| s.done) && t0.steps.len() == 2);
    let t1 = &d.tasks[1];
    assert_eq!(t1.steps.len(), 2);
    assert!(!t1.steps[0].done);
    assert!(t1.steps[0].text.starts_with("**Step 1: Tests:**"));
    assert_eq!(
        d.tasks[2].steps[0].text,
        "**Step 1: Tests**\nwith a continuation line."
    );
    assert!(d.tasks[2].steps[1].done);
    assert_eq!(t1.model.as_deref(), Some("sonnet"));
    assert_eq!(d.tasks[2].model.as_deref(), Some("opus"));
    assert_eq!(d.tasks[0].model.as_deref(), Some("none"));
    assert_eq!(
        t1.files,
        [
            "crates/orchard/src/{basket,scale}.rs",
            "tests/basket.rs",
            "docs/basket.md"
        ]
    );
    let ifc = t1.interfaces.as_deref().unwrap();
    assert!(ifc.starts_with("- Produces: `basket::weigh") && ifc.ends_with("from Task 0."));
    let w = d.waves.as_ref().unwrap();
    assert_eq!(w.header, ["Wave", "Tasks", "Notes"]);
    assert_eq!(w.rows[1], ["B", "3, 3b", "weigh and count"]);
}

#[test]
fn a_task_number_like_22b_is_kept() {
    let d = plan::parse(FIXTURES[1]);
    assert_eq!(d.tasks[0].number, "22b");
    assert_eq!(d.tasks[0].title, "ferment");
    assert_eq!(plan::parse(FIXTURES[0]).tasks[4].number, "3b");
}

#[test]
fn body_span_slices_the_source() {
    for f in FIXTURES {
        for t in plan::parse(f).tasks {
            assert_eq!(&f[t.body_span.clone()], t.body);
        }
    }
}

proptest! {
    #[test]
    fn an_edit_inside_a_task_body_changes_only_that_task(which in 0usize..5, body in "[a-z \n]{0,60}") {
        let before = plan::parse(FIXTURES[0]);
        let mut edited = before.clone();
        edited.tasks[which].set_body(&body);
        let after = plan::parse(&plan::render(&edited));
        prop_assert_eq!(after.tasks.len(), before.tasks.len());
        for i in 0..before.tasks.len() {
            if i != which {
                let (mut a, mut b) = (after.tasks[i].clone(), before.tasks[i].clone());
                a.body_span = 0..0; // spans shift when an earlier task changes length
                b.body_span = 0..0;
                prop_assert_eq!(a, b);
            }
        }
        prop_assert_eq!(&after.preamble, &before.preamble);
        prop_assert_eq!(&after.rest, &before.rest);
        prop_assert_eq!(&after.tasks[which].after, &before.tasks[which].after);
        prop_assert_eq!(after.tasks[which].body.trim_end_matches('\n'), body.trim_end_matches('\n'));
    }

    #[test]
    fn any_text_round_trips(text in "(#{0,3} ?(Task [0-9]{1,2}[a-c]?)?[a-z -]{0,6}\n|- \\[[ x]\\] [a-z]{0,4}\n|```\n|\n){0,24}") {
        prop_assert_eq!(plan::render(&plan::parse(&text)), text);
    }
}
