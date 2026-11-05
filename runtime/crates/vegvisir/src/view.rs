//! A map view: its key, its state, and the operations on it.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::ItemId;

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

/// The view's filters (design §5.5).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Filters {
    /// `f`: only this item's chain.
    #[serde(default)]
    pub focus: Option<ItemId>,
    /// `o`: only agents and branches with an overlap or a clash, and what they share.
    #[serde(default)]
    pub overlaps: bool,
    /// `.`: finished items too.
    #[serde(default)]
    pub finished: bool,
}

/// What a view shows and at which width (in units of 4 px).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewState {
    pub width_units: u32,
    #[serde(default)]
    pub density: Density,
    #[serde(default)]
    pub filters: Filters,
    /// Collapsed layers, 1–6.
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
