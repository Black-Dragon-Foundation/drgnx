//! What cloud machines may cost (design §6.7.5): the projection a start must pass, the cap's states and the bound
//! stated at setup. Pure; amounts in USD, times in seconds.
//!
//! - [`projection`]: this month's spend + the new machine's price × (its expected busy time + the idle time) + what
//!   already runs until its idle stop. A start whose projection passes the cap doesn't happen.
//! - [`cap_state`]: under the cap, at it (no new cloud work), or a machine-hour past it (every machine stops now);
//!   [`guard`] is the same one check ahead, so the stop comes before the spend passes the line.
//! - [`stated_bound`]: what the user is told at setup: with the hub up, one machine-hour past the cap; with the hub
//!   down, max machines × the unattended lifetime (AWS, whose watchdog ends a machine) or × the lifetime (GCP, whose
//!   deadline does) × the price.

/// A machine that already runs: its hourly price and how long it is expected to run on (its jobs, then the idle time).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RunningCost {
    pub price_h: f64,
    pub remaining_s: u64,
}

/// What a start would bring this month's spend to.
pub fn projection(
    month_spent: f64,
    price_h: f64,
    expected_busy_s: u64,
    idle_s: u64,
    running: &[RunningCost],
) -> f64 {
    let ahead: f64 = running
        .iter()
        .map(|r| r.price_h * r.remaining_s as f64 / 3600.0)
        .sum();
    month_spent + price_h * (expected_busy_s + idle_s) as f64 / 3600.0 + ahead
}

/// Where the spend is against the cap.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapState {
    /// Starts may go ahead (through the projection).
    Under,
    /// At the cap: no new cloud work; each machine stops when its current jobs end.
    AtCap,
    /// One machine-hour past the cap: every machine stops now, and its jobs requeue.
    PastCapPlusHour,
}

/// SPENT against CAP, where MACHINE_HOUR is the price of one machine-hour.
pub fn cap_state(spent: f64, cap: f64, machine_hour: f64) -> CapState {
    if spent >= cap + machine_hour {
        CapState::PastCapPlusHour
    } else if spent >= cap {
        CapState::AtCap
    } else {
        CapState::Under
    }
}

/// [`cap_state`] as it will be at the next check: SPENT plus what RATE_H (the running machines' hourly total) adds
/// in CHECK_S. The caller stops the machines on `PastCapPlusHour`, so the spend never passes the line.
pub fn guard(spent: f64, rate_h: f64, check_s: u64, cap: f64, machine_hour: f64) -> CapState {
    cap_state(spent + rate_h * check_s as f64 / 3600.0, cap, machine_hour)
}

/// Which provider a bound is for: who ends a machine when the hub can't.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// The machine's own watchdog powers it off at the unattended lifetime after the hub's last contact.
    Aws,
    /// The provider's deadline, fixed at the start: the lifetime.
    Gcp,
}

/// The user's time limits that bound a machine with the hub gone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hours {
    pub unattended_s: u64,
    pub lifetime_s: u64,
}

/// The bound stated at setup.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bound {
    /// With the hub up and holding credentials: what may be spent past the cap (one machine-hour).
    pub hub_up: f64,
    /// With the hub down, asleep or without credentials: the most spent from then on.
    pub hub_down: f64,
}

