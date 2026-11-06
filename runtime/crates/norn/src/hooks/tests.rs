//! Pattern D (pure): `combine`, the matchers and the rule parser are functions of their arguments. `run` calls a
//! scripted host on paused tokio time, whose hooks take time only by `tokio::time::advance`: no real clock, no
//! thread, no plugin.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use brokkr::Installed;
use serde_json::{Value, json};

use super::*;
use crate::matrix::{Cell, Verdict as M};

const HASH: [u8; 32] = [0xab; 32];

fn cell(v: M) -> Option<Cell> {
    Some(Cell {
        verdict: v,
        limit: None,
    })
}

/// An installed plugin NAME with the one hook HOOK.
fn plugin(name: &str, hook: Value) -> Arc<Installed> {
    let m = json!({"name": name, "version": "0.1.0", "hooks": [hook]});
    Arc::new(Installed {
        dir: PathBuf::new(),
        manifest: brokkr::parse(&serde_json::to_vec(&m).unwrap()).unwrap(),
        hash: HASH,
    })
}

fn before_tool(kind: &str, tool: &str, paths: &[&str], command: Option<&str>) -> HookInput {
    HookInput {
        point: Point::BeforeTool,
        session: Some("s-1".into()),
        step: Some(41),
        tool_kind: Some(kind.into()),
        tool: Some(tool.into()),
        paths: paths.iter().map(PathBuf::from).collect(),
        command: command.map(String::from),
        detail: json!({"tool": {"kind": kind, "name": tool, "input": {}}}),
    }
}

fn rec(name: &str, verdict: Option<Verdict>, error: Option<&str>, advisory: bool) -> Record {
    Record {
        source: Source::Plugin {
            name: name.into(),
            version: "0.1.0".into(),
            hash: HASH,
        },
        verdict,
        ms: 0,
        error: error.map(String::from),
        advisory,
    }
}

/// A hook's script: how long it takes (ms) and what it answers, from the input it was given.
type Script = Box<dyn Fn(&Value) -> (u64, Result<Verdict, String>) + Send + Sync>;

/// The host of these tests: each plugin's hook is a script; a hook past its deadline times out there, as the
/// plugin host's do.
#[derive(Default)]
struct Scripted {
    scripts: HashMap<String, Script>,
    calls: Mutex<Vec<(String, Value, Duration)>>,
}

impl Scripted {
    fn with(
        mut self,
        name: &str,
        f: impl Fn(&Value) -> (u64, Result<Verdict, String>) + Send + Sync + 'static,
    ) -> Self {
        self.scripts.insert(name.into(), Box::new(f));
        self
    }

    /// Every call: the plugin, the input it got, the deadline it was handed.
    fn calls(&self) -> Vec<(String, Value, Duration)> {
        self.calls.lock().unwrap().clone()
    }
}

impl HookHost for Scripted {
    type Plugin = Installed;

    fn run_hook(
        &self,
        plugin: &Installed,
        _point: Point,
        input: Value,
        deadline: Duration,
    ) -> impl Future<Output = Result<Verdict, String>> + Send {
        let name = plugin.manifest.name.as_str().to_string();
        let (ms, result) = self.scripts[&name](&input);
        self.calls.lock().unwrap().push((name, input, deadline));
        async move {
            let work = Duration::from_millis(ms);
            if work > deadline {
                tokio::time::advance(deadline).await;
                return Err(format!("timed out ({} ms)", deadline.as_millis()));
            }
            tokio::time::advance(work).await;
            result
        }
    }
}

fn budget(point: Point) -> Duration {
    Duration::from_millis(u64::from(point.budget_ms()))
}

