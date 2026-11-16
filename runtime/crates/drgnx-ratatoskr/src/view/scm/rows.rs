//! A Source Control view's rows, from its state (pure: the tests build them from a status they write).
//!
//! Keys are tab-separated, the repository's root second: `repos`, `repo⇥ROOT` (a row of the Repositories list),
//! `head⇥ROOT` (a repository's header: its name and buttons), `branch⇥ROOT`, `commit⇥ROOT` (the Commit button),
//! `note⇥ROOT` (no changes, or git's complaint), `sec⇥ROOT⇥SECTION`, `d⇥ROOT⇥SECTION⇥DIR` (a folder, tree view),
//! `f⇥ROOT⇥SECTION⇥PATH`, `graph⇥ROOT`, `c⇥ROOT⇥SHA`, `more⇥ROOT`. Each row carries `drgnx-scm` (what it is: kind,
//! root, section, path, dir, sha) and each button `drgnx-scm-action` (what a click does), which the editor reads.

use super::graph;
use super::status::{Change, Section, Status};
use super::{RepoState, ViewState};
use crate::view::explorer::RowLook;
use crate::view::icons;
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::scm::ViewAs;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// The text of the empty state.
pub const NO_CHANGES: &str = "No changes. Your working tree matches HEAD.";
/// The most rows one section lists; the rest is one row saying how many more.
pub const SECTION_MAX: usize = 5_000;

/// The room a row has: TEXT's width drawn in FACE (none: the view's default), and the px a row may take.
pub struct Room<'a> {
    pub width: &'a dyn Fn(Option<&str>, &str) -> f32,
    pub px: f32,
}

impl Room<'_> {
    /// No bound: every text fits on its row (the tests that read keys and texts).
    pub fn wide() -> Room<'static> {
        Room {
            width: &|_, t| t.chars().count() as f32,
            px: f32::MAX,
        }
    }
}

/// TEXT's words on as many lines as the room holds, each line led by INDENT and measured with it in FACE (a word wider
/// than the room has a line of its own, which the hub's fit cuts).
fn wrap(room: &Room, face: Option<&str>, indent: &str, text: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    for word in text.split(' ').filter(|w| !w.is_empty()) {
        let next = if line.is_empty() {
            word.to_owned()
        } else {
            format!("{line} {word}")
        };
        if !line.is_empty() && (room.width)(face, &format!("{indent}{next}")) > room.px {
            lines.push(format!("{indent}{line}"));
            line = word.to_owned();
        } else {
            line = next;
        }
    }
    lines.push(format!("{indent}{line}"));
    lines
}

/// Rows and the images they name.
struct Out<'a> {
    rows: Vec<Row>,
    images: BTreeMap<ImageId, String>,
    look: &'a RowLook,
    room: &'a Room<'a>,
}

impl Out<'_> {
    /// Icon NAME (a graphical display), else ALT.
    fn icon(&mut self, b: &mut RowBuilder, name: &str, alt: &str) {
        match self
            .look
            .gui
            .and_then(|(_, size, _)| icons::svg(name, size))
        {
            Some((id, svg)) => {
                self.images.insert(id, svg);
                b.image(id, alt);
            }
            None => {
                b.push(alt, None);
            }
        }
    }

    /// A button: icon NAME (ALT on a terminal) that does ACTION, HELP on hover.
    fn button(&mut self, b: &mut RowBuilder, name: &str, alt: &str, action: &str, help: &str) {
        b.push(" ", None);
        let start = b.pos();
        self.icon(b, name, alt);
        let end = b.pos();
        b.prop(start, end, "drgnx-scm-action", json!(action));
        b.prop(start, end, "mouse-face", json!("drgnx-hover"));
        b.prop(start, end, "help-echo", json!(help));
    }

    /// A text button: LABEL in FACE that does ACTION.
    fn text_button(
        &mut self,
        b: &mut RowBuilder,
        label: &str,
        face: &str,
        action: &str,
        help: &str,
    ) {
        let start = b.pos();
        b.push(label, Some(face));
        let end = b.pos();
        b.prop(start, end, "drgnx-scm-action", json!(action));
        b.prop(start, end, "mouse-face", json!("drgnx-hover"));
        b.prop(start, end, "help-echo", json!(help));
    }

    /// The row B, `drgnx-scm` = WHAT over all of it.
    fn finish(&mut self, mut b: RowBuilder, what: Value) {
        let end = b.pos();
        b.prop(0, end, "drgnx-scm", what);
        self.rows.push(b.finish());
    }
}

