//! Schema 7's graph tables as data (Task 2; storage §5.2 exactly, plus `tx.answer` (call 3) and `entity_vec.model`
//! (Task 0's ruling: `search::vec_stale` lists entities without a vector of a model)).

/// The graph tables and their indexes: `tx`, `entity`, `entity_hist`, `link`, `link_stat`, `entity_fts`
/// (contentless, with delete, `secure-delete` set at creation), `entity_vec`, `project_alias`, `excise_log`.
///
/// Run it once with `execute_batch` on a database that has none of them. No triggers and no foreign keys: the
/// primitives in [`super::entity`] and [`super::link`] write versions, FTS rows and stats in the caller's tx.
pub const GRAPH_DDL: &str = "
create table tx (
  id integer primary key,
  at real not null,
  actor text not null,
  class text not null,
  session text, profile text, job text,
  project integer,
  tool text,
  req text,
  state text not null default 'committed',
  reverts integer,
  imported integer not null default 0,
  note text,
  answer text);
create index tx_at on tx(at);
create unique index tx_req on tx(actor, req) where req is not null;

create table entity (
  n integer primary key,
  id text not null unique,
  kind text not null,
  project integer,
  title text, status text, body text,
  priority integer, assignee text,
  lease_holder text, lease_epoch integer not null default 0, lease_until real,
  data text not null default '{}' check (json_valid(data)),
  field_tx text not null default '{}',
  origin text not null,
  source text,
  ver integer not null,
  created_tx integer not null, updated_tx integer not null, retired_tx integer);
create index entity_kind on entity(project, kind, status);
create index entity_assignee on entity(assignee) where assignee is not null;
create index entity_source on entity(source);

create table entity_hist (
  n integer not null, ver integer not null, tx_from integer not null, tx_to integer not null,
  kind text, project integer, title text, status text, body text,
  priority integer, assignee text, data text, field_tx text,
  primary key (n, ver));
create index entity_hist_tx on entity_hist(n, tx_to);

create table link (
  id integer primary key,
  src integer not null, kind text not null, dst integer not null,
  data text check (data is null or json_valid(data)),
  origin text not null, source text,
  tx_from integer not null,
  tx_to integer not null default 4611686018427387904);
create unique index link_cur on link(src, kind, dst) where tx_to = 4611686018427387904;
create index link_out on link(src, kind, tx_to, tx_from);
create index link_in  on link(dst, kind, tx_to, tx_from);

create table link_stat (
  src integer not null, kind text not null, dst integer not null,
  count integer not null, first_tx integer not null, last_tx integer not null,
  primary key (src, kind, dst)) without rowid;

create virtual table entity_fts using fts5(title, body, content='', contentless_delete=1);
insert into entity_fts(entity_fts, rank) values('secure-delete', 1);

create table entity_vec (n integer primary key, bits blob, vec blob, scale real, model text);
create table project_alias (slug text primary key, project integer not null, tx integer not null);
create table excise_log (tx integer primary key, target text not null, fields text, reason text);
";

/// A current link's `tx_to`: 2^62.
pub const SENTINEL: i64 = 1 << 62;

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn loaded() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        conn
    }

    fn plan(conn: &Connection, sql: &str) -> String {
        let mut stmt = conn.prepare(&format!("explain query plan {sql}")).unwrap();
        let rows: Vec<String> = stmt
            .query_map([], |r| r.get::<_, String>(3))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        rows.join(" | ")
    }

    #[test]
    fn ddl_loads_and_plans_current_reads_on_link_cur() {
        let conn = loaded();
        let sql = format!(
            "select dst from link where src = 1 and kind = 'blocks' and dst = 2 and tx_to = {SENTINEL}"
        );
        let p = plan(&conn, &sql);
        assert!(p.contains("link_cur"), "plan: {p}");
        let sql = format!(
            "select src from link where dst = 2 and kind = 'blocks' and tx_to = {SENTINEL}"
        );
        let p = plan(&conn, &sql);
        assert!(p.contains("link_in"), "plan: {p}");
    }

    #[test]
    fn as_of_reads_plan_on_link_out() {
        let conn = loaded();
        let p = plan(
            &conn,
            "select dst from link where src = 1 and kind = 'blocks' and tx_to > 5 and tx_from <= 5",
        );
        assert!(p.contains("link_out"), "plan: {p}");
    }

    #[test]
    fn secure_delete_is_on() {
        let conn = loaded();
        let on: i64 = conn
            .query_row(
                "select count(*) from entity_fts_config where k = 'secure-delete' and v = 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(on, 1);
    }
}
