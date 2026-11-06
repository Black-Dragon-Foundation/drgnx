//! The hook engine (docs/guide/plugins.md, "Rules and hooks"; docs/develop/plugins.md, "The hook engine").
//!
//! At each of the four points (before a tool call, after an edit, before a commit, at review) the hub asks the
//! user's rules and the enabled plugins' hooks about one step:
//! - [`subscribed`]: does any rule or hook look at this step? If not, the point is what it was before hooks.
//! - [`run`]: the rules in list order, then each plugin's hook in plugin order, within the point's budget. It returns
//!   one [`Record`] per rule or hook that matched.
//! - [`combine`]: the records under the matrix's cell, as an [`Outcome`]. Hooks only narrow: no verdict turns Ask or
//!   Never into Allow.
//!
//! Nothing here runs a plugin itself: [`run`] calls the [`HookHost`] it is given (the plugin host in the hub, a script
//! in the tests), which keeps each hook within the deadline it is handed.

mod combine;
mod rules;
#[cfg(test)]
mod tests;

use std::fmt;
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use brokkr::{Filter, Installed, Manifest};
use serde_json::{Value, json};

pub use brokkr::Point;
pub use combine::{Decision, MAX_ANNOTATION_BYTES, MAX_ANNOTATIONS, Outcome, combine};
pub use rules::{Rule, RuleError, RuleVerdict, glob_match, parse_rules};

/// One step at one point, as the engine matches it. `detail` is the input object a hook gets (docs/develop/
/// plugins.md, "The hook engine"): the point's section (`tool`, `edit`, `commit` or `review`) and the envelope
/// fields the point knows; [`run`] sets `v`, `point`, `session`, `step` and `previous` on it.
#[derive(Debug, Clone, PartialEq)]
pub struct HookInput {
    pub point: Point,
    pub session: Option<String>,
    pub step: Option<i64>,
    /// The normalised kind ([`acp_kind`]), or `drgnx` at the hub's own servers.
    pub tool_kind: Option<String>,
    /// The tool's full name (`Bash`, `mcp__drgnx__merge`).
    pub tool: Option<String>,
    /// Relative to the project root when inside it, absolute otherwise.
    pub paths: Vec<PathBuf>,
    pub command: Option<String>,
    pub detail: Value,
}

/// What a rule or a hook said.
#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// No objection: the matrix still decides.
    Allow,
    Deny(String),
    /// The point's replacement object: `{arguments}`, `{content}`, `{message}` or `{notes}`.
    Change(Value),
    Annotate(String),
}

impl Verdict {
    /// The verdict's word: `allow`, `deny`, `change`, `annotate`.
    pub fn word(&self) -> &'static str {
        match self {
            Verdict::Allow => "allow",
            Verdict::Deny(_) => "deny",
            Verdict::Change(_) => "change",
            Verdict::Annotate(_) => "annotate",
        }
    }
}

/// Who gave a record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// A rule: its `id`, and its place in the effective list.
    Rule { id: Option<String>, index: usize },
    Plugin {
        name: String,
        version: String,
        hash: [u8; 32],
    },
}

impl Source {
    /// The name a failure text uses: the plugin's name, or the rule's `rule:…`.
    pub fn name(&self) -> String {
        match self {
            Source::Plugin { name, .. } => name.clone(),
            Source::Rule { .. } => self.to_string(),
        }
    }
}

impl fmt::Display for Source {
    /// `rule:ID`, else `rule:N`; `plugin:NAME@VERSION#` and the hash's first 4 bytes in hex.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Source::Rule { id: Some(id), .. } => write!(f, "rule:{id}"),
            Source::Rule { id: None, index } => write!(f, "rule:{index}"),
            Source::Plugin {
                name,
                version,
                hash,
            } => {
                write!(f, "plugin:{name}@{version}#")?;
                hash[..4].iter().try_for_each(|b| write!(f, "{b:02x}"))
            }
        }
    }
}

