//! Materialise at a record: every document of a branch as it was after a record, so a user's save or an agent's step
//! is a state that can be written out and run (a bisect's candidates, spec §19.6).  The files a branch never touched are
//! its base commit's; the caller writes those.

use crate::docs::TEXT;
use crate::store::{History, Kind, OpRecord, decode_view};
use crate::{BranchId, DocId, OpId, Result, loro};
use ::loro::{Frontiers, LoroDoc};
use rusqlite::params;

impl History {
    /// The text of every document BRANCH holds, as it was after record AT: `(path, text)`, by document.  A document that
    /// no record up to AT holds and whose first stored text is empty did not exist then, and is left out.
    pub fn texts_after(&mut self, branch: BranchId, at: OpId) -> Result<Vec<(String, String)>> {
        let docs: Vec<DocId> = {
            let mut st = self
                .conn
                .prepare("select distinct doc from doc_update where branch = ?1 order by doc")?;
            st.query_map([branch.0], |r| Ok(DocId(r.get(0)?)))?
                .collect::<std::result::Result<_, _>>()?
        };
        let views = {
            let mut st = self
                .conn
                .prepare("select view_blob from op where id <= ?1 order by id desc")?;
            st.query_map([at.0], |r| r.get::<_, Vec<u8>>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        let views = views
            .iter()
            .map(|v| decode_view(v))
            .collect::<Result<Vec<_>>>()?;
        let mut out = Vec::new();
        for doc in docs {
            let then = views.iter().find_map(|v| {
                v.iter()
                    .find(|(d, b, _)| *d == doc && *b == branch)
                    .map(|(_, _, f)| f.0.clone())
            });
            let text = match then {
                Some(f) => {
                    let live = self.live(doc, branch)?;
                    let f = Frontiers::decode(&f).map_err(loro)?;
                    crate::docs::version_of(live, &f)?
                        .get_text(TEXT)
                        .to_string()
                }
                None => {
                    let seed: Vec<u8> = self.conn.query_row(
                        "select bytes from doc_update where doc = ?1 and branch = ?2 order by seq limit 1",
                        params![doc.0, branch.0],
                        |r| r.get(0),
                    )?;
                    let d = LoroDoc::new();
                    d.import(&seed).map_err(loro)?;
                    let t = d.get_text(TEXT).to_string();
                    if t.is_empty() {
                        continue;
                    }
                    t
                }
            };
            out.push((self.path_of(doc)?, text));
        }
        Ok(out)
    }

    /// BRANCH's records of one of KINDS after record AFTER (every one when none), oldest first: the states a bisect
    /// can stop at (a save, an agent's step; typing between them is not one).
    pub fn records_on(
        &self,
        branch: BranchId,
        after: Option<OpId>,
        kinds: &[Kind],
    ) -> Result<Vec<OpRecord>> {
        let ids: Vec<i64> = {
            let mut st = self
                .conn
                .prepare("select id, kind from op where id > ?1 order by id")?;
            st.query_map([after.map_or(0, |o| o.0)], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })?
            .filter_map(|r| r.ok())
            .filter(|(_, k)| kinds.iter().any(|x| x.as_str() == k))
            .map(|(id, _)| id)
            .collect()
        };
        let mut out = Vec::new();
        for id in ids {
            let rec = self.op(OpId(id))?;
            if rec.view.iter().any(|(_, b, _)| *b == branch) {
                out.push(rec);
            }
        }
        Ok(out)
    }
}
