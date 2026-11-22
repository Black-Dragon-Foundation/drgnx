//! The query engine of the chunker (language packs, design §4.1): what a top-level form defines comes from a pack's
//! `queries/chunks.scm`, under rules fixed here, in place of one Rust walker per language.
//!
//! A pattern captures:
//! - `@definition.KIND` on the node that defines, and `@name` on its name (a pattern with the property
//!   `(#set! drgnx.name "c-declarator")` has none: the helper finds it);
//! - `@container` on a node whose `body` field holds members (an `impl`, a class); `@transparent` on a node a
//!   definition may sit inside that is itself the member (a `const` statement holding function values); `@skip` on
//!   one that is only a go-between (a Java enum's declarations, Go's `var (...)` list); `@wrapper` on a node that
//!   wraps a declaration with `@wrapped` on the declaration (`export`, a decorator);
//! - `@doc` on a docstring and `@docowner` on the definition it belongs to.
//!
//! The rules (the same for every language):
//! 1. A top-level form's definitions have no span of their own (the whole form is the unit).
//! 2. A definition counts when every node between it and the top-level form is a wrapper, a transparent node, or a
//!    container's body (the container itself being one of the chain), at most four containers deep. Nested
//!    functions and closures are therefore not symbols.
//! 3. A member's span and doc anchor are the child of the container's body that holds it (its outermost wrapper).
//! 4. A pattern with `(#set! drgnx.split)` gives each definition its own span, but only when the top-level form
//!    holds more than one such definition.
//! 5. The kind is the capture's suffix. Of the patterns that capture one node as a definition, the first in the file
//!    decides, so a method pattern before a function pattern makes a method of what both match.
//! 6. Docs per pack (`:docs`): members take the kinds listed for them (a line comment run, a `/** */` block, a
//!    docstring); top-level forms try a docstring, then a block, then the line comments.

use super::definers::Def;
use super::ts::{block_doc_before, c_declarator_name, doc_before, py_docstring_of, text_of};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use tree_sitter::{Language, Node, Query, QueryCursor, StreamingIterator};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum DocKind {
    Line,
    Block,
    Docstring,
}

#[derive(Clone, Copy)]
enum Role {
    Def(&'static str),
    Name,
    Doc,
    DocOwner,
    Container,
    Transparent,
    Skip,
    Wrapper,
    Wrapped,
    Other,
}

#[derive(Clone, Copy, Default)]
struct Pat {
    split: bool,
    c_name: bool,
}

/// One language's chunking rules, built once from its pack.
pub(super) struct Spec {
    query: Query,
    roles: Vec<Role>,
    pats: Vec<Pat>,
    line: Option<String>,
    block: bool,
    members: Vec<DocKind>,
    top: Vec<DocKind>,
}

/// A kind as a `&'static str`: the distinct kinds of all packs, interned (a few dozen).
fn intern(s: &str) -> &'static str {
    static KINDS: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
    let mut k = KINDS.lock().expect("the kinds lock");
    if let Some(found) = k.iter().find(|x| **x == s) {
        return found;
    }
    let leaked: &'static str = Box::leak(s.to_string().into_boxed_str());
    k.push(leaked);
    leaked
}

impl Spec {
    /// `scm` (a pack's `queries/chunks.scm`) compiled against LANGUAGE, with the pack's docs rules.
    pub(super) fn new(
        language: &Language,
        scm: &str,
        line: Option<&str>,
        block: bool,
        members: &[DocKind],
        top: &[DocKind],
    ) -> Result<Spec, String> {
        let query = Query::new(language, scm).map_err(|e| e.to_string())?;
        let roles = query
            .capture_names()
            .iter()
            .map(|n| match *n {
                "name" => Role::Name,
                "doc" => Role::Doc,
                "docowner" => Role::DocOwner,
                "container" => Role::Container,
                "transparent" => Role::Transparent,
                "skip" => Role::Skip,
                "wrapper" => Role::Wrapper,
                "wrapped" => Role::Wrapped,
                n if n.starts_with("definition.") => Role::Def(intern(&n["definition.".len()..])),
                _ => Role::Other,
            })
            .collect();
        let pats = (0..query.pattern_count())
            .map(|i| {
                let mut p = Pat::default();
                for prop in query.property_settings(i) {
                    match (&*prop.key, prop.value.as_deref()) {
                        ("drgnx.split", _) => p.split = true,
                        ("drgnx.name", Some("c-declarator")) => p.c_name = true,
                        _ => {}
                    }
                }
                p
            })
            .collect();
        Ok(Spec {
            query,
            roles,
            pats,
            line: line.map(str::to_string),
            block,
            members: members.to_vec(),
            top: top.to_vec(),
        })
    }

