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
//! - a (view, class) with no env gets nothing;
//! - a view whose options ask for acks (a terminal's) has at most one patch in flight per (view, class): the next
//!   waits, its rows kept, until `view/ack` names the version sent; a `view/resync` answers a reset at once, and a
//!   reconnect starts afresh, so a lost ack never stalls the view;
//! - a view whose options exempt it from the epoch reset (a terminal's: its faces repaint in the editor) answers a new
//!   epoch with a diff, not a reset.
//!
//! [`Store`] is the pure core (no I/O, no clock), tested in every order of envs, rows, resyncs and restarts.

pub mod explorer;
pub mod extensions;
pub mod files;
pub mod fonts;
pub mod git;
pub mod icons;
pub mod model;
pub mod panel;
pub mod search;
#[cfg(test)]
mod tests;

use drgnx_rows::fit::{self, FontSet};
use drgnx_rows::fit_tty;
use drgnx_rows::image::ImageSet;
use drgnx_rows::{ImageId, Op, Patch, Row, RowBuilder};
use runstav::methods::view::{
    Display, ViewAck, ViewClose, ViewEnv, ViewGlyphs, ViewGlyphsAsk, ViewMeasured, ViewModel,
    ViewResync, ViewWindow,
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
/// ACKED: the last version the editor acknowledged; PENDING: the rows waiting for that ack (an acknowledged view).
struct Pair {
    env: ViewEnv,
    version: u64,
    rows: Vec<Row>,
    images: ImageSet,
    reset_due: bool,
    acked: u64,
    pending: Option<Vec<Row>>,
}

/// How a view's patches go, set by its builder: ACK, at most one unacknowledged patch per (view, class);
/// EPOCH_RESET, a new env epoch makes the next patch a reset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ViewOpts {
    pub ack: bool,
    pub epoch_reset: bool,
}

impl Default for ViewOpts {
    fn default() -> Self {
        ViewOpts {
            ack: false,
            epoch_reset: true,
        }
    }
}

/// The pure core: every (view, class)'s env, version and rows, and every view's model, for one hub instance.
pub struct Store {
    hub: u64,
    pairs: BTreeMap<Key, Pair>,
    /// (connection, view) → its options (none: the defaults).
    opts: BTreeMap<(u64, String), ViewOpts>,
    /// (connection, view) → the model its editor was last sent (views with a model only).
    models: BTreeMap<(u64, String), model::Sent>,
    /// (connection, view, list) → where the editor asked the list's window to start (`view/window`); a builder reads
    /// it ([`Store::window_from`]) when it holds more of the list than a window.
    froms: BTreeMap<(u64, String, String), usize>,
}

impl Store {
    pub fn new(hub: u64) -> Self {
        Store {
            hub,
            pairs: BTreeMap::new(),
            opts: BTreeMap::new(),
            models: BTreeMap::new(),
            froms: BTreeMap::new(),
        }
    }

    /// Where CONN's editor asked list LIST of VIEW's model to start, if it asked.
    pub fn window_from(&self, conn: u64, view: &str, list: &str) -> Option<usize> {
        self.froms
            .get(&(conn, view.to_owned(), list.to_owned()))
            .copied()
    }

    /// CONN's VIEW starts its lists' windows again from where its builder puts them (a new search).
    pub fn forget_windows(&mut self, conn: u64, view: &str) {
        self.froms.retain(|(c, v, _), _| !(*c == conn && v == view));
    }

