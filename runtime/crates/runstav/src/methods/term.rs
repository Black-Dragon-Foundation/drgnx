//! The terminals (docs/develop/terminal.md, "The hub's methods"): the editor opens a terminal (`term/open`), whose
//! worker draws it as the hub-built view `term:<id>` (`view-patch`, acknowledged by `view/ack`), and sends it input,
//! sizes and settings; the worker's events come back as `term/*` events to the connection of the editor session that
//! opened it. Ids are in values and arrays, never object keys.

use super::{Empty, invalid, method};
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The longest terminal id, in bytes.
pub const ID_MAX: usize = 32;
/// The most settings, environment entries or arguments one message carries.
pub const LIST_MAX: usize = 4096;
/// The longest text one input message carries, in bytes (a paste may be large).
pub const TEXT_MAX: usize = 1 << 20;

/// A setting's value: a number, a flag or a string.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum SettingValue {
    Flag(bool),
    Number(i64),
    Text(String),
    List(Vec<String>),
}

impl From<SettingValue> for Value {
    fn from(v: SettingValue) -> Value {
        match v {
            SettingValue::Flag(b) => Value::Bool(b),
            SettingValue::Number(n) => Value::from(n),
            SettingValue::Text(s) => Value::String(s),
            SettingValue::List(l) => Value::from(l),
        }
    }
}

/// `term/open`: a terminal running COMMAND (none: `SHELL` from ENV, else `/bin/sh`) in DIR with exactly ENV, of COLS
/// × ROWS cells of CELL_PX, for display class CLASS. CONFIG are its first settings, as `term/config`'s. Answered with
/// its id and its view (`term:<id>`); the first patch is a reset.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermOpen {
    pub dir: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub cell_px: (u32, u32),
    pub class: String,
    /// The rows above the screen the buffer keeps (`drgnx-term-scrollback-lines`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<u32>,
    #[serde(default)]
    pub config: Vec<(String, SettingValue)>,
    /// The worker's scope's `MemoryMax` and `TasksMax` under a user systemd: a number, with K, M, G or T for memory
    /// (`drgnx-term-linux-cgroup-memory-limit`, `-processes-limit`); none: systemd's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_max: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tasks_max: Option<String>,
    /// Where the editor shows it (`panel`, `editor`): kept for a reattach.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    /// A terminal in a remote folder: TRAMP's prefix of it (`/ssh:host:`), kept for a reattach.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
}

/// `term/open`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermOpened {
    pub id: String,
    pub view: String,
}

/// `term/config`: live settings, `[name, value]` each: `scrollback-lines`, `scrollback-bytes`, `clipboard-write`,
/// `cursor-style`, `enquiry-response`, `title-report`, `grapheme-width-method`, and `colours`
/// (`[fg, bg, cursor, c0 … c15]` as `#rrggbb`, "" for the built-in one: what a program reads back).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermConfig {
    pub id: String,
    pub config: Vec<(String, SettingValue)>,
}

/// `term/key`: a key event, encoded by the worker from the terminal's modes. KEY is its name (`a`, `return`, `f5`),
/// MODS its modifiers (`ctrl`, `shift`, `alt`, `super`), TEXT what it types, UNSHIFTED the codepoint without shift,
/// ACTION `press` (the default), `repeat` or `release`: a repeat or a release reaches the program as itself only while
/// it asked for key event types (the view's `term.key_events`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermKey {
    pub id: String,
    pub key: String,
    #[serde(default)]
    pub mods: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unshifted: Option<u32>,
    #[serde(default, skip_serializing_if = "TermKeyAction::is_press")]
    pub action: TermKeyAction,
}

/// `term/key`'s ACTION.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum TermKeyAction {
    #[default]
    Press,
    Repeat,
    Release,
}

impl TermKeyAction {
    fn is_press(&self) -> bool {
        *self == TermKeyAction::Press
    }
}

/// `term/text` (input method text, sent as is) and `term/paste` (bracketed when the program asked).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermText {
    pub id: String,
    pub text: String,
}

/// `term/focus`: the terminal's window gained (IN) or lost focus.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermFocus {
    pub id: String,
    #[serde(rename = "in")]
    pub focus_in: bool,
}

/// `term/mouse`: KIND `press`, `release` or `motion`, BUTTON 1–11 (0: none), the cell (0-based); sent to the
/// program only while it tracks the mouse.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermMouse {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub button: i32,
    pub col: u32,
    pub row: u32,
    #[serde(default)]
    pub mods: Vec<String>,
}

