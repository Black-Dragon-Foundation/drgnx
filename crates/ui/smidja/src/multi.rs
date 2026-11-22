//! Several OS windows (§4.8, §8.1 tear-out, §8.3 monitors).
//!
//! Every OS window is a full workbench with its own regions, groups, selection and focus [D7]; the attention count,
//! declarations, presets and saved layouts are shared. A monitor that goes away folds its windows' tabs into the main
//! window's active group (with a snapshot); they go back, as they are then, when it returns.

use std::collections::BTreeMap;

use crate::intent::Intent;
use crate::model::{
    Bottom, Center, Focus, Fold, GroupId, Left, Node, Origin, OsWindow, Parked, Refusal, Right,
    RightTab, SideFold, TabId, Version, WinId, WinSize, Workbench, refuse,
};

/// What `tear_out` takes into a new OS window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TearOut {
    Tab(TabId),
    Group(GroupId),
}

impl Workbench {
    /// A new OS window: one empty group, the left on the default place, the right on Detail.
    pub fn window_new(&mut self, monitor: &str, size: WinSize, scale: f32, tty: bool) -> WinId {
        let id = WinId(self.fresh());
        let g = self.new_group(Vec::new());
        let d = &self.defaults;
        let (lw, rw, bh) = if tty {
            (d.tty.left, d.tty.right, d.tty.bottom)
        } else {
            (d.left, d.right, d.bottom)
        };
        let size = match (tty, size) {
            (true, WinSize::Px { w, h }) => WinSize::Cells { cols: w, lines: h },
            (false, WinSize::Cells { cols, lines }) => WinSize::Px { w: cols, h: lines },
            (_, s) => s,
        };
        self.windows.push(OsWindow {
            id,
            monitor: monitor.to_string(),
            size,
            scale: if scale > 0.0 { scale } else { 1.0 },
            tty,
            edges: Vec::new(),
            chrome_hidden: false,
            left: Left {
                place: self.kinds.default_place(),
                visible: true,
                width: lw,
            },
            center: Center {
                tree: Node::Leaf(g),
                active_group: g,
                full_size: None,
            },
            right: Right {
                tab: RightTab::Detail,
                visible: true,
                width: rw,
                detail_pin: None,
                agents_conversation: None,
                inbox_item: None,
                pull_request: None,
                changed: Vec::new(),
            },
            bottom: Bottom {
                tabs: Vec::new(),
                active: None,
                visible: false,
                height: bh,
            },
            fold: Fold {
                left: SideFold::Open,
                right: SideFold::Open,
                overlay: None,
            },
            selection: None,
            selection_gen: 0,
            focus: Focus::Center(g),
            focus_visible: false,
            overlays: Vec::new(),
            toasts: Vec::new(),
            layout_undo: Vec::new(),
            closed_tabs: Vec::new(),
            place_state: BTreeMap::new(),
            program_marks: Vec::new(),
            output_counts: BTreeMap::new(),
            project: None,
            layout_name: None,
            parked: None,
        });
        let wi = self.windows.len() - 1;
        self.refold(wi);
        self.bump();
        id
    }

    /// Close an OS window (never the last one). Its tabs close; no buffer is touched.
    pub fn window_close(&mut self, w: WinId, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        if self.windows.iter().filter(|x| x.parked.is_none()).count() <= 1 {
            return refuse("the last OS window stays");
        }
        let mut ts = self.center_tabs(wi);
        ts.extend(self.windows[wi].bottom.tabs.iter().copied());
        for t in ts {
            self.tabs.remove(&t);
        }
        for g in self.windows[wi].center.tree.leaves() {
            self.groups.remove(&g);
        }
        self.windows.remove(wi);
        Ok(self.bump())
    }

    /// Tear a tab or a group out into a new OS window: a full workbench, its left on the tab's place (or the default
    /// place), its right on Detail.
    pub fn tear_out(&mut self, what: TearOut, origin: Origin) -> Result<(Version, WinId), Refusal> {
        self.gate(origin, Intent::Layout)?;
        let (w, tabs, g) = match what {
            TearOut::Tab(t) => {
                let Some(g) = self.group_of(t) else {
                    return refuse("only a center tab tears out");
                };
                (self.window_of_group(g), vec![t], g)
            }
            TearOut::Group(g) => (
                self.window_of_group(g),
                self.groups
                    .get(&g)
                    .map(|x| x.tabs.clone())
                    .unwrap_or_default(),
                g,
            ),
        };
        let Some(w) = w else {
            return refuse("no such group");
        };
        if self.groups[&g].temp.is_some() {
            return refuse("a temporary layout holds this group");
        }
        if tabs.is_empty() {
            return refuse("an empty group has nothing to tear out");
        }
        let wi = self.wi(w)?;
        self.push_undo(wi);
        let active = self.groups[&g].active;
        for t in &tabs {
            self.take_out(wi, *t);
        }
        self.fix_focus(wi);
        let src = &self.windows[wi];
        let (monitor, size, scale, tty) = (src.monitor.clone(), src.size, src.scale, src.tty);
        let nw = self.window_new(&monitor, size, scale, tty);
        let nwi = self.wi(nw)?;
        let ng = self.windows[nwi].center.active_group;
        for t in &tabs {
            self.join_group(ng, *t);
        }
        let first = active.filter(|a| tabs.contains(a)).unwrap_or(tabs[0]);
        self.activate(nwi, ng, first);
        if self.windows[nwi].left.place.is_none() {
            self.windows[nwi].left.place = self.kinds.default_place();
        }
        Ok((self.bump(), nw))
    }

