//! Outside agents through a real front: bindings, attach, the bound table, the gate, the scope and the tx actor
//! (Tasks 8, 10 and 11).  Each test has its own temp folder: the hub's `work.db` and two git repositories.

use super::*;
use crate::runner::effects::tests::front_in;
use norn::matrix::Role;
use norn::tools::Hub as _;
use runstav::methods::Params;
use serde_json::{Value, json};
use std::process::Command;

fn git(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .current_dir(dir)
        .status()
        .unwrap()
        .success();
    assert!(ok, "git {args:?}");
}

/// A repository NAME under DIR with one commit: its truename.
fn repo(dir: &Path, name: &str) -> PathBuf {
    let r = dir.join(name);
    std::fs::create_dir_all(&r).unwrap();
    git(&r, &["init", "-q", "-b", "main"]);
    std::fs::write(r.join("README"), name).unwrap();
    git(&r, &["add", "."]);
    git(&r, &["commit", "-q", "-m", "first"]);
    std::fs::canonicalize(r).unwrap()
}

struct World {
    dir: tempfile::TempDir,
    f: Arc<Front>,
    /// The project the agent works in, and another one.
    root: PathBuf,
    other: PathBuf,
    /// The id of `root`'s project (a new plan names it).
    mine: String,
}

fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let hub = dir.path().join("hub");
    std::fs::create_dir_all(&hub).unwrap();
    let f = Arc::new(front_in(&hub));
    f.tool_hub.bind(&f);
    let root = repo(dir.path(), "org");
    let other = repo(dir.path(), "other");
    let mine = norn::project::resolve(&root).unwrap().unwrap().id;
    World {
        dir,
        f,
        root,
        other,
        mine,
    }
}

