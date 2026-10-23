//! `graph/sql`'s runner (Task 6; storage §6.6, call 14): a dedicated `mode=ro` connection per call with an authorizer
//! that allows only select, read and functions (never `load_extension` or `fts3_tokenizer`), lowered limits, one
//! statement, a deadline and a row cap.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 6 removes this line.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::pool::ReadPool;

/// A result: column names and rows of JSON values (a blob is `{"blob": LEN}`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rows {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

/// Why a statement was not run (or stopped).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SqlRefusal {
    /// The authorizer's action (`attach`, `pragma`, `insert`, `recursive`, the function name, …).
    NotAllowed(String),
    Deadline,
    TooManyStatements,
    Sql(String),
}

/// Run SQL with PARAMS against POOL's file on its own read-only connection.
pub async fn run(
    pool: &ReadPool,
    sql: String,
    params: Vec<Value>,
    deadline: Duration,
    row_cap: usize,
) -> Result<Rows, SqlRefusal> {
    todo!("Task 6")
}
