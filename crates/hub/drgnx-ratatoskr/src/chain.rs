//! The health of a chain of vector providers and its backoff, shared by the entity embedder ([`crate::embed`]) and Hrafn's
//! source chains ([`crate::search::sources`]): one backoff, not two.
//!
//! A member that fails waits 1, 5 and 30 minutes, then 6 hours, on the hub's clock ([`BACKOFF`]); an answer resets it.
//! Each change of state is one [`Change`] (one log line).

use std::time::Duration;
use tokio::time::Instant;

/// How long a down embedder waits before it is asked again, after its first, second, third and later failures in a row:
/// 1, 5 and 30 minutes, then every 6 hours (on the hub's clock, virtual in tests).
pub const BACKOFF: [Duration; 4] = [
    Duration::from_secs(60),
    Duration::from_secs(5 * 60),
    Duration::from_secs(30 * 60),
    Duration::from_secs(6 * 60 * 60),
];

/// The wait after FAILURES failures in a row (1 or more).
pub fn backoff(failures: u32) -> Duration {
    let i = usize::try_from(failures.max(1) - 1).unwrap_or(usize::MAX);
    BACKOFF[i.min(BACKOFF.len() - 1)]
}

/// How one embedder of the chain stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Health {
    /// It answered last time (or has not been asked yet).
    Answering,
    /// It failed FAILURES times in a row; it is asked again, with one text, at UNTIL.
    Down {
        failures: u32,
        until: Instant,
        why: String,
    },
}

/// A change of an embedder's state: what the log and the Notices say, once each.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Down { model: String, why: String },
    Up { model: String },
}

/// The embedders of the chain by model name, in the user's order, with their health.
#[derive(Debug, Default)]
pub struct Chain {
    entries: Vec<(String, Health)>,
}

impl Chain {
    /// The chain is MODELS now, in that order: an embedder already known keeps its health, a new one answers.
    pub fn sync(&mut self, models: &[String]) {
        let mut old = std::mem::take(&mut self.entries);
        for m in models {
            let health = match old.iter().position(|(o, _)| o == m) {
                Some(i) => old.swap_remove(i).1,
                None => Health::Answering,
            };
            self.entries.push((m.clone(), health));
        }
    }

    /// Each embedder with its health, in the chain's order.
    pub fn entries(&self) -> &[(String, Health)] {
        &self.entries
    }

    fn health_mut(&mut self, model: &str) -> Option<&mut Health> {
        self.entries
            .iter_mut()
            .find(|(m, _)| m == model)
            .map(|(_, h)| h)
    }

    /// Whether MODEL may take a batch: it answered last time.
    pub fn answering(&self, model: &str) -> bool {
        self.entries
            .iter()
            .any(|(m, h)| m == model && *h == Health::Answering)
    }

    /// Whether any embedder of the chain may take a batch.
    pub fn any_answering(&self) -> bool {
        self.entries.iter().any(|(_, h)| *h == Health::Answering)
    }

    /// MODEL failed at NOW with WHY: it waits for its next backoff.  A change only when it was answering.
    pub fn fail(&mut self, model: &str, why: &str, now: Instant) -> Option<Change> {
        let h = self.health_mut(model)?;
        match h {
            Health::Answering => {
                *h = Health::Down {
                    failures: 1,
                    until: now + backoff(1),
                    why: why.to_owned(),
                };
                Some(Change::Down {
                    model: model.to_owned(),
                    why: why.to_owned(),
                })
            }
            Health::Down {
                failures,
                until,
                why: w,
            } => {
                *failures += 1;
                *until = now + backoff(*failures);
                why.clone_into(w);
                None
            }
        }
    }

    /// MODEL answered: its backoff is over.  A change only when it was down.
    pub fn answered(&mut self, model: &str) -> Option<Change> {
        let h = self.health_mut(model)?;
        if *h == Health::Answering {
            return None;
        }
        *h = Health::Answering;
        Some(Change::Up {
            model: model.to_owned(),
        })
    }

    /// The down embedders whose wait is over at NOW, in the chain's order.
    pub fn probes_due(&self, now: Instant) -> Vec<String> {
        self.entries
            .iter()
            .filter(|(_, h)| matches!(h, Health::Down { until, .. } if *until <= now))
            .map(|(m, _)| m.clone())
            .collect()
    }

    /// Retry now: every down embedder is asked at the next step.
    pub fn retry_now(&mut self, now: Instant) {
        for (_, h) in &mut self.entries {
            if let Health::Down { until, .. } = h {
                *until = now;
            }
        }
    }
}
