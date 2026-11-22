//! The data (design §4.1): OS windows with their regions, the center's tree of groups, tabs, selection and focus.
//!
//! Sizes are logical px on a graphical window and columns/lines on a terminal one; the realiser and chrome scale them.
//! Tab and group ids are stable for the session; persistence stores refs, not ids.

use std::collections::{BTreeMap, BTreeSet};

use crate::decl::{Defaults, KindTable};
use crate::layout::LayoutSnapshot;
use crate::persist::Restore;

macro_rules! ids {
    ($($(#[$m:meta])* $name:ident),* $(,)?) => {$(
        $(#[$m])*
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(pub u64);
    )*};
}

ids!(
    /// The model's version: bumped by every change; the realiser and chrome read by version.
    Version,
    /// A tab, stable for the session.
    TabId,
    /// A center group.
    GroupId,
    /// An OS window.
    WinId,
    /// An overlay.
    OverlayId,
);

/// Who asked: `User` (a command the user ran) or `Program` (a timer, a process event, a hub push).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    User,
    Program,
}

/// Why an intent was not carried out, in words the status bar can show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub reason: String,
}

impl Refusal {
    pub fn new(reason: impl Into<String>) -> Self {
        Refusal {
            reason: reason.into(),
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason)
    }
}

pub(crate) fn refuse<T>(reason: impl Into<String>) -> Result<T, Refusal> {
    Err(Refusal::new(reason))
}

/// What a tab shows. A buffer is named by a stable id (its name is only the title).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ref {
    File {
        path: String,
        at: Option<String>,
    },
    Buffer {
        id: String,
        name: String,
    },
    Page {
        page_kind: String,
        key: Option<String>,
    },
    Session {
        id: String,
    },
    Output {
        channel: String,
    },
}

impl Ref {
    /// The same thing shown: what reveal-if-open, singletons and layout restores match on (a file's `at`, a buffer's
    /// name and a page's key are not part of it).
    pub fn same(&self, other: &Ref) -> bool {
        match (self, other) {
            (Ref::File { path: a, .. }, Ref::File { path: b, .. }) => a == b,
            (Ref::Buffer { id: a, .. }, Ref::Buffer { id: b, .. }) => a == b,
            (Ref::Page { page_kind: a, .. }, Ref::Page { page_kind: b, .. }) => a == b,
            (Ref::Session { id: a }, Ref::Session { id: b }) => a == b,
            (Ref::Output { channel: a }, Ref::Output { channel: b }) => a == b,
            _ => false,
        }
    }

    pub fn is_page(&self) -> bool {
        matches!(self, Ref::Page { .. })
    }

    /// A file or a buffer: the refs that may be previews and may be a tab in two groups.
    pub fn is_text(&self) -> bool {
        matches!(self, Ref::File { .. } | Ref::Buffer { .. })
    }

    /// The tab kind a ref gets when the caller names none.
    pub fn default_kind(&self) -> &'static str {
        match self {
            Ref::File { .. } | Ref::Buffer { .. } => "text",
            Ref::Page { .. } => "page",
            Ref::Session { .. } => "session",
            Ref::Output { .. } => "output",
        }
    }

    pub fn page_kind(&self) -> Option<&str> {
        match self {
            Ref::Page { page_kind, .. } => Some(page_kind),
            _ => None,
        }
    }
}

/// A tab. `changed` is the "changed" dot a program display leaves; `placeholder` a restored hub page waiting for its
/// kind; `unavailable` one whose kind never came.
#[derive(Clone, Debug, PartialEq)]
pub struct Tab {
    pub id: TabId,
    pub kind: String,
    pub r: Ref,
    pub preview: bool,
    pub title: String,
    pub icon: String,
    pub marks: Vec<String>,
    pub dirty: bool,
    pub changed: bool,
    pub placeholder: bool,
    pub unavailable: bool,
}