/// Every cell, both point contexts and every list of up to three records of every kind (3 200 cases): no list
/// turns Ask or Never into a go-ahead, and every deny or non-advisory failure denies.
#[test]
fn allow_never_widens() {
    const KINDS: usize = 7;
    let record = |k: usize| match k {
        0 => rec("p", Some(Verdict::Allow), None, false),
        1 => rec("p", Some(Verdict::Deny("no".into())), None, false),
        2 => rec(
            "p",
            Some(Verdict::Change(json!({"arguments": {}}))),
            None,
            false,
        ),
        3 => rec("p", Some(Verdict::Annotate("note".into())), None, true),
        4 => rec("p", None, Some("hook p failed: trap: x"), true),
        5 => rec("p", None, Some("hook p failed: trap: x"), false),
        _ => rec("p", None, None, false),
    };
    let mut lists: Vec<Vec<usize>> = vec![vec![]];
    for len in 1..=3u32 {
        for n in 0..KINDS.pow(len) {
            lists.push(
                (0..len)
                    .map(|i| n / KINDS.pow(i) % KINDS)
                    .collect::<Vec<_>>(),
            );
        }
    }
    let mut cases = 0;
    for c in [None, cell(M::Allow), cell(M::Ask), cell(M::Never)] {
        for accepts in [false, true] {
            for kinds in &lists {
                let records: Vec<Record> = kinds.iter().map(|&k| record(k)).collect();
                let out = combine(c, accepts, &records);
                let denies = kinds
                    .iter()
                    .any(|&k| k == 1 || k == 5 || (k == 2 && !accepts));
                let at = format!("cell {c:?}, accepts_change {accepts}, records {kinds:?}");
                match c.map(|c| c.verdict) {
                    Some(M::Never) => assert!(matches!(out.decision, Decision::Deny(_)), "{at}"),
                    Some(M::Ask) if !denies => {
                        assert!(matches!(out.decision, Decision::Ask { .. }), "{at}")
                    }
                    _ if denies => assert!(matches!(out.decision, Decision::Deny(_)), "{at}"),
                    _ => assert!(matches!(out.decision, Decision::Proceed { .. }), "{at}"),
                }
                assert_eq!(out.provenance, records, "{at}");
                cases += 1;
            }
        }
    }
    assert_eq!(cases, 3_200);
}

#[tokio::test(start_paused = true)]
async fn first_deny_wins_and_names_its_source() {
    let records = [
        Record {
            source: Source::Rule { id: None, index: 0 },
            ..rec("r", Some(Verdict::Allow), None, false)
        },
        rec("one", Some(Verdict::Deny("first".into())), None, false),
        rec("two", Some(Verdict::Deny("second".into())), None, false),
    ];
    let out = combine(cell(M::Ask), false, &records);
    assert_eq!(out.decision, Decision::Deny("first".into()));
    assert_eq!(out.decided_by, Some(1));
    assert_eq!(
        out.provenance[1].source.to_string(),
        "plugin:one@0.1.0#abababab"
    );
    assert_eq!(out.provenance[0].source.to_string(), "rule:0");

    // A deny stops the run: the next hook is recorded as not run, and never called.
    let deny = json!({"point": "before-tool", "verdicts": ["deny"]});
    let host = Scripted::default()
        .with("one", |_| (1, Ok(Verdict::Deny("first".into()))))
        .with("two", |_| (1, Ok(Verdict::Deny("second".into()))));
    let plugins = [plugin("one", deny.clone()), plugin("two", deny)];
    let input = before_tool("execute", "Bash", &[], Some("rm -rf x"));
    let records = run(&input, budget(Point::BeforeTool), &[], &plugins, &host).await;
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].verdict, Some(Verdict::Deny("first".into())));
    assert!(records[1].not_run(), "{:?}", records[1]);
    assert_eq!(records[1].source.name(), "two");
    assert_eq!(host.calls().len(), 1);
    let out = combine(cell(M::Allow), false, &records);
    assert_eq!(
        (out.decision, out.decided_by),
        (Decision::Deny("first".into()), Some(0))
    );
}

#[tokio::test(start_paused = true)]
async fn changes_chain_in_order() {
    let hook = json!({"point": "before-tool", "verdicts": ["change"],
                      "filter": {"tool_kinds": ["drgnx"], "tools": ["mcp__drgnx__merge"]}});
    let suffix = |s: &'static str| {
        move |input: &Value| {
            let branch = input["tool"]["input"]["branch"].as_str().unwrap();
            (
                1,
                Ok(Verdict::Change(
                    json!({"arguments": {"branch": format!("{branch}{s}")}}),
                )),
            )
        }
    };
    let host = Scripted::default()
        .with("one", suffix("-1"))
        .with("two", suffix("-2"));
    let plugins = [plugin("one", hook.clone()), plugin("two", hook)];
    let mut input = before_tool("drgnx", "mcp__drgnx__merge", &[], None);
    input.detail["tool"]["input"] = json!({"branch": "b"});
    let records = run(&input, budget(Point::BeforeTool), &[], &plugins, &host).await;

    let calls = host.calls();
    assert_eq!(calls[0].1["tool"]["input"]["branch"], "b");
    assert_eq!(calls[1].1["tool"]["input"]["branch"], "b-1");
    assert_eq!(
        calls[1].1["previous"],
        json!([{"source": "plugin:one@0.1.0#abababab", "verdict": "change"}])
    );
    assert_eq!(calls[0].1["v"], 1);
    assert_eq!(calls[0].1["point"], "before-tool");
    assert_eq!(calls[0].1["step"], 41);
    let out = combine(None, true, &records);
    assert_eq!(
        out.decision,
        Decision::Proceed {
            changed: Some(json!({"arguments": {"branch": "b-1-2"}}))
        }
    );
}

