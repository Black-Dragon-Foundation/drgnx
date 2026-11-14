//! The edit set (`search/edits`, docs/guide/replace.md "How Replace All writes"): what a write of a view's search
//! would change, per file, computed here from the run's matches and the file as it is now.
//!
//! - **Every edit carries its `old` text** and its range twice: lines and character columns for the editor, UTF-8 byte
//!   offsets for the hub. A match whose text is not at its place any more is skipped ("its text changed"); nothing is
//!   written by position alone.
//! - **Overlapping matches**: sorted by start, the first kept, the others skipped "overlaps another match".
//! - **Whole files skipped**: changed since the search (the run's snapshot: its digest), over [`WRITE_MAX`], binary
//!   (a NUL in its first 8 KiB) or not UTF-8, its buffer open in chunks.
//! - [`splice`] writes a file's edits into its text (each found again by its line, columns and `old`) and gives the
//!   inverse edits, in the new text's coordinates: what Undo writes back.

use super::run::{DIGEST_MAX, Snap};
use runstav::methods::search::{
    EditLine, EditLineKind, EditSkip, EditSource, EditedLine, MatchGroups, PreviewAnswer,
    PreviewHunk, SearchEdit,
};
use std::sync::Arc;
use xxhash_rust::xxh3::xxh3_64;

/// A file larger than this is not written here ("too large to write here"; docs/guide/large-files.md).
pub(super) const WRITE_MAX: u64 = DIGEST_MAX;

/// Bytes looked at for a NUL (a binary file).
const BINARY_PROBE: usize = 8 << 10;

/// Why a whole file is not written.
pub(super) const CHANGED_SINCE_SEARCH: &str = "changed on disk since the search";
pub(super) const CHANGED_SINCE_PREVIEW: &str = "changed on disk since the preview";
pub(super) const TOO_LARGE: &str = "too large to write here";
pub(super) const BINARY: &str = "a binary file: not written here";
pub(super) const NOT_UTF8: &str = "not UTF-8 text: not written here";
pub(super) const IN_CHUNKS: &str = "open in chunks: Large File: Open Whole first";
pub(super) const GONE: &str = "the file is gone";
pub(super) const TEXT_CHANGED: &str = "its text changed";
pub(super) const NO_LONGER: &str = "the regexp no longer matches its text";
pub(super) const OVERLAPS: &str = "overlaps another match";
pub(super) const CHANGED_IN_BUFFER: &str = "changed in its buffer since the search";

/// One edit wanted, before it is checked against the text: NEW none when the replacement cannot be made (a regexp
/// that no longer matches the match's text).
#[derive(Clone, Debug)]
pub(super) struct Want {
    pub id: String,
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
    pub old: String,
    pub new: Option<String>,
}

/// One file's edits wanted: its path, the run's snapshot of it (none: the caller named the edits), whether its buffer
/// is open in chunks, the buffer's text the run searched in its place (`search/buffer`).
#[derive(Clone, Debug)]
pub(super) struct FilePlan {
    pub path: String,
    pub snap: Option<Snap>,
    pub large: bool,
    pub buffer: Option<Arc<str>>,
    pub wants: Vec<Want>,
}

/// One file of a change set: its edits, where its text came from and the digest of the text they are based on (the
/// apply's check: "changed since the preview").
#[derive(Clone, Debug)]
pub(crate) struct Planned {
    pub path: String,
    pub source: EditSource,
    pub edits: Vec<SearchEdit>,
    pub xxh3: u64,
}

fn skip_all(path: &str, wants: &[Want], why: &str) -> Vec<EditSkip> {
    wants
        .iter()
        .map(|w| EditSkip {
            id: Some(w.id.clone()),
            path: path.to_owned(),
            why: why.to_owned(),
        })
        .collect()
}

/// Why BYTES (a file's, whole) are not written here; none when they may be.
pub(super) fn unwritable(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() as u64 > WRITE_MAX {
        return Some(TOO_LARGE);
    }
    if bytes[..bytes.len().min(BINARY_PROBE)].contains(&0) {
        return Some(BINARY);
    }
    std::str::from_utf8(bytes).is_err().then_some(NOT_UTF8)
}

