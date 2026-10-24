//! The reader: bytes to data, or a refusal at a span (Task 1; the subset is docs/develop/settings.md's table).

use std::fmt;

use crate::span::Span;
use crate::value::{Datum, Node};

/// How much a file may hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The largest file read, in bytes.
    pub max_bytes: usize,
    /// The deepest nesting of lists, vectors and `'`/`#'` forms (each is a list in the datum).
    pub max_depth: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_bytes: 1 << 20,
            max_depth: 64,
        }
    }
}

/// Why a file was not read, and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub kind: RefusalKind,
    pub span: Span,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalKind {
    /// Not valid UTF-8.
    NotUtf8,
    /// Larger than `Limits::max_bytes`.
    TooBig,
    /// Nested deeper than `Limits::max_depth`.
    TooDeep,
    /// Not well-formed: an unbalanced paren, a stray dot, …
    Syntax,
    /// A reader macro or backquote: `` ` ``, `,`, `,@`, `#s(`, `#(`, `#[`, `#&`, `#N=`, `#N#`, `#@`, `#$`, `#.`, `##`,
    /// `#_`, `#:`, `#^[`, `#!` (which Emacs reads as a skipped line), and every other `#` form but `#'`, `#x`, `#o`,
    /// `#b` and `#NrN`.
    ReaderMacro,
    /// A string Emacs reads as unibyte with a byte ≥ 0x80 (`"\xe9"`).
    Unibyte,
    /// A raw byte in a multibyte string (`"é\xe9"`).
    RawByte,
    /// An integer beyond 64 bits.
    IntRange,
    /// `\N{NAME}`: Emacs's Unicode names are not carried here (the listed divergence).
    CharName,
    /// A string, character or list the file ends inside.
    Unterminated,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "{} (bytes {}..{})",
            self.message, self.span.start, self.span.end
        )
    }
}

impl std::error::Error for Refusal {}

/// Every top-level datum in `bytes`, or the first refusal.
pub fn read_all(bytes: &[u8], limits: Limits) -> Result<Vec<Node>, Refusal> {
    within_limits(bytes, limits)?;
    let text = std::str::from_utf8(bytes).map_err(|e| {
        let start = e.valid_up_to();
        let end = start + e.error_len().unwrap_or(bytes.len() - start);
        refusal(
            RefusalKind::NotUtf8,
            start,
            end,
            "the file is not valid UTF-8",
        )
    })?;
    Reader {
        text,
        pos: 0,
        max_depth: limits.max_depth,
    }
    .read_all()
}

fn refusal(kind: RefusalKind, start: usize, end: usize, message: impl Into<String>) -> Refusal {
    Refusal {
        kind,
        span: Span { start, end },
        message: message.into(),
    }
}

/// The size limit; the depth limit is checked as lists open.
fn within_limits(bytes: &[u8], limits: Limits) -> Result<(), Refusal> {
    if bytes.len() > limits.max_bytes {
        return Err(refusal(
            RefusalKind::TooBig,
            limits.max_bytes,
            bytes.len(),
            format!("the file is larger than {} bytes", limits.max_bytes),
        ));
    }
    Ok(())
}

// Emacs's character modifier bits (lisp.h) and its raw-byte characters (character.h).
const ALT: u32 = 0x040_0000;
const SUPER: u32 = 0x080_0000;
const HYPER: u32 = 0x100_0000;
const SHIFT: u32 = 0x200_0000;
const CTL: u32 = 0x400_0000;
const META: u32 = 0x800_0000;
const MODIFIERS: u32 = ALT | SUPER | HYPER | SHIFT | CTL | META;
/// Characters above this are raw bytes 0x80–0xFF (`BYTE8_TO_CHAR`).
const MAX_5_BYTE_CHAR: u32 = 0x3F_FF7F;
const NBSP: char = '\u{a0}';

fn byte8_to_char(byte: u32) -> u32 {
    byte + 0x3F_FF00
}

fn is_byte8(c: u32) -> bool {
    c > MAX_5_BYTE_CHAR
}

/// Whitespace to `read`: every control character, space and no-break space.
fn is_space(c: char) -> bool {
    c <= ' ' || c == NBSP
}

/// A character that ends a symbol or number (lread.c `read0`).
fn ends_symbol(c: char) -> bool {
    is_space(c)
        || matches!(
            c,
            '"' | '\'' | ';' | '#' | '(' | ')' | '[' | ']' | '`' | ','
        )
}

/// One open list, vector or `'`/`#'` while its elements are read.
enum Frame {
    List {
        start: usize,
        items: Vec<Node>,
        tail: Tail,
    },
    Vector {
        start: usize,
        items: Vec<Node>,
    },
    Quote {
        start: usize,
        head: &'static str,
        head_end: usize,
    },
}

/// A list's dotted tail: none yet, a `.` read (the tail comes next), or read (only `)` may follow).
enum Tail {
    None,
    Dot,
    Read(Box<Node>),
}

/// What a `#` form gives.
enum Hash {
    Datum(Node),
    /// `#'`: `(function X)` around the next datum.
    Function,
}

