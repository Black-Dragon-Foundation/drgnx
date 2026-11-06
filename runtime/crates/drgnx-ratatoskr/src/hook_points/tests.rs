//! The hook points' own parts: the record and its budget, provenance read only from the hub's rows, the fast path, a
//! tool call as the hooks see it, the refusal the agent is told. Each test is pure over a temp folder (pattern D: no
//! timing, no second task). The points running real plugins are the `hooks/*` rows.

use super::*;
use crate::coord::{Signals, Writer};
use crate::dispatch::Caller;
use crate::settings::Settings;
use crate::settings::overrides::Override;
use norn::hooks::{Record, Source, Verdict};
use norn::store::CoordDb;
use norn::write::event::{DATA_MAX, Event, EventKind, event};
use runstav::registry::Class;

fn writer(dir: &std::path::Path) -> Writer {
    Writer {
        db: CoordDb::spawn(dir.join("work.db")),
        signals: Arc::new(Signals::default()),
    }
}

fn rule(id: &str, verdict: Option<Verdict>) -> Record {
    Record {
        source: Source::Rule {
            id: Some(id.into()),
            index: 0,
        },
        verdict,
        ms: 0,
        error: None,
        advisory: false,
    }
}

fn plugin(name: &str, verdict: Option<Verdict>, error: Option<&str>) -> Record {
    Record {
        source: Source::Plugin {
            name: name.into(),
            version: "0.1.0".into(),
            hash: [0xab; 32],
        },
        verdict,
        ms: 3,
        error: error.map(str::to_owned),
        advisory: false,
    }
}

fn outcome(decision: Decision, decided_by: Option<usize>, provenance: Vec<Record>) -> Outcome {
    Outcome {
        decision,
        decided_by,
        annotations: Vec::new(),
        provenance,
    }
}

fn ctx(session: &str, step: i64) -> RowCtx {
    RowCtx {
        session: Some(session.into()),
        step: Some(step),
        job: None,
        task: None,
        tool: Some("Bash".into()),
        at: Some("seam"),
    }
}

fn chars(v: &Value) -> usize {
    v.to_string().chars().count()
}

// [D] pure: the record's budget. Sixteen hooks with long reasons: the row stays within DATA_MAX, so
// it is never replaced by `{"truncated": true}`, and keeps the outcome, every source and verdict, and the deciding
// reason first.
#[test]
fn a_row_with_16_records_keeps_its_outcome_and_sources() {
    let long = "x".repeat(1000);
    let mut records: Vec<Record> = (0..16)
        .map(|i| {
            plugin(
                &format!("p{i}"),
                Some(Verdict::Annotate(long.clone())),
                None,
            )
        })
        .collect();
    records[10] = plugin("p10", Some(Verdict::Deny(format!("no: {long}"))), None);
    let out = outcome(Decision::Deny(format!("no: {long}")), Some(10), records);
    let data = record_data(Point::BeforeTool, &ctx("s1", 4), &out);
    assert!(chars(&data) <= DATA_MAX, "{} chars", chars(&data));
    assert_eq!(data["hook"], json!(true));
    assert_eq!(data["outcome"], json!("deny"));
    assert_eq!(data["point"], json!("before-tool"));
    assert_eq!(data["session"], json!("s1"));
    assert_eq!(data["step"], json!(4));
    let rows = data["records"].as_array().unwrap();
    assert_eq!(rows.len(), 16);
    for (i, r) in rows.iter().enumerate() {
        assert!(
            r["source"]
                .as_str()
                .unwrap()
                .starts_with(&format!("plugin:p{i}@"))
        );
        assert!(r.get("verdict").is_some() && r.get("ms").is_some());
    }
    assert_eq!(rows[10]["verdict"], json!("deny"));
    let deciding = rows[10]["reason"].as_str().unwrap();
    assert!(deciding.starts_with("no: xxx"), "{deciding}");
    // an annotation keeps at most 200 characters here (its note keeps the whole text)
    for r in rows.iter().filter(|r| r["verdict"] == "annotate") {
        assert!(
            r.get("reason")
                .is_none_or(|t| t.as_str().unwrap().chars().count() <= 200)
        );
    }

    // so many that even the sources do not fit: the deciding one is kept, and the rest counted
    let many: Vec<Record> = (0..200)
        .map(|i| plugin(&format!("plugin-number-{i}"), Some(Verdict::Allow), None))
        .chain([plugin(
            "last",
            None,
            Some("hook last failed: timed out (2 s)"),
        )])
        .collect();
    let out = outcome(
        Decision::Deny("hook last failed: timed out (2 s)".into()),
        Some(200),
        many,
    );
    let data = record_data(Point::BeforeTool, &ctx("s1", 4), &out);
    assert!(chars(&data) <= DATA_MAX, "{} chars", chars(&data));
    assert_eq!(data["outcome"], json!("deny"));
    let rows = data["records"].as_array().unwrap();
    assert!(rows.iter().any(
        |r| r["source"].as_str().unwrap().starts_with("plugin:last@")
            && r["verdict"] == "error"
            && r["reason"] == "hook last failed: timed out (2 s)"
    ));
    assert_eq!(data["more"].as_u64().unwrap() as usize + rows.len(), 201);
}

