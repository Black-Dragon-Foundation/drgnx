# Scale and zoom

**The rule.** A view measures in logical units (`kvardi::Lp`); Glitnir draws in physical pixels (`kvardi::Px`). The one
conversion is `Lp::to_px(&Scale)`, which multiplies by the effective scale and rounds half away from zero. Nothing
else multiplies a length by a scale.

**Doing it right.**

```rust
let scale = screens.scale(&window, Some("editor"), None);   // output × app × window × pane × panel
let px = kvardi::Lp(1.0).to_px(&scale);                     // a 1-lp hairline at 1.5 is 2 px, every frame
let rect = glitnir::geom::Rect::at(x, y, w, px);            // Glitnir takes Px, never Lp
```

**Four levels of zoom, and the display's own scale.** `Scale { output, app, window, pane, panel }` and
`Scale::effective()` is their product. Each zoom is kept between `MIN_ZOOM` and `MAX_ZOOM`.

**Several displays.** Each display has its own output scale (mixed DPI is the normal case).
- A window takes the scale of the display that holds most of it (the lowest id on a tie), and lays out once when it
  crosses to another (`Window::layouts`). Moving about on one display lays out nothing.
- A pane's or panel's own zoom is the window's, and it is kept across the move.
- The window's zoom is remembered per display and per window preset, so a window that returns to a display has that
  display's zoom again.

**Enforced by:** the scan rule `no-raw-scale-mul` (a `*` or `*=` with a value named `…scale…` on either side, through
casts, references and parentheses, anywhere but `kvardi`); the layer rows that keep the view crates (`sja`, `smidja`) off
`glitnir`; and a compile-fail test (`trybuild`) that a logical length does not reach Glitnir. Owner: `kvardi`.
Conformance: `crates/std/kvardi/tests/conformance.rs`.

**Why.** Two roundings of one length (floor in one place, round in another) make a hairline flicker between 1 and 2 px,
and make two panes disagree about where an edge is.
