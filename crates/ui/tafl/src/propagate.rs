//! Propagation: push dirty, pull on demand (the Reactively colouring algorithm), with salsa's durability.
//!
//! - **Write.** A write that changes a value bumps the revision `R` and is queued; when the transaction ends one marking
//!   pass marks the direct dependents **dirty** and their transitive dependents **check**, stopping at cells already
//!   marked. Marking runs no user code. A model object's readers are marked only when they read a changed field.
//! - **Pull.** Pulling a check cell first brings its formula sources up to date; if none changed, the cell is clean
//!   without running. A dirty cell re-runs; when its new value equals the old (the **cutoff**) its dependents stay
//!   clean.
//! - **Edges** are recorded from the reads of each run, and reused when a re-run reads the same sources in the same
//!   order (Preact), so a steady re-run allocates nothing.

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::Waker;
use std::time::Duration;

use crate::cell::{CellId, Value};
use crate::edge::{EdgeTable, NONE};
use crate::engine::{Engine, FormulaError};
use crate::list::ListData;
use crate::ops::pool::Job;
use crate::rd::Rd;
use crate::slab::{Node, SlabInfo, Slabs};

/// A cell's mark (the low two bits of its flags).
pub(crate) const MARK: u8 = 0b11;
pub(crate) const CLEAN: u8 = 0;
pub(crate) const CHECK: u8 = 1;
pub(crate) const DIRTY: u8 = 2;
/// The cell has a compute (a formula or an operator).
pub(crate) const FORMULA: u8 = 1 << 2;
/// Every source of the cell is durable (a durable state: theme, fonts, settings, scale).
pub(crate) const DURABLE: u8 = 1 << 3;
/// A model object: its readers are marked by changed field.
pub(crate) const OBJECT: u8 = 1 << 4;
/// A clock cell.
pub(crate) const CLOCK: u8 = 1 << 5;
/// A free slot.
pub(crate) const FREE: u8 = 1 << 6;
/// An operator that keeps its edges between runs (it links and unlinks item by item).
pub(crate) const KEEP: u8 = 1 << 7;

/// Every field: a read or a change of the whole value.
pub(crate) const ALL: u64 = u64::MAX;

/// The cells, in columns (structure of arrays), one row per slot.
pub(crate) struct Graph {
    pub(crate) node: Vec<Option<Box<dyn Node>>>,
    pub(crate) changed: Vec<u32>,
    pub(crate) verified: Vec<u32>,
    pub(crate) round: Vec<u32>,
    /// The next cell of the same slab.
    pub(crate) next: Vec<u32>,
    pub(crate) flags: Vec<u8>,
    pub(crate) stage: Vec<u8>,
    pub(crate) src: EdgeTable<2>,
    pub(crate) dep: EdgeTable<3>,
    /// (object, reader) → the fields the reader read.
    pub(crate) masks: HashMap<(u32, u32), u64>,
    pub(crate) free: Vec<u32>,
    pub(crate) rev: u32,
    pub(crate) durable_rev: u32,
    pub(crate) live: u64,
    pub(crate) edges: u64,
}

impl Graph {
    fn new() -> Graph {
        Graph {
            node: Vec::new(),
            changed: Vec::new(),
            verified: Vec::new(),
            round: Vec::new(),
            next: Vec::new(),
            flags: Vec::new(),
            stage: Vec::new(),
            src: EdgeTable::default(),
            dep: EdgeTable::default(),
            masks: HashMap::new(),
            free: Vec::new(),
            rev: 1,
            durable_rev: 1,
            live: 0,
            edges: 0,
        }
    }

