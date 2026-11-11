//! The other gates before a task's merge (`docs/develop/orchestration.md`, "The author check" and "Trailers").
//!
//! - **Trailers:** no commit in base..tip carries a `Co-authored-by` line, a "Generated with …" line, or a `…-by:`
//!   trailer naming a model or its maker ([`trailers`]).
//! - **The author check:** the pack's `:author-check` commands and its `:rule-tests` pass on the tip's tree, each
//!   through the queue; a check's run is the newest job at the tip's tree key with the check's selector ([`state`]).
//! - **Waivers:** the user's `Waive once` passes the gates for the tip's tree it was given at ([`waived`]).

use crate::evidence::Evidence;
use crate::facts::selector;
use crate::pack::{Check, Pack};
use crate::rows::failing;

/// Words that make a `…-by:` trailer an AI attribution.
const AI_WORDS: &[&str] = &[
    "claude",
    "anthropic",
    "openai",
    "chatgpt",
    "gpt-",
    "copilot",
    "gemini",
    "codex",
    "ai assistant",
];

/// The attribution lines in a commit's MESSAGE.
pub fn trailers(message: &str) -> Vec<String> {
    message
        .lines()
        .map(str::trim)
        .filter(|l| {
            let low = l.to_lowercase();
            // "Generated with …" as its own line (a body's "code generated with bindgen" isn't one)
            let generated = low
                .trim_start_matches(|c: char| !c.is_ascii_alphanumeric())
                .starts_with("generated with");
            if low.starts_with("co-authored-by:") || generated {
                return true;
            }
            let Some((key, value)) = low.split_once(':') else {
                return false;
            };
            key.ends_with("-by") && !key.contains(' ') && AI_WORDS.iter().any(|w| value.contains(w))
        })
        .map(str::to_owned)
        .collect()
}

/// The checks the author check runs under PACK: its `:author-check` commands and `:rule-tests` (`author-check` on),
/// or the rule tests alone (`rule-tests` on).
pub fn checks(pack: &Pack) -> Vec<Check> {
    let mut out = Vec::new();
    if pack.on("author-check") {
        out.extend(pack.author_check.iter().cloned());
    }
    if pack.on("author-check") || pack.on("rule-tests") {
        out.extend(pack.rule_tests.iter().cloned());
    }
    out
}

/// CHECK's selector, as a job that runs it records it (`vordr::facts::selector`).
pub fn selector_of(check: &Check) -> String {
    selector(&check.dir, &check.run, &[])
}

/// A check's run at a tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    /// No run yet.
    Missing,
    Green,
    /// Its newest run failed these rows.
    Red(Vec<String>),
}

/// The state of the check with SELECTOR at the tree KEY, by its newest run in EVIDENCE (oldest first).
pub fn state(evidence: &[Evidence], key: &str, selector: &str) -> State {
    let Some(e) = evidence
        .iter()
        .rev()
        .find(|e| e.facts.tree_key == key && e.facts.selector == selector)
    else {
        return State::Missing;
    };
    let red: Vec<String> = failing(&e.rows).map(str::to_owned).collect();
    if red.is_empty() {
        State::Green
    } else {
        State::Red(red)
    }
}

/// The reason of the newest waiver given at the tree KEY (the user's `Waive once`; a new tip needs a new one).
pub fn waived(evidence: &[Evidence], key: &str) -> Option<String> {
    evidence
        .iter()
        .rev()
        .find(|e| e.kind == "waiver" && e.facts.tree_key == key)
        .map(|e| e.note.clone().unwrap_or_default())
}

/// The flaky rows in EVIDENCE (oldest first): a row that failed in one run and passed in a later run of the same
/// selector on the same tree, env stamp and platform.  Each holds the merge (flakes are fixed at the cause, never
/// listed).
pub fn flaky(evidence: &[Evidence]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for (i, a) in evidence.iter().enumerate() {
        for row in failing(&a.rows) {
            let passed_later = evidence[i + 1..].iter().any(|b| {
                b.facts == a.facts
                    && b.rows
                        .iter()
                        .any(|r| r.name == row && r.verdict == crate::rows::Verdict::Pass)
            });
            if passed_later && !out.iter().any(|o| o == row) {
                out.push(row.to_owned());
            }
        }
    }
    out
}

