//! A schema-7 store with its tools, for the `task_write_args`, `graph_read_args` and `report_submit` targets: a file made by the graph
//! writer, the tools over it, a caller whose folder is a project, and one task made at the start (the text `@T` in an
//! input stands for its id).  Each input gets a fresh store, so a crash reproduces from its input alone.
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use mimir::{BoxFuture, Tool};
use norn::deny::DenyList;
use norn::project::ProjectRef;
use norn::store::CoordDb;
use norn::tools::{Coord, Ctx, GraphStore, Hub, Identity, SessionRow, core_tools, tools};
use serde_json::{Value, json};
use urdr::graph::{Class, ReadPool, TxMeta};

/// A hub that answers no `agents/list`, as when none runs.
struct NoHub;

impl Hub for NoHub {
    fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
        Box::pin(async { None })
    }
    fn notify(&self) {}
}

struct World {
    rt: tokio::runtime::Runtime,
    ctx: Ctx,
    tools: Vec<Box<dyn Tool<Ctx>>>,
    task: String,
}

fn make(dir: &Path) -> World {
    let home = dir.join("work/alpha");
    std::fs::create_dir_all(&home).unwrap();
    let file = dir.join("work.db");
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let coord = rt.block_on(async {
        let db = CoordDb::spawn(&file);
        // the writer makes the file at its first request
        db.write(TxMeta::new("hub", Class::System, "fuzz"), |_| Ok(()))
            .await
            .unwrap();
        let graph = GraphStore {
            writer: db.graph_writer().unwrap().clone(),
            pool: ReadPool::open(&file, 2),
            deny: Arc::new(RwLock::new(Arc::new(DenyList::load(
                &dir.join("home"),
                &dir.join("config"),
            )))),
        };
        Arc::new(Coord::new(db, Arc::new(NoHub)).with_graph(graph))
    });
    // the caller's folder is a project of its own (a made-up root commit, no git needed)
    let sha = format!("{:040x}", 0xd06f00d_u128);
    coord.projects().lock().unwrap().insert(
        home.clone(),
        Some(ProjectRef {
            id: format!("project:{}", &sha[28..]),
            root: home.clone(),
            slug: "alpha".into(),
            root_commit: Some(sha.clone()),
            roots: vec![sha],
        }),
    );
    let who = Identity::Session {
        agent: "s-0000000a".into(),
        sid: "s1".into(),
        profile: None,
        job: None,
        task: None,
        home: PathBuf::from(&home),
    };
    let mut w = World {
        rt,
        ctx: (coord, who),
        // the coordination tools and the agent core's (`report_submit` is a core tool, not a coordination one)
        tools: tools().into_iter().chain(core_tools()).collect(),
        task: String::new(),
    };
    let made = w.call("task_write", json!({"op": "create", "title": "seed"}));
    w.task = made.unwrap()["done"]["id"].as_str().unwrap().to_owned();
    w
}

impl World {
    /// Check, then call TOOL with ARGS; the structured answer of a success.
    fn call(&self, tool: &str, args: Value) -> Option<Value> {
        let tool = self.tools.iter().find(|t| t.name() == tool).unwrap();
        tool.check(&args).ok()?;
        match self.rt.block_on(tool.call(&self.ctx, args)) {
            mimir::ToolResult::Ok { structured, .. }
            | mimir::ToolResult::Rich { structured, .. } => structured,
            mimir::ToolResult::Err(_) => None,
        }
    }
}

/// Arguments (JSON, `@T` replaced by the seed task's id) through TOOL's check and call, on a fresh store (its own
/// folder, removed after: the writer thread of the last one may still be closing its file). A refusal is an answer;
/// nothing may panic or hang.
pub fn run(tool: &str, data: &[u8]) {
    let Ok(args) = serde_json::from_slice::<Value>(data) else {
        return;
    };
    static N: AtomicU64 = AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "drgnx-fuzz-tools-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    let w = make(&dir);
    let text = args.to_string().replace("@T", &w.task);
    if let Ok(args) = serde_json::from_str::<Value>(&text) {
        let _ = w.call(tool, args);
    }
    drop(w);
    let _ = std::fs::remove_dir_all(&dir);
}