/// The byte offset of each line's start in TEXT (line 1 at index 0).
pub(super) fn line_starts(text: &str) -> Vec<usize> {
    std::iter::once(0)
        .chain(text.match_indices('\n').map(|(i, _)| i + 1))
        .collect()
}

/// The byte offset in TEXT of LINE (from 1) and character column COL (from 0); none past the line's end.
fn byte_at(text: &str, starts: &[usize], line: u32, col: u32) -> Option<usize> {
    let s = *starts.get((line as usize).checked_sub(1)?)?;
    let e = starts
        .get(line as usize)
        .map_or(text.len(), |n| n.saturating_sub(1));
    let l = &text[s..e];
    let off = match l.char_indices().nth(col as usize) {
        Some((i, _)) => i,
        None if l.chars().count() == col as usize => l.len(),
        None => return None,
    };
    Some(s + off)
}

/// The line (from 1) and character column (from 0) of byte offset AT in TEXT.
fn place_of(text: &str, starts: &[usize], at: usize) -> (u32, u32) {
    let i = starts.partition_point(|s| *s <= at) - 1;
    (i as u32 + 1, text[starts[i]..at].chars().count() as u32)
}

/// WANTS found in TEXT: the edits (sorted by start, with byte ranges) and the skipped, each with why.
fn place(path: &str, text: &str, wants: Vec<Want>) -> (Vec<SearchEdit>, Vec<EditSkip>) {
    let starts = line_starts(text);
    let mut found = Vec::new();
    let mut skipped = Vec::new();
    for w in wants {
        let skip = |why: &str| EditSkip {
            id: Some(w.id.clone()),
            path: path.to_owned(),
            why: why.to_owned(),
        };
        let range = byte_at(text, &starts, w.line, w.col)
            .zip(byte_at(text, &starts, w.end_line, w.end_col))
            .filter(|(s, e)| s <= e && text.get(*s..*e) == Some(w.old.as_str()));
        let Some((s, e)) = range else {
            skipped.push(skip(TEXT_CHANGED));
            continue;
        };
        let Some(new) = w.new.clone() else {
            skipped.push(skip(NO_LONGER));
            continue;
        };
        found.push(SearchEdit {
            id: w.id,
            line: w.line,
            col: w.col,
            end_line: w.end_line,
            end_col: w.end_col,
            byte_start: s as u64,
            byte_end: e as u64,
            old: w.old,
            new,
        });
    }
    found.sort_by_key(|e| (e.byte_start, e.byte_end));
    let mut edits: Vec<SearchEdit> = Vec::with_capacity(found.len());
    for e in found {
        match edits.last() {
            // a match inside or across the one before (a nested regexp match): the first is kept.  An insertion (an
            // empty range: an undone line deletion) before an edit at the same place is not an overlap; two at one
            // place are
            Some(last)
                if e.byte_start < last.byte_end
                    || (e.byte_start == last.byte_start && e.byte_end == last.byte_end) =>
            {
                skipped.push(EditSkip {
                    id: Some(e.id),
                    path: path.to_owned(),
                    why: OVERLAPS.to_owned(),
                });
            }
            _ => edits.push(e),
        }
    }
    (edits, skipped)
}

/// The text PLAN's edits are made against and where it came from (the buffer's text the run searched in the file's
/// place, else the file, read blocking); else why the whole file is left out.
fn text_of(plan: &FilePlan) -> Result<(Arc<str>, EditSource), &'static str> {
    let FilePlan {
        path,
        snap,
        large,
        buffer,
        ..
    } = plan;
    if *large {
        return Err(IN_CHUNKS);
    }
    if let Some(t) = buffer {
        // the buffer's text the hub holds now: another than the search's when the editor sent it again since
        if let Some(s) = snap
            && s.tick.is_some()
            && s.xxh3 != Some(xxh3_64(t.as_bytes()))
        {
            return Err(CHANGED_IN_BUFFER);
        }
        return Ok((t.clone(), EditSource::Buffer));
    }
    match std::fs::metadata(path).map(|m| m.len() <= WRITE_MAX) {
        Err(_) => return Err(GONE),
        Ok(false) => return Err(TOO_LARGE),
        Ok(true) => {}
    }
    let Ok(bytes) = std::fs::read(path) else {
        return Err(GONE);
    };
    if let Some(why) = unwritable(&bytes) {
        return Err(why);
    }
    if let Some(s) = snap
        && s.tick.is_none()
        && s.xxh3.is_some_and(|d| d != xxh3_64(&bytes))
    {
        return Err(CHANGED_SINCE_SEARCH);
    }
    // checked UTF-8 above
    Ok((
        String::from_utf8(bytes).unwrap_or_default().into(),
        EditSource::Disk,
    ))
}