fn user() -> Caller {
    Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

fn agent(sid: &str) -> Caller {
    Caller {
        class: Class::Agent,
        sid: Some(sid.into()),
        job: None,
        conn_id: 0,
    }
}

fn bind_params(kind: &str, root: &Path, role: &str) -> BindParams {
    serde_json::from_value(json!({"kind": kind, "root": root, "role": role})).unwrap()
}

impl World {
    async fn bind(&self, kind: &str, root: &Path, role: &str) -> BindingRow {
        bind_in(&self.f, &user(), bind_params(kind, root, role), None)
            .await
            .unwrap()
    }

    /// A claude bridge started in CWD, attached.
    async fn attach(&self, cwd: &Path) -> Attached {
        let who =
            Identity::outside("claude", 4242, Some(1_700_000_000.0), Some(cwd.into())).unwrap();
        attach(&self.f, who).await
    }

    async fn exec(&self, id: &str, method: &'static str, p: Value) -> Result<Value, String> {
        self.f.tool_hub.exec(id, method, p).await
    }

    /// The project of ROOT, registered as the hub does: its id.
    async fn project(&self, root: &Path) -> String {
        let p = crate::graph::project_of(root).await.unwrap().unwrap();
        let id = p.id.clone();
        self.f
            .writer
            .write(&user(), "graph/record", move |tx| {
                Ok(norn::project::register(tx, &p)?)
            })
            .await
            .unwrap();
        id
    }

    /// A plan of the user's in PROJECT at REL (under that project's root): its id.
    async fn user_plan(&self, project: &str, rel: &str) -> String {
        let p = serde_json::from_value(json!({"project": project, "title": "The user's",
            "path": rel, "tasks": [{"number": "1", "title": "one"}]}))
        .unwrap();
        crate::runner::effects::plans_write(&self.f, &user(), p)
            .await
            .unwrap()
            .plan
    }

    /// A spec of the user's in PROJECT at REL: (its head's id, its version).
    async fn user_spec(&self, project: &str, rel: &str) -> (String, u64) {
        let p = serde_json::from_value(json!({"kind": "spec", "project": project, "path": rel,
            "title": "The user's spec", "sections": [{"heading": "Why", "body": "Because.\n"}],
            "base_version": 0}))
        .unwrap();
        let w = crate::records::write::records_write(&self.f, &user(), p)
            .await
            .unwrap();
        (w.record, w.version)
    }

    async fn cards(&self) -> i64 {
        self.f
            .writer
            .db
            .read(|c| {
                Ok(
                    c.query_row("select count(*) from card where kind = 'matrix'", [], |r| {
                        r.get(0)
                    })?,
                )
            })
            .await
            .unwrap()
    }

    /// Call the tool NAME as WHO's connection would (WHO's list, the hub's tools state).
    async fn tool(&self, who: &Identity, name: &str, args: Value) -> Result<String, String> {
        let list = self.f.mcp.outside_list_for(who);
        let t = list
            .iter()
            .find(|t| t.name() == name)
            .ok_or_else(|| format!("no tool {name} in the list"))?;
        t.check(&args).map_err(|e| e.to_string())?;
        match t.call(&(self.f.mcp.coord(), who.clone()), args).await {
            mimir::ToolResult::Ok { text, .. } | mimir::ToolResult::Rich { text, .. } => Ok(text),
            mimir::ToolResult::Err(text) => Err(text),
        }
    }
}

impl World {
    /// A new plan at REL in the agent's project.
    fn new_plan(&self, rel: &str) -> Value {
        json!({"title": "Mine", "project": self.mine, "path": rel,
               "tasks": [{"number": "1", "title": "one"}]})
    }
}

// ---- Task 8: the binding ----

/// [MP-1] A folder in a linked worktree binds its main repository's top-level.
#[tokio::test(flavor = "multi_thread")]
async fn bind_resolves_the_root_to_its_project_top_level() {
    let w = world();
    git(&w.root, &["worktree", "add", "-q", "../wt", "-b", "x"]);
    let sub = w.dir.path().join("wt").join("deep");
    std::fs::create_dir_all(&sub).unwrap();
    let row = w.bind("claude", &sub, "worker").await;
    assert_eq!(row.root, w.root.to_string_lossy());
    assert_eq!((row.kind.as_str(), row.role), ("claude", Role::Worker));
    let (kind, root) = ("claude".to_owned(), w.root.clone());
    let role =
        w.f.writer
            .db
            .read(move |c| Ok(bindings::role_for(c, &kind, &root)?))
            .await
            .unwrap();
    assert_eq!(role, Some(Role::Worker));
    let listed = list(&w.f, &user(), Empty {}).await.unwrap();
    assert_eq!(listed.bindings, vec![row]);
}

/// [MP-1] The home folder, `/` and a folder in no repository are never bound.
#[tokio::test(flavor = "multi_thread")]
async fn bind_refuses_home_and_a_non_project() {
    let w = world();
    let plain = w.dir.path().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    for (root, home) in [
        (w.root.clone(), Some(w.root.clone())),
        (PathBuf::from("/"), None),
        (plain.clone(), None),
        (w.dir.path().join("missing"), None),
    ] {
        let r = bind_in(&w.f, &user(), bind_params("claude", &root, "worker"), home).await;
        assert!(r.is_err(), "{root:?}: {r:?}");
    }
    // a folder whose repository's top-level is the home folder is refused too
    let deep = w.root.join("deep");
    std::fs::create_dir_all(&deep).unwrap();
    let r = bind_in(
        &w.f,
        &user(),
        bind_params("claude", &deep, "worker"),
        Some(w.root.clone()),
    )
    .await;
    assert!(r.is_err(), "{r:?}");
    assert!(
        list(&w.f, &user(), Empty {})
            .await
            .unwrap()
            .bindings
            .is_empty()
    );
}

/// [MP-1] An agent's connection never reaches `outside/*` (the registry's classes), and an agent's caller inside the
/// hub is refused by the handlers too.
#[tokio::test(flavor = "multi_thread")]
async fn an_agent_connection_cannot_bind() {
    let w = world();
    for line in [
        json!({"id": 1, "method": "outside/bind", "params": {"kind": "claude", "root": w.root, "role": "manager"}}),
        json!({"id": 2, "method": "outside/unbind", "params": {"id": "binding:claude-0123456789ab"}}),
        json!({"id": 3, "method": "outside/bindings", "params": {}}),
    ] {
        match crate::dispatch::prelude(Class::Agent, 1, None, &line.to_string()) {
            Err(crate::dispatch::ErrorAnswerOrDrop::Refused(r)) => {
                assert_eq!(r.error.code, ErrorCode::NotAllowed, "{line}")
            }
            Ok(_) => panic!("{line}: an agent's connection reached it"),
            Err(_) => panic!("{line}: dropped"),
        }
    }
    let r = bind(
        &w.f,
        &agent("s-1"),
        bind_params("claude", &w.root, "manager"),
    )
    .await;
    assert_eq!(r.map_err(|e| e.code), Err(ErrorCode::NotAllowed));
    let r = list(&w.f, &agent("s-1"), Empty {}).await;
    assert_eq!(r.map_err(|e| e.code), Err(ErrorCode::NotAllowed));
    assert!(
        list(&w.f, &user(), Empty {})
            .await
            .unwrap()
            .bindings
            .is_empty()
    );
}

// ---- Task 10: the role at attach, the bound table, scope and actor ----

/// [MP-1] A bridge attached from a linked worktree of a bound project has the binding's role.
#[tokio::test(flavor = "multi_thread")]
async fn attach_fills_the_role_from_a_user_binding() {
    let w = world();
    w.bind("claude", &w.root, "worker").await;
    git(&w.root, &["worktree", "add", "-q", "../wt", "-b", "x"]);
    let a = w.attach(&w.dir.path().join("wt")).await;
    assert_eq!(a.who.outside_role(), Some(Role::Worker));
    assert!(a.guard.is_some());
    let id = a.who.id().unwrap();
    let held = w.f.core.outside.get(id).unwrap();
    assert_eq!(
        (held.kind.as_str(), held.root.clone()),
        ("claude", w.root.clone())
    );
    let (who, ctx) = who_for(&w.f, &agent(id)).await.unwrap();
    assert_eq!(
        (
            who.role,
            who.agent.as_deref(),
            ctx.session.as_deref(),
            ctx.plan
        ),
        (Some(Role::Worker), Some("ext:claude"), Some(id), None)
    );
    assert!(ctx.project.is_some());
    // the guard's drop detaches the bridge
    drop(a.guard);
    assert!(w.f.core.outside.get(id).is_none());
}

/// [MP-1] Without a binding the bridge has no role, and the gate refuses it.
#[tokio::test(flavor = "multi_thread")]
async fn attach_without_a_binding_has_no_role() {
    let w = world();
    let a = w.attach(&w.root).await;
    assert_eq!(a.who.outside_role(), None);
    let id = a.who.id().unwrap();
    let e = who_for(&w.f, &agent(id)).await.unwrap_err();
    assert_eq!(
        (e.code, e.message.as_str()),
        (ErrorCode::NotAllowed, NOT_BOUND)
    );
    // nothing is open to it, the tools' list is today's
    let names =
        |l: crate::sessions::ToolList| l.iter().map(|t| t.name().to_owned()).collect::<Vec<_>>();
    let today: Vec<String> = norn::tools::tools()
        .iter()
        .map(|t| t.name().to_owned())
        .collect();
    assert_eq!(names(w.f.mcp.outside_list_for(&a.who)), today);
}

/// [MP-1] A binding for another kind, or for another project, gives nothing.
#[tokio::test(flavor = "multi_thread")]
async fn a_binding_for_another_kind_or_root_gives_nothing() {
    let w = world();
    w.bind("codex", &w.root, "manager").await;
    w.bind("claude", &w.other, "manager").await;
    let a = w.attach(&w.root).await;
    assert_eq!(a.who.outside_role(), None);
    assert!(who_for(&w.f, &agent(a.who.id().unwrap())).await.is_err());
}

/// [Review Focus 2] An unbind reaches a bridge that is open: its next call is refused.
#[tokio::test(flavor = "multi_thread")]
async fn an_unbind_applies_to_a_live_bridge_at_its_next_call() {
    let w = world();
    let row = w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    assert_eq!(a.who.outside_role(), Some(Role::Worker));
    let id = a.who.id().unwrap().to_owned();
    let written = w
        .exec(&id, "plans/write", w.new_plan("docs/plans/org/mine.md"))
        .await
        .unwrap();
    let plan = written["plan"].as_str().unwrap().to_owned();
    assert!(
        w.exec(&id, "plans/get", json!({"plan": plan}))
            .await
            .is_ok()
    );
    let p: UnbindParams = serde_json::from_value(json!({"id": row.id})).unwrap();
    assert!(unbind(&w.f, &user(), p).await.unwrap());
    // the bridge still holds the role it was attached with; the hub reads the binding again
    assert_eq!(a.who.outside_role(), Some(Role::Worker));
    for (method, p) in [
        ("plans/get", json!({"plan": plan})),
        (
            "plans/write",
            json!({"plan": plan, "tasks": [{"number": "2", "title": "two"}]}),
        ),
        ("records/read", json!({"record": plan})),
    ] {
        let e = w.exec(&id, method, p).await.unwrap_err();
        assert_eq!(e, NOT_BOUND, "{method}");
    }
    let e = w
        .tool(&a.who, "plan_read", json!({"plan": plan}))
        .await
        .unwrap_err();
    assert_eq!(e, NOT_BOUND);
}

/// [Review Focus 5] An `ext:` id no bridge holds is refused, never taken for a worker.
#[tokio::test(flavor = "multi_thread")]
async fn an_unknown_ext_id_is_refused_not_a_worker() {
    let w = world();
    w.bind("claude", &w.root, "worker").await;
    let ghost = "ext:claude:9-abcdef";
    let e = who_for(&w.f, &agent(ghost)).await.unwrap_err();
    assert_eq!(
        (e.code, e.message.as_str()),
        (ErrorCode::NotAllowed, NOT_BOUND)
    );
    assert!(scope_of(&w.f, ghost).await.is_err());
    for (method, p) in [
        ("plans/write", w.new_plan("docs/plans/org/ghost.md")),
        ("records/read", json!({"record": "spec:x"})),
    ] {
        assert_eq!(
            w.exec(ghost, method, p).await.unwrap_err(),
            NOT_BOUND,
            "{method}"
        );
    }
    assert!(!w.root.join("docs/plans/org/ghost.md").exists());
    // a session id the hub does not hold keeps today's worker column
    let (who, _) = who_for(&w.f, &agent("s-gone")).await.unwrap();
    assert_eq!(who.role, Some(Role::Worker));
}

/// [MP-1] An outside agent's write is a tx with its own actor, of class `ext`, and `graph revert --tx` undoes it.
#[tokio::test(flavor = "multi_thread")]
async fn an_outside_write_is_a_tx_with_its_ext_actor() {
    let w = world();
    w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    let id = a.who.id().unwrap().to_owned();
    let written = w
        .exec(&id, "plans/write", w.new_plan("docs/plans/org/mine.md"))
        .await
        .unwrap();
    let tx = written["tx"].as_i64().unwrap();
    let plan = written["plan"].as_str().unwrap().to_owned();
    let row =
        w.f.writer
            .db
            .read(move |c| {
                Ok(c.query_row(
                    "select actor, class, session from tx where id = ?1",
                    [tx],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1)?,
                            r.get::<_, Option<String>>(2)?,
                        ))
                    },
                )?)
            })
            .await
            .unwrap();
    assert_eq!(row, (id.clone(), "ext".to_owned(), Some(id.clone())));
    let revert: Params = Params::GraphRevert(serde_json::from_value(json!({"tx": tx})).unwrap());
    let coord = w.f.mcp.coord();
    let r = crate::graph::serve(&w.f.writer, &coord, None, &user(), revert).await;
    match r {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => panic!("the revert: {}", e.message),
        Err(_) => panic!("graph/revert is not graph::serve's"),
    }
    let gone =
        w.f.writer
            .db
            .read(move |c| {
                Ok(urdr::graph::entity::by_id(c, &plan)?.is_none_or(|e| e.retired_tx.is_some()))
            })
            .await
            .unwrap();
    assert!(gone, "the revert retired the plan");
}

