//! A run's rows and model: a file's header row and node (`f:FILE`, FILE relative to the root), a match's row and node
//! (`m:RUN:N`), the model's window, and the rows the window of rows holds.

use super::Run;
use super::group::{Ent, Layout};
use super::run::{Found, Mark, match_id};
use crate::search::context::Def;
use crate::view::model::Doc;
use drgnx_rows::{Row, RowBuilder};
use hrafn::grep::{self, Match, Query};
use serde_json::{Value, json};
use std::path::Path;

/// A preview keeps this much of the text before a match, and cuts longer text to its tail after an ellipsis.
const BEFORE_KEPT: usize = 16;

/// The gap row's key: the rows between the first ones sent and a far block (`fill` sends them).
pub(super) const GAP: &str = "gap";

/// The entries (files and matches) a search's model holds; past them its list `order` is a window of the first ones
/// (Sjá takes no longer list unwindowed).
pub(super) const MODEL_WINDOW: usize = 20_000;

/// The window of the model a regroup sends first: the first rows draw after Sjá takes this much, and the editor asks
/// for the whole window (`view/window`) once they are drawn (a regroup re-parents every node: spec §8's 50 ms).
pub(super) const FIRST_MODEL_WINDOW: usize = 2_000;

fn flat(s: &str) -> String {
    s.replace('\n', "⏎")
}

fn match_json(m: &Match) -> Value {
    json!({"file": m.file, "line": m.line, "col": m.col, "end": m.end, "text": m.text,
           "before": m.before, "after": m.after})
}

/// FILE's header: its tick box, its name, the folder (relative to the root) after it, and when its buffer is too large
/// to send (LARGE) that its matches are the file's on disk.
pub(super) fn header(root: &Path, file: &str, large: bool) -> Row {
    header_at(root, file, large, 0, true)
}

/// [`header`] DEPTH steps in, with its folder after the name when DIR (not under a folder row).
fn header_at(root: &Path, file: &str, large: bool, depth: usize, show_dir: bool) -> Row {
    let path = Path::new(file);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let dir = path
        .parent()
        .and_then(|d| d.strip_prefix(root).ok())
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut b = RowBuilder::new(file_id(root, file));
    b.push(&"  ".repeat(depth), None);
    let p = b.pos();
    b.push("[x]", None)
        .prop(p, p + 3, "drgnx-replace-box", json!(file));
    b.push(" ", None).push(&name, None);
    if show_dir && !dir.is_empty() {
        b.push(&format!("  {dir}/"), Some("drgnx-replace-dim"));
    }
    if large {
        b.push(
            "  open in chunks: searched on disk",
            Some("drgnx-replace-dim"),
        );
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-file", json!(file));
    b.prop(0, end, "drgnx-work-id", json!(file_id(root, file)));
    b.finish()
}

/// FILE as the ids name it: relative to the search's ROOT when under it, else whole, as the editor's
/// `drgnx-replace--key-path` makes it.  A window move sends thousands of ids (removed, added, spliced, parents):
/// with the whole path in each, the paths were 44 % of the line.
pub(super) fn key_path<'a>(root: &Path, file: &'a str) -> &'a str {
    let root = root.to_string_lossy();
    let root = root.strip_suffix('/').unwrap_or(&root);
    file.strip_prefix(root)
        .and_then(|rest| rest.strip_prefix('/'))
        .filter(|rest| !rest.is_empty())
        .unwrap_or(file)
}

/// FILE's node id (and its header row's key), in a search of ROOT.
pub(super) fn file_id(root: &Path, file: &str) -> String {
    format!("f:{}", key_path(root, file))
}

/// The entries (files and matches) of FILES.
pub(super) fn entries_of(files: &[Found]) -> usize {
    files.iter().map(|f| 1 + f.ms.len()).sum()
}

/// FILE's node in the model of a search of ROOT: its id and wire object (the whole path in `path`).
fn file_node(root: &Path, file: &str, parent: Option<&str>) -> (String, Value) {
    let fid = file_id(root, file);
    let name = Path::new(file)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut node = json!({"id": fid, "kind": "file", "flags": 1,
                          "fields": [["label", name], ["path", file]]});
    if let Some(p) = parent {
        node["parent"] = json!(p);
    }
    (fid, node)
}

