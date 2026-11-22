//! The intents of §4.3 that open, close and select: `open`, `pin`, `close`, `reopen_closed`, `select`,
//! `show_context`, `navigate`, `pin_detail`, and the feeding ones (`update_tab`, `set_attention`, `buffer_gone`).
//!
//! Every intent asks `allowed` first (the origin rule, W6): a program may change an existing tab's content and
//! marks, close a killed buffer's tabs, or preview in the active group for a debugger stop; anything else it only
//! marks.

use crate::model::Origin;
use crate::model::{
    Focus, GroupId, OverlayKind, PlaceState, Ref, Refusal, Region, RightTab, Selection, SideFold,
    Source, TabId, Version, WinId, Workbench, refuse,
};

/// What an origin may do with an intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Allowed {
    Do,
    MarkOnly,
    Refuse,
}

/// The intent being gated.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Intent {
    Open { debug_stop: bool },
    Pin,
    Close,
    ReopenClosed,
    Select,
    ShowContext,
    Navigate,
    PinDetail,
    PlaceState,
    Focus,
    Side,
    Resize,
    Bottom,
    Overlay { passive: bool },
    Dismiss { passive: bool },
    Layout,
    TempLayout,
}

/// The origin rule (§4.3): one function every intent calls first.
pub fn allowed(origin: Origin, intent: Intent) -> Allowed {
    match (origin, intent) {
        (Origin::User, _) => Allowed::Do,
        (Origin::Program, Intent::Open { debug_stop: true }) => Allowed::Do,
        (Origin::Program, Intent::Open { debug_stop: false }) => Allowed::MarkOnly,
        (
            Origin::Program,
            Intent::Overlay { passive: true } | Intent::Dismiss { passive: true },
        ) => Allowed::Do,
        (Origin::Program, _) => Allowed::Refuse,
    }
}

/// `open`'s how.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum How {
    Preview,
    Pin,
    Reveal,
}

/// `open`'s options: the target group (default: the active one), a position, whether to focus (default: true for
/// pin and reveal), a debugger stop (the one program preview), and the tab kind (default: from the ref).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OpenOpts {
    pub group: Option<GroupId>,
    pub at: Option<String>,
    pub focus: Option<bool>,
    pub debug_stop: bool,
    pub kind: Option<String>,
}

/// `show_context`'s target: the right's own navigation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    Detail,
    Agents,
    AgentsSession(String),
    Inbox(Option<String>),
    PullRequests(Option<String>),
}

/// `update_tab`'s fields; None leaves a field as it is.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TabFields {
    pub title: Option<String>,
    pub icon: Option<String>,
    pub marks: Option<Vec<String>>,
    pub dirty: Option<bool>,
    pub ref_path: Option<String>,
}

const PROGRAM_ONLY_MARKS: &str = "a program may only mark; the user did not ask for this";

impl Workbench {
    /// The origin rule's gate; a user intent during a restore drops the restore's pending part (§4.9).
    pub(crate) fn gate(&mut self, origin: Origin, intent: Intent) -> Result<Allowed, Refusal> {
        let a = allowed(origin, intent);
        if a == Allowed::Refuse {
            return refuse(PROGRAM_ONLY_MARKS);
        }
        if origin == Origin::User {
            self.discard_pending();
        }
        Ok(a)
    }

    /// A program's display of `r` in window `wi`: a "changed" dot on a tab showing it, the Output channel's count,
    /// or the window's list of marked refs.
    pub(crate) fn mark(&mut self, wi: usize, r: &Ref) -> Option<TabId> {
        let mut found = self.find_in_center(wi, r);
        if found.is_none() {
            found = self.windows[wi]
                .bottom
                .tabs
                .iter()
                .copied()
                .find(|t| self.tabs[t].r.same(r));
        }
        if let Some(t) = found {
            if let Some(tab) = self.tab_mut(t) {
                tab.changed = true;
            }
            return Some(t);
        }
        let w = &mut self.windows[wi];
        match r {
            Ref::Output { channel } => *w.output_counts.entry(channel.clone()).or_insert(0) += 1,
            _ => {
                w.program_marks.retain(|x| !x.same(r));
                w.program_marks.push(r.clone());
                if w.program_marks.len() > 20 {
                    w.program_marks.remove(0);
                }
            }
        }
        None
    }

