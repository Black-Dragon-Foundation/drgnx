//! The question generator: commit subjects as behaviour questions, answered by the forms the commit changed.
//!
//! - A **subject** becomes a question after its ticket ids and leading `area:` words are stripped. It is dropped when it
//!   merges, reverts, has fewer than three words, or names an identifier (a token with `_`, `::`, `/` or a dot inside, a
//!   camelCase token, a hyphenated token that is or starts a symbol of HEAD): such a question would be answered by the
//!   symbol route, which has its own test.
//! - A **target** is a top-level form of the file as the commit left it that overlaps a hunk (a pure deletion has none,
//!   and a file the commit created is not used), found again at HEAD by name: the `(path, symbol)` of its chunk there,
//!   with the same path preferred and an ambiguous name dropped. A form that is gone drops its target, and a commit
//!   with no target left drops out. Configuration files (no symbols) are targets as a whole file.
//! - The **stratum** follows the targets: all in tests, all in docs, all configuration, two or more files
//!   (`cross-file`), else `symbol`.

use super::EvalRow;
use crate::chunk::{BUDGET, chunk_file};
use crate::files::{Class, Commit, Git, Lang, classify};
use crate::store::CodeStore;
use std::collections::{BTreeSet, HashMap};
use std::io::{self, BufRead, Write};
use std::path::Path;

/// How many commits the generator looks at.
pub const HISTORY_LIMIT: usize = 6000;
/// A commit that changes more files than this is a sweep, not a behaviour.
const MAX_FILES: usize = 25;
/// A commit with more targets than this is too broad to name one answer.
const MAX_TARGETS: usize = 6;

/// What HEAD's index knows.
struct Head {
    /// Symbol name to the `(path, chunk symbol)` that define it.
    by_name: HashMap<String, Vec<(String, String)>>,
    names: BTreeSet<String>,
    /// Path to class and language.
    files: HashMap<String, (Class, Lang)>,
}

async fn head_of(store: &CodeStore) -> Result<Head, String> {
    store
        .handle()
        .read(|c| {
            let mut by_name: HashMap<String, Vec<(String, String)>> = HashMap::new();
            let mut q = c.prepare(
                "select s.name, s.path, coalesce(c.symbol, '') from symbol s join chunk c on c.id = s.chunk
                 join file f on f.tree = 0 and f.path = s.path and f.blob = s.blob",
            )?;
            for r in q.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
            })? {
                let (name, path, sym) = r?;
                let e = by_name.entry(name).or_default();
                if !e.contains(&(path.clone(), sym.clone())) {
                    e.push((path, sym));
                }
            }
            let mut files = HashMap::new();
            let mut q = c.prepare("select path, class, lang from file where tree = 0")?;
            for r in q.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
            })? {
                let (path, class, lang) = r?;
                let class = match class.as_str() {
                    "test" => Class::Test,
                    "docs" => Class::Docs,
                    _ => Class::Code,
                };
                let lang = match lang.as_str() {
                    "elisp" => Lang::Elisp,
                    "rust" => Lang::Rust,
                    "c" => Lang::C,
                    "shell" => Lang::Shell,
                    "org" => Lang::Org,
                    "markdown" => Lang::Markdown,
                    _ => Lang::Text,
                };
                files.insert(path, (class, lang));
            }
            let names = by_name.keys().cloned().collect();
            Ok(Head {
                by_name,
                names,
                files,
            })
        })
        .await
        .map_err(|e| e.to_string())
}

fn is_ticket(t: &str) -> bool {
    let t = t.trim_matches(|c: char| "()[],.:;".contains(c));
    if let Some(n) = t.strip_prefix('#') {
        return !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit());
    }
    match t.split_once('-') {
        Some((a, b)) => {
            a.len() >= 2
                && a.bytes()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
                && a.bytes().next().is_some_and(|c| c.is_ascii_uppercase())
                && !b.is_empty()
                && b.bytes().all(|c| c.is_ascii_digit())
        }
        None => false,
    }
}

