//! Hub-built rows (docs/develop/hub.md, "Rows"): the editors' view environments and the rows each (connection,
//! view, display class) was last sent. `view/env`, `view/resync`, `view/glyphs`, `view/measured` and `view/close`
//! are served here; a view's builder hands its rows to [`Views::publish`], which sends the patch (`view-patch`, by
//! `Front::send_to`) that turns what the editor holds into them.
//!
//! The rules (Call 7 of the render offload plan):
//! - the epoch is the editor's, numbered per (view, class), and echoed on every patch; the hub owns `version`;
//! - the hub's instance id ([`Store::hub`], drawn at start) is on every patch, so a patch of an earlier hub never
//!   matches a base the editor holds;
//! - the first patch per (view, class) after a `view/env` with a new epoch is a `reset`;
//! - a (view, class) with no env gets nothing.
//!
//! [`Store`] is the pure core (no I/O, no clock), tested in every order of envs, rows, resyncs and restarts.

pub mod files;
pub mod fonts;
pub mod git;
pub mod grep;
pub mod model;
#[cfg(test)]
mod tests;

use drgnx_rows::fit::{self, FontSet};
use drgnx_rows::fit_tty;
use drgnx_rows::image::ImageSet;
use drgnx_rows::{ImageId, Op, Patch, Row, RowBuilder};
use runstav::methods::view::{
    Display, ViewClose, ViewEnv, ViewGlyphs, ViewGlyphsAsk, ViewMeasured, ViewModel, ViewResync,
};
use runstav::wire::Error;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};

use crate::dispatch::Caller;
use crate::front::Front;

/// One (connection, view, display class).
pub type Key = (u64, String, String);

/// What one (view, class) holds: its env, the version and rows the editor was last sent, and the images it holds.
struct Pair {
    env: ViewEnv,
    version: u64,
    rows: Vec<Row>,
    images: ImageSet,
    reset_due: bool,
}

/// The pure core: every (view, class)'s env, version and rows, and every view's model, for one hub instance.
pub struct Store {
    hub: u64,
    pairs: BTreeMap<Key, Pair>,
    /// (connection, view) → the model its editor was last sent (views with a model only).
    models: BTreeMap<(u64, String), model::Sent>,
}

impl Store {
    pub fn new(hub: u64) -> Self {
        Store {
            hub,
            pairs: BTreeMap::new(),
            models: BTreeMap::new(),
        }
    }

    /// The model version of KEY's view, for its patches; none for a view with no model.
    fn model_version(&self, key: &Key) -> Option<u64> {
        self.models.get(&(key.0, key.1.clone())).map(|s| s.version)
    }

    /// CONN's VIEW's model is now DOC: the `view-model` that turns what its editor holds into it (none when nothing
    /// changed). Its rows' patches name the new version.
    pub fn publish_model(&mut self, conn: u64, view: &str, doc: model::Doc) -> Option<ViewModel> {
        let hub = self.hub;
        let out = self
            .models
            .entry((conn, view.to_owned()))
            .or_default()
            .publish(doc)?;
        Some(Self::model_event(hub, view, out))
    }

    /// CONN's editor asks for VIEW's model again: a reset of what it was last sent.
    pub fn resync_model(&mut self, conn: u64, view: &str) -> Option<ViewModel> {
        let hub = self.hub;
        let out = self.models.get_mut(&(conn, view.to_owned()))?.resync()?;
        Some(Self::model_event(hub, view, out))
    }

    /// CONN subscribed VIEW (again): its editor starts a new replica, so its model starts again at version 1.
    pub fn model_restart(&mut self, conn: u64, view: &str) {
        self.models.remove(&(conn, view.to_owned()));
    }

    /// CONN's VIEW was hidden: it gets no model until it is shown again, and then a reset.
    pub fn model_hidden(&mut self, conn: u64, view: &str) {
        if let Some(s) = self.models.get_mut(&(conn, view.to_owned())) {
            s.reset_due();
        }
    }

    fn model_event(hub: u64, view: &str, out: model::Out) -> ViewModel {
        ViewModel {
            view: view.to_owned(),
            hub,
            base: out.base,
            version: out.version,
            reset: out.reset,
            model: out.model,
        }
    }

