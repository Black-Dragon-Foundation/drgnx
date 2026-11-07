//! The buffer views' core: who gets a frame in every order of watches, changes and flushes (pattern A), and the
//! frame's gutter and hover rules (pattern D).

use super::*;
use runstav::methods::editor::{GutterKind, GutterRange, Projected};
use skuld::{Bound, Partial, every_order};
use std::collections::BTreeSet;

skuld::events!(ViewEv {
    Watch,
    Unwatch,
    Changed,
    Flush,
    UserIdle,
    Gone
});

fn watch(conn: u64, view: &str, file: &str, doc: u64) -> ViewEv {
    ViewEv::Watch {
        conn,
        view: view.into(),
        file: file.into(),
        keys: vec![
            file.into(),
            format!("repo:{}", file.rsplit('/').next().unwrap_or(file)),
        ],
        doc_version: Some(doc),
    }
}

fn changed(key: &str) -> ViewEv {
    ViewEv::Changed {
        keys: vec![key.into()],
    }
}

/// What each connection was sent, and the first broken rule.
#[derive(Default)]
struct Harness {
    v: Views,
    /// (conn, view) → (file shown, the version the editor holds, frames since a full one).
    held: BTreeMap<(u64, String), (String, u64)>,
    /// Views watched now (by the events seen).
    open: BTreeSet<(u64, String)>,
    /// Frames sent per connection.
    sent: BTreeMap<u64, u32>,
    broken: Option<String>,
}

impl Harness {
    fn fail(&mut self, why: String) {
        if self.broken.is_none() {
            self.broken = Some(why);
        }
    }
}

impl skuld::Core for Harness {
    type Event = ViewEv;
    fn step(&mut self, ev: ViewEv) -> Vec<ViewEv> {
        match &ev {
            ViewEv::Watch { conn, view, .. } => {
                self.open.insert((*conn, view.clone()));
            }
            ViewEv::Unwatch { conn, view } => {
                self.open.remove(&(*conn, view.clone()));
            }
            ViewEv::Gone { conn } => self.open.retain(|(c, _)| c != conn),
            _ => {}
        }
        let shown = format!("{ev:?}");
        let outs = self.v.step(ev);
        let mut re = Vec::new();
        for o in outs {
            match o {
                ViewOut::Full {
                    conn,
                    view,
                    file,
                    version,
                    ..
                } => {
                    self.held.insert((conn, view), (file, version));
                }
                ViewOut::Frame {
                    conn,
                    view,
                    file,
                    version,
                    base,
                    ..
                } => {
                    *self.sent.entry(conn).or_default() += 1;
                    let key = (conn, view.clone());
                    if !self.open.contains(&key) {
                        self.fail(format!("{shown}: a frame to {key:?}, not watched"));
                    }
                    match self.held.get(&key) {
                        Some((f, v)) if *v == base && *f == file => {
                            self.held.insert(key, (file, version));
                        }
                        held => {
                            self.fail(format!("{shown}: {key:?} holds {held:?}, got base {base}"))
                        }
                    }
                }
                ViewOut::Arm | ViewOut::NoView => {}
                ViewOut::Idle {
                    conn,
                    view,
                    generation,
                } => re.push(ViewEv::UserIdle {
                    conn,
                    view,
                    generation,
                }),
            }
        }
        if self.v.stranded() {
            self.fail(format!("{shown}: a dirty view with no flush armed"));
        }
        re
    }
}

