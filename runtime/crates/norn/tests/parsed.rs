//! `graph/put-parsed` and `graph/record` (Urdr Task 15a; storage §5.6 door 1): every path a record carries checked
//! against the deny-list, the consistency of a source and its entities, the content compare, derived statuses, and
//! a collected key recorded once.  Personal notes are a fixture under a temp HOME; nothing here reads `~`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use norn::deny::DenyList;
use norn::parsed::{self, DENIED, PutAnswer, PutParsed, Record};
use norn::project::{ProjectCache, ProjectRef};
use norn::store::CoordDb;
use serde_json::{Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, EntityNew, Origin};
use urdr::graph::guard::Guard;
use urdr::graph::schema::GRAPH_DDL;
use urdr::graph::{Class, Tx, TxMeta};

const CANARY: &str = "CANARY-15a-7f3e";

struct Fx {
    _dir: tempfile::TempDir,
    home: PathBuf,
    /// A plan file outside `~/org`.
    plan: String,
    deny: DenyList,
}

impl Fx {
    fn notes(&self) -> String {
        self.home
            .join("org/notes.org")
            .to_string_lossy()
            .into_owned()
    }
}

fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(home.join("org")).unwrap();
    std::fs::write(home.join("org/notes.org"), format!("* {CANARY} private\n")).unwrap();
    let plans = dir.path().join("work/docs/plans");
    std::fs::create_dir_all(&plans).unwrap();
    let plan = plans.join("p.md");
    std::fs::write(&plan, "# P\n### Task 1: one\n- [ ] a\n").unwrap();
    let deny = DenyList::load(&home, &dir.path().join("config"));
    Fx {
        plan: plan.to_string_lossy().into_owned(),
        home,
        deny,
        _dir: dir,
    }
}

/// Schema 7's graph tables, and the two hub-owned tables a put writes (`parsed_file`, `kv`).
fn db() -> Connection {
    let c = Connection::open_in_memory().unwrap();
    c.execute_batch(GRAPH_DDL).unwrap();
    c.execute_batch(
        "create table parsed_file (path text primary key, mtime real);
         create table kv (key text primary key, value text);",
    )
    .unwrap();
    c
}

fn guard() -> Arc<Guard> {
    let mut g = Guard::default();
    norn::grants::register(&mut g);
    Arc::new(g)
}

fn scan() -> TxMeta {
    TxMeta::new("scan:/w", Class::System, "scan")
}

fn put(c: &mut Connection, deny: &DenyList, req: Value) -> PutAnswer {
    let req: PutParsed = serde_json::from_value(req).unwrap();
    let mut tx = Tx::for_test(c, scan(), guard());
    let a = parsed::put(&mut tx, deny, req).unwrap();
    tx.commit_for_test().unwrap();
    a
}

fn count(c: &Connection, sql: &str) -> i64 {
    c.query_row(sql, [], |r| r.get(0)).unwrap()
}

/// The plan P as the scan reads it: the plan, task 1 and its step, with the step's parent.
fn plan_source(p: &str) -> Value {
    json!({
        "source": {"kind": "file", "path": p},
        "mtime": 10.0,
        "entities": [
            {"id": format!("plan:{p}"), "kind": "plan", "title": "P", "status": "open", "data": {"path": p, "line": 1}},
            {"id": format!("task:{p}#1"), "kind": "task", "title": "one", "status": "open",
             "data": {"path": p, "line": 2, "parent": format!("plan:{p}"), "ord": 1}},
            {"id": format!("step:{p}#1.1"), "kind": "step", "title": "a", "status": "open",
             "data": {"path": p, "line": 3, "parent": format!("task:{p}#1"), "ord": 1}}
        ]
    })
}

/// Nothing anywhere in the store holds the canary or the notes' path.
fn nothing_of_the_notes(c: &Connection, f: &Fx) {
    let notes = f.notes();
    for needle in [CANARY, notes.as_str()] {
        let like = format!("%{needle}%");
        let n: i64 = c
            .query_row(
                "select (select count(*) from entity where id like ?1 or title like ?1 or data like ?1 or source like ?1) \
                      + (select count(*) from parsed_file where path like ?1) \
                      + (select count(*) from link where source like ?1)",
                [&like],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0, "{needle} is stored");
    }
}

