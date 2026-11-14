//! What a kernel's iopub says about a cell, as the hub holds it (design §5.4, §5.5): the outputs, in the form nbformat saves.
//!
//! - [`terminal`]: a stream or a traceback as a terminal would show it: `\r` and `\b`, ANSI colours as the theme's **roles**
//!   (0 to 15, never a colour), everything else dropped.
//! - [`mime`]: which representation of a display is shown, images checked by their bytes, SVG never rendered.
//! - this module: the router that files iopub messages under the cell (the request's `msg_id`) they answer, the `display_id`
//!   map, `clear_output`, the caps, and the kernel log for messages that answer nothing.

pub mod file;
pub mod mime;
pub mod terminal;

use std::collections::{HashMap, VecDeque};

use serde_json::{Value, json};

use self::mime::Bundle;
use self::terminal::Terminal;
use super::session::Channel;
use super::wire::Message;

/// Text held per cell (streams, results, tracebacks).
pub const MAX_TEXT: usize = 1 << 20;
/// Outputs held per cell.
pub const MAX_OUTPUTS: usize = 64;
/// Encoded bytes of images held per cell, in all.
pub const MAX_IMAGES: usize = 16 << 20;
/// The longest stream name kept.
pub const MAX_NAME: usize = 64;
/// Entries of the kernel log, and the text of one.
pub const LOG_ENTRIES: usize = 500;
pub const LOG_TEXT: usize = 4096;
/// The longest message type the log keeps.
pub const LOG_TYPE: usize = 64;
/// Traceback entries held per error.
pub const MAX_TRACEBACK: usize = 200;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunStatus {
    Running,
    Ok,
    Error,
    /// A cell queued behind an error: not run.
    Aborted,
    /// Dropped from the hub's queue by an interrupt or a restart.
    Cancelled,
}

#[derive(Clone, Debug)]
pub enum Output {
    Stream {
        name: String,
        text: Terminal,
    },
    Display {
        display_id: Option<String>,
        bundle: Bundle,
    },
    Result {
        count: Option<i64>,
        bundle: Bundle,
    },
    Error {
        ename: String,
        evalue: String,
        traceback: Vec<Terminal>,
    },
}

impl Output {
    /// The nbformat output object. Streams and tracebacks are saved without their colours' roles but with the ANSI the kernel sent
    /// (re-encoded from the styled cells), so another notebook program shows them as it would have.
    pub fn to_nbformat(&self) -> Value {
        match self {
            Output::Stream { name, text } => {
                json!({"output_type": "stream", "name": name, "text": text.to_ansi()})
            }
            Output::Display { bundle, .. } => {
                json!({"output_type": "display_data", "data": bundle.data(), "metadata": bundle.metadata()})
            }
            Output::Result { count, bundle } => json!({
                "output_type": "execute_result", "execution_count": count,
                "data": bundle.data(), "metadata": bundle.metadata(),
            }),
            Output::Error {
                ename,
                evalue,
                traceback,
            } => json!({
                "output_type": "error", "ename": ename, "evalue": evalue,
                "traceback": traceback.iter().map(Terminal::to_ansi).collect::<Vec<_>>(),
            }),
        }
    }

    /// Every string this output holds, in bytes: the cell's text cap counts all of them.
    fn text_len(&self) -> usize {
        match self {
            Output::Stream { name, text } => name.len() + text.len(),
            // the id is held again in the router's map
            Output::Display { display_id, bundle } => {
                2 * display_id.as_ref().map_or(0, String::len) + bundle.text_len()
            }
            Output::Result { bundle, .. } => bundle.text_len(),
            Output::Error {
                ename,
                evalue,
                traceback,
            } => ename.len() + evalue.len() + traceback.iter().map(Terminal::len).sum::<usize>(),
        }
    }

    /// Encoded bytes of the images held: the cell's image total counts them.
    fn image_len(&self) -> usize {
        match self {
            Output::Display { bundle, .. } | Output::Result { bundle, .. } => bundle.image_len(),
            _ => 0,
        }
    }
}

/// One execution of one cell.
#[derive(Clone, Debug)]
pub struct CellRun {
    pub msg_id: String,
    pub outputs: Vec<Output>,
    pub status: RunStatus,
    pub execution_count: Option<i64>,
    /// Output was cut at a cap (the view says so).
    pub truncated: bool,
    /// `clear_output(wait=True)`: the next output clears first.
    clear_pending: bool,
    text: usize,
    images: usize,
}

impl CellRun {
    fn new(msg_id: &str) -> CellRun {
        CellRun {
            msg_id: msg_id.into(),
            outputs: Vec::new(),
            status: RunStatus::Running,
            execution_count: None,
            truncated: false,
            clear_pending: false,
            text: 0,
            images: 0,
        }
    }