/// One file's edit set: its edits (none when it has none to write) and what it skipped. Reads the file (blocking)
/// unless the run searched a buffer's text in its place.
pub(super) fn file_edits(plan: FilePlan) -> (Option<Planned>, Vec<EditSkip>) {
    let (text, source) = match text_of(&plan) {
        Ok(t) => t,
        Err(why) => return (None, skip_all(&plan.path, &plan.wants, why)),
    };
    let xxh3 = xxh3_64(text.as_bytes());
    let (edits, skipped) = place(&plan.path, &text, plan.wants);
    let planned = (!edits.is_empty()).then_some(Planned {
        path: plan.path,
        source,
        edits,
        xxh3,
    });
    (planned, skipped)
}

/// The edit an Edit Results line L wants: its old text (one line, or several once a save split it) replaced by its new
/// lines, or deleted with the newline after it (the file's last line, with none after it, is emptied). Checked
/// against the text as any edit is: a line whose text is not at its place any more is skipped ("its text changed").
pub(super) fn line_want(l: &EditedLine) -> Want {
    let end_line = l.line + l.old.matches('\n').count() as u32;
    let end_col = l.old.rsplit('\n').next().unwrap_or("").chars().count() as u32;
    let mut w = Want {
        id: l.line_id.clone(),
        line: l.line,
        col: 0,
        end_line,
        end_col,
        old: l.old.clone(),
        new: Some(l.new.as_ref().map(|v| v.join("\n")).unwrap_or_default()),
    };
    if l.new.is_none() && l.eol {
        w.end_line += 1;
        w.end_col = 0;
        w.old.push('\n');
    }
    w
}

/// One file's part of an Edit Results document: its match lines (from 1, in order, once each), its snapshot, whether
/// its buffer is open in chunks and the buffer's text the hub holds in its place.
#[derive(Clone, Debug)]
pub(super) struct DocPlan {
    pub path: String,
    pub snap: Option<Snap>,
    pub large: bool,
    pub buffer: Option<Arc<str>>,
    pub lines: Vec<u32>,
}

/// PLAN's Edit Results lines, CONTEXT lines around each match line, each source line once (a match line's kind wins),
/// numbered `l:K` from NEXT on; or why the whole file is left out (as a write would leave it). Reads the file
/// (blocking) unless its buffer's text is held.
pub(super) fn doc_lines(
    plan: DocPlan,
    context: u32,
    next: &mut u64,
) -> Result<Vec<EditLine>, EditSkip> {
    let fp = FilePlan {
        path: plan.path.clone(),
        snap: plan.snap.clone(),
        large: plan.large,
        buffer: plan.buffer.clone(),
        wants: Vec::new(),
    };
    let (text, _) = text_of(&fp).map_err(|why| EditSkip {
        id: None,
        path: plan.path.clone(),
        why: why.to_owned(),
    })?;
    let starts = line_starts(&text);
    // a text ending in a newline has no line after it
    let count = if text.is_empty() {
        0
    } else if text.ends_with('\n') {
        starts.len() - 1
    } else {
        starts.len()
    } as u32;
    let mut kinds = std::collections::BTreeMap::new();
    for &l in plan.lines.iter().filter(|l| (1..=count).contains(*l)) {
        for n in l.saturating_sub(context).max(1)..=(l + context).min(count) {
            kinds.entry(n).or_insert(EditLineKind::Context);
        }
        kinds.insert(l, EditLineKind::Match);
    }
    Ok(kinds
        .into_iter()
        .map(|(n, kind)| {
            let s = starts[n as usize - 1];
            let after = starts.get(n as usize).copied();
            let e = after.map_or(text.len(), |a| a - 1);
            let id = format!("l:{next}");
            *next += 1;
            EditLine {
                line_id: id,
                path: plan.path.clone(),
                line: n,
                text: text[s..e].to_owned(),
                kind,
                eol: after.is_some(),
                held: false,
            }
        })
        .collect())
}

