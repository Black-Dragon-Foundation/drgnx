//! Hit targets (design §6.4; Task 20): what a point of the chrome on screen does when clicked, and what it shows
//! hovered.  The glue asks on every pointer event over chrome, with the point in the OS window's device px (the
//! description's coordinates); no Lisp runs for it.
//!
//! A target is the element under the point, its id, a command id and the command's arguments: a tab (or any part of
//! it but its ×) → `tab-activate (TAB)`, its × → `tab-close (TAB)`, a rail item → `place-go ("PLACE")`, a right tab or
//! a folded strip's item → `right-show (TAB)`, the needs-you chips → `needs-you-show ()`, the agents chip →
//! `right-show (agents)`, the title row's search → `quick-open ()`, a strip's split → `group-split (GROUP right)`, its
//! ⋯ → `group-more (GROUP)`, Detail's pin → `detail-pin ()`, the window controls → `window-minimize`,
//! `window-maximize`, `window-close` (the glue runs those itself).  Backgrounds (the strips, cards, headers, the
//! breadcrumb) have none.

use crate::abi::{Val, with_chrome};
use crate::chrome::{ChromeDesc, ChromeRole, Element, element_at};
use crate::model::RightTab;

/// What a click on an element does: the element's role and id, the command and its arguments.
#[derive(Clone, Debug, PartialEq)]
pub struct HitTarget {
    pub element: ChromeRole,
    pub id: u64,
    pub command_id: &'static str,
    pub args: Vec<Val>,
}

/// The key an element was made with (its id less the role byte): a tab's or group's id, a place's or item's index.
pub fn element_key(id: u64) -> u64 {
    id & ((1 << 56) - 1)
}

/// The element a part belongs to for hover and clicks: a tab's icon, title and marks are the tab's.
fn owner(desc: &ChromeDesc, e: &Element) -> u64 {
    match e.role {
        ChromeRole::TabIcon
        | ChromeRole::TabTitle
        | ChromeRole::TabDirty
        | ChromeRole::TabAgent => e.parent.filter(|p| desc.get(*p).is_some()).unwrap_or(e.id),
        _ => e.id,
    }
}

fn sym(s: &str) -> Val {
    Val::Sym(s.into())
}

/// The target of the element with id ID in DESC, if it has one.
pub fn target_of(desc: &ChromeDesc, id: u64) -> Option<HitTarget> {
    let e = desc.get(id)?;
    let k = element_key(e.id);
    let int = |v: u64| Val::Int(i64::try_from(v).unwrap_or(i64::MAX));
    let right = |i: u64| {
        RightTab::ALL
            .get(usize::try_from(i).ok()?)
            .map(|t| sym(t.name()))
    };
    let (command_id, args) = match e.role {
        ChromeRole::Tab => ("tab-activate", vec![int(k)]),
        ChromeRole::TabClose => ("tab-close", vec![int(k)]),
        ChromeRole::RailItem => ("place-go", vec![Val::Str(e.name.clone())]),
        ChromeRole::RightTabItem | ChromeRole::FoldItem => ("right-show", vec![right(k)?]),
        ChromeRole::TitleAgents => ("right-show", vec![sym("agents")]),
        ChromeRole::TitleNeedsYou | ChromeRole::StatusNeedsYou => ("needs-you-show", vec![]),
        ChromeRole::TitleSearch => ("quick-open", vec![]),
        ChromeRole::StripSplit => ("group-split", vec![int(k), sym("right")]),
        ChromeRole::StripMore => ("group-more", vec![int(k)]),
        ChromeRole::DetailPin => ("detail-pin", vec![]),
        ChromeRole::WinMinimize => ("window-minimize", vec![]),
        ChromeRole::WinMaximize => ("window-maximize", vec![]),
        ChromeRole::WinClose => ("window-close", vec![]),
        _ => return None,
    };
    Some(HitTarget {
        element: e.role,
        id: e.id,
        command_id,
        args,
    })
}

/// The target under (X, Y) of DESC: the deepest element there, a tab's part counting as its tab.
pub fn target(desc: &ChromeDesc, x: i32, y: i32) -> Option<HitTarget> {
    let e = element_at(desc, x, y)?;
    target_of(desc, owner(desc, e))
}

/// The element (X, Y) hovers in DESC: the one a target belongs to (a tab for its parts), None over backgrounds.
pub fn hover(desc: &ChromeDesc, x: i32, y: i32) -> Option<u64> {
    target(desc, x, y).map(|t| t.id)
}

/// `hit(w, x, y)` on OS window W's chrome on screen (the one the glue drew last).
pub fn hit(w: u64, x: i32, y: i32) -> Option<HitTarget> {
    with_chrome(w, |d| d.and_then(|d| target(d, x, y)))
}

/// `hover(w, x, y)` on OS window W's chrome on screen.
pub fn hover_at(w: u64, x: i32, y: i32) -> Option<u64> {
    with_chrome(w, |d| d.and_then(|d| hover(d, x, y)))
}

/// Whether (X, Y) lies on W's chrome on screen (a background included): the glue takes the pointer there.  A card
/// alone is not: its island is the Emacs windows' own ground, so the pointer over it is Emacs's.
pub fn on_chrome(w: u64, x: i32, y: i32) -> bool {
    with_chrome(w, |d| {
        d.and_then(|d| element_at(d, x, y))
            .is_some_and(|e| e.role != ChromeRole::Card)
    })
}

/// An element kind's name as Lisp reads it (`nidhogg-wb-menu-items`' keys): `tab`, `tab-close`, `rail-item`, ….
pub fn kind_name(role: ChromeRole) -> String {
    let s = format!("{role:?}");
    let mut out = String::with_capacity(s.len() + 4);
    for (i, c) in s.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i > 0 {
                out.push('-');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}
