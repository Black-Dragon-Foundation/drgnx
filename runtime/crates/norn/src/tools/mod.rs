//! The 16 coordination tools on `mimir` (docs/develop/coordination.md, "The tools").  The types and the list are
//! Task 0's, so Tasks 7, 8 and 9 build in parallel: Task 7 fills `identity`, `guard` and `report`, Task 8 `job` and
//! `read`, and none of them edits this file's list.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use mimir::BoxFuture;

use urdr::graph::{ReadPool, WriterHandle};

use crate::deny::{DenyList, SharedDeny};
use crate::store::CoordDb;

pub mod graph;
pub mod guard;
pub mod identity;
pub mod job;
pub mod read;
pub mod report;
pub mod tracker;

pub use tracker::{ToolSets, tools_for};

/// Who is calling a tool.  Never built from a tool argument or an environment variable ([`identity`] holds its
/// rules).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Identity {
    /// From a session socket (Task 10); `home` is the cwd the session was minted with.  `sid` and `profile` (the
    /// Urdr plan's Task 0) name the session in its writes' `tx` rows and in grants (`session:SID`, `profile:NAME`);
    /// `profile` is `None` until `msession` keeps it (Urdr Task 15b).
    Session {
        agent: String,
        sid: String,
        profile: Option<String>,
        job: Option<String>,
        task: Option<String>,
        home: PathBuf,
    },
    /// An outside bridge: `id` is `ext:KIND:PID-HASH`.
    Outside {
        id: String,
        kind: String,
        home: Option<PathBuf>,
    },
    /// Read-only: writes answer "no agent identity".
    None,
}

/// A row of the backend's `agents/list`.
pub type SessionRow = runstav::methods::agents::Snapshot;

/// What the tools need of the hub; Ratatoskr implements it (Task 9).
pub trait Hub: Send + Sync {
    /// The backend's `agents/list`, 2 s; `None` = no hub answer.
    fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>>;
    /// A coalesced `coord/notify`.
    fn notify(&self);
}

/// The clock the tools read (`float-time`): seconds since the epoch.
pub type Clock = Arc<dyn Fn() -> f64 + Send + Sync>;

/// The tools' shared state: one per hub, shared by every connection (the report limit counts per identity across
/// them).
pub struct Coord {
    db: CoordDb,
    hub: Arc<dyn Hub>,
    rates: Mutex<guard::Rates>,
    clock: Clock,
    graph: Option<GraphStore>,
}

/// The graph store the schema-7 tools read and write through (the Urdr plan): set by the hub once its writer is
/// open ([`Coord::with_graph`]); `None` before (and in the p2–p3 tests).
#[derive(Clone)]
pub struct GraphStore {
    pub writer: WriterHandle,
    pub pool: ReadPool,
    pub deny: SharedDeny,
}

impl Coord {
    pub fn new(db: CoordDb, hub: Arc<dyn Hub>) -> Coord {
        let clock: Clock = Arc::new(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0.0, |d| d.as_secs_f64())
        });
        Coord::with_clock(db, hub, clock)
    }

    /// A `Coord` whose time is CLOCK's (tests fix it, as the Lisp tests stub `drgnx-coord-mcp--now`).
    pub fn with_clock(db: CoordDb, hub: Arc<dyn Hub>, clock: Clock) -> Coord {
        Coord {
            db,
            hub,
            rates: Mutex::default(),
            clock,
            graph: None,
        }
    }

    /// This `Coord` with the graph store G.
    pub fn with_graph(mut self, g: GraphStore) -> Coord {
        self.graph = Some(g);
        self
    }

    /// The graph store, once the hub has opened it.
    pub fn graph(&self) -> Option<&GraphStore> {
        self.graph.as_ref()
    }

    /// The deny-list in force now (a snapshot: a reload replaces the list, never edits it).
    pub fn deny(&self) -> Option<Arc<DenyList>> {
        self.graph
            .as_ref()
            .map(|g| g.deny.read().unwrap_or_else(|e| e.into_inner()).clone())
    }

    /// The store the tools write through.
    pub fn db(&self) -> &CoordDb {
        &self.db
    }

    /// The hub: its sessions, and `notify` after every write (the Lisp `drgnx-coord-mcp--notify-hub`).
    pub fn hub(&self) -> &dyn Hub {
        &*self.hub
    }

    /// Now, as `float-time` gives it.
    pub fn now(&self) -> f64 {
        (self.clock)()
    }
}

/// A tool call's context.
pub type Ctx = (Arc<Coord>, Identity);

/// Every coordination tool.
pub fn tools() -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    let mut all = report::tools();
    all.extend(job::tools());
    all.extend(read::tools());
    all.extend(tracker::tools());
    all.extend(graph::tools());
    all
}