fn key(parts: &[&str]) -> String {
    parts.join("\t")
}

/// Whether the row KEY is open: sections and folders are unless toggled, the graph and the Repositories list's
/// opposite (the graph starts folded).
pub fn open(state: &ViewState, key: &str) -> bool {
    let folded_first = key.starts_with("graph\t");
    state.toggled.contains(key) == folded_first
}

/// A chevron for OPEN.
fn chevron(out: &mut Out, b: &mut RowBuilder, open: bool) {
    if open {
        out.icon(b, "chevron-down", "▾");
    } else {
        out.icon(b, "chevron-right", "▸");
    }
    b.push(" ", None);
}

/// Where the branch stands: `↓B ↑A`, empty when even.
fn sync_text(st: &Status) -> String {
    let mut s = String::new();
    if st.head.behind > 0 {
        s.push_str(&format!("↓{}", st.head.behind));
    }
    if st.head.ahead > 0 {
        if !s.is_empty() {
            s.push(' ');
        }
        s.push_str(&format!("↑{}", st.head.ahead));
    }
    s
}

/// STATE's rows in LOOK, and the images they name; NOW (seconds since the epoch) dates the graph.
pub fn rows(
    state: &ViewState,
    look: &RowLook,
    room: &Room,
    now: i64,
) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut out = Out {
        rows: Vec::new(),
        images: BTreeMap::new(),
        look,
        room,
    };
    if state.repos.is_empty() {
        let mut b = RowBuilder::new("none");
        b.push(
            if state.scanned {
                "  No git repository in this workspace."
            } else {
                "  Looking for repositories…"
            },
            Some("drgnx-text-muted"),
        );
        out.finish(b, json!({"kind": "none"}));
        return (out.rows, out.images.into_iter().collect());
    }
    let multi = state.repos.len() > 1;
    if multi {
        let open_list = open(state, "repos");
        let mut b = RowBuilder::new("repos");
        chevron(&mut out, &mut b, open_list);
        b.push("SOURCE CONTROL REPOSITORIES", Some("drgnx-scm-section"));
        out.finish(b, json!({"kind": "repos", "key": "repos"}));
        if open_list {
            for r in &state.repos {
                repo_row(&mut out, state, r);
            }
        }
    }
    for r in state.repos.iter().filter(|r| state.selected(r)) {
        repo_block(&mut out, state, r, multi, now);
    }
    (out.rows, out.images.into_iter().collect())
}

/// A row of the Repositories list: the checkbox, the name, the branch, how many changed, the sync badge.
fn repo_row(out: &mut Out, state: &ViewState, r: &RepoState) {
    let root = r.root_str();
    let mut b = RowBuilder::new(key(&["repo", &root]));
    b.push("  ", None);
    let on = state.selected(r);
    let start = b.pos();
    if on {
        out.icon(&mut b, "check", "[x]");
    } else {
        out.icon(&mut b, "square", "[ ]");
    }
    let end = b.pos();
    b.prop(start, end, "drgnx-scm-action", json!("select"));
    b.prop(start, end, "mouse-face", json!("drgnx-hover"));
    b.push(" ", None);
    b.push(&r.found.name, None);
    if let Some(Ok(st)) = &r.status {
        b.push("  ", None);
        b.push(
            st.head.name.as_deref().unwrap_or("(detached)"),
            Some("drgnx-text-muted"),
        );
        let n = st.count();
        if n > 0 {
            b.push(&format!("  {n}"), Some("drgnx-text-muted"));
        }
        let s = sync_text(st);
        if !s.is_empty() {
            b.push(&format!("  {s}"), Some("drgnx-text-muted"));
        }
    }
    out.finish(b, json!({"kind": "repo", "root": root, "selected": on}));
}

