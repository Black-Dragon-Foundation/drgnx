//! The trace supervisor: the files a shell step's processes opened, seen by Gleipnir's tracer (layer 2 of reads through
//! shell commands; docs/develop/work-space.md, "Shell reads"; docs/guide/work-space.md, "Reads through shell commands").
//!
//! Gleipnir answers each notified open itself and hands what it read on ([`gleipnir::trace`]); this module decides
//! which commands are traced, keeps what each one opened, ties it to its timeline step and gives it to the presence
//! model as `opened`, after its rules:
//! - only paths under the session's roots, each by its true name (a link out of them is dropped);
//! - never git-ignored paths (git's own rules, asked once per path and cached), toolchain or system paths;
//! - deduplicated per step, reads and writes apart; a read that is missing after the continue is a failed probe and
//!   dropped (the misses are cached per step); a write is checked at step close, never at its `O_CREAT`;
//! - the budget: a traced step may gain at most max(5 %, 50 ms) of its time, never more than 250 ms (spike S4). Over
//!   it, the rest of the step is continued unread, what it saw is dropped, the step is labelled "opens not traced for
//!   this build", and the command's head is not traced again in that worktree.
//!
//! Attribution: per step (Claude Code's `CLAUDE_CODE_SHELL_PREFIX`), a wrapper's offer is traced only when it is the
//! command of the session's open shell step, and that step's close takes what it opened; whole tree (Codex, Gemini,
//! opt-in), the opens go to the shell step open when they arrive, labelled when two run at once.
//!
//! [`Core`] is pure: it takes the traces' events and the steps' closes in any order and says, once per step, what the
//! step opened. [`touches`] applies the rules through a [`Probe`]; [`Traces`] is the hub's side.

use crate::work::presence::Touch;
use runstav::methods::work::{PresenceMode as Mode, PresenceSource as Source};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

/// Heads never traced (design §7.5's list, and spike S4's additions): their opens cost more than they tell.
pub const SKIP_HEADS: &[&str] = &[
    "cargo", "make", "ninja", "cmake", "npm", "pnpm", "yarn", "pytest", "podman", "emacs",
    "nidhogg", "drgnx",
];
/// `go` is skipped only for these subcommands.
const SKIP_GO: &[&str] = &["build", "test"];
/// Words before a command's own head.
const PREFIXES: &[&str] = &["env", "time", "nice", "nohup", "command", "exec", "builtin"];

/// A traced open's cost beside the answering thread's own time: the kernel's round trip (spike S4: 5.4 µs).
pub const ROUND_TRIP_NS: u64 = 6_000;
/// A traced step's budget: max(5 %, 50 ms), never more than 250 ms.
pub const BUDGET_FLOOR_NS: u64 = 50_000_000;
pub const BUDGET_CAP_NS: u64 = 250_000_000;

/// The step's label when its opens were not traced: the skip list or the budget.
pub const LABEL_BUILD: &str = "opens not traced for this build";
/// The label on macOS, which has no tracer.
pub const LABEL_MACOS: &str = "opens are not traced on macOS";

/// The label of a provider whose tracing is off in `agents-trace-opens`.
pub fn label_off(provider: &str) -> String {
    format!("opens not traced for {provider}: turned off in settings")
}

/// The label of a step whose opens may be another's too.
pub fn label_parallel(n: usize) -> String {
    format!("one of {n} parallel commands")
}

/// Whether a traced step is over its budget: ELAPSED ns since it began, NOTIFICATIONS so far, ANSWERING ns the
/// answering thread spent.
pub fn over_budget(elapsed_ns: u64, notifications: u64, answering_ns: u64) -> bool {
    let cost = answering_ns.saturating_add(notifications.saturating_mul(ROUND_TRIP_NS));
    let allowed = (elapsed_ns / 20).clamp(BUDGET_FLOOR_NS, BUDGET_CAP_NS);
    cost > allowed
}

/// The simple commands of CMD, each as its first words after assignments and prefixes (`cd x && cargo build` → `cd
/// x`, `cargo build`). Quotes are kept together; anything this does not follow (`$(…)`) only adds words.
fn commands(cmd: &str) -> Vec<Vec<String>> {
    let mut out = vec![Vec::new()];
    let mut word = String::new();
    let mut quote: Option<char> = None;
    let mut chars = cmd.chars().peekable();
    let end_word = |word: &mut String, out: &mut Vec<Vec<String>>| {
        if !word.is_empty() {
            out.last_mut().unwrap().push(std::mem::take(word));
        }
    };
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => quote = Some(c),
            (None, '\\') => {
                if let Some(n) = chars.next() {
                    word.push(n);
                }
            }
            (None, ';' | '&' | '|' | '\n' | '(' | ')') => {
                end_word(&mut word, &mut out);
                if !out.last().unwrap().is_empty() {
                    out.push(Vec::new());
                }
            }
            (None, c) if c.is_whitespace() => end_word(&mut word, &mut out),
            (None, c) => word.push(c),
        }
    }
    end_word(&mut word, &mut out);
    out.into_iter()
        .map(|words| {
            words
                .into_iter()
                .skip_while(|w| is_assignment(w) || PREFIXES.contains(&w.as_str()))
                .collect::<Vec<_>>()
        })
        .filter(|w| !w.is_empty())
        .collect()
}

