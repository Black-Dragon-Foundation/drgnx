//! Schema 7's graph tables as data (Task 2; storage §5.2 exactly, plus `tx.answer` (call 3) and `entity_vec.model`
//! (Task 0's ruling: `search::vec_stale` lists entities without a vector of a model)).

/// The graph tables and their indexes: `tx`, `entity`, `entity_hist`, `link`, `link_stat`, `entity_fts`
/// (contentless, with delete, `secure-delete` set at creation), `entity_vec`, `project_alias`, `excise_log`.
/// Task 2 writes it.
pub const GRAPH_DDL: &str = "";

/// A current link's `tx_to`: 2^62.
pub const SENTINEL: i64 = 1 << 62;
