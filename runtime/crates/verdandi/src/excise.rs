//! Excise: take text out of the history for good, keeping every element id.  Each branch's document is exported as JSON
//! updates, the characters to remove become `*` (the same number, so no id, position or anchor moves), and the result is
//! imported into a fresh document that replaces the rows.  Then the file is made to forget: `secure_delete`, `VACUUM`, a
//! full checkpoint of the write-ahead log, and the backups (`VACUUM INTO` copies in `<dir>/backup/`) are deleted, since
//! they hold the old text.  The record says how many characters, never which.

use crate::docs::TEXT;
use crate::revert::char_ids;
use crate::store::{History, Kind, Record, put_op_tx, put_update};
use crate::{BranchId, DocId, Error, OpId, PeerId, Result, loro};
use ::loro::json::{JsonOpContent, TextOp};
use ::loro::{ExportMode, LoroDoc, VersionVector};
use std::collections::{BTreeMap, HashSet};
use std::ops::Range;
use std::path::PathBuf;

/// What to excise.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// These characters of the document as it is now on the branch given.
    Range(Range<usize>),
    /// Every place the text was typed, deleted or not, on any branch (a pattern typed whole, by one author).
    Pattern(String),
}

/// The characters of every insert of a JSON export, by (peer, counter), in runs of consecutive counters.
fn pattern_ids(
    changes: impl Iterator<Item = (u64, i32, String)>,
    pattern: &str,
    kill: &mut HashSet<(u64, i32)>,
) {
    let mut by_peer: BTreeMap<u64, BTreeMap<i32, char>> = BTreeMap::new();
    for (peer, counter, text) in changes {
        let m = by_peer.entry(peer).or_default();
        for (i, c) in text.chars().enumerate() {
            m.insert(counter + i as i32, c);
        }
    }
    let pat: Vec<char> = pattern.chars().collect();
    for (peer, chars) in by_peer {
        // runs of consecutive counters
        let mut runs: Vec<(i32, Vec<char>)> = Vec::new();
        for (counter, c) in chars {
            match runs.last_mut() {
                Some((start, v)) if *start + v.len() as i32 == counter => v.push(c),
                _ => runs.push((counter, vec![c])),
            }
        }
        for (start, v) in runs {
            if v.len() < pat.len() {
                continue;
            }
            for (i, w) in v.windows(pat.len()).enumerate() {
                if w == pat.as_slice() {
                    for k in 0..pat.len() {
                        kill.insert((peer, start + (i + k) as i32));
                    }
                }
            }
        }
    }
}

