//! A drawing crate under crates/ui that is not marked `ui = true`: the scale rule reaches it by its path.
pub fn at(x: f32, scale: f32) -> f32 {
    x * scale
}
