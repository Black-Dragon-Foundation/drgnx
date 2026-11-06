//! Which files the editors have open (a pure core): `pair/open`, `pair/closed` and the full `pair/open-set` an editor
//! sends at setup and on every (re)connection, which replaces what the hub held for that editor.  A pair write goes
//! to the editor that has the file open; the hub never writes the disk behind an open file.
//!
//! - **Large and remote buffers** are open too (the history skips them, the door does not): pair writes to them are
//!   refused.
//! - **An editor that goes away** leaves every file it had open "away": a write refuses ("the editor is away") until
//!   an editor opens the file again or sends its full set.
//! - A file no editor has open, and not away, routes to the disk ([`Route::Disk`]); the door refuses that in this
//!   version ("not open in the editor").

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

pub use runstav::methods::pair::FileKind;

/// The text of a write to a large or remote buffer.
pub const LARGE_OR_REMOTE: &str =
    "this file is open as a large or remote file; pair edits are off for it";

/// Where a write of one file goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// To the editor connection that has it open.
    Editor(u64),
    /// Refused, and why.
    Refused(&'static str),
    /// No editor has it, none went away with it: the disk.
    Disk,
}

/// The editors' open files.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OpenSet {
    /// File → the connections that have it open, and how.
    open: BTreeMap<PathBuf, BTreeMap<u64, FileKind>>,
    /// Files open in an editor when it went away.
    away: BTreeSet<PathBuf>,
}

/// One event of the open set.
#[derive(Clone, Debug, PartialEq)]
pub enum OpenEv {
    Open {
        conn: u64,
        file: PathBuf,
        kind: FileKind,
    },
    Closed {
        conn: u64,
        file: PathBuf,
    },
    /// Connection CONN's full set: it replaces what the hub held for it, and nothing is away any more.
    Set {
        conn: u64,
        files: Vec<(PathBuf, FileKind)>,
    },
    /// Connection CONN is gone.
    Gone {
        conn: u64,
    },
    /// A write of FILE asks its route (a test's probe; the door calls [`OpenSet::route`]).
    Write {
        file: PathBuf,
    },
}

impl OpenSet {
    pub fn step(&mut self, ev: OpenEv) {
        match ev {
            OpenEv::Open { conn, file, kind } => {
                self.away.remove(&file);
                self.open.entry(file).or_default().insert(conn, kind);
            }
            OpenEv::Closed { conn, file } => {
                if let Some(c) = self.open.get_mut(&file) {
                    c.remove(&conn);
                    if c.is_empty() {
                        self.open.remove(&file);
                    }
                }
            }
            OpenEv::Set { conn, files } => {
                self.drop_conn(conn);
                self.away.clear();
                for (file, kind) in files {
                    self.open.entry(file).or_default().insert(conn, kind);
                }
            }
            OpenEv::Gone { conn } => {
                for f in self.drop_conn(conn) {
                    if !self.open.contains_key(&f) {
                        self.away.insert(f);
                    }
                }
            }
            OpenEv::Write { .. } => {}
        }
    }

    /// CONN's entries removed: the files it had.
    fn drop_conn(&mut self, conn: u64) -> Vec<PathBuf> {
        let mut had = Vec::new();
        self.open.retain(|f, c| {
            if c.remove(&conn).is_some() {
                had.push(f.clone());
            }
            !c.is_empty()
        });
        had
    }

    /// Where a write of FILE goes now.
    pub fn route(&self, file: &PathBuf) -> Route {
        match self.open.get(file) {
            Some(c) => match c.iter().find(|(_, k)| **k == FileKind::Normal) {
                Some((conn, _)) => Route::Editor(*conn),
                None => Route::Refused(LARGE_OR_REMOTE),
            },
            None if self.away.contains(file) => Route::Refused(super::door::EDITOR_AWAY),
            None => Route::Disk,
        }
    }

    /// Whether any editor has FILE open, in any kind.
    pub fn is_open(&self, file: &PathBuf) -> bool {
        self.open.contains_key(file)
    }
}

/// The open set as the every-order tests run it: each `Write` records the route it got, beside what an oracle of the
/// same events says is open.
#[cfg(test)]
#[derive(Default)]
struct Probe {
    set: OpenSet,
    routes: Vec<(PathBuf, Route, bool)>,
}

#[cfg(test)]
skuld::events!(OpenEv {
    Open,
    Closed,
    Set,
    Gone,
    Write
});

