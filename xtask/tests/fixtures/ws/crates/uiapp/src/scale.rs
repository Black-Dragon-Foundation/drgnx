pub fn mul(x: f32, scale: f32, s: &S) -> f32 {
    let a = x * scale;
    let b = (x as f32) * s.scale_factor;
    let c = s.zoom_scale() * 2.0;
    let mut d = 1.0;
    d *= scale;
    let e = scale as f32 * x;
    let fine = x * 2.0;
    a + b + c + d + e + fine
}
