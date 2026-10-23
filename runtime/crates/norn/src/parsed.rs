//! `graph/put-parsed` and `graph/record` applied in one tx (Task 15a; storage §5.6 door 1, §9 step 3): typed
//! sources, every path a record carries checked against the deny-list, content-hash compare, derived statuses.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 15a removes this line.

use urdr::graph::{Tx, WriteError};

use crate::deny::DenyList;

/// `graph/put-parsed`'s params. Task 15a gives the fields (or makes it runstav's wire type).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PutParsed {}

/// `graph/put-parsed`'s answer `{changed, retired, refused}`. Task 15a gives the fields.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PutAnswer {}

/// Apply one scan's REQ in TX (actor `scan:<root>`, class `system`, tool `scan`).
pub fn put(tx: &mut Tx<'_>, deny: &DenyList, req: PutParsed) -> Result<PutAnswer, WriteError> {
    todo!("Task 15a")
}
