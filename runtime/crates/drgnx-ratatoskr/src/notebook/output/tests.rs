use base64::Engine as _;
use serde_json::{Value, json};

use super::mime::{Bundle, MAX_SIDE, Shown};
use super::terminal::{Run, Style, Terminal};
use super::*;
use crate::notebook::wire::Message;

fn term(s: &str) -> Terminal {
    let mut t = Terminal::default();
    t.push(s);
    t
}

#[test]
fn a_carriage_return_overwrites_and_a_backspace_backs_up() {
    assert_eq!(term("abc\rX").text(), "Xbc");
    assert_eq!(term("10%\r50%\r100%").text(), "100%");
    assert_eq!(term("abc\x08\x08XY").text(), "aXY");
    assert_eq!(term("line1\nline2\rL").text(), "line1\nLine2");
    assert_eq!(term("a\r\nb").text(), "a\nb");
    // the whole bar is one line, however many messages it came in
    let mut t = Terminal::default();
    for i in 0..100 {
        t.push(&format!("\r{i:3}%"));
    }
    assert_eq!(t.text(), " 99%");
    assert_eq!(t.len(), 4);
    // a backspace at the start stays there; other controls go
    assert_eq!(term("\x08a\x07b\x00").text(), "ab");
}

#[test]
fn ansi_colours_become_theme_roles_and_unknown_sequences_are_dropped() {
    let (text, runs) = term("\x1b[31mred\x1b[0m plain \x1b[1;94mbright\x1b[0m").render();
    assert_eq!(text, "red plain bright");
    let red = Style {
        fg: Some(1),
        ..Style::default()
    };
    let bright = Style {
        fg: Some(12),
        bold: true,
        ..Style::default()
    };
    assert_eq!(
        runs,
        [
            Run {
                start: 0,
                end: 3,
                style: red
            },
            Run {
                start: 10,
                end: 16,
                style: bright
            }
        ]
    );
    // 256-colour: the first 16 are roles, the rest are none; truecolour has no role; the parameters are consumed
    let (text, runs) = term("\x1b[38;5;9mA\x1b[38;5;200mB\x1b[38;2;1;2;3mC\x1b[0mD").render();
    assert_eq!(text, "ABCD");
    assert_eq!(
        runs,
        [Run {
            start: 0,
            end: 1,
            style: Style {
                fg: Some(9),
                ..Style::default()
            }
        }]
    );
    // cursor movement, title strings and a lone ESC vanish; text around them stays
    assert_eq!(
        term("a\x1b[2Jb\x1b[10;5Hc\x1bXd\x1b]0;title\x07e").text(),
        "abcde"
    );
    // an escape cut by the message boundary still works
    let mut t = Terminal::default();
    t.push("x\x1b[3");
    t.push("2mgreen");
    assert_eq!(
        t.render().1,
        [Run {
            start: 1,
            end: 6,
            style: Style {
                fg: Some(2),
                ..Style::default()
            }
        }]
    );
    // erase to end of line
    assert_eq!(term("hello\r\x1b[Kbye").text(), "bye");
    // a runaway sequence does not swallow the rest forever
    let long = format!("\x1b[{}", "1;".repeat(100));
    assert!(
        term(&format!("{long}zzz")).text().ends_with("zzz")
            || term(&format!("{long}zzz")).text().len() <= 3
    );
}

#[test]
fn styles_are_saved_as_the_ansi_they_came_in_as() {
    let t = term("\x1b[1;31mboom\x1b[0m ok\nnext");
    assert_eq!(t.to_ansi(), "\x1b[0;1;31mboom\x1b[0m ok\nnext");
    assert_eq!(term("plain").to_ansi(), "plain");
}

fn png(w: u32, h: u32) -> Vec<u8> {
    let mut b = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    b.extend(w.to_be_bytes());
    b.extend(h.to_be_bytes());
    b.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
    b
}

fn jpeg(w: u16, h: u16) -> Vec<u8> {
    let mut b = vec![0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8];
    b.extend(h.to_be_bytes());
    b.extend(w.to_be_bytes());
    b.extend([1, 1, 0x11, 0]);
    b
}

fn b64(b: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(b)
}

fn display(data: Value) -> Value {
    json!({"data": data, "metadata": {}})
}

