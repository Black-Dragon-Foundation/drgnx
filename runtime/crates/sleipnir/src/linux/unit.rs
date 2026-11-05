//! A job attempt as a transient user service in its job slice (`systemd-run --user`). The service outlives whoever
//! started it (the runner's `serve`, jobq's daemon, a link that dropped), writes its output to the attempt's log
//! itself, and is collected when it ends.

use super::run;
use std::path::PathBuf;

/// job-exec's OOM score: still above every process of the user's, below the containers (1000), so in a job that runs
/// out of memory the kernel takes a container first and job-exec lives to write the verdict (at an equal score the kernel picks by size, and has taken job-exec first).
pub const JOB_EXEC_OOM_SCORE: u32 = 900;

/// One attempt to start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnitReq {
    /// The unit's name without `.service` (`drgnx-run-<id>-<attempt>`, `jobq-<id>`).
    pub unit: String,
    pub id: String,
    pub attempt: u32,
    /// The job's slice ([`super::slices::job_slice`]).
    pub slice: String,
    /// `RuntimeMaxSec`: systemd stops the attempt past it, whatever became of its starter.
    pub runtime_max_s: u64,
    /// The attempt's log: stdout and stderr appended.
    pub log: PathBuf,
    pub env: Vec<(String, String)>,
    pub argv: Vec<String>,
    /// A unit this one lives no longer than (`BindsTo=` and `After=`).
    pub binds_to: Option<String>,
}

/// A unit or env name systemd reads as one word.
fn plain(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.@".contains(&b))
}

