//! A measurement report: one JSON file per scenario run, comparable to an earlier one.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub name: String,
    pub commit: String,
    pub machine: String,
    /// Metric name to value. Every metric is lower-is-better.
    pub metrics: BTreeMap<String, f64>,
}

/// A metric that grew past the tolerance.
#[derive(Debug, Clone, PartialEq)]
pub struct Regression {
    pub metric: String,
    pub base: f64,
    pub new: f64,
}

impl fmt::Display for Regression {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {} -> {}", self.metric, self.base, self.new)
    }
}

impl Report {
    pub fn write_json(&self, path: impl AsRef<Path>) -> Result<(), Error> {
        let path = path.as_ref();
        let mut text = serde_json::to_string_pretty(self).map_err(|source| Error::Json {
            path: path.to_path_buf(),
            source,
        })?;
        text.push('\n');
        fs::write(path, text).map_err(|source| Error::Io {
            path: path.to_path_buf(),
            source,
        })
    }

    pub fn read_json(path: impl AsRef<Path>) -> Result<Report, Error> {
        let path = path.as_ref();
        let text = fs::read_to_string(path).map_err(|source| Error::Io {
            path: path.to_path_buf(),
            source,
        })?;
        serde_json::from_str(&text).map_err(|source| Error::Json {
            path: path.to_path_buf(),
            source,
        })
    }

    /// The metrics of `self` (the new run) that exceed `base`'s by more than `tolerance` (0.05 = 5 %). A metric
    /// missing from `base` has nothing to regress from and is skipped; growth from a base of 0 always counts.
    pub fn compare(&self, base: &Report, tolerance: f64) -> Vec<Regression> {
        self.metrics
            .iter()
            .filter_map(|(metric, &new)| {
                let &old = base.metrics.get(metric)?;
                (new > old * (1.0 + tolerance)).then(|| Regression {
                    metric: metric.clone(),
                    base: old,
                    new,
                })
            })
            .collect()
    }
}
