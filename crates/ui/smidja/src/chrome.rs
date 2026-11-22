//! The chrome description (design §6.1, §6.3 rule 3; Task 17): what the workbench's chrome shows, element by element,
//! with rectangles in device px from the edges Emacs reported (the requested ones until then).
//!
//! The model never sees pixels, colours or fonts: a text's width comes from the caller's `measure` (the glue shapes it
//! in the role's font), as a number. Each element has a stable id per chrome part (§6.3 rule 2), so the glue's scene
//! diffs by id and a hit test (`hit`) answers the element under a point. Hover, press and scroll are the glue's; the
//! description carries only the model's state (active, preview, dirty, counts, focus).

use crate::model::{
    EdgeKey, Focus, GroupId, Rect, Ref, Region, RightTab, SideFold, TabId, WinId, Workbench,
};

/// What an element is. The glue's style table gives each role its look.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ChromeRole {
    TitleRow,
    TitleProject,
    TitleSearch,
    TitleNeedsYou,
    TitleAgents,
    WinMinimize,
    WinMaximize,
    WinClose,
    Rail,
    RailItem,
    StatusBar,
    StatusNeedsYou,
    /// A region's or group's card: the islands (radius 10, gaps 6).
    Card,
    FocusRing,
    TabStrip,
    Tab,
    TabIcon,
    TabTitle,
    TabDirty,
    TabAgent,
    TabClose,
    StripSplit,
    StripMore,
    /// A strip whose tabs do not all fit: the arrows, the fade at the shown tabs' end, and "+N" (the hidden ones).
    StripScrollLeft,
    StripScrollRight,
    StripFade,
    StripCount,
    Breadcrumb,
    BottomStrip,
    RegionHeader,
    RegionTitle,
    RightTabItem,
    DetailPin,
    SectionHeader,
    FoldStrip,
    FoldItem,
}

/// The font role a text is measured and drawn in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TextRole {
    Ui,
    /// A preview tab's title.
    UiItalic,
    /// Region and section titles.
    UiStrong,
}

/// The model's state of an element (never hover or press: the glue's).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub active: bool,
    pub preview: bool,
    pub dirty: bool,
    pub agent: bool,
    pub changed: bool,
    /// The lit rail place, the shown right tab.
    pub lit: bool,
    pub count: u64,
    /// Ember: the count is the user's to act on (§9.3).
    pub needs_you: bool,
}

/// One chrome element: its id (stable while it exists), role, name (its text or label), icon, rect (device px), the
/// text's role, the element it sits in, and its state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Element {
    pub id: u64,
    pub role: ChromeRole,
    pub name: String,
    pub icon: String,
    pub rect: Rect,
    pub text: Option<TextRole>,
    pub parent: Option<u64>,
    pub state: State,
}

/// The chrome of one OS window, in drawing order (parents before children).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChromeDesc {
    pub window: u64,
    pub version: u64,
    /// Device px per logical px.
    pub scale: f32,
    /// The OS window's size, device px.
    pub width: i32,
    pub height: i32,
    pub elements: Vec<Element>,
}

impl ChromeDesc {
    pub fn get(&self, id: u64) -> Option<&Element> {
        self.elements.iter().find(|e| e.id == id)
    }

    pub fn of_role(&self, role: ChromeRole) -> impl Iterator<Item = &Element> {
        self.elements.iter().filter(move |e| e.role == role)
    }
}

/// An element's id: its role in the top byte, a key (a tab, group, place index, …) below.
pub fn element_id(role: ChromeRole, key: u64) -> u64 {
    ((role as u64 + 1) << 56) | (key & ((1 << 56) - 1))
}

/// Sizes the chrome lays out with, logical px; the strips and bands are the model's own defaults.
const ICON: i32 = 16;
const PAD: i32 = 10;
const TAB_MIN: i32 = 80;
const TAB_MAX: i32 = 240;
const CLOSE: i32 = 16;
const ARROW: i32 = 20;
const COUNT: i32 = 36;
const FADE: i32 = 24;
const BUTTON: i32 = 28;
const RAIL_ITEM: i32 = 36;
const CHIP: i32 = 28;
const SEARCH_W: i32 = 480;

