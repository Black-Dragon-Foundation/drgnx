//! The notebook chunker (design §6): each cell is chunked by its language's pack and the results are put in the notebook's
//! text view ([`super::View`]): offsets and lines are the buffer's, a chunk's header and FTS path say `file.ipynb#CELL-ID`.
//! Outputs are not indexed. A file that is not a notebook has no chunks here: the caller reads it as text.

use super::{Kind, Notebook};
use crate::chunk::{Chunk, Ref, Symbol, chunk_file_refs};
use crate::files::Lang;
use std::collections::BTreeMap;

/// The pack language a notebook's language name means.
fn lang_of(name: &str) -> Lang {
    match name {
        "python" | "python3" | "ipython" => Lang::Python,
        "c++" | "cpp" => Lang::Cpp,
        "c#" | "csharp" => Lang::Csharp,
        "bash" | "sh" | "shell" => Lang::Shell,
        other => Lang::parse(other),
    }
}

/// PATH's notebook TEXT chunked cell by cell; none when TEXT is not a notebook.
pub fn chunk(
    path: &str,
    generated: bool,
    text: &str,
    budget: usize,
) -> Option<(Vec<Chunk>, Vec<Symbol>, Vec<Ref>)> {
    let mut n = 0;
    let nb = Notebook::parse(text.to_owned(), &mut || {
        n += 1;
        format!("cell-{n}")
    })
    .ok()?;
    let view = nb.view();
    let notebook_lang = nb.language().map(|l| lang_of(&l)).unwrap_or(Lang::Text);
    let (mut chunks, mut symbols) = (Vec::<Chunk>::new(), Vec::<Symbol>::new());
    let mut refs: BTreeMap<String, (u32, Vec<u32>)> = BTreeMap::new();
    for (cell, at) in nb.cells().iter().zip(&view.cells) {
        if cell.source.trim().is_empty() {
            continue;
        }
        let lang = match cell.kind {
            Kind::Code => notebook_lang,
            Kind::Markdown => Lang::Markdown,
            Kind::Raw => Lang::Text,
        };
        let vpath = format!("{path}#{}", cell.id);
        let (cs, ss, rs) = chunk_file_refs(&vpath, lang, generated, &cell.source, budget);
        let base = at.source.start as u32;
        let line0 = at.first_line - 1;
        let chunk_base = chunks.len() as u32;
        chunks.extend(cs.into_iter().map(|mut c| {
            c.start += base;
            c.end += base;
            c.line_start += line0;
            c.line_end += line0;
            c
        }));
        symbols.extend(ss.into_iter().map(|mut s| {
            s.start += base;
            s.end += base;
            s.chunk += chunk_base;
            s.line_start += line0;
            s.line_end += line0;
            s
        }));
        for r in rs {
            let e = refs.entry(r.name).or_default();
            e.0 += r.n;
            for l in r.lines {
                let l = l + line0;
                if e.1.len() < crate::chunk::REF_LINES && !e.1.contains(&l) {
                    e.1.push(l);
                }
            }
        }
    }
    let refs = refs
        .into_iter()
        .map(|(name, (n, lines))| Ref { name, n, lines })
        .collect();
    Some((chunks, symbols, refs))
}
