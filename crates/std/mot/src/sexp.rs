//! A small reader for the kit's `.eld` data: lists, atoms, strings and numbers, with `;` comments. Shared by the
//! library and by `build.rs` (which generates the token enum from `themes/tokens.eld`), so both read the file the same way.

/// One item of a form.
#[derive(Clone, PartialEq, Debug)]
pub enum Item {
    Atom(String),
    Str(String),
    Num(f64),
    List(Vec<Item>),
}

/// Why a file could not be read.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SexpError {
    pub line: usize,
    pub message: String,
}

fn err(line: usize, message: &str) -> SexpError {
    SexpError {
        line,
        message: message.to_string(),
    }
}

/// The top-level forms of TEXT.
pub fn parse(text: &str) -> Result<Vec<Item>, SexpError> {
    let chars: Vec<char> = text.chars().collect();
    let mut at = 0;
    let mut line = 1;
    let mut stack: Vec<(Vec<Item>, usize)> = Vec::new();
    let mut out = Vec::new();
    let push = |stack: &mut Vec<(Vec<Item>, usize)>, out: &mut Vec<Item>, item: Item| match stack
        .last_mut()
    {
        Some((items, _)) => items.push(item),
        None => out.push(item),
    };
    while at < chars.len() {
        let c = chars[at];
        match c {
            '\n' => {
                line += 1;
                at += 1;
            }
            c if c.is_whitespace() => at += 1,
            ';' => {
                while at < chars.len() && chars[at] != '\n' {
                    at += 1;
                }
            }
            '(' => {
                stack.push((Vec::new(), line));
                at += 1;
            }
            ')' => {
                let (items, _) = stack.pop().ok_or_else(|| err(line, "a `)` with no `(`"))?;
                push(&mut stack, &mut out, Item::List(items));
                at += 1;
            }
            '"' => {
                let start = line;
                let mut s = String::new();
                at += 1;
                loop {
                    let Some(&d) = chars.get(at) else {
                        return Err(err(start, "a string that never ends"));
                    };
                    at += 1;
                    match d {
                        '"' => break,
                        '\\' => {
                            let Some(&e) = chars.get(at) else {
                                return Err(err(start, "a string that never ends"));
                            };
                            at += 1;
                            s.push(e);
                        }
                        '\n' => {
                            line += 1;
                            s.push('\n');
                        }
                        d => s.push(d),
                    }
                }
                push(&mut stack, &mut out, Item::Str(s));
            }
            _ => {
                let start = at;
                while at < chars.len() && !chars[at].is_whitespace() && !"();\"".contains(chars[at])
                {
                    at += 1;
                }
                let word: String = chars[start..at].iter().collect();
                let item = match word.parse::<f64>() {
                    Ok(n) if n.is_finite() => Item::Num(n),
                    _ => Item::Atom(word),
                };
                push(&mut stack, &mut out, item);
            }
        }
    }
    if let Some((_, open)) = stack.last() {
        return Err(err(*open, "a `(` that is never closed"));
    }
    Ok(out)
}
