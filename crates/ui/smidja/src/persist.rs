//! Persistence (§4.9): the model's own versioned text, and the restore state machine. No I/O: `save` returns text,
//! `load` takes it; the glue reads and writes the files.
//!
//! Saved per OS window: its monitor, size, the regions' visibility and sizes, the left's place, the right's tab, the
//! center tree with each tab's ref, preview flag and order, the bottom's tabs. Not saved: selection, focus, overlays,
//! undo. A temporary layout is saved as its return tab.
//!
//! The format, one item per line, children indented one space per level:
//! `smidja-layout 1`, then per window `window MONITOR px|cells W H SCALE`, `left VIS WIDTH PLACE|-`,
//! `right VIS WIDTH TAB`, `bottom VIS HEIGHT ACTIVE|-`, `chrome HIDDEN`, `center ACTIVE FULL|-`, the tree
//! (`split row|column N W1 … WN` followed by its N children, or `group ACTIVE|- N` followed by N `tab` lines), the
//! bottom's `btab` lines, and `end`. A tab is `tab pin|preview KIND TITLE REF…` where REF is `file PATH AT|-`,
//! `buffer ID NAME`, `page KIND KEY|-`, `session ID` or `output CHANNEL`. Strings are quoted with `\"`, `\\` and
//! `\n` escapes; `-` is none.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use crate::layout::{SnapGroup, SnapNode, SnapTab};
use crate::model::{
    Axis, GroupId, Node, Ref, Refusal, RightTab, TabId, Version, WinId, WinSize, Workbench, refuse,
};

pub const HEADER: &str = "smidja-layout 1";

/// A window as read from the text.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingWindow {
    pub monitor: String,
    pub size: WinSize,
    pub scale: f32,
    pub left_visible: bool,
    pub left_width: u32,
    pub left_place: Option<String>,
    pub right_visible: bool,
    pub right_width: u32,
    pub right_tab: RightTab,
    pub bottom_visible: bool,
    pub bottom_height: u32,
    pub bottom_active: Option<usize>,
    pub chrome_hidden: bool,
    pub active: usize,
    pub full_size: Option<usize>,
    pub tree: SnapNode,
    pub bottom_tabs: Vec<SnapTab>,
}

/// What `load` read: the windows to restore.
#[derive(Clone, Debug, PartialEq)]
pub struct Pending {
    pub windows: Vec<PendingWindow>,
}

/// How a ref resolved during a restore.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolved {
    /// It opens now.
    Now,
    /// It opens now with its saved title and a placeholder row (a hub page whose kind is not declared yet).
    Placeholder,
    /// It is gone (a deleted file): dropped, with one notice.
    Gone,
}

/// One ref waiting to be resolved: where it goes.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingRef {
    pub win: WinId,
    /// None: the bottom panel.
    pub group: Option<GroupId>,
    pub pos: usize,
    pub active: bool,
    pub tab: SnapTab,
}

/// The restore state machine (Zed's pattern): `Restoring` until a tick ends it or the user acts.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Restore {
    #[default]
    Finished,
    Restoring {
        pending: Vec<PendingRef>,
        /// Each restored tab's saved position, so later ones go in order.
        pos: BTreeMap<TabId, usize>,
    },
}

