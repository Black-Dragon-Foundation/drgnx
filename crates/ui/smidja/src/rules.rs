//! The rules the model holds (§4.5, W1–W10), as checks over a state and over one step (before → after).
//!
//! `tests/rules.rs` and `smidja-fuzz` run them after every intent of random sequences (`sim`).

use std::collections::BTreeSet;

use crate::model::{Origin, Ref, TabId, Workbench};
use crate::sim::Step;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Rule {
    W1,
    W2,
    W3,
    W4,
    W5,
    W6,
    W7,
    W8,
    W9,
    W10,
}

impl Rule {
    pub const ALL: [Rule; 10] = [
        Rule::W1,
        Rule::W2,
        Rule::W3,
        Rule::W4,
        Rule::W5,
        Rule::W6,
        Rule::W7,
        Rule::W8,
        Rule::W9,
        Rule::W10,
    ];
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuleBroken {
    pub rule: Rule,
    pub detail: String,
}

fn broken(rule: Rule, detail: String) -> Result<(), RuleBroken> {
    Err(RuleBroken { rule, detail })
}

/// Every rule that a state alone shows (W1, W3, W4, W5, W7, W8, W9, and W10's "every tab has a place").
pub fn check_rules(wb: &Workbench) -> Result<(), RuleBroken> {
    for r in [
        Rule::W1,
        Rule::W3,
        Rule::W4,
        Rule::W5,
        Rule::W7,
        Rule::W8,
        Rule::W9,
        Rule::W10,
    ] {
        check_state(r, wb)?;
    }
    Ok(())
}

/// Every rule over one step.
pub fn check_step(before: &Workbench, after: &Workbench, step: &Step) -> Result<(), RuleBroken> {
    for r in Rule::ALL {
        check_rule(r, before, after, step)?;
    }
    Ok(())
}

/// One rule over one step: its state part on `after`, its step part on the change.
pub fn check_rule(
    rule: Rule,
    before: &Workbench,
    after: &Workbench,
    step: &Step,
) -> Result<(), RuleBroken> {
    check_state(rule, after)?;
    match rule {
        Rule::W2 => w2(before, after, step),
        Rule::W6 => w6(before, after, step),
        Rule::W8 => {
            for w in &after.windows {
                if let Some(b) = before.windows.iter().find(|x| x.id == w.id)
                    && w.selection_gen < b.selection_gen
                {
                    return broken(
                        Rule::W8,
                        format!("window {} selection_gen went back", w.id.0),
                    );
                }
            }
            Ok(())
        }
        Rule::W10 => w10(before, after, step),
        _ => Ok(()),
    }
}

fn live(wb: &Workbench) -> impl Iterator<Item = &crate::model::OsWindow> {
    wb.windows.iter().filter(|w| w.parked.is_none())
}

fn check_state(rule: Rule, wb: &Workbench) -> Result<(), RuleBroken> {
    match rule {
        Rule::W1 => {
            // every tab sits in exactly one place: a center group or a bottom panel; the bottom holds only bottom
            // kinds and Output
            let mut seen = BTreeSet::new();
            for w in &wb.windows {
                for g in w.center.tree.leaves() {
                    let Some(grp) = wb.groups.get(&g) else {
                        return broken(rule, format!("group {} in the tree has no entry", g.0));
                    };
                    for t in &grp.tabs {
                        if !seen.insert(*t) {
                            return broken(rule, format!("tab {} is in two places", t.0));
                        }
                        if !wb.tabs.contains_key(t) {
                            return broken(
                                rule,
                                format!("tab {} in group {} has no entry", t.0, g.0),
                            );
                        }
                    }
                }
                for t in &w.bottom.tabs {
                    if !seen.insert(*t) {
                        return broken(rule, format!("tab {} is in two places", t.0));
                    }
                    let Some(tab) = wb.tabs.get(t) else {
                        return broken(rule, format!("bottom tab {} has no entry", t.0));
                    };
                    if !wb.kinds.is_bottom(&tab.kind) && !matches!(tab.r, Ref::Output { .. }) {
                        return broken(rule, format!("a {} tab is in the bottom panel", tab.kind));
                    }
                }
            }
            if let Some(t) = wb.tabs.keys().find(|t| !seen.contains(t)) {
                return broken(rule, format!("tab {} is in no place", t.0));
            }
            Ok(())
        }
        Rule::W3 => {
            for w in live(wb) {
                let mut kinds = BTreeSet::new();
                for g in w.center.tree.leaves() {
                    let grp = &wb.groups[&g];
                    let previews: Vec<&TabId> =
                        grp.tabs.iter().filter(|t| wb.tabs[t].preview).collect();
                    if previews.len() > 1 || previews.first().copied().copied() != grp.preview {
                        return broken(rule, format!("group {} has previews {previews:?}", g.0));
                    }
                    for t in &grp.tabs {
                        if let Ref::Page { page_kind, .. } = &wb.tabs[t].r {
                            if wb.tabs[t].preview {
                                return broken(rule, format!("page {page_kind} is a preview"));
                            }
                            if !kinds.insert(page_kind.clone()) {
                                return broken(
                                    rule,
                                    format!("page {page_kind} twice in window {}", w.id.0),
                                );
                            }
                        }
                    }
                }
            }
            Ok(())
        }
        Rule::W4 => {
            for w in live(wb) {
                let leaves = w.center.tree.leaves();
                if leaves.is_empty() {
                    return broken(rule, format!("window {} has no group", w.id.0));
                }
                if let Some(fs) = w.center.full_size
                    && !leaves.contains(&fs)
                {
                    return broken(
                        rule,
                        format!("window {}: full size names a gone group", w.id.0),
                    );
                }
                if !leaves.contains(&w.center.active_group) {
                    return broken(rule, format!("window {}: the active group is gone", w.id.0));
                }
            }
            Ok(())
        }
        Rule::W5 => {
            for w in live(wb) {
                if !wb.focus_ok(w, &w.focus) {
                    return broken(
                        rule,
                        format!(
                            "window {}: focus {:?} is not visible and live",
                            w.id.0, w.focus
                        ),
                    );
                }
            }
            Ok(())
        }
        Rule::W7 => {
            for w in live(wb) {
                let lit = wb
                    .roles(w.id)
                    .into_iter()
                    .find(|r| r.role == "button" && r.key.starts_with("place:") && r.pressed);
                let rail_shown = wb.roles(w.id).iter().any(|r| r.key == "region:rail");
                if rail_shown && lit.as_ref().map(|r| r.name.as_str()) != w.left.place.as_deref() {
                    return broken(
                        rule,
                        format!(
                            "window {}: rail {:?} ≠ left {:?}",
                            w.id.0,
                            lit.map(|r| r.name),
                            w.left.place
                        ),
                    );
                }
            }
            Ok(())
        }
        Rule::W8 => {
            for w in live(wb) {
                if let Some(s) = &w.selection
                    && s.generation != w.selection_gen
                {
                    return broken(rule, format!("window {}: two selections", w.id.0));
                }
                if wb.detail(w.id) != w.right.detail_pin.as_ref().or(w.selection.as_ref()) {
                    return broken(
                        rule,
                        format!(
                            "window {}: Detail shows neither its pin nor the selection",
                            w.id.0
                        ),
                    );
                }
            }
            Ok(())
        }
        Rule::W9 => {
            for w in live(wb) {
                let Some(r) = wb.realisation(w.id) else {
                    return broken(rule, "no realisation".to_string());
                };
                let mut seen = BTreeSet::new();
                for x in &r.regions {
                    if !seen.insert(x.region) {
                        return broken(rule, format!("region {:?} twice", x.region));
                    }
                }
                let groups = w.center.tree.leaves().len();
                if groups > wb.defaults.max_groups {
                    return broken(rule, format!("window {}: {groups} groups", w.id.0));
                }
            }
            Ok(())
        }
        Rule::W10 => {
            // every tab the model knows is shown somewhere
            let mut placed = BTreeSet::new();
            for w in &wb.windows {
                for g in w.center.tree.leaves() {
                    placed.extend(wb.groups[&g].tabs.iter().copied());
                }
                placed.extend(w.bottom.tabs.iter().copied());
            }
            if let Some(t) = wb.tabs.keys().find(|t| !placed.contains(t)) {
                return broken(
                    rule,
                    format!("tab {} ({:?}) has no place", t.0, wb.tabs[t].r),
                );
            }
            Ok(())
        }
        Rule::W2 | Rule::W6 => Ok(()),
    }
}

fn w2(before: &Workbench, after: &Workbench, step: &Step) -> Result<(), RuleBroken> {
    let user_layout = step.origin == Some(Origin::User) && step.kind.is_layout();
    for w in live(after) {
        let Some(b) = live(before).find(|x| x.id == w.id) else {
            continue;
        };
        let (nb, na) = (b.center.tree.leaves().len(), w.center.tree.leaves().len());
        if na > nb && !user_layout {
            return broken(
                Rule::W2,
                format!("window {}: {nb} → {na} groups by {:?}", w.id.0, step),
            );
        }
    }
    Ok(())
}

fn w6(before: &Workbench, after: &Workbench, step: &Step) -> Result<(), RuleBroken> {
    if step.origin != Some(Origin::Program) {
        return Ok(());
    }
    if live(before).count() != live(after).count() {
        return broken(
            Rule::W6,
            format!("a program step changed the windows: {step:?}"),
        );
    }
    for w in live(after) {
        let Some(b) = live(before).find(|x| x.id == w.id) else {
            continue;
        };
        let same = b.left.visible == w.left.visible
            && b.right.visible == w.right.visible
            && b.bottom.visible == w.bottom.visible
            && b.right.tab == w.right.tab
            && b.chrome_hidden == w.chrome_hidden
            && b.center.full_size == w.center.full_size
            && b.center.tree.leaves() == w.center.tree.leaves()
            && b.fold.overlay == w.fold.overlay
            && b.focus == w.focus;
        if !same {
            return broken(
                Rule::W6,
                format!(
                    "window {}: a program step changed what shows: {step:?}",
                    w.id.0
                ),
            );
        }
    }
    Ok(())
}

fn w10(before: &Workbench, after: &Workbench, step: &Step) -> Result<(), RuleBroken> {
    // closing a group is closing its tabs (they go to Reopen Closed Tab); every other layout step keeps them all
    if !step.kind.is_layout() || step.kind == crate::sim::Kind::CloseGroup {
        return Ok(());
    }
    let tools: BTreeSet<TabId> = before
        .groups
        .values()
        .filter_map(|g| g.temp.as_ref().map(|t| t.tab))
        .collect();
    let mut held: Vec<Ref> = after.tabs.values().map(|t| t.r.clone()).collect();
    for w in &after.windows {
        held.extend(w.closed_tabs.iter().cloned());
    }
    for (id, t) in &before.tabs {
        if tools.contains(id) || after.tabs.contains_key(id) {
            continue;
        }
        if let Ref::Buffer { id: b, .. } = &t.r
            && after.gone_buffers.contains(b)
        {
            continue;
        }
        if !held.iter().any(|r| r.same(&t.r)) {
            return broken(Rule::W10, format!("{:?} lost by {step:?}", t.r));
        }
    }
    Ok(())
}
