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

fn machine(profile: Profile, avail: u64, now: u64) -> MachineState {
    MachineState {
        name: "m".into(),
        profile,
        now,
        boot_id: "boot-a".into(),
        mem_total_mib: avail + 8192,
        mem_available_mib: avail,
        psi: Psi::default(),
        disk_free_gb: 500,
        disk_total_gb: 1000,
        on_ac: true,
        last_start: None,
        running: vec![],
        features: vec![],
        reachable: true,
        others: vec![],
    }
}

fn running(
    name: &str,
    priority: Priority,
    started: u64,
    grant: &Grant,
    minutes: f64,
) -> RunningJob {
    RunningJob {
        id: JobId(name.into()),
        priority,
        started,
        reserve_mib: grant.reserve_mib,
        current_mib: 0,
        cores: grant.cores,
        expected: Expected {
            minutes,
            cpu: 0.0,
            mem_p95_mib: Some(0),
        },
        restartable: true,
        evicted_once: false,
        long_build: false,
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

/// Two schedulers on one machine, each admitting under the shared admission lock: each sees the other's jobs only as
/// reservations (`MachineState.others`), counted by `count_others`. `worst` is the most both have reserved at once.
#[derive(Clone, Debug)]
struct Two {
    profile: Profile,
    avail: u64,
    now: u64,
    ours: [Vec<RunningJob>; 2],
    worst: i64,
}

const NAMES: [&str; 2] = ["hub", "jobq"];

impl Two {
    fn new(profile: Profile, avail: u64) -> Self {
        Two {
            profile,
            avail,
            now: 100_000,
            ours: [vec![], vec![]],
            worst: 0,
        }
    }

    fn limits(&self) -> Limits {
        Limits::for_profile(self.profile, self.avail + 8192, 64)
    }

    /// What may be reserved in all: `MemAvailable − floor − reserve_user` (nothing is in use yet).
    fn limit(&self) -> i64 {
        let l = self.limits();
        self.avail as i64 - l.floor_mib as i64 - l.reserve_user_mib as i64
    }

    fn view(&self, s: usize) -> MachineState {
        let mut m = machine(self.profile, self.avail, self.now);
        m.running = self.ours[s].clone();
        m.others = self.ours[1 - s]
            .iter()
            .map(|r| Reservation {
                scheduler: NAMES[1 - s].into(),
                pid: 100 + s as u32,
                boot_id: "boot-a".into(),
                start_time: 1,
                job: r.id.0.clone(),
                reserve_mib: r.reserve_mib,
                current_mib: r.current_mib,
                expires: self.now + 3600,
            })
            .collect();
        m
    }

    fn try_admit(&mut self, s: usize, name: &str, mem: Range<u64>, p95: Option<u64>) -> bool {
        let lim = self.limits();
        let m = self.view(s);
        let b = budget(&m, &lim);
        let mut j = job(name, Priority::P3, self.now);
        j.spec.mem_mib = mem;
        j.spec.cores = Range { min: 1, max: 1 };
        let exp = Expected {
            minutes: 10.0,
            cpu: 0.1,
            mem_p95_mib: p95,
        };
        if admit(&j, Priority::P3, &exp, &m, &b, &lim).is_err() {
            return false;
        }
        let g = size(&j, &exp, &b, 1);
        self.ours[s].push(running(name, Priority::P3, self.now, &g, 10.0));
        let total: i64 = self
            .ours
            .iter()
            .flatten()
            .map(|r| r.reserve_mib as i64)
            .sum();
        self.worst = self.worst.max(total);
        true
    }
}

proptest! {
    #[test]
    fn admitted_reservations_never_exceed_the_budget(
        dedicated in any::<bool>(),
        avail in 4000u64..64_000,
        jobs in prop::collection::vec((0usize..2, 256u64..8192, 0u64..8192, prop::option::of(0u64..12_000)), 1..24),
    ) {
        let profile = if dedicated { Profile::Dedicated } else { Profile::Workstation };
        let mut two = Two::new(profile, avail);
        for (i, (s, min, extra, p95)) in jobs.into_iter().enumerate() {
            two.try_admit(s, &format!("j{i}"), Range { min, max: min + extra }, p95);
        }
        prop_assert!(two.worst <= two.limit().max(0), "reserved {} of {}", two.worst, two.limit());
    }
}

#[derive(Clone, Debug)]
enum Ev {
    Admit(usize, &'static str),
    Finish(usize, &'static str),
}
skuld::events!(Ev { Admit, Finish });

impl skuld::Core for Two {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let mem = |name: &str| match name {
            "a" | "b" => (
                Range {
                    min: 4000,
                    max: 6000,
                },
                Some(3000),
            ),
            _ => (
                Range {
                    min: 3000,
                    max: 3000,
                },
                None,
            ),
        };
        match ev {
            Ev::Admit(s, name) => {
                let (range, p95) = mem(name);
                self.try_admit(s, name, range, p95);
            }
            Ev::Finish(s, name) => self.ours[s].retain(|r| r.id.0 != name),
        }
        vec![]
    }
}

/// [A] every order: the hub admits a and b and finishes a while jobq admits x and y, each admission under the lock,
/// in every interleaving. However they fall, what both reserve stays within one machine's budget.
#[test]
fn admissions_in_every_order_stay_in_the_budget() {
    let mut p = skuld::Partial::new();
    p.source(
        "hub",
        vec![Ev::Admit(0, "a"), Ev::Admit(0, "b"), Ev::Finish(0, "a")],
    );
    p.source("jobq", vec![Ev::Admit(1, "x"), Ev::Admit(1, "y")]);
    let report = skuld::every_order(
        &p,
        skuld::Bound::default(),
        || Two::new(Profile::Dedicated, 12_000),
        |two, order| {
            if two.worst > two.limit() {
                return Err(format!(
                    "{order:?}: reserved {} of {}",
                    two.worst,
                    two.limit()
                ));
            }
            Ok(())
        },
    );
    assert_eq!(report.mode, skuld::Mode::Exhaustive);
}

proptest! {
    #[test]
    fn a_job_is_evicted_at_most_once(
        jobs in prop::collection::vec((1u8..=5, 0u64..1200, 1u32..30, any::<bool>(), prop::bool::weighted(0.2), 256u64..4096), 1..12),
        rounds in prop::collection::vec((0u64..600, 100u64..20_000), 1..6),
    ) {
        let mut m = machine(Profile::Dedicated, 32_000, 100_000);
        let mut evicted = std::collections::HashSet::new();
        m.running = jobs
            .iter()
            .enumerate()
            .map(|(i, &(p, age, minutes, restartable, once, mib))| {
                let g = Grant { cores: 1, mem_cap_mib: mib, reserve_mib: mib };
                let mut r = running(&id(i).0, Priority::from_number(p), m.now - age, &g, f64::from(minutes));
                r.current_mib = mib / 2;
                r.restartable = restartable;
                r.evicted_once = once;
                if once {
                    evicted.insert(r.id.clone());
                }
                r
            })
            .collect();
        for (dt, need) in rounds {
            m.now += dt;
            for v in preempt_victims(Priority::P1, &m, need, m.now, true) {
                prop_assert!(evicted.insert(v.clone()), "{v} evicted twice");
                let r = m.running.iter_mut().find(|r| r.id == v).unwrap();
                // Requeued and started again: it remembers the eviction.
                r.evicted_once = true;
                r.started = m.now;
            }
        }
    }
}
