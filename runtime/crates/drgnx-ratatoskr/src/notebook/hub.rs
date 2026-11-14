//! The notebooks the hub holds open for an editor, and their kernels (design §4.1, §5.4): `open` reads a file into a [`Book`], `start`
//! starts a kernel for it (never in a sealed session), `execute` queues cells, and a task per kernel (the pump) files what the kernel
//! says under the cell it answers and sends the editor each cell's tail (`notebook-tail`), the state (`notebook-status`) and a kernel's
//! question (`notebook-input-request`).
//!
//! A notebook belongs to the connection that opened it: every call names the connection, and a notebook is no one else's; it ends with
//! the connection, and its kernel with it. What is sent to the editor can be dropped (the editor is told the latest state at the next
//! chance): at most [`TAILS_PER_SEC`] tails a second for a notebook, none while the editor's queue is backed up, and a gone editor
//! ends the pump.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::book::{Book, CellInfo, CellSync, MAX_NOTEBOOK_BYTES};
use super::kernel::{Exit, Kernel, KernelEvent, Timeouts, refuse_when_sealed};
use super::output::terminal::{Run, clean};
use super::output::{Router, RunStatus};
use super::session::Channel;
use super::spec::{Choice, Kernelspec, Skipped, choose, discover, discover_with_skips};
use super::tail::{self, Head, Tail};
use super::wire::Message;
use crate::agents::lock::LaunchPlan;
use crate::debug::{Delivery, Sink};

/// The least time between two tails of one cell.
pub const TAIL_EVERY: Duration = Duration::from_millis(50);
/// The most tails sent for one notebook in a second (what is over waits for the next window).
pub const TAILS_PER_SEC: usize = 100;
/// How often a running cell's output is copied into the notebook (what a save or an output request sees).
pub const SHOW_EVERY: Duration = Duration::from_secs(1);
/// The most notebooks one connection holds open.
pub const MAX_OPEN: usize = 32;
/// What `open` puts in its answer: tails for at most this many cells that have output, within this many bytes of JSON; the others
/// come through `notebook/tail` (the answer says how many).
pub const OPEN_TAILS_MAX: usize = 200;
pub const OPEN_TAILS_BYTES: usize = 1 << 20;
/// The most bytes of cell sources `open` answers with.
pub const OPEN_SOURCE_BYTES: usize = 8 << 20;
/// The longest prompt of an input request that reaches the editor, in characters.
pub const PROMPT_CHARS: usize = 1024;

/// What the editor gets when it opens a notebook.
#[derive(Clone, Debug)]
pub struct Opened {
    pub id: String,
    pub cells: Vec<CellInfo>,
    pub kernelspec: Option<String>,
    pub language: Option<String>,
    /// The tail of each code cell that has output in the file (stale: no kernel has run it in this hub), as the editor gets a tail: the
    /// first [`OPEN_TAILS_MAX`] of them within [`OPEN_TAILS_BYTES`]. A cell without a tail has no output.
    pub tails: Vec<Value>,
    /// How many cells with output have no tail here (ask `notebook/tail`).
    pub more_tails: usize,
}

enum Cmd {
    Execute(Vec<String>),
    Interrupt,
    Input { request: String, value: String },
    Shutdown(oneshot::Sender<Exit>),
}

struct Running {
    name: String,
    cmds: mpsc::Sender<Cmd>,
    /// Which start this is: a pump that ends clears the slot only if it is still its own.
    epoch: u64,
}

/// A notebook's kernel: none, being started (reserved, so a second start is refused) or running.
enum Slot {
    Empty,
    Starting,
    Running(Running),
}

struct Open {
    id: String,
    conn: u64,
    book: tokio::sync::Mutex<Book>,
    kernel: Mutex<Slot>,
    starts: AtomicU64,
    /// Cells that are queued or running (the others are idle): what their heads show.
    states: Mutex<HashMap<String, &'static str>>,
    /// The latest tail event of each cell that is queued or running (the book has the output as of the last copy).
    live: Mutex<HashMap<String, Value>>,
    /// What the kernel's task holds of runs that are not over (requests, cells, latest): none when nothing runs.
    held: std::sync::atomic::AtomicUsize,
    /// What the kernel said that answered no cell (the Sjá log view).
    log: Mutex<super::views::KernelLog>,
}

impl Open {
    fn state_of(&self, cell: &str) -> &'static str {
        self.states
            .lock()
            .expect("states")
            .get(cell)
            .copied()
            .unwrap_or("idle")
    }

    fn set_state(&self, cell: &str, state: Option<&'static str>) {
        let mut s = self.states.lock().expect("states");
        match state {
            Some(st) => s.insert(cell.to_string(), st),
            None => s.remove(cell),
        };
    }

    /// The head of CELL as it is now.
    fn head_of(&self, book: &Book, cell: &str, count: Option<i64>) -> Option<Head> {
        let (kind, _) = book.cell_head(cell)?;
        Some(tail::head(
            kind,
            &book.language().unwrap_or_default(),
            count,
            self.state_of(cell),
        ))
    }

    /// The tail event of CELL from what the book holds.
    fn tail_event(&self, book: &Book, cell: &str) -> Option<Value> {
        let (t, stale) = book.tail(cell)?;
        let head = self.head_of(book, cell, t.execution_count)?;
        Some(tail_json(&self.id, &t, stale, &head))
    }

    /// The tail event a caller asks for: the latest sent while the cell is queued or running, else the book's.
    fn tail_now(&self, book: &Book, cell: &str) -> Option<Value> {
        if self.state_of(cell) != "idle"
            && let Some(v) = self.live.lock().expect("live").get(cell)
        {
            return Some(v.clone());
        }
        self.tail_event(book, cell)
    }
}

