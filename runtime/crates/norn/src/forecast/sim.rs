//! A plan's simulation and calibration (docs/develop/hub.md, "Forecasts"): whole observations resampled over the
//! plan's dependencies, and p90 scaled by past misses. Pure: the seed is the only source of chance.

use std::cmp::Reverse;
use std::collections::{BTreeMap, BinaryHeap};

use super::model::{Class, Obs, Want};

/// How many draws a forecast takes.
pub const DRAWS: usize = 2000;

/// A class smaller than this says too little about its own spread: see [`widen`].
const WIDE_BELOW: u32 = 20;

/// The narrowest p90 of a small class, as a multiple of p50.
const WIDE_P90: f64 = 1.5;

/// Below this many pairs the 90 % rank of [`conformal`] is past the last ratio.
const MIN_PAIRS: usize = 9;

/// A task's index and an observation give a unit and an amount, or nothing.
pub type Price<'a> = &'a dyn Fn(usize, &Obs) -> Option<(String, f64)>;

/// A forecast's middle and its high end.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Range {
    pub p50: f64,
    pub p90: f64,
}

/// One task's ranges. `cost` is by unit, and has no entry for a unit the task was never priced in.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskTotals {
    pub tokens: Range,
    pub active: Range,
    pub cost: BTreeMap<String, Range>,
}

/// A plan's ranges. Each is the plan's own distribution, not a sum of its tasks' ranges: p90s do not add up.
#[derive(Debug, Clone, PartialEq)]
pub struct Totals {
    pub per_task: Vec<TaskTotals>,
    pub tokens: Range,
    pub active: Range,
    pub wall: Range,
    pub cost: BTreeMap<String, Range>,
    pub cold_wakes: Range,
}

/// SplitMix64 (Steele, Lea, Flood 2014, as Vigna's reference code). Own, so a test's numbers do not move with a
/// library's stream.
struct SplitMix64(u64);

impl SplitMix64 {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let z = self.0;
        let z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        let z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// A seed from `parts`, stable across builds and releases: FNV-1a over the bytes, with a byte UTF-8 never holds
/// between parts, so `["ab", "c"]` and `["a", "bc"]` differ.
pub fn seed_of(parts: &[&str]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    let mut eat = |byte: u8| hash = (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3);
    for (i, part) in parts.iter().enumerate() {
        if i > 0 {
            eat(0xff);
        }
        part.bytes().for_each(&mut eat);
    }
    hash
}

/// Items by cumulative weight.
struct Table<T> {
    items: Vec<T>,
    cumulative: Vec<f64>,
}

impl<T> Table<T> {
    fn new(weighted: impl Iterator<Item = (T, f64)>) -> Self {
        let (mut items, mut cumulative, mut sum) = (Vec::new(), Vec::new(), 0.0);
        for (item, weight) in weighted {
            sum += weight;
            items.push(item);
            cumulative.push(sum);
        }
        Table { items, cumulative }
    }

    /// The item at `u` of the total weight, `u` in [0, 1); none in an empty table. Past the end only by rounding.
    fn at(&self, u: f64) -> Option<&T> {
        let x = u * self.cumulative.last()?;
        let i = self.cumulative.partition_point(|c| *c <= x);
        self.items.get(i.min(self.items.len() - 1))
    }
}

/// What one task can draw. `priced` is the same picks with those that have a price: one draw reads both tables at
/// the same point, so with every pick priced the cost is the drawn observation's own.
struct Picks<'a> {
    obs: Table<&'a Obs>,
    priced: Table<(String, f64)>,
}

/// One draw of the plan.
struct Drawn<'p> {
    tokens: Vec<f64>,
    active: Vec<f64>,
    cost: Vec<Option<(&'p str, f64)>>,
    cold_wakes: f64,
    wall: f64,
}

struct Plan<'a> {
    wants: &'a [Want],
    tasks: Vec<Picks<'a>>,
    /// How many parents each task waits for. A dep on a task outside the plan is not waited for.
    waits: Vec<usize>,
    children: Vec<Vec<usize>>,
    slots: usize,
}