    /// A slot: a freed one, else a new row (the columns grow by a 64th, at least 1024 rows, so their slack stays
    /// under 2%).
    fn slot(&mut self) -> u32 {
        if let Some(i) = self.free.pop() {
            return i;
        }
        let i = self.node.len();
        if i == self.node.capacity() {
            let add = (i / 64).max(1024);
            self.node.reserve_exact(add);
            self.changed.reserve_exact(add);
            self.verified.reserve_exact(add);
            self.round.reserve_exact(add);
            self.next.reserve_exact(add);
            self.flags.reserve_exact(add);
            self.stage.reserve_exact(add);
        }
        let reserve = self.node.capacity() - i;
        self.node.push(None);
        self.changed.push(0);
        self.verified.push(0);
        self.round.push(0);
        self.next.push(NONE);
        self.flags.push(FREE);
        self.stage.push(0);
        self.src.grow_to(i + 1, reserve);
        self.dep.grow_to(i + 1, reserve);
        u32::try_from(i).unwrap_or_else(|_| panic!("tafl: more than 4 billion cells"))
    }

    pub(crate) fn mark(&self, i: u32) -> u8 {
        self.flags[i as usize] & MARK
    }

    fn set_mark(&mut self, i: u32, m: u8) {
        let f = &mut self.flags[i as usize];
        *f = (*f & !MARK) | m;
    }

    /// Link CELL → S on the dependents' side (the caller writes the sources' side).
    pub(crate) fn link_dep(&mut self, cell: u32, s: u32, touched: &Cell<bool>) {
        self.dep.push(s, cell);
        self.edges += 1;
        if self.flags[s as usize] & CLOCK != 0 {
            touched.set(true);
        }
    }

    /// Unlink CELL → S on the dependents' side, and its field mask.
    pub(crate) fn unlink_dep(&mut self, cell: u32, s: u32, touched: &Cell<bool>) {
        self.dep.remove_unordered(s, cell);
        if self.flags[s as usize] & OBJECT != 0 {
            self.masks.remove(&(s, cell));
        }
        self.edges = self.edges.saturating_sub(1);
        if self.flags[s as usize] & CLOCK != 0 {
            touched.set(true);
        }
    }

    /// Mark D dirty, and its transitive dependents check (stopping at marked cells). The cells marked.
    pub(crate) fn mark_dirty(&mut self, d: u32, stack: &mut Vec<u32>) -> u64 {
        let m = self.mark(d);
        if m == DIRTY || self.flags[d as usize] & FREE != 0 {
            return 0;
        }
        self.set_mark(d, DIRTY);
        let mut n = 1;
        if m == CLEAN {
            stack.clear();
            self.push_deps(d, stack);
            while let Some(c) = stack.pop() {
                if self.mark(c) == CLEAN && self.flags[c as usize] & FREE == 0 {
                    self.set_mark(c, CHECK);
                    n += 1;
                    self.push_deps(c, stack);
                }
            }
        }
        n
    }

    fn push_deps(&self, c: u32, stack: &mut Vec<u32>) {
        for k in 0..self.dep.len(c) {
            stack.push(self.dep.get(c, k));
        }
    }
}

/// The reads of one run.
pub(crate) struct Recorder {
    pub(crate) cell: u32,
    keep: bool,
    /// How many of the old sources this run read again, in order.
    pos: u32,
    diverged: bool,
    /// Reads past the point where this run left the old order.
    extra: Vec<u32>,
    /// The fields read of each model object.
    masks: Vec<(u32, u64)>,
}

/// The engine's counters.
#[derive(Default)]
pub(crate) struct Counters {
    pub(crate) runs: Cell<u64>,
    pub(crate) marks: Cell<u64>,
    pub(crate) mark_passes: Cell<u64>,
    pub(crate) verifies: Cell<u64>,
    pub(crate) frame_requests: Cell<u64>,
    pub(crate) resets: Cell<u64>,
    pub(crate) item_visits: Cell<u64>,
    pub(crate) ticks: Cell<u64>,
    pub(crate) work_ns: Cell<u64>,
    pub(crate) bookkeeping_ns: Cell<u64>,
}

pub(crate) fn add(c: &Cell<u64>, n: u64) {
    c.set(c.get().wrapping_add(n));
}

/// What the engine shares with other threads: the UI loop's waker, and whether a timer or a job has woken it.
#[derive(Default)]
pub(crate) struct Shared {
    pub(crate) waker: std::sync::Mutex<Option<Waker>>,
    pub(crate) woken: AtomicBool,
}

