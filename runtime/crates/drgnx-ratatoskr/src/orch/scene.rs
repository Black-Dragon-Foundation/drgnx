//! One plan run seeded into a test hub (test-hooks; `RATATOSKR_SEED_SCENE=1` at `serve`), for the look scenes of the
//! Work space (docs/develop/harness.md, "Look scenes"): a paused job with a rule pack, tasks in each gate state, their
//! evidence, a held `gate` card and a merge batch.  The job is paused, so the runner starts no agent for it.  The run
//! is described here as data ([`run`]) and written through the store's own writers ([`seed`]).

use crate::front::Front;
use serde_json::json;
use vordr::batch::Ready;
use vordr::evidence::Evidence;
use vordr::facts::Facts;
use vordr::pack::{Check, Pack, Rule};

/// The seeded job's id.
pub const JOB: &str = "scene-run";

/// One seeded task: its number, title, status, agent, evidence and whether it is in the batch.
pub(crate) struct SeedTask {
    pub n: i64,
    pub title: &'static str,
    pub status: &'static str,
    pub agent: Option<&'static str>,
    pub evidence: Vec<Evidence>,
    pub batch: bool,
}

/// The seeded run: its pack, its tasks, the task a gate holds and why.
pub(crate) struct Run {
    pub pack: Pack,
    pub tasks: Vec<SeedTask>,
    pub held: (i64, &'static str),
}

/// The pack's author check.
fn build() -> Check {
    Check {
        name: "build".into(),
        dir: String::new(),
        run: vec!["bin/drgnx".into(), "build".into()],
    }
}

fn pack() -> Pack {
    let rule = |id: &str, kind: &str, doc: &str| Rule {
        id: id.into(),
        kind: kind.into(),
        doc: doc.into(),
    };
    Pack {
        name: "scene-pack".into(),
        version: 1,
        rules: vec![
            rule(
                "red-first",
                "enforced",
                "The test commit fails, the tip passes",
            ),
            rule(
                "author-check",
                "enforced",
                "Compile, own tests, rule tests before ready to merge",
            ),
            rule(
                "affected-groups",
                "enforced",
                "Affected groups green before a merge; batches of 3",
            ),
            rule(
                "merge-notes",
                "checked",
                "Merges resolved by both commits' intent",
            ),
            rule(
                "push-gate",
                "enforced",
                "One full Linux run on the exact commit before a push",
            ),
            rule("review", "routing", "One review per finished plan"),
        ],
        batch_size: 3,
        author_check: vec![build()],
        push_tiers: vec![check("unit"), check("gui"), check("scenario")],
        groups: vec!["bin/drgnx".into(), "affected".into(), "%r".into()],
        ..Pack::default()
    }
}

/// A test tier or group NAME.
fn check(name: &str) -> Check {
    Check {
        name: name.into(),
        dir: String::new(),
        run: vec!["bin/drgnx".into(), "test".into(), name.into()],
    }
}

/// The batch's combined tree and the line's head tree the seeded gates judged.
pub const BATCH_TREE: &str = "b47c9e1a";
pub const LINE_HEAD: &str = "9c41e07";
pub const LINE_TREE: &str = "e4a07f3c";

/// A gate's run: CHECK on MACHINE for KEY (`batch:JOB@TREE`, `push:JOB@TREE`) at TREE, passing or not.
fn gate_ev(key: &str, tree: &str, machine: &str, c: &Check, ok: bool, at: f64) -> Evidence {
    Evidence {
        kind: if ok { "green" } else { "red" }.into(),
        task: key.into(),
        job: format!("gate{at}"),
        facts: Facts {
            tree_key: tree.into(),
            env_stamp: "scene".into(),
            platform: format!("linux-x86_64/{machine}"),
            selector: vordr::gates::selector_of(c),
        },
        rows: vordr::rows::parse(if ok {
            "test all::rows ... ok\n"
        } else {
            "test all::rows ... FAILED\n"
        }),
        truncated: false,
        at,
        note: None,
    }
}

/// The batch's affected groups and their runs, then the push tiers' runs at the line's head: the groups green on the
/// desktop but one red on the second runner; every tier green.
pub(crate) fn gate_runs() -> (Vec<Check>, Vec<Evidence>) {
    let groups = vec![check("unit"), check("ert:search"), check("hub:view")];
    let b = format!("batch:{JOB}@{BATCH_TREE}");
    let p = format!("push:{JOB}@{LINE_TREE}");
    let mut ev = vec![
        gate_ev(&b, BATCH_TREE, "desktop", &groups[0], true, 30.0),
        gate_ev(&b, BATCH_TREE, "desktop", &groups[1], true, 31.0),
        gate_ev(&b, BATCH_TREE, "runner-1", &groups[2], false, 32.0),
    ];
    for (i, t) in pack().push_tiers.iter().enumerate() {
        ev.push(gate_ev(&p, LINE_TREE, "desktop", t, true, 40.0 + i as f64));
    }
    (groups, ev)
}

/// Evidence of task N: KIND, run SELECTOR, ROWS (cargo test lines), at AT.
fn ev(n: i64, kind: &str, selector: &str, rows: &str, at: f64) -> Evidence {
    Evidence {
        kind: kind.into(),
        task: format!("{JOB}#{n}"),
        job: format!("88{n}{}", at as i64),
        facts: Facts {
            tree_key: format!("{n:07}{}", at as i64),
            env_stamp: "scene".into(),
            platform: "linux-x86_64/local".into(),
            selector: selector.into(),
        },
        rows: vordr::rows::parse(rows),
        truncated: false,
        at,
        note: None,
    }
}

/// The run (the mockup's: hub-orchestration.html).
pub(crate) fn run() -> Run {
    let own = "runtime\ncargo test -p drgnx-search";
    let b = vordr::gates::selector_of(&build());
    let red = |n| {
        ev(
            n,
            "red",
            own,
            "test s::a ... FAILED\ntest s::b ... FAILED\ntest s::c ... FAILED\n",
            10.0,
        )
    };
    let tip = |n| {
        ev(
            n,
            "green",
            own,
            "test s::a ... ok\ntest s::b ... ok\ntest s::c ... ok\n",
            20.0,
        )
    };
    let built = |n| ev(n, "green", &b, "test build::all ... ok\n", 21.0);
    let task = |n, title, status, agent, evidence, batch| SeedTask {
        n,
        title,
        status,
        agent,
        evidence,
        batch,
    };
    Run {
        pack: pack(),
        tasks: vec![
            task(
                0,
                "Base, baselines, fixture",
                "in-review",
                Some("Sonnet"),
                vec![red(0), tip(0), built(0)],
                true,
            ),
            task(
                1,
                "search/run and ids",
                "done",
                Some("Opus"),
                vec![red(1), tip(1), built(1)],
                false,
            ),
            task(
                2,
                "Open buffers in the model",
                "in-review",
                Some("Sonnet"),
                vec![red(2), tip(2), built(2)],
                true,
            ),
            task(
                3,
                "Mode chip; Symbol, Meaning",
                "in-review",
                Some("Sonnet"),
                vec![red(3), tip(3), built(3)],
                true,
            ),
            task(
                4,
                "Context label rows",
                "in-review",
                Some("Sonnet"),
                vec![
                    red(4),
                    tip(4),
                    ev(4, "red", &b, "test build::all ... FAILED\n", 22.0),
                ],
                false,
            ),
            task(
                5,
                "Git scopes, changed lines",
                "needs-input",
                Some("Sonnet"),
                vec![tip(5)],
                false,
            ),
            task(
                6,
                "Keys, docs, perf rows",
                "running",
                Some("Sonnet"),
                vec![],
                false,
            ),
            task(8, "Saved and recent", "open", None, vec![], false),
        ],
        held: (5, "no red for its test commit"),
    }
}

/// Write the run into FRONT's store and its merge queue.  Each write is the hub's (class system), as the gates' are.
pub async fn seed(front: &Front) -> Result<(), String> {
    let r = run();
    let now = crate::clock::wall_secs();
    let meta = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "orch/scene");
    let batch: Vec<i64> = r.tasks.iter().filter(|t| t.batch).map(|t| t.n).collect();
    let (groups, gate_ev) = gate_runs();
    let Run { pack, tasks, held } = r;
    front
        .writer
        .db
        .write(meta, move |tx| {
            use norn::write::jobs::{NewJob, NewTask, job_create, job_set};
            job_create(
                tx,
                NewJob {
                    id: JOB.into(),
                    title: "Search view · .6 part".into(),
                    plan: Some("docs/plans/search-view.md".into()),
                    repo: None,
                    tasks: tasks
                        .iter()
                        .map(|t| NewTask {
                            n: t.n,
                            title: t.title.into(),
                            role: Some("worker".into()),
                            deps: vec![],
                        })
                        .collect(),
                    data: None,
                },
                now,
            )?;
            job_set(tx, JOB, Some("paused"), None, now)?;
            norn::write::evidence::rule_pack(tx, JOB, &pack, None)?;
            for t in &tasks {
                let id = format!("{JOB}#{}", t.n);
                norn::write::tasks::force_status(tx, &id, t.status, t.agent, now)?;
                for e in &t.evidence {
                    norn::write::evidence::record(tx, e, None)?;
                }
            }
            norn::write::cards::card_create(
                tx,
                norn::write::cards::NewCard {
                    job: Some(JOB.into()),
                    task: Some(format!("{JOB}#{}", held.0)),
                    kind: Some("gate".into()),
                    title: Some(format!("the gates hold the merge: {}", held.1)),
                    data: Some(json!({"key": "gates", "tip": "7d21c0e"})),
                },
                now,
            )?;
            for e in &gate_ev {
                norn::write::evidence::record(tx, e, None)?;
            }
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?;
    // the batch as the queue holds it: the first member's trial merge was clean, the others wait for it
    let ready: Vec<Ready> = batch
        .iter()
        .map(|n| Ready {
            task: format!("{JOB}#{n}"),
            tip: format!("{:07x}", 0x7d21c0 + n),
            at: now + *n as f64,
        })
        .collect();
    front.queue.seed(JOB, ready.clone());
    for (i, r) in ready.iter().enumerate() {
        let said = if i == 0 {
            "trial merge clean".to_owned()
        } else {
            format!("{} merges first", ready[0].task)
        };
        front.queue.say(JOB, &r.task, &said);
    }
    front.queue.at_groups(JOB, BATCH_TREE, groups);
    front.queue.at_push(JOB, LINE_HEAD, LINE_TREE);
    front.writer.signals.wrote();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work::trail::flow::{Chip, Queue, TaskFacts, cells};

    /// [D] The seeded run shows every chip state the Flow has: passed, running, held, failed and waiting, and the
    /// review gate the pack routes; the held task is the one with the card.
    #[test]
    fn the_seeded_run_shows_every_chip_state() {
        let r = run();
        let mut seen = Vec::new();
        for t in &r.tasks {
            let f = TaskFacts {
                id: format!("{JOB}#{}", t.n),
                n: t.n,
                title: t.title.into(),
                status: t.status.into(),
                agent: t.agent.map(str::to_owned),
                evidence: t.evidence.clone(),
                queue: if t.batch { Queue::Batch } else { Queue::None },
                held: (t.n == r.held.0).then(|| r.held.1.to_owned()),
                card: None,
            };
            seen.extend(cells(&f, Some(&r.pack)).map(|c| c.chip));
        }
        for chip in [Chip::Ok, Chip::Run, Chip::Held, Chip::Err, Chip::Wait] {
            assert!(seen.contains(&chip), "no {chip:?} in {seen:?}");
        }
        assert!(r.pack.problems().is_empty(), "{:?}", r.pack.problems());
        assert_eq!(r.tasks.iter().filter(|t| t.batch).count(), 3);
        // the gates' runs: the groups at the batch's tree on two machines, one red; every push tier at the line's
        let (groups, ev) = gate_runs();
        assert_eq!(groups.len(), 3);
        let batch: Vec<&Evidence> = ev.iter().filter(|e| e.task.starts_with("batch:")).collect();
        assert!(batch.iter().all(|e| e.facts.tree_key == BATCH_TREE));
        assert!(batch.iter().any(|e| e.kind == "red"));
        let push = ev.iter().filter(|e| e.task.starts_with("push:")).count();
        assert_eq!(push, r.pack.push_tiers.len());
    }
}