struct Reader<'a> {
    text: &'a str,
    pos: usize,
    max_depth: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<char> {
        self.text[self.pos..].chars().next()
    }

    fn advance(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += c.len_utf8();
        Some(c)
    }

    fn eat(&mut self, c: char) -> bool {
        let found = self.peek() == Some(c);
        if found {
            self.pos += c.len_utf8();
        }
        found
    }

    fn syntax(&self, start: usize, message: impl Into<String>) -> Refusal {
        refusal(RefusalKind::Syntax, start, self.pos.max(start), message)
    }

    /// The file ends inside the literal or list at `start`.
    fn unterminated(&self, start: usize, what: &str) -> Refusal {
        refusal(
            RefusalKind::Unterminated,
            start,
            self.text.len(),
            format!("the file ends inside {what}"),
        )
    }

    fn skip_space_and_comments(&mut self) {
        while let Some(c) = self.peek() {
            if is_space(c) {
                self.pos += c.len_utf8();
            } else if c == ';' {
                self.skip_line();
            } else {
                break;
            }
        }
    }

    fn skip_line(&mut self) {
        match self.text[self.pos..].find('\n') {
            Some(i) => self.pos += i + 1,
            None => self.pos = self.text.len(),
        }
    }

    /// The reader proper: an explicit stack, so nesting costs no recursion.
    fn read_all(mut self) -> Result<Vec<Node>, Refusal> {
        let mut out = Vec::new();
        let mut stack: Vec<Frame> = Vec::new();
        loop {
            self.skip_space_and_comments();
            let start = self.pos;
            let Some(c) = self.peek() else {
                return match stack.last() {
                    None => Ok(out),
                    Some(Frame::Quote { start, .. }) => {
                        Err(self.unterminated(*start, "a quoted datum"))
                    }
                    Some(Frame::Vector { start, .. }) => Err(self.unterminated(*start, "a vector")),
                    Some(Frame::List { start, .. }) => Err(self.unterminated(*start, "a list")),
                };
            };
            if let Some(Frame::List {
                tail: Tail::Read(_),
                ..
            }) = stack.last()
                && c != ')'
            {
                return Err(
                    self.syntax(start, "a dotted list must end after its tail: `)` expected")
                );
            }
            let node = match c {
                '(' | '[' | '\'' => {
                    self.open(&stack, start)?;
                    self.pos += 1;
                    stack.push(match c {
                        '(' => Frame::List {
                            start,
                            items: Vec::new(),
                            tail: Tail::None,
                        },
                        '[' => Frame::Vector {
                            start,
                            items: Vec::new(),
                        },
                        _ => Frame::Quote {
                            start,
                            head: "quote",
                            head_end: self.pos,
                        },
                    });
                    continue;
                }
                ')' => {
                    self.pos += 1;
                    match stack.pop() {
                        Some(Frame::List {
                            start: s,
                            items,
                            tail,
                        }) if !matches!(tail, Tail::Dot) => close_list(s, self.pos, items, tail),
                        _ => return Err(self.syntax(start, "`)` closes nothing open here")),
                    }
                }
                ']' => {
                    self.pos += 1;
                    match stack.pop() {
                        Some(Frame::Vector { start: s, items }) => Node {
                            datum: Datum::Vec(items),
                            span: Span {
                                start: s,
                                end: self.pos,
                            },
                        },
                        _ => return Err(self.syntax(start, "`]` closes nothing open here")),
                    }
                }
                '#' | '`' | ',' => match self.reader_macro(start)? {
                    Hash::Datum(node) => node,
                    Hash::Function => {
                        self.open(&stack, start)?;
                        stack.push(Frame::Quote {
                            start,
                            head: "function",
                            head_end: self.pos,
                        });
                        continue;
                    }
                },
                '"' => self.string_literal()?,
                '?' => self.char_literal()?,
                '.' if self.dot_token() => {
                    self.pos += 1;
                    match stack.last_mut() {
                        Some(Frame::List { items, tail, .. })
                            if !items.is_empty() && matches!(tail, Tail::None) =>
                        {
                            *tail = Tail::Dot;
                            continue;
                        }
                        _ => return Err(self.syntax(start, "a `.` outside a dotted list")),
                    }
                }
                _ => self.symbol_or_number()?,
            };
            // A datum is read: it goes into the open list or vector, or closes the `'` around it.
            let mut node = node;
            loop {
                match stack.pop() {
                    None => out.push(node),
                    Some(Frame::List {
                        start,
                        mut items,
                        tail,
                    }) => {
                        let tail = match tail {
                            Tail::None => {
                                items.push(node);
                                Tail::None
                            }
                            // Only `)` is read after a tail (checked above), so this is `Tail::Dot`.
                            _ => Tail::Read(Box::new(node)),
                        };
                        stack.push(Frame::List { start, items, tail });
                    }
                    Some(Frame::Vector { start, mut items }) => {
                        items.push(node);
                        stack.push(Frame::Vector { start, items });
                    }
                    Some(Frame::Quote {
                        start,
                        head,
                        head_end,
                    }) => {
                        let end = node.span.end;
                        let head = Node {
                            datum: Datum::Sym(head.to_owned()),
                            span: Span {
                                start,
                                end: head_end,
                            },
                        };
                        node = Node {
                            datum: Datum::List(vec![head, node]),
                            span: Span { start, end },
                        };
                        continue;
                    }
                }
                break;
            }
        }
    }

    /// One more level of nesting at `start`, or `TooDeep`.
    fn open(&self, stack: &[Frame], start: usize) -> Result<(), Refusal> {
        if stack.len() >= self.max_depth {
            return Err(refusal(
                RefusalKind::TooDeep,
                start,
                start + 1,
                format!("nested deeper than {} levels", self.max_depth),
            ));
        }
        Ok(())
    }

    /// A `.` at `self.pos` is the dot of a dotted pair when what follows could not continue a symbol (lread.c).
    fn dot_token(&self) -> bool {
        match self.text[self.pos + 1..].chars().next() {
            None => true,
            Some(c) => {
                is_space(c) || matches!(c, '"' | '\'' | ';' | '(' | '[' | '#' | '?' | '`' | ',')
            }
        }
    }

    /// `#…`, `` ` ``, `,` and `,@`: the radix integers and `#'` are data; every other form, `#!` included, is
    /// refused with its token's span.
    fn reader_macro(&mut self, start: usize) -> Result<Hash, Refusal> {
        match self.advance() {
            Some('`') => return Err(self.macro_refusal(start, "backquote")),
            Some(',') => {
                let what = if self.eat('@') { "`,@`" } else { "`,`" };
                return Err(self.macro_refusal(start, what));
            }
            _ => {}
        }
        let Some(c) = self.advance() else {
            return Err(self.syntax(start, "`#` at the end of the file"));
        };
        match c {
            '\'' => Ok(Hash::Function),
            'x' | 'X' => self.radix_integer(start, 16).map(Hash::Datum),
            'o' | 'O' => self.radix_integer(start, 8).map(Hash::Datum),
            'b' | 'B' => self.radix_integer(start, 2).map(Hash::Datum),
            '0'..='9' => {
                let mut n = u64::from(c as u8 - b'0');
                while let Some(d) = self.peek().and_then(|d| d.to_digit(10)) {
                    self.pos += 1;
                    n = n.saturating_mul(10).saturating_add(u64::from(d));
                }
                match self.advance() {
                    Some('r' | 'R') if (2..=36).contains(&n) => {
                        self.radix_integer(start, n as u32).map(Hash::Datum)
                    }
                    Some('r' | 'R') => Err(self.syntax(start, format!("radix {n} is not 2 to 36"))),
                    Some('=') => Err(self.macro_refusal(start, "`#N=` (shared structure)")),
                    Some('#') => Err(self.macro_refusal(start, "`#N#` (shared structure)")),
                    _ => Err(self.syntax(start, "`#` and digits not followed by `r`")),
                }
            }
            's' => {
                self.eat('(');
                Err(self.macro_refusal(start, "`#s(` (a record or hash table)"))
            }
            '^' => {
                self.eat('^');
                self.eat('[');
                Err(self.macro_refusal(start, "`#^[` (a char-table)"))
            }
            _ => Err(self.macro_refusal(start, &format!("`#{c}`"))),
        }
    }

    fn macro_refusal(&self, start: usize, what: &str) -> Refusal {
        refusal(
            RefusalKind::ReaderMacro,
            start,
            self.pos,
            format!("{what} is code or an object, not data"),
        )
    }

    /// The digits of `#xN`, `#oN`, `#bN` or `#RrN` after the prefix (lread.c `read_integer`): an optional sign,
    /// then letters and digits, every one below the radix. Nothing needs to follow (`#x10.5` is 16 and 0.5).
    fn radix_integer(&mut self, start: usize, radix: u32) -> Result<Node, Refusal> {
        let negative = self.peek() == Some('-');
        if matches!(self.peek(), Some('-' | '+')) {
            self.pos += 1;
        }
        let mut valid = None;
        let mut value: u128 = 0;
        while let Some(c) = self.peek().filter(char::is_ascii_alphanumeric) {
            self.pos += 1;
            let digit = c.to_digit(36).unwrap_or(36);
            if digit >= radix {
                valid = Some(false);
            } else if valid.is_none() {
                valid = Some(true);
            }
            value = value
                .saturating_mul(u128::from(radix))
                .saturating_add(u128::from(digit));
        }
        if valid != Some(true) {
            return Err(self.syntax(start, format!("not an integer in radix {radix}")));
        }
        self.int_node(start, negative, value)
    }

    fn int_node(&self, start: usize, negative: bool, magnitude: u128) -> Result<Node, Refusal> {
        let value = if negative {
            0i128.checked_sub_unsigned(magnitude)
        } else {
            i128::try_from(magnitude).ok()
        };
        match value.and_then(|v| i64::try_from(v).ok()) {
            Some(i) => Ok(Node {
                datum: Datum::Int(i),
                span: Span {
                    start,
                    end: self.pos,
                },
            }),
            None => Err(refusal(
                RefusalKind::IntRange,
                start,
                self.pos,
                "an integer beyond 64 bits",
            )),
        }
    }

    /// A symbol, or a number when the whole unescaped token has number syntax (lread.c `read0`).
    fn symbol_or_number(&mut self) -> Result<Node, Refusal> {
        let start = self.pos;
        let mut name = String::new();
        let mut quoted = false;
        while let Some(c) = self.peek() {
            // The first character never ends a symbol: `read_all` dispatched every one that would.
            if ends_symbol(c) {
                break;
            }
            self.pos += c.len_utf8();
            if c == '\\' {
                let Some(e) = self.advance() else {
                    return Err(self.unterminated(start, "a symbol (after `\\`)"));
                };
                quoted = true;
                name.push(e);
            } else {
                name.push(c);
            }
        }
        let span = Span {
            start,
            end: self.pos,
        };
        if !quoted && name.starts_with(|c: char| c.is_ascii_digit() || matches!(c, '.' | '-' | '+'))
        {
            match decimal(&name) {
                Some(Number::Float(f)) => {
                    return Ok(Node {
                        datum: Datum::Float(f),
                        span,
                    });
                }
                Some(Number::Int(negative, magnitude)) => {
                    return self.int_node(start, negative, magnitude);
                }
                None => {}
            }
        }
        Ok(Node {
            datum: Datum::Sym(name),
            span,
        })
    }

    /// `"…"` (lread.c `read_string_literal`). Emacs makes the string unibyte when an escape gives a raw byte and
    /// nothing gives a non-ASCII character, and keeps the raw byte in a multibyte string otherwise: both refused.
    fn string_literal(&mut self) -> Result<Node, Refusal> {
        let start = self.pos;
        self.pos += 1;
        let mut text = String::new();
        let (mut single, mut multi) = (false, false);
        let mut not_unicode = None;
        loop {
            let Some(c) = self.advance() else {
                return Err(self.unterminated(start, "a string"));
            };
            match c {
                '"' => break,
                '\\' => {
                    let escape = self.pos - 1;
                    let Some(e) = self.advance() else {
                        return Err(self.unterminated(start, "a string"));
                    };
                    let code = match e {
                        's' => u32::from(b' '),
                        ' ' | '\n' => continue,
                        _ => self.string_escape(start, escape, e)?,
                    };
                    let mut modifiers = code & MODIFIERS;
                    let mut ch = code & !MODIFIERS;
                    if is_byte8(ch) {
                        single = true;
                    } else if ch >= 0x80 {
                        multi = true;
                    } else {
                        if modifiers == CTL && ch == u32::from(b' ') {
                            ch = 0;
                            modifiers = 0;
                        }
                        if modifiers & SHIFT != 0 {
                            if (u32::from(b'A')..=u32::from(b'Z')).contains(&ch) {
                                modifiers &= !SHIFT;
                            } else if (u32::from(b'a')..=u32::from(b'z')).contains(&ch) {
                                ch -= 0x20;
                                modifiers &= !SHIFT;
                            }
                        }
                        if modifiers & META != 0 {
                            modifiers &= !META;
                            ch = byte8_to_char(ch | 0x80);
                            single = true;
                        }
                    }
                    if modifiers != 0 {
                        return Err(
                            self.syntax(escape, "a modifier Emacs does not allow in a string")
                        );
                    }
                    if !is_byte8(ch) {
                        match char::from_u32(ch) {
                            Some(c) => text.push(c),
                            None => {
                                not_unicode.get_or_insert(Span {
                                    start: escape,
                                    end: self.pos,
                                });
                            }
                        }
                    }
                }
                c => {
                    multi |= !c.is_ascii();
                    text.push(c);
                }
            }
        }
        unibyte(start, self.pos, single, multi)?;
        if let Some(span) = not_unicode {
            return Err(refusal(
                RefusalKind::NotUtf8,
                span.start,
                span.end,
                "a character that is not Unicode (a surrogate or beyond U+10FFFF): UTF-8 cannot hold it",
            ));
        }
        Ok(Node {
            datum: Datum::Str(text),
            span: Span {
                start,
                end: self.pos,
            },
        })
    }

    /// `?c` (lread.c `read_char_literal`): the integer Emacs gives, which must end at a delimiter.
    fn char_literal(&mut self) -> Result<Node, Refusal> {
        let start = self.pos;
        self.pos += 1;
        let Some(c) = self.advance() else {
            return Err(self.unterminated(start, "a character"));
        };
        let code = if c == ' ' || c == '\t' {
            u32::from(c)
        } else {
            let mut code = if c == '\\' {
                let Some(e) = self.advance() else {
                    return Err(self.unterminated(start, "a character"));
                };
                self.string_escape(start, start + 1, e)?
            } else {
                u32::from(c)
            };
            let modifiers = code & MODIFIERS;
            code &= !MODIFIERS;
            if is_byte8(code) {
                code -= 0x3F_FF00;
            }
            code |= modifiers;
            match self.peek() {
                None => {}
                Some(n)
                    if n <= ' '
                        || matches!(
                            n,
                            '"' | '\'' | ';' | '(' | ')' | '[' | ']' | '#' | '?' | '`' | ',' | '.'
                        ) => {}
                Some(_) => {
                    return Err(self.syntax(start, "a character must be followed by a delimiter"));
                }
            }
            code
        };
        Ok(Node {
            datum: Datum::Int(i64::from(code)),
            span: Span {
                start,
                end: self.pos,
            },
        })
    }

    /// The escape after a backslash at `escape` whose first character `first` is read (lread.c
    /// `read_char_escape`): a character code with Emacs's modifier bits. `literal` is where the string or
    /// character starts. Modifier chains (`\M-\C-a`) loop, never recurse.
    fn string_escape(
        &mut self,
        literal: usize,
        escape: usize,
        first: char,
    ) -> Result<u32, Refusal> {
        let mut modifiers = 0;
        let mut controls = 0usize;
        let mut c = first;
        let code = loop {
            match c {
                'a' => break 7,
                'b' => break 8,
                'd' => break 127,
                'e' => break 27,
                'f' => break 12,
                'n' => break 10,
                'r' => break 13,
                't' => break 9,
                'v' => break 11,
                '\n' => return Err(self.syntax(escape, "`\\` before a newline in a character")),
                'M' | 'S' | 'H' | 'A' | 's' => {
                    if !self.eat('-') {
                        if c == 's' {
                            break 32;
                        }
                        return Err(self.syntax(escape, format!("`\\{c}` not followed by `-`")));
                    }
                    modifiers |= match c {
                        'M' => META,
                        'S' => SHIFT,
                        'H' => HYPER,
                        'A' => ALT,
                        _ => SUPER,
                    };
                }
                'C' | '^' => {
                    if c == 'C' && !self.eat('-') {
                        return Err(self.syntax(escape, "`\\C` not followed by `-`"));
                    }
                    controls += 1;
                }
                '0'..='7' => {
                    let mut i = c as u32 - u32::from(b'0');
                    for _ in 0..2 {
                        match self.peek().and_then(|d| d.to_digit(8)) {
                            Some(d) => {
                                self.pos += 1;
                                i = i * 8 + d;
                            }
                            None => break,
                        }
                    }
                    if (0x80..0x100).contains(&i) {
                        i = byte8_to_char(i);
                    }
                    break i;
                }
                'x' => {
                    let mut i: u32 = 0;
                    let mut count = 0;
                    while let Some(d) = self.peek().and_then(|d| d.to_digit(16)) {
                        self.pos += 1;
                        i = (i << 4) + d;
                        if i > (META | (META - 1)) {
                            return Err(self.syntax(escape, "a hex character beyond Emacs's range"));
                        }
                        if count < 3 {
                            count += 1;
                        }
                    }
                    if count == 0 {
                        return Err(self.syntax(escape, "`\\x` not followed by a hex digit"));
                    }
                    if count < 3 && i >= 0x80 {
                        i = byte8_to_char(i);
                    }
                    modifiers |= i & MODIFIERS;
                    break i & !MODIFIERS;
                }
                'u' | 'U' => {
                    let digits = if c == 'u' { 4 } else { 8 };
                    let mut i: u32 = 0;
                    for _ in 0..digits {
                        let Some(d) = self.advance() else {
                            return Err(self.unterminated(literal, "a `\\u` escape"));
                        };
                        let Some(d) = d.to_digit(16) else {
                            return Err(
                                self.syntax(escape, format!("`\\{c}` needs {digits} hex digits"))
                            );
                        };
                        i = (i << 4) + d;
                    }
                    if i > 0x10_FFFF {
                        return Err(self.syntax(escape, "a character beyond Unicode"));
                    }
                    break i;
                }
                'N' => break self.char_name(literal, escape)?,
                other => break u32::from(other),
            }
            // After `\M-`, `\C-` or `\^`: the character they apply to, or another escape.
            let Some(next) = self.advance() else {
                return Err(self.unterminated(literal, "a character escape"));
            };
            if next != '\\' {
                break u32::from(next);
            }
            let Some(next) = self.advance() else {
                return Err(self.unterminated(literal, "a character escape"));
            };
            c = next;
        };
        let mut code = code;
        for _ in 0..controls {
            if (0x40..=0x5F).contains(&code) || (0x61..=0x7A).contains(&code) {
                code &= 0x1F;
            } else if code == u32::from(b'?') {
                code = 127;
            } else {
                modifiers |= CTL;
            }
        }
        Ok(code | modifiers)
    }

    /// `\N{U+X}` (Emacs's rule: hex after `U+`, a Unicode scalar value). Any other name would need Unicode's name
    /// table: refused, the listed divergence.
    fn char_name(&mut self, literal: usize, escape: usize) -> Result<u32, Refusal> {
        if !self.eat('{') {
            return Err(self.syntax(escape, "`\\N` not followed by `{`"));
        }
        let mut name = String::new();
        let mut space = false;
        loop {
            let Some(c) = self.advance() else {
                return Err(self.unterminated(literal, "a `\\N{…}` escape"));
            };
            match c {
                '}' => break,
                c if !c.is_ascii() => {
                    return Err(self.syntax(escape, "a character name with a non-ASCII character"));
                }
                ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' => {
                    if !space {
                        name.push(' ');
                    }
                    space = true;
                }
                c => {
                    name.push(c);
                    space = false;
                }
            }
            if name.len() > 200 {
                return Err(self.syntax(escape, "a character name longer than 200 characters"));
            }
        }
        if name.is_empty() {
            return Err(self.syntax(escape, "an empty character name"));
        }
        let Some(hex) = name.strip_prefix("U+") else {
            return Err(refusal(
                RefusalKind::CharName,
                escape,
                self.pos,
                "a character by name (`\\N{NAME}`): write `\\N{U+X}` or the character itself",
            ));
        };
        // string_to_number ("+X", 16): hex digits, then an optional `.`.
        let digits = hex.strip_suffix('.').unwrap_or(hex);
        let code = (!digits.is_empty() && digits.chars().all(|c| c.is_ascii_hexdigit()))
            .then(|| u32::from_str_radix(digits, 16).ok())
            .flatten()
            .filter(|&c| char::from_u32(c).is_some());
        code.ok_or_else(|| {
            self.syntax(
                escape,
                format!("`\\N{{{name}}}` is not a Unicode character"),
            )
        })
    }
}