impl std::task::Wake for Shared {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.woken.store(true, Ordering::SeqCst);
        if let Some(w) = saman::lock(&self.waker).as_ref() {
            w.wake_by_ref();
        }
    }
}

/// The engine's state that a formula's run reaches through `&Rd` (interior mutability: a run pulls its sources, which
/// may run in turn).
pub(crate) struct Core {
    pub(crate) g: RefCell<Graph>,
    rec: RefCell<Vec<Recorder>>,
    spare: RefCell<Vec<Vec<u32>>>,
    spare_masks: RefCell<Vec<Vec<(u32, u64)>>>,
    pub(crate) lists: RefCell<Vec<ListData>>,
    pub(crate) errors: RefCell<HashMap<u32, FormulaError>>,
    pending: RefCell<Vec<(u32, u64)>>,
    tx_bumped: Cell<bool>,
    pub(crate) n: Counters,
    pub(crate) clock: Arc<dyn stund::Provider>,
    /// Clock cells and their grains.
    pub(crate) clocks: RefCell<Vec<(u32, Duration)>>,
    /// An edge to a clock cell came or went: the timer is re-armed.
    pub(crate) clock_touched: Cell<bool>,
    pub(crate) requested: Cell<bool>,
    pub(crate) shared: Arc<Shared>,
    pub(crate) timing: Cell<bool>,
    pub(crate) pool: Arc<saman::Executor>,
    pub(crate) jobs: RefCell<Vec<Job>>,
    pub(crate) wire_ids: RefCell<HashMap<Arc<str>, CellId>>,
    pub(crate) slabs: RefCell<Slabs>,
    pub(crate) model_slab: Cell<u32>,
}

fn panic_message(p: &(dyn Any + Send)) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = p.downcast_ref::<String>() {
        s.clone()
    } else {
        "a formula panicked".to_string()
    }
}

impl Core {
    pub(crate) fn new(pool: Arc<saman::Executor>, clock: Arc<dyn stund::Provider>) -> Core {
        Core {
            g: RefCell::new(Graph::new()),
            rec: RefCell::new(Vec::new()),
            spare: RefCell::new(Vec::new()),
            spare_masks: RefCell::new(Vec::new()),
            lists: RefCell::new(Vec::new()),
            errors: RefCell::new(HashMap::new()),
            pending: RefCell::new(Vec::new()),
            tx_bumped: Cell::new(false),
            n: Counters::default(),
            clock,
            clocks: RefCell::new(Vec::new()),
            clock_touched: Cell::new(false),
            requested: Cell::new(false),
            shared: Arc::new(Shared::default()),
            timing: Cell::new(false),
            pool,
            jobs: RefCell::new(Vec::new()),
            wire_ids: RefCell::new(HashMap::new()),
            slabs: RefCell::new(Slabs::default()),
            model_slab: Cell::new(0),
        }
    }

    pub(crate) fn take_vec(&self) -> Vec<u32> {
        self.spare.borrow_mut().pop().unwrap_or_default()
    }

    pub(crate) fn give_vec(&self, mut v: Vec<u32>) {
        v.clear();
        self.spare.borrow_mut().push(v);
    }

    // ---- slabs and cells

    pub(crate) fn new_slab(&self, key: crate::slab::InstanceKey) -> crate::slab::SlabId {
        let mut s = self.slabs.borrow_mut();
        if let Some(i) = s.free.pop() {
            let info = &mut s.v[i as usize];
            info.head = NONE;
            info.live = true;
            info.key = key;
            return crate::slab::SlabId {
                idx: i,
                round: info.round,
            };
        }
        let i = u32::try_from(s.v.len()).unwrap_or_else(|_| panic!("tafl: too many slabs"));
        s.v.push(SlabInfo {
            head: NONE,
            round: 0,
            live: true,
            key,
        });
        crate::slab::SlabId { idx: i, round: 0 }
    }

