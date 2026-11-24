//! The theme switch (docs/develop/standards/ui-kit.md): a switch of theme is one damage event.

use std::sync::Arc;

use mot::Theme;
use serde_json::json;
use skipan::{Level, Settings, THEME_KEY, ThemeSwitch};

#[test]
fn theme_switch_redraws() {
    let settings = Arc::new(Settings::new());
    let mut sw = ThemeSwitch::new(Arc::clone(&settings), Theme::builtin()).expect("starts");
    assert_eq!(sw.current().name(), "dark");
    assert_eq!(sw.damage_events(), 0);
    // nothing changed: no redraw
    assert!(!sw.poll().expect("polls"));
    // an unrelated setting is no redraw
    settings
        .define("editor.wrap", skipan::Kind::Bool, json!(false))
        .expect("defines");
    settings
        .set("editor.wrap", json!(true), Level::User)
        .expect("sets");
    assert!(!sw.poll().expect("polls"));
    assert_eq!(sw.damage_events(), 0);
    // the switch: one damage event, and the new theme draws
    settings
        .set(THEME_KEY, json!("light"), Level::User)
        .expect("sets");
    assert!(sw.poll().expect("polls"));
    assert_eq!(sw.current().name(), "light");
    assert_eq!(sw.damage_events(), 1);
    // two changes before a poll: still one switch
    settings
        .set(THEME_KEY, json!("high-contrast"), Level::User)
        .expect("sets");
    settings
        .set(THEME_KEY, json!("dark"), Level::User)
        .expect("sets");
    assert!(sw.poll().expect("polls"));
    assert_eq!(sw.damage_events(), 2);
    // the same theme again is not a change
    settings
        .set(THEME_KEY, json!("dark"), Level::User)
        .expect("sets");
    assert!(!sw.poll().expect("polls"));
    assert_eq!(sw.damage_events(), 2);
    // a theme that does not exist is reported and the current one stays
    settings
        .set(THEME_KEY, json!("nope"), Level::User)
        .expect("sets");
    let e = sw.poll().expect_err("no such theme");
    assert_eq!(e.kind(), villa::Kind::NotFound);
    assert_eq!(sw.current().name(), "dark");
}
