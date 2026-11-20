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
    BoardSubscribe, Conclusion as WireConclusion, ConclusionsParams, FlowSubscribe, ScheduleGroup,
    ScheduleSet, ScheduleSubscribe, TrailClose, TrailFilter as WireFilter, TrailLane, TrailSet,
    TrailSubscribe, TrailSubscribed, Window as WireWindow,
};
use runstav::registry::Class;
use runstav::wire::Error;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use vegvisir::schedule::{self, SchedRow};
use vegvisir::trail::{self, NowLine, TrailFilter, Window, Zone};

/// The steps a trail or a lane holds: the session's last ones.
const STEPS: u32 = 500;

/// A Timeline view: its lanes, its window (none: the time their last steps cover), whether it follows now, and what
/// it keeps in colour.
#[derive(Clone, Debug)]
struct Timeline {
    lanes: Vec<TrailLane>,
    window: Option<Window>,
    follow: bool,
    filter: TrailFilter,
}

/// A Schedule view: its window and grouping.
#[derive(Clone, Debug)]
struct Schedule {
    window: Window,
    group: ScheduleGroup,
}

/// What one view shows.
#[derive(Clone, Debug)]
enum Sub {
    Trail(String),
    Timeline(Timeline),
    Schedule(Schedule),
    /// A Board: map view, plans.
    Board(String, Vec<String>),
    /// A Flow view: map view, job (none: the newest running job), and which part of the Flow it is.
    Flow(String, Option<String>, flow::Part),
}

/// What a view's rows are built from, read once per refresh for every class.
enum Data {
    /// A window of the session's steps (all when they fit), its conclusions, how many steps it has, and the fixed clock
    /// of a test hub's scene (none: the wall clock, which an open step's elapsed time follows).
    Trail(Vec<trail::Step>, Vec<trail::Conclusion>, usize, Option<f64>),
    Timeline(Arc<Vec<trail::Lane>>, Shown),
    /// The Schedule's rows with their bars' facts, the machines, the grouping.
    Schedule(Arc<SchedData>, ScheduleGroup, Shown),
    Board(Vec<board::Card>),
    /// The lens's facts, and the part of the Flow the view is.
    Flow(Box<flow::Flow>, flow::Part),
}

/// The Schedule's rows and their bars' facts, and the machines (label, slots used, slots).
type SchedData = (Vec<crate::work::schedule::Fact>, Vec<(String, u32, u32)>);

/// What a Timeline or the Schedule is drawn over: the window, the filter, the now-line (drawn at most every 5 s,
/// [`NowLine`]) and the axis's clock (each second).
#[derive(Clone, Copy, Debug)]
struct Shown {
    win: Window,
    filter: TrailFilter,
    now_line: Option<f64>,
    axis_now: f64,
}

/// The columns the now-line's move is judged on: finer than any track, so a move a track shows is never held back
/// (one it does not show changes no row, and the diff sends nothing).
const NOW_COLS: u32 = 4096;

/// What part of its window a followed Timeline keeps after now.
const FOLLOW_AHEAD: f64 = 0.1;

/// The window a followed Timeline over W shows at NOW (none: it stays).  Smoothly it moves at every redraw of the
/// now-line, keeping [`FOLLOW_AHEAD`] of it after now; with REDUCED motion (the timeline spec's §11) it stays until now
/// reaches its end, then steps on by half its span, now at its middle.
fn followed(w: Window, now: f64, reduced: bool) -> Option<Window> {
    let span = w.to - w.from;
    if reduced {
        return (now >= w.to).then(|| Window {
            from: now - 0.5 * span,
            to: now + 0.5 * span,
        });
    }
    Some(Window {
        from: now - (1.0 - FOLLOW_AHEAD) * span,
        to: now + FOLLOW_AHEAD * span,
    })
}

/// The wire's window as the rows take it.
fn window_of(w: WireWindow) -> Window {
    Window {
        from: w.from,
        to: w.to,
    }
}

fn filter_of(f: Option<WireFilter>) -> TrailFilter {
    match f.unwrap_or_default() {
        WireFilter::All => TrailFilter::All,
        WireFilter::Edits => TrailFilter::Edits,
        WireFilter::Waits => TrailFilter::Waits,
    }
}

/// A session's steps and conclusions (a test hub's scene seeds them).
#[cfg(feature = "test-hooks")]
type SceneTrail = (Vec<trail::Step>, Vec<trail::Conclusion>);

