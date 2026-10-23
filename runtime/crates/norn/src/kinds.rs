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

/// The entity kinds of storage §5.3, plus `project`. Task 10 fills it.
pub const ENTITY_KINDS: &[&str] = &[];

/// The link kinds of storage §5.4. Task 10 fills it.
pub const LINKS: &[LinkKind] = &[];
