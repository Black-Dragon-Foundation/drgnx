//! The notebooks the hub holds open for an editor, and their kernels (design §4.1, §5.4): `open` reads a file into a [`Book`], `start`
//! starts a kernel for it (never in a sealed session), `execute` queues cells, and a task per kernel (the pump) files what the kernel
//! says under the cell it answers and sends the editor each cell's tail (`notebook-tail`), the state (`notebook-status`) and a kernel's
//! question (`notebook-input-request`). The editor is told only what changed, at most 20 times a second per cell.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::book::{Book, CellInfo, CellSync};
use super::kernel::{Exit, Kernel, KernelEvent, Timeouts, refuse_when_sealed};
use super::output::terminal::Run;
use super::output::{CellRun, Router, RunStatus};
use super::session::Channel;
use super::spec::{Choice, Kernelspec, Skipped, choose, discover, discover_with_skips};
use super::tail::{self, Head, Tail};
use super::wire::Message;
use crate::agents::lock::LaunchPlan;
use crate::debug::Sink;

/// The least time between two tails of one cell.
pub const TAIL_EVERY: Duration = Duration::from_millis(50);

/// What the editor gets when it opens a notebook.
#[derive(Clone, Debug)]
pub struct Opened {
    pub id: String,
    pub cells: Vec<CellInfo>,
    pub kernelspec: Option<String>,
    pub language: Option<String>,
    /// Each code cell's tail from the file (stale: no kernel has run it in this hub), as the editor gets a tail.
    pub tails: Vec<Value>,
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
}

struct Open {
    id: String,
    conn: u64,
    book: tokio::sync::Mutex<Book>,
    kernel: Mutex<Option<Running>>,
    starts: AtomicU64,
    /// Cells that are queued or running (the others are idle): what their heads show.
    states: Mutex<HashMap<String, &'static str>>,
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

    /// The tail event of CELL: its tail, and the head that goes with it.
    fn tail_event(&self, book: &Book, cell: &str) -> Option<Value> {
        let (t, stale) = book.tail(cell)?;
        let info = book.cell_info(cell)?;
        let head = tail::head(
            info.kind,
            &book.language().unwrap_or_default(),
            t.execution_count,
            self.state_of(cell),
        );
        Some(tail_json(&self.id, &t, stale, &head))
    }
}

