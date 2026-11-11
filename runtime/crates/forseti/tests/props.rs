//! Properties of the scheduler core over generated inputs ([D] pure, proptest). No machine's real values appear.

use std::collections::HashMap;
use std::path::PathBuf;

use forseti::safety::{MAX_ABOVE_HIGH_MIB, STEP_MIB};
use forseti::*;
use proptest::prelude::*;

fn spec(name: &str) -> JobSpec {
    JobSpec {
        os: Default::default(),
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
    /// Tick after tick from the ceiling, whatever the machine does: `MemoryHigh` never passes the static ceiling,
    /// `MemoryMax` never passes it by more than 512 MiB, and `MemoryHigh ≤ MemoryMax` at every write.
    #[test]
    fn cap_never_exceeds_the_static_ceiling(
        dedicated in any::<bool>(),
        total in 8192u64..131_072,
        ticks in prop::collection::vec((0u64..131_072, 0u64..131_072), 1..40),
    ) {
        let profile = if dedicated { Profile::Dedicated } else { Profile::Workstation };
        let lim = Limits::for_profile(profile, total, 16);
        let ceiling = static_ceiling(profile, total);
        let (mut high, mut max) = (ceiling, ceiling);
        for (ours, avail) in ticks {
            let target = cap_target(ours, avail, lim.reserve_user_mib, lim.floor_mib, ceiling);
            prop_assert!(target <= ceiling);
            let w = cap_step(high, max, target, STEP_MIB);
            prop_assert!(w.high <= ceiling, "high {} over {ceiling}", w.high);
            prop_assert!(w.max <= ceiling + MAX_ABOVE_HIGH_MIB, "max {} over {ceiling} + 512", w.max);
            prop_assert!(w.high <= w.max);
            prop_assert!(w.max + STEP_MIB >= max, "max came down more than one step");
            (high, max) = (w.high, w.max);
        }
    }

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

const KEYS: [&str; 3] = ["K1", "K2", "K3"];

fn pick_keys(mask: u8) -> Vec<String> {
    KEYS.iter()
        .enumerate()
        .filter(|(i, _)| mask & (1 << i) != 0)
        .map(|(_, k)| k.to_string())
        .collect()
}

fn runner_trust(n: u8) -> RunnerTrust {
    [RunnerTrust::Mine, RunnerTrust::MyCloud, RunnerTrust::Shared][usize::from(n % 3)]
}

proptest! {
    #[test]
    fn a_job_never_goes_to_a_runner_its_trust_forbids(
        trust in 0u8..3,
        key_mask in 0u8..8,
        local_only in prop::bool::weighted(0.2),
        heavy in any::<bool>(),
        send in 0u8..3,
        cell in any::<bool>(),
        has_local in any::<bool>(),
        runners in prop::collection::vec((0u8..3, 0u8..8, 0u32..3600, any::<bool>()), 0..6),
    ) {
        let mut j = job("j", Priority::P3, 0);
        j.spec.trust = [JobTrust::Public, JobTrust::Private, JobTrust::PrivateKeys][usize::from(trust)];
        j.spec.keys = pick_keys(key_mask);
        j.spec.local_only = local_only;
        j.spec.weight = if heavy { Weight::Heavy } else { Weight::Light };
        let base = |name: String, local: bool, trust: RunnerTrust| Candidate {
            name,
            local,
            trust,
            keys_allowed: vec![],
            os: Default::default(),
            features: vec![],
            state: RunnerState::Ready,
            accept: Accept::All,
            link_bps: None,
            missing_bytes: 0,
            start_s: 0.0,
            wait_s: 0.0,
            speed: 1.0,
            history: vec![],
            cloud: None,
        };
        let mut cands = Vec::new();
        if has_local {
            cands.push(base("local".into(), true, RunnerTrust::Mine));
        }
        for (i, &(t, allowed, wait, accept_heavy)) in runners.iter().enumerate() {
            let mut c = base(format!("r{i}"), false, runner_trust(t));
            c.keys_allowed = pick_keys(allowed);
            c.wait_s = f64::from(wait);
            c.accept = if accept_heavy { Accept::Heavy } else { Accept::All };
            cands.push(c);
        }
        let ctx = PlaceCtx {
            eff: Priority::P3,
            send: [forseti::place::Send::All, forseti::place::Send::Heavy, forseti::place::Send::None][usize::from(send)],
            machines_cell_allows: cell,
            gates_allowed: false,
            cloud_after_s: 120.0,
            now: 0,
            commits_not_on_origin: 0,
        };
        match pick(&j, &cands, &ctx) {
            Pick::Runner(name) => {
                let c = cands.iter().find(|c| c.name == name).unwrap();
                prop_assert!(!c.local);
                prop_assert!(trust_ok(j.spec.trust, &j.spec.keys, c.trust, &c.keys_allowed),
                    "{:?} with keys {:?} went to {:?} allowed {:?}", j.spec.trust, j.spec.keys, c.trust, c.keys_allowed);
                prop_assert!(!j.spec.local_only);
            }
            Pick::Local => prop_assert!(has_local),
            Pick::Wait(_) => {}
        }
    }
}

/// Generated machines for backfill: per machine its available memory and running jobs `(reserve, current, end in s,
/// CPU in half cores)`; and a queue of `(priority, memory, CPU in half cores, expected s)`.
type Fleet = Vec<(u64, Vec<(u64, u64, u64, u8)>)>;
type Queue = Vec<(u8, u64, u8, u32)>;

const NOW: u64 = 1_000_000;

fn fleet() -> impl Strategy<Value = Fleet> {
    prop::collection::vec(
        (
            2000u64..40_000,
            prop::collection::vec((0u64..8000, 0u64..8000, 0u64..3600, 0u8..8), 0..5),
        ),
        1..4,
    )
}

fn queue() -> impl Strategy<Value = Queue> {
    prop::collection::vec((1u8..=5, 256u64..20_000, 1u8..16, 0u32..7200), 1..10)
}

struct Built2 {
    machines: Vec<MachineState>,
    ends: HashMap<JobId, u64>,
    order: Vec<(JobId, Need)>,
    eff: HashMap<JobId, Priority>,
    expected_s: HashMap<JobId, f64>,
}

fn limits16() -> Limits {
    Limits::for_profile(Profile::Dedicated, 65536, 16)
}

fn run_job(id: JobId, reserve: u64, current: u64, cpu: f64, minutes: f64) -> RunningJob {
    RunningJob {
        id,
        priority: Priority::P4,
        started: NOW - 1000,
        reserve_mib: reserve,
        current_mib: current,
        cores: 1,
        expected: Expected {
            minutes,
            cpu,
            mem_p95_mib: Some(reserve),
        },
        restartable: true,
        evicted_once: false,
        long_build: false,
    }
}

fn build_fleet(f: &Fleet, q: &Queue) -> Built2 {
    let mut ends = HashMap::new();
    let machines = f
        .iter()
        .enumerate()
        .map(|(i, (avail, running))| {
            let mut m = machine(Profile::Dedicated, *avail, NOW);
            m.name = format!("m{i}");
            m.running = running
                .iter()
                .enumerate()
                .map(|(k, &(reserve, current, end, cpu))| {
                    let id = JobId(format!("m{i}r{k}"));
                    ends.insert(id.clone(), NOW + end);
                    run_job(id, reserve, current, f64::from(cpu) / 2.0, 10.0)
                })
                .collect();
            m
        })
        .collect();
    let mut eff = HashMap::new();
    let mut expected_s = HashMap::new();
    let order = q
        .iter()
        .enumerate()
        .map(|(i, &(p, mem, cpu, secs))| {
            let id = JobId(format!("q{i}"));
            eff.insert(id.clone(), Priority::from_number(p));
            expected_s.insert(id.clone(), f64::from(secs));
            (
                id,
                Need {
                    mem_mib: mem,
                    cpu: f64::from(cpu) / 2.0,
                },
            )
        })
        .collect();
    Built2 {
        machines,
        ends,
        order,
        eff,
        expected_s,
    }
}

fn with_budgets(ms: &[MachineState]) -> Vec<(&MachineState, Budget)> {
    ms.iter().map(|m| (m, budget(m, &limits16()))).collect()
}

proptest! {
    /// Only the first job of the highest waiting priority reserves, so a reservation never holds a job of a higher
    /// priority than its own: a P1–P3 job is never held by P4 or P5 work. The same inputs, in any machine order,
    /// give the same reservation.
    #[test]
    fn no_priority_le_3_job_delayed_by_a_reservation(f in fleet(), q in queue()) {
        let b = build_fleet(&f, &q);
        let ms = with_budgets(&b.machines);
        let r = reservation(&b.order, &b.eff, &ms, &b.ends);
        let mut reversed = ms.clone();
        reversed.reverse();
        prop_assert_eq!(&reservation(&b.order, &b.eff, &reversed, &b.ends), &r);
        prop_assert_eq!(&reservation(&b.order, &b.eff, &ms, &b.ends), &r);
        let highest = b.order.iter().map(|(j, _)| b.eff[j]).max().unwrap();
        let head = b.order.iter().find(|(j, _)| b.eff[j] == highest).unwrap();
        let Some(r) = r else {
            // No reservation only when the head fits nowhere, even once every running job has ended.
            for (m, now_b) in &ms {
                let last = budget_at(m, now_b, &b.ends, u64::MAX);
                prop_assert!(last.mem_mib < head.1.mem_mib as i64 || last.cpu < head.1.cpu, "{} fits on {}", head.0, m.name);
            }
            return Ok(());
        };
        prop_assert_eq!(&r.job, &head.0);
        prop_assert_eq!(r.priority, highest);
        for (j, _) in &b.order {
            let p = b.eff[j];
            for m in &b.machines {
                let held = !backfill_ok(j, p, &m.name, b.expected_s[j], &r, NOW);
                prop_assert!(!held || p <= r.priority, "{j} ({p:?}) held by {:?}", r);
                prop_assert!(!held || p.number() > 3 || r.priority.number() <= 3);
            }
        }
    }

    /// What backfill starts on the reserved machine never moves the head's start: start every job it allows that
    /// fits now, and the head's reservation is unchanged.
    #[test]
    fn backfill_never_delays_the_heads_start(f in fleet(), q in queue()) {
        let mut b = build_fleet(&f, &q);
        let Some(r) = reservation(&b.order, &b.eff, &with_budgets(&b.machines), &b.ends) else {
            return Ok(());
        };
        let at = b.machines.iter().position(|m| m.name == r.machine).unwrap();
        let mut started = Vec::new();
        for (j, need) in &b.order {
            let secs = b.expected_s[j];
            let room = budget(&b.machines[at], &limits16());
            let fits = room.mem_mib >= need.mem_mib as i64 && room.cpu >= need.cpu;
            if *j == r.job || !fits || !backfill_ok(j, b.eff[j], &r.machine, secs, &r, NOW) {
                continue;
            }
            let mut rj = run_job(j.clone(), need.mem_mib, 0, need.cpu, secs / 60.0);
            rj.started = NOW;
            b.machines[at].running.push(rj);
            b.ends.insert(j.clone(), expected_end(NOW, secs));
            started.push(j.clone());
        }
        let left: Vec<(JobId, Need)> =
            b.order.iter().filter(|(j, _)| !started.contains(j)).cloned().collect();
        let again = reservation(&left, &b.eff, &with_budgets(&b.machines), &b.ends);
        prop_assert_eq!(again, Some(r), "after backfilling {:?}", started);
    }
}

fn cand(name: String, local: bool, trust: RunnerTrust) -> Candidate {
    Candidate {
        name,
        local,
        trust,
        keys_allowed: vec![],
        os: Default::default(),
        features: vec![],
        state: RunnerState::Ready,
        accept: Accept::All,
        link_bps: None,
        missing_bytes: 0,
        start_s: 0.0,
        wait_s: 0.0,
        speed: 1.0,
        history: vec![],
        cloud: None,
    }
}

fn hist(machine: &str, wall_s: f64, warm: bool, at: u64, disturbed: bool) -> HistRow {
    HistRow {
        key: "k".into(),
        machine: machine.into(),
        grant: Grant {
            cores: 1,
            mem_cap_mib: 1024,
            reserve_mib: 1024,
        },
        wall_s,
        cpu_s: wall_s,
        mem_peak_mib: 512,
        verdict: Verdict::Pass,
        disturbed,
        at,
        warm,
    }
}

/// A generated runner: trust, allowed keys, wait, accepts heavy only, cloud terms (none, or whether the projection
/// fits), benched, missing bytes, a measured link rate.
type GenRunner = (u8, u8, u32, bool, Option<bool>, bool, u32, Option<u32>);

fn gen_runner() -> impl Strategy<Value = GenRunner> {
    (
        0u8..3,
        0u8..8,
        0u32..3600,
        prop::bool::weighted(0.2),
        prop::option::weighted(0.3, any::<bool>()),
        prop::bool::weighted(0.15),
        0u32..2_000_000_000,
        prop::option::of(1u32..2_000_000_000),
    )
}

proptest! {
    /// Learning changes estimates only: the trust filter, the pin, the modes, the runner's state and the cloud's
    /// terms hold whatever was learned. With nothing learned and no warmth known it is the static rule, with no
    /// history every estimate is the default, and the same inputs give the same pick whatever order they were
    /// learned in.
    #[test]
    fn rules_still_hold_under_learning(
        trust in 0u8..3,
        key_mask in 0u8..8,
        local_only in prop::bool::weighted(0.2),
        heavy in any::<bool>(),
        eff in 1u8..=5,
        send in 0u8..3,
        cell in any::<bool>(),
        has_local in any::<bool>(),
        runners in prop::collection::vec(gen_runner(), 0..5),
        rows in prop::collection::vec((0usize..6, 1u32..3600, any::<bool>(), 0u64..100, prop::bool::weighted(0.2)), 0..12),
        links in prop::collection::vec((0usize..6, 1u32..2_000_000_000), 0..6),
        speeds in prop::collection::vec((0usize..6, 0usize..6, 1u32..60), 0..8),
        warm_bits in 0u8..64,
    ) {
        let mut j = job("j", Priority::from_number(eff), 0);
        j.spec.trust = [JobTrust::Public, JobTrust::Private, JobTrust::PrivateKeys][usize::from(trust)];
        j.spec.keys = pick_keys(key_mask);
        j.spec.local_only = local_only;
        j.spec.weight = if heavy { Weight::Heavy } else { Weight::Light };
        let send = [forseti::place::Send::All, forseti::place::Send::Heavy, forseti::place::Send::None][usize::from(send)];
        let mut cands = Vec::new();
        if has_local {
            cands.push(cand("local".into(), true, RunnerTrust::Mine));
        }
        for (i, &(t, allowed, wait, accept_heavy, cloud, benched, missing, link)) in runners.iter().enumerate() {
            let mut c = cand(format!("r{i}"), false, runner_trust(t));
            c.keys_allowed = pick_keys(allowed);
            c.wait_s = f64::from(wait);
            c.accept = if accept_heavy { Accept::Heavy } else { Accept::All };
            c.cloud = cloud.map(|projection_ok| CloudTerms { projection_ok, cap: "cap".into() });
            if benched {
                c.state = RunnerState::Benched("disk".into());
            }
            c.missing_bytes = u64::from(missing);
            c.link_bps = link.map(f64::from);
            c.speed = 1.0 + (i as f64) / 4.0;
            cands.push(c);
        }
        let names: Vec<String> = cands.iter().map(|c| c.name.clone()).chain(["gone".to_string()]).collect();
        let name = |i: usize| names[i % names.len()].clone();
        let history: Vec<HistRow> = rows
            .iter()
            .map(|&(m, wall, warm, at, disturbed)| hist(&name(m), f64::from(wall), warm, at, disturbed))
            .collect();
        for c in &mut cands {
            c.history = history.clone();
        }
        // Each key learned once (the last value wins), then inserted forwards and backwards.
        let link_vals: std::collections::BTreeMap<String, f64> =
            links.iter().map(|&(i, bps)| (name(i), f64::from(bps))).collect();
        let speed_vals: std::collections::BTreeMap<(String, String), f64> =
            speeds.iter().map(|&(a, b, r)| ((name(a), name(b)), f64::from(r) / 10.0)).collect();
        let learn = |rev: bool| {
            let mut l = Learned::default();
            let mut ls: Vec<_> = link_vals.iter().collect();
            let mut ss: Vec<_> = speed_vals.iter().collect();
            if rev {
                ls.reverse();
                ss.reverse();
            }
            for (k, v) in ls {
                l.link_bps.insert(k.clone(), Ewma { value: Some(*v) });
            }
            for (k, v) in ss {
                l.speed.insert(k.clone(), Ewma { value: Some(*v) });
            }
            l
        };
        let learned = learn(false);
        let warm_of = |c: &Candidate| {
            let i = names.iter().position(|n| *n == c.name).unwrap();
            Some(Warmth { slot_near: warm_bits & (1 << i) != 0, images_present: warm_bits & (1 << ((i + 3) % 6)) != 0 })
        };
        let ctx = PlaceCtx {
            eff: Priority::from_number(eff),
            send,
            machines_cell_allows: cell,
            gates_allowed: false,
            cloud_after_s: 120.0,
            now: 0,
            commits_not_on_origin: 0,
        };
        let got = pick_with(&j, &cands, &ctx, &learned, &warm_of);
        prop_assert_eq!(&pick_with(&j, &cands, &ctx, &learn(true), &warm_of), &got);
        prop_assert_eq!(&pick_with(&j, &cands, &ctx, &learned, &warm_of), &got);
        let total = |c: &Candidate| finish_with(&j, c, 0, &learned, warm_of(c)).total_s;
        let passes = |c: &Candidate| filter(&j, c, send, cell).is_ok();
        let best_own = cands
            .iter()
            .filter(|c| c.cloud.is_none() && passes(c))
            .map(total)
            .fold(f64::INFINITY, f64::min);
        match &got {
            Pick::Runner(n) => {
                let c = cands.iter().find(|c| c.name == *n).unwrap();
                prop_assert!(!c.local && passes(c));
                prop_assert!(trust_ok(j.spec.trust, &j.spec.keys, c.trust, &c.keys_allowed));
                prop_assert!(!j.spec.local_only);
                if let Some(terms) = &c.cloud {
                    prop_assert!(terms.projection_ok && eff <= 3);
                    prop_assert!(best_own - total(c) >= 120.0);
                }
            }
            Pick::Local => prop_assert!(has_local && passes(&cands[0])),
            Pick::Wait(_) => prop_assert!(best_own.is_infinite(), "an own machine passed but the job waits"),
        }
        // Nothing learned and no warmth known: exactly the static rule.
        prop_assert_eq!(pick_with(&j, &cands, &ctx, &Learned::default(), &|_| None), pick(&j, &cands, &ctx));
        // No history: every estimate is the default, whatever was learned.
        for c in &cands {
            let mut bare = c.clone();
            bare.history.clear();
            prop_assert_eq!(finish_with(&j, &bare, 0, &learned, warm_of(c)).expected_s, history::DEFAULT_MINUTES * 60.0);
        }
    }
}

proptest! {
    /// Within one priority every project's first job comes within a bound set by the use gaps and weights alone,
    /// however many jobs the other projects queue; each project keeps its own order and nothing is lost.
    #[test]
    fn nothing_starves_under_fairness(
        projects in prop::collection::vec((0u32..7200, 1u32..8), 1..5),
        jobs in prop::collection::vec(0usize..5, 1..60),
    ) {
        let np = projects.len();
        let order: Vec<JobId> = jobs.iter().enumerate().map(|(i, p)| JobId(format!("{}-{i}", p % np))).collect();
        let eff: HashMap<JobId, Priority> = order.iter().map(|j| (j.clone(), Priority::P4)).collect();
        let project = |j: &JobId| j.0.split('-').next().unwrap().to_string();
        let usage: HashMap<String, f64> = projects.iter().enumerate().map(|(i, (u, _))| (i.to_string(), f64::from(*u))).collect();
        let weights: HashMap<String, f64> = projects.iter().enumerate().map(|(i, (_, w))| (i.to_string(), f64::from(*w) / 2.0)).collect();
        let mut drr = Drr::default();
        let q = drr.quantum_s;
        let out = drr.order(&order, &eff, &project, &usage, &weights);
        let mut sorted_in = order.clone();
        sorted_in.sort();
        let mut sorted_out = out.clone();
        sorted_out.sort();
        prop_assert_eq!(sorted_in, sorted_out);
        let of = |v: &[JobId], p: &str| v.iter().filter(|j| project(j) == p).cloned().collect::<Vec<_>>();
        let present: std::collections::BTreeSet<String> = order.iter().map(&project).collect();
        let credit = |p: &str| usage[p] / weights[p];
        for p in &present {
            prop_assert_eq!(of(&order, p), of(&out, p), "project {} reordered", p);
            let bound: f64 = present
                .iter()
                .filter(|o| *o != p && credit(o) <= credit(p))
                // + 1e-6: the charges add up in floating point, so a gap of exactly k charges may allow k + 1 picks
                .map(|o| ((credit(p) - credit(o)) * weights[o.as_str()] / q + 1e-6).floor() + 1.0)
                .sum();
            let first = out.iter().position(|j| &project(j) == p).unwrap();
            prop_assert!(first as f64 <= bound + 1e-9, "project {}'s first job at {} over {}", p, first, bound);
        }
    }
}
