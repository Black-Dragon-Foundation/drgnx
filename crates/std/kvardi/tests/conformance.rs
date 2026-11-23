//! The scale-zoom standard's conformance test: four zoom levels on a display's scale, one rounding rule, a scale per
//! display (docs/develop/standards/scale-zoom.md).

use kvardi::{DisplayId, Lp, MAX_ZOOM, MIN_ZOOM, Px, Rect, Scale, Screens, Window, clamp_zoom};

fn two_displays() -> Screens {
    // a 1.0 display on the left and a 1.5 display on the right, side by side
    let mut s = Screens::new();
    s.set_display(DisplayId(1), Rect::new(0, 0, 1920, 1080), 1.0);
    s.set_display(DisplayId(2), Rect::new(1920, 0, 2880, 1620), 1.5);
    s
}

#[test]
fn four_level_zoom_multiplies() {
    let s = Scale {
        output: 1.5,
        app: 1.25,
        window: 2.0,
        pane: 0.5,
        panel: 2.0,
    };
    assert!((s.effective() - 1.5 * 1.25 * 2.0 * 0.5 * 2.0).abs() < 1e-6);
    // each level counts: change one and the product follows
    for (name, with) in [
        (
            "output",
            Scale {
                output: 2.0,
                ..Scale::default()
            },
        ),
        (
            "app",
            Scale {
                app: 2.0,
                ..Scale::default()
            },
        ),
        (
            "window",
            Scale {
                window: 2.0,
                ..Scale::default()
            },
        ),
        (
            "pane",
            Scale {
                pane: 2.0,
                ..Scale::default()
            },
        ),
        (
            "panel",
            Scale {
                panel: 2.0,
                ..Scale::default()
            },
        ),
    ] {
        assert_eq!(Lp(10.0).to_px(&with), Px(20), "{name}");
    }
    assert_eq!(Scale::default().effective(), 1.0);
}

#[test]
fn rounding_is_stable_at_1_5() {
    let s = Scale {
        output: 1.5,
        ..Scale::default()
    };
    // a 1-lp hairline at 1.5 is 2 px, the same every frame
    for _ in 0..1000 {
        assert_eq!(Lp(1.0).to_px(&s), Px(2));
    }
    // half away from zero, both ways
    assert_eq!(Lp(3.0).to_px(&s), Px(5), "4.5");
    assert_eq!(Lp(-1.0).to_px(&s), Px(-2), "-1.5");
    assert_eq!(Lp(-3.0).to_px(&s), Px(-5), "-4.5");
    assert_eq!(Lp(0.2).to_px(&s), Px(0), "0.3");
}

#[test]
fn a_window_moving_to_another_display_takes_its_scale() {
    let screens = two_displays();
    let mut w = Window::new("main", Rect::new(100, 100, 800, 600));
    screens.place(&mut w, Rect::new(100, 100, 800, 600));
    assert_eq!(w.display(), Some(DisplayId(1)));
    let hair = |w: &Window| Lp(1.0).to_px(&screens.scale(w, None, None));
    assert_eq!(hair(&w), Px(1));
    assert_eq!(w.layouts(), 1, "the first placement lays out");
    // dragged over to the 1.5 display: it lays out once, and a hairline is 2 px
    screens.place(&mut w, Rect::new(2100, 100, 800, 600));
    assert_eq!(w.display(), Some(DisplayId(2)));
    assert_eq!(hair(&w), Px(2));
    assert_eq!(w.layouts(), 2);
    // moving about on the same display lays out nothing more
    screens.place(&mut w, Rect::new(2200, 150, 800, 600));
    screens.place(&mut w, Rect::new(2300, 150, 700, 500));
    assert_eq!(w.layouts(), 2);
}

#[test]
fn pane_zoom_survives_a_display_change() {
    let mut screens = two_displays();
    let mut w = Window::new("main", Rect::new(100, 100, 800, 600));
    screens.place(&mut w, Rect::new(100, 100, 800, 600));
    w.set_pane_zoom("editor", 1.25);
    w.set_panel_zoom("agents", 0.8);
    screens.set_app_zoom(1.1);
    let before = screens.scale(&w, Some("editor"), Some("agents"));
    screens.place(&mut w, Rect::new(2100, 100, 800, 600));
    let after = screens.scale(&w, Some("editor"), Some("agents"));
    assert_eq!((before.output, after.output), (1.0, 1.5));
    assert_eq!((after.pane, after.panel, after.app), (1.25, 0.8, 1.1));
    // a pane with no zoom of its own is not affected by another's
    assert_eq!(screens.scale(&w, Some("terminal"), None).pane, 1.0);
}