/// `term/resize`: the window's size in cells and the cell in px; the lines rewrap, so the next patch is a reset.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermResize {
    pub id: String,
    pub cols: u16,
    pub rows: u16,
    pub cell_px: (u32, u32),
}

/// `term/scroll`: where to scroll: TO `bottom` (the cursor's row), DELTA rows from FROM (a row key; none: the
/// cursor's row), or PROMPT_DELTA shell prompts from it (OSC 133 marks). Answered with the row's key (none: no such
/// row).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermScroll {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delta: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_delta: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

/// `term/scroll`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermRowKey {
    pub key: Option<String>,
}

/// `term/fetch`: the next rows above the screen the buffer lacks, now (above BEFORE_KEY when given; at most MAX_BYTES
/// of rows, 40 kB by default), as a `view-patch` that goes even while another is unacknowledged. Answered with that
/// patch's version (none: nothing is missing).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermFetch {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bytes: Option<u32>,
}

/// `term/fetch`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermFetched {
    pub version: Option<u64>,
}

/// `term/search`: QUERY in every row the terminal holds, the buffer's and above it; DIR `up` (newest first, the
/// default) or `down`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermSearch {
    pub id: String,
    pub query: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dir: Option<String>,
}

/// `term/search`'s answer: FOUND matches, HELD of them in rows the buffer holds; those went first to the terminal's
/// view as its `view-model` MODEL (a list `matches`; none when no editor is attached).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermMatches {
    pub found: u32,
    pub held: u32,
    pub model: Option<u64>,
}

/// `term/text-range`: the text from row FROM_KEY to row TO_KEY (none: the oldest row the terminal holds, beyond the
/// buffer's window; the last row with text), one line per row.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermTextRange {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to_key: Option<String>,
}

/// `term/text-range`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermTextAnswer {
    pub text: String,
}

/// `term/close`: end the terminal's program (SIGHUP, or SIGNAL); `term/exit` follows.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermClose {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal: Option<i32>,
}

/// `term/session-end`: the terminals of the session to KEEP running, detached; the rest end.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermSessionEnd {
    #[serde(default)]
    pub keep: Vec<String>,
}

/// `term/attach`: take an orphaned or detached terminal into this connection's session, at COLS × ROWS cells of
/// CELL_PX. Answered as `term/open` is; the first patch is a reset.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermAttach {
    pub id: String,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub cell_px: (u32, u32),
}

/// One terminal in `term/list`: whether a program runs in it (a worker that does not answer within 200 ms counts as
/// running), and OLD for one from before an update (only `term/close` reaches it). MINE: it draws for the asking
/// connection's session; ORPHANED: no live connection carries its session; DETACHED_AT (ms since the epoch): its
/// session went past the grace, or quit keeping it. Only an orphaned or detached terminal can be taken (`term/attach`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct TermStatus {
    pub id: String,
    pub pid: i32,
    pub running: bool,
    pub cwd: String,
    pub title: String,
    pub old: bool,
    pub mine: bool,
    pub orphaned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detached_at: Option<u64>,
    #[serde(default)]
    pub command: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
}

/// `term/detached`: terminals were left running by a session that is gone; a live editor may offer them.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermDetached {
    pub ids: Vec<String>,
}

/// `term/exit`: the terminal's program ended, with its exit code or the signal that ended it (both none: its worker
/// went away without saying).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermExit {
    pub id: String,
    pub code: Option<i32>,
    pub signal: Option<i32>,
}

/// `term/title`: the program set the title (OSC 0/2).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermTitle {
    pub id: String,
    pub title: String,
}

/// `term/cwd`: the shell's working directory (OSC 7), as the URL or path it sent.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermCwd {
    pub id: String,
    pub cwd: String,
}

/// `term/bell`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermBell {
    pub id: String,
}

/// `term/notify`: a desktop notification the program asked for (OSC 9, 777).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermNotify {
    pub id: String,
    pub title: String,
    pub body: String,
}

/// `term/progress`: OSC 9;4, STATE 0 none, 1 set, 2 error, 3 indeterminate, 4 paused; VALUE 0–100 (-1: none).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermProgress {
    pub id: String,
    pub state: i32,
    pub value: i32,
}

/// `term/clipboard-write`: the program wrote the clipboard (OSC 52, when `clipboard-write` allows); DATA is the text.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermClipboardWrite {
    pub id: String,
    pub primary: bool,
    pub mime: String,
    pub data: String,
}

/// `term/prompt`: a shell integration mark (OSC 133): KIND 1 prompt, 2 input, 3 output (a program runs), 4 the command
/// ended with EXIT.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TermPrompt {
    pub id: String,
    pub kind: i32,
    pub exit: Option<i32>,
}

