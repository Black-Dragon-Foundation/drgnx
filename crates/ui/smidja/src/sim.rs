//! Random intent sequences for the rules' property tests and `smidja-fuzz`: a seeded generator that drives every
//! intent with both origins, 1–3 OS windows, widths 400–3840 px and terminal frames of 80×24 and 120×40. It names
//! nothing itself: places, pages and bottom kinds come from what was declared.

use crate::focus::{BottomRef, Dir, FocusTarget, Vis};
use crate::intent::{How, OpenOpts, TabFields, Target};
use crate::layout::{Dir4, MoveTarget, Side};
use crate::model::{
    GroupId, Origin, OverlayKind, Ref, Region, Source, TabId, WinId, WinSize, Workbench,
};
use crate::multi::TearOut;
use crate::rules::RuleBroken;

/// xorshift64*: small, seeded, the same on every target.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// 0..n (0 when n is 0).
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next_u64() % n as u64) as usize
        }
    }

    pub fn pick<T: Clone>(&mut self, v: &[T]) -> Option<T> {
        if v.is_empty() {
            None
        } else {
            Some(v[self.below(v.len())].clone())
        }
    }
}

/// What a step did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Open,
    Pin,
    Close,
    ReopenClosed,
    Select,
    PinDetail,
    ShowContext,
    Navigate,
    Focus,
    Cycle,
    Side,
    Resize,
    Bottom,
    Overlay,
    Dismiss,
    Split,
    MoveTab,
    Swap,
    Stack,
    FocusDir,
    FullSize,
    ResizeSplit,
    CloseGroup,
    RestorePrevious,
    Preset,
    NextLayout,
    TearOut,
    WindowNew,
    SetWindowSize,
    SetMonitors,
    BeginTemp,
    EndTemp,
    UpdateTab,
    SetAttention,
    BufferGone,
}

impl Kind {
    /// The center layout intents (and the monitor fold-in), which W2 and W10 watch.
    pub fn is_layout(self) -> bool {
        matches!(
            self,
            Kind::Split
                | Kind::MoveTab
                | Kind::Swap
                | Kind::Stack
                | Kind::FullSize
                | Kind::ResizeSplit
                | Kind::CloseGroup
                | Kind::RestorePrevious
                | Kind::Preset
                | Kind::NextLayout
                | Kind::TearOut
                | Kind::SetMonitors
                | Kind::Side
                | Kind::Resize
                | Kind::SetWindowSize
        )
    }
}

/// One step: its kind, its origin (None: feeding, not an intent), and whether the model carried it out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Step {
    pub kind: Kind,
    pub origin: Option<Origin>,
    pub ok: bool,
}

const MONITORS: [&str; 2] = ["m0", "m1"];

fn rand_ref(wb: &Workbench, rng: &mut Rng) -> Ref {
    match rng.below(6) {
        0 | 1 => Ref::File {
            path: format!("/p/f{}.txt", rng.below(8)),
            at: None,
        },
        2 => {
            let n = rng.below(5);
            Ref::Buffer {
                id: format!("b{n}"),
                name: format!("*buf {n}*"),
            }
        }
        3 => {
            let kinds: Vec<String> = wb.kinds.pages.iter().map(|p| p.kind.clone()).collect();
            Ref::Page {
                page_kind: rng.pick(&kinds).unwrap_or_else(|| "none".to_string()),
                key: None,
            }
        }
        4 => Ref::Session {
            id: format!("s{}", rng.below(3)),
        },
        _ => Ref::Output {
            channel: format!("c{}", rng.below(3)),
        },
    }
}

fn rand_size(rng: &mut Rng, tty: bool) -> WinSize {
    if tty {
        if rng.below(2) == 0 {
            WinSize::Cells {
                cols: 80,
                lines: 24,
            }
        } else {
            WinSize::Cells {
                cols: 120,
                lines: 40,
            }
        }
    } else {
        WinSize::Px {
            w: 400 + rng.below(3441) as u32,
            h: 300 + rng.below(1900) as u32,
        }
    }
}

fn some_tab(wb: &Workbench, rng: &mut Rng) -> TabId {
    let ts: Vec<TabId> = wb.tabs.keys().copied().collect();
    if rng.below(20) == 0 {
        TabId(999_999)
    } else {
        rng.pick(&ts).unwrap_or(TabId(999_999))
    }
}

fn some_group(wb: &Workbench, w: WinId, rng: &mut Rng) -> GroupId {
    rng.pick(&wb.groups(w)).unwrap_or(GroupId(999_999))
}

fn dir4(rng: &mut Rng) -> Dir4 {
    [Dir4::Left, Dir4::Right, Dir4::Up, Dir4::Down][rng.below(4)]
}

fn vis(rng: &mut Rng) -> Vis {
    [Vis::Show, Vis::Hide, Vis::Toggle][rng.below(3)]
}

/// A fresh workbench for a run: the declarations given, one graphical window 1920×1080 on monitor m0.
pub fn start(decls: &[crate::decl::Decl]) -> Workbench {
    let mut wb = Workbench::new();
    for d in decls {
        wb.declare(d.clone());
    }
    wb.set_monitors(MONITORS.iter().map(|m| m.to_string()).collect());
    wb.window_new("m0", WinSize::Px { w: 1920, h: 1080 }, 1.0, false);
    wb
}

