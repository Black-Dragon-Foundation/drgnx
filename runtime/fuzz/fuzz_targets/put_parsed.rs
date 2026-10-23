//! Arbitrary bytes as `graph/put-parsed`'s params: the wire type's decode, then `dirs` and `put` on an in-memory
//! schema 7 (door 1, the shape checks, the content compare). A decode error is an answer; nothing may panic, and a
//! put leaves nothing behind (each input runs in a tx that is dropped, not committed).
#![no_main]

use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::Arc;

use libfuzzer_sys::fuzz_target;
use norn::deny::DenyList;
use norn::parsed::{self, PutParsed};
use urdr::Connection;
use urdr::graph::guard::Guard;
use urdr::graph::schema::GRAPH_DDL;
use urdr::graph::{Class, Tx, TxMeta};

struct World {
    conn: Connection,
    deny: DenyList,
    guard: Arc<Guard>,
}

fn world() -> World {
    let dir = std::env::temp_dir().join(format!("drgnx-fuzz-put-{}", std::process::id()));
    let (home, config): (PathBuf, PathBuf) = (dir.join("home"), dir.join("config"));
    std::fs::create_dir_all(home.join("org")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(GRAPH_DDL).unwrap();
    // the two hub-owned tables a put writes
    conn.execute_batch(
        "create table parsed_file (path text primary key, mtime real);
         create table kv (key text primary key, value text);",
    )
    .unwrap();
    let mut guard = Guard::default();
    norn::grants::register(&mut guard);
    World {
        conn,
        deny: DenyList::load(&home, &config),
        guard: Arc::new(guard),
    }
}

thread_local! {
    static WORLD: RefCell<World> = RefCell::new(world());
}

fuzz_target!(|data: &[u8]| {
    // the method's decode (typed, with the registry's checks), then the typed params
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    let method = runstav::registry::find("graph/put-parsed").unwrap();
    if (method.decode)(&value).is_err() {
        return;
    }
    let Ok(req) = serde_json::from_value::<PutParsed>(value) else {
        return;
    };
    WORLD.with(|w| {
        let w = &mut *w.borrow_mut();
        let _ = parsed::dirs(&w.conn, &w.deny, &req);
        let meta = TxMeta::new("scan:/w", Class::System, "scan");
        let mut tx = Tx::for_test(&mut w.conn, meta, w.guard.clone());
        let _ = parsed::put(&mut tx, &w.deny, req);
        // dropped without a commit: the savepoint rolls back
    });
});