/// One rule's or hook's part in a point run.
///
/// - `verdict` is what it said; `None` when it gave none: it failed (`error` says how) or was not run because an
///   earlier record denied (`error` is `None` too).
/// - `error` is the whole failure text (`hook NAME failed: timed out (2 s)`, `hook NAME not run: the point's time
///   ran out (2 s)`). [`combine`] makes it a deny, or a note when `advisory`.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub source: Source,
    pub verdict: Option<Verdict>,
    pub ms: u32,
    pub error: Option<String>,
    pub advisory: bool,
}

impl Record {
    /// Not run, because an earlier record denied.
    pub fn not_run(&self) -> bool {
        self.verdict.is_none() && self.error.is_none()
    }
}

/// A plugin as the engine needs it: its manifest and the hash the user approved.
pub trait HookPlugin: Send + Sync {
    fn manifest(&self) -> &Manifest;
    fn hash(&self) -> [u8; 32];
}

impl HookPlugin for Installed {
    fn manifest(&self) -> &Manifest {
        &self.manifest
    }
    fn hash(&self) -> [u8; 32] {
        self.hash
    }
}

/// What [`run`] calls a hook through: the plugin host with the call's I/O in the hub, a script in the tests.
pub trait HookHost: Sync {
    type Plugin: HookPlugin;

    /// Runs PLUGIN's hook at POINT on INPUT. The host stops it at DEADLINE. An error is what failed, in the words of
    /// the failure texts: `timed out (2 s)`, `trap: MESSAGE`, `busy (2 calls running)`.
    fn run_hook(
        &self,
        plugin: &Self::Plugin,
        point: Point,
        input: Value,
        deadline: Duration,
    ) -> impl Future<Output = Result<Verdict, String>> + Send;

    /// Re-reads INPUT's matching fields (`paths`, `command`) from its `detail` once an accepted change is written in,
    /// as the point derived them from the original step, so a later hook's filter matches the step that will run.
    fn refresh(&self, input: &mut HookInput);

    /// The clock the point's budget is measured on (the hub's, so its test clock decides).
    fn now(&self) -> tokio::time::Instant {
        tokio::time::Instant::now()
    }
}

/// The kind a hook matches on. The agent's kind is kept only when it is an ACP kind; anything else, `drgnx`
/// included, is `other`. An `other` named `NotebookEdit` is `edit` (the Claude adapter reports notebook edits as
/// `other`). `drgnx` is never returned: only the hub's own servers say it.
pub fn acp_kind(raw: Option<&str>, tool_name: Option<&str>) -> &'static str {
    // brokkr's list is the ACP kinds and the hub's own `drgnx`
    let kind = raw
        .and_then(|r| {
            brokkr::TOOL_KINDS
                .iter()
                .copied()
                .find(|k| *k == r && *k != "drgnx")
        })
        .unwrap_or("other");
    if kind == "other" && tool_name == Some("NotebookEdit") {
        "edit"
    } else {
        kind
    }
}

/// Whether PATHS has one path matching one of GLOBS (an empty GLOBS matches everything).
fn paths_match(globs: &[brokkr::manifest::Glob], paths: &[PathBuf]) -> bool {
    globs.is_empty()
        || paths.iter().any(|p| {
            let p = p.to_string_lossy();
            globs.iter().any(|g| glob_match(g.as_str(), &p))
        })
}

/// Whether a hook FILTER matches INPUT. The fields AND together; an empty field matches everything.
fn filter_matches(filter: Option<&Filter>, input: &HookInput) -> bool {
    let Some(f) = filter else { return true };
    let listed = |list: &[String], v: &Option<String>| {
        list.is_empty() || v.as_ref().is_some_and(|v| list.contains(v))
    };
    listed(&f.tool_kinds, &input.tool_kind)
        && listed(&f.tools, &input.tool)
        && paths_match(&f.paths, &input.paths)
}

