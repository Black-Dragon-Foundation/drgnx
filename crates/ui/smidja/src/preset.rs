//! Presets and per-project layouts (§8.2).
//!
//! A preset sets the center's tabs and splits and which sides are open. It never closes a buffer: tabs it does not
//! name join the first group. Applying one pushes a layout snapshot. Presets are declarations (`Decl::Preset`), like
//! kinds and places: the crate names no preset, page kind or place; drgnx declares its five (layout A) at start.

use crate::intent::Intent;
use crate::layout::LayoutSnapshot;
use crate::model::{
    Focus, Node, Origin, Ref, Refusal, RightTab, SavedLayout, TabId, Version, WinId, Workbench,
    refuse,
};

/// What a preset puts in the center.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CenterSpec {
    /// One group, this page active.
    Page(String),
    /// One group, the most recent text tab active (none: Start).
    Recent,
    /// Two groups side by side.
    Split(Box<CenterSpec>, Box<CenterSpec>),
    /// The active group full size, as it is.
    Zen,
}

/// What a preset does with a side.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SideSpec {
    /// Shown, the left on this place.
    Show(Option<String>),
    Hide,
    AsItWas,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preset {
    pub name: String,
    pub center: CenterSpec,
    pub left: SideSpec,
    pub right: SideSpec,
    pub bottom: SideSpec,
    /// Zen hides the rail and the status bar too.
    pub hide_chrome: bool,
}

impl Workbench {
    /// Apply a preset by name to an OS window.
    pub fn apply_preset(
        &mut self,
        w: WinId,
        name: &str,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        let Some(p) = self.kinds.presets.iter().find(|p| p.name == name).cloned() else {
            return refuse(format!("no preset named {name}"));
        };
        if self.any_temp(wi) {
            return refuse("a temporary layout is running");
        }
        self.push_undo(wi);
        self.apply_preset_now(wi, &p);
        self.windows[wi].layout_name = Some(name.to_string());
        Ok(self.bump())
    }

    fn apply_preset_now(&mut self, wi: usize, p: &Preset) {
        if p.center == CenterSpec::Zen {
            let ag = self.windows[wi].center.active_group;
            self.windows[wi].center.full_size = Some(ag);
        } else {
            // the window's tabs, most recently used first per group, the active group first
            let leaves = self.windows[wi].center.tree.leaves();
            let ag = self.windows[wi].center.active_group;
            let mut order: Vec<_> = leaves.iter().copied().filter(|g| *g == ag).collect();
            order.extend(leaves.iter().copied().filter(|g| *g != ag));
            let mru: Vec<TabId> = order
                .iter()
                .flat_map(|g| self.groups[g].mru.clone())
                .collect();
            let all = self.center_tabs(wi);
            let (a, b) = match &p.center {
                CenterSpec::Split(a, b) => ((**a).clone(), Some((**b).clone())),
                c => (c.clone(), None),
            };
            let goes_right = |wb: &Workbench, t: &TabId| match &b {
                Some(CenterSpec::Recent) => wb.tabs[t].r.is_text(),
                Some(CenterSpec::Page(k)) => wb.tabs[t].r.page_kind() == Some(k.as_str()),
                _ => false,
            };
            let right: Vec<TabId> = all
                .iter()
                .copied()
                .filter(|t| goes_right(self, t))
                .collect();
            let left: Vec<TabId> = all.iter().copied().filter(|t| !right.contains(t)).collect();
            for g in &leaves {
                self.groups.remove(g);
            }
            for t in &all {
                if let Some(tab) = self.tabs.get_mut(t) {
                    tab.preview = tab.preview && tab.r.is_text();
                }
            }
            let ga = self.new_group(left);
            let mut tree = Node::Leaf(ga);
            let gb = b.as_ref().map(|_| self.new_group(right));
            if let Some(gb) = gb {
                tree = Node::Split {
                    axis: crate::model::Axis::Row,
                    children: vec![Node::Leaf(ga), Node::Leaf(gb)],
                    weights: vec![0.5, 0.5],
                };
            }
            let win = &mut self.windows[wi];
            win.center.tree = tree;
            win.center.active_group = ga;
            win.center.full_size = None;
            self.fill(wi, ga, &a, &mru);
            if let (Some(gb), Some(b)) = (gb, &b) {
                self.fill(wi, gb, b, &mru);
            }
            self.set_base_focus(wi, Focus::Center(ga));
        }
        let win = &mut self.windows[wi];
        win.chrome_hidden = p.hide_chrome;
        match &p.left {
            SideSpec::Show(place) => {
                win.left.visible = true;
                if let Some(pl) = place
                    && self.kinds.place(pl).is_some()
                {
                    win.left.place = Some(pl.clone());
                }
            }
            SideSpec::Hide => win.left.visible = false,
            SideSpec::AsItWas => {}
        }
        match &p.right {
            SideSpec::Show(_) => {
                win.right.visible = true;
                win.right.tab = RightTab::Detail;
            }
            SideSpec::Hide => win.right.visible = false,
            SideSpec::AsItWas => {}
        }
        match &p.bottom {
            SideSpec::Show(_) => win.bottom.visible = true,
            SideSpec::Hide => win.bottom.visible = false,
            SideSpec::AsItWas => {}
        }
        self.refold(wi);
    }