/// A folder's node (a grouped search's `d:`), under folder PARENT.
fn dir_node(root: &Path, d: &super::group::Dir, parent: Option<&str>) -> Value {
    let mut node = json!({"id": d.id, "kind": "folder", "flags": 1,
                          "fields": [["label", d.label], ["path", root.join(&d.path).to_string_lossy()],
                                     ["count", d.n]]});
    if let Some(p) = parent {
        node["parent"] = json!(p);
    }
    node
}

/// A definition's node (a grouped search's `s:`) in FILE, under the file's node FID: its `path` is the file's, as a
/// file node's (a match under it finds its file there).
fn sym_node(s: &super::group::Sym, file: &str, fid: &str) -> Value {
    json!({"id": s.id, "kind": "symbol", "flags": 1, "parent": fid,
           "fields": [["label", s.name.as_deref().unwrap_or(TOP_LEVEL)], ["path", file], ["kind", s.kind],
                      ["count", s.n]]})
}

/// The label of the matches outside any definition (Symbols grouping).
const TOP_LEVEL: &str = "(top level)";

/// M's node (id ID) in the model, a child of the file node FID.  Its file is its parent's `path`, not a field of its
/// own: a window move sends thousands of match nodes, and the path again in each was 15 % of the line.
fn match_node(fid: &str, id: String, m: &Match) -> (String, Value) {
    let node = json!({"id": id, "kind": "match", "flags": 0, "parent": fid,
                      "fields": [["label", format!("{}{}{}", m.before.trim_start(), m.text, m.after)],
                                 ["line", m.line], ["col", m.col], ["end", m.end], ["text", m.text]]});
    (id, node)
}

/// F's batch (of run RUN) as the model's nodes and the ids it adds to `order`.
pub(super) fn batch_nodes(root: &Path, run: u64, f: &Found) -> (Vec<(String, Value)>, Vec<String>) {
    let (fid, node) = file_node(root, &f.file, None);
    let mut nodes = vec![(fid.clone(), node)];
    nodes.extend(
        f.ms.iter()
            .zip(&f.ns)
            .map(|(m, n)| match_node(&fid, match_id(run, *n), m)),
    );
    let ids = nodes.iter().map(|(id, _)| id.clone()).collect();
    (nodes, ids)
}

/// The search's model: a `tree` of FILES (of run RUN) in the rows' order, each open, with its matches as children;
/// past [`MODEL_WINDOW`] entries `order` is a window of them, from FROM (`view/window`; none: the first).
pub(super) fn grep_doc(root: &Path, run: u64, files: &[Found], from: Option<usize>) -> Doc {
    grep_doc_in(root, run, files, MODEL_WINDOW, from)
}

/// The entries of a search's model window: every node id it holds (`held`: the parent of a window that starts inside a
/// file first, outside `order`, then `order`'s ids), where each comes from (a file, and the match or none for the
/// file's own entry), and the window: its total and first entry.
pub(super) struct Window<'a> {
    root: &'a Path,
    pub total: usize,
    pub from: usize,
    pub held: Vec<String>,
    pub order: std::ops::Range<usize>,
    from_files: Vec<(&'a str, Option<&'a Match>)>,
    /// A grouped search's: its layout and files, and each held entry's row in it (`from_files` unused).
    grouped: Option<(&'a Layout, &'a [Found], Vec<u32>)>,
}

impl Window<'_> {
    /// `held[i]`'s wire object.
    pub(super) fn node(&self, i: usize) -> Value {
        if let Some((l, files, at)) = &self.grouped {
            return ent_node(self.root, l, files, at[i] as usize, &self.held[i]);
        }
        match self.from_files[i] {
            (file, None) => file_node(self.root, file, None).1,
            (file, Some(m)) => match_node(&file_id(self.root, file), self.held[i].clone(), m).1,
        }
    }
}

/// The node id of row AT of a grouped search (run RUN of ROOT).
fn ent_id(root: &Path, run: u64, l: &Layout, files: &[Found], at: usize) -> String {
    match l.ents[at] {
        Ent::Dir(k) => l.dirs[k as usize].id.clone(),
        Ent::File(fi) => file_id(root, &files[fi as usize].file),
        Ent::Sym(k) => l.syms[k as usize].id.clone(),
        Ent::Label(fi, j) => format!("c:{run}:{}", files[fi as usize].ns[j as usize]),
        Ent::Match(fi, j) => match_id(run, files[fi as usize].ns[j as usize]),
    }
}

