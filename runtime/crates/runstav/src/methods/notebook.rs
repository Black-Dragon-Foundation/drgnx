//! Jupyter notebooks (language packs Task 11b, docs/develop/notebooks.md, hub.md "Notebooks"): `notebook/open` reads a notebook into the hub,
//! the editor's cells are `notebook/sync`ed to it, `notebook/execute` runs some of them in the notebook's kernel and the hub sends what
//! comes back as `notebook-tail` events (the string put after a cell, built whole by the hub), `notebook-status` and
//! `notebook-input-request`. The user's: an agent cannot start a kernel.

use super::{invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The longest path, id or name, in bytes.
pub const NAME_MAX: usize = 4096;
/// The most cells one call carries, and the most bytes of one cell's source.
pub const CELLS_MAX: usize = 10_000;
pub const SOURCE_MAX: usize = 8 << 20;
/// The most bytes of a notebook's text in `notebook/open`, and of an answer to a kernel.
pub const TEXT_MAX: usize = 32 << 20;
pub const VALUE_MAX: usize = 64 << 10;

/// `notebook/open`: the notebook at PATH, from TEXT when the editor's buffer has it (else the file).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookOpen {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// A cell the hub holds: its ID, TYPE (`code`, `markdown`, `raw`), SOURCE and the execution count of its last run.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookCell {
    pub id: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_count: Option<i64>,
}

/// A cell as the editor has it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookCellText {
    pub id: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub source: String,
}

/// `notebook/sync` and `notebook/execute`: the editor's CELLS, in order (the notebook's cells become these); for `execute`, the ones
/// to run, in order, with their text.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookCells {
    pub id: String,
    pub cells: Vec<NotebookCellText>,
}

/// `notebook/save`: write the notebook, first taking the editor's CELLS when given.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookSave {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cells: Option<Vec<NotebookCellText>>,
}

/// A call that names a notebook only (`notebook/shutdown`, `/restart`, `/interrupt`, `/close`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookId {
    pub id: String,
}

/// `notebook/start`: a kernel for notebook ID, KERNEL by name (else the notebook's own, else its language's).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookStart {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kernel: Option<String>,
}

/// `notebook/input`: the VALUE for the kernel's input request REQUEST (the id `notebook-input-request` named).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookInput {
    pub id: String,
    pub request: String,
    pub value: String,
}

/// `notebook/tail` and `notebook/output`: one cell of a notebook.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookCellRef {
    pub id: String,
    pub cell: String,
}

/// `notebook/clear`: CELL's output and execution count, or every code cell's when there is no CELL.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookClear {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell: Option<String>,
}

/// A styled stretch of a tail or a head, in characters; FG and BG are the theme's terminal face roles 0 to 15.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookRun {
    pub start: u32,
    pub end: u32,
    #[serde(default)]
    pub fg: Option<u8>,
    #[serde(default)]
    pub bg: Option<u8>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

/// An image shown in a tail: the character AT stands for it; OUTPUT is the output's index in the cell.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookImage {
    pub at: u32,
    pub output: u32,
    pub mime: String,
    pub width: u32,
    pub height: u32,
}

/// One part of a cell's head: ROLE `run` (the run button; ACTION `run` or `stop`), `count` (`[3]`), `language` or `kind`; TEXT what it
/// says, CHIP the chip it is in (`quiet` or `accent`), for the editor to draw with its chip faces.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookHeadPart {
    pub role: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chip: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
}

/// A cell's head: its parts (run button, count, language or kind), the same as plain TEXT, and STATE (`idle`, `queued`, `running`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookHead {
    pub text: String,
    pub state: String,
    pub parts: Vec<NotebookHeadPart>,
}