/// The trail and Timeline views of every connection, keyed (connection, view).
#[derive(Default)]
pub struct Trails {
    views: Mutex<BTreeMap<(u64, String), Sub>>,
    /// What each view was last built from.
    data: Mutex<BTreeMap<(u64, String), Arc<Data>>>,
    front: OnceLock<Weak<Front>>,
    /// The steps and conclusions a test hub's scene gives a session (`orch::scene`), by session id: its trail shows
    /// them in place of the timeline's.
    #[cfg(feature = "test-hooks")]
    scene: Mutex<BTreeMap<String, SceneTrail>>,
    /// One refresh at a time, so a view's patches go out in the order its data was read.
    busy: tokio::sync::Mutex<()>,
    /// Each Timeline's and Schedule's now-line: when it was last drawn.
    lines: Mutex<BTreeMap<(u64, String), NowLine>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Trails {
    /// Session SID's trail in a test hub's scene: STEPS and CONCS.
    #[cfg(feature = "test-hooks")]
    pub fn scene(&self, sid: &str, steps: Vec<trail::Step>, concs: Vec<trail::Conclusion>) {
        lock(&self.scene).insert(sid.to_owned(), (steps, concs));
    }

    /// Connection CONN is gone: its views with it.
    pub fn gone(&self, conn: u64) {
        lock(&self.views).retain(|k, _| k.0 != conn);
        lock(&self.data).retain(|k, _| k.0 != conn);
        lock(&self.lines).retain(|k, _| k.0 != conn);
    }

    /// KEY's now-line at NOW over WINDOW: when it is drawn (now when it is due, else when it was last), and the window
    /// a FOLLOWed view moves to when it is due (now kept in view, [`FOLLOW_AHEAD`] of it after now), recorded in the
    /// view.
    fn clock(
        &self,
        key: &(u64, String),
        window: Option<Window>,
        follow: bool,
        reduced: bool,
        now: f64,
    ) -> (Option<Window>, f64) {
        let col = window.and_then(|w| trail::now_col(&w, NOW_COLS, now));
        let (due, at) = {
            let mut lines = lock(&self.lines);
            let line = lines.entry(key.clone()).or_default();
            let due = line.due(now, col);
            (due, line.drawn.map_or(now, |d| d.0))
        };
        let win = match window
            .filter(|_| follow && due)
            .and_then(|w| followed(w, now, reduced))
        {
            Some(moved) => {
                if let Some(Sub::Timeline(t)) = lock(&self.views).get_mut(key) {
                    t.window = Some(moved);
                }
                // the line is judged on the window it moved to from now on
                lock(&self.lines).insert(
                    key.clone(),
                    NowLine {
                        drawn: Some((now, trail::now_col(&moved, NOW_COLS, now))),
                    },
                );
                Some(moved)
            }
            _ => window,
        };
        (win, at)
    }

    /// Whether KEY's now-line would be drawn again at NOW over WINDOW (nothing recorded).
    fn due(&self, key: &(u64, String), window: Option<Window>, now: f64) -> bool {
        let col = window.and_then(|w| trail::now_col(&w, NOW_COLS, now));
        let mut line = lock(&self.lines).get(key).copied().unwrap_or_default();
        line.due(now, col)
    }

    /// A second passed: a Timeline or Schedule view KEY draws its axis again (its now-line when due) from what it last
    /// read; a followed Timeline whose window moves reads again.  False when KEY is neither.
    async fn tick(&self, f: &Front, key: &(u64, String)) -> bool {
        let now = crate::clock::wall_secs();
        let follow = match lock(&self.views).get(key) {
            Some(Sub::Timeline(t)) => t.follow && self.due(key, t.window, now),
            Some(Sub::Schedule(_)) => false,
            _ => return false,
        };
        if follow {
            self.refresh(f, key).await;
            return true;
        }
        let _one = self.busy.lock().await;
        let Some(data) = lock(&self.data).get(key).cloned() else {
            return true;
        };
        let data = match &*data {
            Data::Timeline(lanes, sh) => {
                let (_, at) = self.clock(key, Some(sh.win), false, false, now);
                Data::Timeline(
                    lanes.clone(),
                    Shown {
                        now_line: Some(at),
                        axis_now: now,
                        ..*sh
                    },
                )
            }
            Data::Schedule(d, g, sh) => {
                let (_, at) = self.clock(key, Some(sh.win), false, false, now);
                Data::Schedule(
                    d.clone(),
                    *g,
                    Shown {
                        now_line: Some(at),
                        axis_now: now,
                        ..*sh
                    },
                )
            }
            _ => return true,
        };
        let data = Arc::new(data);
        lock(&self.data).insert(key.clone(), data.clone());
        for class in f.core.views.classes(key.0, &key.1) {
            let k3 = (key.0, key.1.clone(), class);
            f.core
                .views
                .publish_built(f, &k3, |env, fonts| rows(&data, env, fonts));
        }
        true
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
                .filter(|(k, d)| k.0 == conn && matches!(***d, Data::Timeline(..)))
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
                #[cfg(feature = "test-hooks")]
                let seeded = lock(&self.scene).get(&sid).cloned();
                #[cfg(not(feature = "test-hooks"))]
                let seeded: Option<(Vec<trail::Step>, Vec<trail::Conclusion>)> = None;
                if let Some((steps, concs)) = seeded {
                    let total = steps.len();
                    // the scene's clock: the open step has run 32 s (work-space-dark.html: "32 s…")
                    let clock = steps
                        .iter()
                        .rev()
                        .find(|s| s.end.is_none())
                        .map(|s| s.start + 32.0);
                    Data::Trail(steps, concs, total, clock)
                } else {
                    let from = f.core.views.window_from(key.0, &key.1, "steps");
                    let (steps, total) = trail_steps(f, &sid, from).await;
                    Data::Trail(steps, conclusions(f, &sid).await, total, None)
                }
            }
            Sub::Timeline(t) => {
                let now = crate::clock::wall_secs();
                let reduced = f.core.views.reduced_motion(key.0, &key.1);
                let (win, at) = self.clock(key, t.window, t.follow, reduced, now);
                let lanes = match win {
                    Some(w) => window_lanes(f, &t.lanes, w).await,
                    None => {
                        let mut out = Vec::with_capacity(t.lanes.len());
                        for l in &t.lanes {
                            out.push(trail::Lane {
                                id: l.session.clone(),
                                label: l.label.clone(),
                                steps: steps(f, &l.session).await,
                            });
                        }
                        out
                    }
                };
                let win = win.unwrap_or_else(|| {
                    let (from, to) = trail::range(&lanes);
                    Window { from, to }
                });
                let shown = Shown {
                    win,
                    filter: t.filter,
                    now_line: Some(at),
                    axis_now: now,
                };
                Data::Timeline(Arc::new(lanes), shown)
            }
            Sub::Schedule(s) => {
                let now = crate::clock::wall_secs();
                let (_, at) = self.clock(key, Some(s.window), false, false, now);
                let facts = crate::work::schedule::facts(f, key.0, at).await;
                let shown = Shown {
                    win: s.window,
                    filter: TrailFilter::All,
                    now_line: Some(at),
                    axis_now: now,
                };
                Data::Schedule(Arc::new(facts), s.group, shown)
            }
            Sub::Board(map, plans) => Data::Board(board_cards(f, key.0, &map, &plans).await),
            Sub::Flow(map, job, part) => {
                Data::Flow(Box::new(flow_facts(f, key.0, &map, job).await), part)
            }
        };
        let data = Arc::new(data);
        lock(&self.data).insert(key.clone(), data.clone());
        let near = match *data {
            Data::Timeline(..) => f.core.map.near(key.0),
            Data::Trail(..) | Data::Board(_) | Data::Flow(..) | Data::Schedule(..) => Vec::new(),
        };
        // a tile of the Flow is rows alone, as the map's detail is; so is the Schedule (the List's model is the map's)
        if !matches!(
            *data,
            Data::Flow(_, flow::Part::Detail(_) | flow::Part::Rules(_)) | Data::Schedule(..)
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
        Data::Trail(steps, concs, total, _) => model::trail_doc(steps, concs, *total),
        Data::Timeline(lanes, _) => model::timeline_doc(lanes, near),
        Data::Schedule(..) => crate::view::model::Doc::default(),
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
        Data::Trail(steps, concs, _, clock) => trail::trail_rows_with_images(
            steps,
            concs,
            &renv,
            zone,
            Some(clock.unwrap_or_else(crate::clock::wall_secs)),
        ),
        Data::Timeline(lanes, sh) => only(trail::timeline_rows(
            lanes,
            &renv,
            fonts,
            zone,
            &sh.win,
            trail::track_cols(&renv),
            sh.filter,
            sh.now_line,
            sh.axis_now,
        )),
        Data::Schedule(d, group, sh) => {
            let now = sh.now_line.unwrap_or(sh.axis_now);
            let rows: Vec<SchedRow> =
                d.0.iter()
                    .map(|(r, f)| SchedRow {
                        bar: f.as_ref().map(|f| schedule::bar(f, now)),
                        ..r.clone()
                    })
                    .collect();
            let rows = match group {
                ScheduleGroup::Plan => rows,
                ScheduleGroup::Machine => schedule::by_machine(&rows, &d.1),
            };
            only(schedule::schedule_rows(
                &rows,
                &renv,
                fonts,
                zone,
                &sh.win,
                trail::track_cols(&renv),
                sh.now_line,
                sh.axis_now,
            ))
        }
        Data::Board(cards) => only(board::board_rows(cards, env)),
        Data::Flow(flow, flow::Part::Lens) => flow::flow_rows(flow, env, fonts),
        Data::Flow(flow, flow::Part::Detail(task)) => flow::detail_tile(flow, task, env, fonts),
        Data::Flow(flow, flow::Part::Rules(task)) => {
            flow::rules_rows(flow, task.as_deref(), env, fonts)
        }
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
            // the budget the run spends from: its plan's (every run of it), or its own with no plan
            let plan = row.as_ref().map(|j| {
                crate::runner::plan_scope(j).unwrap_or_else(|| crate::runner::run_scope(j))
            });
            // the run's facts its first start recorded (`runner::tick::run_facts`) and the user's order
            let data = row
                .as_ref()
                .and_then(|j| j.data.clone())
                .unwrap_or_default();
            let meta = (
                data.get("agents")
                    .and_then(Value::as_u64)
                    .and_then(|n| u32::try_from(n).ok()),
                data.get("order")
                    .and_then(Value::as_array)
                    .is_some_and(|a| !a.is_empty()),
                data.get("base").and_then(Value::as_str).map(str::to_owned),
            );
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
                // where its tree started and the commits the merge gate checked (`orch::gates::before_merge`)
                let of = |bucket: &str| data.get(bucket).and_then(|b| b.get(&row.id));
                let commits = of("commits")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|c| flow::CommitFact {
                                sha: c["sha"].as_str().unwrap_or_default().to_owned(),
                                subject: c["subject"].as_str().unwrap_or_default().to_owned(),
                                tests: c["tests"].as_bool().unwrap_or(false),
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                tasks.push(flow::TaskFacts {
                    base: of("bases").and_then(Value::as_str).map(str::to_owned),
                    commits,
                    held: card.map(|k| k.title.clone().unwrap_or_default()),
                    card: card.map(|k| k.id),
                    evidence: norn::read::evidence::of_task(c, &row.id)?,
                    id: row.id,
                    n: row.n,
                    title: row.title.unwrap_or_default(),
                    status: row.status.unwrap_or_default(),
                    agent: row.agent,
                    queue: flow::Queue::None,
                    ..flow::TaskFacts::default()
                });
            }
            Ok(Some((job, title, plan, pack, tasks, meta)))
        })
        .await;
    let Ok(Some((job, title, plan, pack, mut tasks, (agents_at_once, ordered, base)))) = read
    else {
        return flow::Flow::default();
    };
    let (ready, batch) = (f.queue.ready(&job), f.queue.batch(&job));
    let agents = f.core.map.task_agents_of(conn, map);
    for t in &mut tasks {
        if batch.iter().any(|b| b.task == t.id) {
            t.queue = flow::Queue::Batch;
        } else if ready.iter().any(|b| b.task == t.id) {
            t.queue = flow::Queue::Ready;
        }
        // the map's agent on it: the model names it in the table, its own label (the session) follows in the detail
        if let Some(a) = agents.iter().find(|a| a.task == t.id) {
            let (agent, session) = a.names();
            t.agent = Some(agent);
            t.session = session;
            t.minutes = a.minutes;
            t.spend = a.spend.clone();
            t.context = a.context;
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
        agents: agents_at_once,
        ordered,
        base,
    }
}