#[tokio::test(start_paused = true)]
async fn advisory_error_is_annotation() {
    let host = Scripted::default().with("notes", |_| (1, Err("trap: unreachable".into())));
    let plugins = [plugin(
        "notes",
        json!({"point": "after-edit", "verdicts": ["annotate"]}),
    )];
    let mut input = before_tool("edit", "Edit", &["src/a.rs"], None);
    input.point = Point::AfterEdit;
    let records = run(&input, budget(Point::AfterEdit), &[], &plugins, &host).await;
    assert_eq!(
        records[0].error.as_deref(),
        Some("hook notes failed: trap: unreachable")
    );
    assert!(records[0].advisory);
    let out = combine(cell(M::Allow), false, &records);
    assert_eq!(out.decision, Decision::Proceed { changed: None });
    assert_eq!(out.annotations, ["hook notes failed: trap: unreachable"]);
}

#[tokio::test(start_paused = true)]
async fn non_advisory_error_denies() {
    let host = Scripted::default().with("guard", |_| (1, Err("trap: unreachable".into())));
    let plugins = [plugin(
        "guard",
        json!({"point": "before-tool", "verdicts": ["deny"]}),
    )];
    let input = before_tool("execute", "Bash", &[], Some("ls"));
    let records = run(&input, budget(Point::BeforeTool), &[], &plugins, &host).await;
    assert!(!records[0].advisory);
    let out = combine(cell(M::Allow), false, &records);
    assert_eq!(
        out.decision,
        Decision::Deny("hook guard failed: trap: unreachable".into())
    );
    assert_eq!(out.decided_by, Some(0));
}

#[test]
fn rule_matches_by_glob_and_regex() {
    let rules = parse_rules(&json!([
        {"point": "before-tool", "tool_kinds": ["execute"], "command": "^rm\\s+-rf\\s+/",
         "verdict": "deny", "reason": "no rm -rf on absolute paths"},
        {"point": "after-edit", "paths": ["**/*.lock", "migrations/**"], "verdict": "annotate",
         "reason": "a lock file or a migration changed"}
    ]))
    .unwrap();
    let rm = &rules[0];
    assert!(rm.matches(&before_tool("execute", "Bash", &[], Some("rm -rf /tmp"))));
    assert!(!rm.matches(&before_tool("execute", "Bash", &[], Some("rm -rf build"))));
    assert!(!rm.matches(&before_tool("execute", "Bash", &[], None)));
    assert!(!rm.matches(&before_tool("read", "Read", &[], Some("rm -rf /tmp"))));
    let edit = |p: &str| {
        let mut i = before_tool("edit", "Edit", &[p], None);
        i.point = Point::AfterEdit;
        i
    };
    let lock = &rules[1];
    for p in [
        "Cargo.lock",
        "a/b/c.lock",
        "migrations/0001.sql",
        "migrations/x/y.sql",
    ] {
        assert!(lock.matches(&edit(p)), "{p}");
    }
    for p in ["src/lock.rs", "migrationsx/a.sql", "a.lockx"] {
        assert!(!lock.matches(&edit(p)), "{p}");
    }
    assert!(!lock.matches(&before_tool("edit", "Edit", &["Cargo.lock"], None)));

    assert!(glob_match("src/**/*.rs", "src/b.rs"));
    assert!(glob_match("src/**/*.rs", "src/a/b/c.rs"));
    assert!(!glob_match("src/*.rs", "src/a/b.rs"));
    assert!(glob_match("?.rs", "a.rs"));
    assert!(!glob_match("?.rs", "ab.rs"));
    assert!(glob_match("/etc/**", "/etc/passwd"));
    assert!(!glob_match("/etc/**", "etc/passwd"));
    assert!(glob_match("**", "any/thing/at/all"));
    // Iterative: a pattern that makes a backtracking matcher explode returns at once.
    let long = "a".repeat(4096);
    assert!(!glob_match("*a*a*a*a*a*a*a*a*a*a*a*a*b", &long));
    assert!(!glob_match("**/**/**/**/**/**/**/**/x", &"a/".repeat(500)));

    let refused = |v: Value| parse_rules(&v).expect_err("refused");
    let bad = refused(
        json!([{"point": "before-tool", "command": "(", "verdict": "deny", "reason": "r"}]),
    );
    assert_eq!(bad.path, "[0].command");
    let big = refused(
        json!([{"point": "before-tool", "command": "(?:a{1000}){1000}",
                              "verdict": "deny", "reason": "r"}]),
    );
    assert_eq!(big.path, "[0].command");
    let kind = refused(
        json!([{"point": "before-tool", "tool_kinds": ["shell"], "verdict": "deny", "reason": "r"}]),
    );
    assert_eq!(kind.path, "[0].tool_kinds[0]");
    let change = refused(json!([{"point": "before-tool", "verdict": "change", "reason": "r"}]));
    assert_eq!(change.path, "[0].verdict");
}

