//! The Lisp oracle's cases replayed against the Rust writers (Task 4).  `test/fixtures/coord-parity/CASE.input.json`
//! is replayed with the case's clock; the results and the tables must equal `CASE.expect.json`, which
//! `gen.el` made from the real Lisp functions.  Tasks 5 and 6 add cases (one fixture file each).

use norn::read::messages as rmessages;
use norn::store::CoordError;
use norn::write::agents::{self, AgentField, AgentRegister};
use norn::write::cards::{self, CardSet, NewCard};
use norn::write::event::{Event, EventKind, event};
use norn::write::messages::{self, NoticeChange, Send, SendResult};
use norn::write::meta;
use norn::write::review;
use serde_json::{Value, json};
use std::path::PathBuf;
use urdr::Connection;

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

fn event_of(args: &Value, clock: &mut impl Iterator<Item = f64>) -> Event {
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

fn call(
    conn: &Connection,
    fn_name: &str,
    args: &Value,
    clock: &mut impl Iterator<Item = f64>,
) -> Value {
    let agent = || args["agent"].as_str().unwrap().to_owned();
    let ok = |r: Result<u64, CoordError>| json!(r.unwrap());
    match fn_name {
        "drgnx-coord-event-add" | "drgnx-coord-event-add-best-effort" => {
            json!(event(conn, event_of(args, clock)).unwrap())
        }
        "drgnx-coord-version" => ok(meta::version(conn)),
        "drgnx-coord--bump" => ok(meta::bump_version(conn)),
        "drgnx-coord-set-seen" => {
            meta::set_seen(conn, &agent(), args["version"].as_u64().unwrap()).unwrap();
            Value::Null
        }
        "drgnx-coord-seen" => ok(meta::seen(conn, &agent())),
        "drgnx-coord-note-held" => {
            let held = args["held"].as_bool().unwrap().then_some(0);
            meta::note_held(conn, &agent(), held).unwrap();
            Value::Null
        }
        "drgnx-coord-held" => ok(meta::held(conn, &agent())),
        other => call_task5(conn, other, args, clock),
    }
}

/// One table as the oracle dumps it: rows in rowid order (`meta` by key), `data` parsed.
fn dump(conn: &Connection, table: &str) -> Value {
    let cols: Vec<String> = {
        let mut st = conn
            .prepare("select name from pragma_table_info(?1)")
            .unwrap();
        st.query_map([table], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    };
    let pairs: Vec<String> = cols.iter().map(|c| format!("'{c}', \"{c}\"")).collect();
    let order = if table == "meta" { "key" } else { "rowid" };
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

fn replay(input: &Value) -> Value {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(&std::fs::read_to_string(fixtures().join("work-db-6.sql")).unwrap())
        .unwrap();
    for sql in input["setup"].as_array().unwrap() {
        conn.execute_batch(sql.as_str().unwrap()).unwrap();
    }
    let mut clock = input["clock"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t.as_f64().unwrap())
        .collect::<Vec<_>>()
        .into_iter();
    let results: Vec<Value> = input["calls"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| call(&conn, c["fn"].as_str().unwrap(), &c["args"], &mut clock))
        .collect();
    let tables: serde_json::Map<String, Value> =
        ["event", "meta", "message", "card", "review_mark", "agent"]
            .into_iter()
            .map(|t| (t.to_string(), dump(&conn, t)))
            .collect();
    json!({"results": results, "tables": tables})
}

#[test]
fn every_writer_fixture_replays() {
    let dir = fixtures().join("coord-parity");
    let mut inputs: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.to_string_lossy().ends_with(".input.json"))
        .collect();
    inputs.sort();
    assert!(!inputs.is_empty(), "no cases in {}", dir.display());
    for path in inputs {
        let name = path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .replace(".input.json", "");
        let input = expand(serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap());
        let expect_path = dir.join(format!("{name}.expect.json"));
        let expect: Value = serde_json::from_slice(&std::fs::read(&expect_path).unwrap()).unwrap();
        let mut got = replay(&input);
        // Only the tables the case expects are compared.
        let wanted: Vec<String> = expect["tables"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        got["tables"]
            .as_object_mut()
            .unwrap()
            .retain(|k, _| wanted.contains(k));
        assert_eq!(norm(got), norm(expand(expect)), "case {name}");
    }
}

/// Task 5's writers: messages, cards, review marks and agents.  The clock is one reading per call (the cases give
/// every call of a message or card case the same time, so the Lisp's several readings agree).
fn call_task5(
    conn: &Connection,
    fn_name: &str,
    args: &Value,
    clock: &mut impl Iterator<Item = f64>,
) -> Value {
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
            match messages::send(conn, s, now()).unwrap() {
                SendResult::Ok { id, state } => json!({"ok": true, "id": id, "state": state}),
                SendResult::Held { version, .. } => {
                    json!({"held": true, "version": version, "changes": []})
                }
            }
        }
        "drgnx-coord-mark" => {
            json!(messages::mark(conn, int("id"), args["state"].as_str().unwrap(), now()).unwrap())
        }
        "drgnx-coord-message-prompt" => {
            let id = int("id");
            let m = rmessages::message(conn, id).unwrap().unwrap();
            let q = rmessages::message_answers(conn, id).unwrap();
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
            json!(cards::card_create(conn, c, now()).unwrap())
        }
        "drgnx-coord-card-settle" => json!(
            cards::card_settle(conn, int("id"), args["choice"].as_str().unwrap(), now()).unwrap()
        ),
        "drgnx-coord-card-set" => {
            let set = CardSet {
                title: text(args, "title"),
                data: data(),
                state: text(args, "state"),
            };
            cards::card_set(conn, int("id"), set, now()).unwrap();
            Value::Null
        }
        "drgnx-coord-review-mark" => json!(
            review::review_mark(
                conn,
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
            json!(agents::agent_register(conn, a, now()).unwrap())
        }
        "drgnx-coord-agent-seen" => {
            json!(agents::agent_seen(conn, args["id"].as_str().unwrap(), now()).unwrap())
        }
        other => panic!("no Rust writer for {other}"),
    }
}