fn q(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn qo(out: &mut String, s: Option<&str>) {
    match s {
        Some(s) => q(out, s),
        None => out.push('-'),
    }
}

fn write_tab(out: &mut String, depth: usize, word: &str, t: &SnapTab) {
    out.push_str(&" ".repeat(depth));
    out.push_str(word);
    out.push_str(if t.preview { " preview " } else { " pin " });
    q(out, &t.kind);
    out.push(' ');
    q(out, &t.title);
    out.push(' ');
    match &t.r {
        Ref::File { path, at } => {
            out.push_str("file ");
            q(out, path);
            out.push(' ');
            qo(out, at.as_deref());
        }
        Ref::Buffer { id, name } => {
            out.push_str("buffer ");
            q(out, id);
            out.push(' ');
            q(out, name);
        }
        Ref::Page { page_kind, key } => {
            out.push_str("page ");
            q(out, page_kind);
            out.push(' ');
            qo(out, key.as_deref());
        }
        Ref::Session { id } => {
            out.push_str("session ");
            q(out, id);
        }
        Ref::Output { channel } => {
            out.push_str("output ");
            q(out, channel);
        }
    }
    out.push('\n');
}

fn write_node(out: &mut String, depth: usize, n: &SnapNode) {
    let pad = " ".repeat(depth);
    match n {
        SnapNode::Split {
            axis,
            children,
            weights,
        } => {
            let a = if *axis == Axis::Row { "row" } else { "column" };
            let _ = write!(out, "{pad}split {a} {}", children.len());
            for w in weights {
                let _ = write!(out, " {w}");
            }
            out.push('\n');
            for c in children {
                write_node(out, depth + 1, c);
            }
        }
        SnapNode::Leaf(g) => {
            let act = g.active.map_or("-".to_string(), |a| a.to_string());
            let _ = writeln!(out, "{pad}group {act} {}", g.tabs.len());
            for t in &g.tabs {
                write_tab(out, depth + 1, "tab", t);
            }
        }
    }
}

fn opt_idx(v: Option<usize>) -> String {
    v.map_or("-".to_string(), |x| x.to_string())
}

impl Workbench {
    /// The layout as text: one OS window, or every one (parked windows are left out).
    pub fn save(&self, w: Option<WinId>) -> String {
        let mut out = String::from(HEADER);
        out.push('\n');
        for (wi, win) in self.windows.iter().enumerate() {
            if win.parked.is_some() || w.is_some_and(|x| x != win.id) {
                continue;
            }
            let l = self.take_layout(wi);
            out.push_str("window ");
            q(&mut out, &win.monitor);
            let (units, a, b) = match win.size {
                WinSize::Px { w, h } => ("px", w, h),
                WinSize::Cells { cols, lines } => ("cells", cols, lines),
            };
            let _ = writeln!(out, " {units} {a} {b} {}", win.scale);
            let _ = write!(out, " left {} {} ", u8::from(l.left_visible), l.left_width);
            qo(&mut out, l.left_place.as_deref());
            out.push('\n');
            let _ = writeln!(
                out,
                " right {} {} {}",
                u8::from(l.right_visible),
                l.right_width,
                l.right_tab.name()
            );
            let bact = win
                .bottom
                .active
                .and_then(|a| win.bottom.tabs.iter().position(|x| *x == a));
            let _ = writeln!(
                out,
                " bottom {} {} {}",
                u8::from(l.bottom_visible),
                l.bottom_height,
                opt_idx(bact)
            );
            let _ = writeln!(out, " chrome {}", u8::from(l.chrome_hidden));
            let _ = writeln!(out, " center {} {}", l.active, opt_idx(l.full_size));
            write_node(&mut out, 1, &l.tree);
            for t in &win.bottom.tabs {
                let tab = &self.tabs[t];
                let st = SnapTab {
                    r: tab.r.clone(),
                    preview: false,
                    kind: tab.kind.clone(),
                    title: tab.title.clone(),
                };
                write_tab(&mut out, 1, "btab", &st);
            }
            out.push_str("end\n");
        }
        out
    }
}

/// Split a line into words: quoted strings (escapes undone) and bare words; a bare `-` is None.
fn words(line: &str) -> Result<Vec<Option<String>>, Refusal> {
    let mut v = Vec::new();
    let mut cs = line.trim_start().chars().peekable();
    while let Some(&c) = cs.peek() {
        if c == ' ' {
            cs.next();
            continue;
        }
        if c == '"' {
            cs.next();
            let mut s = String::new();
            loop {
                match cs.next() {
                    Some('"') => break,
                    Some('\\') => match cs.next() {
                        Some('n') => s.push('\n'),
                        Some(x) => s.push(x),
                        None => return refuse("an escape at the end of a line"),
                    },
                    Some(x) => s.push(x),
                    None => return refuse("an unclosed string"),
                }
            }
            v.push(Some(s));
        } else {
            let mut s = String::new();
            while let Some(&x) = cs.peek() {
                if x == ' ' {
                    break;
                }
                s.push(x);
                cs.next();
            }
            v.push(if s == "-" { None } else { Some(s) });
        }
    }
    Ok(v)
}

struct Lines<'a> {
    lines: Vec<&'a str>,
    i: usize,
}

impl Lines<'_> {
    fn next(&mut self, word: &str) -> Result<Vec<Option<String>>, Refusal> {
        let Some(l) = self.lines.get(self.i) else {
            return refuse(format!("the layout ends where `{word}` was expected"));
        };
        self.i += 1;
        let w = words(l)?;
        if w.first().and_then(|x| x.as_deref()) != Some(word) {
            return refuse(format!("line {}: `{word}` expected", self.i));
        }
        Ok(w)
    }

    fn peek_word(&self) -> Option<String> {
        let l = self.lines.get(self.i)?;
        l.split_whitespace().next().map(str::to_string)
    }
}