#[test]
fn an_image_is_shown_only_after_its_bytes_check_out() {
    let ok = Bundle::from_message(&display(
        json!({"image/png": b64(&png(640, 480)), "text/plain": "<Figure>"}),
    ));
    assert_eq!(
        ok.shown(),
        &Shown::Image {
            mime: "image/png",
            width: 640,
            height: 480
        }
    );
    assert!(ok.note.is_none());
    assert_eq!(ok.image_bytes("image/png").unwrap(), png(640, 480));
    // kept in the file as the kernel sent it, with its text alternative
    assert_eq!(ok.data()["text/plain"], "<Figure>");
    let j = Bundle::from_message(&display(json!({"image/jpeg": b64(&jpeg(30, 20))})));
    assert_eq!(
        j.shown(),
        &Shown::Image {
            mime: "image/jpeg",
            width: 30,
            height: 20
        }
    );
    // the base64 may carry line breaks
    let broken = b64(&png(2, 2))
        .chars()
        .enumerate()
        .flat_map(|(i, c)| if i % 8 == 7 { vec![c, '\n'] } else { vec![c] })
        .collect::<String>();
    assert!(matches!(
        Bundle::from_message(&display(json!({"image/png": broken}))).shown(),
        Shown::Image { .. }
    ));

    for (what, data, why) in [
        (
            "text that is not an image",
            json!({"image/png": b64(b"hello, not a png at all, no"), "text/plain": "t"}),
            "not a PNG",
        ),
        (
            "a jpeg labelled png",
            json!({"image/png": b64(&jpeg(1, 1)), "text/plain": "t"}),
            "not a PNG",
        ),
        (
            "not base64",
            json!({"image/png": "!!!!", "text/plain": "t"}),
            "base64",
        ),
        (
            "too wide",
            json!({"image/png": b64(&png(MAX_SIDE + 1, 10)), "text/plain": "t"}),
            "over 8192",
        ),
        (
            "zero high",
            json!({"image/jpeg": b64(&jpeg(10, 0)), "text/plain": "t"}),
            "over 8192",
        ),
        (
            "a cut jpeg",
            json!({"image/jpeg": b64(&[0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0]), "text/plain": "t"}),
            "JPEG",
        ),
    ] {
        let b = Bundle::from_message(&display(data));
        assert_eq!(
            b.shown(),
            &Shown::Text {
                text: "t".into(),
                markdown: false
            },
            "{what}"
        );
        assert!(
            b.note.as_deref().unwrap().contains(why),
            "{what}: {:?}",
            b.note
        );
        assert!(
            b.data().get("image/png").is_none() && b.data().get("image/jpeg").is_none(),
            "{what}: a refused image is not kept"
        );
    }
    // over the size cap: refused before it is decoded
    let huge = "A".repeat(7_500_000);
    let b = Bundle::from_message(&display(json!({"image/png": huge, "text/plain": "t"})));
    assert!(b.note.as_deref().unwrap().contains("limit"), "{:?}", b.note);
}

#[test]
fn svg_is_never_shown_but_its_text_alternative_is_and_the_bytes_stay_for_saving() {
    let b = Bundle::from_message(&display(json!({
        "image/svg+xml": "<svg><script>alert(1)</script></svg>", "text/plain": "<Figure>"})));
    assert_eq!(
        b.shown(),
        &Shown::Text {
            text: "<Figure>".into(),
            markdown: false
        }
    );
    assert_eq!(
        b.note.as_deref(),
        Some("SVG output not shown: save as file")
    );
    assert_eq!(b.svg(), Some("<svg><script>alert(1)</script></svg>"));
    // svg alone: nothing to show but the note
    let only = Bundle::from_message(&display(json!({"image/svg+xml": "<svg/>"})));
    assert!(matches!(only.shown(), Shown::Note(_)));
}

