// A logical length cannot be a Glitnir rectangle: only pixels reach it.
fn main() {
    let w = kvardi::Lp(10.0);
    let rect = glitnir::geom::Rect::at(kvardi::Px(0), kvardi::Px(0), w, kvardi::Px(5));
    assert!(!rect.is_empty());
}
