//! The Schedule's facts (`work/schedule/subscribe`, `docs/develop/hub.md`, "The Schedule"): the List of the
//! connection's map view, each row with what its bar is drawn from.  A task's span is its steps' roll-up (first start,
//! last end); a task of a running job has its forecast of what remains (`forecast/get {remaining}`, cached) and its
//! baseline; a plan's bar is its tasks' span and its running job's own wall time (its draws, never a sum of its
//! tasks'); a spec's spans its plans.  The rows (`vegvisir::schedule`) are built from these with the clock.

use crate::front::Front;
use crate::work::map::ListRow;
use runstav::methods::forecast as wire;
use std::collections::BTreeMap;
use vegvisir::Kind;
use vegvisir::schedule::{BarFacts, SchedRow};

/// A row of the Schedule and its bar's facts (none: a row with no bar, as the List's closing row).
pub(crate) type Fact = (SchedRow, Option<BarFacts>);

/// A running job's forecast of what remains, and when its run started (its first step; none before one).
struct JobFacts {
    job: String,
    forecast: wire::Forecast,
    start: Option<f64>,
}

/// The ids a plan item's job may carry: the item's own (`plan:ID`) and the bare ID.
fn plan_keys(item: &str) -> (String, String) {
    (
        item.to_owned(),
        item.strip_prefix("plan:").unwrap_or(item).to_owned(),
    )
}