#[test]
fn the_richest_shown_type_wins_and_the_rest_are_not_shown() {
    let md = Bundle::from_message(&display(
        json!({"text/markdown": "# hi", "text/plain": "hi"}),
    ));
    assert_eq!(
        md.shown(),
        &Shown::Text {
            text: "# hi".into(),
            markdown: true
        }
    );
    let js = Bundle::from_message(&display(json!({"application/json": {"a": [1, 2]}})));
    assert_eq!(
        js.shown(),
        &Shown::Text {
            text: "{\n  \"a\": [\n    1,\n    2\n  ]\n}".into(),
            markdown: false
        }
    );
    // html and widgets show their text alternative or a line; their bytes are not held
    let html = Bundle::from_message(&display(
        json!({"text/html": "<b>x</b>", "text/plain": "x"}),
    ));
    assert_eq!(
        html.shown(),
        &Shown::Text {
            text: "x".into(),
            markdown: false
        }
    );
    assert!(html.data().get("text/html").is_none());
    let w = Bundle::from_message(&display(
        json!({"application/vnd.jupyter.widget-view+json": {"model_id": "a"}}),
    ));
    assert_eq!(w.shown(), &Shown::Note("[mime type not shown]".into()));
    // a multi-line text may come as a list of strings
    let l = Bundle::from_message(&display(json!({"text/plain": ["a\n", "b"]})));
    assert_eq!(
        l.shown(),
        &Shown::Text {
            text: "a\nb".into(),
            markdown: false
        }
    );
}

fn msg(t: &str, parent: &str, content: Value) -> Message {
    let mut m = Message::request("kernel", t, content);
    m.parent = if parent.is_empty() {
        json!({})
    } else {
        json!({"msg_id": parent})
    };
    m
}

fn iopub(r: &mut Router, t: &str, parent: &str, content: Value) -> Option<Change> {
    r.apply(Channel::Iopub, &msg(t, parent, content))
}

#[test]
fn outputs_are_filed_under_the_cell_they_answer_and_consolidated_per_stream() {
    let mut r = Router::new();
    r.begin("run-1");
    r.begin("run-2");
    assert_eq!(
        iopub(
            &mut r,
            "stream",
            "run-1",
            json!({"name": "stdout", "text": "a"})
        ),
        Some(Change::Run("run-1".into()))
    );
    iopub(
        &mut r,
        "stream",
        "run-1",
        json!({"name": "stdout", "text": "b\n"}),
    );
    iopub(
        &mut r,
        "stream",
        "run-2",
        json!({"name": "stdout", "text": "other"}),
    );
    iopub(
        &mut r,
        "stream",
        "run-1",
        json!({"name": "stderr", "text": "warn"}),
    );
    iopub(
        &mut r,
        "stream",
        "run-1",
        json!({"name": "stdout", "text": "c"}),
    );
    let run = r.run("run-1").unwrap();
    let nb = run.to_nbformat();
    assert_eq!(
        nb.len(),
        3,
        "stdout, stderr, stdout again: only neighbours merge"
    );
    assert_eq!(
        nb[0],
        json!({"output_type": "stream", "name": "stdout", "text": "ab\n"})
    );
    assert_eq!(nb[1]["name"], "stderr");
    assert_eq!(r.run("run-2").unwrap().outputs.len(), 1);
    // results and errors
    iopub(
        &mut r,
        "execute_result",
        "run-1",
        json!({"execution_count": 3, "data": {"text/plain": "42"}, "metadata": {}}),
    );
    iopub(
        &mut r,
        "error",
        "run-1",
        json!({"ename": "ZeroDivisionError", "evalue": "x", "traceback": ["\x1b[31mTrace\x1b[0m", "line"]}),
    );
    let nb = r.run("run-1").unwrap().to_nbformat();
    assert_eq!(nb[3]["output_type"], "execute_result");
    assert_eq!(nb[3]["execution_count"], 3);
    assert_eq!(nb[3]["data"]["text/plain"], "42");
    assert_eq!(nb[4]["output_type"], "error");
    assert_eq!(
        nb[4]["traceback"],
        json!(["\x1b[0;31mTrace\x1b[0m", "line"])
    );
}

