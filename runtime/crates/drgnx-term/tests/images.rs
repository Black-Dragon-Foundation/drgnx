//! Images through the worker: kitty, sixel and iTerm2 drawn as canvas files the rows name; the media a remote program
//! may not use; the files' lifetime; animations only while a window shows the terminal.
#![cfg(feature = "ghostty")]

use base64::Engine as _;
use drgnx_rows::{Op, Patch, Row};
use drgnx_term::frame::Next;
use drgnx_term::image::{Pixels, decode_png, encode_png};
use drgnx_term::proto::{In, Out};
use drgnx_term::worker::{Opts, Worker};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const CELL: (u32, u32) = (10, 20);

fn worker(dir: &Path) -> Worker {
    let mut w = Worker::new(&Opts {
        cols: 20,
        rows: 6,
        cell_px: CELL,
        window: 100,
        scrollback: 100,
        img_dir: Some(dir.join("t.img")),
        ..Opts::default()
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

#[derive(Default)]
struct Model {
    rows: Vec<Row>,
}

impl Model {
    fn apply(&mut self, p: &Patch) {
        for op in &p.ops {
            match op {
                Op::Reset(rows) => self.rows = rows.clone(),
                Op::Insert { after, rows } => {
                    let at = after.as_ref().map_or(0, |k| {
                        self.rows.iter().position(|r| &r.key == k).expect("held") + 1
                    });
                    for (n, r) in rows.iter().enumerate() {
                        self.rows.insert(at + n, r.clone());
                    }
                }
                Op::Replace(rows) => {
                    for r in rows {
                        let i = self.rows.iter().position(|h| h.key == r.key).expect("held");
                        self.rows[i] = r.clone();
                    }
                }
                Op::Remove(keys) => self.rows.retain(|r| !keys.contains(&r.key)),
            }
        }
    }

    /// Each row's image slices: (row index, start, end, [file x y w h alt]).
    fn slices(&self) -> Vec<(usize, u32, u32, serde_json::Value)> {
        let mut out = Vec::new();
        for (i, r) in self.rows.iter().enumerate() {
            for p in &r.props {
                if p.2 == "drgnx-term-image" {
                    out.push((i, p.0, p.1, p.3.clone()));
                }
            }
        }
        out
    }

    fn texts(&self) -> Vec<String> {
        self.rows
            .iter()
            .map(|r| r.text.trim_end().to_owned())
            .collect()
    }
}

/// Draw everything due from NOW on, the image helper's work included, applying and acknowledging each patch; the
/// clock moves a frame (20 ms) per round.
fn settle(w: &mut Worker, m: &mut Model, now: u64) {
    settle_until(w, m, now, now);
}

/// `settle`, with the clock kept moving until at least UNTIL (a backfill is due once the output was quiet 100 ms).
fn settle_until(w: &mut Worker, m: &mut Model, now: u64, until: u64) {
    let mut t = now;
    let mut quiet = 0;
    while quiet < 2 {
        w.step(t);
        let mut drew = false;
        for o in w.take_out() {
            if let Out::Patch { patch } = o {
                m.apply(&patch);
                w.handle(
                    In::Ack {
                        version: patch.version,
                    },
                    t,
                );
                drew = true;
            }
        }
        if w.images_busy() {
            w.images(t, true);
            quiet = 0;
        } else if drew {
            quiet = 0;
        } else {
            quiet += 1;
        }
        t += 20;
        if quiet == 2 && t < until {
            quiet = 0;
        }
    }
}

fn png(w: u32, h: u32, rgba: [u8; 4]) -> Vec<u8> {
    encode_png(&Pixels {
        w,
        h,
        rgba: rgba.repeat((w * h) as usize),
    })
}

fn b64(b: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(b)
}

fn canvas(file: &str) -> Pixels {
    decode_png(&std::fs::read(file).expect("canvas file"), 1 << 30).expect("a PNG")
}

#[test]
fn a_kitty_png_is_drawn_as_row_slices_of_a_private_canvas() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    let cmd = format!(
        "\x1b_Ga=T,f=100,q=2;{}\x1b\\after",
        b64(&png(20, 40, [255, 0, 0, 255]))
    );
    w.output(cmd.as_bytes(), 0);
    settle(&mut w, &mut m, 0);
    let s = m.slices();
    assert_eq!(s.len(), 2, "{s:?}");
    assert_eq!((s[0].0, s[1].0), (0, 1));
    let v0 = s[0].3.as_array().unwrap();
    let v1 = s[1].3.as_array().unwrap();
    let file = v0[0].as_str().unwrap().to_owned();
    assert_eq!(v1[0].as_str(), Some(file.as_str()));
    // [file x y w h alt]: one cell row of the 2 × 2 cell canvas each
    assert_eq!(&v0[1..5], &[0, 0, 20, 20].map(serde_json::Value::from));
    assert_eq!(&v1[1..5], &[0, 20, 20, 20].map(serde_json::Value::from));
    assert_eq!(v0[5].as_str(), Some("[image 20×40]"));
    // the slice covers the image's two cells
    assert_eq!((s[0].1, s[0].2), (0, 2));
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(Path::new(&file)), 0o600);
    assert_eq!(mode(&dir.path().join("t.img")), 0o700);
    let c = canvas(&file);
    assert_eq!((c.w, c.h), (20, 40));
    assert_eq!(&c.rgba[..4], &[255, 0, 0, 255]);
    // the text after the image continues on its last row, past it
    assert!(m.texts()[1].ends_with("after"), "{:?}", m.texts());
}

#[test]
fn a_sixel_is_drawn_and_the_output_after_it_follows_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    // 4 × 12 px of blue: two bands; then text, written in the same read
    w.output(b"ab\x1bP0;1;0q#1;2;0;0;100#1~~~~-~~~~\x1b\\cd", 0);
    settle(&mut w, &mut m, 0);
    let s = m.slices();
    assert_eq!(s.len(), 1, "{s:?}");
    let c = canvas(s[0].3[0].as_str().unwrap());
    assert_eq!((c.w, c.h), (10, 20));
    assert_eq!(&c.rgba[..4], &[0, 0, 255, 255]);
    // the image sits after "ab"; the text after it on the row below, at the column the image started in
    assert_eq!((s[0].0, s[0].1, s[0].2), (0, 2, 3));
    assert_eq!(m.texts()[1], "  cd");
}

