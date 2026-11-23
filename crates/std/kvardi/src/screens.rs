//! Displays, windows and the zoom memory: which scale a window has, and what survives a move to another display.

use std::collections::BTreeMap;

use crate::{Scale, clamp_zoom};

/// A rectangle in the desktop's physical pixels.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn new(x: i32, y: i32, w: i32, h: i32) -> Rect {
        Rect { x, y, w, h }
    }

    /// The area both rectangles cover.
    fn overlap(&self, o: &Rect) -> i64 {
        let x0 = i64::from(self.x).max(i64::from(o.x));
        let y0 = i64::from(self.y).max(i64::from(o.y));
        let x1 = (i64::from(self.x) + i64::from(self.w)).min(i64::from(o.x) + i64::from(o.w));
        let y1 = (i64::from(self.y) + i64::from(self.h)).min(i64::from(o.y) + i64::from(o.h));
        if x1 <= x0 || y1 <= y0 {
            0
        } else {
            (x1 - x0) * (y1 - y0)
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct DisplayId(pub u32);

/// One display: where it is on the desktop and its own scale (mixed DPI is the normal case).
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Display {
    pub id: DisplayId,
    pub area: Rect,
    pub output: f32,
}

/// A window: the preset it shows, where it is, the display it is on, and the zoom of its panes and panels (a pane's
/// or panel's own zoom is the window's, and moves with it).
#[derive(Clone, PartialEq, Debug)]
pub struct Window {
    preset: String,
    area: Rect,
    display: Option<DisplayId>,
    panes: BTreeMap<String, f32>,
    panels: BTreeMap<String, f32>,
    layouts: u32,
}

impl Window {
    pub fn new(preset: &str, area: Rect) -> Window {
        Window {
            preset: preset.to_string(),
            area,
            display: None,
            panes: BTreeMap::new(),
            panels: BTreeMap::new(),
            layouts: 0,
        }
    }

    /// The display the window is on, if it is on one.
    pub fn display(&self) -> Option<DisplayId> {
        self.display
    }

    /// How many times the window laid out again because it took another display's scale.
    pub fn layouts(&self) -> u32 {
        self.layouts
    }

    pub fn set_pane_zoom(&mut self, pane: &str, zoom: f32) {
        self.panes.insert(pane.to_string(), clamp_zoom(zoom));
    }

    pub fn set_panel_zoom(&mut self, panel: &str, zoom: f32) {
        self.panels.insert(panel.to_string(), clamp_zoom(zoom));
    }
}

/// The displays, the app's zoom, and each window preset's zoom on each display.
#[derive(Clone, Default, Debug)]
pub struct Screens {
    displays: BTreeMap<DisplayId, Display>,
    app: Option<f32>,
    window_zoom: BTreeMap<(DisplayId, String), f32>,
}

impl Screens {
    pub fn new() -> Screens {
        Screens::default()
    }

    /// A display appears, or changes (a new scale, a new place).
    pub fn set_display(&mut self, id: DisplayId, area: Rect, output: f32) {
        self.displays.insert(id, Display { id, area, output });
    }

    pub fn remove_display(&mut self, id: DisplayId) {
        self.displays.remove(&id);
    }

    pub fn set_app_zoom(&mut self, zoom: f32) {
        self.app = Some(clamp_zoom(zoom));
    }

    /// The window moves or resizes to AREA. It takes the display that holds most of it (the lowest id on a tie), and
    /// lays out once when that is another display. A window that is on no display keeps the one it had.
    pub fn place(&self, w: &mut Window, area: Rect) {
        w.area = area;
        let best = self
            .displays
            .values()
            .map(|d| (d.area.overlap(&area), d.id))
            .filter(|(o, _)| *o > 0)
            // the largest overlap; the lowest id breaks a tie
            .max_by_key(|(o, id)| (*o, std::cmp::Reverse(*id)))
            .map(|(_, id)| id);
        if let Some(id) = best
            && w.display != Some(id)
        {
            w.display = Some(id);
            w.layouts += 1;
        }
    }

    /// The window's zoom on the display it is on, remembered for that display and the window's preset.
    pub fn set_window_zoom(&mut self, w: &Window, zoom: f32) {
        if let Some(d) = w.display {
            self.window_zoom
                .insert((d, w.preset.clone()), clamp_zoom(zoom));
        }
    }

    /// The scale for a pane and a panel of W (none: no zoom of their own): the output scale of the display W is on, the
    /// app's zoom, the window's zoom on that display, and the pane's and panel's own.
    pub fn scale(&self, w: &Window, pane: Option<&str>, panel: Option<&str>) -> Scale {
        let output = w
            .display
            .and_then(|d| self.displays.get(&d))
            .map_or(1.0, |d| d.output);
        let window = w
            .display
            .and_then(|d| self.window_zoom.get(&(d, w.preset.clone())))
            .copied()
            .unwrap_or(1.0);
        Scale {
            output,
            app: self.app.unwrap_or(1.0),
            window,
            pane: pane.and_then(|p| w.panes.get(p)).copied().unwrap_or(1.0),
            panel: panel.and_then(|p| w.panels.get(p)).copied().unwrap_or(1.0),
        }
    }
}