/// A list closed at `end`: `()` is `nil`; a dotted tail that is itself a list joins it, as Emacs's conses do.
fn close_list(start: usize, end: usize, mut items: Vec<Node>, tail: Tail) -> Node {
    let span = Span { start, end };
    let datum = match tail {
        Tail::Read(tail) => match tail.datum {
            Datum::Sym(s) if s == "nil" => Datum::List(items),
            Datum::List(more) => {
                items.extend(more);
                Datum::List(items)
            }
            Datum::Cons(more, last) => {
                items.extend(more);
                Datum::Cons(items, last)
            }
            datum => Datum::Cons(
                items,
                Box::new(Node {
                    datum,
                    span: tail.span,
                }),
            ),
        },
        _ if items.is_empty() => Datum::Sym("nil".to_owned()),
        _ => Datum::List(items),
    };
    Node { datum, span }
}

/// The string at `start..end` read with a raw byte: unibyte (no non-ASCII character) or multibyte with a raw byte.
fn unibyte(start: usize, end: usize, single: bool, multi: bool) -> Result<(), Refusal> {
    match (single, multi) {
        (true, false) => Err(refusal(
            RefusalKind::Unibyte,
            start,
            end,
            "a string Emacs reads as unibyte bytes: write the characters themselves",
        )),
        (true, true) => Err(refusal(
            RefusalKind::RawByte,
            start,
            end,
            "a string with a raw byte: write the characters themselves",
        )),
        _ => Ok(()),
    }
}

