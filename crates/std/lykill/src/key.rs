//! Keys and chords as text: the Emacs spelling (`C-x C-f`, `M-x`, `<f5>`, `RET`) and the VS Code one (`ctrl+p`,
//! `ctrl+shift+p`, `ctrl+k ctrl+s`). Both give the same [`KeyEvent`]s.

/// A key that has a name, not a character.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Named {
    Enter,
    Tab,
    Escape,
    Backspace,
    Delete,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    /// F1 to F24
    F(u8),
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum KeyCode {
    Char(char),
    Named(Named),
}

/// A key press with its modifiers: what the engine matches. (The shell's raw events are turned into these once, at the
/// edge; nothing else reads them: the `no-raw-key-event` scan rule.)
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct KeyEvent {
    pub key: KeyCode,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    /// The super key (Command, Windows)
    pub sup: bool,
}

impl KeyEvent {
    pub fn plain(key: KeyCode) -> KeyEvent {
        KeyEvent {
            key,
            ctrl: false,
            alt: false,
            shift: false,
            sup: false,
        }
    }

    pub fn ch(c: char) -> KeyEvent {
        KeyEvent::plain(KeyCode::Char(c))
    }

    pub fn ctrl(c: char) -> KeyEvent {
        KeyEvent {
            ctrl: true,
            ..KeyEvent::ch(c)
        }
    }
}

fn named(name: &str) -> Option<Named> {
    Some(match name.to_ascii_lowercase().as_str() {
        "ret" | "return" | "enter" => Named::Enter,
        "tab" => Named::Tab,
        "esc" | "escape" => Named::Escape,
        "del" | "delete" => Named::Delete,
        "backspace" => Named::Backspace,
        "up" => Named::Up,
        "down" => Named::Down,
        "left" => Named::Left,
        "right" => Named::Right,
        "home" => Named::Home,
        "end" => Named::End,
        "pageup" | "prior" => Named::PageUp,
        "pagedown" | "next" => Named::PageDown,
        f if f.starts_with('f') => match f[1..].parse::<u8>() {
            Ok(n) if (1..=24).contains(&n) => Named::F(n),
            _ => return None,
        },
        _ => return None,
    })
}

fn key_of(name: &str) -> Option<KeyCode> {
    let name = name.trim_start_matches('<').trim_end_matches('>');
    if name.eq_ignore_ascii_case("spc") || name.eq_ignore_ascii_case("space") {
        return Some(KeyCode::Char(' '));
    }
    let mut cs = name.chars();
    match (cs.next(), cs.next()) {
        (Some(c), None) => Some(KeyCode::Char(c)),
        _ => named(name).map(KeyCode::Named),
    }
}

fn bad(text: &str, why: &str) -> villa::Error {
    villa::Error::invalid(format!("`{text}` is not a key: {why}."))
}

fn emacs(tok: &str) -> villa::Result<KeyEvent> {
    let mut ev = KeyEvent::ch(' ');
    let mut rest = tok;
    // modifiers: `C-`, `M-`, `S-`, `s-`; a lone `-` or `C--` is the minus key
    while rest.len() > 2 && rest.as_bytes()[1] == b'-' {
        match rest.as_bytes()[0] {
            b'C' => ev.ctrl = true,
            b'M' => ev.alt = true,
            b'S' => ev.shift = true,
            b's' => ev.sup = true,
            _ => break,
        }
        rest = &rest[2..];
    }
    ev.key = key_of(rest).ok_or_else(|| bad(tok, "unknown key"))?;
    Ok(ev)
}

fn vscode(tok: &str) -> villa::Result<KeyEvent> {
    let mut ev = KeyEvent::ch(' ');
    let parts: Vec<&str> = tok.split('+').collect();
    let (last, mods) = parts.split_last().ok_or_else(|| bad(tok, "empty"))?;
    for m in mods {
        match m.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => ev.ctrl = true,
            "alt" | "option" => ev.alt = true,
            "shift" => ev.shift = true,
            "meta" | "cmd" | "command" | "win" | "super" => ev.sup = true,
            _ => return Err(bad(tok, "unknown modifier")),
        }
    }
    ev.key = key_of(last).ok_or_else(|| bad(tok, "unknown key"))?;
    Ok(ev)
}

/// A chord: keys separated by spaces, each spelled either way.
pub fn parse_chord(text: &str) -> villa::Result<Vec<KeyEvent>> {
    let mut out = Vec::new();
    for tok in text.split_whitespace() {
        out.push(
            if tok.len() > 1 && tok.contains('+') && !tok.ends_with('+') {
                vscode(tok)?
            } else {
                emacs(tok)?
            },
        );
    }
    if out.is_empty() {
        return Err(bad(text, "no keys"));
    }
    Ok(out)
}
