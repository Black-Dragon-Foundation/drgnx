//! Redaction on capture.  A batch of changes is scanned for the shapes of well-known keys (API keys, tokens, private key
//! blocks) before it reaches a document; each is replaced by `*`, a character for a character, so the offsets of the
//! buffer still hold.  The batch's hash is over the text after redaction.  Only a key *inside one change* is seen: a key
//! typed a character at a time is the user's, and [`History::excise`](crate::History::excise) removes it afterwards.

use crate::Change;
use sha2::{Digest, Sha256};

/// A batch of changes and the hash of the text they insert (SHA-256 in hex, over the inserted texts joined in order).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Batch {
    pub changes: Vec<Change>,
    pub hash: String,
}

impl Batch {
    /// CHANGES with their hash.
    pub fn new(changes: Vec<Change>) -> Batch {
        let mut h = Sha256::new();
        for c in &changes {
            h.update(c.inserted.as_bytes());
        }
        Batch {
            hash: h.finalize().iter().map(|b| format!("{b:02x}")).collect(),
            changes,
        }
    }
}

/// A key's shape: a prefix and a body of PUNCT-or-alphanumeric characters of LEN length.
struct Shape {
    prefix: &'static str,
    body: fn(char) -> bool,
    min: usize,
    max: usize,
}

fn alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

fn word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-'
}

fn underscore(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

fn dash(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '-'
}

fn upper(c: char) -> bool {
    c.is_ascii_uppercase() || c.is_ascii_digit()
}

const MANY: usize = usize::MAX;

const SHAPES: &[Shape] = &[
    // OpenAI, Anthropic and look-alikes
    Shape {
        prefix: "sk-",
        body: word,
        min: 20,
        max: MANY,
    },
    Shape {
        prefix: "ghp_",
        body: alnum,
        min: 30,
        max: MANY,
    },
    Shape {
        prefix: "gho_",
        body: alnum,
        min: 30,
        max: MANY,
    },
    Shape {
        prefix: "ghu_",
        body: alnum,
        min: 30,
        max: MANY,
    },
    Shape {
        prefix: "ghs_",
        body: alnum,
        min: 30,
        max: MANY,
    },
    Shape {
        prefix: "ghr_",
        body: alnum,
        min: 30,
        max: MANY,
    },
    Shape {
        prefix: "github_pat_",
        body: underscore,
        min: 40,
        max: MANY,
    },
    Shape {
        prefix: "glpat-",
        body: word,
        min: 20,
        max: MANY,
    },
    Shape {
        prefix: "AKIA",
        body: upper,
        min: 16,
        max: 16,
    },
    Shape {
        prefix: "ASIA",
        body: upper,
        min: 16,
        max: 16,
    },
    Shape {
        prefix: "AIza",
        body: word,
        min: 35,
        max: 35,
    },
    Shape {
        prefix: "xoxb-",
        body: dash,
        min: 10,
        max: MANY,
    },
    Shape {
        prefix: "xoxa-",
        body: dash,
        min: 10,
        max: MANY,
    },
    Shape {
        prefix: "xoxp-",
        body: dash,
        min: 10,
        max: MANY,
    },
    Shape {
        prefix: "xoxr-",
        body: dash,
        min: 10,
        max: MANY,
    },
    Shape {
        prefix: "xoxs-",
        body: dash,
        min: 10,
        max: MANY,
    },
];

fn starts(chars: &[char], at: usize, s: &str) -> bool {
    s.chars()
        .enumerate()
        .all(|(k, c)| chars.get(at + k) == Some(&c))
}

fn position(chars: &[char], from: usize, s: &str) -> Option<usize> {
    (from..chars.len()).find(|i| starts(chars, *i, s))
}

/// Where a key starts at AT, and how long it is, in characters.
fn key_at(chars: &[char], at: usize) -> Option<usize> {
    if starts(chars, at, "-----BEGIN ") {
        let key = position(chars, at, "PRIVATE KEY-----")?;
        return Some(match position(chars, key, "-----END ") {
            Some(end) => position(chars, end + 9, "-----").map_or(chars.len(), |c| c + 5) - at,
            None => chars.len() - at,
        });
    }
    SHAPES.iter().find_map(|s| {
        if !starts(chars, at, s.prefix) {
            return None;
        }
        let start = at + s.prefix.chars().count();
        let n = chars[start..].iter().take_while(|c| (s.body)(**c)).count();
        (s.min..=s.max)
            .contains(&n)
            .then(|| s.prefix.chars().count() + n)
    })
}

/// TEXT with every key in it replaced by `*`, a character for a character.
pub fn redact(text: &str) -> String {
    let mut chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        // a key starts at a word boundary: `task-list` holds no `sk-`
        let boundary = i == 0 || !chars[i - 1].is_ascii_alphanumeric();
        match boundary.then(|| key_at(&chars, i)).flatten() {
            Some(n) => {
                chars[i..i + n].fill('*');
                i += n;
            }
            None => i += 1,
        }
    }
    chars.into_iter().collect()
}

/// BATCH with the keys in its inserted texts redacted, and its hash over the redacted text.
pub fn scan(batch: Batch) -> Batch {
    Batch::new(
        batch
            .changes
            .into_iter()
            .map(|c| Change {
                inserted: redact(&c.inserted),
                ..c
            })
            .collect(),
    )
}
