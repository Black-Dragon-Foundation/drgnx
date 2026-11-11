//! A run's rows and model: a file's header row and node (`f:FILE`, FILE relative to the root), a match's row and node
//! (`m:RUN:N`), the model's window, and the rows the window of rows holds.

use super::Run;
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
    b.push("[x]", None)
        .prop(0, 3, "drgnx-replace-box", json!(file));
    b.push(" ", None).push(&name, None);
    if !dir.is_empty() {
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
fn file_node(root: &Path, file: &str) -> (String, Value) {
    let fid = file_id(root, file);
    let name = Path::new(file)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let node = json!({"id": fid, "kind": "file", "flags": 1,
                      "fields": [["label", name], ["path", file]]});
    (fid, node)
}

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
    let (fid, node) = file_node(root, &f.file);
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
}

impl Window<'_> {
    /// `held[i]`'s wire object.
    pub(super) fn node(&self, i: usize) -> Value {
        match self.from_files[i] {
            (file, None) => file_node(self.root, file).1,
            (file, Some(m)) => match_node(&file_id(self.root, file), self.held[i].clone(), m).1,
        }
    }
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
    let w = window_of(root, run, files, window, from);
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

/// The rows of all FILES: each file's header, labels and matches.
pub(super) fn rows_total(files: &[Found]) -> usize {
    files.iter().map(Found::rows).sum()
}

/// The search's rows AT (a file's header, then its matches, each first match of a definition after its label; files
/// in the order they were complete); none is built before it.
pub(super) fn rows_in(run: &Run, at: std::ops::Range<usize>) -> Vec<Row> {
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

/// The position among the search's rows of the row KEY (a file's header or a match), if it is there yet.
pub(super) fn row_index(run: &Run, key: &str) -> Option<usize> {
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