/// Lines of context around a preview's hunks: 1, so nearby changes in different definitions are hunks of their own
/// (the mockup's).
const CONTEXT: usize = 1;

/// What a preview knows of a file from its run: each match's definition by id (its first line, from 1, and its name),
/// and the lines of its unticked matches.
#[derive(Debug, Default)]
pub(super) struct Around {
    pub defs: std::collections::HashMap<String, (u32, String)>,
    pub kept: Vec<u32>,
}

/// A definition's head: its first LINE up to its NAME, the paren before the form left out (`defvar
/// drgnx-gateway--pending`, `pub fn queue`); none when the line does not hold the name.
fn def_head(line: &str, name: &str) -> Option<String> {
    let end = line.find(name)? + name.len();
    let head = line[..end].trim_start().trim_start_matches('(');
    Some(head.to_owned())
}

/// One file's preview (`search/preview`): the unified diff of its text before and after its edits, each hunk with the
/// ids of the edits in it and their captures (GROUPS of an edit's old text: a regexp's groups, `None` for one that
/// matched nothing), the head of its first match's definition and its kept lines; the skipped, each with why.
pub(super) fn preview(
    plan: FilePlan,
    groups: impl Fn(&str) -> Vec<Option<String>>,
    around: &Around,
) -> (Option<PreviewAnswer>, Vec<EditSkip>) {
    let (text, _) = match text_of(&plan) {
        Ok(t) => t,
        Err(why) => return (None, skip_all(&plan.path, &plan.wants, why)),
    };
    let path = plan.path.clone();
    let (edits, skipped) = place(&plan.path, &text, plan.wants);
    if edits.is_empty() {
        return (None, skipped);
    }
    let mut new = String::with_capacity(text.len());
    let mut at = 0;
    for e in &edits {
        new.push_str(&text[at..e.byte_start as usize]);
        new.push_str(&e.new);
        at = e.byte_end as usize;
    }
    new.push_str(&text[at..]);
    let diff = similar::TextDiff::from_lines(&*text, new.as_str());
    let (mut plus, mut minus) = (0u32, 0u32);
    for c in diff.iter_all_changes() {
        match c.tag() {
            similar::ChangeTag::Insert => plus += 1,
            similar::ChangeTag::Delete => minus += 1,
            similar::ChangeTag::Equal => {}
        }
    }
    let hunks = diff
        .grouped_ops(CONTEXT)
        .iter()
        .filter_map(|ops| {
            let (first, last) = (ops.first()?, ops.last()?);
            let (old, new) = (
                first.old_range().start..last.old_range().end,
                first.new_range().start..last.new_range().end,
            );
            let mine: Vec<&SearchEdit> = edits
                .iter()
                .filter(|e| old.contains(&(e.line as usize - 1)))
                .collect();
            Some(PreviewHunk {
                old_start: old.start as u32 + 1,
                old_lines: old.len() as u32,
                new_start: new.start as u32 + 1,
                new_lines: new.len() as u32,
                ids: mine.iter().map(|e| e.id.clone()).collect(),
                captures: mine
                    .iter()
                    .map(|e| MatchGroups {
                        id: e.id.clone(),
                        groups: groups(&e.old),
                    })
                    .filter(|g| !g.groups.is_empty())
                    .collect(),
                label: mine.first().and_then(|e| {
                    let (line, name) = around.defs.get(&e.id)?;
                    def_head(text.lines().nth(line.checked_sub(1)? as usize)?, name)
                }),
                kept: around
                    .kept
                    .iter()
                    .copied()
                    .filter(|l| old.contains(&(*l as usize - 1)))
                    .collect(),
            })
        })
        .collect();
    let unified = diff
        .unified_diff()
        .context_radius(CONTEXT)
        .header(&path, &path)
        .to_string();
    (
        Some(PreviewAnswer {
            path,
            diff: unified,
            plus,
            minus,
            hunks,
            skipped: Vec::new(),
        }),
        skipped,
    )
}