fn is_assignment(w: &str) -> bool {
    w.split_once('=').is_some_and(|(k, _)| {
        !k.is_empty()
            && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && !k.starts_with(|c: char| c.is_ascii_digit())
    })
}

fn basename(w: &str) -> &str {
    w.rsplit('/').next().unwrap_or(w)
}

/// The head CMD is not traced for, if any: one on [`SKIP_HEADS`] (`go` only to build or test), or one LEARNED (a
/// command of this worktree that went over the budget). Any simple command of a chain counts.
pub fn skip_head(cmd: &str, learned: &BTreeSet<String>) -> Option<String> {
    commands(cmd).into_iter().find_map(|words| {
        let head = basename(&words[0]).to_string();
        let listed = SKIP_HEADS.contains(&head.as_str())
            || (head == "go" && words.get(1).is_some_and(|s| SKIP_GO.contains(&s.as_str())));
        (listed || learned.contains(&head)).then_some(head)
    })
}

/// The heads CMD runs, by basename (what a step over the budget teaches the worktree's skip list).
pub fn heads(cmd: &str) -> Vec<String> {
    commands(cmd)
        .into_iter()
        .map(|w| basename(&w[0]).to_string())
        .filter(|h| h != "cd")
        .collect()
}

/// Whether the wrapper's OFFERED command is STEP's: the same text, or STEP inside what the CLI wrapped around it (as
/// given, or single-quoted for a shell).
pub fn command_matches(offered: &str, step: &str) -> bool {
    let step = step.trim();
    if step.is_empty() {
        return false;
    }
    let quoted = format!("'{}'", step.replace('\'', r"'\''"));
    offered.trim() == step || offered.contains(step) || offered.contains(&quoted)
}

// ---- the core ----

/// What the supervisor is told, in whatever order the shell sees it.
#[derive(Clone, Debug, PartialEq)]
pub enum TraceEv {
    /// TRACE began for the shell step whose command is COMMAND. With a LABEL it is not read (the skip list): it then
    /// needs no end. A TREE trace ends when its step closes.
    Started {
        trace: u64,
        command: String,
        tree: bool,
        label: Option<String>,
    },
    /// TRACE's command opened PATH (absolute), to WRITE or to read; PARALLEL shell steps were open then.
    Opened {
        trace: u64,
        path: PathBuf,
        write: bool,
        parallel: usize,
    },
    /// TRACE went over the budget: what it saw is dropped and its step labelled.
    Over { trace: u64 },
    /// TRACE's listener ended: every process it covered is gone.
    Ended { trace: u64 },
    /// The session's shell step STEP (its command COMMAND) closed AT.
    StepClosed { step: i64, command: String, at: f64 },
}

/// What one step's traced command opened, before the rules.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Seen {
    pub reads: BTreeSet<PathBuf>,
    pub writes: BTreeSet<PathBuf>,
}

/// One step's outcome, given once: what it opened, or why it is not known.
#[derive(Clone, Debug, PartialEq)]
pub struct Emit {
    pub step: i64,
    pub at: f64,
    pub seen: Seen,
    pub label: Option<String>,
}

#[derive(Clone, Debug)]
struct Trace {
    command: String,
    tree: bool,
    seen: Seen,
    label: Option<String>,
    ended: bool,
    step: Option<(i64, f64)>,
    parallel: usize,
}

/// The most traces kept waiting for a step that may never come (a command no step closes on).
const PENDING_MAX: usize = 64;

/// One session's traces and the steps they belong to (see the module). Pure.
#[derive(Clone, Debug, Default)]
pub struct Core {
    traces: BTreeMap<u64, Trace>,
}

impl Core {
    pub fn new() -> Core {
        Core::default()
    }

    /// EV into the core; the steps now complete, each once.
    pub fn apply(&mut self, ev: TraceEv) -> Vec<Emit> {
        match ev {
            TraceEv::Started {
                trace,
                command,
                tree,
                label,
            } => {
                let ended = label.is_some() && !tree;
                self.traces.insert(
                    trace,
                    Trace {
                        command,
                        tree,
                        seen: Seen::default(),
                        label,
                        ended,
                        step: None,
                        parallel: 1,
                    },
                );
                while self.traces.len() > PENDING_MAX {
                    let Some(old) = self.traces.keys().next().copied() else {
                        break;
                    };
                    self.traces.remove(&old);
                }
            }
            TraceEv::Opened {
                trace,
                path,
                write,
                parallel,
            } => {
                if let Some(t) = self.traces.get_mut(&trace)
                    && t.label.is_none()
                {
                    let set = if write {
                        &mut t.seen.writes
                    } else {
                        &mut t.seen.reads
                    };
                    set.insert(path);
                    t.parallel = t.parallel.max(parallel);
                }
            }
            TraceEv::Over { trace } => {
                if let Some(t) = self.traces.get_mut(&trace) {
                    t.label = Some(LABEL_BUILD.into());
                    t.seen = Seen::default();
                }
            }
            TraceEv::Ended { trace } => {
                if let Some(t) = self.traces.get_mut(&trace) {
                    t.ended = true;
                }
            }
            TraceEv::StepClosed { step, command, at } => {
                if let Some(t) = self
                    .traces
                    .values_mut()
                    .find(|t| t.step.is_none() && command_matches(&t.command, &command))
                {
                    t.step = Some((step, at));
                    if t.tree {
                        t.ended = true;
                    }
                }
            }
        }
        self.due()
    }