    /// The hub's instance id.
    pub fn hub(&self) -> u64 {
        self.hub
    }

    /// CONN's env for (view, class). The caller builds the pair's rows again after it and publishes them.
    pub fn env(&mut self, conn: u64, env: ViewEnv) {
        let key = (conn, env.view.clone(), env.class.clone());
        match self.pairs.get_mut(&key) {
            // a new epoch is a new look: the next patch is a reset; the same epoch (a width) is answered by a diff
            Some(p) => {
                p.reset_due |= p.env.epoch != env.epoch;
                p.env = env;
            }
            None => {
                self.pairs.insert(
                    key,
                    Pair {
                        env,
                        version: 0,
                        rows: Vec::new(),
                        images: ImageSet::default(),
                        reset_due: true,
                    },
                );
            }
        }
    }

    /// The env of (CONN, VIEW, CLASS), if the editor sent one.
    pub fn env_of(&self, key: &Key) -> Option<&ViewEnv> {
        self.pairs.get(key).map(|p| &p.env)
    }

    /// The display classes CONN shows VIEW in.
    pub fn classes(&self, conn: u64, view: &str) -> Vec<String> {
        self.pairs
            .keys()
            .filter(|(c, v, _)| *c == conn && v == view)
            .map(|(_, _, k)| k.clone())
            .collect()
    }

    /// The patch that turns what KEY's editor holds into ROWS (IMAGES: every image the rows may name); none when the
    /// pair has no env or nothing changed.
    pub fn publish(
        &mut self,
        key: &Key,
        rows: Vec<Row>,
        images: &[(ImageId, String)],
    ) -> Option<Patch> {
        let model = self.model_version(key);
        let p = self.pairs.get_mut(key)?;
        let ops = if p.reset_due {
            vec![Op::Reset(rows.clone())]
        } else {
            drgnx_rows::diff(&p.rows, &rows)
        };
        if ops.is_empty() {
            return None;
        }
        p.rows = rows;
        Some(Self::send(self.hub, key, p, ops, images, model))
    }

    /// The patch of OPS for P, which now holds its new rows: the next version, and the images its rows name that the
    /// editor was not sent (a reset: all of them, as the editor drops the rest).
    fn send(
        hub: u64,
        key: &Key,
        p: &mut Pair,
        ops: Vec<Op>,
        images: &[(ImageId, String)],
        model: Option<u64>,
    ) -> Patch {
        let reset = matches!(ops.as_slice(), [Op::Reset(_)]);
        if reset {
            p.reset_due = false;
        }
        for (id, svg) in images {
            p.images.put(*id, svg);
        }
        let new = p.images.for_patch(&p.rows, reset);
        let base = p.version;
        p.version += 1;
        Patch {
            view: key.1.clone(),
            class: key.2.clone(),
            hub,
            base,
            version: p.version,
            env_epoch: p.env.epoch,
            ops,
            images: new,
            model,
        }
    }

    /// The editor of KEY asks for its rows again: a reset of the rows it was last sent.
    pub fn resync(&mut self, key: &Key, images: &[(ImageId, String)]) -> Option<Patch> {
        let model = self.model_version(key);
        let p = self.pairs.get_mut(key)?;
        let ops = vec![Op::Reset(p.rows.clone())];
        Some(Self::send(self.hub, key, p, ops, images, model))
    }

    /// CONN shows VIEW no more.
    pub fn close(&mut self, conn: u64, view: &str) -> bool {
        let before = self.pairs.len() + self.models.len();
        self.pairs.retain(|(c, v, _), _| !(*c == conn && v == view));
        self.models.retain(|(c, v), _| !(*c == conn && v == view));
        self.pairs.len() + self.models.len() != before
    }

    /// Connection CONN is gone: its pairs and models with it.
    pub fn gone(&mut self, conn: u64) {
        self.pairs.retain(|(c, _, _), _| *c != conn);
        self.models.retain(|(c, _), _| *c != conn);
    }
}

