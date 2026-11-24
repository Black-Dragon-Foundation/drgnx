use serde_json::json;

use super::*;
use crate::notebook::output::{Change, Router};
use crate::notebook::session::Channel;
use crate::notebook::wire::Message;

fn run_with(feed: impl FnOnce(&mut dyn FnMut(&str, serde_json::Value))) -> CellRun {
    let mut r = Router::new();
    r.begin("r");
    feed(&mut |t, c| {
        let mut m = Message::request("k", t, c);
        m.parent = json!({"msg_id": "r"});
        let ch = if t == "execute_reply" {
            Channel::Shell
        } else {
            Channel::Iopub
        };
        assert_eq!(r.apply(ch, &m), Some(Change::Run("r".into())));
    });
    r.run("r").unwrap().clone()
}

#[test]
fn a_stream_is_text_with_its_style_runs_and_carries_its_version() {
    let run = run_with(|f| {
        f(
            "stream",
            json!({"name": "stdout", "text": "ok \x1b[31mbad\x1b[0m\nnext"}),
        )
    });
    let t = build("cell-1", &run, 7);
    assert_eq!((t.cell.as_str(), t.version, t.more_lines), ("cell-1", 7, 0));
    assert_eq!(t.text, "ok bad\nnext");
    assert_eq!(
        t.runs,
        [Run {
            start: 3,
            end: 6,
            style: Style {
                fg: Some(1),
                ..Style::default()
            }
        }]
    );
    assert!(t.images.is_empty());
    // no output: an empty tail
    assert_eq!(build("c", &run_with(|_| {}), 1).text, "");
}

#[test]
fn a_long_output_is_cut_to_twenty_rows_with_one_row_saying_how_many_more() {
    let text: String = (0..30).map(|i| format!("line {i}\n")).collect();
    let run = run_with(|f| f("stream", json!({"name": "stdout", "text": text})));
    let t = build("c", &run, 1);
    let rows: Vec<&str> = t.text.split('\n').collect();
    // 31 lines (the last empty), 20 kept
    assert_eq!(rows.len(), 21);
    assert_eq!(rows[19], "line 19");
    assert_eq!(rows[20], "11 more lines: open output");
    assert_eq!(t.more_lines, 11);
}

#[test]
fn the_byte_cap_cuts_rows_and_even_one_row_too_long() {
    let text: String = (0..15).map(|_| format!("{}\n", "x".repeat(1000))).collect();
    let t = build(
        "c",
        &run_with(|f| f("stream", json!({"name": "stdout", "text": text}))),
        1,
    );
    assert!(t.text.len() <= MAX_BYTES + 40, "{}", t.text.len());
    assert!(t.more_lines > 0 && t.text.ends_with("more lines: open output"));
    let one = build(
        "c",
        &run_with(|f| {
            f(
                "stream",
                json!({"name": "stdout", "text": "y".repeat(100_000)}),
            )
        }),
        1,
    );
    assert!(one.text.len() <= MAX_BYTES + 1);
}

#[test]
fn an_image_is_one_character_with_its_entry_and_svg_gets_its_note() {
    use base64::Engine as _;
    let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    png.extend(10u32.to_be_bytes());
    png.extend(20u32.to_be_bytes());
    png.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
    let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
    let run = run_with(|f| {
        f("stream", json!({"name": "stdout", "text": "before"}));
        f(
            "display_data",
            json!({"data": {"image/png": b64, "text/plain": "<Figure>"}}),
        );
        f(
            "display_data",
            json!({"data": {"image/svg+xml": "<svg/>", "text/plain": "<Fig2>"}}),
        );
    });
    let t = build("c", &run, 1);
    assert_eq!(
        t.text,
        format!("before\n{IMAGE_CHAR}\n<Fig2>\nSVG output not shown: save as file")
    );
    assert_eq!(
        t.images,
        [TailImage {
            at: 7,
            output: 1,
            mime: "image/png".into(),
            width: 10,
            height: 20
        }]
    );
    assert_eq!(t.text.chars().nth(7), Some(IMAGE_CHAR));
}

