//! Read access (§4.3 "Feeding and queries"): typed queries for Rust callers and tests, the same as flat tokens for
//! the door, the roles tree [D8], and the whole state as a snapshot.

use crate::model::{
    Focus, Group, GroupId, OverlayKind, Ref, Refusal, Region, RightTab, Selection, SideFold, Tab,
    TabId, WinId, Workbench, refuse,
};

/// A flat token: lists are bracketed by `Open` and `Close`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Token {
    Int(i64),
    Str(String),
    Sym(String),
    Open,
    Close,
}

/// An accessibility role [D8]: `region`, `tablist`, `tab`, `button` or `status`, named, keyed stably by id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Role {
    pub depth: u8,
    pub role: &'static str,
    pub name: String,
    pub key: String,
    pub pressed: bool,
}

/// The whole model as data (tests and persistence round trips).
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot(Box<Workbench>);

fn sym(s: &str) -> Token {
    Token::Sym(s.to_string())
}

fn focus_tokens(f: &Focus, out: &mut Vec<Token>) {
    match f {
        Focus::Left => out.push(sym("left")),
        Focus::Right => out.push(sym("right")),
        Focus::Bottom => out.push(sym("bottom")),
        Focus::Center(g) => {
            out.push(sym("center"));
            out.push(Token::Int(g.0 as i64));
        }
        Focus::Overlay(id, r) => {
            out.push(sym("overlay"));
            out.push(Token::Int(id.0 as i64));
            focus_tokens(r, out);
        }
    }
}

impl Workbench {
    pub fn tab(&self, t: TabId) -> Option<&Tab> {
        self.tabs.get(&t)
    }

    pub fn group(&self, g: GroupId) -> Option<&Group> {
        self.groups.get(&g)
    }

    /// A window's groups in reading order.
    pub fn groups(&self, w: WinId) -> Vec<GroupId> {
        self.window(w)
            .map(|x| self.groups_of(x))
            .unwrap_or_default()
    }

    pub fn tabs_of(&self, g: GroupId) -> Vec<TabId> {
        self.groups
            .get(&g)
            .map(|x| x.tabs.clone())
            .unwrap_or_default()
    }

    pub fn active_group(&self, w: WinId) -> Option<GroupId> {
        self.window(w).map(|x| x.center.active_group)
    }

    /// The active tab of the window's active group.
    pub fn active_tab(&self, w: WinId) -> Option<TabId> {
        self.groups.get(&self.active_group(w)?)?.active
    }

    pub fn selection(&self, w: WinId) -> Option<&Selection> {
        self.window(w)?.selection.as_ref()
    }

    pub fn version(&self) -> crate::model::Version {
        self.version
    }

    /// The place the rail lights: the left's place (W7).
    pub fn rail_lit(&self, w: WinId) -> Option<&str> {
        self.window(w)?.left.place.as_deref()
    }

    /// The roles tree of a window, depth-first.
    pub fn roles(&self, w: WinId) -> Vec<Role> {
        let Some(win) = self.window(w) else {
            return Vec::new();
        };
        let mut v = Vec::new();
        let role = |depth, role, name: &str, key: String, pressed| Role {
            depth,
            role,
            name: name.to_string(),
            key,
            pressed,
        };
        let rr = self.realisation(w);
        let shown = |r: Region| {
            rr.as_ref().is_some_and(|x| {
                x.regions
                    .iter()
                    .any(|y| y.region == r && (y.visible || y.folded))
            })
        };
        if shown(Region::Rail) {
            v.push(role(0, "region", "Rail", "region:rail".into(), false));
            let lit = self.rail_lit(w);
            for p in self.kinds.rail() {
                v.push(role(
                    1,
                    "button",
                    &p.place,
                    format!("place:{}", p.place),
                    lit == Some(p.place.as_str()),
                ));
            }
        }
        if shown(Region::Left) {
            v.push(role(
                0,
                "region",
                win.left.place.as_deref().unwrap_or("Left"),
                "region:left".into(),
                false,
            ));
        }
        v.push(role(0, "region", "Center", "region:center".into(), false));
        let groups = match win.center.full_size {
            Some(fs) => vec![fs],
            None => win.center.tree.leaves(),
        };
        for g in groups {
            let grp = &self.groups[&g];
            let name = grp.active.map_or("Start", |t| self.tabs[&t].title.as_str());
            v.push(role(1, "tablist", name, format!("group:{}", g.0), false));
            for t in &grp.tabs {
                v.push(role(
                    2,
                    "tab",
                    &self.tabs[t].title,
                    format!("tab:{}", t.0),
                    grp.active == Some(*t),
                ));
            }
        }
        if win.right.visible {
            v.push(role(0, "region", "Right", "region:right".into(), false));
            for t in RightTab::ALL {
                v.push(role(
                    1,
                    "button",
                    t.name(),
                    format!("right:{}", t.name()),
                    win.right.tab == t,
                ));
            }
        }
        if win.bottom.visible {
            v.push(role(0, "region", "Bottom", "region:bottom".into(), false));
            v.push(role(1, "tablist", "Panel", "bottom".into(), false));
            for t in &win.bottom.tabs {
                v.push(role(
                    2,
                    "tab",
                    &self.tabs[t].title,
                    format!("tab:{}", t.0),
                    win.bottom.active == Some(*t),
                ));
            }
        }
        if !win.chrome_hidden {
            v.push(role(0, "status", "Status bar", "status".into(), false));
        }
        v
    }

