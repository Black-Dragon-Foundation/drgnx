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
mod model;

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::Params;
use runstav::methods::plans::{ByPlan, PlanView};
use runstav::methods::tasks::{FindParams, TaskList};
use runstav::methods::timeline::{Step as WireStep, TimelineParams};
use runstav::methods::view::ViewEnv;
use runstav::methods::work::{
    BoardSubscribe, Conclusion as WireConclusion, ConclusionsParams, TrailClose, TrailLane,
    TrailSubscribe, TrailSubscribed,
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
}

/// What a view's rows are built from, read once per refresh for every class.
enum Data {
    /// A window of the session's steps (all when they fit), its conclusions, how many steps it has.
    Trail(Vec<trail::Step>, Vec<trail::Conclusion>, usize),
    Timeline(Vec<trail::Lane>),
    Board(Vec<board::Card>),
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
        };
        let data = Arc::new(data);
        lock(&self.data).insert(key.clone(), data.clone());
        let near = match *data {
            Data::Timeline(_) => f.core.map.near(key.0),
            Data::Trail(..) | Data::Board(_) => Vec::new(),
        };
        f.core
            .views
            .publish_model(f, key.0, &key.1, doc_of(&data, &near));
        for class in f.core.views.classes(key.0, &key.1) {
            let k3 = (key.0, key.1.clone(), class);
            f.core
                .views
                .publish_built(f, &k3, |env, fonts| (rows(&data, env, fonts), Vec::new()));
        }
    }
}

/// DATA's model, the lanes of the sessions NEAR lit.
fn doc_of(data: &Data, near: &[String]) -> crate::view::model::Doc {
    match data {
        Data::Trail(steps, concs, total) => model::trail_doc(steps, concs, *total),
        Data::Timeline(lanes) => model::timeline_doc(lanes, near),
        Data::Board(cards) => board::board_doc(cards),
    }
}

/// DATA's rows for ENV, measured with FONTS.
fn rows(data: &Data, env: &ViewEnv, fonts: &dyn drgnx_rows::fit::Measure) -> Vec<drgnx_rows::Row> {
    let palette = drgnx_rows::svg::Palette(env.palette.clone());
    let renv = crate::work::map::render_env(env, &palette);
    let zone = Zone::parse(&env.tz);
    match data {
        Data::Trail(steps, concs, _) => trail::trail_rows(steps, concs, &renv, zone),
        Data::Timeline(lanes) => trail::timeline_rows(lanes, &renv, fonts, zone),
        Data::Board(cards) => board::board_rows(cards, env),
    }
}

/// The most pages of `tasks/find` an unscoped Board reads (50 tasks a page).
const BOARD_PAGES: usize = 4;

/// The Board's cards: the tasks of PLANS (each `plans/get`), else every task (`tasks/find`, up to [`BOARD_PAGES`]
/// pages), each with the agent of connection CONN's map view MAP working on it (by the task's title, as the map's
/// agents carry it). A read that fails leaves its cards out.
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
    let agents = f.core.map.agents_of(conn, map);
    for c in &mut cards {
        c.agent = agents
            .iter()
            .find(|(task, ..)| *task == c.title)
            .map(|(_, id, label)| (id.clone(), label.clone()));
    }
    cards
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
