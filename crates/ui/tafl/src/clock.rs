//! Clock cells: time is a cell, one per grain, holding the time aligned down to its grain. A clock has a timer only
//! while something reads it, and every clock shares one: the engine's, armed for the nearest aligned deadline among the
//! clocks that have readers.

use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Waker};
use std::time::Duration;

use crate::cell::{Formula, Stage};
use crate::engine::Engine;
use crate::propagate::{CLOCK, Core, add};
use crate::slab::StateNode;

/// The armed timer: its deadline and the provider's sleep, polled with the engine's waker.
pub(crate) struct Timer {
    deadline: Duration,
    _sleep: Pin<Box<dyn Future<Output = ()> + Send>>,
}

/// NOW aligned down to GRAIN.
fn aligned(now: Duration, grain: Duration) -> Duration {
    let g = grain.as_nanos().max(1);
    let n = now.as_nanos();
    Duration::from_nanos(u64::try_from(n - n % g).unwrap_or(u64::MAX))
}

impl Core {
    /// Bring clock cell I to the current time without marking anything (it has no readers yet).
    pub(crate) fn refresh_clock(&self, i: u32) {
        let Some(grain) = self.clocks.borrow().iter().find(|c| c.0 == i).map(|c| c.1) else {
            return;
        };
        let v = aligned(self.clock.now(), grain);
        let mut g = self.g.borrow_mut();
        if let Some(slot) = g.node[i as usize]
            .as_mut()
            .and_then(|n| n.value_mut())
            .and_then(|v| v.downcast_mut::<Duration>())
        {
            *slot = v;
        }
    }
}

impl Engine {
    /// The clock of GRAIN: the time since the clock's epoch, aligned down to GRAIN. Clocks of one grain are one cell.
    pub fn clock(&mut self, grain: Duration) -> Formula<Duration> {
        let found = self
            .core
            .clocks
            .borrow()
            .iter()
            .find(|c| c.1 == grain)
            .map(|c| c.0);
        if let Some(i) = found {
            return Formula::new(self.core.id(i));
        }
        let v = aligned(self.core.clock.now(), grain);
        let core = &self.core;
        let cell = core.alloc(
            core.model_slab.get(),
            Box::new(StateNode(v)),
            CLOCK,
            Stage::State as u8,
        );
        core.clocks.borrow_mut().push((cell.idx, grain));
        Formula::new(cell)
    }

    /// Arm the one timer for the nearest aligned deadline among the clocks with readers; none when no clock has one.
    pub(crate) fn rearm(&mut self) {
        let now = self.core.clock.now();
        let next = {
            let g = self.core.g.borrow();
            self.core
                .clocks
                .borrow()
                .iter()
                .filter(|(c, _)| g.dep.len(*c) > 0)
                .map(|(_, grain)| aligned(now, *grain) + *grain)
                .min()
        };
        let Some(deadline) = next else {
            self.timer = None;
            return;
        };
        if self.timer.as_ref().is_some_and(|t| t.deadline == deadline) {
            return;
        }
        // the old sleep goes first, so the provider never holds two
        self.timer = None;
        let mut sleep = self.core.clock.sleep(deadline.saturating_sub(now));
        let waker = Waker::from(self.core.shared.clone());
        // the first poll registers the sleep; a sleep already due is seen by the next frame's tick
        let _ready = sleep
            .as_mut()
            .poll(&mut Context::from_waker(&waker))
            .is_ready();
        self.timer = Some(Timer {
            deadline,
            _sleep: sleep,
        });
    }

    /// The timer's deadline passed: every clock with readers takes the new time (one tick, one marking pass).
    pub(crate) fn tick(&mut self) {
        let now = self.core.clock.now();
        if !self.timer.as_ref().is_some_and(|t| now >= t.deadline) {
            return;
        }
        self.timer = None;
        let clocks: Vec<(u32, Duration)> = self.core.clocks.borrow().clone();
        for (c, grain) in clocks {
            let id = self.core.id(c);
            self.core.set(id, aligned(now, grain));
        }
        self.core.commit();
        add(&self.core.n.ticks, 1);
        self.rearm();
    }
}