fn repo_block(out: &mut Out, state: &ViewState, r: &RepoState, multi: bool, now: i64) {
    let root = r.root_str();
    // the header: the name (with several repositories) and the buttons
    let mut b = RowBuilder::new(key(&["head", &root]));
    b.push(" ", None);
    if multi {
        b.push(&r.found.name, Some("drgnx-scm-section"));
    }
    out.button(&mut b, "check", "✓", "commit", "Commit");
    out.button(&mut b, "refresh-cw", "↻", "refresh", "Refresh");
    out.button(&mut b, "ellipsis", "⋯", "menu", "More Actions…");
    out.finish(b, json!({"kind": "head", "root": root}));
    let st = match &r.status {
        None => {
            let mut b = RowBuilder::new(key(&["note", &root]));
            b.push("  Reading…", Some("drgnx-text-muted"));
            out.finish(b, json!({"kind": "note", "root": root}));
            return;
        }
        Some(Err(e)) => {
            let mut b = RowBuilder::new(key(&["note", &root]));
            b.push(&format!("  git: {e}"), Some("drgnx-text-muted"));
            out.finish(b, json!({"kind": "note", "root": root}));
            return;
        }
        Some(Ok(st)) => st,
    };
    // the branch, and Sync or Publish Branch
    let mut b = RowBuilder::new(key(&["branch", &root]));
    b.push("  ", None);
    let start = b.pos();
    out.icon(&mut b, "git-branch", "⎇");
    b.push(" ", None);
    b.push(st.head.name.as_deref().unwrap_or("(detached)"), None);
    let end = b.pos();
    b.prop(start, end, "drgnx-scm-action", json!("checkout"));
    b.prop(start, end, "mouse-face", json!("drgnx-hover"));
    b.prop(start, end, "help-echo", json!("Checkout to…"));
    let s = sync_text(st);
    if !s.is_empty() {
        b.push(&format!("  {s}"), Some("drgnx-text-muted"));
    }
    if st.head.name.is_some() {
        b.push("  ", None);
        if st.head.upstream.is_none() {
            out.text_button(
                &mut b,
                " Publish Branch ",
                "drgnx-ui-button",
                "publish",
                "Push this branch and track it",
            );
        } else if !s.is_empty() {
            out.text_button(
                &mut b,
                " Sync ",
                "drgnx-ui-button",
                "sync",
                "Pull, then push",
            );
        }
    }
    out.finish(
        b,
        json!({"kind": "branch", "root": root, "branch": st.head.name}),
    );
    // the Commit button (the message is the commit box's)
    let mut b = RowBuilder::new(key(&["commit", &root]));
    b.push("  ", None);
    let on = st.head.name.as_deref().unwrap_or("HEAD");
    out.text_button(
        &mut b,
        &format!("  ✓ Commit on '{on}'  "),
        "drgnx-ui-button-primary",
        "commit",
        "Commit (Ctrl+Enter in the message)",
    );
    out.finish(b, json!({"kind": "commit", "root": root}));
    if st.merge.is_empty() && st.staged.is_empty() && st.changes.is_empty() {
        // wrapped to the side bar's width, never cut: the first row keyed `note⇥ROOT`, the next `note⇥ROOT⇥N`
        let face = Some("drgnx-text-muted");
        for (i, line) in wrap(out.room, face, "  ", NO_CHANGES)
            .into_iter()
            .enumerate()
        {
            let k = if i == 0 {
                key(&["note", &root])
            } else {
                key(&["note", &root, &i.to_string()])
            };
            let mut b = RowBuilder::new(k);
            b.push(&line, face);
            out.finish(b, json!({"kind": "note", "root": root}));
        }
    }
    for s in Section::ALL {
        let list = st.section(s);
        if !list.is_empty() {
            section(out, state, &root, s, list);
        }
    }
    graph_rows(out, state, r, &root, now);
}

/// The section header's group buttons, and each file's.
fn buttons(s: Section) -> &'static [(&'static str, &'static str, &'static str, &'static str)] {
    match s {
        Section::Staged => &[("minus", "−", "unstage", "Unstage")],
        Section::Changes => &[
            ("rotate-ccw", "↶", "discard", "Discard Changes"),
            ("plus", "+", "stage", "Stage"),
        ],
        Section::Merge => &[("plus", "+", "stage", "Stage (mark resolved)")],
    }
}

