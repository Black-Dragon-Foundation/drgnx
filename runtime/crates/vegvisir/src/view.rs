//! A map view: its key, its state, and the operations on it.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::{Item, ItemId, Kind};

/// One map view of one editor connection: the hub keeps state per (connection, view).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ViewKey {
    pub conn: u64,
    pub view: String,
}

/// The look's density (§3.2 there): card sizes, gaps and bands follow it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Density {
    Compact,
    #[default]
    Comfortable,
    Roomy,
}

/// Which items the map shows (`.` cycles Active, Completed, All).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Show {
    /// Agents running or waiting on you, what is not started yet, and anything touched within `recent_days`.
    #[default]
    Active,
    /// Finished items only.
    Completed,
    /// Both, the finished ones faded.
    All,
}

/// How a view draws an item.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Visibility {
    Hidden,
    Normal,
    Faded,
}

/// Where an Active row sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Group {
    InProgress,
    Ready,
}

/// Days an item stays in Active after its last change, by default.
pub const RECENT_DAYS: u32 = 7;

fn recent_days() -> u32 {
    RECENT_DAYS
}

/// The view's filters (design §5.5).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Filters {
    /// `f`: only this item's chain.
    #[serde(default)]
    pub focus: Option<ItemId>,
    /// `o`: only agents and branches with an overlap or a clash, and what they share.
    #[serde(default)]
    pub overlaps: bool,
    /// `.`: Active, Completed or All.
    #[serde(default)]
    pub show: Show,
    /// How long after its last change an item stays in Active.
    #[serde(default = "recent_days")]
    pub recent_days: u32,
}

impl Default for Filters {
    fn default() -> Filters {
        Filters {
            focus: None,
            overlaps: false,
            show: Show::default(),
            recent_days: RECENT_DAYS,
        }
    }
}

/// What the filter makes of an item with these fields at minute NOW.
pub(crate) fn visibility(
    kind: Kind,
    live: bool,
    done: bool,
    ready: bool,
    touched: u64,
    f: &Filters,
    now: u64,
) -> Visibility {
    match f.show {
        Show::Completed => {
            if done && kind != Kind::Machine {
                Visibility::Normal
            } else {
                Visibility::Hidden
            }
        }
        Show::All => {
            if done {
                Visibility::Faded
            } else {
                Visibility::Normal
            }
        }
        Show::Active => {
            let window = u64::from(f.recent_days) * 24 * 60;
            let recent = touched > 0 && now.saturating_sub(touched) <= window;
            if live || ready || recent || kind == Kind::Machine {
                Visibility::Normal
            } else {
                Visibility::Hidden
            }
        }
    }
}

/// How the filter F shows item IT at minute NOW (the clock's minute).
pub fn shown(it: &Item, f: &Filters, now: u64) -> Visibility {
    visibility(it.kind, it.live, it.done, it.ready, it.touched, f, now)
}

/// The group of IT in Active: in progress (a live agent under it, or it needs you), else ready. `None` outside
/// Active and for what is hidden.
pub fn group(it: &Item, f: &Filters, now: u64) -> Option<Group> {
    if f.show != Show::Active || shown(it, f, now) == Visibility::Hidden {
        return None;
    }
    Some(if it.live || it.needs_you {
        Group::InProgress
    } else {
        Group::Ready
    })
}

/// What a view shows and at which width (in units of 4 px).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewState {
    pub width_units: u32,
    #[serde(default)]
    pub density: Density,
    #[serde(default)]
    pub filters: Filters,
    /// Collapsed layers, 1–8.
    #[serde(default)]
    pub collapsed: BTreeSet<u8>,
}

/// A view opened, changed, shown, hidden or closed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum ViewOp {
    Open {
        view: ViewKey,
        state: ViewState,
        shown: bool,
    },
    Set {
        view: ViewKey,
        state: ViewState,
    },
    Shown {
        view: ViewKey,
        shown: bool,
    },
    Close {
        view: ViewKey,
    },
}
