//! Compaction (Task 17; storage §5.2): parsed entities keep their current version plus one old version per day, and
//! the `link_stat` rows of retired sessions fold into per-file totals.  Authored facts (every other origin) are never
//! touched.  Each batch of [`BATCH`] rows is one writer request, so readers and other writes interleave.

use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

use super::pool::ReadPool;
use super::tx::{Tx, TxMeta};
use super::writer::{WriteError, WriterHandle};

/// Entities (or stat rows) per writer request.
pub const BATCH: usize = 500;

/// What a compaction removed (or, with `dry_run`, would).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    /// Old versions of parsed entities dropped.
    pub versions: u64,
    /// `link_stat` rows folded into a total.
    pub link_stats: u64,
}

/// The suffix of a folded total's kind (`touched` → `touched_total`); the row's `src` and `dst` are both the file.
pub const TOTAL_SUFFIX: &str = "_total";

/// A version of a parsed entity: its entity, version and the tx that wrote it.
type Doomed = (i64, i64, i64);

/// The next parsed entities after CURSOR that have history: at most [`BATCH`], ascending.
fn parsed_with_history(c: &Connection, cursor: i64) -> rusqlite::Result<Vec<i64>> {
    let mut s = c.prepare(
        "select n from entity e where origin = 'parsed' and n > ?1
           and exists (select 1 from entity_hist h where h.n = e.n) order by n limit ?2",
    )?;
    s.query_map(params![cursor, BATCH as i64], |r| r.get(0))?
        .collect()
}

/// The old versions among the parsed entities LO..=HI that a later version of the same (UTC) day makes redundant.
fn doomed_in(c: &Connection, lo: i64, hi: i64) -> rusqlite::Result<Vec<Doomed>> {
    let mut s = c.prepare(
        "select h.n, h.ver, h.tx_from from entity_hist h join tx t on t.id = h.tx_from
         where h.n between ?1 and ?2 and h.n in (select n from entity where origin = 'parsed')
           and exists (select 1 from entity_hist h2 join tx t2 on t2.id = h2.tx_from
                       where h2.n = h.n and h2.ver > h.ver
                         and cast(t2.at / 86400 as integer) = cast(t.at / 86400 as integer))
         order by h.n, h.ver",
    )?;
    s.query_map(params![lo, hi], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect()
}

/// A stat row: source, kind, destination, count, first and last tx.
type Stat = (i64, String, i64, i64, i64, i64);

/// Up to [`BATCH`] stat rows of retired sessions that point at a file and are not totals themselves.
fn foldable(c: &Connection) -> rusqlite::Result<Vec<Stat>> {
    let mut s = c.prepare(
        "select s.src, s.kind, s.dst, s.count, s.first_tx, s.last_tx from link_stat s
           join entity e on e.n = s.src and e.kind = 'session' and e.retired_tx is not null
           join entity f on f.n = s.dst and f.kind = 'file'
          where s.kind not like '%\\_total' escape '\\' limit ?1",
    )?;
    s.query_map(params![BATCH as i64], |r| {
        Ok((
            r.get(0)?,
            r.get(1)?,
            r.get(2)?,
            r.get(3)?,
            r.get(4)?,
            r.get(5)?,
        ))
    })?
    .collect()
}

/// What a compaction would remove: counted on a read connection, nothing written.
pub async fn dry_run(pool: &ReadPool) -> Result<Report, WriteError> {
    pool.with(|c| -> rusqlite::Result<Report> {
        let mut report = Report::default();
        let mut cursor = 0;
        loop {
            let ns = parsed_with_history(c, cursor)?;
            let (Some(&lo), Some(&hi)) = (ns.first(), ns.last()) else {
                break;
            };
            report.versions += doomed_in(c, lo, hi)?.len() as u64;
            cursor = hi;
        }
        report.link_stats = c.query_row(
            "select count(*) from link_stat s
               join entity e on e.n = s.src and e.kind = 'session' and e.retired_tx is not null
               join entity f on f.n = s.dst and f.kind = 'file'
              where s.kind not like '%\\_total' escape '\\'",
            [],
            |r| r.get::<_, i64>(0),
        )? as u64;
        Ok(report)
    })
    .await
    .map_err(|e| WriteError::Sql(e.to_string()))?
    .map_err(WriteError::from)
}

fn drop_versions(tx: &mut Tx<'_>, doomed: &[Doomed]) -> Result<(), WriteError> {
    for &(n, ver, _) in doomed {
        // the kept version of that day takes over the dropped one's span (as it stands now: an earlier drop of this
        // batch may have widened it), so an as-of read finds no gap
        tx.sql().execute(
            "update entity_hist set tx_from = min(tx_from,
                 (select tx_from from entity_hist where n = ?1 and ver = ?2))
              where n = ?1 and ver = (select min(ver) from entity_hist where n = ?1 and ver > ?2)",
            params![n, ver],
        )?;
        tx.sql().execute(
            "delete from entity_hist where n = ?1 and ver = ?2",
            params![n, ver],
        )?;
    }
    Ok(())
}

