//! One open notebook as the hub holds it (design §4.1): the file's model (`hrafn::notebook`), what each cell shows (the outputs of
//! its last run, or the file's own, marked stale), and the version of each tail. The buffer owns what the user types; the hub is told
//! the sources when a cell runs and when the buffer is saved.

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};

use hrafn::notebook::{Kind, Notebook};
use serde_json::Value;

use super::output::file::from_nbformat_raw;
use super::output::{CellRun, MAX_OUTPUTS, RunStatus};
use super::tail::{self, Tail};

/// What the buffer says a cell is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CellSync {
    pub id: String,
    pub kind: Kind,
    pub source: String,
}

/// What the hub tells the buffer about a cell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CellInfo {
    pub id: String,
    pub kind: Kind,
    pub source: String,
    pub execution_count: Option<i64>,
}

struct Shown {
    run: CellRun,
    /// From the file, not from a run of this hub.
    stale: bool,
    version: u64,
}

/// The largest notebook file read.
pub const MAX_NOTEBOOK_BYTES: usize = 32 << 20;

pub struct Book {
    pub path: PathBuf,
    nb: Notebook,
    shown: HashMap<String, Shown>,
}

/// An output object as nbformat's writer writes it: multiline text as a list of lines (images stay one string).
fn for_file(mut o: Value) -> Value {
    fn lines(v: &mut Value) {
        if let Value::String(s) = v {
            *v = Value::Array(
                hrafn::notebook::split_lines(s)
                    .into_iter()
                    .map(|l| Value::String(l.to_owned()))
                    .collect(),
            );
        }
    }
    if let Some(t) = o.get_mut("text") {
        lines(t);
    }
    if let Some(Value::Object(d)) = o.get_mut("data") {
        for (k, v) in d.iter_mut() {
            if k.starts_with("text/") || k == "image/svg+xml" {
                lines(v);
            }
        }
    }
    o
}

fn random_id() -> String {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b).expect("the OS random generator");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

impl Book {
    /// The notebook at PATH whose text is TEXT (the file's, read by the caller); ids are minted for cells that lack one.
    pub fn open(path: &Path, text: String) -> Result<Book, String> {
        if text.len() > MAX_NOTEBOOK_BYTES {
            return Err(format!(
                "{}: too large for a notebook ({} MiB; the limit is {} MiB)",
                path.display(),
                text.len() >> 20,
                MAX_NOTEBOOK_BYTES >> 20
            ));
        }
        let nb = Notebook::parse(text, &mut random_id)
            .map_err(|e| format!("{}: not a notebook: {e:?}", path.display()))?;
        let shown = nb
            .cells()
            .iter()
            .enumerate()
            .filter(|(_, c)| c.kind == Kind::Code)
            .map(|(i, c)| {
                // one past the cap, so a cell with more says it was cut
                let outputs = nb
                    .outputs_raw(i, MAX_OUTPUTS + 1)
                    .iter()
                    .filter_map(|r| from_nbformat_raw(r))
                    .collect::<Vec<_>>();
                let mut run = CellRun::from_outputs(&c.id, outputs, RunStatus::Ok);
                run.execution_count = c.execution_count;
                (
                    c.id.clone(),
                    Shown {
                        run,
                        stale: true,
                        version: 1,
                    },
                )
            })
            .collect();
        Ok(Book {
            path: path.to_path_buf(),
            nb,
            shown,
        })
    }

    pub fn cells(&self) -> Vec<CellInfo> {
        self.nb
            .cells()
            .iter()
            .map(|c| CellInfo {
                id: c.id.clone(),
                kind: c.kind,
                source: c.source.clone(),
                execution_count: c.execution_count,
            })
            .collect()
    }

    pub fn kernelspec_name(&self) -> Option<String> {
        self.nb.kernelspec_name()
    }

    pub fn language(&self) -> Option<String> {
        self.nb.language()
    }

    fn index(&self, id: &str) -> Option<usize> {
        self.nb.cells().iter().position(|c| c.id == id)
    }