/// Pattern A. Connection 1 watches x and later unwatches it; connection 2 watches y and is gone at the end;
/// connection 3 watches x in another worktree (the same `repo:` key); an agent moves in x, y and an unwatched z; the
/// clock flushes. In every order a frame goes only to a view watched then, each frame follows the version its editor
/// holds, a dirty view always has a flush armed, z costs nothing, and once 2 is gone it gets nothing.
#[test]
fn every_order_watch_unwatch_and_moves_send_only_to_the_watcher() {
    let mut p = Partial::new();
    p.source(
        "conn1",
        vec![
            watch(1, "v", "/w/x.rs", 1),
            ViewEv::Unwatch {
                conn: 1,
                view: "v".into(),
            },
        ],
    );
    let c2 = p.source(
        "conn2",
        vec![watch(2, "v", "/w/y.rs", 1), ViewEv::Gone { conn: 2 }],
    );
    // an idle of a change the view never had is stale
    p.source(
        "conn3",
        vec![
            watch(3, "u", "/t/x.rs", 1),
            ViewEv::UserIdle {
                conn: 3,
                view: "u".into(),
                generation: 5,
            },
        ],
    );
    let agent = p.source(
        "agent",
        vec![changed("repo:x.rs"), changed("/w/y.rs"), changed("/w/z.rs")],
    );
    p.source("clock", vec![ViewEv::Flush, ViewEv::Flush]);
    p.before((agent, 1), (c2, 1));
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        if let Some(b) = &h.broken {
            return Err(b.clone());
        }
        if h.v.files() != ["/t/x.rs"] {
            return Err(format!("left open {:?}", h.v.files()));
        }
        Ok(())
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// Pattern A. A view's editor sees a gap and watches again, while changes and flushes come in any order, and the
/// user changes the buffer (a newer doc_version, whose quiet ends at once here): every frame follows the version the
/// editor holds (a watch's full frame resets it), a stale idle and a second unwatch do nothing, and nothing stays
/// dirty with no flush armed.
#[test]
fn every_order_a_gap_gets_a_full_frame() {
    let mut p = Partial::new();
    p.source(
        "editor",
        vec![
            watch(1, "v", "/w/x.rs", 1),
            watch(1, "v", "/w/x.rs", 1),
            watch(1, "v", "/w/x.rs", 2),
        ],
    );
    let agent = p.source("agent", vec![changed("/w/x.rs"), changed("/w/x.rs")]);
    p.source("clock", vec![ViewEv::Flush, ViewEv::Flush, ViewEv::Flush]);
    p.source(
        "elsewhere",
        vec![
            watch(2, "q", "/w/q.rs", 1),
            ViewEv::UserIdle {
                conn: 2,
                view: "q".into(),
                generation: 9,
            },
            ViewEv::Unwatch {
                conn: 2,
                view: "q".into(),
            },
            ViewEv::Unwatch {
                conn: 2,
                view: "q".into(),
            },
            ViewEv::Gone { conn: 2 },
        ],
    );
    let _ = agent;
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        if let Some(b) = &h.broken {
            return Err(b.clone());
        }
        Ok(())
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

fn range(session: &str, kind: GutterKind, start: u32, end: u32, help: &str) -> GutterRange {
    GutterRange {
        session: session.into(),
        kind,
        start,
        end,
        projected: None,
        help: help.into(),
    }
}

/// Pattern D. A session's ranges of one kind merge where they overlap or touch; other sessions' and other kinds'
/// stay apart; a projected range stays apart from the same session's own.
#[test]
fn gutter_ranges_merge_per_session() {
    let mut projected = range("a", GutterKind::Changed, 9, 9, "p");
    projected.projected = Some(Projected {
        worktree_label: "wt".into(),
    });
    let got = merge_gutter(vec![
        range("a", GutterKind::Changed, 5, 7, "first"),
        range("b", GutterKind::Changed, 6, 6, "b"),
        range("a", GutterKind::Changed, 8, 10, "second"),
        range("a", GutterKind::Pending, 9, 9, "pending"),
        range("a", GutterKind::Changed, 20, 22, "far"),
        projected.clone(),
    ]);
    let want = vec![
        range("a", GutterKind::Changed, 5, 10, "first"),
        range("b", GutterKind::Changed, 6, 6, "b"),
        projected,
        range("a", GutterKind::Pending, 9, 9, "pending"),
        range("a", GutterKind::Changed, 20, 22, "far"),
    ];
    assert_eq!(got, want);
}

/// Pattern D. A step snapshot's patch gives the lines it changed on its new side: the added lines, and a deletion's
/// place (the line after it); context lines are not changed.
#[test]
fn a_patch_gives_its_changed_lines() {
    let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n+B2\n c\n d\n\
                @@ -10,3 +11,2 @@\n j\n-k\n l\n";
    assert_eq!(changed_ranges(diff), vec![(2, 3), (12, 12)]);
    // a new file is all its lines
    assert_eq!(
        changed_ranges("--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+x\n+y\n"),
        vec![(1, 2)]
    );
}

/// Pattern D. The hover names the agent, the step and how long ago, in words a person reads.
#[test]
fn help_text_names_step_and_age() {
    assert_eq!(
        help_text("Opus", Some(14), 1000.0, 1130.0),
        "Opus · changed in step 14 · 2 min ago"
    );
    assert_eq!(
        help_text("Opus 2", Some(3), 1000.0, 1010.0),
        "Opus 2 · changed in step 3 · just now"
    );
    assert_eq!(
        help_text("Codex", None, 0.0, 7300.0),
        "Codex · changed · 2 h ago"
    );
}
