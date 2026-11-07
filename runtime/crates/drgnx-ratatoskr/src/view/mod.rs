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

pub mod fonts;
#[cfg(test)]
mod tests;

use drgnx_rows::fit::{self, FontSet};
use drgnx_rows::fit_tty;
use drgnx_rows::image::ImageSet;
use drgnx_rows::{ImageId, Op, Patch, Row, RowBuilder};
use runstav::methods::view::{
    Display, ViewAck, ViewClose, ViewEnv, ViewGlyphs, ViewGlyphsAsk, ViewMeasured, ViewResync,
};
use runstav::wire::Error;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

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

/// The pure core: every (view, class)'s env, version and rows, for one hub instance.
pub struct Store {
    hub: u64,
    pairs: BTreeMap<Key, Pair>,
    /// (connection, view) → its options (none: the defaults).
    opts: BTreeMap<(u64, String), ViewOpts>,
}

impl Store {
    pub fn new(hub: u64) -> Self {
        Store {
            hub,
            pairs: BTreeMap::new(),
            opts: BTreeMap::new(),
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
        Some(Self::send(self.hub, key, p, ops, images))
    }

    /// The patch of OPS for P, which now holds its new rows: the next version, and the images its rows name that the
    /// editor was not sent (a reset: all of them, as the editor drops the rest).
    fn send(
        hub: u64,
        key: &Key,
        p: &mut Pair,
        ops: Vec<Op>,
        images: &[(ImageId, String)],
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
        }
    }

    /// The editor of KEY asks for its rows again: a reset of the rows it was last sent.
    pub fn resync(&mut self, key: &Key, images: &[(ImageId, String)]) -> Option<Patch> {
        let p = self.pairs.get_mut(key)?;
        // the rows waiting for an ack go with it: the reset is what is in flight now
        if let Some(rows) = p.pending.take() {
            p.rows = rows;
        }
        let ops = vec![Op::Reset(p.rows.clone())];
        Some(Self::send(self.hub, key, p, ops, images))
    }

    /// CONN shows VIEW no more.
    pub fn close(&mut self, conn: u64, view: &str) -> bool {
        let before = self.pairs.len();
        self.pairs.retain(|(c, v, _), _| !(*c == conn && v == view));
        self.opts.remove(&(conn, view.to_owned()));
        self.pairs.len() != before
    }

    /// Connection CONN is gone: its pairs with it.
    pub fn gone(&mut self, conn: u64) {
        self.pairs.retain(|(c, _, _), _| *c != conn);
        self.opts.retain(|(c, _), _| *c != conn);
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
}

impl Default for Views {
    fn default() -> Self {
        Views {
            store: Mutex::new(Store::new(instance_id())),
            fonts: Mutex::new(Fonts::default()),
            fixtures: Mutex::new(BTreeMap::new()),
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
        let Some((mut rows, images, labels)) =
            lock(&self.fixtures).get(&(key.0, key.1.clone())).cloned()
        else {
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

    pub fn gone(&self, conn: u64) {
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

/// `view/resync`: a reset of what the hub last sent (none for a pair with no env).
pub fn resync(f: &Front, c: &Caller, p: ViewResync) -> Result<bool, Error> {
    let views = &f.core.views;
    let key = (c.conn_id, p.view, p.class);
    let images = views.images_of(&key);
    let patch = lock(&views.store).resync(&key, &images);
    Ok(match patch {
        Some(p) => f.send_to(key.0, "view-patch", json!(p)),
        None => false,
    })
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
    let closed = lock(&views.store).close(c.conn_id, &p.view);
    views.prune_fonts();
    Ok(closed)
}

/// Whether P is one reset.
#[cfg(test)]
pub(crate) fn is_reset(p: &Patch) -> bool {
    matches!(p.ops.as_slice(), [Op::Reset(_)])
}
