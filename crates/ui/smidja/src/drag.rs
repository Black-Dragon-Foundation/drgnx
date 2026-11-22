//! Drags (design §6.4; Task 22): a tab dragged to a drop zone, a divider dragged to resize, and the tab strips' scroll.
//! The glue runs them in its pointer path with no Lisp call; what a drag ends in is one command (`tab-move`,
//! `split-resize`, `region-resize`, the `move_tab`, `resize_split` and `resize` ops' arguments) that Lisp runs.
//!
//! Coordinates are the chrome description's: device px from the OS window's top-left.  A tab drag starts once the
//! pointer moved [`THRESHOLD`] logical px from the press (less is a click).  Its zone is the group card under the
//! pointer (its right or bottom quarter: a new group on that side), the bottom panel's card, or, outside the window, a
//! new OS window.  A divider is the gap beside a side region's card or between two parts of a split; dragging it
//! resizes live, at most one resize handed on per frame ([`Drag::take_live`], which the glue calls once per publish).

use crate::abi::Val;
use crate::chrome::{ChromeDesc, ChromeRole, Element, element_at};
use crate::hit::element_key;
use crate::layout::{MoveTarget, Side};
use crate::model::{Axis, GroupId, Node, Rect, Region, TabId, WinId, Workbench};

/// Logical px the pointer moves from the press before a tab drag starts.
pub const THRESHOLD: f32 = 4.0;

/// What a drag ends in: one command for Lisp.
#[derive(Clone, Debug, PartialEq)]
pub enum DropCommand {
    TabMove {
        tab: TabId,
        target: MoveTarget,
    },
    /// The split at `path` of the center's tree gets `weights`.
    SplitResize {
        path: Vec<usize>,
        weights: Vec<f32>,
    },
    /// A side region's size, logical px.
    RegionResize {
        region: Region,
        size: u32,
    },
}