impl<'a> Plan<'a> {
    fn new(
        wants: &'a [Want],
        classes: &[Class],
        obs: &'a [Obs],
        price: Price<'_>,
        slots: usize,
    ) -> Self {
        let index: BTreeMap<i64, usize> = wants.iter().enumerate().map(|(i, w)| (w.n, i)).collect();
        let mut waits = vec![0; wants.len()];
        let mut children = vec![Vec::new(); wants.len()];
        for (i, want) in wants.iter().enumerate() {
            for parent in want.deps.iter().filter_map(|d| index.get(d)) {
                waits[i] += 1;
                children[*parent].push(i);
            }
        }
        let tasks = classes
            .iter()
            .enumerate()
            .map(|(i, class)| Picks {
                obs: Table::new(class.picks.iter().map(|&(j, w)| (&obs[j], w))),
                priced: Table::new(
                    class
                        .picks
                        .iter()
                        .filter_map(|&(j, w)| Some((price(i, &obs[j])?, w))),
                ),
            })
            .collect();
        Plan {
            wants,
            tasks,
            waits,
            children,
            slots,
        }
    }

    fn draw(&self, rng: &mut SplitMix64) -> Drawn<'_> {
        let n = self.tasks.len();
        let mut drawn = Drawn {
            tokens: vec![0.0; n],
            active: vec![0.0; n],
            cost: vec![None; n],
            cold_wakes: 0.0,
            wall: 0.0,
        };
        let mut secs = vec![0.0; n];
        for (i, task) in self.tasks.iter().enumerate() {
            let u = rng.unit();
            if let Some(o) = task.obs.at(u) {
                drawn.tokens[i] = o.usage.total() as f64;
                drawn.active[i] = o.active_secs;
                drawn.cold_wakes += f64::from(o.cold_wakes);
                secs[i] = o.wall_secs;
            }
            drawn.cost[i] = task.priced.at(u).map(|(unit, usd)| (unit.as_str(), *usd));
        }
        drawn.wall = self.wall_time(&secs);
        drawn
    }

    /// When the last task ends, as the runner would run them: whenever a slot is free it takes the ready task with
    /// the lowest `n`, so a task that waits for its parents leaves its slot to one that can start.
    fn wall_time(&self, secs: &[f64]) -> f64 {
        let mut waits = self.waits.clone();
        let mut ready: BinaryHeap<_> = (0..waits.len())
            .filter(|i| waits[*i] == 0)
            .map(|i| Reverse((self.wants[i].n, i)))
            .collect();
        let mut running: Vec<(f64, usize)> = Vec::with_capacity(self.slots);
        let mut now = 0.0;
        loop {
            while running.len() < self.slots {
                let Some(Reverse((_, i))) = ready.pop() else {
                    break;
                };
                running.push((now + secs[i], i));
            }
            let Some(next) = running.iter().map(|r| r.0).min_by(f64::total_cmp) else {
                return now;
            };
            now = next;
            running.retain(|&(end, i)| {
                if end > now {
                    return true;
                }
                for &child in &self.children[i] {
                    waits[child] -= 1;
                    if waits[child] == 0 {
                        ready.push(Reverse((self.wants[child].n, child)));
                    }
                }
                false
            });
        }
    }
}

/// One value per draw.
#[derive(Debug, Clone, Default)]
struct Series {
    tokens: Vec<f64>,
    active: Vec<f64>,
    cost: BTreeMap<String, Vec<f64>>,
}

impl Series {
    fn push_cost(&mut self, unit: &str, amount: f64) {
        self.cost.entry(unit.to_owned()).or_default().push(amount);
    }

    fn cost_ranges(self) -> BTreeMap<String, Range> {
        self.cost
            .into_iter()
            .map(|(unit, amounts)| (unit, range(amounts)))
            .collect()
    }
}

fn range(mut values: Vec<f64>) -> Range {
    values.sort_by(f64::total_cmp);
    Range {
        p50: quantile(&values, 0.5),
        p90: quantile(&values, 0.9),
    }
}