fn refused_why(a: &PutAnswer) -> Vec<&str> {
    a.refused.iter().map(|r| r.why.as_str()).collect()
}

#[test]
fn rechecks_the_deny_list() {
    let f = fx();
    let mut c = db();
    let notes = f.notes();
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [{
            "source": {"kind": "file", "path": notes}, "mtime": 1.0,
            "entities": [{"id": format!("todo:{notes}#1"), "kind": "todo", "title": CANARY, "data": {"path": notes}}]
        }]}),
    );
    assert_eq!(refused_why(&a), [DENIED]);
    assert_eq!(
        a.refused[0]
            .source
            .as_ref()
            .unwrap()
            .path
            .as_ref()
            .unwrap()
            .as_str(),
        notes
    );
    assert_eq!((a.changed, a.retired), (0, 0));
    assert_eq!(count(&c, "select count(*) from entity"), 0);
    nothing_of_the_notes(&c, &f);
}

#[test]
fn the_spec_form_is_checked_by_its_path() {
    let f = fx();
    let mut c = db();
    let notes = f.notes();
    // the spec source of a plan's `**Spec:**` naming ../../org/notes.org (schema 6's `"spec <path>"` source)
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [{
            "source": {"kind": "spec", "path": notes},
            "entities": [{"id": format!("spec:{notes}"), "kind": "spec", "title": CANARY, "data": {"path": notes, "line": 1}}]
        }]}),
    );
    assert_eq!(refused_why(&a), [DENIED]);
    // a `..` form of the same file is the same file
    let dotted = format!("{}/../org/notes.org", f.home.join("org").display());
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [{"source": {"kind": "spec", "path": dotted},
                            "entities": [{"id": format!("spec:{dotted}"), "kind": "spec"}]}]}),
    );
    assert_eq!(refused_why(&a), [DENIED]);
    nothing_of_the_notes(&c, &f);
}

#[test]
fn an_id_path_into_org_is_refused() {
    let f = fx();
    let mut c = db();
    let notes = f.notes();
    // the source is an allowed file; one entity's id names the notes
    let mut src = plan_source(&f.plan);
    src["entities"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id": format!("task:{notes}#2"), "kind": "task", "title": CANARY}));
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert_eq!(refused_why(&a), [DENIED]);
    // the whole source: none of its entities is stored, nor its file's time
    assert_eq!(count(&c, "select count(*) from entity"), 0);
    assert_eq!(count(&c, "select count(*) from parsed_file"), 0);
    nothing_of_the_notes(&c, &f);
}

#[test]
fn data_path_into_org_is_refused() {
    let f = fx();
    let mut c = db();
    let notes = f.notes();
    // each refused by its own check: data.path through the record's paths, data.repo and data.worktree by name
    for (key, value) in [
        ("path", notes.clone()),
        ("repo", f.home.join("org").display().to_string()),
        ("worktree", f.home.join("org").display().to_string()),
    ] {
        let mut src = plan_source(&f.plan);
        src["entities"][1]["data"][key] = json!(value);
        let a = put(&mut c, &f.deny, json!({"sources": [src]}));
        assert_eq!(refused_why(&a), [DENIED], "data.{key}");
    }
    // a parent id into ~/org
    let mut src = plan_source(&f.plan);
    src["entities"][2]["data"]["parent"] = json!(format!("task:{notes}#1"));
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert_eq!(refused_why(&a), [DENIED]);
    assert_eq!(count(&c, "select count(*) from entity"), 0);
    nothing_of_the_notes(&c, &f);
}

#[test]
fn a_link_to_a_denied_id_is_refused() {
    let f = fx();
    let mut c = db();
    let notes = f.notes();
    let p = &f.plan;
    let mut src = plan_source(p);
    src["links"] =
        json!([{"src": format!("plan:{p}"), "kind": "derives", "dst": format!("spec:{notes}")}]);
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert_eq!(refused_why(&a), [DENIED]);
    assert_eq!(count(&c, "select count(*) from entity"), 0);
    assert_eq!(count(&c, "select count(*) from link"), 0);
    nothing_of_the_notes(&c, &f);
}

#[test]
fn an_entity_path_unlike_its_source_is_refused() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    let other = format!("{}/q.md", Path::new(p).parent().unwrap().display());
    // an entity of another file
    let mut src = plan_source(p);
    src["entities"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id": format!("task:{other}#1"), "kind": "task"}));
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert_eq!(a.refused.len(), 1);
    assert!(
        a.refused[0]
            .why
            .contains("does not carry its source's path"),
        "{a:?}"
    );
    // a data.path unlike its source's
    let mut src = plan_source(p);
    src["entities"][0]["data"]["path"] = json!(other);
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert!(a.refused[0].why.contains("data.path"), "{a:?}");
    // a spec is its own source: a plan file holds none, and a spec source holds only its own spec
    let mut src = plan_source(p);
    src["entities"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id": format!("spec:{p}"), "kind": "spec"}));
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert!(a.refused[0].why.contains("holds no spec"), "{a:?}");
    // a commit source carries no path
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [{"source": {"kind": "commit", "path": p}}]}),
    );
    assert!(
        a.refused[0].why.contains("commit or branch source none"),
        "{a:?}"
    );
    assert_eq!(count(&c, "select count(*) from entity"), 0);
}