impl DropCommand {
    /// The command's id and arguments for OS window W, as the click event carries them.
    pub fn command(&self, w: WinId) -> (&'static str, Vec<Val>) {
        let int = |v: u64| Val::Int(v as i64);
        let sym = |s: &str| Val::Sym(s.into());
        match self {
            DropCommand::TabMove { tab, target } => {
                let t = match target {
                    MoveTarget::Group(g) => Val::List(vec![sym("group"), int(g.0)]),
                    MoveTarget::NewGroup(g, side) => Val::List(vec![
                        sym("new-group"),
                        int(g.0),
                        sym(match side {
                            Side::Right => "right",
                            Side::Down => "down",
                        }),
                    ]),
                    MoveTarget::Bottom => Val::List(vec![sym("bottom")]),
                    MoveTarget::NewOsWindow => Val::List(vec![sym("new-os-window")]),
                };
                ("tab-move", vec![int(tab.0), t])
            }
            DropCommand::SplitResize { path, weights } => (
                "split-resize",
                vec![
                    int(w.0),
                    Val::List(path.iter().map(|i| int(*i as u64)).collect()),
                    Val::List(weights.iter().map(|v| Val::Float(f64::from(*v))).collect()),
                ],
            ),
            DropCommand::RegionResize { region, size } => (
                "region-resize",
                vec![
                    int(w.0),
                    sym(match region {
                        Region::Left => "left",
                        Region::Right => "right",
                        _ => "bottom",
                    }),
                    int(u64::from(*size)),
                ],
            ),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum What {
    Tab(TabId),
    Region(Region),
    /// The divider after child `index` of the split at `path`, along `axis`.
    Split {
        path: Vec<usize>,
        index: usize,
        axis: Axis,
    },
}

/// A drag in progress.
#[derive(Clone, Debug, PartialEq)]
pub struct Drag {
    what: What,
    w: WinId,
    from: (i32, i32),
    at: (i32, i32),
    started: bool,
    /// The live resize not handed on yet.
    pending: Option<DropCommand>,
}

fn inside(r: Rect, x: i32, y: i32) -> bool {
    x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

/// A card's region or group from its key (`chrome.rs`: a group's is 0x100 + its id).
fn card_of(e: &Element) -> Option<Result<Region, GroupId>> {
    let key = element_key(e.id);
    if key >= 0x100 {
        return Some(Err(GroupId(key - 0x100)));
    }
    [Region::Left, Region::Bottom, Region::Right]
        .into_iter()
        .find(|r| *r as u64 == key)
        .map(Ok)
}

fn region_card(desc: &ChromeDesc, region: Region) -> Option<Rect> {
    desc.of_role(ChromeRole::Card)
        .find(|e| card_of(e) == Some(Ok(region)))
        .map(|e| e.rect)
}

/// The cards' union of the groups under N.
fn extent(desc: &ChromeDesc, n: &Node) -> Option<Rect> {
    match n {
        Node::Leaf(g) => desc
            .of_role(ChromeRole::Card)
            .find(|e| card_of(e) == Some(Err(*g)))
            .map(|e| e.rect),
        Node::Split { children, .. } => {
            children
                .iter()
                .filter_map(|c| extent(desc, c))
                .reduce(|a, b| {
                    let (x, y) = (a.x.min(b.x), a.y.min(b.y));
                    Rect {
                        x,
                        y,
                        w: (a.x + a.w).max(b.x + b.w) - x,
                        h: (a.y + a.h).max(b.y + b.h) - y,
                    }
                })
        }
    }
}

/// Along AXIS: a rect's start and length.
fn span(r: Rect, axis: Axis) -> (i32, i32) {
    match axis {
        Axis::Row => (r.x, r.w),
        Axis::Column => (r.y, r.h),
    }
}

/// Every divider of the tree N: its split's path, the child before it, and the gap's rect.
type Divider = (Vec<usize>, usize, Axis, Rect);

fn dividers(desc: &ChromeDesc, n: &Node, path: &mut Vec<usize>, out: &mut Vec<Divider>) {
    let Node::Split { axis, children, .. } = n else {
        return;
    };
    let axis = *axis;
    let ext: Vec<Option<Rect>> = children.iter().map(|c| extent(desc, c)).collect();
    for i in 0..children.len().saturating_sub(1) {
        if let (Some(a), Some(b)) = (ext[i], ext[i + 1]) {
            let gap = match axis {
                Axis::Row => Rect {
                    x: a.x + a.w,
                    y: a.y.min(b.y),
                    w: b.x - (a.x + a.w),
                    h: a.h.max(b.h),
                },
                Axis::Column => Rect {
                    x: a.x.min(b.x),
                    y: a.y + a.h,
                    w: a.w.max(b.w),
                    h: b.y - (a.y + a.h),
                },
            };
            out.push((path.clone(), i, axis, gap));
        }
    }
    for (i, c) in children.iter().enumerate() {
        path.push(i);
        dividers(desc, c, path, out);
        path.pop();
    }
}

impl Drag {
    /// The tab being dragged, once the drag started (before that the press is a click's).
    pub fn tab(&self) -> Option<TabId> {
        match self.what {
            What::Tab(t) if self.started => Some(t),
            _ => None,
        }
    }

    /// A divider drag's axis (`Row`: the divider moves left and right).
    pub fn divider(&self) -> Option<Axis> {
        match &self.what {
            What::Region(Region::Bottom) => Some(Axis::Column),
            What::Region(_) => Some(Axis::Row),
            What::Split { axis, .. } => Some(*axis),
            What::Tab(_) => None,
        }
    }

    /// Whether the pointer moved far enough for a drag.
    pub fn started(&self) -> bool {
        self.started
    }

    /// The pointer moved to (X, Y); a divider's resize there waits for [`Drag::take_live`].
    pub fn motion(&mut self, wb: &Workbench, desc: &ChromeDesc, x: i32, y: i32) {
        self.at = (x, y);
        let t = (THRESHOLD * desc.scale).round() as i32;
        if (x - self.from.0).abs() >= t || (y - self.from.1).abs() >= t {
            self.started = true;
        }
        if self.started && !matches!(self.what, What::Tab(_)) {
            self.pending = self.resize(wb, desc);
        }
    }

    /// The live resize to hand on now: the newest since the last call, at most one.
    pub fn take_live(&mut self) -> Option<DropCommand> {
        self.pending.take()
    }

    /// A tab drag's drop zone at the pointer and the rect it lights (none outside the window).
    pub fn zone(&self, desc: &ChromeDesc) -> Option<(MoveTarget, Option<Rect>)> {
        if !matches!(self.what, What::Tab(_)) || !self.started {
            return None;
        }
        let (x, y) = self.at;
        if x < 0 || y < 0 || x >= desc.width || y >= desc.height {
            return Some((MoveTarget::NewOsWindow, None));
        }
        let card = desc
            .of_role(ChromeRole::Card)
            .filter(|e| inside(e.rect, x, y))
            .last()?;
        let r = card.rect;
        match card_of(card)? {
            Ok(Region::Bottom) => Some((MoveTarget::Bottom, Some(r))),
            Ok(_) => None,
            Err(g) => Some(if x >= r.x + r.w - r.w / 4 {
                let half = Rect {
                    x: r.x + r.w / 2,
                    w: r.w - r.w / 2,
                    ..r
                };
                (MoveTarget::NewGroup(g, Side::Right), Some(half))
            } else if y >= r.y + r.h - r.h / 4 {
                let half = Rect {
                    y: r.y + r.h / 2,
                    h: r.h - r.h / 2,
                    ..r
                };
                (MoveTarget::NewGroup(g, Side::Down), Some(half))
            } else {
                (MoveTarget::Group(g), Some(r))
            }),
        }
    }

    /// The drag ends at (X, Y): its one command, if any.  A tab not moved past the threshold, or dropped on its own
    /// group's middle, moves nothing; a divider not moved resizes nothing.
    pub fn end(mut self, wb: &Workbench, desc: &ChromeDesc, x: i32, y: i32) -> Option<DropCommand> {
        self.motion(wb, desc, x, y);
        if !self.started {
            return None;
        }
        match self.what {
            What::Tab(t) => {
                let (target, _) = self.zone(desc)?;
                if let MoveTarget::Group(g) = target
                    && wb.group_of(t) == Some(g)
                {
                    return None;
                }
                Some(DropCommand::TabMove { tab: t, target })
            }
            _ => self.resize(wb, desc),
        }
    }

    /// The resize the pointer asks for now.
    fn resize(&self, wb: &Workbench, desc: &ChromeDesc) -> Option<DropCommand> {
        let s = desc.scale;
        let (x, y) = self.at;
        match &self.what {
            What::Tab(_) => None,
            What::Region(region) => {
                let r = region_card(desc, *region)?;
                let size = match region {
                    Region::Left => x - r.x,
                    Region::Right => r.x + r.w - x,
                    _ => r.y + r.h - y,
                };
                Some(DropCommand::RegionResize {
                    region: *region,
                    size: (size.max(0) as f32 / s).round() as u32,
                })
            }
            What::Split { path, index, .. } => {
                let tree = &wb.windows.iter().find(|o| o.id == self.w)?.center.tree;
                let Node::Split { axis, children, .. } = node_at(tree, path)? else {
                    return None;
                };
                let ext: Vec<i32> = children
                    .iter()
                    .map(|c| extent(desc, c).map_or(0, |r| span(r, *axis).1))
                    .collect();
                let a = span(extent(desc, &children[*index])?, *axis);
                let d = &wb.defaults;
                let min = (match axis {
                    Axis::Row => d.split_min_w,
                    Axis::Column => d.split_min_h,
                } as f32
                    * s) as i32;
                let pair = ext[*index] + ext[index + 1];
                let at = match axis {
                    Axis::Row => x,
                    Axis::Column => y,
                };
                let first = (at - a.0).clamp(min.min(pair / 2), (pair - min).max(pair / 2));
                let mut out = ext;
                out[*index] = first;
                out[index + 1] = pair - first;
                let total: i32 = out.iter().sum();
                Some(DropCommand::SplitResize {
                    path: path.clone(),
                    weights: out.iter().map(|v| *v as f32 / total as f32).collect(),
                })
            }
        }
    }
}

fn node_at<'a>(n: &'a Node, path: &[usize]) -> Option<&'a Node> {
    match path.split_first() {
        None => Some(n),
        Some((i, rest)) => match n {
            Node::Split { children, .. } => node_at(children.get(*i)?, rest),
            Node::Leaf(_) => None,
        },
    }
}

impl Workbench {
    /// A press at (X, Y) of OS window W's chrome DESC starts a drag: on a tab (not its ×) a tab drag, on a divider a
    /// resize; None elsewhere.
    pub fn drag_begin(&self, w: WinId, desc: &ChromeDesc, x: i32, y: i32) -> Option<Drag> {
        let what = match element_at(desc, x, y) {
            Some(e)
                if matches!(
                    e.role,
                    ChromeRole::Tab
                        | ChromeRole::TabIcon
                        | ChromeRole::TabTitle
                        | ChromeRole::TabDirty
                        | ChromeRole::TabAgent
                ) =>
            {
                // a tab the model has (a stale description's is no drag)
                let t = TabId(element_key(e.id));
                if !self.tabs.contains_key(&t) {
                    return None;
                }
                What::Tab(t)
            }
            Some(e) if e.role != ChromeRole::Card => return None,
            _ => self.divider_at(w, desc, x, y)?,
        };
        Some(Drag {
            what,
            w,
            from: (x, y),
            at: (x, y),
            started: false,
            pending: None,
        })
    }

    /// Whether (X, Y) of DESC is on a divider of OS window W.
    pub fn on_divider(&self, w: WinId, desc: &ChromeDesc, x: i32, y: i32) -> bool {
        self.divider_at(w, desc, x, y).is_some()
    }

    /// The divider at (X, Y): the gap beside a side region's card (towards the center) or between two parts of a
    /// split; a hand's width of slack around a gap.
    fn divider_at(&self, w: WinId, desc: &ChromeDesc, x: i32, y: i32) -> Option<What> {
        if element_at(desc, x, y).is_some_and(|e| e.role != ChromeRole::Card) {
            return None;
        }
        let gap = (self.defaults.gap as f32 * desc.scale).round() as i32;
        let slack = (2.0 * desc.scale).round() as i32;
        let near = |r: Rect| {
            x >= r.x - slack && x < r.x + r.w + slack && y >= r.y - slack && y < r.y + r.h + slack
        };
        for (region, gap_rect) in [Region::Left, Region::Right, Region::Bottom]
            .into_iter()
            .filter_map(|reg| Some((reg, region_card(desc, reg)?)))
            .map(|(reg, r)| {
                let g = match reg {
                    Region::Left => Rect {
                        x: r.x + r.w,
                        w: gap,
                        ..r
                    },
                    Region::Right => Rect {
                        x: r.x - gap,
                        w: gap,
                        ..r
                    },
                    _ => Rect {
                        y: r.y - gap,
                        h: gap,
                        ..r
                    },
                };
                (reg, g)
            })
        {
            if near(gap_rect) {
                return Some(What::Region(region));
            }
        }
        let tree = &self.windows.iter().find(|o| o.id == w)?.center.tree;
        let mut all = Vec::new();
        dividers(desc, tree, &mut Vec::new(), &mut all);
        all.into_iter()
            .find(|(_, _, _, r)| near(*r))
            .map(|(path, index, axis, _)| What::Split { path, index, axis })
    }

    /// Scroll group G's tab strip by DELTA tabs (negative: towards its start) from what it shows; whether it moved.
    /// The chrome is built anew ([`Workbench::chrome_generation`]); the model's version does not change.
    pub fn tab_strip_scroll(&mut self, g: GroupId, delta: i32) -> bool {
        let Some(grp) = self.groups.get(&g) else {
            return false;
        };
        let (n, active) = (grp.tabs.len(), grp.active);
        let shown = self.strip_shown.get(g);
        let to = (shown as i64 + i64::from(delta)).clamp(0, n.saturating_sub(1) as i64) as usize;
        if to == shown {
            return false;
        }
        self.strip_scroll.insert(g, (to, active));
        self.chrome_gen += 1;
        true
    }

    /// Where group G's strip starts: the user's scroll while the tab it was made under is still active (false: keep
    /// it), else what it showed last with the active tab to be brought into view (true).
    pub(crate) fn strip_start(&self, g: GroupId) -> (usize, bool) {
        let active = self.groups.get(&g).and_then(|grp| grp.active);
        match self.strip_scroll.get(&g) {
            Some((first, a)) if *a == active => (*first, false),
            _ => (self.strip_shown.get(g), true),
        }
    }

    /// Counts the chrome's changes that are not the model's (a strip scrolled).
    pub fn chrome_generation(&self) -> u64 {
        self.chrome_gen
    }
}
