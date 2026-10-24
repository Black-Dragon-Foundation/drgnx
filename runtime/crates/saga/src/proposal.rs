//! A hand edit to a view, read back (Task 14b): the diff against the view, the graph operations it comes to, and
//! the parts that map to none.  Pure.
//!
//! The edit is aligned with the view line by line (longest common subsequence).  Every line belongs to the piece of
//! the view it came from; an inserted line belongs to the piece before it.  A piece whose text changed becomes one
//! operation (its new body, and its new status when its text says a different one).  A piece whose lines were all
//! deleted maps to nothing (a record is never retired by an edit): its place in the edited text is `unmapped`.

use crate::status;
use crate::view::{self, ViewModel};
use std::ops::Range;

/// The fields only the user may set.  A line `<field>:` (or `:<field>:`) in an edited piece touches one.
pub const USER_ONLY_FIELDS: [&str; 1] = ["matrix"];

/// What reading an edit came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    /// A unified diff of the edited file against the view (headers stripped).
    pub diff: String,
    /// One operation per changed piece: `id`, `kind`, `seq`, `role` of the piece; `body` its new text; `status` set
    /// only when the new text says a different one; `title` and `source` empty.
    pub ops: Vec<crate::import::GraphOp>,
    /// Byte ranges of the edited file (header included) that map to no operation.
    pub unmapped: Vec<Range<usize>>,
    /// The model's graph version.
    pub base_version: u64,
    /// Ids of the ops that touch a user-only field ([`USER_ONLY_FIELDS`]).
    pub user_only: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Equal(usize, usize),
    Del(usize),
    Ins(usize),
}

fn lines(s: &str) -> Vec<&str> {
    s.split_inclusive('\n').collect()
}

/// Longest cell count the quadratic alignment is run on; a larger middle is one replaced block.
const MAX_CELLS: usize = 16_000_000;

fn align(a: &[&str], b: &[&str]) -> Vec<Step> {
    let pre = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let suf = a[pre..]
        .iter()
        .rev()
        .zip(b[pre..].iter().rev())
        .take_while(|(x, y)| x == y)
        .count();
    let (am, bm) = (&a[pre..a.len() - suf], &b[pre..b.len() - suf]);
    let mut out: Vec<Step> = (0..pre).map(|i| Step::Equal(i, i)).collect();
    if am.len().saturating_mul(bm.len()) > MAX_CELLS {
        out.extend((0..am.len()).map(|i| Step::Del(pre + i)));
        out.extend((0..bm.len()).map(|j| Step::Ins(pre + j)));
    } else {
        let (n, m) = (am.len(), bm.len());
        let w = m + 1;
        let mut t = vec![0u32; (n + 1) * w];
        for i in (0..n).rev() {
            for j in (0..m).rev() {
                t[i * w + j] = if am[i] == bm[j] {
                    t[(i + 1) * w + j + 1] + 1
                } else {
                    t[(i + 1) * w + j].max(t[i * w + j + 1])
                };
            }
        }
        let (mut i, mut j) = (0, 0);
        while i < n || j < m {
            if i < n && j < m && am[i] == bm[j] {
                out.push(Step::Equal(pre + i, pre + j));
                i += 1;
                j += 1;
            } else if i < n && (j >= m || t[(i + 1) * w + j] >= t[i * w + j + 1]) {
                out.push(Step::Del(pre + i));
                i += 1;
            } else {
                out.push(Step::Ins(pre + j));
                j += 1;
            }
        }
    }
    let (an, bn) = (a.len(), b.len());
    out.extend((0..suf).map(|k| Step::Equal(an - suf + k, bn - suf + k)));
    out
}

fn unified(a: &[&str], b: &[&str], steps: &[Step]) -> String {
    const CTX: usize = 3;
    let changed: Vec<usize> = steps
        .iter()
        .enumerate()
        .filter(|(_, s)| !matches!(s, Step::Equal(..)))
        .map(|(k, _)| k)
        .collect();
    let mut out = String::new();
    if changed.is_empty() {
        return out;
    }
    out.push_str("--- view\n+++ edited\n");
    let mut k = 0;
    while k < changed.len() {
        let start = changed[k].saturating_sub(CTX);
        let mut end = changed[k];
        while k + 1 < changed.len() && changed[k + 1] <= end + 2 * CTX + 1 {
            k += 1;
            end = changed[k];
        }
        k += 1;
        let end = (end + CTX + 1).min(steps.len());
        let (mut a0, mut b0, mut an, mut bn) = (None, None, 0, 0);
        let mut body = String::new();
        for s in &steps[start..end] {
            let (ai, bi, tag, text) = match *s {
                Step::Equal(i, j) => (Some(i), Some(j), ' ', a[i]),
                Step::Del(i) => (Some(i), None, '-', a[i]),
                Step::Ins(j) => (None, Some(j), '+', b[j]),
            };
            if let Some(i) = ai {
                a0.get_or_insert(i);
                an += 1;
            }
            if let Some(j) = bi {
                b0.get_or_insert(j);
                bn += 1;
            }
            body.push(tag);
            body.push_str(text);
            if !text.ends_with('\n') {
                body.push_str("\n\\ No newline at end of file\n");
            }
        }
        out.push_str(&format!(
            "@@ -{},{an} +{},{bn} @@\n{body}",
            a0.map_or(0, |x| x + 1),
            b0.map_or(0, |x| x + 1)
        ));
    }
    out
}

