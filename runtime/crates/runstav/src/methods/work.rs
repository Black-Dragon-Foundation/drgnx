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
//! The Work map: `work/map/subscribe`, `work/map/set`, `work/map/close` and the event `work-map`, per (connection,
//! view), sent to that connection only.

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

/// `agents/presence/subscribe`'s params: a workspace (every file under its roots) or one file.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PresenceSubscribe {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<Workspace>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
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

/// A map view's filters: `f` (only an item's chain), `o` (only overlaps and clashes), `.` (finished items too).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapFilters {
    /// An item id: only its chain.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus: Option<String>,
    #[serde(default)]
    pub overlaps: bool,
    #[serde(default)]
    pub finished: bool,
}

/// `work/map/subscribe`'s params: one map view of this connection (VIEW is the editor's id for it), the workspace it
/// shows, and how.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapSubscribe {
    pub view: String,
    pub workspace: Workspace,
    /// The drawing width, in units of 4 px.
    pub width_units: u32,
    #[serde(default)]
    pub density: MapDensity,
    #[serde(default)]
    pub filters: MapFilters,
    /// Collapsed layers, 1 to 6.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub collapsed: Vec<u8>,
    /// The selected item: a quiet reflow that would move its chain waits for the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
    /// Rows: the view's rows come as `view-patch` per display class (`view/env`), the first a reset, and no
    /// `work-map` event comes; the width is the env's (`width_units` is ignored). The answer is `{hub, version}`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rows: bool,
}

/// `work/map/subscribe`'s answer: the full frame, or (`rows`) the hub's instance id and the view's version.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum MapSubscribed {
    Frame(MapFrame),
    Rows(MapRows),
}

/// `work/map/subscribe`'s answer to a rows view: its patches name this hub and start from a reset.
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

/// `work/trail/subscribe`'s params: one view of the connection shows `session`'s trail, or a Timeline of `lanes`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TrailSubscribe {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lanes: Vec<TrailLane>,
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

/// A map view's full frame: `work/map/subscribe`'s answer.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapFrame {
    /// The frame's version; every `work-map` after it names the version it applies to (`base`).
    pub version: u64,
    /// The items the view shows, each with its kind, label, flags and card fields.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub items: Vec<serde_json::Value>,
    /// The edges between them.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub edges: Vec<serde_json::Value>,
    /// Rows, positions and forms, lanes, ports and bands, in units of 4 px.
    pub layout: serde_json::Value,
    /// The needs-you strip.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub needs_you: Vec<serde_json::Value>,
    /// The mission chips (the machines' load).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub chips: Vec<serde_json::Value>,
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
    /// False: hidden (no deltas, one stale mark); true again: a full frame.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shown: Option<bool>,
    /// The selection moved (a map key).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
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

/// The data of `work-map`: what changed in one view since version `base`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WorkMap {
    pub view: String,
    pub version: u64,
    pub base: u64,
    /// A full frame (a relayout): `changed` is every item shown, `layout` the new one.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub full: bool,
    /// Items new or changed, whole.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub changed: Vec<serde_json::Value>,
    /// Ids no longer shown: they fade out and leave their place empty.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub removed: Vec<String>,
    /// Ids that arrived live: they fade in at their place in `places`.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub entered: Vec<String>,
    /// The free places the arrivals took (id → rect), and their forms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub places: Option<serde_json::Value>,
    /// Every edge between the items shown, when the edge set changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edges: Option<Vec<serde_json::Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs_you: Option<Vec<serde_json::Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chips: Option<Vec<serde_json::Value>>,
    /// The view is hidden and its frame is out of date: shown again, it gets a full frame.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stale: Option<bool>,
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
    if collapsed.iter().any(|l| !(1..=6).contains(l)) {
        return Err(invalid("collapsed", "layers 1 to 6"));
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
            "machines/list", MachinesList(Empty) -> MachinesList,
            classes: [User], writes: false,
            doc: "the machines the hub knows: local, and those reported and not yet expired",
        ),
        method!(
            "work/conclusions", WorkConclusions(ConclusionsParams) -> Conclusions,
            classes: [User], writes: false,
            doc: "a session's decisions and findings, numbered, each with the step the hub stamped and the steps it rests on",
            check: check_conclusions,
        ),
        method!(
            "work/map/subscribe", WorkMapSubscribe(MapSubscribe) -> MapSubscribed,
            classes: [User], writes: false,
            doc: "open (or open again) one map view of this connection: the answer is its full frame, and work-map events follow, to this connection only; with rows, its rows come as view-patch per display class instead",
            check: check_map_subscribe,
        ),
        method!(
            "work/map/set", WorkMapSet(MapSet) -> MapVersion,
            classes: [User], writes: false,
            doc: "change one map view (filters, collapsed layers, width, density, shown, the selection): a change the user made relayouts at once",
            check: check_map_set,
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
            "work/trail/close", WorkTrailClose(TrailClose) -> bool,
            classes: [User], writes: false,
            doc: "end one trail or Timeline view of this connection (a connection's views end with it)",
            check: check_trail_close,
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
}