/// [Review Focus 5] Through the tools' `exec` an outside actor reaches the four methods only.
#[tokio::test(flavor = "multi_thread")]
async fn an_outside_actor_reaches_only_four_methods_through_exec() {
    let w = world();
    w.bind("claude", &w.root, "manager").await;
    let a = w.attach(&w.root).await;
    let id = a.who.id().unwrap();
    for (method, p) in [
        ("exec/start", json!({"argv": ["true"], "cwd": w.root})),
        (
            "outside/bind",
            json!({"kind": "claude", "root": w.root, "role": "manager"}),
        ),
        ("outside/bindings", json!({})),
        ("agents/list", json!({})),
        ("job/propose", json!({"plan": "plan:x"})),
    ] {
        let e = w.exec(id, method, p).await.unwrap_err();
        assert!(e.contains("not open to an outside agent"), "{method}: {e}");
    }
    assert_eq!(
        OUTSIDE_METHODS,
        ["plans/get", "plans/write", "records/read", "records/write"]
    );
}

/// [Review Focus 3] A record of no project whose file lies under the agent's project root is its project's (for a
/// bound outside agent and for a session alike); one under another project's root is not.
#[tokio::test(flavor = "multi_thread")]
async fn an_imported_record_of_the_project_is_the_agents_and_one_outside_is_not() {
    let w = world();
    let mine = w.project(&w.root).await;
    let theirs = w.project(&w.other).await;
    let here = w.user_plan(&mine, "docs/plans/org/users.md").await;
    let there = w.user_plan(&theirs, "docs/plans/other/users.md").await;
    w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    let id = a.who.id().unwrap();
    let got = w
        .exec(id, "plans/get", json!({"plan": here}))
        .await
        .unwrap();
    assert_eq!(got["tasks"].as_array().map(Vec::len), Some(1), "{got}");
    assert!(
        w.exec(id, "plans/get", json!({"plan": there}))
            .await
            .is_err()
    );
    // a session of the project reaches it the same way
    let session = Scope::Project {
        id: Some(mine),
        root: Some(w.root.clone()),
        jobs: Vec::new(),
        sessions: vec!["s-1".into()],
    };
    let r =
        w.f.writer
            .db
            .read(move |c| {
                let e = |id: &str| urdr::graph::entity::by_id(c, id).unwrap().unwrap();
                Ok((
                    session.allows_ent(c, &e(&here)).is_ok(),
                    session.allows_ent(c, &e(&there)).is_ok(),
                ))
            })
            .await
            .unwrap();
    assert_eq!(r, (true, false));
}