/// The flaky rows that hold a merge under PACK: [`flaky`]'s, when its `flake-hold` is on.
pub fn flake_holds(pack: &Pack, evidence: &[Evidence]) -> Vec<String> {
    if pack.on("flake-hold") {
        flaky(evidence)
    } else {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::evidence::Evidence;
    use crate::facts::Facts;
    use crate::pack::{Check, Pack, Rule};
    use crate::rows::{Class, Row};

    fn rule(id: &str) -> Rule {
        Rule {
            id: id.into(),
            kind: "enforced".into(),
            doc: String::new(),
        }
    }

    fn check(name: &str, dir: &str, run: &[&str]) -> Check {
        Check {
            name: name.into(),
            dir: dir.into(),
            run: run.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn ev(key: &str, selector: &str, rows: Vec<Row>) -> Evidence {
        Evidence {
            kind: "green".into(),
            task: "t1".into(),
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

    #[test]
    fn attribution_trailers_are_found() {
        assert!(trailers("hub: a fix\n\nBody.\n").is_empty());
        assert_eq!(
            trailers("x\n\nCo-authored-by: Someone <a@b>\n"),
            vec!["Co-authored-by: Someone <a@b>"]
        );
        assert_eq!(trailers("x\n\nco-authored-by: a\n").len(), 1);
        assert_eq!(
            trailers("x\n\nGenerated with [Claude Code](https://claude.com)\n").len(),
            1
        );
        assert_eq!(
            trailers("x\n\nSigned-off-by: Claude <noreply@anthropic.com>\n").len(),
            1
        );
        // a person's sign-off and a body that names a model are not trailers to refuse
        assert!(trailers("x\n\nSigned-off-by: A Person <p@x.org>\n").is_empty());
        assert!(trailers("route reviews to Gemini\n\nThe gemini route.\n").is_empty());
    }

    #[test]
    fn the_author_checks_and_their_state_at_the_tip() {
        let p = Pack {
            name: "p".into(),
            rules: vec![rule("author-check")],
            author_check: vec![check("build", "", &["bin/drgnx", "build"])],
            rule_tests: vec![check("rules", "runtime", &["cargo", "test", "--test", "r"])],
            ..Pack::default()
        };
        let cs = checks(&p);
        assert_eq!(cs.len(), 2);
        assert_eq!(selector_of(&cs[0]), ".\nbin/drgnx build");
        assert_eq!(selector_of(&cs[1]), "runtime\ncargo test --test r");
        // rule tests alone when only rule-tests is on; nothing when neither is
        let only = Pack {
            rules: vec![rule("rule-tests")],
            ..p.clone()
        };
        assert_eq!(checks(&only).len(), 1);
        assert!(
            checks(&Pack {
                rules: vec![],
                ..p.clone()
            })
            .is_empty()
        );
        let sel = selector_of(&cs[0]);
        assert_eq!(state(&[], "P", &sel), State::Missing);
        let green = ev("P", &sel, vec![Row::pass("(job)")]);
        let red = ev(
            "P",
            &sel,
            vec![Row::fail("build:x (lib)", Class::Build, vec![])],
        );
        let elsewhere = ev("Q", &sel, vec![Row::pass("(job)")]);
        assert_eq!(state(&[elsewhere], "P", &sel), State::Missing);
        assert_eq!(state(std::slice::from_ref(&green), "P", &sel), State::Green);
        assert_eq!(
            state(&[green.clone(), red.clone()], "P", &sel),
            State::Red(vec!["build:x (lib)".into()]),
            "the newest run counts"
        );
        assert_eq!(state(&[red, green], "P", &sel), State::Green);
    }

    #[test]
    fn a_row_that_fails_then_passes_on_the_same_tree_is_flaky() {
        let fail = |key: &str| {
            ev(
                key,
                "s",
                vec![Row::fail("a::t", Class::Assert, vec![]), Row::pass("b::u")],
            )
        };
        let pass = |key: &str| ev(key, "s", vec![Row::pass("a::t"), Row::pass("b::u")]);
        assert_eq!(flaky(&[fail("P"), pass("P")]), vec!["a::t"]);
        // fixed by a new tree: not a flake
        assert!(flaky(&[fail("P"), pass("Q")]).is_empty());
        // passed first, then failed: a red, not a flake
        assert!(flaky(&[pass("P"), fail("P")]).is_empty());
        // another selector's pass doesn't count
        let mut other = pass("P");
        other.facts.selector = "t".into();
        assert!(flaky(&[fail("P"), other]).is_empty());
        // only under a pack whose flake-hold is on
        let on = Pack {
            rules: vec![rule("flake-hold")],
            ..Pack::default()
        };
        assert_eq!(flake_holds(&on, &[fail("P"), pass("P")]), vec!["a::t"]);
        assert!(flake_holds(&Pack::default(), &[fail("P"), pass("P")]).is_empty());
    }

    #[test]
    fn a_waiver_holds_for_the_tree_it_was_given_at() {
        let mut w = ev("P", "", vec![]);
        w.kind = "waiver".into();
        w.note = Some("a docs change".into());
        let green = ev("P", "x", vec![Row::pass("(job)")]);
        assert_eq!(waived(std::slice::from_ref(&green), "P"), None);
        assert_eq!(
            waived(&[green.clone(), w.clone()], "P").as_deref(),
            Some("a docs change")
        );
        // once: a new tip needs a new waiver
        assert_eq!(waived(&[w], "Q"), None);
    }
}