#[test]
fn an_error_has_its_head_row_and_traceback_and_an_aborted_or_cancelled_cell_says_so() {
    let run = run_with(|f| {
        f(
            "error",
            json!({"ename": "ValueError", "evalue": "bad", "traceback": ["\x1b[31mTrace\x1b[0m here", "last"]}),
        );
    });
    let t = build("c", &run, 1);
    assert_eq!(t.text, "ValueError: bad\nTrace here\nlast");
    assert_eq!(t.runs.len(), 2, "the head and the coloured word");
    assert_eq!(
        t.runs[1],
        Run {
            start: 16,
            end: 21,
            style: Style {
                fg: Some(1),
                ..Style::default()
            }
        }
    );
    let aborted = run_with(|f| f("execute_reply", json!({"status": "aborted"})));
    assert_eq!(build("c", &aborted, 1).text, "aborted");
    let mut r = Router::new();
    r.begin("q");
    r.cancel("q");
    assert_eq!(build("c", r.run("q").unwrap(), 1).text, "cancelled");
}

#[test]
fn half_a_million_styled_lines_cost_only_the_rows_shown() {
    let text = "\x1b[31mx\x1b[0m\n".repeat(400_000);
    let run = run_with(|f| f("stream", json!({"name": "stdout", "text": text})));
    // built on a thread that is waited for with a deadline: a build that walks every line fails the test instead of hanging it
    let slot = std::sync::Arc::new(std::sync::Mutex::new(None));
    let s2 = slot.clone();
    std::thread::spawn(move || *saman::lock(&s2) = Some(build("c", &run, 1)));
    let t = skuld::wait_until("the tail", 20, || saman::lock(&slot).take());
    assert_eq!(t.more_lines, 400_001 - MAX_ROWS);
    assert!(
        t.text
            .ends_with(&format!("{} more lines: open output", 400_001 - MAX_ROWS))
    );
    assert_eq!(t.runs.len(), MAX_ROWS);
    assert_eq!(
        t.runs[1].start, 2,
        "the second row's run starts after the first row and its newline"
    );
}

#[test]
fn an_error_value_of_many_lines_is_capped_like_any_other_row_and_its_text_is_clean() {
    let evalue = (0..60)
        .map(|i| format!("line {i}"))
        .collect::<Vec<_>>()
        .join("\n");
    let run = run_with(|f| {
        f(
            "error",
            json!({"ename": "E", "evalue": evalue, "traceback": []}),
        )
    });
    let t = build("c", &run, 1);
    assert_eq!(
        t.text.split('\n').count(),
        MAX_ROWS + 1,
        "twenty rows and the more-lines row"
    );
    assert_eq!(t.more_lines, 40);
    let run = run_with(|f| {
        f(
            "error",
            json!({"ename": "E\u{202e}", "evalue": "v\u{fffc}\x1b[0m", "traceback": []}),
        )
    });
    assert_eq!(build("c", &run, 1).text, "E: v[0m");
}

#[test]
fn a_tail_has_the_execution_count_and_a_head_shows_the_prompt_the_kind_and_the_state() {
    use hrafn::notebook::Kind;
    let run = run_with(|f| {
        f(
            "execute_reply",
            json!({"status": "ok", "execution_count": 7}),
        )
    });
    assert_eq!(build("c", &run, 1).execution_count, Some(7));
    let h = head(Kind::Code, "python", Some(7), "idle");
    assert_eq!(h.text, "[7]  python");
    assert_eq!(head(Kind::Code, "python", None, "idle").text, "[ ]  python");
    assert_eq!(
        head(Kind::Code, "python", Some(7), "running").text,
        "[*]  python"
    );
    assert_eq!(
        head(Kind::Code, "python", Some(7), "queued").state,
        "queued"
    );
    assert_eq!(head(Kind::Code, "", None, "idle").text, "[ ]  code");
    assert_eq!(
        head(Kind::Markdown, "python", None, "idle").text,
        "markdown"
    );
    assert_eq!(head(Kind::Raw, "x", None, "idle").text, "raw");
    // a language name from a file cannot carry controls or bidi marks into the head
    assert_eq!(
        head(Kind::Code, "py\u{202e}\x1b", None, "idle").text,
        "[ ]  py"
    );
}

