//! The Work space's methods (agent system part 2; `docs/develop/work-space.md`, `docs/guide/work-space.md`).
//!
//! Machines: `machines/report` (a user connection tells the hub which slots a machine has and who holds them, for a
//! time) and `machines/list`; the event `machines-changed` carries the list again when it changed.
//!
//! Conclusions: `work/conclusions` (a session's decisions and findings, with their steps and links).
//!
//! The presence model: `agents/presence/subscribe`, `agents/presence/get` and the event `agent-presence` (who is in
//! which file, at which line, now). The `agents/` names keep clear of `presence/set`, the user's own away state.
//!
//! The Work map: `work/map/subscribe`, `work/map/set`, `work/map/close`, per (connection, view); its model and rows
//! (`view-model`, `view-patch`) go to that connection only.

use super::{Empty, invalid, method};
use crate::registry::Method;
use crate::types::{Bounded, Id, null_as_empty};
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The workspace a Work view shows: one id, the roots (repositories or folders) it spans. The editor sends it with
/// every subscription; the hub never decides what a workspace is.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    /// `workspace:` and 12 hex digits.
    pub id: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub roots: Vec<std::path::PathBuf>,
}

/// One slot of a machine: where one agent job runs.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub id: String,
    /// Who holds it now (a job or a session id); none when free.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holder: Option<String>,
    /// What the slot is for: `agent-job`, `build`, `test`, `gpu`, ...
    pub kind: String,
}

/// What a reporter (jobq) says about one machine: its slots, valid for `ttl` seconds.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MachineReport {
    pub machine: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub slots: Vec<Slot>,
    /// Seconds the report stands; after that the machine is gone from the list until it reports again.
    pub ttl: f64,
}

/// A machine as the hub lists it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Machine {
    pub machine: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub slots: Vec<Slot>,
    /// The hub's own machine: always listed, never expires.
    pub local: bool,
}

/// `machines/list`'s answer, and the data of `machines-changed`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MachinesList {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub machines: Vec<Machine>,
}

/// `work/conclusions`'s params: a session id.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConclusionsParams {
    pub session: String,
}

/// A spec or plan edit under review: the document now, against its text before (`from`, the git blob id of that
/// text in the document's repository).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DocChange {
    pub doc: std::path::PathBuf,
    pub from: String,
}

/// A code change under review: its files, relative to the repository, and its own branch (a task working on that
/// branch is the change's author, not a task it reaches).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CodeChange {
    pub paths: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
}

/// What `review/effects` looks at.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum ChangeRef {
    Doc(DocChange),
    Code(CodeChange),
}

/// `review/effects`'s params.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EffectsParams {
    pub change: ChangeRef,
}

/// Where a task the change reaches is: under way (running, waiting for an answer, in review) or queued in a run that
/// goes on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum TaskState {
    Running,
    NeedsInput,
    InReview,
    Queued,
}

/// What the change does to a task: it removes the task (or retires its plan or spec), changes its brief (its own text
/// or the plan's shared text), or touches files its agent edits or reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Effect {
    Stops,
    BriefChanges,
    Overlaps,
}

/// One task the change reaches, with the sentence the review shows ("Task 3 is running: it would stop.").
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskEffect {
    /// `JOB#N`.
    pub task: String,
    pub task_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    /// The name of the session working on it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    pub state: TaskState,
    pub effect: Effect,
    pub why: String,
}

/// `machines/move`: move a job, or a session's next jobs, to another machine.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MoveParams {
    /// `job:ID` (a job of the queue) or `session:ID` (an agent: its next jobs).
    pub target: String,
    /// `local` (this machine) or a runner's name.
    pub machine: String,
}

/// `machines/move`'s answer.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MoveResult {
    /// The move is made: a waiting job waits for the machine named, or the session's next jobs go there. False when
    /// it was already there, or when it runs and the user is asked first (`card`).
    pub moved: bool,
    /// The card asking whether to restart a job that runs (Restart / Keep), by id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<String>,
    /// What happened, in words ("its next jobs go to laptop").
    pub said: String,
}

