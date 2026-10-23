//! `graph/sql`'s runner (Task 6; storage §6.6, call 14): a dedicated `mode=ro` connection per call with an authorizer
//! that allows only select, read and functions (never `load_extension` or `fts3_tokenizer`), lowered limits, one
//! statement, a deadline and a row cap.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rusqlite::config::DbConfig;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::limits::Limit;
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{Connection, params_from_iter};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::pool::ReadPool;

/// A result: column names and rows of JSON values (a blob is `{"blob": LEN}`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rows {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

/// Why a statement was not run (or stopped).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SqlRefusal {
    /// The authorizer's action (`attach`, `pragma`, `insert`, `recursive`, the function name, …).
    NotAllowed(String),
    Deadline,
    TooManyStatements,
    Sql(String),
}

/// The limits lowered on the runner's connection (call 14): the progress handler cannot interrupt one opcode, so
/// a single huge allocation is stopped by `LENGTH` instead.
const LIMITS: [(Limit, i32); 7] = [
    (Limit::SQLITE_LIMIT_LENGTH, 1_000_000),
    (Limit::SQLITE_LIMIT_SQL_LENGTH, 100_000),
    (Limit::SQLITE_LIMIT_ATTACHED, 0),
    (Limit::SQLITE_LIMIT_EXPR_DEPTH, 100),
    (Limit::SQLITE_LIMIT_COMPOUND_SELECT, 50),
    (Limit::SQLITE_LIMIT_FUNCTION_ARG, 8),
    (Limit::SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 1_000),
];

/// Functions refused by name within `SQLITE_FUNCTION`: the bundled build has extension loading and FTS3 compiled
/// in, and the authorizer must not depend on their API switches staying off.
const DENIED_FUNCTIONS: [&str; 2] = ["load_extension", "fts3_tokenizer"];

/// Virtual-machine steps between deadline checks.
const PROGRESS_STEPS: i32 = 1_000;

/// The first action the authorizer refused on a connection, for the answer.
type Denied = Arc<Mutex<Option<String>>>;

/// Run SQL with PARAMS against POOL's file on its own read-only connection.
pub async fn run(
    pool: &ReadPool,
    sql: String,
    params: Vec<Value>,
    deadline: Duration,
    row_cap: usize,
) -> Result<Rows, SqlRefusal> {
    let path = pool.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let (conn, denied) = open(&path)?;
        query(&conn, &denied, &sql, &params, deadline, row_cap)
    })
    .await
    .unwrap_or_else(|_| Err(SqlRefusal::Sql("the query panicked".into())))
}

/// A `mode=ro` connection hardened for untrusted SQL: defensive on, schema untrusted, limits lowered, and the
/// authorizer installed for the connection's life (a statement may be re-prepared during a step).
fn open(path: &Path) -> Result<(Connection, Denied), SqlRefusal> {
    let sql_err = |e: rusqlite::Error| SqlRefusal::Sql(e.to_string());
    let conn = crate::open_readonly(path).map_err(|e| SqlRefusal::Sql(e.to_string()))?;
    conn.set_db_config(DbConfig::SQLITE_DBCONFIG_DEFENSIVE, true)
        .map_err(sql_err)?;
    conn.set_db_config(DbConfig::SQLITE_DBCONFIG_TRUSTED_SCHEMA, false)
        .map_err(sql_err)?;
    for (limit, value) in LIMITS {
        conn.set_limit(limit, value).map_err(sql_err)?;
    }
    let denied = Denied::default();
    let record = Arc::clone(&denied);
    conn.authorizer(Some(move |ctx: AuthContext<'_>| {
        authorize(ctx.action, &record)
    }))
    .map_err(sql_err)?;
    Ok((conn, denied))
}

/// Allow `SQLITE_SELECT`, `SQLITE_READ` and `SQLITE_FUNCTION` except the denied names; deny everything else and
/// remember the first refusal. The callback touches nothing on the connection.
fn authorize(action: AuthAction<'_>, denied: &Mutex<Option<String>>) -> Authorization {
    let refused = match action {
        AuthAction::Select | AuthAction::Read { .. } => return Authorization::Allow,
        AuthAction::Function { function_name } => {
            if !DENIED_FUNCTIONS
                .iter()
                .any(|d| d.eq_ignore_ascii_case(function_name))
            {
                return Authorization::Allow;
            }
            function_name.to_ascii_lowercase()
        }
        other => action_name(other),
    };
    denied
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get_or_insert(refused);
    Authorization::Deny
}

