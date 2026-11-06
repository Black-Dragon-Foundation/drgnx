//! Forecasts (docs/develop/hub.md, "Forecasts"): the sweep that turns finished tasks into samples.
//!
//! A sample is derived from the `step` and `spend` tables ([`norn::forecast::sample`]), so a restart, a sweep that
//! runs twice and the backfill of history are the same code: [`sweep`] takes what is due, a page at a time.

use crate::front::Front;
use norn::forecast::sample::{self, ProfileFacts};
use std::collections::HashMap;

/// Samples taken per read.
const PAGE: i64 = 100;
/// The cache time to live a profile is assumed to have.
const DEFAULT_TTL_SECS: f64 = 300.0;

/// The model each profile name is configured with (the user's profiles first, then the built-in ones).
fn profile_models(front: &Front) -> HashMap<String, Option<String>> {
    let cur = front.settings.current();
    let mut out = HashMap::new();
    for p in cur
        .loaded
        .values
        .agents_profiles
        .iter()
        .chain(&crate::settings::defaults().profiles)
    {
        out.entry(p.name.clone()).or_insert_with(|| p.model.clone());
    }
    out
}

/// Sample every finished task that is due, page by page, until none is.  Best effort: a store that is not ready
/// ends the sweep, and the next one starts again.
pub async fn sweep(front: &Front) {
    let models = profile_models(front);
    loop {
        let m = models.clone();
        let page = front
            .writer
            .db
            .read(move |c| {
                let facts = |profile: Option<&str>, _role: &str| ProfileFacts {
                    model: profile.and_then(|p| m.get(p).cloned().flatten()),
                    ttl_secs: DEFAULT_TTL_SECS,
                };
                let due = sample::due(c, PAGE)?;
                let n = due.len();
                let mut rows = Vec::new();
                for task in due {
                    rows.extend(sample::gather(c, &task, &facts)?);
                }
                Ok((n, rows))
            })
            .await;
        let (due, mut rows) = match page {
            Ok(p) => p,
            Err(e) => {
                tracing::debug!("forecast sweep: {e}");
                return;
            }
        };
        if rows.is_empty() {
            return;
        }
        let at = crate::clock::wall_secs();
        for r in &mut rows {
            r.at = at;
        }
        let wrote = front
            .writer
            .write(&crate::runner::service(), "forecast/sample", move |tx| {
                for r in &rows {
                    sample::put(tx, r)?;
                }
                Ok(())
            })
            .await;
        if let Err(e) = wrote {
            tracing::debug!("forecast sweep: {e}");
            return;
        }
        if i64::try_from(due).unwrap_or(PAGE) < PAGE {
            return;
        }
    }
}
