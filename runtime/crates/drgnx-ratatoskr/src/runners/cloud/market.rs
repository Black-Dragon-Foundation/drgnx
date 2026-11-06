//! Spot or on-demand (design §6.7.3; `docs/guide/runners.md`, "Spot"), per `drgnx-runners-cloud-market`.
//!
//! `spot-then-on-demand` (the default) starts spot machines, and in a region where spot failed twice within an hour
//! (two preemptions, or "no spot capacity" twice) uses on-demand there for 6 hours. A job that can't be restarted never
//! goes to spot. Pure: the hub records what happened in a [`History`] and asks [`Policy::for_job`] at each start.

use super::Market;
use std::collections::BTreeMap;

/// Two failures of one kind within this many seconds turn a region to on-demand.
pub const WINDOW_S: u64 = 3600;
/// For this long, counted from the second.
pub const FALLBACK_S: u64 = 6 * 3600;

/// `drgnx-runners-cloud-market`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// Spot only.
    Spot,
    /// On-demand only.
    OnDemand,
    /// Spot, and on-demand where spot fails.
    #[default]
    SpotThenOnDemand,
}

impl Mode {
    /// The setting's value: `spot`, `on-demand`, `spot-then-on-demand`.
    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "spot" => Some(Mode::Spot),
            "on-demand" => Some(Mode::OnDemand),
            "spot-then-on-demand" => Some(Mode::SpotThenOnDemand),
            _ => None,
        }
    }
}

/// What spot did in a region.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// A spot machine got the provider's notice.
    Preempted,
    /// A spot start answered "no capacity".
    NoCapacity,
}

/// What spot did, per region: only what can still matter (the window and the fallback), so it stays small.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct History {
    by_region: BTreeMap<String, Vec<(u64, Event)>>,
}

impl History {
    /// EVENT in REGION at AT.
    pub fn record(&mut self, region: &str, at: u64, event: Event) {
        let v = self.by_region.entry(region.to_string()).or_default();
        v.push((at, event));
        v.sort_by_key(|(t, _)| *t);
        let newest = v.last().map_or(at, |(t, _)| *t);
        v.retain(|(t, _)| newest.saturating_sub(*t) < WINDOW_S + FALLBACK_S);
    }

    /// How many events it keeps, over every region.
    pub fn len(&self) -> usize {
        self.by_region.values().map(Vec::len).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Whether REGION is on on-demand at NOW: two events of one kind within the window, the second less than the
    /// fallback ago.
    pub fn falls_back(&self, region: &str, now: u64) -> bool {
        let Some(v) = self.by_region.get(region) else {
            return false;
        };
        [Event::Preempted, Event::NoCapacity]
            .into_iter()
            .any(|kind| {
                let times: Vec<u64> = v
                    .iter()
                    .filter(|(t, e)| *e == kind && *t <= now)
                    .map(|(t, _)| *t)
                    .collect();
                times
                    .windows(2)
                    .any(|w| w[1] - w[0] < WINDOW_S && now - w[1] < FALLBACK_S)
            })
    }
}

/// The market a start uses.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Policy {
    pub mode: Mode,
}

impl Policy {
    /// The market for a restartable job in REGION at NOW.
    pub fn choose(&self, region: &str, now: u64, history: &History) -> Market {
        match self.mode {
            Mode::Spot => Market::Spot,
            Mode::OnDemand => Market::OnDemand,
            Mode::SpotThenOnDemand if history.falls_back(region, now) => Market::OnDemand,
            Mode::SpotThenOnDemand => Market::Spot,
        }
    }