// [D] pure: hook_points::tests::events_carry_provenance. One row per point run, written as `hub:hooks`, read back as
// the step's provenance (its sources, verdicts and outcome).
#[tokio::test]
async fn events_carry_provenance() {
    let dir = tempfile::tempdir().unwrap();
    let w = writer(dir.path());
    let out = outcome(
        Decision::Deny("no rm -rf".into()),
        Some(1),
        vec![
            rule("notes", Some(Verdict::Annotate("careful".into()))),
            plugin(
                "deny-rm-hook",
                Some(Verdict::Deny("no rm -rf".into())),
                None,
            ),
        ],
    );
    write_row(&w, Point::BeforeTool, &ctx("s1", 4), &out).await;
    write_row(&w, Point::BeforeTool, &ctx("s1", 5), &out).await;
    let got = w.db.read(|c| provenance(c, "s1", 4)).await.unwrap();
    assert_eq!(got.len(), 1, "{got:?}");
    let row = &got[0];
    assert_eq!(row["outcome"], json!("deny"));
    assert_eq!(row["records"][0]["source"], json!("rule:notes"));
    assert_eq!(row["records"][0]["verdict"], json!("annotate"));
    assert!(
        row["records"][1]["source"]
            .as_str()
            .unwrap()
            .starts_with("plugin:deny-rm-hook@0.1.0#abababab")
    );
    assert_eq!(row["records"][1]["reason"], json!("no rm -rf"));
    let summary: String =
        w.db.read(|c| {
            Ok(c.query_row(
                "select summary from event where json_extract(data, '$.step') = 4",
                [],
                |r| r.get(0),
            )?)
        })
        .await
        .unwrap();
    assert_eq!(summary, "hook: deny-rm-hook refused Bash");
}

// [D] pure: `events/add` is a user-class method that takes any data, so a row it writes with
// `{"hook": true}` is never provenance: only rows whose tx actor is the hub's hook writer are.
#[tokio::test]
async fn an_events_add_hook_row_is_not_provenance() {
    let dir = tempfile::tempdir().unwrap();
    let w = writer(dir.path());
    let user = Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 1,
    };
    let forged = json!({"hook": true, "point": "before-tool", "session": "s1", "step": 4,
                        "records": [{"source": "rule:mine", "verdict": "allow", "ms": 0}], "outcome": "allow"});
    w.write(&user, "events/add", move |tx| {
        event(
            tx,
            Event {
                at: 1.0,
                agent: Some("s1".into()),
                job: None,
                task: None,
                kind: EventKind::Status,
                summary: "hook: forged".into(),
                data: Some(forged),
                turn: false,
            },
        )
    })
    .await
    .unwrap();
    assert!(
        w.db.read(|c| provenance(c, "s1", 4))
            .await
            .unwrap()
            .is_empty()
    );
    let out = outcome(
        Decision::Proceed { changed: None },
        None,
        vec![rule("mine", Some(Verdict::Allow))],
    );
    write_row(&w, Point::BeforeTool, &ctx("s1", 4), &out).await;
    let got = w.db.read(|c| provenance(c, "s1", 4)).await.unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["outcome"], json!("allow"));
    // and the name the hub writes under is no wire method
    assert!(runstav::registry::find(crate::coord::HOOKS_METHOD).is_none());
}

