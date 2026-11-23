/// A quantiser's step named `scale`: not a UI scale, so no rule reads it.
pub fn dequantise(sum: i64, scale: f64) -> f64 {
    sum as f64 * scale
}
