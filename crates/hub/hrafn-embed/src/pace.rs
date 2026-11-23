//! The pacing rule for the GPU path. Budgets come from the stall limit, not from VRAM: a batch's worst submit over
//! 8 ms halves the token budget, under 4 ms doubles it, never past [`TOKEN_CAP`]. One chunk is the smallest batch, so
//! the budget never stays below the chunk that leads the next batch.
//!
//! Pure logic with no clock of its own: the caller hands in `Forward::worst_submit`. On the CPU path that is zero, so
//! the budget sits at the cap.
//!
//! Each source has a budget of its own: the built-in engine's [`Pacer::new`] (capped at [`TOKEN_CAP`]), the llama.cpp
//! engine's [`Pacer::fixed`] (its batch size, which no stall measure moves). Either takes chunks in the order
//! [`by_length`] gives, so a batch holds texts of about one length.

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
    cap: usize,
}

impl Default for Pacer {
    fn default() -> Self {
        Self::new()
    }
}

impl Pacer {
    pub fn new() -> Pacer {
        Pacer {
            budget: PACE_START,
            cap: TOKEN_CAP,
        }
    }

    /// A budget of TOKENS that stays there: a source whose batches no stall measure sizes (the llama.cpp engine's
    /// batch size).
    pub fn fixed(tokens: usize) -> Pacer {
        let tokens = tokens.max(1);
        Pacer {
            budget: tokens,
            cap: tokens,
        }
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
            self.budget = (self.budget * 2).min(self.cap);
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

/// The order to batch texts of LENGTHS in: shortest first, equal lengths in their given order. Each batch then holds
/// texts of about one length, so a batch's padding and context are sized to its own longest.
pub fn by_length(lengths: &[usize]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..lengths.len()).collect();
    order.sort_by_key(|&i| lengths[i]);
    order
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fixed_budget_never_moves() {
        let mut p = Pacer::fixed(8192);
        p.observe(Duration::from_millis(100));
        assert_eq!(p.budget(), 4096, "a stall still halves it");
        p.observe(Duration::ZERO);
        p.observe(Duration::ZERO);
        assert_eq!(p.budget(), 8192, "and it never passes its own cap");
    }

    #[test]
    fn by_length_is_shortest_first_and_stable() {
        assert_eq!(by_length(&[5, 1, 5, 3, 1]), vec![1, 4, 3, 0, 2]);
        assert!(by_length(&[]).is_empty());
    }
}