/// TEXT with EDITS written (each found again by its line, columns and `old`; one not there refuses the whole), and
/// the inverse edits in the new text's coordinates (the same ids), in order.
pub(super) fn splice(
    text: &str,
    edits: &[SearchEdit],
) -> Result<(String, Vec<SearchEdit>), String> {
    let wants = edits
        .iter()
        .map(|e| Want {
            id: e.id.clone(),
            line: e.line,
            col: e.col,
            end_line: e.end_line,
            end_col: e.end_col,
            old: e.old.clone(),
            new: Some(e.new.clone()),
        })
        .collect();
    let (placed, skipped) = place("", text, wants);
    if let Some(s) = skipped.first() {
        return Err(s.why.clone());
    }
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    let mut spans = Vec::with_capacity(placed.len());
    for e in &placed {
        out.push_str(&text[at..e.byte_start as usize]);
        let s = out.len();
        out.push_str(&e.new);
        spans.push((s, out.len()));
        at = e.byte_end as usize;
    }
    out.push_str(&text[at..]);
    let starts = line_starts(&out);
    let inverse = placed
        .iter()
        .zip(spans)
        .map(|(e, (s, end))| {
            let (line, col) = place_of(&out, &starts, s);
            let (end_line, end_col) = place_of(&out, &starts, end);
            SearchEdit {
                id: e.id.clone(),
                line,
                col,
                end_line,
                end_col,
                byte_start: s as u64,
                byte_end: end as u64,
                old: e.new.clone(),
                new: e.old.clone(),
            }
        })
        .collect();
    Ok((out, inverse))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn want(id: &str, line: u32, col: u32, old: &str, new: &str) -> Want {
        Want {
            id: id.into(),
            line,
            col,
            end_line: line,
            end_col: col + old.chars().count() as u32,
            old: old.into(),
            new: Some(new.into()),
        }
    }

    fn plan(path: &str, wants: Vec<Want>) -> FilePlan {
        FilePlan {
            path: path.into(),
            snap: None,
            large: false,
            buffer: None,
            wants,
        }
    }

    fn whys(s: &[EditSkip]) -> Vec<(String, String)> {
        s.iter()
            .map(|s| (s.id.clone().unwrap_or_default(), s.why.clone()))
            .collect()
    }

    /// [D] Each edit carries character columns for the editor and byte offsets for the hub (a line with multi-byte
    /// characters before the match), and its old text; a match whose text moved is skipped, and so is one a regexp no
    /// longer matches.
    #[test]
    fn edits_carry_both_ranges_and_their_old_text() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a.rs");
        std::fs::write(&f, "été pending\nx pending y\n").unwrap();
        let p = f.to_string_lossy().into_owned();
        let mut gone = want("m:1:2", 2, 0, "pendant", "queued");
        gone.new = Some("q".into());
        let mut no_re = want("m:1:3", 1, 4, "pending", "");
        no_re.new = None;
        let (planned, skipped) = file_edits(plan(
            &p,
            vec![
                want("m:1:0", 1, 4, "pending", "queued"),
                want("m:1:1", 2, 2, "pending", "queued"),
                gone,
            ],
        ));
        let planned = planned.unwrap();
        assert_eq!(planned.source, EditSource::Disk);
        let e = &planned.edits[0];
        assert_eq!((e.line, e.col, e.end_col), (1, 4, 11));
        assert_eq!((e.byte_start, e.byte_end), (6, 13), "é is two bytes");
        assert_eq!((e.old.as_str(), e.new.as_str()), ("pending", "queued"));
        assert_eq!(planned.edits[1].byte_start, 16);
        assert_eq!(whys(&skipped), [("m:1:2".into(), TEXT_CHANGED.into())]);
        let (_, skipped) = file_edits(plan(&p, vec![no_re]));
        assert_eq!(whys(&skipped), [("m:1:3".into(), NO_LONGER.into())]);
    }

    /// [D] A preview is the file's unified diff after its edits: lines added and removed, a hunk per group of nearby
    /// changes (3 lines of context) with the ids of its matches and their groups; a skipped match is not in it.
    #[test]
    fn a_preview_is_the_diff_with_its_hunks_matches_and_groups() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a.txt");
        let text: String = (1..=20).map(|i| format!("line {i} food\n")).collect();
        std::fs::write(&f, &text).unwrap();
        let p = f.to_string_lossy().into_owned();
        let (answer, skipped) = preview(
            plan(
                &p,
                vec![
                    want("m:1:0", 2, 7, "food", "d-f"),
                    want("m:1:1", 3, 7, "food", "d-f"),
                    want("m:1:2", 18, 8, "food", "d-f"),
                    want("m:1:3", 19, 8, "fool", "x"),
                ],
            ),
            |old| vec![Some(old[..1].to_owned()), None],
            &Around::default(),
        );
        let a = answer.unwrap();
        assert_eq!(whys(&skipped), [("m:1:3".into(), TEXT_CHANGED.into())]);
        assert_eq!((a.plus, a.minus), (3, 3));
        assert!(
            a.diff
                .contains("-line 2 food\n-line 3 food\n+line 2 d-f\n+line 3 d-f\n"),
            "{}",
            a.diff
        );
        assert_eq!(a.hunks.len(), 2);
        let h = &a.hunks[0];
        assert_eq!(
            (h.old_start, h.old_lines, h.new_start, h.new_lines),
            (1, 4, 1, 4),
            "1 line of context, as the mockup's hunks"
        );
        assert_eq!(h.ids, ["m:1:0", "m:1:1"]);
        assert_eq!(h.captures[0].groups, [Some("f".to_owned()), None]);
        assert_eq!(a.hunks[1].ids, ["m:1:2"]);
        assert!(a.diff.contains("@@ -17,3 +17,3 @@"), "{}", a.diff);
    }

    /// [D] A definition's head is its first line up to its name, without the paren before it: the form and the name
    /// (`defvar drgnx-gateway--pending`, `pub fn queue`); none when the line does not hold the name.
    #[test]
    fn a_definitions_head_is_its_form_and_name() {
        assert_eq!(
            def_head(
                "(defvar drgnx-gateway--pending (make-hash-table :test #'eq)",
                "drgnx-gateway--pending"
            ),
            Some("defvar drgnx-gateway--pending".to_owned())
        );
        assert_eq!(
            def_head(
                "  (defun drgnx-gateway--queue (p reply)",
                "drgnx-gateway--queue"
            ),
            Some("defun drgnx-gateway--queue".to_owned())
        );
        assert_eq!(
            def_head("    pub fn queue(p: P) {", "queue"),
            Some("pub fn queue".to_owned())
        );
        assert_eq!(def_head("#[derive(Debug)]", "Gateway"), None);
    }

    /// [D] Each hunk is named by its first match's definition (the run's context label), and the lines of the file's
    /// unticked matches inside it are listed: they stay as they are, between the changed lines.
    #[test]
    fn a_preview_hunk_names_its_definition_and_its_kept_lines() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a.txt");
        let text: String = (1..=20).map(|i| format!("line {i} food\n")).collect();
        std::fs::write(&f, &text).unwrap();
        let p = f.to_string_lossy().into_owned();
        let around = Around {
            defs: [("m:1:0".to_owned(), (2, "line".to_owned()))].into(),
            kept: vec![3, 19],
        };
        let (answer, _) = preview(
            plan(
                &p,
                vec![
                    want("m:1:0", 2, 7, "food", "d-f"),
                    want("m:1:1", 4, 7, "food", "d-f"),
                    want("m:1:2", 18, 8, "food", "d-f"),
                ],
            ),
            |_| Vec::new(),
            &around,
        );
        let a = answer.unwrap();
        assert_eq!(a.hunks[0].label.as_deref(), Some("line"));
        assert_eq!(
            a.hunks[0].kept,
            [3],
            "line 3's match is unticked, inside hunk 1"
        );
        assert_eq!(a.hunks[1].label, None, "no definition around line 18");
        assert_eq!(a.hunks[1].kept, [19]);
    }

    /// [D] Overlapping and nested matches: sorted by start, the first kept, the others skipped with today's reason.
    #[test]
    fn overlaps_keep_the_first() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a.txt");
        std::fs::write(&f, "aaaa\n").unwrap();
        let p = f.to_string_lossy().into_owned();
        let (planned, skipped) = file_edits(plan(
            &p,
            vec![
                want("m:1:1", 1, 1, "aa", "b"),
                want("m:1:0", 1, 0, "aaa", "b"),
                want("m:1:2", 1, 0, "a", "c"),
            ],
        ));
        let ids: Vec<_> = planned
            .unwrap()
            .edits
            .iter()
            .map(|e| e.id.clone())
            .collect();
        // the shorter of two at one start first; the one after it that does not overlap it is kept
        assert_eq!(ids, ["m:1:2", "m:1:1"]);
        assert_eq!(whys(&skipped), [("m:1:0".into(), OVERLAPS.into())]);
    }

    /// [D] Whole files skipped: changed since the search (the run's digest), binary, not UTF-8, too large, gone, a
    /// buffer open in chunks; a buffer's text is the source when the run searched it.
    #[test]
    fn whole_files_are_skipped_with_why() {
        let d = tempfile::tempdir().unwrap();
        let w = || vec![want("m:1:0", 1, 0, "ab", "x")];
        let at = |name: &str, bytes: &[u8]| {
            let f = d.path().join(name);
            std::fs::write(&f, bytes).unwrap();
            f.to_string_lossy().into_owned()
        };
        let why = |p: FilePlan| {
            let (planned, s) = file_edits(p);
            assert!(planned.is_none());
            s[0].why.clone()
        };
        let p = at("changed.txt", b"ab\n");
        let snap = Snap {
            size: 3,
            mtime: None,
            inode: 0,
            xxh3: Some(xxh3_64(b"ab\r\n")),
            tick: None,
        };
        assert_eq!(
            why(FilePlan {
                snap: Some(snap),
                ..plan(&p, w())
            }),
            CHANGED_SINCE_SEARCH
        );
        assert_eq!(why(plan(&at("bin", b"ab\0\n"), w())), BINARY);
        assert_eq!(why(plan(&at("latin", b"ab \xe9\n"), w())), NOT_UTF8);
        let big = d.path().join("big");
        std::fs::File::create(&big)
            .unwrap()
            .set_len(WRITE_MAX + 1)
            .unwrap();
        assert_eq!(why(plan(&big.to_string_lossy(), w())), TOO_LARGE);
        assert_eq!(
            why(plan(&d.path().join("none").to_string_lossy(), w())),
            GONE
        );
        assert_eq!(
            why(FilePlan {
                large: true,
                ..plan(&p, w())
            }),
            IN_CHUNKS
        );
        let (planned, _) = file_edits(FilePlan {
            buffer: Some("ab unsaved\n".into()),
            ..plan(&d.path().join("unsaved.txt").to_string_lossy(), w())
        });
        let planned = planned.unwrap();
        assert_eq!(planned.source, EditSource::Buffer);
        assert_eq!(planned.xxh3, xxh3_64(b"ab unsaved\n"));
    }

    /// [D] A splice writes every edit and its inverse puts the text back, across a replacement with a newline in it
    /// (the edits after it move a line down) and multi-byte text; an edit not found refuses the whole.
    #[test]
    fn splice_and_its_inverse_round_trip() {
        let text = "one ünï two\nthree two\n";
        let edits: Vec<SearchEdit> = [
            want("a", 1, 8, "two", "2\nand a half"),
            want("b", 2, 6, "two", "deux"),
            want("c", 1, 4, "ünï", "u"),
        ]
        .into_iter()
        .map(|w| {
            let (mut e, _) = place("", text, vec![w]);
            e.remove(0)
        })
        .collect();
        let (out, inverse) = splice(text, &edits).unwrap();
        assert_eq!(out, "one u 2\nand a half\nthree deux\n");
        assert_eq!(
            (inverse[2].line, inverse[2].col),
            (3, 6),
            "b moved a line down"
        );
        let (back, _) = splice(&out, &inverse).unwrap();
        assert_eq!(back, text);
        assert_eq!(splice("other\n", &edits).unwrap_err(), TEXT_CHANGED);
    }

    fn doc(path: &str, lines: Vec<u32>) -> DocPlan {
        DocPlan {
            path: path.into(),
            snap: None,
            large: false,
            buffer: None,
            lines,
        }
    }

    /// [D] An Edit Results document holds each source line once, however many matches or context windows name it: a
    /// match line is `match` even inside another's context, the windows stop at the file's ends, the ids run on
    /// across files, and the file's last line without a newline says so.
    #[test]
    fn an_edit_doc_holds_each_source_line_once() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a.txt");
        let text: String = (1..=10).map(|i| format!("l{i}\n")).collect();
        std::fs::write(&f, text.trim_end()).unwrap();
        let p = f.to_string_lossy().into_owned();
        let mut next = 5;
        let lines = doc_lines(doc(&p, vec![1, 3, 4, 10]), 1, &mut next).unwrap();
        let got: Vec<(String, u32, &str, EditLineKind, bool)> = lines
            .iter()
            .map(|l| (l.line_id.clone(), l.line, l.text.as_str(), l.kind, l.eol))
            .collect();
        use EditLineKind::{Context as C, Match as M};
        assert_eq!(
            got,
            [
                ("l:5".into(), 1, "l1", M, true),
                ("l:6".into(), 2, "l2", C, true),
                ("l:7".into(), 3, "l3", M, true),
                ("l:8".into(), 4, "l4", M, true),
                ("l:9".into(), 5, "l5", C, true),
                ("l:10".into(), 9, "l9", C, true),
                ("l:11".into(), 10, "l10", M, false),
            ]
        );
        assert_eq!(next, 12);
        let none = doc_lines(doc(&p, vec![2]), 0, &mut next).unwrap();
        assert_eq!(none.len(), 1, "no context: the match lines alone");
        let mut chunks = doc(&p, vec![1]);
        chunks.large = true;
        let skip = doc_lines(chunks, 0, &mut next).unwrap_err();
        assert_eq!((skip.id, skip.why.as_str()), (None, IN_CHUNKS));
    }

    fn line(id: &str, n: u32, old: &str, new: Option<&[&str]>, eol: bool) -> EditedLine {
        EditedLine {
            line_id: id.into(),
            path: runstav::types::AbsPath::new("/x".to_owned()).unwrap(),
            line: n,
            old: old.into(),
            new: new.map(|v| v.iter().map(|s| (*s).to_owned()).collect()),
            eol,
        }
    }

    /// [D] Edit Results lines write as edits: a line typed into several lines replaces the one, a deleted line goes
    /// with its newline (the last line, with none after it, is emptied), a line split by an earlier save is found by
    /// its several old lines, and a line whose text changed underneath is skipped.
    #[test]
    fn edited_lines_split_delete_and_skip_a_changed_line() {
        let text = "a\nb\nc1\nc2\nd\ne";
        let wants = vec![
            line_want(&line("l:0", 1, "a", Some(&["A1", "A2"]), true)),
            line_want(&line("l:1", 2, "b", None, true)),
            line_want(&line("l:2", 3, "c1\nc2", Some(&["C"]), true)),
            line_want(&line("l:3", 5, "x", Some(&["X"]), true)),
            line_want(&line("l:4", 6, "e", None, false)),
        ];
        let (edits, skipped) = place("", text, wants);
        assert_eq!(whys(&skipped), [("l:3".into(), TEXT_CHANGED.into())]);
        let (out, inverse) = splice(text, &edits).unwrap();
        assert_eq!(out, "A1\nA2\nC\nd\n");
        assert_eq!(splice(&out, &inverse).unwrap().0, text);
    }
}
