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

#[cfg(test)]
mod tests;

use drgnx_rows::{ImageId, Op, Patch, Row};
use runstav::methods::view::{ViewClose, ViewEnv, ViewGlyphs, ViewMeasured, ViewResync};
use runstav::wire::Error;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, MutexGuard};

use crate::dispatch::Caller;
use crate::front::Front;

/// One (connection, view, display class).
pub type Key = (u64, String, String);

/// What one (view, class) holds: its env, the version and rows the editor was last sent, and the images it holds.
struct Pair {
    env: ViewEnv,
    version: u64,
    rows: Vec<Row>,
    sent_images: BTreeSet<ImageId>,
    reset_due: bool,
}

/// The pure core: every (view, class)'s env, version and rows, for one hub instance.
pub struct Store {
    hub: u64,
    pairs: BTreeMap<Key, Pair>,
}

impl Store {
    pub fn new(hub: u64) -> Self {
        Store {
            hub,
            pairs: BTreeMap::new(),
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
                        sent_images: BTreeSet::new(),
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
            p.sent_images.clear();
            p.reset_due = false;
        }
        let named: BTreeSet<ImageId> = p
            .rows
            .iter()
            .flat_map(|r| r.images.iter().map(|i| i.1))
            .collect();
        let new: Vec<(ImageId, String)> = images
            .iter()
            .filter(|(id, _)| named.contains(id) && !p.sent_images.contains(id))
            .cloned()
            .collect();
        p.sent_images.extend(new.iter().map(|i| i.0));
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
        }
    }

    /// The editor of KEY asks for its rows again: a reset of the rows it was last sent.
    pub fn resync(&mut self, key: &Key, images: &[(ImageId, String)]) -> Option<Patch> {
        let p = self.pairs.get_mut(key)?;
        let ops = vec![Op::Reset(p.rows.clone())];
        Some(Self::send(self.hub, key, p, ops, images))
    }

    /// CONN shows VIEW no more.
    pub fn close(&mut self, conn: u64, view: &str) -> bool {
        let before = self.pairs.len();
        self.pairs.retain(|(c, v, _), _| !(*c == conn && v == view));
        self.pairs.len() != before
    }

    /// Connection CONN is gone: its pairs with it.
    pub fn gone(&mut self, conn: u64) {
        self.pairs.retain(|(c, _, _), _| *c != conn);
    }
}

/// A random instance id below 2^53, so every JSON reader holds it exactly.
fn instance_id() -> u64 {
    let mut b = [0u8; 8];
    getrandom::fill(&mut b).expect("the system's random source");
    u64::from_le_bytes(b) & ((1 << 53) - 1)
}

/// A fixture view's rows and the images they may name.
type Fixture = (Vec<Row>, Vec<(ImageId, String)>);

/// The shell: the store, the rows the test fixture view is given (test hooks), and the sending.
pub struct Views {
    store: Mutex<Store>,
    /// `__test_view_rows`: the rows and images of a fixture view per (connection, view), the same in every class.
    fixtures: Mutex<BTreeMap<(u64, String), Fixture>>,
}

impl Default for Views {
    fn default() -> Self {
        Views {
            store: Mutex::new(Store::new(instance_id())),
            fixtures: Mutex::new(BTreeMap::new()),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Views {
    /// Builds (CONN, VIEW, CLASS)'s rows again and sends what changed. The builders: the test fixture view.
    fn build(&self, f: &Front, key: &Key) {
        let Some((rows, images)) = lock(&self.fixtures).get(&(key.0, key.1.clone())).cloned()
        else {
            return;
        };
        let patch = lock(&self.store).publish(key, rows, &images);
        if let Some(p) = patch {
            f.send_to(key.0, "view-patch", json!(p));
        }
    }

    /// The images a resync's reset may name.
    fn images_of(&self, key: &Key) -> Vec<(ImageId, String)> {
        lock(&self.fixtures)
            .get(&(key.0, key.1.clone()))
            .map(|(_, i)| i.clone())
            .unwrap_or_default()
    }

    /// `__test_view_rows {view, rows, images?}` (test hooks): CONN's fixture view VIEW shows ROWS in every class.
    pub fn fixture(
        &self,
        f: &Front,
        conn: u64,
        view: String,
        rows: Vec<Row>,
        images: Vec<(ImageId, String)>,
    ) {
        lock(&self.fixtures).insert((conn, view.clone()), (rows, images));
        let classes = lock(&self.store).classes(conn, &view);
        for class in classes {
            self.build(f, &(conn, view.clone(), class));
        }
    }

    pub fn gone(&self, conn: u64) {
        lock(&self.store).gone(conn);
        lock(&self.fixtures).retain(|(c, _), _| *c != conn);
    }
}

/// `view/env`: the env is kept and the (view, class)'s rows built again.
pub fn env(f: &Front, c: &Caller, p: ViewEnv) -> Result<bool, Error> {
    let views = &f.core.views;
    let key = (c.conn_id, p.view.clone(), p.class.clone());
    lock(&views.store).env(c.conn_id, p);
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

/// `view/glyphs`: the editor's advances (the fitter's, which reads them, arrives with it).
pub fn glyphs(_f: &Front, _c: &Caller, _p: ViewGlyphs) -> Result<bool, Error> {
    Ok(true)
}

/// `view/measured`: the fit guard's measurements (the fitter's, which reads them, arrives with it).
pub fn measured(_f: &Front, _c: &Caller, _p: ViewMeasured) -> Result<bool, Error> {
    Ok(true)
}

/// `view/close`: CALLER's VIEW ends.
pub fn close(f: &Front, c: &Caller, p: ViewClose) -> Result<bool, Error> {
    let views = &f.core.views;
    lock(&views.fixtures).remove(&(c.conn_id, p.view.clone()));
    Ok(lock(&views.store).close(c.conn_id, &p.view))
}

/// Whether P is one reset.
#[cfg(test)]
pub(crate) fn is_reset(p: &Patch) -> bool {
    matches!(p.ops.as_slice(), [Op::Reset(_)])
}
