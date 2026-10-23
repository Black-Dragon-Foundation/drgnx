//! The migration's tests: schema-6 fixtures under a temporary HOME only (`test/fixtures/work-db-6.sql` and the
//! shaped `work-db-6-shaped.sql`), never a real `work.db` or anything the user calls personal notes.

use super::*;

use std::collections::BTreeMap;
use std::process::{Command, Stdio};
use std::time::Duration;

use urdr::graph::{Writer, WriterOpts, hist};

/// The steps' trace and the failures tests ask for, by database path (tests run in parallel, each on its own file).
pub(super) mod hooks {
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    use super::super::Stop;

    static FAIL: Mutex<Vec<(PathBuf, &'static str)>> = Mutex::new(Vec::new());
    static TRACE: Mutex<Vec<(PathBuf, &'static str)>> = Mutex::new(Vec::new());

    /// The migration reached STEP on DB: traced, and failed when a test asked for it.
    pub(in crate::migrate7) fn reach(db: &Path, step: &'static str) -> Result<(), Stop> {
        TRACE.lock().unwrap().push((db.to_path_buf(), step));
        if FAIL
            .lock()
            .unwrap()
            .iter()
            .any(|(p, s)| p == db && *s == step)
        {
            return Err(Stop::Failed(format!("a test hook failed step {step}")));
        }
        Ok(())
    }

    /// Before the copy's check: a test that asked for `check` breaks the copy, so the real check fails.
    pub(in crate::migrate7) fn before_check(db: &Path, copy: &Path) {
        if FAIL
            .lock()
            .unwrap()
            .iter()
            .any(|(p, s)| p == db && *s == "check")
        {
            std::fs::write(copy, b"not a database: a broken copy").unwrap();
        }
    }

    pub(in crate::migrate7) fn fail_at(db: &Path, step: &'static str) {
        FAIL.lock().unwrap().push((db.to_path_buf(), step));
    }

    pub(in crate::migrate7) fn trace(db: &Path) -> Vec<&'static str> {
        TRACE
            .lock()
            .unwrap()
            .iter()
            .filter(|(p, _)| p == db)
            .map(|(_, s)| *s)
            .collect()
    }
}

const DDL6: &str = include_str!("../../../../../test/fixtures/work-db-6.sql");
const SHAPED: &str = include_str!("../../../../../test/fixtures/work-db-6-shaped.sql");
const CANARY: &[u8] = b"CANARY-7f3a";

/// A schema-6 file from the shaped fixture under a temporary HOME.
struct Fx {
    dir: tempfile::TempDir,
    home: PathBuf,
    db: PathBuf,
    opts: MigrateOpts,
}

impl Fx {
    fn backups(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(&self.opts.backup_dir)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }
}

fn empty_fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let data = dir.path().join("data");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&data).unwrap();
    let db = data.join("work.db");
    let opts = MigrateOpts {
        backup_dir: data.join("backup"),
        home: home.clone(),
        config_dir: dir.path().join("config"),
    };
    Fx {
        dir,
        home,
        db,
        opts,
    }
}

/// The shaped fixture, `$HOME` being the fixture's home.
fn fixture() -> Fx {
    let fx = empty_fx();
    let c = Connection::open(&fx.db).unwrap();
    c.execute_batch(DDL6).unwrap();
    c.execute_batch(&SHAPED.replace("$HOME", fx.home.to_str().unwrap()))
        .unwrap();
    fx
}

/// A connection as the writer opens one.
fn writer_conn(db: &Path) -> Connection {
    let c = Connection::open(db).unwrap();
    c.busy_timeout(Duration::from_secs(5)).unwrap();
    c.pragma_update(None, "journal_mode", "wal").unwrap();
    c.pragma_update(None, "secure_delete", "ON").unwrap();
    c
}

fn migrated() -> (Fx, Connection, MigrateReport) {
    let fx = fixture();
    let mut c = writer_conn(&fx.db);
    let report = run(&mut c, &fx.db, &fx.opts).unwrap();
    (fx, c, report)
}

fn one<T: urdr_from_sql::Get>(c: &Connection, sql: &str) -> T {
    T::get(c, sql)
}

/// A one-value query, typed (norn names no rusqlite type).
mod urdr_from_sql {
    use urdr::Connection;

    pub trait Get: Sized {
        fn get(c: &Connection, sql: &str) -> Self;
    }
    impl Get for i64 {
        fn get(c: &Connection, sql: &str) -> i64 {
            c.query_row(sql, [], |r| r.get(0))
                .unwrap_or_else(|e| panic!("{sql}: {e}"))
        }
    }
    impl Get for String {
        fn get(c: &Connection, sql: &str) -> String {
            c.query_row(sql, [], |r| r.get(0))
                .unwrap_or_else(|e| panic!("{sql}: {e}"))
        }
    }
    impl Get for Option<String> {
        fn get(c: &Connection, sql: &str) -> Option<String> {
            c.query_row(sql, [], |r| r.get(0))
                .unwrap_or_else(|e| panic!("{sql}: {e}"))
        }
    }
}

