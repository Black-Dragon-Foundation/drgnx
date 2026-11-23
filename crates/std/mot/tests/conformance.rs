//! The ui-kit standard's conformance test: every token has a value in every theme, a theme file is checked, and a switch
//! of theme is one damage event (docs/develop/standards/ui-kit.md).

use std::sync::Arc;

use kvardi::Lp;
use mot::{Kind, Rgba, THEME_KEY, Theme, ThemeSwitch, Token};
use serde_json::json;
use skipan::{Level, Settings};

#[test]
fn every_token_has_a_value_in_every_theme() {
    let themes = Theme::builtin();
    let names: Vec<&str> = themes.iter().map(Theme::name).collect();
    assert_eq!(names, ["dark", "light", "high-contrast"]);
    assert!(Token::ALL.len() > 60);
    for t in &themes {
        for &tok in Token::ALL {
            assert!(t.has(tok), "{} has no value for {}", t.name(), tok.name());
            match tok.kind() {
                // a metric is a length: none is zero or negative
                Kind::Metric => assert!(t.metric(tok) > Lp(0.0), "{} {}", t.name(), tok.name()),
                // a colour has its own value (the theme's `has` above), read as an Rgba
                Kind::Colour => assert_eq!(t.colour(tok), t.colour(tok)),
            }
        }
    }
}

#[test]
fn the_look_is_in_the_themes() {
    let dark = &Theme::builtin()[0];
    assert_eq!(dark.colour(Token::Gap), Rgba::new(0x0a, 0x0b, 0x0d, 255));
    assert_eq!(dark.colour(Token::Accent), Rgba::new(0x7a, 0xa5, 0xff, 255));
    // the overlay is translucent: 0.90 of 255
    assert_eq!(dark.colour(Token::Overlay).a, 230);
    assert_eq!(dark.metric(Token::Row), Lp(26.0));
    assert_eq!(dark.metric(Token::RCard), Lp(10.0));
    // high contrast has no tints
    let hc = &Theme::builtin()[2];
    assert_eq!(hc.colour(Token::OkTint).a, 0);
    assert_eq!(Token::SelQuiet.name(), "sel-quiet");
}

#[test]
fn a_theme_that_is_wrong_is_refused_with_the_reason() {
    let ok = include_str!("../themes/dark.eld");
    let refused = |text: &str, why: &str| {
        let e = Theme::parse(text).expect_err(why);
        assert_eq!(e.kind(), villa::Kind::Invalid, "{why}");
        let said = format!("{} {}", e.message(), e.detail().unwrap_or(""));
        assert!(said.contains(why), "{said}");
    };
    // a token the table does not have
    refused(&ok.replace("(gap ", "(gapp "), "gapp");
    // a token left out: it is named
    refused(&ok.replace(" (row 26)\n", ""), "row");
    // a token twice
    refused(
        &ok.replace(" (row 26)\n", " (row 26)\n (row 27)\n"),
        "twice",
    );
    // a colour that is a number, a metric that is a colour
    refused(
        &ok.replace("(gap \"#0a0b0d\")", "(gap 5)"),
        "must give it as",
    );
    refused(
        &ok.replace("(row 26)", "(row \"#000000\")"),
        "must give it as a number",
    );
    // a bad colour
    refused(&ok.replace("#0a0b0d", "#0a0b0"), "not a colour");
    refused(&ok.replace("#0a0b0d", "red"), "not a colour");
    // no name, unreadable text
    refused(&ok.replace(":name \"dark\"", ""), "name");
    refused("(drgnx-theme :version 1 (gap", "never closed");
}

#[test]
fn a_theme_file_loads_from_disk() {
    let sb = raun::Sandbox::new();
    let path = sb.home().join("mine.eld");
    eitri::replace_file(&path, include_str!("../themes/light.eld").as_bytes()).expect("written");
    let t = Theme::load(&path).expect("loads");
    assert_eq!(t.name(), "light");
    assert_eq!(t.colour(Token::Editor), Rgba::new(255, 255, 255, 255));
    let e = Theme::load(&sb.home().join("none.eld")).expect_err("missing");
    assert_eq!(e.kind(), villa::Kind::Io);
}

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