    /// Make the notebook's cells what the buffer says: removed ones go, moved ones move, new ones come, text and type follow.
    pub fn sync(&mut self, cells: &[CellSync]) {
        // the usual case, the same cells in the same order: one pass, nothing found or moved
        if cells.len() == self.nb.cells().len()
            && cells.iter().zip(self.nb.cells()).all(|(a, b)| a.id == b.id)
        {
            for (i, c) in cells.iter().enumerate() {
                if self.nb.cells()[i].source != c.source {
                    self.nb.set_source(i, &c.source);
                }
                self.nb.set_kind(i, c.kind);
            }
            return;
        }
        let want: std::collections::HashSet<&str> = cells.iter().map(|c| c.id.as_str()).collect();
        for i in (0..self.nb.cells().len()).rev() {
            if !want.contains(self.nb.cells()[i].id.as_str()) {
                let id = self.nb.cells()[i].id.clone();
                self.nb.remove(i);
                self.shown.remove(&id);
            }
        }
        for (at, c) in cells.iter().enumerate() {
            match self.index(&c.id) {
                Some(j) if j == at => {}
                Some(j) => self.nb.move_cell(j, at),
                None => {
                    let mut once = Some(c.id.clone());
                    self.nb.insert(at, c.kind, &c.source, &mut || {
                        once.take().unwrap_or_else(random_id)
                    });
                }
            }
            let i = self.index(&c.id).expect("the cell is there now");
            if self.nb.cells()[i].source != c.source {
                self.nb.set_source(i, &c.source);
            }
            self.nb.set_kind(i, c.kind);
        }
    }

    /// Cell ID shows what RUN has now (its outputs, its state, whether they were cut), with its execution count.
    pub fn show(&mut self, id: &str, run: &CellRun) {
        let Some(i) = self.index(id) else { return };
        if run.execution_count.is_some() {
            self.nb.set_execution_count(i, run.execution_count);
        }
        let version = self.shown.get(id).map_or(0, |s| s.version) + 1;
        self.shown.insert(
            id.to_string(),
            Shown {
                run: run.clone(),
                stale: false,
                version,
            },
        );
    }

    /// The tail of cell ID, and whether it is the file's own (stale).
    pub fn tail(&self, id: &str) -> Option<(Tail, bool)> {
        self.index(id)?;
        Some(match self.shown.get(id) {
            Some(s) => (tail::build(id, &s.run, s.version), s.stale),
            None => (
                tail::build(id, &CellRun::from_outputs(id, [], RunStatus::Ok), 0),
                false,
            ),
        })
    }

    /// The cell's full output as nbformat objects.
    pub fn outputs_of(&self, id: &str) -> Vec<Value> {
        self.shown
            .get(id)
            .map(|s| s.run.to_nbformat())
            .unwrap_or_default()
    }

    /// The file's text as it would be written.
    pub fn render(&mut self) -> String {
        for i in 0..self.nb.cells().len() {
            let c = &self.nb.cells()[i];
            if c.kind != Kind::Code {
                continue;
            }
            if let Some(s) = self.shown.get(&c.id).filter(|s| !s.stale) {
                let objs: Vec<Value> = s.run.to_nbformat().into_iter().map(for_file).collect();
                self.nb.set_outputs(i, &objs);
            }
        }
        self.nb.render()
    }

    /// Write the notebook to its file by a temporary file and a rename.
    pub fn save(&mut self) -> Result<(), String> {
        let text = self.render();
        let dir = self
            .path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let name = self
            .path
            .file_name()
            .ok_or("the notebook has no file name")?;
        let d = rustix::fs::open(
            dir,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(|e| format!("{}: {e}", dir.display()))?;
        let mode = std::fs::metadata(&self.path)
            .map(|m| std::os::unix::fs::PermissionsExt::mode(&m.permissions()) & 0o777)
            .unwrap_or(0o644);
        eitri::write_regular(d.as_fd(), Path::new(name), text.as_bytes(), mode)
            .map_err(|e| format!("{}: {e}", self.path.display()))
    }
}

#[cfg(test)]
mod tests;
