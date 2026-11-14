//! Placement: the hard filters (trust and pin, features, state, modes, the matrix cell), the finish-time estimate,
//! the cloud's terms, and the pick.

use serde::{Deserialize, Serialize};

use crate::history::HistRow;
use crate::learn::{Learned, Warmth};
use crate::model::{Job, JobTrust, Os, Priority, RunnerTrust, WaitReason};

/// A runner's state as the hub knows it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RunnerState {
    Ready,
    /// Out of rotation, with its last strike's reason.
    Benched(String),
    /// Its credentials need the user (the command to run).
    NeedsLogin(String),
    /// The hub lacks the runner keys since its restart.
    NeedsKeys,
    /// A cloud machine waits for the user's confirm.
    AwaitingConfirm,
    Unreachable {
        since: u64,
    },
    /// A Mac on battery that went quiet (its lid closed): no strike, its attempts keep their grace.
    Sleeping {
        since: u64,
    },
    Draining,
    Preempting,
}

/// What a runner accepts (per runner).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Accept {
    All,
    Heavy,
}

/// What a project sends away from this machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Send {
    All,
    Heavy,
    None,
}

/// A cloud candidate's spend terms: whether starting it fits the projection, and the reason shown when it doesn't
/// ("cloud cap: $41 of $50 used; …").
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CloudTerms {
    pub projection_ok: bool,
    pub cap: String,
}

/// A machine that might run the job.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Candidate {
    pub name: String,
    /// The hub's own machine.
    pub local: bool,
    pub trust: RunnerTrust,
    /// The keys a `my-cloud` runner may get.
    pub keys_allowed: Vec<String>,
    /// The OS its jobs run on: `macos` for a Mac runner; the hub's own machine and Linux runners `linux` (a hub on a
    /// Mac runs its container jobs in podman's Linux machine).
    #[serde(default)]
    pub os: Os,
    pub features: Vec<String>,
    pub state: RunnerState,
    pub accept: Accept,
    /// The measured link rate, bytes per second (none yet: no transfer is counted).
    pub link_bps: Option<f64>,
    /// What the runner lacks for this job: objects, blobs, `needs` artifacts.
    pub missing_bytes: u64,
    /// Until it can start: 0 when running, the boot time for a cloud machine, the redial time when reconnecting.
    pub start_s: f64,
    /// Until room frees, from its running jobs' expected ends.
    pub wait_s: f64,
    /// The static speed ratio applied to another machine's time (1.0 the same, 1.6 takes 60 % longer).
    pub speed: f64,
    /// The job's history rows (its key) from every machine.
    pub history: Vec<HistRow>,
    /// Set for a cloud machine: it counts only on the cloud's terms.
    pub cloud: Option<CloudTerms>,
}

/// The estimate placement compares: `total = wait + start + transfer + expected`, in seconds.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct FinishEstimate {
    pub wait_s: f64,
    pub start_s: f64,
    pub transfer_s: f64,
    pub expected_s: f64,
    pub total_s: f64,
}

/// What [`pick`] and [`why_here`] read besides the job and the candidates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlaceCtx {
    /// The job's effective priority.
    pub eff: Priority,
    /// The project's send mode.
    pub send: Send,
    /// The starter's `machines` matrix cell allows sending it away.
    pub machines_cell_allows: bool,
    /// The project allows cloud for gates.
    pub gates_allowed: bool,
    /// How much sooner a cloud machine must finish than the best own machine (`runners-cloud-after`).
    pub cloud_after_s: f64,
    pub now: u64,
    /// The job's commits the public origin lacks (a public project's job; 0 otherwise).
    pub commits_not_on_origin: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Pick {
    Runner(String),
    Local,
    Wait(WaitReason),
}

