//! Identity: unique ordinals and handles in every order of starts and ends (pattern A), and the rules (pattern D).

use super::*;
use skuld::{Bound, Partial, every_order};
use std::collections::BTreeSet;

#[derive(Clone, Debug)]
enum Ev {
    Take {
        workspace: &'static str,
        session: &'static str,
        model: &'static str,
    },
    Free {
        session: &'static str,
    },
}

skuld::events!(Ev { Take, Free });

fn take(workspace: &'static str, session: &'static str, model: &'static str) -> Ev {
    Ev::Take {
        workspace,
        session,
        model,
    }
}

fn free(session: &'static str) -> Ev {
    Ev::Free { session }
}

/// The pool, what each live session was given, and the first broken rule.
#[derive(Default)]
struct Harness {
    pool: Pool,
    given: BTreeMap<&'static str, (&'static str, Identity)>,
    broken: Option<String>,
}

impl skuld::Core for Harness {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        match ev {
            Ev::Take {
                workspace,
                session,
                model,
            } => {
                let id = self.pool.take(workspace, session, model);
                if self.pool.take(workspace, session, model) != id && self.broken.is_none() {
                    self.broken = Some(format!("{session} changed identity"));
                }
                self.given.insert(session, (workspace, id));
            }
            Ev::Free { session } => {
                self.pool.free(session);
                self.given.remove(session);
            }
        }
        let mut seen: BTreeSet<(&str, u32)> = BTreeSet::new();
        let mut handles: BTreeSet<(&str, String)> = BTreeSet::new();
        for (ws, id) in self.given.values() {
            if (!seen.insert((ws, id.ordinal)) || !handles.insert((ws, id.handle.clone())))
                && self.broken.is_none()
            {
                self.broken = Some(format!("{ws}: {id:?} given twice in {:?}", self.given));
            }
        }
        Vec::new()
    }
}

/// Pattern A. Four sessions start and two end in one workspace while a fifth starts in another, in every order: no
/// two live sessions of a workspace share an ordinal or a handle, a session keeps its identity, and the ones left
/// hold the lowest ordinals their history allows. Edges: a session ends after it started.
#[test]
fn every_order_starts_and_ends_keep_ordinals_unique() {
    let mut p = Partial::new();
    p.source("a", vec![take("w", "a", "Opus"), free("a")]);
    p.source("b", vec![take("w", "b", "Opus")]);
    p.source("c", vec![take("w", "c", "Sonnet"), free("c")]);
    p.source("d", vec![take("w", "d", "Opus")]);
    p.source("e", vec![take("v", "e", "Opus")]);
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        if let Some(b) = &h.broken {
            return Err(b.clone());
        }
        let left: BTreeSet<&str> = h.given.keys().copied().collect();
        if left != BTreeSet::from(["b", "d", "e"]) {
            return Err(format!("left {left:?}"));
        }
        if h.given["e"].1.ordinal != 1 || h.given["e"].1.handle != "Opus" {
            return Err(format!(
                "another workspace counts apart: {:?}",
                h.given["e"]
            ));
        }
        if h.given.values().any(|(_, id)| id.ordinal > 4) {
            return Err(format!("an ordinal past four starts: {:?}", h.given));
        }
        Ok(())
    });
    assert!(r.orders > 20, "{} orders", r.orders);
}

/// Pattern D. Forty agents of three models in one workspace: forty handles, ordinals 1 to 40.
#[test]
fn forty_agents_get_unique_handles() {
    let pool = Pool::default();
    let models = ["Opus", "Sonnet", "Codex"];
    let ids: Vec<Identity> = (0..40)
        .map(|i| pool.take("w", &format!("s{i}"), models[i % 3]))
        .collect();
    let handles: BTreeSet<&str> = ids.iter().map(|i| i.handle.as_str()).collect();
    assert_eq!(handles.len(), 40);
    let ordinals: Vec<u32> = ids.iter().map(|i| i.ordinal).collect();
    assert_eq!(ordinals, (1..=40).collect::<Vec<u32>>());
    assert!(ids.iter().all(|i| i.monogram.chars().count() <= 3));
}

/// Pattern D. An ordinal freed by an ended session is given again, the lowest first.
#[test]
fn a_freed_ordinal_is_reused_lowest_first() {
    let pool = Pool::default();
    for s in ["a", "b", "c"] {
        pool.take("w", s, "Opus");
    }
    pool.free("b");
    pool.free("a");
    assert_eq!(pool.take("w", "d", "Sonnet").ordinal, 1);
    assert_eq!(pool.take("w", "e", "Sonnet").ordinal, 2);
    assert_eq!(pool.take("w", "f", "Sonnet").ordinal, 4);
    assert_eq!(pool.get("c").unwrap().ordinal, 3, "a live ordinal is kept");
}

/// Pattern D. A subagent holds an identity of its own, beside its parent's, and ends with it.
#[test]
fn a_subagent_has_its_own_identity() {
    let pool = Pool::default();
    let parent = pool.take("w", "s1", "Opus");
    let kid = pool.take("w", "agent:s1/t1", "Opus");
    assert_ne!(parent.ordinal, kid.ordinal);
    assert_ne!(parent.handle, kid.handle);
    pool.take("w", "s10", "Sonnet");
    pool.free("s1");
    assert_eq!(pool.get("agent:s1/t1"), None);
    assert!(
        pool.get("s10").is_some(),
        "another session's id is not a subagent's"
    );
}

/// Pattern D. Handles number per model: the first of a model goes by its name, the next ones by a number; a freed
/// number is given again; the monogram is the initial and that number.
#[test]
fn handles_count_per_model() {
    let pool = Pool::default();
    let got: Vec<(String, String)> = [
        ("a", "Opus"),
        ("b", "Opus"),
        ("c", "Sonnet"),
        ("d", "Opus"),
        ("e", "Sonnet"),
    ]
    .into_iter()
    .map(|(s, m)| {
        let i = pool.take("w", s, m);
        (i.handle, i.monogram)
    })
    .collect();
    let want = [
        ("Opus", "O"),
        ("Opus 2", "O2"),
        ("Sonnet", "S"),
        ("Opus 3", "O3"),
        ("Sonnet 2", "S2"),
    ]
    .map(|(h, m)| (h.to_string(), m.to_string()));
    assert_eq!(got, want);
    pool.free("b");
    assert_eq!(pool.take("w", "f", "Opus").handle, "Opus 2");
    assert_eq!(model_short(Some("claude-opus-4-1"), Some("claude")), "Opus");
    assert_eq!(model_short(Some("deepseek-chat"), None), "Deepseek");
    assert_eq!(model_short(Some("moonshotai/kimi-k2"), None), "Kimi");
    assert_eq!(model_short(None, Some("codex")), "Codex");
    assert_eq!(model_short(None, None), "Agent");
}
