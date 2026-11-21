//! Reads through shell commands, layer 1: the files a command names (docs/develop/work-space.md, "Shell reads").
//!
//! [`parse`] is pure and table-driven: it reads the command text of a shell step and returns the words that name files,
//! sorted by what the command does with them (read, write, list, run as a script). [`resolve`] turns those words into
//! canonical paths against the step's working directory and keeps only the ones under the workspace's roots.
//!
//! What it cannot know is never guessed: `$(...)`, variables, `xargs` input, a `bash -c` inside a `bash -c`, a
//! heredoc and a subshell are left out and named in [`Parsed::skipped`].

use std::collections::HashSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// One word that names a file (or a directory to `cd` into), with what the resolver needs to place it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Word {
    pub text: String,
    /// Any part of the word was quoted: no `~` and no glob expansion then.
    pub quoted: bool,
    /// How many `cd`s ran before this word's command: the word's working directory is the start after `cds[..cds]`.
    pub cds: usize,
}

/// Why a piece of a command was left out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipKind {
    /// `$(...)` or backticks.
    Substitution,
    /// `$NAME` or `${...}`.
    Variable,
    /// `xargs`, `find -exec`, `fd -x`: the files come from elsewhere.
    Xargs,
    /// A `bash -c` inside a `bash -c`.
    NestedShell,
    /// `<<EOF`: the rest is the body.
    Heredoc,
    /// `( ... )`.
    Subshell,
    /// `for`, `case`, `function`.
    Control,
    /// A `cd` whose target is not known (`cd`, `cd -`, `cd $X`) or inside a nested `bash -c`.
    Cd,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skip {
    pub kind: SkipKind,
    pub text: String,
}

/// What [`parse`] found in one command.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Parsed {
    pub reads: Vec<Word>,
    pub writes: Vec<Word>,
    /// `ls`, `find`, `fd`, `tree`, and a recursive search without a path: the directory, not its files.
    pub listed: Vec<Word>,
    /// `cd X` in the order they ran; entry `i` has `cds == i`.
    pub cds: Vec<Word>,
    /// Scripts the command runs (`./x.sh`, `python y.py`): a read of the script, not of what it reads.
    pub scripts: Vec<Word>,
    pub skipped: Vec<Skip>,
}

/// What [`resolve`] keeps: canonical paths under the roots.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Resolved {
    /// Reads and scripts (a directory named as a read moves to `listed`).
    pub reads: Vec<PathBuf>,
    pub writes: Vec<PathBuf>,
    pub listed: Vec<PathBuf>,
    /// Globs and brace words that matched nothing, matched more than the cap, or could not be expanded.
    pub patterns: Vec<String>,
}

// ---------------------------------------------------------------------------------------------------------------
// Lexing

#[derive(Debug, Clone, PartialEq, Eq)]
struct Raw {
    text: String,
    quoted: bool,
    /// Holds a substitution or a variable: its value is unknown.
    dynamic: bool,
}

impl Raw {
    fn empty() -> Raw {
        Raw {
            text: String::new(),
            quoted: false,
            dynamic: false,
        }
    }
    fn plain(t: &str) -> Raw {
        Raw {
            text: t.to_string(),
            quoted: false,
            dynamic: false,
        }
    }
}

enum Tok {
    Word(Raw),
    Pipe,
    Break,
    /// `<`: the next word is read.
    In,
    /// `>`, `>>`, `&>`: the next word is written.
    Out,
    /// `>&`: the next word is written unless it is a descriptor.
    Dup,
    /// `<<<`, `<&`: the next word is not a file.
    Ignore,
}

struct Lexed {
    toks: Vec<Tok>,
    skipped: Vec<Skip>,
}

fn flush(cur: &mut Option<Raw>, toks: &mut Vec<Tok>) {
    if let Some(r) = cur.take() {
        toks.push(Tok::Word(r));
    }
}

fn is_fd(cur: &Option<Raw>) -> bool {
    cur.as_ref().is_some_and(|r| {
        !r.quoted && !r.text.is_empty() && r.text.bytes().all(|b| b.is_ascii_digit())
    })
}

/// Index after the `)` that closes the `(` at `i`.
fn skip_parens(cs: &[char], i: usize) -> usize {
    let mut depth = 0usize;
    let mut j = i;
    while j < cs.len() {
        match cs[j] {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return j + 1;
                }
            }
            _ => {}
        }
        j += 1;
    }
    cs.len()
}

/// Index after the character `close` that follows `i` (or the end).
fn skip_to(cs: &[char], i: usize, close: char) -> usize {
    let mut j = i;
    while j < cs.len() && cs[j] != close {
        j += 1;
    }
    (j + 1).min(cs.len())
}

/// Handle a `$` at `cs[*i]`.
fn dollar(cs: &[char], i: &mut usize, r: &mut Raw) {
    match cs.get(*i + 1) {
        Some('(') => {
            r.dynamic = true;
            r.text.push_str("$(");
            *i = skip_parens(cs, *i + 1);
        }
        Some('{') => {
            r.dynamic = true;
            r.text.push_str("${");
            *i = skip_to(cs, *i + 1, '}');
        }
        Some(c) if !c.is_whitespace() && !matches!(c, '"' | '\'') => {
            r.dynamic = true;
            r.text.push('$');
            *i += 1;
        }
        _ => {
            r.text.push('$');
            *i += 1;
        }
    }
}

