//! The affected groups of a merge batch (`docs/develop/orchestration.md`, "Affected groups"): the groups the base's
//! own tool names for the batch's combined diff (`bin/drgnx test --affected A..B --json`), each run at the combined
//! tree through the queue; the batch merges when every group is green, a failing row tolerated only when the base's
//! `test/frozen.eld` lists it.

use serde::Deserialize;

use crate::evidence::Evidence;
use crate::gates::{State, selector_of, state};
use crate::pack::Check;

#[derive(Deserialize)]
struct Listed {
    groups: Vec<Group>,
}

#[derive(Deserialize)]
struct Group {
    id: String,
    #[serde(default)]
    dir: Option<String>,
    run: Vec<String>,
}

/// The groups in the JSON the groups command printed, as checks (name = the group's id).
pub fn parse(json: &str) -> Result<Vec<Check>, String> {
    let l: Listed =
        serde_json::from_str(json).map_err(|e| format!("the groups command's JSON: {e}"))?;
    Ok(l.groups
        .into_iter()
        .map(|g| Check {
            name: g.id,
            dir: g.dir.unwrap_or_default(),
            run: g.run,
        })
        .collect())
}

/// The groups command with `%r` replaced by RANGE.
pub fn command(template: &[String], range: &str) -> Vec<String> {
    template.iter().map(|a| a.replace("%r", range)).collect()
}

/// Where the batch's groups stand.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Green,
    /// These groups have no run at the tree yet.
    Missing(Vec<Check>),
    /// These groups fail rows no frozen row lists: (group, rows).
    Red(Vec<(String, Vec<String>)>),
}

/// The batch's GROUPS at the tree KEY by EVIDENCE (oldest first); KNOWN says a failing row is a frozen one.  A red
/// counts before a missing run: it holds now.
pub fn judge(
    groups: &[Check],
    evidence: &[Evidence],
    key: &str,
    known: impl Fn(&str) -> bool,
) -> Outcome {
    let (mut red, mut missing) = (Vec::new(), Vec::new());
    for g in groups {
        match state(evidence, key, &selector_of(g)) {
            State::Green => {}
            State::Missing => missing.push(g.clone()),
            State::Red(rows) => {
                let new: Vec<String> = rows.into_iter().filter(|r| !known(r)).collect();
                if !new.is_empty() {
                    red.push((g.name.clone(), new));
                }
            }
        }
    }
    if !red.is_empty() {
        Outcome::Red(red)
    } else if !missing.is_empty() {
        Outcome::Missing(missing)
    } else {
        Outcome::Green
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::facts::Facts;
    use crate::rows::{Class, Row};

    fn ev(key: &str, selector: &str, rows: Vec<Row>) -> Evidence {
        Evidence {
            kind: "green".into(),
            task: "batch:j@T".into(),
            job: "x".into(),
            facts: Facts {
                tree_key: key.into(),
                env_stamp: "e".into(),
                platform: "p".into(),
                selector: selector.into(),
            },
            rows,
            truncated: false,
            at: 1.0,
            note: None,
        }
    }

    const JSON: &str = r#"{"range":"a..b","groups":[{"id":"unit","dir":null,"run":["bin/drgnx","test","--container"]},{"id":"rust:vordr","dir":"runtime","run":["cargo","test","-p","vordr"]}],"why":[]}"#;

    #[test]
    fn the_groups_commands_json_reads_as_checks() {
        let g = parse(JSON).unwrap();
        assert_eq!(g.len(), 2);
        assert_eq!((g[0].name.as_str(), g[0].dir.as_str()), ("unit", ""));
        assert_eq!(selector_of(&g[1]), "runtime\ncargo test -p vordr");
        assert!(parse("not json").is_err());
        let t: Vec<String> = ["bin/drgnx", "test", "--affected", "%r", "--json"]
            .map(String::from)
            .to_vec();
        assert_eq!(command(&t, "h..c")[3], "h..c");
    }

    #[test]
    fn a_batch_merges_only_on_its_groups_and_only_frozen_reds_are_tolerated() {
        let g = parse(JSON).unwrap();
        let (unit, rust) = (selector_of(&g[0]), selector_of(&g[1]));
        let none = |_: &str| false;
        // no runs: both missing (a merge without its groups is not green)
        assert_eq!(judge(&g, &[], "T", none), Outcome::Missing(g.clone()));
        let green = |s: &str| ev("T", s, vec![Row::pass("(job)")]);
        assert_eq!(
            judge(&g, &[green(&unit)], "T", none),
            Outcome::Missing(vec![g[1].clone()])
        );
        assert_eq!(
            judge(&g, &[green(&unit), green(&rust)], "T", none),
            Outcome::Green
        );
        // a run at another tree doesn't count
        let elsewhere = ev("U", &rust, vec![Row::pass("(job)")]);
        assert_eq!(
            judge(&g, &[green(&unit), elsewhere], "T", none),
            Outcome::Missing(vec![g[1].clone()])
        );
        // a new red on the line holds; a frozen one is tolerated
        let red = ev(
            "T",
            &unit,
            vec![Row::fail("drgnx-review/edge-cases", Class::Assert, vec![])],
        );
        let both = [red, green(&rust)];
        assert_eq!(
            judge(&g, &both, "T", none),
            Outcome::Red(vec![(
                "unit".into(),
                vec!["drgnx-review/edge-cases".into()]
            )])
        );
        assert_eq!(
            judge(&g, &both, "T", |r| r == "drgnx-review/edge-cases"),
            Outcome::Green
        );
    }
}
