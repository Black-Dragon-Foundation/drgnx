//! Properties of the scheduler core over generated inputs ([D] pure, proptest). No machine's real values appear.

use std::collections::HashMap;
use std::path::PathBuf;

use forseti::*;
use proptest::prelude::*;

fn spec(name: &str) -> JobSpec {
    JobSpec {
        name: name.into(),
        kind: Kind::Test,
        weight: Weight::Light,
        suite: None,
        tree: PathBuf::from("/src/project"),
        cwd: PathBuf::from("."),
        command: vec!["make".into(), "check".into()],
        select: None,
        needs: vec![],
        inputs_extra: vec![],
        inputs_outside: vec![],
        features: vec![],
        cores: Range { min: 1, max: 4 },
        mem_mib: Range {
            min: 1024,
            max: 4096,
        },
        disk_gib: 1,
        timeout_s: 1200,
        restartable: true,
        writes_tree: false,
        priority: None,
        for_user: None,
        gate: None,
        expect: Expect::default(),
        outputs: vec![],
        state: vec![],
        on: None,
        lane: Lane::Work,
        fresh: false,
        stop_on_red: false,
        project: "alpha".into(),
        trust: JobTrust::Private,
        keys: vec![],
        local_only: false,
        writes: vec![],
    }
}

fn job(name: &str, own: Priority, submitted: u64) -> Job {
    Job {
        id: JobId(name.into()),
        spec: spec(name),
        own,
        submitted,
        state: JobState::Queued,
        attempt: 1,
        evicted_once: false,
        disturbed: false,
        blocked_caller: false,
    }
}

fn id(i: usize) -> JobId {
    JobId(format!("j{i}"))
}

/// A generated graph: per job its own priority, user and blocked flags and the earlier jobs it needs; plus locks
/// (`lock k` held by a job) and waits on them.
#[derive(Clone, Debug)]
struct Graph {
    own: Vec<(u8, bool, bool, Vec<usize>)>,
    locks: Vec<(usize, usize)>,
    waits: Vec<(usize, usize)>,
}

fn graph() -> impl Strategy<Value = Graph> {
    (1usize..12).prop_flat_map(|n| {
        let jobs = prop::collection::vec(
            (
                1u8..=5,
                prop::bool::weighted(0.1),
                prop::bool::weighted(0.15),
                prop::collection::vec(0usize..n, 0..3),
            ),
            n,
        );
        let locks = prop::collection::vec((0usize..4, 0usize..n), 0..3);
        let waits = prop::collection::vec((0usize..n, 0usize..4), 0..4);
        (jobs, locks, waits).prop_map(|(own, locks, waits)| Graph { own, locks, waits })
    })
}

type Built = (Vec<Job>, Vec<(PathBuf, JobId)>, Vec<(JobId, PathBuf)>);

fn build(g: &Graph) -> Built {
    let jobs = g
        .own
        .iter()
        .enumerate()
        .map(|(i, (p, user, blocked, needs))| {
            let mut j = job(&id(i).0, Priority::from_number(*p), 0);
            j.spec.for_user = user.then(|| "the user asked".to_string());
            j.blocked_caller = *blocked;
            // Needs point at earlier jobs only, so the graph has no cycle.
            j.spec.needs = needs.iter().filter(|&&t| t < i).map(|&t| id(t)).collect();
            j
        })
        .collect();
    let path = |k: usize| PathBuf::from(format!("/lock/{k}"));
    let mut seen = std::collections::BTreeSet::new();
    let locks = g
        .locks
        .iter()
        .filter(|(k, _)| seen.insert(*k))
        .map(|&(k, h)| (path(k), id(h)))
        .collect();
    let waits = g.waits.iter().map(|&(w, k)| (id(w), path(k))).collect();
    (jobs, locks, waits)
}

proptest! {
    #[test]
    fn inheritance_is_monotone(g in graph(), lift in any::<prop::sample::Index>(), to in 1u8..=5) {
        let (jobs, locks, waits) = build(&g);
        let eff = effective_priorities(&jobs, &locks, &waits);
        for j in &jobs {
            prop_assert!(eff[&j.id] >= j.own, "{} fell below its own priority", j.id);
            for t in &j.spec.needs {
                prop_assert!(eff[t] >= eff[&j.id], "{t} is below its waiter {}", j.id);
            }
        }
        for (w, path) in &waits {
            if let Some((_, h)) = locks.iter().find(|(p, _)| p == path) {
                prop_assert!(eff[h] >= eff[w], "lock holder {h} is below its waiter {w}");
            }
        }
        // Raising one job's own priority never lowers anyone's.
        let mut lifted = jobs.clone();
        let i = lift.index(lifted.len());
        lifted[i].own = lifted[i].own.max(Priority::from_number(to));
        let eff2 = effective_priorities(&lifted, &locks, &waits);
        for j in &jobs {
            prop_assert!(eff2[&j.id] >= eff[&j.id], "lifting {} lowered {}", lifted[i].id, j.id);
        }
    }
}

/// One job a minute arrives (P2–P5) and one starts: the queue stays as long as its backlog, and higher work never
/// stops coming. Promotion and aging still start every job within three promotions, its expected time and the
/// backlog.
#[derive(Clone, Debug)]
struct Load {
    backlog: Vec<(u8, u32)>,
    arrivals: Vec<(u8, u32)>,
}

const TICK: u64 = 60;
const E_MAX: u32 = 60;

fn load() -> impl Strategy<Value = Load> {
    let one = (2u8..=5, 1u32..=E_MAX);
    (
        prop::collection::vec(one.clone(), 1..16),
        prop::collection::vec(one, 600),
    )
        .prop_map(|(backlog, arrivals)| Load { backlog, arrivals })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]
    #[test]
    fn no_starvation(l in load()) {
        let b = l.backlog.len() as u64;
        let bound = 3 * 3600 + u64::from(E_MAX) * 60 + (b + u64::from(E_MAX) + 2) * TICK;
        let mut minutes: HashMap<JobId, f64> = HashMap::new();
        let mut queue: Vec<Job> = Vec::new();
        let mut arrived: HashMap<JobId, u64> = HashMap::new();
        let mut started: HashMap<JobId, u64> = HashMap::new();
        let mut n = 0usize;
        let mut add = |queue: &mut Vec<Job>, minutes: &mut HashMap<JobId, f64>, (p, e): (u8, u32), at: u64| {
            let j = job(&id(n).0, Priority::from_number(p), at);
            n += 1;
            minutes.insert(j.id.clone(), f64::from(e));
            arrived.insert(j.id.clone(), at);
            queue.push(j);
        };
        for &x in &l.backlog {
            add(&mut queue, &mut minutes, x, 0);
        }
        let ticks = l.arrivals.len() as u64;
        for (t, &x) in l.arrivals.iter().enumerate() {
            let now = t as u64 * TICK;
            add(&mut queue, &mut minutes, x, now);
            let exp = |j: &JobId| Expected { minutes: minutes[j], cpu: 1.0, mem_p95_mib: Some(512) };
            let order = queue_order(&queue, &HashMap::new(), &exp, now);
            let head = order[0].clone();
            queue.retain(|j| j.id != head);
            started.insert(head, now);
        }
        let end = ticks * TICK;
        for (j, a) in &arrived {
            match started.get(j) {
                Some(s) => prop_assert!(s - a <= bound, "{j} waited {} s, over {bound}", s - a),
                None => prop_assert!(end - a <= bound, "{j} still waits after {} s, over {bound}", end - a),
            }
        }
    }
}
