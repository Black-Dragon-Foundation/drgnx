//! Counting the orders of a partial order: dynamic programming over the vector of source positions.

use std::collections::HashMap;

use crate::Partial;

/// An event: (source, index in its source).
pub(crate) type At = (usize, usize);

/// The most position vectors [`Graph::weight`] keeps for a uniform draw.
const WEIGH_MAX_STATES: usize = 1_000_000;

/// A partial order's shape, checked to be acyclic.
pub(crate) struct Graph {
    names: Vec<&'static str>,
    lens: Vec<usize>,
    /// `preds[s][i]`: the events the edges put before event `i` of source `s`.
    preds: Vec<Vec<Vec<At>>>,
}

impl Graph {
    pub(crate) fn new<E>(p: &Partial<E>) -> Result<Self, String> {
        let names = p.sources.iter().map(|s| s.name).collect();
        let lens: Vec<usize> = p.sources.iter().map(|s| s.events.len()).collect();
        let mut preds: Vec<Vec<Vec<At>>> = lens.iter().map(|&n| vec![Vec::new(); n]).collect();
        for &(a, b) in &p.edges {
            preds[b.0][b.1].push(a);
        }
        let g = Self { names, lens, preds };
        g.acyclic()?;
        Ok(g)
    }

    pub(crate) fn sources(&self) -> usize {
        self.lens.len()
    }

    pub(crate) fn total(&self) -> usize {
        self.lens.iter().sum()
    }

    pub(crate) fn done(&self, pos: &[usize]) -> bool {
        pos.iter().zip(&self.lens).all(|(p, n)| p == n)
    }

    /// The sources whose next event may run, lowest first: the natural scheduler takes the first.
    pub(crate) fn enabled(&self, pos: &[usize]) -> Vec<usize> {
        (0..self.lens.len())
            .filter(|&s| {
                pos[s] < self.lens[s] && self.preds[s][pos[s]].iter().all(|&(a, i)| pos[a] > i)
            })
            .collect()
    }

    /// Kahn's algorithm over every event, with each source's chain and the declared edges.
    fn acyclic(&self) -> Result<(), String> {
        let mut base = Vec::with_capacity(self.lens.len());
        let mut total = 0;
        for &n in &self.lens {
            base.push(total);
            total += n;
        }
        let mut indegree = vec![0usize; total];
        let mut after: Vec<Vec<usize>> = vec![Vec::new(); total];
        for (s, events) in self.preds.iter().enumerate() {
            for (i, preds) in events.iter().enumerate() {
                let node = base[s] + i;
                if i > 0 {
                    after[node - 1].push(node);
                    indegree[node] += 1;
                }
                for &(a, j) in preds {
                    after[base[a] + j].push(node);
                    indegree[node] += 1;
                }
            }
        }
        let mut ready: Vec<usize> = (0..total).filter(|&n| indegree[n] == 0).collect();
        let mut ran = 0;
        while let Some(n) = ready.pop() {
            ran += 1;
            for &m in &after[n] {
                indegree[m] -= 1;
                if indegree[m] == 0 {
                    ready.push(m);
                }
            }
        }
        if ran == total {
            return Ok(());
        }
        let stuck: Vec<String> = self
            .lens
            .iter()
            .enumerate()
            .flat_map(|(s, &n)| (0..n).map(move |i| (s, i)))
            .filter(|&(s, i)| indegree[base[s] + i] > 0)
            .map(|(s, i)| format!("{}[{i}]", self.names[s]))
            .collect();
        let more = if stuck.len() > 8 {
            format!(" and {} more", stuck.len() - 8)
        } else {
            String::new()
        };
        Err(format!(
            "the edges form a cycle: {}{more} can never run",
            stuck.iter().take(8).cloned().collect::<Vec<_>>().join(", ")
        ))
    }

    /// The orders from the start, at most `cap`; with a `budget`, only those within that many delays.
    pub(crate) fn count(&self, budget: Option<u32>, cap: u64) -> u64 {
        let mut memo = HashMap::new();
        self.count_from(&mut vec![0; self.sources()], budget, cap, &mut memo)
    }

    fn count_from(
        &self,
        pos: &mut [usize],
        budget: Option<u32>,
        cap: u64,
        memo: &mut HashMap<(Vec<usize>, Option<u32>), u64>,
    ) -> u64 {
        if self.done(pos) {
            return cap.min(1);
        }
        let key = (pos.to_vec(), budget);
        if let Some(&n) = memo.get(&key) {
            return n;
        }
        let mut sum = 0u64;
        for (rank, s) in self.enabled(pos).into_iter().enumerate() {
            let rest = match budget {
                None => None,
                Some(b) => match u32::try_from(rank).ok().and_then(|r| b.checked_sub(r)) {
                    Some(r) => Some(r),
                    None => break,
                },
            };
            pos[s] += 1;
            sum = sum
                .saturating_add(self.count_from(pos, rest, cap, memo))
                .min(cap);
            pos[s] -= 1;
            if sum >= cap {
                break;
            }
        }
        memo.insert(key, sum);
        sum
    }

    /// The number of orders from `pos`, as a float (for a uniform draw); `Err` when there are too many to weigh.
    pub(crate) fn weight(
        &self,
        pos: &mut [usize],
        memo: &mut HashMap<Vec<usize>, f64>,
    ) -> Result<f64, String> {
        if self.done(pos) {
            return Ok(1.0);
        }
        if let Some(&w) = memo.get(&*pos) {
            return Ok(w);
        }
        let mut sum = 0.0;
        for s in self.enabled(pos) {
            pos[s] += 1;
            sum += self.weight(pos, memo)?;
            pos[s] -= 1;
        }
        if memo.len() >= WEIGH_MAX_STATES || !sum.is_finite() {
            return Err(format!(
                "too many orders to draw uniformly (more than {WEIGH_MAX_STATES} position vectors, or more orders \
                 than a float holds); split the sources"
            ));
        }
        memo.insert(pos.to_vec(), sum);
        Ok(sum)
    }
}

/// The number of orders consistent with `p`, exactly up to `cap` (`cap` itself when there are more). `Err` when the
/// edges form a cycle.
pub fn count<E>(p: &Partial<E>, cap: u64) -> Result<u64, String> {
    Ok(Graph::new(p)?.count(None, cap))
}
