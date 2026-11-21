//! Which editor buffer views get a frame, and when (pure; `docs/develop/hub.md`, "The buffer view").
//!
//! A view is one connection's buffer shown in a window, keyed by (connection, view). It has match keys (its file's
//! true name, and `repo:rel`, the same file in every worktree of its repository): a change that names one of them
//! makes the view dirty, and the next flush sends it one frame. The flush is armed once per 50 ms of the hub's clock
//! (the shell's single task), so a view gets at most one frame per 50 ms, and only its own connection gets it. A
//! frame's version follows the one before (`base`); a watch answers a full frame (`base` 0), which is also how an
//! editor that saw a gap gets back in step. A watch of a view already watched with a newer `doc_version` is the user
//! changing the buffer: its frame follows after 300 ms of quiet (the shell's idle task, by generation).

use std::collections::BTreeMap;

/// One view: a connection's id for one buffer.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ViewKey {
    pub conn: u64,
    pub view: String,
}

#[derive(Clone, Debug)]
struct View {
    file: String,
    keys: Vec<String>,
    version: u64,
    dirty: bool,
    doc_version: Option<u64>,
    /// The user's latest change (an idle that names an older one is stale).
    typed: u64,
}

/// What the core is told.
#[derive(Clone, Debug, PartialEq)]
pub enum ViewEv {
    /// CONN's VIEW shows FILE (KEYS: its match keys), at the editor's DOC_VERSION.
    Watch {
        conn: u64,
        view: String,
        file: String,
        keys: Vec<String>,
        doc_version: Option<u64>,
    },
    Unwatch {
        conn: u64,
        view: String,
    },
    /// What is shown in the files these keys name changed (presence, an edit, a projection's input).
    Changed {
        keys: Vec<String>,
    },
    /// The 50 ms flush.
    Flush,
    /// The user's change GENERATION of the view has had 300 ms of quiet.
    UserIdle {
        conn: u64,
        view: String,
        generation: u64,
    },
    /// Connection CONN is gone.
    Gone {
        conn: u64,
    },
}

/// What the shell does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ViewOut {
    /// The watch's answer: FILE's full frame at VERSION.
    Full {
        conn: u64,
        view: String,
        file: String,
        version: u64,
        doc_version: Option<u64>,
    },
    /// An `agent-buffer` event to CONN: FILE's frame at VERSION, after BASE.
    Frame {
        conn: u64,
        view: String,
        file: String,
        version: u64,
        base: u64,
        doc_version: Option<u64>,
    },
    /// Arm the flush (it is not armed).
    Arm,
    /// Arm the view's 300 ms idle for change GENERATION.
    Idle {
        conn: u64,
        view: String,
        generation: u64,
    },
    /// No such view (an unwatch).
    NoView,
}

/// See the module.
#[derive(Debug, Default)]
pub struct Views {
    views: BTreeMap<ViewKey, View>,
    armed: bool,
}

impl Views {
    pub fn step(&mut self, ev: ViewEv) -> Vec<ViewOut> {
        let mut out = Vec::new();
        match ev {
            ViewEv::Watch {
                conn,
                view,
                file,
                keys,
                doc_version,
            } => {
                let key = ViewKey {
                    conn,
                    view: view.clone(),
                };
                let v = self.views.entry(key).or_insert_with(|| View {
                    file: file.clone(),
                    keys: keys.clone(),
                    version: 0,
                    dirty: false,
                    doc_version,
                    typed: 0,
                });
                let typed = v.file == file
                    && v.version > 0
                    && doc_version.is_some()
                    && doc_version != v.doc_version;
                v.file = file.clone();
                v.keys = keys;
                v.doc_version = doc_version;
                v.version += 1;
                v.dirty = false;
                out.push(ViewOut::Full {
                    conn,
                    view: view.clone(),
                    file,
                    version: v.version,
                    doc_version,
                });
                if typed {
                    v.typed += 1;
                    out.push(ViewOut::Idle {
                        conn,
                        view,
                        generation: v.typed,
                    });
                }
            }
            ViewEv::Unwatch { conn, view } => {
                if self.views.remove(&ViewKey { conn, view }).is_none() {
                    out.push(ViewOut::NoView);
                }
            }
            ViewEv::Changed { keys } => {
                let mut any = false;
                for v in self.views.values_mut() {
                    if v.keys.iter().any(|k| keys.contains(k)) {
                        v.dirty = true;
                        any = true;
                    }
                }
                if any {
                    out.extend(self.arm());
                }
            }
            ViewEv::UserIdle {
                conn,
                view,
                generation,
            } => {
                if let Some(v) = self.views.get_mut(&ViewKey { conn, view })
                    && v.typed == generation
                {
                    v.dirty = true;
                    out.extend(self.arm());
                }
            }
            ViewEv::Flush => {
                self.armed = false;
                for (k, v) in self.views.iter_mut().filter(|(_, v)| v.dirty) {
                    v.dirty = false;
                    v.version += 1;
                    out.push(ViewOut::Frame {
                        conn: k.conn,
                        view: k.view.clone(),
                        file: v.file.clone(),
                        version: v.version,
                        base: v.version - 1,
                        doc_version: v.doc_version,
                    });
                }
            }
            ViewEv::Gone { conn } => self.views.retain(|k, _| k.conn != conn),
        }
        out
    }

