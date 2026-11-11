//! A search grouped otherwise than by file in the order found (`search/group`, `search/run`'s `group` and `sort`): a
//! tree of folders (`d:` nodes, one-child chains joined), or each file's matches under the definition they are in (`s:`
//! nodes, the rest under "(top level)"), or the files in another order. The layout is every row in order, each with
//! its parent node; it is built from the matches the run holds (no search again), once per change of the files.

use super::rows::key_path;
use super::run::Found;
use runstav::methods::search::{GrepGroup, GrepSort};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

/// One row of a grouped search: a folder, a file, a definition, a context label, or a match (file and match indices
/// into the run's files).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Ent {
    Dir(u32),
    File(u32),
    Sym(u32),
    Label(u32, u32),
    Match(u32, u32),
}

/// A folder node: its id (`d:` and its path from the root), its label (the joined chain below its parent folder) and
/// its matches.
#[derive(Clone, Debug)]
pub(super) struct Dir {
    pub id: String,
    pub label: String,
    pub path: String,
    pub n: usize,
    /// Folded (`search/fold`): the rows under it are not shown.
    pub folded: bool,
}

/// A definition node of file `file`: its id (`s:PATH:START:END:NAME`, `s:PATH:top` for the matches outside any), its
/// name and kind (none at the top level) and its matches.
#[derive(Clone, Debug)]
pub(super) struct Sym {
    pub id: String,
    pub name: Option<String>,
    pub kind: String,
    pub file: u32,
    pub n: usize,
}

/// A grouped search's rows in order.
#[derive(Debug, Default)]
pub(super) struct Layout {
    pub ents: Vec<Ent>,
    /// Each row's parent node (a row index), none at the top.
    pub parents: Vec<Option<u32>>,
    /// Each row's indent, in steps.
    pub depth: Vec<u32>,
    pub dirs: Vec<Dir>,
    pub syms: Vec<Sym>,
    /// The rows that are nodes of the model (all but the labels), in order.
    pub model: Vec<u32>,
    /// Each file's row, and each of its matches' rows.
    pub at_file: Vec<u32>,
    pub at_match: Vec<Vec<u32>>,
    /// The folders' and definitions' rows by id.
    pub at_node: HashMap<String, u32>,
    /// The rows shown (all but those under a folded folder), and each row's place among them (none: hidden).
    pub shown: Vec<u32>,
    pub shown_at: Vec<Option<u32>>,
}

/// How a layout orders and folds: the sort, the files' ranks (by path relative to the root; [`GrepSort::Rank`]) and
/// the folded folders' ids.
#[derive(Clone, Copy, Default)]
pub(super) struct Order<'a> {
    pub sort: Option<GrepSort>,
    pub ranks: Option<&'a HashMap<String, f64>>,
    pub folded: Option<&'a HashSet<String>>,
}

impl Order<'_> {
    /// File I's rank (0 when the map has none).
    fn rank(&self, root: &Path, files: &[Found], i: u32) -> f64 {
        self.ranks
            .and_then(|r| r.get(key_path(root, &files[i as usize].file)).copied())
            .unwrap_or(0.0)
    }
}

/// Whether the rows need a layout: Files in the order found do not.
pub(super) fn grouped(group: GrepGroup, sort: Option<GrepSort>) -> bool {
    group != GrepGroup::File || sort.is_some()
}

/// The order of the files FILES (indices) of a search of ROOT by O's sort; none keeps it.
fn sorted(root: &Path, files: &[Found], idx: &mut [u32], o: &Order) {
    let path = |i: &u32| key_path(root, &files[*i as usize].file);
    match o.sort {
        None => {}
        Some(GrepSort::Path) => idx.sort_by(|a, b| path(a).cmp(path(b))),
        Some(GrepSort::Count) => idx.sort_by(|a, b| {
            let n = |i: &u32| files[*i as usize].ms.len();
            n(b).cmp(&n(a)).then_with(|| path(a).cmp(path(b)))
        }),
        Some(GrepSort::Rank) => idx.sort_by(|a, b| {
            let r = |i: &u32| o.rank(root, files, *i);
            r(b).total_cmp(&r(a)).then_with(|| path(a).cmp(path(b)))
        }),
    }
}