/// Every row of SQL as JSON values (numbers, text, null), for comparing a view with a schema-6 table.
fn rows(c: &Connection, sql: &str) -> Vec<Vec<Value>> {
    let mut stmt = c.prepare(sql).unwrap_or_else(|e| panic!("{sql}: {e}"));
    let n = stmt.column_count();
    stmt.query_map([], |r| {
        (0..n)
            .map(|i| {
                let text: Option<String> = r.get::<_, Option<String>>(i).ok().flatten();
                let int: Option<i64> = r.get::<_, Option<i64>>(i).ok().flatten();
                let real: Option<f64> = r.get::<_, Option<f64>>(i).ok().flatten();
                Ok(match (int, real, text) {
                    (Some(v), _, _) => json!(v),
                    (None, Some(v), _) => json!(v),
                    (None, None, Some(t)) => json!(t),
                    _ => Value::Null,
                })
            })
            .collect::<Result<Vec<Value>, _>>()
    })
    .unwrap()
    .collect::<Result<Vec<_>, _>>()
    .unwrap()
}

/// The fixture before migration, in memory, for comparing the views with schema 6's tables.
fn fixture_in_memory(home: &Path) -> Connection {
    let c = Connection::open_in_memory().unwrap();
    c.execute_batch(DDL6).unwrap();
    c.execute_batch(&SHAPED.replace("$HOME", home.to_str().unwrap()))
        .unwrap();
    c
}

fn file_has(path: &Path, needle: &[u8]) -> bool {
    fs::read(path).is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle))
}

fn wal_of(db: &Path) -> PathBuf {
    let mut w = db.as_os_str().to_owned();
    w.push("-wal");
    PathBuf::from(w)
}

/// A JSON column read back as a value (key order is not kept by the migration).
fn parse_data(v: &Value) -> Value {
    match v {
        Value::String(s) => serde_json::from_str(s).unwrap_or_else(|_| v.clone()),
        other => other.clone(),
    }
}

const DENIED_IDS: &str =
    "('plan:H/org/plans/secret.md', 'task:H/org/plans/secret.md#1', 'spec:H/org/notes.org')";

fn denied_ids(home: &Path) -> String {
    DENIED_IDS.replace('H', home.to_str().unwrap())
}

#[test]
fn counts_are_kept() {
    let (fx, c, report) = migrated();
    let t = |name: &str| report.tables[name];
    assert_eq!(t("node"), (970, 967));
    assert_eq!(t("edge"), (169, 165));
    assert_eq!(t("jtask"), (5, 5));
    assert_eq!(t("jdep"), (4, 3));
    assert_eq!(t("decision"), (4, 4));
    assert_eq!(t("file"), (57, 55));
    assert_eq!(t("meta"), (7, 7));
    for (name, n) in [
        ("job", 2),
        ("message", 3),
        ("card", 2),
        ("event", 5),
        ("spend", 2),
        ("agent", 1),
        ("review_mark", 1),
    ] {
        assert_eq!(t(name), (n, n), "{name}");
        let now: i64 = one(&c, &format!("select count(*) from {name}"));
        assert_eq!(now, n as i64, "{name}");
    }
    let by_kind = rows(
        &c,
        "select kind, count(*) from node group by kind order by kind",
    );
    assert_eq!(
        by_kind,
        [
            ("branch", 2),
            ("commit", 123),
            ("plan", 25),
            ("ruling", 294),
            ("spec", 4),
            ("step", 366),
            ("task", 152),
            ("todo", 1)
        ]
        .map(|(k, n)| vec![json!(k), json!(n)])
    );
    let want: BTreeMap<String, u64> = [
        ("derives->derives", 15),
        ("derives->denied", 1),
        ("derives->dropped", 1),
        ("implements->implements", 123),
        ("implements->dropped", 1),
        ("on-branch->on_branch", 2),
        ("ledger-of->relates", 25),
        ("ledger-of->denied", 1),
        ("parent->parent_of", 152 + 366),
        ("jdep->blocks", 3),
        ("jdep->dropped", 1),
        ("replaces->supersedes", 2),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    assert_eq!(report.links, want);
    // The views give back schema 6's rows (the denied ones and the edges whose end was no node aside).
    let old = fixture_in_memory(&fx.home);
    let cols = "id, kind, title, path, line, status, parent, ord, source, data";
    let shape = |rs: Vec<Vec<Value>>| -> Vec<Vec<Value>> {
        rs.into_iter()
            .map(|mut r| {
                let d = parse_data(&r[9]);
                r[9] = d;
                r
            })
            .collect()
    };
    let before = shape(rows(
        &old,
        &format!(
            "select {cols} from node where id not in {} order by id",
            denied_ids(&fx.home)
        ),
    ));
    let after = shape(rows(&c, &format!("select {cols} from node order by id")));
    assert_eq!(before.len(), 967);
    assert_eq!(after, before);
    let before = rows(
        &old,
        "select src, dst, kind, origin, source from edge where src in (select id from node) or kind = 'ledger-of' \
         order by src, dst, kind",
    );
    let before: Vec<Vec<Value>> = before
        .into_iter()
        .filter(|r| {
            let s = r[0].as_str().unwrap();
            let d = r[1].as_str().unwrap();
            !(s.contains("/org/") || d.contains("/org/") || d.ends_with("gone.md"))
        })
        .collect();
    let after = rows(
        &c,
        "select src, dst, kind, origin, source from edge order by src, dst, kind",
    );
    assert_eq!(after.len(), 165);
    assert_eq!(after, before);
    for (view, sql) in [
        ("jtask", "select * from jtask order by id"),
        (
            "jdep",
            "select * from jdep where dep <> 'j9#9' order by task, dep",
        ),
        ("decision", "select * from decision order by n"),
        (
            "file",
            "select * from file where path not like '%/org/plans/%' and path not like '%notes.org' order by path",
        ),
    ] {
        let mut before = rows(&old, sql);
        let mut after = rows(&c, &sql.replace(" where dep <> 'j9#9'", ""));
        if view == "jtask" {
            for r in before.iter_mut().chain(after.iter_mut()) {
                r[8] = parse_data(&r[8]);
            }
        }
        if view == "file" {
            after = rows(&c, "select * from file order by path");
        }
        assert_eq!(after, before, "{view}");
    }
}

#[test]
fn views_have_schema_6_columns() {
    let (_fx, c, _) = migrated();
    let old = Connection::open_in_memory().unwrap();
    old.execute_batch(DDL6).unwrap();
    let cols = |c: &Connection, t: &str| -> Vec<Value> {
        rows(
            c,
            &format!("select name from pragma_table_info('{t}') order by cid"),
        )
        .into_iter()
        .map(|mut r| r.remove(0))
        .collect()
    };
    for t in ["node", "edge", "jtask", "jdep", "decision", "file", "meta"] {
        let ty: String = one(
            &c,
            &format!("select type from sqlite_master where name = '{t}'"),
        );
        assert_eq!(ty, "view", "{t}");
        assert_eq!(cols(&c, t), cols(&old, t), "{t}");
        assert!(!cols(&old, t).is_empty());
    }
}

/// Every string literal of an Emacs Lisp source, with the text right before it and right after it.
fn literals(src: &str) -> Vec<(String, String, String)> {
    let b = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b';' => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'?' => i += if b.get(i + 1) == Some(&b'\\') { 3 } else { 2 },
            b'"' => {
                let start = i;
                let mut s = Vec::new();
                i += 1;
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' && i + 1 < b.len() {
                        match b[i + 1] {
                            b'n' => s.push(b'\n'),
                            b't' => s.push(b'\t'),
                            b'\n' => {}
                            c => s.push(c),
                        }
                        i += 2;
                    } else {
                        s.push(b[i]);
                        i += 1;
                    }
                }
                let before =
                    String::from_utf8_lossy(&b[start.saturating_sub(80)..start]).into_owned();
                let after =
                    String::from_utf8_lossy(&b[(i + 1).min(b.len())..(i + 81).min(b.len())])
                        .into_owned();
                out.push((String::from_utf8_lossy(&s).into_owned(), before, after));
                i += 1;
            }
            _ => i += 1,
        }
    }
    out
}