/// The bound for PROVIDER with at most MAX_MACHINES at PRICE_H each (the dearest allowed size).
pub fn stated_bound(provider: Kind, max_machines: u32, hours: Hours, price_h: f64) -> Bound {
    let unattended = match provider {
        Kind::Aws => hours.unattended_s.min(hours.lifetime_s),
        Kind::Gcp => hours.lifetime_s,
    };
    Bound {
        hub_up: price_h,
        hub_down: max_machines as f64 * unattended as f64 / 3600.0 * price_h,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    const H: u64 = 3600;

    proptest! {
        /// [D] property: every start goes through the projection; machines then run as projected (busy, then idle
        /// until their stop), with time passing between the requests. What they cost never passes the cap.
        #[test]
        fn projected_spend_never_passes_the_cap(
            cap in 1.0f64..200.0,
            spent_frac in 0.0f64..1.0,
            reqs in prop::collection::vec((0.01f64..20.0, 0u64..4 * H, 0u64..H, 0u64..2 * H), 0..30),
        ) {
            let mut spent = cap * spent_frac;
            let mut now = 0u64;
            // (price per hour, when it stops)
            let mut running: Vec<(f64, u64)> = vec![];
            for (price_h, busy_s, idle_s, gap) in reqs {
                let to = now + gap;
                for (p, end) in &running {
                    spent += p * ((*end).min(to).saturating_sub(now)) as f64 / 3600.0;
                }
                running.retain(|(_, end)| *end > to);
                now = to;
                prop_assert!(spent <= cap + 1e-6, "{spent} > {cap}");
                let rc: Vec<RunningCost> = running
                    .iter()
                    .map(|(p, end)| RunningCost { price_h: *p, remaining_s: end - now })
                    .collect();
                if projection(spent, price_h, busy_s, idle_s, &rc) <= cap {
                    running.push((price_h, now + busy_s + idle_s));
                }
            }
            for (p, end) in &running {
                spent += p * (end - now) as f64 / 3600.0;
            }
            prop_assert!(spent <= cap + 1e-6, "{spent} > {cap}");
        }

        /// [D] property: with the hub up, machines start through the projection and the cap's states, then run longer
        /// than projected; the guard, looking one check ahead, stops them all before the spend passes the cap plus one
        /// machine-hour. With the hub gone at DOWN_AT, every machine still running ends by its own layers: AWS by the
        /// unattended lifetime after the hub's last contact, GCP by its deadline (its lifetime from its start). What
        /// it then costs stays within the stated bound.
        #[test]
        fn the_bound_holds_hub_up_and_down(
            cap in 1.0f64..100.0,
            price_h in 0.01f64..10.0,
            max in 1u32..4,
            machines in prop::collection::vec((0u64..4 * H, 0u64..12 * H, 0u64..2 * H), 1..8),
            gcp in any::<bool>(),
            down_at in 0u64..12 * H,
        ) {
            const CHECK_S: u64 = 60;
            let provider = if gcp { Kind::Gcp } else { Kind::Aws };
            let hours = Hours { unattended_s: 2 * H, lifetime_s: 8 * H };
            let bound = stated_bound(provider, max, hours, price_h);
            prop_assert!((bound.hub_up - price_h).abs() < 1e-9);

            // hub up: (projected busy, actual run, when it is asked for)
            let mut spent = 0.0f64;
            let mut wanted: Vec<(u64, u64, u64)> = machines.clone();
            wanted.sort_by_key(|m| m.2);
            let mut running: Vec<(u64, u64)> = vec![]; // (started, ends)
            let mut t = 0u64;
            while t < 16 * H {
                let rate = running.len() as f64 * price_h;
                if guard(spent, rate, CHECK_S, cap, price_h) == CapState::PastCapPlusHour {
                    running.clear();
                }
                for (busy, actual, _) in wanted.iter().filter(|m| m.2 >= t && m.2 < t + CHECK_S) {
                    let rc: Vec<RunningCost> = running
                        .iter()
                        .map(|(s, _)| RunningCost {
                            price_h,
                            remaining_s: (s + busy + 900).saturating_sub(t),
                        })
                        .collect();
                    if running.len() < max as usize
                        && cap_state(spent, cap, price_h) == CapState::Under
                        && projection(spent, price_h, *busy, 900, &rc) <= cap
                    {
                        running.push((t, t + (*actual).max(1)));
                    }
                }
                spent += running.len() as f64 * price_h * CHECK_S as f64 / 3600.0;
                prop_assert!(spent <= cap + bound.hub_up + 1e-6, "{spent} > {cap} + {}", bound.hub_up);
                running.retain(|(_, end)| *end > t + CHECK_S);
                t += CHECK_S;
            }

            // hub down at DOWN_AT: up to MAX machines started before it, each running as long as it likes
            let mut after = 0.0f64;
            for (_, actual, at) in machines.iter().take(max as usize) {
                let started = (*at).min(down_at);
                let wants = started + actual;
                let ends = match provider {
                    // the watchdog: the unattended lifetime after the last contact, the lifetime whatever runs
                    Kind::Aws => wants.min(down_at + hours.unattended_s).min(started + hours.lifetime_s),
                    // the provider's deadline, fixed at the start
                    Kind::Gcp => wants.min(started + hours.lifetime_s),
                };
                after += price_h * ends.saturating_sub(down_at) as f64 / 3600.0;
            }
            prop_assert!(after <= bound.hub_down + 1e-6, "{after} > {}", bound.hub_down);
        }
    }

    // [D] pure
    #[test]
    fn the_bound_is_the_designs() {
        let hours = Hours {
            unattended_s: 2 * H,
            lifetime_s: 8 * H,
        };
        // "Worst case with drgnx down: 2 machines × 2 h = about $1.64" at $0.41/h
        let aws = stated_bound(Kind::Aws, 2, hours, 0.41);
        assert!((aws.hub_down - 1.64).abs() < 1e-9, "{aws:?}");
        assert!((aws.hub_up - 0.41).abs() < 1e-9, "{aws:?}");
        // GCP: the guest can't end itself, so the lifetime
        let gcp = stated_bound(Kind::Gcp, 2, hours, 0.41);
        assert!((gcp.hub_down - 6.56).abs() < 1e-9, "{gcp:?}");
        assert!(
            (projection(41.0, 1.2, 1500, 900, &[]) - 41.8).abs() < 1e-9,
            "the new machine's price × (busy + idle)"
        );
        let running = [RunningCost {
            price_h: 0.6,
            remaining_s: 1800,
        }];
        assert!((projection(41.0, 1.2, 1500, 900, &running) - 42.1).abs() < 1e-9);
    }
}
