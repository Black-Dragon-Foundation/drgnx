//! The push gate (`docs/develop/orchestration.md`, "The push gate"): one full Linux run before a push, its tiers (the
//! pack's `:push-tiers`) green on the exact commit's tree with the current env stamp.  The push itself stays the
//! user's (the matrix's `push.ci` and `push.main`); the gate only refuses one that is early.

use crate::evidence::Evidence;
use crate::gates::selector_of;
use crate::pack::{Check, Pack};
use crate::rows::failing;

/// What the gate says of a push.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Push {
    /// The pack has no push gate, or every tier is green.
    Ready,
    /// The push gate is on, but the pack names no tiers: refused (a gate never passes on nothing).
    NoTiers,
    /// These tiers have no run on this tree with this env stamp on Linux.
    Missing(Vec<Check>),
    /// These tiers' newest runs failed these rows.
    Red(Vec<(String, Vec<String>)>),
}

/// The push gate under PACK for the tree KEY, by EVIDENCE (oldest first) and the env STAMP the hub has now.  A run
/// counts only when its tree, selector and env stamp are these and its platform is Linux.
pub fn judge(pack: &Pack, evidence: &[Evidence], key: &str, stamp: &str) -> Push {
    if !pack.on("push-gate") {
        return Push::Ready;
    }
    if pack.push_tiers.is_empty() {
        return Push::NoTiers;
    }
    let mut missing = Vec::new();
    let mut red = Vec::new();
    for tier in &pack.push_tiers {
        let sel = selector_of(tier);
        let newest = evidence.iter().rev().find(|e| {
            e.facts.tree_key == key
                && e.facts.selector == sel
                && e.facts.env_stamp == stamp
                && e.facts.platform.starts_with("linux-")
        });
        match newest {
            None => missing.push(tier.clone()),
            Some(e) => {
                let rows: Vec<String> = failing(&e.rows).map(str::to_owned).collect();
                if !rows.is_empty() {
                    red.push((tier.name.clone(), rows));
                }
            }
        }
    }
    if !red.is_empty() {
        Push::Red(red)
    } else if !missing.is_empty() {
        Push::Missing(missing)
    } else {
        Push::Ready
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::facts::Facts;
    use crate::pack::Rule;
    use crate::rows::{Class, Row};

    fn tier(name: &str) -> Check {
        Check {
            name: name.into(),
            dir: String::new(),
            run: vec!["bin/drgnx".into(), "test".into(), name.into()],
        }
    }

    fn pack(tiers: Vec<Check>) -> Pack {
        Pack {
            name: "p".into(),
            rules: vec![Rule {
                id: "push-gate".into(),
                kind: "enforced".into(),
                doc: String::new(),
            }],
            push_tiers: tiers,
            ..Pack::default()
        }
    }

    fn run(t: &Check, key: &str, stamp: &str, platform: &str, rows: Vec<Row>) -> Evidence {
        Evidence {
            kind: "full-run".into(),
            task: "push:J@T".into(),
            job: "x".into(),
            facts: Facts {
                tree_key: key.into(),
                env_stamp: stamp.into(),
                platform: platform.into(),
                selector: selector_of(t),
            },
            rows,
            truncated: false,
            at: 1.0,
            note: None,
        }
    }

    #[test]
    fn a_push_without_a_full_run_is_refused_with_the_missing_tiers() {
        let (unit, ui) = (tier("unit"), tier("ui"));
        let p = pack(vec![unit.clone(), ui.clone()]);
        let lin = "linux-x86_64/local";
        // no run at all (the base)
        assert_eq!(
            judge(&p, &[], "T", "e1"),
            Push::Missing(vec![unit.clone(), ui.clone()])
        );
        let green = |t: &Check| run(t, "T", "e1", lin, vec![Row::pass("a::t")]);
        // one tier in: the other is named
        assert_eq!(
            judge(&p, &[green(&unit)], "T", "e1"),
            Push::Missing(vec![ui.clone()])
        );
        // another tree, another env stamp or another platform never counts
        let others = [
            run(&ui, "U", "e1", lin, vec![Row::pass("a::t")]),
            run(&ui, "T", "e0", lin, vec![Row::pass("a::t")]),
            run(
                &ui,
                "T",
                "e1",
                "macos-aarch64/local",
                vec![Row::pass("a::t")],
            ),
        ];
        for o in others {
            assert_eq!(
                judge(&p, &[green(&unit), o], "T", "e1"),
                Push::Missing(vec![ui.clone()])
            );
        }
        // a red tier says its rows; all green is ready
        let red = run(
            &ui,
            "T",
            "e1",
            lin,
            vec![Row::fail("b::u", Class::Assert, vec![])],
        );
        assert_eq!(
            judge(&p, &[green(&unit), red], "T", "e1"),
            Push::Red(vec![("ui".into(), vec!["b::u".into()])])
        );
        assert_eq!(
            judge(&p, &[green(&unit), green(&ui)], "T", "e1"),
            Push::Ready
        );
    }

    #[test]
    fn a_push_gate_with_no_tiers_refuses_and_no_push_gate_passes() {
        assert_eq!(judge(&pack(vec![]), &[], "T", "e"), Push::NoTiers);
        assert!(
            pack(vec![])
                .problems()
                .iter()
                .any(|p| p.contains("push-tiers"))
        );
        let off = Pack {
            rules: vec![],
            ..pack(vec![tier("unit")])
        };
        assert_eq!(judge(&off, &[], "T", "e"), Push::Ready);
    }
}
