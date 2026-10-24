//! drgnx's closed lists (Task 10; storage §5.3, §5.4): the entity kinds and the link kinds with their ends. Adding
//! one is a code change with a test.

/// A link kind: which entity kinds it joins, and whether it changes readiness (beads's `AffectsReadyWork`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinkKind {
    pub name: &'static str,
    /// Entity kinds at the source (`["*"]`: any).
    pub from: &'static [&'static str],
    /// Entity kinds at the target (`["*"]`: any).
    pub to: &'static [&'static str],
    pub affects_ready: bool,
}

/// The entity kinds of storage §5.3 (its table, plus `worktree`, the end of `in_worktree`), plus `project`, plus
/// `option` (a setting's history: Urdr Task 10b, unified-settings design §12).
pub const ENTITY_KINDS: &[&str] = &[
    "task", "decision", "note", "grant", "agent", "session", "commit", "branch", "file", "symbol",
    "spec", "plan", "step", "ruling", "todo", "worktree", "project", "option",
];

const ANY: &[&str] = &["*"];
const TASK: &[&str] = &["task"];

const fn link(
    name: &'static str,
    from: &'static [&'static str],
    to: &'static [&'static str],
    affects_ready: bool,
) -> LinkKind {
    LinkKind {
        name,
        from,
        to,
        affects_ready,
    }
}

/// The link kinds of storage §5.4.
pub const LINKS: &[LinkKind] = &[
    link("blocks", TASK, TASK, true),
    link("parent_of", &["task", "plan"], &["task", "step"], true),
    link("split_from", TASK, TASK, false),
    link("discovered_from", TASK, TASK, false),
    link("relates", ANY, ANY, false),
    link("duplicates", ANY, ANY, false),
    link("derives", &["plan"], &["spec"], false),
    link("implements", &["commit"], &["task", "step", "todo"], false),
    link(
        "on_branch",
        &["commit", "plan", "session"],
        &["branch"],
        false,
    ),
    link(
        "in_project",
        &["commit", "plan", "session"],
        &["project"],
        false,
    ),
    link(
        "in_worktree",
        &["commit", "plan", "session"],
        &["worktree"],
        false,
    ),
    link("works_on", &["session"], TASK, false),
    link("run_by", &["session"], &["agent"], false),
    link("touched", &["session"], &["file"], false),
    link("authored", &["session"], &["commit"], false),
    link("decided", &["session"], &["decision"], false),
    link("about", &["decision", "note"], ANY, false),
    link("supersedes", &["decision"], &["decision"], false),
    link("renamed_to", &["file"], &["file"], false),
    link("defines", &["file", "symbol"], &["symbol"], false),
    link("references", &["file", "symbol"], &["symbol"], false),
    link("imports", &["file", "symbol"], &["symbol"], false),
    link("calls", &["file", "symbol"], &["symbol"], false),
];

/// Whether KIND is one of [`ENTITY_KINDS`].
pub fn is_entity_kind(kind: &str) -> bool {
    ENTITY_KINDS.contains(&kind)
}

/// The link kind NAME, if it is on the list.
pub fn link_kind(name: &str) -> Option<&'static LinkKind> {
    LINKS.iter().find(|l| l.name == name)
}

/// Whether a link NAME may join an entity of kind FROM to one of kind TO.
pub fn link_allowed(name: &str, from: &str, to: &str) -> bool {
    fn ends(list: &[&str], kind: &str) -> bool {
        list.iter().any(|k| *k == "*" || *k == kind)
    }
    link_kind(name).is_some_and(|l| ends(l.from, from) && ends(l.to, to))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The design's lists, written out again: a change to either list is a change to this test.
    #[test]
    fn the_list_is_the_designs() {
        assert_eq!(
            ENTITY_KINDS,
            [
                "task", "decision", "note", "grant", "agent", "session", "commit", "branch",
                "file", "symbol", "spec", "plan", "step", "ruling", "todo", "worktree", "project",
                "option"
            ]
        );
        let rows: Vec<(&str, Vec<&str>, Vec<&str>, bool)> = LINKS
            .iter()
            .map(|l| (l.name, l.from.to_vec(), l.to.to_vec(), l.affects_ready))
            .collect();
        let expect: Vec<(&str, Vec<&str>, Vec<&str>, bool)> = vec![
            ("blocks", vec!["task"], vec!["task"], true),
            (
                "parent_of",
                vec!["task", "plan"],
                vec!["task", "step"],
                true,
            ),
            ("split_from", vec!["task"], vec!["task"], false),
            ("discovered_from", vec!["task"], vec!["task"], false),
            ("relates", vec!["*"], vec!["*"], false),
            ("duplicates", vec!["*"], vec!["*"], false),
            ("derives", vec!["plan"], vec!["spec"], false),
            (
                "implements",
                vec!["commit"],
                vec!["task", "step", "todo"],
                false,
            ),
            (
                "on_branch",
                vec!["commit", "plan", "session"],
                vec!["branch"],
                false,
            ),
            (
                "in_project",
                vec!["commit", "plan", "session"],
                vec!["project"],
                false,
            ),
            (
                "in_worktree",
                vec!["commit", "plan", "session"],
                vec!["worktree"],
                false,
            ),
            ("works_on", vec!["session"], vec!["task"], false),
            ("run_by", vec!["session"], vec!["agent"], false),
            ("touched", vec!["session"], vec!["file"], false),
            ("authored", vec!["session"], vec!["commit"], false),
            ("decided", vec!["session"], vec!["decision"], false),
            ("about", vec!["decision", "note"], vec!["*"], false),
            ("supersedes", vec!["decision"], vec!["decision"], false),
            ("renamed_to", vec!["file"], vec!["file"], false),
            ("defines", vec!["file", "symbol"], vec!["symbol"], false),
            ("references", vec!["file", "symbol"], vec!["symbol"], false),
            ("imports", vec!["file", "symbol"], vec!["symbol"], false),
            ("calls", vec!["file", "symbol"], vec!["symbol"], false),
        ];
        assert_eq!(rows, expect);
        // Every named end is an entity kind, and only the two readiness links affect ready.
        for l in LINKS {
            for k in l.from.iter().chain(l.to) {
                assert!(*k == "*" || is_entity_kind(k), "{}: {k}", l.name);
            }
        }
        let ready: Vec<&str> = LINKS
            .iter()
            .filter(|l| l.affects_ready)
            .map(|l| l.name)
            .collect();
        assert_eq!(ready, ["blocks", "parent_of"]);
    }

    #[test]
    fn link_ends_are_checked() {
        assert!(link_allowed("blocks", "task", "task"));
        assert!(!link_allowed("blocks", "note", "task"));
        assert!(link_allowed("about", "note", "file"));
        assert!(!link_allowed("about", "task", "file"));
        assert!(link_allowed("relates", "grant", "project"));
        assert!(!link_allowed("owns", "task", "task"));
    }
}