#[test]
fn unchanged_is_untouched() {
    let f = fx();
    let mut c = db();
    let a = put(&mut c, &f.deny, json!({"sources": [plan_source(&f.plan)]}));
    assert_eq!((a.changed, a.retired, a.refused.len()), (3, 0, 0));
    // parent_of from data.parent: plan → task → step
    assert_eq!(
        count(&c, "select count(*) from link where kind = 'parent_of'"),
        2
    );
    assert_eq!(
        count(&c, "select count(*) from parsed_file where mtime = 10.0"),
        1
    );
    let a = put(&mut c, &f.deny, json!({"sources": [plan_source(&f.plan)]}));
    assert_eq!((a.changed, a.retired, a.refused.len()), (0, 0, 0));
    assert_eq!(count(&c, "select count(*) from entity_hist"), 0);
    assert_eq!(count(&c, "select max(ver) from entity"), 1);
    assert_eq!(count(&c, "select count(*) from link"), 2);
    // a changed title is one new version, nothing else
    let mut src = plan_source(&f.plan);
    src["entities"][1]["title"] = json!("one, renamed");
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert_eq!((a.changed, a.retired), (1, 0));
    assert_eq!(count(&c, "select count(*) from entity_hist"), 1);
}

#[test]
fn gone_retires() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    // the step left the plan: retired, its parent_of link too
    let mut src = plan_source(p);
    src["entities"].as_array_mut().unwrap().pop();
    let a = put(&mut c, &f.deny, json!({"sources": [src]}));
    assert_eq!((a.changed, a.retired), (0, 1));
    assert_eq!(
        count(
            &c,
            "select count(*) from link where tx_to = 4611686018427387904"
        ),
        1
    );
    // it came back: the same entity again
    let a = put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    assert_eq!((a.changed, a.retired), (1, 0));
    assert_eq!(
        count(&c, "select count(*) from entity where retired_tx is null"),
        3
    );
    // the file is gone: everything it held retired, its links, its row
    let a = put(
        &mut c,
        &f.deny,
        json!({"gone": [{"kind": "file", "path": p}]}),
    );
    assert_eq!(a.retired, 3);
    assert_eq!(
        count(&c, "select count(*) from entity where retired_tx is null"),
        0
    );
    assert_eq!(
        count(
            &c,
            "select count(*) from link where tx_to = 4611686018427387904"
        ),
        0
    );
    assert_eq!(count(&c, "select count(*) from parsed_file"), 0);
}

#[test]
fn refuses_non_parsed_kinds() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    for (id, kind) in [
        ("grant:x".to_string(), "grant"),
        (format!("decision:{p}"), "decision"),
        ("task:abc-1x2y3".to_string(), "task"),
        ("task:J1#2".to_string(), "task"),
    ] {
        let a = put(
            &mut c,
            &f.deny,
            json!({"sources": [{"source": {"kind": "file", "path": p}, "entities": [{"id": id, "kind": kind}]}]}),
        );
        assert_eq!(a.refused.len(), 1, "{id}");
    }
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [{"source": {"kind": "commit"}, "entities": [{"id": "commit:/x/y", "kind": "commit"}]}]}),
    );
    assert_eq!(a.refused.len(), 1);
    assert_eq!(count(&c, "select count(*) from entity"), 0);
}