#[test]
fn decrqss_still_answers_and_a_save_file_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    w.output(b"\x1bP$qm\x1b\\", 0);
    let reply = String::from_utf8(w.take_pty()).unwrap();
    assert!(reply.contains("$r"), "{reply:?}");
    let file = format!(
        "\x1b]1337;File=inline=0:{}\x07x",
        b64(&png(8, 8, [0, 255, 0, 255]))
    );
    w.output(file.as_bytes(), 0);
    settle(&mut w, &mut m, 0);
    assert!(m.slices().is_empty());
    assert_eq!(m.texts()[0], "x");
    assert!(
        !dir.path().join("t.img").exists()
            || std::fs::read_dir(dir.path().join("t.img"))
                .unwrap()
                .next()
                .is_none()
    );
}

#[test]
fn an_iterm2_image_is_sized_in_cells() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    let seq = format!(
        "\x1b]1337;File=inline=1;width=3:{}\x07",
        b64(&png(60, 30, [0, 255, 0, 255]))
    );
    // split across two reads, inside the base64
    let (a, b) = seq.as_bytes().split_at(seq.len() / 2);
    w.output(a, 0);
    w.output(b, 0);
    settle(&mut w, &mut m, 0);
    let s = m.slices();
    assert_eq!(s.len(), 1, "{s:?}");
    let c = canvas(s[0].3[0].as_str().unwrap());
    // 3 cells wide (30 px) keeping the ratio: 15 px tall, in one 20 px cell row
    assert_eq!((c.w, c.h), (30, 20));
    assert_eq!(&c.rgba[..4], &[0, 255, 0, 255]);
    assert_eq!(&c.rgba[(16 * 30) * 4..(16 * 30) * 4 + 4], &[0, 0, 0, 0]);
}

/// A kitty temporary file (the spec's name rule) in the temp directory holding a red 8 × 8 PNG.
fn temp_png(dir: &Path) -> PathBuf {
    let p = dir.join("tty-graphics-protocol-drgnx-test.png");
    std::fs::write(&p, png(8, 8, [255, 0, 0, 255])).unwrap();
    p
}

#[test]
fn a_remote_program_cannot_make_the_worker_read_local_files() {
    let tmp = tempfile::Builder::new()
        .tempdir_in(std::env::temp_dir())
        .unwrap();
    for remote in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let mut w = worker(dir.path());
        let mut m = Model::default();
        w.handle(
            In::Config {
                config: vec![("remote".into(), serde_json::json!(remote))],
            },
            0,
        );
        let path = temp_png(tmp.path());
        let cmd = format!(
            "\x1b_Ga=T,t=t,f=100,q=2;{}\x1b\\",
            b64(path.to_string_lossy().as_bytes())
        );
        w.output(cmd.as_bytes(), 0);
        settle(&mut w, &mut m, 0);
        assert_eq!(m.slices().is_empty(), remote, "remote {remote}");
        // the file medium is off either way
        let f = tmp.path().join("plain.png");
        std::fs::write(&f, png(8, 8, [0, 0, 255, 255])).unwrap();
        let cmd = format!(
            "\x1b_Ga=T,t=f,f=100,q=2;{}\x1b\\",
            b64(f.to_string_lossy().as_bytes())
        );
        let before = m.slices().len();
        w.output(cmd.as_bytes(), 1);
        settle(&mut w, &mut m, 1);
        assert_eq!(m.slices().len(), before, "remote {remote}");
    }
}

