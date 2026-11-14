//! Jupyter notebooks (language packs Task 11, docs/specs/drgnx/2026-11-14-jupyter-tier1-design.md §2): an nbformat 4.x file as
//! cells, read and written **without changing a byte nobody edited**.
//!
//! Re-serialising a parsed value would change bytes (`1e-05` becomes `1e-5`, an integer above 2^53 becomes a float, escapes are
//! normalised, key order is lost), so the notebook keeps the file's text and, for each cell, its byte span in it:
//!
//! - **Untouched**: saved as the original bytes (a notebook nobody edited is not even rewritten).
//! - **Edited**: the `cells` array is spliced: an untouched cell is its span, copied; an edited cell is re-emitted by nbformat's
//!   layout (its writer is `indent=1`, sorted keys, `(",", ": ")`, `ensure_ascii=False`, multiline strings split into lists
//!   of lines) with its **unedited fields' values copied from their raw spans**; an added cell is a new element, a removed one
//!   leaves with its separator.
//! - **Ids** (a 4.5 cell needs one) are minted in memory on load and written only when a saved edit happens, for every cell that
//!   lacks one, with `nbformat_minor` set to 5.
//! - **Outputs** are what the caller set: the hub caps them (a re-run cell's capped output is what is saved).
//!
//! A file that is not a notebook (not JSON, not an object with `cells`, `nbformat` below 4, a cell that is not an object) is a
//! [`NotANotebook`]: the caller opens it as text and never rewrites it.

mod chunker;
mod view;

pub use chunker::chunk;
pub use view::{CellRange, View};

use serde::Deserialize;
use serde_json::Value;
use serde_json::value::RawValue;
use std::ops::Range;

/// Why a file is not a notebook (it is opened as text).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NotANotebook {
    /// Not JSON.
    Json(String),
    /// JSON, but not an object.
    NotAnObject,
    /// No `cells` array, no `nbformat` number, or no `nbformat_minor`.
    Missing(&'static str),
    /// `nbformat` below 4: another format.
    Version(i64),
    /// The cell at this index is not a cell.
    BadCell(usize),
}

impl std::fmt::Display for NotANotebook {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NotANotebook::Json(e) => write!(f, "not JSON: {e}"),
            NotANotebook::NotAnObject => write!(f, "not a JSON object"),
            NotANotebook::Missing(what) => write!(f, "no {what}"),
            NotANotebook::Version(v) => write!(f, "nbformat {v} is not read (4 and later are)"),
            NotANotebook::BadCell(i) => write!(f, "cell {i} is not a cell"),
        }
    }
}

impl std::error::Error for NotANotebook {}

/// A cell's type.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Code,
    Markdown,
    Raw,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Code => "code",
            Kind::Markdown => "markdown",
            Kind::Raw => "raw",
        }
    }
}

/// Where a cell's file text comes from.
#[derive(Clone, Debug)]
enum Origin {
    /// Its bytes in the file: copied as they are.
    Untouched(Range<usize>),
    /// Edited: its members as `(key, JSON text)` in the original's order, the unedited values still their raw spans.
    Changed(Vec<(String, String)>),
    /// Added by an edit: emitted whole.
    New,
}

/// One cell.
#[derive(Clone, Debug)]
pub struct Cell {
    pub id: String,
    /// Whether the file gave the cell this id (a minted one is written by the first saving edit).
    had_id: bool,
    pub kind: Kind,
    pub source: String,
    origin: Origin,
    /// The cell's `outputs` and `execution_count` as the caller set them (code cells), kept for the view.
    pub execution_count: Option<i64>,
}

/// The layout of the file's `cells` array, kept so an added cell looks like its neighbours.
#[derive(Clone, Debug)]
struct Layout {
    /// One level of indent (the whitespace before the first top-level key; one space as nbformat writes).
    unit: String,
    /// After `[`, between elements, before `]`.
    lead: String,
    sep: String,
    trail: String,
}

/// An nbformat 4.x notebook.
#[derive(Clone, Debug)]
pub struct Notebook {
    text: String,
    cells_span: Range<usize>,
    minor: Range<usize>,
    nbformat: i64,
    minor_value: i64,
    layout: Layout,
    cells: Vec<Cell>,
    metadata: Option<String>,
    changed: bool,
}