    /// The chunks query's raw matches over N: (pattern, captures by node id).
    fn matches<'t>(
        &self,
        root: Node<'t>,
        n: Node<'t>,
        text: &str,
        mut each: impl FnMut(usize, &[(Role, Node<'t>)]),
    ) {
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(n.start_byte()..n.end_byte());
        let mut it = cursor.matches(&self.query, root, text.as_bytes());
        while let Some(m) = it.next() {
            let caps: Vec<(Role, Node)> = m
                .captures()
                .iter()
                .map(|c| (self.roles[c.index as usize], c.node))
                .collect();
            each(m.pattern_index, &caps);
        }
    }

    /// The declaration the top-level node N wraps (`export …`, a decorated definition), else N.
    pub(super) fn inner<'t>(&self, root: Node<'t>, n: Node<'t>, text: &str) -> Node<'t> {
        let mut found = None;
        self.matches(root, n, text, |_, caps| {
            let wrapper = caps.iter().find(|c| matches!(c.0, Role::Wrapper));
            let wrapped = caps.iter().find(|c| matches!(c.0, Role::Wrapped));
            if let (Some(w), Some(d)) = (wrapper, wrapped)
                && w.1.id() == n.id()
                && found.is_none()
            {
                found = Some(d.1);
            }
        });
        found.unwrap_or(n)
    }

    /// What the top-level node N defines, and the form's own docstring.
    pub(super) fn analyse<'t>(
        &self,
        root: Node<'t>,
        n: Node<'t>,
        text: &str,
    ) -> (Vec<Def>, Option<(String, String)>) {
        struct Cand<'t> {
            pat: usize,
            d: Node<'t>,
            name: Option<Node<'t>>,
            kind: &'static str,
        }
        let mut cands: Vec<Cand> = Vec::new();
        let mut containers: HashSet<usize> = HashSet::new();
        let mut transparents: HashSet<usize> = HashSet::new();
        let mut skips: HashSet<usize> = HashSet::new();
        let mut wrappers: HashMap<usize, usize> = HashMap::new();
        let mut docs: HashMap<usize, Node> = HashMap::new();
        self.matches(root, n, text, |pat, caps| {
            let (mut d, mut name, mut kind) = (None, None, None);
            let (mut wrapper, mut wrapped, mut doc, mut owner) = (None, None, None, None);
            for (role, node) in caps {
                match role {
                    Role::Def(k) => {
                        d = Some(*node);
                        kind = Some(*k);
                    }
                    Role::Name => name = Some(*node),
                    Role::Doc => doc = Some(*node),
                    Role::DocOwner => owner = Some(*node),
                    Role::Container => {
                        containers.insert(node.id());
                    }
                    Role::Transparent => {
                        transparents.insert(node.id());
                    }
                    Role::Skip => {
                        skips.insert(node.id());
                    }
                    Role::Wrapper => wrapper = Some(*node),
                    Role::Wrapped => wrapped = Some(*node),
                    Role::Other => {}
                }
            }
            if let (Some(w), Some(x)) = (wrapper, wrapped) {
                wrappers.insert(w.id(), x.id());
            }
            if let (Some(s), Some(o)) = (doc, owner) {
                docs.entry(o.id()).or_insert(s);
            }
            if let (Some(d), Some(kind)) = (d, kind) {
                cands.push(Cand { pat, d, name, kind });
            }
        });

        // rule 2: the chain from each definition up to N; rule 3: its member node
        struct Kept<'t> {
            c: Cand<'t>,
            depth: usize,
            member: Option<Node<'t>>,
        }
        let mut kept: Vec<Kept> = Vec::new();
        for c in cands {
            let mut cur = c.d;
            let mut real = c.d; // the lowest node of the chain that is not a go-between
            let (mut depth, mut member) = (0usize, None);
            let ok = loop {
                if cur.id() == n.id() {
                    break true;
                }
                let Some(p) = cur.parent() else {
                    break false;
                };
                if wrappers.get(&p.id()) == Some(&cur.id()) || transparents.contains(&p.id()) {
                    cur = p;
                    real = p;
                } else if skips.contains(&p.id()) {
                    cur = p;
                } else if let Some(container) = p.parent()
                    && containers.contains(&container.id())
                    && container.child_by_field_name("body").map(|b| b.id()) == Some(p.id())
                {
                    if member.is_none() {
                        member = Some(real);
                    }
                    depth += 1;
                    cur = container;
                    real = container;
                } else {
                    break false;
                }
            };
            if ok && depth <= 4 {
                kept.push(Kept { c, depth, member });
            }
        }
        // rule 5: one definition per (node, name): the first pattern in the file decides
        kept.sort_by_key(|k| {
            (
                k.c.d.start_byte(),
                k.c.name.map_or(0, |x| x.start_byte()),
                k.c.pat,
            )
        });
        let mut seen: HashSet<(usize, usize)> = HashSet::new();
        kept.retain(|k| seen.insert((k.c.d.id(), k.c.name.map_or(usize::MAX, |x| x.id()))));