#[tokio::test(start_paused = true)]
async fn rules_run_before_plugins() {
    let mut rules = parse_rules(&json!([
        {"point": "before-tool", "tool_kinds": ["execute"], "verdict": "annotate", "reason": "a shell command"}
    ]))
    .unwrap();
    let host = Scripted::default().with("guard", |_| (1, Ok(Verdict::Allow)));
    let plugins = [plugin(
        "guard",
        json!({"point": "before-tool", "verdicts": ["deny"]}),
    )];
    let input = before_tool("execute", "Bash", &[], Some("ls"));
    let records = run(&input, budget(Point::BeforeTool), &rules, &plugins, &host).await;
    assert_eq!(records[0].source.to_string(), "rule:0");
    assert_eq!(
        records[0].verdict,
        Some(Verdict::Annotate("a shell command".into()))
    );
    assert_eq!(records[1].source.name(), "guard");
    assert_eq!(
        host.calls()[0].1["previous"],
        json!([{"source": "rule:0", "verdict": "annotate"}])
    );

    // A rule that denies stops the run before any plugin is called.
    rules.extend(
        parse_rules(&json!([
            {"id": "no-shell", "point": "before-tool", "verdict": "deny", "reason": "no shell"}
        ]))
        .unwrap(),
    );
    let host = Scripted::default().with("guard", |_| (1, Ok(Verdict::Allow)));
    let records = run(&input, budget(Point::BeforeTool), &rules, &plugins, &host).await;
    assert_eq!(records[1].source.to_string(), "rule:no-shell");
    assert!(records[2].not_run());
    assert!(host.calls().is_empty());
    let out = combine(cell(M::Allow), false, &records);
    assert_eq!(out.decision, Decision::Deny("no shell".into()));
    assert_eq!(out.annotations, ["a shell command"]);
}

#[tokio::test(start_paused = true)]
async fn filter_skips_unmatched_hooks() {
    let host = Scripted::default()
        .with("exec", |_| (1, Ok(Verdict::Allow)))
        .with("src", |_| (1, Ok(Verdict::Allow)))
        .with("all", |_| (1, Ok(Verdict::Allow)))
        .with("edits", |_| (1, Ok(Verdict::Allow)));
    let plugins = [
        plugin(
            "exec",
            json!({"point": "before-tool", "verdicts": ["deny"], "filter": {"tool_kinds": ["execute"]}}),
        ),
        plugin(
            "src",
            json!({"point": "before-tool", "verdicts": ["deny"], "filter": {"paths": ["src/**"]}}),
        ),
        plugin("all", json!({"point": "before-tool", "verdicts": ["deny"]})),
        plugin(
            "edits",
            json!({"point": "after-edit", "verdicts": ["deny"]}),
        ),
    ];
    let input = before_tool("execute", "Bash", &["docs/a.md"], Some("cat docs/a.md"));
    let records = run(&input, budget(Point::BeforeTool), &[], &plugins, &host).await;
    let called: Vec<String> = host.calls().into_iter().map(|c| c.0).collect();
    assert_eq!(called, ["exec", "all"]);
    let named: Vec<String> = records.iter().map(|r| r.source.name()).collect();
    assert_eq!(named, ["exec", "all"]);
    assert!(subscribed(&input, &[], &plugins));
    assert!(!subscribed(
        &before_tool("read", "Read", &["docs/a.md"], None),
        &[],
        &plugins[..2]
    ));
    assert!(subscribed(
        &before_tool("read", "Read", &["src/a.rs"], None),
        &[],
        &plugins[..2]
    ));
}

