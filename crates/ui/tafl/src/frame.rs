//! Frames: the demand roots (visible blocks, a11y nodes, agents' subscriptions) are brought up to date, whole blocks
//! only, until the budget is spent; the rest go first in the next frame.

use std::time::Duration;

use crate::cell::CellId;
use crate::engine::Engine;

/// What a frame did: the roots brought up to date, the ones left for the next frame (whole blocks), and the roots whose
/// value changed (their items become damage).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FrameOut {
    pub done: Vec<CellId>,
    pub deferred: Vec<CellId>,
    pub changed_items: Vec<CellId>,
}

impl Engine {
    /// One frame: landed jobs and a due clock tick are applied, then the roots carried from the last frame and ROOTS
    /// are pulled in order, each whole, until BUDGET (on the engine's clock) is spent; at least one root is done.
    pub fn frame(&mut self, roots: &[CellId], budget: Duration) -> FrameOut {
        crate::ops::pool::land(self);
        self.tick();
        let start = self.core.clock.now();
        let mut order = std::mem::take(&mut self.carried);
        for r in roots {
            if !order.contains(r) {
                order.push(*r);
            }
        }
        let mut out = FrameOut::default();
        let e: &Engine = self;
        for (k, root) in order.iter().enumerate() {
            if !out.done.is_empty() && e.core.clock.now().saturating_sub(start) >= budget {
                out.deferred.extend_from_slice(&order[k..]);
                break;
            }
            if !e.core.is_live(*root) {
                continue;
            }
            if e.core.update(e, root.idx) {
                out.changed_items.push(*root);
            }
            out.done.push(*root);
        }
        self.carried.clone_from(&out.deferred);
        self.core.requested.set(false);
        self.after();
        out
    }
}