fn fold(tx: &mut Tx<'_>, rows: &[Stat]) -> Result<(), WriteError> {
    for (src, kind, dst, count, first, last) in rows {
        tx.sql().execute(
            "insert into link_stat (src, kind, dst, count, first_tx, last_tx) values (?1, ?2, ?1, ?3, ?4, ?5)
             on conflict (src, kind, dst) do update set count = count + excluded.count,
               first_tx = min(first_tx, excluded.first_tx), last_tx = max(last_tx, excluded.last_tx)",
            params![dst, format!("{kind}{TOTAL_SUFFIX}"), count, first, last],
        )?;
        tx.sql().execute(
            "delete from link_stat where src = ?1 and kind = ?2 and dst = ?3",
            params![src, kind, dst],
        )?;
    }
    Ok(())
}

/// Compact the store: one writer request per batch (a batch with nothing to do writes nothing, not even a `tx`).
/// META is the caller's (the user's CLI).
pub async fn run(
    writer: &WriterHandle,
    pool: &ReadPool,
    meta: TxMeta,
) -> Result<Report, WriteError> {
    let read = |e: crate::Error| WriteError::Sql(e.to_string());
    let mut report = Report::default();
    let mut cursor = 0;
    loop {
        let (ns, doomed) = pool
            .with(move |c| -> rusqlite::Result<(Vec<i64>, Vec<Doomed>)> {
                let ns = parsed_with_history(c, cursor)?;
                let doomed = match (ns.first(), ns.last()) {
                    (Some(&lo), Some(&hi)) => doomed_in(c, lo, hi)?,
                    _ => Vec::new(),
                };
                Ok((ns, doomed))
            })
            .await
            .map_err(read)??;
        let Some(&hi) = ns.last() else { break };
        cursor = hi;
        if doomed.is_empty() {
            continue;
        }
        report.versions += doomed.len() as u64;
        writer
            .write(meta.clone(), move |tx: &mut Tx<'_>| {
                drop_versions(tx, &doomed)
            })
            .await?;
    }
    loop {
        let rows = pool.with(foldable).await.map_err(read)??;
        if rows.is_empty() {
            break;
        }
        report.link_stats += rows.len() as u64;
        writer
            .write(meta.clone(), move |tx: &mut Tx<'_>| fold(tx, &rows))
            .await?;
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::graph::entity::{self, Changes, EntityNew, Origin};
    use crate::graph::tx::Class;
    use crate::graph::writer::Writer;
    use crate::graph::writer::tests::{opts, rule};
    use crate::graph::{link, pool::ReadPool};

    fn user() -> TxMeta {
        TxMeta::new("user", Class::User, "cli:graph-compact")
    }

    fn spawn(dir: &tempfile::TempDir) -> (Writer, WriterHandle, ReadPool, PathBuf) {
        let path = dir.path().join("work.db");
        let (w, h) = Writer::spawn(&path, opts(16, 1), rule()).unwrap();
        let pool = ReadPool::open(&path, 2);
        (w, h, pool, path)
    }

    fn new(kind: &str, id: &str, origin: Origin) -> EntityNew {
        EntityNew {
            id: id.into(),
            kind: kind.into(),
            project: None,
            title: Some("v0".into()),
            status: None,
            body: None,
            priority: None,
            assignee: None,
            data: serde_json::json!({}),
            origin,
            source: None,
        }
    }

    /// Entity ID of KIND/ORIGIN with EDITS further versions, each in its own tx, the tx times DAYS days apart in
    /// the list's order (an edit at day 0.0 and 0.5 is the same day).
    async fn with_versions(
        h: &WriterHandle,
        kind: &str,
        id: &str,
        origin: Origin,
        days: &[f64],
    ) -> i64 {
        let (kind, id) = (kind.to_string(), id.to_string());
        let n = h
            .write(user(), move |tx: &mut Tx<'_>| {
                Ok(entity::create(tx, new(&kind, &id, origin))?.n)
            })
            .await
            .unwrap()
            .value;
        for (i, day) in days.iter().enumerate() {
            let day = *day;
            h.write(user(), move |tx: &mut Tx<'_>| {
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        title: Some(Some(format!("v{}", i + 1))),
                        ..Changes::default()
                    },
                )?;
                // days apart, the first of them on a fixed midnight
                tx.sql().execute(
                    "update tx set at = ?1 where id = ?2",
                    params![
                        1_700_000_000.0 - 1_700_000_000.0 % 86400.0 + day * 86400.0,
                        tx.id()
                    ],
                )?;
                Ok(())
            })
            .await
            .unwrap();
        }
        n
    }

    async fn count(pool: &ReadPool, sql: impl Into<String>) -> i64 {
        let sql = sql.into();
        pool.with(move |c| c.query_row(&sql, [], |r| r.get::<_, i64>(0)).unwrap())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn compact_never_touches_authored() {
        let dir = tempfile::tempdir().unwrap();
        let (_w, h, pool, _) = spawn(&dir);
        let days = [0.1, 0.2, 0.3, 1.1, 1.2];
        let parsed = with_versions(&h, "plan", "plan:a", Origin::Parsed, &days).await;
        let task = with_versions(&h, "task", "task:a-00001", Origin::Recorded, &days).await;
        let note = with_versions(&h, "note", "note:1", Origin::Inferred, &days).await;
        let hist = |n: i64| format!("select count(*) from entity_hist where n = {n}");
        assert_eq!(count(&pool, hist(parsed)).await, 5);
        let seen = dry_run(&pool).await.unwrap();
        assert_eq!(
            seen,
            Report {
                versions: 2,
                link_stats: 0
            }
        );
        assert_eq!(
            count(&pool, hist(parsed)).await,
            5,
            "a dry run changes nothing"
        );
        let done = run(&h, &pool, user()).await.unwrap();
        assert_eq!(done, seen);
        // the parsed entity keeps the last old version of each day, the authored ones every version
        assert_eq!(count(&pool, hist(parsed)).await, 3);
        assert_eq!(count(&pool, hist(task)).await, 5);
        assert_eq!(count(&pool, hist(note)).await, 5);
        // the span of a dropped version went to the kept one: no gap
        let gaps = count(
            &pool,
            "select count(*) from entity_hist a join entity_hist b on b.n = a.n
               and b.ver = (select min(ver) from entity_hist where n = a.n and ver > a.ver)
             where a.n = (select n from entity where id = 'plan:a') and a.tx_to < b.tx_from",
        )
        .await;
        assert_eq!(gaps, 0);
        assert_eq!(run(&h, &pool, user()).await.unwrap(), Report::default());
    }

    #[tokio::test]
    async fn retired_sessions_stats_fold_into_file_totals() {
        let dir = tempfile::tempdir().unwrap();
        let (_w, h, pool, _) = spawn(&dir);
        let file = h
            .write(user(), |tx: &mut Tx<'_>| {
                Ok(entity::create(tx, new("file", "file:/a", Origin::Inferred))?.n)
            })
            .await
            .unwrap()
            .value;
        let mut sessions = Vec::new();
        for id in ["session:1", "session:2", "session:3"] {
            let n = h
                .write(user(), move |tx: &mut Tx<'_>| {
                    Ok(entity::create(tx, new("session", id, Origin::Recorded))?.n)
                })
                .await
                .unwrap()
                .value;
            sessions.push(n);
            h.write(user(), move |tx: &mut Tx<'_>| {
                link::stat_bump(tx, n, "touched", file)?;
                link::stat_bump(tx, n, "touched", file)
            })
            .await
            .unwrap();
        }
        // sessions 1 and 2 end; 3 is still live
        for n in &sessions[..2] {
            let n = *n;
            h.write(user(), move |tx: &mut Tx<'_>| entity::retire(tx, n))
                .await
                .unwrap();
        }
        assert_eq!(
            dry_run(&pool).await.unwrap(),
            Report {
                versions: 0,
                link_stats: 2
            }
        );
        assert_eq!(run(&h, &pool, user()).await.unwrap().link_stats, 2);
        let total = count(
            &pool,
            "select count from link_stat where kind = 'touched_total' and src = dst",
        )
        .await;
        assert_eq!(total, 4);
        assert_eq!(
            count(
                &pool,
                "select count(*) from link_stat where kind = 'touched'"
            )
            .await,
            1
        );
        assert_eq!(run(&h, &pool, user()).await.unwrap(), Report::default());
    }
}