        let splits = kept
            .iter()
            .filter(|k| self.pats[k.c.pat].split && k.depth == 0)
            .count();
        let defs: Vec<Def> = kept
            .iter()
            .filter_map(|k| {
                let name = match k.c.name {
                    Some(x) => text_of(x, text).to_string(),
                    None if self.pats[k.c.pat].c_name => {
                        c_declarator_name(k.c.d, text)?.to_string()
                    }
                    None => return None,
                };
                let anchor = k.member.unwrap_or(n);
                let span = match k.member {
                    Some(m) => Some((m.start_byte(), m.end_byte())),
                    None if self.pats[k.c.pat].split && splits > 1 => {
                        Some((k.c.d.start_byte(), k.c.d.end_byte()))
                    }
                    None => None,
                };
                let kinds = if k.depth > 0 {
                    &self.members
                } else {
                    &self.top
                };
                let doc1 = kinds.iter().find_map(|kind| match kind {
                    DocKind::Line => self
                        .line
                        .as_deref()
                        .and_then(|l| doc_before(text, anchor.start_byte(), l)),
                    DocKind::Block => block_doc_before(text, anchor.start_byte()),
                    DocKind::Docstring => docs
                        .get(&k.c.d.id())
                        .and_then(|s| py_docstring_of(*s, text)),
                });
                Some(Def {
                    name,
                    kind: k.c.kind,
                    span,
                    doc1: doc1.map(|d| d.0),
                })
            })
            .collect();

        // rule 6: the form's own doc
        let doc = if defs.is_empty() {
            None
        } else {
            let inner = wrappers.get(&n.id()).copied().unwrap_or(n.id());
            let docstring = self
                .members
                .contains(&DocKind::Docstring)
                .then(|| docs.get(&inner).and_then(|s| py_docstring_of(*s, text)))
                .flatten();
            docstring
                .or_else(|| {
                    self.block
                        .then(|| block_doc_before(text, n.start_byte()))
                        .flatten()
                })
                .or_else(|| {
                    self.line
                        .as_deref()
                        .and_then(|l| doc_before(text, n.start_byte(), l))
                })
        };
        (defs, doc)
    }
}
