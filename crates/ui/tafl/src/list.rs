//! Versioned collections: a list of model objects with a version, an epoch and a splice log. A reader follows a list
//! by its splices since the version it last saw; a reader behind the log's start (it was trimmed) starts over once.
//! Only what is read is materialised: a window reads its rows' items, `len` is kept, not counted.

use std::collections::VecDeque;
use std::marker::PhantomData;
use std::ops::Range;

use crate::cell::{CellId, Value};
use crate::engine::Engine;
use crate::model::{Model, ModelRef, Obj};
use crate::propagate::{ALL, add};
use crate::rd::{Rd, Wr};
use crate::splice::{Key, Splice};

/// How many splices a collection keeps for its readers, and how many items they may name in all (a big insert is not
/// kept: its readers start over, which costs what reading the splice would).
pub(crate) const LOG_CAP: usize = 1024;
pub(crate) const LOG_ITEMS: usize = 8192;

/// A collection's version: bumped by every splice that changes it.
#[derive(Clone, Copy, PartialEq, Eq, Debug, PartialOrd, Ord, Hash)]
pub struct Version(pub u64);

/// Whether a `filter_by` matcher is monotone: `Yes(refines)` says when a new key only narrows the old one's matches
/// (fuzzy matching: one more letter), so the previous result is filtered instead of the whole list.
pub enum Monotone<K> {
    No,
    Yes(fn(old: &K, new: &K) -> bool),
}

/// A model collection of T, windowed: only what is read is materialised.
pub struct List<T>(pub(crate) ModelRef, PhantomData<fn() -> T>);

impl<T> Clone for List<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for List<T> {}

/// The items of a range of a collection, as read by a formula.
pub struct Window<T: Model> {
    pub start: usize,
    pub(crate) items: Vec<Obj<T>>,
}

impl<T: Model> Window<T> {
    pub fn len(&self) -> usize {
        self.items.len()
    }
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
    pub fn iter(&self) -> impl Iterator<Item = Obj<T>> + '_ {
        self.items.iter().copied()
    }
}

/// A collection's data, in the engine's list table.
pub(crate) struct ListData {
    /// The items held: all of a local collection, or the window of a remote one.
    pub(crate) items: Vec<CellId>,
    /// The remote collection's length, when the items are a window of it.
    pub(crate) total: Option<u64>,
    /// The window's first position.
    pub(crate) from: usize,
    pub(crate) version: u64,
    pub(crate) epoch: u32,
    /// (the version a splice made, the splice), oldest first.
    pub(crate) log: VecDeque<(u64, Splice)>,
    /// The items the log's splices name.
    log_items: usize,
    /// An operator's new result is being computed on the pool; the old one is shown meanwhile.
    pub(crate) busy: bool,
    /// A pool job's result, waiting for its operator's next run.
    pub(crate) landed: Option<Vec<bool>>,
}

/// What a reader at version SEEN has to do to follow a collection.
pub(crate) enum Follow {
    /// Nothing changed.
    Same,
    /// These splices, in order.
    Splices(Vec<Splice>),
    /// Start over: the log was trimmed past the reader, or a reset came.
    Restart,
}