    /// The slab's index, or a panic for a dropped slab (a bug in the caller).
    pub(crate) fn slab_idx(&self, s: crate::slab::SlabId) -> u32 {
        let slabs = self.slabs.borrow();
        let ok = slabs
            .v
            .get(s.idx as usize)
            .is_some_and(|i| i.live && i.round == s.round);
        assert!(ok, "tafl: a cell was made in a dropped slab");
        s.idx
    }

    /// A new cell in slab SLAB holding NODE.
    pub(crate) fn alloc(&self, slab: u32, node: Box<dyn Node>, flags: u8, stage: u8) -> CellId {
        let mut g = self.g.borrow_mut();
        let i = g.slot();
        let u = i as usize;
        let rev = g.rev;
        g.node[u] = Some(node);
        g.flags[u] = flags;
        g.stage[u] = stage;
        g.changed[u] = rev;
        g.verified[u] = 0;
        let mut slabs = self.slabs.borrow_mut();
        let info = &mut slabs.v[slab as usize];
        g.next[u] = info.head;
        info.head = i;
        g.live += 1;
        CellId {
            idx: i,
            round: g.round[u],
        }
    }

    /// The cells of slab S, in no particular order.
    pub(crate) fn slab_cells(&self, s: u32) -> Vec<u32> {
        let g = self.g.borrow();
        let mut out = Vec::new();
        let mut c = self.slabs.borrow().v[s as usize].head;
        while c != NONE {
            out.push(c);
            c = g.next[c as usize];
        }
        out
    }

    /// Free CELLS (one slab's): their edges go, their outside dependents are marked dirty (a read of a freed cell is an
    /// error shown in place), and their slots and nodes are released. The nodes, for the caller to drop.
    pub(crate) fn free_cells(&self, cells: &[u32]) -> Vec<Box<dyn Node>> {
        let mut dropped = Vec::with_capacity(cells.len());
        let mut tmp = self.take_vec();
        let mut stack = self.take_vec();
        let mut marks = 0;
        {
            let mut g = self.g.borrow_mut();
            let g = &mut *g;
            for &c in cells {
                g.flags[c as usize] |= FREE;
            }
            for &c in cells {
                g.src.copy_into(c, &mut tmp);
                for &s in &tmp {
                    g.unlink_dep(c, s, &self.clock_touched);
                }
                g.src.clear(c);
                g.dep.copy_into(c, &mut tmp);
                for &d in &tmp {
                    if g.flags[d as usize] & FREE == 0 {
                        g.src.remove(d, c);
                        g.masks.remove(&(c, d));
                        g.edges = g.edges.saturating_sub(1);
                        marks += g.mark_dirty(d, &mut stack);
                    }
                }
                g.dep.clear(c);
                let u = c as usize;
                if let Some(n) = g.node[u].take() {
                    dropped.push(n);
                }
                g.round[u] = g.round[u].wrapping_add(1);
                g.flags[u] = FREE;
                g.next[u] = NONE;
                g.live -= 1;
                g.free.push(c);
            }
        }
        {
            let mut errors = self.errors.borrow_mut();
            for c in cells {
                errors.remove(c);
            }
        }
        self.give_vec(tmp);
        self.give_vec(stack);
        add(&self.n.marks, marks);
        if marks > 0 {
            self.request_frame();
        }
        dropped
    }

    /// The slot of C, or a panic when C was freed: a handle outlived its instance.
    pub(crate) fn live(&self, c: CellId) -> usize {
        let g = self.g.borrow();
        let u = c.idx as usize;
        let ok = u < g.round.len() && g.round[u] == c.round && g.flags[u] & FREE == 0;
        assert!(ok, "tafl: a cell of a dropped instance was used");
        u
    }

    /// Whether C is a live cell (not freed, not a slot reused since).
    pub(crate) fn is_live(&self, c: CellId) -> bool {
        let g = self.g.borrow();
        let u = c.idx as usize;
        u < g.round.len() && g.round[u] == c.round && g.flags[u] & FREE == 0
    }

