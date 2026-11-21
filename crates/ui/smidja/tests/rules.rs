//! Task 13: the rules W1–W10 (§4.5) after every intent of random sequences, with deterministic seeds.
//!
//! The sim steps both origins over 1–3 OS windows, widths 400–3840, and TTY windows; each test also starts from a
//! TTY at 80×24 and at 120×40. `smidja-fuzz` runs the same checks for a given time.
mod fixture;
use fixture::*;
use smidja::sim::{run, start};
use smidja::*;

const SEEDS: u64 = 120;
const STEPS: usize = 250;

/// The starting states: layout A at 1920×1080, plus a TTY window at 80×24 and at 120×40.
fn starts() -> Vec<Workbench> {
    let d = decls();
    let mut v = vec![start(&d)];
    for (cols, lines) in [(80, 24), (120, 40)] {
        let mut wb = start(&d);
        wb.window_new("tty", WinSize::Cells { cols, lines }, 1.0, true);
        v.push(wb);
    }
    v
}

fn holds(rule: Rule) {
    for (i, wb) in starts().into_iter().enumerate() {
        check_rules(&wb).unwrap();
        for seed in 0..SEEDS {
            let r = run(wb.clone(), seed * 7 + i as u64, STEPS, |b, a, s| {
                check_rule(rule, b, a, s)
            });
            if let Err((n, step, broken)) = r {
                panic!(
                    "start {i} seed {seed} step {n} {step:?}: {:?} {}",
                    broken.rule, broken.detail
                );
            }
        }
    }
}

#[test]
fn w1_only_center_holds_user_tabs() {
    holds(Rule::W1);
}

#[test]
fn w2_only_user_layout_splits() {
    holds(Rule::W2);
}

#[test]
fn w3_preview_and_page_limits() {
    holds(Rule::W3);
}

#[test]
fn w4_last_group_stays() {
    holds(Rule::W4);
}

#[test]
fn w5_focus_is_visible_and_live() {
    holds(Rule::W5);
}

#[test]
fn w6_program_never_changes_visibility_or_right_tab() {
    holds(Rule::W6);
}

#[test]
fn w7_rail_equals_left() {
    holds(Rule::W7);
}

#[test]
fn w8_one_selection_per_window() {
    holds(Rule::W8);
}

#[test]
fn w9_no_other_region() {
    holds(Rule::W9);
}

#[test]
fn w10_no_tab_lost_by_layout() {
    holds(Rule::W10);
}
