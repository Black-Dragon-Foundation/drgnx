//! Arbitrary bytes as the lines of one MCP connection, served by `mimir::serve` with the 16 coordination tools over a
//! schema-6 `work.db` (the oracle's fixture): as given (the stateless era, or whatever the lines say), and after a
//! legacy `initialize` handshake. Every answer line must be one JSON value; nothing may panic or hang.
#![no_main]

use std::sync::{Arc, OnceLock};

use libfuzzer_sys::fuzz_target;
use mimir::{BoxFuture, Limits, ServerInfo, Tool};
use norn::store::CoordDb;
use norn::tools::{Coord, Ctx, Hub, Identity, SessionRow, tools};

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
    ctx: Arc<Ctx>,
    tools: Arc<[Box<dyn Tool<Ctx>>]>,
}

/// One database for the whole run (a file in a temporary directory: the store opens a path), and one runtime.
fn world() -> &'static World {
    static WORLD: OnceLock<World> = OnceLock::new();
    WORLD.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("drgnx-fuzz-mcp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("work.db");
        let schema = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../test/fixtures/work-db-6.sql"
        ));
        urdr::Connection::open(&file)
            .unwrap()
            .execute_batch(schema)
            .unwrap();
        let coord = Arc::new(Coord::new(CoordDb::spawn(&file), Arc::new(NoHub)));
        let who = Identity::Session {
            agent: "s-0000000a".into(),
            sid: "s1".into(),
            profile: None,
            job: Some("j1".into()),
            task: None,
            home: dir,
        };
        World {
            rt: tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap(),
            ctx: Arc::new((coord, who)),
            tools: tools().into(),
        }
    })
}

const INITIALIZE: &str = concat!(
    r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"f","version":"0"}}}"#,
    "\n",
    r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    "\n",
);

fn run(input: &[u8]) {
    let w = world();
    let mut out: Vec<u8> = Vec::new();
    let limits = Limits {
        max_in: 1 << 16,
        max_out: 1 << 24,
    };
    w.rt.block_on(mimir::serve(
        w.ctx.clone(),
        w.tools.clone(),
        ServerInfo::default(),
        input,
        &mut out,
        limits,
    ));
    for line in out.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        assert!(
            serde_json::from_slice::<serde_json::Value>(line).is_ok(),
            "an answer line that is not JSON"
        );
    }
}

fuzz_target!(|data: &[u8]| {
    run(data);
    let mut legacy = INITIALIZE.as_bytes().to_vec();
    legacy.extend_from_slice(data);
    run(&legacy);
});
