//! The worker driven with a fake clock: frames, rows, backfill, input encodings and styles.
#![cfg(feature = "ghostty")]

use drgnx_rows::{Colour, Op, Patch, Row, Style};
use drgnx_term::frame::Next;
use drgnx_term::proto::{In, Out};
use drgnx_term::worker::{BACKFILL_MAX_BYTES, Opts, Worker};

fn worker(cols: u16, rows: u16, window: usize) -> Worker {
    let mut w = Worker::new(&Opts {
        cols,
        rows,
        cell_px: (10, 20),
        window,
        scrollback: window,
        scrollback_bytes: 64 << 20,
        clipboard_write: true,
    })
    .expect("engine");
    w.handle(
        In::Attach {
            view: "term:1".into(),
            class: "gui".into(),
            hub: 7,
            env_epoch: 1,
        },
        0,
    );
    w
}

fn patches(w: &mut Worker) -> Vec<Patch> {
    w.take_out()
        .into_iter()
        .filter_map(|o| match o {
            Out::Patch { patch } => Some(*patch),
            _ => None,
        })
        .collect()
}

/// The editor's buffer: patches applied in order, as the inserter does.
#[derive(Default)]
struct Model {
    rows: Vec<Row>,
    version: u64,
}

impl Model {
    fn apply(&mut self, p: &Patch) {
        for op in &p.ops {
            match op {
                Op::Reset(rows) => self.rows = rows.clone(),
                Op::Insert { after, rows } => {
                    let at = match after {
                        None => 0,
                        Some(k) => {
                            self.rows
                                .iter()
                                .position(|r| &r.key == k)
                                .expect("insert after a held key")
                                + 1
                        }
                    };
                    for (n, r) in rows.iter().enumerate() {
                        assert!(
                            self.rows.iter().all(|h| h.key != r.key),
                            "key {} inserted twice",
                            r.key
                        );
                        self.rows.insert(at + n, r.clone());
                    }
                }
                Op::Replace(rows) => {
                    for r in rows {
                        let i = self
                            .rows
                            .iter()
                            .position(|h| h.key == r.key)
                            .expect("replace a held key");
                        self.rows[i] = r.clone();
                    }
                }
                Op::Remove(keys) => self.rows.retain(|r| !keys.contains(&r.key)),
            }
        }
        self.version = p.version;
    }

    fn texts(&self) -> Vec<String> {
        self.rows
            .iter()
            .map(|r| r.text.trim_end().to_owned())
            .collect()
    }
}

/// Draw what is due at NOW, apply and acknowledge it; returns the patches.
fn draw(w: &mut Worker, m: &mut Model, now: u64) -> Vec<Patch> {
    w.step(now);
    let ps = patches(w);
    for p in &ps {
        m.apply(p);
        w.handle(In::Ack { version: p.version }, now);
    }
    ps
}

#[test]
fn echo_frame_is_immediate_after_key() {
    let (mut w, mut m) = (worker(20, 4, 100), Model::default());
    draw(&mut w, &mut m, 0);
    w.output(b"a", 100);
    assert_eq!(
        draw(&mut w, &mut m, 100).len(),
        1,
        "first output after a quiet spell draws"
    );
    // output 5 ms later without a key waits for the 16 ms frame
    w.output(b"b", 105);
    assert_eq!(w.next(105), Next::At(116));
    w.step(116);
    let ps = patches(&mut w);
    assert_eq!(ps.len(), 1);
    w.handle(
        In::Ack {
            version: ps[0].version,
        },
        116,
    );
    // a key, then its echo 3 ms later: drawn at once
    w.key("c", 0, "c", 0, 120);
    assert_eq!(w.take_pty(), b"c");
    w.output(b"c", 123);
    assert_eq!(w.next(123), Next::Frame);
}

