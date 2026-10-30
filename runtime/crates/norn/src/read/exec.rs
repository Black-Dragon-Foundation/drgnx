//! The exec readers (agent system part 1, Task 4): a job as its entity keeps it.

use crate::store::{CoordError, Tx};
use serde_json::Value;

/// One job.
#[derive(Clone, Debug, PartialEq)]
pub struct Exec {
    pub id: String,
    /// `running`, `done`, `stopped`, `timed-out` or `lost`.
    pub status: String,
    pub starter: Option<String>,
    pub argv: Vec<String>,
    pub cwd: String,
    pub kind: String,
    pub timebox_s: i64,
    pub started: f64,
    pub exit: Option<i32>,
    pub ended: Option<f64>,
    pub summary: Option<Value>,
}

const SELECT: &str =
    "select id, status, data from entity where kind = 'exec' and retired_tx is null";

/// A row's `(id, status, data)` as a job.
type Parts = (String, Option<String>, String);

fn exec((id, status, data): Parts) -> Exec {
    let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
    let text = |k: &str| d[k].as_str().unwrap_or("").to_string();
    Exec {
        id,
        status: status.unwrap_or_default(),
        starter: d["starter"].as_str().map(str::to_string),
        argv: d["argv"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        cwd: text("cwd"),
        kind: text("kind"),
        timebox_s: d["timebox_s"].as_i64().unwrap_or(0),
        started: d["started"].as_f64().unwrap_or(0.0),
        exit: d["exit"].as_i64().and_then(|n| i32::try_from(n).ok()),
        ended: d["ended"].as_f64(),
        summary: d.get("summary").filter(|v| !v.is_null()).cloned(),
    }
}

/// Job ID, or none.
pub fn get(conn: &Tx, id: &str) -> Result<Option<Exec>, CoordError> {
    Ok(
        super::tasks::opt(conn.query_row(&format!("{SELECT} and id = ?1"), [id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        }))?
        .map(exec),
    )
}

/// The jobs with STATUS (none: all), newest first.
pub fn list(conn: &Tx, status: Option<&str>) -> Result<Vec<Exec>, CoordError> {
    let mut st = conn.prepare(&format!(
        "{SELECT} and (?1 is null or status = ?1) order by n desc"
    ))?;
    let rows = st.query_map([status], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
    Ok(rows
        .collect::<Result<Vec<Parts>, _>>()?
        .into_iter()
        .map(exec)
        .collect())
}
