//! vttest (Thomas Dickey's VT100/VT220 test program) driven through the worker: vttest runs on a PTY of 80 × 24 under
//! the worker's run loop, a key script walks its menus, and each named screen is compared with its golden in
//! `test/conformance/vttest/NAME.txt`: the rows the editor would hold (text, then the style runs). The goldens were
//! recorded from the worker and checked by eye against the screens vttest itself describes; a mismatch with vttest's
//! own description is a row in the docs (docs/develop/terminal.md, "vttest"), not a change to the golden.
//!
//! `UPDATE_VTTEST_GOLDENS=1` writes the goldens instead of comparing. vttest must be installed (the test images carry
//! it: test/container/base/Containerfile, rust-packages.sh): without it the test fails, it never skips.
#![cfg(feature = "ghostty")]

use drgnx_rows::{Op, Row, Style};
use drgnx_term::proto::{In, Out};
use drgnx_term::pty::{Pty, winsize};
use drgnx_term::run::run;
use drgnx_term::worker::{Opts, Worker};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const COLS: u16 = 80;
const ROWS: usize = 24;
/// What vttest shows when it waits for a key: a screen is complete once one of these is on it.
const PROMPTS: [&str; 3] = ["Push <RETURN>", "Enter choice number", "Push any key"];

struct Vt {
    w: UnixStream,
    r: BufReader<UnixStream>,
    rows: Vec<Row>,
    styles: HashMap<u32, Style>,
    version: u64,
    loop_: Option<std::thread::JoinHandle<std::io::Result<drgnx_term::run::Exit>>>,
}

fn vttest_bin() -> String {
    let path = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
    path.split(':')
        .map(|d| format!("{d}/vttest"))
        .find(|p| std::path::Path::new(p).is_file())
        .expect(
            "vttest is not installed: the test images carry it (test/container/base/Containerfile)",
        )
}

impl Vt {
    fn start() -> Vt {
        let (hub, ctl) = UnixStream::pair().unwrap();
        let env = vec![
            ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
            ("LANG".to_owned(), "C".to_owned()),
            ("TERM".to_owned(), "xterm-256color".to_owned()),
        ];
        let size = winsize(COLS, ROWS as u16, (8, 16));
        let pty = Pty::spawn(&vttest_bin(), &[], "/", &env, size).unwrap();
        let t = std::thread::spawn(move || {
            let w = Worker::new(&Opts {
                cols: COLS,
                rows: ROWS as u16,
                cell_px: (8, 16),
                window: 0,
                ..Opts::default()
            })
            .expect("engine");
            run(w, pty, Some(ctl), None)
        });
        hub.set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let mut vt = Vt {
            w: hub.try_clone().unwrap(),
            r: BufReader::new(hub),
            rows: Vec::new(),
            styles: HashMap::new(),
            version: 0,
            loop_: Some(t),
        };
        vt.send(&In::Attach {
            view: "term:vt".into(),
            class: "gui".into(),
            hub: 1,
            env_epoch: 1,
        });
        vt
    }

    fn send(&mut self, m: &In) {
        let mut l = serde_json::to_vec(m).unwrap();
        l.push(b'\n');
        self.w.write_all(&l).unwrap();
    }

    /// Read what the worker sent (at most one read's wait): patches applied and acknowledged. Whether a patch came.
    fn pump(&mut self) -> bool {
        let mut line = String::new();
        match self.r.read_line(&mut line) {
            Ok(0) => panic!("the worker went away"),
            Ok(_) => {}
            Err(_) => return false,
        }
        let Ok(Out::Patch { patch }) = serde_json::from_str::<Out>(&line) else {
            return false;
        };
        for (id, s) in &patch.styles {
            self.styles.insert(*id, *s);
        }
        for op in &patch.ops {
            match op {
                Op::Reset(rows) => self.rows = rows.clone(),
                Op::Insert { after, rows } => {
                    let at = after.as_ref().map_or(0, |k| {
                        self.rows
                            .iter()
                            .position(|r| &r.key == k)
                            .expect("insert after a held key")
                            + 1
                    });
                    for (n, r) in rows.iter().enumerate() {
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
        self.version = patch.version;
        self.send(&In::Ack {
            version: patch.version,
        });
        true
    }

    /// The screen's rows (the last 24 the editor holds), text only.
    fn screen(&self) -> Vec<String> {
        let from = self.rows.len().saturating_sub(ROWS);
        self.rows[from..]
            .iter()
            .map(|r| r.text.trim_end().to_owned())
            .collect()
    }

    /// Type TEXT, then wait for the screen it leads to: one that shows MARK (what vttest writes last on that screen)
    /// and a prompt.
    fn key(&mut self, text: &str, mark: &str) -> Vec<String> {
        self.send(&In::Text { text: text.into() });
        self.settle(text, mark)
    }

    /// Wait until the screen shows MARK and a prompt, then until the worker is quiet (a read's wait with no patch):
    /// the screen vttest drew is whole. A screen is never taken while vttest still echoes or draws it.
    fn settle(&mut self, what: &str, mark: &str) -> Vec<String> {
        let seen = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            skuld::wait_until(
                &format!("vttest's screen with {mark:?} after {what:?}"),
                20,
                || {
                    self.pump();
                    let s = self.screen();
                    (s.iter().any(|l| l.contains(mark))
                        && s.iter().any(|l| PROMPTS.iter().any(|p| l.contains(p))))
                    .then_some(())
                },
            )
        }));
        if let Err(e) = seen {
            eprintln!(
                "vttest's screen when the wait for {mark:?} ran out:\n{}",
                self.screen().join("\n")
            );
            std::panic::resume_unwind(e);
        }
        skuld::wait_until(&format!("the worker quiet after {what:?}"), 20, || {
            (!self.pump()).then_some(())
        });
        self.screen()
    }

    /// The screen as a golden: its 24 lines, then each row's style runs with the style spelled out.
    fn golden(&self) -> String {
        let from = self.rows.len().saturating_sub(ROWS);
        let mut out = String::new();
        for r in &self.rows[from..] {
            out.push_str(r.text.trim_end());
            out.push('\n');
        }
        out.push_str("--- runs (row: start-end style)\n");
        for (y, r) in self.rows[from..].iter().enumerate() {
            for (s, e, face) in &r.runs {
                let style = face
                    .strip_prefix("s:")
                    .and_then(|id| id.parse::<u32>().ok())
                    .and_then(|id| self.styles.get(&id))
                    .map_or_else(|| face.clone(), |st| serde_json::to_string(st).unwrap());
                out.push_str(&format!("{y}: {s}-{e} {style}\n"));
            }
        }
        out
    }

    fn close(mut self) {
        self.send(&In::Close { signal: Some(9) });
        let _ = self.loop_.take().unwrap().join();
    }
}

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../../test/conformance/vttest/{name}.txt"))
}

