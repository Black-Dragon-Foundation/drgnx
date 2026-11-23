//! A plan task's `**Status:**` line: it wins over the ticks, the graph's status is written into it, and a text nobody
//! changed round-trips byte for byte.

use saga::import::{self, AnyDoc};
use saga::plan;
use saga::status::{STATUSES, status_of, with_status};

const TASK: &str = "### Task 3: Build it\n\n- [ ] one\n- [ ] two\n";

fn read(raw: &str) -> Option<String> {
    status_of("task", "task", raw)
}

#[test]
fn every_state_round_trips_through_the_line() {
    for s in STATUSES {
        let text = with_status("task", "task", TASK, s);
        let text = text.as_deref().unwrap_or(TASK);
        assert_eq!(read(text).as_deref(), Some(s), "{s}: {text:?}");
        // an unchanged graph writes nothing
        assert_eq!(with_status("task", "task", text, s), None, "{s}");
        // and the text is a plan that renders back as it came
        let doc = format!("# P\n\n{text}");
        assert_eq!(plan::render(&plan::parse(&doc)), doc, "{s}");
        // back to open: the text is the original (open needs no line; ticks stay unticked)
        let back = with_status("task", "task", text, "open");
        let back = back.as_deref().unwrap_or(text);
        assert_eq!(read(back).as_deref(), Some("open"), "{s}");
        if s != "done" {
            assert!(!back.contains("**Status:**"), "{s}: {back:?}");
        }
    }
}

#[test]
fn a_line_and_the_reason_are_kept() {
    let t = "### Task 3: Build it\n\n**Status:** parked — revisit after B1\n\n- [ ] one\n";
    assert_eq!(read(t).as_deref(), Some("parked"));
    let t2 = with_status("task", "task", t, "blocked").unwrap();
    assert!(
        t2.contains("**Status:** blocked — revisit after B1\n"),
        "{t2:?}"
    );
    assert_eq!(read(&t2).as_deref(), Some("blocked"));
}

#[test]
fn a_line_wins_over_unticked_or_ticked_steps() {
    let done = "### Task 3: x\n\n**Status:** done — merged\n\n- [ ] one\n";
    assert_eq!(read(done).as_deref(), Some("done"));
    let open = "### Task 3: x\n\n**Status:** open\n\n- [x] one\n- [x] two\n";
    assert_eq!(read(open).as_deref(), Some("open"));
}

#[test]
fn a_removed_line_falls_back_to_the_ticks() {
    let with = "### Task 3: x\n\n**Status:** blocked — waits\n\n- [x] one\n- [x] two\n";
    assert_eq!(read(with).as_deref(), Some("blocked"));
    let without = "### Task 3: x\n\n- [x] one\n- [x] two\n";
    assert_eq!(read(without).as_deref(), Some("done"));
    assert_eq!(
        read("### Task 3: x\n\n- [ ] one\n").as_deref(),
        Some("open")
    );
}

#[test]
fn an_unknown_word_stays_text_and_the_ticks_decide() {
    let t = "### Task 3: x\n\n**Status:** wibble — hmm\n\n- [ ] one\n";
    assert_eq!(read(t).as_deref(), Some("open"));
    // writing "open" changes nothing: the line is never dropped
    assert_eq!(with_status("task", "task", t, "open"), None);
    let blocked = with_status("task", "task", t, "blocked").unwrap();
    assert!(
        blocked.contains("**Status:** blocked — hmm\n"),
        "{blocked:?}"
    );
}

#[test]
fn done_with_ticked_steps_needs_no_line_but_done_without_steps_does() {
    let steps = with_status("task", "task", TASK, "done").unwrap();
    assert!(
        steps.contains("- [x] one") && !steps.contains("**Status:**"),
        "{steps:?}"
    );
    let bare = "### Task 4: spike\n\nJust prose.\n";
    let t = with_status("task", "task", bare, "done").unwrap();
    assert!(
        t.starts_with("### Task 4: spike\n**Status:** done\n"),
        "{t:?}"
    );
    assert_eq!(read(&t).as_deref(), Some("done"));
}

#[test]
fn the_import_takes_the_lines_status() {
    let text = "# P\n\n### Task 1: a\n\n**Status:** accepted — spike result taken\n\nProse.\n\n### Task 2: b\n\n- [ ] x\n";
    let Some(doc) = import::parse("plan", text) else {
        panic!()
    };
    assert!(matches!(doc, AnyDoc::Plan(_)));
    let ops = import::ops(&doc, std::path::Path::new("/p/docs/plans/x/p.md"));
    let st: Vec<_> = ops
        .iter()
        .filter(|o| o.kind == "task")
        .map(|o| o.status.as_deref())
        .collect();
    assert_eq!(st, [Some("accepted"), Some("open")]);
}