/// Do one random step.
pub fn step(wb: &mut Workbench, rng: &mut Rng) -> Step {
    let wins = wb.windows();
    let w = rng.pick(&wins).expect("a window is always there");
    let origin = if rng.below(4) == 0 {
        Origin::Program
    } else {
        Origin::User
    };
    let o = Some(origin);
    let (kind, origin, ok) = match rng.below(36) {
        0..=4 => {
            let r = rand_ref(wb, rng);
            let how = [How::Preview, How::Pin, How::Reveal][rng.below(3)];
            let opts = OpenOpts {
                group: (rng.below(4) == 0).then(|| some_group(wb, w, rng)),
                debug_stop: rng.below(6) == 0,
                kind: (rng.below(8) == 0).then(|| "terminal".to_string()),
                ..OpenOpts::default()
            };
            (Kind::Open, o, wb.open(w, r, how, opts, origin).is_ok())
        }
        5 => (Kind::Pin, o, wb.pin(some_tab(wb, rng), origin).is_ok()),
        6 | 7 => (Kind::Close, o, wb.close(some_tab(wb, rng), origin).is_ok()),
        8 => (Kind::ReopenClosed, o, wb.reopen_closed(w, origin).is_ok()),
        9 => {
            let g = some_group(wb, w, rng);
            let src = match rng.below(4) {
                0 => Source::Left,
                1 => Source::Center(g, some_tab(wb, rng)),
                2 => Source::Right(crate::model::RightTab::Agents),
                _ => Source::Bottom,
            };
            let id = format!("i{}", rng.below(5));
            (
                Kind::Select,
                o,
                wb.select(w, "file", &id, src, origin).is_ok(),
            )
        }
        10 => {
            let pin = (rng.below(2) == 0)
                .then(|| wb.selection(w).cloned())
                .flatten();
            (Kind::PinDetail, o, wb.pin_detail(w, pin, origin).is_ok())
        }
        11 => {
            let t = match rng.below(5) {
                0 => Target::Detail,
                1 => Target::Agents,
                2 => Target::AgentsSession("s1".into()),
                3 => Target::Inbox(None),
                _ => Target::PullRequests(Some("7".into())),
            };
            (
                Kind::ShowContext,
                o,
                wb.show_context(w, t, rng.below(2) == 0, origin).is_ok(),
            )
        }
        12 | 13 => {
            let places: Vec<String> = wb.kinds.places.iter().map(|p| p.place.clone()).collect();
            let p = rng.pick(&places).unwrap_or_default();
            (Kind::Navigate, o, wb.navigate(w, &p, origin).is_ok())
        }
        14 => {
            let t = match rng.below(4) {
                0 => FocusTarget::Region(
                    [
                        Region::Rail,
                        Region::Left,
                        Region::Center,
                        Region::Right,
                        Region::Bottom,
                    ][rng.below(5)],
                ),
                1 => FocusTarget::Group(some_group(wb, w, rng)),
                _ => FocusTarget::Tab(some_tab(wb, rng)),
            };
            (Kind::Focus, o, wb.focus(w, t, origin).is_ok())
        }
        15 => {
            let d = if rng.below(2) == 0 {
                Dir::Next
            } else {
                Dir::Prev
            };
            (Kind::Cycle, o, wb.cycle_region(w, d, origin).is_ok())
        }
        16 => {
            let r = [Region::Left, Region::Right, Region::Bottom][rng.below(3)];
            (Kind::Side, o, wb.side(w, r, vis(rng), origin).is_ok())
        }
        17 => {
            let r = [Region::Left, Region::Right, Region::Bottom][rng.below(3)];
            (
                Kind::Resize,
                o,
                wb.resize(w, r, rng.below(700) as u32, origin).is_ok(),
            )
        }
        18 => {
            let b = if rng.below(2) == 0 {
                let ks = wb.kinds.bottom.clone();
                BottomRef::Kind(rng.pick(&ks).unwrap_or_default())
            } else {
                BottomRef::Tab(some_tab(wb, rng))
            };
            (Kind::Bottom, o, wb.bottom(w, b, vis(rng), origin).is_ok())
        }
        19 => {
            use OverlayKind as K;
            let ks = [
                K::Palette,
                K::QuickOpen,
                K::Switcher,
                K::Menu,
                K::Toast,
                K::Card,
                K::QuickHelp,
                K::FindBar,
                K::DebugToolbar,
                K::Completion,
                K::Minibuffer,
                K::Side,
            ];
            let k = ks[rng.below(ks.len())];
            let spec = if rng.below(2) == 0 { "left" } else { "right" };
            (Kind::Overlay, o, wb.overlay(w, k, spec, origin).is_ok())
        }
        20 => (Kind::Dismiss, o, wb.dismiss(w, None, origin).is_ok()),
        21 => {
            let side = if rng.below(2) == 0 {
                Side::Right
            } else {
                Side::Down
            };
            (
                Kind::Split,
                o,
                wb.split(some_group(wb, w, rng), side, origin).is_ok(),
            )
        }
        22 => {
            let target = match rng.below(4) {
                0 => MoveTarget::Group(some_group(wb, w, rng)),
                1 => MoveTarget::NewGroup(some_group(wb, w, rng), Side::Right),
                2 => MoveTarget::Bottom,
                _ => MoveTarget::NewOsWindow,
            };
            if target == MoveTarget::NewOsWindow && wins.len() >= 3 {
                (Kind::MoveTab, o, false)
            } else {
                (
                    Kind::MoveTab,
                    o,
                    wb.move_tab(some_tab(wb, rng), target, origin).is_ok(),
                )
            }
        }
        23 => (
            Kind::Swap,
            o,
            wb.swap(some_group(wb, w, rng), dir4(rng), origin).is_ok(),
        ),
        24 => (
            Kind::Stack,
            o,
            wb.stack(some_group(wb, w, rng), dir4(rng), origin).is_ok(),
        ),
        25 => (
            Kind::FocusDir,
            o,
            wb.focus_dir(w, dir4(rng), origin).is_ok(),
        ),
        26 => (Kind::FullSize, o, wb.full_size(w, origin).is_ok()),
        27 => {
            let ws = [1.0 + rng.below(3) as f32, 1.0 + rng.below(3) as f32];
            (
                Kind::ResizeSplit,
                o,
                wb.resize_split(w, &[], &ws, origin).is_ok(),
            )
        }
        28 => (
            Kind::CloseGroup,
            o,
            wb.close_group(some_group(wb, w, rng), origin).is_ok(),
        ),
        29 => (
            Kind::RestorePrevious,
            o,
            wb.restore_previous_layout(w, origin).is_ok(),
        ),
        30 => {
            let names: Vec<String> = wb.kinds().presets.iter().map(|p| p.name.clone()).collect();
            if names.is_empty() || rng.below(3) == 0 {
                (Kind::NextLayout, o, wb.next_layout(w, origin).is_ok())
            } else {
                let n = &names[rng.below(names.len())];
                (Kind::Preset, o, wb.apply_preset(w, n, origin).is_ok())
            }
        }
        31 => {
            if wins.len() >= 3 {
                (Kind::TearOut, o, false)
            } else {
                let what = if rng.below(2) == 0 {
                    TearOut::Tab(some_tab(wb, rng))
                } else {
                    TearOut::Group(some_group(wb, w, rng))
                };
                (Kind::TearOut, o, wb.tear_out(what, origin).is_ok())
            }
        }
        32 => {
            if wins.len() < 3 && rng.below(2) == 0 {
                let tty = rng.below(3) == 0;
                let m = MONITORS[rng.below(2)];
                wb.window_new(m, rand_size(rng, tty), 1.0 + rng.below(2) as f32, tty);
                (Kind::WindowNew, None, true)
            } else {
                let tty = wb.window(w).is_some_and(|x| x.tty);
                let ok = wb
                    .set_window_size(w, rand_size(rng, tty), 1.0 + rng.below(2) as f32)
                    .is_ok();
                (Kind::SetWindowSize, None, ok)
            }
        }
        33 => {
            let ms: Vec<String> = match rng.below(3) {
                0 => vec!["m0".into()],
                _ => MONITORS.iter().map(|m| m.to_string()).collect(),
            };
            wb.set_monitors(ms);
            (Kind::SetMonitors, None, true)
        }
        34 => {
            let g = some_group(wb, w, rng);
            if rng.below(2) == 0 {
                (
                    Kind::BeginTemp,
                    o,
                    wb.begin_temp_layout(g, "ediff", "Ediff: a ↔ b", origin)
                        .is_ok(),
                )
            } else {
                (Kind::EndTemp, None, wb.end_temp_layout(g).is_ok())
            }
        }
        _ => match rng.below(3) {
            0 => {
                let f = TabFields {
                    title: Some(format!("t{}", rng.below(9))),
                    dirty: Some(rng.below(2) == 0),
                    ..TabFields::default()
                };
                (
                    Kind::UpdateTab,
                    None,
                    wb.update_tab(some_tab(wb, rng), f).is_ok(),
                )
            }
            1 => {
                wb.set_attention(rng.below(5) as u64, Vec::new());
                (Kind::SetAttention, None, true)
            }
            _ => {
                wb.buffer_gone(&format!("b{}", rng.below(5)));
                (Kind::BufferGone, None, true)
            }
        },
    };
    Step { kind, origin, ok }
}

/// Run `steps` random steps from `start`, checking each with `check`; the first broken rule stops the run.
pub fn run(
    mut wb: Workbench,
    seed: u64,
    steps: usize,
    mut check: impl FnMut(&Workbench, &Workbench, &Step) -> Result<(), RuleBroken>,
) -> Result<(), (usize, Step, RuleBroken)> {
    let mut rng = Rng::new(seed);
    for i in 0..steps {
        let before = wb.clone();
        let s = step(&mut wb, &mut rng);
        if let Err(e) = check(&before, &wb, &s) {
            return Err((i, s, e));
        }
    }
    Ok(())
}