#[test]
fn updates_set_status_from_the_fixed_list() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    let task = format!("task:{p}#1");
    // folded into the request's own entity: made done at once, one version
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [plan_source(p)], "updates": [{"id": task, "status": "done", "data_patch": {"range-stale": true}}]}),
    );
    assert_eq!((a.changed, a.refused.len()), (3, 0));
    let t = entity::by_id(&c, &task).unwrap().unwrap();
    assert_eq!((t.status.as_deref(), t.ver), (Some("done"), 1));
    assert_eq!(t.data["range-stale"], json!(true));
    // the same derivation again writes nothing
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [plan_source(p)], "updates": [{"id": task, "status": "done", "data_patch": {"range-stale": true}}]}),
    );
    assert_eq!(a.changed, 0);
    // a later update on its own: a new version
    let a = put(
        &mut c,
        &f.deny,
        json!({"updates": [{"id": task, "data_patch": {"stale": true, "range-stale": null}}]}),
    );
    assert_eq!(a.changed, 1);
    let t = entity::by_id(&c, &task).unwrap().unwrap();
    assert_eq!(
        (t.data["stale"].clone(), t.data.get("range-stale")),
        (json!(true), None)
    );
    // a later update's status on its own: a new version with that status (URDR-MUT-RECORD-1, parsed.rs:734)
    let a = put(
        &mut c,
        &f.deny,
        json!({"updates": [{"id": task, "status": "open"}]}),
    );
    assert_eq!((a.changed, a.refused.len()), (1, 0), "{a:?}");
    let t = entity::by_id(&c, &task).unwrap().unwrap();
    assert_eq!(t.status.as_deref(), Some("open"));
    // a status off the list, or on a kind that takes none
    for (id, status) in [
        (task.clone(), "blocked"),
        (format!("plan:{p}"), "in-review"),
    ] {
        let a = put(
            &mut c,
            &f.deny,
            json!({"updates": [{"id": id, "status": status}]}),
        );
        assert_eq!(a.refused.len(), 1, "{status}");
    }
}

#[test]
fn updates_refuse_other_fields() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    let task = format!("task:{p}#1");
    put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    for patch in [
        json!({"title": "x"}),
        json!({"path": "/elsewhere"}),
        json!({"gone": "yes"}),
    ] {
        let a = put(
            &mut c,
            &f.deny,
            json!({"updates": [{"id": task, "data_patch": patch}]}),
        );
        assert_eq!(a.refused.len(), 1, "{patch}");
    }
    // a path into ~/org through an update
    let a = put(
        &mut c,
        &f.deny,
        json!({"updates": [{"id": format!("plan:{p}"), "data_patch": {"worktree": f.home.join("org").display().to_string()}}]}),
    );
    assert_eq!(refused_why(&a), [DENIED]);
    // an entity no scan made: a tracker task, and a parsed-looking id recorded by someone else
    {
        let mut tx = Tx::for_test(&mut c, TxMeta::new("user", Class::User, "test"), guard());
        for id in ["task:abc-1x2y3".to_string(), format!("task:{p}#9")] {
            entity::create(
                &mut tx,
                EntityNew {
                    id,
                    kind: "task".into(),
                    project: None,
                    title: Some("mine".into()),
                    status: Some("open".into()),
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )
            .unwrap();
        }
        tx.commit_for_test().unwrap();
    }
    for id in ["task:abc-1x2y3".to_string(), format!("task:{p}#9")] {
        let a = put(
            &mut c,
            &f.deny,
            json!({"updates": [{"id": id, "status": "done"}]}),
        );
        assert_eq!(a.refused.len(), 1, "{id}");
        assert!(a.refused[0].why.contains("not a parsed entity"), "{a:?}");
    }
    assert_eq!(
        count(&c, "select count(*) from entity where status = 'done'"),
        0
    );
}