#[test]
fn the_reply_sets_the_state_and_an_aborted_cell_is_not_an_error() {
    let mut r = Router::new();
    for id in ["a", "b", "c"] {
        r.begin(id);
    }
    r.apply(
        Channel::Shell,
        &msg(
            "execute_reply",
            "a",
            json!({"status": "ok", "execution_count": 7}),
        ),
    );
    r.apply(
        Channel::Shell,
        &msg(
            "execute_reply",
            "b",
            json!({"status": "error", "execution_count": 8}),
        ),
    );
    r.apply(
        Channel::Shell,
        &msg("execute_reply", "c", json!({"status": "aborted"})),
    );
    assert_eq!(r.run("a").unwrap().status, RunStatus::Ok);
    assert_eq!(r.run("a").unwrap().execution_count, Some(7));
    assert_eq!(r.run("b").unwrap().status, RunStatus::Error);
    assert_eq!(r.run("c").unwrap().status, RunStatus::Aborted);
    assert!(r.run("c").unwrap().outputs.is_empty());
    // an interrupt or restart cancels what is still running, never what finished
    r.begin("d");
    r.cancel("d");
    r.cancel("a");
    assert_eq!(r.run("d").unwrap().status, RunStatus::Cancelled);
    assert_eq!(r.run("a").unwrap().status, RunStatus::Ok);
    // execute_input sets the count while it runs
    r.begin("e");
    iopub(
        &mut r,
        "execute_input",
        "e",
        json!({"code": "1", "execution_count": 9}),
    );
    assert_eq!(r.run("e").unwrap().execution_count, Some(9));
}

#[test]
fn the_answer_to_the_hubs_own_readiness_ping_is_not_the_kernels_log() {
    // the hub asks `kernel_info` again until a status comes; an answer that arrives after the kernel is ready is not news
    let mut r = Router::new();
    assert_eq!(
        r.apply(
            Channel::Shell,
            &msg("kernel_info_reply", "ping", json!({"status": "ok"}))
        ),
        None
    );
    assert_eq!(r.log().count(), 0);
}

#[test]
fn a_message_that_answers_nothing_goes_to_the_log_never_to_a_cell() {
    let mut r = Router::new();
    r.begin("run-1");
    assert_eq!(
        iopub(
            &mut r,
            "stream",
            "",
            json!({"name": "stderr", "text": "kernel says hi"})
        ),
        Some(Change::Log)
    );
    assert_eq!(
        iopub(
            &mut r,
            "stream",
            "someone-elses-request",
            json!({"name": "stdout", "text": "x"})
        ),
        Some(Change::Log)
    );
    assert!(r.run("run-1").unwrap().outputs.is_empty());
    let log: Vec<_> = r.log().collect();
    assert_eq!(log.len(), 2);
    assert_eq!(log[0].text, "kernel says hi");
    // status messages are not output at all
    assert_eq!(
        iopub(
            &mut r,
            "status",
            "run-1",
            json!({"execution_state": "busy"})
        ),
        None
    );
    // the log is bounded
    for i in 0..(LOG_ENTRIES + 20) {
        iopub(
            &mut r,
            "stream",
            "",
            json!({"name": "stdout", "text": format!("{i}")}),
        );
    }
    assert_eq!(r.log().count(), LOG_ENTRIES);
    iopub(
        &mut r,
        "stream",
        "",
        json!({"name": "stdout", "text": "z".repeat(LOG_TEXT * 3)}),
    );
    assert_eq!(r.log().last().unwrap().text.len(), LOG_TEXT);
}

#[test]
fn a_display_is_updated_in_place_by_its_id_and_clear_output_clears() {
    let mut r = Router::new();
    r.begin("run-1");
    let with_id = |text: &str| json!({"data": {"text/plain": text}, "metadata": {}, "transient": {"display_id": "d1"}});
    iopub(&mut r, "display_data", "run-1", with_id("0%"));
    iopub(
        &mut r,
        "stream",
        "run-1",
        json!({"name": "stdout", "text": "between\n"}),
    );
    assert_eq!(
        iopub(&mut r, "update_display_data", "run-1", with_id("50%")),
        Some(Change::Run("run-1".into()))
    );
    iopub(&mut r, "update_display_data", "run-1", with_id("100%"));
    let nb = r.run("run-1").unwrap().to_nbformat();
    assert_eq!(
        nb.len(),
        2,
        "the update rewrote the output, it did not add one"
    );
    assert_eq!(nb[0]["data"]["text/plain"], "100%");
    // an update for an id nobody displayed is nothing
    let other = json!({"data": {"text/plain": "?"}, "transient": {"display_id": "nope"}});
    assert_eq!(iopub(&mut r, "update_display_data", "run-1", other), None);
    // clear_output now
    iopub(&mut r, "clear_output", "run-1", json!({"wait": false}));
    assert!(r.run("run-1").unwrap().outputs.is_empty());
    assert_eq!(
        iopub(&mut r, "update_display_data", "run-1", with_id("late")),
        None,
        "its display is gone"
    );
    // clear_output(wait=True): the old output stays until the next one arrives
    iopub(
        &mut r,
        "stream",
        "run-1",
        json!({"name": "stdout", "text": "old"}),
    );
    iopub(&mut r, "clear_output", "run-1", json!({"wait": true}));
    assert_eq!(r.run("run-1").unwrap().outputs.len(), 1);
    iopub(
        &mut r,
        "stream",
        "run-1",
        json!({"name": "stdout", "text": "new"}),
    );
    let nb = r.run("run-1").unwrap().to_nbformat();
    assert_eq!((nb.len(), nb[0]["text"].as_str()), (1, Some("new")));
}

