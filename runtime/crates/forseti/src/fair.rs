//! Fairness between projects within a priority: deficit round robin on machine-seconds over the last hour.

use std::collections::{BTreeMap, HashMap, VecDeque};

use crate::model::{JobId, Priority};

/// Deficit round robin. Each project starts a priority's round with the machine-seconds it used over the last 3600 s,
/// divided by its weight; the project with the least goes next, and each job it gets charges it `quantum_s` / its
/// weight. So a project that used less goes first, shares follow the weights, and one project's 400 chunks don't
/// starve another's work. P1 is exempt.
#[derive(Clone, Debug, PartialEq)]
pub struct Drr {
    /// What one job charges its project: the expected time of a job with no history (10 minutes).
    pub quantum_s: f64,
}

impl Default for Drr {
    fn default() -> Self {
        Drr { quantum_s: 600.0 }
    }
}

impl Drr {
    /// Reorders `order` (the queue order) within each run of jobs of one priority (`eff`; a job missing there is
    /// P5), never across runs, and keeps each project's jobs in their order. `weights` default to 1.
    pub fn order(
        &mut self,
        order: &[JobId],
        eff: &HashMap<JobId, Priority>,
        project_of: &dyn Fn(&JobId) -> String,
        usage_last_hour_s: &HashMap<String, f64>,
        weights: &HashMap<String, f64>,
    ) -> Vec<JobId> {
        let prio = |j: &JobId| eff.get(j).copied().unwrap_or(Priority::P5);
        let mut out = Vec::with_capacity(order.len());
        let mut start = 0;
        while start < order.len() {
            let p = prio(&order[start]);
            let end = order[start..]
                .iter()
                .position(|j| prio(j) != p)
                .map_or(order.len(), |n| start + n);
            let run = &order[start..end];
            if p == Priority::P1 {
                out.extend_from_slice(run);
            } else {
                self.share(run, project_of, usage_last_hour_s, weights, &mut out);
            }
            start = end;
        }
        out
    }

    /// One run of one priority: the project with the least credit (use ÷ weight, plus its charges) goes next; on a
    /// tie, the one whose next job comes first in the run.
    fn share(
        &self,
        run: &[JobId],
        project_of: &dyn Fn(&JobId) -> String,
        usage: &HashMap<String, f64>,
        weights: &HashMap<String, f64>,
        out: &mut Vec<JobId>,
    ) {
        struct Flow<'a> {
            jobs: VecDeque<(usize, &'a JobId)>,
            credit: f64,
            weight: f64,
        }
        let mut flows: BTreeMap<String, Flow> = BTreeMap::new();
        for (i, j) in run.iter().enumerate() {
            let p = project_of(j);
            let flow = flows.entry(p.clone()).or_insert_with(|| {
                let weight = weights.get(&p).copied().filter(|w| *w > 0.0).unwrap_or(1.0);
                Flow {
                    jobs: VecDeque::new(),
                    credit: usage.get(&p).copied().unwrap_or(0.0) / weight,
                    weight,
                }
            });
            flow.jobs.push_back((i, j));
        }
        loop {
            let next = flows
                .values_mut()
                .filter(|f| !f.jobs.is_empty())
                .min_by(|a, b| {
                    a.credit
                        .total_cmp(&b.credit)
                        .then(a.jobs[0].0.cmp(&b.jobs[0].0))
                });
            let Some(flow) = next else {
                return;
            };
            let (_, j) = flow.jobs.pop_front().expect("a flow with jobs");
            out.push(j.clone());
            flow.credit += self.quantum_s / flow.weight;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(s: &[&str]) -> Vec<JobId> {
        s.iter().map(|x| JobId(x.to_string())).collect()
    }

    fn names(v: &[JobId]) -> Vec<&str> {
        v.iter().map(|j| j.0.as_str()).collect()
    }

    #[test]
    fn drr_shares_within_a_priority_and_exempts_p1() {
        // [D] pure. Job names start with their project's letter.
        let order = ids(&["a1", "a2", "b1", "a3", "a4", "a5", "b2", "b3"]);
        let eff: HashMap<JobId, Priority> = order
            .iter()
            .enumerate()
            .map(|(i, j)| (j.clone(), if i < 3 { Priority::P1 } else { Priority::P4 }))
            .collect();
        let project = |j: &JobId| j.0[..1].to_string();
        let none = HashMap::new();
        let mut drr = Drr::default();
        // A used an hour; B nothing: B's two go first. P1 keeps its order.
        let used: HashMap<String, f64> = [("a".to_string(), 3600.0)].into();
        let out = drr.order(&order, &eff, &project, &used, &none);
        assert_eq!(
            names(&out),
            ["a1", "a2", "b1", "b2", "b3", "a3", "a4", "a5"]
        );
        // Equal use: they alternate, the earlier job first.
        let out = drr.order(&order, &eff, &project, &HashMap::new(), &none);
        assert_eq!(
            names(&out),
            ["a1", "a2", "b1", "a3", "b2", "a4", "b3", "a5"]
        );
        // B weighs 2: two of B's for each of A's.
        let order = ids(&["a1", "a2", "a3", "b1", "b2", "b3", "b4"]);
        let eff: HashMap<JobId, Priority> =
            order.iter().map(|j| (j.clone(), Priority::P4)).collect();
        let w: HashMap<String, f64> = [("b".to_string(), 2.0)].into();
        let out = drr.order(&order, &eff, &project, &HashMap::new(), &w);
        assert_eq!(names(&out), ["a1", "b1", "b2", "a2", "b3", "b4", "a3"]);
    }

    #[test]
    fn runs_of_one_priority_are_never_crossed() {
        // [D] pure: P3 then P4 then P3 again (a promoted job), each run reordered alone.
        let order = ids(&["a1", "b1", "a2", "b2", "a3"]);
        let p = [
            Priority::P3,
            Priority::P3,
            Priority::P4,
            Priority::P4,
            Priority::P3,
        ];
        let eff: HashMap<JobId, Priority> = order.iter().cloned().zip(p).collect();
        let project = |j: &JobId| j.0[..1].to_string();
        let used: HashMap<String, f64> = [("a".to_string(), 3600.0)].into();
        let out = Drr::default().order(&order, &eff, &project, &used, &HashMap::new());
        assert_eq!(names(&out), ["b1", "a1", "b2", "a2", "a3"]);
    }
}