pub struct Notebooks {
    sink: Arc<dyn Sink>,
    /// The session's private folder (connection files and sockets).
    folder: PathBuf,
    kernel_dirs: Vec<PathBuf>,
    timeouts: Timeouts,
    books: Mutex<HashMap<String, Arc<Open>>>,
    /// Notebooks being opened, by connection: counted with the open ones against [`MAX_OPEN`] from the moment the call starts.
    reserved: Mutex<HashMap<u64, usize>>,
    epochs: AtomicU64,
}

fn style_json(r: &Run) -> Value {
    let s = r.style;
    json!({"start": r.start, "end": r.end, "fg": s.fg, "bg": s.bg,
           "bold": s.bold, "italic": s.italic, "underline": s.underline, "inverse": s.inverse})
}

/// A tail as the editor gets it.
pub fn tail_json(id: &str, t: &Tail, stale: bool, head: &Head) -> Value {
    json!({
        "id": id, "cell": t.cell, "text": t.text, "version": t.version, "stale": stale,
        "execution_count": t.execution_count,
        "head": {"text": head.text, "state": head.state, "runs": head.runs.iter().map(style_json).collect::<Vec<_>>()},
        "runs": t.runs.iter().map(style_json).collect::<Vec<_>>(),
        "images": t.images.iter().map(|i| json!({"at": i.at, "output": i.output, "mime": i.mime,
                                                  "width": i.width, "height": i.height})).collect::<Vec<_>>(),
        "more_lines": t.more_lines,
    })
}

/// A notebook's id: not a count, so another connection cannot guess it.
fn new_id() -> String {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("the OS random generator");
    format!(
        "nb{}",
        b.iter().map(|x| format!("{x:02x}")).collect::<String>()
    )
}

/// The notebook file at PATH as text: a regular file (opened without waiting, so a FIFO is refused, and looked at after it is open), read
/// at most [`MAX_NOTEBOOK_BYTES`].
pub(crate) fn read_notebook(path: &Path) -> Result<String, String> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let shown = path.display();
    let f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| format!("{shown}: {e}"))?;
    let meta = f.metadata().map_err(|e| format!("{shown}: {e}"))?;
    if !meta.is_file() {
        return Err(format!("{shown}: not a regular file"));
    }
    let mut bytes = Vec::new();
    f.take(MAX_NOTEBOOK_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("{shown}: {e}"))?;
    if bytes.len() > MAX_NOTEBOOK_BYTES {
        return Err(format!(
            "{shown}: too large for a notebook (the limit is {} MiB)",
            MAX_NOTEBOOK_BYTES >> 20
        ));
    }
    String::from_utf8(bytes).map_err(|_| format!("{shown}: not UTF-8 text"))
}

/// A place reserved for a notebook being opened: given back when the call ends without having opened it.
struct Place<'a>(&'a Notebooks, Option<u64>);

impl Place<'_> {
    /// The notebook is in the books: the place is no longer held (called with the books lock held).
    fn commit(&mut self) {
        if let Some(conn) = self.1.take() {
            Self::release(self.0, conn);
        }
    }

    fn release(nb: &Notebooks, conn: u64) {
        let mut r = nb.reserved.lock().expect("reserved");
        if let Some(n) = r.get_mut(&conn) {
            *n -= 1;
            if *n == 0 {
                r.remove(&conn);
            }
        }
    }
}

impl Drop for Place<'_> {
    fn drop(&mut self) {
        if let Some(conn) = self.1.take() {
            Self::release(self.0, conn);
        }
    }
}

/// Clears the reservation of a kernel's slot if a start ends without handing the kernel over (an error, or the call dropped).
struct Reserved<'a>(&'a Open, bool);

impl Drop for Reserved<'_> {
    fn drop(&mut self) {
        if self.1 {
            let mut k = self.0.kernel.lock().expect("kernel");
            if matches!(*k, Slot::Starting) {
                *k = Slot::Empty;
            }
        }
    }
}

impl Notebooks {
    pub fn new(
        sink: Arc<dyn Sink>,
        folder: PathBuf,
        kernel_dirs: Vec<PathBuf>,
        timeouts: Timeouts,
    ) -> Notebooks {
        Notebooks {
            sink,
            folder,
            kernel_dirs,
            timeouts,
            books: Mutex::new(HashMap::new()),
            reserved: Mutex::new(HashMap::new()),
            epochs: AtomicU64::new(1),
        }
    }