fn s(w: &[Option<String>], i: usize) -> Result<String, Refusal> {
    match w.get(i) {
        Some(Some(x)) => Ok(x.clone()),
        _ => refuse(format!("field {i} missing")),
    }
}

fn o(w: &[Option<String>], i: usize) -> Result<Option<String>, Refusal> {
    match w.get(i) {
        Some(x) => Ok(x.clone()),
        None => refuse(format!("field {i} missing")),
    }
}

fn n<T: std::str::FromStr>(w: &[Option<String>], i: usize) -> Result<T, Refusal> {
    s(w, i)?
        .parse()
        .map_err(|_| Refusal::new(format!("field {i} is not a number")))
}

fn on(w: &[Option<String>], i: usize) -> Result<Option<usize>, Refusal> {
    match o(w, i)? {
        Some(x) => x
            .parse()
            .map(Some)
            .map_err(|_| Refusal::new(format!("field {i} is not a number"))),
        None => Ok(None),
    }
}

fn flag(w: &[Option<String>], i: usize) -> Result<bool, Refusal> {
    Ok(n::<u8>(w, i)? != 0)
}

fn read_tab(w: &[Option<String>]) -> Result<SnapTab, Refusal> {
    let preview = s(w, 1)? == "preview";
    let r = match s(w, 4)?.as_str() {
        "file" => Ref::File {
            path: s(w, 5)?,
            at: o(w, 6)?,
        },
        "buffer" => Ref::Buffer {
            id: s(w, 5)?,
            name: s(w, 6)?,
        },
        "page" => Ref::Page {
            page_kind: s(w, 5)?,
            key: o(w, 6)?,
        },
        "session" => Ref::Session { id: s(w, 5)? },
        "output" => Ref::Output { channel: s(w, 5)? },
        x => return refuse(format!("unknown ref `{x}`")),
    };
    Ok(SnapTab {
        r,
        preview,
        kind: s(w, 2)?,
        title: s(w, 3)?,
    })
}

fn read_node(l: &mut Lines) -> Result<SnapNode, Refusal> {
    match l.peek_word().as_deref() {
        Some("split") => {
            let w = l.next("split")?;
            let axis = match s(&w, 1)?.as_str() {
                "row" => Axis::Row,
                "column" => Axis::Column,
                x => return refuse(format!("unknown axis `{x}`")),
            };
            let k: usize = n(&w, 2)?;
            let mut weights = Vec::new();
            for i in 0..k {
                weights.push(n::<f32>(&w, 3 + i)?);
            }
            let mut children = Vec::new();
            for _ in 0..k {
                children.push(read_node(l)?);
            }
            Ok(SnapNode::Split {
                axis,
                children,
                weights,
            })
        }
        _ => {
            let w = l.next("group")?;
            let active = on(&w, 1)?;
            let k: usize = n(&w, 2)?;
            let mut tabs = Vec::new();
            for _ in 0..k {
                tabs.push(read_tab(&l.next("tab")?)?);
            }
            Ok(SnapNode::Leaf(SnapGroup { tabs, active }))
        }
    }
}

/// Read saved text; a version this build does not know is refused.
pub fn load(text: &str) -> Result<Pending, Refusal> {
    let mut l = Lines {
        lines: text.lines().filter(|x| !x.trim().is_empty()).collect(),
        i: 0,
    };
    match l.lines.first() {
        Some(h) if *h == HEADER => l.i = 1,
        Some(h) => return refuse(format!("unknown layout version: {h}")),
        None => return refuse("an empty layout"),
    }
    let mut windows = Vec::new();
    while l.i < l.lines.len() {
        let w = l.next("window")?;
        let size = match s(&w, 2)?.as_str() {
            "px" => WinSize::Px {
                w: n(&w, 3)?,
                h: n(&w, 4)?,
            },
            "cells" => WinSize::Cells {
                cols: n(&w, 3)?,
                lines: n(&w, 4)?,
            },
            x => return refuse(format!("unknown units `{x}`")),
        };
        let monitor = s(&w, 1)?;
        let scale: f32 = n(&w, 5)?;
        let lw = l.next("left")?;
        let rw = l.next("right")?;
        let bw = l.next("bottom")?;
        let cw = l.next("chrome")?;
        let ctw = l.next("center")?;
        let tree = read_node(&mut l)?;
        let mut bottom_tabs = Vec::new();
        while l.peek_word().as_deref() == Some("btab") {
            bottom_tabs.push(read_tab(&l.next("btab")?)?);
        }
        l.next("end")?;
        windows.push(PendingWindow {
            monitor,
            size,
            scale,
            left_visible: flag(&lw, 1)?,
            left_width: n(&lw, 2)?,
            left_place: o(&lw, 3)?,
            right_visible: flag(&rw, 1)?,
            right_width: n(&rw, 2)?,
            right_tab: RightTab::from_name(&s(&rw, 3)?)
                .ok_or_else(|| Refusal::new("unknown right tab"))?,
            bottom_visible: flag(&bw, 1)?,
            bottom_height: n(&bw, 2)?,
            bottom_active: on(&bw, 3)?,
            chrome_hidden: flag(&cw, 1)?,
            active: n(&ctw, 1)?,
            full_size: on(&ctw, 2)?,
            tree,
            bottom_tabs,
        });
    }
    Ok(Pending { windows })
}