#[tokio::test(start_paused = true)]
async fn a_change_where_none_is_accepted_is_an_error() {
    let change = Some(Verdict::Change(json!({"arguments": {"a": 1}})));
    let out = combine(
        cell(M::Allow),
        false,
        &[rec("p", change.clone(), None, false)],
    );
    assert_eq!(
        out.decision,
        Decision::Deny("hook p failed: change is not accepted here".into())
    );
    let out = combine(cell(M::Allow), false, &[rec("p", change, None, true)]);
    assert_eq!(out.decision, Decision::Proceed { changed: None });
    assert_eq!(
        out.annotations,
        ["hook p failed: change is not accepted here"]
    );

    // A change of the wrong shape for its point, and a verdict the manifest did not declare, are errors.
    let host = Scripted::default()
        .with("msg", |_| (1, Ok(Verdict::Change(json!({"msg": "x"})))))
        .with("quiet", |_| {
            (1, Ok(Verdict::Change(json!({"message": "y"}))))
        });
    let commit = HookInput {
        point: Point::BeforeCommit,
        session: None,
        step: None,
        tool_kind: None,
        tool: None,
        paths: vec![],
        command: None,
        detail: json!({"commit": {"branch": "j7-3", "message": "x"}}),
    };
    let msg = [plugin(
        "msg",
        json!({"point": "before-commit", "verdicts": ["change"]}),
    )];
    let records = run(&commit, budget(Point::BeforeCommit), &[], &msg, &host).await;
    assert_eq!(
        records[0].error.as_deref(),
        Some("hook msg failed: change for before-commit must be {\"message\": string}")
    );
    let quiet = [plugin(
        "quiet",
        json!({"point": "before-commit", "verdicts": ["annotate", "deny"]}),
    )];
    let records = run(&commit, budget(Point::BeforeCommit), &[], &quiet, &host).await;
    assert_eq!(
        records[0].error.as_deref(),
        Some("hook quiet failed: it answered change, which its manifest does not declare")
    );
    assert!(matches!(
        combine(None, true, &records).decision,
        Decision::Deny(_)
    ));
}

#[test]
fn kind_is_normalised_to_the_acp_enum() {
    assert_eq!(acp_kind(Some("execute"), Some("Bash")), "execute");
    assert_eq!(acp_kind(Some("switch_mode"), None), "switch_mode");
    assert_eq!(acp_kind(Some("drgnx"), Some("Bash")), "other");
    assert_eq!(acp_kind(Some("Execute"), None), "other");
    assert_eq!(acp_kind(None, None), "other");
    assert_eq!(acp_kind(Some("other"), Some("NotebookEdit")), "edit");
    assert_eq!(acp_kind(None, Some("NotebookEdit")), "edit");
    assert_eq!(acp_kind(Some("drgnx"), Some("NotebookEdit")), "edit");
    assert_eq!(acp_kind(Some("read"), Some("NotebookEdit")), "read");
    // An agent's `drgnx` reaches no hook filtered on the hub's tools.
    let hub = [plugin(
        "hub",
        json!({"point": "before-tool", "verdicts": ["deny"], "filter": {"tool_kinds": ["drgnx"]}}),
    )];
    let kind = acp_kind(Some("drgnx"), Some("Bash"));
    assert!(!subscribed(
        &before_tool(kind, "Bash", &[], None),
        &[],
        &hub
    ));
}