/// What a conclusion rests on: a file with optional lines, or a page.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConclusionSource {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// First and last line, 1-based.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<[u32; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

/// The steps a conclusion links back to (timeline step ids).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConclusionLinks {
    /// The steps its named sources match ("named").
    #[serde(default, deserialize_with = "null_as_empty")]
    pub named: Vec<i64>,
    /// The reads, searches, pages and thoughts since the previous conclusion.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub since_last: Vec<i64>,
    /// Named sources no step of the session matches ("named, not read in this session").
    #[serde(default, deserialize_with = "null_as_empty")]
    pub unmatched: Vec<ConclusionSource>,
}

/// A decision or a finding, as the Work space shows it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Conclusion {
    /// Its number in the session, from 1.
    pub n: u32,
    /// `decision:N`, or the finding's note id.
    pub id: String,
    /// `decision` or `finding`.
    pub kind: String,
    pub text: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub sources: Vec<ConclusionSource>,
    /// The timeline step the hub stamped; absent: step unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<i64>,
    /// When it was recorded (seconds since the epoch).
    pub at: f64,
    /// `own`, `from-brief`, `needs-user`, or `from-text` (a fenced block in a message).
    pub origin: String,
    pub links: ConclusionLinks,
}

/// `work/conclusions`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Conclusions {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub conclusions: Vec<Conclusion>,
}

/// How a session is in a file.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum PresenceMode {
    /// A directory listing or a recursive search over it.
    Listed,
    Read,
    /// About to change: an edit waiting for the user's permission, or still streaming its input.
    Pending,
    /// Written by a shell command.
    Write,
    /// Changed by an edit tool.
    Edit,
}

/// Where the hub saw it.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum PresenceSource {
    /// A read or search step's ACP fields.
    Acp,
    /// An edit step.
    Edit,
    /// A file a shell step's command names ("from the command").
    Command,
    /// A file a shell step's processes opened ("seen open").
    Opened,
}

/// One session in one file: the presence model's entry.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PresenceEntry {
    pub session: String,
    /// An absolute path in one of the workspace's repositories.
    pub file: String,
    pub mode: PresenceMode,
    /// The last line known; absent: the file only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// The last line of its range (a read's `limit`, an edit's changed lines); absent: `line` only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_end: Option<u32>,
    /// The column after the last character an edit inserted (0-based, in characters): where its cursor sits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub col: Option<u32>,
    pub source: PresenceSource,
    /// The timeline step it came from; 0 while it is live.
    pub step: i64,
    /// The hub's time of the step, or of the tool call's last update (seconds since the epoch).
    pub at: f64,
    /// From a tool call still running (`tool_call` names it): replaced by its step's entry when the step closes, and
    /// never kept across a hub restart.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub live: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call: Option<String>,
}

/// Who is in FILE now; the data of `agent-presence`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FilePresence {
    pub file: String,
    /// FILE relative to the top of its git checkout, so a badge lands on the user's tree whatever worktree the agent
    /// is in; absent outside git.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rel: Option<String>,
    /// The project of that checkout: 16 hex digits of its git common directory's main checkout (the same id for every
    /// worktree of one repository, as the code index's).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub entries: Vec<PresenceEntry>,
}

/// `agents/presence/subscribe`'s params: a workspace (every file under its roots) or one file. With a workspace, VIEW
/// (the editor sent its `view/env`) also gets who is here as rows: one per agent, one per shown path.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PresenceSubscribe {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<Workspace>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<String>,
}

/// `agents/presence/get`'s params.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PresenceGet {
    pub file: String,
}

/// The files with someone in them now, each with its entries.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PresenceFiles {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub files: Vec<FilePresence>,
}

/// A map view's density (the look's).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum MapDensity {
    Compact,
    #[default]
    Comfortable,
    Roomy,
}

