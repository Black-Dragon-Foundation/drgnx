//! IO as a budget (Task 10b): the weight a job's priority gives it, whether a job's expected IO fits the device, and
//! the live cap under pressure. Pure; `sleipnir::linux::io` reads the device and writes the cgroup files.

use crate::model::{Expected, JobId, Limits, Priority, RunningJob, WaitReason};

/// A job's `IOWeight` from its priority: P1 1000, P2 500, P3 200, P4 100, P5 50 (systemd takes 1 to 10000, 100 is its
/// default). Weights only act under the `io.cost` controller or BFQ (`sleipnir::linux::io::probe`).
pub fn weight_of(p: Priority) -> u32 {
    match p {
        Priority::P1 => 1000,
        Priority::P2 => 500,
        Priority::P3 => 200,
        Priority::P4 => 100,
        Priority::P5 => 50,
    }
}

/// Whether a job expecting EXP fits the device beside the RUNNING jobs: their expected MiB/s and this one's are at
/// most `limits.io_device_mbps`. A device that is not known counts nothing, and a job without a measured IO counts as
/// none.
pub fn fits(limits: &Limits, running: &[RunningJob], exp: &Expected) -> Result<(), WaitReason> {
    let (Some(device), Some(need)) = (limits.io_device_mbps, exp.io_p95_mbps) else {
        return Ok(());
    };
    let used: f64 = running.iter().filter_map(|r| r.expected.io_p95_mbps).sum();
    let free = (device - used).max(0.0);
    if need > free {
        return Err(WaitReason::IoBandwidth {
            need_mbps: need,
            free_mbps: free,
        });
    }
    Ok(())
}

/// The cap a job gets under pressure when it has no history to halve, MiB/s.
pub const DEFAULT_CAP_MBPS: f64 = 50.0;

/// A running job, as the live cap reads it.
#[derive(Clone, Debug, PartialEq)]
pub struct IoJob {
    pub id: JobId,
    pub priority: Priority,
    /// The pack declares it hard on the disk (`Derived::io_heavy`): only such a job is capped.
    pub io_heavy: bool,
    /// Its expected IO ([`Expected::io_p95_mbps`]).
    pub expected_mbps: Option<f64>,
}

/// One move of the live cap.
#[derive(Clone, Debug, PartialEq)]
pub enum IoStep {
    /// Cap the job's IO at this much, MiB/s (`io.max`).
    Cap { job: JobId, mbps: f64 },
    /// Lift the job's cap.
    Lift(JobId),
}

/// What to do about the IO pressure PRESSURE (`io full avg10`, percent) against LIMIT: above it, the lowest-priority
/// `io_heavy` job not yet CAPPED gets a cap of half its expected IO ([`DEFAULT_CAP_MBPS`] without history), one job per
/// tick; at half the limit or less, every capped job in JOBS is lifted. Between the two nothing moves, so a cap does
/// not flap.
pub fn steps(pressure: f64, limit: f64, capped: &[JobId], jobs: &[IoJob]) -> Vec<IoStep> {
    if pressure <= limit / 2.0 {
        return capped
            .iter()
            .filter(|c| jobs.iter().any(|j| j.id == **c))
            .map(|c| IoStep::Lift(c.clone()))
            .collect();
    }
    if pressure <= limit {
        return vec![];
    }
    // the lowest priority (the highest number); the first of equals
    let mut pick: Option<&IoJob> = None;
    for j in jobs
        .iter()
        .filter(|j| j.io_heavy && !capped.contains(&j.id))
    {
        if pick.is_none_or(|p| j.priority.number() > p.priority.number()) {
            pick = Some(j);
        }
    }
    pick.map(|j| IoStep::Cap {
        job: j.id.clone(),
        mbps: j.expected_mbps.map_or(DEFAULT_CAP_MBPS, |m| m / 2.0),
    })
    .into_iter()
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{expected_min, machine, running};

    /// [D] pure (Task 10b): a weight per priority, higher for the more urgent, inside systemd's range.
    #[test]
    fn io_weights_follow_priority() {
        let w: Vec<u32> = Priority::ALL.iter().map(|p| weight_of(*p)).collect();
        assert_eq!(w, [1000, 500, 200, 100, 50]);
        assert!(w.windows(2).all(|p| p[0] > p[1]));
        assert!(w.iter().all(|w| (1..=10_000).contains(w)));
    }

    fn io_job(id: &str, p: Priority, heavy: bool, mbps: Option<f64>) -> IoJob {
        IoJob {
            id: JobId(id.into()),
            priority: p,
            io_heavy: heavy,
            expected_mbps: mbps,
        }
    }

    /// [D] pure (Task 10b): over the limit the lowest-priority io-heavy job is capped at half its p95, one a tick; at
    /// half the limit the caps lift; in between nothing moves.
    #[test]
    fn pressure_caps_the_lowest_io_heavy_job_and_lifts() {
        let jobs = [
            io_job("p1", Priority::P1, true, Some(400.0)),
            io_job("p5", Priority::P5, true, Some(300.0)),
            io_job("p4", Priority::P4, true, None),
            io_job("p5light", Priority::P5, false, Some(900.0)),
        ];
        let one = |id: &str, mbps| {
            vec![IoStep::Cap {
                job: JobId(id.into()),
                mbps,
            }]
        };
        assert_eq!(steps(15.0, 10.0, &[], &jobs), one("p5", 150.0));
        // still over: the next lowest, which has no history to halve
        let capped = [JobId("p5".into())];
        assert_eq!(
            steps(12.0, 10.0, &capped, &jobs),
            one("p4", DEFAULT_CAP_MBPS)
        );
        // between the limit and its half: nothing moves
        assert_eq!(steps(7.0, 10.0, &capped, &jobs), vec![]);
        // low again: every cap lifts, in the order they were given; a job that ended is not named
        let capped = [JobId("p5".into()), JobId("p4".into()), JobId("gone".into())];
        assert_eq!(
            steps(4.0, 10.0, &capped, &jobs),
            vec![
                IoStep::Lift(JobId("p5".into())),
                IoStep::Lift(JobId("p4".into()))
            ]
        );
        // nothing io-heavy is running: nothing to cap
        assert_eq!(
            steps(50.0, 10.0, &[], &[io_job("a", Priority::P5, false, None)]),
            vec![]
        );
    }

    /// [D] pure (Task 10b): admission counts the running jobs' expected IO against what the device moves.
    #[test]
    fn expected_io_must_fit_the_device() {
        let mut lim = Limits::for_profile(crate::model::Profile::Dedicated, 32768, 8);
        let m = machine(crate::model::Profile::Dedicated);
        let mut r = running("r1", Priority::P3, m.now - 60, 512, 512);
        r.expected = Expected {
            io_p95_mbps: Some(80.0),
            ..expected_min(10.0)
        };
        let me = Expected {
            io_p95_mbps: Some(30.0),
            ..expected_min(10.0)
        };
        assert_eq!(
            fits(&lim, std::slice::from_ref(&r), &me),
            Ok(()),
            "no device figure"
        );
        lim.io_device_mbps = Some(100.0);
        assert_eq!(
            fits(&lim, std::slice::from_ref(&r), &me),
            Err(WaitReason::IoBandwidth {
                need_mbps: 30.0,
                free_mbps: 20.0
            })
        );
        assert_eq!(fits(&lim, &[], &me), Ok(()));
    }
}
