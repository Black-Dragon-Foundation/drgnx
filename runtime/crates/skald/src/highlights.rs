//! The `highlights.scm` predicate subset (design §3.4): Emacs accepts only `eq?`, `match?` and `pred?`, so a pack may
//! use `#eq?`, `#match?` with a portable regexp, `#any-of?`, `#not-eq?` and `#not-match?`. Everything else (`#set!`,
//! `#lua-match?`, `#vim-match?`, …) is refused here, in the pack job and in the index check.

const ALLOWED: &[&str] = &["#eq?", "#match?", "#any-of?", "#not-eq?", "#not-match?"];

/// The reasons `text` is not in the subset, each starting `line N:`.
pub fn check(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut line = 1usize;
    let mut chars = text.chars().peekable();
    // the regexp string of a #match? / #not-match? still to come
    let mut want_regexp = false;
    while let Some(c) = chars.next() {
        match c {
            '\n' => line += 1,
            ';' => {
                for c in chars.by_ref() {
                    if c == '\n' {
                        line += 1;
                        break;
                    }
                }
            }
            '"' => {
                let at = line;
                let mut s = String::new();
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => match chars.next() {
                            Some('n') => s.push('\n'),
                            Some('t') => s.push('\t'),
                            Some(o) => s.push(o),
                            None => {}
                        },
                        '\n' => {
                            line += 1;
                            s.push('\n');
                        }
                        o => s.push(o),
                    }
                }
                if std::mem::take(&mut want_regexp)
                    && let Some(why) = portable_regexp(&s)
                {
                    out.push(format!(
                        "line {at}: the regexp \"{s}\" is not portable: {why}"
                    ));
                }
            }
            '#' => {
                let mut name = String::from("#");
                while let Some(&n) = chars.peek() {
                    if n.is_ascii_alphanumeric() || matches!(n, '-' | '_' | '.') {
                        name.push(n);
                        chars.next();
                    } else {
                        break;
                    }
                }
                if let Some(&n) = chars.peek()
                    && matches!(n, '?' | '!')
                {
                    name.push(n);
                    chars.next();
                }
                if ALLOWED.contains(&name.as_str()) {
                    want_regexp = matches!(name.as_str(), "#match?" | "#not-match?");
                } else {
                    want_regexp = false;
                    out.push(format!("line {line}: the predicate {name} is not in the portable subset (eq?, match?, any-of?, not-eq?, not-match?)"));
                }
            }
            ')' => want_regexp = false,
            _ => {}
        }
    }
    out
}

/// Why `re` is outside the portable subset (literals, `.`, classes, `^ $ * + ? |`, groups), or `None`.
fn portable_regexp(re: &str) -> Option<String> {
    let cs: Vec<char> = re.chars().collect();
    let (mut i, mut depth) = (0usize, 0i32);
    while i < cs.len() {
        match cs[i] {
            '\\' => match cs.get(i + 1) {
                Some(n) if n.is_ascii_alphanumeric() => {
                    return Some(format!("\\{n} differs between engines"));
                }
                Some(_) => i += 1,
                None => return Some("a trailing backslash".into()),
            },
            '(' => {
                if cs.get(i + 1) == Some(&'?') {
                    return Some("(? groups and lookaround".into());
                }
                depth += 1;
            }
            ')' => {
                depth -= 1;
                if depth < 0 {
                    return Some("an unbalanced )".into());
                }
            }
            '{' | '}' => return Some("{ intervals".into()),
            '[' => {
                if cs.get(i + 1) == Some(&':') {
                    return Some("[: POSIX classes".into());
                }
                i += 1;
                if cs.get(i) == Some(&'^') {
                    i += 1;
                }
                if cs.get(i) == Some(&']') {
                    i += 1;
                }
                while i < cs.len() && cs[i] != ']' {
                    if cs[i] == '\\' {
                        return Some("a backslash in a class".into());
                    }
                    i += 1;
                }
                if i >= cs.len() {
                    return Some("an unterminated [".into());
                }
            }
            _ => {}
        }
        i += 1;
    }
    (depth != 0).then(|| "an unbalanced (".into())
}
