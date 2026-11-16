//! The three-way merge of a record file with the graph, piece by piece.  The base is what the hub last wrote (or read)
//! of each piece; the file is what is on disk now; the live pieces are the graph's.  A piece changed on one side
//! takes that side; changed on both to different text, the file's text is kept and the piece is flagged; a piece
//! new on either side is kept where it was added.  So a hand edit is never dropped by a regeneration, and a graph
//! change made meanwhile still lands.  Pure: the hub applies the acts and writes the text.

use crate::import::GraphOp;
use std::collections::{HashMap, HashSet};

/// What the hub last wrote or read of one piece: the graph version it was at, and the digests of the piece's text,
/// newest first (the older ones catch an editor saving text it loaded before the hub's last write).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Base {
    pub ver: i64,
    pub hashes: Vec<String>,
}

/// One live piece of the graph's view of the file, in the graph's order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Live {
    pub id: String,
    pub ver: i64,
    pub body: String,
    pub seq: u32,
}

/// What the hub does to the graph after a merge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Act {
    /// The file changed the piece: the graph takes the file's piece.
    Update { id: String, op: GraphOp },
    /// A piece the file added.
    Create(GraphOp),
    /// A piece the file deleted (unchanged in the graph).
    Retire { id: String },
    /// Both sides changed the piece: the file's text (empty when the file deleted it) is kept, and the piece flagged.
    Conflict { id: String, file: String },
}

/// The merge's result: the file's new text, the pieces' ids in that order, what to do to the graph and the
/// flagged ids (in file order).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Merged {
    pub text: String,
    pub order: Vec<String>,
    pub acts: Vec<Act>,
    pub conflicts: Vec<String>,
}

/// The lines of TEXT that set a field only the user may set (`USER_ONLY_FIELDS`), in order.
fn user_only_lines(text: &str) -> Vec<&str> {
    text.lines()
        .filter(|l| {
            let t = l
                .trim_start()
                .trim_start_matches(['-', '*', '+', '#', ':', ' '])
                .to_lowercase();
            crate::proposal::USER_ONLY_FIELDS.iter().any(|f| {
                t.strip_prefix(f)
                    .is_some_and(|r| r.trim_start().starts_with([':', '=']))
            })
        })
        .collect()
}

/// A piece's digest as the base keeps it.
pub fn digest_piece(text: &str) -> String {
    crate::view::digest(text)
}

/// FILE (the pieces on disk now, as `import::ops` made them), BASE (by id) and LIVE (the graph's pieces in order),
/// merged.
pub fn merge(file: &[GraphOp], base: &HashMap<String, Base>, live: &[Live]) -> Merged {
    let live_by: HashMap<&str, &Live> = live.iter().map(|l| (l.id.as_str(), l)).collect();
    let in_file: HashSet<&str> = file.iter().map(|o| o.id.as_str()).collect();
    let mut m = Merged::default();
    let mut out: Vec<(String, String)> = Vec::new(); // (id, text) in the new order
    let conflict = |m: &mut Merged, id: &str, file: &str| {
        m.acts.push(Act::Conflict {
            id: id.to_string(),
            file: file.to_string(),
        });
        m.conflicts.push(id.to_string());
    };
    for f in file {
        let fd = digest_piece(&f.body);
        let (b, l) = (base.get(&f.id), live_by.get(f.id.as_str()));
        match (b, l) {
            (Some(b), Some(l)) => {
                let head = b.hashes.first().map(String::as_str);
                let file_changed = head != Some(fd.as_str());
                let graph_changed = head != Some(digest_piece(&l.body).as_str());
                let stale = file_changed && b.hashes.iter().skip(1).any(|h| *h == fd);
                if !file_changed {
                    out.push((f.id.clone(), l.body.clone()));
                    continue;
                }
                if f.body == l.body {
                    // both sides reached the same text
                } else if stale
                    || graph_changed
                    || user_only_lines(&f.body) != user_only_lines(&l.body)
                {
                    // a field only the user sets is not changed by a file edit: the user resolves it
                    conflict(&mut m, &f.id, &f.body);
                } else {
                    m.acts.push(Act::Update {
                        id: f.id.clone(),
                        op: f.clone(),
                    });
                }
                out.push((f.id.clone(), f.body.clone()));
            }
            (Some(b), None) => {
                // the graph retired it: gone, unless the file changed it meanwhile
                if b.hashes.first() != Some(&fd) {
                    conflict(&mut m, &f.id, &f.body);
                    out.push((f.id.clone(), f.body.clone()));
                }
            }
            (None, Some(l)) => {
                if l.body != f.body {
                    conflict(&mut m, &f.id, &f.body);
                }
                out.push((f.id.clone(), f.body.clone()));
            }
            (None, None) => {
                m.acts.push(Act::Create(f.clone()));
                out.push((f.id.clone(), f.body.clone()));
            }
        }
    }
    // pieces the file deleted
    for l in live {
        if in_file.contains(l.id.as_str()) {
            continue;
        }
        if let Some(b) = base.get(&l.id) {
            if b.hashes.first() == Some(&digest_piece(&l.body)) {
                m.acts.push(Act::Retire { id: l.id.clone() });
            } else {
                conflict(&mut m, &l.id, "");
            }
        }
    }
    // pieces the graph added: after the nearest piece before them in the graph's order that the text has
    let mut prev: Option<&str> = None;
    for l in live {
        if !in_file.contains(l.id.as_str()) && !base.contains_key(&l.id) {
            let at = prev
                .and_then(|p| out.iter().position(|(id, _)| id == p))
                .map_or(0, |i| i + 1);
            out.insert(at, (l.id.clone(), l.body.clone()));
        }
        if out.iter().any(|(id, _)| *id == l.id) {
            prev = Some(l.id.as_str());
        }
    }
    m.text = out.iter().map(|(_, t)| t.as_str()).collect();
    m.order = out.into_iter().map(|(id, _)| id).collect();
    m
}
