//! The user's hook rules (`drgnx-agents-hook-rules`): match a point, tool kinds, path globs and a command regex,
//! then deny or annotate. This is the setting's schema: `parse_rules` checks a value when the setting is applied.

use std::fmt;

use brokkr::Point;
use brokkr::manifest::Glob;
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use super::{HookInput, paths_match};

/// A rule's verdict. Rules never change anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuleVerdict {
    Deny,
    Annotate,
}

/// One rule. An absent field matches everything; the fields AND together.
#[derive(Debug, Clone)]
pub struct Rule {
    /// `^[a-z0-9-]{1,32}$`, unique in its list. Only a rule with an id can be switched off for one project.
    pub id: Option<String>,
    pub point: Point,
    /// ACP kinds, or `drgnx` for the hub's own tools.
    pub tool_kinds: Vec<String>,
    pub paths: Vec<Glob>,
    pub command: Option<Regex>,
    pub verdict: RuleVerdict,
    pub reason: String,
}

impl Rule {
    /// Whether this rule looks at INPUT.
    pub fn matches(&self, input: &HookInput) -> bool {
        self.point == input.point
            && (self.tool_kinds.is_empty()
                || input
                    .tool_kind
                    .as_ref()
                    .is_some_and(|k| self.tool_kinds.contains(k)))
            && paths_match(&self.paths, &input.paths)
            && self
                .command
                .as_ref()
                .is_none_or(|re| input.command.as_deref().is_some_and(|c| re.is_match(c)))
    }
}

/// A rule as the setting holds it.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Spec {
    #[serde(default)]
    id: Option<String>,
    point: Point,
    #[serde(default)]
    tool_kinds: Vec<String>,
    #[serde(default)]
    paths: Vec<Glob>,
    #[serde(default)]
    command: Option<String>,
    verdict: RuleVerdict,
    reason: String,
}

/// A `command` regex's compiled size limit.
const REGEX_SIZE_LIMIT: usize = 1024 * 1024;
const MAX_REASON_CHARS: usize = 1000;

/// Why a rule list was refused: the JSON path of the value at fault and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleError {
    pub path: String,
    pub message: String,
}

impl fmt::Display for RuleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.path.is_empty() {
            f.write_str(&self.message)
        } else {
            write!(f, "{}: {}", self.path, self.message)
        }
    }
}

impl std::error::Error for RuleError {}

/// Parses and checks a rule list. A bad rule refuses the whole list.
pub fn parse_rules(v: &Value) -> Result<Vec<Rule>, RuleError> {
    let specs: Vec<Spec> = serde_path_to_error::deserialize(v).map_err(|e| RuleError {
        path: e.path().to_string().trim_start_matches('.').to_string(),
        message: e.inner().to_string(),
    })?;
    let mut rules: Vec<Rule> = Vec::with_capacity(specs.len());
    for (i, s) in specs.into_iter().enumerate() {
        let at = |field: &str, message: String| RuleError {
            path: format!("[{i}].{field}"),
            message,
        };
        if let Some(id) = &s.id {
            let ok = (1..=32).contains(&id.len())
                && id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
            if !ok {
                return Err(at(
                    "id",
                    format!("{id:?} is not an id: 1 to 32 lowercase letters, digits and `-`"),
                ));
            }
            if rules.iter().any(|r| r.id.as_ref() == Some(id)) {
                return Err(at("id", format!("{id:?} is the id of an earlier rule")));
            }
        }
        for (j, k) in s.tool_kinds.iter().enumerate() {
            if !brokkr::TOOL_KINDS.contains(&k.as_str()) {
                return Err(at(
                    &format!("tool_kinds[{j}]"),
                    format!("{k:?} is not a tool kind"),
                ));
            }
        }
        let command = match &s.command {
            None => None,
            Some(src) => Some(
                regex::RegexBuilder::new(src)
                    .size_limit(REGEX_SIZE_LIMIT)
                    .build()
                    .map_err(|e| at("command", e.to_string()))?,
            ),
        };
        if s.reason.trim().is_empty() || s.reason.chars().count() > MAX_REASON_CHARS {
            return Err(at(
                "reason",
                format!("a reason is 1 to {MAX_REASON_CHARS} characters"),
            ));
        }
        rules.push(Rule {
            id: s.id,
            point: s.point,
            tool_kinds: s.tool_kinds,
            paths: s.paths,
            command,
            verdict: s.verdict,
            reason: s.reason,
        });
    }
    Ok(rules)
}

/// Whether PATH matches GLOB, segment by segment: `*` and `?` stay within one segment (`?` is one character), and a
/// `**` segment matches any number of segments, none included. Iterative, with one backtrack point per level, so
/// the time is at most the product of the lengths.
pub fn glob_match(glob: &str, path: &str) -> bool {
    let pat: Vec<&str> = glob.split('/').collect();
    let segs: Vec<&str> = path.split('/').collect();
    wildcard(&pat, &segs, |p| *p == "**", |p, s| segment_match(p, s))
}

/// Whether one segment matches: `*` is any run of characters, `?` one character.
fn segment_match(pat: &str, seg: &str) -> bool {
    let p: Vec<char> = pat.chars().collect();
    let s: Vec<char> = seg.chars().collect();
    wildcard(&p, &s, |c| *c == '*', |c, x| *c == '?' || c == x)
}

/// The classic wildcard match of PAT over ITEMS: an element for which STAR holds matches any run of items, any
/// other matches one item by ONE. Only the last star is backtracked to, which is enough because a star matches
/// anything.
fn wildcard<P, T>(
    pat: &[P],
    items: &[T],
    star: impl Fn(&P) -> bool,
    one: impl Fn(&P, &T) -> bool,
) -> bool {
    let (mut p, mut i) = (0, 0);
    let mut back: Option<(usize, usize)> = None;
    while i < items.len() {
        if p < pat.len() && star(&pat[p]) {
            back = Some((p, i));
            p += 1;
        } else if p < pat.len() && one(&pat[p], &items[i]) {
            p += 1;
            i += 1;
        } else if let Some((bp, bi)) = back {
            back = Some((bp, bi + 1));
            p = bp + 1;
            i = bi + 1;
        } else {
            return false;
        }
    }
    pat[p..].iter().all(star)
}
