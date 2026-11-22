//! The merge queue's batch (`docs/develop/orchestration.md`, "The merge queue"): tasks ready to merge, in readiness
//! order, up to the pack's size.

/// A task ready to merge: it passed its gates at TIP, at time AT.
#[derive(Clone, Debug, PartialEq)]
pub struct Ready {
    pub task: String,
    pub tip: String,
    pub at: f64,
}

/// The next batch out of READY (any order): the earliest ready first, at most SIZE, skipping a task that CLASH says
/// conflicts with one already in the batch (it waits for the next batch, after the earlier one merged).
pub fn form(ready: &[Ready], size: usize, clash: impl Fn(&Ready, &Ready) -> bool) -> Vec<Ready> {
    let mut order: Vec<&Ready> = ready.iter().collect();
    order.sort_by(|a, b| a.at.total_cmp(&b.at).then_with(|| a.task.cmp(&b.task)));
    let mut out: Vec<Ready> = Vec::new();
    for r in order {
        if out.len() >= size.max(1) {
            break;
        }
        if out.iter().any(|m| clash(m, r)) {
            continue;
        }
        out.push(r.clone());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(task: &str, at: f64) -> Ready {
        Ready {
            task: task.into(),
            tip: format!("tip-{task}"),
            at,
        }
    }

    #[test]
    fn a_batch_takes_the_earliest_ready_up_to_its_size() {
        let ready = vec![r("c", 3.0), r("a", 1.0), r("d", 4.0), r("b", 2.0)];
        let names = |b: Vec<Ready>| b.into_iter().map(|r| r.task).collect::<Vec<_>>();
        assert_eq!(names(form(&ready, 3, |_, _| false)), vec!["a", "b", "c"]);
        assert_eq!(names(form(&ready, 0, |_, _| false)), vec!["a"]);
        // b conflicts with a: it waits; d fills the place
        let clash = |x: &Ready, y: &Ready| (x.task.as_str(), y.task.as_str()) == ("a", "b");
        assert_eq!(names(form(&ready, 3, clash)), vec!["a", "c", "d"]);
        assert!(form(&[], 3, |_, _| false).is_empty());
    }
}