pub struct Notebooks {
    sink: Arc<dyn Sink>,
    /// The session's private folder (connection files and sockets).
    folder: PathBuf,
    kernel_dirs: Vec<PathBuf>,
    timeouts: Timeouts,
    books: Mutex<HashMap<String, Arc<Open>>>,
    next: AtomicU64,
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
            next: AtomicU64::new(1),
        }
    }

    fn get(&self, id: &str) -> Result<Arc<Open>, String> {
        self.books
            .lock()
            .expect("books")
            .get(id)
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

    /// Open the notebook at PATH for the editor on CONN; TEXT is the buffer's text when it has one, else the file is read.
    pub async fn open(
        &self,
        conn: u64,
        path: &Path,
        text: Option<String>,
    ) -> Result<Opened, String> {
        let text = match text {
            Some(t) => t,
            None => {
                // not read at all when it is over the limit
                let len = tokio::fs::metadata(path)
                    .await
                    .map_err(|e| format!("{}: {e}", path.display()))?
                    .len();
                if len > super::book::MAX_NOTEBOOK_BYTES as u64 {
                    return Err(format!(
                        "{}: too large for a notebook ({} MiB)",
                        path.display(),
                        len >> 20
                    ));
                }
                tokio::fs::read_to_string(path)
                    .await
                    .map_err(|e| format!("{}: {e}", path.display()))?
            }
        };
        let book = Book::open(path, text)?;
        let id = format!("nb{}", self.next.fetch_add(1, Ordering::SeqCst));
        let (cells, kernelspec, language) = (book.cells(), book.kernelspec_name(), book.language());
        let open = Arc::new(Open {
            id: id.clone(),
            conn,
            book: tokio::sync::Mutex::new(book),
            kernel: Mutex::new(None),
            starts: AtomicU64::new(1),
            states: Mutex::new(HashMap::new()),
        });
        let tails = {
            let book = open.book.lock().await;
            cells
                .iter()
                .filter_map(|c| open.tail_event(&book, &c.id))
                .collect()
        };
        let opened = Opened {
            id: id.clone(),
            cells,
            kernelspec,
            language,
            tails,
        };
        self.books.lock().expect("books").insert(id, open);
        Ok(opened)
    }

    /// The editor's cells (their text and types) are the notebook's.
    pub async fn sync(&self, id: &str, cells: &[CellSync]) -> Result<(), String> {
        self.get(id)?.book.lock().await.sync(cells);
        Ok(())
    }

    /// Write the notebook (after taking the editor's cells, when given).
    pub async fn save(&self, id: &str, cells: Option<&[CellSync]>) -> Result<(), String> {
        let open = self.get(id)?;
        let mut book = open.book.lock().await;
        if let Some(c) = cells {
            book.sync(c);
        }
        book.save()
    }

    /// The tail of one cell, from what the hub holds.
    pub async fn tail(&self, id: &str, cell: &str) -> Result<Value, String> {
        let open = self.get(id)?;
        let book = open.book.lock().await;
        open.tail_event(&book, cell)
            .ok_or_else(|| format!("no cell {cell}"))
    }

    /// CELL (or every code cell) has no output and no execution count; a cell that is queued or running is left as it is.
    pub async fn clear(&self, id: &str, cell: Option<&str>) -> Result<(), String> {
        let open = self.get(id)?;
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
            if book.cell_info(&c).is_none() {
                return Err(format!("no cell {c}"));
            }
            if open.state_of(&c) != "idle" {
                continue;
            }
            book.clear(&c);
            if let Some(v) = open.tail_event(&book, &c) {
                self.sink.send(open.conn, "notebook-tail", v);
            }
        }
        Ok(())
    }

    /// The full output of one cell as nbformat objects.
    pub async fn output(&self, id: &str, cell: &str) -> Result<Vec<Value>, String> {
        Ok(self.get(id)?.book.lock().await.outputs_of(cell))
    }

    /// Start a kernel for notebook ID: KERNEL by name, else the notebook's own, else its language's; a sealed session (PLAN enforced)
    /// is refused. Returns the kernelspec's name.
    pub async fn start(
        &self,
        id: &str,
        kernel: Option<&str>,
        plan: Option<&LaunchPlan>,
    ) -> Result<String, String> {
        if let Some(p) = plan {
            refuse_when_sealed(p).map_err(|r| r.0.to_string())?;
        }
        let open = self.get(id)?;
        if open.kernel.lock().expect("kernel").is_some() {
            return Err("this notebook already has a kernel".into());
        }
        let specs = self.kernels();
        let (name, lang) = {
            let b = open.book.lock().await;
            (
                kernel.map(String::from).or_else(|| b.kernelspec_name()),
                b.language(),
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
        let cwd = open
            .book
            .lock()
            .await
            .path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        self.status(&open, "starting", None, 0);
        let k = Kernel::start(&spec, &self.folder, &conn_id, &cwd, self.timeouts)
            .await
            .inspect_err(|_| {
                self.status(&open, "dead", None, 0);
            })?;
        let (tx, rx) = mpsc::channel(64);
        *open.kernel.lock().expect("kernel") = Some(Running {
            name: spec.name.clone(),
            cmds: tx,
        });
        let pump = Pump::new(open.clone(), k, self.sink.clone());
        crate::clock::spawn("notebook-pump", pump.run(rx));
        Ok(spec.name)
    }

    fn status(&self, open: &Open, state: &str, cell: Option<&str>, queue: usize) {
        send_status(&*self.sink, open, state, cell, queue);
    }

    async fn command(&self, id: &str, cmd: Cmd) -> Result<(), String> {
        let open = self.get(id)?;
        let tx = open
            .kernel
            .lock()
            .expect("kernel")
            .as_ref()
            .map(|r| r.cmds.clone())
            .ok_or("this notebook has no kernel")?;
        tx.send(cmd)
            .await
            .map_err(|_| "the kernel has ended".to_string())
    }

    /// Queue CELLS (id and source, in order) to run: their text becomes the notebook's first.
    pub async fn execute(&self, id: &str, cells: &[CellSync]) -> Result<(), String> {
        let open = self.get(id)?;
        {
            let mut book = open.book.lock().await;
            let mut all = book
                .cells()
                .into_iter()
                .map(|c| CellSync {
                    id: c.id,
                    kind: c.kind,
                    source: c.source,
                })
                .collect::<Vec<_>>();
            for c in cells {
                if let Some(a) = all.iter_mut().find(|a| a.id == c.id) {
                    a.source = c.source.clone();
                }
            }
            book.sync(&all);
        }
        self.command(
            id,
            Cmd::Execute(cells.iter().map(|c| c.id.clone()).collect()),
        )
        .await
    }

    pub async fn interrupt(&self, id: &str) -> Result<(), String> {
        self.command(id, Cmd::Interrupt).await
    }

    /// The answer to a kernel's `input_request` (REQUEST is the id the event named).
    pub async fn input(&self, id: &str, request: &str, value: &str) -> Result<(), String> {
        self.command(
            id,
            Cmd::Input {
                request: request.into(),
                value: value.into(),
            },
        )
        .await
    }

    /// End the notebook's kernel; how it ended.
    pub async fn shutdown(&self, id: &str) -> Result<Exit, String> {
        let open = self.get(id)?;
        let running = open
            .kernel
            .lock()
            .expect("kernel")
            .take()
            .ok_or("this notebook has no kernel")?;
        let (tx, rx) = oneshot::channel();
        running
            .cmds
            .send(Cmd::Shutdown(tx))
            .await
            .map_err(|_| "the kernel has ended".to_string())?;
        rx.await.map_err(|_| "the kernel's task ended".to_string())
    }

    /// A new kernel of the same kind for notebook ID: the old one is asked to shut down (its group killed after the grace), what was queued
    /// is cancelled, and a new process starts with a new connection file and key. The kernel's name.
    pub async fn restart(&self, id: &str) -> Result<String, String> {
        let name = self.kernel_name(id).ok_or("this notebook has no kernel")?;
        self.shutdown(id).await?;
        self.start(id, Some(&name), None).await
    }

    /// Forget notebook ID (its kernel ends first).
    pub async fn close(&self, id: &str) {
        let _ = self.shutdown(id).await;
        self.books.lock().expect("books").remove(id);
    }

    /// The kernel's name for notebook ID, when it has one.
    pub fn kernel_name(&self, id: &str) -> Option<String> {
        self.get(id)
            .ok()?
            .kernel
            .lock()
            .expect("kernel")
            .as_ref()
            .map(|r| r.name.clone())
    }
}

fn send_status(sink: &dyn Sink, open: &Open, state: &str, cell: Option<&str>, queue: usize) {
    sink.send(
        open.conn,
        "notebook-status",
        json!({"id": open.id, "state": state, "cell": cell, "queue": queue}),
    );
}

/// The task of one kernel.
struct Pump {
    open: Arc<Open>,
    kernel: Kernel,
    sink: Arc<dyn Sink>,
    router: Router,
    /// `msg_id` of a request to its cell.
    cells: HashMap<String, String>,
    /// A cell's latest request.
    latest: HashMap<String, String>,
    queue: VecDeque<String>,
    current: Option<(String, String)>,
    dirty: HashSet<String>,
    last: HashMap<String, tokio::time::Instant>,
    /// A kernel's `input_request` header by the id the editor was told.
    inputs: HashMap<String, Value>,
    /// The current request's reply (shell) and its `idle` (iopub) have come: it is done when both have, in either order.
    replied: bool,
    idle: bool,
}

impl Pump {
    fn new(open: Arc<Open>, kernel: Kernel, sink: Arc<dyn Sink>) -> Pump {
        Pump {
            open,
            kernel,
            sink,
            router: Router::new(),
            cells: HashMap::new(),
            latest: HashMap::new(),
            queue: VecDeque::new(),
            current: None,
            dirty: HashSet::new(),
            last: HashMap::new(),
            inputs: HashMap::new(),
            replied: false,
            idle: false,
        }
    }

    fn status(&self, state: &str) {
        send_status(
            &*self.sink,
            &self.open,
            state,
            self.current.as_ref().map(|c| c.0.as_str()),
            self.queue.len(),
        );
    }

    /// Send CELL's tail now.
    async fn flush(&mut self, cell: &str) {
        self.dirty.remove(cell);
        self.last.insert(cell.to_string(), crate::clock::now());
        let mut book = self.open.book.lock().await;
        if let Some(run) = self.latest.get(cell).and_then(|m| self.router.run(m)) {
            book.show(cell, run);
        }
        if let Some(v) = self.open.tail_event(&book, cell) {
            self.sink.send(self.open.conn, "notebook-tail", v);
        }
    }

    async fn touch(&mut self, cell: &str) {
        let due = self
            .last
            .get(cell)
            .is_none_or(|t| crate::clock::now().duration_since(*t) >= TAIL_EVERY);
        if due {
            self.flush(cell).await;
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
                book.cells()
                    .into_iter()
                    .find(|c| c.id == cell)
                    .map(|c| c.source)
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
                    (self.replied, self.idle) = (false, false);
                    self.status("busy");
                    self.open.set_state(&cell, Some("running"));
                    self.flush(&cell).await;
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

    /// The queued cells that will not run: shown as ABORTED or CANCELLED.
    async fn drop_queue(&mut self, why: RunStatus) {
        let dropped: Vec<String> = self.queue.drain(..).collect();
        for cell in dropped {
            let run = CellRun::from_outputs("dropped", Vec::new(), why);
            self.latest.remove(&cell);
            self.dirty.remove(&cell);
            let mut book = self.open.book.lock().await;
            book.show(&cell, &run);
            self.open.set_state(&cell, None);
            if let Some(v) = self.open.tail_event(&book, &cell) {
                self.sink.send(self.open.conn, "notebook-tail", v);
            }
        }
    }

    /// The current request is done when its reply and its `idle` have both come (they travel on different sockets, so either can be
    /// first): its tail is final, an error aborts what is queued, and the next cell goes.
    async fn finish_if_done(&mut self) {
        if !(self.replied && self.idle) {
            return;
        }
        let Some((cell, msg_id)) = self.current.take() else {
            return;
        };
        let status = self.router.run(&msg_id).map(|r| r.status);
        self.open.set_state(&cell, None);
        self.flush(&cell).await;
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
            let cell = self.cells.get(&parent).cloned();
            let request = m.header.msg_id.clone();
            self.sink.send(
                self.open.conn,
                "notebook-input-request",
                json!({"id": self.open.id, "cell": cell, "request": request,
                       "prompt": m.content.get("prompt").and_then(Value::as_str).unwrap_or(""),
                       "password": m.content.get("password").and_then(Value::as_bool).unwrap_or(false)}),
            );
            self.inputs.insert(
                request,
                serde_json::to_value(&m.header).unwrap_or(Value::Null),
            );
            // keep what the kernel asked for until it is answered, within bounds
            if self.inputs.len() > 16 {
                self.inputs.clear();
            }
            return;
        }
        let Some(super::output::Change::Run(msg_id)) = self.router.apply(channel, &m) else {
            return;
        };
        let Some(cell) = self.cells.get(&msg_id).cloned() else {
            return;
        };
        if channel == Channel::Shell && m.header.msg_type == "execute_reply" && is_current {
            self.replied = true;
            self.flush(&cell).await;
            self.finish_if_done().await;
        } else {
            self.touch(&cell).await;
        }
    }

    async fn run(mut self, mut rx: mpsc::Receiver<Cmd>) {
        self.status("idle");
        let mut tick = crate::clock::interval(TAIL_EVERY);
        let mut shutdown: Option<oneshot::Sender<Exit>> = None;
        loop {
            tokio::select! {
                cmd = rx.recv() => match cmd {
                    None => break,
                    Some(Cmd::Shutdown(tx)) => { shutdown = Some(tx); break; }
                    Some(Cmd::Execute(cells)) => {
                        for cell in &cells {
                            self.open.set_state(cell, Some("queued"));
                            self.flush(cell).await;
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
                        if let Some(parent) = self.inputs.remove(&request) {
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
                    let due: Vec<String> = self.dirty.iter().cloned().collect();
                    for cell in due {
                        self.flush(&cell).await;
                    }
                }
            }
        }
        // the cells still queued or running did not finish
        self.drop_queue(RunStatus::Cancelled).await;
        if let Some((cell, msg)) = self.current.take() {
            self.router.cancel(&msg);
            self.flush(&cell).await;
        }
        *self.open.kernel.lock().expect("kernel") = None;
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