/// What goes after a cell (the `notebook-tail` event's data, and `notebook/tail`'s answer): TEXT with its RUNS and IMAGES, at most 20 rows
/// (`more_lines` are left out), the head that goes with it, the cell's execution count, VERSION (counts up with each change) and
/// whether the output is `stale` (the file's own, no kernel ran it in this hub).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookTail {
    pub id: String,
    pub cell: String,
    pub text: String,
    pub version: u64,
    pub stale: bool,
    #[serde(default)]
    pub execution_count: Option<i64>,
    pub head: NotebookHead,
    pub runs: Vec<NotebookRun>,
    pub images: Vec<NotebookImage>,
    pub more_lines: u32,
}

/// `notebook/open`'s answer: the notebook's ID, its CELLS, the kernelspec name and language it names, and the TAILS of the code cells that
/// have output in the file: the first 200 of them within 1 MiB of JSON (a cell without a tail has no output), and how many more there are
/// (`more_tails`: ask `notebook/tail` for the cells it names).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookOpened {
    pub id: String,
    pub cells: Vec<NotebookCell>,
    #[serde(default)]
    pub kernelspec: Option<String>,
    #[serde(default)]
    pub language: Option<String>,
    pub tails: Vec<NotebookTail>,
    pub more_tails: u32,
}

/// An installed kernelspec.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookKernel {
    pub name: String,
    pub display_name: String,
    pub language: String,
    /// `signal` or `message`.
    pub interrupt: String,
}

/// A kernelspec that was found and not used, and why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookSkipped {
    pub name: String,
    pub why: String,
}

/// `notebook/kernels`' answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookKernels {
    pub kernels: Vec<NotebookKernel>,
    pub skipped: Vec<NotebookSkipped>,
}

/// `notebook/start`'s and `/restart`'s answer: the kernelspec started.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookStarted {
    pub kernel: String,
}

/// `notebook/shutdown`'s answer: how the kernel ended.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookEnded {
    #[serde(default)]
    pub code: Option<i32>,
    #[serde(default)]
    pub signal: Option<i32>,
    pub stderr: String,
}

/// What one of a notebook's Sjá views shows (docs/develop/notebooks.md, "The views"): `outline` is one row per cell, `output` the
/// whole output of one cell, `log` what the kernel says that answers no cell.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum NotebookViewKind {
    Outline,
    Output,
    Log,
}

/// `notebook/view`: the hub view of KIND for notebook ID (`output` names the CELL). The answer names the view; the editor then sends `view/env` for it like
/// any hub-fed view and gets its rows as `view-patch` events.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookViewParams {
    pub id: String,
    pub kind: NotebookViewKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell: Option<String>,
}

/// `notebook/view`'s answer: the view's id (at most 64 bytes, what `view/env` and `view/close` name).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookViewName {
    pub view: String,
}

/// `notebook/log`: the kernel's log of notebook ID after entry SINCE (all it holds when none).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookLogParams {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<u64>,
}

/// `notebook/focus`: the editor is in cell CELL of notebook ID (none: in none of its cells, such as in a view of it). The outline marks
/// that cell's row (the property `drgnx-notebook-current`). The editor sends it when the cell changes, not on every move of point.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookFocusParams {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell: Option<String>,
}

/// One entry of a kernel's log: a message that answered no cell (the kernel's own logging, a message from another client). SEQ
/// counts from 1; TYPE is the message type (`stream`, `error`, ...); TEXT is what it says, cut at 4096 characters.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookLogEntry {
    pub seq: u64,
    #[serde(rename = "type")]
    pub ty: String,
    pub text: String,
}

/// `notebook/log`'s answer: the ENTRIES after SINCE (the hub keeps the last 500), NEXT the number to pass as `since` to get what is
/// newer, LOST how many entries after SINCE the hub no longer holds.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookLog {
    pub entries: Vec<NotebookLogEntry>,
    pub next: u64,
    pub lost: u64,
}

/// `notebook/output`'s answer: the cell's whole output as nbformat objects (within the hub's limits).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct NotebookOutput {
    pub outputs: Vec<Value>,
}

fn name(field: &'static str, s: &str) -> Result<(), Error> {
    if s.is_empty() || s.len() > NAME_MAX {
        return Err(invalid(field, "1 to 4096 bytes"));
    }
    Ok(())
}