enum Number {
    /// Negative, and the magnitude (saturated far beyond 64 bits).
    Int(bool, u128),
    Float(f64),
}

/// A whole token in decimal number syntax (lread.c `string_to_number`, base 10), or `None` for a symbol.
fn decimal(token: &str) -> Option<Number> {
    let b = token.as_bytes();
    let at = |i: usize| b.get(i).copied().unwrap_or(0);
    let negative = at(0) == b'-';
    let mut i = usize::from(matches!(at(0), b'-' | b'+'));
    let digits_start = i;
    let mut magnitude: u128 = 0;
    while at(i).is_ascii_digit() {
        magnitude = magnitude
            .saturating_mul(10)
            .saturating_add(u128::from(at(i) - b'0'));
        i += 1;
    }
    let leading = i > digits_start;
    if at(i) == b'.' {
        i += 1;
    }
    let trail_start = i;
    while at(i).is_ascii_digit() {
        i += 1;
    }
    let trailing = i > trail_start;
    let mut special = None;
    let mut exponent = false;
    if matches!(at(i), b'e' | b'E') {
        let e = i;
        i += 1;
        if matches!(at(i), b'+' | b'-') {
            i += 1;
        }
        if at(i).is_ascii_digit() {
            exponent = true;
            while at(i).is_ascii_digit() {
                i += 1;
            }
        } else if at(i - 1) == b'+' && b[i..].starts_with(b"INF") {
            exponent = true;
            i += 3;
            special = Some(f64::INFINITY);
        } else if at(i - 1) == b'+' && b[i..].starts_with(b"NaN") {
            exponent = true;
            i += 3;
            // Emacs puts the leading integer into the NaN's payload.
            let payload = (magnitude as u64) & 0x0007_FFFF_FFFF_FFFF;
            special = Some(f64::from_bits(0x7FF8_0000_0000_0000 | payload));
        } else {
            i = e;
        }
    }
    if i != b.len() {
        return None;
    }
    if trailing || (leading && exponent) {
        let value = match special {
            Some(v) => v,
            None => token[digits_start..].parse::<f64>().ok()?,
        };
        return Some(Number::Float(if negative { -value } else { value }));
    }
    leading.then_some(Number::Int(negative, magnitude))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::span::line_col;
    use proptest::prelude::*;
    use serde_json::{Value, json};
    use std::collections::HashSet;

    fn read(text: &str) -> Result<Vec<Node>, Refusal> {
        read_all(text.as_bytes(), Limits::default())
    }

    /// The canonical dump of test/fixtures/huginn/README.md.
    fn dump(node: &Node) -> Value {
        let all = |items: &[Node]| Value::Array(items.iter().map(dump).collect());
        match &node.datum {
            Datum::Int(i) => json!(["int", i.to_string()]),
            Datum::Float(f) => json!(["float", float_text(*f)]),
            Datum::Str(s) => json!(["str", s]),
            Datum::Sym(s) => json!(["sym", s]),
            Datum::List(items) => json!(["list", all(items)]),
            Datum::Cons(items, tail) => json!(["cons", all(items), dump(tail)]),
            Datum::Vec(items) => json!(["vec", all(items)]),
        }
    }

    fn dump_all(nodes: &[Node]) -> Value {
        Value::Array(nodes.iter().map(dump).collect())
    }

    fn float_text(f: f64) -> String {
        let sign = if f.is_sign_negative() { "-" } else { "" };
        if f.is_nan() {
            format!("{sign}0.0e+NaN")
        } else if f.is_infinite() {
            format!("{sign}1.0e+INF")
        } else {
            format!("{f:?}")
        }
    }

    fn float_value(text: &str) -> f64 {
        if text.ends_with("e+NaN") {
            f64::NAN
        } else if text.ends_with("e+INF") {
            if text.starts_with('-') {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            }
        } else {
            text.parse()
                .unwrap_or_else(|_| panic!("not a float: {text}"))
        }
    }

    /// Equal dumps; floats by value (any NaN equals any NaN, -0.0 is not 0.0).
    fn same(expected: &Value, actual: &Value) -> bool {
        match (expected, actual) {
            (Value::Array(e), Value::Array(a)) if e.len() == a.len() => {
                if e.len() == 2 && e[0] == "float" && a[0] == "float" {
                    let (x, y) = (
                        float_value(e[1].as_str().unwrap_or_default()),
                        float_value(a[1].as_str().unwrap_or_default()),
                    );
                    return (x.is_nan() && y.is_nan()) || x.to_bits() == y.to_bits();
                }
                e.iter().zip(a).all(|(x, y)| same(x, y))
            }
            _ => expected == actual,
        }
    }

    fn accepts(text: &str, expected: Value) {
        match read(text) {
            Ok(nodes) => {
                let actual = dump_all(&nodes);
                assert!(
                    same(&expected, &actual),
                    "{text:?}: expected {expected}, read {actual}"
                );
            }
            Err(r) => panic!("{text:?}: refused: {r}"),
        }
    }

    fn refuses(text: &str, kind: RefusalKind, at: usize) {
        refuses_bytes(text.as_bytes(), kind, at);
    }

    fn refuses_bytes(bytes: &[u8], kind: RefusalKind, at: usize) {
        match read_all(bytes, Limits::default()) {
            Err(r) => assert!(
                r.kind == kind && r.span.start == at,
                "{bytes:?}: expected {kind:?} at {at}, got {:?} at {}: {}",
                r.kind,
                r.span.start,
                r.message
            ),
            Ok(nodes) => panic!("{bytes:?}: read {}", dump_all(&nodes)),
        }
    }

    #[test]
    fn every_case_in_the_shared_table() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test/fixtures/huginn/cases.json"
        );
        let table = std::fs::read_to_string(path).expect("the shared case table");
        let rows: Vec<Value> = serde_json::from_str(&table).expect("cases.json is JSON");
        let mut ids = HashSet::new();
        let mut failures = Vec::new();
        for row in &rows {
            let id = row["id"].as_str().expect("every row has an id");
            assert!(ids.insert(id), "duplicate id {id}");
            let text = row["text"].as_str().expect("every row has a text");
            // An id starting `bytes-` is one byte per character (README.md).
            let bytes: Vec<u8> = if id.starts_with("bytes-") {
                text.chars()
                    .map(|c| u8::try_from(u32::from(c)).expect("a bytes- row is below U+0100"))
                    .collect()
            } else {
                text.as_bytes().to_vec()
            };
            match (row["expect"].as_str(), read_all(&bytes, Limits::default())) {
                (Some("accept"), Ok(nodes)) => {
                    let actual = dump_all(&nodes);
                    if !same(&row["dump"], &actual) {
                        failures.push(format!("{id}: expected {}, read {actual}", row["dump"]));
                    }
                }
                (Some("accept"), Err(r)) => failures.push(format!("{id}: refused: {r}")),
                (Some("refuse" | "refuse-rust-only"), Err(r)) => {
                    let kind = format!("{:?}", r.kind);
                    if row["kind"].as_str() != Some(kind.as_str())
                        || row["at"].as_u64() != Some(r.span.start as u64)
                    {
                        failures.push(format!(
                            "{id}: expected {} at {}, got {kind} at {}: {}",
                            row["kind"], row["at"], r.span.start, r.message
                        ));
                    }
                }
                (Some("refuse" | "refuse-rust-only"), Ok(nodes)) => {
                    failures.push(format!("{id}: read {}", dump_all(&nodes)));
                }
                (other, _) => failures.push(format!("{id}: unknown expect {other:?}")),
            }
        }
        assert!(
            failures.is_empty(),
            "{} of {} rows:\n{}",
            failures.len(),
            rows.len(),
            failures.join("\n")
        );
    }

    #[test]
    fn values_emacs_gives() {
        // lexpr's misreads, read as Emacs reads them (design §11.2).
        accepts("foo\\ bar", json!([["sym", "foo bar"]]));
        accepts("\"a\\\nb\"", json!([["str", "ab"]]));
        accepts(
            "?\\C-a ?\\^a \"\\^a\"",
            json!([["int", "1"], ["int", "1"], ["str", "\u{1}"]]),
        );
        // `\N{U+X}` takes Emacs's trailing dot, and a BOM is a symbol character.
        accepts("?\\N{U+41.}", json!([["int", "65"]]));
        // The largest escapes Emacs takes.
        accepts(
            "?\\xfffffff ?\\U0010FFFF",
            json!([["int", "264241407"], ["int", "1114111"]]),
        );
        accepts("\u{feff}a", json!([["sym", "\u{feff}a"]]));
        accepts("1\"a\"b", json!([["int", "1"], ["str", "a"], ["sym", "b"]]));
        accepts("a\u{2003}b", json!([["sym", "a\u{2003}b"]]));
        accepts(
            "(a ; c\n . ;; d\n b)",
            json!([["cons", [["sym", "a"]], ["sym", "b"]]]),
        );
        // `"\M-\M-…\M-a"` is `"\M-a"`, without recursion.
        let many = format!("?{}a", "\\M-".repeat(100_000));
        accepts(&many, json!([["int", "134217825"]]));
    }

    #[test]
    fn syntax_errors_refuse_where_emacs_does() {
        use RefusalKind::Syntax;
        for (text, at) in [
            (")", 0),
            ("]", 0),
            ("(a]", 2),
            ("[a)", 2),
            ("')", 1),
            ("1)", 1),
            ("( . a)", 2),
            ("[a . b]", 3),
            ("(a . b c)", 7),
            ("(a . b . c)", 7),
            ("(a . ;c\n)", 8),
            ("?ab", 0),
            ("?a\u{a0}", 0),
            ("#x", 0),
            ("#x1g", 0),
            ("#b", 0),
            ("#o", 0),
            ("#24r", 0),
            ("#b12", 0),
            ("#1r0", 0),
            ("#37r0", 0),
            ("#99999999999999999999r0", 0),
            ("a#b", 1),
            ("#", 0),
            ("#12", 0),
            ("#12x", 0),
            ("\"\\C-%\"", 1),
            ("\"\\S-1\"", 1),
            ("\"\\H-a\"", 1),
            ("\"\\C-\u{e9}\"", 1),
            ("\"\\x\"", 1),
            ("?\\x", 1),
            ("\"\\u12\"", 1),
            ("\"\\uzzzz\"", 1),
            ("\"\\U00110000\"", 1),
            ("?\\U00110000", 1),
            ("?\\x10000000", 1),
            ("?\\M", 1),
            ("?\\C", 1),
            ("?\\S", 1),
            ("?\\\n", 1),
            ("\"\\N{U+D800}\"", 1),
            ("?\\N{U+DFFF}", 1),
            ("\"\\N{U+110000}\"", 1),
            ("\"\\N{U+}\"", 1),
            ("?\\N{U+-0}", 1),
            ("?\\N{}", 1),
            ("?\\N", 1),
            ("?\\N{LATIN CAPITAL LETTER \u{d8}}", 1),
        ] {
            refuses(text, Syntax, at);
        }
        let long = format!("?\\N{{{}}}", "A".repeat(201));
        refuses(&long, Syntax, 1);
    }

    #[test]
    fn the_file_ends_inside() {
        use RefusalKind::Unterminated;
        for (text, at) in [
            ("\"abc", 0),
            ("(a", 0),
            ("(a (b", 3),
            ("[a", 0),
            ("'", 0),
            ("#'", 0),
            ("(a . b", 0),
            ("(a .", 0),
            ("?", 0),
            ("?\\", 0),
            ("?\\C-", 0),
            ("?\\M-", 0),
            ("?\\^", 0),
            ("?\\C-\\", 0),
            ("?\\C-\\M-", 0),
            ("?\\u12", 0),
            ("?\\N{U+41", 0),
            ("\"\\M-\"", 0),
            ("a\\", 0),
            ("(a b\\", 3),
        ] {
            refuses(text, Unterminated, at);
        }
    }

    #[test]
    fn reader_macros_refuse_with_the_token_span() {
        for (text, start, end) in [
            ("`a", 0, 1),
            (",a", 0, 1),
            (",@a", 0, 2),
            ("#s(a)", 0, 3),
            ("#(\"a\")", 0, 2),
            ("#[0]", 0, 2),
            ("#&3\"a\"", 0, 2),
            ("#1=a", 0, 3),
            ("#12#", 0, 4),
            ("#@00", 0, 2),
            ("#$", 0, 2),
            ("#.x", 0, 2),
            ("##", 0, 2),
            ("#_x", 0, 2),
            ("#:x", 0, 2),
            ("#t", 0, 2),
            ("#^[nil]", 0, 3),
            ("#^^[3 0]", 0, 4),
            ("(a #s(b))", 3, 6),
        ] {
            let r = read(text).expect_err(text);
            assert_eq!(
                (r.kind, r.span),
                (RefusalKind::ReaderMacro, Span { start, end }),
                "{text}: {}",
                r.message
            );
        }
    }

    #[test]
    fn divergences_huginn_refuses() {
        // Listed: `\N{NAME}` needs Unicode's name table.
        refuses(
            "\"\\N{LATIN SMALL LETTER E WITH ACUTE}\"",
            RefusalKind::CharName,
            1,
        );
        refuses("?\\N{BED}", RefusalKind::CharName, 1);
        // A string Emacs reads with a character UTF-8 cannot hold: a surrogate, or beyond U+10FFFF.
        refuses("\"a\\uD800\"", RefusalKind::NotUtf8, 2);
        refuses("\"\\x110000\"", RefusalKind::NotUtf8, 1);
        refuses("\"\\x3FFFFF\"", RefusalKind::Unibyte, 0);
    }

    #[test]
    fn invalid_utf8_is_refused_at_the_bad_byte() {
        refuses_bytes(b"(a \xff)", RefusalKind::NotUtf8, 3);
        refuses_bytes(b"\"\xc3\"", RefusalKind::NotUtf8, 1);
        refuses_bytes(b"ok \xe9", RefusalKind::NotUtf8, 3);
        refuses_bytes(b"\xed\xa0\x80", RefusalKind::NotUtf8, 0);
        // The span is the bad sequence: one byte, or what is left of a sequence the file cuts short.
        let span = |bytes: &[u8]| {
            read_all(bytes, Limits::default())
                .expect_err("not UTF-8")
                .span
        };
        assert_eq!(span(b"(a \xff)"), Span { start: 3, end: 4 });
        assert_eq!(span(b"ok \xe2\x82"), Span { start: 3, end: 5 });
    }

    #[test]
    fn a_refusal_says_why_and_where() {
        let r = read("(a #37r0)").expect_err("radix 37");
        assert_eq!(r.to_string(), "radix 37 is not 2 to 36 (bytes 3..7)");
    }

    #[test]
    fn a_nan_keeps_its_leading_integer_as_payload() {
        // Emacs prints it back: `5.0e+NaN`.
        let nodes = read("5.0e+NaN").expect("a NaN");
        let Datum::Float(f) = nodes[0].datum else {
            panic!("a float");
        };
        assert_eq!(f.to_bits(), 0x7FF8_0000_0000_0005);
    }

    #[test]
    fn depth_64_reads_65_refuses() {
        let nested =
            |n: usize, open: &str, close: &str| format!("{}x{}", open.repeat(n), close.repeat(n));
        for (open, close) in [("(", ")"), ("[", "]"), ("'", ""), ("#'", "")] {
            assert!(read(&nested(64, open, close)).is_ok(), "64 of {open}");
            let r = read(&nested(65, open, close)).expect_err("65 levels");
            assert_eq!(r.kind, RefusalKind::TooDeep, "{open}");
            assert_eq!(r.span.start, 64 * open.len(), "{open}");
            assert_eq!(r.span.end, r.span.start + 1, "{open}");
        }
        let limits = Limits {
            max_depth: 2,
            ..Limits::default()
        };
        assert!(read_all(b"((a) [b] 'c)", limits).is_ok());
        assert_eq!(
            read_all(b"((a) ['c])", limits).map_err(|r| (r.kind, r.span.start)),
            Err((RefusalKind::TooDeep, 6))
        );
    }

    #[test]
    fn one_mib_reads_one_more_byte_refuses() {
        let mib = 1 << 20;
        let fits = format!("\"{}\"", "a".repeat(mib - 2));
        assert_eq!(read(&fits).map(|n| n.len()), Ok(1));
        let over = format!("\"{}\"", "a".repeat(mib - 1));
        let r = read(&over).expect_err("one byte too many");
        assert_eq!(
            (r.kind, r.span),
            (
                RefusalKind::TooBig,
                Span {
                    start: mib,
                    end: mib + 1
                }
            )
        );
    }

    /// Every node and the text its span covers.
    fn each_node<'a>(node: &'a Node, out: &mut Vec<&'a Node>) {
        out.push(node);
        match &node.datum {
            Datum::List(items) | Datum::Vec(items) => items.iter().for_each(|n| each_node(n, out)),
            Datum::Cons(items, tail) => {
                items.iter().for_each(|n| each_node(n, out));
                each_node(tail, out);
            }
            _ => {}
        }
    }

    #[test]
    fn spans_cover_the_datum() {
        let text = "; settings\n(drgnx-settings :version 1\n  (fill-column 100)\n  (tab-width 4 :merge keep)\n  \
                    (foo '(a . b))\n  (bar #'ignore)\n  (s \"é\\n\\x41\") (c ?\\C-a ? ) (v [1 2.5 #x1F])\n  \
                    (d (a . (b c))) (q 'x) (sym foo\\ bar) (n -0.0e+NaN) (e ()))\n42";
        let nodes = read(text).expect("the sample reads");
        let mut all = Vec::new();
        nodes.iter().for_each(|n| each_node(n, &mut all));
        assert!(all.len() > 40, "{} nodes", all.len());
        for node in all {
            let source = &text[node.span.start..node.span.end];
            // The `quote` or `function` a `'` or `#'` stands for has that token as its span.
            if matches!(source, "'" | "#'") {
                assert!(matches!(&node.datum, Datum::Sym(s) if s == "quote" || s == "function"));
                continue;
            }
            let again = read(source).unwrap_or_else(|r| panic!("{source:?}: {r}"));
            assert_eq!(again.len(), 1, "{source:?}");
            assert!(
                same(&dump(node), &dump(&again[0])),
                "{source:?}: {} vs {}",
                dump(node),
                dump(&again[0])
            );
        }
    }

    #[test]
    fn line_col_counts_characters() {
        let text = "ab\ncé\td\n";
        assert_eq!(line_col(text, 0), (1, 0));
        assert_eq!(line_col(text, 2), (1, 2));
        assert_eq!(line_col(text, 3), (2, 0));
        let d = text.find('d').unwrap();
        assert_eq!(line_col(text, d), (2, 3));
        // Inside a character: the character's own column; past the end: the end.
        assert_eq!(line_col(text, 5), (2, 1));
        assert_eq!(line_col(text, text.len()), (3, 0));
        assert_eq!(line_col(text, text.len() + 10), (3, 0));
        let r = read("(a\n  \"é\\xe9\")").expect_err("raw byte");
        assert_eq!(line_col("(a\n  \"é\\xe9\")", r.span.start), (2, 2));
    }

    fn spans_inside(nodes: &[Node], len: usize) -> bool {
        let mut all = Vec::new();
        nodes.iter().for_each(|n| each_node(n, &mut all));
        all.iter()
            .all(|n| n.span.start <= n.span.end && n.span.end <= len)
    }

    proptest! {
        #[test]
        fn any_bytes_read_or_refuse_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..256)) {
            match read_all(&bytes, Limits::default()) {
                Ok(nodes) => prop_assert!(spans_inside(&nodes, bytes.len())),
                Err(r) => prop_assert!(r.span.start <= r.span.end && r.span.end <= bytes.len()),
            }
        }

        #[test]
        fn lisp_like_text_reads_or_refuses_never_panics(
            text in "[()\\[\\]'#`,.?\\\\\"; \n\ta-fx0-9+\\-eENUCMSHAs^{}é\u{a0}]{0,80}"
        ) {
            match read(&text) {
                Ok(nodes) => prop_assert!(spans_inside(&nodes, text.len())),
                Err(r) => prop_assert!(r.span.start <= r.span.end && r.span.end <= text.len()),
            }
        }
    }
}