/// Start vttest, wait for its menu, then walk STEPS: each `(KEYS, MARK)` types KEYS ("\r" is Return) and waits for
/// the screen that shows MARK. The screen the last step leaves is checked against golden NAME.
fn golden(name: &str, steps: &[(&str, &str)]) {
    let mut vt = Vt::start();
    vt.settle("the start", "Enter choice number");
    for (keys, mark) in steps {
        vt.key(keys, mark);
    }
    let got = vt.golden();
    vt.close();
    let path = golden_path(name);
    if std::env::var_os("UPDATE_VTTEST_GOLDENS").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &got).unwrap();
        println!("=== {name}\n{got}");
        return;
    }
    let want = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("no golden {}: {e}", path.display()));
    assert!(
        got == want,
        "vttest screen {name} differs from its golden {}:\n{got}",
        path.display()
    );
}

#[test]
fn cursor_movement() {
    // menu 1, its first screen: the border of *'s and +'s and the frame of E's (CUP, CUU/CUD/CUF/CUB, IND, RI, NEL)
    golden("cursor-movement", &[("1\r", "free position around it")]);
}

#[test]
fn scroll_regions() {
    // menu 2 up to its first scroll test: a region of rows 12-13 scrolled down (DECSTBM, RI); the column-mode
    // screens on the way are checked only for their marks
    golden(
        "scroll-regions",
        &[
            ("2\r", "WRAP AROUND"),
            ("\r", "TAB setting"),
            ("\r", "132 column mode, light"),
            ("\r", "80 column mode, light"),
            ("\r", "132 column mode, dark"),
            ("\r", "80 column mode, dark"),
            ("\r", "Soft scroll down region [12..13]"),
        ],
    );
}

#[test]
fn character_sets() {
    // menu 3, item 8: the VT100 character sets in G0 (SI) and G1 (SO), DEC line drawing among them
    golden(
        "character-sets",
        &[
            ("3\r", "Menu 3: Character-Set Tests"),
            ("8\r", "These are the installed character sets"),
        ],
    );
}

#[test]
fn reports() {
    // menu 6, item 3: the device status reports (DSR 5, the terminal's status; DSR 6, the cursor's position)
    golden(
        "reports",
        &[
            ("6\r", "Menu 6: Terminal Reports"),
            ("3\r", "Push <RETURN>"),
        ],
    );
}

#[test]
fn insert_delete() {
    // menu 8 up to the staggered right column: insert and delete line (IL, DL), insert mode (IRM), delete
    // character (DCH)
    golden(
        "insert-delete",
        &[
            ("8\r", "Screen accordion"),
            ("\r", "Top line: A's"),
            ("\r", "Insert Mode"),
            ("\r", "Delete Character"),
            ("\r", "staggered"),
        ],
    );
}

#[test]
fn double_width() {
    // menu 4, its first screen: double-width and double-height lines (DECDWL, DECDHL) in 80 columns
    golden(
        "double-width",
        &[("4\r", "This is not a double-width line")],
    );
}

#[test]
fn colours() {
    // menu 11.6, item 2: the ISO 6429 colour test pattern (SGR 30-37, 40-47)
    golden(
        "colours",
        &[
            ("11\r", "Menu 11: Non-VT100"),
            ("6\r", "Menu 11.6: ISO 6429 colors"),
            ("2\r", "Push <RETURN>"),
        ],
    );
}

#[test]
fn vt52_exit() {
    // menu 7 through to the screen after VT52 mode is left (ESC <): the identify reply and the cursor report in ANSI
    // mode again. vttest reads each reply up to a Return, which the script types once the reply is in (the `<13>`
    // on those lines)
    golden(
        "vt52-exit",
        &[
            ("7\r", "Only this, and,/Push"),
            ("\r", "ics character set"),
            ("\r", "IDENTIFY command"),
            ("\r", "restoring ANSI mode"),
            ("\r", "Response to CUP(1,1)/DSR(6)"),
        ],
    );
}