struct Builder<'a> {
    s: f32,
    out: Vec<Element>,
    measure: &'a dyn Fn(&str, TextRole) -> u32,
}

impl Builder<'_> {
    fn d(&self, v: i32) -> i32 {
        (v as f32 * self.s).round() as i32
    }

    fn push(&mut self, role: ChromeRole, key: u64, rect: Rect, parent: Option<u64>) -> u64 {
        let id = element_id(role, key);
        self.out.push(Element {
            id,
            role,
            name: String::new(),
            icon: String::new(),
            rect,
            text: None,
            parent,
            state: State::default(),
        });
        id
    }

    fn last(&mut self) -> &mut Element {
        self.out.last_mut().expect("an element was pushed")
    }

    fn text(&mut self, name: &str, role: TextRole) {
        let e = self.last();
        e.name = name.to_string();
        e.text = Some(role);
    }

    fn width(&self, name: &str, role: TextRole) -> i32 {
        i32::try_from((self.measure)(name, role)).unwrap_or(i32::MAX)
    }
}

fn rect(x: i32, y: i32, w: i32, h: i32) -> Rect {
    Rect { x, y, w, h }
}

/// A tab's title as the strip shows it.
fn ref_crumb(r: &Ref) -> String {
    match r {
        Ref::File { path, .. } => path.clone(),
        Ref::Buffer { name, .. } => name.clone(),
        Ref::Page { page_kind, key } => key
            .as_ref()
            .map_or_else(|| page_kind.clone(), |k| format!("{page_kind} › {k}")),
        Ref::Session { id } => id.clone(),
        Ref::Output { channel } => channel.clone(),
    }
}