    fn arm(&mut self) -> Option<ViewOut> {
        (!std::mem::replace(&mut self.armed, true)).then_some(ViewOut::Arm)
    }

    /// Whether any view is dirty while no flush is armed (never, after a step).
    pub fn stranded(&self) -> bool {
        !self.armed && self.views.values().any(|v| v.dirty)
    }

    /// The views open now.
    pub fn len(&self) -> usize {
        self.views.len()
    }

    pub fn is_empty(&self) -> bool {
        self.views.is_empty()
    }

    /// The files some view shows now.
    pub fn files(&self) -> Vec<String> {
        let mut f: Vec<String> = self.views.values().map(|v| v.file.clone()).collect();
        f.sort();
        f.dedup();
        f
    }
}

/// RANGES merged per (session, kind, projected): overlapping or touching ranges become one, the first one's help
/// kept; sorted by start, then end, session, kind and projection.
pub fn merge_gutter(
    mut ranges: Vec<runstav::methods::editor::GutterRange>,
) -> Vec<runstav::methods::editor::GutterRange> {
    ranges.sort_by(|a, b| {
        (&a.session, a.kind, &a.projected, a.start, a.end).cmp(&(
            &b.session,
            b.kind,
            &b.projected,
            b.start,
            b.end,
        ))
    });
    let mut out: Vec<runstav::methods::editor::GutterRange> = Vec::new();
    for r in ranges {
        if let Some(last) = out.last_mut()
            && last.session == r.session
            && last.kind == r.kind
            && last.projected == r.projected
            && r.start <= last.end.saturating_add(1)
        {
            last.end = last.end.max(r.end);
            continue;
        }
        out.push(r);
    }
    out.sort_by(|a, b| {
        (a.start, a.end, &a.session, a.kind, &a.projected).cmp(&(
            b.start,
            b.end,
            &b.session,
            b.kind,
            &b.projected,
        ))
    });
    out
}

/// How long ago AGO seconds is, as a gutter's hover says it.
fn age(ago: f64) -> String {
    let s = ago.max(0.0) as u64;
    match s {
        0..60 => "just now".to_string(),
        60..3600 => format!("{} min ago", s / 60),
        3600..86_400 => format!("{} h ago", s / 3600),
        _ => format!("{} d ago", s / 86_400),
    }
}

/// A changed range's hover: "HANDLE · changed in step STEP · AGE" (the step left out when unknown).
pub fn help_text(handle: &str, step: Option<u64>, at: f64, now: f64) -> String {
    match step {
        Some(n) => format!("{handle} · changed in step {n} · {}", age(now - at)),
        None => format!("{handle} · changed · {}", age(now - at)),
    }
}

/// The lines a unified DIFF (one file's patch) changed on its new side, merged into (first, last) ranges, 1-based: its
/// added lines, and a deletion's place (the line after it). Context lines are not changed.
pub fn changed_ranges(diff: &str) -> Vec<(u32, u32)> {
    let mut lines: Vec<u32> = Vec::new();
    let mut new_line: Option<u32> = None;
    for l in diff.lines() {
        if let Some(rest) = l.strip_prefix("@@ ") {
            // `@@ -a,b +c,d @@`: the new side starts at line c
            new_line = rest
                .split_whitespace()
                .find_map(|w| w.strip_prefix('+'))
                .and_then(|w| w.split(',').next())
                .and_then(|n| n.parse().ok());
            continue;
        }
        let Some(n) = new_line.as_mut() else {
            continue;
        };
        match l.as_bytes().first() {
            Some(b'+') => {
                lines.push(*n);
                *n += 1;
            }
            Some(b'-') => lines.push((*n).max(1)),
            Some(b' ') => *n += 1,
            _ => {}
        }
    }
    lines.sort_unstable();
    let mut out: Vec<(u32, u32)> = Vec::new();
    for n in lines {
        match out.last_mut() {
            Some((_, e)) if n <= *e + 1 => *e = (*e).max(n),
            _ => out.push((n, n)),
        }
    }
    out
}

#[cfg(test)]
mod tests;
