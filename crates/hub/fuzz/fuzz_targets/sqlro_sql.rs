//! Arbitrary SQL through `graph/sql`'s runner on a WAL store with rows and a pending WAL. Never a write and never a
//! checkpoint (the database file and the WAL are byte for byte as they were), and an answer within the deadline plus
//! 100 ms.
#![no_main]

use std::cell::RefCell;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use libfuzzer_sys::fuzz_target;
use urdr::Connection;
use urdr::graph::ReadPool;
use urdr::graph::schema::GRAPH_DDL;
use urdr::graph::sqlro;

const DEADLINE: Duration = Duration::from_millis(50);
const SLACK: Duration = Duration::from_millis(100);

struct World {
    rt: tokio::runtime::Runtime,
    pool: ReadPool,
    db: PathBuf,
    wal: PathBuf,
    before: (Vec<u8>, Vec<u8>),
    /// Keeps the file's WAL from being checkpointed and removed when the last connection closes.
    _writer: Connection,
}

fn world() -> World {
    let dir = std::env::temp_dir().join(format!("drgnx-fuzz-sql-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("work.db");
    let wal = dir.join("work.db-wal");
    let writer = Connection::open(&db).unwrap();
    writer.pragma_update(None, "journal_mode", "wal").unwrap();
    writer.pragma_update(None, "wal_autocheckpoint", 0).unwrap();
    writer.execute_batch(GRAPH_DDL).unwrap();
    writer
        .execute_batch(
            "insert into entity (n, id, kind, origin, ver, created_tx, updated_tx)
             with recursive c(i) as (select 1 union all select i + 1 from c where i < 2000)
             select i, 'note:' || i, 'note', 'recorded', 1, 1, 1 from c;",
        )
        .unwrap();
    let read = |p: &PathBuf| std::fs::read(p).unwrap_or_default();
    World {
        rt: tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap(),
        pool: ReadPool::open(&db, 1),
        before: (read(&db), read(&wal)),
        db,
        wal,
        _writer: writer,
    }
}

thread_local! {
    static WORLD: RefCell<World> = RefCell::new(world());
}

fuzz_target!(|data: &[u8]| {
    let Ok(sql) = std::str::from_utf8(data) else {
        return;
    };
    WORLD.with(|w| {
        let w = w.borrow();
        let start = Instant::now();
        let _ =
            w.rt.block_on(sqlro::run(&w.pool, sql.to_owned(), vec![], DEADLINE, 100));
        let took = start.elapsed();
        assert!(took <= DEADLINE + SLACK, "{took:?} for {sql:?}");
        assert!(
            std::fs::read(&w.db).unwrap() == w.before.0,
            "the database file changed: {sql:?}"
        );
        assert!(
            std::fs::read(&w.wal).unwrap_or_default() == w.before.1,
            "the WAL changed: {sql:?}"
        );
    });
});