    /// Make a group show what a center spec names: its page (opened if missing) or its most recent text tab.
    fn fill(&mut self, wi: usize, g: crate::model::GroupId, c: &CenterSpec, mru: &[TabId]) {
        let target = match c {
            CenterSpec::Page(k) => {
                let found = self.groups[&g]
                    .tabs
                    .iter()
                    .copied()
                    .find(|t| self.tabs[t].r.page_kind() == Some(k.as_str()));
                match found {
                    Some(t) => Some(t),
                    None => {
                        let t = self.new_tab(
                            Ref::Page {
                                page_kind: k.clone(),
                                key: None,
                            },
                            false,
                            None,
                            None,
                        );
                        self.join_group(g, t);
                        Some(t)
                    }
                }
            }
            CenterSpec::Recent => {
                let tabs = &self.groups[&g].tabs;
                mru.iter()
                    .copied()
                    .find(|t| tabs.contains(t) && self.tabs[t].r.is_text())
                    .or_else(|| mru.iter().copied().find(|t| tabs.contains(t)))
            }
            _ => None,
        };
        if let Some(t) = target {
            self.activate(wi, g, t);
        }
    }

    /// Next Layout: the presets in order, then the user's saved layouts for the window's project.
    pub fn next_layout(&mut self, w: WinId, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        let mut names: Vec<String> = self.kinds.presets.iter().map(|p| p.name.clone()).collect();
        let declared = names.len();
        let project = self.windows[wi].project.clone();
        let saved: Vec<&SavedLayout> = self
            .layouts
            .iter()
            .filter(|l| Some(&l.project) == project.as_ref())
            .collect();
        names.extend(saved.iter().map(|l| l.name.clone()));
        let cur = self.windows[wi]
            .layout_name
            .as_ref()
            .and_then(|n| names.iter().position(|x| x == n));
        let next = cur.map_or(0, |i| (i + 1) % names.len());
        let name = names[next].clone();
        if next < declared {
            return self.apply_preset(w, &name, origin);
        }
        if self.any_temp(wi) {
            return refuse("a temporary layout is running");
        }
        let l = saved[next - declared].layout.clone();
        self.push_undo(wi);
        self.apply_layout(wi, &l);
        self.windows[wi].layout_name = Some(name);
        Ok(self.bump())
    }

    /// Save the window's arrangement as a named layout of a project (replacing one of the same name).
    pub fn save_project_layout(
        &mut self,
        w: WinId,
        project: &str,
        name: &str,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        let layout: LayoutSnapshot = self.take_layout(wi);
        self.layouts
            .retain(|l| !(l.project == project && l.name == name));
        self.layouts.push(SavedLayout {
            project: project.to_string(),
            name: name.to_string(),
            layout,
        });
        Ok(self.bump())
    }

    /// The project the window works on (its saved layouts join Next Layout).
    pub fn set_project(&mut self, w: WinId, project: Option<String>) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.windows[wi].project = project;
        Ok(self.bump())
    }

    pub fn layout_name(&self, w: WinId) -> Option<&str> {
        self.windows
            .iter()
            .find(|x| x.id == w)?
            .layout_name
            .as_deref()
    }
}