/// The `systemd-run` arguments for R (without the program).
pub fn run_args(r: &UnitReq) -> Result<Vec<String>, String> {
    if !plain(&r.unit) || !plain(&r.slice) || !r.slice.ends_with(".slice") {
        return Err(format!(
            "a unit and its slice are plain names: {:?} {:?}",
            r.unit, r.slice
        ));
    }
    let log = r
        .log
        .to_str()
        .filter(|l| r.log.is_absolute() && !l.contains(['\n', '\0', ' ']))
        .ok_or_else(|| {
            format!(
                "the attempt's log must be an absolute path without spaces: {}",
                r.log.display()
            )
        })?;
    if r.argv.is_empty() {
        return Err("a unit needs a command".into());
    }
    let mut a: Vec<String> = [
        "--user",
        "--no-ask-password",
        "--quiet",
        "--collect",
        &format!("--unit={}.service", r.unit),
        &format!("--slice={}", r.slice),
        "--property",
        &format!("OOMScoreAdjust={JOB_EXEC_OOM_SCORE}"),
        "--property",
        "OOMPolicy=kill",
        // a job never swaps: a keyed job's secrets never reach swap (job-exec checks it before the first key)
        "--property",
        "MemorySwapMax=0",
        "--property",
        &format!("RuntimeMaxSec={}", r.runtime_max_s.max(1)),
        "--property",
        &format!("StandardOutput=append:{log}"),
        "--property",
        &format!("StandardError=append:{log}"),
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    if let Some(b) = &r.binds_to {
        if !plain(b) {
            return Err(format!("BindsTo names a plain unit: {b:?}"));
        }
        a.extend([
            "--property".into(),
            format!("BindsTo={b}"),
            "--property".into(),
            format!("After={b}"),
        ]);
    }
    for (k, v) in &r.env {
        if !plain(k) || k.contains(['.', '@', '-']) || v.contains(['\n', '\0']) {
            return Err(format!("an environment entry systemd can't carry: {k:?}"));
        }
        a.push(format!("--setenv={k}={v}"));
    }
    a.push("--".into());
    a.extend(r.argv.iter().cloned());
    Ok(a)
}

/// Starts R; the unit's name.
pub fn start(r: &UnitReq) -> Result<String, String> {
    let args = run_args(r)?;
    let out = run::limited(
        std::path::Path::new("systemd-run"),
        &args,
        &[],
        run::SYSTEMCTL_LIMIT,
    )?;
    if !out.status.success() {
        return Err(format!(
            "systemd-run {}: {}",
            r.unit,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(format!("{}.service", r.unit))
}

/// Stops UNIT (and with it the processes in it), without waiting.
pub fn stop(unit: &str) -> Result<(), String> {
    run::systemctl_ok(&["stop", "--no-block", unit]).map(|_| ())
}

/// Whether UNIT is running (`active` or still starting).
pub fn active(unit: &str) -> bool {
    run::systemctl(&["is-active", unit]).is_ok_and(|o| {
        let s = String::from_utf8_lossy(&o.stdout);
        matches!(s.trim(), "active" | "activating" | "reloading")
    })
}

/// One unit as `systemctl list-units` shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnitStatus {
    pub unit: String,
    pub load: String,
    pub active: String,
    pub sub: String,
}

/// Our units whose names start with PREFIX, loaded or not.
pub fn list(prefix: &str) -> Vec<UnitStatus> {
    if !plain(prefix) {
        return vec![];
    }
    let pattern = format!("{prefix}*");
    let Ok(out) = run::systemctl(&[
        "list-units",
        "--all",
        "--plain",
        "--no-legend",
        "--full",
        &pattern,
    ]) else {
        return vec![];
    };
    parse_list(&String::from_utf8_lossy(&out.stdout))
}

/// `list-units --plain --no-legend` lines: UNIT LOAD ACTIVE SUB DESCRIPTION.
pub fn parse_list(text: &str) -> Vec<UnitStatus> {
    text.lines()
        .filter_map(|l| {
            let mut w = l.split_whitespace();
            Some(UnitStatus {
                unit: w.next()?.to_string(),
                load: w.next()?.to_string(),
                active: w.next()?.to_string(),
                sub: w.next()?.to_string(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req() -> UnitReq {
        UnitReq {
            unit: "drgnx-run-a3f-1".into(),
            id: "a3f".into(),
            attempt: 1,
            slice: "drgnx-runner-work-a3f.slice".into(),
            runtime_max_s: 660,
            log: "/r/jobs/a3f.1/a3f.1.log".into(),
            env: vec![("DRGNX_JOB".into(), "a3f".into())],
            argv: vec![
                "/r/bin/sleipnir".into(),
                "job-exec".into(),
                "/r/jobs/a3f.1".into(),
            ],
            binds_to: None,
        }
    }

    /// [D] The unit's properties: its slice, job-exec's OOM score, the kill policy, no swap, the time limit and the
    /// log; the command after `--`.
    #[test]
    fn a_unit_has_the_jobs_properties() {
        let a = run_args(&req()).unwrap();
        for want in [
            "--unit=drgnx-run-a3f-1.service",
            "--slice=drgnx-runner-work-a3f.slice",
            "--collect",
            "OOMScoreAdjust=900",
            "OOMPolicy=kill",
            "MemorySwapMax=0",
            "RuntimeMaxSec=660",
            "StandardOutput=append:/r/jobs/a3f.1/a3f.1.log",
            "StandardError=append:/r/jobs/a3f.1/a3f.1.log",
            "--setenv=DRGNX_JOB=a3f",
        ] {
            assert!(a.iter().any(|s| s == want), "{want}: {a:?}");
        }
        let dash = a.iter().position(|s| s == "--").unwrap();
        assert_eq!(
            a[dash + 1..],
            ["/r/bin/sleipnir", "job-exec", "/r/jobs/a3f.1"]
        );
        let b = run_args(&UnitReq {
            binds_to: Some("drgnx-run-a3f-1.service".into()),
            ..req()
        })
        .unwrap();
        assert!(
            b.windows(2)
                .any(|w| w == ["--property", "BindsTo=drgnx-run-a3f-1.service"])
        );
        for bad in [
            UnitReq {
                unit: "a b".into(),
                ..req()
            },
            UnitReq {
                slice: "x".into(),
                ..req()
            },
            UnitReq {
                log: "rel/log".into(),
                ..req()
            },
            UnitReq {
                argv: vec![],
                ..req()
            },
            UnitReq {
                env: vec![("A B".into(), "1".into())],
                ..req()
            },
            UnitReq {
                env: vec![("A".into(), "1\n2".into())],
                ..req()
            },
        ] {
            assert!(run_args(&bad).is_err(), "{bad:?}");
        }
        assert_eq!(
            parse_list(
                "drgnx-run-a3f-1.service loaded active running job a3f\nx.service not-found inactive dead x\n"
            ),
            [
                UnitStatus {
                    unit: "drgnx-run-a3f-1.service".into(),
                    load: "loaded".into(),
                    active: "active".into(),
                    sub: "running".into()
                },
                UnitStatus {
                    unit: "x.service".into(),
                    load: "not-found".into(),
                    active: "inactive".into(),
                    sub: "dead".into()
                },
            ]
        );
    }
}
