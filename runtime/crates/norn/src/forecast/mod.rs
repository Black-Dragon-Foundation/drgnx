//! Forecasts of what a plan will take (docs/develop/hub.md, "Forecasts").
//!
//! - [`model`]: reference classes, rates, the cost of a wake.
//! - [`sim`]: a plan's simulation over its dependencies, and calibration.
//! - [`sample`]: one row per finished task, derived from the `step` and `spend` tables.

pub mod model;
pub mod sample;
pub mod sim;
