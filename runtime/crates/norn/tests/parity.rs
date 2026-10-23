//! The Lisp oracle's cases replayed against the Rust writers (Task 4; on schema 7 since Urdr Task 12).
//! `test/fixtures/coord-parity/CASE.input.json` is replayed with the case's clock; the results and the tables must
//! equal `CASE.expect.json`, which `gen.el` made from the real Lisp functions.  Tasks 5 and 6 add cases (one fixture
//! file each).
//!
//! The database is the hub's: a schema-6 file made from `work-db-6.sql` and the case's setup, opened by the graph
//! writer's opening rule (so migrated to schema 7), and every call is one write of that writer.  The tables are
//! compared **through the compat views and the kept tables**: `jtask`, `jdep` and `decision` are views over
//! entities and links, `meta` a view over `kv`; the new `tx` and `entity` columns of the kept tables, and the keys the
//! migration and the schema bump add to `meta`, are left out (`every_write_has_one_tx_row` looks at the first).

use norn::read::decisions::Decision;
use norn::read::messages as rmessages;
use norn::store::{CoordDb, CoordError, WTx};
use norn::write::agents::{self, AgentField, AgentRegister};
use norn::write::cards::{self, CardSet, NewCard};
use norn::write::decisions::{self, Decide, DecideResult, Held};
use norn::write::event::{Event, EventKind, event};
use norn::write::jobs::{self, NewJob, NewTask};
use norn::write::messages::{self, NoticeChange, Send, SendResult};
use norn::write::meta;
use norn::write::prune;
use norn::write::review;
use norn::write::tasks::{self, ClaimResult};
use serde_json::{Value, json};
use std::path::PathBuf;
use urdr::Connection;
use urdr::graph::{Class, TxMeta};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures")
}

/// "__REP:C:N__" is the character C, N times.
fn expand(v: Value) -> Value {
    match v {
        Value::String(s) => {
            let rep = s
                .strip_prefix("__REP:")
                .and_then(|r| r.strip_suffix("__"))
                .and_then(|r| r.split_once(':'));
            match rep {
                Some((c, n)) if c.chars().count() == 1 => {
                    Value::String(c.repeat(n.parse().expect("repeat count")))
                }
                _ => Value::String(s),
            }
        }
        Value::Array(a) => Value::Array(a.into_iter().map(expand).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, expand(v))).collect()),
        v => v,
    }
}

/// Every number as a float, so `100` and `100.0` compare equal.
fn norm(v: Value) -> Value {
    match v {
        Value::Number(n) => json!(n.as_f64().unwrap()),
        Value::Array(a) => Value::Array(a.into_iter().map(norm).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, norm(v))).collect()),
        v => v,
    }
}