#[tokio::test]
async fn record_with_collected_is_idempotent() {
    let f = fx();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("work.db");
    let db = CoordDb::spawn(&path);
    let w = db.graph_writer().unwrap().clone();
    let deny = Arc::new(f.deny);
    let p = f.plan.clone();
    let req: PutParsed =
        serde_json::from_value(json!({"sources": [plan_source(&p)], "collected": ["job j3"]}))
            .unwrap();
    let d = deny.clone();
    w.write(scan(), move |tx| parsed::put(tx, &d, req))
        .await
        .unwrap();
    let repo = Path::new(&p).parent().unwrap().display().to_string();
    let record = |key: &str| -> (TxMeta, Record) {
        let mut meta = TxMeta::new("backend", Class::System, "proto:graph/record");
        meta.req = Some(key.into());
        let req: Record = serde_json::from_value(json!({
            "task": format!("task:{p}#1"), "repo": repo, "collected": key,
            "commits": [{"sha": "aaaa1111", "date": 2.0, "subject": "two", "seq": -1},
                        {"sha": "bbbb2222", "date": 1.0, "subject": "one", "seq": -2}]
        }))
        .unwrap();
        (meta, req)
    };
    let mut answers = Vec::new();
    for _ in 0..2 {
        let (meta, req) = record("job j1");
        let d = deny.clone();
        answers.push(
            w.write(meta, move |tx| {
                parsed::record(tx, &d, &mut ProjectCache::default(), req)
            })
            .await
            .unwrap(),
        );
    }
    assert_eq!(answers[0].value.ids, ["commit:aaaa1111", "commit:bbbb2222"]);
    assert!(!answers[0].replayed);
    assert!(answers[1].replayed);
    assert_eq!(answers[1].value, answers[0].value);
    // a key the collector kept before (here through a put) writes nothing
    let (meta, req) = record("job j3");
    let d = deny.clone();
    let third = w
        .write(meta, move |tx| {
            parsed::record(tx, &d, &mut ProjectCache::default(), req)
        })
        .await
        .unwrap();
    assert!(third.value.ids.is_empty());
    let c = Connection::open(&path).unwrap();
    assert_eq!(
        count(&c, "select count(*) from entity where kind = 'commit'"),
        2
    );
    assert_eq!(
        count(
            &c,
            "select count(*) from link where kind = 'implements' and origin = 'recorded' and source = 'recorded'"
        ),
        2
    );
    assert_eq!(count(&c, "select count(*) from tx where req = 'job j1'"), 1);
    assert_eq!(
        count(
            &c,
            "select count(*) from kv where key in ('job j1', 'job j3') and value = 'collected'"
        ),
        2
    );
    // the Lisp collector's check reads the same key through the `meta` view
    assert_eq!(
        count(&c, "select count(*) from meta where key = 'job j1'"),
        1
    );
}

#[test]
fn orphan_commits_and_unnamed_specs_are_retired() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    let dir = Path::new(p).parent().unwrap().display().to_string();
    let spec = format!("{dir}/s.md");
    let ledger = format!("{dir}/p.ledger.md");
    let task = format!("task:{p}#1");
    let mut plan = plan_source(p);
    plan["links"] =
        json!([{"src": format!("plan:{p}"), "kind": "derives", "dst": format!("spec:{spec}")}]);
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [
            plan,
            {"source": {"kind": "spec", "path": spec}, "entities": [{"id": format!("spec:{spec}"), "kind": "spec", "data": {"path": spec}}]},
            {"source": {"kind": "commit"}, "entities": [{"id": "commit:aaaa1111", "kind": "commit", "data": {"sha": "aaaa1111", "repo": dir}}]},
            {"source": {"kind": "file", "path": ledger},
             "entities": [{"id": format!("file:{ledger}"), "kind": "file", "data": {"path": ledger}}],
             "links": [{"src": format!("file:{ledger}"), "kind": "ledger-of", "dst": format!("plan:{p}")},
                       {"src": "commit:aaaa1111", "kind": "implements", "dst": task, "origin": "inferred"}]}
        ]}),
    );
    assert_eq!((a.changed, a.refused.len()), (6, 0), "{a:?}");
    assert_eq!(
        count(
            &c,
            "select count(*) from link where kind = 'relates' and json_extract(data, '$.was') = 'ledger-of'"
        ),
        1
    );
    assert_eq!(
        count(
            &c,
            "select count(*) from link where kind = 'implements' and origin = 'inferred'"
        ),
        1
    );
    // the ledger forgets the commit, the plan forgets its spec: both go at the end of the next put
    let a = put(
        &mut c,
        &f.deny,
        json!({"sources": [
            plan_source(p),
            {"source": {"kind": "file", "path": ledger},
             "entities": [{"id": format!("file:{ledger}"), "kind": "file", "data": {"path": ledger}}],
             "links": [{"src": format!("file:{ledger}"), "kind": "ledger-of", "dst": format!("plan:{p}")}]}
        ]}),
    );
    assert_eq!(a.retired, 2, "{a:?}");
    for id in ["commit:aaaa1111".to_string(), format!("spec:{spec}")] {
        assert!(
            entity::by_id(&c, &id)
                .unwrap()
                .unwrap()
                .retired_tx
                .is_some(),
            "{id}"
        );
    }
}

