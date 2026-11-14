//! Text as a terminal shows it: the part of a stream or a traceback the view needs, and the styles as roles of the theme's terminal
//! faces (0 to 15), never colours. `\r` returns to the start of the line and overwrites, `\b` backs up one character, `ESC [ K`
//! erases to the end of the line, SGR sets the style; every other escape sequence is dropped.

/// How a run of text is styled. `fg` and `bg` are terminal face roles 0 to 15 (8 to 15 bright).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Style {
    pub fg: Option<u8>,
    pub bg: Option<u8>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

/// A styled stretch of the rendered text, in characters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Run {
    pub start: usize,
    pub end: usize,
    pub style: Style,
}

type Cell = (char, Style);

/// Characters that change how text reads or is laid out, not what it says: bidirectional controls (they reorder what follows) and
/// the object replacement character (the tail's mark for an image). They never reach a view.
pub fn is_unsafe(c: char) -> bool {
    matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{fffc}')
}

/// S without its control characters (but newlines and tabs) and its [`is_unsafe`] ones.
pub fn clean(s: &str) -> String {
    s.chars()
        .filter(|c| !is_unsafe(*c) && (!c.is_control() || *c == '\n' || *c == '\t'))
        .collect()
}

#[derive(Clone, Debug, Default)]
pub struct Terminal {
    done: Vec<Vec<Cell>>,
    line: Vec<Cell>,
    col: usize,
    style: Style,
    /// An escape sequence cut by the end of a message.
    esc: Option<String>,
    bytes: usize,
}

fn size(c: char) -> usize {
    c.len_utf8()
}

impl Terminal {
    pub fn push(&mut self, s: &str) {
        for c in s.chars() {
            if let Some(mut seq) = self.esc.take() {
                if seq.is_empty() {
                    // after ESC: `[` starts a CSI, `]` an OSC (a title, a link); anything else is a two-byte sequence, dropped
                    if c == '[' || c == ']' {
                        self.esc = Some(c.to_string());
                    }
                    continue;
                }
                seq.push(c);
                if seq.starts_with(']') {
                    // an OSC ends with BEL or ESC \; a runaway one is dropped
                    if c != '\x07' && !seq.ends_with("\x1b\\") && seq.len() < 4096 {
                        self.esc = Some(seq);
                    }
                } else if ('@'..='~').contains(&c) {
                    // a CSI ends with a byte 0x40 to 0x7e
                    self.csi(&seq[1..]);
                } else if seq.len() < 64 {
                    self.esc = Some(seq);
                }
                continue;
            }
            match c {
                '\x1b' => self.esc = Some(String::new()),
                '\n' => {
                    self.done.push(std::mem::take(&mut self.line));
                    self.col = 0;
                    self.bytes += 1;
                }
                '\r' => self.col = 0,
                '\x08' => self.col = self.col.saturating_sub(1),
                c if (c.is_control() && c != '\t') || is_unsafe(c) => {}
                c => {
                    if self.col < self.line.len() {
                        self.bytes = self.bytes - size(self.line[self.col].0) + size(c);
                        self.line[self.col] = (c, self.style);
                    } else {
                        self.line.push((c, self.style));
                        self.bytes += size(c);
                    }
                    self.col += 1;
                }
            }
        }
    }

    fn csi(&mut self, body: &str) {
        let (params, fin) = body.split_at(body.len() - 1);
        match fin {
            "m" => self.sgr(params),
            "K" if params.is_empty() || params == "0" => {
                for (c, _) in self.line.drain(self.col.min(self.line.len())..) {
                    self.bytes -= size(c);
                }
            }
            _ => {}
        }
    }

    fn sgr(&mut self, params: &str) {
        let nums: Vec<u32> = if params.is_empty() {
            vec![0]
        } else {
            params
                .split([';', ':'])
                .map(|p| p.parse().unwrap_or(0))
                .collect()
        };
        let mut i = 0;
        while i < nums.len() {
            let n = nums[i];
            let s = &mut self.style;
            match n {
                0 => *s = Style::default(),
                1 => s.bold = true,
                3 => s.italic = true,
                4 => s.underline = true,
                7 => s.inverse = true,
                22 => s.bold = false,
                23 => s.italic = false,
                24 => s.underline = false,
                27 => s.inverse = false,
                30..=37 => s.fg = Some((n - 30) as u8),
                90..=97 => s.fg = Some((n - 90 + 8) as u8),
                39 => s.fg = None,
                40..=47 => s.bg = Some((n - 40) as u8),
                100..=107 => s.bg = Some((n - 100 + 8) as u8),
                49 => s.bg = None,
                38 | 48 => {
                    // 38;5;n (a palette entry: the first 16 are roles, the rest has none) and 38;2;r;g;b (a colour literal: none)
                    let role = match nums.get(i + 1) {
                        Some(5) => {
                            let v = nums.get(i + 2).copied();
                            i += 2;
                            v.filter(|v| *v < 16).map(|v| v as u8)
                        }
                        Some(2) => {
                            i += 4;
                            None
                        }
                        _ => None,
                    };
                    if n == 38 {
                        self.style.fg = role;
                    } else {
                        self.style.bg = role;
                    }
                }
                _ => {}
            }
            i += 1;
        }
    }