fn lex(src: &str) -> Lexed {
    let cs: Vec<char> = src.chars().collect();
    let mut toks = Vec::new();
    let mut skipped = Vec::new();
    let mut cur: Option<Raw> = None;
    let mut i = 0;
    'outer: while i < cs.len() {
        let c = cs[i];
        match c {
            ' ' | '\t' | '\r' => {
                flush(&mut cur, &mut toks);
                i += 1;
            }
            '\n' => {
                flush(&mut cur, &mut toks);
                toks.push(Tok::Break);
                i += 1;
            }
            '#' if cur.is_none() => {
                while i < cs.len() && cs[i] != '\n' {
                    i += 1;
                }
            }
            '\'' => {
                let r = cur.get_or_insert_with(Raw::empty);
                r.quoted = true;
                i += 1;
                while i < cs.len() && cs[i] != '\'' {
                    r.text.push(cs[i]);
                    i += 1;
                }
                i += 1;
            }
            '"' => {
                let r = cur.get_or_insert_with(Raw::empty);
                r.quoted = true;
                i += 1;
                while i < cs.len() && cs[i] != '"' {
                    match cs[i] {
                        '\\' if i + 1 < cs.len() && matches!(cs[i + 1], '"' | '\\' | '$' | '`') => {
                            r.text.push(cs[i + 1]);
                            i += 2;
                        }
                        '$' => dollar(&cs, &mut i, r),
                        '`' => {
                            r.dynamic = true;
                            r.text.push('`');
                            i = skip_to(&cs, i + 1, '`');
                        }
                        ch => {
                            r.text.push(ch);
                            i += 1;
                        }
                    }
                }
                i += 1;
            }
            '\\' => {
                let r = cur.get_or_insert_with(Raw::empty);
                match cs.get(i + 1) {
                    Some('\n') => i += 2,
                    Some(&n) => {
                        if matches!(n, '*' | '?' | '[' | '~') {
                            r.quoted = true;
                        }
                        r.text.push(n);
                        i += 2;
                    }
                    None => i += 1,
                }
            }
            '`' => {
                let r = cur.get_or_insert_with(Raw::empty);
                r.dynamic = true;
                r.text.push('`');
                i = skip_to(&cs, i + 1, '`');
            }
            '$' => {
                let r = cur.get_or_insert_with(Raw::empty);
                dollar(&cs, &mut i, r);
            }
            '|' => {
                flush(&mut cur, &mut toks);
                match cs.get(i + 1) {
                    Some('|') => {
                        toks.push(Tok::Break);
                        i += 2;
                    }
                    Some('&') => {
                        toks.push(Tok::Pipe);
                        i += 2;
                    }
                    _ => {
                        toks.push(Tok::Pipe);
                        i += 1;
                    }
                }
            }
            ';' => {
                flush(&mut cur, &mut toks);
                toks.push(Tok::Break);
                i += 1;
            }
            '&' => {
                flush(&mut cur, &mut toks);
                match cs.get(i + 1) {
                    Some('&') => {
                        toks.push(Tok::Break);
                        i += 2;
                    }
                    Some('>') => {
                        toks.push(Tok::Out);
                        i += 2;
                        if cs.get(i) == Some(&'>') {
                            i += 1;
                        }
                    }
                    _ => {
                        toks.push(Tok::Break);
                        i += 1;
                    }
                }
            }
            '(' | ')' => {
                flush(&mut cur, &mut toks);
                skipped.push(Skip {
                    kind: SkipKind::Subshell,
                    text: "(".into(),
                });
                break 'outer;
            }
            '<' => {
                if is_fd(&cur) {
                    cur = None;
                } else {
                    flush(&mut cur, &mut toks);
                }
                match cs.get(i + 1) {
                    Some('<') => {
                        if cs.get(i + 2) == Some(&'<') {
                            toks.push(Tok::Ignore);
                            i += 3;
                        } else {
                            skipped.push(Skip {
                                kind: SkipKind::Heredoc,
                                text: "<<".into(),
                            });
                            break 'outer;
                        }
                    }
                    Some('(') => {
                        skipped.push(Skip {
                            kind: SkipKind::Substitution,
                            text: "<(".into(),
                        });
                        break 'outer;
                    }
                    Some('&') => {
                        toks.push(Tok::Ignore);
                        i += 2;
                    }
                    Some('>') => {
                        toks.push(Tok::In);
                        i += 2;
                    }
                    _ => {
                        toks.push(Tok::In);
                        i += 1;
                    }
                }
            }
            '>' => {
                if is_fd(&cur) {
                    cur = None;
                } else {
                    flush(&mut cur, &mut toks);
                }
                match cs.get(i + 1) {
                    Some('>') | Some('|') => {
                        toks.push(Tok::Out);
                        i += 2;
                    }
                    Some('&') => {
                        toks.push(Tok::Dup);
                        i += 2;
                    }
                    Some('(') => {
                        skipped.push(Skip {
                            kind: SkipKind::Substitution,
                            text: ">(".into(),
                        });
                        break 'outer;
                    }
                    _ => {
                        toks.push(Tok::Out);
                        i += 1;
                    }
                }
            }
            ch => {
                cur.get_or_insert_with(Raw::empty).text.push(ch);
                i += 1;
            }
        }
    }
    flush(&mut cur, &mut toks);
    Lexed { toks, skipped }
}

#[derive(Clone, Copy)]
enum Rk {
    In,
    Out,
    Dup,
    Ignore,
}

struct Seg {
    piped: bool,
    words: Vec<Raw>,
    redirs: Vec<(Rk, Raw)>,
}

fn segments(toks: Vec<Tok>) -> Vec<Seg> {
    let new = |piped| Seg {
        piped,
        words: Vec::new(),
        redirs: Vec::new(),
    };
    let mut out = Vec::new();
    let mut cur = new(false);
    let mut pending: Option<Rk> = None;
    for t in toks {
        match t {
            Tok::Word(w) => match pending.take() {
                Some(rk) => cur.redirs.push((rk, w)),
                None => cur.words.push(w),
            },
            Tok::Pipe | Tok::Break => {
                pending = None;
                let piped = matches!(t, Tok::Pipe);
                out.push(std::mem::replace(&mut cur, new(piped)));
            }
            Tok::In => pending = Some(Rk::In),
            Tok::Out => pending = Some(Rk::Out),
            Tok::Dup => pending = Some(Rk::Dup),
            Tok::Ignore => pending = Some(Rk::Ignore),
        }
    }
    out.push(cur);
    out
}

// ---------------------------------------------------------------------------------------------------------------
// Option scanning

/// Which options of a command take a value.
struct Spec {
    /// Short letters that take the next word (or the rest of their cluster).
    short: &'static str,
    /// Short letters whose value is only ever attached (`sed -i.bak`): the rest of the cluster.
    attached: &'static str,
    /// Long options that take `n` words (or `=value`).
    long: &'static [(&'static str, usize)],
}

const NO_OPTS: Spec = Spec {
    short: "",
    attached: "",
    long: &[],
};

#[derive(Default)]
struct Opts {
    flags: Vec<char>,
    longs: Vec<String>,
    /// `(option, position among its values, value)`
    vals: Vec<(String, usize, Raw)>,
    operands: Vec<Raw>,
}