/// Does TOKEN name an identifier of the project?
fn is_identifier(token: &str, names: &BTreeSet<String>) -> bool {
    if token.contains('`') {
        return true;
    }
    let t = token.trim_matches(|c: char| !c.is_alphanumeric());
    if t.is_empty() {
        return false;
    }
    if t.contains('_') || t.contains("::") || t.contains('/') {
        return true;
    }
    let b = t.as_bytes();
    if (1..b.len().saturating_sub(1)).any(|i| {
        b[i] == b'.' && b[i - 1].is_ascii_alphanumeric() && b[i + 1].is_ascii_alphanumeric()
    }) {
        return true;
    }
    if b.windows(2)
        .any(|w| w[0].is_ascii_lowercase() && w[1].is_ascii_uppercase())
    {
        return true;
    }
    if t.contains('-') {
        let lower = t.to_lowercase();
        return names.contains(&lower)
            || names
                .range(lower.clone() + "-"..)
                .next()
                .is_some_and(|n| n.starts_with(&(lower.clone() + "-")));
    }
    false
}

/// The question a commit SUBJECT makes, or none (see the module's rules).
pub fn clean_subject(subject: &str, names: &BTreeSet<String>) -> Option<String> {
    let low = subject.to_lowercase();
    if ["merge", "revert", "wip", "fixup", "squash"]
        .iter()
        .any(|p| low.starts_with(p))
    {
        return None;
    }
    let mut s = subject.trim();
    for _ in 0..3 {
        match s.split_once(": ") {
            Some((head, rest)) if head.len() <= 30 && !head.contains(char::is_whitespace) => {
                s = rest.trim_start();
            }
            _ => break,
        }
    }
    let tokens: Vec<&str> = s.split_whitespace().filter(|t| !is_ticket(t)).collect();
    if tokens.len() < 3 || tokens.iter().any(|t| is_identifier(t, names)) {
        return None;
    }
    Some(tokens.join(" "))
}

/// Byte offset of the start of each line (1-based line N is entry N - 1) and the text's length.
fn line_offsets(text: &str) -> Vec<usize> {
    let mut v = vec![0];
    v.extend(text.match_indices('\n').map(|(i, _)| i + 1));
    v
}

/// The targets of one commit, or none.
fn targets_of(repo: &Path, git: &dyn Git, head: &Head, c: &Commit) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for ch in &c.changes {
        if ch.added || ch.hunks.is_empty() {
            continue;
        }
        let Ok(bytes) = git.show(repo, &c.id, &ch.path) else {
            continue;
        };
        let (lang, _) = classify(&ch.path, &bytes[..bytes.len().min(256)]);
        let mut add = |t: (String, String)| {
            if !out.contains(&t) {
                out.push(t);
            }
        };
        if lang == Lang::Text {
            if head
                .files
                .get(&ch.path)
                .is_some_and(|(_, l)| *l == Lang::Text)
            {
                add((ch.path.clone(), String::new()));
            }
            continue;
        }
        let text = String::from_utf8_lossy(&bytes);
        let (_, symbols) = chunk_file(&ch.path, lang, false, &text, BUDGET);
        let lines = line_offsets(&text);
        for (l1, l2) in &ch.hunks {
            let lo = lines
                .get((*l1 as usize).saturating_sub(1))
                .copied()
                .unwrap_or(text.len());
            let hi = lines.get(*l2 as usize).copied().unwrap_or(text.len());
            let around: Vec<_> = symbols
                .iter()
                .filter(|s| (s.start as usize) < hi && (s.end as usize) > lo)
                .collect();
            // a test body (`ert-deftest` and the like) defines no symbol: the test file is the answer
            if around.is_empty()
                && head
                    .files
                    .get(&ch.path)
                    .is_some_and(|(c, _)| *c == Class::Test)
            {
                add((ch.path.clone(), String::new()));
            }
            for s in around {
                let Some(defs) = head.by_name.get(&s.name) else {
                    continue;
                };
                let same: Vec<&(String, String)> =
                    defs.iter().filter(|(p, _)| *p == ch.path).collect();
                match (same.as_slice(), defs.as_slice()) {
                    ([one], _) => add((*one).clone()),
                    ([], [one]) => add(one.clone()),
                    _ => {}
                }
            }
        }
    }
    out
}