impl Workbench {
    /// The chrome of OS window `w` (None: no such window, or a terminal one: its chrome is text, §6.6). `measure`
    /// gives a text's width in device px in a role's font.
    pub fn chrome(&self, w: WinId, measure: &dyn Fn(&str, TextRole) -> u32) -> Option<ChromeDesc> {
        let wi = self.windows.iter().position(|x| x.id == w)?;
        let win = &self.windows[wi];
        if win.tty {
            return None;
        }
        let d = &self.defaults;
        let mut b = Builder {
            s: win.scale,
            out: Vec::new(),
            measure,
        };
        let (fw, fh) = (b.d(win.size.width() as i32), b.d(win.size.height() as i32));
        let reg = |r: Region| self.rect(w, EdgeKey::Region(r));
        let focus = win.focus.base().clone();

        // the frame strips: title row, status bar (the rail is a region)
        if !win.chrome_hidden {
            let th = b.d(d.title_row as i32);
            let title = b.push(ChromeRole::TitleRow, 0, rect(0, 0, fw, th), None);
            let name = win.project.clone().unwrap_or_default();
            let pw = b.width(&name, TextRole::UiStrong);
            b.push(
                ChromeRole::TitleProject,
                0,
                rect(b.d(PAD + 4), 0, pw, th),
                Some(title),
            );
            b.text(&name, TextRole::UiStrong);
            let sw = b.d(SEARCH_W).min(fw / 3);
            b.push(
                ChromeRole::TitleSearch,
                0,
                rect((fw - sw) / 2, b.d(5), sw, th - b.d(10)),
                Some(title),
            );
            b.last().icon = "search".into();
            let chip = b.d(CHIP);
            // window controls at the right, then the chips left of them
            let step = b.d(BUTTON + 8);
            let mut x = fw - 3 * step;
            for (i, (role, icon)) in [
                (ChromeRole::WinMinimize, "minus"),
                (ChromeRole::WinMaximize, "square"),
                (ChromeRole::WinClose, "x"),
            ]
            .into_iter()
            .enumerate()
            {
                b.push(
                    role,
                    0,
                    rect(x + i as i32 * step, (th - chip) / 2, b.d(BUTTON), chip),
                    Some(title),
                );
                b.last().icon = icon.into();
            }
            x -= b.d(8);
            for (role, key, icon) in [
                (ChromeRole::TitleAgents, 1, "bot"),
                (ChromeRole::TitleNeedsYou, 0, "bell"),
            ] {
                x -= b.d(CHIP + 20);
                b.push(
                    role,
                    key,
                    rect(x, (th - chip) / 2, b.d(CHIP + 16), chip),
                    Some(title),
                );
                let e = b.last();
                e.icon = icon.into();
                if role == ChromeRole::TitleNeedsYou {
                    e.state.count = self.attention.count;
                    e.state.needs_you = self.attention.count > 0;
                }
            }
            let sh = b.d(d.status_bar as i32);
            let status = b.push(ChromeRole::StatusBar, 0, rect(0, fh - sh, fw, sh), None);
            b.push(
                ChromeRole::StatusNeedsYou,
                0,
                rect(fw - b.d(80), fh - sh, b.d(72), sh),
                Some(status),
            );
            let e = b.last();
            e.icon = "bell".into();
            e.state.count = self.attention.count;
            e.state.needs_you = self.attention.count > 0;
        }

        // the rail: the places in declaration order, the foot ones at the bottom
        if let Some(r) =
            reg(Region::Rail).filter(|_| self.region_rects(wi).iter().any(|x| x.0 == Region::Rail))
        {
            let rail = b.push(ChromeRole::Rail, 0, r, None);
            let item = b.d(RAIL_ITEM);
            let x = r.x + (r.w - item) / 2;
            let (mut top, mut foot) = (r.y + b.d(8), r.y + r.h - b.d(8));
            for (i, p) in self.kinds.places.iter().enumerate() {
                let y = if p.foot {
                    foot -= item + b.d(4);
                    foot + b.d(4)
                } else {
                    top += item + b.d(4);
                    top - item - b.d(4)
                };
                b.push(
                    ChromeRole::RailItem,
                    i as u64,
                    rect(x, y, item, item),
                    Some(rail),
                );
                let e = b.last();
                e.name = p.place.clone();
                e.icon = p.icon.clone();
                e.state.lit = win.left.place.as_deref() == Some(p.place.as_str());
            }
        }

        // the left: card, region header, section headers
        if let Some(r) =
            reg(Region::Left).filter(|_| win.left.visible && win.fold.left == SideFold::Open)
        {
            let card = b.push(ChromeRole::Card, Region::Left as u64, r, None);
            if focus == Focus::Left {
                b.push(ChromeRole::FocusRing, Region::Left as u64, r, Some(card));
            }
            let hh = b.d(d.region_header as i32);
            let place = win.left.place.clone().unwrap_or_default();
            let hdr = b.push(
                ChromeRole::RegionHeader,
                Region::Left as u64,
                rect(r.x, r.y, r.w, hh),
                Some(card),
            );
            b.push(
                ChromeRole::RegionTitle,
                Region::Left as u64,
                rect(r.x + b.d(PAD + 2), r.y, r.w - b.d(2 * PAD), hh),
                Some(hdr),
            );
            b.text(&place, TextRole::UiStrong);
            let sections = self
                .kinds
                .places
                .iter()
                .find(|p| p.place == place)
                .map(|p| p.sections.clone())
                .unwrap_or_default();
            for (i, name) in sections.iter().enumerate() {
                let sr = self.rect(w, EdgeKey::Section(i as u32)).unwrap_or_default();
                // the first section's header sits under the region header, on the same window (R I-7)
                let y = if i == 0 { r.y + hh } else { sr.y };
                b.push(
                    ChromeRole::SectionHeader,
                    i as u64,
                    rect(r.x, y, r.w, b.d(d.section_header as i32)),
                    Some(card),
                );
                b.text(name, TextRole::UiStrong);
            }
        }

        // the center: each group's card, tab strip and breadcrumb
        let groups = self.group_rects(wi);
        for (g, _) in &groups {
            let Some(r) = self.rect(w, EdgeKey::Group(*g)) else {
                continue;
            };
            self.group_chrome(&mut b, *g, r, focus == Focus::Center(*g));
        }

        // the bottom panel's strip
        if let Some(r) = reg(Region::Bottom).filter(|_| win.bottom.visible) {
            let card = b.push(ChromeRole::Card, Region::Bottom as u64, r, None);
            if focus == Focus::Bottom {
                b.push(ChromeRole::FocusRing, Region::Bottom as u64, r, Some(card));
            }
            let strip = b.push(
                ChromeRole::BottomStrip,
                0,
                rect(r.x, r.y, r.w, b.d(d.tab_strip as i32)),
                Some(card),
            );
            let tabs: Vec<TabId> = win.bottom.tabs.clone();
            let th = b.d(d.tab_strip as i32);
            self.tabs_chrome(&mut b, strip, r.x, r.y, th, &tabs, win.bottom.active);
        }

        // the right: open (card, header with the four tabs, Detail's pin) or folded (the strip)
        if let Some(r) = reg(Region::Right).filter(|_| win.right.visible) {
            let count = |t: RightTab| {
                self.attention
                    .by_kind
                    .iter()
                    .find(|(k, _)| k == t.name())
                    .map_or(0, |x| x.1)
            };
            let icon = |t: RightTab| match t {
                RightTab::Detail => "info",
                RightTab::Agents => "bot",
                RightTab::Inbox => "inbox",
                RightTab::PullRequests => "git-pull-request",
            };
            if win.fold.right == SideFold::Folded {
                let strip = b.push(ChromeRole::FoldStrip, 0, r, None);
                let item = b.d(RAIL_ITEM);
                for (i, t) in RightTab::ALL.into_iter().enumerate() {
                    let y = r.y + b.d(8) + i as i32 * (item + b.d(4));
                    b.push(
                        ChromeRole::FoldItem,
                        i as u64,
                        rect(r.x + (r.w - item) / 2, y, item, item),
                        Some(strip),
                    );
                    let e = b.last();
                    e.name = t.name().into();
                    e.icon = icon(t).into();
                    e.state.count = count(t);
                    e.state.needs_you =
                        matches!(t, RightTab::Agents | RightTab::Inbox) && count(t) > 0;
                    e.state.changed = win.right.changed.contains(&t);
                }
            } else {
                let card = b.push(ChromeRole::Card, Region::Right as u64, r, None);
                if focus == Focus::Right {
                    b.push(ChromeRole::FocusRing, Region::Right as u64, r, Some(card));
                }
                let hh = b.d(d.region_header as i32);
                let hdr = b.push(
                    ChromeRole::RegionHeader,
                    Region::Right as u64,
                    rect(r.x, r.y, r.w, hh),
                    Some(card),
                );
                let mut x = r.x + b.d(6);
                for (i, t) in RightTab::ALL.into_iter().enumerate() {
                    let n = count(t);
                    let label = if n > 0 { format!("{n}") } else { String::new() };
                    let tw = b.d(ICON + 2 * 8)
                        + if n > 0 {
                            b.width(&label, TextRole::Ui) + b.d(4)
                        } else {
                            0
                        };
                    b.push(
                        ChromeRole::RightTabItem,
                        i as u64,
                        rect(x, r.y, tw, hh),
                        Some(hdr),
                    );
                    b.text(&label, TextRole::Ui);
                    let e = b.last();
                    e.icon = icon(t).into();
                    e.state.lit = win.right.tab == t;
                    e.state.count = n;
                    e.state.needs_you = matches!(t, RightTab::Agents | RightTab::Inbox) && n > 0;
                    e.state.changed = win.right.changed.contains(&t);
                    x += tw;
                }
                if win.right.tab == RightTab::Detail {
                    let bw = b.d(BUTTON);
                    b.push(
                        ChromeRole::DetailPin,
                        0,
                        rect(r.x + r.w - bw - b.d(6), r.y + (hh - bw) / 2, bw, bw),
                        Some(hdr),
                    );
                    let e = b.last();
                    e.icon = "pin".into();
                    e.state.active = win.right.detail_pin.is_some();
                }
            }
        }

        Some(ChromeDesc {
            window: w.0,
            version: self.version.0,
            scale: win.scale,
            width: fw,
            height: fh,
            elements: b.out,
        })
    }

