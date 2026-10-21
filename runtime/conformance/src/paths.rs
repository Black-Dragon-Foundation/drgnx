//! Where a hub's data dir and socket are: runstav's rule (`runstav::paths`, pinned by the shared fixture
//! `test/fixtures/hub-socket-cases.json`), so the harness and the hub cannot drift apart.

pub use runstav::paths::*;