/// A multi-window tool's lifetime in one group (§5.3.3): its tab is active while it lasts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TempLayout {
    pub tool: String,
    pub tab: TabId,
    pub return_to: Option<TabId>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    pub id: GroupId,
    pub tabs: Vec<TabId>,
    /// None only for an empty group (it shows Start).
    pub active: Option<TabId>,
    pub preview: Option<TabId>,
    /// Most recently used first.
    pub mru: Vec<TabId>,
    pub temp: Option<TempLayout>,
}

/// `Row`: children side by side; `Column`: stacked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    Row,
    Column,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    Split {
        axis: Axis,
        children: Vec<Node>,
        weights: Vec<f32>,
    },
    Leaf(GroupId),
}

/// The regions; nothing else exists (W9).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Region {
    Rail,
    Left,
    Center,
    Right,
    Bottom,
}

/// The right's four fixed tabs [D1].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum RightTab {
    Detail,
    Agents,
    Inbox,
    PullRequests,
}

impl RightTab {
    pub const ALL: [RightTab; 4] = [
        RightTab::Detail,
        RightTab::Agents,
        RightTab::Inbox,
        RightTab::PullRequests,
    ];

    pub fn name(self) -> &'static str {
        match self {
            RightTab::Detail => "detail",
            RightTab::Agents => "agents",
            RightTab::Inbox => "inbox",
            RightTab::PullRequests => "pull-requests",
        }
    }

    pub fn from_name(s: &str) -> Option<RightTab> {
        RightTab::ALL.into_iter().find(|t| t.name() == s)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    Left,
    Center(GroupId, TabId),
    Right(RightTab),
    Bottom,
}

/// The OS window's one selection (§7.1).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub kind: String,
    pub id: String,
    pub source: Source,
    pub generation: u64,
}

/// Where keys go. Never the rail or a strip; `Overlay` carries the focus it returns to (§4.1).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Focus {
    Left,
    Center(GroupId),
    Right,
    Bottom,
    Overlay(OverlayId, Box<Focus>),
}