    fn group_chrome(&self, b: &mut Builder, g: GroupId, r: Rect, focused: bool) {
        let d = &self.defaults;
        let grp = &self.groups[&g];
        let card = b.push(ChromeRole::Card, 0x100 + g.0, r, None);
        if focused {
            b.push(ChromeRole::FocusRing, 0x100 + g.0, r, Some(card));
        }
        let th = b.d(d.tab_strip as i32);
        let strip = b.push(
            ChromeRole::TabStrip,
            g.0,
            rect(r.x, r.y, r.w, th),
            Some(card),
        );
        let bw = b.d(BUTTON);
        let tabs = grp.tabs.clone();
        // the tabs that fit before the split and more buttons; when not all do, from the strip's start (the user's
        // scroll, or the active tab brought into view), then the fade, "+N" and the arrows
        let x0 = r.x + b.d(4);
        let avail = r.x + r.w - 2 * bw - b.d(4) - x0;
        let widths: Vec<i32> = tabs.iter().map(|t| self.tab_w(b, *t)).collect();
        let (first, n) = if widths.iter().sum::<i32>() <= avail {
            (0, tabs.len())
        } else {
            let lim = avail - b.d(COUNT) - 2 * b.d(ARROW);
            let fits = |from: usize, to: usize| widths[from..to].iter().sum::<i32>() <= lim;
            let (mut first, reveal) = self.strip_start(g);
            first = first.min(tabs.len() - 1);
            if let Some(ai) = grp
                .active
                .and_then(|a| tabs.iter().position(|t| *t == a))
                .filter(|_| reveal)
            {
                first = first.min(ai);
                while first < ai && !fits(first, ai + 1) {
                    first += 1;
                }
            }
            while first > 0 && fits(first - 1, tabs.len()) {
                first -= 1;
            }
            let n = (first..tabs.len())
                .take_while(|i| fits(first, i + 1))
                .count()
                .max(1);
            (first, n)
        };
        self.strip_shown.set(g, first);
        self.tabs_chrome(b, strip, r.x, r.y, th, &tabs[first..first + n], grp.active);
        if n < tabs.len() {
            let mut x = x0 + avail - b.d(COUNT) - 2 * b.d(ARROW);
            b.push(
                ChromeRole::StripFade,
                g.0,
                rect(x - b.d(FADE), r.y, b.d(FADE), th),
                Some(strip),
            );
            b.push(
                ChromeRole::StripCount,
                g.0,
                rect(x, r.y, b.d(COUNT), th),
                Some(strip),
            );
            b.text(&format!("+{}", tabs.len() - n), TextRole::Ui);
            x += b.d(COUNT);
            for (role, icon) in [
                (ChromeRole::StripScrollLeft, "chevron-left"),
                (ChromeRole::StripScrollRight, "chevron-right"),
            ] {
                let aw = b.d(ARROW);
                b.push(role, g.0, rect(x, r.y + (th - aw) / 2, aw, aw), Some(strip));
                b.last().icon = icon.into();
                x += aw;
            }
        }
        for (i, (role, icon)) in [
            (ChromeRole::StripSplit, "columns-2"),
            (ChromeRole::StripMore, "ellipsis"),
        ]
        .into_iter()
        .enumerate()
        {
            let x = r.x + r.w - (2 - i as i32) * bw - b.d(4);
            b.push(role, g.0, rect(x, r.y + (th - bw) / 2, bw, bw), Some(strip));
            b.last().icon = icon.into();
        }
        let ch = b.d(d.breadcrumb as i32);
        let crumb = grp
            .active
            .map(|t| ref_crumb(&self.tabs[&t].r))
            .unwrap_or_default();
        b.push(
            ChromeRole::Breadcrumb,
            g.0,
            rect(r.x, r.y + th, r.w, ch),
            Some(card),
        );
        b.text(&crumb, TextRole::Ui);
    }