fn section(out: &mut Out, state: &ViewState, root: &str, s: Section, list: &[Change]) {
    let k = key(&["sec", root, s.id()]);
    let is_open = open(state, &k);
    let mut b = RowBuilder::new(k.clone());
    b.push(" ", None);
    chevron(out, &mut b, is_open);
    b.push(s.title(), Some("drgnx-scm-section"));
    b.push(&format!("  {}", list.len()), Some("drgnx-text-muted"));
    for (icon, alt, action, help) in buttons(s) {
        out.button(
            &mut b,
            icon,
            alt,
            &format!("{action}-all"),
            &format!("{help} All"),
        );
    }
    out.finish(
        b,
        json!({"kind": "section", "root": root, "section": s.id(), "key": k}),
    );
    if !is_open {
        return;
    }
    let shown = &list[..list.len().min(SECTION_MAX)];
    match state.view_as {
        ViewAs::List => {
            for c in shown {
                file_row(out, root, s, c, 2, true);
            }
        }
        ViewAs::Tree => tree(out, state, root, s, shown),
    }
    if list.len() > SECTION_MAX {
        let mut b = RowBuilder::new(key(&["many", root, s.id()]));
        b.push(
            &format!("    {} more not listed", list.len() - SECTION_MAX),
            Some("drgnx-text-muted"),
        );
        out.finish(b, json!({"kind": "note", "root": root}));
    }
}

/// LIST grouped in its folders: a folder row (folding, its buttons acting on all inside), then what is in it.
fn tree(out: &mut Out, state: &ViewState, root: &str, s: Section, list: &[Change]) {
    let mut dirs: BTreeSet<&str> = BTreeSet::new();
    for c in list {
        let mut end = 0;
        while let Some(i) = c.path[end..].find('/') {
            end += i;
            dirs.insert(&c.path[..end]);
            end += 1;
        }
    }
    // walk the paths in order, each folder's row before its first entry
    let mut items: Vec<(&str, Option<&Change>)> = dirs.iter().map(|d| (*d, None)).collect();
    items.extend(list.iter().map(|c| (c.path.as_str(), Some(c))));
    items.sort_by(|a, b| tree_order(a.0, a.1.is_none(), b.0, b.1.is_none()));
    let mut hidden: Option<String> = None;
    for (path, change) in items {
        if let Some(h) = &hidden {
            if path.starts_with(h.as_str()) {
                continue;
            }
            hidden = None;
        }
        let depth = path.matches('/').count();
        match change {
            None => {
                let k = key(&["d", root, s.id(), path]);
                let is_open = open(state, &k);
                let mut b = RowBuilder::new(k.clone());
                b.push(&" ".repeat(2 + 2 * depth), None);
                chevron(out, &mut b, is_open);
                out.icon(&mut b, if is_open { "folder-open" } else { "folder" }, "");
                b.push(" ", None);
                b.push(path.rsplit('/').next().unwrap_or(path), None);
                for (icon, alt, action, help) in buttons(s) {
                    out.button(
                        &mut b,
                        icon,
                        alt,
                        &format!("{action}-dir"),
                        &format!("{help} Folder"),
                    );
                }
                out.finish(
                    b,
                    json!({"kind": "dir", "root": root, "section": s.id(), "dir": path, "key": k}),
                );
                if !is_open {
                    hidden = Some(format!("{path}/"));
                }
            }
            Some(c) => file_row(out, root, s, c, 2 + 2 * depth + 2, false),
        }
    }
}

/// Folders before files at each level, then by name: A's path (a folder when A_DIR) against B's.
fn tree_order(a: &str, a_dir: bool, b: &str, b_dir: bool) -> std::cmp::Ordering {
    let (mut ia, mut ib) = (a.split('/').peekable(), b.split('/').peekable());
    loop {
        match (ia.next(), ib.next()) {
            (Some(x), Some(y)) => {
                // at this level each is a folder when more follows, or it is a folder row
                let xd = ia.peek().is_some() || a_dir;
                let yd = ib.peek().is_some() || b_dir;
                if x != y || xd != yd {
                    return yd.cmp(&xd).then(x.cmp(y));
                }
            }
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (None, None) => return std::cmp::Ordering::Equal,
        }
    }
}