    /// Notebook ID if it is CONN's: any other is "no open notebook" (an id says nothing to a connection it is not).
    fn get(&self, conn: u64, id: &str) -> Result<Arc<Open>, String> {
        self.books
            .lock()
            .expect("books")
            .get(id)
            .filter(|o| o.conn == conn)
            .cloned()
            .ok_or_else(|| format!("no open notebook {id}"))
    }

    /// The installed kernelspecs.
    pub fn kernels(&self) -> Vec<Kernelspec> {
        discover(&self.kernel_dirs)
    }

    /// The installed kernelspecs and the ones that were found and not used, with why (logged too).
    pub fn kernels_with_skips(&self) -> (Vec<Kernelspec>, Vec<Skipped>) {
        let (specs, skipped) = discover_with_skips(&self.kernel_dirs);
        for k in &skipped {
            tracing::info!(target: "drgnx::notebook", "kernelspec {} not used: {}", k.name, k.why);
        }
        (specs, skipped)
    }

    /// Open the notebook at PATH (a `.ipynb` file) for the editor on CONN; TEXT is the buffer's text when it has one, else the file is read.
    pub async fn open(
        &self,
        conn: u64,
        path: &Path,
        text: Option<String>,
    ) -> Result<Opened, String> {
        if !path
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("ipynb"))
        {
            return Err(format!("{}: not a .ipynb file", path.display()));
        }
        // a place is taken under the books lock before anything is awaited: concurrent opens cannot pass the limit together
        let mut place = {
            let books = self.books.lock().expect("books");
            let mut reserved = self.reserved.lock().expect("reserved");
            let held = books.values().filter(|o| o.conn == conn).count()
                + reserved.get(&conn).copied().unwrap_or(0);
            if held >= MAX_OPEN {
                return Err(format!("{MAX_OPEN} notebooks are open: close one first"));
            }
            *reserved.entry(conn).or_default() += 1;
            Place(self, Some(conn))
        };
        let text = match text {
            Some(t) => t,
            None => {
                let p = path.to_path_buf();
                crate::clock::blocking(move || read_notebook(&p))
                    .await
                    .map_err(|e| e.to_string())??
            }
        };
        let book = Book::open(path, text)?;
        let id = new_id();
        let (cells, kernelspec, language) = (book.cells(), book.kernelspec_name(), book.language());
        if cells.iter().map(|c| c.source.len()).sum::<usize>() > OPEN_SOURCE_BYTES {
            return Err(format!(
                "{}: more than {} MiB of cell sources",
                path.display(),
                OPEN_SOURCE_BYTES >> 20
            ));
        }
        let open = Arc::new(Open {
            id: id.clone(),
            conn,
            book: tokio::sync::Mutex::new(book),
            kernel: Mutex::new(Slot::Empty),
            starts: AtomicU64::new(1),
            states: Mutex::new(HashMap::new()),
            live: Mutex::new(HashMap::new()),
            held: std::sync::atomic::AtomicUsize::new(0),
            log: Mutex::new(super::views::KernelLog::default()),
        });
        let (tails, more_tails) = {
            let book = open.book.lock().await;
            let (mut tails, mut more, mut bytes) = (Vec::new(), 0, 0);
            for c in cells
                .iter()
                .filter(|c| c.kind == hrafn::notebook::Kind::Code)
            {
                let Some((t, _)) = book.tail(&c.id) else {
                    continue;
                };
                if t.text.is_empty() && t.images.is_empty() {
                    continue;
                }
                if tails.len() >= OPEN_TAILS_MAX || bytes >= OPEN_TAILS_BYTES {
                    more += 1;
                } else if let Some(ev) = open.tail_event(&book, &c.id) {
                    bytes += ev.to_string().len();
                    tails.push(ev);
                }
            }
            (tails, more)
        };
        let opened = Opened {
            id: id.clone(),
            cells,
            kernelspec,
            language,
            tails,
            more_tails,
        };
        {
            // the open notebook takes the place the reservation held, in one step
            let mut books = self.books.lock().expect("books");
            books.insert(id, open);
            place.commit();
        }
        Ok(opened)
    }

    /// The editor's cells (their text and types) are the notebook's.
    pub async fn sync(&self, conn: u64, id: &str, cells: &[CellSync]) -> Result<(), String> {
        self.get(conn, id)?.book.lock().await.sync(cells);
        Ok(())
    }

    /// Write the notebook (after taking the editor's cells, when given).
    pub async fn save(
        &self,
        conn: u64,
        id: &str,
        cells: Option<&[CellSync]>,
    ) -> Result<(), String> {
        let open = self.get(conn, id)?;
        let mut book = open.book.lock().await;
        if let Some(c) = cells {
            book.sync(c);
        }
        book.save()
    }

    /// The tail of one cell, from what the hub holds.
    pub async fn tail(&self, conn: u64, id: &str, cell: &str) -> Result<Value, String> {
        let open = self.get(conn, id)?;
        let book = open.book.lock().await;
        open.tail_now(&book, cell)
            .ok_or_else(|| format!("no cell {cell}"))
    }

    /// CELL (or every code cell) has no output and no execution count; a cell that is queued or running is left as it is.
    pub async fn clear(&self, conn: u64, id: &str, cell: Option<&str>) -> Result<(), String> {
        let open = self.get(conn, id)?;
        let mut book = open.book.lock().await;
        let targets: Vec<String> = match cell {
            Some(c) => vec![c.to_string()],
            None => book
                .cells()
                .into_iter()
                .filter(|c| c.kind == hrafn::notebook::Kind::Code)
                .map(|c| c.id)
                .collect(),
        };
        for c in targets {
            if book.cell_head(&c).is_none() {
                return Err(format!("no cell {c}"));
            }
            if open.state_of(&c) != "idle" {
                continue;
            }
            book.clear(&c);
            book.next_version(&c);
            if let Some(v) = open.tail_event(&book, &c) {
                self.sink.send_lossy(open.conn, "notebook-tail", v);
            }
        }
        Ok(())
    }

    /// The full output of one cell as nbformat objects.
    pub async fn output(&self, conn: u64, id: &str, cell: &str) -> Result<Vec<Value>, String> {
        Ok(self.get(conn, id)?.book.lock().await.outputs_of(cell))
    }

    /// Start a kernel for notebook ID: KERNEL by name, else the notebook's own, else its language's; a sealed session (PLAN enforced)
    /// is refused. Returns the kernelspec's name. The slot is reserved before anything is started: a second start is refused.
    pub async fn start(
        &self,
        conn: u64,
        id: &str,
        kernel: Option<&str>,
        plan: Option<&LaunchPlan>,
    ) -> Result<String, String> {
        if let Some(p) = plan {
            refuse_when_sealed(p).map_err(|r| r.0.to_string())?;
        }
        let open = self.get(conn, id)?;
        {
            let mut slot = open.kernel.lock().expect("kernel");
            if !matches!(*slot, Slot::Empty) {
                return Err("this notebook already has a kernel (or one is starting)".into());
            }
            *slot = Slot::Starting;
        }
        let _reserved = Reserved(&open, true);
        let specs = self.kernels();
        let (name, lang, cwd) = {
            let b = open.book.lock().await;
            (
                kernel.map(String::from).or_else(|| b.kernelspec_name()),
                b.language(),
                b.path
                    .parent()
                    .map(Path::to_path_buf)
                    .unwrap_or_else(|| PathBuf::from(".")),
            )
        };
        let spec = match choose(&specs, name.as_deref(), lang.as_deref()) {
            Choice::Found(s) => s,
            Choice::Ask(names) => return Err(format!("several kernels fit: {}", names.join(", "))),
            Choice::Missing => {
                return Err(format!("no kernel {}", name.or(lang).unwrap_or_default()));
            }
        };
        let conn_id = format!(
            "{}-k{}",
            open.id,
            open.starts.fetch_add(1, Ordering::SeqCst)
        );
        self.status(&open, "starting", None, 0);
        let k = Kernel::start(&spec, &self.folder, &conn_id, &cwd, self.timeouts)
            .await
            .inspect_err(|_| self.status(&open, "dead", None, 0))?;
        // the notebook may have been closed (or its editor gone) while the kernel started: then the kernel is not wanted
        let registered = self
            .books
            .lock()
            .expect("books")
            .get(id)
            .is_some_and(|o| Arc::ptr_eq(o, &open));
        if !registered {
            let _ = k.shutdown().await;
            return Err("the notebook was closed while its kernel started".into());
        }
        let (tx, rx) = mpsc::channel(64);
        let epoch = self.epochs.fetch_add(1, Ordering::SeqCst);
        *open.kernel.lock().expect("kernel") = Slot::Running(Running {
            name: spec.name.clone(),
            cmds: tx,
            epoch,
        });
        let pump = Pump::new(open.clone(), k, self.sink.clone(), epoch);
        crate::clock::spawn("notebook-pump", pump.run(rx));
        Ok(spec.name)
    }

    fn status(&self, open: &Open, state: &str, cell: Option<&str>, queue: usize) {
        send_status(&*self.sink, open, state, cell, queue);
    }

    async fn command(&self, conn: u64, id: &str, cmd: Cmd) -> Result<(), String> {
        let open = self.get(conn, id)?;
        let tx = match &*open.kernel.lock().expect("kernel") {
            Slot::Running(r) => r.cmds.clone(),
            _ => return Err("this notebook has no kernel".into()),
        };
        tx.send(cmd)
            .await
            .map_err(|_| "the kernel has ended".to_string())
    }

    /// Queue CELLS (id and source, in order) to run: their text becomes the notebook's first.
    pub async fn execute(&self, conn: u64, id: &str, cells: &[CellSync]) -> Result<(), String> {
        let open = self.get(conn, id)?;
        let ids: Vec<String> = {
            let mut book = open.book.lock().await;
            book.update(cells);
            // only code cells the notebook has: any other id is nothing to run
            cells
                .iter()
                .filter(|c| {
                    book.cell_head(&c.id)
                        .is_some_and(|(k, _)| k == hrafn::notebook::Kind::Code)
                })
                .map(|c| c.id.clone())
                .collect()
        };
        self.command(conn, id, Cmd::Execute(ids)).await
    }

    pub async fn interrupt(&self, conn: u64, id: &str) -> Result<(), String> {
        self.command(conn, id, Cmd::Interrupt).await
    }

    /// The answer to a kernel's `input_request` (REQUEST is the id the event named).
    pub async fn input(
        &self,
        conn: u64,
        id: &str,
        request: &str,
        value: &str,
    ) -> Result<(), String> {
        self.command(
            conn,
            id,
            Cmd::Input {
                request: request.into(),
                value: value.into(),
            },
        )
        .await
    }

    /// End the notebook's kernel; how it ended.
    pub async fn shutdown(&self, conn: u64, id: &str) -> Result<Exit, String> {
        let open = self.get(conn, id)?;
        end_kernel(&open).await
    }

    /// A new kernel of the same kind for notebook ID: the old one is asked to shut down (its group killed after the grace), what was queued
    /// is cancelled, and a new process starts with a new connection file and key. The kernel's name.
    pub async fn restart(&self, conn: u64, id: &str) -> Result<String, String> {
        let name = self
            .kernel_name(conn, id)
            .ok_or("this notebook has no kernel")?;
        self.shutdown(conn, id).await?;
        self.start(conn, id, Some(&name), None).await
    }

    /// Forget notebook ID (its kernel ends first).
    pub async fn close(&self, conn: u64, id: &str) {
        if let Ok(open) = self.get(conn, id) {
            let _ = end_kernel(&open).await;
            self.books.lock().expect("books").remove(id);
        }
    }

    /// The connection CONN is gone: its notebooks close and their kernels end.
    pub async fn gone(&self, conn: u64) {
        let opens: Vec<Arc<Open>> = {
            let mut books = self.books.lock().expect("books");
            let ids: Vec<String> = books
                .iter()
                .filter(|(_, o)| o.conn == conn)
                .map(|(k, _)| k.clone())
                .collect();
            ids.iter().filter_map(|k| books.remove(k)).collect()
        };
        for open in opens {
            let _ = end_kernel(&open).await;
        }
    }

    /// The kernel's log of notebook ID after entry SINCE: the entries, the number to ask the next after, and how many after SINCE are no
    /// longer held.
    pub fn kernel_log(
        &self,
        conn: u64,
        id: &str,
        since: u64,
    ) -> Result<(Vec<super::views::LogEntry>, u64, u64), String> {
        let open = self.get(conn, id)?;
        let log = open.log.lock().expect("log");
        let (entries, lost) = log.since(since);
        Ok((entries, log.last_seq(), lost))
    }

    /// Whether notebook ID is CONN's.
    pub fn owns(&self, conn: u64, id: &str) -> bool {
        self.get(conn, id).is_ok()
    }

    /// The first LIMIT cells of notebook ID for its outline, and how many cells there are.
    pub async fn outline(
        &self,
        conn: u64,
        id: &str,
        limit: usize,
    ) -> Result<(usize, Vec<super::views::OutlineCell>), String> {
        let open = self.get(conn, id)?;
        let book = open.book.lock().await;
        let (total, mut cells) = book.outline(limit);
        for c in &mut cells {
            match open.state_of(&c.id) {
                "queued" => c.state = "queued",
                "running" => c.state = "running",
                _ => {}
            }
        }
        Ok((total, cells))
    }

    /// Cell CELL of notebook ID as a run (what its full-output view shows).
    pub async fn run_of(
        &self,
        conn: u64,
        id: &str,
        cell: &str,
    ) -> Result<super::output::CellRun, String> {
        let open = self.get(conn, id)?;
        let book = open.book.lock().await;
        book.run_of(cell).ok_or_else(|| format!("no cell {cell}"))
    }

    /// How many runs the notebook's kernel task still holds (none when nothing is queued or running).
    pub fn held_runs(&self, conn: u64, id: &str) -> Option<usize> {
        Some(self.get(conn, id).ok()?.held.load(Ordering::SeqCst))
    }

    /// The kernel's name for notebook ID, when it has one.
    pub fn kernel_name(&self, conn: u64, id: &str) -> Option<String> {
        match &*self.get(conn, id).ok()?.kernel.lock().expect("kernel") {
            Slot::Running(r) => Some(r.name.clone()),
            _ => None,
        }
    }
}

