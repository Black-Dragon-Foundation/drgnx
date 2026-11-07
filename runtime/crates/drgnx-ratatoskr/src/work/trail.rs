//! The trail and the Timeline as rows (`work/trail/subscribe`): one session's steps with its conclusions among them,
//! or a lane per agent session, built here (`vegvisir::trail`) and sent per display class as `view-patch`
//! (`docs/develop/hub.md`, "The trail and the Timeline"). Read again from the timeline and the conclusions store after
//! each write and each closed step; each class gets only the rows that changed. Before the rows, the view's model
//! (`model`) for the editor's replica; a Timeline's model again (from what was last read) when the map's selection
//! moves, for the lanes it lights.

mod model;

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::timeline::{Step as WireStep, TimelineParams};
use runstav::methods::view::ViewEnv;
use runstav::methods::work::{
    Conclusion as WireConclusion, ConclusionsParams, TrailClose, TrailLane, TrailSubscribe,
    TrailSubscribed,
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
}

/// What a view's rows are built from, read once per refresh for every class.
enum Data {
    Trail(Vec<trail::Step>, Vec<trail::Conclusion>),
    Timeline(Vec<trail::Lane>),
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
            Sub::Trail(sid) => Data::Trail(steps(f, &sid).await, conclusions(f, &sid).await),
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
        };
        let data = Arc::new(data);
        lock(&self.data).insert(key.clone(), data.clone());
        let near = match *data {
            Data::Timeline(_) => f.core.map.near(key.0),
            Data::Trail(..) => Vec::new(),
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
        Data::Trail(steps, concs) => model::trail_doc(steps, concs),
        Data::Timeline(lanes) => model::timeline_doc(lanes, near),
    }
}

/// DATA's rows for ENV, measured with FONTS.
fn rows(data: &Data, env: &ViewEnv, fonts: &dyn drgnx_rows::fit::Measure) -> Vec<drgnx_rows::Row> {
    let palette = drgnx_rows::svg::Palette(env.palette.clone());
    let renv = crate::work::map::render_env(env, &palette);
    let zone = Zone::parse(&env.tz);
    match data {
        Data::Trail(steps, concs) => trail::trail_rows(steps, concs, &renv, zone),
        Data::Timeline(lanes) => trail::timeline_rows(lanes, &renv, fonts, zone),
    }
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
    let Ok(p) = serde_json::from_value::<TimelineParams>(
        json!({"scope": "session", "id": sid, "limit": STEPS}),
    ) else {
        return Vec::new();
    };
    match crate::timeline::get(f, &hub_caller(), p).await {
        Ok(t) => t.steps.iter().map(step_of).collect(),
        Err(_) => Vec::new(),
    }
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