impl Layout {
    fn push(&mut self, e: Ent, parent: Option<u32>, depth: u32) -> u32 {
        let at = self.ents.len() as u32;
        self.ents.push(e);
        self.parents.push(parent);
        self.depth.push(depth);
        if !matches!(e, Ent::Label(..)) {
            self.model.push(at);
        }
        at
    }

    /// File FI's row and its matches' (their labels when CONTEXT, in Files and Folders), under PARENT at DEPTH.
    fn file(
        &mut self,
        root: &Path,
        files: &[Found],
        fi: u32,
        parent: Option<u32>,
        depth: u32,
        by_sym: bool,
    ) {
        let f = &files[fi as usize];
        let at = self.push(Ent::File(fi), parent, depth);
        self.at_file[fi as usize] = at;
        let mut ms = vec![0; f.ms.len()];
        if by_sym {
            // the definitions in the order of their first match, the top level last
            let mut order: Vec<Option<&Arc<crate::search::context::Def>>> = Vec::new();
            let mut of: Vec<usize> = Vec::with_capacity(f.ms.len());
            for j in 0..f.ms.len() {
                let d = f.ctx.get(j).and_then(Option::as_ref);
                let k = match order.iter().position(|o| match (o, d) {
                    (Some(a), Some(b)) => {
                        Arc::ptr_eq(a, b) || (a.start == b.start && a.end == b.end)
                    }
                    (None, None) => true,
                    _ => false,
                }) {
                    Some(k) => k,
                    None => {
                        order.push(d);
                        order.len() - 1
                    }
                };
                of.push(k);
            }
            let mut ks: Vec<usize> = (0..order.len()).collect();
            ks.sort_by_key(|k| order[*k].map_or(u32::MAX, |d| d.start));
            let kp = key_path(root, &f.file);
            for k in ks {
                let n = of.iter().filter(|x| **x == k).count();
                let (id, name, kind) = match order[k] {
                    Some(d) => (
                        format!("s:{kp}:{}:{}:{}", d.start, d.end, d.name),
                        Some(d.name.clone()),
                        d.kind.clone(),
                    ),
                    None => (format!("s:{kp}:top"), None, String::new()),
                };
                let s = self.syms.len() as u32;
                self.syms.push(Sym {
                    id: id.clone(),
                    name,
                    kind,
                    file: fi,
                    n,
                });
                let sat = self.push(Ent::Sym(s), Some(at), depth + 1);
                self.at_node.insert(id, sat);
                for (j, x) in of.iter().enumerate() {
                    if *x == k {
                        ms[j] = self.push(Ent::Match(fi, j as u32), Some(sat), depth + 2);
                    }
                }
            }
        } else {
            for j in 0..f.ms.len() {
                if f.labelled(j).is_some() {
                    self.push(Ent::Label(fi, j as u32), Some(at), depth + 1);
                }
                ms[j] = self.push(Ent::Match(fi, j as u32), Some(at), depth + 1);
            }
        }
        self.at_match[fi as usize] = ms;
    }

    /// The rows of FILES (a search of ROOT) grouped as GROUP, ordered and folded as O.
    pub(super) fn build(root: &Path, files: &[Found], group: GrepGroup, o: &Order) -> Layout {
        let mut l = Layout {
            at_file: vec![0; files.len()],
            at_match: vec![Vec::new(); files.len()],
            ..Layout::default()
        };
        let mut idx: Vec<u32> = (0..files.len() as u32).collect();
        match group {
            GrepGroup::File | GrepGroup::Symbol => {
                sorted(root, files, &mut idx, o);
                for fi in idx {
                    l.file(root, files, fi, None, 0, group == GrepGroup::Symbol);
                }
            }
            GrepGroup::Tree => {
                let mut t = Node::default();
                for fi in idx {
                    let kp = key_path(root, &files[fi as usize].file);
                    let parts: Vec<&str> = kp.split('/').filter(|p| !p.is_empty()).collect();
                    let (dirs, _) = parts.split_at(parts.len().saturating_sub(1));
                    let (n, r) = (files[fi as usize].ms.len(), o.rank(root, files, fi));
                    let mut at = &mut t;
                    (at.n, at.rank) = (at.n + n, at.rank + r);
                    for d in dirs {
                        at = at.dirs.entry((*d).to_owned()).or_default();
                        (at.n, at.rank) = (at.n + n, at.rank + r);
                    }
                    at.files.push(fi);
                }
                let o = Order {
                    sort: Some(o.sort.unwrap_or(GrepSort::Path)),
                    ..*o
                };
                l.tree(root, files, &t, "", None, 0, &o);
            }
        }
        l.show();
        l
    }

