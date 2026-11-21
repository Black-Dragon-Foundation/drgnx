//! When a batch's groups are red (`docs/develop/orchestration.md`, "Reruns, interaction reds, flakes"): the red groups
//! run again, in parallel, at the line's HEAD and at each tip merged alone onto it; one round, never a bisection.
//!
//! - rows red at the line itself are the line's: the line is held, a followup and a card, no tip blamed;
//! - tips red alone (rows the line doesn't fail) go back to their tasks with those rows; the rest merge;
//! - every tip green alone: an **interaction red**, the later tip in readiness order goes back, the tips named.

/// What the reruns say.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// These runs are not in yet (`(line)` for the line's).
    Wait(Vec<String>),
    /// The line itself fails these rows.
    Line(Vec<String>),
    /// These tips fail alone: (task, rows).
    Culprits(Vec<(String, Vec<String>)>),
    /// Every tip passes alone: BACK goes back, TIPS were the batch.
    Interaction { back: String, tips: Vec<String> },
}

/// The verdict from the failing rows of the line's run (LINE) and of each tip's alone (TIPS, in readiness order),
/// `None` for a run not in yet.  Pure: the same results in any order of arrival give the same verdict.
pub fn verdict(line: Option<&[String]>, tips: &[(String, Option<Vec<String>>)]) -> Verdict {
    let mut pending: Vec<String> = Vec::new();
    if line.is_none() {
        pending.push("(line)".into());
    }
    pending.extend(
        tips.iter()
            .filter(|(_, r)| r.is_none())
            .map(|(t, _)| t.clone()),
    );
    if !pending.is_empty() {
        return Verdict::Wait(pending);
    }
    let line = line.unwrap_or_default();
    if !line.is_empty() {
        return Verdict::Line(line.to_vec());
    }
    let culprits: Vec<(String, Vec<String>)> = tips
        .iter()
        .filter_map(|(t, r)| {
            let rows = r.clone().unwrap_or_default();
            (!rows.is_empty()).then(|| (t.clone(), rows))
        })
        .collect();
    if !culprits.is_empty() {
        return Verdict::Culprits(culprits);
    }
    Verdict::Interaction {
        back: tips.last().map(|(t, _)| t.clone()).unwrap_or_default(),
        tips: tips.iter().map(|(t, _)| t.clone()).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn the_reruns_name_the_line_the_culprits_or_the_later_tip() {
        let tips = |a: Option<&[&str]>, b: Option<&[&str]>, c: Option<&[&str]>| {
            vec![
                ("a".to_string(), a.map(s)),
                ("b".to_string(), b.map(s)),
                ("c".to_string(), c.map(s)),
            ]
        };
        let none: &[String] = &[];
        // not all in
        assert_eq!(
            verdict(None, &tips(Some(&[]), None, Some(&[]))),
            Verdict::Wait(s(&["(line)", "b"]))
        );
        // the line fails by itself: no tip is blamed
        assert_eq!(
            verdict(
                Some(&s(&["x"])),
                &tips(Some(&["x"]), Some(&["x"]), Some(&[]))
            ),
            Verdict::Line(s(&["x"]))
        );
        // exactly the tips red alone
        assert_eq!(
            verdict(Some(none), &tips(Some(&[]), Some(&["y"]), Some(&[]))),
            Verdict::Culprits(vec![("b".into(), s(&["y"]))])
        );
        // all green alone: the later tip, both named
        assert_eq!(
            verdict(Some(none), &tips(Some(&[]), Some(&[]), Some(&[]))),
            Verdict::Interaction {
                back: "c".into(),
                tips: s(&["a", "b", "c"])
            }
        );
    }

    /// The runs end in any order; the verdict waits until all are in, and then names exactly the failing tips.
    #[derive(Clone, Debug)]
    enum Ev {
        Line(Vec<String>),
        Tip(usize, Vec<String>),
    }
    skuld::events!(Ev { Line, Tip });

    struct Fold {
        line: Option<Vec<String>>,
        tips: Vec<(String, Option<Vec<String>>)>,
        seen: Vec<Verdict>,
    }

    impl skuld::Core for Fold {
        type Event = Ev;
        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            match ev {
                Ev::Line(r) => self.line = Some(r),
                Ev::Tip(i, r) => self.tips[i].1 = Some(r),
            }
            self.seen.push(verdict(self.line.as_deref(), &self.tips));
            Vec::new()
        }
    }

    #[test]
    fn every_order_of_the_reruns_ends_in_one_verdict_naming_exactly_the_failing_tips() {
        let mut p = skuld::Partial::new();
        p.source("line", vec![Ev::Line(vec![])]);
        p.source("a", vec![Ev::Tip(0, vec![])]);
        p.source("b", vec![Ev::Tip(1, s(&["t::y"]))]);
        p.source("c", vec![Ev::Tip(2, vec![])]);
        let make = || Fold {
            line: None,
            tips: ["a", "b", "c"]
                .iter()
                .map(|t| (t.to_string(), None))
                .collect(),
            seen: Vec::new(),
        };
        let r = skuld::every_order(&p, skuld::Bound::default(), make, |f, order| {
            let (last, before) = f.seen.split_last().ok_or("no step")?;
            if before.iter().any(|v| !matches!(v, Verdict::Wait(_))) {
                return Err(format!("a verdict before every run was in: {order:?}"));
            }
            if *last != Verdict::Culprits(vec![("b".into(), s(&["t::y"]))]) {
                return Err(format!("{last:?} in {order:?}"));
            }
            Ok(())
        });
        assert_eq!(r.orders, 24, "{r:?}");
    }
}
