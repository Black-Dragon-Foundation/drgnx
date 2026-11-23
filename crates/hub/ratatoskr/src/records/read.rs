//! `records/read`: a spec's or decision's head, sections with keys, links and version.

use super::write::{Actor, locate};
use super::{Piece, pieces};
use crate::coord::fail;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::CoordDb;
use runstav::methods::records::{RecordLink, RecordRead, RecordView, SectionView};
use runstav::wire::Error;
use saga::import;
use urdr::graph::entity;
use urdr::graph::schema::SENTINEL;

/// The text of a section piece under its heading line, and the heading's text.
fn split_heading(body: &str) -> (String, String) {
    let (line, rest) = body.split_once('\n').unwrap_or((body, ""));
    (
        line.trim_start_matches('#').trim().to_owned(),
        rest.trim_start_matches('\n').to_owned(),
    )
}

fn view_of(p: &Piece) -> SectionView {
    let (heading, body) = split_heading(&p.body);
    SectionView {
        key: p.data["records"]["key"].as_str().unwrap_or("").to_owned(),
        id: p.id.clone(),
        heading,
        body,
        conflict: !p.data["records"]["conflict"].is_null(),
    }
}

/// The record READ names, as ACTOR may reach it.
pub(crate) async fn read_core(
    db: &CoordDb,
    actor: &Actor,
    p: RecordRead,
) -> Result<RecordView, Error> {
    let (file, kind) = locate(db, p.record.as_str()).await?;
    actor.scope.allows_path(&file).map_err(fail)?;
    let ps = pieces(db, &file).await?;
    let head = ps
        .first()
        .ok_or_else(|| super::err("the record has no pieces"))?;
    let key = import::source_key(&file);
    let (n, id) = (head.n, head.id.clone());
    let (version, links) = db
        .read(move |c| {
            let version: i64 = c.query_row(
                "select coalesce(max(updated_tx), 0) from entity where source = ?1 and retired_tx is null",
                [&key],
                |r| r.get(0),
            )?;
            let mut st = c.prepare(&format!(
                "select src, kind, dst from link where (src = ?1 or dst = ?1) and tx_to = {SENTINEL} order by id"
            ))?;
            let rows: Vec<(i64, String, i64)> = st
                .query_map([n], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<_, _>>()?;
            let mut links = Vec::new();
            for (src, kind, dst) in rows {
                let outgoing = src == n;
                let other = if outgoing { dst } else { src };
                if let Some(e) = entity::by_n(c, other)?.filter(|e| e.retired_tx.is_none()) {
                    links.push(RecordLink {
                        kind,
                        to: e.id,
                        outgoing,
                    });
                }
            }
            Ok((version as u64, links))
        })
        .await
        .map_err(fail)?;
    let title = db
        .read(move |c| Ok(entity::by_id(c, &id)?.and_then(|e| e.title)))
        .await
        .map_err(fail)?;
    Ok(RecordView {
        record: head.id.clone(),
        kind,
        path: file.to_string_lossy().into_owned(),
        title,
        status: head.status.clone(),
        version,
        head: head.body.clone(),
        sections: ps
            .iter()
            .filter(|p| p.role == "section")
            .map(view_of)
            .collect(),
        links,
    })
}

pub(crate) async fn records_read(
    f: &Front,
    c: &Caller,
    p: RecordRead,
) -> Result<RecordView, Error> {
    let scope = crate::runner::effects::scope_of(f, c).await?;
    let actor = Actor {
        meta: crate::coord::tx_meta(c, "records/read"),
        agent: c.class == runstav::registry::Class::Agent,
        scope,
        root: None,
        may_approve: false,
    };
    read_core(&f.writer.db, &actor, p).await
}
