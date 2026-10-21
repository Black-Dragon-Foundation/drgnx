//! The 16 coordination tools on `mimir` (docs/develop/coordination.md, "The tools").  The types and the list are
//! Task 0's, so Tasks 7, 8 and 9 build in parallel: Task 7 fills `identity`, `guard` and `report`, Task 8 `job` and
//! `read`, and none of them edits this file's list.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use mimir::BoxFuture;

use crate::store::CoordDb;

pub mod guard;
pub mod identity;
pub mod job;
pub mod read;
pub mod report;

/// Who is calling a tool.  Never built from a tool argument or an environment variable.
pub enum Identity {
    /// From a session socket (Task 10); `home` is the cwd the session was minted with.
    Session {
        agent: String,
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

/// The tools' shared state.
#[allow(dead_code)] // read by the tools of Tasks 7 and 8
pub struct Coord {
    db: CoordDb,
    hub: Arc<dyn Hub>,
    rates: Mutex<guard::Rates>,
}

impl Coord {
    pub fn new(db: CoordDb, hub: Arc<dyn Hub>) -> Coord {
        Coord {
            db,
            hub,
            rates: Mutex::default(),
        }
    }
}

/// A tool call's context.
pub type Ctx = (Arc<Coord>, Identity);

/// Every coordination tool.
pub fn tools() -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    let mut all = report::tools();
    all.extend(job::tools());
    all.extend(read::tools());
    all
}
