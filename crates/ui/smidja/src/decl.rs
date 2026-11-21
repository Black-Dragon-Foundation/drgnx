//! Declarations (§4.4): what features say instead of where, and the defaults of §4.2.
//!
//! Kinds, places and their homes are data the hub and Lisp declare; the crate names none of them.

use crate::model::{Ref, Version, Workbench};

/// One declaration. Declaring the same thing again changes nothing; a changed one replaces the old in its place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decl {
    TabKind {
        kind: String,
    },
    PageKind {
        kind: String,
        title: String,
        icon: String,
        place: Option<String>,
        selects: Option<String>,
        view: Option<String>,
    },
    /// A left place; `foot` places sit at the rail's foot, after the others.
    Place {
        place: String,
        icon: String,
        view: Option<String>,
        sections: Vec<String>,
        home: Option<String>,
        foot: bool,
    },
    SelectionKind {
        kind: String,
        detail: Option<String>,
    },
    BottomKind {
        kind: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageKind {
    pub kind: String,
    pub title: String,
    pub icon: String,
    pub place: Option<String>,
    pub selects: Option<String>,
    pub view: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Place {
    pub place: String,
    pub icon: String,
    pub view: Option<String>,
    pub sections: Vec<String>,
    pub home: Option<String>,
    pub foot: bool,
}

/// The declared kinds, in declaration order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct KindTable {
    pub tab_kinds: Vec<String>,
    pub pages: Vec<PageKind>,
    pub places: Vec<Place>,
    pub selections: Vec<(String, Option<String>)>,
    pub bottom: Vec<String>,
}

impl KindTable {
    pub fn page(&self, kind: &str) -> Option<&PageKind> {
        self.pages.iter().find(|p| p.kind == kind)
    }

    pub fn place(&self, place: &str) -> Option<&Place> {
        self.places.iter().find(|p| p.place == place)
    }

    /// The places in rail order: declaration order, the foot places last.
    pub fn rail(&self) -> Vec<&Place> {
        let mut v: Vec<&Place> = self.places.iter().filter(|p| !p.foot).collect();
        v.extend(self.places.iter().filter(|p| p.foot));
        v
    }

    /// The place a window's left starts on: the first place without a home page (layout A: Files).
    pub fn default_place(&self) -> Option<String> {
        self.rail()
            .into_iter()
            .find(|p| p.home.is_none())
            .map(|p| p.place.clone())
    }

    pub fn is_bottom(&self, kind: &str) -> bool {
        self.bottom.iter().any(|k| k == kind)
    }
}

/// Terminal sizes in columns and lines (§6.6): the builder's numbers where the spec names none.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TtyDefaults {
    pub rail: u32,
    pub left: u32,
    pub left_min: u32,
    pub left_max: u32,
    pub right: u32,
    pub right_min: u32,
    pub right_max: u32,
    pub bottom: u32,
    pub bottom_min: u32,
    pub title_row: u32,
    pub status_bar: u32,
    pub split_min_w: u32,
    pub split_min_h: u32,
}

/// §4.2's sizes (logical px) and the limits of the Global Constraints.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Defaults {
    pub title_row: u32,
    pub rail: u32,
    pub left: u32,
    pub left_min: u32,
    pub left_max: u32,
    pub right: u32,
    pub right_min: u32,
    pub right_max: u32,
    pub bottom: u32,
    pub bottom_min: u32,
    pub status_bar: u32,
    pub tab_strip: u32,
    pub breadcrumb: u32,
    pub region_header: u32,
    pub section_header: u32,
    pub folded_strip: u32,
    pub gap: u32,
    pub card_radius: u32,
    pub max_groups: usize,
    pub split_min_w: u32,
    pub split_min_h: u32,
    pub undo_cap: usize,
    pub closed_cap: usize,
    pub tty: TtyDefaults,
}

impl Default for Defaults {
    fn default() -> Self {
        Defaults {
            title_row: 38,
            rail: 44,
            left: 272,
            left_min: 200,
            left_max: 480,
            right: 392,
            right_min: 320,
            right_max: 560,
            bottom: 240,
            bottom_min: 120,
            status_bar: 24,
            tab_strip: 34,
            breadcrumb: 22,
            region_header: 34,
            section_header: 26,
            folded_strip: 44,
            gap: 6,
            card_radius: 10,
            max_groups: 8,
            split_min_w: 320,
            split_min_h: 160,
            undo_cap: 50,
            closed_cap: 20,
            tty: TtyDefaults {
                rail: 4,
                left: 24,
                left_min: 16,
                left_max: 48,
                right: 32,
                right_min: 24,
                right_max: 64,
                bottom: 10,
                bottom_min: 5,
                title_row: 1,
                status_bar: 1,
                split_min_w: 20,
                split_min_h: 5,
            },
        }
    }
}

impl Workbench {
    /// Declare a kind, place or selection kind. Returns the version, bumped only when the table changed.
    pub fn declare(&mut self, d: Decl) -> Version {
        let changed = match d {
            Decl::TabKind { kind } => push_new(&mut self.kinds.tab_kinds, kind),
            Decl::BottomKind { kind } => push_new(&mut self.kinds.bottom, kind),
            Decl::SelectionKind { kind, detail } => {
                upsert(&mut self.kinds.selections, (kind, detail), |a, b| {
                    a.0 == b.0
                })
            }
            Decl::PageKind {
                kind,
                title,
                icon,
                place,
                selects,
                view,
            } => {
                let p = PageKind {
                    kind: kind.clone(),
                    title,
                    icon,
                    place,
                    selects,
                    view,
                };
                let changed = upsert(&mut self.kinds.pages, p, |a, b| a.kind == b.kind);
                // a restored tab of this kind fills now (§4.9, cold hub)
                for t in self.tabs.values_mut() {
                    if matches!(&t.r, Ref::Page { page_kind, .. } if *page_kind == kind)
                        && (t.placeholder || t.unavailable)
                    {
                        t.placeholder = false;
                        t.unavailable = false;
                    }
                }
                changed
            }
            Decl::Place {
                place,
                icon,
                view,
                sections,
                home,
                foot,
            } => {
                let p = Place {
                    place,
                    icon,
                    view,
                    sections,
                    home,
                    foot,
                };
                upsert(&mut self.kinds.places, p, |a, b| a.place == b.place)
            }
        };
        if changed {
            // a window made before any place was declared starts on the default place now
            let dp = self.kinds.default_place();
            for w in &mut self.windows {
                if w.left.place.is_none() {
                    w.left.place = dp.clone();
                }
            }
            self.bump()
        } else {
            self.version
        }
    }

    pub fn kinds(&self) -> &KindTable {
        &self.kinds
    }

    pub fn defaults(&self) -> &Defaults {
        &self.defaults
    }
}

fn push_new(v: &mut Vec<String>, k: String) -> bool {
    if v.contains(&k) {
        false
    } else {
        v.push(k);
        true
    }
}

fn upsert<T: PartialEq>(v: &mut Vec<T>, x: T, key: impl Fn(&T, &T) -> bool) -> bool {
    match v.iter().position(|y| key(y, &x)) {
        Some(i) if v[i] == x => false,
        Some(i) => {
            v[i] = x;
            true
        }
        None => {
            v.push(x);
            true
        }
    }
}
