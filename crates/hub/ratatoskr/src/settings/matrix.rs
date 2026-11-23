//! Decoding the `agents-matrix` setting and a plan's `matrix` field (agent system part 1, Task 12): the user's base
//! preset, the time presets and the cell overrides, as JSON in the wire's own words (`runstav::methods::matrix`).
//!
//! ```json
//! {"preset": "balanced",
//!  "time": [{"when": "away", "preset": "cautious"}],
//!  "cells": [{"action": "commit", "column": {"role": "worker"}, "verdict": "ask"}]}
//! ```

use norn::matrix::Matrix;
use runstav::methods::matrix::{CellRow, Preset, TimePreset};
use serde::Deserialize;
use serde_json::Value;

/// What the setting says.  A missing `preset` is Balanced.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Decoded {
    pub preset: Option<Preset>,
    pub time_presets: Vec<TimePreset>,
    pub overrides: Matrix,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Raw {
    #[serde(default)]
    preset: Option<Preset>,
    #[serde(default)]
    time: Vec<TimePreset>,
    #[serde(default)]
    cells: Vec<CellRow>,
}

/// The cells of ROWS as one layer.
pub fn layer(rows: &[CellRow]) -> Matrix {
    let mut m = Matrix::default();
    for r in rows {
        m.set(
            r.action,
            r.column.clone(),
            norn::matrix::Cell {
                verdict: r.verdict,
                limit: r.limit,
            },
        );
    }
    m
}

/// Decode V (`null` is the empty setting); the error names what does not fit.
pub fn decode(v: &Value) -> Result<Decoded, String> {
    if v.is_null() {
        return Ok(Decoded::default());
    }
    let raw: Raw = serde_json::from_value(v.clone()).map_err(|e| format!("agents-matrix: {e}"))?;
    Ok(Decoded {
        preset: raw.preset,
        time_presets: raw.time,
        overrides: layer(&raw.cells),
    })
}

/// A plan's `matrix` field: only cells (a plan changes no preset).
pub fn decode_cells(v: &Value) -> Result<Matrix, String> {
    let rows: Vec<CellRow> =
        serde_json::from_value(v.clone()).map_err(|e| format!("matrix: {e}"))?;
    Ok(layer(&rows))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn decodes_preset_time_and_cells() {
        let d = decode(&json!({
            "preset": "cautious",
            "time": [{"when": "away", "preset": "autonomous"}],
            "cells": [{"action": "commit", "column": {"role": "worker"}, "verdict": "never"}]
        }))
        .unwrap();
        assert_eq!(d.preset, Some(Preset::Cautious));
        assert_eq!(d.time_presets.len(), 1);
        assert_eq!(d.overrides.cells.len(), 1);
        assert_eq!(decode(&Value::Null).unwrap(), Decoded::default());
        assert!(decode(&json!({"preset": "wild"})).is_err());
    }
}