/// The trust table (runners design §6.6). A job that names keys is `private+keys` whatever its trust says.
///
/// | job trust | `mine` | `my-cloud` | `shared` |
/// |---|---|---|---|
/// | `public` | yes | yes | yes |
/// | `private` | yes | yes | no |
/// | `private+keys` | yes | if every key is on its list | no |
pub fn trust_ok(
    job: JobTrust,
    keys: &[String],
    runner: RunnerTrust,
    keys_allowed: &[String],
) -> bool {
    let job = if keys.is_empty() {
        job
    } else {
        JobTrust::PrivateKeys
    };
    match (job, runner) {
        (_, RunnerTrust::Mine) | (JobTrust::Public, _) => true,
        (JobTrust::Private, RunnerTrust::MyCloud) => true,
        (JobTrust::PrivateKeys, RunnerTrust::MyCloud) => {
            keys.iter().all(|k| keys_allowed.contains(k))
        }
        (_, RunnerTrust::Shared) => false,
    }
}

/// The stages of [`filter`], in order: a refusal from a later stage came closer to running.
/// A runner of the right OS that lacks a feature came closer than one of the wrong OS.
const STAGE_TRUST: u8 = 0;
const STAGE_OS: u8 = 1;
const STAGE_FEATURES: u8 = 2;
const STAGE_STATE: u8 = 3;
const STAGE_MODE: u8 = 4;
const STAGE_CELL: u8 = 5;
const STAGE_CLOUD: u8 = 6;

/// Why trust keeps `job` off `c`, in words.
fn trust_text(job: &Job, c: &Candidate) -> String {
    let spec = &job.spec;
    if let Some(k) = spec.keys.iter().find(|k| {
        !trust_ok(
            JobTrust::PrivateKeys,
            &[(*k).clone()],
            c.trust,
            &c.keys_allowed,
        )
    }) {
        return format!("needs key `{k}`, which runner {} may not get", c.name);
    }
    format!(
        "project {} is private; runner {} is shared",
        spec.project, c.name
    )
}

fn check(
    job: &Job,
    c: &Candidate,
    send: Send,
    machines_cell_allows: bool,
    with_trust: bool,
) -> Result<(), (u8, WaitReason)> {
    let spec = &job.spec;
    if with_trust && !c.local && !trust_ok(spec.trust, &spec.keys, c.trust, &c.keys_allowed) {
        return Err((STAGE_TRUST, WaitReason::Trust(trust_text(job, c))));
    }
    let pinned_away =
        (spec.local_only && !c.local) || spec.on.as_ref().is_some_and(|on| *on != c.name);
    if pinned_away {
        return Err((STAGE_TRUST, WaitReason::Pinned));
    }
    if spec.os != c.os {
        return Err((STAGE_OS, WaitReason::Os(spec.os)));
    }
    if c.os == Os::Macos && !spec.keys.is_empty() {
        return Err((
            STAGE_TRUST,
            WaitReason::Trust(format!(
                "needs keys, and a Mac runner ({}) never gets keys",
                c.name
            )),
        ));
    }
    let missing: Vec<String> = spec
        .features
        .iter()
        .filter(|f| !c.features.contains(f))
        .cloned()
        .collect();
    if !missing.is_empty() {
        return Err((STAGE_FEATURES, WaitReason::Features(missing)));
    }
    let state = match &c.state {
        RunnerState::Ready => None,
        RunnerState::Benched(_) => Some(WaitReason::Benched),
        RunnerState::NeedsLogin(_) => Some(WaitReason::NeedsLogin),
        RunnerState::NeedsKeys => Some(WaitReason::NeedsKeys),
        RunnerState::AwaitingConfirm => Some(WaitReason::AwaitingConfirm),
        RunnerState::Unreachable { since } | RunnerState::Sleeping { since } => {
            Some(WaitReason::DesktopUnreachable { since: *since })
        }
        RunnerState::Draining | RunnerState::Preempting => Some(WaitReason::DrainWaits),
    };
    if let Some(r) = state {
        return Err((STAGE_STATE, r));
    }
    if c.local {
        return Ok(());
    }
    let sends = match send {
        Send::All => true,
        Send::Heavy => spec.heavy(),
        Send::None => false,
    };
    let accepts = c.accept == Accept::All || spec.heavy();
    if !(sends && accepts) {
        return Err((STAGE_MODE, WaitReason::Mode));
    }
    if !machines_cell_allows {
        return Err((STAGE_CELL, WaitReason::Matrix));
    }
    Ok(())
}

