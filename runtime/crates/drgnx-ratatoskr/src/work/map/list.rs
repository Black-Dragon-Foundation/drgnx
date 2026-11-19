//! List mode's rows on the kit (`docs/develop/work-space.md`, the Work map's List): one row for each entry of
//! `vegvisir::list::entries`, built from the kit's pieces. The left part is the tree row (its indent and twisty, a
//! task's state dot) and the title; the right part (progress, chips, the state's word, the agent's mark, the machine)
//! starts at a stop, so the hub's fit cuts the title with an ellipsis there and the pieces stay whole. The Active
//! groups have section headers; a row on the selected chain has a gutter edge.

use std::collections::BTreeSet;

use drgnx_rows::faces::FaceId;
use drgnx_rows::fit::Measure;
use drgnx_rows::kit::{self, ChipFill, Comp, KitEnv, ProgressKind, RowKind, Status, Tone};
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::view::ViewEnv;
use serde_json::Value;
use vegvisir::list::{COMPLETED_MORE, ListChip, ListEntry};
use vegvisir::{Group, ItemId, Kind, Model, TaskState, Visibility};

use crate::view::kit_env;
use crate::work::trail::flow::row_px;

/// The progress bar's width, logical px (the mockup's `.prog`).
const BAR_PX: u16 = 46;
/// Room kept at the right edge, logical px: the window's fringe and its truncation glyph are not drawn on.
const EDGE_PX: f32 = 28.0;
/// The gutter edge's width, logical px.
const GUTTER_PX: f32 = 3.0;

/// Logical px as device px, half up (as `drgnx-px` rounds).
fn px(v: f32, scale: f32) -> u32 {
    (f64::from(v) * f64::from(scale) + 0.5 + 1e-9).floor() as u32
}

/// A gap of about V logical px in B: spaces (a 4 px space is the least the fonts draw), one on a terminal.
fn gap(b: &mut RowBuilder, kit: &KitEnv, v: f32) {
    let n = if kit.tty {
        1
    } else {
        (v / 4.0).round().max(1.0) as usize
    };
    b.push(&" ".repeat(n), None);
}

fn status_of(s: TaskState) -> Status {
    match s {
        TaskState::Done => Status::Done,
        TaskState::Running => Status::Running,
        TaskState::NeedsYou => Status::NeedsYou,
        TaskState::NotStarted => Status::Idle,
    }
}

fn group_title(g: Group) -> &'static str {
    match g {
        Group::InProgress => "In progress",
        Group::Ready => "Ready",
    }
}

/// The rows of ENTRIES for the map M, SELECTED drawn as selected, in ENV's class, measured by FONTS.
pub(crate) fn rows(
    m: &Model,
    entries: &[ListEntry],
    selected: Option<&ItemId>,
    env: &ViewEnv,
    fonts: &dyn Measure,
) -> Vec<Row> {
    if entries.is_empty() {
        // a workspace with nothing in it says so (the graph's layers have their labels; a list has no rows to show)
        let mut b = RowBuilder::new("empty:list");
        b.push(
            "  Nothing here yet: an agent, a spec or a plan puts something on the map",
            None,
        );
        let end = b.pos();
        b.face(0, end, FaceId::KitEmptyState.name());
        return vec![b.finish()];
    }
    let kit = kit_env(env);
    let on_chain: BTreeSet<usize> = selected
        .map(|s| vegvisir::list::chain_gutter(entries, m, s))
        .unwrap_or_default()
        .into_iter()
        .flat_map(|(a, b)| [a, b])
        .collect();
    let agents: Vec<ItemId> = m
        .items()
        .into_values()
        .filter(|it| it.kind == Kind::Agent)
        .map(|it| it.id)
        .collect();
    let slot = |a: &ItemId| -> u8 {
        let n = agents.iter().position(|x| x == a).unwrap_or(0);
        u8::try_from(n % 12).unwrap_or(0) + 1
    };
    let mut out = Vec::new();
    let mut section: Option<Group> = None;
    for (n, e) in entries.iter().enumerate() {
        if e.depth == 0
            && let Some(g) = e.group
            && section != Some(g)
        {
            section = Some(g);
            let specs = entries
                .iter()
                .filter(|x| x.depth == 0 && x.group == Some(g))
                .count();
            out.push(header(
                format!("list:grp:{n}"),
                group_title(g),
                u32::try_from(specs).ok(),
                &kit,
            ));
        }
        if e.item.0 == COMPLETED_MORE {
            let mut r = header(format!("list:{n}"), "Completed", e.count, &kit);
            let end = u32::try_from(r.text.chars().count()).unwrap_or(u32::MAX);
            r.props.push((
                0,
                end,
                "drgnx-work-id".into(),
                Value::String(e.item.0.clone()),
            ));
            out.push(r);
            continue;
        }
        let draw_right = |b: &mut RowBuilder| right(b, m, e, &kit, &slot);
        let rw = {
            let mut scratch = RowBuilder::new("measure");
            draw_right(&mut scratch);
            row_px(fonts, &scratch.finish())
        };
        let mut b = RowBuilder::new(format!("list:{n}"));
        let start = b.pos();
        // the gutter edge: a strip in the quiet selection colour for a row on the selected chain, its room for the others
        if !kit.tty {
            let chain = on_chain.contains(&n) || selected == Some(&e.item);
            b.pad(
                px(GUTTER_PX, kit.scale),
                chain.then(|| FaceId::SelectedQuiet.name()),
            );
        }
        let label_at = left(&mut b, e, &kit);
        let label_end = b.pos();
        b.prop(
            label_at,
            label_end,
            "help-echo",
            Value::String(e.label.clone()),
        );
        let done = e
            .chips
            .iter()
            .any(|c| matches!(c, ListChip::State(TaskState::Done)));
        let dim = if e.visibility == Visibility::Faded {
            Some(FaceId::WorkDim)
        } else if done {
            Some(FaceId::TextMuted)
        } else {
            None
        };
        if let Some(f) = dim {
            b.face(label_at, label_end, f.name());
        }
        if rw > 0 {
            if kit.tty {
                b.push("  ", None);
            } else {
                let width = env.width_px;
                let stop = width
                    .saturating_sub(rw + px(EDGE_PX, kit.scale))
                    .max(width * 2 / 5);
                b.stop(stop);
            }
            draw_right(&mut b);
        }
        let end = b.pos();
        if selected == Some(&e.item) {
            b.face(start, end, FaceId::Selected.name());
        }
        b.prop(start, end, "drgnx-work-id", Value::String(e.item.0.clone()));
        out.push(b.finish());
    }
    out
}

