//! Priority: inheritance, promotion and the queue order.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use crate::model::{Expected, Job, JobId, JobSpec, Priority};

/// A job's effective priority: the highest of its own and of everything that waits on it. Waiters are the jobs that
/// need it, the jobs waiting for a state lock it holds (`locks` are `(path, holder)`, `waits_on_lock` `(waiter,
/// path)`), the user (P1, when `for_user` is set) and a blocked caller (P3).
pub fn effective_priorities(
    jobs: &[Job],
    locks: &[(PathBuf, JobId)],
    waits_on_lock: &[(JobId, PathBuf)],
) -> HashMap<JobId, Priority> {
    let mut eff: HashMap<JobId, Priority> = jobs
        .iter()
        .map(|j| {
            let mut p = j.own;
            if j.spec.for_user.is_some() {
                p = p.max(Priority::P1);
            }
            if j.blocked_caller {
                p = p.max(Priority::P3);
            }
            (j.id.clone(), p)
        })
        .collect();
    // waiter → the jobs it waits on
    let mut edges: Vec<(&JobId, &JobId)> = Vec::new();
    for j in jobs {
        edges.extend(j.spec.needs.iter().map(|t| (&j.id, t)));
    }
    for (waiter, path) in waits_on_lock {
        edges.extend(
            locks
                .iter()
                .filter(|(p, _)| p == path)
                .map(|(_, holder)| (waiter, holder)),
        );
    }
    // A fixpoint: each pass only raises, and there are five priorities, so it ends (cycles included).
    loop {
        let mut changed = false;
        for &(w, t) in &edges {
            let (Some(&pw), Some(&pt)) = (eff.get(w), eff.get(t)) else {
                continue;
            };
            if pw > pt {
                eff.insert(t.clone(), pw);
                changed = true;
            }
        }
        if !changed {
            return eff;
        }
    }
}

/// Refuses a new job whose needs reach a cycle; the error lists the cycle's jobs in order.
pub fn check_no_cycle(jobs: &[Job], new: &JobSpec) -> Result<(), Vec<JobId>> {
    let by_id: HashMap<&JobId, &Job> = jobs.iter().map(|j| (&j.id, j)).collect();
    let mut done: HashSet<&JobId> = HashSet::new();
    let mut path: Vec<&JobId> = Vec::new();
    for start in &new.needs {
        walk(start, &by_id, &mut done, &mut path)?;
    }
    Ok(())
}

fn walk<'a>(
    at: &'a JobId,
    by_id: &HashMap<&'a JobId, &'a Job>,
    done: &mut HashSet<&'a JobId>,
    path: &mut Vec<&'a JobId>,
) -> Result<(), Vec<JobId>> {
    if let Some(i) = path.iter().position(|p| *p == at) {
        return Err(path[i..].iter().map(|j| (*j).clone()).collect());
    }
    if done.contains(at) {
        return Ok(());
    }
    let Some(job) = by_id.get(at) else {
        return Ok(());
    };
    path.push(at);
    for next in &job.spec.needs {
        walk(next, by_id, done, path)?;
    }
    path.pop();
    done.insert(at);
    Ok(())
}

/// One step up per 3600 s waited, never into P1 (a P1 job stays P1).
pub fn promote(own: Priority, waited_s: u64) -> Priority {
    if own == Priority::P1 {
        return own;
    }
    let steps = (waited_s / 3600).min(4) as u8;
    Priority::from_number(own.number().saturating_sub(steps).max(2))
}