fn lisp_sources(dirs: &[&str]) -> Vec<(PathBuf, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let mut out = Vec::new();
    let mut stack: Vec<PathBuf> = dirs.iter().map(|d| root.join(d)).collect();
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(&dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "el") {
                out.push((p.clone(), fs::read_to_string(&p).unwrap()));
            }
        }
    }
    out.sort();
    out
}

/// The table names after `from`, `join`, `into` and `update` in SQL.
fn tables_named(sql: &str) -> Vec<String> {
    let words: Vec<String> = sql
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect();
    words
        .windows(2)
        .filter(|w| matches!(w[0].as_str(), "from" | "join" | "into" | "update"))
        .map(|w| w[1].clone())
        .collect()
}

/// The constants a `format` select may name: their values are read from their `defconst` strings.
const FORMAT_CONSTANTS: &[&str] = &[
    "drgnx-coord--agent-cols",
    "drgnx-coord--event-cols",
    "drgnx-coord--decision-cols",
    "drgnx-work--select",
];

/// The symbol at the start of TEXT (after blanks).
fn symbol_at(text: &str) -> String {
    text.trim_start()
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || "-_*:/<>=!?".contains(*c))
        .collect()
}

#[test]
fn every_old_select_runs_on_the_views() {
    let (_fx, c, _) = migrated();
    let sources: Vec<(PathBuf, String)> = lisp_sources(&["core", "modules"])
        .into_iter()
        // The search store is another database, with tables of its own named `file` and `meta`.
        .filter(|(p, _)| {
            !p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("drgnx-search")
        })
        .collect();
    let mut constants: HashMap<String, String> = HashMap::new();
    for (_, src) in &sources {
        for (lit, before, _) in literals(src) {
            if let Some(at) = before.rfind("(defconst ") {
                let rest = &before[at + "(defconst ".len()..];
                let name = symbol_at(rest);
                // The value right after the name, not a docstring further on.
                if rest.trim() == name && FORMAT_CONSTANTS.contains(&name.as_str()) {
                    constants.insert(name, lit);
                }
            }
        }
    }
    assert_eq!(constants.len(), FORMAT_CONSTANTS.len(), "{constants:?}");
    let ours = ["node", "edge", "jtask", "jdep", "decision", "file", "meta"];
    let mut checked = Vec::new();
    let mut failures = Vec::new();
    for (path, src) in &sources {
        for (lit, before, after) in literals(src) {
            let head = before.trim_end();
            let sql = if head.ends_with("(format") && lit.contains("%s") {
                let sym = symbol_at(&after);
                let Some(value) = constants.get(&sym) else {
                    let raw = lit.trim_start().to_lowercase();
                    if raw.starts_with("select")
                        && tables_named(&lit)
                            .iter()
                            .any(|t| ours.contains(&t.as_str()))
                    {
                        failures.push(format!(
                            "{}: a format select names {sym:?}, not one of {FORMAT_CONSTANTS:?}: {lit}",
                            path.display()
                        ));
                    }
                    continue;
                };
                lit.replacen("%s", value, 1).replace("%s", "")
            } else if let Some(at) = head.rfind("(concat ")
                && let Some(value) = constants.get(head[at + "(concat ".len()..].trim())
            {
                format!("{value}{lit}")
            } else {
                lit.clone()
            };
            if !sql.trim_start().to_lowercase().starts_with("select")
                || !tables_named(&sql)
                    .iter()
                    .any(|t| ours.contains(&t.as_str()))
            {
                continue;
            }
            match c.prepare(&sql) {
                Ok(_) => checked.push(sql),
                Err(e) => failures.push(format!("{}: {sql}: {e}", path.display())),
            }
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
    // The extraction found the readers it must (a sanity bound, and the fragment over two views).
    assert!(checked.len() >= 30, "{}: {checked:#?}", checked.len());
    assert!(
        checked
            .iter()
            .any(|s| s.contains("not in (select e.src from edge e join node s")),
        "{checked:#?}"
    );
    assert!(
        checked
            .iter()
            .any(|s| s.contains("from decision where ver > ?"))
    );
}

#[test]
fn every_schema_6_lisp_write_fails_on_7() {
    let (_fx, c, _) = migrated();
    let mut writes = Vec::new();
    for (path, src) in lisp_sources(&["core"]) {
        if !path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("drgnx-work")
        {
            continue;
        }
        for (lit, _, _) in literals(&src) {
            let head = lit.trim_start().to_lowercase();
            if !["insert", "delete", "update", "replace"]
                .iter()
                .any(|w| head.starts_with(w))
            {
                continue;
            }
            let target = tables_named(&lit).into_iter().next().unwrap_or_default();
            if ["node", "edge", "file", "meta"].contains(&target.as_str()) {
                writes.push(lit);
            }
        }
    }
    // Task 16 deleted the editor's node/edge/file writers; what is left is drgnx-work-db's own `meta` writes (the
    // `local` writer mode's migration), which must fail on 7 all the same
    assert!(writes.len() >= 3, "{writes:#?}");
    for w in &writes {
        let sql = w.replace('?', "null");
        let r = c.execute_batch(&sql);
        assert!(r.is_err(), "a schema-6 write ran on schema 7: {w}");
    }
}

#[test]
fn as_of_before_migration_is_approximate() {
    let (fx, c, _) = migrated();
    let n: i64 = one(
        &c,
        &format!(
            "select n from entity where id = 'plan:{}/w/alpha/docs/plans/p1.md'",
            fx.home.display()
        ),
    );
    let last: i64 = one(&c, "select max(id) from tx");
    let asof = hist::entity_as_of(&c, n, last).unwrap().unwrap();
    assert!(asof.approximate);
    let not_imported: i64 = one(&c, "select count(*) from tx where imported = 0");
    assert_eq!(not_imported, 0);
    // Time order: a plan seen before its tasks is made in an earlier tx, and as of a time before it, it is not there.
    let made: f64 = c
        .query_row(
            "select t.at from entity e join tx t on t.id = e.created_tx where e.n = ?1",
            [n],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(made, 1700001001.0);
    let before = hist::tx_at(&c, made - 1.0).unwrap();
    assert!(hist::entity_as_of(&c, n, before).unwrap().is_none());
    let ordered: i64 = one(
        &c,
        "select count(*) from tx a join tx b on b.id = a.id + 1 where b.at < a.at",
    );
    assert_eq!(ordered, 0, "tx times never go back");
}

#[test]
fn decision_chain_becomes_linked_entities() {
    let (_fx, c, _) = migrated();
    let n: i64 = one(&c, "select count(*) from entity where kind = 'decision'");
    assert_eq!(n, 4);
    let links = rows(
        &c,
        "select s.id, d.id from link l join entity s on s.n = l.src join entity d on d.n = l.dst \
         where l.kind = 'supersedes' order by s.id",
    );
    assert_eq!(
        links,
        vec![
            vec![json!("decision:2"), json!("decision:1")],
            vec![json!("decision:3"), json!("decision:2")]
        ]
    );
    let view = rows(&c, "select n, replaces, status from decision order by n");
    assert_eq!(
        view,
        vec![
            vec![json!(1), Value::Null, json!("replaced")],
            vec![json!(2), json!(1), json!("replaced")],
            vec![json!(3), json!(2), json!("active")],
            vec![json!(4), Value::Null, json!("active")]
        ]
    );
    // Authors: the user's decisions are imported as system-class txs (never `user` class), an agent's as its own.
    let authors = rows(
        &c,
        "select e.id, t.actor, t.class from entity e join tx t on t.id = e.created_tx \
         where e.kind = 'decision' order by e.id",
    );
    assert_eq!(
        authors,
        vec![
            vec![json!("decision:1"), json!("user"), json!("system")],
            vec![json!("decision:2"), json!("agent:a1"), json!("agent")],
            vec![json!("decision:3"), json!("agent:a1"), json!("agent")],
            vec![json!("decision:4"), json!("user"), json!("system")]
        ]
    );
    let user_class: i64 = one(&c, "select count(*) from tx where class = 'user'");
    assert_eq!(user_class, 0);
}

#[test]
fn jtask_becomes_task_entities_with_blocks() {
    let (_fx, c, _) = migrated();
    let held = rows(
        &c,
        "select kind, assignee, lease_holder, lease_epoch, lease_until, json_extract(data, '$.job'), \
         json_extract(data, '$.n'), json_extract(data, '$.role'), json_extract(data, '$.note'), origin \
         from entity where id = 'task:j1#2'",
    );
    assert_eq!(
        held,
        vec![vec![
            json!("task"),
            json!("a1"),
            json!("a1"),
            json!(1),
            json!(1700009999.0),
            json!("j1"),
            json!(2),
            json!("coder"),
            json!("x"),
            json!("recorded")
        ]]
    );
    let free: i64 = one(&c, "select lease_epoch from entity where id = 'task:j1#1'");
    assert_eq!(free, 0, "a task without a lease_until holds none");
    let blocks = rows(
        &c,
        "select s.id, d.id from link l join entity s on s.n = l.src join entity d on d.n = l.dst \
         where l.kind = 'blocks' order by s.id, d.id",
    );
    assert_eq!(
        blocks,
        vec![
            vec![json!("task:j1#1"), json!("task:j1#2")],
            vec![json!("task:j1#2"), json!("task:j1#3")],
            vec![json!("task:j2#1"), json!("task:j2#2")]
        ]
    );
    // Created at its job's creation or its first event, whichever is first.
    let at: f64 = c
        .query_row(
            "select t.at from entity e join tx t on t.id = e.created_tx where e.id = 'task:j1#1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(at, 1700000100.0);
}

#[test]
fn log_version_and_seen_unchanged() {
    let (_fx, c, _) = migrated();
    let kv = rows(
        &c,
        "select key, value from meta where key in ('log-version', 'seen:user', 'seen:a1', 'event-pruned', \
         'migrate-6-dropped', 'schema', 'compat-read') order by key",
    );
    assert_eq!(
        kv,
        [
            ("compat-read", "6"),
            ("event-pruned", "1700000000"),
            ("log-version", "3"),
            ("migrate-6-dropped", "0"),
            ("schema", "7"),
            ("seen:a1", "1700000250"),
            ("seen:user", "1700000300")
        ]
        .map(|(k, v)| vec![json!(k), json!(v)])
    );
    let report: String = one(&c, "select value from kv where key = 'migrate-7'");
    let report: Value = serde_json::from_str(&report).unwrap();
    assert_eq!(report["tables"]["node"], json!([970, 967]));
}

#[test]
fn projects_and_aliases() {
    let fx = empty_fx();
    let w = fx.home.join("w");
    fs::create_dir_all(&w).unwrap();
    let repo = project::tests::repo(&w, "alpha", Some(1_700_000_000));
    for d in ["docs/specs", "docs/plans"] {
        fs::create_dir_all(repo.join(d)).unwrap();
    }
    let c = Connection::open(&fx.db).unwrap();
    c.execute_batch(DDL6).unwrap();
    c.execute_batch(&SHAPED.replace("$HOME", fx.home.to_str().unwrap()))
        .unwrap();
    drop(c);
    let mut c = writer_conn(&fx.db);
    let report = run(&mut c, &fx.db, &fx.opts).unwrap();
    let projects = rows(
        &c,
        "select e.n, a.slug from entity e join project_alias a on a.project = e.n where e.kind = 'project'",
    );
    assert_eq!(projects.len(), 1, "{projects:?}");
    assert_eq!(projects[0][1], json!("alpha"));
    let p = projects[0][0].as_i64().unwrap();
    // The board's todo (its folder is under ~/org) and the decision of no job have none.
    assert_eq!(report.no_project, 2);
    let without: i64 = one(
        &c,
        "select count(*) from entity where project is null and kind <> 'project'",
    );
    assert_eq!(without, 2);
    let with: i64 = one(
        &c,
        // the project entity's own `project` is itself: not counted
        &format!("select count(*) from entity where project = {p} and kind <> 'project'"),
    );
    let all: i64 = one(&c, "select count(*) from entity where kind <> 'project'");
    assert_eq!(with, all - 2);
}

#[test]
fn interrupted_migration_leaves_schema_6() {
    const CHILD: &str = "DRGNX_TEST_MIGRATE7_CHILD";
    if let Ok(db) = std::env::var(CHILD) {
        // The child: migrate until the pause hook stops it inside the transaction (the parent kills it there).
        let db = PathBuf::from(db);
        let data = db.parent().unwrap().to_path_buf();
        let opts = MigrateOpts {
            backup_dir: data.join("backup"),
            home: data.parent().unwrap().join("home"),
            config_dir: data.parent().unwrap().join("config"),
        };
        let mut c = writer_conn(&db);
        let _ = run(&mut c, &db, &opts);
        return;
    }
    let fx = fixture();
    let census = |db: &Path| -> Vec<Vec<Value>> {
        let c = Connection::open(db).unwrap();
        rows(
            &c,
            "select (select count(*) from node), (select count(*) from edge), (select count(*) from jtask), \
             (select count(*) from decision), (select value from meta where key = 'schema'), \
             (select group_concat(type || ':' || name, ',') from sqlite_master where name in \
              ('node', 'meta', 'entity', 'kv'))",
        )
    };
    let before = census(&fx.db);
    let marker = fx.dir.path().join("paused");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "migrate7::tests::interrupted_migration_leaves_schema_6",
            "--test-threads=1",
        ])
        .env(CHILD, &fx.db)
        .env(
            "DRGNX_TEST_MIGRATE7_PAUSE",
            format!("entities:{}", marker.display()),
        )
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    while !marker.exists() {
        if let Some(s) = child.try_wait().unwrap() {
            panic!("the child ended before the pause: {s}");
        }
        assert!(Instant::now() < deadline, "the child never paused");
        std::thread::sleep(Duration::from_millis(50));
    }
    // SIGKILL, mid-transaction.
    child.kill().unwrap();
    child.wait().unwrap();
    let after = census(&fx.db);
    assert_eq!(after, before);
    assert_eq!(after[0][4], json!("6"));
    assert_eq!(after[0][5], json!("table:meta,table:node"));
    // And the file still migrates.
    let mut c = writer_conn(&fx.db);
    let report = run(&mut c, &fx.db, &fx.opts).unwrap();
    assert_eq!(report.tables["node"], (970, 967));
}

#[test]
fn rerun_is_a_no_op() {
    let (fx, mut c, _) = migrated();
    let census = |c: &Connection| {
        rows(
            c,
            "select (select count(*) from tx), (select count(*) from entity), (select count(*) from link), \
             (select max(ver) from entity)",
        )
    };
    let before = census(&c);
    let backups = fx.backups();
    assert_eq!(backups.len(), 1, "{backups:?}");
    assert!(backups[0].starts_with("work-pre7-"));
    assert_eq!(
        open(&mut c, &fx.db, &fx.opts),
        OpenOutcome::Ready { schema: SCHEMA }
    );
    assert_eq!(census(&c), before);
    assert_eq!(fx.backups(), backups);
    // run on a schema-7 file is refused, not repeated.
    assert!(run(&mut c, &fx.db, &fx.opts).is_err());
    assert_eq!(census(&c), before);
}

#[test]
fn a_failed_backup_check_stops_it() {
    let fx = fixture();
    hooks::fail_at(&fx.db, "check");
    let mut c = writer_conn(&fx.db);
    let e = run(&mut c, &fx.db, &fx.opts).unwrap_err();
    assert!(e.contains("failed its check"), "{e}");
    assert_eq!(
        fx.backups(),
        Vec::<String>::new(),
        "a failed copy is removed"
    );
    let schema: String = one(&c, "select value from meta where key = 'schema'");
    assert_eq!(schema, "6");
    let ty: String = one(&c, "select type from sqlite_master where name = 'node'");
    assert_eq!(ty, "table");
    assert!(!hooks::trace(&fx.db).contains(&"begin"));
}

#[tokio::test]
async fn a_failed_migration_is_not_retried() {
    let fx = fixture();
    hooks::fail_at(&fx.db, "entities");
    let (writer, handle) =
        Writer::spawn(&fx.db, WriterOpts::default(), open_rule(fx.opts.clone())).unwrap();
    handle.tick().await;
    let failed = |h: &urdr::graph::WriterHandle| match h.status().last_open {
        Some(OpenOutcome::Failed(r)) => r,
        other => panic!("{other:?}"),
    };
    let reason = failed(&handle);
    assert!(reason.contains("schema 7 failed"), "{reason}");
    for _ in 0..3 {
        handle.tick().await;
    }
    assert_eq!(failed(&handle), reason);
    let entities = hooks::trace(&fx.db)
        .into_iter()
        .filter(|s| *s == "entities")
        .count();
    assert_eq!(entities, 1, "never run again in this process");
    assert_eq!(fx.backups().len(), 1);
    let e = handle
        .write(TxMeta::new("hub", Class::System, "test"), |_| Ok(()))
        .await
        .unwrap_err();
    assert!(matches!(e, WriteError::NotReady(_)), "{e:?}");
    tokio::task::spawn_blocking(move || writer.shutdown())
        .await
        .unwrap();
    let c = Connection::open(&fx.db).unwrap();
    let schema: String = one(&c, "select value from meta where key = 'schema'");
    assert_eq!(schema, "6");
}

#[test]
fn a_fresh_file_is_schema_7() {
    let fx = empty_fx();
    let mut c = writer_conn(&fx.db);
    assert_eq!(
        open(&mut c, &fx.db, &fx.opts),
        OpenOutcome::Ready { schema: SCHEMA }
    );
    assert!(fx.backups().is_empty(), "nothing to copy");
    let kv = rows(&c, "select key, value from meta order by key");
    assert_eq!(
        kv,
        vec![
            vec![json!("compat-read"), json!("6")],
            vec![json!("schema"), json!("7")]
        ]
    );
    let schema = |c: &Connection| {
        rows(
            c,
            "select type, name, tbl_name, sql from sqlite_master where name not like 'sqlite_%' order by name",
        )
    };
    let (_m, migrated_conn, _) = migrated();
    assert_eq!(schema(&c), schema(&migrated_conn));
    // A write of a coordination table works; a view refuses one.
    c.execute("insert into event (at, kind) values (1.0, 'x')", [])
        .unwrap();
    assert!(c.execute("insert into node (id) values ('x')", []).is_err());
}

#[test]
fn no_git_runs_inside_the_transaction() {
    let (fx, _c, _) = migrated();
    let trace = hooks::trace(&fx.db);
    let begin = trace.iter().position(|s| *s == "begin").unwrap();
    let resolves: Vec<usize> = trace
        .iter()
        .enumerate()
        .filter(|(_, s)| **s == "resolve")
        .map(|(i, _)| i)
        .collect();
    assert!(!resolves.is_empty(), "{trace:?}");
    assert!(resolves.iter().all(|i| *i < begin), "{trace:?}");
    assert!(trace.iter().position(|s| *s == "commit").unwrap() > begin);
}

#[test]
fn denied_sources_are_not_migrated() {
    let (fx, c, report) = migrated();
    assert_eq!(
        (
            report.denied_nodes,
            report.denied_edges,
            report.denied_files
        ),
        (3, 2, 2)
    );
    let org: i64 = one(
        &c,
        "select count(*) from entity where id like '%/org/%' and id not like '%/org/board.org%'",
    );
    assert_eq!(org, 0);
    let board: i64 = one(
        &c,
        "select count(*) from entity where id like '%/org/board.org#t1'",
    );
    assert_eq!(board, 1, "the board is not a personal note");
    let files = rows(
        &c,
        "select path from file where path like '%/org/%' order by path",
    );
    assert_eq!(
        files,
        vec![vec![json!(format!("{}/org/board.org", fx.home.display()))]]
    );
    let linked: i64 = one(
        &c,
        "select count(*) from link where source like '%/org/%' or data like '%/org/%'",
    );
    assert_eq!(linked, 0);
    let kept: String = one(&c, "select value from kv where key = 'migrate-7'");
    let kept: Value = serde_json::from_str(&kept).unwrap();
    assert_eq!(kept["denied"], json!({"nodes": 3, "edges": 2, "files": 2}));
    assert!(
        !kept.to_string().contains("/org/"),
        "the report names no path of the user's"
    );
    assert_eq!(report.denied_in, vec![report.backup.clone().unwrap()]);
    // After the scrub, the canary is in neither the file nor its WAL (the pre-migration copy still has it).
    assert!(!file_has(&fx.db, CANARY));
    assert!(!file_has(&wal_of(&fx.db), CANARY));
    assert!(file_has(report.backup.as_ref().unwrap(), CANARY));
}

#[test]
fn an_edge_whose_own_source_is_denied_is_not_migrated() {
    // Both ends pass the node door; only the edge's source names a file under org/ (the edge door alone denies it).
    // Its twin with a project source is kept.
    let fx = empty_fx();
    fs::create_dir_all(fx.home.join("org")).unwrap();
    fs::write(fx.home.join("org/notes.org"), "* a note\n").unwrap();
    let h = fx.home.display().to_string();
    let c = Connection::open(&fx.db).unwrap();
    c.execute_batch(DDL6).unwrap();
    c.execute_batch(&format!(
        "insert into node (id, kind, title, path, line, status, parent, ord, source, data, updated) values
           ('plan:{h}/w/p.md', 'plan', 'P', '{h}/w/p.md', 1, 'open', null, null, '{h}/w/p.md', null, 1.0),
           ('spec:{h}/w/s.md', 'spec', 'S', '{h}/w/s.md', 1, null, null, null, 'spec {h}/w/s.md', null, 1.0),
           ('spec:{h}/w/t.md', 'spec', 'T', '{h}/w/t.md', 1, null, null, null, 'spec {h}/w/t.md', null, 1.0);
         insert into edge (src, dst, kind, origin, source) values
           ('plan:{h}/w/p.md', 'spec:{h}/w/s.md', 'derives', 'parsed', '{h}/org/notes.org'),
           ('plan:{h}/w/p.md', 'spec:{h}/w/t.md', 'derives', 'parsed', '{h}/w/p.md');"
    ))
    .unwrap();
    drop(c);
    let mut c = writer_conn(&fx.db);
    let report = run(&mut c, &fx.db, &fx.opts).unwrap();
    assert_eq!((report.denied_nodes, report.denied_edges), (0, 1));
    assert_eq!(report.links["derives->denied"], 1);
    assert_eq!(
        rows(
            &c,
            "select src, dst, source from edge where kind = 'derives'"
        ),
        vec![vec![
            json!(format!("plan:{h}/w/p.md")),
            json!(format!("spec:{h}/w/t.md")),
            json!(format!("{h}/w/p.md"))
        ]]
    );
}

#[test]
fn the_spec_form_is_denied() {
    let (fx, c, report) = migrated();
    let home = fx.home.display();
    let spec: i64 = one(
        &c,
        &format!("select count(*) from entity where id = 'spec:{home}/org/notes.org'"),
    );
    assert_eq!(spec, 0);
    assert_eq!(report.links["derives->denied"], 1);
    let p3: i64 = one(
        &c,
        &format!("select count(*) from entity where id = 'plan:{home}/w/alpha/docs/plans/p3.md'"),
    );
    assert_eq!(p3, 1, "the plan stays, its link to the notes does not");
    let p3_links = rows(
        &c,
        &format!(
            "select dst from edge where src = 'plan:{home}/w/alpha/docs/plans/p3.md' and kind = 'derives'"
        ),
    );
    assert_eq!(
        p3_links,
        vec![vec![json!(format!("spec:{home}/w/alpha/docs/specs/s3.md"))]]
    );
    // The source string alone denies a node whose id and path say nothing.
    let deny = DenyList::load(&fx.home, &fx.opts.config_dir);
    let node = |source: &str| OldNode {
        id: Some("spec:x".into()),
        kind: Some("spec".into()),
        title: None,
        path: None,
        line: None,
        status: None,
        parent: None,
        ord: None,
        source: Some(source.into()),
        data: None,
        updated: None,
    };
    assert!(node_denied(
        &deny,
        &node(&format!("spec {home}/org/notes.org"))
    ));
    assert!(
        node_denied(&deny, &node("spec relative/notes.org")),
        "an unknown form is denied"
    );
    assert!(!node_denied(
        &deny,
        &node(&format!("spec {home}/w/alpha/s.md"))
    ));
}

/// Task 8 on a store Task 11 made: an imported entity's text leaves every version (the imported, approximate one in
/// `entity_hist` included), the file and its WAL; the pre-migration copy is a kept copy that still holds it.
#[tokio::test]
async fn excise_on_a_migrated_store_leaves_no_trace() {
    use urdr::graph::excise::{self, Target};
    const TEXT: &str = "EXCISE-MIGRATED-c4n4ry";
    let fx = fixture();
    {
        let c = Connection::open(&fx.db).unwrap();
        c.execute(
            "update jtask set title = ?1, data = ?2 where id = 'j1#2'",
            [
                format!("{TEXT} title"),
                json!({ "note": format!("{TEXT} note") }).to_string(),
            ],
        )
        .unwrap();
    }
    let (writer, handle) =
        Writer::spawn(&fx.db, WriterOpts::default(), open_rule(fx.opts.clone())).unwrap();
    handle.tick().await;
    assert_eq!(
        handle.status().last_open,
        Some(OpenOutcome::Ready { schema: SCHEMA })
    );
    let read = || Connection::open(&fx.db).unwrap();
    let n: i64 = one(&read(), "select n from entity where id = 'task:j1#2'");
    // A change after the migration moves the imported version into entity_hist.
    handle
        .write(
            TxMeta::new("hub", Class::System, "test"),
            move |tx: &mut Tx<'_>| {
                entity::update(
                    tx,
                    n,
                    None,
                    Changes {
                        body: Some(Some(format!("{TEXT} body"))),
                        ..Changes::default()
                    },
                )
                .map(|_| ())
            },
        )
        .await
        .unwrap();
    let imported = format!(
        "select count(*) from entity_hist h join tx t on t.id = h.tx_from where h.n = {n} and t.imported = 1"
    );
    let imported_versions: i64 = one(&read(), &imported);
    assert!(imported_versions >= 1, "an imported version in entity_hist");
    let first: i64 = one(
        &read(),
        &format!("select created_tx from entity where n = {n}"),
    );
    let asof = hist::entity_as_of(&read(), n, first).unwrap().unwrap();
    assert!(asof.approximate, "the imported version is approximate");
    assert!(file_has(&fx.db, TEXT.as_bytes()) || file_has(&wal_of(&fx.db), TEXT.as_bytes()));
    let report = excise::excise(
        &handle,
        TxMeta::new("user", Class::User, "cli:graph-excise"),
        Target::Entity("task:j1#2".into()),
        None,
        "integration".into(),
        vec![],
    )
    .await
    .unwrap();
    let scrubbed = excise::scrub(&handle).await.unwrap();
    assert!(scrubbed.vacuumed && scrubbed.wal_truncated, "{scrubbed:?}");
    let c = read();
    let left: i64 = one(
        &c,
        &format!(
            "select count(*) from (select title, body, data from entity_hist where n = {n} \
             union all select title, body, data from entity where n = {n}) \
             where title like '%{TEXT}%' or body like '%{TEXT}%' or data like '%{TEXT}%'"
        ),
    );
    assert_eq!(left, 0, "every version blanked");
    let still_imported: i64 = one(&c, &imported);
    assert_eq!(still_imported, imported_versions, "the history stays");
    drop(c);
    assert!(!file_has(&fx.db, TEXT.as_bytes()), "work.db holds the text");
    assert!(
        !file_has(&wal_of(&fx.db), TEXT.as_bytes()),
        "work.db-wal holds the text"
    );
    // The pre-migration copy is a kept copy, and it still holds the text.
    let pre7 = fx.opts.backup_dir.join(&fx.backups()[0]);
    assert!(
        fx.backups()[0].starts_with("work-pre7-"),
        "{:?}",
        fx.backups()
    );
    let kept = excise::kept_copies(&fx.db);
    assert!(kept.contains(&pre7), "{kept:?}");
    assert_eq!(excise::holding(&kept, &report.needles), vec![pre7]);
    tokio::task::spawn_blocking(move || writer.shutdown())
        .await
        .unwrap();
}