#[test]
fn zoom_is_remembered_per_display() {
    let mut screens = two_displays();
    let mut w = Window::new("main", Rect::new(100, 100, 800, 600));
    screens.place(&mut w, Rect::new(100, 100, 800, 600));
    screens.set_window_zoom(&w, 1.2);
    screens.place(&mut w, Rect::new(2100, 100, 800, 600));
    assert_eq!(
        screens.scale(&w, None, None).window,
        1.0,
        "the other display has none yet"
    );
    screens.set_window_zoom(&w, 1.5);
    // back: that display's zoom comes back, and the other's is still its own
    screens.place(&mut w, Rect::new(100, 100, 800, 600));
    assert_eq!(screens.scale(&w, None, None).window, 1.2);
    screens.place(&mut w, Rect::new(2100, 100, 800, 600));
    assert_eq!(screens.scale(&w, None, None).window, 1.5);
    // a window of another preset has its own memory
    let mut other = Window::new("review", Rect::new(100, 100, 800, 600));
    screens.place(&mut other, Rect::new(100, 100, 800, 600));
    assert_eq!(screens.scale(&other, None, None).window, 1.0);
}

#[test]
fn a_window_spanning_two_displays_uses_the_one_holding_most_of_it() {
    let screens = two_displays();
    // 1000 px wide across the seam at x = 1920: 700 on the left, 300 on the right
    let mut w = Window::new("main", Rect::new(1220, 0, 1000, 600));
    screens.place(&mut w, Rect::new(1220, 0, 1000, 600));
    assert_eq!(w.display(), Some(DisplayId(1)));
    // dragged until 700 are on the right
    screens.place(&mut w, Rect::new(1920 - 300, 0, 1000, 600));
    assert_eq!(w.display(), Some(DisplayId(2)));
    // exactly half and half: the lowest id, always
    screens.place(&mut w, Rect::new(1920 - 500, 0, 1000, 600));
    assert_eq!(w.display(), Some(DisplayId(1)));
    // a window off every display keeps the one it had
    screens.place(&mut w, Rect::new(-9000, -9000, 100, 100));
    assert_eq!(w.display(), Some(DisplayId(1)));
}

#[test]
fn a_zoom_is_kept_within_bounds() {
    assert_eq!(clamp_zoom(100.0), MAX_ZOOM);
    assert_eq!(clamp_zoom(0.0), MIN_ZOOM);
    assert_eq!(clamp_zoom(f32::NAN), 1.0);
    let mut screens = two_displays();
    screens.set_app_zoom(1000.0);
    let w = Window::new("main", Rect::default());
    assert_eq!(screens.scale(&w, None, None).app, MAX_ZOOM);
}

#[test]
fn a_display_that_changes_scale_changes_the_window_on_it() {
    let mut screens = two_displays();
    let mut w = Window::new("main", Rect::new(100, 100, 800, 600));
    screens.place(&mut w, Rect::new(100, 100, 800, 600));
    screens.set_display(DisplayId(1), Rect::new(0, 0, 1920, 1080), 2.0);
    assert_eq!(Lp(1.0).to_px(&screens.scale(&w, None, None)), Px(2));
    screens.remove_display(DisplayId(1));
    screens.place(&mut w, Rect::new(2100, 100, 800, 600));
    assert_eq!(w.display(), Some(DisplayId(2)));
}

#[test]
fn a_length_between_pixels_keeps_its_fraction() {
    let s = Scale {
        output: 1.5,
        ..Scale::default()
    };
    assert_eq!(Lp(3.0).to_len(&s), 4.5);
    assert_eq!(Lp(3.0).to_px(&s), Px(5), "the pixel rule still rounds");
    let zoomed = Scale {
        output: 1.5,
        pane: 2.0,
        ..Scale::default()
    };
    assert_eq!(Lp(0.5).to_len(&zoomed), 1.5, "every zoom is in the product");
}
