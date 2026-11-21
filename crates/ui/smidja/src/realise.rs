//! What the realiser builds (§5.1): the skeleton per OS window in device px, and the actual edges it sends back.
//!
//! Chrome and hit tests use the edges Emacs reported, never the requested sizes, once they are there; edges for an
//! older version are ignored.

use crate::model::{
    EdgeKey, Focus, GroupId, Node, OverlayId, OverlayKind, Rect, Ref, Region, SideFold, TabId,
    Version, WinId, Workbench,
};

/// One region of the skeleton: shown or not, folded (the right's strip), its size in device px (cells on a TTY).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RegionReal {
    pub region: Region,
    pub visible: bool,
    pub folded: bool,
    pub size: u32,
}

/// A center group: its active tab and ref, and the attached pane's ref (a conversation's composer, §5.2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GroupReal {
    pub id: GroupId,
    pub active: Option<TabId>,
    pub r: Option<Ref>,
    pub attached: Option<Ref>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Realisation {
    pub version: Version,
    pub regions: Vec<RegionReal>,
    /// The center's tree as shown (full size: the one group).
    pub tree: Node,
    pub groups: Vec<GroupReal>,
    pub bottom: Option<(TabId, Ref)>,
    pub focus: Focus,
    /// Groups held by a temporary layout and the tool's tab.
    pub temp: Vec<(GroupId, TabId)>,
    pub overlays: Vec<(OverlayId, OverlayKind)>,
}

impl Workbench {
    fn scale_of(&self, wi: usize) -> f32 {
        let w = &self.windows[wi];
        if w.tty { 1.0 } else { w.scale }
    }

    /// The skeleton for an OS window.
    pub fn realisation(&self, w: WinId) -> Option<Realisation> {
        let wi = self.windows.iter().position(|x| x.id == w)?;
        let win = &self.windows[wi];
        let s = self.scale_of(wi);
        let dev = |v: u32| (v as f32 * s).round() as u32;
        let rects = self.region_rects(wi);
        let size = |r: Region| {
            rects.iter().find(|x| x.0 == r).map_or(0, |x| match r {
                Region::Bottom => x.1.h as u32,
                _ => x.1.w as u32,
            })
        };
        let regions = vec![
            RegionReal {
                region: Region::Rail,
                visible: size(Region::Rail) > 0,
                folded: false,
                size: dev(size(Region::Rail)),
            },
            RegionReal {
                region: Region::Left,
                visible: win.left.visible && win.fold.left == SideFold::Open,
                folded: win.left.visible && win.fold.left == SideFold::Folded,
                size: dev(win.left.width),
            },
            RegionReal {
                region: Region::Center,
                visible: true,
                folded: false,
                size: dev(size(Region::Center)),
            },
            RegionReal {
                region: Region::Right,
                visible: win.right.visible,
                folded: win.right.visible && win.fold.right == SideFold::Folded,
                size: dev(size(Region::Right)),
            },
            RegionReal {
                region: Region::Bottom,
                visible: win.bottom.visible,
                folded: false,
                size: dev(win.bottom.height),
            },
        ];
        let tree = match win.center.full_size {
            Some(fs) => Node::Leaf(fs),
            None => win.center.tree.clone(),
        };
        let groups = tree
            .leaves()
            .into_iter()
            .map(|g| {
                let grp = &self.groups[&g];
                let r = grp.active.map(|t| self.tabs[&t].r.clone());
                let attached = r.clone().filter(|r| matches!(r, Ref::Session { .. }));
                GroupReal {
                    id: g,
                    active: grp.active,
                    r,
                    attached,
                }
            })
            .collect();
        let bottom = win
            .bottom
            .active
            .filter(|_| win.bottom.visible)
            .map(|t| (t, self.tabs[&t].r.clone()));
        let temp = win
            .center
            .tree
            .leaves()
            .into_iter()
            .filter_map(|g| self.groups[&g].temp.as_ref().map(|t| (g, t.tab)))
            .collect();
        Some(Realisation {
            version: self.version,
            regions,
            tree,
            groups,
            bottom,
            focus: win.focus.clone(),
            temp,
            overlays: win.overlays.iter().map(|o| (o.id, o.kind)).collect(),
        })
    }

    /// Emacs's actual device-px edges after realising `version`; ignored (false) when the model has moved on.
    pub fn set_edges(&mut self, w: WinId, version: Version, edges: Vec<(EdgeKey, Rect)>) -> bool {
        if version != self.version {
            return false;
        }
        match self.windows.iter_mut().find(|x| x.id == w) {
            Some(win) => {
                win.edges = edges;
                true
            }
            None => false,
        }
    }

    /// The left's section I as requested: the left below its region header, shared evenly by the place's sections.
    fn section_rect(&self, wi: usize, i: u32) -> Option<Rect> {
        let win = &self.windows[wi];
        let left = self
            .region_rects(wi)
            .into_iter()
            .find(|x| x.0 == Region::Left)?
            .1;
        let place = win.left.place.as_deref()?;
        let n = self
            .kinds
            .places
            .iter()
            .find(|p| p.place == place)?
            .sections
            .len() as i32;
        if i as i32 >= n {
            return None;
        }
        let top = left.y + self.defaults.region_header as i32;
        let each = (left.h - self.defaults.region_header as i32).max(0) / n;
        Some(Rect {
            x: left.x,
            y: top + i as i32 * each,
            w: left.w,
            h: each,
        })
    }

    /// The rectangle chrome and hit tests use, in device px: the reported edge, else the requested one.
    pub fn rect(&self, w: WinId, key: EdgeKey) -> Option<Rect> {
        let wi = self.windows.iter().position(|x| x.id == w)?;
        if let Some((_, r)) = self.windows[wi].edges.iter().find(|(k, _)| *k == key) {
            return Some(*r);
        }
        let s = self.scale_of(wi);
        let r = match key {
            EdgeKey::Region(reg) => self.region_rects(wi).into_iter().find(|x| x.0 == reg)?.1,
            EdgeKey::Group(g) => self.group_rects(wi).into_iter().find(|x| x.0 == g)?.1,
            EdgeKey::Section(i) => self.section_rect(wi, i)?,
        };
        let d = |v: i32| (v as f32 * s).round() as i32;
        Some(Rect {
            x: d(r.x),
            y: d(r.y),
            w: d(r.w),
            h: d(r.h),
        })
    }
}
