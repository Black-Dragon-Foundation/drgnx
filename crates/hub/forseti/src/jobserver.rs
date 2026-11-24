//! The machine's jobserver: how many tokens its pool holds (the pure sizing; the pool is `sleipnir::linux::jobserver`).
//!
//! A job that takes part gets the pool's fifo (`MAKEFLAGS=--jobserver-auth=fifo:…`); the build tools it runs take a
//! token for every process they start beyond their own, so the machine's build parallelism follows the budget while
//! jobs run, not only at their start ([`crate::admit::jobs_for`] sizes a job once, at its start).

use crate::admit::Budget;

/// What the pool's size is read from, on every admission tick.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PoolInput {
    /// What the machine can still give ([`crate::admit::budget`]).
    pub budget: Budget,
    /// The CPU the jobs of the pool hold now, which the budget has already taken out (they get it back as tokens).
    pub pool_cpu: f64,
    /// The memory the jobs of the pool hold beyond their use, MiB, likewise.
    pub pool_mib: u64,
    /// The memory one token is worth, MiB (`unit_mib` of the jobs: [`crate::admit::DEFAULT_UNIT_MIB`] without one).
    pub unit_mib: u64,
    /// The cores a waiting P1 or P2 job needs: tokens are left for it first (the weights' rule, `resize::weights`).
    pub waiting_p12_cores: u32,
}

/// The tokens the pool holds: one per core of CPU and per `unit_mib` of memory the machine can give the pool (its
/// budget plus what the pool's jobs hold), the smaller of the two, less the cores a waiting P1–P2 job needs; never
/// fewer than one, so a build always progresses.
pub fn tokens(i: &PoolInput) -> u32 {
    let cpu = (i.budget.cpu + i.pool_cpu).max(0.0).floor() as u64;
    let mem = (i.budget.mem_mib.max(0) as u64 + i.pool_mib) / i.unit_mib.max(1);
    let n = cpu.min(mem).saturating_sub(u64::from(i.waiting_p12_cores));
    u32::try_from(n).unwrap_or(u32::MAX).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(cpu: f64, mem_mib: i64) -> PoolInput {
        PoolInput {
            budget: Budget { mem_mib, cpu },
            pool_cpu: 0.0,
            pool_mib: 0,
            unit_mib: 2048,
            waiting_p12_cores: 0,
        }
    }

    /// [D] pure (Task 10a): a token per core and per unit of memory, the smaller, never none.
    #[test]
    fn tokens_follow_the_budget() {
        assert_eq!(tokens(&input(8.0, 16_384)), 8, "8 cores, 8 units");
        assert_eq!(tokens(&input(8.0, 4096)), 2, "memory is the limit");
        assert_eq!(
            tokens(&input(3.5, 65_536)),
            3,
            "a part of a core is no token"
        );
        assert_eq!(tokens(&input(-2.0, -500)), 1, "a build always progresses");
        // the pool's own jobs hold 4 cores and 8 GiB: they count as the pool's to give
        let held = PoolInput {
            pool_cpu: 4.0,
            pool_mib: 8192,
            ..input(0.0, 0)
        };
        assert_eq!(tokens(&held), 4);
        // a rise of the budget is a rise of the pool, and a fall a fall
        assert!(tokens(&input(12.0, 65_536)) > tokens(&input(6.0, 65_536)));
        assert!(tokens(&input(6.0, 65_536)) > tokens(&input(2.0, 65_536)));
    }

    /// [D] pure (Task 10a): the cores a waiting P1–P2 job needs come off the pool first; one token stays.
    #[test]
    fn a_waiting_p1_gets_tokens_first() {
        let waiting = |n| PoolInput {
            waiting_p12_cores: n,
            ..input(8.0, 65_536)
        };
        assert_eq!(tokens(&waiting(0)), 8);
        assert_eq!(tokens(&waiting(3)), 5);
        assert_eq!(tokens(&waiting(20)), 1);
    }
}