impl Opts {
    fn flag(&self, c: char) -> bool {
        self.flags.contains(&c)
    }
    fn long(&self, n: &str) -> bool {
        self.longs.iter().any(|l| l == n)
    }
    fn has(&self, keys: &[&str]) -> bool {
        self.vals.iter().any(|(k, _, _)| keys.contains(&k.as_str()))
    }
    fn vals_of<'a>(&'a self, keys: &'a [&'a str]) -> impl Iterator<Item = &'a Raw> + 'a {
        self.vals
            .iter()
            .filter(move |(k, _, _)| keys.contains(&k.as_str()))
            .map(|(_, _, v)| v)
    }
}

fn scan(args: &[Raw], spec: &Spec) -> Opts {
    let mut o = Opts::default();
    let mut i = 0;
    let mut only_operands = false;
    while i < args.len() {
        let a = &args[i];
        i += 1;
        if only_operands || a.dynamic || a.text == "-" || !a.text.starts_with('-') {
            o.operands.push(a.clone());
            continue;
        }
        if a.text == "--" {
            only_operands = true;
            continue;
        }
        if let Some(long) = a.text.strip_prefix("--") {
            let (name, inline) = match long.split_once('=') {
                Some((n, v)) => (n, Some(v)),
                None => (long, None),
            };
            o.longs.push(name.to_string());
            if let Some(&(_, n)) = spec.long.iter().find(|(l, _)| *l == name) {
                if let Some(v) = inline {
                    o.vals.push((name.to_string(), 0, Raw::plain(v)));
                } else {
                    for k in 0..n {
                        if i < args.len() {
                            o.vals.push((name.to_string(), k, args[i].clone()));
                            i += 1;
                        }
                    }
                }
            }
            continue;
        }
        let chars: Vec<char> = a.text[1..].chars().collect();
        let mut k = 0;
        while k < chars.len() {
            let c = chars[k];
            k += 1;
            o.flags.push(c);
            if spec.attached.contains(c) {
                break;
            }
            if spec.short.contains(c) {
                if k < chars.len() {
                    let rest: String = chars[k..].iter().collect();
                    o.vals.push((c.to_string(), 0, Raw::plain(&rest)));
                } else if i < args.len() {
                    o.vals.push((c.to_string(), 0, args[i].clone()));
                    i += 1;
                }
                break;
            }
        }
    }
    o
}

// ---------------------------------------------------------------------------------------------------------------
// The parser

#[derive(Clone, Copy)]
enum L {
    // where a word goes in `Parsed`
    Read,
    Write,
    Listed,
    Script,
}

struct P {
    out: Parsed,
    depth: u8,
    stopped: bool,
}

fn is_assignment(r: &Raw) -> bool {
    if r.quoted {
        return false;
    }
    match r.text.split_once('=') {
        Some((name, _)) => {
            !name.is_empty()
                && !name.as_bytes()[0].is_ascii_digit()
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        }
        None => false,
    }
}

const SYSTEM_DIRS: [&str; 5] = [
    "/bin/",
    "/usr/bin/",
    "/usr/local/bin/",
    "/sbin/",
    "/usr/sbin/",
];

const INTERPRETERS: [&str; 8] = [
    "python", "python3", "python2", "node", "nodejs", "ruby", "perl", "lua",
];
const SHELLS: [&str; 5] = ["bash", "sh", "zsh", "dash", "ksh"];

impl P {
    fn word(&self, r: &Raw) -> Word {
        Word {
            text: r.text.clone(),
            quoted: r.quoted,
            cds: self.out.cds.len(),
        }
    }

    fn skip(&mut self, kind: SkipKind, text: &str) {
        let text: String = text.chars().take(80).collect();
        self.out.skipped.push(Skip { kind, text });
    }

    fn skip_dynamic(&mut self, r: &Raw) {
        let kind = if r.text.contains("$(") || r.text.contains('`') {
            SkipKind::Substitution
        } else {
            SkipKind::Variable
        };
        self.skip(kind, &r.text);
    }

    fn file(&mut self, l: L, r: &Raw) {
        if r.dynamic {
            self.skip_dynamic(r);
            return;
        }
        if r.text.is_empty() {
            return;
        }
        let w = self.word(r);
        match l {
            L::Read => self.out.reads.push(w),
            L::Write => self.out.writes.push(w),
            L::Listed => self.out.listed.push(w),
            L::Script => self.out.scripts.push(w),
        }
    }