/// The parts of a head as (role, text, chip, action).
fn parts(h: &Head) -> Vec<(&str, &str, &str, &str)> {
    h.parts
        .iter()
        .map(|p| (p.role, p.text.as_str(), p.chip, p.action))
        .collect()
}

#[test]
fn a_heads_parts_are_the_run_button_the_count_chip_and_the_language_chip_each_named() {
    use hrafn::notebook::Kind;
    assert_eq!(
        parts(&head(Kind::Code, "python", Some(7), "idle")),
        [
            ("run", "", "", "run"),
            ("count", "[7]", "quiet", ""),
            ("language", "python", "quiet", "")
        ]
    );
    // a queued or running cell has a stop button and an accent count
    for state in ["queued", "running"] {
        assert_eq!(
            parts(&head(Kind::Code, "python", Some(7), state)),
            [
                ("run", "", "", "stop"),
                ("count", "[*]", "accent", ""),
                ("language", "python", "quiet", "")
            ],
            "{state}"
        );
    }
    assert_eq!(
        parts(&head(Kind::Code, "", None, "idle"))[1..],
        [
            ("count", "[ ]", "quiet", ""),
            ("language", "code", "quiet", "")
        ]
    );
    // markdown and raw cells have their kind only
    assert_eq!(
        parts(&head(Kind::Markdown, "python", None, "idle")),
        [("kind", "markdown", "quiet", "")]
    );
    assert_eq!(
        parts(&head(Kind::Raw, "x", None, "idle")),
        [("kind", "raw", "quiet", "")]
    );
    // a language from a file carries no controls or direction marks, and is short
    assert_eq!(
        parts(&head(Kind::Code, "py\u{202e}\x1b", None, "idle"))[2].1,
        "py"
    );
    assert_eq!(
        parts(&head(Kind::Code, &"p".repeat(10_000), None, "idle"))[2]
            .1
            .chars()
            .count(),
        64
    );
}

#[test]
fn a_head_chip_is_short_and_a_tail_carries_a_bounded_number_of_runs() {
    use hrafn::notebook::Kind;
    let h = head(Kind::Code, &"p".repeat(10_000), None, "idle");
    assert_eq!(h.text.chars().count(), "[ ]  ".chars().count() + 64);
    // every other character coloured: rows of hundreds of runs are cut to MAX_RUNS
    let line: String = (0..1000)
        .map(|i| if i % 2 == 0 { "\x1b[31ma\x1b[0m" } else { "b" })
        .collect();
    let run = run_with(|f| {
        f(
            "stream",
            json!({"name": "stdout", "text": format!("{line}\n").repeat(5)}),
        )
    });
    let t = build("c", &run, 1);
    assert_eq!(t.runs.len(), MAX_RUNS);
}

#[test]
fn a_tail_names_the_stream_of_its_output() {
    let stdout = run_with(|f| f("stream", json!({"name": "stdout", "text": "ok"})));
    assert_eq!(build("c", &stdout, 1).stream, "stream");
    let stderr = run_with(|f| f("stream", json!({"name": "stderr", "text": "warn"})));
    assert_eq!(build("c", &stderr, 1).stream, "stderr");
    // a failed run is `error` whatever came before it
    let failed = run_with(|f| {
        f("stream", json!({"name": "stdout", "text": "ok"}));
        f(
            "error",
            json!({"ename": "NameError", "evalue": "x", "traceback": []}),
        )
    });
    assert_eq!(build("c", &failed, 1).stream, "error");
}
