//! Folding at narrow widths (§4.6) as data: one table for px, one for terminal columns, one function for both.
//!
//! The right folds when the center would drop under its floor with the right open, then the left when the center
//! would drop under its own floor (the folded right's strip counted). A side the user hid stays hidden; folding
//! applies only to open sides. Every visible column (rail, left, center, right or its strip) costs one gap.

use crate::model::{
    Focus, Fold, OverlayKind, Refusal, Region, SideFold, Version, WinId, WinSize, Workbench,
};

/// One unit system's fold rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FoldTable {
    /// The rail's width, and the window width from which it shows (0: always).
    pub rail: u32,
    pub rail_from: u32,
    /// The folded right's strip (0: none).
    pub strip: u32,
    /// Per visible column.
    pub gap: u32,
    /// The right folds when the center would be under this with it open.
    pub right_center_min: u32,
    /// The left folds when the center would be under this with it open.
    pub left_center_min: u32,
}

/// Graphical windows, logical px [D5].
pub const FOLD_PX: FoldTable = FoldTable {
    rail: 44,
    rail_from: 0,
    strip: 44,
    gap: 6,
    right_center_min: 900,
    left_center_min: 800,
};

/// Terminal frames, columns (§6.6): the rail only from 100 columns.
pub const FOLD_CELLS: FoldTable = FoldTable {
    rail: 4,
    rail_from: 100,
    strip: 0,
    gap: 1,
    right_center_min: 80,
    left_center_min: 60,
};

/// The rail's width at this window width (0: hidden).
pub fn rail_width(t: &FoldTable, width: u32, chrome_hidden: bool) -> u32 {
    if chrome_hidden || width < t.rail_from {
        0
    } else {
        t.rail
    }
}

/// The center's width with these columns (`strip`: the folded right's strip shows).
pub fn center_width(
    t: &FoldTable,
    width: u32,
    rail: u32,
    left: u32,
    right: u32,
    strip: bool,
) -> i64 {
    let strip_w = if strip { t.strip } else { 0 };
    let cols = 1 + u32::from(rail > 0) + u32::from(left > 0) + u32::from(right > 0 || strip_w > 0);
    i64::from(width)
        - i64::from(rail)
        - i64::from(left)
        - i64::from(right)
        - i64::from(strip_w)
        - i64::from(t.gap * cols)
}

/// The fold for a window: `left` / `right` are the open sides' widths (None: hidden by the user).
pub fn compute(
    t: &FoldTable,
    width: u32,
    chrome_hidden: bool,
    left: Option<u32>,
    right: Option<u32>,
) -> (SideFold, SideFold) {
    let rail = rail_width(t, width, chrome_hidden);
    let right_folded = match right {
        Some(r) => {
            center_width(t, width, rail, left.unwrap_or(0), r, false)
                < i64::from(t.right_center_min)
        }
        None => false,
    };
    let right_open = if right_folded { 0 } else { right.unwrap_or(0) };
    let left_folded = match left {
        Some(l) => {
            center_width(t, width, rail, l, right_open, right_folded) < i64::from(t.left_center_min)
        }
        None => false,
    };
    let f = |b| if b { SideFold::Folded } else { SideFold::Open };
    (f(left_folded), f(right_folded))
}

impl Workbench {
    pub(crate) fn table(&self, wi: usize) -> &'static FoldTable {
        if self.windows[wi].tty {
            &FOLD_CELLS
        } else {
            &FOLD_PX
        }
    }

    /// Recompute a window's fold; an overlay of a side that no longer folds closes, and a focused side that folds
    /// gives focus to the active group.
    pub(crate) fn refold(&mut self, wi: usize) {
        let t = *self.table(wi);
        let w = &self.windows[wi];
        let (l, r) = compute(
            &t,
            w.size.width(),
            w.chrome_hidden,
            w.left.visible.then_some(w.left.width),
            w.right.visible.then_some(w.right.width),
        );
        let w = &mut self.windows[wi];
        w.fold.left = l;
        w.fold.right = r;
        let stale = match w.fold.overlay {
            Some(Region::Left) => l == SideFold::Open || !w.left.visible,
            Some(Region::Right) => r == SideFold::Open || !w.right.visible,
            _ => false,
        };
        if stale {
            let ids: Vec<_> = w
                .overlays
                .iter()
                .filter(|o| o.kind == OverlayKind::Side)
                .map(|o| o.id)
                .collect();
            for id in ids {
                self.drop_overlay(wi, id);
            }
        }
        self.fix_focus(wi);
    }

    /// Set an OS window's size (px, or cells on a terminal) and scale; folds follow.
    pub fn set_window_size(
        &mut self,
        w: WinId,
        size: WinSize,
        scale: f32,
    ) -> Result<Version, Refusal> {
        let wi = self.wi(w)?;
        let win = &mut self.windows[wi];
        if matches!(size, WinSize::Cells { .. }) != win.tty {
            return crate::model::refuse(
                "a terminal frame is sized in cells, a graphical one in px",
            );
        }
        win.size = size;
        win.scale = if scale > 0.0 { scale } else { 1.0 };
        self.refold(wi);
        Ok(self.bump())
    }

    pub fn fold(&self, w: WinId) -> Option<Fold> {
        self.windows.iter().find(|x| x.id == w).map(|x| x.fold)
    }
}

/// The focus a side overlay returns to: the center (§4.6).
pub(crate) fn side_return(ag: crate::model::GroupId) -> Focus {
    Focus::Center(ag)
}
