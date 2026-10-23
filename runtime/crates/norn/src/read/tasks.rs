//! The tasks readers (Task 6): `drgnx-coord-tasks`, `drgnx-coord-task` and the private row helpers of
//! `core/drgnx-coord.el`.

use crate::store::{CoordError, Tx};

/// `Ok(None)` for "no such row", every other SQLite error as it is.
pub(crate) fn opt<T>(r: Result<T, urdr::SqliteError>) -> Result<Option<T>, CoordError> {
    match r {
        Ok(v) => Ok(Some(v)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// One `jtask` row without its dependencies (`drgnx-coord--task-row`).
#[derive(Debug, Clone, PartialEq)]
pub struct TaskRow {
    pub id: String,
    pub n: i64,
    pub title: Option<String>,
    pub role: Option<String>,
    pub status: Option<String>,
    /// The holder.
    pub agent: Option<String>,
    pub lease_until: Option<f64>,
}

/// A task with its dependencies (`drgnx-coord--task-plist`).
#[derive(Debug, Clone, PartialEq)]
pub struct Task {
    pub row: TaskRow,
    pub deps: Vec<String>,
}

const COLS: &str = "id, n, title, role, status, agent, lease_until";

/// The row closure for [`COLS`] (a macro: `urdr` does not export SQLite's row type).
macro_rules! from_row {
    () => {
        |r| {
            Ok(TaskRow {
                id: r.get(0)?,
                n: r.get(1)?,
                title: r.get(2)?,
                role: r.get(3)?,
                status: r.get(4)?,
                agent: r.get(5)?,
                lease_until: r.get(6)?,
            })
        }
    };
}

/// The row of TASK, or `None`.
pub fn task_row(conn: &Tx, task: &str) -> Result<Option<TaskRow>, CoordError> {
    opt(conn.query_row(
        &format!("select {COLS} from jtask where id = ?1"),
        [task],
        from_row!(),
    ))
}

/// TASK's dependencies, ordered by id (`drgnx-coord--deps`).
pub fn deps(conn: &Tx, task: &str) -> Result<Vec<String>, CoordError> {
    let mut st = conn.prepare("select dep from jdep where task = ?1 order by dep")?;
    let rows = st.query_map([task], |r| r.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// JOB's tasks, in order (`drgnx-coord-tasks`).
pub fn tasks(conn: &Tx, job: &str) -> Result<Vec<Task>, CoordError> {
    let rows: Vec<TaskRow> = {
        let mut st = conn.prepare(&format!(
            "select {COLS} from jtask where job = ?1 order by n"
        ))?;
        let rows = st.query_map([job], from_row!())?;
        rows.collect::<Result<_, _>>()?
    };
    rows.into_iter()
        .map(|row| {
            let deps = deps(conn, &row.id)?;
            Ok(Task { row, deps })
        })
        .collect()
}

/// TASK with its dependencies, or `None` (`drgnx-coord-task`).
pub fn task(conn: &Tx, task: &str) -> Result<Option<Task>, CoordError> {
    match task_row(conn, task)? {
        None => Ok(None),
        Some(row) => {
            let deps = deps(conn, &row.id)?;
            Ok(Some(Task { row, deps }))
        }
    }
}

/// TASK's job (`drgnx-coord--task-job`).
pub fn task_job(conn: &Tx, task: &str) -> Result<Option<String>, CoordError> {
    Ok(opt(conn.query_row(
        "select job from jtask where id = ?1",
        [task],
        |r| r.get::<_, Option<String>>(0),
    ))?
    .flatten())
}

/// TASK as "ID title", or `None` when there is no such task (`drgnx-coord--task-label`; a missing title prints as
/// Lisp prints nil).
pub fn label(conn: &Tx, task: &str) -> Result<Option<String>, CoordError> {
    Ok(task_row(conn, task)?.map(|r| format!("{} {}", r.id, r.title.as_deref().unwrap_or("nil"))))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    #[test]
    fn tasks_come_in_order_with_their_deps() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute_batch(
            "insert into jtask (id, job, n, title, status) values ('j#2', 'j', 2, 'two', 'pending');
             insert into jtask (id, job, n, title, status) values ('j#1', 'j', 1, 'one', 'ready');
             insert into jdep values ('j#2', 'j#1');",
        )
        .unwrap();
        let ts = tasks(&c, "j").unwrap();
        assert_eq!(
            ts.iter().map(|t| t.row.id.as_str()).collect::<Vec<_>>(),
            ["j#1", "j#2"]
        );
        assert_eq!(ts[1].deps, ["j#1"]);
        assert_eq!(label(&c, "j#2").unwrap().as_deref(), Some("j#2 two"));
        assert_eq!(task(&c, "nope").unwrap(), None);
        assert_eq!(task_job(&c, "j#1").unwrap().as_deref(), Some("j"));
    }
}