    /// Read a path as tokens: `active-tab`, `selection`, `focus`, `fold`, `tabs`, `groups`, `attention`, `roles`,
    /// `detail`, `places`, `sections` (the left's; [`Workbench::sections`] for a region).
    pub fn query(&self, w: WinId, path: &str) -> Result<Vec<Token>, Refusal> {
        let Some(win) = self.window(w) else {
            return refuse("no such OS window");
        };
        let mut out = Vec::new();
        let sel = |s: Option<&Selection>, out: &mut Vec<Token>| match s {
            Some(s) => {
                out.push(Token::Str(s.kind.clone()));
                out.push(Token::Str(s.id.clone()));
                out.push(Token::Int(s.generation as i64));
            }
            None => out.push(sym("nil")),
        };
        match path {
            "active-tab" => out.push(
                self.active_tab(w)
                    .map_or(sym("nil"), |t| Token::Int(t.0 as i64)),
            ),
            "selection" => sel(win.selection.as_ref(), &mut out),
            "detail" => sel(self.detail(w), &mut out),
            "focus" => focus_tokens(&win.focus, &mut out),
            "fold" => {
                let f = |x: SideFold| {
                    sym(if x == SideFold::Open {
                        "open"
                    } else {
                        "folded"
                    })
                };
                out.push(f(win.fold.left));
                out.push(f(win.fold.right));
                out.push(sym(match win.fold.overlay {
                    Some(Region::Left) => "left",
                    Some(Region::Right) => "right",
                    _ => "none",
                }));
            }
            "tabs" => {
                for t in self.center_tabs(self.wi(w)?) {
                    let tab = &self.tabs[&t];
                    out.push(Token::Open);
                    out.push(Token::Int(t.0 as i64));
                    out.push(Token::Str(tab.kind.clone()));
                    out.push(Token::Str(tab.title.clone()));
                    out.push(sym(if tab.preview { "preview" } else { "pinned" }));
                    out.push(Token::Close);
                }
            }
            "groups" => {
                for g in win.center.tree.leaves() {
                    let grp = &self.groups[&g];
                    out.push(Token::Open);
                    out.push(Token::Int(g.0 as i64));
                    out.push(grp.active.map_or(sym("nil"), |t| Token::Int(t.0 as i64)));
                    out.push(Token::Int(grp.tabs.len() as i64));
                    out.push(Token::Close);
                }
            }
            "attention" => {
                out.push(Token::Int(self.attention.count as i64));
                for (k, n) in &self.attention.by_kind {
                    out.push(Token::Str(k.clone()));
                    out.push(Token::Int(*n as i64));
                }
            }
            "roles" => {
                for r in self.roles(w) {
                    out.push(Token::Open);
                    out.push(Token::Int(i64::from(r.depth)));
                    out.push(sym(r.role));
                    out.push(Token::Str(r.name));
                    out.push(Token::Str(r.key));
                    out.push(Token::Close);
                }
            }
            "places" => {
                for p in self.kinds.rail() {
                    out.push(Token::Str(p.place.clone()));
                }
            }
            "sections" => return self.sections(w, Region::Left),
            _ => return refuse(format!("no query path {path}")),
        }
        Ok(out)
    }

    /// A region's sections as tokens: one list `(PLACE (ID TITLE SIZE) ...)` for the region's current place, `nil`
    /// when it shows none. ID is the section's index (`set_edges`' `(section ID)`), SIZE its requested height. Only
    /// the left has places; the answer is one list, so a lone section still comes back as a list of one row.
    pub fn sections(&self, w: WinId, region: Region) -> Result<Vec<Token>, Refusal> {
        let wi = self.wi(w)?;
        let place = match region {
            Region::Left => self.windows[wi].left.place.clone(),
            _ => None,
        };
        let Some(place) = place else {
            return Ok(vec![sym("nil")]);
        };
        let names = self
            .kinds
            .places
            .iter()
            .find(|p| p.place == place)
            .map(|p| p.sections.clone())
            .unwrap_or_default();
        let mut out = vec![Token::Open, Token::Str(place)];
        for (i, name) in names.into_iter().enumerate() {
            let h = self.section_rect(wi, i as u32).map_or(0, |r| r.h);
            out.extend([
                Token::Open,
                Token::Int(i as i64),
                Token::Str(name),
                Token::Int(i64::from(h)),
                Token::Close,
            ]);
        }
        out.push(Token::Close);
        Ok(out)
    }

    /// Whether a side is shown as an overlay (the folded side asked for).
    pub fn side_overlay(&self, w: WinId) -> Option<Region> {
        let win = self.window(w)?;
        win.overlays
            .iter()
            .any(|o| o.kind == OverlayKind::Side)
            .then_some(())?;
        win.fold.overlay
    }

    /// Refs a program display could only mark in this window.
    pub fn program_marks(&self, w: WinId) -> Vec<Ref> {
        self.window(w)
            .map(|x| x.program_marks.clone())
            .unwrap_or_default()
    }

    pub fn output_count(&self, w: WinId, channel: &str) -> u64 {
        self.window(w)
            .and_then(|x| x.output_counts.get(channel).copied())
            .unwrap_or(0)
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot(Box::new(self.clone()))
    }

    pub fn restore(&mut self, s: Snapshot) {
        *self = *s.0;
    }
}