/// The authorizer code's name, lower case without `SQLITE_` (`insert`, `create_table`, `attach`, …).
fn action_name(action: AuthAction<'_>) -> String {
    let name = match action {
        AuthAction::CreateIndex { .. } => "create_index",
        AuthAction::CreateTable { .. } => "create_table",
        AuthAction::CreateTempIndex { .. } => "create_temp_index",
        AuthAction::CreateTempTable { .. } => "create_temp_table",
        AuthAction::CreateTempTrigger { .. } => "create_temp_trigger",
        AuthAction::CreateTempView { .. } => "create_temp_view",
        AuthAction::CreateTrigger { .. } => "create_trigger",
        AuthAction::CreateView { .. } => "create_view",
        AuthAction::Delete { .. } => "delete",
        AuthAction::DropIndex { .. } => "drop_index",
        AuthAction::DropTable { .. } => "drop_table",
        AuthAction::DropTempIndex { .. } => "drop_temp_index",
        AuthAction::DropTempTable { .. } => "drop_temp_table",
        AuthAction::DropTempTrigger { .. } => "drop_temp_trigger",
        AuthAction::DropTempView { .. } => "drop_temp_view",
        AuthAction::DropTrigger { .. } => "drop_trigger",
        AuthAction::DropView { .. } => "drop_view",
        AuthAction::Insert { .. } => "insert",
        AuthAction::Pragma { .. } => "pragma",
        AuthAction::Transaction { .. } => "transaction",
        AuthAction::Update { .. } => "update",
        AuthAction::Attach { .. } => "attach",
        AuthAction::Detach { .. } => "detach",
        AuthAction::AlterTable { .. } => "alter_table",
        AuthAction::Reindex { .. } => "reindex",
        AuthAction::Analyze { .. } => "analyze",
        AuthAction::CreateVtable { .. } => "create_vtable",
        AuthAction::DropVtable { .. } => "drop_vtable",
        AuthAction::Savepoint { .. } => "savepoint",
        AuthAction::Recursive => "recursive",
        AuthAction::Unknown { code, .. } => return format!("action {code}"),
        _ => "unknown",
    };
    name.to_string()
}

/// Prepare and step one statement on a connection made by [`open`], with the deadline and the row cap.
fn query(
    conn: &Connection,
    denied: &Mutex<Option<String>>,
    sql: &str,
    params: &[Value],
    deadline: Duration,
    row_cap: usize,
) -> Result<Rows, SqlRefusal> {
    let start = Instant::now();
    let late = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&late);
    conn.progress_handler(
        PROGRESS_STEPS,
        Some(move || {
            let over = start.elapsed() >= deadline;
            if over {
                flag.store(true, Ordering::Relaxed);
            }
            over
        }),
    )
    .map_err(|e| SqlRefusal::Sql(e.to_string()))?;
    let fail = |e: rusqlite::Error| refusal(e, denied, &late);
    // rusqlite refuses a tail holding another statement (`MultipleStatement`); comments and blanks may follow.
    let mut stmt = conn.prepare(sql).map_err(fail)?;
    let columns: Vec<String> = stmt.column_names().into_iter().map(String::from).collect();
    let width = columns.len();
    let mut rows = stmt
        .query(params_from_iter(params.iter().map(bind)))
        .map_err(fail)?;
    let mut out = Vec::new();
    let mut truncated = false;
    while let Some(row) = rows.next().map_err(fail)? {
        if out.len() == row_cap {
            truncated = true;
            break;
        }
        let mut values = Vec::with_capacity(width);
        for i in 0..width {
            values.push(to_json(row.get_ref(i).map_err(fail)?));
        }
        out.push(values);
    }
    Ok(Rows {
        columns,
        rows: out,
        truncated,
    })
}

/// The answer for a failed prepare or step: the authorizer's refusal first, then the deadline, then the rest.
fn refusal(e: rusqlite::Error, denied: &Mutex<Option<String>>, late: &AtomicBool) -> SqlRefusal {
    if let Some(action) = denied.lock().unwrap_or_else(|e| e.into_inner()).take() {
        return SqlRefusal::NotAllowed(action);
    }
    if late.load(Ordering::Relaxed) {
        return SqlRefusal::Deadline;
    }
    if matches!(e, rusqlite::Error::MultipleStatement) {
        return SqlRefusal::TooManyStatements;
    }
    SqlRefusal::Sql(e.to_string())
}