#[test]
fn a_cell_holds_at_most_64_outputs_and_a_megabyte_of_text_and_says_so() {
    let mut r = Router::new();
    r.begin("many");
    for i in 0..(MAX_OUTPUTS + 10) {
        iopub(
            &mut r,
            "display_data",
            "many",
            json!({"data": {"text/plain": format!("{i}")}}),
        );
    }
    let run = r.run("many").unwrap();
    assert_eq!(run.outputs.len(), MAX_OUTPUTS);
    assert!(run.truncated);

    r.begin("text");
    let chunk = "x".repeat(200_000);
    for _ in 0..8 {
        iopub(
            &mut r,
            "stream",
            "text",
            json!({"name": "stdout", "text": chunk}),
        );
    }
    let run = r.run("text").unwrap();
    let held: usize = run
        .outputs
        .iter()
        .map(Output::to_nbformat)
        .map(|o| o["text"].as_str().unwrap().len())
        .sum();
    assert_eq!(
        held,
        MAX_TEXT - "stdout".len(),
        "cut at the cap, not past it"
    );
    assert!(run.truncated);
    // a result too big for what is left is dropped whole
    iopub(
        &mut r,
        "execute_result",
        "text",
        json!({"data": {"text/plain": "y".repeat(1000)}, "execution_count": 1}),
    );
    assert_eq!(r.run("text").unwrap().outputs.len(), 1);
}

// ---- the security review's findings (T11b, 2026-11-14) ----

fn png_of(w: u32, h: u32, size: usize) -> String {
    let mut b = png(w, h);
    b.resize(size, 0);
    b64(&b)
}

#[test]
fn every_retained_string_counts_toward_the_text_cap() {
    let big = "m".repeat(600_000);
    let mut r = Router::new();
    // metadata: two displays of 600 KB metadata do not both fit in a megabyte
    r.begin("meta");
    for _ in 0..2 {
        iopub(
            &mut r,
            "display_data",
            "meta",
            json!({"data": {"text/plain": "x"}, "metadata": {"k": big}}),
        );
    }
    assert_eq!(r.run("meta").unwrap().outputs.len(), 1);
    assert!(r.run("meta").unwrap().truncated);
    // the display id is held twice (in the output and in the map): counted
    r.begin("ids");
    for i in 0..4 {
        let id = format!("{i}{}", "d".repeat(300_000));
        iopub(
            &mut r,
            "display_data",
            "ids",
            json!({"data": {"text/plain": "x"}, "transient": {"display_id": id}}),
        );
    }
    assert!(
        r.run("ids").unwrap().outputs.len() <= 3,
        "{}",
        r.run("ids").unwrap().outputs.len()
    );
    assert!(r.run("ids").unwrap().truncated);
    // error name and value
    r.begin("err");
    for _ in 0..2 {
        iopub(
            &mut r,
            "error",
            "err",
            json!({"ename": big, "evalue": "v", "traceback": []}),
        );
    }
    assert_eq!(r.run("err").unwrap().outputs.len(), 1);
    // a stream's name is short
    r.begin("name");
    iopub(
        &mut r,
        "stream",
        "name",
        json!({"name": "n".repeat(10_000), "text": "t"}),
    );
    let nb = r.run("name").unwrap().to_nbformat();
    assert_eq!(nb[0]["name"].as_str().unwrap().len(), 64);
}