/// What the budget scope PLAN (a plan's, every run of it: `runner::plan_scope`; a run's with no plan) spent in USD
/// (measured and estimated) and its USD budget: none when it has neither.
fn plan_cost(
    b: &crate::budget::Budgets,
    plan: &runstav::methods::timeline::BudgetScope,
) -> Option<(f64, Option<f64>)> {
    use runstav::methods::matrix::Unit;
    let v = b.view(plan);
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
        None => Sub::Timeline(Timeline {
            lanes: p.lanes,
            window: p.window.map(window_of),
            follow: p.follow.unwrap_or(false),
            filter: filter_of(p.filter),
        }),
    };
    let key = (c.conn_id, p.view);
    lock(&f.core.trails.lines).remove(&key);
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
/// view is that task's detail tile instead, with `rules` the Rules tile (`detail` with it: its Evidence tab's task):
/// rows alone, no model.
pub async fn flow_subscribe(
    f: &Front,
    c: &Caller,
    p: FlowSubscribe,
) -> Result<TrailSubscribed, Error> {
    let key = (c.conn_id, p.view);
    let part = match (p.detail, p.rules) {
        (task, true) => flow::Part::Rules(task),
        (Some(task), false) => flow::Part::Detail(task),
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

/// `work/trail/set`: a Timeline view of CALLER's connection takes a new window (which stops following unless `follow`
/// says otherwise), follow or filter, and draws again; false when it is not a Timeline.
pub async fn set(f: &Front, c: &Caller, p: TrailSet) -> Result<bool, Error> {
    let key = (c.conn_id, p.view);
    {
        let mut views = lock(&f.core.trails.views);
        let Some(Sub::Timeline(t)) = views.get_mut(&key) else {
            return Ok(false);
        };
        if let Some(w) = p.window {
            t.window = Some(window_of(w));
            t.follow = false;
        }
        if let Some(on) = p.follow {
            t.follow = on;
        }
        if p.filter.is_some() {
            t.filter = filter_of(p.filter);
        }
    }
    // a new window: the now-line is drawn on it at once
    lock(&f.core.trails.lines).remove(&key);
    f.core.trails.refresh(f, &key).await;
    Ok(true)
}

/// `work/schedule/subscribe`: VIEW of CALLER's connection shows the Schedule over `window`; its rows go to each class
/// its editor sent a `view/env` for, the first patch of each a reset, before the answer.
pub async fn schedule_subscribe(
    f: &Front,
    c: &Caller,
    p: ScheduleSubscribe,
) -> Result<TrailSubscribed, Error> {
    let key = (c.conn_id, p.view);
    lock(&f.core.trails.lines).remove(&key);
    lock(&f.core.trails.views).insert(
        key.clone(),
        Sub::Schedule(Schedule {
            window: window_of(p.window),
            group: p.group,
        }),
    );
    f.core.trails.refresh(f, &key).await;
    Ok(TrailSubscribed {
        hub: f.core.views.hub(),
    })
}

/// `work/schedule/set`: a Schedule view of CALLER's connection takes a new window or grouping and draws again; false
/// when it is not a Schedule.
pub async fn schedule_set(f: &Front, c: &Caller, p: ScheduleSet) -> Result<bool, Error> {
    let key = (c.conn_id, p.view);
    {
        let mut views = lock(&f.core.trails.views);
        let Some(Sub::Schedule(s)) = views.get_mut(&key) else {
            return Ok(false);
        };
        if let Some(w) = p.window {
            s.window = window_of(w);
        }
        if let Some(g) = p.group {
            s.group = g;
        }
    }
    lock(&f.core.trails.lines).remove(&key);
    f.core.trails.refresh(f, &key).await;
    Ok(true)
}

/// `work/trail/close`: VIEW of CALLER's connection ends.
pub fn close(f: &Front, c: &Caller, p: TrailClose) -> Result<bool, Error> {
    let key = (c.conn_id, p.view);
    lock(&f.core.trails.data).remove(&key);
    lock(&f.core.trails.lines).remove(&key);
    Ok(lock(&f.core.trails.views).remove(&key).is_some())
}

/// LANES' steps in WIN: one ranged read per lane (`norn::read::steps::window`), all in one read of the store.
async fn window_lanes(f: &Front, lanes: &[TrailLane], win: Window) -> Vec<trail::Lane> {
    let ids: Vec<String> = lanes.iter().map(|l| l.session.clone()).collect();
    let read = f
        .writer
        .db
        .read(move |c| {
            read_lanes(&ids, |sid| {
                norn::read::steps::window(c, &format!("session:{sid}"), win.from, win.to)
            })
        })
        .await
        .unwrap_or_default();
    lanes
        .iter()
        .zip(read.into_iter().chain(std::iter::repeat_with(Vec::new)))
        .map(|(l, steps)| trail::Lane {
            id: l.session.clone(),
            label: l.label.clone(),
            steps,
        })
        .collect()
}

/// The steps of each of the sessions IDS, by READ (one call a lane), as the Timeline draws them.
fn read_lanes<E>(
    ids: &[String],
    mut read: impl FnMut(&str) -> Result<Vec<norn::read::steps::WindowStep>, E>,
) -> Result<Vec<Vec<trail::Step>>, E> {
    let mut out = Vec::with_capacity(ids.len());
    for sid in ids {
        out.push(read(sid)?.into_iter().map(window_step).collect());
    }
    Ok(out)
}

fn window_step(s: norn::read::steps::WindowStep) -> trail::Step {
    trail::Step {
        id: s.id,
        seq: u64::try_from(s.seq).unwrap_or(0),
        class: s.class.as_str().to_owned(),
        tool: s.tool,
        detail: trail::Detail {
            kind: s.kind,
            ..trail::Detail::default()
        },
        start: s.start,
        end: s.end,
    }
}

/// The trails' background: every view read again after each write (coalesced) and each closed step.
pub async fn run(front: Arc<Front>) {
    let _ = front.core.trails.front.set(Arc::downgrade(&front));
    let signals = front.writer.signals.clone();
    loop {
        // a trail with a step still open counts its seconds: drawn again each second, between the writes
        let ticking = lock(&front.core.trails.data).values().any(|d| {
            matches!(&**d, Data::Trail(steps, _, _, None) if steps.iter().any(|s| s.end.is_none()))
        });
        // a Timeline or Schedule moves its clock each second
        let ticking = ticking
            || lock(&front.core.trails.views)
                .values()
                .any(|s| matches!(s, Sub::Timeline(_) | Sub::Schedule(_)));
        let timed = if ticking {
            tokio::select! {
                () = signals.trail.notified() => false,
                () = crate::clock::sleep(std::time::Duration::from_secs(1)) => true,
            }
        } else {
            signals.trail.notified().await;
            false
        };
        let keys: Vec<(u64, String)> = lock(&front.core.trails.views).keys().cloned().collect();
        for k in keys {
            // between writes, a Timeline or Schedule draws its clock from what it read
            if timed && front.core.trails.tick(&front, &k).await {
                continue;
            }
            front.core.trails.refresh(&front, &k).await;
        }
    }
}

#[cfg(test)]
mod window_tests {
    use super::*;

    /// A followed Timeline moves with now at every redraw; with reduced motion it scrolls in steps: it stays while now
    /// is in it, then steps half its span (flow Task 30, `a11y-flow/reduced-motion-follow-steps`).
    #[test]
    fn reduced_motion_follow_steps() {
        let w = Window {
            from: 0.0,
            to: 100.0,
        };
        let smooth = followed(w, 50.0, false).expect("a smooth follow moves");
        assert_eq!((smooth.from, smooth.to), (-40.0, 60.0));
        assert_eq!(followed(w, 50.0, true), None, "in view: the window stays");
        assert_eq!(followed(w, 99.0, true), None);
        let step = followed(w, 100.0, true).expect("at its end it steps");
        assert_eq!((step.from, step.to), (50.0, 150.0));
    }
    use norn::read::steps::WindowStep;
    use norn::write::steps::StepClass;

    /// A Timeline over a window reads each lane once (one ranged query a lane), whatever its steps, and each step's
    /// detail kind reaches its segment.
    #[test]
    fn a_timeline_reads_one_window_per_lane() {
        let ids: Vec<String> = (0..30).map(|i| format!("s{i}")).collect();
        let mut asked: Vec<String> = Vec::new();
        let lanes = read_lanes::<()>(&ids, |sid| {
            asked.push(sid.to_owned());
            Ok((0..3)
                .map(|i| WindowStep {
                    id: i,
                    seq: i + 1,
                    class: StepClass::Tool,
                    start: i as f64,
                    end: Some(i as f64 + 0.5),
                    tool: None,
                    kind: Some("edit".into()),
                })
                .collect())
        })
        .unwrap();
        assert_eq!(asked, ids);
        assert_eq!(lanes.len(), 30);
        assert_eq!(lanes[0][1].detail.kind.as_deref(), Some("edit"));
        assert_eq!(lanes[0][1].class, "tool");
        assert_eq!(trail::SegKind::of(&lanes[0][1]), trail::SegKind::Edit);
    }
}
