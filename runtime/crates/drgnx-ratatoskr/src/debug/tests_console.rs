//! The debug console's lines (`console.rs`): splitting, ANSI, counting, groups, the queue's cap.

use super::console::{BATCH_BYTES, Console, QUEUE_CAP};
use serde_json::{Value, json};

fn out(cat: &str, text: &str) -> Value {
    json!({"category": cat, "output": text})
}

fn texts(batch: &Value) -> Vec<String> {
    batch["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["text"].as_str().unwrap().to_owned())
        .collect()
}

/// Output is split into lines; a line without its newline waits for the rest (the next event of its category), or
/// goes as it is when the session ends.
#[test]
fn output_splits_into_lines_and_waits_for_the_newline() {
    let mut c = Console::default();
    c.output(&out("stdout", "one\ntw"), false);
    c.output(&out("stdout", "o\nthr"), false);
    let b = c.take(false).unwrap();
    assert_eq!(texts(&b), ["one", "two"]);
    assert_eq!(b["lines"][0]["category"], "stdout");
    assert!(c.take(false).is_none());
    assert_eq!(texts(&c.take(true).unwrap()), ["thr"]);
}

/// ANSI SGR becomes face runs in characters (colours, bold, reset; 256-colour's first 16), carried across events;
/// other escapes go. Only for stdout/stderr or an adapter with `supportsANSIStyling`.
#[test]
fn ansi_sgr_becomes_face_runs() {
    let mut c = Console::default();
    c.output(
        &out("stdout", "a \u{1b}[31;1mré\u{1b}[0m b\u{1b}[2K\n"),
        false,
    );
    c.output(&out("stdout", "\u{1b}[38;5;12mx\n"), false);
    c.output(&out("stdout", "y\u{1b}[39m z\n"), false);
    c.output(&out("console", "\u{1b}[31mraw\n"), false);
    let b = c.take(false).unwrap();
    let l = &b["lines"];
    assert_eq!(l[0]["text"], "a ré b");
    assert_eq!(
        l[0]["runs"],
        json!([
            [2, 4, "drgnx-debug-console-red"],
            [2, 4, "drgnx-debug-console-bold"]
        ])
    );
    assert_eq!(
        l[1]["runs"],
        json!([[0, 1, "drgnx-debug-console-bright-blue"]])
    );
    assert_eq!(
        l[2]["runs"],
        json!([[0, 1, "drgnx-debug-console-bright-blue"]]),
        "carried to the next event"
    );
    assert_eq!(
        l[3]["text"], "\u{1b}[31mraw",
        "a console message without the capability is text"
    );
    let mut c = Console::default();
    c.output(&out("console", "\u{1b}[32mok\n"), true);
    assert_eq!(
        c.take(false).unwrap()["lines"][0]["runs"],
        json!([[0, 2, "drgnx-debug-console-green"]])
    );
}

/// Identical consecutive lines are one line with a count; one that continues the last batch's line says so.
#[test]
fn identical_lines_are_counted() {
    let mut c = Console::default();
    c.output(&out("stdout", "tick\ntick\ntick\ntock\n"), false);
    let b = c.take(false).unwrap();
    assert_eq!(texts(&b), ["tick", "tock"]);
    assert_eq!(b["lines"][0]["count"], 3);
    c.output(&out("stdout", "tock\ntock\n"), false);
    let b = c.take(false).unwrap();
    assert_eq!(b["lines"][0]["more"], true);
    assert_eq!(b["lines"][0]["count"], 2);
    c.output(&out("stderr", "tock\n"), false);
    assert!(
        c.take(false).unwrap()["lines"][0].get("more").is_none(),
        "another category is another line"
    );
}

/// `group` start and end indent the lines between them; a group's own text is its header line; categories,
/// logpoint sources and structured values come with their lines; telemetry stays out.
#[test]
fn groups_categories_sources_and_values() {
    let mut c = Console::default();
    c.output(
        &json!({"category": "console", "output": "Group", "group": "start"}),
        false,
    );
    c.output(&out("stdout", "inside\n"), false);
    c.output(
        &json!({"category": "console", "output": "", "group": "end"}),
        false,
    );
    c.output(&out("stdout", "after\n"), false);
    c.output(&json!({"category": "telemetry", "output": "x\n"}), false);
    c.output(&json!({"category": "console", "output": "hit 3\n", "source": {"path": "/p/a.py"}, "line": 12}), false);
    c.output(
        &json!({"category": "stdout", "output": "obj\n", "variablesReference": 9}),
        false,
    );
    let b = c.take(false).unwrap();
    assert_eq!(texts(&b), ["Group", "inside", "after", "hit 3", "obj"]);
    let l = &b["lines"];
    assert!(l[0].get("depth").is_none());
    assert_eq!(l[1]["depth"], 1);
    assert!(l[2].get("depth").is_none());
    assert_eq!(l[3]["source"], json!({"path": "/p/a.py", "line": 12}));
    assert_eq!(l[4]["node"], json!({"reference": 9}));
}

/// A batch goes at once past 64 KiB; past 4 MB the oldest lines go and the batch says how many.
#[test]
fn the_queue_is_capped() {
    let mut c = Console::default();
    let line = "x".repeat(1000);
    let mut n = 0;
    while !c.full() {
        c.output(&out("stdout", &format!("{line}{n}\n")), false);
        n += 1;
    }
    // each line counts its text and 64 bytes for what goes with it
    assert!(
        n * 1070 >= BATCH_BYTES && (n - 1) * 1064 < BATCH_BYTES,
        "{n} lines"
    );
    for i in 0..(QUEUE_CAP / 1000 + 500) {
        c.output(&out("stdout", &format!("{line}{i}\n")), false);
    }
    let b = c.take(false).unwrap();
    let skipped = b["skipped"].as_u64().unwrap();
    assert!(skipped >= 500, "{skipped}");
    let kept = b["lines"].as_array().unwrap().len();
    assert!(kept * 1064 <= QUEUE_CAP);
    assert!(
        texts(&b)
            .last()
            .unwrap()
            .ends_with(&format!("{}", QUEUE_CAP / 1000 + 499))
    );
}