    /// Bytes of text held.
    pub fn len(&self) -> usize {
        self.bytes
    }

    pub fn is_empty(&self) -> bool {
        self.bytes == 0
    }

    /// Drop OVER bytes from the end.
    pub fn truncate_back(&mut self, over: usize) {
        let mut left = over;
        while left > 0 {
            if let Some((c, _)) = self.line.pop() {
                left = left.saturating_sub(size(c));
                self.bytes -= size(c);
            } else if let Some(prev) = self.done.pop() {
                // the newline before this empty line
                self.line = prev;
                left = left.saturating_sub(1);
                self.bytes -= 1;
            } else {
                break;
            }
        }
        self.col = self.col.min(self.line.len());
    }

    fn lines(&self) -> impl Iterator<Item = &Vec<Cell>> {
        self.done.iter().chain(std::iter::once(&self.line))
    }

    /// The text, and the styled runs of it (character offsets; unstyled stretches have no run).
    pub fn render(&self) -> (String, Vec<Run>) {
        let (mut text, mut runs) = (String::new(), Vec::<Run>::new());
        let mut at = 0;
        for (n, line) in self.lines().enumerate() {
            if n > 0 {
                text.push('\n');
                at += 1;
            }
            for (c, st) in line {
                text.push(*c);
                if *st != Style::default() {
                    match runs.last_mut() {
                        Some(r) if r.end == at && r.style == *st => r.end += 1,
                        _ => runs.push(Run {
                            start: at,
                            end: at + 1,
                            style: *st,
                        }),
                    }
                }
                at += 1;
            }
        }
        (text, runs)
    }

    /// How many lines the text has (a final empty line counts).
    pub fn line_count(&self) -> usize {
        self.done.len() + 1
    }

    /// The first ROWS lines, each with its runs (offsets within the line, in characters): the work is the rows', however many
    /// lines there are.
    pub fn head(&self, rows: usize) -> Vec<(String, Vec<Run>)> {
        self.lines()
            .take(rows)
            .map(|line| {
                let (mut text, mut runs) = (String::new(), Vec::<Run>::new());
                for (at, (c, st)) in line.iter().enumerate() {
                    text.push(*c);
                    if *st != Style::default() {
                        match runs.last_mut() {
                            Some(r) if r.end == at && r.style == *st => r.end += 1,
                            _ => runs.push(Run {
                                start: at,
                                end: at + 1,
                                style: *st,
                            }),
                        }
                    }
                }
                (text, runs)
            })
            .collect()
    }

    pub fn text(&self) -> String {
        self.render().0
    }

    /// The text with its styles written as SGR, for the file.
    pub fn to_ansi(&self) -> String {
        let mut out = String::new();
        let mut cur = Style::default();
        for (n, line) in self.lines().enumerate() {
            if n > 0 {
                out.push('\n');
            }
            for (c, st) in line {
                if *st != cur {
                    out.push_str(&sgr_for(*st));
                    cur = *st;
                }
                out.push(*c);
            }
        }
        if cur != Style::default() {
            out.push_str("\x1b[0m");
        }
        out
    }
}

fn sgr_for(s: Style) -> String {
    let mut p = vec!["0".to_string()];
    if s.bold {
        p.push("1".into());
    }
    if s.italic {
        p.push("3".into());
    }
    if s.underline {
        p.push("4".into());
    }
    if s.inverse {
        p.push("7".into());
    }
    let code = |r: u8, base: u8| {
        if r < 8 {
            (base + r).to_string()
        } else {
            (base + 60 + r - 8).to_string()
        }
    };
    if let Some(f) = s.fg {
        p.push(code(f, 30));
    }
    if let Some(b) = s.bg {
        p.push(code(b, 40));
    }
    format!("\x1b[{}m", p.join(";"))
}