/// The wire object of row AT (node ID) of a grouped search.
fn ent_node(root: &Path, l: &Layout, files: &[Found], at: usize, id: &str) -> Value {
    let run = super::run::parse_match_id(id).map_or(0, |(r, _)| r);
    let parent = l.parents[at].map(|p| ent_id(root, run, l, files, p as usize));
    match l.ents[at] {
        Ent::Dir(k) => dir_node(root, &l.dirs[k as usize], parent.as_deref()),
        Ent::File(fi) => file_node(root, &files[fi as usize].file, parent.as_deref()).1,
        Ent::Sym(k) => {
            let s = &l.syms[k as usize];
            let file = &files[s.file as usize].file;
            sym_node(s, file, &parent.unwrap_or_else(|| file_id(root, file)))
        }
        Ent::Label(..) => Value::Null,
        Ent::Match(fi, j) => {
            let m = &files[fi as usize].ms[j as usize];
            match_node(&parent.unwrap_or_default(), id.to_owned(), m).1
        }
    }
}

/// The entries (nodes) of RUN's model: its files and matches, and a grouped search's folders and definitions.
pub(super) fn run_entries(run: &Run) -> usize {
    match run.layout() {
        Some(l) => l.model.len(),
        None => entries_of(&run.files),
    }
}

/// RUN's model window of at most WINDOW entries from FROM ([`window_of`], grouped or not).
pub(super) fn run_window(run: &Run, window: usize, from: Option<usize>) -> Window<'_> {
    let root = run.query.root.as_path();
    let Some(l) = run.layout() else {
        return window_of(root, run.id, &run.files, window, from);
    };
    let total = l.model.len();
    let from = from.unwrap_or(0).min(total.saturating_sub(window));
    let end = (from + window).min(total);
    let mut at: Vec<u32> = Vec::new();
    // the nodes above the window's first entry, outermost first, outside `order`
    if let Some(first) = l.model.get(from) {
        let mut up = l.parents[*first as usize];
        while let Some(p) = up {
            at.push(p);
            up = l.parents[p as usize];
        }
        at.reverse();
    }
    let outside = at.len();
    at.extend_from_slice(&l.model[from..end]);
    let held = at
        .iter()
        .map(|a| ent_id(root, run.id, l, &run.files, *a as usize))
        .collect::<Vec<_>>();
    Window {
        root,
        total,
        from,
        order: outside..held.len(),
        held,
        from_files: Vec::new(),
        grouped: Some((l, &run.files, at)),
    }
}

/// RUN's model ([`grep_doc`], grouped or not), its window from FROM.
pub(super) fn run_doc(run: &Run, from: Option<usize>) -> Doc {
    run_doc_of(run, MODEL_WINDOW, from)
}

/// RUN's model with a window of at most WINDOW entries from FROM.
pub(super) fn run_doc_of(run: &Run, window: usize, from: Option<usize>) -> Doc {
    doc_of(&run_window(run, window, from))
}

/// FILES' (run RUN) window of at most WINDOW entries from entry FROM (clamped so the window is full): its ids only, no
/// node built.
pub(super) fn window_of<'a>(
    root: &'a Path,
    run: u64,
    files: &'a [Found],
    window: usize,
    from: Option<usize>,
) -> Window<'a> {
    let total = entries_of(files);
    let from = from.unwrap_or(0).min(total.saturating_sub(window));
    let end = from + window;
    let mut w = Window {
        root,
        total,
        from,
        held: Vec::new(),
        order: 0..0,
        from_files: Vec::new(),
        grouped: None,
    };
    let mut parent = false;
    let mut at = 0;
    for f in files {
        if at >= end {
            break;
        }
        let n = 1 + f.ms.len();
        if at + n <= from {
            at += n;
            continue;
        }
        parent |= at < from;
        w.held.push(file_id(root, &f.file));
        w.from_files.push((&f.file, None));
        at += 1;
        let skip = from.saturating_sub(at);
        at += skip;
        for (m, k) in
            f.ms.iter()
                .zip(&f.ns)
                .skip(skip)
                .take(end.saturating_sub(at))
        {
            w.held.push(match_id(run, *k));
            w.from_files.push((&f.file, Some(m)));
            at += 1;
        }
    }
    w.order = usize::from(parent)..w.held.len();
    w
}