fn cells(field: &'static str, c: &[NotebookCellText]) -> Result<(), Error> {
    if c.len() > CELLS_MAX {
        return Err(invalid(field, "at most 10000 cells"));
    }
    for cell in c {
        name("cells/id", &cell.id)?;
        if !matches!(cell.ty.as_str(), "code" | "markdown" | "raw") {
            return Err(invalid("cells/type", "code, markdown or raw"));
        }
        if cell.source.len() > SOURCE_MAX {
            return Err(invalid("cells/source", "at most 8 MiB"));
        }
    }
    Ok(())
}

fn check_open(p: &NotebookOpen) -> Result<(), Error> {
    name("path", &p.path)?;
    if p.text.as_ref().is_some_and(|t| t.len() > TEXT_MAX) {
        return Err(invalid("text", "at most 32 MiB"));
    }
    Ok(())
}

fn check_cells(p: &NotebookCells) -> Result<(), Error> {
    name("id", &p.id)?;
    cells("cells", &p.cells)
}

fn check_save(p: &NotebookSave) -> Result<(), Error> {
    name("id", &p.id)?;
    p.cells.as_deref().map_or(Ok(()), |c| cells("cells", c))
}

fn check_id(p: &NotebookId) -> Result<(), Error> {
    name("id", &p.id)
}

fn check_start(p: &NotebookStart) -> Result<(), Error> {
    name("id", &p.id)?;
    p.kernel.as_deref().map_or(Ok(()), |k| name("kernel", k))
}

fn check_input(p: &NotebookInput) -> Result<(), Error> {
    name("id", &p.id)?;
    name("request", &p.request)?;
    if p.value.len() > VALUE_MAX {
        return Err(invalid("value", "at most 64 KiB"));
    }
    Ok(())
}

fn check_cell(p: &NotebookCellRef) -> Result<(), Error> {
    name("id", &p.id)?;
    name("cell", &p.cell)
}

fn check_focus(p: &NotebookFocusParams) -> Result<(), Error> {
    name("id", &p.id)?;
    p.cell.as_deref().map_or(Ok(()), |c| name("cell", c))
}

fn check_log(p: &NotebookLogParams) -> Result<(), Error> {
    name("id", &p.id)
}

fn check_view(p: &NotebookViewParams) -> Result<(), Error> {
    name("id", &p.id)?;
    match (p.kind, p.cell.as_deref()) {
        (NotebookViewKind::Output, Some(c)) => name("cell", c),
        (NotebookViewKind::Output, None) => Err(invalid("cell", "the cell whose output it shows")),
        (NotebookViewKind::Outline | NotebookViewKind::Log, None) => Ok(()),
        (NotebookViewKind::Outline | NotebookViewKind::Log, Some(_)) => {
            Err(invalid("cell", "none for this view"))
        }
    }
}