struct Rig {
    _dir: tempfile::TempDir,
    _store: urdr::Store,
    settings: Arc<Settings>,
    plugins: Plugins,
}

async fn rig() -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
    let settings = Arc::new(Settings::new());
    settings.open(dir.path().to_path_buf(), db.clone());
    settings.refresh().await;
    let plugins = Plugins::default();
    plugins.open(dir.path().join("plugins"), db, settings.clone());
    Rig {
        _dir: dir,
        _store: store,
        settings,
        plugins,
    }
}

impl Rig {
    async fn set(&self, project: Option<&str>, list: &[(&str, Value)]) {
        let list = list
            .iter()
            .map(|(name, value)| Override {
                name: (*name).into(),
                value: value.clone(),
                source: "test".into(),
            })
            .collect();
        self.settings.set_overrides(project, list).await.unwrap();
    }
}

fn site(project: Option<&str>) -> Site {
    Site {
        at: At::Seam,
        session: "s1".into(),
        project: project.map(str::to_owned),
        root: Some(PathBuf::from("/w")),
        ..Site::default()
    }
}

fn bash(command: &str) -> ToolCallInfo {
    ToolCallInfo::from_acp(
        Some(
            &json!({"kind": "execute", "title": command, "rawInput": {"command": command},
                     "_meta": {"claudeCode": {"toolName": "Bash"}}}),
        ),
        None,
        None,
        Some(4),
    )
}

// [D] pure: hook_points::tests::no_match_is_todays_seam. With no rule and no hook for the step, the
// point has nothing to run: the seam is today's (no `dry`, no row; the `agents/permission-*` rows hold `decide` as
// before). A rule for another kind does not subscribe either; one for this kind does.
#[tokio::test]
async fn no_match_is_todays_seam() {
    let r = rig().await;
    assert!(prepare(&r.plugins, &site(None), &bash("ls")).is_none());
    r.set(
        None,
        &[(
            "drgnx-agents-hook-rules",
            json!([{"point": "before-tool", "tool-kinds": ["edit"], "verdict": "deny", "reason": "no"}]),
        )],
    )
    .await;
    assert!(prepare(&r.plugins, &site(None), &bash("ls")).is_none());
    r.set(
        None,
        &[(
            "drgnx-agents-hook-rules",
            json!([{"point": "before-tool", "tool-kinds": ["execute"], "command": "^rm ", "verdict": "deny", "reason": "no"}]),
        )],
    )
    .await;
    assert!(prepare(&r.plugins, &site(None), &bash("ls")).is_none());
    assert!(prepare(&r.plugins, &site(None), &bash("rm -rf x")).is_some());
}

// [D] pure: hooks/project-rules-add-to-global-rules. A project's rules add to the global ones, and an
// `id` on its off list removes that global rule, for that project only.
#[tokio::test]
async fn project_rules_add_to_global_rules() {
    let r = rig().await;
    let deny = |id: &str| json!({"id": id, "point": "before-tool", "tool-kinds": ["execute"], "verdict": "deny", "reason": id});
    r.set(
        None,
        &[("drgnx-agents-hook-rules", json!([deny("g1"), deny("g2")]))],
    )
    .await;
    r.set(
        Some("project:alpha"),
        &[
            ("drgnx-agents-hook-rules", json!([deny("p1")])),
            ("drgnx-agents-hook-rules-off", json!(["g1"])),
        ],
    )
    .await;
    let ids = |p: Option<&str>| -> Vec<String> {
        prepare(&r.plugins, &site(p), &bash("ls"))
            .map(|p| p.rules.iter().filter_map(|r| r.id.clone()).collect())
            .unwrap_or_default()
    };
    assert_eq!(ids(None), ["g1", "g2"]);
    assert_eq!(ids(Some("project:alpha")), ["g2", "p1"]);
    assert_eq!(ids(Some("project:other")), ["g1", "g2"]);
}