/// Whether candidate `c` may take `job`, checked in this order: trust and the pin, features, the runner's state, the
/// send and accept modes, the matrix cell. The local machine passes trust, the modes and the cell always.
pub fn filter(
    job: &Job,
    c: &Candidate,
    send: Send,
    machines_cell_allows: bool,
) -> Result<(), WaitReason> {
    check(job, c, send, machines_cell_allows, true).map_err(|(_, r)| r)
}

/// When `job` would finish on `c` by the static rule: its wait, its start, the transfer (`missing_bytes / link_bps`, 0
/// on the local machine) and the expected time from the history on `c`, else other machines' × `c.speed`, else 10
/// minutes. [`finish_with`] with nothing learned and no warmth known. `job` and `now` aren't read.
pub fn finish(job: &Job, c: &Candidate, now: u64) -> FinishEstimate {
    finish_with(job, c, now, &Learned::default(), None)
}

/// When `job` would finish on `c`, with what placement has learned: the transfer at the learned link rate (else the
/// measured `c.link_bps`), and the expected time from [`Learned::expected_for`] (warm or cold when `warmth` is
/// known, learned speed ratios, else the static rule). `job` and `now` aren't read.
pub fn finish_with(
    job: &Job,
    c: &Candidate,
    now: u64,
    learned: &Learned,
    warmth: Option<Warmth>,
) -> FinishEstimate {
    let _ = (job, now);
    let expected_s = learned.expected_for(c, warmth).minutes * 60.0;
    let transfer_s = match learned.link(&c.name).or(c.link_bps) {
        Some(bps) if !c.local && bps > 0.0 => c.missing_bytes as f64 / bps,
        _ => 0.0,
    };
    FinishEstimate {
        wait_s: c.wait_s,
        start_s: c.start_s,
        transfer_s,
        expected_s,
        total_s: c.wait_s + c.start_s + transfer_s + expected_s,
    }
}

/// The tie order: local, then `mine`, `my-cloud`, `shared`.
fn tie_rank(c: &Candidate) -> u8 {
    match (c.local, c.trust) {
        (true, _) => 0,
        (false, RunnerTrust::Mine) => 1,
        (false, RunnerTrust::MyCloud) => 2,
        (false, RunnerTrust::Shared) => 3,
    }
}

/// Whether a cloud machine counts: the job's priority is 1–3 (or it is a gate's and the project allows cloud for
/// gates), it finishes at least `after_s` before the best own machine, and starting it fits the spend projection.
pub fn cloud_counts(
    eff: Priority,
    gates_allowed: bool,
    is_gate: bool,
    best_own_s: f64,
    cloud_s: f64,
    after_s: f64,
    projection_ok: bool,
) -> bool {
    let waited_on = eff.number() <= 3 || (gates_allowed && is_gate);
    waited_on && best_own_s - cloud_s >= after_s && projection_ok
}

/// The smallest estimated finish among the candidates that pass [`filter`] (and, for cloud machines,
/// [`cloud_counts`]); ties go to the local machine, then `mine`, `my-cloud`, `shared`. With none, the job waits with
/// the reason of the candidate that came closest (the latest check it failed). The static rule: [`pick_with`] with
/// nothing learned and no warmth known.
pub fn pick(job: &Job, cands: &[Candidate], ctx: &PlaceCtx) -> Pick {
    pick_with(job, cands, ctx, &Learned::default(), &|_| None)
}

