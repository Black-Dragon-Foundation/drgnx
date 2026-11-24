//! Edges: N inline per cell and direction (two sources, three dependents: most cells read one or two sources and have
//! one to three readers, so most never allocate for their edges), the rest in a slot of a dense side arena.

/// No cell.
pub(crate) const NONE: u32 = u32::MAX;
/// The first inline slot of a cell whose edges are in the arena (the second holds the arena slot).
const SPILLED: u32 = u32::MAX - 1;

/// One direction of the graph's edges (sources, or dependents), for every cell.
pub(crate) struct EdgeTable<const N: usize> {
    inline: Vec<[u32; N]>,
    slots: Vec<Vec<u32>>,
    free_slots: Vec<u32>,
}

impl<const N: usize> Default for EdgeTable<N> {
    fn default() -> Self {
        EdgeTable {
            inline: Vec::new(),
            slots: Vec::new(),
            free_slots: Vec::new(),
        }
    }
}

impl<const N: usize> EdgeTable<N> {
    /// Room for one more cell (its edges empty), the column growing by RESERVE rows when full.
    pub(crate) fn grow_to(&mut self, len: usize, reserve: usize) {
        if self.inline.len() == self.inline.capacity() {
            self.inline.reserve_exact(reserve);
        }
        while self.inline.len() < len {
            self.inline.push([NONE; N]);
        }
    }

    pub(crate) fn capacity(&self) -> usize {
        self.inline.capacity()
    }

    /// Cell I's edges, in order.
    pub(crate) fn of(&self, i: u32) -> &[u32] {
        let p = &self.inline[i as usize];
        if p[0] == SPILLED {
            &self.slots[p[1] as usize]
        } else {
            let n = p.iter().position(|&x| x == NONE).unwrap_or(N);
            &p[..n]
        }
    }

    pub(crate) fn len(&self, i: u32) -> usize {
        self.of(i).len()
    }

    pub(crate) fn get(&self, i: u32, k: usize) -> u32 {
        self.of(i)[k]
    }

    pub(crate) fn contains(&self, i: u32, x: u32) -> bool {
        self.of(i).contains(&x)
    }

    pub(crate) fn copy_into(&self, i: u32, out: &mut Vec<u32>) {
        out.clear();
        out.extend_from_slice(self.of(i));
    }

    pub(crate) fn push(&mut self, i: u32, x: u32) {
        let p = &mut self.inline[i as usize];
        if p[0] == SPILLED {
            self.slots[p[1] as usize].push(x);
            return;
        }
        if let Some(free) = p.iter().position(|&y| y == NONE) {
            p[free] = x;
            return;
        }
        let mut v = Vec::with_capacity(N * 2);
        v.extend_from_slice(p);
        v.push(x);
        let slot = match self.free_slots.pop() {
            Some(s) => {
                self.slots[s as usize] = v;
                s
            }
            None => {
                self.slots.push(v);
                u32::try_from(self.slots.len() - 1)
                    .unwrap_or_else(|_| panic!("tafl: too many spilled cells"))
            }
        };
        let mut q = [NONE; N];
        q[0] = SPILLED;
        q[1] = slot;
        *p = q;
    }

    /// Edges back inline once they fit again (the slot's memory goes back to the arena's free list).
    fn unspill(&mut self, i: u32) {
        let p = &mut self.inline[i as usize];
        if p[0] != SPILLED {
            return;
        }
        let slot = p[1] as usize;
        if self.slots[slot].len() > N {
            return;
        }
        let v = std::mem::take(&mut self.slots[slot]);
        let mut q = [NONE; N];
        q[..v.len()].copy_from_slice(&v);
        *p = q;
        self.free_slots.push(slot as u32);
    }

    /// Remove X, keeping the order of the rest (a formula's sources are compared in order on its next run).
    pub(crate) fn remove(&mut self, i: u32, x: u32) -> bool {
        let p = &mut self.inline[i as usize];
        if p[0] == SPILLED {
            let v = &mut self.slots[p[1] as usize];
            let Some(at) = v.iter().position(|&y| y == x) else {
                return false;
            };
            v.remove(at);
            self.unspill(i);
            return true;
        }
        let Some(at) = p.iter().position(|&y| y == x) else {
            return false;
        };
        p.copy_within(at + 1.., at);
        p[N - 1] = NONE;
        true
    }

    /// Remove X where the order does not matter (an operator's item edges, a cell's readers).
    pub(crate) fn remove_unordered(&mut self, i: u32, x: u32) -> bool {
        let p = &mut self.inline[i as usize];
        if p[0] == SPILLED {
            let v = &mut self.slots[p[1] as usize];
            let Some(at) = v.iter().position(|&y| y == x) else {
                return false;
            };
            v.swap_remove(at);
            self.unspill(i);
            return true;
        }
        self.remove(i, x)
    }

    /// Keep the first N edges of cell I.
    pub(crate) fn truncate(&mut self, i: u32, n: usize) {
        let p = &mut self.inline[i as usize];
        if p[0] == SPILLED {
            self.slots[p[1] as usize].truncate(n);
            self.unspill(i);
        } else {
            for slot in p.iter_mut().skip(n) {
                *slot = NONE;
            }
        }
    }

    /// Replace cell I's edges with those of KEEP (a slice of other memory).
    pub(crate) fn set(&mut self, i: u32, keep: &[u32]) {
        self.clear(i);
        for &x in keep {
            self.push(i, x);
        }
    }

    pub(crate) fn clear(&mut self, i: u32) {
        self.truncate(i, 0);
    }

    /// Bytes held in the arena (its vectors' heaps and headers).
    pub(crate) fn spill_bytes(&self) -> usize {
        self.slots.capacity() * std::mem::size_of::<Vec<u32>>()
            + self.slots.iter().map(|v| v.capacity() * 4).sum::<usize>()
    }
}