#[test]
fn flood_sends_screen_only_until_idle() {
    let (mut w, mut m) = (worker(20, 5, 1000), Model::default());
    draw(&mut w, &mut m, 0);
    let mut t = 1000;
    for chunk in 0..5 {
        let text: String = (0..100)
            .map(|i| format!("l{:04}\r\n", chunk * 100 + i))
            .collect();
        w.output(text.as_bytes(), t);
        for p in draw(&mut w, &mut m, t) {
            let rows: usize = p
                .ops
                .iter()
                .map(|o| match o {
                    Op::Insert { rows, .. } | Op::Replace(rows) | Op::Reset(rows) => rows.len(),
                    Op::Remove(_) => 0,
                })
                .sum();
            assert!(
                rows <= 5,
                "a frame during the flood carries the screen only, got {rows} rows"
            );
        }
        t += 50;
        assert!(
            !matches!(w.next(t), Next::Backfill),
            "no backfill while output flows"
        );
    }
    // 100 ms after the last output: the backfill starts
    let last = t - 50;
    assert_eq!(w.next(last + 99), Next::At(last + 100));
    assert_eq!(w.next(last + 100), Next::Backfill);
}

#[test]
fn backfill_chunks_under_40kb_newest_first() {
    let (mut w, mut m) = (worker(80, 5, 10_000), Model::default());
    draw(&mut w, &mut m, 0);
    let text: String = (0..3000)
        .map(|i| format!("line {i:05} {}\r\n", "x".repeat(60)))
        .collect();
    w.output(text.as_bytes(), 1000);
    draw(&mut w, &mut m, 1000);
    let mut t = 1100;
    let mut firsts = Vec::new();
    loop {
        assert!(t < 10_000, "backfill does not end");
        if w.next(t) != Next::Backfill {
            break;
        }
        for p in draw(&mut w, &mut m, t) {
            let size = serde_json::to_vec(&p.ops).unwrap().len();
            assert!(size <= BACKFILL_MAX_BYTES + 1024, "chunk of {size} bytes");
            let Some(Op::Insert { rows, .. }) = p.ops.first() else {
                panic!("a chunk inserts")
            };
            firsts.push(rows[0].text.clone());
        }
        t += 1;
    }
    assert!(
        firsts.len() >= 5,
        "3000 rows of 80 columns take several chunks, got {}",
        firsts.len()
    );
    // newest first: each chunk starts above the last one
    let n: Vec<u32> = firsts.iter().map(|s| s[5..10].parse().unwrap()).collect();
    assert!(
        n.windows(2).all(|p| p[0] > p[1]),
        "chunks newest first: {n:?}"
    );
    let want: Vec<String> = (0..3000)
        .map(|i| format!("line {i:05} {}", "x".repeat(60)))
        .collect();
    let texts = m.texts();
    assert_eq!(
        texts[..3000],
        want[..],
        "the buffer holds every line once, in order"
    );
}

#[test]
fn one_patch_in_flight_until_ack() {
    let mut w = worker(20, 4, 100);
    w.step(0);
    let first = patches(&mut w);
    assert_eq!(first.len(), 1);
    w.output(b"more", 100);
    assert_eq!(
        w.next(100),
        Next::Idle,
        "nothing is drawn while a patch is in flight"
    );
    w.step(100);
    assert!(patches(&mut w).is_empty());
    w.handle(
        In::Ack {
            version: first[0].version + 5,
        },
        101,
    );
    assert_eq!(
        w.next(101),
        Next::Idle,
        "an ack of another version releases nothing"
    );
    w.handle(
        In::Ack {
            version: first[0].version,
        },
        102,
    );
    assert_eq!(w.next(102), Next::Frame);
    let next = {
        w.step(102);
        patches(&mut w)
    };
    assert_eq!(next.len(), 1);
    assert_eq!(next[0].base, first[0].version);
}

#[test]
fn sync_mode_holds_frame_until_reset_or_150ms() {
    let (mut w, mut m) = (worker(20, 4, 100), Model::default());
    draw(&mut w, &mut m, 0);
    w.output(b"\x1b[?2026hx", 1000);
    assert_eq!(w.next(1000), Next::At(1150));
    w.step(1100);
    assert!(patches(&mut w).is_empty(), "held");
    w.output(b"y\x1b[?2026l", 1100);
    assert_eq!(w.next(1100), Next::Frame, "the program let go");
    draw(&mut w, &mut m, 1100);
    assert_eq!(m.texts()[0], "xy");
    // held and never let go: drawn after 150 ms
    w.output(b"\x1b[?2026hz", 2000);
    w.step(2149);
    assert!(patches(&mut w).is_empty());
    assert_eq!(w.next(2150), Next::Frame);
}