/// The Schedule's rows of connection CONN's List at NOW, with the machines (label, slots used, slots); empty when CONN
/// has no map view.
pub(crate) async fn facts(f: &Front, conn: u64, now: f64) -> (Vec<Fact>, Vec<(String, u32, u32)>) {
    let Some((list, machines)) = f.core.map.list_of(conn) else {
        return (Vec::new(), Vec::new());
    };
    // the plans' running jobs
    let plans: Vec<(String, String)> = list
        .iter()
        .filter(|r| r.kind == Some(Kind::Plan))
        .map(|r| plan_keys(&r.entry.item.0))
        .collect();
    let jobs: Vec<Option<String>> = f
        .writer
        .db
        .read(move |c| {
            let mut out = Vec::with_capacity(plans.len());
            let mut st = c.prepare(
                "select id from job where plan in (?1, ?2) and status in ('running', 'paused') \
                 order by created desc limit 1",
            )?;
            for (a, b) in &plans {
                out.push(st.query_row((a, b), |r| r.get::<_, String>(0)).ok());
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();
    let mut by_plan: BTreeMap<String, JobFacts> = BTreeMap::new();
    let plan_items = list.iter().filter(|r| r.kind == Some(Kind::Plan));
    for (row, job) in plan_items.zip(jobs) {
        let Some(job) = job else { continue };
        if let Ok(forecast) = crate::forecast::remaining_forecast(f, &job, now).await {
            by_plan.insert(
                row.entry.item.0.clone(),
                JobFacts {
                    job,
                    forecast,
                    start: None,
                },
            );
        }
    }
    // the spans: every task row's, and every running job's tasks' (their run's start)
    let mut ids: Vec<String> = list
        .iter()
        .filter(|r| r.kind == Some(Kind::Task))
        .map(|r| task_key(&r.entry.item.0))
        .collect();
    for j in by_plan.values() {
        ids.extend(
            j.forecast
                .tasks
                .iter()
                .map(|t| format!("{}#{}", j.job, t.n)),
        );
    }
    let spans: BTreeMap<String, (Option<f64>, Option<f64>)> = f
        .writer
        .db
        .read(move |c| {
            let mut out = BTreeMap::new();
            for id in ids {
                let r = norn::read::steps::rollup(c, norn::read::steps::Scope::Task, &id)?;
                out.insert(id, (r.first, r.last));
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();
    for j in by_plan.values_mut() {
        j.start = j
            .forecast
            .tasks
            .iter()
            .filter_map(|t| spans.get(&format!("{}#{}", j.job, t.n)).and_then(|s| s.0))
            .reduce(f64::min);
    }
    (rows_of(&list, &by_plan, &spans), machines)
}

/// The step's task key of a task item (`task:ID` → `ID`).
fn task_key(item: &str) -> String {
    item.strip_prefix("task:").unwrap_or(item).to_owned()
}

/// A task item's job and number, when its id is a job's task (`JOB#N`).
fn job_task(item: &str) -> Option<(&str, u64)> {
    let (job, n) = task_key_ref(item).rsplit_once('#')?;
    Some((job, n.parse().ok()?))
}

fn task_key_ref(item: &str) -> &str {
    item.strip_prefix("task:").unwrap_or(item)
}

/// LIST's rows with their bars' facts: tasks from SPANS and their job's forecast in BY_PLAN, plans from their tasks
/// and their job, specs from their plans.
fn rows_of(
    list: &[ListRow],
    by_plan: &BTreeMap<String, JobFacts>,
    spans: &BTreeMap<String, (Option<f64>, Option<f64>)>,
) -> Vec<Fact> {
    let jobs: BTreeMap<&str, &JobFacts> = by_plan.values().map(|j| (j.job.as_str(), j)).collect();
    let mut out: Vec<Fact> = list
        .iter()
        .map(|r| {
            let row = SchedRow {
                item: r.entry.item.0.clone(),
                label: r.entry.label.clone(),
                depth: r.entry.depth,
                bar: None,
                budget: r.entry.budget.clone(),
            };
            let facts = match r.kind {
                Some(Kind::Task) => Some(task_facts(
                    r,
                    jobs.get(job_task(&r.entry.item.0).map_or("", |j| j.0)),
                    spans,
                )),
                Some(Kind::Plan) => Some(BarFacts {
                    done: r.done,
                    target: r.target,
                    whole: true,
                    ..BarFacts::default()
                }),
                // a spec, or the plans no spec holds
                _ if r.entry.depth == 0 && r.entry.count.is_none() => Some(BarFacts {
                    done: r.done,
                    target: r.target,
                    whole: true,
                    ..BarFacts::default()
                }),
                _ => None,
            };
            (row, facts)
        })
        .collect();
    // a plan: its tasks' span and its job's wall time and baseline; then a spec: its plans'
    for depth in [1u8, 0] {
        for i in 0..out.len() {
            if out[i].0.depth != depth || out[i].1.is_none() {
                continue;
            }
            let kids: Vec<BarFacts> = out[i + 1..]
                .iter()
                .take_while(|(r, _)| r.depth > depth)
                .filter(|(r, _)| r.depth == depth + 1)
                .filter_map(|(_, f)| f.clone())
                .collect();
            let job = by_plan.get(&out[i].0.item).filter(|_| depth == 1);
            let Some(f) = out[i].1.as_mut() else { continue };
            span_of(f, &kids, job);
        }
    }
    out
}

/// A task's facts: its span, and its job's forecast of it and baseline.
fn task_facts(
    r: &ListRow,
    job: Option<&&JobFacts>,
    spans: &BTreeMap<String, (Option<f64>, Option<f64>)>,
) -> BarFacts {
    let (first, last) = spans
        .get(&task_key(&r.entry.item.0))
        .copied()
        .unwrap_or((None, None));
    let mut f = BarFacts {
        started: first,
        ended: last,
        done: r.done,
        waiting: r.waiting,
        machine: r.entry.machine.clone(),
        ..BarFacts::default()
    };
    if let (Some(j), Some((_, n))) = (job, job_task(&r.entry.item.0))
        && let Some(t) = j.forecast.tasks.iter().find(|t| t.n == n)
    {
        f.start = Some(t.start.p50);
        f.p50 = Some(t.finish.p50);
        f.p90 = Some(t.finish.p90);
        f.baseline = baseline_of(j).and_then(|(start, b)| {
            b.tasks
                .iter()
                .find(|bt| bt.n == n)
                .map(|bt| start + bt.finish.p50)
        });
    }
    f
}

/// JOB's baseline and its run's start (the baseline's offsets count from it).
fn baseline_of(j: &JobFacts) -> Option<(f64, &wire::Baseline)> {
    Some((j.start?, j.forecast.baseline.as_ref()?))
}

/// F's span from its children KIDS (first start, last end when every one has ended), and, for a plan with a running
/// JOB, the job's own wall time from the forecast's clock and its baseline; a spec takes its plans' latest finish.
fn span_of(f: &mut BarFacts, kids: &[BarFacts], job: Option<&JobFacts>) {
    f.started = kids.iter().filter_map(|k| k.started).reduce(f64::min);
    f.ended = if kids
        .iter()
        .all(|k| k.ended.is_some() || k.started.is_none())
    {
        kids.iter().filter_map(|k| k.ended).reduce(f64::max)
    } else {
        None
    };
    f.waiting = false;
    match job {
        Some(j) => {
            let at = j.forecast.made_at;
            f.p50 = Some(at + j.forecast.wall_secs.p50);
            f.p90 = Some(at + j.forecast.wall_secs.p90);
            if let Some((start, b)) = baseline_of(j) {
                f.baseline = Some(start + b.finish.p50);
                f.baseline_wall = Some(b.finish.p50);
            }
        }
        None => {
            f.p50 = kids.iter().filter_map(|k| k.p50).reduce(f64::max);
            f.p90 = kids.iter().filter_map(|k| k.p90).reduce(f64::max);
        }
    }
    if f.started.is_none() {
        f.start = kids.iter().filter_map(|k| k.start).reduce(f64::min);
    }
}