/// [`grep_doc`] holding at most WINDOW entries, from entry FROM (clamped so the window is full). A window that starts
/// inside a file holds the file's node too, outside `order`: Sjá shows a match under its file.
pub(super) fn grep_doc_in(
    root: &Path,
    run: u64,
    files: &[Found],
    window: usize,
    from: Option<usize>,
) -> Doc {
    doc_of(&window_of(root, run, files, window, from))
}

/// The model of window W.
fn doc_of(w: &Window) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "tree",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["order"],
            "classes": ["selected", "match", "dim"],
            "flags": ["expanded"],
            "forms": [],
            "start": "order",
        }),
        ..Doc::default()
    };
    for (i, id) in w.held.iter().enumerate() {
        d.nodes.insert(id.clone(), w.node(i));
    }
    let order = w.held[w.order.clone()].to_vec();
    if w.total > order.len() {
        d.windows.insert("order".into(), (w.total, w.from));
    }
    d.lists.insert("order".into(), order);
    d
}

/// M's row (key ID): a tick box, the text around the match (the match struck out and the replacement beside it when
/// REPLACE is not empty and still fits the match), and WHY Replace All skipped it, if it did.
pub(super) fn match_row(
    q: &Query,
    replace: &str,
    id: String,
    m: &Match,
    why: Option<&str>,
    agent: Option<&super::AgentMark>,
) -> Row {
    let before = m.before.trim_start();
    let kept: Vec<char> = before.chars().collect();
    let before = if kept.len() > BEFORE_KEPT {
        format!(
            "…{}",
            kept[kept.len() - (BEFORE_KEPT - 1)..]
                .iter()
                .collect::<String>()
        )
    } else {
        before.to_owned()
    };
    let new = if replace.is_empty() {
        None
    } else {
        grep::new_text(q, &m.text, replace)
    };
    let mut b = RowBuilder::new(id.clone());
    // a match handed to an agent (Ask an Agent) shows the agent's mark in its indent
    match agent {
        Some(a) => b.push(&a.glyph, Some(&a.face)).push(" ", None),
        None => b.push("  ", None),
    };
    let at = b.pos();
    b.push("[x]", None)
        .prop(at, at + 3, "drgnx-replace-box", match_json(m));
    b.push(" ", None).push(&flat(&before), None);
    match new {
        Some(n) => {
            // what the match and its replacement share at either end shows once, untinted
            let (old, new): (Vec<char>, Vec<char>) =
                (m.text.chars().collect(), n.chars().collect());
            let pre = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
            let room = old.len().min(new.len()) - pre;
            let suf = old
                .iter()
                .rev()
                .zip(new.iter().rev())
                .take(room)
                .take_while(|(a, b)| a == b)
                .count();
            let part = |cs: &[char]| flat(&cs.iter().collect::<String>());
            b.push(&part(&old[..pre]), None);
            let gone = &old[pre..old.len() - suf];
            if !gone.is_empty() {
                b.push(&part(gone), Some("drgnx-replace-old"));
            }
            let added = &new[pre..new.len() - suf];
            if !added.is_empty() {
                b.push(&part(added), Some("drgnx-replace-new"));
            }
            b.push(&part(&old[old.len() - suf..]), None);
        }
        None => {
            b.push(&flat(&m.text), Some("drgnx-replace-match"));
        }
    }
    b.push(&flat(&m.after), None);
    if let Some(why) = why {
        b.push(&format!("  — {why}"), Some("drgnx-replace-dim"));
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-match", match_json(m));
    b.prop(0, end, "drgnx-work-id", json!(id));
    b.finish()
}

/// Match N's row (M) in RUN: with an index mode's MARK, a definition's or a hit's row; else its match row, with why
/// Replace All skipped it, if it did.
fn row_of(run: &Run, m: &Match, n: u32, mark: Option<&Mark>) -> Row {
    let id = match_id(run.id, n);
    match mark {
        Some(Mark::Span { more, captures }) => span_row(id, m, *more, captures),
        Some(mark) => marked_row(id, m, mark),
        None => {
            let why = run.reasons.get(&id).map(String::as_str);
            let agent = run.handed.get(&id);
            match_row(&run.query, &run.replace, id, m, why, agent)
        }
    }
}

/// The glyph for a definition of KIND (Hrafn's kinds): a function's `ƒ`, a type's `◇`, a macro's `#`, a variable's
/// or a constant's `≡`, else `•`.
fn kind_icon(kind: &str) -> &'static str {
    match kind {
        "function" | "method" | "constructor" => "ƒ",
        "struct" | "enum" | "union" | "class" | "interface" | "trait" | "type" | "record"
        | "impl" | "module" => "◇",
        "macro" => "#",
        "variable" | "constant" | "static" | "custom" | "face" => "≡",
        _ => "•",
    }
}

