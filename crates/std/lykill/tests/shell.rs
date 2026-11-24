//! The edge: skel's raw key event becomes a lykill `KeyEvent`.

use lykill::{KeyCode, KeyEvent, Named};
use skel::event::{KeyEv, NHSHELL_MOD_ALT, NHSHELL_MOD_CTRL, NHSHELL_MOD_SHIFT, NHSHELL_MOD_SUPER};

fn press(keysym: u32, mods: u32) -> KeyEv {
    KeyEv {
        keysym,
        mods,
        pressed: 1,
        ..KeyEv::default()
    }
}

#[test]
fn a_character_is_itself_with_the_case_it_produced() {
    assert_eq!(
        KeyEvent::from_skel(&press(0x61, 0)),
        Some(KeyEvent::ch('a'))
    );
    assert_eq!(
        KeyEvent::from_skel(&press(0x41, NHSHELL_MOD_SHIFT)),
        Some(KeyEvent::ch('A')),
        "shift is in the character"
    );
    assert_eq!(
        KeyEvent::from_skel(&press(0x20, 0)),
        Some(KeyEvent::ch(' '))
    );
    assert_eq!(
        KeyEvent::from_skel(&press(0x0100_0000 + 0x00e9, 0)),
        Some(KeyEvent::ch('é'))
    );
}

#[test]
fn modifiers_match_the_chord_text() {
    let ctrl_x = KeyEvent::from_skel(&press(0x78, NHSHELL_MOD_CTRL)).expect("a key");
    assert_eq!(ctrl_x, lykill::parse_chord("C-x").expect("chord")[0]);
    let meta_x = KeyEvent::from_skel(&press(0x78, NHSHELL_MOD_ALT)).expect("a key");
    assert_eq!(meta_x, lykill::parse_chord("M-x").expect("chord")[0]);
    let cs_a =
        KeyEvent::from_skel(&press(0x41, NHSHELL_MOD_CTRL | NHSHELL_MOD_SHIFT)).expect("a key");
    assert_eq!(cs_a, lykill::parse_chord("C-S-a").expect("chord")[0]);
    let s_k = KeyEvent::from_skel(&press(0x6b, NHSHELL_MOD_SUPER)).expect("a key");
    assert_eq!(s_k, lykill::parse_chord("s-k").expect("chord")[0]);
}

#[test]
fn named_keys_carry_shift() {
    assert_eq!(
        KeyEvent::from_skel(&press(0xff0d, 0)).map(|k| k.key),
        Some(KeyCode::Named(Named::Enter))
    );
    let s_up = KeyEvent::from_skel(&press(0xff52, NHSHELL_MOD_SHIFT)).expect("a key");
    assert_eq!(s_up.key, KeyCode::Named(Named::Up));
    assert!(s_up.shift);
    assert_eq!(
        KeyEvent::from_skel(&press(0xffbe, 0)).map(|k| k.key),
        Some(KeyCode::Named(Named::F(1)))
    );
    assert_eq!(
        KeyEvent::from_skel(&press(0xffc9, 0)).map(|k| k.key),
        Some(KeyCode::Named(Named::F(12)))
    );
}

#[test]
fn a_release_a_modifier_alone_or_an_unknown_key_is_not_a_key() {
    let mut up = press(0x61, 0);
    up.pressed = 0;
    assert_eq!(KeyEvent::from_skel(&up), None);
    assert_eq!(
        KeyEvent::from_skel(&press(0xffe1, NHSHELL_MOD_SHIFT)),
        None,
        "Shift_L"
    );
    assert_eq!(KeyEvent::from_skel(&press(0xfe50, 0)), None, "a dead key");
}

#[test]
fn a_converted_key_resolves_in_a_keymap() {
    let mut k = lykill::Keymap::new();
    k.bind("C-x C-f", "find-file", "").expect("bound");
    let cx = lykill::KeyContext::new();
    let mut s = lykill::Session::new(std::time::Duration::from_secs(1));
    let a = KeyEvent::from_skel(&press(0x78, NHSHELL_MOD_CTRL)).expect("a key");
    let b = KeyEvent::from_skel(&press(0x66, NHSHELL_MOD_CTRL)).expect("a key");
    assert_eq!(s.feed(&k, a, &cx), lykill::Resolution::Prefix);
    assert_eq!(
        s.feed(&k, b, &cx),
        lykill::Resolution::Command("find-file".into())
    );
}