    /// A run that is only outputs (read from a file, or set by the hub), in STATUS.
    /// The caps of a kernel's output hold for it too (a file is as untrusted as a kernel).
    pub fn from_outputs(
        msg_id: &str,
        outputs: impl IntoIterator<Item = Output>,
        status: RunStatus,
    ) -> CellRun {
        let mut r = CellRun {
            status,
            ..CellRun::new(msg_id)
        };
        for o in outputs {
            r.push_output(o);
        }
        r
    }

    /// Hold OUT unless a cap says no (then the run says it was cut); whether it was kept.
    pub(crate) fn push_output(&mut self, out: Output) -> bool {
        if self.outputs.len() >= MAX_OUTPUTS
            || self.text + out.text_len() > MAX_TEXT
            || self.images + out.image_len() > MAX_IMAGES
        {
            self.truncated = true;
            return false;
        }
        self.text += out.text_len();
        self.images += out.image_len();
        self.outputs.push(out);
        true
    }

    /// The cell's `outputs` for the file.
    pub fn to_nbformat(&self) -> Vec<Value> {
        self.outputs.iter().map(Output::to_nbformat).collect()
    }
}

/// A message that answered no request of ours.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogEntry {
    pub msg_type: String,
    pub text: String,
}

/// What a message changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    /// The run with this `msg_id` (its outputs or its state).
    Run(String),
    Log,
}

#[derive(Default)]
pub struct Router {
    runs: HashMap<String, CellRun>,
    /// `display_id` to the run and the index of its output.
    displays: HashMap<String, (String, usize)>,
    log: VecDeque<LogEntry>,
}

impl Router {
    pub fn new() -> Router {
        Router::default()
    }

    /// A request with MSG_ID has been sent: its replies are filed under it.
    pub fn begin(&mut self, msg_id: &str) {
        self.runs.insert(msg_id.to_string(), CellRun::new(msg_id));
    }

    pub fn run(&self, msg_id: &str) -> Option<&CellRun> {
        self.runs.get(msg_id)
    }

    pub fn run_mut(&mut self, msg_id: &str) -> Option<&mut CellRun> {
        self.runs.get_mut(msg_id)
    }

    /// Forget a run (its cell is done being shown).
    pub fn end(&mut self, msg_id: &str) {
        self.runs.remove(msg_id);
        self.displays.retain(|_, (m, _)| m != msg_id);
    }

    /// The run ended without the kernel's say (an interrupt or restart dropped it from the queue).
    pub fn cancel(&mut self, msg_id: &str) -> Option<Change> {
        let r = self.runs.get_mut(msg_id)?;
        if r.status == RunStatus::Running {
            r.status = RunStatus::Cancelled;
        }
        Some(Change::Run(msg_id.into()))
    }

    pub fn log(&self) -> impl Iterator<Item = &LogEntry> {
        self.log.iter()
    }