/// The point's 2 s are shared: a hook gets the smaller of its own deadline and what is left, and one that would
/// start after the budget is spent is not run (a note if advisory, else a deny).
#[tokio::test(start_paused = true)]
async fn the_points_budget_is_shared() {
    let host = Scripted::default()
        .with("a", |_| (1000, Ok(Verdict::Allow)))
        .with("b", |_| (1000, Ok(Verdict::Allow)))
        .with("c", |_| (1000, Ok(Verdict::Allow)))
        .with("d", |_| (1000, Ok(Verdict::Allow)))
        .with("e", |_| (1000, Ok(Verdict::Allow)));
    let note = json!({"point": "before-tool", "verdicts": ["annotate"]});
    let plugins = [
        plugin(
            "a",
            json!({"point": "before-tool", "verdicts": ["annotate"], "deadline_ms": 500}),
        ),
        plugin("b", json!({"point": "before-tool", "verdicts": ["deny"]})),
        plugin("c", note.clone()),
        plugin("d", note),
        plugin("e", json!({"point": "before-tool", "verdicts": ["deny"]})),
    ];
    let input = before_tool("execute", "Bash", &[], Some("make"));
    let records = run(&input, budget(Point::BeforeTool), &[], &plugins, &host).await;

    let deadlines: Vec<u128> = host.calls().iter().map(|c| c.2.as_millis()).collect();
    assert_eq!(deadlines, [500, 1500, 500]);
    let ms: Vec<u32> = records.iter().map(|r| r.ms).collect();
    assert_eq!(&ms[..3], [500, 1000, 500]);
    assert_eq!(
        records[0].error.as_deref(),
        Some("hook a failed: timed out (500 ms)")
    );
    assert_eq!(records[1].verdict, Some(Verdict::Allow));
    assert_eq!(
        records[3].error.as_deref(),
        Some("hook d not run: the point's time ran out (2 s)")
    );
    assert_eq!(
        records[4].error.as_deref(),
        Some("hook e not run: the point's time ran out (2 s)")
    );
    let out = combine(cell(M::Allow), false, &records);
    assert_eq!(
        out.decision,
        Decision::Deny("hook e not run: the point's time ran out (2 s)".into())
    );
    assert_eq!(out.decided_by, Some(4));
    assert_eq!(out.annotations.len(), 3);
}

#[test]
fn filter_matches_exact_tool_names() {
    let merge = [plugin(
        "merge",
        json!({"point": "before-tool", "verdicts": ["deny"],
               "filter": {"tool_kinds": ["drgnx"], "tools": ["mcp__drgnx__merge"]}}),
    )];
    assert!(subscribed(
        &before_tool("drgnx", "mcp__drgnx__merge", &[], None),
        &[],
        &merge
    ));
    for (kind, tool) in [
        ("drgnx", "mcp__drgnx__merge_x"),
        ("drgnx", "mcp__drgnx__Merge"),
        ("drgnx", "mcp__drgnx__mer"),
        ("other", "mcp__drgnx__merge"),
    ] {
        assert!(
            !subscribed(&before_tool(kind, tool, &[], None), &[], &merge),
            "{kind} {tool}"
        );
    }
    let mut no_tool = before_tool("drgnx", "x", &[], None);
    no_tool.tool = None;
    assert!(!subscribed(&no_tool, &[], &merge));
}

#[test]
fn rule_ids_are_unique() {
    let rule =
        |id: &str| json!({"id": id, "point": "at-review", "verdict": "annotate", "reason": "r"});
    let twice = parse_rules(&json!([rule("a"), rule("b"), rule("a")])).expect_err("refused");
    assert_eq!(twice.path, "[2].id");
    let long = "x".repeat(33);
    for bad in ["", "A", "a_b", long.as_str()] {
        let e = parse_rules(&json!([rule(bad)])).expect_err(bad);
        assert_eq!(e.path, "[0].id", "{bad}");
    }
    let rules = parse_rules(
        &json!([rule("lock-files"), {"point": "at-review", "verdict": "annotate", "reason": "r"}]),
    )
    .unwrap();
    assert_eq!(rules[0].id.as_deref(), Some("lock-files"));
    assert_eq!(rules[1].id, None);
    let unknown =
        parse_rules(&json!([{"point": "at-review", "verdict": "deny", "reason": "r", "when": 1}]))
            .expect_err("unknown key");
    assert!(unknown.path.starts_with("[0]"), "{unknown}");
    assert!(unknown.message.contains("when"), "{unknown}");
    let no_reason = parse_rules(&json!([{"point": "at-review", "verdict": "deny", "reason": ""}]))
        .expect_err("empty reason");
    assert_eq!(no_reason.path, "[0].reason");
}
