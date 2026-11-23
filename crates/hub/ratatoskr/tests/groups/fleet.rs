//! The fleet rows' binary (`cargo test -p ratatoskr --features fleet --test fleet`): each file is a module, its rows `<file>::<test>`; run in the fake fleet's harness with --test-threads=1 (test/runners/README.md; Cargo.toml).

#[path = "../fleet_keys.rs"]
mod fleet_keys;
#[path = "../fleet_registry.rs"]
mod fleet_registry;
#[path = "../fleet_runners.rs"]
mod fleet_runners;
#[path = "../fleet_sync.rs"]
mod fleet_sync;
#[path = "../term_scope.rs"]
mod term_scope;
