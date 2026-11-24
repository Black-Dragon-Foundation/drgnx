//! The engine: slabs of cells, the global revision, the durable revision and the dirty marks.

use std::sync::Arc;

use crate::cell::{CellId, Formula, Origin, Stage, State, Value};
use crate::clock::Timer;
use crate::list::{List, ListData};
use crate::model::{Model, ModelRef};
use crate::propagate::{Core, DIRTY, DURABLE, FORMULA};
use crate::rd::{Rd, Wr};
use crate::slab::{FormulaNode, InstanceKey, ListCellNode, SlabId, StateNode};
use crate::state_table::Table;
use crate::stats::Stats;

/// A formula that panicked: its cell keeps its old value, and this is shown in place.
#[derive(Clone, Debug, PartialEq)]
pub struct FormulaError {
    pub cell: CellId,
    pub message: String,
}

/// The engine: slabs of cells, the global revision, the durable revision and the dirty marks.
pub struct Engine {
    pub(crate) core: Core,
    pub(crate) states: Table,
    pub(crate) timer: Option<Timer>,
    /// Roots a frame over budget left for the next one.
    pub(crate) carried: Vec<CellId>,
}

impl Engine {
    /// An engine whose `filter_by` jobs run on POOL and whose clock cells and frame budgets read CLOCK.
    pub fn new(pool: Arc<saman::Executor>, clock: Arc<dyn stund::Provider>) -> Engine {
        let core = Core::new(pool, clock);
        let model = core.new_slab(InstanceKey {
            doc: Arc::from(""),
            path: Arc::from(&[][..]),
        });
        core.model_slab.set(model.idx);
        Engine {
            core,
            states: Table::default(),
            timer: None,
            carried: Vec::new(),
        }
    }

    /// A slab for the instance OWNER: its cells are freed together by [`Engine::drop_slab`].
    pub fn slab(&mut self, owner: InstanceKey) -> SlabId {
        self.core.new_slab(owner)
    }

    /// Free every cell of slab S and its edges. Its named states go to the state table (those that differ from their
    /// initial value); readers outside it that read its cells are marked, and show an error when pulled.
    pub fn drop_slab(&mut self, s: SlabId) {
        let idx = self.core.slab_idx(s);
        let cells = self.core.slab_cells(idx);
        self.states.keep(&self.core, &cells);
        let nodes = self.core.free_cells(&cells);
        {
            let mut slabs = self.core.slabs.borrow_mut();
            let info = &mut slabs.v[idx as usize];
            tracing::trace!(doc = %info.key.doc, cells = cells.len(), "slab dropped");
            info.live = false;
            info.head = crate::edge::NONE;
            info.round = info.round.wrapping_add(1);
            slabs.free.push(idx);
        }
        drop(nodes);
        self.after();
    }

    /// A state cell in slab S holding INIT.
    pub fn state<T: Value>(&mut self, s: SlabId, init: T) -> State<T> {
        let slab = self.core.slab_idx(s);
        State::new(
            self.core
                .alloc(slab, Box::new(StateNode(init)), 0, Stage::State as u8),
        )
    }

    /// A durable state (theme, fonts, settings, scale): cells reading only durable states are never revalidated by
    /// other writes.
    pub fn durable<T: Value>(&mut self, s: SlabId, init: T) -> State<T> {
        let slab = self.core.slab_idx(s);
        State::new(
            self.core
                .alloc(slab, Box::new(StateNode(init)), DURABLE, Stage::State as u8),
        )
    }

    /// A formula cell in slab S: F runs when the cell is pulled and a source changed, never before.
    pub fn formula<T: Value>(
        &mut self,
        s: SlabId,
        stage: Stage,
        f: impl Fn(&Rd) -> T + 'static,
    ) -> Formula<T> {
        let slab = self.core.slab_idx(s);
        let node = FormulaNode { value: None, f };
        Formula::new(
            self.core
                .alloc(slab, Box::new(node), FORMULA | DIRTY, stage as u8),
        )
    }

    /// A write transaction: F's writes are compared with the old values, and the changed ones marked in one pass when
    /// it ends (one frame requested however many there were).
    pub fn write<R>(&mut self, _origin: Origin, f: impl FnOnce(&mut Wr) -> R) -> R {
        let out = {
            let mut w = Wr { e: self };
            f(&mut w)
        };
        self.core.commit();
        self.after();
        out
    }