/// DIR as a project of its own (a made-up root commit, no git): the cache `put_with` and `record` are given.
fn projects_for(dir: &Path) -> ProjectCache {
    let sha = "0123456789abcdef0123456789abcdef01234567".to_string();
    let mut cache = ProjectCache::default();
    cache.insert(
        dir.to_path_buf(),
        Some(ProjectRef {
            id: format!("project:{}", &sha[28..]),
            root: dir.to_path_buf(),
            slug: "plans".into(),
            root_commit: Some(sha.clone()),
            roots: vec![sha],
        }),
    );
    cache
}

/// One `graph/record` of commit aaaa1111 with SUBJECT and DATE on task 1 of plan P, its repository P's folder.
fn record_once(
    c: &mut Connection,
    deny: &DenyList,
    projects: &mut ProjectCache,
    p: &str,
    subject: &str,
    date: f64,
) -> Vec<String> {
    let req: Record = serde_json::from_value(json!({
        "task": format!("task:{p}#1"),
        "repo": Path::new(p).parent().unwrap().display().to_string(),
        "commits": [{"sha": "aaaa1111", "date": date, "subject": subject, "seq": -1}]
    }))
    .unwrap();
    let mut tx = Tx::for_test(
        c,
        TxMeta::new("backend", Class::System, "proto:graph/record"),
        guard(),
    );
    let a = parsed::record(&mut tx, deny, projects, req).unwrap();
    tx.commit_for_test().unwrap();
    a.ids
}

/// An entity the scan sends again takes what it is now: its project (resolved meanwhile), status and data, beside
/// its title (Task 19's report-shape mutants of `apply_want`).
#[test]
fn a_re_put_brings_project_status_and_data_up_to_date() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    let dir = Path::new(p).parent().unwrap();
    let task = format!("task:{p}#1");
    put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    let t = entity::by_id(&c, &task).unwrap().unwrap();
    assert_eq!(
        (t.project, t.status.as_deref(), t.data["line"].clone()),
        (None, Some("open"), json!(2))
    );
    let mut src = plan_source(p);
    src["entities"][1]["status"] = json!("done");
    src["entities"][1]["data"]["line"] = json!(4);
    let req: PutParsed = serde_json::from_value(json!({"sources": [src]})).unwrap();
    let mut projects = projects_for(dir);
    let mut tx = Tx::for_test(&mut c, scan(), guard());
    let a = parsed::put_with(&mut tx, &f.deny, &mut projects, req).unwrap();
    tx.commit_for_test().unwrap();
    // all three take the project; the task its status and line too
    assert_eq!((a.changed, a.retired, a.refused.len()), (3, 0, 0), "{a:?}");
    let n = projects.project_n(dir).expect("registered");
    let t = entity::by_id(&c, &task).unwrap().unwrap();
    assert_eq!(
        (
            t.project,
            t.status.as_deref(),
            t.data["line"].clone(),
            t.title.as_deref(),
            t.ver
        ),
        (Some(n), Some("done"), json!(4), Some("one"), 2)
    );
    let plan = entity::by_id(&c, &format!("plan:{p}")).unwrap().unwrap();
    assert_eq!(
        (plan.project, plan.status.as_deref()),
        (Some(n), Some("open"))
    );
}