#[cfg(test)]
impl skuld::Core for Probe {
    type Event = OpenEv;
    fn step(&mut self, ev: OpenEv) -> Vec<OpenEv> {
        if let OpenEv::Write { file } = &ev {
            let open = self.set.is_open(file);
            self.routes.push((file.clone(), self.set.route(file), open));
        }
        self.set.step(ev);
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skuld::{Bound, Partial, every_order};

    fn p(s: &str) -> PathBuf {
        PathBuf::from(format!("/w/{s}"))
    }

    fn open(conn: u64, f: &str) -> OpenEv {
        OpenEv::Open {
            conn,
            file: p(f),
            kind: FileKind::Normal,
        }
    }

    fn write(f: &str) -> OpenEv {
        OpenEv::Write { file: p(f) }
    }

    /// [A] Two editors open and close files while writes of them come: in every order a write of a file some editor
    /// has open goes to an editor (never the disk), a write of a large file is refused, and the disk is the route only
    /// for a file no editor has open and none went away with.  Edges: a connection's events in its own order; its
    /// `Gone` after them.
    #[test]
    fn every_order_open_close_and_writes_never_write_behind_an_open_file() {
        let mut pt = Partial::new();
        pt.source(
            "editor 1",
            vec![
                open(1, "a"),
                OpenEv::Open {
                    conn: 1,
                    file: p("big"),
                    kind: FileKind::Large,
                },
                OpenEv::Closed {
                    conn: 1,
                    file: p("a"),
                },
                OpenEv::Gone { conn: 1 },
            ],
        );
        pt.source("editor 2", vec![open(2, "a"), open(2, "b")]);
        pt.source(
            "editor 3",
            vec![OpenEv::Set {
                conn: 3,
                files: vec![(p("d"), FileKind::Normal)],
            }],
        );
        pt.source(
            "writes",
            vec![write("a"), write("b"), write("big"), write("c")],
        );
        every_order(&pt, Bound::default(), Probe::default, |probe, order| {
            for (f, route, open) in &probe.routes {
                match route {
                    Route::Disk if *open => return Err(format!("{f:?} open, routed to disk")),
                    Route::Editor(_) if !*open => {
                        return Err(format!("{f:?} not open, routed to an editor"));
                    }
                    Route::Refused(why) if *f == p("big") && *open && *why != LARGE_OR_REMOTE => {
                        return Err(format!("big: {why}"));
                    }
                    _ => {}
                }
                if *f == p("c") && *route != Route::Disk {
                    return Err(format!("c: {route:?}"));
                }
            }
            // after editor 1 left, its large file is away, unless a full set came after (it says what is open);
            // a stays with editor 2, d with editor 3
            let at = |k: &str| order.iter().position(|e| skuld::Events::kind(e) == k);
            let big = if at("Set") > at("Gone") {
                Route::Disk
            } else {
                Route::Refused(super::super::door::EDITOR_AWAY)
            };
            for (f, want) in [
                ("big", big),
                ("a", Route::Editor(2)),
                ("d", Route::Editor(3)),
            ] {
                if probe.set.route(&p(f)) != want {
                    return Err(format!("{f} at the end: {:?}", probe.set.route(&p(f))));
                }
            }
            Ok(())
        });
    }

    /// [A] An editor reconnects (connection 1 gone, connection 3 sends its full set) while a second editor opens a
    /// file: in every order the new set replaces the old one (what connection 1 had is neither open nor away once the
    /// set came), and the other editor's file stays its own.  Edges: the reconnect's set comes after the old
    /// connection is gone.
    #[test]
    fn every_order_an_open_set_replaces_the_old_one() {
        let mut pt = Partial::new();
        let old = pt.source(
            "old connection",
            vec![open(1, "a"), open(1, "b"), OpenEv::Gone { conn: 1 }],
        );
        let new = pt.source(
            "reconnected",
            vec![OpenEv::Set {
                conn: 3,
                files: vec![(p("b"), FileKind::Normal), (p("r"), FileKind::Remote)],
            }],
        );
        // the other editor closes a file it never had: nothing changes
        pt.source(
            "other editor",
            vec![
                open(2, "c"),
                open(2, "b"),
                OpenEv::Closed {
                    conn: 2,
                    file: p("z"),
                },
            ],
        );
        pt.source("writes", vec![write("b")]);
        pt.before((old, 2), (new, 0));
        every_order(&pt, Bound::default(), Probe::default, |probe, _| {
            let s = &probe.set;
            let want_b = s.route(&p("b"));
            if !matches!(want_b, Route::Editor(2 | 3)) {
                return Err(format!("b: {want_b:?}"));
            }
            for (f, want) in [
                ("a", Route::Disk),
                ("c", Route::Editor(2)),
                ("r", Route::Refused(LARGE_OR_REMOTE)),
            ] {
                if s.route(&p(f)) != want {
                    return Err(format!("{f}: {:?}", s.route(&p(f))));
                }
            }
            Ok(())
        });
    }
}