/// [Review Focus 3] Another project's plan is refused to a bound agent before the matrix is asked (no card).
#[tokio::test(flavor = "multi_thread")]
async fn another_projects_plan_is_refused_to_a_bound_agent() {
    let w = world();
    let theirs = w.project(&w.other).await;
    let there = w.user_plan(&theirs, "docs/plans/other/users.md").await;
    w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    let id = a.who.id().unwrap();
    let e = w
        .exec(
            id,
            "plans/write",
            json!({"plan": there, "tasks": [{"number": "2", "title": "x"}]}),
        )
        .await
        .unwrap_err();
    assert!(
        e.contains("another") || e.contains("outside your project"),
        "{e}"
    );
    assert!(
        w.exec(id, "plans/get", json!({"plan": there}))
            .await
            .is_err()
    );
    // nor may its new plan name the other project
    let mut p = w.new_plan("docs/plans/org/mine.md");
    p["project"] = json!(theirs);
    assert!(w.exec(id, "plans/write", p).await.is_err());
    assert_eq!(w.cards().await, 0);
}

// ---- Task 11: the tools opened ----

/// [MP-3] A bound outside agent's list is every outside agent's and the four plan and record tools.
#[tokio::test(flavor = "multi_thread")]
async fn a_bound_outside_agent_lists_the_four_tools() {
    let w = world();
    w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    let names: Vec<String> =
        w.f.mcp
            .outside_list_for(&a.who)
            .iter()
            .map(|t| t.name().to_owned())
            .collect();
    let mut want: Vec<String> = norn::tools::tools()
        .iter()
        .map(|t| t.name().to_owned())
        .collect();
    want.extend(norn::tools::OUTSIDE_TOOLS.iter().map(|s| (*s).to_owned()));
    assert_eq!(names, want);
}