#[test]
fn row_keys_survive_scroll() {
    let (mut w, mut m) = (worker(20, 5, 100), Model::default());
    w.output(b"a\r\nb\r\nc\r\nd\r\ne", 0);
    draw(&mut w, &mut m, 0);
    let keys: Vec<String> = m.rows.iter().map(|r| r.key.clone()).collect();
    assert_eq!(m.texts(), ["a", "b", "c", "d", "e"]);
    w.output(b"\r\nf", 100);
    let ps = draw(&mut w, &mut m, 100);
    assert_eq!(ps.len(), 1);
    for op in &ps[0].ops {
        match op {
            Op::Insert { after, rows } => {
                assert_eq!(after.as_deref(), Some(keys[4].as_str()));
                assert_eq!(rows.len(), 1);
            }
            other => panic!("a scroll only inserts, got {other:?}"),
        }
    }
    assert_eq!(m.texts(), ["a", "b", "c", "d", "e", "f"]);
    assert_eq!(
        m.rows[..5]
            .iter()
            .map(|r| r.key.clone())
            .collect::<Vec<_>>(),
        keys
    );
}

#[test]
fn osc52_write_is_reported_as_text() {
    let mut w = worker(30, 2, 10);
    // "from-osc52" in base64
    w.output(b"\x1b]52;c;ZnJvbS1vc2M1Mg==\x07", 0);
    let writes: Vec<_> = w
        .take_out()
        .into_iter()
        .filter_map(|o| match o {
            Out::ClipboardWrite { primary, data, .. } => Some((primary, data)),
            _ => None,
        })
        .collect();
    assert_eq!(writes, vec![(false, "from-osc52".to_owned())]);
}

#[test]
fn resize_sends_reset() {
    let (mut w, mut m) = (worker(20, 5, 100), Model::default());
    w.output(b"hello", 0);
    draw(&mut w, &mut m, 0);
    w.handle(
        In::Resize {
            cols: 10,
            rows: 3,
            cell_px: (10, 20),
        },
        100,
    );
    let ps = draw(&mut w, &mut m, 100);
    assert_eq!(ps.len(), 1);
    assert_eq!(ps[0].base, 0);
    assert!(matches!(ps[0].ops[0], Op::Reset(ref rows) if rows.len() == 3));
}

#[test]
fn eviction_never_renumbers() {
    let (mut w, mut m) = (worker(20, 3, 4), Model::default());
    let mut seen: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut t = 0;
    for i in 0..20 {
        w.output(format!("r{i:02}\r\n").as_bytes(), t);
        draw(&mut w, &mut m, t);
        t += 200;
        while w.next(t) == Next::Backfill {
            draw(&mut w, &mut m, t);
        }
        for r in &m.rows {
            let text = r.text.trim_end().to_owned();
            if text.is_empty() {
                continue;
            }
            if let Some(k) = seen.get(&text) {
                assert_eq!(k, &r.key, "{text} renumbered");
            }
            seen.insert(text, r.key.clone());
        }
        assert!(
            m.rows.len() <= 3 + 4,
            "the window holds at most 4 rows above the screen"
        );
    }
    // 4 rows above the 3-row screen (r18, r19 and the empty line the cursor is on)
    assert_eq!(m.texts(), ["r14", "r15", "r16", "r17", "r18", "r19", ""]);
}

fn typed(w: &mut Worker, key: &str, mods: &[&str], text: &str) -> Vec<u8> {
    w.handle(
        In::Key {
            key: key.into(),
            mods: mods.iter().map(|s| s.to_string()).collect(),
            text: text.into(),
            unshifted: 0,
        },
        0,
    );
    w.take_pty()
}

#[test]
fn kitty_flags_encode_tab_ctrl_i_shift_return() {
    let mut w = worker(20, 4, 10);
    // legacy first: ctrl+i and tab are both a tab
    assert_eq!(typed(&mut w, "i", &["ctrl"], ""), b"\t");
    // CSI > 1 u: disambiguate escape codes (the kitty keyboard protocol)
    w.output(b"\x1b[>1u", 0);
    assert_eq!(typed(&mut w, "tab", &[], ""), b"\t");
    assert_eq!(typed(&mut w, "i", &["ctrl"], ""), b"\x1b[105;5u");
    assert_eq!(typed(&mut w, "return", &["shift"], ""), b"\x1b[13;2u");
    assert_eq!(typed(&mut w, "a", &[], "a"), b"a");
}