fn touches_user_only(text: &str) -> bool {
    text.lines().any(|l| {
        let t = l
            .trim_start()
            .trim_start_matches(['-', '*', '+', '#', ':', ' '])
            .to_lowercase();
        USER_ONLY_FIELDS.iter().any(|f| {
            t.strip_prefix(f)
                .is_some_and(|r| r.trim_start().starts_with([':', '=']))
        })
    })
}

fn static_kind(k: &str) -> &'static str {
    match k {
        "task" => "task",
        "todo" => "todo",
        "plan" => "plan",
        _ => "note",
    }
}

fn static_role(r: &str) -> &'static str {
    match r {
        "head" => "head",
        "task" => "task",
        "section" => "section",
        "row" => "row",
        "block" => "block",
        "item" => "item",
        _ => "rest",
    }
}

/// Read EDITED (the file as a person left it) against VIEW (the file the hub wrote), MODEL being the pieces VIEW
/// shows (with `ids`, `kinds` and `roles` filled, or the ops cannot name their records and none are made).
pub fn read(view: &str, edited: &str, model: &ViewModel) -> Proposal {
    let v = view::strip_header(view);
    let e = view::strip_header(edited);
    let e_off = edited.len() - e.len();
    let (al, bl) = (lines(v), lines(e));
    let steps = align(&al, &bl);
    let diff = unified(&al, &bl, &steps);

    // the part of each old line, by byte offset
    let mut ends = Vec::with_capacity(model.parts.len());
    let mut acc = 0;
    for p in &model.parts {
        acc += p.len();
        ends.push(acc);
    }
    let part_of = |off: usize| {
        ends.iter()
            .position(|&e| off < e)
            .unwrap_or(ends.len().saturating_sub(1))
    };
    let mut a_off = Vec::with_capacity(al.len());
    let mut o = 0;
    for l in &al {
        a_off.push(o);
        o += l.len();
    }
    let n = model.parts.len();
    let mut text = vec![String::new(); n];
    let mut touched = vec![false; n];
    let mut cur = 0usize;
    let mut deleted = vec![false; n];
    for s in &steps {
        if n == 0 {
            break;
        }
        match *s {
            Step::Equal(i, j) => {
                cur = part_of(a_off[i]);
                text[cur].push_str(bl[j]);
            }
            Step::Del(i) => {
                cur = part_of(a_off[i]);
                touched[cur] = true;
                deleted[cur] = true;
            }
            Step::Ins(j) => {
                touched[cur] = true;
                text[cur].push_str(bl[j]);
            }
        }
    }

    // unmapped: a touched piece whose edited text is empty; its place is where the next edited line starts
    let mut unmapped = Vec::new();
    let mut ops = Vec::new();
    let mut user_only = Vec::new();
    let mut b_at: Vec<usize> = vec![0; n];
    // the edited byte offset at which each part's text starts
    {
        let mut pos = 0usize;
        for k in 0..n {
            b_at[k] = pos;
            pos += text[k].len();
        }
    }
    for k in 0..n {
        if !touched[k] {
            continue;
        }
        if text[k].is_empty() {
            if deleted[k] {
                let p = e_off + b_at[k];
                unmapped.push(p..p);
            }
            continue;
        }
        if model.ids.len() != n || model.kinds.len() != n || model.roles.len() != n {
            let p = e_off + b_at[k];
            unmapped.push(p..p + text[k].len());
            continue;
        }
        let (kind, role) = (&model.kinds[k], &model.roles[k]);
        let new_status = status::status_of(kind, role, &text[k]);
        let old_status = status::status_of(kind, role, &model.parts[k]);
        if touches_user_only(&text[k]) {
            user_only.push(model.ids[k].clone());
        }
        ops.push(crate::import::GraphOp {
            id: model.ids[k].clone(),
            kind: static_kind(kind),
            seq: k as u32,
            role: static_role(role),
            title: None,
            status: if new_status != old_status {
                new_status
            } else {
                None
            },
            body: std::mem::take(&mut text[k]),
            source: String::new(),
            task: None,
            parent: None,
            repo: None,
        });
    }
    Proposal {
        diff,
        ops,
        unmapped,
        base_version: model.version,
        user_only,
    }
}