impl Workbench {
    /// Start restoring: windows (the existing ones first, in order, then new ones) get their sizes, sides and empty
    /// groups at once; every tab waits for `resolve`. Tabs already open join the first group.
    pub fn restore_begin(&mut self, p: Pending) -> Result<Vec<WinId>, Refusal> {
        let mut ids = Vec::new();
        let mut pending = Vec::new();
        let live: Vec<WinId> = self.windows();
        for (i, pw) in p.windows.into_iter().enumerate() {
            let w = match live.get(i) {
                Some(w) => *w,
                None => self.window_new(
                    &pw.monitor,
                    pw.size,
                    pw.scale,
                    matches!(pw.size, WinSize::Cells { .. }),
                ),
            };
            let wi = self.wi(w)?;
            let old = self.center_tabs(wi);
            let old_groups = self.windows[wi].center.tree.leaves();
            for g in &old_groups {
                for t in self.tabs_of(*g) {
                    self.detach(*g, t);
                }
            }
            let mut leaves = Vec::new();
            let tree = self.pending_tree(w, &pw.tree, &mut pending, &mut leaves);
            for g in old_groups {
                self.groups.remove(&g);
            }
            for t in old {
                self.join_group(leaves[0], t);
            }
            for (k, st) in pw.bottom_tabs.into_iter().enumerate() {
                pending.push(PendingRef {
                    win: w,
                    group: None,
                    pos: k,
                    active: pw.bottom_active == Some(k),
                    tab: st,
                });
            }
            let win = &mut self.windows[wi];
            win.monitor = pw.monitor;
            if matches!(pw.size, WinSize::Cells { .. }) == win.tty {
                win.size = pw.size;
            }
            win.scale = pw.scale;
            win.left.visible = pw.left_visible;
            win.left.width = pw.left_width;
            win.left.place = pw.left_place;
            win.right.visible = pw.right_visible;
            win.right.width = pw.right_width;
            win.right.tab = pw.right_tab;
            win.bottom.visible = pw.bottom_visible;
            win.bottom.height = pw.bottom_height;
            win.chrome_hidden = pw.chrome_hidden;
            win.center.tree = tree;
            win.center.active_group = leaves.get(pw.active).copied().unwrap_or(leaves[0]);
            win.center.full_size = pw.full_size.and_then(|x| leaves.get(x).copied());
            let ag = win.center.active_group;
            self.set_base_focus(wi, crate::model::Focus::Center(ag));
            self.refold(wi);
            ids.push(w);
        }
        self.restore = Restore::Restoring {
            pending,
            pos: BTreeMap::new(),
        };
        self.bump();
        Ok(ids)
    }

    fn pending_tree(
        &mut self,
        w: WinId,
        n: &SnapNode,
        pending: &mut Vec<PendingRef>,
        leaves: &mut Vec<GroupId>,
    ) -> Node {
        match n {
            SnapNode::Split {
                axis,
                children,
                weights,
            } => Node::Split {
                axis: *axis,
                children: children
                    .iter()
                    .map(|c| self.pending_tree(w, c, pending, leaves))
                    .collect(),
                weights: weights.clone(),
            },
            SnapNode::Leaf(sg) => {
                let g = self.new_group(Vec::new());
                leaves.push(g);
                for (k, st) in sg.tabs.iter().enumerate() {
                    pending.push(PendingRef {
                        win: w,
                        group: Some(g),
                        pos: k,
                        active: sg.active == Some(k),
                        tab: st.clone(),
                    });
                }
                Node::Leaf(g)
            }
        }
    }