    /// The market for a job (RESTARTABLE or not) in REGION at NOW; none when the setting allows it none (spot only, and
    /// a job that can't be restarted never goes to spot).
    pub fn for_job(
        &self,
        restartable: bool,
        region: &str,
        now: u64,
        history: &History,
    ) -> Option<Market> {
        match (restartable, self.mode) {
            (true, _) => Some(self.choose(region, now, history)),
            (false, Mode::Spot) => None,
            (false, _) => Some(Market::OnDemand),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const H: u64 = 3600;

    // [D] pure
    #[test]
    fn market_falls_back_after_2_preemptions_for_6h() {
        let p = Policy {
            mode: Mode::SpotThenOnDemand,
        };
        let (eu, us) = ("eu-west-1", "us-east-1");
        let mut h = History::default();
        assert_eq!(p.choose(eu, 0, &h), Market::Spot);
        h.record(eu, 1000, Event::Preempted);
        assert_eq!(p.choose(eu, 1001, &h), Market::Spot, "one is not two");
        // the second an hour later: not within the hour
        h.record(eu, 1000 + H, Event::Preempted);
        assert_eq!(p.choose(eu, 1001 + H, &h), Market::Spot);
        // the third 400 s after the second: two within the hour, on-demand there for 6 h
        let at = 1400 + H;
        h.record(eu, at, Event::Preempted);
        assert_eq!(p.choose(eu, at, &h), Market::OnDemand);
        assert_eq!(p.choose(eu, at + 6 * H - 1, &h), Market::OnDemand);
        assert_eq!(p.choose(eu, at + 6 * H, &h), Market::Spot);
        // only in that region
        assert_eq!(p.choose(us, at, &h), Market::Spot);

        // "no spot capacity" twice is the same
        h.record(us, 100, Event::NoCapacity);
        assert_eq!(p.choose(us, 150, &h), Market::Spot);
        h.record(us, 200, Event::NoCapacity);
        assert_eq!(p.choose(us, 200, &h), Market::OnDemand);
        assert_eq!(p.choose(us, 200 + 6 * H, &h), Market::Spot);
        // one of each is not two of one
        let mut mixed = History::default();
        mixed.record(eu, 10, Event::Preempted);
        mixed.record(eu, 20, Event::NoCapacity);
        assert_eq!(p.choose(eu, 30, &mixed), Market::Spot);

        // the other modes never change
        let mut hot = History::default();
        hot.record(eu, 10, Event::Preempted);
        hot.record(eu, 20, Event::Preempted);
        let spot = Policy { mode: Mode::Spot };
        let od = Policy {
            mode: Mode::OnDemand,
        };
        assert_eq!(spot.choose(eu, 30, &hot), Market::Spot);
        assert_eq!(od.choose(eu, 30, &History::default()), Market::OnDemand);

        // what it keeps stays bounded: an event older than the window and the fallback goes
        let mut long = History::default();
        for n in 0..1000u64 {
            long.record(eu, n * 4 * H, Event::Preempted);
        }
        assert!(long.len() <= 3, "{}", long.len());

        // the setting's values
        assert_eq!(Mode::parse("spot"), Some(Mode::Spot));
        assert_eq!(Mode::parse("on-demand"), Some(Mode::OnDemand));
        assert_eq!(
            Mode::parse("spot-then-on-demand"),
            Some(Mode::SpotThenOnDemand)
        );
        assert_eq!(Mode::parse("cheap"), None);
        assert_eq!(Mode::default(), Mode::SpotThenOnDemand);
    }

    // [D] pure
    #[test]
    fn non_restartable_never_spot() {
        let eu = "eu-west-1";
        let mut hot = History::default();
        hot.record(eu, 10, Event::Preempted);
        hot.record(eu, 20, Event::Preempted);
        for mode in [Mode::Spot, Mode::OnDemand, Mode::SpotThenOnDemand] {
            for h in [History::default(), hot.clone()] {
                let p = Policy { mode };
                assert_ne!(p.for_job(false, eu, 30, &h), Some(Market::Spot), "{mode:?}");
            }
        }
        let then = Policy {
            mode: Mode::SpotThenOnDemand,
        };
        assert_eq!(
            then.for_job(false, eu, 30, &History::default()),
            Some(Market::OnDemand)
        );
        assert_eq!(
            then.for_job(true, eu, 30, &History::default()),
            Some(Market::Spot)
        );
        // spot only: a job that can't be restarted has no cloud market at all
        let spot = Policy { mode: Mode::Spot };
        assert_eq!(spot.for_job(false, eu, 30, &History::default()), None);
        assert_eq!(
            spot.for_job(true, eu, 30, &History::default()),
            Some(Market::Spot)
        );
    }
}