/// End OPEN's kernel and say how it ended.
async fn end_kernel(open: &Open) -> Result<Exit, String> {
    // taken in a statement of its own: the guard must not live through the match, whose Starting arm locks the slot again
    let slot = std::mem::replace(&mut *open.kernel.lock().expect("kernel"), Slot::Empty);
    let cmds = match slot {
        Slot::Running(r) => r.cmds,
        Slot::Starting => {
            *open.kernel.lock().expect("kernel") = Slot::Starting;
            return Err("the kernel is starting".into());
        }
        Slot::Empty => return Err("this notebook has no kernel".into()),
    };
    let (tx, rx) = oneshot::channel();
    cmds.send(Cmd::Shutdown(tx))
        .await
        .map_err(|_| "the kernel has ended".to_string())?;
    rx.await.map_err(|_| "the kernel's task ended".to_string())
}

fn send_status(sink: &dyn Sink, open: &Open, state: &str, cell: Option<&str>, queue: usize) {
    sink.send_lossy(
        open.conn,
        "notebook-status",
        json!({"id": open.id, "state": state, "cell": cell, "queue": queue}),
    );
}

/// How many tails may go out in a second: a window that opens at the first and counts.
pub(crate) struct Budget {
    start: tokio::time::Instant,
    sent: usize,
}