    /// The refs still waiting.
    pub fn pending_refs(&self) -> Vec<Ref> {
        match &self.restore {
            Restore::Restoring { pending, .. } => pending.iter().map(|p| p.tab.r.clone()).collect(),
            Restore::Finished => Vec::new(),
        }
    }

    pub fn restoring(&self) -> bool {
        matches!(self.restore, Restore::Restoring { .. })
    }

    /// Resolve every waiting entry of a ref.
    pub fn resolve(&mut self, r: &Ref, how: Resolved) -> Result<Version, Refusal> {
        let Restore::Restoring { pending, pos } = &mut self.restore else {
            return refuse("no restore is waiting");
        };
        let (mine, rest): (Vec<PendingRef>, Vec<PendingRef>) = std::mem::take(pending)
            .into_iter()
            .partition(|p| p.tab.r.same(r));
        *pending = rest;
        let mut pos = std::mem::take(pos);
        if mine.is_empty() {
            self.put_pos(pos);
            return refuse("that ref is not waiting");
        }
        for p in mine {
            if how == Resolved::Gone {
                self.notices
                    .push(format!("{}: gone, not restored", p.tab.title));
                continue;
            }
            let t = self.new_tab(
                p.tab.r.clone(),
                p.tab.preview,
                Some(p.tab.kind.clone()),
                Some(p.tab.title.clone()),
            );
            if how == Resolved::Placeholder
                && let Some(tab) = self.tab_mut(t)
            {
                tab.placeholder = true;
            }
            pos.insert(t, p.pos);
            let Ok(wi) = self.wi(p.win) else {
                continue;
            };
            match p.group.filter(|g| self.groups.contains_key(g)) {
                Some(g) => {
                    let at = self.groups[&g]
                        .tabs
                        .iter()
                        .position(|x| pos.get(x).is_some_and(|q| *q > p.pos));
                    self.join_group(g, t);
                    if let Some(i) = at {
                        let grp = self.group_mut(g);
                        grp.tabs.retain(|x| *x != t);
                        grp.tabs.insert(i, t);
                    }
                    if p.active {
                        // the saved left place stands: a restored page tab does not move the left
                        let place = self.windows[wi].left.place.clone();
                        self.activate(wi, g, t);
                        self.windows[wi].left.place = place;
                    }
                }
                None => {
                    let b = &mut self.windows[wi].bottom;
                    let at = b
                        .tabs
                        .iter()
                        .position(|x| pos.get(x).is_some_and(|q| *q > p.pos));
                    match at {
                        Some(i) => b.tabs.insert(i, t),
                        None => b.tabs.push(t),
                    }
                    if p.active || b.active.is_none() {
                        b.active = Some(t);
                    }
                }
            }
        }
        self.put_pos(pos);
        Ok(self.bump())
    }

    fn put_pos(&mut self, p: BTreeMap<TabId, usize>) {
        if let Restore::Restoring { pos, .. } = &mut self.restore {
            *pos = p;
        }
    }

    /// The restore's time is up: refs never resolved open as placeholders, and every placeholder whose kind was never
    /// declared shows "unavailable" with one notice. The restore is finished.
    pub fn restore_tick(&mut self) -> Version {
        let waiting = self.pending_refs();
        for r in waiting {
            let _ = self.resolve(&r, Resolved::Placeholder);
        }
        let mut notes = Vec::new();
        for t in self.tabs.values_mut() {
            if !t.placeholder {
                continue;
            }
            let declared = match &t.r {
                Ref::Page { page_kind, .. } => self.kinds.page(page_kind).is_some(),
                _ => true,
            };
            if declared {
                t.placeholder = false;
            } else if !t.unavailable {
                t.unavailable = true;
                notes.push(format!(
                    "{}: unavailable (its kind was never declared)",
                    t.title
                ));
            }
        }
        self.notices.extend(notes);
        self.restore = Restore::Finished;
        self.bump()
    }

    /// A user intent during a restore drops what is still waiting (stale state never overrides the user).
    pub(crate) fn discard_pending(&mut self) {
        if let Restore::Restoring { .. } = self.restore {
            self.restore = Restore::Finished;
        }
    }

    pub fn notices(&self) -> &[String] {
        &self.notices
    }

    /// Hand the notices to the caller (Notices lines) and forget them.
    pub fn take_notices(&mut self) -> Vec<String> {
        std::mem::take(&mut self.notices)
    }
}
