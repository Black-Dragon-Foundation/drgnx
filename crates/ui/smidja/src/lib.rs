//! Smiðja ("smithy, workshop"): drgnx's workbench model (design §4).
//!
//! One placement authority: features state intents (open, select, show context, navigate, overlays, layout) and the
//! model decides regions, groups, tabs, selection and focus; Emacs realises what it says. Pure Rust with no I/O, no
//! Emacs types and no drawing: it knows logical sizes (columns on a terminal) and decides what fits. Kinds, places and
//! pages are data the hub and Lisp declare. Persistence is text in and out; the glue reads and writes the files.
//!
//! The rules W1–W10 (§4.5) are checked by `rules`, after every intent of random sequences (`sim`).

pub mod abi;
pub mod decl;
pub mod focus;
pub mod fold;
pub mod intent;
pub mod layout;
pub mod model;
pub mod multi;
pub mod persist;
pub mod preset;
pub mod query;
pub mod realise;
pub mod rules;
pub mod sim;
pub mod temp;

pub use decl::{Decl, Defaults, KindTable, PageKind, Place};
pub use focus::{BottomRef, Dir, FocusTarget, Vis};
pub use fold::{FOLD_CELLS, FOLD_PX, FoldTable};
pub use intent::{Allowed, How, Intent, OpenOpts, TabFields, Target, allowed};
pub use layout::{Dir4, LayoutSnapshot, MoveTarget, Side};
pub use model::{
    Attention, Axis, EdgeKey, Focus, Fold, Group, GroupId, Node, Origin, OsWindow, Overlay,
    OverlayId, OverlayKind, PlaceState, Rect, Ref, Refusal, Region, RightTab, Selection, SideFold,
    Source, Tab, TabId, TempLayout, Version, WinId, WinSize, Workbench,
};
pub use multi::TearOut;
pub use persist::{Pending, Resolved, load};
pub use preset::{CenterSpec, Preset, SideSpec};
pub use query::{Role, Snapshot, Token};
pub use realise::{GroupReal, Realisation, RegionReal};
pub use rules::{Rule, RuleBroken, check_rule, check_rules, check_step};