impl Focus {
    /// The focus under every overlay.
    pub fn base(&self) -> &Focus {
        match self {
            Focus::Overlay(_, r) => r.base(),
            f => f,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OverlayKind {
    Palette,
    QuickOpen,
    Switcher,
    Menu,
    Toast,
    Card,
    QuickHelp,
    FindBar,
    DebugToolbar,
    Completion,
    Minibuffer,
    /// A folded side opened over the center.
    Side,
}

impl OverlayKind {
    /// At most one of these at a time (a new one replaces the old).
    pub fn modal(self) -> bool {
        matches!(
            self,
            OverlayKind::Palette
                | OverlayKind::QuickOpen
                | OverlayKind::Switcher
                | OverlayKind::Side
        )
    }

    /// Shown without taking focus; a program may post these.
    pub fn passive(self) -> bool {
        matches!(
            self,
            OverlayKind::Toast
                | OverlayKind::Card
                | OverlayKind::QuickHelp
                | OverlayKind::DebugToolbar
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Overlay {
    pub id: OverlayId,
    pub kind: OverlayKind,
    pub spec: String,
}

/// An OS window's size: logical px, or cells on a terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinSize {
    Px { w: u32, h: u32 },
    Cells { cols: u32, lines: u32 },
}

impl WinSize {
    pub fn width(self) -> u32 {
        match self {
            WinSize::Px { w, .. } => w,
            WinSize::Cells { cols, .. } => cols,
        }
    }

    pub fn height(self) -> u32 {
        match self {
            WinSize::Px { h, .. } => h,
            WinSize::Cells { lines, .. } => lines,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// What an edge or a requested rectangle belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EdgeKey {
    Region(Region),
    Group(GroupId),
    /// The left place's Nth section window (its header band, §6.1).
    Section(u32),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Left {
    pub place: Option<String>,
    pub visible: bool,
    pub width: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Center {
    pub tree: Node,
    pub active_group: GroupId,
    pub full_size: Option<GroupId>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Right {
    pub tab: RightTab,
    pub visible: bool,
    pub width: u32,
    pub detail_pin: Option<Selection>,
    pub agents_conversation: Option<String>,
    pub inbox_item: Option<String>,
    pub pull_request: Option<String>,
    /// Right tabs with a "changed" dot.
    pub changed: Vec<RightTab>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Bottom {
    pub tabs: Vec<TabId>,
    pub active: Option<TabId>,
    pub visible: bool,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SideFold {
    Open,
    Folded,
}

/// Computed from the size (§4.6): never set by an intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fold {
    pub left: SideFold,
    pub right: SideFold,
    /// The folded side open as an overlay, `Region::Left` or `Region::Right`.
    pub overlay: Option<Region>,
}

/// A place's own state per OS window (f5.5: "where you left it").
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PlaceState {
    pub selection: Option<String>,
    pub scroll: u32,
}

/// An OS window whose monitor went away: its tabs live in the main window until it returns (§8.3).
#[derive(Clone, Debug, PartialEq)]
pub struct Parked {
    pub monitor: String,
    /// Each moved tab and the group it came from (None: the bottom panel).
    pub moved: Vec<(Option<GroupId>, TabId)>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OsWindow {
    pub id: WinId,
    pub monitor: String,
    pub size: WinSize,
    pub scale: f32,
    pub tty: bool,
    /// Actual device-px edges sent back after a realisation (`set_edges`).
    pub edges: Vec<(EdgeKey, Rect)>,
    /// Zen: the rail and the status bar are hidden too.
    pub chrome_hidden: bool,
    pub left: Left,
    pub center: Center,
    pub right: Right,
    pub bottom: Bottom,
    pub fold: Fold,
    pub selection: Option<Selection>,
    pub selection_gen: u64,
    pub focus: Focus,
    /// The focus ring shows (`:focus-visible'): focus last came by key (F6, Shift-F6, Esc to the center), not by a
    /// pointer click into a region.
    pub focus_visible: bool,
    /// Overlays bottom to top (toasts are in `toasts`).
    pub overlays: Vec<Overlay>,
    /// The toast lane: the first is the one shown.
    pub toasts: Vec<Overlay>,
    pub layout_undo: Vec<LayoutSnapshot>,
    /// Closed tabs' refs, oldest first, for Reopen Closed Tab.
    pub closed_tabs: Vec<Ref>,
    pub place_state: BTreeMap<String, PlaceState>,
    /// Refs a program wanted to show and could only mark (no tab shows them).
    pub program_marks: Vec<Ref>,
    /// Output channels' counts of program output not yet seen.
    pub output_counts: BTreeMap<String, u64>,
    pub project: Option<String>,
    /// The preset or saved layout last applied.
    pub layout_name: Option<String>,
    pub parked: Option<Parked>,
}

/// The attention count (§9.3): the same in every OS window.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Attention {
    pub count: u64,
    pub by_kind: Vec<(String, u64)>,
}

/// A user's saved arrangement for a project.
#[derive(Clone, Debug, PartialEq)]
pub struct SavedLayout {
    pub project: String,
    pub name: String,
    pub layout: LayoutSnapshot,
}

/// The first tab each strip showed at the last chrome build: what the chrome drew, not the model's state, so never
/// part of a comparison.
#[derive(Debug, Default)]
pub struct StripShown(pub(crate) std::sync::Mutex<BTreeMap<GroupId, usize>>);

impl StripShown {
    pub(crate) fn get(&self, g: GroupId) -> usize {
        self.0.lock().map_or(0, |m| m.get(&g).copied().unwrap_or(0))
    }

    pub(crate) fn set(&self, g: GroupId, first: usize) {
        if let Ok(mut m) = self.0.lock() {
            m.insert(g, first);
        }
    }
}

impl Clone for StripShown {
    fn clone(&self) -> Self {
        StripShown(std::sync::Mutex::new(
            self.0.lock().map(|m| m.clone()).unwrap_or_default(),
        ))
    }
}

impl PartialEq for StripShown {
    fn eq(&self, _: &Self) -> bool {
        true
    }
}

/// The whole model, process-wide.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Workbench {
    pub(crate) windows: Vec<OsWindow>,
    pub(crate) attention: Attention,
    pub(crate) kinds: KindTable,
    pub(crate) defaults: Defaults,
    pub(crate) layouts: Vec<SavedLayout>,
    pub(crate) version: Version,
    pub(crate) tabs: BTreeMap<TabId, Tab>,
    pub(crate) groups: BTreeMap<GroupId, Group>,
    pub(crate) gone_buffers: BTreeSet<String>,
    pub(crate) monitors: Vec<String>,
    pub(crate) restore: Restore,
    pub(crate) notices: Vec<String>,
    pub(crate) next_id: u64,
    /// Tab strips the user scrolled: the first tab shown and the active tab then (`drag.rs`).
    pub(crate) strip_scroll: BTreeMap<GroupId, (usize, Option<TabId>)>,
    /// The first tab each strip showed when the chrome was last built.
    pub(crate) strip_shown: StripShown,
    /// The chrome's own changes that are not the model's (a strip scrolled).
    pub(crate) chrome_gen: u64,
}

impl Workbench {
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn bump(&mut self) -> Version {
        self.version.0 += 1;
        self.version
    }

    pub(crate) fn fresh(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    pub(crate) fn wi(&self, w: WinId) -> Result<usize, Refusal> {
        match self.windows.iter().position(|x| x.id == w) {
            Some(i) => Ok(i),
            None => refuse("no such OS window"),
        }
    }

    pub(crate) fn tab_mut(&mut self, t: TabId) -> Option<&mut Tab> {
        self.tabs.get_mut(&t)
    }

    pub(crate) fn group_mut(&mut self, g: GroupId) -> &mut Group {
        self.groups.get_mut(&g).expect("a group in a tree exists")
    }

    /// The window whose center holds group `g`.
    pub(crate) fn window_of_group(&self, g: GroupId) -> Option<WinId> {
        self.windows
            .iter()
            .find(|w| w.center.tree.contains(g))
            .map(|w| w.id)
    }

    /// The center group holding tab `t`.
    pub(crate) fn group_of(&self, t: TabId) -> Option<GroupId> {
        self.groups
            .values()
            .find(|g| g.tabs.contains(&t))
            .map(|g| g.id)
    }

    /// The window holding tab `t` in its center or its bottom panel.
    pub(crate) fn window_of_tab(&self, t: TabId) -> Option<WinId> {
        if let Some(g) = self.group_of(t) {
            return self.window_of_group(g);
        }
        self.windows
            .iter()
            .find(|w| w.bottom.tabs.contains(&t))
            .map(|w| w.id)
    }

    /// The groups of a window in reading order.
    pub(crate) fn groups_of(&self, w: &OsWindow) -> Vec<GroupId> {
        w.center.tree.leaves()
    }

    /// The center tabs of a window, group by group in reading order.
    pub(crate) fn center_tabs(&self, wi: usize) -> Vec<TabId> {
        let mut out = Vec::new();
        for g in self.windows[wi].center.tree.leaves() {
            out.extend(self.groups[&g].tabs.iter().copied());
        }
        out
    }

    /// The first tab of the window's center showing the same thing as `r`.
    pub(crate) fn find_in_center(&self, wi: usize, r: &Ref) -> Option<TabId> {
        self.center_tabs(wi)
            .into_iter()
            .find(|t| self.tabs[t].r.same(r))
    }

    pub(crate) fn default_title(&self, r: &Ref) -> String {
        match r {
            Ref::File { path, .. } => path.rsplit('/').next().unwrap_or(path).to_string(),
            Ref::Buffer { name, .. } => name.clone(),
            Ref::Page { page_kind, .. } => match self.kinds.page(page_kind) {
                Some(p) => p.title.clone(),
                None => page_kind.clone(),
            },
            Ref::Session { id } => id.clone(),
            Ref::Output { channel } => channel.clone(),
        }
    }

    pub(crate) fn new_tab(
        &mut self,
        r: Ref,
        preview: bool,
        kind: Option<String>,
        title: Option<String>,
    ) -> TabId {
        let id = TabId(self.fresh());
        let icon = match r.page_kind().and_then(|k| self.kinds.page(k)) {
            Some(p) => p.icon.clone(),
            None => String::new(),
        };
        let tab = Tab {
            id,
            kind: kind.unwrap_or_else(|| r.default_kind().to_string()),
            title: title.unwrap_or_else(|| self.default_title(&r)),
            preview: preview && !r.is_page(),
            r,
            icon,
            marks: Vec::new(),
            dirty: false,
            changed: false,
            placeholder: false,
            unavailable: false,
        };
        self.tabs.insert(id, tab);
        id
    }

    pub(crate) fn new_group(&mut self, tabs: Vec<TabId>) -> GroupId {
        let id = GroupId(self.fresh());
        let mut g = Group {
            id,
            active: tabs.last().copied(),
            preview: None,
            mru: tabs.iter().rev().copied().collect(),
            tabs,
            temp: None,
        };
        for t in &g.tabs {
            if self.tabs[t].preview {
                if g.preview.is_none() {
                    g.preview = Some(*t);
                } else if let Some(tab) = self.tabs.get_mut(t) {
                    tab.preview = false;
                }
            }
        }
        self.groups.insert(id, g);
        id
    }

    /// Activate a center tab in its group; the left follows a page tab whose kind names a place (§4.7).
    pub(crate) fn activate(&mut self, wi: usize, g: GroupId, t: TabId) {
        let group = self.group_mut(g);
        group.active = Some(t);
        group.mru.retain(|x| *x != t);
        group.mru.insert(0, t);
        let place = match &self.tabs[&t].r {
            Ref::Page { page_kind, .. } => self.kinds.page(page_kind).and_then(|p| p.place.clone()),
            _ => None,
        };
        if let Some(p) = place
            && self.kinds.place(&p).is_some()
        {
            self.windows[wi].left.place = Some(p);
        }
    }

    /// Set the focus under any overlays.
    pub(crate) fn set_base_focus(&mut self, wi: usize, f: Focus) {
        fn put(cur: &mut Focus, f: Focus) {
            match cur {
                Focus::Overlay(_, r) => put(r, f),
                c => *c = f,
            }
        }
        if let Focus::Center(g) = f {
            let c = &mut self.windows[wi].center;
            c.active_group = g;
            // focusing another group while one is full size shows that one full size instead (W5)
            if c.full_size.is_some() {
                c.full_size = Some(g);
            }
        }
        put(&mut self.windows[wi].focus, f);
    }

    /// Whether a focus names a visible region with a live window (W5).
    pub(crate) fn focus_ok(&self, w: &OsWindow, f: &Focus) -> bool {
        match f {
            Focus::Left => w.left.visible && w.fold.left == SideFold::Open,
            Focus::Right => w.right.visible && w.fold.right == SideFold::Open,
            Focus::Bottom => w.bottom.visible,
            Focus::Center(g) => {
                w.center.tree.contains(*g) && w.center.full_size.is_none_or(|fs| fs == *g)
            }
            Focus::Overlay(id, r) => w.overlays.iter().any(|o| o.id == *id) && self.focus_ok(w, r),
        }
    }

    /// Hiding or folding the focused region, or removing its group, moves focus to the active group (W5).
    pub(crate) fn fix_focus(&mut self, wi: usize) {
        let w = &self.windows[wi];
        let mut ag = w.center.active_group;
        if !w.center.tree.contains(ag) {
            ag = w.center.tree.leaves()[0];
        }
        if let Some(fs) = w.center.full_size {
            ag = fs;
        }
        self.windows[wi].center.active_group = ag;
        let mut f = self.windows[wi].focus.clone();
        // drop overlays that no longer exist from the chain
        fn prune(f: Focus, live: &[OverlayId]) -> Focus {
            match f {
                Focus::Overlay(id, r) if live.contains(&id) => {
                    Focus::Overlay(id, Box::new(prune(*r, live)))
                }
                Focus::Overlay(_, r) => prune(*r, live),
                other => other,
            }
        }
        let live: Vec<OverlayId> = self.windows[wi].overlays.iter().map(|o| o.id).collect();
        f = prune(f, &live);
        self.windows[wi].focus = f;
        let base = self.windows[wi].focus.base().clone();
        if !self.focus_ok(&self.windows[wi], &base) {
            self.set_base_focus(wi, Focus::Center(ag));
        }
    }
}
