//! `board.org`: an Org outline parsed into headline items and rendered back byte-exact.  Only the headline and the
//! property drawer are interpreted; everything else (planning lines, logbook, source blocks, lists, text the parser
//! does not know) stays in `body` as written.
//!
//! A headline is a line of `*`s at column 0 followed by a space.  Keywords: the Org defaults (`TODO`, `DONE`) plus
//! `NEXT STARTED WAITING HOLD REVIEW CANCELLED CANCELED` plus any `#+TODO:`/`#+SEQ_TODO:`/`#+TYP_TODO:` words in the
//! preamble.  Tags are a trailing `:a:b:` after whitespace.  The property drawer is the `:PROPERTIES:` … `:END:`
//! block at the start of the body (after an optional planning line).

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrgItem {
    pub level: usize,
    pub keyword: Option<String>,
    /// Title without keyword and tags (priority cookies stay in it).
    pub title: String,
    pub tags: Vec<String>,
    pub properties: Vec<(String, String)>,
    /// Everything after the headline line up to the next headline, drawer included, as written.
    pub body: String,
    /// The headline line as written, with its terminator.
    pub heading: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrgDoc {
    /// Text before the first headline.
    pub preamble: String,
    pub items: Vec<OrgItem>,
}

pub(crate) fn is_default_keyword(w: &str) -> bool {
    DEFAULT_KEYWORDS.contains(&w)
}

const DEFAULT_KEYWORDS: &[&str] = &[
    "TODO",
    "DONE",
    "NEXT",
    "STARTED",
    "WAITING",
    "HOLD",
    "REVIEW",
    "CANCELLED",
    "CANCELED",
];

fn headline_level(line: &str) -> Option<usize> {
    let n = line.bytes().take_while(|&b| b == b'*').count();
    let rest = &line[n..];
    (n > 0 && (rest.starts_with(' ') || rest.trim_end_matches(['\n', '\r']).is_empty()))
        .then_some(n)
}

fn file_keywords(preamble: &str) -> Vec<String> {
    let mut out = Vec::new();
    for l in preamble.lines() {
        let u = l.trim().to_ascii_uppercase();
        for p in ["#+TODO:", "#+SEQ_TODO:", "#+TYP_TODO:"] {
            if let Some(rest) = u.strip_prefix(p) {
                for w in rest.split(|c: char| c.is_whitespace() || c == '|') {
                    let w = w.split('(').next().unwrap_or("");
                    if !w.is_empty() {
                        out.push(w.to_string());
                    }
                }
            }
        }
    }
    out
}

fn split_tags(title: &str) -> (&str, Vec<String>) {
    let t = title.trim_end();
    // the last whitespace by its char, so a multi-byte one (U+00A0, U+3000) is stepped over whole
    if let Some((i, ws)) = t.char_indices().rev().find(|(_, c)| c.is_whitespace()) {
        let last = &t[i + ws.len_utf8()..];
        if last.len() > 2
            && last.starts_with(':')
            && last.ends_with(':')
            && last[1..last.len() - 1].split(':').all(|g| {
                !g.is_empty() && g.chars().all(|c| c.is_alphanumeric() || "_@#%".contains(c))
            })
        {
            let tags = last[1..last.len() - 1]
                .split(':')
                .map(String::from)
                .collect();
            return (t[..i].trim_end(), tags);
        }
    }
    (t, Vec::new())
}

fn drawer_properties(body: &str) -> Vec<(String, String)> {
    let mut lines = body.lines().peekable();
    if let Some(l) = lines.peek() {
        let u = l.trim_start();
        if u.starts_with("SCHEDULED:") || u.starts_with("DEADLINE:") || u.starts_with("CLOSED:") {
            lines.next();
        }
    }
    if !lines
        .next()
        .is_some_and(|l| l.trim().eq_ignore_ascii_case(":PROPERTIES:"))
    {
        return Vec::new();
    }
    let mut props = Vec::new();
    for l in lines {
        let l = l.trim();
        if l.eq_ignore_ascii_case(":END:") {
            break;
        }
        if let Some(rest) = l.strip_prefix(':')
            && let Some(i) = rest.find(':')
        {
            props.push((rest[..i].to_string(), rest[i + 1..].trim().to_string()));
        }
    }
    props
}

pub fn parse(text: &str) -> OrgDoc {
    let mut preamble = String::new();
    let mut raw: Vec<(String, String)> = Vec::new();
    for l in text.split_inclusive('\n') {
        if headline_level(l).is_some() {
            raw.push((l.to_string(), String::new()));
        } else if let Some(last) = raw.last_mut() {
            last.1.push_str(l);
        } else {
            preamble.push_str(l);
        }
    }
    let mut keywords: Vec<String> = DEFAULT_KEYWORDS.iter().map(|s| s.to_string()).collect();
    keywords.extend(file_keywords(&preamble));
    let items = raw
        .into_iter()
        .map(|(heading, body)| {
            let level = headline_level(&heading).unwrap_or(1);
            let rest = heading[level..].trim();
            let (keyword, rest) = match rest.split_once(char::is_whitespace) {
                Some((w, r)) if keywords.iter().any(|k| k == w) => (Some(w.to_string()), r),
                None if keywords.iter().any(|k| k == rest) => (Some(rest.to_string()), ""),
                _ => (None, rest),
            };
            let (title, tags) = split_tags(rest);
            OrgItem {
                level,
                keyword,
                title: title.trim().to_string(),
                tags,
                properties: drawer_properties(&body),
                body,
                heading,
            }
        })
        .collect();
    OrgDoc { preamble, items }
}

pub fn render(doc: &OrgDoc) -> String {
    let mut s = doc.preamble.clone();
    for i in &doc.items {
        s.push_str(&i.heading);
        s.push_str(&i.body);
    }
    s
}
