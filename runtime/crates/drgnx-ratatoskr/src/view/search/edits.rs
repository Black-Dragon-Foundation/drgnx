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
use runstav::methods::search::{EditSkip, EditSource, SearchEdit};
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
            // a match inside or across the one before (a nested regexp match): the first is kept
            Some(last) if e.byte_start < last.byte_end || (e.byte_start == last.byte_start) => {
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

/// One file's edit set: its edits (none when it has none to write) and what it skipped. Reads the file (blocking)
/// unless the run searched a buffer's text in its place.
pub(super) fn file_edits(plan: FilePlan) -> (Option<Planned>, Vec<EditSkip>) {
    let FilePlan {
        path,
        snap,
        large,
        buffer,
        wants,
    } = plan;
    if large {
        return (None, skip_all(&path, &wants, IN_CHUNKS));
    }
    let (text, source): (Arc<str>, EditSource) = match buffer {
        Some(t) => {
            // the buffer's text the hub holds now: another than the search's when the editor sent it again since
            if let Some(s) = &snap
                && s.tick.is_some()
                && s.xxh3 != Some(xxh3_64(t.as_bytes()))
            {
                return (
                    None,
                    skip_all(&path, &wants, "changed in its buffer since the search"),
                );
            }
            (t, EditSource::Buffer)
        }
        None => {
            let small = std::fs::metadata(&path).map(|m| m.len() <= WRITE_MAX);
            match small {
                Err(_) => return (None, skip_all(&path, &wants, GONE)),
                Ok(false) => return (None, skip_all(&path, &wants, TOO_LARGE)),
                Ok(true) => {}
            }
            let Ok(bytes) = std::fs::read(&path) else {
                return (None, skip_all(&path, &wants, GONE));
            };
            if let Some(why) = unwritable(&bytes) {
                return (None, skip_all(&path, &wants, why));
            }
            if let Some(s) = &snap
                && s.tick.is_none()
                && s.xxh3.is_some_and(|d| d != xxh3_64(&bytes))
            {
                return (None, skip_all(&path, &wants, CHANGED_SINCE_SEARCH));
            }
            // checked UTF-8 above
            let text: Arc<str> = String::from_utf8(bytes).unwrap_or_default().into();
            (text, EditSource::Disk)
        }
    };
    let xxh3 = xxh3_64(text.as_bytes());
    let (edits, skipped) = place(&path, &text, wants);
    let planned = (!edits.is_empty()).then_some(Planned {
        path,
        source,
        edits,
        xxh3,
    });
    (planned, skipped)
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
}