/// Which items a map view shows: `.` cycles them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum MapShow {
    /// Agents running or waiting on you, what is not started, and what changed within `recent_days`.
    #[default]
    Active,
    /// Finished items only.
    Completed,
    /// Both, the finished ones faded.
    All,
}

/// How a map view is drawn.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum MapMode {
    /// Nested rows: spec, plan, task.
    #[default]
    List,
    /// The layers and the edges between them.
    Graph,
}

fn recent_days() -> u32 {
    7
}

/// A map view's filters: `f` (only an item's chain), `o` (only overlaps and clashes), `.` (Active, Completed or All).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapFilters {
    /// An item id: only its chain.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus: Option<String>,
    #[serde(default)]
    pub overlaps: bool,
    #[serde(default)]
    pub show: MapShow,
    /// Days a changed item stays in Active (`drgnx-work-recent-days`).
    #[serde(default = "recent_days")]
    pub recent_days: u32,
}

impl Default for MapFilters {
    fn default() -> MapFilters {
        MapFilters {
            focus: None,
            overlaps: false,
            show: MapShow::default(),
            recent_days: recent_days(),
        }
    }
}

/// `work/map/subscribe`'s params: one map view of this connection (VIEW is the editor's id for it), the workspace it
/// shows, and how. Its rows come as `view-patch` per display class (`view/env`), the first a reset.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapSubscribe {
    pub view: String,
    pub workspace: Workspace,
    /// The drawing width, in units of 4 px, until the view's GUI classes sent a `view/env` (then theirs).
    pub width_units: u32,
    #[serde(default)]
    pub density: MapDensity,
    /// List (the default) or Graph.
    #[serde(default)]
    pub mode: MapMode,
    #[serde(default)]
    pub filters: MapFilters,
    /// Collapsed layers, 1 to 6.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub collapsed: Vec<u8>,
    /// The selected item: a quiet reflow that would move its chain waits for the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
    /// The form the user asked for (`work/map/set {outline}`, sent again by the editor): `on`, `off` or `auto`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outline: Option<String>,
}

/// `work/map/subscribe`'s answer: the view's patches name this hub and start from a reset.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapRows {
    pub hub: u64,
    pub version: u64,
}

/// One lane of a Timeline: an agent session and its label.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TrailLane {
    pub session: String,
    pub label: String,
}

/// A span of time a Timeline or the Schedule shows, in seconds since the epoch (`from` before `to`).
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Window {
    pub from: f64,
    pub to: f64,
}

/// What a Timeline keeps in colour: every step, the edits, or the waits (on you, a machine, a pause, a stall).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum TrailFilter {
    #[default]
    All,
    Edits,
    Waits,
}

/// `work/trail/subscribe`'s params: one view of the connection shows `session`'s trail, or a Timeline of `lanes`
/// (a plan's, a task's or a machine's sessions: the editor sends the scope's lanes) over `window` (none: the time
/// their last steps cover), following now when `follow`, with `filter`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TrailSubscribe {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lanes: Vec<TrailLane>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<Window>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<TrailFilter>,
}

/// `work/trail/set`'s params: a Timeline view's window, follow and filter, without subscribing again (zoom, pan,
/// filter).  A window given without `follow` stops following.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TrailSet {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<Window>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<TrailFilter>,
}

/// How the Schedule groups its rows: the List's (spec, plan, task), or the tasks under the machine they ran on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ScheduleGroup {
    #[default]
    Plan,
    Machine,
}

/// `work/schedule/subscribe`'s params: one view of the connection shows the Schedule over `window`: the List's rows
/// of the connection's map view, each with its bar.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScheduleSubscribe {
    pub view: String,
    pub window: Window,
    #[serde(default)]
    pub group: ScheduleGroup,
}

/// `work/schedule/set`'s params: a Schedule view's window or grouping, without subscribing again.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScheduleSet {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<Window>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<ScheduleGroup>,
}