#[test]
fn a_canvas_file_goes_once_no_row_names_it_and_the_editor_acked() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    w.output(
        format!(
            "\x1b_Ga=T,f=100,q=2;{}\x1b\\",
            b64(&png(10, 20, [9, 9, 9, 255]))
        )
        .as_bytes(),
        0,
    );
    settle(&mut w, &mut m, 0);
    let file = m.slices()[0].3[0].as_str().unwrap().to_owned();
    assert!(Path::new(&file).exists());
    // the program deletes its images: the rows no longer name the file, and the ack lets it go
    w.output(b"\x1b_Ga=d,q=2\x1b\\", 100);
    settle(&mut w, &mut m, 100);
    assert!(m.slices().is_empty());
    assert!(!Path::new(&file).exists());
    drop(w);
    assert!(
        !dir.path().join("t.img").exists(),
        "the directory goes with the worker"
    );
}

#[test]
fn over_disk_max_a_row_above_the_screen_shows_its_alt() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    w.handle(
        In::Config {
            config: vec![("image-disk-max".into(), serde_json::json!(1))],
        },
        0,
    );
    let img = |c: u8| {
        format!(
            "\x1b_Ga=T,f=100,q=2;{}\x1b\\",
            b64(&png(10, 20, [c, 0, 0, 255]))
        )
    };
    w.output(img(1).as_bytes(), 0);
    settle(&mut w, &mut m, 0);
    let first = m.slices()[0].3[0].as_str().unwrap().to_owned();
    // scrolled off a few rows at a time (each frame sees it go), far above the rows the engine reports
    for n in 0..5 {
        w.output(b"\r\n\r\n\r\n\r\n", 100 + n * 20);
        settle(&mut w, &mut m, 100 + n * 20);
    }
    w.output(img(2).as_bytes(), 200);
    settle(&mut w, &mut m, 200);
    let s = m.slices();
    let old = s
        .iter()
        .find(|x| x.0 == 0)
        .expect("the first image's row, above the screen");
    assert_eq!(old.3[0].as_str(), Some(""), "{s:?}");
    assert_eq!(old.3[5].as_str(), Some("[image 10×20]"));
    assert!(!Path::new(&first).exists());
    assert!(
        s.iter()
            .any(|x| x.0 > 0 && !x.3[0].as_str().unwrap().is_empty())
    );
}

#[test]
fn an_animation_plays_only_while_a_window_shows_the_terminal() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    let frame = |c: u8| b64(&[c, 0, 0, 255].repeat(100 * 100));
    let cmds = format!(
        "\x1b_Ga=T,i=1,f=32,s=100,v=100,q=2;{}\x1b\\\x1b_Ga=f,i=1,f=32,s=100,v=100,z=100,q=2;{}\x1b\\\x1b_Ga=a,i=1,r=1,z=100,q=2\x1b\\\x1b_Ga=a,i=1,s=3,v=1,q=2\x1b\\",
        frame(10),
        frame(200)
    );
    w.output(cmds.as_bytes(), 1000);
    settle(&mut w, &mut m, 1000);
    let first = m.slices()[0].3[0].as_str().unwrap().to_owned();
    let due = match w.next(1000) {
        Next::At(t) => t,
        n => panic!("an animation frame is due, not {n:?}"),
    };
    assert!(due > 1000 && due <= 1200, "{due}");
    settle(&mut w, &mut m, due);
    let second = m.slices()[0].3[0].as_str().unwrap().to_owned();
    assert_ne!(first, second, "the next frame is a new canvas");
    w.handle(In::Visible { visible: false }, due);
    settle(&mut w, &mut m, due);
    assert_eq!(w.next(due + 5000), Next::Idle);
}

#[test]
fn a_row_that_scrolled_past_unseen_comes_back_with_its_image() {
    let dir = tempfile::tempdir().unwrap();
    let mut w = worker(dir.path());
    let mut m = Model::default();
    w.output(
        format!(
            "\x1b_Ga=T,f=100,q=2;{}\x1b\\x\r\n",
            b64(&png(10, 20, [5, 5, 5, 255]))
        )
        .as_bytes(),
        0,
    );
    settle(&mut w, &mut m, 0);
    assert_eq!(m.slices().len(), 1);
    // a flood: the image's row scrolls far past the screen between two frames, and the backfill brings it back
    w.output("y\r\n".repeat(40).as_bytes(), 1000);
    settle_until(&mut w, &mut m, 1000, 1200);
    let s = m.slices();
    assert_eq!(s.len(), 1, "{:?}", m.texts());
    assert!(m.texts()[s[0].0].starts_with(' '), "{:?}", m.texts());
    assert_eq!(s[0].3[5].as_str(), Some("[image 10×20]"));
}