/// The cells of a score bar.
const BAR_CELLS: usize = 4;

/// A score bar SHARE (0 to 1) full, in eighths of a cell: the full cells, then the part of the last one, padded with
/// spaces to [`BAR_CELLS`]; a share above 0 shows at least an eighth.
fn bar(share: f64) -> (String, usize) {
    const PARTS: [char; 7] = ['▏', '▎', '▍', '▌', '▋', '▊', '▉'];
    let eighths = (share.clamp(0.0, 1.0) * (BAR_CELLS * 8) as f64).round() as usize;
    let eighths = if share > 0.0 { eighths.max(1) } else { 0 };
    let mut s = "█".repeat(eighths / 8);
    if eighths % 8 > 0 {
        s.push(PARTS[eighths % 8 - 1]);
    }
    let filled = s.chars().count();
    s.push_str(&" ".repeat(BAR_CELLS - filled));
    (s, filled)
}

/// M's row (key ID) in a Pattern search: its first line, the match lit; `+N lines` dim when it runs MORE lines on; its
/// metavariables (CAPTURES) on hover, `$K = …` one a line. The tick box, the match and the id as a match row's.
fn span_row(id: String, m: &Match, more: u32, captures: &[(String, String)]) -> Row {
    let mut b = RowBuilder::new(id.clone());
    b.push("  ", None);
    let at = b.pos();
    b.push("[x]", None)
        .prop(at, at + 3, "drgnx-replace-box", match_json(m));
    b.push(" ", None)
        .push(&flat(m.before.trim_start()), None)
        .push(&flat(&m.text), Some("drgnx-replace-match"))
        .push(&flat(&m.after), None);
    if more > 0 {
        let s = if more == 1 { "" } else { "s" };
        b.push(&format!("  +{more} line{s}"), Some("drgnx-replace-dim"));
    }
    let end = b.pos();
    if !captures.is_empty() {
        let echo: Vec<String> = captures
            .iter()
            .map(|(k, v)| format!("${k} = {}", flat(v)))
            .collect();
        b.prop(0, end, "help-echo", json!(echo.join("\n")));
    }
    b.prop(0, end, "drgnx-replace-match", match_json(m));
    b.prop(0, end, "drgnx-work-id", json!(id));
    b.finish()
}