/// PLUGIN's hook at INPUT's point, when its filter matches INPUT.
fn hook_for<'a, P: HookPlugin>(plugin: &'a P, input: &HookInput) -> Option<&'a brokkr::HookDecl> {
    plugin
        .manifest()
        .hooks
        .iter()
        .find(|h| h.point == input.point)
        .filter(|h| filter_matches(h.filter.as_ref(), input))
}

/// Whether any rule or enabled hook looks at INPUT: the points' fast path.
pub fn subscribed<P: HookPlugin>(input: &HookInput, rules: &[Rule], plugins: &[Arc<P>]) -> bool {
    rules.iter().any(|r| r.matches(input))
        || plugins.iter().any(|p| hook_for(&**p, input).is_some())
}

/// `2 s`, or `500 ms` when not whole seconds.
fn span(d: Duration) -> String {
    let ms = d.as_millis();
    if ms.is_multiple_of(1000) {
        format!("{} s", ms / 1000)
    } else {
        format!("{ms} ms")
    }
}

/// The point's word in failure texts and inputs.
fn point_word(p: Point) -> &'static str {
    match p {
        Point::BeforeTool => "before-tool",
        Point::AfterEdit => "after-edit",
        Point::BeforeCommit => "before-commit",
        Point::AtReview => "at-review",
    }
}

/// Where a change at POINT lands in the input: its section, the field in it, the key of the replacement object, and
/// that value's type in failure texts.
fn change_slot(p: Point) -> (&'static str, &'static str, &'static str, &'static str) {
    match p {
        Point::BeforeTool => ("tool", "input", "arguments", "object"),
        Point::AfterEdit => ("edit", "content", "content", "string"),
        Point::BeforeCommit => ("commit", "message", "message", "string"),
        Point::AtReview => ("review", "notes", "notes", "string"),
    }
}

/// CHANGE's new value when it is POINT's replacement object (exactly its one key, of its type).
fn changed_value(p: Point, change: &Value) -> Result<Value, String> {
    let (_, _, key, ty) = change_slot(p);
    let value = change
        .as_object()
        .filter(|o| o.len() == 1)
        .and_then(|o| o.get(key))
        .filter(|v| {
            if ty == "object" {
                v.is_object()
            } else {
                v.is_string()
            }
        });
    value
        .cloned()
        .ok_or_else(|| format!("change for {} must be {{\"{key}\": {ty}}}", point_word(p)))
}

/// The earlier records of this run, as a hook's input shows them.
fn previous(records: &[Record]) -> Value {
    let list = records
        .iter()
        .map(|r| {
            let verdict = match (&r.verdict, &r.error) {
                (Some(v), _) => v.word(),
                (None, Some(_)) => "error",
                (None, None) => "not run",
            };
            json!({"source": r.source.to_string(), "verdict": verdict})
        })
        .collect();
    Value::Array(list)
}