/// A JSON parameter as SQLite binds it: booleans as 0/1, arrays and objects as their JSON text.
fn bind(v: &Value) -> SqlValue {
    match v {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        Value::Number(n) => match n.as_i64() {
            Some(i) => SqlValue::Integer(i),
            None => SqlValue::Real(n.as_f64().unwrap_or(f64::NAN)),
        },
        Value::String(s) => SqlValue::Text(s.clone()),
        other => SqlValue::Text(other.to_string()),
    }
}

/// A column value as JSON; a blob is shown by its length, a non-finite real as null.
fn to_json(v: ValueRef<'_>) -> Value {
    match v {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(i) => Value::from(i),
        ValueRef::Real(f) => serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number),
        ValueRef::Text(t) => Value::String(String::from_utf8_lossy(t).into_owned()),
        ValueRef::Blob(b) => json!({ "blob": b.len() }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    const SECONDS: Duration = Duration::from_secs(2);

    /// `work.db` (WAL) with `t(id, name, data)` (two rows, an index on `name`) and `n(x)` (2,000 rows); the writer
    /// is closed.
    fn fixture() -> (tempfile::TempDir, ReadPool) {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let w = Connection::open(&file).unwrap();
        w.pragma_update(None, "journal_mode", "wal").unwrap();
        w.execute_batch(
            "create table t(id integer primary key, name text, data blob);
             insert into t values (1, 'a', x'010203'), (2, 'b', null);
             create index t_name on t(name);
             create table n(x integer);
             with recursive c(x) as (select 1 union all select x + 1 from c where x < 2000)
             insert into n select x from c;",
        )
        .unwrap();
        drop(w);
        let pool = ReadPool::open(file, 2);
        (dir, pool)
    }

    async fn sql(pool: &ReadPool, text: &str) -> Result<Rows, SqlRefusal> {
        run(pool, text.to_string(), Vec::new(), SECONDS, 1_000).await
    }

    fn refused(r: Result<Rows, SqlRefusal>, action: &str) {
        assert_eq!(r, Err(SqlRefusal::NotAllowed(action.to_string())));
    }

    fn bytes(path: &Path) -> Vec<u8> {
        fs::read(path).unwrap()
    }

    #[tokio::test]
    async fn select_works() {
        let (_dir, pool) = fixture();
        let r = run(
            &pool,
            "select id, name, data, 1.5 as r from t where id = ?1".into(),
            vec![json!(1)],
            SECONDS,
            10,
        )
        .await
        .unwrap();
        assert_eq!(r.columns, ["id", "name", "data", "r"]);
        assert_eq!(
            r.rows,
            vec![vec![json!(1), json!("a"), json!({"blob": 3}), json!(1.5)]]
        );
        assert!(!r.truncated);
        // A non-recursive CTE, a join and JSON1 are reads.
        let r = sql(
            &pool,
            "with two as (select id from t) select count(*), json_array(1, 2) from two join n on n.x = two.id",
        )
        .await
        .unwrap();
        assert_eq!(r.rows, vec![vec![json!(2), json!("[1,2]")]]);
    }

    #[tokio::test]
    async fn attach_is_refused() {
        let (dir, pool) = fixture();
        refused(
            sql(&pool, "attach database ':memory:' as x").await,
            "attach",
        );
        let other = dir.path().join("other.db");
        let text = format!("attach database '{}' as x", other.display());
        refused(sql(&pool, &text).await, "attach");
        assert!(!other.exists());
        refused(sql(&pool, "detach database main").await, "detach");
        // `VACUUM INTO` would write a copy anywhere; it prepares without an action code, then attaches its target
        // when it runs, and that is refused.
        let copy = dir.path().join("copy.db");
        let text = format!("vacuum into '{}'", copy.display());
        refused(sql(&pool, &text).await, "attach");
        assert!(!copy.exists());
    }

    #[tokio::test]
    async fn pragma_is_refused() {
        let (_dir, pool) = fixture();
        for text in [
            "pragma journal_mode",
            "pragma journal_mode = delete",
            "pragma wal_checkpoint(truncate)",
            "pragma query_only = 0",
            "pragma writable_schema = 1",
            "pragma trusted_schema = 1",
        ] {
            refused(sql(&pool, text).await, "pragma");
        }
    }

    #[tokio::test]
    async fn insert_update_delete_create_drop_are_refused() {
        let (_dir, pool) = fixture();
        let file = pool.path().to_path_buf();
        let before = bytes(&file);
        refused(
            sql(&pool, "insert into t(name) values ('c')").await,
            "insert",
        );
        refused(
            sql(&pool, "replace into t(id, name) values (1, 'c')").await,
            "insert",
        );
        refused(sql(&pool, "update t set name = 'c'").await, "update");
        refused(sql(&pool, "delete from t").await, "delete");
        // DDL: SQLite asks for more than one action (the schema table's insert or delete, then the DDL's own code);
        // the first refusal is reported.
        for text in [
            "create table z(x)",
            "create temp table z(x)",
            "create index ti on t(name)",
            "create view v as select 1",
            "create trigger tr after insert on t begin select 1; end",
            "drop table t",
            "drop index t_name",
            "alter table t add column y",
            "reindex",
            "analyze",
            // VACUUM has no action code of its own; it attaches a scratch database when it runs, which is refused.
            "vacuum",
        ] {
            let r = sql(&pool, text).await;
            assert!(matches!(r, Err(SqlRefusal::NotAllowed(_))), "{text}: {r:?}");
        }
        assert_eq!(bytes(&file), before);
        let r = sql(&pool, "select count(*) from t").await.unwrap();
        assert_eq!(r.rows, vec![vec![json!(2)]]);
    }

    #[tokio::test]
    async fn begin_commit_are_refused() {
        let (_dir, pool) = fixture();
        for text in ["begin", "begin immediate", "commit", "end", "rollback"] {
            refused(sql(&pool, text).await, "transaction");
        }
        for text in ["savepoint s", "release s", "rollback to s"] {
            refused(sql(&pool, text).await, "savepoint");
        }
    }

    #[tokio::test]
    async fn load_extension_is_refused() {
        let (_dir, pool) = fixture();
        refused(
            sql(&pool, "select load_extension('/nonexistent/libx')").await,
            "load_extension",
        );
        refused(
            sql(&pool, "select LOAD_EXTENSION('/nonexistent/libx', 'f')").await,
            "load_extension",
        );
        // With the extension API switched on, only the authorizer stands between the SQL and the loader.
        let (conn, denied) = open(pool.path()).unwrap();
        // SAFETY: the handle is this live connection's; the call only flips its extension-loading switch.
        let rc = unsafe { rusqlite::ffi::sqlite3_enable_load_extension(conn.handle(), 1) };
        assert_eq!(rc, rusqlite::ffi::SQLITE_OK);
        refused(
            query(
                &conn,
                &denied,
                "select load_extension('/nonexistent/libx')",
                &[],
                SECONDS,
                10,
            ),
            "load_extension",
        );
    }

    #[tokio::test]
    async fn a_recursive_cte_is_refused() {
        let (_dir, pool) = fixture();
        refused(
            sql(
                &pool,
                "with recursive c(x) as (select 1 union all select x + 1 from c) select count(*) from c",
            )
            .await,
            "recursive",
        );
    }

    #[tokio::test]
    async fn two_statements_are_refused() {
        let (_dir, pool) = fixture();
        assert_eq!(
            sql(&pool, "select 1; select 2").await,
            Err(SqlRefusal::TooManyStatements)
        );
        // A trailing semicolon, blanks or a comment are not a second statement.
        for text in ["select 1;", "select 1;  ", "select 1; -- done"] {
            assert_eq!(
                sql(&pool, text).await.unwrap().rows,
                vec![vec![json!(1)]],
                "{text}"
            );
        }
    }

    #[tokio::test]
    async fn a_long_query_meets_the_deadline() {
        let (_dir, pool) = fixture();
        let start = Instant::now();
        let r = run(
            &pool,
            "select count(*) from n a, n b, n c".into(),
            Vec::new(),
            Duration::from_millis(100),
            10,
        )
        .await;
        assert_eq!(r, Err(SqlRefusal::Deadline));
        assert!(start.elapsed() < Duration::from_secs(10));
    }

    #[tokio::test]
    async fn rows_are_capped() {
        let (_dir, pool) = fixture();
        let r = run(
            &pool,
            "select x from n order by x".into(),
            Vec::new(),
            SECONDS,
            10,
        )
        .await
        .unwrap();
        assert_eq!(r.rows.len(), 10);
        assert_eq!(r.rows[9], vec![json!(10)]);
        assert!(r.truncated);
        let r = run(&pool, "select x from n".into(), Vec::new(), SECONDS, 2_000)
            .await
            .unwrap();
        assert_eq!(r.rows.len(), 2_000);
        assert!(!r.truncated);
    }

    #[tokio::test]
    async fn never_checkpoints() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("work.db");
        let wal: PathBuf = dir.path().join("work.db-wal");
        let w = Connection::open(&file).unwrap();
        w.pragma_update(None, "journal_mode", "wal").unwrap();
        w.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
        w.execute_batch("create table t(x); insert into t values (1), (2);")
            .unwrap();
        // The writer closes first without checkpointing, so the runner is the last connection to close.
        w.set_db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true)
            .unwrap();
        drop(w);
        let main = bytes(&file);
        let frames = fs::metadata(&wal).unwrap().len();
        assert!(frames > 0);
        let pool = ReadPool::open(file.clone(), 2);
        let r = sql(&pool, "select count(*) from t").await.unwrap();
        assert_eq!(r.rows, vec![vec![json!(2)]]);
        assert_eq!(bytes(&file), main);
        assert_eq!(fs::metadata(&wal).unwrap().len(), frames);
    }

    #[tokio::test]
    async fn a_huge_blob_is_refused() {
        let (_dir, pool) = fixture();
        for text in [
            "select randomblob(999999999)",
            "select printf('%.*c', 999999999, 'x')",
        ] {
            let r = sql(&pool, text).await;
            assert!(
                matches!(&r, Err(SqlRefusal::Sql(t)) if t.contains("too big")),
                "{text}: {r:?}"
            );
        }
    }

    #[tokio::test]
    async fn pragma_table_functions_are_refused_or_harmless() {
        let (_dir, pool) = fixture();
        let file = pool.path().to_path_buf();
        let before = bytes(&file);
        // A pragma's table-valued function prepares `PRAGMA …` on the same connection when it runs, which the
        // authorizer refuses; only pragmas without side effects have such functions at all.
        for text in [
            "select * from pragma_table_info('t')",
            "select * from pragma_journal_mode('delete')",
            "select * from pragma_wal_checkpoint('truncate')",
            "select * from pragma_query_only(0)",
            "select name from pragma_function_list",
        ] {
            match sql(&pool, text).await {
                Ok(_) => {}
                Err(SqlRefusal::NotAllowed(a)) => assert_eq!(a, "pragma", "{text}"),
                Err(SqlRefusal::Sql(t)) if t.contains("no such table") => {}
                other => panic!("{text}: {other:?}"),
            }
        }
        assert_eq!(bytes(&file), before);
        let mode: String = Connection::open(&file)
            .unwrap()
            .query_row("pragma journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
    }

    #[tokio::test]
    async fn dbstat_is_read_only() {
        let (_dir, pool) = fixture();
        let r = sql(&pool, "select count(*) from dbstat").await.unwrap();
        assert!(r.rows[0][0].as_i64().unwrap() > 0);
        for text in [
            "insert into dbstat(name) values ('t')",
            "update dbstat set name = 'x'",
            "delete from dbstat",
            "insert into sqlite_dbpage values (1, zeroblob(4096))",
        ] {
            assert!(sql(&pool, text).await.is_err(), "{text}");
        }
    }

    #[tokio::test]
    async fn fts3_tokenizer_is_refused() {
        let (_dir, pool) = fixture();
        refused(
            sql(&pool, "select fts3_tokenizer('simple')").await,
            "fts3_tokenizer",
        );
        refused(
            sql(&pool, "select fts3_tokenizer('evil', x'0000000000000000')").await,
            "fts3_tokenizer",
        );
    }

    #[tokio::test]
    async fn attach_limit_is_zero() {
        let (_dir, pool) = fixture();
        let (conn, _denied) = open(pool.path()).unwrap();
        assert_eq!(conn.limit(Limit::SQLITE_LIMIT_ATTACHED).unwrap(), 0);
        for (limit, value) in LIMITS {
            assert_eq!(conn.limit(limit).unwrap(), value, "{limit:?}");
        }
        assert!(conn.db_config(DbConfig::SQLITE_DBCONFIG_DEFENSIVE).unwrap());
        assert!(
            !conn
                .db_config(DbConfig::SQLITE_DBCONFIG_TRUSTED_SCHEMA)
                .unwrap()
        );
    }
}
