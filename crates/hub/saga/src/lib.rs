//! saga: the org folder's record formats — plans, ledgers, DEFERRED.md, BUILD-BOARD.md and `board.org` — parsed into
//! models, turned into graph operations and rendered back as views, byte-exact (`docs/develop/records.md`).  Pure:
//! no I/O, no store.  Agent system part 1 fills it: Task 5 (`md`, `plan`, `ledger`), Task 6 (`table`, `deferred`,
//! `board_md`, `org`), Task 14 (`import`, `view`); specs and ADRs (`spec`), the links
//! between record files (`links`) and the three-way merge of a view with the graph (`merge`).

pub mod board_md;
pub mod deferred;
pub mod import;
pub mod ledger;
pub mod links;
pub mod md;
pub mod merge;
pub mod org;
pub mod plan;
pub mod spec;
pub mod status;
pub mod table;
pub mod view;