/// `work/trail/subscribe`'s answer: the view's patches name this hub and start from a reset.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TrailSubscribed {
    pub hub: u64,
}

/// `work/trail/close`'s params.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TrailClose {
    pub view: String,
}

/// `work/board/subscribe`'s params: one view of the connection shows the Board of the tracker's tasks (of `plans`,
/// else every task), each card naming the agent of map view `map` that works on it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BoardSubscribe {
    pub view: String,
    pub map: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub plans: Vec<String>,
}

/// `work/flow/subscribe`: view `view` shows the Flow lens of job `job` (else the newest running job), with the agents
/// of map view `map` on its tasks.  With `detail` (a task id of that job), the view is the task's detail tile: why
/// the gates hold it, what clears it, its evidence and its actions; with `rules`, the Rules tile (the run's rule pack:
/// each rule, its kind, how the hub holds it), and `detail` with it names the selected task its Evidence tab shows. A
/// tile is rows with no model.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FlowSubscribe {
    pub view: String,
    pub map: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rules: bool,
}

/// `work/map/set`'s params: what changes in one view (each absent field stays).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapSet {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filters: Option<MapFilters>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_units: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub density: Option<MapDensity>,
    /// List or Graph.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<MapMode>,
    /// False: hidden (nothing is sent); true again: its model and rows drawn anew (the model a reset).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shown: Option<bool>,
    /// The selection moved (a map key).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
    /// Nothing is selected any more (Esc, or the selection went with no item left to take it).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub clear: bool,
    /// The form a rows view is drawn in: `on` the outline, `off` the cards, `auto` (where none was asked) the outline
    /// only where the cards do not fit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outline: Option<String>,
}

/// `work/map/set`'s answer: the view's version after it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapVersion {
    pub version: u64,
}

/// `work/map/close`'s params.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapClose {
    pub view: String,
}

/// The longest view id, in bytes.
pub const VIEW_MAX: usize = 64;
/// The widest map, in units.
pub const WIDTH_MAX: u32 = 10_000;

fn check_view(view: &str) -> Result<(), Error> {
    if view.is_empty() || view.len() > VIEW_MAX {
        return Err(invalid("view", "a view id of 1 to 64 bytes"));
    }
    Ok(())
}

fn check_layers(collapsed: &[u8]) -> Result<(), Error> {
    if collapsed.iter().any(|l| !(1..=8).contains(l)) {
        return Err(invalid("collapsed", "layers 1 to 8"));
    }
    Ok(())
}

fn check_width(w: u32) -> Result<(), Error> {
    if w > WIDTH_MAX {
        return Err(invalid("width_units", "at most 10000 units"));
    }
    Ok(())
}

fn check_map_subscribe(p: &MapSubscribe) -> Result<(), Error> {
    check_view(&p.view)?;
    check_width(p.width_units)?;
    check_layers(&p.collapsed)
}

/// `work/target/set`'s params: the target date of a spec or a plan (null clears it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TargetSetParams {
    /// `spec:ID` or `plan:ID`.
    pub item: super::graph::ParsedId,
    /// Seconds since the epoch; null removes the target.
    pub target_at: Option<f64>,
}

fn check_target_set(p: &TargetSetParams) -> Result<(), Error> {
    let item = p.item.as_str();
    if !(item.starts_with("spec:") || item.starts_with("plan:")) {
        return Err(invalid("item", "a spec: or plan: id"));
    }
    if p.target_at.is_some_and(|t| !t.is_finite()) {
        return Err(invalid("target_at", "a finite number of seconds, or null"));
    }
    Ok(())
}

fn check_map_set(p: &MapSet) -> Result<(), Error> {
    check_view(&p.view)?;
    if let Some(w) = p.width_units {
        check_width(w)?;
    }
    check_layers(p.collapsed.as_deref().unwrap_or_default())
}

fn check_map_close(p: &MapClose) -> Result<(), Error> {
    check_view(&p.view)
}