/// Request-type params all carry a terminal id.
trait HasId {
    fn id(&self) -> &str;
}

macro_rules! has_id {
    ($($t:ty),+) => { $(impl HasId for $t { fn id(&self) -> &str { &self.id } })+ };
}
has_id!(
    TermConfig,
    TermKey,
    TermText,
    TermFocus,
    TermMouse,
    TermResize,
    TermAttach,
    TermScroll,
    TermFetch,
    TermSearch,
    TermTextRange,
    TermClose
);

fn check_id<T: HasId>(p: &T) -> Result<(), Error> {
    let id = p.id();
    if id.is_empty() || id.len() > ID_MAX {
        return Err(invalid("id", "a terminal id of 1 to 32 bytes"));
    }
    Ok(())
}

fn check_open(p: &TermOpen) -> Result<(), Error> {
    if p.class.is_empty() || p.class.len() > super::view::CLASS_MAX {
        return Err(invalid("class", "a display class of 1 to 64 bytes"));
    }
    if p.env.len() > LIST_MAX
        || p.config.len() > LIST_MAX
        || p.command.as_ref().is_some_and(|c| c.len() > LIST_MAX)
    {
        return Err(invalid(
            "env",
            "at most 4096 entries, settings or arguments",
        ));
    }
    if p.cols == 0 || p.rows == 0 {
        return Err(invalid("cols", "at least one column and one row"));
    }
    if !p.dir.starts_with('/') {
        return Err(invalid("dir", "an absolute directory"));
    }
    let limit = |v: &Option<String>, units: &[char]| {
        v.as_deref().is_none_or(|s| {
            let digits = s.strip_suffix(|c: char| units.contains(&c)).unwrap_or(s);
            !digits.is_empty() && digits.len() <= 20 && digits.bytes().all(|b| b.is_ascii_digit())
        })
    };
    if !limit(&p.memory_max, &['K', 'M', 'G', 'T']) || !limit(&p.tasks_max, &[]) {
        return Err(invalid(
            "memory_max",
            "a number of bytes (K, M, G or T after it) or of tasks",
        ));
    }
    Ok(())
}

fn check_text(p: &TermText) -> Result<(), Error> {
    check_id(p)?;
    if p.text.len() > TEXT_MAX {
        return Err(invalid("text", "at most 1 MiB of text"));
    }
    Ok(())
}

fn check_resize(p: &TermResize) -> Result<(), Error> {
    check_id(p)?;
    if p.cols == 0 || p.rows == 0 {
        return Err(invalid("cols", "at least one column and one row"));
    }
    Ok(())
}