    /// Open `r` in window `w` (§4.3 `open`). Returns the tab, or None when a program display only marked.
    pub fn open(
        &mut self,
        w: WinId,
        r: Ref,
        how: How,
        o: OpenOpts,
        origin: Origin,
    ) -> Result<(Version, Option<TabId>), Refusal> {
        let wi = self.wi(w)?;
        let a = self.gate(
            origin,
            Intent::Open {
                debug_stop: o.debug_stop,
            },
        )?;
        let active = self.windows[wi].center.active_group;
        let debug_ok = how == How::Preview && r.is_text() && o.group.is_none_or(|g| g == active);
        // `allowed` decides by origin; a program's debugger stop must also be a text preview in the active group
        if a == Allowed::MarkOnly || (origin == Origin::Program && o.debug_stop && !debug_ok) {
            let t = self.mark(wi, &r);
            return Ok((self.bump(), t));
        }
        let focus = origin == Origin::User && o.focus.unwrap_or(how != How::Preview);
        // Output goes to the bottom panel unless a group is named (rule 3)
        if let Ref::Output { .. } = &r
            && o.group.is_none()
        {
            let t = self.open_in_bottom(wi, r, focus);
            return Ok((self.bump(), Some(t)));
        }
        let mut g = o.group.unwrap_or(active);
        if !self.windows[wi].center.tree.contains(g) {
            return refuse("no such group in this window");
        }
        // a group held by a temporary layout passes opens to the next group, or keeps them behind the tool's tab
        let mut behind = false;
        if self.groups[&g].temp.is_some() {
            let leaves = self.windows[wi].center.tree.leaves();
            let i = leaves.iter().position(|x| *x == g).unwrap_or(0);
            let next = (1..leaves.len())
                .map(|k| leaves[(i + k) % leaves.len()])
                .find(|x| self.groups[x].temp.is_none());
            match next {
                Some(n) => g = n,
                None => behind = true,
            }
        }
        let how = if matches!(r, Ref::Session { .. }) || r.is_page() {
            How::Pin
        } else {
            how
        };
        // reveal-if-open: pages anywhere in this window's center, text in any group
        if let Some(t) = self.find_in_center(wi, &r) {
            let tg = self.group_of(t).expect("a center tab has a group");
            if let Some(tab) = self.tab_mut(t) {
                match (&mut tab.r, &r) {
                    (Ref::Page { key, .. }, Ref::Page { key: k2, .. }) => *key = k2.clone(),
                    (Ref::File { at, .. }, Ref::File { at: a2, .. })
                        if o.at.is_some() || a2.is_some() =>
                    {
                        *at = o.at.clone().or_else(|| a2.clone());
                    }
                    _ => {}
                }
                tab.changed = false;
            }
            if how != How::Preview && self.tabs[&t].preview {
                self.tabs.get_mut(&t).expect("tab").preview = false;
                self.group_mut(tg).preview = None;
            }
            let locked = self.groups[&tg].temp.as_ref().is_some_and(|tl| tl.tab != t);
            if !locked {
                self.activate(wi, tg, t);
                if focus {
                    self.set_base_focus(wi, Focus::Center(tg));
                }
            }
            return Ok((self.bump(), Some(t)));
        }
        let t = match (how, self.groups[&g].preview) {
            (How::Preview, Some(p)) if !behind => {
                let title = self.default_title(&r);
                let kind = o
                    .kind
                    .clone()
                    .unwrap_or_else(|| r.default_kind().to_string());
                let mut r = r;
                if let (Ref::File { at, .. }, Some(a2)) = (&mut r, &o.at) {
                    *at = Some(a2.clone());
                }
                let tab = self.tab_mut(p).expect("the preview tab exists");
                tab.r = r;
                tab.title = title;
                tab.kind = kind;
                tab.dirty = false;
                tab.changed = false;
                tab.marks.clear();
                p
            }
            _ => {
                let mut r = r;
                if let (Ref::File { at, .. }, Some(a2)) = (&mut r, &o.at) {
                    *at = Some(a2.clone());
                }
                let preview = how == How::Preview && self.groups[&g].preview.is_none();
                let t = self.new_tab(r, preview, o.kind.clone(), None);
                let group = self.group_mut(g);
                let at = match group
                    .active
                    .and_then(|a| group.tabs.iter().position(|x| *x == a))
                {
                    Some(i) => i + 1,
                    None => group.tabs.len(),
                };
                group.tabs.insert(at, t);
                group.mru.push(t);
                if preview {
                    group.preview = Some(t);
                }
                t
            }
        };
        if !behind {
            self.activate(wi, g, t);
            if focus {
                self.set_base_focus(wi, Focus::Center(g));
            }
        }
        Ok((self.bump(), Some(t)))
    }

