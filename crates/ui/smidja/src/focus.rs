//! Focus, the region intents and overlays (§4.3, §9.1).
//!
//! F6 cycles left, the center's groups in reading order, right, bottom, skipping hidden regions and opening a folded
//! side as its overlay; the rail and the strips are never focus. An overlay records the focus it returns to; at most
//! one modal overlay exists (palette, quick open, switcher, a side), the minibuffer box and its completion stack above
//! it, and toasts are their own lane with one shown. Overlays never take region space or enter layout undo.

use crate::intent::Intent;
use crate::model::{
    Focus, GroupId, Origin, Overlay, OverlayId, OverlayKind, Ref, Refusal, Region, SideFold, TabId,
    Version, WinId, Workbench, refuse,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FocusTarget {
    Region(Region),
    Group(GroupId),
    Tab(TabId),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    Next,
    Prev,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Vis {
    Show,
    Hide,
    Toggle,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BottomRef {
    Kind(String),
    Tab(TabId),
}

/// A stop of the F6 ring.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stop {
    Left,
    Group(GroupId),
    Right,
    Bottom,
}

impl Workbench {
    /// Move focus to a region, a group or a tab.
    pub fn focus(
        &mut self,
        w: WinId,
        target: FocusTarget,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Focus)?;
        let win = &self.windows[wi];
        match target {
            FocusTarget::Region(Region::Rail) => return refuse("the rail is never focus"),
            FocusTarget::Region(Region::Center) => {
                let ag = win.center.active_group;
                self.set_base_focus(wi, Focus::Center(ag));
            }
            FocusTarget::Region(side @ (Region::Left | Region::Right)) => {
                let (vis, fold) = if side == Region::Left {
                    (win.left.visible, win.fold.left)
                } else {
                    (win.right.visible, win.fold.right)
                };
                if !vis {
                    return refuse("that side is hidden");
                }
                if fold == SideFold::Folded {
                    if win.fold.overlay != Some(side) {
                        self.open_side_overlay(wi, side);
                    }
                } else {
                    self.set_base_focus(
                        wi,
                        if side == Region::Left {
                            Focus::Left
                        } else {
                            Focus::Right
                        },
                    );
                }
            }
            FocusTarget::Region(Region::Bottom) => {
                if !win.bottom.visible {
                    return refuse("the bottom panel is hidden");
                }
                self.set_base_focus(wi, Focus::Bottom);
            }
            FocusTarget::Group(g) => {
                if !win.center.tree.contains(g) {
                    return refuse("no such group in this window");
                }
                if win.center.full_size.is_some_and(|fs| fs != g) {
                    return refuse("full size shows one group");
                }
                self.set_base_focus(wi, Focus::Center(g));
            }
            FocusTarget::Tab(t) => {
                if win.bottom.tabs.contains(&t) {
                    let win = &mut self.windows[wi];
                    win.bottom.active = Some(t);
                    win.bottom.visible = true;
                    self.set_base_focus(wi, Focus::Bottom);
                } else {
                    let Some(g) = self.group_of(t).filter(|g| win.center.tree.contains(*g)) else {
                        return refuse("no such tab in this window");
                    };
                    if let Some(tl) = &self.groups[&g].temp
                        && tl.tab != t
                    {
                        return refuse(crate::intent::temp_reason(&tl.tool));
                    }
                    if win.center.full_size.is_some_and(|fs| fs != g) {
                        return refuse("full size shows one group");
                    }
                    self.activate(wi, g, t);
                    self.set_base_focus(wi, Focus::Center(g));
                }
            }
        }
        Ok(self.bump())
    }

    /// F6 / Shift-F6: the region ring.
    pub fn cycle_region(&mut self, w: WinId, dir: Dir, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Focus)?;
        let win = &self.windows[wi];
        // a side overlay counts as its side; any other overlay keeps the keys
        let cur = match &win.focus {
            Focus::Overlay(id, _) => match win.overlays.iter().find(|o| o.id == *id) {
                Some(o) if o.kind == OverlayKind::Side => match win.fold.overlay {
                    Some(Region::Left) => Stop::Left,
                    _ => Stop::Right,
                },
                _ => return refuse("an overlay holds the keys"),
            },
            Focus::Left => Stop::Left,
            Focus::Right => Stop::Right,
            Focus::Bottom => Stop::Bottom,
            Focus::Center(g) => Stop::Group(*g),
        };
        let mut stops = Vec::new();
        if win.left.visible {
            stops.push(Stop::Left);
        }
        match win.center.full_size {
            Some(fs) => stops.push(Stop::Group(fs)),
            None => stops.extend(win.center.tree.leaves().into_iter().map(Stop::Group)),
        }
        if win.right.visible {
            stops.push(Stop::Right);
        }
        if win.bottom.visible {
            stops.push(Stop::Bottom);
        }
        let n = stops.len();
        let i = stops.iter().position(|s| *s == cur).unwrap_or(0);
        let next = match dir {
            Dir::Next => stops[(i + 1) % n],
            Dir::Prev => stops[(i + n - 1) % n],
        };
        self.dismiss_side(wi);
        self.go_stop(wi, next);
        Ok(self.bump())
    }

    fn go_stop(&mut self, wi: usize, s: Stop) {
        let win = &self.windows[wi];
        match s {
            Stop::Left if win.fold.left == SideFold::Folded => {
                self.open_side_overlay(wi, Region::Left)
            }
            Stop::Right if win.fold.right == SideFold::Folded => {
                self.open_side_overlay(wi, Region::Right)
            }
            Stop::Left => self.set_base_focus(wi, Focus::Left),
            Stop::Right => self.set_base_focus(wi, Focus::Right),
            Stop::Bottom => self.set_base_focus(wi, Focus::Bottom),
            Stop::Group(g) => self.set_base_focus(wi, Focus::Center(g)),
        }
    }

    fn dismiss_side(&mut self, wi: usize) {
        let ids: Vec<_> = self.windows[wi]
            .overlays
            .iter()
            .filter(|o| o.kind == OverlayKind::Side)
            .map(|o| o.id)
            .collect();
        for id in ids {
            self.drop_overlay(wi, id);
        }
    }

    /// Show, hide or toggle the left, the right or the bottom panel (the user's visibility; folding is separate).
    pub fn side(
        &mut self,
        w: WinId,
        region: Region,
        vis: Vis,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Side)?;
        let win = &mut self.windows[wi];
        let cur = match region {
            Region::Left => &mut win.left.visible,
            Region::Right => &mut win.right.visible,
            Region::Bottom => &mut win.bottom.visible,
            _ => return refuse("only the left, the right and the bottom panel hide"),
        };
        let new = match vis {
            Vis::Show => true,
            Vis::Hide => false,
            Vis::Toggle => !*cur,
        };
        *cur = new;
        self.refold(wi);
        let win = &self.windows[wi];
        let folded = match region {
            Region::Left => win.fold.left == SideFold::Folded,
            Region::Right => win.fold.right == SideFold::Folded,
            _ => false,
        };
        if new && folded && win.fold.overlay != Some(region) {
            self.open_side_overlay(wi, region);
        }
        Ok(self.bump())
    }

    /// Resize a side or the bottom panel, clamped (left 200–480, right 320–560, bottom 120 to half the center column).
    pub fn resize(
        &mut self,
        w: WinId,
        region: Region,
        size: u32,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Resize)?;
        let d = &self.defaults;
        let win = &self.windows[wi];
        let (lmin, lmax, rmin, rmax, bmin, chrome) = if win.tty {
            let t = &d.tty;
            (
                t.left_min,
                t.left_max,
                t.right_min,
                t.right_max,
                t.bottom_min,
                t.title_row + t.status_bar,
            )
        } else {
            (
                d.left_min,
                d.left_max,
                d.right_min,
                d.right_max,
                d.bottom_min,
                d.title_row + d.status_bar,
            )
        };
        let column = win
            .size
            .height()
            .saturating_sub(if win.chrome_hidden { 0 } else { chrome });
        let bmax = (column / 2).max(bmin);
        let win = &mut self.windows[wi];
        match region {
            Region::Left => win.left.width = size.clamp(lmin, lmax),
            Region::Right => win.right.width = size.clamp(rmin, rmax),
            Region::Bottom => win.bottom.height = size.clamp(bmin, bmax),
            _ => return refuse("only the sides and the bottom panel resize"),
        }
        self.refold(wi);
        Ok(self.bump())
    }

    /// Show, hide or toggle a bottom tab (by kind: the first tab of that kind, made if missing).
    pub fn bottom(
        &mut self,
        w: WinId,
        b: BottomRef,
        vis: Vis,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Bottom)?;
        let t = match b {
            BottomRef::Tab(t) => {
                if !self.windows[wi].bottom.tabs.contains(&t) {
                    return refuse("no such bottom tab");
                }
                t
            }
            BottomRef::Kind(k) => {
                if !self.kinds.is_bottom(&k) {
                    return refuse(format!("no bottom kind named {k}"));
                }
                let found = self.windows[wi]
                    .bottom
                    .tabs
                    .iter()
                    .copied()
                    .find(|t| self.tabs[t].kind == k);
                match found {
                    Some(t) => t,
                    None => {
                        let t = self.new_tab(
                            Ref::Page {
                                page_kind: k.clone(),
                                key: None,
                            },
                            false,
                            Some(k),
                            None,
                        );
                        self.windows[wi].bottom.tabs.push(t);
                        t
                    }
                }
            }
        };
        let win = &mut self.windows[wi];
        let show = match vis {
            Vis::Show => true,
            Vis::Hide => false,
            Vis::Toggle => !(win.bottom.visible && win.bottom.active == Some(t)),
        };
        if show {
            win.bottom.active = Some(t);
            win.bottom.visible = true;
            self.set_base_focus(wi, Focus::Bottom);
        } else {
            win.bottom.visible = false;
            self.fix_focus(wi);
        }
        Ok(self.bump())
    }

    /// Show an overlay. A focus-taking one records the focus to return to.
    pub fn overlay(
        &mut self,
        w: WinId,
        kind: OverlayKind,
        spec: &str,
        origin: Origin,
    ) -> Result<(Version, OverlayId), Refusal> {
        let wi = self.wi(w)?;
        self.gate(
            origin,
            Intent::Overlay {
                passive: kind.passive(),
            },
        )?;
        if kind == OverlayKind::Side {
            let side = match spec {
                "left" => Region::Left,
                "right" => Region::Right,
                _ => return refuse("a side overlay is the left or the right"),
            };
            let win = &self.windows[wi];
            let folded = if side == Region::Left {
                win.left.visible && win.fold.left == SideFold::Folded
            } else {
                win.right.visible && win.fold.right == SideFold::Folded
            };
            if !folded {
                return refuse("only a folded side opens as an overlay");
            }
        }
        let id = self.push_overlay(wi, kind, spec.to_string());
        Ok((self.bump(), id))
    }

    pub(crate) fn push_overlay(&mut self, wi: usize, kind: OverlayKind, spec: String) -> OverlayId {
        let id = OverlayId(self.fresh());
        let o = Overlay { id, kind, spec };
        if kind == OverlayKind::Toast {
            self.windows[wi].toasts.push(o);
            return id;
        }
        if kind.modal() {
            let old: Vec<_> = self.windows[wi]
                .overlays
                .iter()
                .filter(|x| x.kind.modal())
                .map(|x| x.id)
                .collect();
            for x in old {
                self.drop_overlay(wi, x);
            }
        }
        let ag = self.windows[wi].center.active_group;
        let win = &mut self.windows[wi];
        if kind == OverlayKind::Side {
            win.fold.overlay = Some(if o.spec == "left" {
                Region::Left
            } else {
                Region::Right
            });
            // Esc, a click outside or a pick returns to the center (§4.6)
            let ret = crate::fold::side_return(ag);
            win.focus = rewrap(&win.focus, ret);
        }
        win.overlays.push(o);
        if !kind.passive() {
            let prev = std::mem::replace(&mut win.focus, Focus::Left);
            win.focus = Focus::Overlay(id, Box::new(prev));
        }
        id
    }

    /// Remove an overlay; the focus it held goes back to its return focus.
    pub(crate) fn drop_overlay(&mut self, wi: usize, id: OverlayId) {
        fn splice(f: Focus, id: OverlayId) -> Focus {
            match f {
                Focus::Overlay(i, r) if i == id => *r,
                Focus::Overlay(i, r) => Focus::Overlay(i, Box::new(splice(*r, id))),
                other => other,
            }
        }
        let win = &mut self.windows[wi];
        if let Some(i) = win.overlays.iter().position(|o| o.id == id) {
            let o = win.overlays.remove(i);
            if o.kind == OverlayKind::Side {
                win.fold.overlay = None;
            }
        }
        win.toasts.retain(|o| o.id != id);
        let f = std::mem::replace(&mut win.focus, Focus::Left);
        win.focus = splice(f, id);
    }

    /// Dismiss an overlay (None: the top one; a program may dismiss only passive ones).
    pub fn dismiss(
        &mut self,
        w: WinId,
        id: Option<OverlayId>,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        let win = &self.windows[wi];
        let found = match id {
            Some(id) => win
                .overlays
                .iter()
                .chain(win.toasts.iter())
                .find(|o| o.id == id),
            None if origin == Origin::Program => win.toasts.first(),
            None => win.overlays.last().or(win.toasts.first()),
        };
        let Some(o) = found else {
            return refuse("no such overlay");
        };
        let (oid, passive) = (o.id, o.kind.passive());
        self.gate(origin, Intent::Dismiss { passive })?;
        self.drop_overlay(wi, oid);
        Ok(self.bump())
    }

    pub fn overlays(&self, w: WinId) -> &[Overlay] {
        self.windows
            .iter()
            .find(|x| x.id == w)
            .map(|x| x.overlays.as_slice())
            .unwrap_or(&[])
    }

    /// The toast shown (one at a time).
    pub fn toast(&self, w: WinId) -> Option<&Overlay> {
        self.windows.iter().find(|x| x.id == w)?.toasts.first()
    }

    pub fn focus_of(&self, w: WinId) -> Option<&Focus> {
        self.windows.iter().find(|x| x.id == w).map(|x| &x.focus)
    }
}

/// The same overlay chain over a new base focus.
fn rewrap(f: &Focus, base: Focus) -> Focus {
    match f {
        Focus::Overlay(i, r) => Focus::Overlay(*i, Box::new(rewrap(r, base))),
        _ => base,
    }
}