fn check_clear(p: &NotebookClear) -> Result<(), Error> {
    name("id", &p.id)?;
    p.cell.as_deref().map_or(Ok(()), |c| name("cell", c))
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "notebook/open", NotebookOpen(NotebookOpen) -> NotebookOpened,
            classes: [User], writes: false,
            doc: "open a Jupyter notebook in the hub (from the buffer's text, else the file): its id, cells, kernelspec and each code cell's tail from the file",
            check: check_open,
        ),
        method!(
            "notebook/sync", NotebookSync(NotebookCells) -> bool,
            classes: [User], writes: false,
            doc: "the editor's cells (id, type, source) in order become the notebook's: removed ones go, moved ones move, new ones come",
            check: check_cells,
        ),
        method!(
            "notebook/execute", NotebookExecute(NotebookCells) -> bool,
            classes: [User], writes: false,
            doc: "queue cells (id, type, source, in order) to run in the notebook's kernel: their text becomes the notebook's first; an error aborts the rest, an interrupt or a restart cancels them",
            check: check_cells,
        ),
        method!(
            "notebook/save", NotebookSave(NotebookSave) -> bool,
            classes: [User], writes: false,
            doc: "write the notebook (after taking the editor's cells when given) by a temporary file and a rename; a symbolic link is replaced by a regular file",
            check: check_save,
        ),
        method!(
            "notebook/kernels", NotebookKernels(super::Empty) -> NotebookKernels,
            classes: [User], writes: false,
            doc: "the installed kernelspecs, and the ones found and not used with the reason",
        ),
        method!(
            "notebook/start", NotebookStart(NotebookStart) -> NotebookStarted,
            classes: [User], writes: false,
            doc: "start a kernel for the notebook, unconfined (the user's code as a terminal runs it); refused in a sealed session; ready when it answers kernel_info and publishes a status",
            check: check_start,
        ),
        method!(
            "notebook/restart", NotebookRestart(NotebookId) -> NotebookStarted,
            classes: [User], writes: false,
            doc: "end the notebook's kernel (asked, then its process group killed after the grace), cancel what was queued, and start a new one of the same kernelspec with a new connection and key",
            check: check_id,
        ),
        method!(
            "notebook/shutdown", NotebookShutdown(NotebookId) -> NotebookEnded,
            classes: [User], writes: false,
            doc: "end the notebook's kernel and say how it ended",
            check: check_id,
        ),
        method!(
            "notebook/interrupt", NotebookInterrupt(NotebookId) -> bool,
            classes: [User], writes: false,
            doc: "interrupt the running cell (SIGINT to the kernel's group, or an interrupt_request when its kernelspec says so) and cancel what is queued",
            check: check_id,
        ),
        method!(
            "notebook/input", NotebookInput(NotebookInput) -> bool,
            classes: [User], writes: false,
            doc: "answer a kernel's input request (the id notebook-input-request named)",
            check: check_input,
        ),
        method!(
            "notebook/tail", NotebookTail(NotebookCellRef) -> NotebookTail,
            classes: [User], writes: false,
            doc: "the tail of one cell as the hub holds it (an editor that lost a string asks for it again)",
            check: check_cell,
        ),
        method!(
            "notebook/output", NotebookOutput(NotebookCellRef) -> NotebookOutput,
            classes: [User], writes: false,
            doc: "the whole output of one cell as nbformat objects, within the hub's limits (the inline tail is cut at 20 rows)",
            check: check_cell,
        ),
        method!(
            "notebook/view", NotebookView(NotebookViewParams) -> NotebookViewName,
            classes: [User], writes: false,
            doc: "a hub view of a notebook for the editor to show in Sjá: the cell outline (one row per cell with its index, type, first line, prompt and state) the whole output of one cell (windowed by view/window) or the kernel's log; the answer names the view, rows follow its view/env",
            check: check_view,
        ),
        method!(
            "notebook/focus", NotebookFocus(NotebookFocusParams) -> bool,
            classes: [User], writes: false,
            doc: "the editor is in this cell of the notebook (none: in none): the cell outline marks its row; sent when the cell changes",
            check: check_focus,
        ),
        method!(
            "notebook/log", NotebookLog(NotebookLogParams) -> NotebookLog,
            classes: [User], writes: false,
            doc: "the kernel's log of a notebook after entry `since`: the messages that answered no cell (the kernel's own logging, messages from other clients), the last 500, each cut at 4096 characters",
            check: check_log,
        ),
        method!(
            "notebook/clear", NotebookClear(NotebookClear) -> bool,
            classes: [User], writes: false,
            doc: "clear one cell's output and execution count, or every code cell's; a queued or running cell is left as it is",
            check: check_clear,
        ),
        method!(
            "notebook/close", NotebookClose(NotebookId) -> bool,
            classes: [User], writes: false,
            doc: "forget the notebook (its kernel ends first); unsaved changes are the editor's",
            check: check_id,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use crate::registry::{self, Class};
    use serde_json::json;

    #[test]
    fn every_notebook_method_is_the_users_and_takes_what_it_names() {
        for m in [
            "open",
            "sync",
            "execute",
            "save",
            "kernels",
            "start",
            "restart",
            "shutdown",
            "interrupt",
            "input",
            "tail",
            "output",
            "view",
            "focus",
            "log",
            "clear",
            "close",
        ] {
            let m = registry::find(&format!("notebook/{m}"))
                .unwrap_or_else(|| panic!("notebook/{m} is registered"));
            assert!(
                m.allows(Class::User) && !m.allows(Class::Agent) && !m.writes,
                "{}",
                m.name
            );
        }
        let ok =
            |name: &str, v: serde_json::Value| (registry::find(name).unwrap().decode)(&v).is_ok();
        assert!(ok("notebook/open", json!({"path": "/p/n.ipynb"})));
        assert!(ok(
            "notebook/open",
            json!({"path": "/p/n.ipynb", "text": "{}"})
        ));
        assert!(ok(
            "notebook/sync",
            json!({"id": "nb1", "cells": [{"id": "a", "type": "code", "source": "1"}]})
        ));
        assert!(ok("notebook/save", json!({"id": "nb1"})));
        assert!(ok("notebook/kernels", json!({})));
        assert!(ok(
            "notebook/start",
            json!({"id": "nb1", "kernel": "python3"})
        ));
        assert!(ok(
            "notebook/input",
            json!({"id": "nb1", "request": "r", "value": "x"})
        ));
        assert!(ok("notebook/clear", json!({"id": "nb1"})));
        assert!(ok("notebook/view", json!({"id": "nb1", "kind": "outline"})));
        assert!(ok(
            "notebook/view",
            json!({"id": "nb1", "kind": "output", "cell": "a"})
        ));
        assert!(ok("notebook/view", json!({"id": "nb1", "kind": "log"})));
        assert!(ok("notebook/log", json!({"id": "nb1"})));
        assert!(ok("notebook/focus", json!({"id": "nb1"})));
        assert!(ok("notebook/focus", json!({"id": "nb1", "cell": "a"})));
        assert!(ok("notebook/log", json!({"id": "nb1", "since": 4})));
        assert!(ok("notebook/tail", json!({"id": "nb1", "cell": "a"})));
    }

    #[test]
    fn what_is_wrong_is_refused_with_its_path() {
        let err = |name: &str, v: serde_json::Value| {
            (registry::find(name).unwrap().decode)(&v).err().unwrap()
        };
        assert_eq!(
            err("notebook/open", json!({"path": ""})).path.as_deref(),
            Some("path")
        );
        assert_eq!(
            err(
                "notebook/open",
                json!({"path": "/p", "text": "x".repeat(33 << 20)})
            )
            .path
            .as_deref(),
            Some("text")
        );
        assert_eq!(
            err(
                "notebook/sync",
                json!({"id": "nb1", "cells": [{"id": "a", "type": "chart", "source": ""}]})
            )
            .path
            .as_deref(),
            Some("cells/type")
        );
        assert_eq!(
            err("notebook/execute", json!({"id": "nb1", "cells": [{"id": "a", "type": "code", "source": "x".repeat(9 << 20)}]}))
                .path
                .as_deref(),
            Some("cells/source")
        );
        assert_eq!(
            err(
                "notebook/input",
                json!({"id": "nb1", "request": "r", "value": "x".repeat(70_000)})
            )
            .path
            .as_deref(),
            Some("value")
        );
        assert!(err("notebook/tail", json!({"id": "nb1"})).path.is_some());
        assert!(
            err("notebook/view", json!({"id": "nb1", "kind": "chart"}))
                .path
                .is_some()
        );
        assert!(
            err("notebook/log", json!({"id": "nb1", "since": -1}))
                .path
                .is_some()
        );
        assert_eq!(
            err("notebook/focus", json!({"id": "nb1", "cell": ""}))
                .path
                .as_deref(),
            Some("cell")
        );
        assert_eq!(
            err("notebook/view", json!({"id": "nb1", "kind": "output"}))
                .path
                .as_deref(),
            Some("cell")
        );
        assert_eq!(
            err(
                "notebook/view",
                json!({"id": "nb1", "kind": "outline", "cell": "a"})
            )
            .path
            .as_deref(),
            Some("cell")
        );
        assert!(err("notebook/shutdown", json!({})).path.is_some());
    }
}
