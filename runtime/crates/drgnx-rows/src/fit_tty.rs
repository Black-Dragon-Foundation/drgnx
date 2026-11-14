//! Fitting text to terminal columns: Unicode's widths (`unicode-width`), overridden by the editor's
//! `char-width-table` (`view/env`'s `tty_widths`, `[from, to, width]` ranges).

use unicode_width::UnicodeWidthChar;

/// CH's columns: the editor's table first, else Unicode's (a control char takes none).
pub fn char_width(ch: char, table: &[(u32, u32, u8)]) -> usize {
    let c = u32::from(ch);
    if let Some((_, _, w)) = table
        .iter()
        .find(|(from, to, _)| (*from..=*to).contains(&c))
    {
        return usize::from(*w);
    }
    ch.width().unwrap_or(0)
}

/// TEXT's columns.
pub fn width(text: &str, table: &[(u32, u32, u8)]) -> usize {
    text.chars().map(|c| char_width(c, table)).sum()
}

/// TEXT fitted to COLS columns: whole when it fits, else cut with an ellipsis (one column).
pub fn fit(text: &str, cols: usize, table: &[(u32, u32, u8)]) -> String {
    if width(text, table) <= cols {
        return text.to_owned();
    }
    let room = cols.saturating_sub(1);
    let mut used = 0;
    let mut out = String::new();
    for c in text.chars() {
        let w = char_width(c, table);
        if used + w > room {
            break;
        }
        used += w;
        out.push(c);
    }
    out.push(crate::fit::ELLIPSIS);
    out
}