/// A section header row.
fn header(key: String, title: &str, count: Option<u32>, kit: &KitEnv) -> Row {
    let mut b = RowBuilder::new(key);
    kit::expand(
        &mut b,
        kit,
        &Comp::SectionHeader {
            title: title.to_owned(),
            collapsible: false,
            collapsed: false,
            count,
            state: kit::State::Rest,
            action: None,
        },
    );
    b.finish()
}

/// The left part of E's row in B: its indent, twisty and state dot, then the title. Returns where the title starts.
fn left(b: &mut RowBuilder, e: &ListEntry, kit: &KitEnv) -> u32 {
    let state = e.chips.iter().find_map(|c| match c {
        ListChip::State(s) => Some(*s),
        _ => None,
    });
    kit::expand(
        b,
        kit,
        &Comp::Row {
            kind: RowKind::Tree,
            depth: u16::from(e.depth),
            // a task has no twisty: its dot comes after the indent
            twisty: state.is_none().then_some(!e.collapsed),
            text: String::new(),
            state: kit::State::Rest,
            icon: None,
            action: None,
        },
    );
    if let Some(s) = state {
        kit::expand(
            b,
            kit,
            &Comp::StatusDot {
                status: status_of(s),
                word: false,
            },
        );
        gap(b, kit, 6.0);
    }
    let at = b.pos();
    b.push(&e.label, None);
    at
}

/// The right part of E's row in B, each piece after a gap.
fn right(b: &mut RowBuilder, m: &Model, e: &ListEntry, kit: &KitEnv, slot: &dyn Fn(&ItemId) -> u8) {
    let chip = |b: &mut RowBuilder, label: String| {
        kit::expand(
            b,
            kit,
            &Comp::Chip {
                label,
                tone: Tone::Neutral,
                fill: ChipFill::Soft,
                icon: None,
                state: kit::State::Rest,
                action: None,
            },
        );
    };
    let mut first = true;
    let mut sep = |b: &mut RowBuilder| {
        if !std::mem::take(&mut first) {
            gap(b, kit, 8.0);
        }
    };
    let muted = FaceId::TextMuted.name();
    for c in &e.chips {
        match c {
            ListChip::Progress(d, t) => {
                sep(b);
                kit::expand(
                    b,
                    kit,
                    &Comp::Progress {
                        kind: ProgressKind::Bar,
                        value: if *t == 0 {
                            0.0
                        } else {
                            f64::from((*d).min(*t)) / f64::from(*t)
                        },
                        width: if kit.tty { 40 } else { BAR_PX },
                    },
                );
                gap(b, kit, 6.0);
                b.push(&format!("{d}/{t}"), Some(muted));
            }
            ListChip::Files(f, l) => {
                sep(b);
                chip(b, format!("{f} files {l} lines"));
            }
            ListChip::Branch(x) => {
                sep(b);
                chip(b, x.clone());
            }
            ListChip::Meter(bm) => {
                sep(b);
                chip(b, vegvisir::render::meter_text(bm));
            }
            ListChip::State(s) => {
                // a terminal's state dot has its word already
                if !kit.tty {
                    sep(b);
                    b.push(s.word(), Some(FaceId::TextSubtle.name()));
                }
            }
        }
    }
    if let Some(a) = &e.agent {
        sep(b);
        let label = m.item(a).map_or_else(|| a.0.clone(), |it| it.label);
        let handle: String = label.chars().take(1).flat_map(char::to_uppercase).collect();
        kit::expand(
            b,
            kit,
            &Comp::AgentMark {
                slot: slot(a),
                handle,
            },
        );
        gap(b, kit, 5.0);
        b.push(&label, Some(muted));
    }
    if let Some(mach) = &e.machine {
        sep(b);
        b.push(mach, Some(FaceId::TextSubtle.name()));
    }
}
