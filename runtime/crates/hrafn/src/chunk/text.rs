//! Plain text: line windows under the budget, with no symbols.

use super::{Chunk, Header, Lines, Nws, Symbol, build_chunk};

/// Consecutive spans over `text[start..end]`, each of at most `budget` non-whitespace characters: whole lines, and
/// a line that is over the budget on its own is cut inside.
pub(super) fn windows(
    text: &str,
    nws: &Nws,
    (start, end): (usize, usize),
    budget: usize,
) -> Vec<(usize, usize)> {
    let budget = budget.max(1);
    let mut spans = Vec::new();
    let mut ws = start;
    let mut at = start;
    while at < end {
        let line_end = text[at..end].find('\n').map_or(end, |i| at + i + 1);
        if nws.count(ws, line_end) > budget {
            if at > ws {
                spans.push((ws, at));
                ws = at;
            }
            // one line over the budget: cut it
            while nws.count(ws, line_end) > budget {
                let mut n = 0;
                let mut cut = line_end;
                for (i, c) in text[ws..line_end].char_indices() {
                    if !c.is_whitespace() {
                        n += 1;
                        if n == budget {
                            cut = ws + i + c.len_utf8();
                            break;
                        }
                    }
                }
                spans.push((ws, cut));
                ws = cut;
            }
        }
        at = line_end;
    }
    if ws < end {
        spans.push((ws, end));
    }
    spans
}

pub(super) fn chunk(
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> (Vec<Chunk>, Vec<Symbol>) {
    if text.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let nws = Nws::new(text);
    let lines = Lines::new(text);
    let header = Header {
        path,
        title: None,
        section: None,
        defs: Vec::new(),
        docs: Vec::new(),
        part: None,
    };
    let chunks = windows(text, &nws, (0, text.len()), budget)
        .into_iter()
        .map(|span| {
            let embed = !generated && nws.count(span.0, span.1) > 0;
            build_chunk(text, &lines, span, &header, None, embed)
        })
        .collect();
    (chunks, Vec::new())
}