fn check_presence_subscribe(p: &PresenceSubscribe) -> Result<(), Error> {
    match &p.view {
        Some(v) if v.is_empty() || v.len() > super::view::VIEW_MAX => {
            return Err(invalid("view", "a view id of 1 to 64 bytes"));
        }
        Some(_) if p.workspace.is_none() => return Err(invalid("view", "rows need a workspace")),
        _ => {}
    }
    match (&p.workspace, &p.file) {
        (Some(_), None) => Ok(()),
        (None, Some(f)) if f.starts_with('/') => Ok(()),
        (None, Some(_)) => Err(invalid("file", "an absolute path")),
        _ => Err(invalid("workspace", "one of workspace or file")),
    }
}

fn check_presence_get(p: &PresenceGet) -> Result<(), Error> {
    if p.file.starts_with('/') {
        Ok(())
    } else {
        Err(invalid("file", "an absolute path"))
    }
}

/// The most lanes one Timeline holds.
const LANES_MAX: usize = 256;

fn check_trail_subscribe(p: &TrailSubscribe) -> Result<(), Error> {
    check_view(&p.view)?;
    if let Some(w) = &p.window {
        check_window(w)?;
    }
    let name = |s: &str| !s.is_empty() && s.len() <= NAME_MAX;
    match (&p.session, p.lanes.is_empty()) {
        (Some(s), true) if name(s) => Ok(()),
        (Some(_), true) => Err(invalid("session", "a session id")),
        (None, false) if p.lanes.len() > LANES_MAX => Err(invalid("lanes", "at most 256 lanes")),
        (None, false)
            if p.lanes
                .iter()
                .all(|l| name(&l.session) && l.label.len() <= NAME_MAX) =>
        {
            Ok(())
        }
        (None, false) => Err(invalid("lanes", "lanes of a session id and a label")),
        _ => Err(invalid("session", "one of session or lanes")),
    }
}

fn check_trail_close(p: &TrailClose) -> Result<(), Error> {
    check_view(&p.view)
}

/// The longest window a Timeline or the Schedule shows: a year.
pub const WINDOW_MAX: f64 = 366.0 * 86_400.0;

fn check_window(w: &Window) -> Result<(), Error> {
    if !(w.from.is_finite() && w.to.is_finite() && w.from >= 0.0 && w.to > w.from) {
        return Err(invalid("window", "from before to, seconds since the epoch"));
    }
    if w.to - w.from > WINDOW_MAX {
        return Err(invalid("window", "a window of a year at most"));
    }
    Ok(())
}

fn check_trail_set(p: &TrailSet) -> Result<(), Error> {
    check_view(&p.view)?;
    p.window.as_ref().map_or(Ok(()), check_window)
}

fn check_schedule_subscribe(p: &ScheduleSubscribe) -> Result<(), Error> {
    check_view(&p.view)?;
    check_window(&p.window)
}

fn check_schedule_set(p: &ScheduleSet) -> Result<(), Error> {
    check_view(&p.view)?;
    p.window.as_ref().map_or(Ok(()), check_window)
}

/// The most plans one Board is scoped to.
const PLANS_MAX: usize = 64;

fn check_board_subscribe(p: &BoardSubscribe) -> Result<(), Error> {
    check_view(&p.view)?;
    check_view(&p.map).map_err(|_| invalid("map", "a map view id of 1 to 64 bytes"))?;
    if p.plans.len() > PLANS_MAX || p.plans.iter().any(|s| s.is_empty() || s.len() > NAME_MAX) {
        return Err(invalid("plans", "at most 64 plan ids"));
    }
    Ok(())
}

fn check_flow_subscribe(p: &FlowSubscribe) -> Result<(), Error> {
    check_view(&p.view)?;
    check_view(&p.map).map_err(|_| invalid("map", "a map view id of 1 to 64 bytes"))?;
    if p.job
        .as_ref()
        .is_some_and(|j| j.is_empty() || j.len() > NAME_MAX)
    {
        return Err(invalid("job", "a job id"));
    }
    if p.detail
        .as_ref()
        .is_some_and(|t| t.is_empty() || t.len() > NAME_MAX)
    {
        return Err(invalid("detail", "a task id"));
    }
    Ok(())
}