    /// Read cell C inside a run without taking a value (a collection's cell): brought up to date and recorded.
    pub(crate) fn touch(&self, e: &Engine, c: CellId) {
        let u = self.live(c);
        if self.g.borrow().flags[u] & FORMULA != 0 {
            self.update(e, c.idx);
        }
        self.record(c.idx, ALL);
    }

    pub(crate) fn id(&self, i: u32) -> CellId {
        CellId {
            idx: i,
            round: self.g.borrow().round[i as usize],
        }
    }

    // ---- pull

    /// Bring cell I up to date. True when it re-ran and its value changed.
    pub(crate) fn update(&self, e: &Engine, i: u32) -> bool {
        let m = self.g.borrow().mark(i);
        if m == CLEAN {
            return false;
        }
        if m == CHECK {
            let skip = {
                let g = self.g.borrow();
                g.flags[i as usize] & DURABLE != 0 && g.verified[i as usize] >= g.durable_rev
            };
            if !skip {
                add(&self.n.verifies, 1);
                let mut tmp = self.take_vec();
                self.g.borrow().src.copy_into(i, &mut tmp);
                for &s in &tmp {
                    let formula = self.g.borrow().flags[s as usize] & FORMULA != 0;
                    if formula {
                        self.update(e, s);
                    }
                    if self.g.borrow().mark(i) == DIRTY {
                        break;
                    }
                }
                self.give_vec(tmp);
            }
        }
        if self.g.borrow().mark(i) == DIRTY {
            self.run(e, i)
        } else {
            let mut g = self.g.borrow_mut();
            let r = g.rev;
            g.set_mark(i, CLEAN);
            g.verified[i as usize] = r;
            false
        }
    }

    /// Re-run cell I: its reads recorded, a panic caught (the old value stays and the error is kept for the cell), the
    /// edges brought to what this run read. True when the value changed.
    fn run(&self, e: &Engine, i: u32) -> bool {
        let (node, keep) = {
            let mut g = self.g.borrow_mut();
            let keep = g.flags[i as usize] & KEEP != 0;
            (g.node[i as usize].take(), keep)
        };
        let Some(mut node) = node else {
            let id = self.id(i);
            let message = "a formula reads itself (a cycle)".to_string();
            self.errors.borrow_mut().insert(
                i,
                FormulaError {
                    cell: id,
                    message: message.clone(),
                },
            );
            panic!("tafl: {message}");
        };
        let rec = Recorder {
            cell: i,
            keep,
            pos: 0,
            diverged: false,
            extra: self.take_vec(),
            masks: self.spare_masks.borrow_mut().pop().unwrap_or_default(),
        };
        self.rec.borrow_mut().push(rec);
        let t0 = self.timing.get().then(|| self.clock.now());
        let res = catch_unwind(AssertUnwindSafe(|| node.run(&Rd { e })));
        if let Some(t0) = t0 {
            let ns =
                u64::try_from(self.clock.now().saturating_sub(t0).as_nanos()).unwrap_or(u64::MAX);
            add(&self.n.work_ns, ns);
        }
        let rec = self
            .rec
            .borrow_mut()
            .pop()
            .unwrap_or_else(|| panic!("tafl: a run lost its recorder"));
        self.g.borrow_mut().node[i as usize] = Some(node);
        let ok = res.is_ok();
        self.finish(i, rec, ok);
        add(&self.n.runs, 1);
        let changed = match res {
            Ok(changed) => {
                if self.errors.borrow().contains_key(&i) {
                    self.errors.borrow_mut().remove(&i);
                }
                changed
            }
            Err(p) => {
                let message = panic_message(&*p);
                let cell = self.id(i);
                tracing::warn!(cell = i, %message, "a formula panicked; its cell keeps its old value");
                self.errors
                    .borrow_mut()
                    .insert(i, FormulaError { cell, message });
                false
            }
        };
        let mut stack = self.take_vec();
        let mut marks = 0;
        {
            let mut g = self.g.borrow_mut();
            let g = &mut *g;
            let r = g.rev;
            if changed {
                g.changed[i as usize] = r;
                for k in 0..g.dep.len(i) {
                    let d = g.dep.get(i, k);
                    if g.mark(d) == CHECK {
                        g.set_mark(d, DIRTY);
                    } else {
                        marks += g.mark_dirty(d, &mut stack);
                    }
                }
            }
            g.set_mark(i, CLEAN);
            g.verified[i as usize] = r;
            crate::durable::settle(g, i);
        }
        self.give_vec(stack);
        add(&self.n.marks, marks);
        changed
    }