fn check_attach(p: &TermAttach) -> Result<(), Error> {
    check_id(p)?;
    if p.cols == 0 || p.rows == 0 {
        return Err(invalid("cols", "at least one column and one row"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "term/open", TermOpen(TermOpen) -> TermOpened,
            classes: [User], writes: false,
            doc: "open a terminal: its worker runs the command (else the shell) on a PTY and draws the view term:<id>, a reset first; its events go to this editor session",
            check: check_open,
        ),
        method!(
            "term/config", TermConfig(TermConfig) -> bool,
            classes: [User], writes: false,
            doc: "a terminal's live settings, [name, value] each: scrollback-lines (the buffer's window, trimmed or backfilled at once), scrollback-bytes, clipboard-write",
            check: check_id,
        ),
        method!(
            "term/key", TermKey(TermKey) -> bool,
            classes: [User], writes: false,
            doc: "a key press, repeat or release, encoded by the worker from the terminal's modes (kitty keyboard, modifyOtherKeys, DECCKM); its echo is drawn at once",
            check: check_id,
        ),
        method!(
            "term/text", TermText(TermText) -> bool,
            classes: [User], writes: false,
            doc: "text from an input method, sent to the program as it is",
            check: check_text,
        ),
        method!(
            "term/paste", TermPaste(TermText) -> bool,
            classes: [User], writes: false,
            doc: "pasted text, bracketed when the program asked (mode 2004)",
            check: check_text,
        ),
        method!(
            "term/focus", TermFocus(TermFocus) -> bool,
            classes: [User], writes: false,
            doc: "the terminal's window gained or lost focus: reported to the program when it asked (mode 1004)",
            check: check_id,
        ),
        method!(
            "term/mouse", TermMouse(TermMouse) -> bool,
            classes: [User], writes: false,
            doc: "a mouse press, release or motion at a cell: sent to the program only while it tracks the mouse",
            check: check_id,
        ),
        method!(
            "term/resize", TermResize(TermResize) -> bool,
            classes: [User], writes: false,
            doc: "the terminal's size in cells and its cell in px: the lines rewrap and the next view-patch is a reset",
            check: check_resize,
        ),
        method!(
            "term/scroll", TermScroll(TermScroll) -> TermRowKey,
            classes: [User], writes: false,
            doc: "the row to scroll to: the bottom, some rows from a row, or some shell prompts from it (OSC 133); its key, none when there is no such row",
            check: check_id,
        ),
        method!(
            "term/fetch", TermFetch(TermFetch) -> TermFetched,
            classes: [User], writes: false,
            doc: "the next rows above the screen the buffer lacks, now, as a view-patch even while another waits for its view/ack: that patch's version, none when nothing is missing",
            check: check_id,
        ),
        method!(
            "term/search", TermSearch(TermSearch) -> TermMatches,
            classes: [User], writes: false,
            doc: "a string in every row the terminal holds, above the buffer's window too: [key, col, len] per match, newest first (dir up) or oldest first (down)",
            check: check_id,
        ),
        method!(
            "term/text-range", TermTextRange(TermTextRange) -> TermTextAnswer,
            classes: [User], writes: false,
            doc: "the text of the rows from one key to another, one line per row; with no first key from the oldest row the terminal holds, beyond the buffer's window",
            check: check_id,
        ),
        method!(
            "term/close", TermClose(TermClose) -> bool,
            classes: [User], writes: false,
            doc: "end a terminal's program (SIGHUP, or the signal given): term/exit follows; false for no such terminal",
            check: check_id,
        ),
        method!(
            "term/list", TermList(Empty) -> Vec<TermStatus>,
            classes: [User], writes: false,
            doc: "every terminal: its worker's pid, whether a program runs in it (no answer within 200 ms counts as running), its cwd, title and command, whether it is from before an update, whether it is this session's, orphaned (no live connection carries its session) or detached (since when), and where it was shown",
        ),
        method!(
            "term/session-end", TermSessionEnd(TermSessionEnd) -> u32,
            classes: [User], writes: false,
            doc: "the editor exits cleanly: every terminal of the session this connection's hello named ends now, without the 60 s grace, but those in keep, which detach and run on; how many ended",
        ),
        method!(
            "term/attach", TermAttach(TermAttach) -> TermOpened,
            classes: [User], writes: false,
            doc: "take an orphaned or detached terminal into this connection's session at a size: it draws here from a reset, its program redraws (SIGWINCH); refused for a terminal another live session has",
            check: check_attach,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    /// A schema that is a map: an object whose keys are data (ids), not field names.
    fn maps(v: &Value, at: &str, out: &mut Vec<String>) {
        match v {
            Value::Object(m) => {
                let map = m.contains_key("patternProperties")
                    || m.get("additionalProperties")
                        .is_some_and(|a| !matches!(a, Value::Bool(false)))
                        && !m.contains_key("properties");
                if map {
                    out.push(at.to_owned());
                }
                for (k, x) in m {
                    maps(x, &format!("{at}/{k}"), out);
                }
            }
            Value::Array(a) => a
                .iter()
                .enumerate()
                .for_each(|(i, x)| maps(x, &format!("{at}/{i}"), out)),
            _ => {}
        }
    }

    /// The terminals' methods and events carry ids in values and arrays, never as object keys.
    #[test]
    fn term_protocol_uses_no_ids_as_object_keys() {
        let methods: Vec<_> = crate::registry::registry()
            .iter()
            .filter(|m| m.name.starts_with("term/"))
            .collect();
        assert_eq!(
            methods.len(),
            16,
            "the term/ methods: {:?}",
            methods.iter().map(|m| m.name).collect::<Vec<_>>()
        );
        let mut found = Vec::new();
        for m in methods {
            maps(
                &serde_json::to_value((m.params)()).unwrap(),
                &format!("{} params", m.name),
                &mut found,
            );
            maps(
                &serde_json::to_value((m.result)()).unwrap(),
                &format!("{} result", m.name),
                &mut found,
            );
        }
        let events: Vec<_> = crate::events::events()
            .iter()
            .filter(|e| e.name.starts_with("term/"))
            .collect();
        assert_eq!(
            events.len(),
            9,
            "the term/ events: {:?}",
            events.iter().map(|e| e.name).collect::<Vec<_>>()
        );
        for e in events {
            maps(
                &serde_json::to_value((e.data)()).unwrap(),
                e.name,
                &mut found,
            );
        }
        assert!(found.is_empty(), "maps (ids as keys) at {found:?}");
    }
}
