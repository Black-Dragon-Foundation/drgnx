//! The trail and the Timeline as rows (`work/trail/subscribe`): one session's steps with its conclusions among them,
//! or a lane per agent session, built here (`vegvisir::trail`) and sent per display class as `view-patch`
//! (`docs/develop/hub.md`, "The trail and the Timeline"). Read again from the timeline and the conclusions store after
//! each write and each closed step; each class gets only the rows that changed. Before the rows, the view's model
//! (`model`) for the editor's replica; a Timeline's model again (from what was last read) when the map's selection
//! moves, for the lanes it lights.
//!
//! The Board (`work/board/subscribe`) is a view of the same kind: the tracker's tasks (`tasks/find`, or `plans/get` of
//! its plans) as cards with the agents of a map view on them (`board`), its own model and rows, read again after each
//! write like a trail.

mod board;
pub(crate) mod flow;
mod model;

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::plans::{ByPlan, PlanView};
use runstav::methods::tasks::{FindParams, TaskList};
use runstav::methods::timeline::{Step as WireStep, TimelineParams};
use runstav::methods::view::ViewEnv;
use runstav::methods::work::{
    BoardSubscribe, Conclusion as WireConclusion, ConclusionsParams, FlowSubscribe, TrailClose,
    TrailLane, TrailSubscribe, TrailSubscribed,
};
use runstav::registry::Class;
use runstav::wire::Error;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use vegvisir::trail::{self, Zone};

/// The steps a trail or a lane holds: the session's last ones.
const STEPS: u32 = 500;

/// What one view shows.
#[derive(Clone, Debug)]
enum Sub {
    Trail(String),
    Timeline(Vec<TrailLane>),
    /// A Board: map view, plans.
    Board(String, Vec<String>),
    /// A Flow view: map view, job (none: the newest running job), and which part of the Flow it is.
    Flow(String, Option<String>, flow::Part),
}

/// What a view's rows are built from, read once per refresh for every class.
enum Data {
    /// A window of the session's steps (all when they fit), its conclusions, how many steps it has.
    Trail(Vec<trail::Step>, Vec<trail::Conclusion>, usize),
    Timeline(Vec<trail::Lane>),
    Board(Vec<board::Card>),
    /// The lens's facts, and the part of the Flow the view is.
    Flow(Box<flow::Flow>, flow::Part),
}