impl Budget {
    pub(crate) fn new(now: tokio::time::Instant) -> Budget {
        Budget {
            start: now,
            sent: 0,
        }
    }

    /// Whether another may go at NOW.
    pub(crate) fn allowed(&mut self, now: tokio::time::Instant) -> bool {
        if now.duration_since(self.start) >= Duration::from_secs(1) {
            *self = Budget::new(now);
        }
        self.sent < TAILS_PER_SEC
    }

    pub(crate) fn spend(&mut self) {
        self.sent += 1;
    }
}

/// The task of one kernel.
struct Pump {
    open: Arc<Open>,
    kernel: Kernel,
    sink: Arc<dyn Sink>,
    epoch: u64,
    router: Router,
    /// `msg_id` of a request to its cell (only the requests that are not over).
    cells: HashMap<String, String>,
    /// A cell's latest request that is not over.
    latest: HashMap<String, String>,
    queue: VecDeque<String>,
    current: Option<(String, String)>,
    dirty: HashSet<String>,
    last: HashMap<String, tokio::time::Instant>,
    /// When a running cell's output was last copied into the notebook.
    shown_at: HashMap<String, tokio::time::Instant>,
    /// The tails sent in this second.
    budget: Budget,
    /// An `input_request` the editor was told of: by the id it was told, the cell and the request's header.
    inputs: HashMap<String, (String, Value)>,
    /// What the editor's backed-up queue did not take and must not lose: the latest status and the input requests, by key; sent
    /// again at each tick until they go.
    pending: HashMap<String, (&'static str, Value)>,
    /// The editor is gone.
    gone: bool,
    /// The current request's reply (shell) and its `idle` (iopub) have come: it is done when both have, in either order.
    replied: bool,
    idle: bool,
}

impl Pump {
    fn new(open: Arc<Open>, kernel: Kernel, sink: Arc<dyn Sink>, epoch: u64) -> Pump {
        Pump {
            open,
            kernel,
            sink,
            epoch,
            router: Router::new(),
            cells: HashMap::new(),
            latest: HashMap::new(),
            queue: VecDeque::new(),
            current: None,
            dirty: HashSet::new(),
            last: HashMap::new(),
            shown_at: HashMap::new(),
            budget: Budget::new(crate::clock::now()),
            inputs: HashMap::new(),
            pending: HashMap::new(),
            gone: false,
            replied: false,
            idle: false,
        }
    }