fn check_conclusions(p: &ConclusionsParams) -> Result<(), Error> {
    if p.session.is_empty() || p.session.len() > NAME_MAX {
        return Err(invalid("session", "a session id"));
    }
    Ok(())
}

/// `work/files`: the files session `session` edited.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditedFiles {
    pub session: Id,
}

/// One edited file: its added and removed lines against the worktree's base.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditedFile {
    /// Relative to the worktree.
    pub path: String,
    pub plus: u32,
    pub minus: u32,
    /// The file is not in the base at all (the agent made it).
    pub untracked: bool,
    /// When the agent last read it (seconds); absent until the edit history supplies it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at: Option<f64>,
}

/// `work/files`' answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct EditedFilesList {
    pub files: Vec<EditedFile>,
}

/// `work/hunks`: one file's changes.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HunksParams {
    pub session: Id,
    /// Relative to the worktree.
    pub path: Bounded<String, 4096>,
}

/// `work/hunks`' answer: the unified diff against the base.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Hunks {
    pub diff: String,
}

/// `work/file-at`: a file as the edit history had it after a step.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FileAtParams {
    pub session: Id,
    /// Relative to the worktree.
    pub path: Bounded<String, 4096>,
    /// The step; the newest record of the session at or before it answers.
    pub seq: u64,
}

/// `work/file-at`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FileAt {
    /// The file's bytes, base64.
    pub bytes: String,
    /// The step of the record this is.
    pub seq: u64,
}

/// The longest machine name, in bytes.
pub const NAME_MAX: usize = 64;
/// Most slots one report may hold.
pub const SLOTS_MAX: usize = 256;
/// The longest a report may stand, in seconds.
pub const TTL_MAX: f64 = 86_400.0;

fn check_move(p: &MoveParams) -> Result<(), Error> {
    let target = p.target.as_str();
    let id = target
        .strip_prefix("job:")
        .or_else(|| target.strip_prefix("session:"));
    if id.is_none_or(|id| id.is_empty() || id.len() > 128) {
        return Err(invalid("target", "job:ID or session:ID"));
    }
    let name = p.machine.as_str();
    if name.is_empty()
        || name.len() > NAME_MAX
        || name == "auto"
        || name.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(invalid(
            "machine",
            "local or a runner's name, of 1 to 64 characters with no spaces",
        ));
    }
    Ok(())
}