/// The trail and Timeline views of every connection, keyed (connection, view).
#[derive(Default)]
pub struct Trails {
    views: Mutex<BTreeMap<(u64, String), Sub>>,
    /// What each view was last built from.
    data: Mutex<BTreeMap<(u64, String), Arc<Data>>>,
    front: OnceLock<Weak<Front>>,
    /// One refresh at a time, so a view's patches go out in the order its data was read.
    busy: tokio::sync::Mutex<()>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Trails {
    /// Connection CONN is gone: its views with it.
    pub fn gone(&self, conn: u64) {
        lock(&self.views).retain(|k, _| k.0 != conn);
        lock(&self.data).retain(|k, _| k.0 != conn);
    }

    /// The selection of a map view of connection CONN moved: its Timelines' models again, for the lanes it lights
    /// (their rows stay).
    pub fn map_moved(&self, conn: u64) {
        let Some(f) = self.front.get().and_then(Weak::upgrade) else {
            return;
        };
        crate::clock::spawn("trail:near", async move {
            let trails = &f.core.trails;
            let _one = trails.busy.lock().await;
            let near = f.core.map.near(conn);
            let mine: Vec<((u64, String), Arc<Data>)> = lock(&trails.data)
                .iter()
                .filter(|(k, d)| k.0 == conn && matches!(***d, Data::Timeline(_)))
                .map(|(k, d)| (k.clone(), d.clone()))
                .collect();
            for (key, data) in mine {
                f.core
                    .views
                    .publish_model(&f, key.0, &key.1, doc_of(&data, &near));
            }
        });
    }

    /// `view/window` of CONN's VIEW: a trail draws again with its window where the editor asked; false when VIEW is
    /// not a trail.
    pub async fn window(&self, f: &Front, conn: u64, view: &str) -> bool {
        let key = (conn, view.to_owned());
        if !matches!(lock(&self.views).get(&key), Some(Sub::Trail(_))) {
            return false;
        }
        self.refresh(f, &key).await;
        true
    }

    /// An env of (connection, view, class) K3 arrived: a trail or Timeline view of that name draws again.
    pub fn view_env(&self, k3: &crate::view::Key) {
        let key = (k3.0, k3.1.clone());
        if !lock(&self.views).contains_key(&key) {
            return;
        }
        let Some(f) = self.front.get().and_then(Weak::upgrade) else {
            return;
        };
        crate::clock::spawn("trail:env", async move {
            f.core.trails.refresh(&f, &key).await;
        });
    }

    /// KEY's view read again and drawn for each class its editor sent an env for.
    async fn refresh(&self, f: &Front, key: &(u64, String)) {
        let _one = self.busy.lock().await;
        let Some(sub) = lock(&self.views).get(key).cloned() else {
            return;
        };
        let data = match sub {
            Sub::Trail(sid) => {
                let from = f.core.views.window_from(key.0, &key.1, "steps");
                let (steps, total) = trail_steps(f, &sid, from).await;
                Data::Trail(steps, conclusions(f, &sid).await, total)
            }
            Sub::Timeline(lanes) => {
                let mut out = Vec::with_capacity(lanes.len());
                for l in lanes {
                    out.push(trail::Lane {
                        id: l.session.clone(),
                        label: l.label.clone(),
                        steps: steps(f, &l.session).await,
                    });
                }
                Data::Timeline(out)
            }
            Sub::Board(map, plans) => Data::Board(board_cards(f, key.0, &map, &plans).await),
            Sub::Flow(map, job, part) => {
                Data::Flow(Box::new(flow_facts(f, key.0, &map, job).await), part)
            }
        };
        let data = Arc::new(data);
        lock(&self.data).insert(key.clone(), data.clone());
        let near = match *data {
            Data::Timeline(_) => f.core.map.near(key.0),
            Data::Trail(..) | Data::Board(_) | Data::Flow(..) => Vec::new(),
        };
        // a tile of the Flow is rows alone, as the map's detail is
        if !matches!(
            *data,
            Data::Flow(_, flow::Part::Detail(_) | flow::Part::Rules)
        ) {
            f.core
                .views
                .publish_model(f, key.0, &key.1, doc_of(&data, &near));
        }
        for class in f.core.views.classes(key.0, &key.1) {
            let k3 = (key.0, key.1.clone(), class);
            f.core
                .views
                .publish_built(f, &k3, |env, fonts| rows(&data, env, fonts));
        }
    }
}

/// DATA's model, the lanes of the sessions NEAR lit.
fn doc_of(data: &Data, near: &[String]) -> crate::view::model::Doc {
    match data {
        Data::Trail(steps, concs, total) => model::trail_doc(steps, concs, *total),
        Data::Timeline(lanes) => model::timeline_doc(lanes, near),
        Data::Board(cards) => board::board_doc(cards),
        Data::Flow(flow, _) => flow::flow_doc(flow),
    }
}

/// DATA's rows for ENV, measured with FONTS, and the images they draw.
fn rows(
    data: &Data,
    env: &ViewEnv,
    fonts: &dyn drgnx_rows::fit::Measure,
) -> (Vec<drgnx_rows::Row>, Vec<(drgnx_rows::ImageId, String)>) {
    let palette = drgnx_rows::svg::Palette(env.palette.clone());
    let renv = crate::work::map::render_env(env, &palette);
    let zone = Zone::parse(&env.tz);
    let only = |rows| (rows, Vec::new());
    match data {
        Data::Trail(steps, concs, _) => only(trail::trail_rows(steps, concs, &renv, zone)),
        Data::Timeline(lanes) => only(trail::timeline_rows(lanes, &renv, fonts, zone)),
        Data::Board(cards) => only(board::board_rows(cards, env)),
        Data::Flow(flow, flow::Part::Lens) => flow::flow_rows(flow, env, fonts),
        Data::Flow(flow, flow::Part::Detail(task)) => only(flow::detail_rows(flow, task, env)),
        Data::Flow(flow, flow::Part::Rules) => flow::rules_rows(flow, env),
    }
}

/// The most pages of `tasks/find` an unscoped Board reads (50 tasks a page).
const BOARD_PAGES: usize = 4;

/// The Board's cards: the tasks of PLANS (each `plans/get`), else every task (`tasks/find`, up to [`BOARD_PAGES`]
/// pages), each with the agent of connection CONN's map view MAP working on it (by the task's id, which the
/// map's agents carry: two tasks of one title never share one). A read that fails leaves its cards out.
async fn board_cards(f: &Front, conn: u64, map: &str, plans: &[String]) -> Vec<board::Card> {
    let caller = hub_caller();
    let mut cards = Vec::new();
    if plans.is_empty() {
        let mut cursor: Option<u64> = None;
        for _ in 0..BOARD_PAGES {
            let Ok(p) = serde_json::from_value::<FindParams>(json!({"cursor": cursor})) else {
                break;
            };
            let Ok(Ok(v)) = crate::graph::serve(
                &f.writer,
                &f.tools,
                f.dirs.get(),
                &caller,
                Params::TasksFind(p),
            )
            .await
            else {
                break;
            };
            let Ok(list) = serde_json::from_value::<TaskList>(v) else {
                break;
            };
            cards.extend(list.tasks.iter().map(|t| board::Card {
                id: t["id"].as_str().unwrap_or_default().to_owned(),
                title: t["title"].as_str().unwrap_or_default().to_owned(),
                status: t["status"].as_str().unwrap_or_default().to_owned(),
                ..board::Card::default()
            }));
            cursor = list.cursor;
            if cursor.is_none() {
                break;
            }
        }
    } else {
        for plan in plans {
            let Ok(p) = serde_json::from_value::<ByPlan>(json!({"plan": plan})) else {
                continue;
            };
            let Ok(view): Result<PlanView, _> =
                crate::runner::effects::plans_get(f, &caller, p).await
            else {
                continue;
            };
            cards.extend(view.tasks.iter().map(|t| board::Card {
                id: t.id.clone(),
                title: t.title.clone(),
                status: t.status.clone(),
                plan: Some(plan.clone()),
                progress: (!t.steps.is_empty()).then(|| {
                    (
                        t.steps.iter().filter(|s| s.done).count() as u32,
                        t.steps.len() as u32,
                    )
                }),
                agent: None,
            }));
        }
    }
    board::put_agents(&mut cards, &f.core.map.agents_of(conn, map));
    cards
}

/// The Flow lens's facts: JOB (else the newest running job, else the newest), its tasks with their evidence, the
/// agents of connection CONN's map view MAP on them, its rule pack, its merge queue and its open `gate` cards.  A read
/// that fails shows an empty lens.
async fn flow_facts(f: &Front, conn: u64, map: &str, job: Option<String>) -> flow::Flow {
    let read = f
        .writer
        .db
        .read(move |c| {
            let job = match job {
                Some(j) => Some(j),
                None => norn::read::jobs::jobs(c, Some("running"))?
                    .into_iter()
                    .next()
                    .or(norn::read::jobs::jobs(c, None)?.into_iter().next()),
            };
            let Some(job) = job else {
                return Ok(None);
            };
            let row = norn::read::jobs::job(c, &job)?;
            // the budget scope the runner books the run's spend under
            let plan = row.as_ref().map(crate::runner::plan_scope);
            let title = row
                .and_then(|j| j.title.or(j.plan))
                .unwrap_or_else(|| job.clone());
            let pack = norn::read::evidence::pack_of_job(c, &job)?;
            let cards = norn::read::cards::cards(c, &job, Some("open"))?;
            let mut tasks = Vec::new();
            for t in norn::read::tasks::tasks(c, &job)? {
                let row = t.row;
                let card = cards.iter().find(|k| {
                    k.task.as_deref() == Some(row.id.as_str()) && k.kind.as_deref() == Some("gate")
                });
                tasks.push(flow::TaskFacts {
                    held: card.map(|k| k.title.clone().unwrap_or_default()),
                    card: card.map(|k| k.id),
                    evidence: norn::read::evidence::of_task(c, &row.id)?,
                    id: row.id,
                    n: row.n,
                    title: row.title.unwrap_or_default(),
                    status: row.status.unwrap_or_default(),
                    agent: row.agent,
                    queue: flow::Queue::None,
                });
            }
            Ok(Some((job, title, plan, pack, tasks)))
        })
        .await;
    let Ok(Some((job, title, plan, pack, mut tasks))) = read else {
        return flow::Flow::default();
    };
    let (ready, batch) = (f.queue.ready(&job), f.queue.batch(&job));
    let agents = f.core.map.agents_of(conn, map);
    for t in &mut tasks {
        if batch.iter().any(|b| b.task == t.id) {
            t.queue = flow::Queue::Batch;
        } else if ready.iter().any(|b| b.task == t.id) {
            t.queue = flow::Queue::Ready;
        }
        if let Some((_, _, label)) = agents.iter().find(|(task, ..)| *task == t.id) {
            t.agent = Some(label.clone());
        }
    }
    let seen = f.queue.seen(&job);
    let names: Vec<(String, String)> = tasks
        .iter()
        .map(|t| (t.id.clone(), format!("T{}", t.n)))
        .collect();
    let batch = batch
        .iter()
        .map(|b| {
            let t = tasks.iter().find(|t| t.id == b.task);
            flow::Member {
                label: t.map_or_else(|| b.task.clone(), |t| format!("T{}", t.n)),
                title: t.map(|t| t.title.clone()).unwrap_or_default(),
                tip: b.tip[..b.tip.len().min(7)].to_owned(),
                said: flow::note(
                    seen.said.get(&b.task).map(String::as_str),
                    seen.audited.get(&b.task).map(String::as_str),
                    &names,
                ),
            }
        })
        .collect();
    // the gates' runs at the trees they judged last: the batch's groups (`batch:JOB@TREE`), the push tiers
    // (`push:JOB@TREE`, the pack's tiers)
    let tiers = pack
        .as_ref()
        .map(|p| p.push_tiers.clone())
        .unwrap_or_default();
    let (j, g, p) = (job.clone(), seen.groups.clone(), seen.push.clone());
    let runs = f
        .writer
        .db
        .read(move |c| {
            let groups = match g {
                Some((tree, checks)) => Some(flow::Runs {
                    evidence: norn::read::evidence::of_task(c, &format!("batch:{j}@{tree}"))?,
                    at: tree,
                    checks,
                }),
                None => None,
            };
            let push = match p {
                Some((_head, tree)) => Some(flow::Runs {
                    evidence: norn::read::evidence::of_task(c, &format!("push:{j}@{tree}"))?,
                    at: tree,
                    checks: tiers,
                }),
                None => None,
            };
            Ok((groups, push))
        })
        .await;
    let (groups, push) = runs.unwrap_or_default();
    flow::Flow {
        job,
        title,
        pack,
        tasks,
        batch,
        groups,
        push,
        machines: f.core.map.machines_of(conn, map),
        cost: plan.and_then(|p| plan_cost(&f.core.budgets, &p)),
    }
}

/// What the plan scope PLAN (`runner::plan_scope`) spent in USD (measured and estimated) and its USD budget: none when
/// it has neither.
fn plan_cost(b: &crate::budget::Budgets, plan: &str) -> Option<(f64, Option<f64>)> {
    use runstav::methods::matrix::Unit;
    use runstav::methods::timeline::BudgetScope;
    let v = b.view(&BudgetScope::Plan(runstav::types::Bounded(plan.to_owned())));
    let spent: f64 = v
        .spent
        .iter()
        .filter(|l| matches!(l.unit, Unit::Usd | Unit::UsdEst))
        .map(|l| l.amount)
        .sum();
    let limit = v
        .limits
        .iter()
        .find(|l| matches!(l.unit, Unit::Usd))
        .map(|l| l.amount);
    (spent > 0.0 || limit.is_some()).then_some((spent, limit))
}

/// The caller the trail reads the store as.
fn hub_caller() -> Caller {
    Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

/// Session SID's last steps, oldest first (none when it has none or the read failed).
async fn steps(f: &Front, sid: &str) -> Vec<trail::Step> {
    steps_before(f, sid, None).await
}

/// Session SID's [`STEPS`] steps before seq BEFORE (none: its last), oldest first.
async fn steps_before(f: &Front, sid: &str, before: Option<u64>) -> Vec<trail::Step> {
    let Ok(p) = serde_json::from_value::<TimelineParams>(
        json!({"scope": "session", "id": sid, "limit": STEPS, "before": before}),
    ) else {
        return Vec::new();
    };
    match crate::timeline::get(f, &hub_caller(), p).await {
        Ok(t) => t.steps.iter().map(step_of).collect(),
        Err(_) => Vec::new(),
    }
}

/// A trail's steps of session SID: its last [`STEPS`], or, when the editor asked for a window FROM (`view/window`,
/// a position in the whole trail; clamped), the [`STEPS`] from there; and how many the session has (seq counts them
/// from 1).
async fn trail_steps(f: &Front, sid: &str, from: Option<usize>) -> (Vec<trail::Step>, usize) {
    let last = steps(f, sid).await;
    let total = last
        .last()
        .map_or(0, |s| usize::try_from(s.seq).unwrap_or(usize::MAX));
    let Some(from) = from.map(|n| n.min(total.saturating_sub(STEPS as usize))) else {
        return (last, total);
    };
    if from + STEPS as usize >= total {
        return (last, total);
    }
    let page = steps_before(f, sid, Some((from + STEPS as usize + 1) as u64)).await;
    (page, total)
}

/// Session SID's conclusions.
async fn conclusions(f: &Front, sid: &str) -> Vec<trail::Conclusion> {
    let p = ConclusionsParams {
        session: sid.to_owned(),
    };
    match crate::work::conclusions::get(f, &hub_caller(), p).await {
        Ok(c) => c.conclusions.iter().map(conclusion_of).collect(),
        Err(_) => Vec::new(),
    }
}

fn step_of(s: &WireStep) -> trail::Step {
    let d = s.detail.clone().unwrap_or_default();
    trail::Step {
        id: s.id,
        seq: s.seq,
        class: json!(s.class).as_str().unwrap_or("tool").to_owned(),
        tool: s.tool.clone(),
        detail: trail::Detail {
            kind: d.kind,
            path: d.path,
            line_start: d.line_start,
            line_end: d.line_end,
            query: d.query,
            url: d.url,
            title: d.title,
        },
        start: s.start,
        end: s.end,
    }
}

fn conclusion_of(c: &WireConclusion) -> trail::Conclusion {
    let mut rests_on = c.links.named.clone();
    for id in &c.links.since_last {
        if !rests_on.contains(id) {
            rests_on.push(*id);
        }
    }
    trail::Conclusion {
        n: c.n,
        kind: c.kind.clone(),
        text: c.text.clone(),
        step: c.step,
        rests_on,
        unmatched: c
            .links
            .unmatched
            .iter()
            .filter_map(|s| s.path.clone().or_else(|| s.url.clone()))
            .collect(),
    }
}

/// `work/trail/subscribe`: VIEW of CALLER's connection shows a session's trail or a Timeline of sessions; its rows go
/// to each class its editor sent a `view/env` for, the first patch of each a reset, before the answer.
pub async fn subscribe(f: &Front, c: &Caller, p: TrailSubscribe) -> Result<TrailSubscribed, Error> {
    let sub = match p.session {
        Some(s) => Sub::Trail(s),
        None => Sub::Timeline(p.lanes),
    };
    let key = (c.conn_id, p.view);
    lock(&f.core.trails.views).insert(key.clone(), sub);
    f.core.views.model_restart(key.0, &key.1);
    f.core.trails.refresh(f, &key).await;
    Ok(TrailSubscribed {
        hub: f.core.views.hub(),
    })
}

/// `work/board/subscribe`: VIEW of CALLER's connection shows the Board (the tasks of `plans`, else every task, with
/// the agents of map view `map`); its model and rows go out as a trail's do, before the answer.
pub async fn board_subscribe(
    f: &Front,
    c: &Caller,
    p: BoardSubscribe,
) -> Result<TrailSubscribed, Error> {
    let key = (c.conn_id, p.view);
    lock(&f.core.trails.views).insert(key.clone(), Sub::Board(p.map, p.plans));
    f.core.views.model_restart(key.0, &key.1);
    f.core.trails.refresh(f, &key).await;
    Ok(TrailSubscribed {
        hub: f.core.views.hub(),
    })
}

/// `work/flow/subscribe`: VIEW of CALLER's connection shows the Flow lens of `job` (else the newest running job), with
/// the agents of map view `map`; its model and rows go out as a Board's do, before the answer.  With `detail`, the
/// view is that task's detail tile instead, with `rules` the Rules tile: rows alone, no model.
pub async fn flow_subscribe(
    f: &Front,
    c: &Caller,
    p: FlowSubscribe,
) -> Result<TrailSubscribed, Error> {
    let key = (c.conn_id, p.view);
    let part = match (p.detail, p.rules) {
        (Some(task), _) => flow::Part::Detail(task),
        (None, true) => flow::Part::Rules,
        (None, false) => flow::Part::Lens,
    };
    let lens = part == flow::Part::Lens;
    lock(&f.core.trails.views).insert(key.clone(), Sub::Flow(p.map, p.job, part));
    if lens {
        f.core.views.model_restart(key.0, &key.1);
    }
    f.core.trails.refresh(f, &key).await;
    Ok(TrailSubscribed {
        hub: f.core.views.hub(),
    })
}

/// `work/trail/close`: VIEW of CALLER's connection ends.
pub fn close(f: &Front, c: &Caller, p: TrailClose) -> Result<bool, Error> {
    let key = (c.conn_id, p.view);
    lock(&f.core.trails.data).remove(&key);
    Ok(lock(&f.core.trails.views).remove(&key).is_some())
}

/// The trails' background: every view read again after each write (coalesced) and each closed step.
pub async fn run(front: Arc<Front>) {
    let _ = front.core.trails.front.set(Arc::downgrade(&front));
    let signals = front.writer.signals.clone();
    loop {
        signals.trail.notified().await;
        let keys: Vec<(u64, String)> = lock(&front.core.trails.views).keys().cloned().collect();
        for k in keys {
            front.core.trails.refresh(&front, &k).await;
        }
    }
}
