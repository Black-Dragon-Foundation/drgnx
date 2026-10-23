//! Graph B of the storage design (10^5 nodes, 10^6 links, 6 kinds): walk timings. Ignored in normal runs; Task 20
//! runs it under the perf lock: `cargo test -p urdr --features test-hooks --bench walk -- --ignored --nocapture`.
#![cfg(feature = "test-hooks")]

use std::time::Instant;

use urdr::graph::ReadPool;
use urdr::graph::link::Direction;
use urdr::graph::walk::{Budget, PathQ, Scope, Seen, Walk, neighbors, path, synthetic};

struct All;
impl Scope for All {
    fn allows(&self, _: Option<i64>) -> Seen {
        Seen::Full
    }
    fn valid(&self) -> bool {
        true
    }
}

#[tokio::test]
#[ignore]
async fn graph_b_walks() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("work.db");
    synthetic(&file, 100_000, 1_000_000, 6).unwrap();
    let pool = ReadPool::open(&file, 2);
    for depth in 1..=3 {
        let t = Instant::now();
        let o = neighbors(
            &pool,
            Walk {
                from: 1,
                kinds: vec![],
                direction: Direction::Both,
                depth,
                as_of: None,
            },
            &All,
            Budget::default(),
        )
        .await
        .unwrap();
        println!(
            "neighbors depth {depth}: {} nodes, {:?}, {:?}",
            o.nodes.len(),
            o.truncated,
            t.elapsed()
        );
    }
    let t = Instant::now();
    let o = path(
        &pool,
        PathQ {
            from: 1,
            to: 99_999,
            kinds: vec![],
            max_depth: 8,
            as_of: None,
        },
        &All,
        Budget::default(),
    )
    .await
    .unwrap();
    println!(
        "path: {} nodes, {:?}, {:?}",
        o.nodes.len(),
        o.truncated,
        t.elapsed()
    );
}
