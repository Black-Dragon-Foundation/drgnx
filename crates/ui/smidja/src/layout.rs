//! The center's layout intents (§4.3, §8.1) and layout undo (§4.10).
//!
//! Only the user splits the center (W2). Every layout intent pushes a snapshot of the window's arrangement first (cap
//! 50); a snapshot holds refs, so restoring never brings back a killed buffer, and tabs it does not name join the
//! first group (W10). Tab switches, selection and focus are navigation and are never undone.

use crate::intent::Intent;
use crate::model::{
    Axis, Focus, GroupId, Node, Origin, Rect, Ref, Refusal, Region, RightTab, SideFold, TabId,
    Version, WinId, Workbench, refuse,
};

/// Where a split puts the new group.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Right,
    Down,
}

/// A direction on screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir4 {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MoveTarget {
    Group(GroupId),
    NewGroup(GroupId, Side),
    Bottom,
    NewOsWindow,
}

/// A tab in a snapshot: its ref and how it looked.
#[derive(Clone, Debug, PartialEq)]
pub struct SnapTab {
    pub r: Ref,
    pub preview: bool,
    pub kind: String,
    pub title: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SnapGroup {
    pub tabs: Vec<SnapTab>,
    pub active: Option<usize>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SnapNode {
    Split {
        axis: Axis,
        children: Vec<SnapNode>,
        weights: Vec<f32>,
    },
    Leaf(SnapGroup),
}

/// A window's arrangement: the center tree with refs, and the sides.
#[derive(Clone, Debug, PartialEq)]
pub struct LayoutSnapshot {
    pub tree: SnapNode,
    /// Leaf indices in reading order.
    pub active: usize,
    pub full_size: Option<usize>,
    pub left_place: Option<String>,
    pub left_visible: bool,
    pub left_width: u32,
    pub right_tab: RightTab,
    pub right_visible: bool,
    pub right_width: u32,
    pub bottom_visible: bool,
    pub bottom_height: u32,
    pub chrome_hidden: bool,
}

impl Node {
    /// The groups in reading order.
    pub fn leaves(&self) -> Vec<GroupId> {
        let mut v = Vec::new();
        self.walk(&mut v);
        v
    }

    fn walk(&self, v: &mut Vec<GroupId>) {
        match self {
            Node::Leaf(g) => v.push(*g),
            Node::Split { children, .. } => children.iter().for_each(|c| c.walk(v)),
        }
    }

    pub fn contains(&self, g: GroupId) -> bool {
        match self {
            Node::Leaf(x) => *x == g,
            Node::Split { children, .. } => children.iter().any(|c| c.contains(g)),
        }
    }

    /// Put `new` beside `g`: inside g's parent when it splits the same way (g's weight halved), else in a new split.
    fn insert_beside(&mut self, g: GroupId, new: GroupId, axis: Axis) -> bool {
        match self {
            Node::Leaf(x) if *x == g => {
                *self = Node::Split {
                    axis,
                    children: vec![Node::Leaf(g), Node::Leaf(new)],
                    weights: vec![0.5, 0.5],
                };
                true
            }
            Node::Leaf(_) => false,
            Node::Split {
                axis: a,
                children,
                weights,
            } => {
                if *a == axis
                    && let Some(i) = children.iter().position(|c| *c == Node::Leaf(g))
                {
                    let half = weights[i] / 2.0;
                    weights[i] = half;
                    weights.insert(i + 1, half);
                    children.insert(i + 1, Node::Leaf(new));
                    return true;
                }
                children.iter_mut().any(|c| c.insert_beside(g, new, axis))
            }
        }
    }

    /// Remove leaf `g`; its weight goes to its neighbour, and a split left with one child collapses.
    fn remove_leaf(&mut self, g: GroupId) -> bool {
        let Node::Split {
            children, weights, ..
        } = self
        else {
            return false;
        };
        if let Some(i) = children.iter().position(|c| *c == Node::Leaf(g)) {
            let w = weights.remove(i);
            children.remove(i);
            let j = if i > 0 { i - 1 } else { 0 };
            if let Some(x) = weights.get_mut(j) {
                *x += w;
            }
            if children.len() == 1 {
                *self = children.remove(0);
            }
            return true;
        }
        let done = children.iter_mut().any(|c| c.remove_leaf(g));
        if done
            && let Node::Split { children, .. } = self
            && children.len() == 1
        {
            *self = children.remove(0);
        }
        done
    }

    fn node_at_mut(&mut self, path: &[usize]) -> Option<&mut Node> {
        match path.split_first() {
            None => Some(self),
            Some((i, rest)) => match self {
                Node::Split { children, .. } => children.get_mut(*i)?.node_at_mut(rest),
                Node::Leaf(_) => None,
            },
        }
    }
}

/// Rectangles of each leaf inside `r`, by the weights.
fn rects(n: &Node, r: (f64, f64, f64, f64), out: &mut Vec<(GroupId, Rect)>) {
    match n {
        Node::Leaf(g) => out.push((
            *g,
            Rect {
                x: r.0.round() as i32,
                y: r.1.round() as i32,
                w: r.2.round() as i32,
                h: r.3.round() as i32,
            },
        )),
        Node::Split {
            axis,
            children,
            weights,
        } => {
            let total: f64 = weights.iter().map(|w| f64::from(*w)).sum();
            let mut off = 0.0;
            for (c, w) in children.iter().zip(weights) {
                let f = f64::from(*w) / total;
                let sub = match axis {
                    Axis::Row => (r.0 + r.2 * off, r.1, r.2 * f, r.3),
                    Axis::Column => (r.0, r.1 + r.3 * off, r.2, r.3 * f),
                };
                rects(c, sub, out);
                off += f;
            }
        }
    }
}

impl Workbench {
    /// The center's rectangle in the window's units (px or cells), and each region's.
    pub(crate) fn region_rects(&self, wi: usize) -> Vec<(Region, Rect)> {
        let win = &self.windows[wi];
        let t = self.table(wi);
        let d = &self.defaults;
        let (title, status) = match (win.chrome_hidden, win.tty) {
            (true, _) => (0, 0),
            (false, true) => (d.tty.title_row, d.tty.status_bar),
            (false, false) => (d.title_row, d.status_bar),
        };
        let width = win.size.width();
        let height = win.size.height();
        let rail = crate::fold::rail_width(t, width, win.chrome_hidden);
        let left = if win.left.visible && win.fold.left == SideFold::Open {
            win.left.width
        } else {
            0
        };
        let (right, strip) = match (win.right.visible, win.fold.right) {
            (true, SideFold::Open) => (win.right.width, false),
            (true, SideFold::Folded) => (0, true),
            _ => (0, false),
        };
        let cw = crate::fold::center_width(t, width, rail, left, right, strip).max(1) as i32;
        let gap = t.gap as i32;
        let body = height.saturating_sub(title + status) as i32;
        let bottom = if win.bottom.visible {
            win.bottom.height as i32
        } else {
            0
        };
        let mut v = Vec::new();
        let mut x = 0;
        if rail > 0 {
            v.push((
                Region::Rail,
                Rect {
                    x,
                    y: title as i32,
                    w: rail as i32,
                    h: body,
                },
            ));
            x += rail as i32;
        }
        x += gap;
        if left > 0 {
            v.push((
                Region::Left,
                Rect {
                    x,
                    y: title as i32,
                    w: left as i32,
                    h: body,
                },
            ));
            x += left as i32 + gap;
        }
        v.push((
            Region::Center,
            Rect {
                x,
                y: title as i32,
                w: cw,
                h: (body - bottom).max(1),
            },
        ));
        if bottom > 0 {
            v.push((
                Region::Bottom,
                Rect {
                    x,
                    y: title as i32 + body - bottom,
                    w: cw,
                    h: bottom,
                },
            ));
        }
        x += cw + gap;
        if right > 0 || strip {
            let rw = if strip { t.strip } else { right } as i32;
            v.push((
                Region::Right,
                Rect {
                    x,
                    y: title as i32,
                    w: rw,
                    h: body,
                },
            ));
        }
        v
    }

    /// Each visible group's rectangle in the window's units.
    pub(crate) fn group_rects(&self, wi: usize) -> Vec<(GroupId, Rect)> {
        let c = self
            .region_rects(wi)
            .into_iter()
            .find(|(r, _)| *r == Region::Center)
            .map(|x| x.1)
            .unwrap_or_default();
        let r = (
            f64::from(c.x),
            f64::from(c.y),
            f64::from(c.w),
            f64::from(c.h),
        );
        let mut out = Vec::new();
        match self.windows[wi].center.full_size {
            Some(fs) => out.push((fs, c)),
            None => rects(&self.windows[wi].center.tree, r, &mut out),
        }
        out
    }

    /// The group next to `g` in direction `d`: the nearest one past that edge that overlaps it across.
    fn neighbour(&self, wi: usize, g: GroupId, d: Dir4) -> Option<GroupId> {
        let rs = self.group_rects(wi);
        let me = rs.iter().find(|(x, _)| *x == g)?.1;
        rs.iter()
            .filter(|(x, _)| *x != g)
            .filter_map(|(x, r)| {
                let (dist, overlap) = match d {
                    Dir4::Left => (me.x - (r.x + r.w), overlap(me.y, me.h, r.y, r.h)),
                    Dir4::Right => (r.x - (me.x + me.w), overlap(me.y, me.h, r.y, r.h)),
                    Dir4::Up => (me.y - (r.y + r.h), overlap(me.x, me.w, r.x, r.w)),
                    Dir4::Down => (r.y - (me.y + me.h), overlap(me.x, me.w, r.x, r.w)),
                };
                (dist >= 0 && overlap > 0).then_some((dist, -overlap, *x))
            })
            .min()
            .map(|x| x.2)
    }

    /// A window's arrangement now, for layout undo and saved layouts (a temporary layout's tool tab is left out and
    /// its return tab counts as active).
    pub(crate) fn take_layout(&self, wi: usize) -> LayoutSnapshot {
        let win = &self.windows[wi];
        let snap_group = |g: GroupId| {
            let grp = &self.groups[&g];
            let tool = grp.temp.as_ref().map(|t| t.tab);
            let active = match &grp.temp {
                Some(t) => t.return_to,
                None => grp.active,
            };
            let ids: Vec<TabId> = grp
                .tabs
                .iter()
                .copied()
                .filter(|t| Some(*t) != tool)
                .collect();
            SnapGroup {
                active: active.and_then(|a| ids.iter().position(|x| *x == a)),
                tabs: ids
                    .iter()
                    .map(|t| {
                        let tab = &self.tabs[t];
                        SnapTab {
                            r: tab.r.clone(),
                            preview: tab.preview,
                            kind: tab.kind.clone(),
                            title: tab.title.clone(),
                        }
                    })
                    .collect(),
            }
        };
        fn conv(n: &Node, f: &dyn Fn(GroupId) -> SnapGroup) -> SnapNode {
            match n {
                Node::Leaf(g) => SnapNode::Leaf(f(*g)),
                Node::Split {
                    axis,
                    children,
                    weights,
                } => SnapNode::Split {
                    axis: *axis,
                    children: children.iter().map(|c| conv(c, f)).collect(),
                    weights: weights.clone(),
                },
            }
        }
        let leaves = win.center.tree.leaves();
        let pos = |g: GroupId| leaves.iter().position(|x| *x == g);
        LayoutSnapshot {
            tree: conv(&win.center.tree, &snap_group),
            active: pos(win.center.active_group).unwrap_or(0),
            full_size: win.center.full_size.and_then(pos),
            left_place: win.left.place.clone(),
            left_visible: win.left.visible,
            left_width: win.left.width,
            right_tab: win.right.tab,
            right_visible: win.right.visible,
            right_width: win.right.width,
            bottom_visible: win.bottom.visible,
            bottom_height: win.bottom.height,
            chrome_hidden: win.chrome_hidden,
        }
    }

    pub(crate) fn push_undo(&mut self, wi: usize) {
        let s = self.take_layout(wi);
        let cap = self.defaults.undo_cap;
        let u = &mut self.windows[wi].layout_undo;
        u.push(s);
        while u.len() > cap {
            u.remove(0);
        }
    }

    /// Make window `wi` match a snapshot. Tabs are found by ref (a killed buffer is skipped, a closed one made
    /// again); tabs the snapshot does not name join the first group.
    pub(crate) fn apply_layout(&mut self, wi: usize, s: &LayoutSnapshot) {
        let old_groups = self.windows[wi].center.tree.leaves();
        let mut pool: Vec<TabId> = self.center_tabs(wi);
        let mut made: Vec<(GroupId, bool)> = Vec::new();
        let tree = self.build_tree(wi, &s.tree, &mut pool, &mut made);
        for g in old_groups {
            self.groups.remove(&g);
        }
        let mut tree = tree;
        // groups that came out empty only because their refs are gone are dropped
        for (g, was_empty) in &made {
            if !was_empty && self.groups[g].tabs.is_empty() && tree.leaves().len() > 1 {
                tree.remove_leaf(*g);
                self.groups.remove(g);
            }
        }
        let leaves = tree.leaves();
        let first = leaves[0];
        for t in pool {
            self.join_group(first, t);
        }
        let win = &mut self.windows[wi];
        win.center.active_group = leaves.get(s.active).copied().unwrap_or(first);
        win.center.full_size = s.full_size.and_then(|i| leaves.get(i).copied());
        win.center.tree = tree;
        win.left.place = s.left_place.clone();
        win.left.visible = s.left_visible;
        win.left.width = s.left_width;
        win.right.tab = s.right_tab;
        win.right.visible = s.right_visible;
        win.right.width = s.right_width;
        win.bottom.visible = s.bottom_visible;
        win.bottom.height = s.bottom_height;
        win.chrome_hidden = s.chrome_hidden;
        let ag = win.center.active_group;
        if matches!(win.focus.base(), Focus::Center(_)) {
            self.set_base_focus(wi, Focus::Center(ag));
        }
        self.refold(wi);
    }

    fn build_tree(
        &mut self,
        wi: usize,
        n: &SnapNode,
        pool: &mut Vec<TabId>,
        made: &mut Vec<(GroupId, bool)>,
    ) -> Node {
        match n {
            SnapNode::Split {
                axis,
                children,
                weights,
            } => Node::Split {
                axis: *axis,
                children: children
                    .iter()
                    .map(|c| self.build_tree(wi, c, pool, made))
                    .collect(),
                weights: weights.clone(),
            },
            SnapNode::Leaf(sg) => {
                let g = self.new_group(Vec::new());
                made.push((g, sg.tabs.is_empty()));
                let mut active = None;
                for (i, st) in sg.tabs.iter().enumerate() {
                    let Some(t) = self.take_or_make(wi, st, pool) else {
                        continue;
                    };
                    self.join_group(g, t);
                    if sg.active == Some(i) {
                        active = Some(t);
                    }
                }
                let grp = self.group_mut(g);
                if let Some(a) = active.or(grp.tabs.first().copied()) {
                    grp.active = Some(a);
                    grp.mru.retain(|x| *x != a);
                    grp.mru.insert(0, a);
                }
                Node::Leaf(g)
            }
        }
    }

    /// The tab for a snapshot entry: one now in the center (or the bottom panel) showing the same ref, or a new one;
    /// None for a killed buffer.
    fn take_or_make(&mut self, wi: usize, st: &SnapTab, pool: &mut Vec<TabId>) -> Option<TabId> {
        if let Ref::Buffer { id, .. } = &st.r
            && self.gone_buffers.contains(id)
        {
            return None;
        }
        if let Some(i) = pool.iter().position(|t| self.tabs[t].r.same(&st.r)) {
            let t = pool.remove(i);
            if let Some(g) = self.group_of(t) {
                self.detach(g, t);
            }
            return Some(t);
        }
        let b = &mut self.windows[wi].bottom;
        if let Some(i) = b.tabs.iter().position(|t| self.tabs[t].r.same(&st.r)) {
            let t = b.tabs.remove(i);
            if b.active == Some(t) {
                b.active = b.tabs.last().copied();
            }
            if b.tabs.is_empty() {
                b.visible = false;
            }
            return Some(t);
        }
        Some(self.new_tab(
            st.r.clone(),
            st.preview,
            Some(st.kind.clone()),
            Some(st.title.clone()),
        ))
    }

    /// Take a tab out of a group's lists, leaving the group (even empty) in place.
    pub(crate) fn detach(&mut self, g: GroupId, t: TabId) {
        let grp = self.group_mut(g);
        grp.tabs.retain(|x| *x != t);
        grp.mru.retain(|x| *x != t);
        if grp.preview == Some(t) {
            grp.preview = None;
        }
        if grp.active == Some(t) {
            grp.active = grp.mru.first().copied();
        }
    }

    /// Append a tab to a group (not activated unless the group had none); a second preview is pinned (W3).
    pub(crate) fn join_group(&mut self, g: GroupId, t: TabId) {
        let has_preview = self.groups[&g].preview.is_some();
        let tab = self.tabs.get_mut(&t).expect("tab");
        if tab.preview && has_preview {
            tab.preview = false;
        }
        let preview = tab.preview;
        let grp = self.group_mut(g);
        grp.tabs.push(t);
        grp.mru.push(t);
        if preview {
            grp.preview = Some(t);
        }
        if grp.active.is_none() {
            grp.active = Some(t);
            grp.mru.retain(|x| *x != t);
            grp.mru.insert(0, t);
        }
    }

    /// Remove a group from its window's tree; its space goes to its sibling, focus and the active group follow.
    pub(crate) fn remove_group(&mut self, wi: usize, g: GroupId) {
        let leaves = self.windows[wi].center.tree.leaves();
        let i = leaves.iter().position(|x| *x == g).unwrap_or(0);
        let heir = if i > 0 {
            leaves[i - 1]
        } else {
            leaves.get(1).copied().unwrap_or(g)
        };
        let win = &mut self.windows[wi];
        win.center.tree.remove_leaf(g);
        if win.center.full_size == Some(g) {
            win.center.full_size = None;
        }
        if win.center.active_group == g {
            win.center.active_group = heir;
        }
        if let Focus::Center(x) = win.focus.base()
            && *x == g
        {
            self.set_base_focus(wi, Focus::Center(heir));
        }
        self.groups.remove(&g);
    }

    fn layout_gate(&mut self, g: GroupId, origin: Origin) -> Result<usize, Refusal> {
        self.gate(origin, Intent::Layout)?;
        let Some(w) = self.window_of_group(g) else {
            return refuse("no such group");
        };
        self.wi(w)
    }

    fn check_split(&self, wi: usize, g: GroupId, side: Side) -> Result<(), Refusal> {
        let d = &self.defaults;
        if self.windows[wi].center.tree.leaves().len() >= d.max_groups {
            return refuse(format!("a window holds at most {} groups", d.max_groups));
        }
        let (mw, mh) = if self.windows[wi].tty {
            (d.tty.split_min_w, d.tty.split_min_h)
        } else {
            (d.split_min_w, d.split_min_h)
        };
        let Some((_, r)) = self.group_rects(wi).into_iter().find(|(x, _)| *x == g) else {
            return refuse("full size shows one group");
        };
        let small = match side {
            Side::Right => r.w / 2 < mw as i32,
            Side::Down => r.h / 2 < mh as i32,
        };
        if small {
            return refuse(format!(
                "a split here would make a group smaller than {mw} × {mh}"
            ));
        }
        Ok(())
    }

    /// Split a group: its active tab moves into the new group (a lone text tab is shown in both; never an empty
    /// group). At most 8 groups; refused when a half would be under 320 × 160.
    pub fn split(
        &mut self,
        g: GroupId,
        side: Side,
        origin: Origin,
    ) -> Result<(Version, GroupId), Refusal> {
        let wi = self.layout_gate(g, origin)?;
        let grp = &self.groups[&g];
        if let Some(tl) = &grp.temp {
            return refuse(crate::intent::temp_reason(&tl.tool));
        }
        let Some(a) = grp.active else {
            return refuse("an empty group has nothing to split off");
        };
        let lone = grp.tabs.len() == 1;
        if lone && !self.tabs[&a].r.is_text() {
            return refuse("a page or a conversation is shown in one place");
        }
        self.check_split(wi, g, side)?;
        self.push_undo(wi);
        let t = if lone {
            let tab = self.tabs[&a].clone();
            self.new_tab(tab.r, false, Some(tab.kind), Some(tab.title))
        } else {
            self.detach(g, a);
            a
        };
        let n = self.add_group_beside(wi, g, side, t);
        Ok((self.bump(), n))
    }

    fn add_group_beside(&mut self, wi: usize, g: GroupId, side: Side, t: TabId) -> GroupId {
        let n = self.new_group(Vec::new());
        self.join_group(n, t);
        let axis = if side == Side::Right {
            Axis::Row
        } else {
            Axis::Column
        };
        self.windows[wi].center.tree.insert_beside(g, n, axis);
        self.activate(wi, n, t);
        self.set_base_focus(wi, Focus::Center(n));
        n
    }

    /// Move a tab to a group, a new group beside one, the bottom panel (terminals) or a new OS window.
    pub fn move_tab(
        &mut self,
        t: TabId,
        target: MoveTarget,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        self.gate(origin, Intent::Layout)?;
        let Some(w) = self.window_of_tab(t) else {
            return refuse("no such tab");
        };
        let wi = self.wi(w)?;
        let src = self.group_of(t);
        if let Some(s) = src
            && self.groups[&s].temp.is_some()
        {
            return refuse("a temporary layout holds this group");
        }
        match target {
            MoveTarget::NewOsWindow => {
                self.tear_out(crate::multi::TearOut::Tab(t), origin)?;
                return Ok(self.version);
            }
            MoveTarget::Bottom => {
                if src.is_none() {
                    return refuse("the tab is in the bottom panel already");
                }
                if !self.kinds.is_bottom(&self.tabs[&t].kind) {
                    return refuse("only a bottom kind (a terminal) moves to the bottom panel");
                }
                self.push_undo(wi);
                self.take_out(wi, t);
                let tab = self.tabs.get_mut(&t).expect("tab");
                tab.preview = false;
                let b = &mut self.windows[wi].bottom;
                b.tabs.push(t);
                b.active = Some(t);
                b.visible = true;
            }
            MoveTarget::Group(g) => {
                let Some(gw) = self.window_of_group(g) else {
                    return refuse("no such group");
                };
                let gwi = self.wi(gw)?;
                if self.groups[&g].temp.is_some() {
                    return refuse("a temporary layout holds that group");
                }
                if src == Some(g) {
                    return Ok(self.version);
                }
                if self.page_elsewhere(gwi, t) {
                    return refuse("that window shows this page already");
                }
                self.push_undo(wi);
                self.take_out(wi, t);
                self.join_group(g, t);
                self.activate(gwi, g, t);
            }
            MoveTarget::NewGroup(g, side) => {
                if self.window_of_group(g) != Some(w) {
                    return refuse("no such group in this window");
                }
                self.check_split(wi, g, side)?;
                if self.page_elsewhere(wi, t) {
                    return refuse("this window shows this page already");
                }
                if src == Some(g) && self.groups[&g].tabs.len() == 1 {
                    return refuse("the group would be left empty");
                }
                self.push_undo(wi);
                if let Some(s) = src {
                    self.detach(s, t);
                } else {
                    self.windows[wi].bottom.tabs.retain(|x| *x != t);
                    let b = &mut self.windows[wi].bottom;
                    if b.active == Some(t) {
                        b.active = b.tabs.last().copied();
                    }
                }
                self.add_group_beside(wi, g, side, t);
                if let Some(s) = src
                    && self.groups[&s].tabs.is_empty()
                {
                    self.remove_group(wi, s);
                }
            }
        }
        self.fix_focus(wi);
        Ok(self.bump())
    }

    /// Whether `t` is a page tab whose kind another tab in window `wi`'s center already shows (W3: one per window).
    fn page_elsewhere(&self, wi: usize, t: TabId) -> bool {
        let r = &self.tabs[&t].r;
        r.is_page()
            && self
                .center_tabs(wi)
                .into_iter()
                .any(|x| x != t && self.tabs[&x].r.same(r))
    }

    /// Take a tab out of its group (an emptied group goes unless it is the last) or the bottom panel, keeping it.
    pub(crate) fn take_out(&mut self, wi: usize, t: TabId) {
        if let Some(g) = self.group_of(t) {
            self.detach(g, t);
            if self.groups[&g].tabs.is_empty() && self.windows[wi].center.tree.leaves().len() > 1 {
                self.remove_group(wi, g);
            }
        } else {
            let b = &mut self.windows[wi].bottom;
            b.tabs.retain(|x| *x != t);
            if b.active == Some(t) {
                b.active = b.tabs.last().copied();
            }
            if b.tabs.is_empty() {
                b.visible = false;
            }
        }
    }

    /// Swap two neighbouring groups' tabs; the groups (Emacs's windows) stay where they are.
    pub fn swap(&mut self, g: GroupId, d: Dir4, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.layout_gate(g, origin)?;
        let Some(n) = self.neighbour(wi, g, d) else {
            return refuse("no group there");
        };
        if self.groups[&g].temp.is_some() || self.groups[&n].temp.is_some() {
            return refuse("a temporary layout holds the group");
        }
        self.push_undo(wi);
        let a = self.groups[&g].clone();
        let b = self.groups[&n].clone();
        for (to, from) in [(g, &b), (n, &a)] {
            let grp = self.group_mut(to);
            grp.tabs = from.tabs.clone();
            grp.active = from.active;
            grp.preview = from.preview;
            grp.mru = from.mru.clone();
        }
        self.set_base_focus(wi, Focus::Center(n));
        Ok(self.bump())
    }

    /// Merge a group's tabs into its neighbour's; the group goes.
    pub fn stack(&mut self, g: GroupId, d: Dir4, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.layout_gate(g, origin)?;
        let Some(n) = self.neighbour(wi, g, d) else {
            return refuse("no group there");
        };
        if self.groups[&g].temp.is_some() || self.groups[&n].temp.is_some() {
            return refuse("a temporary layout holds the group");
        }
        self.push_undo(wi);
        let moved = self.groups[&g].tabs.clone();
        let active = self.groups[&g].active;
        for t in moved {
            self.detach(g, t);
            self.join_group(n, t);
        }
        if let Some(a) = active {
            self.activate(wi, n, a);
        }
        self.remove_group(wi, g);
        self.set_base_focus(wi, Focus::Center(n));
        Ok(self.bump())
    }

    /// Directional focus: between groups, from an edge group into the side on that side, and from a side back into
    /// the nearest group. Navigation: not undoable.
    pub fn focus_dir(&mut self, w: WinId, d: Dir4, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Focus)?;
        let win = &self.windows[wi];
        let base = win.focus.base().clone();
        let rs = self.group_rects(wi);
        let edge = |pick: &dyn Fn(&Rect) -> i32, best_max: bool| -> Option<GroupId> {
            let v = rs.iter().map(|(_, r)| pick(r));
            let target = if best_max { v.max()? } else { v.min()? };
            let ag = win.center.active_group;
            let cands: Vec<GroupId> = rs
                .iter()
                .filter(|(_, r)| pick(r) == target)
                .map(|(g, _)| *g)
                .collect();
            if cands.contains(&ag) {
                Some(ag)
            } else {
                cands.first().copied()
            }
        };
        let to = match (base, d) {
            (Focus::Center(g), _) => match self.neighbour(wi, g, d) {
                Some(n) => Focus::Center(n),
                None => match d {
                    Dir4::Left if win.left.visible => Focus::Left,
                    Dir4::Right if win.right.visible => Focus::Right,
                    Dir4::Down if win.bottom.visible => Focus::Bottom,
                    _ => return refuse("nothing there"),
                },
            },
            (Focus::Left, Dir4::Right) => {
                Focus::Center(edge(&|r| r.x, false).ok_or_else(|| Refusal::new("no group"))?)
            }
            (Focus::Right, Dir4::Left) => {
                Focus::Center(edge(&|r| r.x + r.w, true).ok_or_else(|| Refusal::new("no group"))?)
            }
            (Focus::Bottom, Dir4::Up) => {
                Focus::Center(edge(&|r| r.y + r.h, true).ok_or_else(|| Refusal::new("no group"))?)
            }
            _ => return refuse("nothing there"),
        };
        match to {
            Focus::Left if win.fold.left == SideFold::Folded => {
                self.open_side_overlay(wi, Region::Left)
            }
            Focus::Right if win.fold.right == SideFold::Folded => {
                self.open_side_overlay(wi, Region::Right)
            }
            f => self.set_base_focus(wi, f),
        }
        Ok(self.bump())
    }

    /// Show the active group alone, or everything again (W4).
    pub fn full_size(&mut self, w: WinId, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        self.push_undo(wi);
        let win = &mut self.windows[wi];
        win.center.full_size = match win.center.full_size {
            Some(_) => None,
            None => Some(win.center.active_group),
        };
        self.fix_focus(wi);
        Ok(self.bump())
    }

    /// Set a split's weights (the split at `path`, child indices from the root).
    pub fn resize_split(
        &mut self,
        w: WinId,
        path: &[usize],
        weights: &[f32],
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        let ok = match self.windows[wi].center.tree.clone().node_at_mut(path) {
            Some(Node::Split { weights: ws, .. }) => ws.len() == weights.len(),
            _ => false,
        };
        if !ok || weights.iter().any(|x| !x.is_finite() || *x <= 0.0) {
            return refuse("no such split, or weights that do not fit it");
        }
        self.push_undo(wi);
        let sum: f32 = weights.iter().sum();
        if let Some(Node::Split { weights: ws, .. }) =
            self.windows[wi].center.tree.node_at_mut(path)
        {
            *ws = weights.iter().map(|x| x / sum).collect();
        }
        Ok(self.bump())
    }

    /// Close a group: its tabs go to Reopen Closed Tab; the last group stays, empty.
    pub fn close_group(&mut self, g: GroupId, origin: Origin) -> Result<Version, Refusal> {
        let wi = self.layout_gate(g, origin)?;
        if let Some(tl) = &self.groups[&g].temp {
            return refuse(crate::intent::temp_reason(&tl.tool));
        }
        self.push_undo(wi);
        for t in self.groups[&g].tabs.clone() {
            let r = self.tabs[&t].r.clone();
            self.detach(g, t);
            self.tabs.remove(&t);
            self.windows[wi].closed_tabs.push(r);
        }
        let cap = self.defaults.closed_cap;
        let c = &mut self.windows[wi].closed_tabs;
        while c.len() > cap {
            c.remove(0);
        }
        if self.windows[wi].center.tree.leaves().len() > 1 {
            self.remove_group(wi, g);
        }
        self.fix_focus(wi);
        Ok(self.bump())
    }

    /// Restore Previous Layout: pop one snapshot.
    pub fn restore_previous_layout(
        &mut self,
        w: WinId,
        origin: Origin,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        self.gate(origin, Intent::Layout)?;
        if self.any_temp(wi) {
            return refuse("a temporary layout is running");
        }
        let Some(s) = self.windows[wi].layout_undo.pop() else {
            return refuse("no earlier layout");
        };
        self.apply_layout(wi, &s);
        Ok(self.bump())
    }

    pub(crate) fn any_temp(&self, wi: usize) -> bool {
        self.windows[wi]
            .center
            .tree
            .leaves()
            .iter()
            .any(|g| self.groups[g].temp.is_some())
    }

    pub fn undo_depth(&self, w: WinId) -> usize {
        self.windows
            .iter()
            .find(|x| x.id == w)
            .map_or(0, |x| x.layout_undo.len())
    }
}

fn overlap(a: i32, al: i32, b: i32, bl: i32) -> i32 {
    (a + al).min(b + bl) - a.max(b)
}