/// Simulates the plan `draws` times. Each draw takes one whole observation per task, weighted by its class, so one
/// run's tokens, time and cost stay together, and runs the tasks over their dependencies on `slots` slots.
///
/// `classes[i]` belongs to `wants[i]`, and `obs` is the history followed by the prior, as [`Class::picks`] counts.
/// `price` answers a task's unit and amount for an observation, or `None`. It is called once per pick, not per draw.
/// A pick without a price is never a zero: the task's cost comes from its priced picks alone, and a task with none
/// is in no unit. Units are never summed.
///
/// The same seed and a `price` of a wake's cost give the same draws, so a plan's wake cost comes from a second run.
/// Nothing here widens or calibrates: that is [`widen`] and [`conformal`], on the plan's totals too.
pub fn simulate(
    wants: &[Want],
    classes: &[Class],
    obs: &[Obs],
    price: Price<'_>,
    slots: usize,
    seed: u64,
    draws: usize,
) -> Totals {
    let plan = Plan::new(wants, classes, obs, price, slots);
    let mut rng = SplitMix64(seed);
    let mut per_task = vec![Series::default(); wants.len()];
    let mut total = Series::default();
    let (mut wall, mut cold_wakes) = (Vec::with_capacity(draws), Vec::with_capacity(draws));
    for _ in 0..draws {
        let drawn = plan.draw(&mut rng);
        let mut cost: BTreeMap<&str, f64> = BTreeMap::new();
        for (i, series) in per_task.iter_mut().enumerate() {
            series.tokens.push(drawn.tokens[i]);
            series.active.push(drawn.active[i]);
            if let Some((unit, amount)) = drawn.cost[i] {
                series.push_cost(unit, amount);
                *cost.entry(unit).or_default() += amount;
            }
        }
        total.tokens.push(drawn.tokens.iter().sum());
        total.active.push(drawn.active.iter().sum());
        for (unit, amount) in cost {
            total.push_cost(unit, amount);
        }
        wall.push(drawn.wall);
        cold_wakes.push(drawn.cold_wakes);
    }
    Totals {
        per_task: per_task
            .into_iter()
            .map(|mut s| TaskTotals {
                tokens: range(std::mem::take(&mut s.tokens)),
                active: range(std::mem::take(&mut s.active)),
                cost: s.cost_ranges(),
            })
            .collect(),
        tokens: range(std::mem::take(&mut total.tokens)),
        active: range(std::mem::take(&mut total.active)),
        wall: range(wall),
        cost: total.cost_ranges(),
        cold_wakes: range(cold_wakes),
    }
}

/// The nearest-rank quantile of sorted values: the value at rank ⌈q·n⌉, 1-based. 0 with no values.
pub fn quantile(sorted: &[f64], q: f64) -> f64 {
    let rank = (q * sorted.len() as f64).ceil() as usize;
    sorted.get(rank.saturating_sub(1)).copied().unwrap_or(0.0)
}

/// The small-class floor: below 20 observations a p90 is at least 1.5 × p50, however tight the draws came out. `n`
/// is the class's size; for a plan's total, the smallest class in it.
pub fn widen(r: Range, n: u32) -> Range {
    if n >= WIDE_BELOW {
        return r;
    }
    Range {
        p50: r.p50,
        p90: r.p90.max(r.p50 * WIDE_P90),
    }
}