    /// The rows shown: all but those under a folded folder.
    fn show(&mut self) {
        let mut hidden = vec![false; self.ents.len()];
        self.shown_at = vec![None; self.ents.len()];
        for i in 0..self.ents.len() {
            hidden[i] = self.parents[i].is_some_and(|p| {
                let p = p as usize;
                hidden[p] || matches!(self.ents[p], Ent::Dir(k) if self.dirs[k as usize].folded)
            });
            if !hidden[i] {
                self.shown_at[i] = Some(self.shown.len() as u32);
                self.shown.push(i as u32);
            }
        }
    }

    /// The folded folders above row AT, outermost first (opening them shows it).
    pub(super) fn folded_above(&self, at: usize) -> Vec<String> {
        let mut out = Vec::new();
        let mut up = self.parents[at];
        while let Some(p) = up {
            if let Ent::Dir(k) = self.ents[p as usize]
                && self.dirs[k as usize].folded
            {
                out.push(self.dirs[k as usize].id.clone());
            }
            up = self.parents[p as usize];
        }
        out.reverse();
        out
    }

    /// Folder T's children (at PATH, under the row PARENT, at DEPTH): its folders, each with its one-child chain joined,
    /// then its files, each set in O's order (a folder by its matches' count, or its files' ranks together).
    #[allow(clippy::too_many_arguments)]
    fn tree(
        &mut self,
        root: &Path,
        files: &[Found],
        t: &Node,
        path: &str,
        parent: Option<u32>,
        depth: u32,
        o: &Order,
    ) {
        let mut dirs: Vec<(String, &Node)> = t
            .dirs
            .iter()
            .map(|(name, mut d)| {
                let mut label = name.clone();
                while d.files.is_empty() && d.dirs.len() == 1 {
                    let (next, inner) = d.dirs.iter().next().expect("one");
                    label = format!("{label}/{next}");
                    d = inner;
                }
                (label, d)
            })
            .collect();
        match o.sort {
            Some(GrepSort::Count) => {
                dirs.sort_by(|a, b| b.1.n.cmp(&a.1.n).then_with(|| a.0.cmp(&b.0)))
            }
            Some(GrepSort::Rank) => {
                dirs.sort_by(|a, b| b.1.rank.total_cmp(&a.1.rank).then_with(|| a.0.cmp(&b.0)));
            }
            _ => {}
        }
        for (label, d) in dirs {
            let p = if path.is_empty() {
                label.clone()
            } else {
                format!("{path}/{label}")
            };
            let id = format!("d:{p}");
            let k = self.dirs.len() as u32;
            let folded = o.folded.is_some_and(|f| f.contains(&id));
            self.dirs.push(Dir {
                id: id.clone(),
                label,
                path: p.clone(),
                n: d.n,
                folded,
            });
            let at = self.push(Ent::Dir(k), parent, depth);
            self.at_node.insert(id, at);
            self.tree(root, files, d, &p, Some(at), depth + 1, o);
        }
        let mut fs = t.files.clone();
        sorted(root, files, &mut fs, o);
        for fi in fs {
            self.file(root, files, fi, parent, depth, false);
        }
    }

    /// The row of file FI's J-th match.
    pub(super) fn match_row(&self, fi: usize, j: usize) -> Option<usize> {
        self.at_match.get(fi)?.get(j).map(|x| *x as usize)
    }
}

/// A folder of the tree being built: its folders by name, its files, its matches.
#[derive(Default)]
struct Node {
    dirs: BTreeMap<String, Node>,
    files: Vec<u32>,
    n: usize,
    rank: f64,
}