    /// Formula C's value, brought up to date. A formula with no good run panics with its error ([`Engine::try_pull`]).
    pub fn pull<T: Value>(&mut self, c: Formula<T>) -> T {
        self.try_pull(c)
            .unwrap_or_else(|err| panic!("tafl: {}", err.message))
    }

    /// Formula C's value, brought up to date, or its error when it never ran well.
    pub fn try_pull<T: Value>(&mut self, c: Formula<T>) -> Result<T, FormulaError> {
        let e: &Engine = self;
        let v = e.core.value_of::<T>(e, c.id());
        self.after();
        v
    }

    /// State S's value.
    pub fn peek<T: Value>(&self, s: State<T>) -> T {
        self.core
            .value_of::<T>(self, s.id())
            .unwrap_or_else(|err| panic!("tafl: {}", err.message))
    }

    /// The error of C's last run, if it panicked.
    pub fn error(&self, c: CellId) -> Option<FormulaError> {
        self.core
            .errors
            .borrow()
            .get(&c.idx)
            .filter(|e| e.cell == c)
            .cloned()
    }

    /// Time formulas' runs: `work_ns` and `bookkeeping_ns` in [`Stats`] (off by default: it reads the clock per run).
    pub fn set_timing(&mut self, on: bool) {
        self.core.timing.set(on);
    }

    pub fn stats(&self) -> Stats {
        let core = &self.core;
        let n = &core.n;
        let g = core.g.borrow();
        let cols = g.node.capacity()
            * (std::mem::size_of::<Option<Box<dyn crate::slab::Node>>>() + 4 * 4 + 2);
        let edges = g.src.capacity() * 8
            + g.dep.capacity() * 12
            + g.src.spill_bytes()
            + g.dep.spill_bytes();
        let nodes: usize = g.node.iter().flatten().map(|n| n.bytes()).sum();
        let masks = g.masks.capacity() * 24;
        let lists: usize = core
            .lists
            .borrow()
            .iter()
            .map(|l| l.items.capacity() * 8 + l.log.len() * 48)
            .sum();
        Stats {
            cells: g.live,
            edges: g.edges,
            bytes: (cols + edges + nodes + masks + lists) as u64,
            runs: n.runs.get(),
            marks: n.marks.get(),
            mark_passes: n.mark_passes.get(),
            verifies: n.verifies.get(),
            frame_requests: n.frame_requests.get(),
            resets: n.resets.get(),
            item_visits: n.item_visits.get(),
            timers: u64::from(self.timer.is_some()),
            ticks: n.ticks.get(),
            jobs: core.jobs.borrow().len() as u64,
            bookkeeping_ns: n.bookkeeping_ns.get(),
            work_ns: n.work_ns.get(),
        }
    }

    /// A new, empty model collection of T.
    pub fn list<T: Model>(&mut self) -> List<T> {
        let core = &self.core;
        let aux = u32::try_from(core.lists.borrow().len())
            .unwrap_or_else(|_| panic!("tafl: too many lists"));
        let cell = core.alloc(
            core.model_slab.get(),
            Box::new(ListCellNode),
            0,
            Stage::State as u8,
        );
        core.lists.borrow_mut().push(ListData::new());
        List::new(ModelRef { cell, aux })
    }

    /// Request a frame: false when one is requested already (writes coalesce into one frame).
    pub fn request_frame(&self) -> bool {
        self.core.request_frame()
    }

    /// The waker of the UI loop: woken when a frame is requested, a clock ticks or a job lands.
    pub fn set_waker(&mut self, w: std::task::Waker) {
        *saman::lock(&self.core.shared.waker) = Some(w);
    }

    /// Wait for every job on the pool and land its result (tests and tools; never on the UI thread).
    pub fn settle_blocking(&mut self) {
        crate::ops::pool::settle(self);
        self.after();
    }

    /// What every entry point does last: the clock's timer follows the clock cells' readers.
    pub(crate) fn after(&mut self) {
        if self.core.clock_touched.replace(false) {
            self.rearm();
        }
    }
}