#[test]
fn images_are_capped_per_cell_in_total() {
    let mut r = Router::new();
    r.begin("img");
    // 4.5 MiB each (under the single-image cap): two fit in 16 MiB, not three
    let img = png_of(100, 100, 4_718_592);
    for _ in 0..4 {
        iopub(
            &mut r,
            "display_data",
            "img",
            json!({"data": {"image/png": img.clone(), "text/plain": "p"}}),
        );
    }
    let run = r.run("img").unwrap();
    assert_eq!(run.outputs.len(), 2);
    assert!(run.truncated);
}

#[test]
fn an_update_cannot_grow_a_display_past_the_caps_and_a_smaller_one_gives_the_room_back() {
    let mut r = Router::new();
    r.begin("u");
    let with =
        |text: String| json!({"data": {"text/plain": text}, "transient": {"display_id": "d"}});
    iopub(&mut r, "display_data", "u", with("small".into()));
    iopub(
        &mut r,
        "update_display_data",
        "u",
        // two representations of 600 KB: 1.2 MB held, over the megabyte
        json!({"data": {"text/plain": "x".repeat(600_000), "text/markdown": "y".repeat(600_000)},
               "transient": {"display_id": "d"}}),
    );
    let run = r.run("u").unwrap();
    assert_eq!(
        run.to_nbformat()[0]["data"]["text/plain"],
        "small",
        "the old one stays"
    );
    assert!(run.truncated);
    // grow to near the cap, shrink, and a second big display fits
    r.begin("v");
    iopub(&mut r, "display_data", "v", with("y".repeat(400_000)));
    iopub(&mut r, "update_display_data", "v", with("tiny".into()));
    iopub(
        &mut r,
        "display_data",
        "v",
        json!({"data": {"text/plain": "z".repeat(400_000)}}),
    );
    assert_eq!(r.run("v").unwrap().outputs.len(), 2);
}

#[test]
fn a_traceback_of_a_million_empty_entries_is_cut_to_a_few_hundred() {
    let mut r = Router::new();
    r.begin("t");
    let tb: Vec<Value> = (0..1_000_000).map(|_| json!("")).collect();
    iopub(
        &mut r,
        "error",
        "t",
        json!({"ename": "E", "evalue": "v", "traceback": tb}),
    );
    let nb = r.run("t").unwrap().to_nbformat();
    assert!(nb[0]["traceback"].as_array().unwrap().len() <= MAX_TRACEBACK);
}

#[test]
fn the_kernel_log_keeps_a_short_message_type() {
    let mut r = Router::new();
    let mut m = Message::request("k", "stream", json!({"name": "stdout", "text": "x"}));
    m.header.msg_type = "t".repeat(1_000_000);
    r.apply(Channel::Iopub, &m);
    assert_eq!(r.log().next().unwrap().msg_type.len(), LOG_TYPE);
}

#[test]
fn erasing_gives_the_text_budget_back() {
    let mut r = Router::new();
    r.begin("e");
    iopub(
        &mut r,
        "stream",
        "e",
        json!({"name": "stdout", "text": "x".repeat(900_000)}),
    );
    // a progress bar redrawn: erase the line each time
    iopub(
        &mut r,
        "stream",
        "e",
        json!({"name": "stdout", "text": "\r\x1b[K"}),
    );
    iopub(
        &mut r,
        "stream",
        "e",
        json!({"name": "stdout", "text": "y".repeat(500_000)}),
    );
    let nb = r.run("e").unwrap().to_nbformat();
    assert_eq!(
        nb[0]["text"].as_str().unwrap().len(),
        500_000,
        "the new chunk was kept whole"
    );
    assert!(!r.run("e").unwrap().truncated);
}

#[test]
fn a_huge_number_of_lines_is_counted_not_walked_and_unsafe_characters_never_reach_the_view() {
    let t = term(&"\x1b[31mx\x1b[0m\n".repeat(400_000));
    assert_eq!(t.line_count(), 400_001);
    let head = t.head(3);
    assert_eq!(head.len(), 3);
    assert_eq!(head[0].0, "x");
    assert_eq!(
        head[0].1,
        [Run {
            start: 0,
            end: 1,
            style: Style {
                fg: Some(1),
                ..Style::default()
            }
        }]
    );
    // bidi controls and the object replacement character are dropped from terminal text
    assert_eq!(term("a\u{202e}b\u{fffc}c\u{2066}d").text(), "abcd");
}