/// [MP-3] An unbound one keeps today's list.
#[tokio::test(flavor = "multi_thread")]
async fn an_unbound_one_lists_todays_tools() {
    let w = world();
    let a = w.attach(&w.other).await;
    let names: Vec<String> =
        w.f.mcp
            .outside_list_for(&a.who)
            .iter()
            .map(|t| t.name().to_owned())
            .collect();
    let today: Vec<String> = norn::tools::tools()
        .iter()
        .map(|t| t.name().to_owned())
        .collect();
    assert_eq!(names, today);
    assert!(
        !names
            .iter()
            .any(|n| norn::tools::OUTSIDE_TOOLS.contains(&n.as_str()))
    );
}

/// [MP-3] A bound worker's `plan_write` makes its plan and its view file, as its own tx.
#[tokio::test(flavor = "multi_thread")]
async fn plan_write_by_a_bound_worker_outside_agent_creates_its_plan() {
    let w = world();
    w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    let text = w
        .tool(&a.who, "plan_write", w.new_plan("docs/plans/org/mine.md"))
        .await
        .unwrap();
    let v: Value = serde_json::from_str(&text).unwrap();
    assert!(w.root.join("docs/plans/org/mine.md").is_file());
    let tx = v["tx"].as_i64().unwrap();
    let actor: String = w
        .f
        .writer
        .db
        .read(move |c| Ok(c.query_row("select actor from tx where id = ?1", [tx], |r| r.get(0))?))
        .await
        .unwrap();
    assert_eq!(actor, a.who.id().unwrap());
    // its own plan: a later change needs no card
    let plan = v["plan"].as_str().unwrap();
    let r = w
        .tool(
            &a.who,
            "plan_write",
            json!({"plan": plan, "tasks": [{"number": "1", "title": "one, again"}]}),
        )
        .await;
    assert!(r.is_ok(), "{r:?}");
    assert_eq!(w.cards().await, 0);
    let read = w
        .tool(&a.who, "plan_read", json!({"plan": plan}))
        .await
        .unwrap();
    assert!(read.contains("one, again"), "{read}");
}

