//! Who is here as rows: only the user's tree is shown (pattern D), and every order of the model's sources gives the same
//! rows (pattern A).

use super::*;
use crate::work::presence::{Presence, PresenceEv, Touch};
use runstav::methods::work::PresenceSource as Source;

const T: f64 = 150.0;

fn ident(s: &str) -> Option<(u32, String)> {
    match s {
        "s1" => Some((1, "Opus".into())),
        "s2" => Some((2, "Sonnet".into())),
        "s3" => Some((3, "Opus 2".into())),
        _ => None,
    }
}

/// A linked worktree at /wt/feature whose main checkout is /w.
fn land(f: &str) -> Option<String> {
    f.strip_prefix("/wt/feature/").map(|r| format!("/w/{r}"))
}

fn step(session: &str, n: i64, at: f64, file: &str, mode: Mode) -> PresenceEv {
    PresenceEv::Step {
        session: session.into(),
        step: n,
        at,
        files: vec![Touch {
            file: file.into(),
            mode,
            line: Some(n as u32 * 10),
            source: Source::Acp,
        }],
    }
}

fn now(p: &Presence) -> Vec<(RepoPath, Vec<Entry>)> {
    p.files_under("/", T)
        .into_iter()
        .map(|f| {
            let e = p.now(&f, T).into_iter().cloned().collect();
            (f, e)
        })
        .collect()
}

fn here_of(p: &Presence) -> Here {
    here(&now(p), &["/w".to_owned()], land, ident)
}

fn keys(rows: &[Row]) -> Vec<String> {
    rows.iter().map(|r| r.key.clone()).collect()
}

#[test]
fn presence_rows_only_for_shown_paths() {
    let mut p = Presence::new();
    p.apply(step("s1", 1, 100.0, "/w/src/a.rs", Mode::Edit));
    // a worktree's file lands at its place in the main checkout
    p.apply(step("s2", 2, 101.0, "/wt/feature/src/b.rs", Mode::Pending));
    // outside the tree and landing nowhere: not shown
    p.apply(step("s3", 3, 102.0, "/elsewhere/c.rs", Mode::Edit));
    // an agent the hub has not named: not shown
    p.apply(step("s4", 4, 103.0, "/w/d.rs", Mode::Edit));
    let h = here_of(&p);
    let agents: Vec<(&str, &str)> = h
        .agents
        .iter()
        .map(|a| (a.session.as_str(), a.path.as_str()))
        .collect();
    assert_eq!(agents, vec![("s1", "/w/src/a.rs"), ("s2", "/w/src/b.rs")]);
    let paths: Vec<(&str, Vec<u32>, bool)> = h
        .paths
        .iter()
        .map(|(k, (o, d))| (k.as_str(), o.iter().copied().collect(), *d))
        .collect();
    assert_eq!(
        paths,
        vec![
            ("/w", vec![1, 2], true),
            ("/w/src", vec![1, 2], true),
            ("/w/src/a.rs", vec![1], false),
            ("/w/src/b.rs", vec![2], false),
        ]
    );
    assert_eq!(
        keys(&rows(&h)),
        vec![
            "a:s1",
            "a:s2",
            "p:/w",
            "p:/w/src",
            "p:/w/src/a.rs",
            "p:/w/src/b.rs"
        ]
    );
    // a read shows its agent and puts no badge
    p.apply(step("s3", 5, 104.0, "/w/notes.md", Mode::Read));
    let h = here_of(&p);
    assert_eq!(
        h.agents.last().map(|a| a.path.as_str()),
        Some("/w/notes.md")
    );
    assert!(!h.paths.contains_key("/w/notes.md"));
}

fn permutations(n: usize) -> Vec<Vec<usize>> {
    if n == 0 {
        return vec![Vec::new()];
    }
    let mut out = Vec::new();
    for p in permutations(n - 1) {
        for i in 0..=p.len() {
            let mut q = p.clone();
            q.insert(i, n - 1);
            out.push(q);
        }
    }
    out
}

#[test]
fn every_order_presence_converges() {
    let events = [
        step("s1", 1, 100.0, "/w/src/a.rs", Mode::Edit),
        step("s2", 2, 101.0, "/w/src/b.rs", Mode::Read),
        step("s3", 3, 102.0, "/wt/feature/lib/c.rs", Mode::Write),
        step("s1", 4, 103.0, "/w/README.md", Mode::Read),
        step("s2", 5, 104.0, "/w/src/a.rs", Mode::Pending),
    ];
    let mut seen: Option<serde_json::Value> = None;
    for order in permutations(events.len()) {
        let mut p = Presence::new();
        for i in &order {
            p.apply(events[*i].clone());
        }
        let got = serde_json::to_value(rows(&here_of(&p))).expect("rows serialise");
        match &seen {
            None => seen = Some(got),
            Some(first) => assert_eq!(&got, first, "order {order:?}"),
        }
    }
    let first = seen.expect("an order ran");
    let keys: Vec<&str> = first
        .as_array()
        .expect("rows")
        .iter()
        .filter_map(|r| r["key"].as_str())
        .collect();
    assert_eq!(
        keys,
        vec![
            "a:s1",
            "a:s2",
            "a:s3",
            "p:/w",
            "p:/w/lib",
            "p:/w/lib/c.rs",
            "p:/w/src",
            "p:/w/src/a.rs"
        ]
    );
}
