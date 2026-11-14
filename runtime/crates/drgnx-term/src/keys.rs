//! The editor's key names to libghostty-vt's keys (W3C codes). Emacs sends presses only, with no physical key codes,
//! so a printable key is named by its character on a US layout; anything the table lacks goes as unidentified with its
//! text, which the encoder sends as it is.

/// A key's `GhosttyKey` code (key/event.h's enum; the values are fixed across 1.x).
pub type KeyCode = i32;

const DIGIT_0: KeyCode = 6;
const A: KeyCode = 20;
const F1: KeyCode = 121;

/// The code of the named key NAME (`"a"`, `"return"`, `"f5"`, ...), and the codepoint the key gives without shift (0
/// for a key that gives none). Unknown names give `(0, 0)`: unidentified.
pub fn code(name: &str) -> (KeyCode, u32) {
    let mut chars = name.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        return printable(c);
    }
    let named = match name {
        "return" | "enter" | "RET" => 58,
        "tab" | "TAB" => 64,
        "backspace" | "DEL" => 53,
        "escape" | "ESC" => 120,
        "space" | "SPC" => return (63, ' ' as u32),
        "delete" | "deletechar" => 68,
        "insert" => 72,
        "home" => 71,
        "end" => 69,
        "prior" | "page-up" => 74,
        "next" | "page-down" => 73,
        "up" => 78,
        "down" => 75,
        "left" => 76,
        "right" => 77,
        _ => {
            if let Some(n) = name.strip_prefix('f').and_then(|n| n.parse::<i32>().ok())
                && (1..=25).contains(&n)
            {
                F1 + n - 1
            } else {
                0
            }
        }
    };
    (named, 0)
}

/// A printable character's key on a US layout, and its unshifted codepoint (shifted symbols name their base key).
fn printable(c: char) -> (KeyCode, u32) {
    let lower = c.to_ascii_lowercase();
    let key = match lower {
        'a'..='z' => A + (lower as i32 - 'a' as i32),
        '0'..='9' => DIGIT_0 + (lower as i32 - '0' as i32),
        _ => match US_SHIFTED.iter().find(|(s, _)| *s == c) {
            Some((_, base)) => return printable(*base),
            None => symbol(c),
        },
    };
    if key == 0 {
        return (0, 0);
    }
    (key, lower as u32)
}

fn symbol(c: char) -> KeyCode {
    match c {
        '`' => 1,
        '\\' => 2,
        '[' => 3,
        ']' => 4,
        ',' => 5,
        '=' => 16,
        '-' => 46,
        '.' => 47,
        '\'' => 48,
        ';' => 49,
        '/' => 50,
        ' ' => 63,
        _ => 0,
    }
}

/// Shifted symbols of a US layout and the key that gives them.
const US_SHIFTED: [(char, char); 21] = [
    ('~', '`'),
    ('!', '1'),
    ('@', '2'),
    ('#', '3'),
    ('$', '4'),
    ('%', '5'),
    ('^', '6'),
    ('&', '7'),
    ('*', '8'),
    ('(', '9'),
    (')', '0'),
    ('_', '-'),
    ('+', '='),
    ('{', '['),
    ('}', ']'),
    ('|', '\\'),
    (':', ';'),
    ('"', '\''),
    ('<', ','),
    ('>', '.'),
    ('?', '/'),
];

/// Modifier names (`"ctrl"`, `"shift"`, `"alt"`/`"meta"`, `"super"`) to `GhosttyMods` bits.
pub fn mods(names: &[String]) -> u16 {
    names.iter().fold(0, |m, n| {
        m | match n.as_str() {
            "shift" => 1,
            "ctrl" | "control" => 2,
            "alt" | "meta" => 4,
            "super" => 8,
            _ => 0,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_map_to_w3c_codes() {
        assert_eq!(code("a"), (20, 'a' as u32));
        assert_eq!(code("Z"), (45, 'z' as u32));
        assert_eq!(code("7"), (13, '7' as u32));
        assert_eq!(code("?"), (50, '/' as u32));
        assert_eq!(code("return"), (58, 0));
        assert_eq!(code("f12"), (132, 0));
        assert_eq!(code("é"), (0, 0));
        assert_eq!(mods(&["ctrl".into(), "shift".into()]), 3);
    }
}