/// [MP-3] A bound chat never changes the graph (the chat column's `graph.change` is Never).
#[tokio::test(flavor = "multi_thread")]
async fn a_bound_chat_outside_agent_cannot_change_the_graph() {
    let w = world();
    w.bind("claude", &w.root, "chat").await;
    let a = w.attach(&w.root).await;
    let e = w
        .tool(&a.who, "plan_write", w.new_plan("docs/plans/org/mine.md"))
        .await
        .unwrap_err();
    assert_eq!(e, "graph.change is never allowed here");
    assert!(!w.root.join("docs/plans/org/mine.md").exists());
}

/// [MP-2] Rewriting the user's own spec asks the user (one card) and writes nothing.
#[tokio::test(flavor = "multi_thread")]
async fn records_write_on_a_users_spec_asks_and_writes_nothing() {
    let w = world();
    let mine = w.project(&w.root).await;
    let (spec, version) = w.user_spec(&mine, "docs/specs/org/users.md").await;
    let file = w.root.join("docs/specs/org/users.md");
    let before = std::fs::read_to_string(&file).unwrap();
    w.bind("claude", &w.root, "worker").await;
    let a = w.attach(&w.root).await;
    let read = w
        .tool(&a.who, "records_read", json!({"record": spec}))
        .await
        .unwrap();
    assert!(read.contains("Because."), "{read}");
    let e = w
        .tool(
            &a.who,
            "records_write",
            json!({"record": spec, "kind": "spec", "base_version": version,
                   "sections": [{"heading": "Why", "body": "Rewritten.\n"}]}),
        )
        .await
        .unwrap_err();
    assert!(
        e.starts_with("the matrix asks the user first (card "),
        "{e}"
    );
    assert_eq!(w.cards().await, 1);
    assert_eq!(std::fs::read_to_string(&file).unwrap(), before);
    let again = w
        .tool(&a.who, "records_read", json!({"record": spec}))
        .await
        .unwrap();
    let v: Value = serde_json::from_str(&again).unwrap();
    assert_eq!(v["version"], json!(version));
}

/// [MP-2] An outside agent never marks a task done nor approves a record, whatever its role.
#[tokio::test(flavor = "multi_thread")]
async fn an_outside_agent_never_marks_done() {
    let w = world();
    w.bind("claude", &w.root, "manager").await;
    let a = w.attach(&w.root).await;
    let written = w
        .tool(&a.who, "plan_write", w.new_plan("docs/plans/org/mine.md"))
        .await
        .unwrap();
    let plan = serde_json::from_str::<Value>(&written).unwrap()["plan"]
        .as_str()
        .unwrap()
        .to_owned();
    let e = w
        .tool(
            &a.who,
            "plan_write",
            json!({"plan": plan, "tasks": [{"number": "1", "status": "done"}]}),
        )
        .await
        .unwrap_err();
    assert_eq!(e, "task.done is never allowed here");
    let e = w
        .tool(
            &a.who,
            "records_write",
            json!({"kind": "spec", "path": "docs/specs/org/mine.md", "title": "Mine",
                   "status": "approved", "sections": [], "base_version": 0}),
        )
        .await
        .unwrap_err();
    assert!(e.starts_with("an agent may not approve a record"), "{e}");
    assert!(!w.root.join("docs/specs/org/mine.md").exists());
    assert_eq!(w.cards().await, 0);
}