    /// EVENT to the editor, droppable: whether it was sent; a gone editor ends the pump.
    fn emit(&mut self, event: &str, data: Value) -> bool {
        match self.sink.send_lossy(self.open.conn, event, data) {
            Delivery::Sent => true,
            Delivery::Dropped => false,
            Delivery::Gone => {
                self.gone = true;
                false
            }
        }
    }

    /// The message the router just logged (it answered no cell) goes into the notebook's kernel log, and the editor is told (one
    /// `notebook-log` is kept, the newest, until it is delivered).
    fn log_last(&mut self) {
        let Some(e) = self.router.log().last().cloned() else {
            return;
        };
        let seq = self
            .open
            .log
            .lock()
            .expect("log")
            .push(&e.msg_type, &e.text);
        let id = self.open.id.clone();
        self.emit_kept("log".into(), "notebook-log", json!({"id": id, "seq": seq}));
    }

    /// EVENT that is kept until it is delivered (under KEY: a newer one with the same key replaces it).
    fn emit_kept(&mut self, key: String, event: &'static str, data: Value) {
        if self.emit(event, data.clone()) {
            self.pending.remove(&key);
        } else if !self.gone {
            self.pending.insert(key, (event, data));
        }
    }

    /// The kept events are sent again.
    fn resend(&mut self) {
        let keys: Vec<String> = self.pending.keys().cloned().collect();
        for key in keys {
            let Some((event, data)) = self.pending.get(&key).cloned() else {
                continue;
            };
            if self.emit(event, data) {
                self.pending.remove(&key);
            }
        }
    }