    /// The monitors present now. Windows on a monitor that went away fold into the main (first) window; parked windows
    /// whose monitor is back get their tabs back. Nothing else moves.
    pub fn set_monitors(&mut self, monitors: Vec<String>) -> Version {
        self.monitors = monitors;
        if self.windows.is_empty() {
            return self.bump();
        }
        let main = 0;
        for wi in 1..self.windows.len() {
            let win = &self.windows[wi];
            let present = self.monitors.contains(&win.monitor);
            let parked = win.parked.is_some();
            if !parked && !present {
                self.park(main, wi);
            } else if parked && present {
                self.unpark(main, wi);
            }
        }
        for wi in 0..self.windows.len() {
            self.fix_focus(wi);
        }
        self.bump()
    }

    fn park(&mut self, main: usize, wi: usize) {
        self.push_undo(main);
        let mg = self.windows[main].center.active_group;
        let mut moved = Vec::new();
        for g in self.windows[wi].center.tree.leaves() {
            for t in self.groups[&g].tabs.clone() {
                // a page kind the main window already shows stays parked: one per window (W3); so does a temporary
                // layout's tool tab, which belongs to its group until the tool ends
                let dup_page = self.tabs[&t].r.is_page()
                    && self.find_in_center(main, &self.tabs[&t].r).is_some();
                let tool = self.groups[&g].temp.as_ref().is_some_and(|tl| tl.tab == t);
                if dup_page || tool {
                    continue;
                }
                self.detach(g, t);
                self.join_group(mg, t);
                moved.push((Some(g), t));
            }
        }
        for t in std::mem::take(&mut self.windows[wi].bottom.tabs) {
            self.windows[main].bottom.tabs.push(t);
            moved.push((None, t));
        }
        let win = &mut self.windows[wi];
        win.bottom.active = None;
        win.bottom.visible = false;
        win.overlays.clear();
        win.toasts.clear();
        let monitor = win.monitor.clone();
        win.parked = Some(Parked { monitor, moved });
    }

    fn unpark(&mut self, main: usize, wi: usize) {
        let Some(p) = self.windows[wi].parked.take() else {
            return;
        };
        for (g, t) in p.moved {
            if !self.tabs.contains_key(&t) {
                continue;
            }
            let in_main_center = self
                .group_of(t)
                .is_some_and(|x| self.windows[main].center.tree.contains(x));
            let in_main_bottom = self.windows[main].bottom.tabs.contains(&t);
            if !in_main_center && !in_main_bottom {
                continue;
            }
            if let Some(x) = self.group_of(t) {
                self.detach(x, t);
            } else {
                let b = &mut self.windows[main].bottom;
                b.tabs.retain(|x| *x != t);
                if b.active == Some(t) {
                    b.active = b.tabs.last().copied();
                }
                if b.tabs.is_empty() {
                    b.visible = false;
                }
            }
            match g {
                Some(g) if self.groups.contains_key(&g) => self.join_group(g, t),
                // its group went meanwhile: a center tab goes back to the window's first group, never the bottom (W1)
                Some(_) => {
                    let first = self.windows[wi].center.tree.leaves()[0];
                    self.join_group(first, t);
                }
                None => {
                    let b = &mut self.windows[wi].bottom;
                    b.tabs.push(t);
                    b.active = Some(t);
                }
            }
        }
        for g in self.windows[wi].center.tree.leaves() {
            if self.groups[&g].tabs.is_empty() && self.windows[wi].center.tree.leaves().len() > 1 {
                self.remove_group(wi, g);
            }
        }
    }

    pub fn windows(&self) -> Vec<WinId> {
        self.windows
            .iter()
            .filter(|w| w.parked.is_none())
            .map(|w| w.id)
            .collect()
    }

    pub fn window(&self, w: WinId) -> Option<&OsWindow> {
        self.windows.iter().find(|x| x.id == w)
    }
}