#[test]
fn decckm_arrows() {
    let mut w = worker(20, 4, 10);
    assert_eq!(typed(&mut w, "up", &[], ""), b"\x1b[A");
    w.output(b"\x1b[?1h", 0);
    assert_eq!(typed(&mut w, "up", &[], ""), b"\x1bOA");
    assert_eq!(typed(&mut w, "left", &[], ""), b"\x1bOD");
}

#[test]
fn bracketed_paste_wraps() {
    let mut w = worker(20, 4, 10);
    w.handle(In::Paste { text: "hi".into() }, 0);
    assert_eq!(w.take_pty(), b"hi");
    w.output(b"\x1b[?2004h", 0);
    w.handle(In::Paste { text: "hi".into() }, 0);
    assert_eq!(w.take_pty(), b"\x1b[200~hi\x1b[201~");
}

#[test]
fn sgr_mouse_only_while_tracking() {
    let mut w = worker(20, 6, 10);
    let press = In::Mouse {
        kind: "press".into(),
        button: 1,
        col: 2,
        row: 3,
        mods: vec![],
    };
    w.handle(press.clone(), 0);
    assert!(
        w.take_pty().is_empty(),
        "nothing while the program does not track the mouse"
    );
    w.output(b"\x1b[?1000h\x1b[?1006h", 0);
    w.handle(press, 0);
    assert_eq!(w.take_pty(), b"\x1b[<0;3;4M");
}

#[test]
fn rgb_and_ansi_map_to_styles() {
    let (mut w, mut m) = (worker(20, 2, 10), Model::default());
    w.output(
        b"\x1b[31mR\x1b[38;2;1;2;3mG\x1b[38;5;200mP\x1b[1;4mB\x1b[0m.",
        0,
    );
    let ps = draw(&mut w, &mut m, 0);
    let styles = &ps[0].styles;
    let id = |s: Style| {
        styles
            .iter()
            .find(|(_, x)| *x == s)
            .map(|(i, _)| *i)
            .expect("style sent")
    };
    let red = id(Style {
        fg: Colour::Ansi(1),
        ..Style::default()
    });
    let rgb = id(Style {
        fg: Colour::Rgb([1, 2, 3]),
        ..Style::default()
    });
    let cube = id(Style {
        fg: Colour::Rgb([255, 0, 215]),
        ..Style::default()
    });
    let bold = id(Style {
        fg: Colour::Rgb([255, 0, 215]),
        bold: true,
        underline: true,
        ..Style::default()
    });
    let row = &m.rows[0];
    assert_eq!(row.text, "RGPB.");
    assert_eq!(
        row.runs,
        vec![
            (0, 1, format!("s:{red}")),
            (1, 2, format!("s:{rgb}")),
            (2, 3, format!("s:{cube}")),
            (3, 4, format!("s:{bold}")),
        ]
    );
}

#[test]
fn wide_cell_adds_stop() {
    let (mut w, mut m) = (worker(20, 2, 10), Model::default());
    w.output("中a".as_bytes(), 0);
    let ps = draw(&mut w, &mut m, 0);
    let row = &m.rows[0];
    assert_eq!(row.text, "中 a");
    assert_eq!(
        row.stops,
        vec![(1, 20)],
        "the wide character's second cell: a stop at column 2's pixel"
    );
    // the cursor, after the a in column 3, is at the text's index 3
    let term = ps[0]
        .term
        .as_ref()
        .expect("a reset carries the terminal's state");
    assert_eq!(
        (term.cursor.0.as_str(), term.cursor.1),
        (row.key.as_str(), 3)
    );
}

#[test]
fn osc8_link_is_a_row_prop() {
    let (mut w, mut m) = (worker(30, 2, 10), Model::default());
    w.output(
        b"see \x1b]8;;file:///tmp/a.txt\x1b\\a.txt\x1b]8;;\x1b\\ end",
        0,
    );
    draw(&mut w, &mut m, 0);
    let row = &m.rows[0];
    assert_eq!(row.text, "see a.txt end");
    assert_eq!(
        row.props,
        vec![(
            4,
            9,
            "drgnx-term-link".to_owned(),
            serde_json::json!("file:///tmp/a.txt")
        )]
    );
}