/// A random instance id below 2^53, so every JSON reader holds it exactly.
fn instance_id() -> u64 {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b).expect("the system's random source");
    u64::from_le_bytes(b) & ((1 << 53) - 1)
}

/// A fixture view's labels: (key, text, px), each a row fitted to PX then a stop.
pub type Label = (String, String, u32);

/// A fixture view's rows, the images they may name, and its labels.
pub type Fixture = (Vec<Row>, Vec<(ImageId, String)>, Vec<Label>);

/// The rows of LABELS in ENV's class: each text fitted to its PX (a GUI class by FONTS' advances, a terminal by
/// columns of the env's cell), then a stop at PX and a `|` after it.
pub fn label_rows(labels: &[Label], env: &ViewEnv, fonts: &FontSet) -> Vec<Row> {
    labels
        .iter()
        .map(|(key, text, px)| {
            let fitted = match env.display {
                Display::Gui => fit::fit(fonts, "ui", text, *px as f32),
                Display::Tty => {
                    let cols = (*px / env.cell.0.max(1)) as usize;
                    fit_tty::fit(text, cols, &env.tty_widths)
                }
            };
            let mut b = RowBuilder::new(key.clone());
            b.push(&fitted, None).stop(*px).push("|", None);
            b.finish()
        })
        .collect()
}

/// The fonts each (view, class) measures with, and the files they were read from.
#[derive(Default)]
struct Fonts {
    files: fonts::Files,
    sets: BTreeMap<Key, FontSet>,
}

/// The shell: the store, the fonts, the rows the test fixture view is given (test hooks), and the sending.
pub struct Views {
    store: Mutex<Store>,
    fonts: Mutex<Fonts>,
    /// `__test_view_rows`: the rows and images of a fixture view per (connection, view), the same in every class.
    fixtures: Mutex<BTreeMap<(u64, String), Fixture>>,
    /// The text searches streaming rows (`search/grep`).
    greps: grep::Greps,
    /// The git letters streaming rows (`git/letters`).
    letters: git::Letters,
    /// The ranked file queries (`search/files`) and the names they rank.
    files: files::Files,
    /// The front, kept once at the hub's start: a search thread reaches the store and the connections through it.
    front: OnceLock<Weak<Front>>,
}