    fn status(&mut self, state: &str) {
        let (cell, queue) = (self.current.as_ref().map(|c| c.0.clone()), self.queue.len());
        self.emit_kept(
            "status".into(),
            "notebook-status",
            json!({"id": self.open.id, "state": state, "cell": cell, "queue": queue}),
        );
    }

    /// Whether another tail may go in this second.
    fn allowed(&mut self) -> bool {
        self.budget.allowed(crate::clock::now())
    }

    /// Send CELL's tail now (a tail the editor's queue could not take is sent again at the next tick).
    async fn flush(&mut self, cell: &str, finished: bool) {
        self.dirty.remove(cell);
        let now = crate::clock::now();
        self.last.insert(cell.to_string(), now);
        let mut book = self.open.book.lock().await;
        let version = book.next_version(cell);
        let event = match self.latest.get(cell).and_then(|m| self.router.run(m)) {
            Some(run) => {
                let Some((kind, _)) = book.cell_head(cell) else {
                    return;
                };
                let t = tail::build(cell, run, version);
                // the notebook gets a copy of the output now and then and when the cell is done, not with every tail
                if finished
                    || self
                        .shown_at
                        .get(cell)
                        .is_none_or(|t0| now.duration_since(*t0) >= SHOW_EVERY)
                {
                    book.show(cell, run);
                    self.shown_at.insert(cell.to_string(), now);
                }
                let head = tail::head(
                    kind,
                    &book.language().unwrap_or_default(),
                    t.execution_count,
                    self.open.state_of(cell),
                );
                Some(tail_json(&self.open.id, &t, false, &head))
            }
            None => self.open.tail_event(&book, cell),
        };
        drop(book);
        let Some(event) = event else { return };
        {
            let mut live = self.open.live.lock().expect("live");
            if finished {
                live.remove(cell);
            } else {
                live.insert(cell.to_string(), event.clone());
            }
        }
        self.budget.spend();
        if !self.emit("notebook-tail", event) {
            self.dirty.insert(cell.to_string());
        }
    }

    async fn touch(&mut self, cell: &str) {
        let due = self
            .last
            .get(cell)
            .is_none_or(|t| crate::clock::now().duration_since(*t) >= TAIL_EVERY);
        if due && self.allowed() {
            self.flush(cell, false).await;
        } else {
            self.dirty.insert(cell.to_string());
        }
    }

    async fn start_next(&mut self) {
        while self.current.is_none() {
            let Some(cell) = self.queue.pop_front() else {
                break;
            };
            let code = {
                let book = self.open.book.lock().await;
                book.cell_info(&cell).map(|c| c.source)
            };
            let Some(code) = code else { continue };
            let content = json!({"code": code, "silent": false, "store_history": true, "user_expressions": {},
                                 "allow_stdin": true, "stop_on_error": true});
            match self
                .kernel
                .request(Channel::Shell, "execute_request", content)
            {
                Ok(msg_id) => {
                    self.router.begin(&msg_id);
                    self.cells.insert(msg_id.clone(), cell.clone());
                    self.latest.insert(cell.clone(), msg_id.clone());
                    self.current = Some((cell.clone(), msg_id));
                    self.count_held();
                    (self.replied, self.idle) = (false, false);
                    self.status("busy");
                    self.open.set_state(&cell, Some("running"));
                    self.flush(&cell, false).await;
                }
                Err(_) => {
                    self.status("dead");
                    return;
                }
            }
        }
        if self.current.is_none() {
            self.status("idle");
        }
    }

    fn count_held(&self) {
        self.open.held.store(
            self.cells.len() + self.latest.len() + self.router.held(),
            Ordering::SeqCst,
        );
    }

    /// The queued cells that will not run: shown as ABORTED or CANCELLED (what output they had stays).
    async fn drop_queue(&mut self, why: RunStatus) {
        let dropped: Vec<String> = self.queue.drain(..).collect();
        for cell in dropped {
            self.dirty.remove(&cell);
            self.open.set_state(&cell, None);
            self.open.live.lock().expect("live").remove(&cell);
            let mut book = self.open.book.lock().await;
            book.mark(&cell, why);
            if let Some(v) = self.open.tail_event(&book, &cell) {
                drop(book);
                self.emit("notebook-tail", v);
            }
        }
    }

    /// The current request is done when its reply and its `idle` have both come (they travel on different sockets, so either can be
    /// first): its tail is final, the run is forgotten, an error aborts what is queued, and the next cell goes.
    async fn finish_if_done(&mut self) {
        if !(self.replied && self.idle) {
            return;
        }
        let Some((cell, msg_id)) = self.current.take() else {
            return;
        };
        let status = self.router.run(&msg_id).map(|r| r.status);
        self.open.set_state(&cell, None);
        self.flush(&cell, true).await;
        // nothing of the run is kept but what the notebook holds, and what the kernel says of it later is of no cell
        self.router.end(&msg_id);
        self.cells.remove(&msg_id);
        self.latest.remove(&cell);
        self.shown_at.remove(&cell);
        self.inputs.retain(|_, (c, _)| *c != cell);
        let inputs = &self.inputs;
        self.pending.retain(|k, _| {
            k.strip_prefix("input:")
                .is_none_or(|r| inputs.contains_key(r))
        });
        self.count_held();
        if status == Some(RunStatus::Error) {
            self.drop_queue(RunStatus::Aborted).await;
        }
        self.start_next().await;
    }

