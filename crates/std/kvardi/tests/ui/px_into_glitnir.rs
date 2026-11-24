// The control: the same call with pixels compiles, so the failure above is the unit, not something else.
fn main() {
    let r = glitnir::geom::Rect::at(kvardi::Px(0), kvardi::Px(0), kvardi::Px(10), kvardi::Px(5));
    assert_eq!(r.w, 10);
}