    /// CONN's editor asks list LIST of VIEW's model to start at FROM (`view/window`).
    pub fn set_window(&mut self, conn: u64, view: &str, list: &str, from: usize) {
        self.froms
            .insert((conn, view.to_owned(), list.to_owned()), from);
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

    /// CONN's VIEW's model gains NODES, new or changed: the `view-model` of those alone (none when none changed), or
    /// `None` when there is no model to extend (none sent, or a reset due) and the builder sends the whole.
    pub fn extend_model(
        &mut self,
        conn: u64,
        view: &str,
        nodes: Vec<serde_json::Value>,
    ) -> Option<Option<ViewModel>> {
        let hub = self.hub;
        let s = self.models.get_mut(&(conn, view.to_owned()))?;
        if !s.extendable() {
            return None;
        }
        Some(s.extend(nodes).map(|out| Self::model_event(hub, view, out)))
    }

    /// CONN's VIEW's model gains NODES, new, and their IDS at the end of list NAME ([`model::Sent::append`]): the
    /// `view-model` of that change alone, or `None` when there is no model to append to (none sent, a reset due, a
    /// windowed list) and the builder publishes the whole.
    pub fn append_model(
        &mut self,
        conn: u64,
        view: &str,
        nodes: Vec<(String, serde_json::Value)>,
        name: &str,
        ids: Vec<String>,
    ) -> Option<ViewModel> {
        let hub = self.hub;
        let out = self
            .models
            .get_mut(&(conn, view.to_owned()))?
            .append(nodes, name, ids)?;
        Some(Self::model_event(hub, view, out))
    }

    /// CONN's VIEW's model, one windowed list, moves by M over the same entries ([`model::Sent::move_window`]):
    /// the `view-model` of the move alone, or `None` when it cannot say it (none sent, a reset due, the total changed)
    /// and the builder publishes the whole.
    pub fn move_model(
        &mut self,
        conn: u64,
        view: &str,
        m: model::WindowMove,
        node: impl FnMut(usize) -> serde_json::Value,
    ) -> Option<ViewModel> {
        let hub = self.hub;
        let out = self
            .models
            .get_mut(&(conn, view.to_owned()))?
            .move_window(m, node)?;
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
        self.forget_windows(conn, view);
    }

    /// CONN's VIEW was hidden: it gets no model until it is shown again, and then a reset.
    pub fn model_hidden(&mut self, conn: u64, view: &str) {
        if let Some(s) = self.models.get_mut(&(conn, view.to_owned())) {
            s.reset_due();
        }
    }

    /// M as a `view-model` event's data, its model moved in (`json!(m)` would copy the whole model).
    pub fn model_data(m: ViewModel) -> serde_json::Value {
        let ViewModel {
            view,
            hub,
            base,
            version,
            reset,
            model,
        } = m;
        let mut d = serde_json::Map::new();
        d.insert("view".into(), view.into());
        d.insert("hub".into(), hub.into());
        d.insert("base".into(), base.into());
        d.insert("version".into(), version.into());
        if reset {
            d.insert("reset".into(), true.into());
        }
        d.insert("model".into(), model);
        d.into()
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

    /// CONN's VIEW goes by OPTS from now on.
    pub fn options(&mut self, conn: u64, view: &str, opts: ViewOpts) {
        self.opts.insert((conn, view.to_owned()), opts);
    }

    fn opts_of(&self, conn: u64, view: &str) -> ViewOpts {
        self.opts
            .get(&(conn, view.to_owned()))
            .copied()
            .unwrap_or_default()
    }

    /// Whether KEY's editor was sent a patch it has not acknowledged yet (an acknowledged view only).
    pub fn in_flight(&self, key: &Key) -> bool {
        self.opts_of(key.0, &key.1).ack && self.pairs.get(key).is_some_and(|p| p.acked < p.version)
    }

    /// KEY's editor applied VERSION: the rows that waited for it go (the patch), when it is the version last sent.
    pub fn ack(&mut self, key: &Key, version: u64) -> Option<Patch> {
        let p = self.pairs.get_mut(key)?;
        if version != p.version {
            return None;
        }
        p.acked = version;
        let rows = p.pending.take()?;
        self.publish(key, rows, &[])
    }

    /// The hub's instance id.
    pub fn hub(&self) -> u64 {
        self.hub
    }

    /// CONN's env for (view, class). The caller builds the pair's rows again after it and publishes them.
    pub fn env(&mut self, conn: u64, env: ViewEnv) {
        let key = (conn, env.view.clone(), env.class.clone());
        let epoch_reset = self.opts_of(conn, &env.view).epoch_reset;
        // the first env of a new buffer: what the hub believes the editor holds went with the old buffer
        if env.attach {
            self.pairs.remove(&key);
        }
        match self.pairs.get_mut(&key) {
            // a new epoch is a new look: the next patch is a reset (unless the view repaints in place); the same epoch
            // (a width) is answered by a diff
            Some(p) => {
                p.reset_due |= epoch_reset && p.env.epoch != env.epoch;
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
                        acked: 0,
                        pending: None,
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
    /// pair has no env, nothing changed, or (an acknowledged view) a patch is in flight: then ROWS wait for its ack.
    pub fn publish(
        &mut self,
        key: &Key,
        rows: Vec<Row>,
        images: &[(ImageId, String)],
    ) -> Option<Patch> {
        let held = self.in_flight(key);
        let model = self.model_version(key);
        let p = self.pairs.get_mut(key)?;
        if held {
            for (id, svg) in images {
                p.images.put(*id, svg);
            }
            p.pending = Some(rows);
            return None;
        }
        p.pending = None;
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
            styles: Vec::new(),
            term: None,
            model,
        }
    }

    /// The editor of KEY asks for its rows again: a reset of the rows it was last sent.
    pub fn resync(&mut self, key: &Key, images: &[(ImageId, String)]) -> Option<Patch> {
        let model = self.model_version(key);
        let p = self.pairs.get_mut(key)?;
        // the rows waiting for an ack go with it: the reset is what is in flight now
        if let Some(rows) = p.pending.take() {
            p.rows = rows;
        }
        let ops = vec![Op::Reset(p.rows.clone())];
        Some(Self::send(self.hub, key, p, ops, images, model))
    }

    /// CONN shows VIEW no more.
    pub fn close(&mut self, conn: u64, view: &str) -> bool {
        let before = self.pairs.len() + self.models.len();
        self.pairs.retain(|(c, v, _), _| !(*c == conn && v == view));
        self.opts.remove(&(conn, view.to_owned()));
        self.models.retain(|(c, v), _| !(*c == conn && v == view));
        self.froms.retain(|(c, v, _), _| !(*c == conn && v == view));
        self.pairs.len() + self.models.len() != before
    }

    /// Connection CONN is gone: its pairs and models with it.
    pub fn gone(&mut self, conn: u64) {
        self.pairs.retain(|(c, _, _), _| *c != conn);
        self.opts.retain(|(c, _), _| *c != conn);
        self.models.retain(|(c, _), _| *c != conn);
        self.froms.retain(|(c, _, _), _| *c != conn);
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
    /// The Search view's searches streaming rows (`search/run`).
    greps: search::Greps,
    /// The git letters streaming rows (`git/letters`).
    letters: git::Letters,
    /// The ranked file queries (`search/files`) and the names they rank.
    files: files::Files,
    /// The Explorer's listings (`explorer/subscribe`).
    explorers: explorer::Explorers,
    /// The Extensions lists (`extensions/list`).
    lists: extensions::Lists,
    /// The agent panels' rows (`agent-panel/SESSION`).
    pub panels: Arc<panel::Panels>,
    /// The front, kept once at the hub's start: a search thread reaches the store and the connections through it.
    front: OnceLock<Weak<Front>>,
}

impl Default for Views {
    fn default() -> Self {
        Views {
            store: Mutex::new(Store::new(instance_id())),
            fonts: Mutex::new(Fonts::default()),
            fixtures: Mutex::new(BTreeMap::new()),
            greps: search::Greps::default(),
            letters: git::Letters::default(),
            files: files::Files::default(),
            explorers: explorer::Explorers::default(),
            lists: extensions::Lists::default(),
            panels: Arc::default(),
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
        if self.grep_build(f, key)
            || self.git_build(f, key)
            || self.files_build(f, key)
            || self.explorer_build(f, key)
            || self.extensions_build(f, key)
            || f.core.presence.here_build(f, key.0, &key.1)
        {
            return;
        }
        if let Some(sid) = panel::session_of(&key.1) {
            self.panels.build_session(f, sid, Some(key.0));
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

    /// Every (connection, view, class) that shows VIEW.
    pub fn keys_of(&self, view: &str) -> Vec<Key> {
        lock(&self.store)
            .pairs
            .keys()
            .filter(|(_, v, _)| v == view)
            .cloned()
            .collect()
    }

    /// The sessions an agent panel shows: their steps' facts are kept.
    fn prune_panels(&self) {
        let shown = lock(&self.store)
            .pairs
            .keys()
            .filter_map(|(_, v, _)| panel::session_of(v).map(str::to_owned))
            .collect();
        self.panels.prune(&shown);
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
        out.is_some_and(|m| f.send_to(conn, "view-model", Store::model_data(m)))
    }

    /// CONN's VIEW's model gains NODES ([`Store::extend_model`]); false when there is no model to extend, and the
    /// builder publishes the whole.
    pub fn extend_model(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        nodes: Vec<serde_json::Value>,
    ) -> bool {
        let Some(out) = lock(&self.store).extend_model(conn, view, nodes) else {
            return false;
        };
        if let Some(m) = out {
            f.send_to(conn, "view-model", Store::model_data(m));
        }
        true
    }

    /// CONN's VIEW was hidden: its next model is a reset.
    pub fn model_hidden(&self, conn: u64, view: &str) {
        lock(&self.store).model_hidden(conn, view);
    }

    /// CONN subscribed VIEW (again): its model starts again.
    pub fn model_restart(&self, conn: u64, view: &str) {
        lock(&self.store).model_restart(conn, view);
    }

    /// Where CONN's editor asked list LIST of VIEW's model to start ([`Store::window_from`]).
    pub fn window_from(&self, conn: u64, view: &str, list: &str) -> Option<usize> {
        lock(&self.store).window_from(conn, view, list)
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
    pub fn fixture(&self, f: &Front, conn: u64, view: String, fixture: Fixture, opts: ViewOpts) {
        lock(&self.store).options(conn, &view, opts);
        lock(&self.fixtures).insert((conn, view.clone()), fixture);
        let classes = lock(&self.store).classes(conn, &view);
        for class in classes {
            self.build(f, &(conn, view.clone(), class));
        }
    }

    /// The hub's instance id the patches carry.
    pub fn hub_id(&self) -> u64 {
        lock(&self.store).hub()
    }

    /// The front kept at the hub's start (none before it), for a model outside the views that publishes rows later.
    pub fn front_weak(&self) -> Option<Weak<Front>> {
        self.front.get().cloned()
    }

    /// ROWS, which read no env (a data view), for every class CONN shows VIEW in: what changed goes out.
    pub fn publish_rows(&self, f: &Front, conn: u64, view: &str, rows: Vec<Row>) {
        let patches: Vec<Patch> = {
            let mut store = lock(&self.store);
            store
                .classes(conn, view)
                .into_iter()
                .filter_map(|class| {
                    store.publish(&(conn, view.to_owned(), class), rows.clone(), &[])
                })
                .collect()
        };
        for p in patches {
            f.send_to(conn, "view-patch", json!(p));
        }
    }

    /// CONN's VIEW starts afresh: each class's next patch is a reset.
    pub fn restart_rows(&self, conn: u64, view: &str) {
        let mut store = lock(&self.store);
        for class in store.classes(conn, view) {
            store.restart(&(conn, view.to_owned(), class));
        }
    }

    /// Keep the front once; the searches' threads send through it.
    pub fn bind(&self, front: &Arc<Front>) {
        let _ = self.front.set(Arc::downgrade(front));
        self.panels.bind(front);
    }

    pub fn gone(&self, conn: u64) {
        self.greps.gone(conn);
        self.letters.gone(conn);
        self.files.gone(conn);
        self.explorers.gone(conn);
        self.lists.gone(conn);
        self.panels.gone(conn, None);
        lock(&self.store).gone(conn);
        lock(&self.fixtures).retain(|(c, _), _| *c != conn);
        self.prune_fonts();
        self.prune_panels();
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
        return Ok(m.is_some_and(|m| f.send_to(c.conn_id, "view-model", Store::model_data(m))));
    }
    let key = (c.conn_id, p.view, p.class);
    let images = views.images_of(&key);
    let patch = lock(&views.store).resync(&key, &images);
    Ok(match patch {
        Some(p) => f.send_to(key.0, "view-patch", json!(p)),
        None => false,
    })
}

/// `view/window`: CALLER's editor needs another window of a list of VIEW's model. The from is kept, and the view's
/// builder (a trail's `steps`, a search's or an Explorer's `order`) sends its model again with it; false when none
/// holds the view.
pub async fn window(f: &Front, c: &Caller, p: ViewWindow) -> Result<bool, Error> {
    let views = &f.core.views;
    let from = usize::try_from(p.from).unwrap_or(usize::MAX);
    lock(&views.store).set_window(c.conn_id, &p.view, &p.list, from);
    Ok(views.grep_window(f, c.conn_id, &p.view)
        || views.explorer_window(f, c.conn_id, &p.view)
        || f.core.trails.window(f, c.conn_id, &p.view).await)
}

/// `view/ack`: the editor applied a patch; an acknowledged view's waiting rows go (false for a pair with no env).
pub fn ack(f: &Front, c: &Caller, p: ViewAck) -> Result<bool, Error> {
    let views = &f.core.views;
    let key = (c.conn_id, p.view, p.class);
    let mut store = lock(&views.store);
    if store.env_of(&key).is_none() {
        return Ok(false);
    }
    let patch = store.ack(&key, p.version);
    drop(store);
    if let Some(patch) = patch {
        f.send_to(key.0, "view-patch", json!(patch));
    }
    Ok(true)
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
    views.explorers.stop(c.conn_id, &p.view);
    views.lists.stop(c.conn_id, &p.view);
    views.panels.gone(c.conn_id, Some(&p.view));
    let closed = lock(&views.store).close(c.conn_id, &p.view);
    views.prune_fonts();
    views.prune_panels();
    Ok(closed)
}

/// Whether P is one reset.
#[cfg(test)]
pub(crate) fn is_reset(p: &Patch) -> bool {
    matches!(p.ops.as_slice(), [Op::Reset(_)])
}