/// [`pick`] with what placement has learned: each estimate is [`finish_with`] with `warmth(c)`, and on an equal
/// estimate and tie order a warm start wins before the name. The filters and the cloud's terms are [`pick`]'s.
pub fn pick_with(
    job: &Job,
    cands: &[Candidate],
    ctx: &PlaceCtx,
    learned: &Learned,
    warmth: &dyn Fn(&Candidate) -> Option<Warmth>,
) -> Pick {
    // The refusal that came closest: the latest stage, the local machine first on a tie, then the given order.
    let mut closest: Option<(u8, bool, WaitReason)> = None;
    let mut refuse = |stage: u8, local: bool, r: WaitReason| {
        let better = closest
            .as_ref()
            .is_none_or(|(s, l, _)| stage > *s || (stage == *s && local && !*l));
        if better {
            closest = Some((stage, local, r));
        }
    };
    // (candidate, estimate, cold: a warm start sorts first)
    let mut passing: Vec<(&Candidate, f64, bool)> = Vec::new();
    for c in cands {
        match check(job, c, ctx.send, ctx.machines_cell_allows, true) {
            Ok(()) => {
                let w = warmth(c);
                let total = finish_with(job, c, ctx.now, learned, w).total_s;
                passing.push((c, total, !w.is_some_and(Warmth::warm)));
            }
            Err((stage, r)) => refuse(stage, c.local, r),
        }
    }
    let best_own_s = passing
        .iter()
        .filter(|(c, _, _)| c.cloud.is_none())
        .map(|&(_, t, _)| t)
        .fold(f64::INFINITY, f64::min);
    let is_gate = job.spec.gate.is_some();
    let mut best: Option<(&Candidate, f64, bool)> = None;
    for (c, total, cold) in passing {
        if let Some(terms) = &c.cloud {
            let counts = cloud_counts(
                ctx.eff,
                ctx.gates_allowed,
                is_gate,
                best_own_s,
                total,
                ctx.cloud_after_s,
                terms.projection_ok,
            );
            if !counts {
                if !terms.projection_ok {
                    refuse(STAGE_CLOUD, false, WaitReason::CloudCap(terms.cap.clone()));
                }
                continue;
            }
        }
        let better = best.is_none_or(|(b, bt, b_cold)| {
            total
                .total_cmp(&bt)
                .then(tie_rank(c).cmp(&tie_rank(b)))
                .then(cold.cmp(&b_cold))
                .then(c.name.cmp(&b.name))
                .is_lt()
        });
        if better {
            best = Some((c, total, cold));
        }
    }
    match best {
        Some((c, _, _)) if c.local => Pick::Local,
        Some((c, _, _)) => Pick::Runner(c.name.clone()),
        None => Pick::Wait(closest.map_or(WaitReason::NoRunner, |(_, _, r)| r)),
    }
}

