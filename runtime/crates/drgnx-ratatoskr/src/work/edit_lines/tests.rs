//! Edit lines and read ranges from ACP content: every case pure (pattern D), the providers' shapes as the mock sends
//! them.

use super::*;
use serde_json::json;

fn range(line: u32, line_end: u32, col: u32) -> Result<EditRange, NoUniqueMatch> {
    Ok(EditRange {
        line,
        line_end,
        col,
    })
}

/// Pattern D. Claude's `Edit` (a fragment): before it lands its `oldText` gives the place; once it landed (the file
/// holds `newText`) the same range comes from `newText`.
#[test]
fn claude_edit_streams_its_range_before_completion() {
    let before = "fn a() {\n    old();\n}\n";
    let (old, new) = ("old();", "new_one();\n    new_two();");
    assert!(!is_whole_file(before, Some(old), new));
    assert_eq!(of_diff(before, Some(old), new, false), range(2, 3, 14));
    let after = "fn a() {\n    new_one();\n    new_two();\n}\n";
    assert_eq!(of_diff(after, Some(old), new, false), range(2, 3, 14));
}

/// Pattern D. Codex sends one `Diff` per hunk: each has its own exact range.
#[test]
fn codex_one_diff_per_hunk_gives_each_range() {
    let text: String = (1..=20).map(|n| format!("l{n}: x\n")).collect();
    let content = json!([
        {"type": "diff", "path": "/w/a.rs", "oldText": "l3: x\n", "newText": "three\n"},
        {"type": "content", "content": {"type": "text", "text": "ignored"}},
        {"type": "diff", "path": "/w/a.rs", "oldText": "l15: x\n", "newText": "fifteen\nfifteen b\n"},
    ]);
    let items = diffs(Some(&content));
    assert_eq!(items.len(), 2, "only the diff items");
    let got: Vec<_> = items
        .iter()
        .map(|(_, o, n)| {
            of_diff(
                &text,
                o.as_deref(),
                n,
                is_whole_file(&text, o.as_deref(), n),
            )
        })
        .collect();
    assert_eq!(got, vec![range(3, 3, 5), range(15, 16, 9)]);
    // the call as a whole sits where its last hunk is
    let call: Vec<_> = items.into_iter().map(|(_, o, n)| (o, n)).collect();
    assert_eq!(of_call(&text, &call), range(15, 16, 9).ok());
}

/// Pattern D. Gemini's diff is the whole file: old against new gives the first to the last changed line, the cursor
/// after the last inserted line.
#[test]
fn gemini_whole_file_diff_gives_the_changed_lines() {
    let old: String = (1..=10).map(|n| format!("a{n}\n")).collect();
    let new = old.replace("a4\n", "B4\n").replace("a7\n", "a7\nNEW\n");
    assert!(is_whole_file(&old, Some(&old), &new));
    assert_eq!(of_diff(&old, Some(&old), &new, true), range(4, 8, 3));
    // a new file (no old text) is all its lines
    assert_eq!(of_diff("", None, "x\nyz\n", true), range(1, 2, 2));
    // the same text again changes nothing
    assert_eq!(of_diff(&old, Some(&old), &old, true), Err(NoUniqueMatch));
}

/// Pattern D. A fragment found twice, or found nowhere (neither old nor new), names no lines.
#[test]
fn no_unique_match_is_file_only() {
    let text = "x();\nx();\n";
    assert_eq!(
        of_diff(text, Some("x();"), "y();", false),
        Err(NoUniqueMatch)
    );
    assert_eq!(
        of_diff("a\n", Some("gone"), "never", false),
        Err(NoUniqueMatch)
    );
    assert_eq!(of_diff("a\n", Some(""), "b", false), Err(NoUniqueMatch));
}

/// Pattern D. The cursor sits after the last inserted character: on the line's own column for a one-line change, on
/// the last inserted line for several, before a closing line break, counted in characters.
#[test]
fn col_is_after_the_last_inserted_character() {
    assert_eq!(
        of_diff("let x = foo(1);\n", Some("foo(1)"), "foo(1, 2)", false),
        range(1, 1, 17)
    );
    assert_eq!(
        of_diff("p\nq\nold\n", Some("old\n"), "a\nbc\n", false),
        range(3, 4, 2)
    );
    assert_eq!(of_diff("é = 1;\n", Some("1"), "été", false), range(1, 1, 7));
    // a deletion: the cursor stays where the text was
    assert_eq!(of_diff("ab cd\n", Some(" cd"), "", false), range(1, 1, 2));
}

/// Pattern D. A CRLF file counts its lines as LF does.
#[test]
fn crlf_text_counts_lines_as_lf() {
    let text = "a\r\nb\r\nold\r\n";
    assert_eq!(of_diff(text, Some("old"), "new", false), range(3, 3, 3));
    assert_eq!(
        of_diff(text, Some("b\r\nold"), "b\r\nnew\r\nmore", false),
        range(2, 4, 4)
    );
}

/// Pattern D. A read's range: its location's line (else its offset) for LIMIT lines; without a limit its line alone;
/// nothing naming a line, none.
#[test]
fn read_with_limit_is_a_range() {
    assert_eq!(
        of_read(&[json!({"path": "/w/a", "line": 10})], None, Some(5)),
        Some((10, 14))
    );
    assert_eq!(of_read(&[], Some(40), Some(10)), Some((40, 49)));
    assert_eq!(of_read(&[], Some(0), None), Some((1, 1)));
    assert_eq!(of_read(&[], None, Some(3)), Some((1, 3)));
    assert_eq!(of_read(&[json!({"path": "/w/a"})], None, None), None);
}