    /// Tab T's width in its strip: icon, title, marks and ×, within the tab's bounds.
    fn tab_w(&self, b: &Builder, t: TabId) -> i32 {
        let tab = &self.tabs[&t];
        let role = if tab.preview {
            TextRole::UiItalic
        } else {
            TextRole::Ui
        };
        let marks = i32::from(tab.dirty) + i32::from(tab.marks.iter().any(|m| m == "agent"));
        (b.d(PAD + ICON + 6 + CLOSE + PAD + 6 * marks) + b.width(&tab.title, role))
            .clamp(b.d(TAB_MIN), b.d(TAB_MAX))
    }

    /// TABS laid out in a strip of height TH from (X, Y): icon, title (italic for a preview), dirty dot, agent mark, ×.
    #[allow(clippy::too_many_arguments)]
    fn tabs_chrome(
        &self,
        b: &mut Builder,
        strip: u64,
        x: i32,
        y: i32,
        th: i32,
        tabs: &[TabId],
        active: Option<TabId>,
    ) {
        let mut x = x + b.d(4);
        for t in tabs {
            let tab = &self.tabs[t];
            let role = if tab.preview {
                TextRole::UiItalic
            } else {
                TextRole::Ui
            };
            let w = self.tab_w(b, *t);
            let id = b.push(ChromeRole::Tab, t.0, rect(x, y, w, th), Some(strip));
            {
                let e = b.last();
                e.name = tab.title.clone();
                e.icon = tab.icon.clone();
                e.state.active = active == Some(*t);
                e.state.preview = tab.preview;
                e.state.dirty = tab.dirty;
                e.state.agent = tab.marks.iter().any(|m| m == "agent");
                e.state.changed = tab.changed;
            }
            let icon = b.d(ICON);
            let ix = x + b.d(PAD);
            b.push(
                ChromeRole::TabIcon,
                t.0,
                rect(ix, y + (th - icon) / 2, icon, icon),
                Some(id),
            );
            b.last().icon = tab.icon.clone();
            let close = b.d(CLOSE);
            let cx = x + w - b.d(PAD) - close;
            let tx = ix + icon + b.d(6);
            let mut mx = cx - b.d(2);
            if tab.marks.iter().any(|m| m == "agent") {
                mx -= b.d(6);
                b.push(
                    ChromeRole::TabAgent,
                    t.0,
                    rect(mx, y + (th - b.d(6)) / 2, b.d(6), b.d(6)),
                    Some(id),
                );
            }
            if tab.dirty {
                mx -= b.d(6);
                b.push(
                    ChromeRole::TabDirty,
                    t.0,
                    rect(mx, y + (th - b.d(6)) / 2, b.d(6), b.d(6)),
                    Some(id),
                );
            }
            b.push(
                ChromeRole::TabTitle,
                t.0,
                rect(tx, y, (mx - b.d(4) - tx).max(0), th),
                Some(id),
            );
            b.text(&tab.title, role);
            b.last().state.active = active == Some(*t);
            b.push(
                ChromeRole::TabClose,
                t.0,
                rect(cx, y + (th - close) / 2, close, close),
                Some(id),
            );
            b.last().icon = "x".into();
            x += w;
        }
    }
}

/// The element under (X, Y) in DESC: the deepest (last drawn) one whose rect holds the point, or None.
pub fn element_at(desc: &ChromeDesc, x: i32, y: i32) -> Option<&Element> {
    desc.elements.iter().rev().find(|e| {
        e.role != ChromeRole::FocusRing
            && x >= e.rect.x
            && y >= e.rect.y
            && x < e.rect.x + e.rect.w
            && y < e.rect.y + e.rect.h
    })
}
