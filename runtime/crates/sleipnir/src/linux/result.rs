//! `result.json`: what job-exec writes in the attempt's folder before it exits, and what the scheduler records.

use super::parse::{Counts, RowVerdict};
use forseti::{Grant, Verdict};
use serde::{Deserialize, Serialize};
use std::io;
use std::path::Path;

/// One row's result, as the `row` frames carry it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RowResult {
    pub name: String,
    pub verdict: RowVerdict,
    pub attempt: u32,
    pub machine: String,
}

/// An attempt's result.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ResultJson {
    pub verdict: Verdict,
    /// The named reason of an `infra` verdict, with its prefix (`infra: setup`); none otherwise.
    pub infra: Option<String>,
    pub counts: Counts,
    pub rows: Vec<RowResult>,
    /// The failed and crashed rows' names.
    pub failing: Vec<String>,
    pub machine: String,
    pub grant: Grant,
    pub wall_s: f64,
    pub cpu_s: f64,
    pub mem_peak_mib: u64,
    /// A watched job's (a Mac's: no kernel cap) peak past its grant, MiB; none where the kernel enforces the cap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mem_overshoot_mib: Option<u64>,
    /// Something outside the job slowed it (paused, throttled); its time is not a fair sample.
    pub disturbed: bool,
    /// The attempt's log.
    pub log: String,
}

/// The file name.
pub const RESULT: &str = "result.json";

impl ResultJson {
    /// Writes it into DIR by rename, so a reader never sees half of it.
    pub fn write(&self, dir: &Path) -> io::Result<()> {
        let tmp = dir.join(format!(".{RESULT}.tmp"));
        std::fs::write(
            &tmp,
            serde_json::to_vec_pretty(self).map_err(io::Error::other)?,
        )?;
        std::fs::rename(&tmp, dir.join(RESULT))
    }

    /// Reads DIR's.
    pub fn read(dir: &Path) -> io::Result<ResultJson> {
        serde_json::from_slice(&std::fs::read(dir.join(RESULT))?).map_err(io::Error::other)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] The keys a reader (the hub, jobq's store) relies on, and a round trip through the file.
    #[test]
    fn result_json_shape() {
        let r = ResultJson {
            verdict: Verdict::Infra("setup".into()),
            infra: Some("infra: setup".into()),
            counts: Counts {
                ran: 2,
                passed: 1,
                failed: 1,
                skipped: 0,
                crashed: 0,
            },
            rows: vec![RowResult {
                name: "a::b".into(),
                verdict: RowVerdict::Fail,
                attempt: 1,
                machine: "desk".into(),
            }],
            failing: vec!["a::b".into()],
            machine: "desk".into(),
            grant: Grant {
                cores: 2,
                mem_cap_mib: 4096,
                reserve_mib: 2048,
            },
            wall_s: 1.5,
            cpu_s: 0.25,
            mem_peak_mib: 300,
            mem_overshoot_mib: None,
            disturbed: false,
            log: "/r/jobs/a.1/a.1.log".into(),
        };
        let v = serde_json::to_value(&r).unwrap();
        let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(
            keys,
            [
                "counts",
                "cpu_s",
                "disturbed",
                "failing",
                "grant",
                "infra",
                "log",
                "machine",
                "mem_peak_mib",
                "rows",
                "verdict",
                "wall_s"
            ]
        );
        let mut ck: Vec<&str> = v["counts"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        ck.sort();
        assert_eq!(ck, ["crashed", "failed", "passed", "ran", "skipped"]);
        assert_eq!(v["rows"][0]["verdict"], "fail");
        let d = tempfile::tempdir().unwrap();
        r.write(d.path()).unwrap();
        assert_eq!(ResultJson::read(d.path()).unwrap(), r);
        assert!(!d.path().join(".result.json.tmp").exists());
    }
}