#[test]
fn an_image_over_sixteen_megapixels_is_refused_even_when_each_side_is_allowed() {
    let b = Bundle::from_message(&display(
        json!({"image/png": b64(&png(8000, 8000)), "text/plain": "t"}),
    ));
    assert!(matches!(b.shown(), Shown::Text { .. }));
    assert!(
        b.note.as_deref().unwrap().contains("megapixel"),
        "{:?}",
        b.note
    );
    let ok = Bundle::from_message(&display(json!({"image/png": b64(&png(4000, 4000))})));
    assert!(matches!(ok.shown(), Shown::Image { .. }));
}

#[test]
fn the_svg_note_offers_a_save_only_when_the_svg_was_kept() {
    let big = "s".repeat(2_000_000);
    let b = Bundle::from_message(&display(json!({"image/svg+xml": big, "text/plain": "t"})));
    assert_eq!(b.svg(), None);
    assert_eq!(b.note.as_deref(), Some("SVG output too large to keep"));
    let ok = Bundle::from_message(&display(
        json!({"image/svg+xml": "<svg/>", "text/plain": "t"}),
    ));
    assert_eq!(
        ok.note.as_deref(),
        Some("SVG output not shown: save as file")
    );
}

#[test]
fn text_shown_has_no_control_or_bidi_characters_but_the_file_keeps_what_the_kernel_sent() {
    let raw = "a\u{202e}b\u{fffc}c\x1b[31m\u{200f}d";
    let b = Bundle::from_message(&display(json!({"text/plain": raw})));
    assert_eq!(
        b.shown(),
        &Shown::Text {
            text: "abc[31md".into(),
            markdown: false
        }
    );
    assert_eq!(b.data()["text/plain"], raw);
}

#[test]
fn a_file_is_as_untrusted_as_a_kernel_and_its_outputs_go_through_the_same_caps() {
    use crate::notebook::output::file::{MAX_RAW_OUTPUT, from_nbformat_raw};
    // a traceback of two million empty entries builds two hundred
    let raw = format!(
        r#"{{"output_type": "error", "ename": "E", "evalue": "v", "traceback": [{}""]}}"#,
        r#""","#.repeat(2_000_000)
    );
    let Some(Output::Error { traceback, .. }) = from_nbformat_raw(&raw) else {
        panic!("not an error output")
    };
    assert!(traceback.len() <= MAX_TRACEBACK);
    // an output too large to read is a line saying so
    let huge = format!(
        r#"{{"output_type": "stream", "name": "stdout", "text": "{}"}}"#,
        "x".repeat(MAX_RAW_OUTPUT)
    );
    let Some(Output::Display { bundle, .. }) = from_nbformat_raw(&huge) else {
        panic!("not a note")
    };
    assert!(
        matches!(bundle.shown(), Shown::Text { text, .. } if text.contains("too large to load"))
    );
    // the list form of a stream's text, and a name that is too long
    let s = r#"{"output_type": "stream", "name": "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn", "text": ["a\n", "b"]}"#;
    let Some(Output::Stream { name, text }) = from_nbformat_raw(s) else {
        panic!("not a stream")
    };
    assert_eq!((name.len(), text.text().as_str()), (MAX_NAME, "a\nb"));
    assert!(from_nbformat_raw(r#"{"output_type": "mystery"}"#).is_none());
    // the run's caps: 100 outputs keep 64 and say so; text past the cap is dropped whole
    let many: Vec<Output> = (0..100)
        .map(|_| {
            from_nbformat_raw(r#"{"output_type": "stream", "name": "a", "text": "t"}"#).unwrap()
        })
        .collect();
    let run = CellRun::from_outputs("r", many, RunStatus::Ok);
    assert_eq!(run.outputs.len(), MAX_OUTPUTS);
    assert!(run.truncated);
}

#[test]
fn a_text_the_view_shows_as_it_was_sent_is_held_once() {
    let mut r = Router::new();
    r.begin("t");
    iopub(
        &mut r,
        "display_data",
        "t",
        json!({"data": {"text/plain": "x".repeat(700_000)}}),
    );
    assert_eq!(
        r.run("t").unwrap().outputs.len(),
        1,
        "700 KB fits a megabyte"
    );
    assert!(!r.run("t").unwrap().truncated);
}