/// A changed file: its icon, its name, its folder dimmed (LIST: the tree shows it), its letter in its git face and
/// its buttons, INDENT columns in.
fn file_row(out: &mut Out, root: &str, s: Section, c: &Change, indent: usize, folder: bool) {
    let mut b = RowBuilder::new(key(&["f", root, s.id(), &c.path]));
    b.push(&" ".repeat(indent), None);
    let (dir, name) = match c.path.rsplit_once('/') {
        Some((d, n)) => (d, n),
        None => ("", c.path.as_str()),
    };
    out.icon(&mut b, icons::file_icon(name), "");
    b.push(" ", None);
    let start = b.pos();
    b.push(name, None);
    let end = b.pos();
    if c.letter == 'D' {
        b.face(start, end, "drgnx-scm-deleted");
    }
    if folder && !dir.is_empty() {
        b.push(&format!("  {dir}"), Some("drgnx-text-muted"));
    }
    if let Some(o) = &c.orig {
        b.push(&format!("  ← {o}"), Some("drgnx-text-muted"));
    }
    b.push("  ", None);
    let letter = c.letter.to_string();
    let start = b.pos();
    b.push(&letter, Some(c.kind.face()));
    let end = b.pos();
    b.prop(start, end, "drgnx-git-status", json!(c.kind.name()));
    out.button(&mut b, "file", "o", "open", "Open File");
    for (icon, alt, action, help) in buttons(s) {
        out.button(&mut b, icon, alt, action, help);
    }
    let untracked = c.letter == 'U';
    out.finish(
        b,
        json!({"kind": "file", "root": root, "section": s.id(), "path": c.path, "untracked": untracked,
               "letter": letter}),
    );
}

fn graph_rows(out: &mut Out, state: &ViewState, r: &RepoState, root: &str, now: i64) {
    let k = key(&["graph", root]);
    let is_open = open(state, &k);
    let mut b = RowBuilder::new(k.clone());
    b.push(" ", None);
    chevron(out, &mut b, is_open);
    b.push("Source Control Graph", Some("drgnx-scm-section"));
    out.finish(b, json!({"kind": "graph", "root": root, "key": k}));
    if !is_open {
        return;
    }
    let Some(g) = &r.graph else {
        let mut b = RowBuilder::new(key(&["gnote", root]));
        b.push("    Reading…", Some("drgnx-text-muted"));
        out.finish(b, json!({"kind": "note", "root": root}));
        return;
    };
    for (c, lanes) in g.commits.iter().zip(&g.lanes) {
        let mut b = RowBuilder::new(key(&["c", root, &c.sha]));
        b.push("  ", None);
        b.push(lanes, Some("drgnx-scm-lane"));
        b.push(" ", None);
        if g.incoming.contains(&c.sha) {
            b.push("↓ ", Some("drgnx-scm-incoming"));
        } else if g.outgoing.contains(&c.sha) {
            b.push("↑ ", Some("drgnx-scm-outgoing"));
        }
        b.push(&c.subject, None);
        for r in &c.refs {
            let r = r.strip_prefix("HEAD -> ").unwrap_or(r);
            b.push(" ", None);
            b.push(&format!(" {r} "), Some("drgnx-scm-ref"));
        }
        b.push(
            &format!("  {} · {}", c.author, graph::age(c.time, now)),
            Some("drgnx-text-muted"),
        );
        out.finish(
            b,
            json!({"kind": "commit-row", "root": root, "sha": c.sha, "subject": c.subject}),
        );
    }
    if g.commits.len() >= r.graph_limit {
        let mut b = RowBuilder::new(key(&["more", root]));
        b.push("    ", None);
        out.text_button(
            &mut b,
            "Load more…",
            "drgnx-text-muted",
            "more",
            "The next 200 commits",
        );
        out.finish(b, json!({"kind": "more", "root": root}));
    }
}