fn text(args: &Value, key: &str) -> Option<String> {
    args.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// The clock of a case: one reading per call.
type Clock = dyn Iterator<Item = f64>;

fn event_of(args: &Value, clock: &mut Clock) -> Event {
    let data = args.get("data").filter(|d| !d.is_null()).cloned();
    Event {
        at: args
            .get("at")
            .and_then(Value::as_f64)
            .unwrap_or_else(|| clock.next().expect("the clock ran out")),
        agent: text(args, "agent"),
        job: text(args, "job"),
        task: text(args, "task"),
        kind: EventKind::parse(args["kind"].as_str().unwrap()).expect("an event kind"),
        summary: text(args, "summary").unwrap_or_default(),
        turn: data.as_ref().is_some_and(|d| d["turn"] == json!(true)),
        data,
    }
}

fn call(tx: &mut WTx<'_>, fn_name: &str, args: &Value, clock: &mut Clock) -> Value {
    let agent = || args["agent"].as_str().unwrap().to_owned();
    let ok = |r: Result<u64, CoordError>| json!(r.unwrap());
    match fn_name {
        "drgnx-coord-event-add" | "drgnx-coord-event-add-best-effort" => {
            json!(event(tx, event_of(args, clock)).unwrap())
        }
        "drgnx-coord-version" => ok(meta::version(tx.sql())),
        "drgnx-coord--bump" => ok(meta::bump_version(tx)),
        "drgnx-coord-set-seen" => {
            meta::set_seen(tx, &agent(), args["version"].as_u64().unwrap()).unwrap();
            Value::Null
        }
        "drgnx-coord-seen" => ok(meta::seen(tx.sql(), &agent())),
        "drgnx-coord-note-held" => {
            let held = args["held"].as_bool().unwrap().then_some(0);
            meta::note_held(tx, &agent(), held).unwrap();
            Value::Null
        }
        "drgnx-coord-held" => ok(meta::held(tx.sql(), &agent())),
        other => call_task5(tx, other, args, clock),
    }
}

// ---- Task 6: jobs, tasks and leases, decisions, pruning ----

/// The time of a call that has `"now"` in its case (the clock then answers it forever).
fn now_of(clock: &mut Clock) -> f64 {
    clock.next().expect("this call needs a \"now\" in its case")
}

/// An empty list is nil in the Lisp, so null in the oracle's output.
fn list_or_null(v: Vec<Value>) -> Value {
    if v.is_empty() { Value::Null } else { json!(v) }
}

fn decision_json(d: &Decision) -> Value {
    json!({"n": d.n, "kind": d.kind, "subject": d.subject, "task": d.task, "paths": d.paths,
           "reason": d.reason, "author": d.author, "status": d.status, "job": d.job,
           "replaces": d.replaces, "at": d.at, "ver": d.ver})
}

fn held_json(h: &Held) -> Value {
    json!({"held": true, "version": h.version,
           "changes": list_or_null(h.changes.iter().map(decision_json).collect())})
}

fn claim_json(r: ClaimResult) -> Value {
    match r {
        ClaimResult::Ok => json!({"ok": true}),
        ClaimResult::Held(h) => held_json(&h),
        ClaimResult::Taken(a) => json!({"taken": a}),
        ClaimResult::NotReady(d) => {
            json!({"not-ready": list_or_null(d.into_iter().map(Value::from).collect())})
        }
        ClaimResult::Error(m) => json!({"error": m}),
    }
}

/// A refused call is `{"signal": MESSAGE}`, as the oracle records an error.
fn signal(r: Result<Value, CoordError>) -> Value {
    match r {
        Ok(v) => v,
        Err(CoordError::Refused(m)) => json!({"signal": m}),
        Err(e) => panic!("{e}"),
    }
}

fn seen_of(args: &Value) -> Option<u64> {
    args.get("seen").and_then(Value::as_u64)
}

fn call_jobs(tx: &mut WTx<'_>, fn_name: &str, args: &Value, clock: &mut Clock) -> Value {
    let s = |k: &str| text(args, k);
    let req = |k: &str| text(args, k).unwrap_or_else(|| panic!("{fn_name} needs {k}"));
    let data = args.get("data").filter(|d| !d.is_null()).cloned();
    signal(match fn_name {
        "drgnx-coord-job-create" => {
            let tasks = args["tasks"]
                .as_array()
                .map(|ts| {
                    ts.iter()
                        .map(|t| NewTask {
                            n: t["n"].as_i64().unwrap(),
                            title: t["title"].as_str().unwrap().to_owned(),
                            role: text(t, "role"),
                            deps: t["deps"]
                                .as_array()
                                .map(|d| d.iter().map(|n| n.as_i64().unwrap()).collect())
                                .unwrap_or_default(),
                        })
                        .collect()
                })
                .unwrap_or_default();
            jobs::job_create(
                tx,
                NewJob {
                    id: req("id"),
                    title: req("title"),
                    plan: s("plan"),
                    repo: s("repo"),
                    tasks,
                    data,
                },
                now_of(clock),
            )
            .map(|id| json!(id))
        }
        "drgnx-coord-job-set" => jobs::job_set(
            tx,
            &req("id"),
            s("status").as_deref(),
            data.as_ref(),
            now_of(clock),
        )
        .map(|()| Value::Null),
        "drgnx-coord-force-status" => tasks::force_status(
            tx,
            &req("task"),
            &req("status"),
            s("agent").as_deref(),
            now_of(clock),
        )
        .map(|b| json!(b)),
        "drgnx-coord-claim" => tasks::claim(
            tx,
            &req("task"),
            &req("agent"),
            seen_of(args),
            now_of(clock),
        )
        .map(claim_json),
        "drgnx-coord-set-status" => tasks::set_status(
            tx,
            &req("task"),
            &req("agent"),
            &req("status"),
            seen_of(args),
            now_of(clock),
        )
        .map(claim_json),
        "drgnx-coord-heartbeat" => {
            tasks::heartbeat(tx, &req("task"), &req("agent"), now_of(clock)).map(|()| Value::Null)
        }
        "drgnx-coord-renew" => tasks::renew(tx, &req("agent"), now_of(clock)).map(|()| Value::Null),
        "drgnx-coord-release-stale" => tasks::release_stale(tx, now_of(clock)).map(|rs| {
            list_or_null(
                rs.into_iter()
                    .map(|r| json!({"task": r.task, "agent": r.agent, "job": r.job}))
                    .collect(),
            )
        }),
        "drgnx-coord-decide" => decisions::decide(
            tx,
            Decide {
                kind: req("kind"),
                subject: req("subject"),
                task: s("task"),
                paths: s("paths"),
                reason: s("reason"),
                author: req("author"),
                seen: seen_of(args),
                replaces: args.get("replaces").and_then(Value::as_i64),
                job: s("job"),
            },
            now_of(clock),
        )
        .map(|r| match r {
            DecideResult::Ok { n, status, version } => {
                json!({"ok": true, "n": n, "status": status, "version": version})
            }
            DecideResult::Held(h) => held_json(&h),
            DecideResult::Error(m) => json!({"error": m}),
        }),
        "drgnx-coord-events-prune" => prune::events_prune(tx, now_of(clock)).map(|n| json!(n)),
        "drgnx-coord--events-cap" => prune::events_cap_to(tx, args["max_rows"].as_i64().unwrap())
            .map(|n| n.map_or(Value::Null, |n| json!(n))),
        "drgnx-coord-events-prune-daily" => prune::prune_daily_tx(tx, now_of(clock))
            .map(|ran| if ran { json!(true) } else { Value::Null }),
        other => panic!("no Rust writer for {other}"),
    })
}

/// Columns the oracle's tables do not have: the kept tables' new `tx` and `entity`.
const NEW_COLUMNS: [&str; 2] = ["tx", "entity"];

/// One table as the oracle dumps it: rows in rowid order (`meta` by key, `decision` by number), `data` parsed.  The
/// views have no rowid: `jtask` and `jdep` come in the view's own order and are sorted by the comparison.
fn dump(conn: &Connection, table: &str) -> Value {
    let cols: Vec<String> = {
        let mut st = conn
            .prepare("select name from pragma_table_info(?1)")
            .unwrap();
        st.query_map([table], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .filter(|c: &String| !NEW_COLUMNS.contains(&c.as_str()))
            .collect()
    };
    let pairs: Vec<String> = cols.iter().map(|c| format!("'{c}', \"{c}\"")).collect();
    let order = match table {
        "meta" => "key",
        "decision" => "n",
        "jtask" | "jdep" => "1, 2",
        _ => "rowid",
    };
    let sql = format!(
        "select coalesce(json_group_array(json_object({})), '[]') from (select * from {table} order by {order})",
        pairs.join(", ")
    );
    let text: String = conn.query_row(&sql, [], |r| r.get(0)).unwrap();
    let mut rows: Value = serde_json::from_str(&text).unwrap();
    for row in rows.as_array_mut().unwrap() {
        if let Some(Value::String(d)) = row.get("data").cloned() {
            row["data"] = serde_json::from_str(&d).unwrap();
        }
    }
    rows
}

/// Every table a case can name (`"tables"` in `gen.el`); only the ones `CASE.expect.json` has are compared.
const TABLES: [&str; 10] = [
    "event",
    "meta",
    "message",
    "card",
    "review_mark",
    "agent",
    "job",
    "jtask",
    "jdep",
    "decision",
];

/// The keys the schema-6 file, its migration and the schema bump keep in `meta` besides what the writers put there.
const SCHEMA_KEYS: [&str; 4] = ["schema", "compat-read", "migrate-6-dropped", "migrate-7"];

/// What the comparison looks at: the writers' `meta` keys only, and the view tables in a fixed order (their rows have
/// no rowid to be in).
fn tidy(mut tables: Value) -> Value {
    let map = tables.as_object_mut().unwrap();
    if let Some(Value::Array(rows)) = map.get_mut("meta") {
        rows.retain(|r| !SCHEMA_KEYS.contains(&r["key"].as_str().unwrap_or("")));
    }
    for view in ["jtask", "jdep"] {
        if let Some(Value::Array(rows)) = map.get_mut(view) {
            rows.sort_by_key(|r| r.to_string());
        }
    }
    tables
}

/// A case replayed: the database it ran on (kept for the caller to look at) and what the calls answered.
struct Replayed {
    db: CoordDb,
    file: PathBuf,
    results: Vec<Value>,
    /// `tx` rows before the first call (the migration's own) and after the last.
    txs: (i64, i64),
    _dir: tempfile::TempDir,
}

/// A schema-6 database with the case's setup, opened by the graph writer, and every call as one write of it.
async fn run(input: &Value) -> Replayed {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    {
        let conn = Connection::open(&file).unwrap();
        conn.execute_batch(&std::fs::read_to_string(fixtures().join("work-db-6.sql")).unwrap())
            .unwrap();
        for sql in input["setup"].as_array().unwrap() {
            conn.execute_batch(sql.as_str().unwrap()).unwrap();
        }
    }
    let db = CoordDb::spawn(&file);
    let count_txs = |db: &CoordDb| {
        let db = db.clone();
        async move {
            db.read(|c| Ok(c.query_row("select count(*) from tx", [], |r| r.get::<_, i64>(0))?))
                .await
                .unwrap()
        }
    };
    let before = count_txs(&db).await;
    let mut clock: std::vec::IntoIter<f64> = input["clock"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t.as_f64().unwrap())
        .collect::<Vec<_>>()
        .into_iter();
    let mut results = Vec::new();
    for c in input["calls"].as_array().unwrap() {
        let name = c["fn"].as_str().unwrap().to_owned();
        let args = c["args"].clone();
        let now = c.get("now").and_then(Value::as_f64);
        let meta = TxMeta::new("hub", Class::System, format!("parity:{name}"));
        let taken = clock;
        let (value, back) = db
            .write(meta, move |tx| {
                let mut mine = taken;
                // A call with "now" sees that time at every `float-time`; the others take the clock.
                let v = match now {
                    Some(now) => call(tx, &name, &args, &mut std::iter::repeat(now)),
                    None => call(tx, &name, &args, &mut mine),
                };
                Ok((v, mine))
            })
            .await
            .unwrap();
        clock = back;
        results.push(value);
    }
    let after = count_txs(&db).await;
    Replayed {
        db,
        file,
        results,
        txs: (before, after),
        _dir: dir,
    }
}

/// The tables of the case, as `dump` reads them from the database after the calls.
fn tables_of(r: &Replayed) -> Value {
    let conn = Connection::open(&r.file).unwrap();
    let tables: serde_json::Map<String, Value> = TABLES
        .iter()
        .map(|t| ((*t).to_owned(), dump(&conn, t)))
        .collect();
    Value::Object(tables)
}

fn cases() -> Vec<(String, Value, Value)> {
    let dir = fixtures().join("coord-parity");
    let mut inputs: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.to_string_lossy().ends_with(".input.json"))
        // the tools' cases (`tools-*`) are tests/tools.rs's
        .filter(|p| {
            !p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("tools-")
        })
        .collect();
    inputs.sort();
    assert!(!inputs.is_empty(), "no cases in {}", dir.display());
    inputs
        .into_iter()
        .map(|path| {
            let name = path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .replace(".input.json", "");
            let input = expand(serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap());
            let expect_path = dir.join(format!("{name}.expect.json"));
            let expect: Value =
                serde_json::from_slice(&std::fs::read(&expect_path).unwrap()).unwrap();
            (name, input, expect)
        })
        .collect()
}

#[tokio::test]
async fn every_writer_fixture_replays() {
    for (name, input, expect) in cases() {
        let replayed = run(&input).await;
        let mut tables = tables_of(&replayed);
        // Only the tables the case expects are compared.
        let wanted: Vec<String> = expect["tables"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        tables
            .as_object_mut()
            .unwrap()
            .retain(|k, _| wanted.contains(k));
        let got = json!({"results": replayed.results, "tables": tidy(tables)});
        let mut expect = expand(expect);
        expect["tables"] = tidy(expect["tables"].take());
        assert_eq!(norm(got), norm(expect), "case {name}");
    }
}

/// Every call of a case is one write of the graph writer: one `tx` row each (the migration's own apart), and every row
/// a writer made in a kept table names a tx.
#[tokio::test]
async fn every_write_has_one_tx_row() {
    let mut checked = 0;
    for (name, input, _) in cases() {
        // the cases whose setup inserts kept rows by hand leave rows with no tx
        if !input["setup"].as_array().unwrap().is_empty() {
            continue;
        }
        let replayed = run(&input).await;
        let calls = input["calls"].as_array().unwrap().len() as i64;
        assert_eq!(
            replayed.txs.1 - replayed.txs.0,
            calls,
            "case {name}: one tx row per call"
        );
        for table in ["event", "message", "card", "review_mark", "agent", "job"] {
            let orphans: i64 = replayed
                .db
                .read(move |c| {
                    Ok(c.query_row(
                        &format!(
                            "select count(*) from {table} where tx is null or tx not in (select id from tx)"
                        ),
                        [],
                        |r| r.get(0),
                    )?)
                })
                .await
                .unwrap();
            assert_eq!(orphans, 0, "case {name}: a {table} row names no tx");
        }
        checked += 1;
    }
    assert!(checked >= 5, "only {checked} cases were looked at");
}

/// Task 5's writers: messages, cards, review marks and agents.  The clock is one reading per call (the cases give
/// every call of a message or card case the same time, so the Lisp's several readings agree).
fn call_task5(tx: &mut WTx<'_>, fn_name: &str, args: &Value, clock: &mut Clock) -> Value {
    let mut now = || clock.next().expect("the clock ran out");
    let int = |k: &str| args[k].as_i64().unwrap();
    let data = || args.get("data").filter(|d| !d.is_null()).cloned();
    match fn_name {
        "drgnx-coord-send" => {
            let s = Send {
                job: text(args, "job"),
                sender: text(args, "sender"),
                recipient: text(args, "recipient").unwrap(),
                text: text(args, "text").unwrap(),
                seen: args.get("seen").and_then(Value::as_u64),
                answers: args.get("answers").and_then(Value::as_i64),
                question: args.get("question") == Some(&json!(true)),
            };
            // `changes` is the decision reader's (Task 6); these cases have no decisions
            match messages::send(tx, s, now()).unwrap() {
                SendResult::Ok { id, state } => json!({"ok": true, "id": id, "state": state}),
                SendResult::Held { version, .. } => {
                    json!({"held": true, "version": version, "changes": []})
                }
            }
        }
        "drgnx-coord-mark" => {
            json!(messages::mark(tx, int("id"), args["state"].as_str().unwrap(), now()).unwrap())
        }
        "drgnx-coord-message-prompt" => {
            let id = int("id");
            let m = rmessages::message(tx.sql(), id).unwrap().unwrap();
            let q = rmessages::message_answers(tx.sql(), id).unwrap();
            json!(messages::message_prompt(&m, q.as_ref()))
        }
        "drgnx-coord-notice" => {
            let changes: Vec<NoticeChange> = args["changes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|d| NoticeChange {
                    n: d["n"].as_i64().unwrap(),
                    kind: text(d, "kind").unwrap(),
                    subject: text(d, "subject").unwrap(),
                    status: text(d, "status").unwrap(),
                })
                .collect();
            json!(messages::notice(
                args["v"].as_u64().unwrap(),
                args["job"].as_str().unwrap(),
                &changes,
                args["seen"].as_u64().unwrap()
            ))
        }
        "drgnx-coord-card-create" => {
            let c = NewCard {
                job: text(args, "job"),
                task: text(args, "task"),
                kind: text(args, "kind"),
                title: text(args, "title"),
                data: data(),
            };
            json!(cards::card_create(tx, c, now()).unwrap())
        }
        "drgnx-coord-card-settle" => json!(
            cards::card_settle(tx, int("id"), args["choice"].as_str().unwrap(), now()).unwrap()
        ),
        "drgnx-coord-card-set" => {
            let set = CardSet {
                title: text(args, "title"),
                data: data(),
                state: text(args, "state"),
            };
            cards::card_set(tx, int("id"), set, now()).unwrap();
            Value::Null
        }
        "drgnx-coord-review-mark" => json!(
            review::review_mark(
                tx,
                args["agent"].as_str().unwrap(),
                args["path"].as_str().unwrap(),
                args["state"].as_str().unwrap(),
                args["hash"].as_str().unwrap(),
                now(),
                None
            )
            .unwrap()
        ),
        "drgnx-coord-agent-register" => {
            let a = AgentRegister {
                id: text(args, "id").unwrap(),
                kind: text(args, "kind"),
                name: text(args, "name"),
                cwd: text(args, "cwd"),
                worktree: text(args, "worktree"),
                branch: text(args, "branch"),
                base: text(args, "base"),
                plan: text(args, "plan"),
                task: text(args, "task"),
                pid: args.get("pid").and_then(Value::as_i64),
                clear: args
                    .get("clear")
                    .and_then(Value::as_array)
                    .map(|c| {
                        c.iter()
                            .map(|f| AgentField::parse(f.as_str().unwrap()).unwrap())
                            .collect()
                    })
                    .unwrap_or_default(),
            };
            json!(agents::agent_register(tx, a, now()).unwrap())
        }
        "drgnx-coord-agent-seen" => {
            json!(agents::agent_seen(tx, args["id"].as_str().unwrap(), now()).unwrap())
        }
        other => call_jobs(tx, other, args, clock),
    }
}