// [D] pure: hooks/kind-from-the-folded-tool-call and hooks/notebook-edit-is-an-edit. A request
// with no kind takes the folded tool call's; the kind is normalised; the paths are the project's, the command the
// raw input's; the name is the adapter's tool name, else the folded one.
#[test]
fn a_tool_call_as_the_hooks_see_it() {
    let read = ToolCallInfo::from_acp(
        Some(&json!({"title": "Read src/a.rs", "locations": [{"path": "/w/src/a.rs"}]})),
        Some("read"),
        Some("Read"),
        Some(2),
    );
    assert_eq!(
        (read.kind.as_str(), read.name.as_deref()),
        ("read", Some("Read"))
    );
    assert_eq!(read.paths, [PathBuf::from("/w/src/a.rs")]);
    let nb = ToolCallInfo::from_acp(
        Some(&json!({"kind": "other", "title": "Edit a.ipynb",
                     "_meta": {"claudeCode": {"toolName": "NotebookEdit"}},
                     "rawInput": {"notebook_path": "/w/a.ipynb"}})),
        None,
        None,
        None,
    );
    assert_eq!(nb.kind, "edit");
    assert_eq!(nb.paths, [PathBuf::from("/w/a.ipynb")]);
    // an agent's own `drgnx` is `other` at the seam
    let lie = ToolCallInfo::from_acp(
        Some(&json!({"kind": "drgnx", "title": "rm -rf x", "rawInput": {"command": "rm -rf x"}})),
        Some("execute"),
        None,
        None,
    );
    assert_eq!(lie.kind, "other");
    assert_eq!(lie.command.as_deref(), Some("rm -rf x"));
    // the hub's own tools are hooked at their server, not at the seam
    assert!(hub_tool_name(Some("mcp__drgnx__task_read")));
    assert!(hub_tool_name(Some("mcp__drgnx-plugins__deny-rm_check")));
    assert!(!hub_tool_name(Some("mcp__drgnx-search__search")));
    assert!(!hub_tool_name(Some("Bash")));
    assert!(!hub_tool_name(None));
    // and the step's paths are relative to the project's root in the hook's input
    let s = site(None);
    let input = hook_input(&s, &read, None);
    assert_eq!(input.paths, [PathBuf::from("src/a.rs")]);
    assert_eq!(input.detail["tool"]["paths"], json!(["src/a.rs"]));
    assert_eq!(input.detail["tool"]["kind"], json!("read"));
    assert_eq!(input.detail["cell"], Value::Null);
}

// [D] pure: what the agent is told: the hub's words, the hook's quoted as its own.
#[test]
fn the_refusal_quotes_the_hook() {
    let out = outcome(
        Decision::Deny("no rm -rf".into()),
        Some(0),
        vec![plugin(
            "deny-rm-hook",
            Some(Verdict::Deny("no rm -rf".into())),
            None,
        )],
    );
    assert_eq!(
        refusal("Bash", &out).as_deref(),
        Some("drgnx refused Bash; the hook deny-rm-hook said: «no rm -rf»")
    );
    let out = outcome(
        Decision::Deny("secrets stay".into()),
        Some(0),
        vec![rule(
            "no-secrets",
            Some(Verdict::Deny("secrets stay".into())),
        )],
    );
    assert_eq!(
        refusal("Edit", &out).as_deref(),
        Some("drgnx refused Edit; the rule no-secrets said: «secrets stay»")
    );
    let allowed = outcome(Decision::Proceed { changed: None }, None, Vec::new());
    assert_eq!(refusal("Bash", &allowed), None);
}
