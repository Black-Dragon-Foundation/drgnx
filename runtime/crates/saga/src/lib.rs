//! saga: the org folder's record formats — plans, ledgers, DEFERRED.md, BUILD-BOARD.md and `board.org` — parsed into
//! models, turned into graph operations and rendered back as views, byte-exact (`docs/develop/records.md`).  Pure:
//! no I/O, no store.  Agent system part 1 fills it: Task 5 (`md`, `plan`, `ledger`), Task 6 (`table`, `deferred`,
//! `board_md`, `org`), Task 14 (`import`, `view`), Task 14b (`proposal`).

pub mod board_md;
pub mod deferred;
pub mod import;
pub mod ledger;
pub mod md;
pub mod org;
pub mod plan;
pub mod table;
pub mod view;