impl History {
    /// Excise TARGET from DOC (BRANCH names the text a range counts in).  Every branch's copy goes, the ids stay.  One
    /// `excise` record by AUTHOR at AT.
    pub fn excise(
        &mut self,
        doc: DocId,
        branch: BranchId,
        target: &Target,
        author: PeerId,
        at: f64,
    ) -> Result<OpId> {
        let branches: Vec<BranchId> = {
            let mut st = self
                .conn
                .prepare("select distinct branch from doc_update where doc = ?1 order by branch")?;
            st.query_map([doc.0], |r| Ok(BranchId(r.get(0)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        // what is only in memory goes to the rows first
        for b in &branches {
            self.save(doc, *b)?;
        }
        let mut jsons = Vec::new();
        for b in &branches {
            let d = self.live(doc, *b)?.clone();
            jsons.push((
                *b,
                d.export_json_updates_without_peer_compression(
                    &VersionVector::default(),
                    &d.oplog_vv(),
                )
                .map_err(loro)?,
            ));
        }
        let mut kill: HashSet<(u64, i32)> = HashSet::new();
        match target {
            Target::Range(r) => {
                let ids = char_ids(&self.live(doc, branch)?.get_text(TEXT));
                if r.start >= r.end || r.end > ids.len() {
                    return Err(Error::Refused(format!(
                        "{}..{} is not a range of a text of {} characters",
                        r.start,
                        r.end,
                        ids.len()
                    )));
                }
                kill.extend(ids[r.clone()].iter().map(|id| (id.peer, id.counter)));
            }
            Target::Pattern(p) => {
                if p.is_empty() {
                    return Err(Error::Refused("an empty pattern matches everything".into()));
                }
                for (_, js) in &jsons {
                    let inserts = js.changes.iter().flat_map(|ch| {
                        ch.ops.iter().filter_map(move |op| match &op.content {
                            JsonOpContent::Text(TextOp::Insert { text, .. }) => {
                                Some((ch.id.peer, op.counter, text.clone()))
                            }
                            _ => None,
                        })
                    });
                    pattern_ids(inserts, p, &mut kill);
                }
            }
        }
        if kill.is_empty() {
            return Err(Error::Refused("nothing matched".into()));
        }
        let mut fresh = Vec::new();
        for (b, mut js) in jsons {
            for ch in &mut js.changes {
                let peer = ch.id.peer;
                for op in &mut ch.ops {
                    if let JsonOpContent::Text(TextOp::Insert { text, .. }) = &mut op.content {
                        let counter = op.counter;
                        *text = text
                            .chars()
                            .enumerate()
                            .map(|(i, c)| {
                                if kill.contains(&(peer, counter + i as i32)) {
                                    '*'
                                } else {
                                    c
                                }
                            })
                            .collect();
                    }
                }
            }
            let d = LoroDoc::new();
            d.import_json_updates(js).map_err(loro)?;
            fresh.push((b, d.export(ExportMode::all_updates()).map_err(loro)?));
        }
        let path = self.path_of(doc)?;
        let view = self.view()?;
        self.conn.pragma_update(None, "secure_delete", "on")?;
        let tx = self.conn.transaction()?;
        for (b, bytes) in &fresh {
            tx.execute(
                "delete from doc_update where doc = ?1 and branch = ?2",
                [doc.0, b.0],
            )?;
            tx.execute(
                "delete from doc_snapshot where doc = ?1 and branch = ?2",
                [doc.0, b.0],
            )?;
            put_update(&tx, doc, *b, bytes)?;
        }
        // a preview holds text of the files it would change
        tx.execute("delete from preview", [])?;
        let id = put_op_tx(
            &tx,
            &Record {
                kind: Kind::Excise,
                author,
                cause: Default::default(),
                spans: Vec::new(),
                parents: Vec::new(),
                git: None,
                summary: format!("excised {} characters in {path}", kill.len()),
                at,
            },
            &view,
            &[],
        )?;
        tx.commit()?;
        for b in &branches {
            self.forget(doc, *b);
        }
        self.purge_backups()?;
        self.conn.execute_batch("vacuum")?;
        self.conn
            .query_row("pragma wal_checkpoint(truncate)", [], |_| Ok(()))?;
        Ok(id)
    }

    /// A copy of `history.db` as `<dir>/backup/NAME.db` (`VACUUM INTO`).
    pub fn backup(&self, name: &str) -> Result<PathBuf> {
        if name.is_empty() || name.contains(['/', '\\', '\0']) {
            return Err(Error::Refused(format!("{name:?} is not a backup name")));
        }
        let dir = self.dir.join("backup");
        std::fs::create_dir_all(&dir)?;
        let p = dir.join(format!("{name}.db"));
        let path = p
            .to_str()
            .ok_or_else(|| Error::Refused("the backup path is not UTF-8".into()))?;
        self.conn.execute("vacuum into ?1", [path])?;
        std::fs::set_permissions(&p, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
        Ok(p)
    }

    /// Delete every backup: they hold what was just excised.
    fn purge_backups(&self) -> Result<()> {
        let dir = self.dir.join("backup");
        let Ok(rd) = std::fs::read_dir(&dir) else {
            return Ok(());
        };
        for e in rd.flatten() {
            if e.path().is_file() {
                std::fs::remove_file(e.path())?;
            }
        }
        Ok(())
    }
}