impl ListData {
    pub(crate) fn new() -> ListData {
        ListData {
            items: Vec::new(),
            total: None,
            from: 0,
            version: 0,
            epoch: 0,
            log: VecDeque::new(),
            log_items: 0,
            busy: false,
            landed: None,
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.total.map_or(self.items.len(), |t| {
            usize::try_from(t).unwrap_or(usize::MAX)
        })
    }

    fn position(&self, k: Key) -> Option<usize> {
        self.items.iter().position(|c| Key::of(*c) == k)
    }

    fn insert_at(&self, after: Option<Key>) -> usize {
        after.map_or(0, |k| self.position(k).map_or(self.items.len(), |p| p + 1))
    }

    /// Apply S; true when it changed the collection (its version is bumped and S logged).
    pub(crate) fn apply(&mut self, s: Splice) -> bool {
        let changed = match &s {
            Splice::Insert { after, items } => {
                let at = self.insert_at(*after);
                let new: Vec<CellId> = items.iter().map(|r| r.cell).collect();
                let n = new.len();
                self.items.splice(at..at, new);
                n > 0
            }
            Splice::Remove { keys } => {
                let before = self.items.len();
                if keys.len() > 8 {
                    let set: std::collections::HashSet<Key> = keys.iter().copied().collect();
                    self.items.retain(|c| !set.contains(&Key::of(*c)));
                } else {
                    self.items.retain(|c| !keys.contains(&Key::of(*c)));
                }
                self.items.len() != before
            }
            Splice::Move { key, after } => match self.position(*key) {
                Some(p) => {
                    let c = self.items.remove(p);
                    let at = self.insert_at(*after);
                    self.items.insert(at, c);
                    true
                }
                None => false,
            },
            Splice::Reset { total, epoch } => {
                if *epoch < self.epoch {
                    false
                } else {
                    self.epoch = *epoch;
                    self.items.clear();
                    self.from = 0;
                    self.total = (*total > 0).then_some(*total);
                    true
                }
            }
        };
        if changed {
            self.log_splice(s);
        }
        changed
    }

    /// Bump the version for S, already applied.
    pub(crate) fn log_splice(&mut self, s: Splice) {
        self.version += 1;
        self.log_items += named(&s);
        self.log.push_back((self.version, s));
        while self.log.len() > LOG_CAP || self.log_items > LOG_ITEMS {
            let Some((_, old)) = self.log.pop_front() else {
                break;
            };
            self.log_items -= named(&old);
        }
    }

    /// What a reader that saw version SEEN has to do.
    pub(crate) fn follow(&self, seen: u64) -> Follow {
        if seen == self.version {
            return Follow::Same;
        }
        match self.log.front() {
            Some((first, _)) if *first <= seen + 1 => {}
            _ => return Follow::Restart,
        }
        let mut out = Vec::new();
        for (v, s) in &self.log {
            if *v <= seen {
                continue;
            }
            if matches!(s, Splice::Reset { .. }) {
                return Follow::Restart;
            }
            out.push(s.clone());
        }
        Follow::Splices(out)
    }
}

/// How many items S names.
fn named(s: &Splice) -> usize {
    match s {
        Splice::Insert { items, .. } => items.len(),
        Splice::Remove { keys } => keys.len(),
        Splice::Move { .. } | Splice::Reset { .. } => 1,
    }
}

impl<T> List<T> {
    pub(crate) fn new(r: ModelRef) -> Self {
        List(r, PhantomData)
    }
    pub fn model_ref(self) -> ModelRef {
        self.0
    }
}

impl<T: Model> List<T> {
    /// The collection's length (kept, not counted: reading it visits no item).
    pub fn len(self, r: &Rd) -> usize {
        r.e.core.touch(r.e, self.0.cell);
        r.e.core.lists.borrow()[self.0.aux as usize].len()
    }
    pub fn is_empty(self, r: &Rd) -> bool {
        self.len(r) == 0
    }
    /// The items of ROWS that are held (for a remote collection: those of its window); `start` is the first one's row.
    pub fn window(self, r: &Rd, rows: Range<usize>) -> Window<T> {
        r.e.core.touch(r.e, self.0.cell);
        let lists = r.e.core.lists.borrow();
        let l = &lists[self.0.aux as usize];
        let start = rows.start.max(l.from);
        let end = rows.end.min(l.from + l.items.len());
        let items: Vec<Obj<T>> = if start < end {
            l.items[start - l.from..end - l.from]
                .iter()
                .map(|c| Obj::from_ref(ModelRef { cell: *c, aux: 0 }))
                .collect()
        } else {
            Vec::new()
        };
        add(&r.e.core.n.item_visits, items.len() as u64);
        Window { start, items }
    }
    /// Apply splice S. A reset of an older epoch than the collection's is ignored.
    pub fn splice(self, w: &mut Wr, s: Splice) {
        let core = &w.e.core;
        let changed = core.lists.borrow_mut()[self.0.aux as usize].apply(s);
        if changed {
            let mut g = core.g.borrow_mut();
            core.changed(&mut g, self.0.cell.idx, ALL);
        }
    }
    pub fn version(self, r: &Rd) -> Version {
        r.e.core.touch(r.e, self.0.cell);
        Version(r.e.core.lists.borrow()[self.0.aux as usize].version)
    }
    /// Whether a new result is being computed on the pool (the old one is shown meanwhile).
    pub fn busy(self, r: &Rd) -> bool {
        r.e.core.touch(r.e, self.0.cell);
        r.e.core.lists.borrow()[self.0.aux as usize].busy
    }
    /// The items for which F holds, in order: an upstream splice becomes a downstream splice, and a patched item is
    /// tested again alone.
    pub fn filter(self, e: &mut Engine, f: impl Fn(Obj<T>, &Rd) -> bool + 'static) -> List<T> {
        crate::ops::filter::make(e, self, f)
    }
    /// The items for which PRED(item, key) holds, KEY read from cells. PRED is a plain function: over 10,000 items it
    /// runs on the work pool, and the old result stays (`busy`) until the new one lands. With `Monotone::Yes`, a key
    /// that refines the old one filters the previous result only.
    pub fn filter_by<K: Value + Send + Sync>(
        self,
        e: &mut Engine,
        key: impl Fn(&Rd) -> K + 'static,
        pred: fn(&T, &K) -> bool,
        monotone: Monotone<K>,
    ) -> List<T>
    where
        T: Send + Sync,
    {
        crate::ops::pool::make(e, self, key, pred, monotone)
    }
    /// The items sorted by KEY (stable for equal keys by item): a changed key moves its item alone.
    pub fn sort_by<K: Ord + Value>(
        self,
        e: &mut Engine,
        key: impl Fn(Obj<T>, &Rd) -> K + 'static,
    ) -> List<T> {
        crate::ops::sort::make(e, self, key)
    }
}