/// The queue order: by priority (the effective one, or the job's own promoted by its wait, whichever is higher); P1–P4
/// shortest expected first with aging (`expected − waited`, in minutes); P5 oldest first, shortest first only within
/// the same minute.
pub fn queue_order(
    jobs: &[Job],
    eff: &HashMap<JobId, Priority>,
    expected: &dyn Fn(&JobId) -> Expected,
    now: u64,
) -> Vec<JobId> {
    struct Key<'a> {
        prio: Priority,
        primary: f64,
        secondary: f64,
        submitted: u64,
        id: &'a JobId,
    }
    let mut keys: Vec<Key> = jobs
        .iter()
        .map(|j| {
            let waited_s = now.saturating_sub(j.submitted);
            let inherited = eff.get(&j.id).copied().unwrap_or(j.own);
            let prio = inherited.max(promote(j.own, waited_s));
            let minutes = expected(&j.id).minutes;
            let (primary, secondary) = if prio == Priority::P5 {
                ((j.submitted / 60) as f64, minutes)
            } else {
                (minutes - waited_s as f64 / 60.0, 0.0)
            };
            Key {
                prio,
                primary,
                secondary,
                submitted: j.submitted,
                id: &j.id,
            }
        })
        .collect();
    keys.sort_by(|a, b| {
        b.prio
            .cmp(&a.prio)
            .then(a.primary.total_cmp(&b.primary))
            .then(a.secondary.total_cmp(&b.secondary))
            .then(a.submitted.cmp(&b.submitted))
            .then(a.id.cmp(b.id))
    });
    keys.into_iter().map(|k| k.id.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{expected_min, job};

    #[test]
    fn inherits_through_needs_and_state_locks() {
        // [D] pure. A gate's chunk 7 (P4) needs prefix build a3f (P4); the user bumps chunk 7.
        let mut chunk7 = job("chunk7", Priority::P4, 0);
        chunk7.spec.needs = vec![JobId("a3f".into())];
        chunk7.spec.for_user = Some("run chunk 7 first".into());
        let a3f = job("a3f", Priority::P4, 0);
        // A P1 job waits on a build dir that a running P5 job holds.
        let user = job("user", Priority::P1, 0);
        let holder = job("holder", Priority::P5, 0);
        // A P5 job an agent is blocked on.
        let mut blocked = job("blocked", Priority::P5, 0);
        blocked.blocked_caller = true;
        let alone = job("alone", Priority::P5, 0);
        let dir = PathBuf::from("/build/dir");
        let jobs = [chunk7, a3f, user, holder, blocked, alone];
        let eff = effective_priorities(
            &jobs,
            &[(dir.clone(), JobId("holder".into()))],
            &[(JobId("user".into()), dir)],
        );
        let at = |n: &str| eff[&JobId(n.into())];
        assert_eq!(at("chunk7"), Priority::P1);
        assert_eq!(at("a3f"), Priority::P1);
        assert_eq!(at("holder"), Priority::P1);
        assert_eq!(at("blocked"), Priority::P3);
        assert_eq!(at("alone"), Priority::P5);
    }

    #[test]
    fn a_cycle_is_refused() {
        // [D] pure
        let mut a = job("a", Priority::P4, 0);
        a.spec.needs = vec![JobId("b".into())];
        let mut b = job("b", Priority::P4, 0);
        b.spec.needs = vec![JobId("a".into())];
        let c = job("c", Priority::P4, 0);
        let mut new = job("new", Priority::P4, 0).spec;
        new.needs = vec![JobId("c".into())];
        assert_eq!(
            check_no_cycle(&[a.clone(), b.clone(), c.clone()], &new),
            Ok(())
        );
        new.needs = vec![JobId("a".into())];
        let cycle = check_no_cycle(&[a, b, c], &new).unwrap_err();
        assert_eq!(cycle, vec![JobId("a".into()), JobId("b".into())]);
    }

    #[test]
    fn promotion_stops_below_priority_1() {
        // [D] pure
        assert_eq!(promote(Priority::P5, 0), Priority::P5);
        assert_eq!(promote(Priority::P5, 3599), Priority::P5);
        assert_eq!(promote(Priority::P5, 3600), Priority::P4);
        assert_eq!(promote(Priority::P5, 3 * 3600), Priority::P2);
        assert_eq!(promote(Priority::P5, 100 * 3600), Priority::P2);
        assert_eq!(promote(Priority::P3, 7200), Priority::P2);
        assert_eq!(promote(Priority::P2, 7200), Priority::P2);
        assert_eq!(promote(Priority::P1, 7200), Priority::P1);
    }

    #[test]
    fn priority_5_is_oldest_first() {
        // [D] pure. Older beats shorter; within one minute the shorter goes first.
        let now = 10_000;
        let old_long = job("old-long", Priority::P5, now - 600);
        let new_short = job("new-short", Priority::P5, now - 60);
        let same_min_long = job("same-long", Priority::P5, now - 1800);
        let same_min_short = job("same-short", Priority::P5, now - 1790);
        let jobs = [new_short, old_long, same_min_short, same_min_long];
        let minutes: HashMap<&str, f64> = [
            ("old-long", 50.0),
            ("new-short", 1.0),
            ("same-long", 40.0),
            ("same-short", 2.0),
        ]
        .into();
        let exp = |id: &JobId| expected_min(minutes[id.0.as_str()]);
        let order = queue_order(&jobs, &HashMap::new(), &exp, now);
        let names: Vec<&str> = order.iter().map(|j| j.0.as_str()).collect();
        assert_eq!(names, ["same-short", "same-long", "old-long", "new-short"]);
    }

    #[test]
    fn shortest_first_with_aging() {
        // [D] pure
        let now = 100_000;
        let a = job("a", Priority::P3, now); // 30 min, just in
        let b = job("b", Priority::P3, now); // 10 min, just in
        let c = job("c", Priority::P3, now - 25 * 60); // 30 min, waited 25: key 5
        let p1 = job("p1", Priority::P1, now); // 120 min, but P1
        let p4 = job("p4", Priority::P4, now - 50 * 60); // 1 min, waited 50, still P4
        let minutes: HashMap<&str, f64> = [
            ("a", 30.0),
            ("b", 10.0),
            ("c", 30.0),
            ("p1", 120.0),
            ("p4", 1.0),
        ]
        .into();
        let exp = |id: &JobId| expected_min(minutes[id.0.as_str()]);
        let order = queue_order(&[a, b, c, p1, p4], &HashMap::new(), &exp, now);
        let names: Vec<&str> = order.iter().map(|j| j.0.as_str()).collect();
        assert_eq!(names, ["p1", "c", "b", "a", "p4"]);
    }

    #[test]
    fn the_order_takes_the_effective_or_the_promoted_priority() {
        // [D] pure. An inherited P2 beats an own P3; a P5 that waited two hours is P3.
        let now = 100_000;
        let lifted = job("lifted", Priority::P5, now);
        let aged = job("aged", Priority::P5, now - 2 * 3600);
        let p4 = job("p4", Priority::P4, now);
        let eff: HashMap<JobId, Priority> = [(JobId("lifted".into()), Priority::P2)].into();
        let exp = |_: &JobId| expected_min(5.0);
        let order = queue_order(&[p4, aged, lifted], &eff, &exp, now);
        let names: Vec<&str> = order.iter().map(|j| j.0.as_str()).collect();
        assert_eq!(names, ["lifted", "aged", "p4"]);
    }
}
