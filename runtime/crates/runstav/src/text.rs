//! User-visible text through one sanitizer (contract Task 13; design §6.2 rule 8).

use std::ops::RangeInclusive;

/// The control characters: C0, DEL, C1, U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069, U+2028, U+2029
/// (`drgnx-coord-control-chars`, the contract's `drgnx-text-control-chars`).
pub const CONTROL: &[RangeInclusive<char>] = &[
    '\u{0}'..='\u{1f}',
    '\u{7f}'..='\u{9f}',
    '\u{61c}'..='\u{61c}',
    '\u{200e}'..='\u{200f}',
    '\u{2028}'..='\u{2029}',
    '\u{202a}'..='\u{202e}',
    '\u{2066}'..='\u{2069}',
];

fn is_control(c: char) -> bool {
    CONTROL.iter().any(|r| r.contains(&c))
}

/// At most MAX characters of S; when S is longer, the last of them is `…`.
fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    if max > 0 {
        out.push('…');
    }
    out
}

/// Every run of [`CONTROL`] characters and of `\n\r\t` becomes one space; trimmed; cut at MAX characters with `…`.
/// HEADER also turns `]` and `#` into spaces (`drgnx-coord-message-prompt`).
pub fn one_line(text: &str, max: usize, header: bool) -> String {
    let mut out = String::with_capacity(text.len());
    let mut gap = false;
    for c in text.chars() {
        if is_control(c) || matches!(c, '\n' | '\r' | '\t') || (header && matches!(c, ']' | '#')) {
            gap = true;
            continue;
        }
        if gap && !out.is_empty() {
            out.push(' ');
        }
        gap = false;
        out.push(c);
    }
    clip(&out, max)
}

/// Each [`CONTROL`] character becomes a space (no merging, no trim); cut at MAX characters, no `…`.  The event
/// summary and card title rule (`drgnx-coord--one-line`): the store holds what the Lisp writer would.
pub fn coord_line(text: &str, max: usize) -> String {
    text.chars()
        .map(|c| if is_control(c) { ' ' } else { c })
        .take(max)
        .collect()
}

/// Control characters other than `\n` and `\t` replaced (by a space), trimmed, cut at MAX characters
/// (`drgnx-coord-mcp--text-cut`).  The flag says whether it was cut.
pub fn cut(text: &str, max: usize) -> (String, bool) {
    let clean: String = text
        .chars()
        .map(|c| {
            if is_control(c) && !matches!(c, '\n' | '\t') {
                ' '
            } else {
                c
            }
        })
        .collect();
    let clean = clean.trim();
    if clean.chars().count() > max {
        (clean.chars().take(max).collect(), true)
    } else {
        (clean.to_string(), false)
    }
}

/// "outside agent (unverified) KIND" for `ext:KIND:…`, else NAME or ID.
pub fn agent_label(id: &str, name: Option<&str>) -> String {
    if let Some(rest) = id.strip_prefix("ext:") {
        let kind = rest.split(':').next().unwrap_or("");
        return format!("outside agent (unverified) {kind}");
    }
    name.filter(|n| !n.is_empty()).unwrap_or(id).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn the_set_is_the_contracts() {
        let mut expected: Vec<char> = Vec::new();
        expected.extend('\u{0}'..='\u{1f}');
        expected.extend('\u{7f}'..='\u{9f}');
        expected.extend(['\u{61c}', '\u{200e}', '\u{200f}', '\u{2028}', '\u{2029}']);
        expected.extend('\u{202a}'..='\u{202e}');
        expected.extend('\u{2066}'..='\u{2069}');
        for c in &expected {
            assert!(is_control(*c), "{:x}", *c as u32);
        }
        let total: usize = CONTROL.iter().map(|r| r.clone().count()).sum();
        assert_eq!(total, expected.len());
        for c in [
            'a', ' ', '~', '\u{a0}', '\u{200d}', '\u{2027}', '\u{202f}', '\u{2065}', '\u{206a}',
        ] {
            assert!(!is_control(c), "{:x}", c as u32);
        }
    }

    #[test]
    fn bidi_overrides_are_stripped() {
        assert_eq!(one_line("a\u{202e}b\u{2066}\u{2069}c", 50, false), "a b c");
        // a run becomes one space; a real space beside it stays (Lisp: `[CONTROL]+` → " ")
        assert_eq!(one_line("x\r\n\t y\u{2028}z", 50, false), "x  y z");
        assert_eq!(coord_line("a\u{202e}\u{202e}b\nc", 50), "a  b c");
        assert_eq!(coord_line(&"x".repeat(300), 200), "x".repeat(200));
        let (t, cut_off) = cut("a\u{202e}b\nc\td\u{7}", 50);
        assert_eq!((t.as_str(), cut_off), ("a b\nc\td", false));
    }

    #[test]
    fn header_drops_brackets_and_hash() {
        // each `]` and `#` is a space and `[` stays, as `drgnx-coord-message-prompt` writes the sender
        assert_eq!(one_line("[esc] #1 hi", 50, true), "[esc   1 hi");
        assert_eq!(one_line("[esc] #1 hi", 50, false), "[esc] #1 hi");
    }

    #[test]
    fn cuts_by_characters_with_an_ellipsis() {
        assert_eq!(one_line("ééééé", 5, false), "ééééé");
        assert_eq!(one_line("éééééé", 5, false), "éééé…");
        assert_eq!(cut("日本語日本語", 3), ("日本語".to_string(), true));
        assert_eq!(cut("abc", 3), ("abc".to_string(), false));
    }

    #[test]
    fn labels() {
        assert_eq!(
            agent_label("ext:claude:123-ab", Some("x")),
            "outside agent (unverified) claude"
        );
        assert_eq!(agent_label("a1", Some("Ann")), "Ann");
        assert_eq!(agent_label("a1", None), "a1");
    }

    proptest! {
        #[test]
        fn one_line_never_returns_a_control_char_or_newline(s in any::<String>(), max in 0usize..40, header in any::<bool>()) {
            let out = one_line(&s, max, header);
            prop_assert!(out.chars().all(|c| !is_control(c) && !matches!(c, '\n' | '\r' | '\t')));
            prop_assert!(out.chars().count() <= max);
        }
    }
}
