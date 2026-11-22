//! Order-dependent crashes (job-scheduler design §8.2 step 5): the suspect passed alone, so some earlier row of its
//! chunk crashes it. [`bisect_plan`] plans at most `budget` runs that, together, name that row; [`find`] reads which of
//! them crashed. With no per-row lines at all there are no done rows to search: [`halves`] cuts the chunk in two, again
//! and again, down to single rows. Pure.

/// The runs a bisect may take (§8.2).
pub const BUDGET: usize = 4;

/// The runs to try, each the done rows it holds in their order and then the suspect. They are independent (none needs
/// another's answer), so they may run side by side.
///
/// The done rows are cut into `m = min(rows, 2^budget - 1)` contiguous groups numbered from 1; run `k` holds the groups
/// whose number has bit `k` set. A culprit in group `g` makes exactly the runs of `g`'s set bits crash (the pair crashes
/// together; the other runs lack the culprit), so [`find`] reads `g` back from which runs crashed.
pub fn bisect_plan(done_rows: &[String], suspect: &str, budget: usize) -> Vec<Vec<String>> {
    if done_rows.is_empty() || budget == 0 {
        return vec![];
    }
    let groups = groups(done_rows.len(), budget);
    (0..budget)
        .map(|k| {
            let mut run: Vec<String> = done_rows
                .iter()
                .enumerate()
                .filter(|(i, _)| (group_of(*i, done_rows.len(), groups) >> k) & 1 == 1)
                .map(|(_, r)| r.clone())
                .collect();
            run.push(suspect.to_string());
            run
        })
        // a run no group reaches (fewer groups than bits) holds only the suspect: nothing to learn from it
        .filter(|run| run.len() > 1)
        .collect()
}

fn groups(rows: usize, budget: usize) -> usize {
    rows.min((1usize << budget.min(16)) - 1)
}

/// The group (from 1) of done row I of N, in M contiguous groups.
fn group_of(i: usize, n: usize, m: usize) -> usize {
    i * m / n + 1
}

/// What [`find`] makes of the runs' outcomes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Culprit {
    /// The one done row that crashes the suspect.
    Row(String),
    /// More done rows than runs could tell apart: the culprit is one of these, in order.
    Group(Vec<String>),
    /// No run crashed: the crash doesn't come back (a flake), or doesn't need a done row.
    None,
}

/// Reads PLAN's outcomes (`crashed[i]` for `plan[i]`, so `plan` must be what [`bisect_plan`] gave for the same
/// arguments) into the culprit.
pub fn find(done_rows: &[String], suspect: &str, budget: usize, crashed: &[bool]) -> Culprit {
    let plan = bisect_plan(done_rows, suspect, budget);
    let groups = groups(done_rows.len(), budget);
    // the plan drops empty runs: map each kept run back to its bit
    let bits: Vec<usize> = (0..budget)
        .filter(|k| (1..=groups).any(|g| (g >> k) & 1 == 1))
        .collect();
    debug_assert_eq!(bits.len(), plan.len());
    let g = bits
        .iter()
        .zip(crashed)
        .filter(|(_, c)| **c)
        .fold(0usize, |g, (k, _)| g | (1 << k));
    if g == 0 || g > groups {
        return Culprit::None;
    }
    let n = done_rows.len();
    let members: Vec<String> = done_rows
        .iter()
        .enumerate()
        .filter(|(i, _)| group_of(*i, n, groups) == g)
        .map(|(_, r)| r.clone())
        .collect();
    match members.as_slice() {
        [one] => Culprit::Row(one.clone()),
        _ => Culprit::Group(members),
    }
}

/// A chunk with no per-row lines cut in two (the first half is the larger when odd). Cut each part again until every
/// part is one row.
pub fn halves(rows: &[String]) -> (Vec<String>, Vec<String>) {
    let at = rows.len().div_ceil(2);
    (rows[..at].to_vec(), rows[at..].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("t{i}")).collect()
    }

    /// Whether RUN crashes when ROW and the suspect are both in it, in that order (the planted pair).
    fn crashes(run: &[String], row: &str, suspect: &str) -> bool {
        run.iter()
            .position(|r| r == row)
            .is_some_and(|a| run.iter().position(|r| r == suspect).is_some_and(|b| a < b))
    }

    // [D] pure
    #[test]
    fn finds_a_planted_pair_within_4() {
        for n in 1..=15 {
            let done = names(n);
            for culprit in &done {
                let plan = bisect_plan(&done, "suspect", BUDGET);
                assert!(plan.len() <= BUDGET, "{n}: {} runs", plan.len());
                let crashed: Vec<bool> = plan
                    .iter()
                    .map(|r| crashes(r, culprit, "suspect"))
                    .collect();
                assert_eq!(
                    find(&done, "suspect", BUDGET, &crashed),
                    Culprit::Row(culprit.clone()),
                    "{n} rows, culprit {culprit}"
                );
            }
        }
        // more rows than 4 runs can tell apart: the group that holds the culprit, in order
        let done = names(100);
        let plan = bisect_plan(&done, "suspect", BUDGET);
        let crashed: Vec<bool> = plan.iter().map(|r| crashes(r, "t42", "suspect")).collect();
        match find(&done, "suspect", BUDGET, &crashed) {
            Culprit::Group(g) => assert!(g.contains(&"t42".to_string()) && g.len() <= 7, "{g:?}"),
            other => panic!("{other:?}"),
        }
        // no run crashed: nothing to name
        assert_eq!(find(&done, "suspect", BUDGET, &[false; 4]), Culprit::None);
        // every run ends with the suspect, after the done rows' order
        assert!(
            plan.iter()
                .all(|r| r.last().map(String::as_str) == Some("suspect"))
        );
    }

    // [D] pure
    #[test]
    fn no_row_lines_halves_to_singles() {
        fn singles(rows: Vec<String>, depth: usize, max_depth: &mut usize, out: &mut Vec<String>) {
            if rows.len() <= 1 {
                *max_depth = (*max_depth).max(depth);
                out.extend(rows);
                return;
            }
            let (a, b) = halves(&rows);
            assert!(!a.is_empty() && !b.is_empty());
            singles(a, depth + 1, max_depth, out);
            singles(b, depth + 1, max_depth, out);
        }
        for n in [1usize, 2, 5, 8, 13, 40] {
            let rows = names(n);
            let (mut depth, mut out) = (0, vec![]);
            singles(rows.clone(), 0, &mut depth, &mut out);
            assert_eq!(out, rows, "every row once, in order");
            assert!(
                depth <= (n as f64).log2().ceil() as usize,
                "{n}: depth {depth}"
            );
        }
        assert!(bisect_plan(&[], "s", BUDGET).is_empty());
    }
}