    fn files<'a>(&mut self, l: L, rs: impl IntoIterator<Item = &'a Raw>) {
        for r in rs {
            self.file(l, r);
        }
    }

    fn run(&mut self, src: &str) {
        let lx = lex(src);
        self.out.skipped.extend(lx.skipped);
        for seg in segments(lx.toks) {
            self.seg(seg);
            if self.stopped {
                break;
            }
        }
    }

    fn seg(&mut self, seg: Seg) {
        for (rk, w) in &seg.redirs {
            match rk {
                Rk::In => self.file(L::Read, w),
                Rk::Out => self.file(L::Write, w),
                Rk::Dup => {
                    if !(w.text == "-"
                        || (!w.text.is_empty() && w.text.bytes().all(|b| b.is_ascii_digit())))
                    {
                        self.file(L::Write, w);
                    }
                }
                Rk::Ignore => {}
            }
        }
        let mut ws: &[Raw] = &seg.words;
        // Leading assignments and words that only wrap or sequence another command.
        loop {
            let Some(h) = ws.first() else { return };
            if is_assignment(h) {
                ws = &ws[1..];
                continue;
            }
            match h.text.as_str() {
                "do" | "then" | "else" | "elif" | "if" | "while" | "until" | "!" | "time"
                | "nohup" | "command" | "exec" | "builtin" | "{" | "}" => {
                    ws = &ws[1..];
                }
                "done" | "fi" | "esac" | "in" => return,
                "for" | "case" | "select" | "function" => {
                    let t = ws
                        .iter()
                        .map(|r| r.text.as_str())
                        .collect::<Vec<_>>()
                        .join(" ");
                    self.skip(SkipKind::Control, &t);
                    return;
                }
                "env" => {
                    ws = &ws[1..];
                    while let Some(n) = ws.first() {
                        if is_assignment(n) || (n.text.starts_with('-') && n.text.len() > 1) {
                            let takes = matches!(n.text.as_str(), "-u" | "-C" | "-S");
                            ws = &ws[if takes { 2.min(ws.len()) } else { 1 }..];
                        } else {
                            break;
                        }
                    }
                }
                "timeout" => {
                    ws = &ws[1..];
                    while let Some(n) = ws.first() {
                        if n.text.starts_with('-') && n.text.len() > 1 {
                            let takes = matches!(n.text.as_str(), "-s" | "-k");
                            ws = &ws[if takes { 2.min(ws.len()) } else { 1 }..];
                        } else {
                            break;
                        }
                    }
                    if !ws.is_empty() {
                        ws = &ws[1..]; // the duration
                    }
                }
                "nice" => {
                    ws = &ws[1..];
                    if let Some(n) = ws.first() {
                        if n.text == "-n" {
                            ws = &ws[2.min(ws.len())..];
                        } else if n.text.starts_with('-') {
                            ws = &ws[1..];
                        }
                    }
                }
                _ => break,
            }
        }
        let head = &ws[0];
        if head.dynamic {
            self.skip_dynamic(head);
            return;
        }
        let args = &ws[1..];
        let text = head.text.as_str();
        if text.contains('/') {
            if let Some(base) = SYSTEM_DIRS.iter().find_map(|d| text.strip_prefix(d)) {
                let base = base.to_string();
                self.command(&base, args, seg.piped);
            } else {
                self.file(L::Script, head);
            }
            return;
        }
        self.command(text, args, seg.piped);
    }

    fn command(&mut self, name: &str, args: &[Raw], piped: bool) {
        match name {
            "cd" | "pushd" => self.cd(args),
            "xargs" => {
                self.skip(SkipKind::Xargs, "xargs");
            }
            "tee" => {
                let o = scan(args, &NO_OPTS);
                self.files(L::Write, &o.operands);
            }
            "cat" | "tac" | "less" | "more" | "bat" | "batcat" | "wc" | "head" | "tail" | "cut"
            | "sort" | "nl" => {
                let spec = match name {
                    "head" => Spec {
                        short: "nc",
                        attached: "",
                        long: &[("lines", 1), ("bytes", 1)],
                    },
                    "tail" => Spec {
                        short: "ncs",
                        attached: "",
                        long: &[("lines", 1), ("bytes", 1), ("sleep-interval", 1)],
                    },
                    "cut" => Spec {
                        short: "dfcb",
                        attached: "",
                        long: &[
                            ("delimiter", 1),
                            ("fields", 1),
                            ("characters", 1),
                            ("bytes", 1),
                        ],
                    },
                    "sort" => Spec {
                        short: "kTtSo",
                        attached: "",
                        long: &[
                            ("key", 1),
                            ("field-separator", 1),
                            ("temporary-directory", 1),
                            ("buffer-size", 1),
                            ("output", 1),
                            ("files0-from", 1),
                        ],
                    },
                    "wc" => Spec {
                        short: "",
                        attached: "",
                        long: &[("files0-from", 1)],
                    },
                    "less" => Spec {
                        short: "pPt",
                        attached: "",
                        long: &[],
                    },
                    "more" => Spec {
                        short: "n",
                        attached: "",
                        long: &[],
                    },
                    _ => NO_OPTS,
                };
                let o = scan(args, &spec);
                self.files(L::Read, &o.operands);
                self.files(L::Read, o.vals_of(&["files0-from"]));
                self.files(L::Write, o.vals_of(&["o", "output"]));
            }
            "diff" => {
                let spec = Spec {
                    short: "UCFIxL",
                    attached: "",
                    long: &[
                        ("label", 1),
                        ("ignore-matching-lines", 1),
                        ("exclude", 1),
                        ("from-file", 1),
                        ("to-file", 1),
                    ],
                };
                let o = scan(args, &spec);
                self.files(L::Read, &o.operands);
            }
            "jq" => {
                let spec = Spec {
                    short: "fL",
                    attached: "",
                    long: &[
                        ("arg", 2),
                        ("argjson", 2),
                        ("slurpfile", 2),
                        ("rawfile", 2),
                        ("from-file", 1),
                        ("indent", 1),
                    ],
                };
                let o = scan(args, &spec);
                let prog_file = o.has(&["f", "from-file"]);
                self.files(L::Read, o.vals_of(&["f", "from-file"]));
                for (k, idx, v) in &o.vals {
                    if (k == "slurpfile" || k == "rawfile") && *idx == 1 {
                        self.file(L::Read, v);
                    }
                }
                if !(o.long("args") || o.long("jsonargs")) {
                    let skip = if prog_file { 0 } else { 1 };
                    self.files(L::Read, o.operands.iter().skip(skip));
                }
            }
            "grep" | "egrep" | "fgrep" | "rg" | "ag" | "ack" => self.grep(name, args, piped),
            "sed" => {
                let spec = Spec {
                    short: "efl",
                    attached: "i",
                    long: &[("expression", 1), ("file", 1), ("line-length", 1)],
                };
                let o = scan(args, &spec);
                let script = o.has(&["e", "expression", "f", "file"]);
                self.files(L::Read, o.vals_of(&["f", "file"]));
                let in_place = o.flag('i') || o.long("in-place");
                let l = if in_place { L::Write } else { L::Read };
                self.files(l, o.operands.iter().skip(if script { 0 } else { 1 }));
            }
            "awk" | "gawk" | "mawk" | "nawk" => {
                let spec = Spec {
                    short: "Fvfei",
                    attached: "",
                    long: &[
                        ("field-separator", 1),
                        ("assign", 1),
                        ("file", 1),
                        ("source", 1),
                        ("include", 1),
                    ],
                };
                let o = scan(args, &spec);
                let prog = o.has(&["f", "file", "e", "source"]);
                self.files(L::Read, o.vals_of(&["f", "file"]));
                let rest = o.operands.iter().skip(if prog { 0 } else { 1 });
                for r in rest {
                    if !is_assignment(r) {
                        self.file(L::Read, r);
                    }
                }
            }
            "find" => self.find(args),
            "fd" | "fdfind" => {
                let spec = Spec {
                    short: "teEdScjo",
                    attached: "",
                    long: &[
                        ("type", 1),
                        ("extension", 1),
                        ("exclude", 1),
                        ("max-depth", 1),
                        ("min-depth", 1),
                        ("exact-depth", 1),
                        ("size", 1),
                        ("color", 1),
                        ("threads", 1),
                        ("owner", 1),
                        ("changed-within", 1),
                        ("changed-before", 1),
                        ("search-path", 1),
                        ("base-directory", 1),
                        ("ignore-file", 1),
                    ],
                };
                let o = scan(args, &spec);
                if o.flag('x') || o.flag('X') || o.long("exec") || o.long("exec-batch") {
                    self.skip(SkipKind::Xargs, "fd -x");
                    return;
                }
                let before = self.out.listed.len();
                self.files(L::Listed, o.vals_of(&["search-path"]));
                self.files(L::Listed, o.operands.iter().skip(1));
                if self.out.listed.len() == before {
                    self.file(L::Listed, &Raw::plain("."));
                }
            }
            "ls" | "tree" => {
                let spec = if name == "ls" {
                    Spec {
                        short: "wTI",
                        attached: "",
                        long: &[
                            ("width", 1),
                            ("tabsize", 1),
                            ("ignore", 1),
                            ("block-size", 1),
                            ("time-style", 1),
                            ("sort", 1),
                            ("format", 1),
                            ("time", 1),
                            ("indicator-style", 1),
                            ("hide", 1),
                            ("quoting-style", 1),
                        ],
                    }
                } else {
                    Spec {
                        short: "LPIo",
                        attached: "",
                        long: &[
                            ("filelimit", 1),
                            ("charset", 1),
                            ("sort", 1),
                            ("timefmt", 1),
                        ],
                    }
                };
                let o = scan(args, &spec);
                if o.operands.is_empty() {
                    self.file(L::Listed, &Raw::plain("."));
                } else {
                    self.files(L::Listed, &o.operands);
                }
            }
            "source" | "." => {
                let o = scan(args, &NO_OPTS);
                if let Some(r) = o.operands.first() {
                    self.file(L::Script, r);
                }
            }
            n if SHELLS.contains(&n) => self.shell(args),
            n if INTERPRETERS.contains(&n) => {
                // The first word that is not an option (or an option's value) is the script; `-c`, `-m`, `-e` run text.
                let mut i = 0;
                while i < args.len() {
                    let a = &args[i];
                    i += 1;
                    match a.text.as_str() {
                        "-c" | "-m" | "-e" | "-p" | "-E" | "--eval" | "--print" => return,
                        "-W" | "-X" | "-r" | "-I" | "--require" | "--import" => i += 1,
                        t if t.starts_with('-') && !a.dynamic => {}
                        _ => {
                            self.file(L::Script, a);
                            return;
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn cd(&mut self, args: &[Raw]) {
        let o = scan(args, &NO_OPTS);
        match o.operands.first() {
            Some(r) if !r.dynamic && r.text != "-" && !r.text.is_empty() => {
                if self.depth > 0 {
                    self.skip(SkipKind::Cd, &r.text);
                    self.stopped = true;
                } else {
                    let w = self.word(r);
                    self.out.cds.push(w);
                }
            }
            Some(r) => {
                let t = r.text.clone();
                self.skip(SkipKind::Cd, &t);
                self.stopped = true;
            }
            None => {
                self.skip(SkipKind::Cd, "cd");
                self.stopped = true;
            }
        }
    }

    fn shell(&mut self, args: &[Raw]) {
        let o = scan(
            args,
            &Spec {
                short: "oO",
                attached: "",
                long: &[("rcfile", 1), ("init-file", 1)],
            },
        );
        if o.flag('c') {
            let Some(cmd) = o.operands.first() else {
                return;
            };
            if self.depth >= 1 {
                self.skip(SkipKind::NestedShell, &cmd.text);
                return;
            }
            if cmd.dynamic {
                self.skip_dynamic(cmd);
                return;
            }
            let text = cmd.text.clone();
            self.depth += 1;
            let was_stopped = self.stopped;
            self.run(&text);
            self.stopped = was_stopped;
            self.depth -= 1;
        } else if let Some(r) = o.operands.first() {
            self.file(L::Script, r);
        }
    }

    fn grep(&mut self, name: &str, args: &[Raw], piped: bool) {
        let spec = match name {
            "rg" => Spec {
                short: "efgmABCtTjMEr",
                attached: "",
                long: &[
                    ("regexp", 1),
                    ("file", 1),
                    ("glob", 1),
                    ("iglob", 1),
                    ("max-count", 1),
                    ("type", 1),
                    ("type-not", 1),
                    ("after-context", 1),
                    ("before-context", 1),
                    ("context", 1),
                    ("threads", 1),
                    ("max-columns", 1),
                    ("encoding", 1),
                    ("replace", 1),
                    ("max-depth", 1),
                    ("pre", 1),
                ],
            },
            "ag" => Spec {
                short: "ABCGgm",
                attached: "",
                long: &[("depth", 1), ("file-search-regex", 1)],
            },
            "ack" => Spec {
                short: "ABCm",
                attached: "",
                long: &[("type", 1), ("match", 1)],
            },
            _ => Spec {
                short: "efmABCdD",
                attached: "",
                long: &[
                    ("regexp", 1),
                    ("file", 1),
                    ("max-count", 1),
                    ("after-context", 1),
                    ("before-context", 1),
                    ("context", 1),
                    ("include", 1),
                    ("exclude", 1),
                    ("exclude-dir", 1),
                    ("directories", 1),
                    ("devices", 1),
                    ("binary-files", 1),
                    ("label", 1),
                ],
            },
        };
        let o = scan(args, &spec);
        let files_mode = name == "rg" && o.long("files");
        let pattern_given = match name {
            "ag" => o.has(&["g"]),
            "ack" => o.has(&["match"]),
            _ => o.has(&["e", "regexp", "f", "file"]),
        };
        if matches!(name, "grep" | "egrep" | "fgrep" | "rg") {
            self.files(L::Read, o.vals_of(&["f", "file"]));
        }
        let skip = if pattern_given || files_mode { 0 } else { 1 };
        let before = self.out.reads.len() + self.out.listed.len();
        let l = if files_mode { L::Listed } else { L::Read };
        self.files(l, o.operands.iter().skip(skip));
        let no_paths = self.out.reads.len() + self.out.listed.len() == before;
        if no_paths && !piped {
            let recursive = match name {
                "rg" | "ag" | "ack" => true,
                _ => {
                    o.flag('r')
                        || o.flag('R')
                        || o.long("recursive")
                        || o.long("dereference-recursive")
                }
            };
            if recursive {
                self.file(L::Listed, &Raw::plain("."));
            }
        }
    }

    fn find(&mut self, args: &[Raw]) {
        let mut i = 0;
        while i < args.len() && matches!(args[i].text.as_str(), "-H" | "-L" | "-P") {
            i += 1;
        }
        let mut any = false;
        while i < args.len() {
            let a = &args[i];
            if !a.dynamic
                && (a.text.starts_with('-') || matches!(a.text.as_str(), "(" | "!" | ")" | ","))
            {
                break;
            }
            self.file(L::Listed, a);
            any = true;
            i += 1;
        }
        if !any {
            self.file(L::Listed, &Raw::plain("."));
        }
        if args[i.min(args.len())..]
            .iter()
            .any(|a| matches!(a.text.as_str(), "-exec" | "-execdir" | "-ok" | "-okdir"))
        {
            self.skip(SkipKind::Xargs, "find -exec");
        }
    }
}

/// The files a shell command names, by what it does with them. Never panics; the same text gives the same answer.
pub fn parse(cmd: &str) -> Parsed {
    let mut p = P {
        out: Parsed::default(),
        depth: 0,
        stopped: false,
    };
    p.run(cmd);
    p.out
}

// ---------------------------------------------------------------------------------------------------------------
// Resolving

/// Canonical paths of what a parsed command names, against `cwd`, under `roots` only. At most `glob_cap` paths come
/// from globs in all; a glob over the cap, one that matches nothing and a brace word go to `patterns`.
pub fn resolve(p: &Parsed, cwd: &Path, roots: &[PathBuf], glob_cap: usize) -> Resolved {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    resolve_with_home(p, cwd, roots, glob_cap, home.as_deref())
}

/// [`resolve`] with the home directory given (for tests and for a hub that knows its user's).
pub fn resolve_with_home(
    p: &Parsed,
    cwd: &Path,
    roots: &[PathBuf],
    glob_cap: usize,
    home: Option<&Path>,
) -> Resolved {
    let roots: Vec<PathBuf> = roots
        .iter()
        .filter_map(|r| std::fs::canonicalize(r).ok())
        .collect();
    let mut cwds: Vec<Option<PathBuf>> = vec![Some(realpath(cwd))];
    for (i, cd) in p.cds.iter().enumerate() {
        let next = cwds
            .get(i)
            .and_then(|c| c.as_ref())
            .and_then(|base| target(cd, base, home))
            .map(|t| realpath(&t))
            .filter(|r| r.is_dir());
        cwds.push(next);
    }
    let mut budget = glob_cap;
    let mut out = Resolved::default();
    let mut reads = collect(
        &p.reads,
        &cwds,
        &roots,
        home,
        &mut budget,
        &mut out.patterns,
    );
    reads.extend(collect(
        &p.scripts,
        &cwds,
        &roots,
        home,
        &mut budget,
        &mut out.patterns,
    ));
    let mut listed = collect(
        &p.listed,
        &cwds,
        &roots,
        home,
        &mut budget,
        &mut out.patterns,
    );
    let writes = collect(
        &p.writes,
        &cwds,
        &roots,
        home,
        &mut budget,
        &mut out.patterns,
    );
    // A read or a listing of something that is not there is no read; a write may create its file.
    let (dirs, files): (Vec<_>, Vec<_>) = reads.into_iter().partition(|r| r.is_dir());
    listed.extend(dirs);
    out.reads = dedup(files.into_iter().filter(|r| r.exists()).collect());
    out.listed = dedup(listed.into_iter().filter(|r| r.exists()).collect());
    out.writes = dedup(writes);
    out
}

fn dedup(v: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    v.into_iter().filter(|p| seen.insert(p.clone())).collect()
}

fn target(w: &Word, base: &Path, home: Option<&Path>) -> Option<PathBuf> {
    let t = w.text.as_str();
    if t.is_empty() {
        return None;
    }
    if !w.quoted && t.starts_with('~') {
        let home = home?;
        return match t {
            "~" => Some(home.to_path_buf()),
            _ => t.strip_prefix("~/").map(|rest| home.join(rest)),
        };
    }
    let p = Path::new(t);
    Some(if p.is_absolute() {
        p.to_path_buf()
    } else {
        base.join(p)
    })
}

fn has_glob(t: &str) -> bool {
    t.contains(['*', '?', '['])
}

fn collect(
    words: &[Word],
    cwds: &[Option<PathBuf>],
    roots: &[PathBuf],
    home: Option<&Path>,
    budget: &mut usize,
    patterns: &mut Vec<String>,
) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let keep = |c: &Path, out: &mut Vec<PathBuf>| {
        let r = realpath(c);
        if roots.iter().any(|root| r.starts_with(root)) {
            out.push(r);
        }
    };
    for w in words {
        let Some(base) = cwds.get(w.cds).and_then(|c| c.as_ref()) else {
            continue;
        };
        let Some(t) = target(w, base, home) else {
            continue;
        };
        if !w.quoted && w.text.contains('{') && w.text.contains(',') {
            patterns.push(w.text.clone());
        } else if !w.quoted && has_glob(&w.text) {
            let (matches, over) = expand(&t, *budget);
            *budget -= matches.len();
            if matches.is_empty() || over {
                patterns.push(w.text.clone());
            }
            for m in &matches {
                keep(m, &mut out);
            }
        } else {
            keep(&t, &mut out);
        }
    }
    out
}

/// The tail of a path that does not exist yet is joined, lexically, onto the real path of its longest existing part, so
/// a symlink on the way is followed and a `..` cannot hide where it lands.
fn realpath(p: &Path) -> PathBuf {
    if let Ok(c) = std::fs::canonicalize(p) {
        return c;
    }
    let mut cur = p.to_path_buf();
    let mut tail: Vec<OsString> = Vec::new();
    loop {
        if let Ok(c) = std::fs::canonicalize(&cur) {
            cur = c;
            break;
        }
        match cur.file_name() {
            Some(n) => tail.push(n.to_os_string()),
            None => {
                if cur.parent().is_none() {
                    break;
                }
                tail.push(OsString::from(".."));
            }
        }
        if !cur.pop() {
            break;
        }
    }
    for c in tail.iter().rev() {
        if c == ".." {
            cur.pop();
        } else {
            cur.push(c);
        }
    }
    cur
}

/// Matches of `pat` (absolute) in name order, at most `limit`; `true` when there were more.
fn expand(pat: &Path, limit: usize) -> (Vec<PathBuf>, bool) {
    let comps: Vec<String> = pat
        .components()
        .map(|c| match c {
            std::path::Component::RootDir => "/".to_string(),
            other => other.as_os_str().to_string_lossy().into_owned(),
        })
        .collect();
    if comps.iter().any(|c| c == "**") {
        return (Vec::new(), false);
    }
    let mut out = Vec::new();
    let mut over = false;
    walk(PathBuf::new(), &comps, limit, &mut out, &mut over);
    (out, over)
}

fn walk(cur: PathBuf, comps: &[String], limit: usize, out: &mut Vec<PathBuf>, over: &mut bool) {
    if *over {
        return;
    }
    let Some((c, rest)) = comps.split_first() else {
        if cur.symlink_metadata().is_ok() {
            if out.len() >= limit {
                *over = true;
            } else {
                out.push(cur);
            }
        }
        return;
    };
    if !has_glob(c) {
        walk(cur.join(c), rest, limit, out, over);
        return;
    }
    let Ok(rd) = std::fs::read_dir(&cur) else {
        return;
    };
    let mut names: Vec<String> = rd
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let pc: Vec<char> = c.chars().collect();
    for n in names {
        if n.starts_with('.') && !c.starts_with('.') {
            continue;
        }
        let nc: Vec<char> = n.chars().collect();
        if glob_match(&pc, &nc) {
            walk(cur.join(&n), rest, limit, out, over);
            if *over {
                return;
            }
        }
    }
}

/// `[...]` at `p[pi]` against `ch`: `(matched, index after the class)`, `None` when the class is not closed.
fn class(p: &[char], pi: usize, ch: char) -> Option<(bool, usize)> {
    let mut j = pi + 1;
    let neg = matches!(p.get(j), Some('!') | Some('^'));
    if neg {
        j += 1;
    }
    let mut matched = false;
    let mut first = true;
    while j < p.len() {
        if p[j] == ']' && !first {
            return Some((matched != neg, j + 1));
        }
        first = false;
        if j + 2 < p.len() && p[j + 1] == '-' && p[j + 2] != ']' {
            if p[j] <= ch && ch <= p[j + 2] {
                matched = true;
            }
            j += 3;
        } else {
            if p[j] == ch {
                matched = true;
            }
            j += 1;
        }
    }
    None
}

fn glob_match(p: &[char], s: &[char]) -> bool {
    let (mut pi, mut si) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while si < s.len() {
        if pi < p.len() {
            match p[pi] {
                '*' => {
                    star = Some((pi, si));
                    pi += 1;
                    continue;
                }
                '?' => {
                    pi += 1;
                    si += 1;
                    continue;
                }
                '[' => match class(p, pi, s[si]) {
                    Some((true, next)) => {
                        pi = next;
                        si += 1;
                        continue;
                    }
                    Some((false, _)) => {}
                    None => {
                        if s[si] == '[' {
                            pi += 1;
                            si += 1;
                            continue;
                        }
                    }
                },
                '\\' if pi + 1 < p.len() => {
                    if p[pi + 1] == s[si] {
                        pi += 2;
                        si += 1;
                        continue;
                    }
                }
                c => {
                    if c == s[si] {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                }
            }
        }
        match star {
            Some((sp, ss)) => {
                pi = sp + 1;
                si = ss + 1;
                star = Some((sp, ss + 1));
            }
            None => return false,
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    const CORPUS: &str = include_str!("shell_read/corpus.txt");

    fn texts(ws: &[Word]) -> Vec<&str> {
        ws.iter().map(|w| w.text.as_str()).collect()
    }

    #[test]
    fn pipes_and_chains() {
        let p =
            parse("cat a.txt | grep foo b.txt && head -n 5 c.txt; tail -3 d.txt || wc -l e.txt");
        assert_eq!(
            texts(&p.reads),
            ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]
        );
        assert!(p.writes.is_empty() && p.skipped.is_empty());
        // stdin from a pipe is not a file
        assert!(parse("ls | head -n 3").reads.is_empty());
    }

    #[test]
    fn redirect_in_is_a_read_out_is_a_write() {
        let p = parse("sort < in.txt > out.txt 2>err.log >> log.txt");
        assert_eq!(texts(&p.reads), ["in.txt"]);
        assert_eq!(texts(&p.writes), ["out.txt", "err.log", "log.txt"]);
        let q = parse("cat x.txt 2>&1 >&2 &> all.log");
        assert_eq!(texts(&q.reads), ["x.txt"]);
        assert_eq!(texts(&q.writes), ["all.log"]);
    }

    #[test]
    fn leading_cd_moves_the_cwd() {
        let p = parse("cd src && cat main.rs; cd ../docs && head -n 2 a.md");
        assert_eq!(texts(&p.cds), ["src", "../docs"]);
        assert_eq!((p.cds[0].cds, p.cds[1].cds), (0, 1));
        assert_eq!((p.reads[0].cds, p.reads[1].cds), (1, 2));
        assert!(
            parse("cd - && cat x")
                .skipped
                .iter()
                .any(|s| s.kind == SkipKind::Cd)
        );
    }

    #[test]
    fn sed_n_and_awk_files() {
        let p = parse(
            "sed -n '1,5p' a.rs; sed -n -e 5p b.rs c.rs; awk '{print $1}' data.csv; awk -F, -f prog.awk x.csv n=3",
        );
        assert_eq!(
            texts(&p.reads),
            ["a.rs", "b.rs", "c.rs", "data.csv", "prog.awk", "x.csv"]
        );
        assert!(
            p.skipped.is_empty(),
            "single quotes keep $1 out of the shell"
        );
        let q = parse("sed -i.bak 's/a/b/' w.txt");
        assert_eq!(texts(&q.writes), ["w.txt"]);
        assert!(q.reads.is_empty());
    }

    #[test]
    fn rg_with_paths_and_without() {
        assert_eq!(texts(&parse("rg foo src tests").reads), ["src", "tests"]);
        assert_eq!(texts(&parse("rg -n -g '*.rs' foo").listed), ["."]);
        let piped = parse("cat x | rg foo");
        assert_eq!(texts(&piped.reads), ["x"]);
        assert!(piped.listed.is_empty());
        assert_eq!(texts(&parse("grep -rn foo").listed), ["."]);
        assert!(parse("grep foo").listed.is_empty());
        assert_eq!(
            texts(&parse("grep -e foo -f pats f.txt").reads),
            ["pats", "f.txt"]
        );
    }

    #[test]
    fn ls_and_find_are_listed_not_read() {
        let p = parse("ls -la docs; ls; find src -name '*.rs' -type f; fd foo crates; fd foo");
        assert_eq!(texts(&p.listed), ["docs", ".", "src", "crates", "."]);
        assert!(p.reads.is_empty());
    }

    #[test]
    fn script_run_is_a_read_of_the_script() {
        let p = parse(
            "./run.sh --fast; python3 tools/x.py a; bash build.sh; source env.sh; node -e 'x'; /usr/bin/cat /etc/hosts",
        );
        assert_eq!(
            texts(&p.scripts),
            ["./run.sh", "tools/x.py", "build.sh", "env.sh"]
        );
        assert_eq!(texts(&p.reads), ["/etc/hosts"]);
        let q = parse("bash -c 'cat a.txt | head -n1 b.txt'");
        assert_eq!(texts(&q.reads), ["a.txt", "b.txt"]);
    }

    #[test]
    fn substitution_variables_and_xargs_are_skipped() {
        let p = parse("cat $(ls) $FILE \"$HOME/x\" ok.txt");
        assert_eq!(texts(&p.reads), ["ok.txt"]);
        assert_eq!(p.skipped.len(), 3);
        let q = parse("ls | xargs cat");
        assert!(q.reads.is_empty() && q.skipped.iter().any(|s| s.kind == SkipKind::Xargs));
        let n = parse("bash -c \"bash -c 'cat a'\"");
        assert!(n.reads.is_empty() && n.skipped.iter().any(|s| s.kind == SkipKind::NestedShell));
        let h = parse("cat a <<EOF\nb\nEOF");
        assert_eq!(texts(&h.reads), ["a"]);
        assert!(h.skipped.iter().any(|s| s.kind == SkipKind::Heredoc));
        assert!(
            parse("(cd x && cat y)")
                .skipped
                .iter()
                .any(|s| s.kind == SkipKind::Subshell)
        );
        assert!(
            parse("find . -exec cat {} +")
                .skipped
                .iter()
                .any(|s| s.kind == SkipKind::Xargs)
        );
    }

    struct Tree {
        _dir: tempfile::TempDir,
        ws: PathBuf,
        outside: PathBuf,
    }

    fn tree() -> Tree {
        let dir = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(dir.path()).unwrap();
        let ws = base.join("ws");
        let outside = base.join("outside");
        for d in [ws.join("sub"), ws.join("many"), outside.clone()] {
            std::fs::create_dir_all(d).unwrap();
        }
        for f in ["a.txt", "b.txt", "sub/c.txt"] {
            std::fs::write(ws.join(f), "x").unwrap();
        }
        for i in 0..250 {
            std::fs::write(ws.join("many").join(format!("f{i:03}.txt")), "x").unwrap();
        }
        std::fs::write(outside.join("secret.txt"), "x").unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, ws.join("link")).unwrap();
            std::os::unix::fs::symlink(outside.join("secret.txt"), ws.join("linkfile")).unwrap();
        }
        Tree {
            _dir: dir,
            ws,
            outside,
        }
    }

    #[test]
    fn dotdot_and_links_out_of_the_roots_are_dropped() {
        let t = tree();
        let roots = [t.ws.clone()];
        let r = |cmd: &str| resolve_with_home(&parse(cmd), &t.ws, &roots, 200, None);
        let got = r("cat ../outside/secret.txt link/secret.txt linkfile a.txt");
        assert_eq!(got.reads, [t.ws.join("a.txt")]);
        let moved = r("cd ../outside && cat secret.txt");
        assert!(moved.reads.is_empty());
        let inside = r("cd sub && cat ../a.txt c.txt");
        assert_eq!(inside.reads, [t.ws.join("a.txt"), t.ws.join("sub/c.txt")]);
        let abs = r(&format!(
            "cat {}/secret.txt > {}/new.txt",
            t.outside.display(),
            t.outside.display()
        ));
        assert!(abs.reads.is_empty() && abs.writes.is_empty());
        // a path that does not exist yet is still checked after its `..`
        assert!(
            r("echo x > nothere/../../outside/new.txt")
                .writes
                .is_empty()
        );
    }

    #[test]
    fn resolve_places_writes_directories_tilde_and_globs() {
        let t = tree();
        let roots = [t.ws.clone()];
        let home = Some(t.ws.as_path());
        let r = |cmd: &str, cap| resolve_with_home(&parse(cmd), &t.ws, &roots, cap, home);
        assert_eq!(r("echo hi > new.txt", 200).writes, [t.ws.join("new.txt")]);
        let d = r("cat sub", 200);
        assert!(d.reads.is_empty());
        assert_eq!(d.listed, [t.ws.join("sub")]);
        assert_eq!(r("cat ~/a.txt", 200).reads, [t.ws.join("a.txt")]);
        let g = r("cat *.txt sub/[c].txt", 200);
        assert_eq!(
            g.reads,
            [
                t.ws.join("a.txt"),
                t.ws.join("b.txt"),
                t.ws.join("sub/c.txt")
            ]
        );
        assert!(g.patterns.is_empty());
        assert_eq!(r("cat '*.txt'", 200).reads, Vec::<PathBuf>::new());
        assert_eq!(r("cat nothing*", 200).patterns, ["nothing*"]);
    }

    #[test]
    fn glob_caps_at_200() {
        let t = tree();
        let got = resolve_with_home(
            &parse("cat many/*.txt"),
            &t.ws,
            std::slice::from_ref(&t.ws),
            200,
            None,
        );
        assert_eq!(got.reads.len(), 200);
        assert_eq!(got.patterns, ["many/*.txt"]);
        assert_eq!(got.reads[0], t.ws.join("many/f000.txt"));
    }

    #[test]
    fn corpus_parses_and_every_line_is_stable() {
        let mut named = 0;
        for line in CORPUS
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        {
            let a = parse(line);
            assert_eq!(a, parse(line), "{line}");
            named += a.reads.len() + a.writes.len() + a.listed.len() + a.scripts.len();
        }
        assert!(named > 20, "the corpus names files");
    }

    proptest! {
        #[test]
        fn parse_never_panics_and_is_deterministic(s in "\\PC{0,120}", words in prop::collection::vec(
            prop::sample::select(vec!["cat", "|", "&&", ";", ">", "<", "2>&1", "'", "\"", "$(", ")", "`", "*", "[a", "cd", "--", "-n", "bash -c", "xargs", "\\", "<<", "~", "{a,b}", "x.txt"]), 0..14)) {
            prop_assert_eq!(parse(&s), parse(&s));
            let joined = words.join(" ");
            prop_assert_eq!(parse(&joined), parse(&joined));
            let glued = words.concat();
            prop_assert_eq!(parse(&glued), parse(&glued));
        }
    }
}