    fn due(&mut self) -> Vec<Emit> {
        let done: Vec<u64> = self
            .traces
            .iter()
            .filter(|(_, t)| t.ended && t.step.is_some())
            .map(|(id, _)| *id)
            .collect();
        done.into_iter()
            .filter_map(|id| self.traces.remove(&id))
            .filter_map(|t| {
                let (step, at) = t.step?;
                let label = t
                    .label
                    .or_else(|| (t.parallel > 1).then(|| label_parallel(t.parallel)));
                Some(Emit {
                    step,
                    at,
                    seen: t.seen,
                    label,
                })
            })
            .collect()
    }

    /// The trace open for COMMAND's step in a whole-tree session, if one is.
    pub fn tree_trace(&self, command: &str) -> Option<u64> {
        self.traces
            .iter()
            .find(|(_, t)| t.tree && t.step.is_none() && t.command == command)
            .map(|(id, _)| *id)
    }

    /// Traces not yet given out.
    pub fn pending(&self) -> usize {
        self.traces.len()
    }
}

// ---- the rules ----

/// The rules' I/O: a path's true name, and which paths git ignores.
pub trait Probe {
    /// P's true name (links followed), or `None` when it does not exist.
    fn real(&mut self, p: &Path) -> Option<PathBuf>;
    /// Of PATHS (true names under ROOT), those git ignores.
    fn ignored(&mut self, root: &Path, paths: &[PathBuf]) -> BTreeSet<PathBuf>;
}

/// Where opens are kept: under one of `roots`, never under one of `never`.
#[derive(Clone, Debug, Default)]
pub struct Rules {
    pub roots: Vec<PathBuf>,
    pub never: Vec<PathBuf>,
}

/// System paths no trace keeps (design §7.5).
const SYSTEM: &[&str] = &["/usr", "/etc", "/proc", "/sys", "/dev"];
/// Toolchain and cache paths under the home no trace keeps: cargo's, rustup's, mise's and npm's.
const HOME_NEVER: &[&str] = &[
    ".cargo",
    ".rustup",
    ".local/share/mise",
    ".cache/mise",
    ".npm",
];

impl Rules {
    /// ROOTS kept; the system, HOME's toolchains and caches, and TOOLCHAIN (Gleipnir's toolchain roots) never.
    pub fn new(roots: Vec<PathBuf>, home: Option<&Path>, toolchain: &[PathBuf]) -> Rules {
        let mut never: Vec<PathBuf> = SYSTEM.iter().map(PathBuf::from).collect();
        if let Some(h) = home {
            never.extend(HOME_NEVER.iter().map(|d| h.join(d)));
        }
        never.extend(toolchain.iter().cloned());
        Rules { roots, never }
    }

    fn root_of(&self, p: &Path) -> Option<&Path> {
        self.roots
            .iter()
            .filter(|r| p.starts_with(r))
            .max_by_key(|r| r.components().count())
            .map(PathBuf::as_path)
    }
}

/// P without `.` and `..` (lexically, before its true name is asked).
fn clean(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// What SEEN keeps under RULES, as presence (`opened`, no line): each path by its true name, under a root and
/// nowhere it never is, not git-ignored; a missing one is dropped (a write is looked at now, at its step's close).
pub fn touches(seen: &Seen, rules: &Rules, probe: &mut impl Probe) -> Vec<Touch> {
    let mut kept: BTreeMap<PathBuf, Mode> = BTreeMap::new();
    let mut by_root: BTreeMap<PathBuf, Vec<PathBuf>> = BTreeMap::new();
    let all = seen
        .reads
        .iter()
        .map(|p| (p, Mode::Read))
        .chain(seen.writes.iter().map(|p| (p, Mode::Write)));
    for (p, mode) in all {
        let Some(real) = probe.real(&clean(p)) else {
            continue;
        };
        if rules.never.iter().any(|n| real.starts_with(n)) {
            continue;
        }
        let Some(root) = rules.root_of(&real) else {
            continue;
        };
        by_root
            .entry(root.to_path_buf())
            .or_default()
            .push(real.clone());
        let m = kept.entry(real).or_insert(mode);
        *m = (*m).max(mode);
    }
    for (root, paths) in by_root {
        for p in probe.ignored(&root, &paths) {
            kept.remove(&p);
        }
    }
    kept.into_iter()
        .map(|(p, mode)| Touch {
            file: p.to_string_lossy().into_owned(),
            mode,
            line: None,
            source: Source::Opened,
        })
        .collect()
}

mod shell;
pub use shell::{FsProbe, SessionTrace, TraceMode, Traces};

#[cfg(test)]
mod tests;