/// A commit recorded again takes its project (resolved meanwhile), its subject and its data as they are now (Task
/// 19's report-shape mutants of `record`).
#[test]
fn a_recorded_commit_again_takes_its_project_subject_and_data() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    let dir = Path::new(p).parent().unwrap();
    put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    let ids = record_once(
        &mut c,
        &f.deny,
        &mut ProjectCache::default(),
        p,
        "first",
        1.0,
    );
    assert_eq!(ids, ["commit:aaaa1111"]);
    let first = entity::by_id(&c, "commit:aaaa1111").unwrap().unwrap();
    assert_eq!(
        (
            first.project,
            first.title.as_deref(),
            first.data["date"].clone()
        ),
        (None, Some("first"), json!(1.0))
    );
    let mut projects = projects_for(dir);
    let ids = record_once(&mut c, &f.deny, &mut projects, p, "first, amended", 2.0);
    assert_eq!(ids, ["commit:aaaa1111"]);
    let n = projects.project_n(dir).expect("registered");
    let again = entity::by_id(&c, "commit:aaaa1111").unwrap().unwrap();
    assert_eq!(
        (
            again.project,
            again.title.as_deref(),
            again.data["date"].clone(),
            again.ver
        ),
        (Some(n), Some("first, amended"), json!(2.0), 2)
    );
}

/// The refusal of one `graph/record` of commit aaaa1111 on TASK in REPO (the tx is dropped, never committed).
fn record_refusal(c: &mut Connection, deny: &DenyList, task: &str, repo: &str) -> String {
    let req: Record = serde_json::from_value(json!({
        "task": task, "repo": repo,
        "commits": [{"sha": "aaaa1111", "date": 1.0, "subject": "s", "seq": -1}]
    }))
    .unwrap();
    let mut tx = Tx::for_test(
        c,
        TxMeta::new("backend", Class::System, "proto:graph/record"),
        guard(),
    );
    match parsed::record(&mut tx, deny, &mut ProjectCache::default(), req) {
        Err(urdr::graph::WriteError::Refused(why)) => why,
        other => panic!("{task} in {repo}: not refused: {other:?}"),
    }
}

/// Door 1 of `graph/record`: a repository in `~/org` is refused with an allowed task, and a task whose id names the
/// notes with an allowed repository; either alone is enough (URDR-MUT-RECORD-1, parsed.rs's `||`).
#[test]
fn record_refuses_a_denied_repo_or_a_denied_task_alone() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    let org_repo = f.home.join("org/proj");
    std::fs::create_dir_all(&org_repo).unwrap();
    let task = format!("task:{p}#1");
    let repo = Path::new(p).parent().unwrap().display().to_string();
    let notes_task = format!("task:{}#1", f.notes());
    assert_eq!(
        record_refusal(&mut c, &f.deny, &task, &org_repo.display().to_string()),
        DENIED
    );
    assert_eq!(record_refusal(&mut c, &f.deny, &notes_task, &repo), DENIED);
    assert_eq!(
        count(&c, "select count(*) from entity where kind = 'commit'"),
        0
    );
    nothing_of_the_notes(&c, &f);
}

/// A commit is recorded only on a live task, step or todo: a retired task and a live entity of another kind are
/// "no task" (URDR-MUT-RECORD-1, parsed.rs's `&&` of the task filter).
#[test]
fn record_needs_a_live_task_of_a_task_kind() {
    let f = fx();
    let mut c = db();
    let p = &f.plan;
    put(&mut c, &f.deny, json!({"sources": [plan_source(p)]}));
    let repo = Path::new(p).parent().unwrap().display().to_string();
    let plan = format!("plan:{p}");
    assert_eq!(
        record_refusal(&mut c, &f.deny, &plan, &repo),
        format!("no task {plan}")
    );
    let task = format!("task:{p}#1");
    let n = entity::by_id(&c, &task).unwrap().unwrap().n;
    let mut tx = Tx::for_test(&mut c, scan(), guard());
    entity::retire(&mut tx, n).unwrap();
    tx.commit_for_test().unwrap();
    assert_eq!(
        record_refusal(&mut c, &f.deny, &task, &repo),
        format!("no task {task}")
    );
    // the step is still live: a commit on it is recorded
    let step = format!("step:{p}#1.1");
    let req: Record = serde_json::from_value(json!({
        "task": step, "repo": repo,
        "commits": [{"sha": "aaaa1111", "date": 1.0, "subject": "s", "seq": -1}]
    }))
    .unwrap();
    let mut tx = Tx::for_test(
        &mut c,
        TxMeta::new("backend", Class::System, "proto:graph/record"),
        guard(),
    );
    let a = parsed::record(&mut tx, &f.deny, &mut ProjectCache::default(), req).unwrap();
    assert_eq!(a.ids, ["commit:aaaa1111"]);
}