/// Runs the rules, then the plugins' hooks, on INPUT within BUDGET (the whole point's).
///
/// - Only the rules and hooks that match INPUT are run, and only they get a record.
/// - A deny (or a failure of a non-advisory hook) stops the run: the later matches are recorded not run.
/// - Each hook gets the smaller of its `deadline_ms` and what is left of BUDGET. One that would start with nothing
///   left is not run, and its record is that failure.
/// - Each hook sees the earlier records (`previous`) and the last accepted change: it is written into the input
///   (before-tool: `tool.input`; after-edit: `edit.content`; before-commit: `commit.message`; at-review:
///   `review.notes`), then [`HookHost::refresh`] re-reads the matching fields, so later hooks' filters match the
///   step as it will run. Rules run first, before any change, so they always match INPUT as the point gave it.
/// - A change where ACCEPTS_CHANGE is false is that hook's failure ("change is not accepted here") and is never
///   written in; so is a change of the wrong shape, and a verdict the hook's manifest does not declare (`allow` is
///   always allowed).
pub async fn run<H: HookHost>(
    input: &HookInput,
    budget: Duration,
    accepts_change: bool,
    rules: &[Rule],
    plugins: &[Arc<H::Plugin>],
    host: &H,
) -> Vec<Record> {
    let start = host.now();
    let mut records = Vec::new();
    let mut stopped = false;
    for (index, rule) in rules.iter().enumerate() {
        if !rule.matches(input) {
            continue;
        }
        let verdict = match rule.verdict {
            RuleVerdict::Deny => Verdict::Deny(rule.reason.clone()),
            RuleVerdict::Annotate => Verdict::Annotate(rule.reason.clone()),
        };
        let deny = matches!(verdict, Verdict::Deny(_));
        records.push(Record {
            source: Source::Rule {
                id: rule.id.clone(),
                index,
            },
            verdict: (!stopped).then_some(verdict),
            ms: 0,
            error: None,
            advisory: false,
        });
        stopped |= deny;
    }

    // The step as the accepted changes so far leave it: the hooks see it, and their filters match it.
    let mut step = input.clone();
    if !step.detail.is_object() {
        step.detail = json!({});
    }
    step.detail["v"] = json!(1);
    step.detail["point"] = json!(point_word(input.point));
    step.detail["session"] = json!(input.session);
    step.detail["step"] = json!(input.step);
    for plugin in plugins {
        let Some(hook) = hook_for(&**plugin, &step) else {
            continue;
        };
        let m = plugin.manifest();
        let name = m.name.as_str();
        let mut record = Record {
            source: Source::Plugin {
                name: name.to_string(),
                version: m.version.clone(),
                hash: plugin.hash(),
            },
            verdict: None,
            ms: 0,
            error: None,
            advisory: hook.advisory,
        };
        if stopped {
            records.push(record);
            continue;
        }
        let left = budget.saturating_sub(host.now() - start);
        if left.is_zero() {
            record.error = Some(format!(
                "hook {name} not run: the point's time ran out ({})",
                span(budget)
            ));
            stopped |= !hook.advisory;
            records.push(record);
            continue;
        }
        let deadline = hook
            .deadline_ms
            .map_or(left, |d| left.min(Duration::from_millis(u64::from(d))));
        step.detail["previous"] = previous(&records);
        let t0 = host.now();
        let answer = host
            .run_hook(plugin, input.point, step.detail.clone(), deadline)
            .await;
        record.ms = u32::try_from((host.now() - t0).as_millis()).unwrap_or(u32::MAX);
        let checked = answer.and_then(|v| {
            let kind = match &v {
                Verdict::Allow => None,
                Verdict::Deny(_) => Some(brokkr::VerdictKind::Deny),
                Verdict::Change(_) => Some(brokkr::VerdictKind::Change),
                Verdict::Annotate(_) => Some(brokkr::VerdictKind::Annotate),
            };
            if kind.is_some_and(|k| !hook.verdicts.contains(&k)) {
                return Err(format!(
                    "it answered {}, which its manifest does not declare",
                    v.word()
                ));
            }
            if let Verdict::Change(c) = &v {
                // A refused change is never written in: later hooks see the step that will run.
                if !accepts_change {
                    return Err("change is not accepted here".into());
                }
                let new = changed_value(input.point, c)?;
                let (section, field, _, _) = change_slot(input.point);
                let slot = &mut step.detail[section];
                if !slot.is_object() {
                    *slot = json!({});
                }
                slot[field] = new;
                host.refresh(&mut step);
            }
            Ok(v)
        });
        match checked {
            Ok(v) => {
                stopped |= matches!(v, Verdict::Deny(_));
                record.verdict = Some(v);
            }
            Err(what) => {
                record.error = Some(format!("hook {name} failed: {what}"));
                stopped |= !hook.advisory;
            }
        }
        records.push(record);
    }
    records
}