impl Default for Views {
    fn default() -> Self {
        Views {
            store: Mutex::new(Store::new(instance_id())),
            fonts: Mutex::new(Fonts::default()),
            fixtures: Mutex::new(BTreeMap::new()),
            greps: grep::Greps::default(),
            letters: git::Letters::default(),
            files: files::Files::default(),
            front: OnceLock::new(),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Views {
    /// Builds (CONN, VIEW, CLASS)'s rows again and sends what changed. The builders: the test fixture view (its
    /// rows as given, then its labels fitted with the class's fonts).
    fn build(&self, f: &Front, key: &Key) {
        if self.grep_build(f, key) || self.git_build(f, key) || self.files_build(f, key) {
            return;
        }
        let Some((mut rows, images, labels)) =
            lock(&self.fixtures).get(&(key.0, key.1.clone())).cloned()
        else {
            // not a fixture: a Work map, trail or Timeline view of that name, if there is one
            f.core.map.view_env(f, key);
            f.core.trails.view_env(key);
            return;
        };
        if !labels.is_empty() {
            let env = lock(&self.store).env_of(key).cloned();
            if let Some(env) = env {
                let fitted = self.with_fonts(key, |set| label_rows(&labels, &env, set));
                rows.extend(fitted.unwrap_or_default());
            }
        }
        let patch = lock(&self.store).publish(key, rows, &images);
        if let Some(p) = patch {
            f.send_to(key.0, "view-patch", json!(p));
        }
        self.ask(f, key);
    }

    /// The hub's instance id (on every patch).
    pub fn hub(&self) -> u64 {
        lock(&self.store).hub()
    }

    /// The display classes CONN shows VIEW in.
    pub fn classes(&self, conn: u64, view: &str) -> Vec<String> {
        lock(&self.store).classes(conn, view)
    }

    /// The envs CONN sent for VIEW, one per class.
    pub fn envs(&self, conn: u64, view: &str) -> Vec<ViewEnv> {
        let store = lock(&self.store);
        store
            .classes(conn, view)
            .into_iter()
            .filter_map(|class| store.env_of(&(conn, view.to_owned(), class)).cloned())
            .collect()
    }

    /// A builder's rows for KEY: BUILD makes them from KEY's env and fonts, the patch from what its editor holds goes
    /// out (`view-patch`), and the glyphs the build missed are asked for. Nothing before KEY's env.
    pub fn publish_built(
        &self,
        f: &Front,
        key: &Key,
        build: impl FnOnce(&ViewEnv, &FontSet) -> (Vec<Row>, Vec<(ImageId, String)>),
    ) {
        let Some(env) = lock(&self.store).env_of(key).cloned() else {
            return;
        };
        let Some((rows, images)) = self.with_fonts(key, |set| build(&env, set)) else {
            return;
        };
        let patch = lock(&self.store).publish(key, rows, &images);
        if let Some(p) = patch {
            f.send_to(key.0, "view-patch", json!(p));
        }
        self.ask(f, key);
    }

    /// CONN's VIEW's model is now DOC: what changed goes out (`view-model`) before the rows built from it, which name
    /// its version. Returns whether one went.
    pub fn publish_model(&self, f: &Front, conn: u64, view: &str, doc: model::Doc) -> bool {
        let out = lock(&self.store).publish_model(conn, view, doc);
        out.is_some_and(|m| f.send_to(conn, "view-model", json!(m)))
    }

    /// CONN's VIEW was hidden: its next model is a reset.
    pub fn model_hidden(&self, conn: u64, view: &str) {
        lock(&self.store).model_hidden(conn, view);
    }

    /// CONN subscribed VIEW (again): its model starts again.
    pub fn model_restart(&self, conn: u64, view: &str) {
        lock(&self.store).model_restart(conn, view);
    }

    /// KEY's font set, for a builder to measure with (none before its `view/env`).
    pub fn with_fonts<R>(&self, key: &Key, then: impl FnOnce(&FontSet) -> R) -> Option<R> {
        lock(&self.fonts).sets.get(key).map(then)
    }

    /// Asks KEY's editor for the advances its builders missed (`view-glyphs`), each (role, char) once.
    fn ask(&self, f: &Front, key: &Key) {
        let asks = self.with_fonts(key, FontSet::take_asks).unwrap_or_default();
        if !asks.is_empty() {
            let ask: Vec<(String, String)> =
                asks.into_iter().map(|(r, c)| (r, c.to_string())).collect();
            let ask = ViewGlyphsAsk {
                view: key.1.clone(),
                class: key.2.clone(),
                ask,
            };
            f.send_to(key.0, "view-glyphs", json!(ask));
        }
    }

    /// KEY's env arrived: its font set is made again when the fonts it names changed (the editor's answers kept
    /// otherwise), and the files no env names any more are dropped.
    fn env_fonts(&self, key: &Key, env: &ViewEnv, old: Option<&ViewEnv>) {
        let mut fonts = lock(&self.fonts);
        if old.is_some_and(|o| o.fonts == env.fonts) && fonts.sets.contains_key(key) {
            return;
        }
        let set = fonts.files.font_set(env);
        fonts.sets.insert(key.clone(), set);
    }

    /// Forget the font sets of the keys the store no longer holds, and the files no env names.
    fn prune_fonts(&self) {
        let store = lock(&self.store);
        let mut fonts = lock(&self.fonts);
        fonts.sets.retain(|k, _| store.pairs.contains_key(k));
        let Fonts { files, .. } = &mut *fonts;
        files.keep_only(store.pairs.values().map(|p| &p.env));
    }

    /// The images a resync's reset may name.
    fn images_of(&self, key: &Key) -> Vec<(ImageId, String)> {
        lock(&self.fixtures)
            .get(&(key.0, key.1.clone()))
            .map(|(_, i, _)| i.clone())
            .unwrap_or_default()
    }

    /// `__test_view_rows {view, rows, images?, labels?}` (test hooks): CONN's fixture view VIEW shows ROWS in every
    /// class, then LABELS fitted with each class's fonts.
    pub fn fixture(&self, f: &Front, conn: u64, view: String, fixture: Fixture) {
        lock(&self.fixtures).insert((conn, view.clone()), fixture);
        let classes = lock(&self.store).classes(conn, &view);
        for class in classes {
            self.build(f, &(conn, view.clone(), class));
        }
    }

    /// Keep the front once; the searches' threads send through it.
    pub fn bind(&self, front: &Arc<Front>) {
        let _ = self.front.set(Arc::downgrade(front));
    }

    pub fn gone(&self, conn: u64) {
        self.greps.gone(conn);
        self.letters.gone(conn);
        self.files.gone(conn);
        lock(&self.store).gone(conn);
        lock(&self.fixtures).retain(|(c, _), _| *c != conn);
        self.prune_fonts();
    }
}

/// `view/env`: the env is kept and the (view, class)'s rows built again.
pub fn env(f: &Front, c: &Caller, p: ViewEnv) -> Result<bool, Error> {
    let views = &f.core.views;
    let key = (c.conn_id, p.view.clone(), p.class.clone());
    let old = lock(&views.store).env_of(&key).cloned();
    views.env_fonts(&key, &p, old.as_ref());
    lock(&views.store).env(c.conn_id, p);
    views.prune_fonts();
    views.build(f, &key);
    Ok(true)
}

/// `view/resync`: a reset of what the hub last sent (none for a pair with no env); with `model`, of the view's model.
pub fn resync(f: &Front, c: &Caller, p: ViewResync) -> Result<bool, Error> {
    let views = &f.core.views;
    if p.model {
        let m = lock(&views.store).resync_model(c.conn_id, &p.view);
        return Ok(m.is_some_and(|m| f.send_to(c.conn_id, "view-model", json!(m))));
    }
    let key = (c.conn_id, p.view, p.class);
    let images = views.images_of(&key);
    let patch = lock(&views.store).resync(&key, &images);
    Ok(match patch {
        Some(p) => f.send_to(key.0, "view-patch", json!(p)),
        None => false,
    })
}

/// `view/glyphs`: the editor's advances for the chars the hub asked of it; the (view, class) is built again by them.
pub fn glyphs(f: &Front, c: &Caller, p: ViewGlyphs) -> Result<bool, Error> {
    let views = &f.core.views;
    let key = (c.conn_id, p.view, p.class);
    let answers: Vec<(String, char, f32)> = p
        .glyphs
        .into_iter()
        .filter_map(|(role, s, px)| {
            let mut cs = s.chars();
            match (cs.next(), cs.next()) {
                (Some(ch), None) => Some((role, ch, px)),
                _ => None,
            }
        })
        .collect();
    if views.with_fonts(&key, |set| set.glyphs(&answers)).is_none() {
        return Ok(false);
    }
    views.build(f, &key);
    Ok(true)
}

/// `view/measured`: the fit guard's measurements of strings that overflowed; they win over the sums from now on.
pub fn measured(f: &Front, c: &Caller, p: ViewMeasured) -> Result<bool, Error> {
    let views = &f.core.views;
    let key = (c.conn_id, p.view, p.class);
    let kept = views.with_fonts(&key, |set| {
        for (role, text, px) in &p.measured {
            set.measured(role, text, *px);
        }
    });
    if kept.is_none() {
        return Ok(false);
    }
    views.build(f, &key);
    Ok(true)
}

/// `view/close`: CALLER's VIEW ends.
pub fn close(f: &Front, c: &Caller, p: ViewClose) -> Result<bool, Error> {
    let views = &f.core.views;
    lock(&views.fixtures).remove(&(c.conn_id, p.view.clone()));
    views.greps.stop(c.conn_id, &p.view);
    views.letters.stop(c.conn_id, &p.view);
    views.files.stop(c.conn_id, &p.view);
    let closed = lock(&views.store).close(c.conn_id, &p.view);
    views.prune_fonts();
    Ok(closed)
}

/// Whether P is one reset.
#[cfg(test)]
pub(crate) fn is_reset(p: &Patch) -> bool {
    matches!(p.ops.as_slice(), [Op::Reset(_)])
}