#[test]
fn scroll_by_prompts_rows_and_to_the_bottom() {
    let mut w = worker(20, 3, 100);
    let mut m = Model::default();
    let mut now = 0;
    // three prompts (OSC 133 A), each followed by a command's output
    for p in ["one", "two", "three"] {
        // the shell waits at its prompt: the frame sees the cursor on the prompt's row
        w.output(format!("\x1b]133;A\x07$ {p}").as_bytes(), now);
        now += 20;
        draw(&mut w, &mut m, now);
        w.output(b"\r\nout\r\nout\r\n", now);
        now += 20;
        draw(&mut w, &mut m, now);
    }
    // the backfill completes the window
    for _ in 0..5 {
        now += 500;
        draw(&mut w, &mut m, now);
    }
    let key_of = |m: &Model, text: &str| {
        m.rows
            .iter()
            .find(|r| r.text == text)
            .map(|r| r.key.clone())
    };
    let bottom = w.scroll(None, None, None, Some("bottom"));
    assert_eq!(
        bottom,
        m.rows.last().map(|r| r.key.clone()),
        "the cursor's row"
    );
    assert_eq!(w.scroll(None, None, Some(-1), None), key_of(&m, "$ three"));
    assert_eq!(w.scroll(None, None, Some(-3), None), key_of(&m, "$ one"));
    assert_eq!(
        w.scroll(None, None, Some(-4), None),
        None,
        "no fourth prompt"
    );
    let one = key_of(&m, "$ one");
    assert_eq!(
        w.scroll(one.as_deref(), None, Some(1), None),
        key_of(&m, "$ two")
    );
    assert_eq!(
        w.scroll(one.as_deref(), Some(-5), None, None),
        m.rows.first().map(|r| r.key.clone()),
        "clamped"
    );
}

#[test]
fn search_and_text_range_read_beyond_the_window() {
    let mut w = worker(20, 3, 2);
    let mut m = Model::default();
    w.output(b"A1\r\nA2\r\nA3\r\nA4\r\nA5\r\nA6", 0);
    for n in 1..5 {
        draw(&mut w, &mut m, n * 500);
    }
    assert_eq!(w.text_range(None, None), "A1\nA2\nA3\nA4\nA5\nA6");
    let a1 = w.search("A1", true);
    assert_eq!(a1, [(None, 0, 2)], "A1 is beyond the window of 2: no key");
    let a5 = w.search("A5", true);
    assert!(a5[0].0.is_some(), "A5 is in the window: {a5:?}");
    let from = a5[0].0.clone();
    assert_eq!(w.text_range(from.as_deref(), None), "A5\nA6");
    assert_eq!(w.search("A", false).len(), 6);
}

/// One `view-model` a worker sent: base, version, reset, the model's ops.
type Sent = (u64, u64, bool, serde_json::Value);

/// The `view-model`s a worker sent, and its answers.
fn models(w: &mut Worker) -> (Vec<Sent>, Vec<serde_json::Value>) {
    let (mut models, mut answers) = (Vec::new(), Vec::new());
    for o in w.take_out() {
        match o {
            Out::Model { model } => {
                assert_eq!(model["view"], "term:1");
                assert_eq!(model["hub"], 7);
                let ops: serde_json::Value =
                    serde_json::from_str(model["model"].as_str().expect("a string")).expect("JSON");
                models.push((
                    model["base"].as_u64().unwrap(),
                    model["version"].as_u64().unwrap(),
                    model["reset"] == true,
                    ops,
                ));
            }
            Out::Answer { result, .. } => answers.push(result),
            _ => {}
        }
    }
    (models, answers)
}