    /// Bring cell I's sources to what the run in REC read.
    fn finish(&self, i: u32, mut rec: Recorder, ok: bool) {
        {
            let mut g = self.g.borrow_mut();
            let g = &mut *g;
            if !rec.keep {
                let old_len = g.src.len(i);
                let p = rec.pos as usize;
                if !rec.diverged {
                    if ok && p < old_len {
                        for k in (p..old_len).rev() {
                            let s = g.src.get(i, k);
                            g.unlink_dep(i, s, &self.clock_touched);
                        }
                        g.src.truncate(i, p);
                    }
                } else {
                    let mut old = self.take_vec();
                    g.src.copy_into(i, &mut old);
                    if ok {
                        for &s in &old[p..] {
                            if !rec.extra.contains(&s) {
                                g.unlink_dep(i, s, &self.clock_touched);
                            }
                        }
                        for &s in &rec.extra {
                            if !old[p..].contains(&s) {
                                g.link_dep(i, s, &self.clock_touched);
                            }
                        }
                        g.src.truncate(i, p);
                        for &s in &rec.extra {
                            g.src.push(i, s);
                        }
                    } else {
                        // a panic: keep every old source and add the new ones, so the next write still reaches the cell
                        for &s in &rec.extra {
                            if !old.contains(&s) {
                                g.link_dep(i, s, &self.clock_touched);
                                g.src.push(i, s);
                            }
                        }
                    }
                    self.give_vec(old);
                }
            }
            for &(o, m) in &rec.masks {
                if g.flags[o as usize] & OBJECT == 0 || !g.dep.contains(o, i) {
                    continue;
                }
                let e = g.masks.entry((o, i)).or_insert(0);
                if ok && !rec.keep {
                    *e = m;
                } else {
                    *e |= m;
                }
            }
        }
        let extra = std::mem::take(&mut rec.extra);
        self.give_vec(extra);
        let mut masks = std::mem::take(&mut rec.masks);
        masks.clear();
        self.spare_masks.borrow_mut().push(masks);
    }

    /// Record a read of S (MASK: the fields read, for a model object) into the run in progress.
    pub(crate) fn record(&self, s: u32, mask: u64) {
        let mut recs = self.rec.borrow_mut();
        let Some(r) = recs.last_mut() else {
            return;
        };
        let cell = r.cell;
        let object = self.g.borrow().flags[s as usize] & OBJECT != 0;
        if r.keep {
            // an operator reads many items: its edges and field masks only grow during a run
            let mut g = self.g.borrow_mut();
            if !g.dep.contains(s, cell) {
                g.src.push(cell, s);
                g.link_dep(cell, s, &self.clock_touched);
            }
            if object {
                *g.masks.entry((s, cell)).or_insert(0) |= mask;
            }
            return;
        }
        if object {
            match r.masks.iter_mut().find(|(o, _)| *o == s) {
                Some(e) => e.1 |= mask,
                None => r.masks.push((s, mask)),
            }
        }
        let g = self.g.borrow();
        if !r.diverged {
            let old_len = g.src.len(cell) as u32;
            if r.pos < old_len && g.src.get(cell, r.pos as usize) == s {
                r.pos += 1;
                return;
            }
            if (0..r.pos).any(|k| g.src.get(cell, k as usize) == s) {
                return;
            }
            r.diverged = true;
        }
        if !r.extra.contains(&s) && !(0..r.pos).any(|k| g.src.get(cell, k as usize) == s) {
            r.extra.push(s);
        }
    }

    /// The cell of the run in progress.
    pub(crate) fn current(&self) -> u32 {
        self.rec
            .borrow()
            .last()
            .map(|r| r.cell)
            .unwrap_or_else(|| panic!("tafl: no formula is running"))
    }