/// An object as `(key, raw value)` in the file's order.
struct Pairs<'a>(Vec<(String, &'a RawValue)>);

impl<'de: 'a, 'a> Deserialize<'de> for Pairs<'a> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V<'a>(std::marker::PhantomData<&'a ()>);
        impl<'de: 'a, 'a> serde::de::Visitor<'de> for V<'a> {
            type Value = Pairs<'a>;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut m: M,
            ) -> Result<Pairs<'a>, M::Error> {
                let mut out = Vec::new();
                while let Some((k, v)) = m.next_entry::<String, &'de RawValue>()? {
                    out.push((k, v));
                }
                Ok(Pairs(out))
            }
        }
        d.deserialize_map(V(std::marker::PhantomData))
    }
}

/// V with every object's keys in sorted order, as nbformat's writer (`sort_keys=True`) writes them: whatever way the build's
/// `serde_json::Map` orders keys (another crate in the build may turn on `preserve_order`).
fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            Value::Object(
                keys.into_iter()
                    .map(|k| (k.clone(), sorted(&m[k])))
                    .collect(),
            )
        }
        Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// The offset of RAW (a slice of TEXT) in TEXT.
fn offset(text: &str, raw: &str) -> usize {
    raw.as_ptr() as usize - text.as_ptr() as usize
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Source {
    One(String),
    Lines(Vec<String>),
}

#[derive(Deserialize)]
struct Probe {
    cell_type: String,
    #[serde(default)]
    id: Option<String>,
    source: Source,
    #[serde(default)]
    execution_count: Option<i64>,
}

/// Python's `str.splitlines(True)`: break after `\n`, `\r`, `\r\n`, `\x0b`, `\x0c`, `\x1c` to `\x1e`, `\x85`, ` ` and
/// ` `, each line keeping its ending. nbformat splits a multiline string with it; the lines are what `source` holds.
pub fn split_lines(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = s.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        let breaks = matches!(
            c,
            '\n' | '\r'
                | '\x0b'
                | '\x0c'
                | '\x1c'
                | '\x1d'
                | '\x1e'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !breaks {
            continue;
        }
        let mut end = i + c.len_utf8();
        if c == '\r'
            && let Some(&(j, '\n')) = chars.peek()
        {
            chars.next();
            end = j + 1;
        }
        out.push(&s[start..end]);
        start = end;
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

fn to_json(s: &str) -> String {
    serde_json::to_string(s).expect("a string serialises")
}

impl Notebook {
    /// TEXT read as a notebook. A cell without an id gets one from `mint` (in memory: the file is not changed).
    pub fn parse(text: String, mint: &mut dyn FnMut() -> String) -> Result<Notebook, NotANotebook> {
        let top: Pairs = serde_json::from_str(&text).map_err(|e| {
            if e.is_data() {
                NotANotebook::NotAnObject
            } else {
                NotANotebook::Json(e.to_string())
            }
        })?;
        let find = |k: &str| top.0.iter().find(|(key, _)| key == k).map(|(_, v)| *v);
        let nbformat = find("nbformat")
            .and_then(|v| v.get().trim().parse::<i64>().ok())
            .ok_or(NotANotebook::Missing("nbformat"))?;
        if nbformat < 4 {
            return Err(NotANotebook::Version(nbformat));
        }
        let minor_raw = find("nbformat_minor").ok_or(NotANotebook::Missing("nbformat_minor"))?;
        let minor_value = minor_raw
            .get()
            .trim()
            .parse::<i64>()
            .map_err(|_| NotANotebook::Missing("nbformat_minor"))?;
        let minor =
            offset(&text, minor_raw.get())..offset(&text, minor_raw.get()) + minor_raw.get().len();
        let cells_raw = find("cells").ok_or(NotANotebook::Missing("cells"))?;
        let cells_span =
            offset(&text, cells_raw.get())..offset(&text, cells_raw.get()) + cells_raw.get().len();
        let elements: Vec<&RawValue> =
            serde_json::from_str(cells_raw.get()).map_err(|_| NotANotebook::Missing("cells"))?;
        let mut cells = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for (i, el) in elements.iter().enumerate() {
            let probe: Probe =
                serde_json::from_str(el.get()).map_err(|_| NotANotebook::BadCell(i))?;
            let kind = match probe.cell_type.as_str() {
                "code" => Kind::Code,
                "markdown" => Kind::Markdown,
                "raw" => Kind::Raw,
                _ => return Err(NotANotebook::BadCell(i)),
            };
            let source = match probe.source {
                Source::One(s) => s,
                Source::Lines(l) => l.concat(),
            };
            // an id that repeats an earlier one is not the file's: it is minted afresh like a missing one
            let (id, had_id) = match probe.id {
                Some(id) if !id.is_empty() && seen.insert(id.clone()) => (id, true),
                _ => {
                    let mut id = mint();
                    while !seen.insert(id.clone()) {
                        id = mint();
                    }
                    (id, false)
                }
            };
            let from = offset(&text, el.get());
            cells.push(Cell {
                id,
                had_id,
                kind,
                source,
                origin: Origin::Untouched(from..from + el.get().len()),
                execution_count: probe.execution_count,
            });
        }
        // the layout: one indent unit (the whitespace before the first top-level key), and how the array is spaced
        let unit = {
            // the whitespace before the first key of the root object (nbformat writes one space)
            let brace = text.find('{').unwrap_or(0);
            let rest = &text[brace + 1..];
            let quote = rest.find('"').unwrap_or(0);
            let gap = &rest[..quote];
            let ws = gap.rsplit('\n').next().unwrap_or("");
            if gap.contains('\n') && !ws.is_empty() && ws.chars().all(char::is_whitespace) {
                ws.to_owned()
            } else {
                " ".to_owned()
            }
        };
        let (lead, trail) = if cells.is_empty() {
            (format!("\n{unit}{unit}"), format!("\n{unit}"))
        } else {
            let first = match &cells[0].origin {
                Origin::Untouched(r) => r.clone(),
                _ => unreachable!(),
            };
            let last = match &cells[cells.len() - 1].origin {
                Origin::Untouched(r) => r.clone(),
                _ => unreachable!(),
            };
            (
                text[cells_span.start + 1..first.start].to_owned(),
                text[last.end..cells_span.end - 1].to_owned(),
            )
        };
        let sep = if cells.len() > 1 {
            let (a, b) = match (&cells[0].origin, &cells[1].origin) {
                (Origin::Untouched(a), Origin::Untouched(b)) => (a.clone(), b.clone()),
                _ => unreachable!(),
            };
            text[a.end..b.start].to_owned()
        } else {
            format!(
                ",{}",
                if lead.is_empty() {
                    String::new()
                } else {
                    lead.clone()
                }
            )
        };
        let metadata = find("metadata").map(|v| v.get().to_owned());
        Ok(Notebook {
            text,
            cells_span,
            minor,
            nbformat,
            minor_value,
            layout: Layout {
                unit,
                lead,
                sep,
                trail,
            },
            cells,
            metadata,
            changed: false,
        })
    }

    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    /// Whether anything was edited since the notebook was read or last saved.
    pub fn is_changed(&self) -> bool {
        self.changed
    }

    /// Whether some cell had no id in the file: the first saving edit writes ids and moves `nbformat_minor` to 5.
    pub fn needs_ids(&self) -> bool {
        self.cells.iter().any(|c| !c.had_id)
    }

    /// The language the notebook names (`metadata.kernelspec.language`, else `metadata.language_info.name`), lower case.
    pub fn language(&self) -> Option<String> {
        let m: Value = serde_json::from_str(self.metadata.as_deref()?).ok()?;
        m.pointer("/kernelspec/language")
            .or_else(|| m.pointer("/language_info/name"))
            .and_then(Value::as_str)
            .map(str::to_lowercase)
    }

    /// The kernel the notebook names (`metadata.kernelspec.name`).
    pub fn kernelspec_name(&self) -> Option<String> {
        let m: Value = serde_json::from_str(self.metadata.as_deref()?).ok()?;
        m.pointer("/kernelspec/name")
            .and_then(Value::as_str)
            .map(str::to_owned)
    }

    fn pairs_of(&self, i: usize) -> Vec<(String, String)> {
        match &self.cells[i].origin {
            Origin::Changed(p) => p.clone(),
            Origin::Untouched(r) => {
                let pairs: Pairs =
                    serde_json::from_str(&self.text[r.clone()]).unwrap_or(Pairs(vec![]));
                pairs
                    .0
                    .into_iter()
                    .map(|(k, v)| (k, v.get().to_owned()))
                    .collect()
            }
            Origin::New => Vec::new(),
        }
    }

    /// Make cell I editable: its members as pairs.
    fn change(&mut self, i: usize) -> &mut Vec<(String, String)> {
        if !matches!(self.cells[i].origin, Origin::Changed(_)) {
            let pairs = if matches!(self.cells[i].origin, Origin::New) {
                self.new_pairs(i)
            } else {
                self.pairs_of(i)
            };
            self.cells[i].origin = Origin::Changed(pairs);
        }
        self.changed = true;
        match &mut self.cells[i].origin {
            Origin::Changed(p) => p,
            _ => unreachable!(),
        }
    }

    fn new_pairs(&self, i: usize) -> Vec<(String, String)> {
        let c = &self.cells[i];
        let mut p = vec![("cell_type".to_owned(), to_json(c.kind.name()))];
        if c.kind == Kind::Code {
            p.push(("execution_count".into(), "null".into()));
        }
        p.push(("id".into(), to_json(&c.id)));
        p.push(("metadata".into(), "{}".into()));
        if c.kind == Kind::Code {
            p.push(("outputs".into(), "[]".into()));
        }
        p.push(("source".into(), self.source_json(&c.source)));
        p
    }

    fn member_indent(&self) -> String {
        // elements sit at depth 2 (root member, array element); their members one deeper
        self.layout.unit.repeat(3)
    }

    fn source_json(&self, source: &str) -> String {
        let lines = split_lines(source);
        if lines.is_empty() {
            return "[]".to_owned();
        }
        let inner = self.layout.unit.repeat(4);
        let body: Vec<String> = lines
            .iter()
            .map(|l| format!("{inner}{}", to_json(l)))
            .collect();
        format!("[\n{}\n{}]", body.join(",\n"), self.member_indent())
    }

    fn set_pair(pairs: &mut Vec<(String, String)>, key: &str, json: String) {
        if let Some(p) = pairs.iter_mut().find(|(k, _)| k == key) {
            p.1 = json;
        } else {
            // sorted keys, as nbformat writes them: before the first key that sorts after this one
            let at = pairs
                .iter()
                .position(|(k, _)| k.as_str() > key)
                .unwrap_or(pairs.len());
            pairs.insert(at, (key.to_owned(), json));
        }
    }

    /// Cell I's source is now SOURCE.
    pub fn set_source(&mut self, i: usize, source: &str) {
        if self.cells[i].source == source {
            return;
        }
        let json = self.source_json(source);
        self.cells[i].source = source.to_owned();
        Self::set_pair(self.change(i), "source", json);
    }

    /// Cell I's type is now KIND: the members the new type lacks go, the ones it needs come (a code cell has `outputs` and
    /// `execution_count`, the others none).
    pub fn set_kind(&mut self, i: usize, kind: Kind) {
        if self.cells[i].kind == kind {
            return;
        }
        self.cells[i].kind = kind;
        let pairs = self.change(i);
        Self::set_pair(pairs, "cell_type", to_json(kind.name()));
        if kind == Kind::Code {
            Self::set_pair(pairs, "execution_count", "null".into());
            Self::set_pair(pairs, "outputs", "[]".into());
        } else {
            pairs.retain(|(k, _)| k != "outputs" && k != "execution_count");
        }
    }

    /// Cell I's execution count.
    pub fn set_execution_count(&mut self, i: usize, n: Option<i64>) {
        self.cells[i].execution_count = n;
        let json = n.map_or_else(|| "null".to_owned(), |n| n.to_string());
        Self::set_pair(self.change(i), "execution_count", json);
    }

    /// Cell I's outputs are now OUTPUTS (nbformat output objects), written as nbformat writes them: sorted keys, the file's
    /// indent unit. (Floats in a kernel's own JSON are written the way Rust prints them.)
    pub fn set_outputs(&mut self, i: usize, outputs: &[Value]) {
        let json = if outputs.is_empty() {
            "[]".to_owned()
        } else {
            let unit = self.layout.unit.clone();
            let base = self.member_indent();
            let items: Vec<String> = outputs
                .iter()
                .map(|o| {
                    let mut buf = Vec::new();
                    let fmt = serde_json::ser::PrettyFormatter::with_indent(unit.as_bytes());
                    let mut ser = serde_json::Serializer::with_formatter(&mut buf, fmt);
                    serde::Serialize::serialize(&sorted(o), &mut ser).expect("a value serialises");
                    let s = String::from_utf8(buf).expect("JSON is UTF-8");
                    // the item sits one level inside the array: its later lines carry the array's indent plus one unit
                    let pad = format!("{base}{unit}");
                    let body = s.replace('\n', &format!("\n{pad}"));
                    format!("{pad}{body}")
                })
                .collect();
            format!("[\n{}\n{base}]", items.join(",\n"))
        };
        Self::set_pair(self.change(i), "outputs", json);
    }

    /// A new cell of KIND with SOURCE at index AT; its id from MINT.
    pub fn insert(
        &mut self,
        at: usize,
        kind: Kind,
        source: &str,
        mint: &mut dyn FnMut() -> String,
    ) {
        let mut id = mint();
        while self.cells.iter().any(|c| c.id == id) {
            id = mint();
        }
        let cell = Cell {
            id,
            had_id: true,
            kind,
            source: source.to_owned(),
            origin: Origin::New,
            execution_count: None,
        };
        self.cells.insert(at.min(self.cells.len()), cell);
        self.changed = true;
    }

    /// Remove cell I.
    pub fn remove(&mut self, i: usize) {
        self.cells.remove(i);
        self.changed = true;
    }

    /// Move cell FROM to index TO.
    pub fn move_cell(&mut self, from: usize, to: usize) {
        let c = self.cells.remove(from);
        self.cells.insert(to.min(self.cells.len()), c);
        self.changed = true;
    }

    /// The file's text as it is now: the original bytes when nothing was edited, else the splice of §2.
    pub fn render(&self) -> String {
        if !self.changed {
            return self.text.clone();
        }
        let need_ids = self.needs_ids();
        let elem_indent = self.layout.unit.repeat(2);
        let member_indent = self.member_indent();
        let mut elements: Vec<String> = Vec::new();
        for (i, c) in self.cells.iter().enumerate() {
            let element = match &c.origin {
                Origin::Untouched(r) if c.had_id || !need_ids => self.text[r.clone()].to_owned(),
                Origin::Untouched(_) => {
                    let mut p = self.pairs_of(i);
                    if !c.had_id {
                        Self::set_pair(&mut p, "id", to_json(&c.id));
                    }
                    emit(&p, &elem_indent, &member_indent)
                }
                Origin::Changed(p) => {
                    let mut p = p.clone();
                    // a changed cell carries its id: minted ones are written now
                    if !p.iter().any(|(k, _)| k == "id") || !c.had_id {
                        Self::set_pair(&mut p, "id", to_json(&c.id));
                    }
                    emit(&p, &elem_indent, &member_indent)
                }
                Origin::New => emit(&self.new_pairs(i), &elem_indent, &member_indent),
            };
            elements.push(element);
        }
        let array = if elements.is_empty() {
            "[]".to_owned()
        } else {
            format!(
                "[{}{}{}]",
                self.layout.lead,
                elements.join(&self.layout.sep),
                self.layout.trail
            )
        };
        let mut splices: Vec<(Range<usize>, String)> = vec![(self.cells_span.clone(), array)];
        if need_ids && self.nbformat == 4 && self.minor_value < 5 {
            splices.push((self.minor.clone(), "5".to_owned()));
        }
        splices.sort_by_key(|(r, _)| r.start);
        let mut out = String::with_capacity(self.text.len());
        let mut at = 0;
        for (r, s) in splices {
            out.push_str(&self.text[at..r.start]);
            out.push_str(&s);
            at = r.end;
        }
        out.push_str(&self.text[at..]);
        out
    }

    /// The notebook as one text: what the editor's buffer holds ([`View`]).
    pub fn view(&self) -> View {
        View::of(self)
    }
}

/// A cell object from its members, laid out as nbformat lays out a cell at depth 2.
fn emit(pairs: &[(String, String)], elem_indent: &str, member_indent: &str) -> String {
    let body: Vec<String> = pairs
        .iter()
        .map(|(k, v)| format!("{member_indent}{}: {v}", to_json(k)))
        .collect();
    format!("{{\n{}\n{elem_indent}}}", body.join(",\n"))
}

impl Cell {
    /// Whether the file gave this cell its id.
    pub fn had_id(&self) -> bool {
        self.had_id
    }
}