#[test]
fn search_sends_its_held_matches_as_a_list_model() {
    // pattern D (pure: the worker driven with a fake clock)
    let mut w = worker(20, 3, 2);
    let mut m = Model::default();
    w.output(b"A1\r\nA2\r\nA3\r\nA4\r\nA5\r\nA6", 0);
    for n in 1..5 {
        draw(&mut w, &mut m, n * 500);
    }
    let search = |req| In::Search {
        req,
        query: "A".into(),
        dir: None,
    };
    w.handle(search(1), 3000);
    let (ms, answers) = models(&mut w);
    assert_eq!(ms.len(), 1, "one model per search");
    let (base, version, reset, ops) = &ms[0];
    assert_eq!(
        (*base, *version, *reset),
        (0, 1, true),
        "the first model of a view"
    );
    let r = &ops["ops"][0]["reset"];
    assert_eq!(r["descriptor"]["scheme"], "list");
    assert_eq!(r["lists"][0]["name"], "matches");
    let ids = r["lists"][0]["ids"].as_array().unwrap();
    // A1 is beyond the window of 2: only the held rows' matches, newest first
    let held = w.search("A", true);
    let keyed: Vec<_> = held.iter().filter(|m| m.0.is_some()).collect();
    assert_eq!(ids.len(), keyed.len());
    assert!(
        keyed.len() < held.len(),
        "some matches are in rows the editor lacks"
    );
    let first = r["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == ids[0])
        .expect("the first match's node");
    let field = |name: &str| {
        first["fields"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f[0] == name)
            .map(|f| f[1].clone())
    };
    assert_eq!(field("key"), Some(serde_json::json!(keyed[0].0)));
    assert_eq!(field("col"), Some(serde_json::json!(0)));
    assert_eq!(field("len"), Some(serde_json::json!(1)));
    assert_eq!(
        answers,
        [serde_json::json!({"found": held.len(), "held": keyed.len(), "model": 1})]
    );
    // the next search goes on from it; a model resync resends it and draws no rows
    w.handle(search(2), 3100);
    let (ms, _) = models(&mut w);
    assert_eq!(
        (ms[0].0, ms[0].1, ms[0].2),
        (1, 2, true),
        "each search's model is a reset"
    );
    w.handle(In::Resync { model: true }, 3200);
    let out = w.take_out();
    assert!(out.iter().all(|o| !matches!(o, Out::Patch { .. })));
    let Some(Out::Model { model }) = out.first() else {
        panic!("a model: {out:?}")
    };
    assert_eq!(
        (model["base"].as_u64(), model["version"].as_u64()),
        (Some(2), Some(3))
    );
    assert_eq!(model["reset"], true);
    // attached again (a new editor): its model starts again
    w.handle(
        In::Attach {
            view: "term:1".into(),
            class: "gui".into(),
            hub: 7,
            env_epoch: 1,
        },
        3300,
    );
    w.take_out();
    w.handle(search(3), 3400);
    let (ms, _) = models(&mut w);
    assert_eq!((ms[0].0, ms[0].1), (0, 1));
}

#[test]
fn settings_reach_the_engine() {
    let (mut w, mut m) = (worker(20, 2, 10), Model::default());
    let cfg = |name: &str, v: serde_json::Value| In::Config {
        config: vec![(name.to_string(), v)],
    };
    // the default cursor: a new terminal shows it at once
    w.handle(cfg("cursor-style", serde_json::json!("bar")), 0);
    w.output(b"x", 0);
    let ps = draw(&mut w, &mut m, 0);
    let term = ps
        .iter()
        .rev()
        .find_map(|p| p.term.as_ref())
        .expect("the terminal's state");
    assert_eq!(term.cursor.2, drgnx_rows::CursorShape::Bar);
    assert!(!term.bracketed_paste);
    // ENQ is answered with the setting's text
    w.take_pty();
    w.handle(cfg("enquiry-response", serde_json::json!("drgnx")), 1000);
    w.output(b"\x05", 1000);
    assert_eq!(w.take_pty(), b"drgnx");
    // a program reads the editor's background back (OSC 11)
    w.handle(
        cfg("colours", serde_json::json!(["#102030", "#405060", ""])),
        2000,
    );
    w.output(b"\x1b]11;?\x07", 2000);
    let reply = String::from_utf8_lossy(&w.take_pty()).into_owned();
    assert!(reply.contains("4040/5050/6060"), "{reply:?}");
    // the editor learns the program wants bracketed paste
    w.output(b"\x1b[?2004h", 3000);
    let ps = draw(&mut w, &mut m, 3000);
    assert!(
        ps.iter()
            .rev()
            .find_map(|p| p.term.as_ref())
            .is_some_and(|t| t.bracketed_paste)
    );
}