    /// File one message of the kernel. Messages for a request we did not make (or no longer track) are logged, never shown in a cell.
    pub fn apply(&mut self, channel: Channel, m: &Message) -> Option<Change> {
        let t = m.header.msg_type.as_str();
        if t == "status" {
            // `status` carries no output; the run's state is the reply's
            return None;
        }
        let parent = m.parent.get("msg_id").and_then(Value::as_str).unwrap_or("");
        if parent.is_empty() || !self.runs.contains_key(parent) {
            return self.log_message(m);
        }
        let parent = parent.to_string();
        let c = &m.content;
        let str_of = |k: &str| c.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        match (channel, t) {
            (Channel::Shell, "execute_reply") => {
                let r = self.runs.get_mut(&parent)?;
                r.status = match c.get("status").and_then(Value::as_str) {
                    Some("ok") => RunStatus::Ok,
                    Some("aborted") => RunStatus::Aborted,
                    _ => RunStatus::Error,
                };
                if let Some(n) = c.get("execution_count").and_then(Value::as_i64) {
                    r.execution_count = Some(n);
                }
            }
            (Channel::Iopub, "execute_input") => {
                self.runs.get_mut(&parent)?.execution_count =
                    c.get("execution_count").and_then(Value::as_i64);
            }
            (Channel::Iopub, "stream") => {
                let name: String = str_of("name").chars().take(MAX_NAME).collect();
                let text = str_of("text");
                let r = self.runs.get_mut(&parent)?;
                Self::start_output(r, &mut self.displays);
                if let Some(Output::Stream { name: n, text: t }) = r.outputs.last_mut()
                    && *n == name
                {
                    // the text can shrink (a carriage return and an erase): the budget follows the text both ways
                    let before = t.len();
                    t.push(&text);
                    r.text = (r.text + t.len()).saturating_sub(before);
                    Self::cap_text(r);
                } else {
                    let mut term = Terminal::default();
                    term.push(&text);
                    Self::add(r, Output::Stream { name, text: term });
                }
            }
            (Channel::Iopub, "display_data") => {
                let id = display_id(m);
                let out = Output::Display {
                    display_id: id.clone(),
                    bundle: Bundle::from_message(c),
                };
                self.add_with_display(&parent, out, id)?;
            }
            (Channel::Iopub, "update_display_data") => {
                let id = display_id(m)?;
                let (run, at) = self.displays.get(&id)?.clone();
                let r = self.runs.get_mut(&run)?;
                let new = Bundle::from_message(c);
                if let Some(Output::Display { bundle, .. }) = r.outputs.get_mut(at) {
                    // an update is held to the same caps as an addition, counting what it replaces as given back
                    let (text, images) = (
                        r.text.saturating_sub(bundle.text_len()),
                        r.images.saturating_sub(bundle.image_len()),
                    );
                    if text + new.text_len() > MAX_TEXT || images + new.image_len() > MAX_IMAGES {
                        r.truncated = true;
                    } else {
                        r.text = text + new.text_len();
                        r.images = images + new.image_len();
                        *bundle = new;
                    }
                }
                return Some(Change::Run(run));
            }
            (Channel::Iopub, "execute_result") => {
                let count = c.get("execution_count").and_then(Value::as_i64);
                let out = Output::Result {
                    count,
                    bundle: Bundle::from_message(c),
                };
                self.add_with_display(&parent, out, None)?;
            }
            (Channel::Iopub, "error") => {
                let traceback = c
                    .get("traceback")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .take(MAX_TRACEBACK)
                            .map(|l| {
                                let mut t = Terminal::default();
                                t.push(l);
                                t
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let out = Output::Error {
                    ename: str_of("ename"),
                    evalue: str_of("evalue"),
                    traceback,
                };
                self.add_with_display(&parent, out, None)?;
            }
            (Channel::Iopub, "clear_output") => {
                let wait = c.get("wait").and_then(Value::as_bool).unwrap_or(false);
                let r = self.runs.get_mut(&parent)?;
                if wait {
                    r.clear_pending = true;
                } else {
                    Self::clear(r, &mut self.displays);
                }
            }
            _ => return None,
        }
        Some(Change::Run(parent))
    }

    fn clear(r: &mut CellRun, displays: &mut HashMap<String, (String, usize)>) {
        r.outputs.clear();
        r.text = 0;
        r.images = 0;
        r.clear_pending = false;
        displays.retain(|_, (m, _)| *m != r.msg_id);
    }

    fn start_output(r: &mut CellRun, displays: &mut HashMap<String, (String, usize)>) {
        if r.clear_pending {
            Self::clear(r, displays);
        }
    }

    fn add_with_display(&mut self, run: &str, out: Output, id: Option<String>) -> Option<()> {
        let r = self.runs.get_mut(run)?;
        Self::start_output(r, &mut self.displays);
        let at = r.outputs.len();
        if Self::add(r, out)
            && let Some(id) = id
        {
            self.displays.insert(id, (run.to_string(), at));
        }
        Some(())
    }

    /// Whether the output was kept (the caps drop it, and the run says so).
    fn add(r: &mut CellRun, out: Output) -> bool {
        r.push_output(out)
    }

    /// A stream grew past the text cap: cut it back to what fits.
    fn cap_text(r: &mut CellRun) {
        if r.text > MAX_TEXT {
            r.truncated = true;
            let over = r.text - MAX_TEXT;
            if let Some(Output::Stream { text, .. }) = r.outputs.last_mut() {
                text.truncate_back(over);
            }
            r.text = MAX_TEXT;
        }
    }

    fn log_message(&mut self, m: &Message) -> Option<Change> {
        let text = match m.header.msg_type.as_str() {
            "stream" => m
                .content
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            "error" => m
                .content
                .get("evalue")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            _ => String::new(),
        };
        let text: String = text.chars().take(LOG_TEXT).collect();
        if self.log.len() >= LOG_ENTRIES {
            self.log.pop_front();
        }
        self.log.push_back(LogEntry {
            msg_type: m.header.msg_type.chars().take(LOG_TYPE).collect(),
            text,
        });
        Some(Change::Log)
    }
}

/// `transient.display_id` of a display message.
fn display_id(m: &Message) -> Option<String> {
    m.content
        .get("transient")?
        .get("display_id")?
        .as_str()
        .map(String::from)
}

#[cfg(test)]
mod tests;