/// Why a job runs here although other runners exist, in the design's words, when trust alone keeps it here: a key no
/// runner may get, commits the public origin lacks, or a private project with only shared runners free. `None` when
/// a runner may take it, or something other than trust holds it.
pub fn why_here(job: &Job, cands: &[Candidate], ctx: &PlaceCtx) -> Option<String> {
    let remote = || cands.iter().filter(|c| !c.local);
    if remote().any(|c| filter(job, c, ctx.send, ctx.machines_cell_allows).is_ok()) {
        return None;
    }
    // The runners that only trust holds back.
    let free: Vec<&Candidate> = remote()
        .filter(|c| check(job, c, ctx.send, ctx.machines_cell_allows, false).is_ok())
        .collect();
    if free.is_empty() {
        return None;
    }
    let spec = &job.spec;
    if let Some(k) = spec.keys.iter().find(|k| {
        !free.iter().any(|c| {
            trust_ok(
                JobTrust::PrivateKeys,
                &[(*k).clone()],
                c.trust,
                &c.keys_allowed,
            )
        })
    }) {
        return Some(format!(
            "runs here: needs key `{k}`, which no runner may get"
        ));
    }
    if spec.keys.is_empty() && spec.trust == JobTrust::Private {
        if ctx.commits_not_on_origin > 0 {
            let n = ctx.commits_not_on_origin;
            let commits = if n == 1 { "commit" } else { "commits" };
            return Some(format!("runs here: {n} {commits} not on origin"));
        }
        if free.iter().all(|c| c.trust == RunnerTrust::Shared) {
            let only = if free.len() == 1 {
                "the only free runner is shared"
            } else {
                "the only free runners are shared"
            };
            return Some(format!(
                "runs here: project {} is private; {only}",
                spec.project
            ));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::job;

    fn cand(name: &str, trust: RunnerTrust) -> Candidate {
        Candidate {
            name: name.into(),
            local: false,
            trust,
            keys_allowed: vec![],
            os: Os::Linux,
            features: vec!["podman".into()],
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

    fn local() -> Candidate {
        Candidate {
            local: true,
            ..cand("local", RunnerTrust::Mine)
        }
    }

    fn ctx() -> PlaceCtx {
        PlaceCtx {
            eff: Priority::P3,
            send: Send::All,
            machines_cell_allows: true,
            gates_allowed: false,
            cloud_after_s: 120.0,
            now: 1_000_000,
            commits_not_on_origin: 0,
        }
    }

    fn keys(ks: &[&str]) -> Vec<String> {
        ks.iter().map(|k| k.to_string()).collect()
    }

    #[test]
    fn trust_table_is_the_designs() {
        // [D] pure: all nine cells.
        use JobTrust::*;
        use RunnerTrust::*;
        let k = keys(&["K"]);
        let none: Vec<String> = vec![];
        let cells = [
            (Public, &none, Mine, true),
            (Public, &none, MyCloud, true),
            (Public, &none, Shared, true),
            (Private, &none, Mine, true),
            (Private, &none, MyCloud, true),
            (Private, &none, Shared, false),
            (PrivateKeys, &k, Mine, true),
            (PrivateKeys, &k, MyCloud, false),
            (PrivateKeys, &k, Shared, false),
        ];
        for (job, ks, runner, want) in cells {
            assert_eq!(
                trust_ok(job, ks, runner, &[]),
                want,
                "{job:?} on {runner:?}"
            );
        }
        // private+keys on my-cloud only with every key listed
        let two = keys(&["A", "B"]);
        assert!(!trust_ok(PrivateKeys, &two, MyCloud, &keys(&["A"])));
        assert!(trust_ok(
            PrivateKeys,
            &two,
            MyCloud,
            &keys(&["B", "A", "C"])
        ));
        assert!(!trust_ok(PrivateKeys, &two, Shared, &keys(&["A", "B"])));
        // a job naming keys is private+keys whatever its trust says
        assert!(!trust_ok(Public, &k, Shared, &[]));
    }

    #[test]
    fn a_pinned_job_never_leaves() {
        // [D] pure
        let mut fast = cand("desktop", RunnerTrust::Mine);
        fast.speed = 0.1;
        fast.history = vec![];
        let mut slow_local = local();
        slow_local.wait_s = 3600.0;
        let cands = [slow_local, fast];
        let mut j = job("j", Priority::P3, 0);
        assert_eq!(pick(&j, &cands, &ctx()), Pick::Runner("desktop".into()));
        j.spec.local_only = true;
        assert_eq!(pick(&j, &cands, &ctx()), Pick::Local);
        j.spec.local_only = false;
        j.spec.on = Some("desktop".into());
        let mut cands2 = cands.clone();
        cands2[0].wait_s = 0.0;
        cands2[1].wait_s = 3600.0;
        assert_eq!(pick(&j, &cands2, &ctx()), Pick::Runner("desktop".into()));
        // Pinned to a benched runner: it waits, saying why.
        cands2[1].state = RunnerState::Benched("setup failed".into());
        assert_eq!(pick(&j, &cands2, &ctx()), Pick::Wait(WaitReason::Benched));
    }

    /// [D] The OS comes before features: a featureless container job (`linux`, the default) never places on a Mac
    /// runner, a `macos` job never on a Linux one (it waits for a Mac runner, never the hub's machine), and a keyed job
    /// is refused on a Mac with the reason.
    #[test]
    fn the_os_is_matched_before_features() {
        let mut j = job("j", Priority::P3, 0);
        j.spec.features = vec![];
        let mut mac = cand("mac", RunnerTrust::Mine);
        mac.os = Os::Macos;
        mac.features = vec!["host-jobs".into()];
        assert_eq!(
            filter(&j, &mac, Send::All, true),
            Err(WaitReason::Os(Os::Linux))
        );
        assert_eq!(
            pick(&j, &[mac.clone()], &ctx()),
            Pick::Wait(WaitReason::Os(Os::Linux))
        );
        j.spec.os = Os::Macos;
        j.spec.features = vec!["gpu".into()];
        // the OS is reported before the missing feature
        assert_eq!(
            filter(&j, &cand("box", RunnerTrust::Mine), Send::All, true),
            Err(WaitReason::Os(Os::Macos))
        );
        assert_eq!(
            filter(&j, &local(), Send::All, true),
            Err(WaitReason::Os(Os::Macos))
        );
        // a Mac lacking the feature came closer than the hub's Linux machine: the job waits on the feature
        assert_eq!(
            pick(&j, &[local(), mac.clone()], &ctx()),
            Pick::Wait(WaitReason::Features(vec!["gpu".into()]))
        );
        j.spec.features = vec![];
        assert_eq!(filter(&j, &mac, Send::All, true), Ok(()));
        j.spec.keys = vec!["GH_TOKEN".into()];
        assert!(matches!(
            filter(&j, &mac, Send::All, true),
            Err(WaitReason::Trust(t)) if t.contains("Mac")
        ));
    }

    #[test]
    fn filter_order_reports_trust_first() {
        // [D] pure
        let mut j = job("j", Priority::P3, 0);
        j.spec.trust = JobTrust::Private;
        j.spec.features = keys(&["podman", "gpu"]);
        let mut c = cand("box", RunnerTrust::Shared);
        c.state = RunnerState::Benched("disk".into());
        c.accept = Accept::Heavy;
        assert!(matches!(
            filter(&j, &c, Send::All, false),
            Err(WaitReason::Trust(_))
        ));
        c.trust = RunnerTrust::Mine;
        assert_eq!(
            filter(&j, &c, Send::All, false),
            Err(WaitReason::Features(keys(&["gpu"])))
        );
        c.features.push("gpu".into());
        assert_eq!(filter(&j, &c, Send::All, false), Err(WaitReason::Benched));
        c.state = RunnerState::Ready;
        assert_eq!(filter(&j, &c, Send::All, false), Err(WaitReason::Mode));
        c.accept = Accept::All;
        assert_eq!(filter(&j, &c, Send::Heavy, false), Err(WaitReason::Mode));
        assert_eq!(filter(&j, &c, Send::None, false), Err(WaitReason::Mode));
        assert_eq!(filter(&j, &c, Send::All, false), Err(WaitReason::Matrix));
        assert_eq!(filter(&j, &c, Send::All, true), Ok(()));
        // The local machine passes trust, the modes and the cell, but not features or its state.
        let mut l = local();
        l.trust = RunnerTrust::Shared;
        assert_eq!(
            filter(&j, &l, Send::None, false),
            Err(WaitReason::Features(keys(&["gpu"])))
        );
        l.features.push("gpu".into());
        assert_eq!(filter(&j, &l, Send::None, false), Ok(()));
        // Each state's reason.
        let states = [
            (
                RunnerState::NeedsLogin("aws sso login".into()),
                WaitReason::NeedsLogin,
            ),
            (RunnerState::NeedsKeys, WaitReason::NeedsKeys),
            (RunnerState::AwaitingConfirm, WaitReason::AwaitingConfirm),
            (
                RunnerState::Unreachable { since: 5 },
                WaitReason::DesktopUnreachable { since: 5 },
            ),
            (
                RunnerState::Sleeping { since: 6 },
                WaitReason::DesktopUnreachable { since: 6 },
            ),
            (RunnerState::Draining, WaitReason::DrainWaits),
            (RunnerState::Preempting, WaitReason::DrainWaits),
        ];
        for (s, want) in states {
            c.state = s;
            assert_eq!(filter(&j, &c, Send::All, true), Err(want));
        }
    }

    #[test]
    fn ties_go_local_then_mine() {
        // [D] pure: equal estimates everywhere.
        let mut j = job("j", Priority::P3, 0);
        j.spec.trust = JobTrust::Public;
        let all = [
            cand("shared", RunnerTrust::Shared),
            cand("cloudy", RunnerTrust::MyCloud),
            cand("mine", RunnerTrust::Mine),
            local(),
        ];
        assert_eq!(pick(&j, &all, &ctx()), Pick::Local);
        assert_eq!(pick(&j, &all[..3], &ctx()), Pick::Runner("mine".into()));
        assert_eq!(pick(&j, &all[..2], &ctx()), Pick::Runner("cloudy".into()));
        assert_eq!(pick(&j, &all[..1], &ctx()), Pick::Runner("shared".into()));
        assert_eq!(pick(&j, &[], &ctx()), Pick::Wait(WaitReason::NoRunner));
    }

    #[test]
    fn transfer_counts_missing_bytes_at_the_link_rate() {
        // [D] pure
        let j = job("j", Priority::P3, 0);
        let mut c = cand("desktop", RunnerTrust::Mine);
        c.missing_bytes = 1_000_000_000;
        c.link_bps = Some(100_000_000.0);
        c.wait_s = 30.0;
        c.start_s = 5.0;
        let f = finish(&j, &c, 0);
        assert_eq!(f.transfer_s, 10.0);
        assert_eq!(f.expected_s, 600.0, "no history: 10 minutes");
        assert_eq!(f.total_s, 30.0 + 5.0 + 10.0 + 600.0);
        let mut l = local();
        l.missing_bytes = 1_000_000_000;
        l.link_bps = Some(1.0);
        assert_eq!(finish(&j, &l, 0).transfer_s, 0.0);
        // A slow link loses to a slower machine that has everything.
        let mut slow = cand("slow", RunnerTrust::Mine);
        slow.wait_s = 40.0; // 640 s against 645 s
        assert_eq!(pick(&j, &[c, slow], &ctx()), Pick::Runner("slow".into()));
    }

    #[test]
    fn finish_reads_this_machines_history_then_others() {
        // [D] pure
        let j = job("j", Priority::P3, 0);
        let row = |machine: &str, wall_s: f64| HistRow {
            key: "k".into(),
            machine: machine.into(),
            grant: crate::model::Grant {
                cores: 1,
                mem_cap_mib: 1024,
                reserve_mib: 1024,
            },
            wall_s,
            cpu_s: wall_s,
            mem_peak_mib: 512,
            verdict: crate::model::Verdict::Pass,
            disturbed: false,
            at: 1,
            warm: true,
        };
        let mut c = cand("laptop", RunnerTrust::Mine);
        c.speed = 1.5;
        c.history = vec![row("desktop", 600.0)];
        assert_eq!(finish(&j, &c, 0).expected_s, 900.0);
        c.history.push(row("laptop", 300.0));
        assert_eq!(finish(&j, &c, 0).expected_s, 300.0);
    }

    #[test]
    fn cloud_only_for_priority_1_to_3_unless_gates_allowed() {
        // [D] pure
        for p in [Priority::P1, Priority::P2, Priority::P3] {
            assert!(cloud_counts(p, false, false, 1000.0, 100.0, 120.0, true));
        }
        assert!(!cloud_counts(
            Priority::P4,
            false,
            true,
            1000.0,
            100.0,
            120.0,
            true
        ));
        assert!(cloud_counts(
            Priority::P4,
            true,
            true,
            1000.0,
            100.0,
            120.0,
            true
        ));
        assert!(!cloud_counts(
            Priority::P4,
            true,
            false,
            1000.0,
            100.0,
            120.0,
            true
        ));
        assert!(!cloud_counts(
            Priority::P5,
            true,
            false,
            1000.0,
            100.0,
            120.0,
            true
        ));
        assert!(!cloud_counts(
            Priority::P1,
            false,
            false,
            1000.0,
            100.0,
            120.0,
            false
        ));
        // In the pick: a P4 bulk job never starts a cloud machine.
        let mut j = job("j", Priority::P4, 0);
        j.spec.trust = JobTrust::Private;
        let mut cloud = cand("aws-1", RunnerTrust::MyCloud);
        cloud.cloud = Some(CloudTerms {
            projection_ok: true,
            cap: String::new(),
        });
        let mut slow_local = local();
        slow_local.wait_s = 3600.0;
        let mut c = ctx();
        c.eff = Priority::P4;
        assert_eq!(
            pick(&j, &[slow_local.clone(), cloud.clone()], &c),
            Pick::Local
        );
        c.eff = Priority::P2;
        assert_eq!(
            pick(&j, &[slow_local.clone(), cloud.clone()], &c),
            Pick::Runner("aws-1".into())
        );
        cloud.cloud = Some(CloudTerms {
            projection_ok: false,
            cap: "cloud cap: $41 of $50 used".into(),
        });
        assert_eq!(pick(&j, &[slow_local, cloud.clone()], &c), Pick::Local);
        assert_eq!(
            pick(&j, &[cloud], &c),
            Pick::Wait(WaitReason::CloudCap("cloud cap: $41 of $50 used".into()))
        );
    }

    #[test]
    fn cloud_must_win_by_runners_cloud_after() {
        // [D] pure
        assert!(!cloud_counts(
            Priority::P1,
            false,
            false,
            1000.0,
            881.0,
            120.0,
            true
        ));
        assert!(cloud_counts(
            Priority::P1,
            false,
            false,
            1000.0,
            880.0,
            120.0,
            true
        ));
        let j = job("j", Priority::P1, 0);
        let mut cloud = cand("aws-1", RunnerTrust::MyCloud);
        cloud.cloud = Some(CloudTerms {
            projection_ok: true,
            cap: String::new(),
        });
        cloud.start_s = 60.0;
        let mut l = local();
        l.wait_s = 100.0; // local 700 s, cloud 660 s: 40 s sooner is not enough
        let mut c = ctx();
        c.eff = Priority::P1;
        assert_eq!(pick(&j, &[l.clone(), cloud.clone()], &c), Pick::Local);
        l.wait_s = 300.0; // local 900 s: cloud wins by 240 s
        assert_eq!(pick(&j, &[l, cloud], &c), Pick::Runner("aws-1".into()));
    }

    #[test]
    fn why_here_texts_are_the_designs() {
        // [D] pure
        let mut j = job("j", Priority::P3, 0);
        j.spec.project = "alpha".into();
        j.spec.trust = JobTrust::PrivateKeys;
        j.spec.keys = keys(&["CRATES_IO_TOKEN"]);
        let mut cloud = cand("aws-1", RunnerTrust::MyCloud);
        cloud.keys_allowed = keys(&["OTHER"]);
        let cands = [local(), cloud, cand("box", RunnerTrust::Shared)];
        assert_eq!(pick(&j, &cands, &ctx()), Pick::Local);
        assert_eq!(
            why_here(&j, &cands, &ctx()).as_deref(),
            Some("runs here: needs key `CRATES_IO_TOKEN`, which no runner may get")
        );
        j.spec.keys = vec![];
        j.spec.trust = JobTrust::Private;
        let mut c = ctx();
        c.commits_not_on_origin = 3;
        let shared_only = [local(), cand("box", RunnerTrust::Shared)];
        assert_eq!(
            why_here(&j, &shared_only, &c).as_deref(),
            Some("runs here: 3 commits not on origin")
        );
        assert_eq!(
            why_here(&j, &shared_only, &ctx()).as_deref(),
            Some("runs here: project alpha is private; the only free runner is shared")
        );
        // A runner may take it: nothing to explain.
        let with_mine = [local(), cand("desktop", RunnerTrust::Mine)];
        assert_eq!(why_here(&j, &with_mine, &ctx()), None);
        // Held by something else than trust (a benched shared box): nothing to explain either.
        let mut benched = cand("box", RunnerTrust::Shared);
        benched.state = RunnerState::Benched("disk".into());
        assert_eq!(why_here(&j, &[local(), benched], &ctx()), None);
    }
}