/// An entity ID written by ACTOR (class CLASS) with DATA: its `n`.
async fn entity_by(
    w: &World,
    actor: &str,
    class: urdr::graph::Class,
    id: &str,
    kind: &str,
    data: Value,
) -> i64 {
    use urdr::graph::entity::{EntityNew, Origin};
    let (id, kind) = (id.to_owned(), kind.to_owned());
    w.f.writer
        .db
        .write(urdr::graph::TxMeta::new(actor, class, "test"), move |tx| {
            Ok(urdr::graph::entity::create(
                tx,
                EntityNew {
                    id,
                    kind,
                    project: None,
                    title: Some("t".into()),
                    status: Some("active".into()),
                    body: None,
                    priority: None,
                    assignee: None,
                    data,
                    origin: Origin::Recorded,
                    source: None,
                },
            )?
            .n)
        })
        .await
        .unwrap()
}

/// [review] An id that is its pid alone (no start time) owns nothing: a later process with that pid is another.
#[tokio::test(flavor = "multi_thread")]
async fn a_pid_alone_id_owns_nothing() {
    let w = world();
    let ext = urdr::graph::Class::Ext;
    let alone = entity_by(&w, "ext:claude:42", ext, "note:a", "note", json!({})).await;
    let hashed = entity_by(&w, "ext:claude:42-abcdef", ext, "note:b", "note", json!({})).await;
    let r =
        w.f.writer
            .db
            .read(move |c| {
                Ok((
                    own_record(c, &[alone], "ext:claude:42")?,
                    own_record(c, &[hashed], "ext:claude:42-abcdef")?,
                    own_record(c, &[hashed], "ext:claude:43-abcdef")?,
                    own_record(c, &[], "ext:claude:42-abcdef")?,
                ))
            })
            .await
            .unwrap();
    assert_eq!(r, (false, true, false, false));
}

/// [review] A binding entity another writer made never counts, and `outside/bind` says so instead of answering a
/// binding that gives nothing.
#[tokio::test(flavor = "multi_thread")]
async fn bind_refuses_a_binding_another_writer_made() {
    let w = world();
    // the hub's guard refuses any other writer of a binding ...
    let id = bindings::binding_id("claude", &w.root);
    let (bid, root) = (id.clone(), w.root.clone());
    let refused =
        w.f.writer
            .db
            .write(
                urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "test"),
                move |tx| {
                    Ok(urdr::graph::entity::create(
                        tx,
                        urdr::graph::entity::EntityNew {
                            id: bid,
                            kind: "binding".into(),
                            project: None,
                            title: None,
                            status: Some("active".into()),
                            body: None,
                            priority: None,
                            assignee: None,
                            data: json!({"kind": "claude", "root": root, "role": "manager"}),
                            origin: urdr::graph::entity::Origin::Recorded,
                            source: None,
                        },
                    )?
                    .n)
                },
            )
            .await;
    assert!(refused.is_err(), "{refused:?}");
    // ... so one is made by hand in the file: the user's binding whose first tx is then not the user's
    w.bind("claude", &w.root, "manager").await;
    let file = w.dir.path().join("hub").join("work.db");
    let raw = urdr::Connection::open(&file).unwrap();
    let n = raw
        .execute(
            "update tx set class = 'system' where id = (select created_tx from entity where id = ?1)",
            [&id],
        )
        .unwrap();
    assert_eq!(n, 1);
    drop(raw);
    let e = bind_in(
        &w.f,
        &user(),
        bind_params("claude", &w.root, "worker"),
        None,
    )
    .await
    .unwrap_err();
    assert!(e.message.contains("never counts"), "{}", e.message);
    let a = w.attach(&w.root).await;
    assert_eq!(a.who.outside_role(), None);
}