/// M's row (key ID) in an index mode, by its MARK: a definition's kind icon and signature (the name lit as a match), or
/// a hit's score bar (the score on hover) before its symbol, then the rest of its line, and `(moved)` when its lines
/// moved since they were indexed. The tick box, the match and the id as a match row's.
fn marked_row(id: String, m: &Match, mark: &Mark) -> Row {
    let mut b = RowBuilder::new(id.clone());
    b.push("  ", None);
    let at = b.pos();
    b.push("[x]", None)
        .prop(at, at + 3, "drgnx-replace-box", match_json(m));
    b.push(" ", None);
    match mark {
        Mark::Def { kind, sig } => {
            let at = b.pos();
            b.push(kind_icon(kind), Some("drgnx-replace-kind"));
            b.prop(at, b.pos(), "help-echo", json!(kind));
            b.push(" ", None);
            let sig = flat(sig);
            match sig.find(m.text.as_str()).filter(|_| !m.text.is_empty()) {
                Some(i) => {
                    b.push(&sig[..i], None)
                        .push(&m.text, Some("drgnx-replace-match"))
                        .push(&sig[i + m.text.len()..], None);
                }
                None => {
                    b.push(&sig, None);
                }
            }
        }
        Mark::Score {
            score,
            share,
            moved,
        } => {
            let (cells, filled) = bar(*share);
            let at = b.pos();
            b.push(&cells, None);
            if filled > 0 {
                b.face(at, at + filled as u32, "drgnx-replace-score");
            }
            b.prop(at, b.pos(), "help-echo", json!(format!("score {score:.2}")));
            b.push(" ", None)
                .push(&flat(&m.text), Some("drgnx-replace-kind"))
                .push(&flat(&m.after), None);
            if *moved {
                b.push("  (moved)", Some("drgnx-replace-dim"));
            }
        }
        // drawn by `span_row`
        Mark::Span { .. } => {
            b.push(&flat(&m.text), Some("drgnx-replace-match"));
        }
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-replace-match", match_json(m));
    b.prop(0, end, "drgnx-work-id", json!(id));
    b.finish()
}

/// The label row above match N of RUN, the first in definition D: `ƒ` and its name, dim; the names around it on hover.
/// Not a node: no tick, no `drgnx-work-id`, not a stop for Next Match.
pub(super) fn label_row(run: u64, n: u32, d: &Def) -> Row {
    let mut b = RowBuilder::new(format!("c:{run}:{n}"));
    b.push(&format!("  ƒ {}", flat(&d.name)), Some("drgnx-replace-ctx"));
    let end = b.pos();
    b.prop(0, end, "help-echo", json!(d.path.join(" › ")));
    b.finish()
}

/// The rows of RUN: each file's header, labels and matches (a grouped search's: its layout's).
pub(super) fn rows_total(run: &Run) -> usize {
    match run.layout() {
        Some(l) => l.shown.len(),
        None => run.files.iter().map(Found::rows).sum(),
    }
}

/// Row AT of a grouped search RUN (layout L).
fn ent_row(run: &Run, l: &Layout, at: usize) -> Row {
    let root = run.query.root.as_path();
    let depth = l.depth[at] as usize;
    match l.ents[at] {
        Ent::Dir(k) => {
            let d = &l.dirs[k as usize];
            let mut b = RowBuilder::new(d.id.clone());
            b.push(&"  ".repeat(depth), None);
            // its fold chevron: a click folds or opens it (`search/fold`)
            let p = b.pos();
            b.push(if d.folded { "▸" } else { "▾" }, Some("drgnx-replace-dim"))
                .prop(p, p + 1, "drgnx-replace-fold", json!(d.id));
            b.push(" ", None);
            let p = b.pos();
            b.push("[x]", None)
                .prop(p, p + 3, "drgnx-replace-box", json!(d.id));
            b.push(" ", None)
                .push(&format!("{}/", d.label), Some("drgnx-replace-folder"))
                .push(&format!("  {}", d.n), Some("drgnx-replace-dim"));
            let end = b.pos();
            b.prop(0, end, "drgnx-work-id", json!(d.id));
            b.finish()
        }
        Ent::File(fi) => {
            let f = &run.files[fi as usize];
            header_at(
                root,
                &f.file,
                f.large,
                depth,
                run.group != super::GrepGroup::Tree,
            )
        }
        Ent::Sym(k) => {
            let s = &l.syms[k as usize];
            let mut b = RowBuilder::new(s.id.clone());
            b.push(&"  ".repeat(depth), None);
            let p = b.pos();
            b.push("[x]", None)
                .prop(p, p + 3, "drgnx-replace-box", json!(s.id));
            b.push(" ", None);
            match &s.name {
                Some(name) => {
                    let p = b.pos();
                    b.push(kind_icon(&s.kind), Some("drgnx-replace-kind"));
                    b.prop(p, b.pos(), "help-echo", json!(s.kind));
                    b.push(" ", None)
                        .push(&flat(name), Some("drgnx-replace-symbol"));
                }
                None => {
                    b.push(TOP_LEVEL, Some("drgnx-replace-dim"));
                }
            }
            b.push(&format!("  {}", s.n), Some("drgnx-replace-dim"));
            let end = b.pos();
            b.prop(0, end, "drgnx-work-id", json!(s.id));
            b.finish()
        }
        Ent::Label(fi, j) => {
            let f = &run.files[fi as usize];
            let d = f.labelled(j as usize).expect("a label row's definition");
            indented(label_row(run.id, f.ns[j as usize], d), depth - 1)
        }
        Ent::Match(fi, j) => {
            let f = &run.files[fi as usize];
            let (m, k) = (&f.ms[j as usize], f.ns[j as usize]);
            indented(
                row_of(run, m, k, f.marks.get(j as usize).and_then(Option::as_ref)),
                depth - 1,
            )
        }
    }
}

/// ROW with N more steps of indent before it (its properties moved along).
fn indented(mut row: Row, n: usize) -> Row {
    if n == 0 {
        return row;
    }
    let pad = "  ".repeat(n);
    let k = pad.chars().count() as u32;
    row.text.insert_str(0, &pad);
    for r in &mut row.runs {
        (r.0, r.1) = (r.0 + k, r.1 + k);
    }
    for p in &mut row.props {
        (p.0, p.1) = (p.0 + k, p.1 + k);
    }
    for s in &mut row.stops {
        s.0 += k;
    }
    for i in &mut row.images {
        i.0 += k;
    }
    for s in &mut row.spaces {
        s.0 += k;
    }
    row
}

/// The search's rows AT (a file's header, then its matches, each first match of a definition after its label; files
/// in the order they were complete); none is built before it.
pub(super) fn rows_in(run: &Run, at: std::ops::Range<usize>) -> Vec<Row> {
    if let Some(l) = run.layout() {
        let end = at.end.min(l.shown.len());
        return l.shown[at.start.min(end)..end]
            .iter()
            .map(|i| ent_row(run, l, *i as usize))
            .collect();
    }
    let mut rows = Vec::new();
    let mut i = 0;
    for f in &run.files {
        if i >= at.end {
            break;
        }
        let n = f.rows();
        if i + n <= at.start {
            i += n;
            continue;
        }
        if at.contains(&i) {
            rows.push(header(&run.query.root, &f.file, f.large));
        }
        i += 1;
        for (j, (m, k)) in f.ms.iter().zip(&f.ns).enumerate() {
            if i >= at.end {
                break;
            }
            if let Some(d) = f.labelled(j) {
                if at.contains(&i) {
                    rows.push(label_row(run.id, *k, d));
                }
                i += 1;
                if i >= at.end {
                    break;
                }
            }
            if at.contains(&i) {
                rows.push(row_of(run, m, *k, f.marks.get(j).and_then(Option::as_ref)));
            }
            i += 1;
        }
    }
    rows
}

/// The first LIMIT rows of the search's rows.
pub(super) fn rows_upto(run: &Run, limit: usize) -> Vec<Row> {
    rows_in(run, 0..limit)
}

/// The gap row: N rows between the first ones sent and the block (they come when it is in sight, `fill`).
pub(super) fn gap_row(n: usize) -> Row {
    let mut b = RowBuilder::new(GAP.to_owned());
    b.push(&format!("  ⋯ {n} more"), Some("drgnx-replace-dim"));
    b.finish()
}

/// The row (shown or not) of node KEY in a grouped search RUN (layout L).
pub(super) fn ent_index(run: &Run, l: &Layout, key: &str) -> Option<usize> {
    if let Some(at) = l.at_node.get(key) {
        return Some(*at as usize);
    }
    if let Some((r, n)) = super::run::parse_match_id(key) {
        if r != run.id {
            return None;
        }
        let fi = run.files.iter().position(|f| {
            f.ns.first()
                .zip(f.ns.last())
                .is_some_and(|(a, b)| (*a..=*b).contains(&n))
        })?;
        let j = run.files[fi].ns.binary_search(&n).ok()?;
        return l.match_row(fi, j);
    }
    let fi = run
        .files
        .iter()
        .position(|f| key == file_id(&run.query.root, &f.file))?;
    Some(l.at_file[fi] as usize)
}

/// The position among the search's rows of the row KEY (a file's header or a match), if it is there yet.
pub(super) fn row_index(run: &Run, key: &str) -> Option<usize> {
    if let Some(l) = run.layout() {
        let at = ent_index(run, l, key)?;
        return l.shown_at[at].map(|i| i as usize);
    }
    if let Some((r, n)) = super::run::parse_match_id(key) {
        if r != run.id {
            return None;
        }
        // a file's numbers are one block (a file searched again from its buffer gets a later block in its old place):
        // the file whose block holds N, then N among its matches
        let mut before = 0;
        for f in &run.files {
            if let (Some(first), Some(last)) = (f.ns.first(), f.ns.last())
                && (*first..=*last).contains(&n)
            {
                let j = f.ns.binary_search(&n).ok()?;
                let labels = if f.labels == 0 {
                    0
                } else {
                    (0..=j).filter(|i| f.labelled(*i).is_some()).count()
                };
                return Some(before + 1 + labels + j);
            }
            before += f.rows();
        }
        return None;
    }
    let mut at = 0;
    for f in &run.files {
        if key == file_id(&run.query.root, &f.file) {
            return Some(at);
        }
        at += f.rows();
    }
    None
}