    /// The bottom panel's Output tab shows `r`'s channel (one Output tab; the channel switches in place).
    fn open_in_bottom(&mut self, wi: usize, r: Ref, focus: bool) -> TabId {
        let existing = self.windows[wi]
            .bottom
            .tabs
            .iter()
            .copied()
            .find(|t| matches!(self.tabs[t].r, Ref::Output { .. }));
        let t = match existing {
            Some(t) => {
                let title = self.default_title(&r);
                let tab = self.tab_mut(t).expect("tab");
                tab.r = r;
                tab.title = title;
                t
            }
            None => {
                let t = self.new_tab(r, false, None, None);
                self.windows[wi].bottom.tabs.push(t);
                t
            }
        };
        if let Ref::Output { channel } = &self.tabs[&t].r {
            let ch = channel.clone();
            self.windows[wi].output_counts.remove(&ch);
        }
        let w = &mut self.windows[wi];
        w.bottom.active = Some(t);
        w.bottom.visible = true;
        if focus {
            self.set_base_focus(wi, Focus::Bottom);
        }
        t
    }

    /// Pin a preview tab in place.
    pub fn pin(&mut self, t: TabId, origin: Origin) -> Result<Version, Refusal> {
        self.gate(origin, Intent::Pin)?;
        let Some(g) = self.group_of(t) else {
            return refuse("no such tab in a center group");
        };
        if self.tabs[&t].preview {
            self.tabs.get_mut(&t).expect("tab").preview = false;
            self.group_mut(g).preview = None;
        }
        Ok(self.bump())
    }

    /// Close a tab: the group's most recently used tab becomes active; an emptied group that is not the last goes
    /// and its space goes to its sibling; the last stays and shows Start.
    pub fn close(&mut self, t: TabId, origin: Origin) -> Result<Version, Refusal> {
        self.gate(origin, Intent::Close)?;
        let Some(w) = self.window_of_tab(t) else {
            return refuse("no such tab");
        };
        let wi = self.wi(w)?;
        if let Some(g) = self.group_of(t)
            && let Some(tl) = &self.groups[&g].temp
            && tl.tab == t
        {
            return refuse(temp_reason(&tl.tool));
        }
        let r = self.tabs[&t].r.clone();
        self.remove_tab(wi, t);
        let cap = self.defaults.closed_cap;
        let closed = &mut self.windows[wi].closed_tabs;
        closed.push(r);
        while closed.len() > cap {
            closed.remove(0);
        }
        self.fix_focus(wi);
        Ok(self.bump())
    }

    /// Take a tab out of its group or the bottom panel and forget it (no buffer is touched).
    pub(crate) fn remove_tab(&mut self, wi: usize, t: TabId) {
        self.tabs.remove(&t);
        if let Some(g) = self.group_of(t) {
            let group = self.group_mut(g);
            group.tabs.retain(|x| *x != t);
            group.mru.retain(|x| *x != t);
            if group.preview == Some(t) {
                group.preview = None;
            }
            if group.active == Some(t) {
                group.active = group.mru.first().copied();
            }
            let empty = group.tabs.is_empty();
            if empty && self.windows[wi].center.tree.leaves().len() > 1 {
                self.remove_group(wi, g);
            }
            return;
        }
        let b = &mut self.windows[wi].bottom;
        b.tabs.retain(|x| *x != t);
        if b.active == Some(t) {
            b.active = b.tabs.last().copied();
        }
        if b.tabs.is_empty() {
            b.visible = false;
        }
    }