    /// Read cell C inside a run: brought up to date, recorded with MASK, and its value given to F.
    pub(crate) fn read_with<V: 'static, R>(
        &self,
        e: &Engine,
        c: CellId,
        mask: u64,
        f: impl FnOnce(&V) -> R,
    ) -> R {
        let u = self.live(c);
        let i = c.idx;
        let (formula, fresh_clock) = {
            let g = self.g.borrow();
            (
                g.flags[u] & FORMULA != 0,
                g.flags[u] & CLOCK != 0 && g.dep.len(i) == 0,
            )
        };
        if fresh_clock {
            self.refresh_clock(i);
        }
        if formula {
            self.update(e, i);
        }
        self.record(i, mask);
        let g = self.g.borrow();
        let v = g.node[u]
            .as_ref()
            .and_then(|n| n.value())
            .and_then(|v| v.downcast_ref::<V>());
        match v {
            Some(v) => f(v),
            None => {
                let why = self.no_value(i, g.node[u].is_none());
                drop(g);
                panic!("tafl: {why}");
            }
        }
    }

    fn no_value(&self, i: u32, running: bool) -> String {
        if running {
            return "a formula reads itself (a cycle)".into();
        }
        match self.errors.borrow().get(&i) {
            Some(e) => format!("a source formula failed: {}", e.message),
            None => "a cell was read as another type".into(),
        }
    }

    /// Cell C's value outside a run (no edge recorded); for a formula, brought up to date first.
    pub(crate) fn value_of<T: Value>(&self, e: &Engine, c: CellId) -> Result<T, FormulaError> {
        let u = self.live(c);
        let (formula, fresh_clock) = {
            let g = self.g.borrow();
            (
                g.flags[u] & FORMULA != 0,
                g.flags[u] & CLOCK != 0 && g.dep.len(c.idx) == 0,
            )
        };
        if fresh_clock {
            self.refresh_clock(c.idx);
        }
        if formula {
            self.update(e, c.idx);
        }
        let g = self.g.borrow();
        match g.node[u]
            .as_ref()
            .and_then(|n| n.value())
            .and_then(|v| v.downcast_ref::<T>())
        {
            Some(v) => Ok(v.clone()),
            None => Err(self
                .errors
                .borrow()
                .get(&c.idx)
                .cloned()
                .unwrap_or(FormulaError {
                    cell: c,
                    message: "the formula has no value".into(),
                })),
        }
    }

    // ---- write

    /// This transaction's revision: bumped at its first change.
    pub(crate) fn tx_rev(&self, g: &mut Graph) -> u32 {
        if !self.tx_bumped.get() {
            self.tx_bumped.set(true);
            g.rev = g.rev.wrapping_add(1);
            if g.rev == u32::MAX {
                crate::durable::renumber(g);
            }
        }
        g.rev
    }

    /// Queue cell I as changed (MASK: the fields that changed, for a model object).
    pub(crate) fn changed(&self, g: &mut Graph, i: u32, mask: u64) {
        let r = self.tx_rev(g);
        g.changed[i as usize] = r;
        if g.flags[i as usize] & DURABLE != 0 {
            g.durable_rev = r;
        }
        self.pending.borrow_mut().push((i, mask));
    }

    /// Write V into cell C; an equal value is a no-op.
    pub(crate) fn set<T: Value>(&self, c: CellId, v: T) {
        let u = self.live(c);
        let mut g = self.g.borrow_mut();
        let slot = g.node[u]
            .as_mut()
            .and_then(|n| n.value_mut())
            .and_then(|v| v.downcast_mut::<T>())
            .unwrap_or_else(|| panic!("tafl: a state was written as another type"));
        if *slot == v {
            return;
        }
        *slot = v;
        self.changed(&mut g, c.idx, ALL);
    }

    /// Change model object C in place with F; only the fields that differ are marked.
    pub(crate) fn patch<T: crate::model::Model>(&self, c: CellId, f: impl FnOnce(&mut T)) {
        let u = self.live(c);
        let mut g = self.g.borrow_mut();
        let slot = g.node[u]
            .as_mut()
            .and_then(|n| n.value_mut())
            .and_then(|v| v.downcast_mut::<T>())
            .unwrap_or_else(|| panic!("tafl: a model object was patched as another type"));
        let old = slot.clone();
        f(slot);
        let mask = T::diff(&old, slot);
        if mask != 0 {
            self.changed(&mut g, c.idx, mask);
        }
    }

    /// End the transaction: one marking pass over its changes.
    pub(crate) fn commit(&self) {
        self.tx_bumped.set(false);
        let mut pending = std::mem::take(&mut *self.pending.borrow_mut());
        if pending.is_empty() {
            *self.pending.borrow_mut() = pending;
            return;
        }
        add(&self.n.mark_passes, 1);
        let mut stack = self.take_vec();
        let mut marks = 0;
        {
            let mut g = self.g.borrow_mut();
            let g = &mut *g;
            for &(s, mask) in &pending {
                let object = g.flags[s as usize] & OBJECT != 0;
                for k in 0..g.dep.len(s) {
                    let d = g.dep.get(s, k);
                    if object && mask != ALL {
                        let read = g.masks.get(&(s, d)).copied().unwrap_or(ALL);
                        if read & mask == 0 {
                            continue;
                        }
                    }
                    marks += g.mark_dirty(d, &mut stack);
                }
            }
        }
        pending.clear();
        *self.pending.borrow_mut() = pending;
        self.give_vec(stack);
        add(&self.n.marks, marks);
        if marks > 0 {
            self.request_frame();
        }
    }

    pub(crate) fn request_frame(&self) -> bool {
        if self.requested.get() {
            return false;
        }
        self.requested.set(true);
        add(&self.n.frame_requests, 1);
        if let Some(w) = saman::lock(&self.shared.waker).as_ref() {
            w.wake_by_ref();
        }
        true
    }

    // ---- operators' helpers

    /// The sources of operator MY that changed since it last ran: whether any outside its source list SRC and its
    /// items did (a query: start over), and which model objects did.
    pub(crate) fn changed_sources(&self, my: u32, src: u32) -> (bool, Vec<u32>) {
        let g = self.g.borrow();
        let since = g.verified[my as usize];
        let mut outside = false;
        let mut objs = Vec::new();
        for k in 0..g.src.len(my) {
            let s = g.src.get(my, k);
            if g.changed[s as usize] > since {
                if g.flags[s as usize] & OBJECT != 0 {
                    objs.push(s);
                } else if s != src {
                    outside = true;
                }
            }
        }
        (outside, objs)
    }

    /// Unlink operator MY from S.
    pub(crate) fn unlink(&self, my: u32, s: u32) {
        let mut g = self.g.borrow_mut();
        if g.src.remove_unordered(my, s) {
            g.unlink_dep(my, s, &self.clock_touched);
        }
    }

    /// Unlink operator MY from every model object it reads (it starts over): one pass over its sources.
    pub(crate) fn unlink_objects(&self, my: u32) {
        let mut all = self.take_vec();
        let mut keep = self.take_vec();
        {
            let mut g = self.g.borrow_mut();
            let g = &mut *g;
            g.src.copy_into(my, &mut all);
            for &s in &all {
                if g.flags[s as usize] & OBJECT != 0 {
                    g.unlink_dep(my, s, &self.clock_touched);
                } else {
                    keep.push(s);
                }
            }
            g.src.set(my, &keep);
        }
        self.give_vec(all);
        self.give_vec(keep);
    }

    /// Model object C's value, untracked (an operator's snapshot).
    pub(crate) fn object<T: Clone + 'static>(&self, c: CellId) -> T {
        let g = self.g.borrow();
        g.node[c.idx as usize]
            .as_ref()
            .and_then(|n| n.value())
            .and_then(|v| v.downcast_ref::<T>())
            .cloned()
            .unwrap_or_else(|| panic!("tafl: a list holds an item of another type"))
    }
}