    async fn on_message(&mut self, channel: Channel, m: Message) {
        let parent = m
            .parent
            .get("msg_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let is_current = self.current.as_ref().is_some_and(|c| c.1 == parent);
        if channel == Channel::Iopub && m.header.msg_type == "status" {
            if is_current
                && m.content.get("execution_state").and_then(Value::as_str) == Some("idle")
            {
                self.idle = true;
                self.finish_if_done().await;
            }
            return;
        }
        if channel == Channel::Stdin && m.header.msg_type == "input_request" {
            // only the running cell may ask, once at a time, and the editor gets a short clean prompt
            let Some(cell) = self.cells.get(&parent).cloned().filter(|_| is_current) else {
                return;
            };
            if self.inputs.values().any(|(c, _)| *c == cell) {
                return;
            }
            let request = m.header.msg_id.clone();
            let prompt: String = clean(
                m.content
                    .get("prompt")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
            )
            .chars()
            .take(PROMPT_CHARS)
            .collect();
            let event = json!({"id": self.open.id, "cell": cell, "request": request, "prompt": prompt,
                               "password": m.content.get("password").and_then(Value::as_bool).unwrap_or(false)});
            self.inputs.insert(
                request.clone(),
                (cell, serde_json::to_value(&m.header).unwrap_or(Value::Null)),
            );
            self.emit_kept(format!("input:{request}"), "notebook-input-request", event);
            return;
        }
        let change = self.router.apply(channel, &m);
        if change == Some(super::output::Change::Log) {
            self.log_last();
            return;
        }
        let Some(super::output::Change::Run(msg_id)) = change else {
            return;
        };
        let Some(cell) = self.cells.get(&msg_id).cloned() else {
            return;
        };
        if channel == Channel::Shell && m.header.msg_type == "execute_reply" && is_current {
            self.replied = true;
            self.finish_if_done().await;
        } else {
            self.touch(&cell).await;
        }
    }

    async fn run(mut self, mut rx: mpsc::Receiver<Cmd>) {
        self.status("idle");
        let mut tick = crate::clock::interval(TAIL_EVERY);
        let mut shutdown: Option<oneshot::Sender<Exit>> = None;
        while !self.gone {
            tokio::select! {
                cmd = rx.recv() => match cmd {
                    None => break,
                    Some(Cmd::Shutdown(tx)) => { shutdown = Some(tx); break; }
                    Some(Cmd::Execute(cells)) => {
                        for cell in &cells {
                            self.open.set_state(cell, Some("queued"));
                            self.flush(cell, false).await;
                        }
                        self.queue.extend(cells);
                        self.start_next().await;
                    }
                    Some(Cmd::Interrupt) => {
                        let _ = self.kernel.interrupt();
                        self.drop_queue(RunStatus::Cancelled).await;
                        self.status(if self.current.is_some() { "busy" } else { "idle" });
                    }
                    Some(Cmd::Input { request, value }) => {
                        self.pending.remove(&format!("input:{request}"));
                        if let Some((_, parent)) = self.inputs.remove(&request) {
                            let mut reply = Message::request("hub", "input_reply", json!({"value": value, "status": "ok"}));
                            reply.parent = parent;
                            let _ = self.kernel.send(Channel::Stdin, &reply);
                        }
                    }
                },
                ev = self.kernel.next() => match ev {
                    KernelEvent::Message(ch, m) => self.on_message(ch, *m).await,
                    KernelEvent::Closed(..) => {}
                    KernelEvent::Flood => { self.status("dead"); break; }
                    KernelEvent::Exited(_) => { self.status("dead"); break; }
                },
                _ = tick.tick() => {
                    self.resend();
                    let due: Vec<String> = self.dirty.iter().cloned().collect();
                    for cell in due {
                        if self.allowed() {
                            self.flush(&cell, false).await;
                        }
                    }
                }
            }
        }
        // the cells still queued or running did not finish
        self.drop_queue(RunStatus::Cancelled).await;
        if let Some((cell, msg)) = self.current.take() {
            self.router.cancel(&msg);
            self.open.set_state(&cell, None);
            self.flush(&cell, true).await;
        }
        {
            // the slot is cleared only if it is still this kernel's (a restart may have started the next)
            let mut slot = self.open.kernel.lock().expect("kernel");
            if matches!(&*slot, Slot::Running(r) if r.epoch == self.epoch) {
                *slot = Slot::Empty;
            }
        }
        let (open, sink) = (self.open.clone(), self.sink.clone());
        let exit = self.kernel.shutdown().await;
        send_status(&*sink, &open, "dead", None, 0);
        if let Some(tx) = shutdown {
            let _ = tx.send(exit);
        }
    }
}

#[cfg(test)]
mod tests;
