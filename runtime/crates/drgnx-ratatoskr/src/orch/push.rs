//! The push gate (`docs/develop/orchestration.md`, "The push gate"): a job's agent asking to push (`push.ci`,
//! `push.main`) is refused until the pack's tiers are green on the exact commit's tree with the hub's env stamp now
//! (`vordr::push::judge`); the missing tiers start through the queue as evidence of `push:JOB@TREE`.  The push itself
//! stays the user's: a push the gate lets through still meets the matrix.

use std::path::Path;

use vordr::push::{Push, judge};

use crate::front::Front;
use crate::orch::gates::{git, run_of, start};

/// Why JOB's push from the tree DIR (its `HEAD`, the commit a push sends) is refused, or none when it may go on to
/// the matrix.  A job with no rule pack has no push gate.
pub async fn refusal(front: &Front, job: &str, dir: &Path) -> Option<String> {
    let j = job.to_owned();
    let pack = front
        .writer
        .db
        .read(move |c| norn::read::evidence::pack_of_job(c, &j))
        .await
        .ok()
        .flatten()?;
    if !pack.on("push-gate") {
        return None;
    }
    let d = dir.to_owned();
    let found = crate::clock::blocking(move || {
        let top = git(&d, &["rev-parse", "--show-toplevel"])?
            .trim()
            .to_owned();
        let head = git(&d, &["rev-parse", "HEAD"])?.trim().to_owned();
        let tree = git(&d, &["rev-parse", "HEAD^{tree}"])?.trim().to_owned();
        Ok::<_, String>((top, head, tree))
    })
    .await;
    let (top, head, tree) = match found {
        Ok(Ok(t)) => t,
        Ok(Err(e)) => return Some(format!("the push gate cannot read the commit: {e}")),
        Err(e) => return Some(format!("the push gate cannot read the commit: {e}")),
    };
    let key = format!("push:{job}@{tree}");
    let k = key.clone();
    let evidence = match front
        .writer
        .db
        .read(move |c| norn::read::evidence::of_task(c, &k))
        .await
    {
        Ok(e) => e,
        Err(e) => return Some(format!("the push gate cannot read its runs: {e}")),
    };
    match judge(&pack, &evidence, &tree, crate::exec::env_stamp()) {
        Push::Ready => None,
        Push::NoTiers => Some("the push gate is on but the job's pack names no tiers".into()),
        Push::Red(red) => {
            let said: Vec<String> = red
                .iter()
                .map(|(t, rows)| format!("{t}: {}", rows.join(", ")))
                .collect();
            Some(format!(
                "the full run before a push fails at {head}: {}",
                said.join("; ")
            ))
        }
        Push::Missing(tiers) => {
            for t in &tiers {
                if let Err(e) = start(front, &key, Path::new(&top), &head, &tree, &run_of(t)).await
                {
                    return Some(format!("the push gate could not start {}: {e}", t.name));
                }
            }
            let names: Vec<&str> = tiers.iter().map(|t| t.name.as_str()).collect();
            Some(format!(
                "a push needs one full run on the exact commit first; running now at {head}: {} (ask again once \
                 they are green)",
                names.join(", ")
            ))
        }
    }
}