/// Split conformal scaling: `p90 × factor` covers the next run at least 9 times in 10, if past and future runs are
/// exchangeable, which is why callers key pairs by role, profile and model and keep a recent window.
///
/// `pairs` are (p90, actual). The factor is the actual/p90 ratio at rank ⌈(n+1)·0.9⌉, 1-based; below 9 pairs that
/// rank does not exist, and the answer is `None`. A p90 of zero says nothing, so its pair does not count.
///
/// Each p90 must be the forecast as it stood before calibration. Measured against a calibrated p90 the ratios tell
/// only how the last factor did, and the factor would swing. It can be below 1, and a p90 scaled by it can fall
/// below its p50, which the caller holds at p50.
pub fn conformal(pairs: &[(f64, f64)]) -> Option<f64> {
    let mut ratios: Vec<f64> = pairs
        .iter()
        .filter(|(p90, _)| *p90 > 0.0)
        .map(|(p90, actual)| actual / p90)
        .collect();
    let n = ratios.len();
    if n < MIN_PAIRS {
        return None;
    }
    ratios.sort_by(f64::total_cmp);
    Some(ratios[((n + 1) * 9).div_ceil(10) - 1])
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::super::model::{Level, Usage, prior, reference_class};
    use super::*;

    fn task(n: i64, deps: &[i64]) -> Want {
        Want {
            n,
            role: "implement".to_owned(),
            profile: "sonnet".to_owned(),
            model: None,
            project: None,
            brief_bytes: 4096,
            deps: deps.to_vec(),
        }
    }

    fn ob(tokens: u64, secs: f64) -> Obs {
        Obs {
            role: "implement".to_owned(),
            profile: Some("sonnet".to_owned()),
            model: None,
            project: None,
            brief_bytes: 4096,
            usage: Usage {
                cache_read: tokens,
                ..Usage::default()
            },
            active_secs: secs,
            wall_secs: secs,
            wakes: 0,
            cold_wakes: 0,
            context: None,
            cost: None,
        }
    }

    fn class(picks: &[(usize, f64)]) -> Class {
        Class {
            level: Level::Project,
            n: picks.len() as u32,
            other_model: false,
            picks: picks.to_vec(),
        }
    }

    /// `tasks` tasks, each able to draw any of `obs`, equally.
    fn classes(tasks: usize, obs: &[Obs]) -> Vec<Class> {
        let picks: Vec<(usize, f64)> = (0..obs.len()).map(|i| (i, 1.0)).collect();
        vec![class(&picks); tasks]
    }

    fn unpriced(_: usize, _: &Obs) -> Option<(String, f64)> {
        None
    }

    fn sim(wants: &[Want], obs: &[Obs], slots: usize) -> Totals {
        let classes = classes(wants.len(), obs);
        simulate(wants, &classes, obs, &unpriced, slots, 7, DRAWS)
    }

    fn near(got: f64, expected: f64) {
        assert!((got - expected).abs() < 1e-9, "{got} is not {expected}");
    }

    #[test]
    fn splitmix_gives_the_published_stream() {
        let mut rng = SplitMix64(1_234_567);
        let stream: Vec<u64> = (0..5).map(|_| rng.next_u64()).collect();
        assert_eq!(
            stream,
            [
                6_457_827_717_110_365_317,
                3_203_168_211_198_807_973,
                9_817_491_932_198_370_423,
                4_593_380_528_125_082_431,
                16_408_922_859_458_223_821,
            ]
        );
    }

    #[test]
    fn a_unit_draw_is_in_the_half_open_interval() {
        let mut rng = SplitMix64(u64::MAX - 0x9e37_79b9_7f4a_7c15);
        for _ in 0..1000 {
            assert!((0.0..1.0).contains(&rng.unit()));
        }
    }

    #[test]
    fn the_seed_is_fnv1a() {
        assert_eq!(seed_of(&[""]), 0xcbf2_9ce4_8422_2325);
        assert_eq!(seed_of(&["a"]), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(seed_of(&["foobar"]), 0x8594_4171_f739_67e8);
    }

    #[test]
    fn a_seed_keeps_its_parts_apart() {
        assert_ne!(seed_of(&["ab", "c"]), seed_of(&["a", "bc"]));
    }

    #[test]
    fn the_same_seed_gives_the_same_numbers() {
        // many values, or two seeds land on the same quantiles
        let obs: Vec<Obs> = (1..=997).map(|i| ob(i * 100, i as f64)).collect();
        let wants = [task(1, &[]), task(2, &[1]), task(3, &[])];
        let classes = classes(3, &obs);
        let run = |seed| simulate(&wants, &classes, &obs, &unpriced, 2, seed, DRAWS);
        assert_eq!(run(5), run(5));
        assert_ne!(run(5), run(6));
    }

    #[test]
    fn one_task_reproduces_its_observations_quantiles() {
        // 15 values: F(8) = 0.53 and F(14) = 0.93, well clear of 0.5 and 0.9 for 2000 draws
        let obs: Vec<Obs> = (1..=15).map(|i| ob(i * 10, i as f64)).collect();
        let totals = sim(&[task(1, &[])], &obs, 3);
        assert_eq!(
            totals.per_task[0].tokens,
            Range {
                p50: 80.0,
                p90: 140.0
            }
        );
        assert_eq!(
            totals.tokens,
            Range {
                p50: 80.0,
                p90: 140.0
            }
        );
        assert_eq!(
            totals.wall,
            Range {
                p50: 8.0,
                p90: 14.0
            }
        );
    }

    #[test]
    fn the_draws_follow_the_weights() {
        let obs = [ob(10, 1.0), ob(20, 1.0)];
        let wants = [task(1, &[])];
        let run = |picks: &[(usize, f64)]| {
            simulate(&wants, &[class(picks)], &obs, &unpriced, 1, 3, DRAWS).tokens
        };
        assert_eq!(
            run(&[(0, 3.0), (1, 1.0)]),
            Range {
                p50: 10.0,
                p90: 20.0
            }
        );
        assert_eq!(
            run(&[(0, 1.0), (1, 3.0)]),
            Range {
                p50: 20.0,
                p90: 20.0
            }
        );
        assert_eq!(
            run(&[(0, 1.0), (1, 0.0)]),
            Range {
                p50: 10.0,
                p90: 10.0
            }
        );
    }

    #[test]
    fn serial_tasks_add_up_and_parallel_tasks_do_not() {
        let obs = [ob(1, 60.0)];
        let wall = |wants: &[Want]| sim(wants, &obs, 3).wall.p50;
        near(wall(&[task(1, &[]), task(2, &[1]), task(3, &[2])]), 180.0);
        near(wall(&[task(1, &[]), task(2, &[]), task(3, &[])]), 60.0);
        let six: Vec<Want> = (1..=6).map(|n| task(n, &[])).collect();
        near(wall(&six), 120.0);
    }

    #[test]
    fn parallel_wall_time_beats_the_longest_p50() {
        // P(max of three ≤ 20) = (2/3)³ = 0.30, so the plan's p50 is 30 while every task's is 20
        let obs = [ob(1, 10.0), ob(1, 20.0), ob(1, 30.0)];
        let totals = sim(&[task(1, &[]), task(2, &[]), task(3, &[])], &obs, 3);
        let longest = totals
            .per_task
            .iter()
            .map(|t| t.active.p50)
            .fold(0.0, f64::max);
        near(longest, 20.0);
        near(totals.wall.p50, 30.0);
    }

    #[test]
    fn four_ready_tasks_wait_for_a_slot() {
        let obs = [ob(1, 60.0)];
        let wants: Vec<Want> = (1..=4).map(|n| task(n, &[])).collect();
        near(sim(&wants, &obs, 3).wall.p90, 120.0);
        near(sim(&wants, &obs, 4).wall.p90, 60.0);
    }

    #[test]
    fn a_dependency_waits_for_its_slowest_parent() {
        let obs = [ob(1, 10.0), ob(1, 100.0), ob(1, 5.0)];
        let wants = [task(1, &[]), task(2, &[]), task(3, &[1, 2])];
        let classes = [class(&[(0, 1.0)]), class(&[(1, 1.0)]), class(&[(2, 1.0)])];
        let totals = simulate(&wants, &classes, &obs, &unpriced, 3, 1, 10);
        near(totals.wall.p50, 105.0);
    }

    #[test]
    fn a_task_waiting_for_a_parent_leaves_its_slot_to_a_ready_one() {
        // 2 waits for 1, so 3 starts beside 1 at once: 100 then 10, with 3 done long before
        let obs = [ob(1, 100.0), ob(1, 10.0), ob(1, 50.0)];
        let wants = [task(1, &[]), task(2, &[1]), task(3, &[])];
        let classes = [class(&[(0, 1.0)]), class(&[(1, 1.0)]), class(&[(2, 1.0)])];
        let totals = simulate(&wants, &classes, &obs, &unpriced, 2, 1, 10);
        near(totals.wall.p50, 110.0);
    }

    #[test]
    fn a_parent_may_have_a_higher_number() {
        let obs = [ob(1, 60.0)];
        near(sim(&[task(1, &[2]), task(2, &[])], &obs, 3).wall.p50, 120.0);
    }

    #[test]
    fn a_dep_outside_the_plan_is_not_waited_for() {
        let obs = [ob(1, 60.0)];
        near(sim(&[task(1, &[9])], &obs, 3).wall.p50, 60.0);
    }

    #[test]
    fn whole_observations_keep_tokens_and_time_together() {
        let obs = [ob(1, 10.0), ob(1000, 1000.0)];
        let wants = [task(1, &[])];
        let classes = classes(1, &obs);
        let plan = Plan::new(&wants, &classes, &obs, &unpriced, 1);
        let mut rng = SplitMix64(11);
        let seen: BTreeSet<(u64, u64)> = (0..DRAWS)
            .map(|_| plan.draw(&mut rng))
            .map(|d| (d.tokens[0] as u64, d.wall as u64))
            .collect();
        assert_eq!(seen, BTreeSet::from([(1, 10), (1000, 1000)]));
    }

    #[test]
    fn one_draw_prices_the_observation_it_drew() {
        let obs = [ob(1, 10.0), ob(1000, 1000.0)];
        let wants = [task(1, &[])];
        let classes = classes(1, &obs);
        let price = |_: usize, o: &Obs| Some(("usd".to_owned(), o.usage.total() as f64));
        let plan = Plan::new(&wants, &classes, &obs, &price, 1);
        let mut rng = SplitMix64(11);
        for _ in 0..DRAWS {
            let d = plan.draw(&mut rng);
            assert_eq!(d.cost[0], Some(("usd", d.tokens[0])));
        }
    }

    #[test]
    fn mixed_units_stay_apart() {
        let obs = [ob(1, 1.0)];
        let wants = [task(1, &[]), task(2, &[])];
        let classes = classes(2, &obs);
        let price = |i: usize, _: &Obs| {
            Some(if i == 0 {
                ("usd".to_owned(), 2.0)
            } else {
                ("usd-est".to_owned(), 3.0)
            })
        };
        let totals = simulate(&wants, &classes, &obs, &price, 3, 1, DRAWS);
        assert_eq!(totals.cost.len(), 2);
        assert_eq!(totals.cost["usd"], Range { p50: 2.0, p90: 2.0 });
        assert_eq!(totals.cost["usd-est"], Range { p50: 3.0, p90: 3.0 });
    }

    #[test]
    fn an_unpriced_task_leaves_no_unit_behind() {
        let obs = [ob(1, 1.0)];
        let wants = [task(1, &[]), task(2, &[])];
        let classes = classes(2, &obs);
        let price = |i: usize, _: &Obs| (i == 0).then(|| ("usd".to_owned(), 2.0));
        let totals = simulate(&wants, &classes, &obs, &price, 3, 1, DRAWS);
        assert_eq!(totals.cost["usd"], Range { p50: 2.0, p90: 2.0 });
        assert!(totals.per_task[1].cost.is_empty());
        assert!(sim(&wants, &obs, 3).cost.is_empty());
    }

    #[test]
    fn a_pick_with_no_price_is_not_a_zero() {
        // half the picks have a price: without care the total would be 0, 5 or 10
        let obs = [ob(1, 1.0), ob(2, 1.0)];
        let wants = [task(1, &[]), task(2, &[])];
        let classes = classes(2, &obs);
        let price = |_: usize, o: &Obs| (o.usage.total() == 1).then(|| ("usd".to_owned(), 5.0));
        let totals = simulate(&wants, &classes, &obs, &price, 3, 1, DRAWS);
        assert_eq!(totals.per_task[0].cost["usd"], Range { p50: 5.0, p90: 5.0 });
        assert_eq!(
            totals.cost["usd"],
            Range {
                p50: 10.0,
                p90: 10.0
            }
        );
    }

    #[test]
    fn a_prior_class_draws_from_past_the_history() {
        let obs = vec![ob(10, 1.0); 3];
        let prior = prior();
        let wants = [task(1, &[]), task(2, &[])];
        let classes: Vec<Class> = wants
            .iter()
            .map(|w| reference_class(w, &obs, &prior))
            .collect();
        let pool: Vec<Obs> = obs.iter().chain(&prior).cloned().collect();
        let totals = simulate(&wants, &classes, &pool, &unpriced, 3, 1, DRAWS);
        // five equal picks: ×1 is the third of five, ×3 the fifth
        let tokens = |i: usize| prior[i].usage.total() as f64;
        let expected = Range {
            p50: tokens(2),
            p90: tokens(4),
        };
        assert_eq!(totals.per_task[0].tokens, expected);
        assert_eq!(totals.per_task[1].tokens, expected);
    }

    #[test]
    fn cold_wakes_add_up_over_a_plan() {
        let mut o = ob(1, 1.0);
        o.cold_wakes = 2;
        let totals = sim(&[task(1, &[]), task(2, &[])], &[o], 3);
        assert_eq!(totals.cold_wakes, Range { p50: 4.0, p90: 4.0 });
    }

    #[test]
    fn quantile_is_the_nearest_rank() {
        let values: Vec<f64> = (1..=2000).map(f64::from).collect();
        assert_eq!(quantile(&values, 0.5), 1000.0);
        assert_eq!(quantile(&values, 0.9), 1800.0);
        assert_eq!(quantile(&[1.0, 2.0, 3.0, 4.0], 0.5), 2.0);
        assert_eq!(quantile(&[7.0], 0.9), 7.0);
        assert_eq!(quantile(&[], 0.9), 0.0);
    }

    #[test]
    fn widen_keeps_p90_at_one_and_a_half_times_p50_below_twenty() {
        let tight = Range {
            p50: 100.0,
            p90: 110.0,
        };
        assert_eq!(
            widen(tight, 5),
            Range {
                p50: 100.0,
                p90: 150.0
            }
        );
        assert_eq!(
            widen(tight, 19),
            Range {
                p50: 100.0,
                p90: 150.0
            }
        );
        assert_eq!(widen(tight, 20), tight);
        let wide = Range {
            p50: 100.0,
            p90: 300.0,
        };
        assert_eq!(widen(wide, 5), wide);
    }

    #[test]
    fn conformal_needs_nine_pairs() {
        assert_eq!(conformal(&[(1.0, 1.0); 8]), None);
        assert_eq!(conformal(&[(1.0, 1.0); 9]), Some(1.0));
    }

    #[test]
    fn conformal_takes_the_right_rank() {
        // scrambled: 7 is coprime to 19
        let pairs: Vec<(f64, f64)> = (1..=19)
            .map(|i| (10.0, f64::from((i * 7) % 19 + 1)))
            .collect();
        near(conformal(&pairs).unwrap(), 1.8);
    }

    #[test]
    fn conformal_at_nine_pairs_takes_the_largest() {
        let pairs: Vec<(f64, f64)> = (1..=9).map(|i| (1.0, f64::from(i))).collect();
        assert_eq!(conformal(&pairs), Some(9.0));
    }

    #[test]
    fn conformal_divides_each_actual_by_its_own_p90() {
        let pairs: Vec<(f64, f64)> = (1..=9)
            .map(|i| (f64::from(i), 2.0 * f64::from(i)))
            .collect();
        assert_eq!(conformal(&pairs), Some(2.0));
    }

    #[test]
    fn a_p90_of_zero_does_not_count() {
        let mut pairs = vec![(1.0, 1.0); 8];
        pairs.push((0.0, 5.0));
        assert_eq!(conformal(&pairs), None);
        pairs.push((1.0, 1.0));
        assert_eq!(conformal(&pairs), Some(1.0));
    }

    /// Box-Muller.
    fn normal(rng: &mut SplitMix64) -> f64 {
        let (a, b) = (1.0 - rng.unit(), rng.unit());
        (-2.0 * a.ln()).sqrt() * (std::f64::consts::TAU * b).cos()
    }

    #[test]
    fn conformal_on_a_clean_history_covers_nine_in_ten() {
        // The guarantee is an average over histories, and it is exact: rank 181 of 201 covers 181/201 = 0.9005. One
        // history of 200 swings by about 0.024, so one seed cannot tell a fault from bad luck, and 200 fixed seeds can.
        const SEEDS: u32 = 200;
        // tasks of every size, and a p90 that runs low: it covers P(0.5 z + 0.3 ≤ 0) = 0.27 of runs before scaling
        let coverage = |seed: u32| {
            let mut rng = SplitMix64(seed_of(&["conformal", &seed.to_string()]));
            let pairs: Vec<(f64, f64)> = (0..1000)
                .map(|_| {
                    let p90 = 1e6 * normal(&mut rng).exp();
                    (p90, p90 * (0.5 * normal(&mut rng) + 0.3).exp())
                })
                .collect();
            let (past, future) = pairs.split_at(200);
            let share = |factor: f64| {
                let covered = future.iter().filter(|(p90, a)| *a <= p90 * factor);
                covered.count() as f64 / future.len() as f64
            };
            (share(1.0), share(conformal(past).unwrap()))
        };
        let (mut raw, mut scaled) = (0.0, 0.0);
        for seed in 0..SEEDS {
            let (r, s) = coverage(seed);
            raw += r / f64::from(SEEDS);
            scaled += s / f64::from(SEEDS);
        }
        assert!(raw < 0.4, "the raw p90 covers {raw}");
        assert!((scaled - 181.0 / 201.0).abs() < 0.005, "{scaled}");
    }
}