    /// Reopen the most recently closed tab of this window (the last 20 are kept; a killed buffer is skipped).
    pub fn reopen_closed(&mut self, w: WinId, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::ReopenClosed)?;
        while let Some(r) = self.windows[wi].closed_tabs.pop() {
            if let Ref::Buffer { id, .. } = &r
                && self.gone_buffers.contains(id)
            {
                continue;
            }
            let (v, _) = self.open(w, r, How::Pin, OpenOpts::default(), Origin::User)?;
            return Ok(v);
        }
        refuse("no closed tab to reopen")
    }

    /// Set the window's selection (§4.3 `select`): Detail follows unless pinned; another right tab gets Detail's dot;
    /// the left follows a page tab whose kind names a place; nothing opens, focuses or folds.
    pub fn select(
        &mut self,
        w: WinId,
        kind: &str,
        id: &str,
        source: Source,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Select)?;
        let place = match &source {
            Source::Center(_, t) => match self.tabs.get(t).map(|x| &x.r) {
                Some(Ref::Page { page_kind, .. }) => {
                    self.kinds.page(page_kind).and_then(|p| p.place.clone())
                }
                _ => None,
            },
            _ => None,
        };
        let win = &mut self.windows[wi];
        win.selection_gen += 1;
        win.selection = Some(Selection {
            kind: kind.to_string(),
            id: id.to_string(),
            source,
            generation: win.selection_gen,
        });
        if win.right.tab != RightTab::Detail && !win.right.changed.contains(&RightTab::Detail) {
            win.right.changed.push(RightTab::Detail);
        }
        if let Some(p) = place {
            win.left.place = Some(p);
        }
        Ok(self.bump())
    }

    /// Pin Detail on a selection (None: unpin and follow the selection again). Per OS window, never saved.
    pub fn pin_detail(
        &mut self,
        w: WinId,
        sel: Option<Selection>,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::PinDetail)?;
        self.windows[wi].right.detail_pin = sel;
        Ok(self.bump())
    }

    /// What Detail shows: its pin, else the selection.
    pub fn detail(&self, w: WinId) -> Option<&Selection> {
        let win = self.windows.iter().find(|x| x.id == w)?;
        win.right.detail_pin.as_ref().or(win.selection.as_ref())
    }

    /// The right's own navigation: sets its tab, shows it if hidden, opens it as an overlay if folded. User only.
    pub fn show_context(
        &mut self,
        w: WinId,
        target: Target,
        focus: bool,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::ShowContext)?;
        let win = &mut self.windows[wi];
        let tab = match target {
            Target::Detail => RightTab::Detail,
            Target::Agents => {
                win.right.agents_conversation = None;
                RightTab::Agents
            }
            Target::AgentsSession(s) => {
                win.right.agents_conversation = Some(s);
                RightTab::Agents
            }
            Target::Inbox(i) => {
                win.right.inbox_item = i;
                RightTab::Inbox
            }
            Target::PullRequests(p) => {
                win.right.pull_request = p;
                RightTab::PullRequests
            }
        };
        win.right.tab = tab;
        win.right.changed.retain(|x| *x != tab);
        win.right.visible = true;
        self.refold(wi);
        if self.windows[wi].fold.right == SideFold::Folded {
            self.open_side_overlay(wi, Region::Right);
        } else if focus {
            self.set_base_focus(wi, Focus::Right);
        }
        Ok(self.bump())
    }

    /// Set the left's place (§4.3 `navigate`): shows the left (an overlay when folded), opens the place's home page
    /// pinned, focuses the left. A second click on a place without a home hides the left; one with a home never does.
    pub fn navigate(
        &mut self,
        w: WinId,
        place: &str,
        origin: Origin,
    ) -> Result<(Version, Option<TabId>), Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Navigate)?;
        let Some(p) = self.kinds.place(place) else {
            return refuse(format!("no place named {place}"));
        };
        let home = p.home.clone();
        let win = &self.windows[wi];
        let shown = win.left.visible && win.fold.left == SideFold::Open;
        if shown && win.left.place.as_deref() == Some(place) && home.is_none() {
            self.windows[wi].left.visible = false;
            self.refold(wi);
            return Ok((self.bump(), None));
        }
        self.windows[wi].left.place = Some(place.to_string());
        self.windows[wi].left.visible = true;
        self.refold(wi);
        let mut tab = None;
        if let Some(h) = home {
            let r = Ref::Page {
                page_kind: h,
                key: None,
            };
            let o = OpenOpts {
                focus: Some(false),
                ..OpenOpts::default()
            };
            tab = self.open(w, r, How::Pin, o, Origin::User)?.1;
            self.windows[wi].left.place = Some(place.to_string());
        }
        if self.windows[wi].fold.left == SideFold::Folded {
            let open = self.windows[wi].fold.overlay == Some(Region::Left);
            if !open {
                self.open_side_overlay(wi, Region::Left);
            }
        } else {
            self.set_base_focus(wi, Focus::Left);
        }
        Ok((self.bump(), tab))
    }

    /// Keep a place's own selection and scroll (per OS window), restored when the place is shown again.
    pub fn set_place_state(
        &mut self,
        w: WinId,
        place: &str,
        s: PlaceState,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::PlaceState)?;
        self.windows[wi].place_state.insert(place.to_string(), s);
        Ok(self.bump())
    }

    /// The current place's state.
    pub fn place_state(&self, w: WinId) -> Option<&PlaceState> {
        let win = self.windows.iter().find(|x| x.id == w)?;
        win.place_state.get(win.left.place.as_deref()?)
    }

    /// Set a tab's title, icon, marks, dirty flag or file path. Never moves anything.
    pub fn update_tab(&mut self, t: TabId, f: TabFields) -> Result<Version, Refusal> {
        let Some(tab) = self.tab_mut(t) else {
            return refuse("no such tab");
        };
        if let Some(x) = f.title {
            tab.title = x;
        }
        if let Some(x) = f.icon {
            tab.icon = x;
        }
        if let Some(x) = f.marks {
            tab.marks = x;
        }
        if let Some(x) = f.dirty {
            tab.dirty = x;
        }
        if let (Some(p), Ref::File { path, .. }) = (f.ref_path, &mut tab.r) {
            *path = p;
        }
        Ok(self.bump())
    }

    /// The attention count, shared by every OS window.
    pub fn set_attention(&mut self, count: u64, by_kind: Vec<(String, u64)>) -> Version {
        self.attention = crate::model::Attention { count, by_kind };
        self.bump()
    }

    pub fn attention(&self) -> &crate::model::Attention {
        &self.attention
    }

    /// A buffer was killed: every tab of it closes, in every group and window (origin program, §5.3.4).
    pub fn buffer_gone(&mut self, buffer_id: &str) -> Version {
        self.gone_buffers.insert(buffer_id.to_string());
        for wi in 0..self.windows.len() {
            let mut ts = self.center_tabs(wi);
            ts.extend(self.windows[wi].bottom.tabs.iter().copied());
            for t in ts {
                if matches!(&self.tabs[&t].r, Ref::Buffer { id, .. } if id == buffer_id) {
                    self.remove_tab(wi, t);
                }
            }
            self.fix_focus(wi);
        }
        self.bump()
    }

    pub(crate) fn open_side_overlay(&mut self, wi: usize, side: Region) {
        let spec = if side == Region::Left {
            "left"
        } else {
            "right"
        };
        self.push_overlay(wi, OverlayKind::Side, spec.to_string());
    }
}

/// The reason a locked group gives: "Ediff is running here; q quits it".
pub(crate) fn temp_reason(tool: &str) -> String {
    let mut c = tool.chars();
    let name = match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect::<String>(),
        None => String::new(),
    };
    format!("{name} is running here; q quits it")
}