fn check_report(p: &MachineReport) -> Result<(), Error> {
    let name = p.machine.as_str();
    if name.is_empty()
        || name.len() > NAME_MAX
        || name.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(invalid(
            "machine",
            "a name of 1 to 64 characters with no spaces",
        ));
    }
    if name == "local" {
        return Err(invalid(
            "machine",
            "local is the hub's own machine; it is not reported",
        ));
    }
    if !(p.ttl > 0.0 && p.ttl <= TTL_MAX) {
        return Err(invalid("ttl", "seconds, more than 0 and at most 86400"));
    }
    if p.slots.len() > SLOTS_MAX {
        return Err(invalid("slots", "at most 256 slots"));
    }
    if p.slots.iter().any(|s| s.id.is_empty() || s.kind.is_empty()) {
        return Err(invalid("slots", "every slot needs an id and a kind"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/presence/subscribe", AgentsPresenceSubscribe(PresenceSubscribe) -> PresenceFiles,
            classes: [User], writes: false,
            doc: "this connection gets agent-presence for the files under a workspace's roots, or for one file; the answer is who is in them now",
            check: check_presence_subscribe,
        ),
        method!(
            "agents/presence/get", AgentsPresenceGet(PresenceGet) -> FilePresence,
            classes: [User], writes: false,
            doc: "who is in a file now: each session's last mode, line, source and step there",
            check: check_presence_get,
        ),
        method!(
            "machines/report", MachinesReport(MachineReport) -> Machine,
            classes: [User], writes: false,
            doc: "a machine's slots and who holds them, valid for ttl seconds (jobq reports; an agent may not)",
            check: check_report,
        ),
        method!(
            "machines/move", MachinesMove(MoveParams) -> MoveResult,
            classes: [User], writes: true,
            doc: "move a job (job:ID) or an agent's next jobs (session:ID) to a machine: a waiting job is placed there; a running one is never stopped here, a card asks Restart or Keep; an unknown or untrusted machine is refused with why",
            check: check_move,
        ),
        method!(
            "machines/list", MachinesList(Empty) -> MachinesList,
            classes: [User], writes: false,
            doc: "the machines the hub knows: local, and those reported and not yet expired",
        ),
        method!(
            "review/effects", ReviewEffects(EffectsParams) -> Vec<TaskEffect>,
            classes: [User], writes: false,
            doc: "what a spec, plan or code change would do to the tasks under way or queued: a removed task (or a retired plan or spec) stops, a running task whose brief changes gets a steer, a task whose agent edits or reads a changed file would need to rebase; tasks not started or done are left out",
        ),
        method!(
            "work/conclusions", WorkConclusions(ConclusionsParams) -> Conclusions,
            classes: [User], writes: false,
            doc: "a session's decisions and findings, numbered, each with the step the hub stamped and the steps it rests on",
            check: check_conclusions,
        ),
        method!(
            "work/map/subscribe", WorkMapSubscribe(MapSubscribe) -> MapRows,
            classes: [User], writes: false,
            doc: "open (or open again) one map view of this connection: its model comes as view-model (a reset first) and its rows as view-patch per display class, to this connection only; the answer is the hub's id and the view's version",
            check: check_map_subscribe,
        ),
        method!(
            "work/map/set", WorkMapSet(MapSet) -> MapVersion,
            classes: [User], writes: false,
            doc: "change one map view (filters, collapsed layers, width, density, shown, the selection): a change the user made relayouts at once",
            check: check_map_set,
        ),
        method!(
            "work/target/set", WorkTargetSet(TargetSetParams) -> bool,
            classes: [User], writes: true,
            doc: "set (or with null clear) the target date of a spec or a plan; true when the item exists",
            check: check_target_set,
        ),
        method!(
            "work/map/close", WorkMapClose(MapClose) -> bool,
            classes: [User], writes: false,
            doc: "end one map view of this connection (a connection's views end with it)",
            check: check_map_close,
        ),
        method!(
            "work/trail/subscribe", WorkTrailSubscribe(TrailSubscribe) -> TrailSubscribed,
            classes: [User], writes: false,
            doc: "open (or open again) one trail view (a session's steps and conclusions) or Timeline view (a lane per session) of this connection: its rows come as view-patch per display class, the first a reset, before the answer",
            check: check_trail_subscribe,
        ),
        method!(
            "work/trail/set", WorkTrailSet(TrailSet) -> bool,
            classes: [User], writes: false,
            doc: "zoom, pan or filter one Timeline view of this connection without subscribing again: its window (a window without follow stops following), follow (now kept in view) and filter (all, edits, waits); false when the view is not a Timeline",
            check: check_trail_set,
        ),
        method!(
            "work/schedule/subscribe", WorkScheduleSubscribe(ScheduleSubscribe) -> TrailSubscribed,
            classes: [User], writes: false,
            doc: "open (or open again) one Schedule view of this connection over a window: the List's rows of the connection's map view (or its tasks by machine), each with its bar (done, forecast to p50 and p90, baseline, target, state), its rows per display class, the first a reset, before the answer",
            check: check_schedule_subscribe,
        ),
        method!(
            "work/schedule/set", WorkScheduleSet(ScheduleSet) -> bool,
            classes: [User], writes: false,
            doc: "zoom, pan or regroup one Schedule view of this connection without subscribing again; false when the view is not a Schedule",
            check: check_schedule_set,
        ),
        method!(
            "work/trail/close", WorkTrailClose(TrailClose) -> bool,
            classes: [User], writes: false,
            doc: "end one trail, Timeline, Schedule or Board view of this connection (a connection's views end with it)",
            check: check_trail_close,
        ),
        method!(
            "work/board/subscribe", WorkBoardSubscribe(BoardSubscribe) -> TrailSubscribed,
            classes: [User], writes: false,
            doc: "open (or open again) one Board view of this connection: the tracker's tasks (of plans, else every task) by column, its model and its rows per display class, the first a reset, before the answer; read again after each write",
            check: check_board_subscribe,
        ),
        method!(
            "work/flow/subscribe", WorkFlowSubscribe(FlowSubscribe) -> TrailSubscribed,
            classes: [User], writes: false,
            doc: "open (or open again) one Flow lens view of this connection: a plan run's tasks by gate (a chip per gate from the hub's evidence), its merge batch and rule pack, its model and its rows per display class, the first a reset, before the answer; read again after each write; with detail, one task's detail tile (why it is held, what clears it, its evidence, its actions), with rules the Rules tile (the rule pack), as rows alone",
            check: check_flow_subscribe,
        ),
        method!(
            "work/files", WorkFiles(EditedFiles) -> EditedFilesList,
            classes: [User], writes: false,
            doc: "the files a session edited, with added and removed lines against its worktree's base (new files included)",
        ),
        method!(
            "work/hunks", WorkHunks(HunksParams) -> Hunks,
            classes: [User], writes: false,
            doc: "one edited file's unified diff against its worktree's base",
        ),
        method!(
            "work/file-at", WorkFileAt(FileAtParams) -> FileAt,
            classes: [User], writes: false,
            doc: "a file's bytes (base64) as the agent had it after its newest edit-history record at or before step seq",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn report(v: serde_json::Value) -> Result<MachineReport, Error> {
        let (p, _) = crate::registry::decode_params::<MachineReport>(&v)?;
        check_report(&p).map(|()| p)
    }

    #[test]
    fn a_report_is_checked() {
        assert!(
            report(
                json!({"machine": "desktop", "ttl": 30, "slots": [{"id": "s1", "kind": "build"}]})
            )
            .is_ok()
        );
        for bad in [
            json!({"machine": "", "ttl": 30}),
            json!({"machine": "a b", "ttl": 30}),
            json!({"machine": "local", "ttl": 30}),
            json!({"machine": "m", "ttl": 0}),
            json!({"machine": "m", "ttl": 90000}),
            json!({"machine": "m", "ttl": 5, "slots": [{"id": "", "kind": "build"}]}),
        ] {
            assert!(report(bad.clone()).is_err(), "{bad}");
        }
    }

    /// The Rules tile takes the selected task with it (its Evidence tab's); a task id is still checked.
    #[test]
    fn the_rules_tile_takes_the_selected_task() {
        let flow = |v: serde_json::Value| {
            let (p, _) = crate::registry::decode_params::<FlowSubscribe>(&v)?;
            check_flow_subscribe(&p)
        };
        assert!(
            flow(json!({"view": "v/rules", "map": "v", "rules": true, "detail": "J#5"})).is_ok()
        );
        assert!(flow(json!({"view": "v/rules", "map": "v", "rules": true, "detail": ""})).is_err());
    }

    /// A target is set on a spec or a plan only, with a finite time or null.
    #[test]
    fn a_task_id_is_refused_as_a_target_item() {
        let t = |v: serde_json::Value| {
            let (p, _) = crate::registry::decode_params::<TargetSetParams>(&v)?;
            check_target_set(&p)
        };
        assert!(t(json!({"item": "plan:p1", "target_at": 1.8e9})).is_ok());
        assert!(t(json!({"item": "spec:s1", "target_at": null})).is_ok());
        assert!(t(json!({"item": "task:t1", "target_at": 1.8e9})).is_err());
    }
}
