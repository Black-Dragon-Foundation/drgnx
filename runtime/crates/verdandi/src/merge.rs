//! Merges.  After git has merged two branches, the history unions their documents: Loro merges the two operation sets, so
//! every element keeps its id and the anchors on it stay true.  Where git's text for a file differs from the union (a
//! conflict the user resolved, a rebase or a squash that rewrote the work), one correction is written as new operations
//! by the merging author, and the text the correction inserts that the source branch holds gets that branch's element
//! ids as its provenance.

use crate::apply::spans_of;
use crate::docs::TEXT;
use crate::revert::{char_ids, set_text_range};
use crate::store::{History, Kind, Record, put_update};
use crate::{BranchId, DocId, OpId, PeerId, Result, Span, loro};
use ::loro::ExportMode;
use std::collections::HashMap;

/// Where NEEDLE first occurs in HAY, in characters.
fn find(hay: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

impl History {
    /// Record the merge of SOURCE into TARGET.  GIT_MERGED is git's merged text by path.  Each document of SOURCE is
    /// imported into TARGET's (the union); a file whose union text is not git's gets one correction by AUTHOR at AT.
    /// One `merge` record, with every document's operations in one transaction.
    pub fn record_merge(
        &mut self,
        target: BranchId,
        source: BranchId,
        git_merged: &HashMap<String, String>,
        author: PeerId,
        at: f64,
    ) -> Result<OpId> {
        let mut docs: Vec<DocId> = Vec::new();
        for b in [source, target] {
            let mut st = self
                .conn
                .prepare("select distinct doc from doc_update where branch = ?1 order by doc")?;
            let ids = st
                .query_map([b.0], |r| Ok(DocId(r.get(0)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            for d in ids {
                if !docs.contains(&d) {
                    docs.push(d);
                }
            }
        }
        let (mut spans, mut prov) = (Vec::new(), Vec::new());
        let mut corrected = 0usize;
        for doc in &docs {
            let src = if self.load(*doc, source)? {
                Some(self.live(*doc, source)?.clone())
            } else {
                None
            };
            if !self.load(*doc, target)? {
                // a file the target does not have yet: it starts from the source's operations
                let Some(s) = &src else { continue };
                let bytes = s.export(ExportMode::all_updates()).map_err(loro)?;
                put_update(&self.conn, *doc, target, &bytes)?;
            }
            let d = self.live(*doc, target)?.clone();
            if let Some(s) = &src {
                d.import(&s.export(ExportMode::all_updates()).map_err(loro)?)
                    .map_err(loro)?;
            }
            let Some(git) = git_merged.get(&self.path_of(*doc)?) else {
                continue;
            };
            if d.get_text(TEXT).to_string() == *git {
                continue;
            }
            d.commit();
            d.set_peer_id(author.0).map_err(loro)?;
            let before = d.oplog_vv().get(&author.0).copied().unwrap_or(0);
            let (pos, n) = set_text_range(&d, git)?;
            d.commit();
            let after = d.oplog_vv().get(&author.0).copied().unwrap_or(0);
            if after > before {
                spans.push((
                    *doc,
                    Span {
                        peer: author,
                        start: before as u32,
                        end: after as u32,
                    },
                ));
                corrected += 1;
            }
            if let Some(s) = &src {
                let t = s.get_text(TEXT);
                let (hay, ids) = (t.to_string().chars().collect::<Vec<_>>(), char_ids(&t));
                let ins: Vec<char> = git.chars().skip(pos).take(n).collect();
                let text: String = ins.iter().collect();
                for line in text.split_inclusive('\n') {
                    let line: Vec<char> = line.chars().collect();
                    if let Some(k) = find(&hay, &line) {
                        prov.extend(
                            spans_of(&ids[k..k + line.len()])
                                .into_iter()
                                .map(|p| (*doc, p)),
                        );
                    }
                }
            }
        }
        self.commit_record(
            Record {
                kind: Kind::Merge,
                author,
                cause: Default::default(),
                spans,
                parents: vec![],
                git: None,
                summary: format!("merge, {corrected} files corrected"),
                at,
            },
            target,
            &docs,
            &prov,
        )
    }
}
