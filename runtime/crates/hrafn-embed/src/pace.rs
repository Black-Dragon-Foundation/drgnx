//! The pacing rule for the GPU path. Budgets come from the stall limit, not from VRAM: a batch's worst submit over
//! 8 ms halves the token budget, under 4 ms doubles it, never past [`TOKEN_CAP`]. One chunk is the smallest batch, so
//! the budget never stays below the chunk that leads the next batch.
//!
//! Pure logic with no clock of its own: the caller hands in `Forward::worst_submit`. On the CPU path that is zero, so
//! the budget sits at the cap.

use crate::local::TOKEN_CAP;
use std::time::Duration;

/// Where the budget starts, in tokens.
pub const PACE_START: usize = 2048;
/// A worst submit over this halves the budget.
pub const PACE_OVER: Duration = Duration::from_millis(8);
/// A worst submit under this doubles it.
pub const PACE_UNDER: Duration = Duration::from_millis(4);

#[derive(Debug, Clone)]
pub struct Pacer {
    budget: usize,
}

impl Default for Pacer {
    fn default() -> Self {
        Self::new()
    }
}

impl Pacer {
    pub fn new() -> Pacer {
        Pacer { budget: PACE_START }
    }

    /// The token budget of the next batch.
    pub fn budget(&self) -> usize {
        self.budget
    }

    /// The last batch's worst submit.
    pub fn observe(&mut self, worst_submit: Duration) {
        if worst_submit > PACE_OVER {
            self.budget = (self.budget / 2).max(1);
        } else if worst_submit < PACE_UNDER {
            self.budget = (self.budget * 2).min(TOKEN_CAP);
        }
    }

    /// How many of the next chunks (their token lengths, in order) go into the next batch: as many as fit the budget,
    /// and at least the first, to which the budget rises when it is below it.
    pub fn take(&mut self, lengths: &[usize]) -> usize {
        let Some(&first) = lengths.first() else {
            return 0;
        };
        self.budget = self.budget.max(first);
        let mut held = 0;
        let mut n = 0;
        for &len in lengths {
            if n > 0 && held + len > self.budget {
                break;
            }
            held += len;
            n += 1;
        }
        n
    }
}