fn stratum_of(head: &Head, targets: &[(String, String)]) -> &'static str {
    let class = |p: &str| head.files.get(p).map(|(c, l)| (*c, *l));
    let all = |f: &dyn Fn(Class, Lang) -> bool| {
        targets
            .iter()
            .all(|(p, _)| class(p).is_some_and(|(c, l)| f(c, l)))
    };
    let paths: BTreeSet<&str> = targets.iter().map(|(p, _)| p.as_str()).collect();
    if all(&|c, _| c == Class::Test) {
        "tests"
    } else if all(&|c, _| c == Class::Docs) {
        "docs"
    } else if all(&|_, l| l == Lang::Text) {
        "config"
    } else if paths.len() >= 2 {
        "cross-file"
    } else {
        "symbol"
    }
}

/// The questions of REPO's history, answered at HEAD by STORE (a tier-1 index of HEAD's files).
pub async fn generate(
    repo: &Path,
    git: &dyn Git,
    store: &CodeStore,
) -> Result<Vec<EvalRow>, String> {
    let history = git
        .history(repo, HISTORY_LIMIT)
        .map_err(|e| format!("git history: {e}"))?;
    let head = head_of(store).await?;
    let newest = history.iter().map(|c| c.time).max().unwrap_or(0);
    let mut rows = Vec::new();
    for c in &history {
        if c.changes.len() > MAX_FILES {
            continue;
        }
        let Some(query) = clean_subject(&c.subject, &head.names) else {
            continue;
        };
        let targets = targets_of(repo, git, &head, c);
        if targets.is_empty() || targets.len() > MAX_TARGETS {
            continue;
        }
        let id: String = c.id.chars().take(12).collect();
        let half = match u64::from_str_radix(&id[..id.len().min(8)], 16) {
            Ok(n) if n % 2 == 1 => "test",
            _ => "dev",
        };
        rows.push(EvalRow {
            stratum: stratum_of(&head, &targets).into(),
            dir: targets[0].0.split('/').next().unwrap_or(".").to_string(),
            age_days: u32::try_from((newest - c.time).max(0) / 86_400).unwrap_or(u32::MAX),
            half: half.into(),
            query,
            targets,
            id,
        });
    }
    Ok(rows)
}

/// ROWS as JSON lines, one file per half: `DIR/dev.jsonl` and `DIR/test.jsonl`. The files are the frozen sets:
/// they are never overwritten.
pub fn write_sets(dir: &Path, rows: &[EvalRow]) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    for half in ["dev", "test"] {
        let path = dir.join(format!("{half}.jsonl"));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|e| {
                io::Error::new(
                    e.kind(),
                    format!("{}: {e} (the sets are frozen)", path.display()),
                )
            })?;
        for r in rows.iter().filter(|r| r.half == half) {
            writeln!(f, "{}", serde_json::to_string(r).map_err(io::Error::other)?)?;
        }
    }
    Ok(())
}

/// A frozen set.
pub fn read_set(path: &Path) -> io::Result<Vec<EvalRow>> {
    let f = std::io::BufReader::new(std::fs::File::open(path)?);
    f.lines()
        .filter(|l| l.as_ref().map_or(true, |l| !l.trim().is_empty()))
        .map(|l| {
            let l = l?;
            serde_json::from_str(&l).map_err(io::Error::other)
        })
        .collect()
}
