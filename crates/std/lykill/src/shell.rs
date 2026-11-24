//! The edge: skel's raw key event becomes a [`KeyEvent`] here and nowhere else (`no-raw-key-event`).
//!
//! The shell hands over an X keysym and the modifier mask after the event. A printable key is its character, with the
//! case it produced: `shift` is kept only on a key that is not a character (an arrow) or when `ctrl` or `alt` is also
//! held, where the character is the plain letter (`C-S-a`), as the chord text spells it. A release, a modifier on its
//! own (`Shift_L`) and a key the engine does not know are not keys.

use skel::event::{
    KeyEv, NHSHELL_MOD_ALT, NHSHELL_MOD_CTRL, NHSHELL_MOD_META, NHSHELL_MOD_SHIFT,
    NHSHELL_MOD_SUPER,
};

use crate::{KeyCode, KeyEvent, Named};

fn named(keysym: u32) -> Option<Named> {
    Some(match keysym {
        0xff0d | 0xff8d => Named::Enter,
        0xff09 | 0xfe20 => Named::Tab,
        0xff1b => Named::Escape,
        0xff08 => Named::Backspace,
        0xffff => Named::Delete,
        0xff50 => Named::Home,
        0xff51 => Named::Left,
        0xff52 => Named::Up,
        0xff53 => Named::Right,
        0xff54 => Named::Down,
        0xff55 => Named::PageUp,
        0xff56 => Named::PageDown,
        0xff57 => Named::End,
        0xffbe..=0xffd5 => Named::F((keysym - 0xffbe + 1) as u8),
        _ => return None,
    })
}

fn character(keysym: u32) -> Option<char> {
    match keysym {
        0x20..=0x7e | 0xa0..=0xff => char::from_u32(keysym),
        0x0100_0000..=0x0110_ffff => char::from_u32(keysym - 0x0100_0000),
        _ => None,
    }
}

impl KeyEvent {
    /// The key a press of skel's raw event is; none for a release, a modifier alone or a key without a name.
    pub fn from_skel(ev: &KeyEv) -> Option<KeyEvent> {
        if ev.pressed == 0 {
            return None;
        }
        let ctrl = ev.mods & NHSHELL_MOD_CTRL != 0;
        let alt = ev.mods & (NHSHELL_MOD_ALT | NHSHELL_MOD_META) != 0;
        let sup = ev.mods & NHSHELL_MOD_SUPER != 0;
        let shift = ev.mods & NHSHELL_MOD_SHIFT != 0;
        if let Some(n) = named(ev.keysym) {
            return Some(KeyEvent {
                key: KeyCode::Named(n),
                ctrl,
                alt,
                shift,
                sup,
            });
        }
        let c = character(ev.keysym)?;
        if ctrl || alt {
            // the plain letter, with shift as a modifier: `C-S-a`
            let lower = c.to_lowercase().next().unwrap_or(c);
            let shifted = shift || lower != c;
            return Some(KeyEvent {
                key: KeyCode::Char(lower),
                ctrl,
                alt,
                shift: shifted && lower.is_alphabetic(),
                sup,
            });
        }
        Some(KeyEvent {
            key: KeyCode::Char(c),
            ctrl,
            alt,
            shift: false,
            sup,
        })
    }
}
