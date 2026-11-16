//! The links between record files, read from their own text: a relative markdown link or a backtick path that names
//! another record is `relates`; a plan's `**Spec:**` line, or its link to a spec, is `derives`; `X.ledger.md` is
//! `relates` to `X.md`; an ADR's link on a `Supersedes` line is `supersedes`.  Links inside code fences, to files that
//! are not records, or out of the root are dropped.  Pure: KNOWN says which paths are records.

use std::path::{Component, Path, PathBuf};

/// One link from a record file to another.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Link {
    pub to: PathBuf,
    /// `relates`, `derives` (plan → spec) or `supersedes` (decision → decision).
    pub kind: &'static str,
}

/// P with `.` and `..` resolved lexically; None when it climbs above the filesystem root.
fn clean(p: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    Some(out)
}

/// The targets a line names: `[text](target)` link targets and backtick spans that look like paths.
fn targets(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = line;
    while let Some(i) = rest.find("](") {
        let after = &rest[i + 2..];
        let Some(end) = after.find(')') else { break };
        let t = after[..end].split_whitespace().next().unwrap_or("");
        let t = t.split('#').next().unwrap_or("");
        if !t.is_empty() && !t.contains("://") && !t.starts_with("mailto:") {
            out.push(t.to_string());
        }
        rest = &after[end..];
    }
    let mut parts = line.split('`');
    parts.next();
    while let (Some(code), Some(_)) = (parts.next(), parts.next()) {
        if code.ends_with(".md") && !code.contains(' ') {
            out.push(code.to_string());
        }
    }
    out
}

fn kind_of(file: &Path) -> &'static str {
    let s = file.to_string_lossy();
    if s.contains("/specs/") {
        "spec"
    } else if s.ends_with(".ledger.md") {
        "ledger"
    } else if s.contains("/plans/") {
        "plan"
    } else if s.contains("/decisions/") || s.contains("/adr/") {
        "decision"
    } else {
        "other"
    }
}

/// The links of record FILE (under ROOT), whose text is TEXT; KNOWN says whether a path is a record.
pub fn links(text: &str, file: &Path, root: &Path, known: &dyn Fn(&Path) -> bool) -> Vec<Link> {
    let dir = file.parent().unwrap_or(root);
    let from = kind_of(file);
    let mut out: Vec<Link> = Vec::new();
    let add = |to: PathBuf, kind: &'static str, out: &mut Vec<Link>| {
        if to != file && !out.iter().any(|l| l.to == to) {
            out.push(Link { to, kind });
        }
    };
    if from == "ledger" {
        let s = file.to_string_lossy();
        let plan = PathBuf::from(format!("{}.md", &s[..s.len() - ".ledger.md".len()]));
        if known(&plan) {
            add(plan, "relates", &mut out);
        }
    }
    let mut fenced = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let spec_line = line.trim_start().starts_with("**Spec:**");
        let supersedes = line.to_lowercase().contains("supersedes");
        for t in targets(line) {
            // a backtick path is relative to the root (`docs/specs/a.md`) or to the file
            let cands = [dir.join(&t), root.join(&t)];
            let Some(to) = cands
                .iter()
                .filter_map(|c| clean(c))
                .find(|c| c.starts_with(root) && known(c))
            else {
                continue;
            };
            let kind = match (from, kind_of(&to)) {
                ("plan", "spec") if spec_line || !out.iter().any(|l| l.kind == "derives") => {
                    "derives"
                }
                ("decision", "decision") if supersedes => "supersedes",
                _ => "relates",
            };
            add(to, kind, &mut out);
        }
    }
    out
}
