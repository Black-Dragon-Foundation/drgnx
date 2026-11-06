//! Plugins in the hub (`docs/guide/plugins.md`, `docs/develop/plugins.md`): which are installed, which the user
//! approved and with which files, which run for a project, and the approval cards.
//!
//! - Installing is the CLI's ([`install`], `ratatoskr plugins install PATH`): it copies a folder into
//!   `<data>/plugins/NAME/`. The hub reads that folder with `brokkr::scan` at start and at every `plugins/list`
//!   ([`Plugins::sync`]); nothing else makes a plugin known.
//! - Approval is a row of `runtime.db`'s `plugin` table: the hash the user was shown ([`Plugins::approve`]), kept with
//!   the manifest's whole reach. A plugin whose files hash differently is `changed`: it stops being offered and a card
//!   asks again. Only the user's connection calls `plugins/approve` and `plugins/disable` (the method registry's
//!   classes); no agent tool or manager tool reaches them.
//! - Which approved plugins run for a project is the settings' ([`Plugins::enabled_for`], [`Plugins::rules_for`]): the
//!   global lists, and a project's own from its private workspace file, which the editor sends as `config/settings`.
//! - [`io`]: the plugin host's I/O policy (its key-value store with the manifest's quota, and the HTTP address
//!   decision); [`hub_io`]: the host's `HostIo` over it ([`host_io`]: one per session or job). Running a plugin is
//!   the host's.

pub mod hub_io;
pub mod io;

#[cfg(test)]
mod tests;

use std::collections::BTreeMap;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use brokkr::{Installed, Manifest, Point, VerdictKind};
use eitri::Kind;
use norn::hooks::Rule;
use runstav::methods::plugins::{
    ApproveParams, DisableParams, HookReach, PluginChanged, PluginList, PluginRow, PluginState,
    Reach,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};

use crate::dispatch::Caller;
use crate::front::Front;
use crate::settings::Settings;

/// An installed plugin whose files the user approved and that has not changed since: what the host is handed.
pub type Plugin = Installed;

const SETTING_PLUGINS: &str = "drgnx-agents-plugins";
const SETTING_RULES: &str = "drgnx-agents-hook-rules";
const SETTING_RULES_OFF: &str = "drgnx-agents-hook-rules-off";

fn error(code: ErrorCode, message: impl Into<String>, path: Option<&str>) -> Error {
    Error {
        code,
        message: message.into(),
        path: path.map(str::to_owned),
    }
}

fn internal(e: impl std::fmt::Display) -> Error {
    error(ErrorCode::Internal, e.to_string(), None)
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The lower-case hex of a hash.
pub fn hex(hash: &[u8; 32]) -> String {
    use std::fmt::Write;
    hash.iter().fold(String::with_capacity(64), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

fn point_name(p: Point) -> &'static str {
    match p {
        Point::BeforeTool => "before-tool",
        Point::AfterEdit => "after-edit",
        Point::BeforeCommit => "before-commit",
        Point::AtReview => "at-review",
    }
}

fn verdict_name(v: VerdictKind) -> &'static str {
    match v {
        VerdictKind::Allow => "allow",
        VerdictKind::Deny => "deny",
        VerdictKind::Change => "change",
        VerdictKind::Annotate => "annotate",
    }
}

/// Everything a manifest lets a plugin do, in the wire's words.
pub fn reach_of(m: &Manifest) -> Reach {
    Reach {
        abilities: m
            .abilities
            .iter()
            .map(|a| a.name.as_str().to_owned())
            .collect(),
        hosts: m
            .hosts
            .iter()
            .map(|h| format!("{}:{}", h.host(), h.port()))
            .collect(),
        hooks: m
            .hooks
            .iter()
            .map(|h| {
                let f = h.filter.clone().unwrap_or_default();
                HookReach {
                    point: point_name(h.point).into(),
                    verdicts: h.verdicts.iter().map(|v| verdict_name(*v).into()).collect(),
                    tool_kinds: f.tool_kinds,
                    tools: f.tools,
                    paths: f.paths.iter().map(|g| g.as_str().to_owned()).collect(),
                }
            })
            .collect(),
    }
}

/// What a plugin's row in `runtime.db` says.
#[derive(Clone, Debug, PartialEq)]
struct Stored {
    approved_hash: Option<String>,
    enabled: bool,
    approved_reach: Option<Reach>,
}

fn state_of(stored: Option<&Stored>, hash: &str) -> PluginState {
    match stored {
        None
        | Some(Stored {
            approved_hash: None,
            ..
        }) => PluginState::Unapproved,
        Some(s) if s.approved_hash.as_deref() != Some(hash) => PluginState::Changed,
        Some(s) if !s.enabled => PluginState::Disabled,
        Some(_) => PluginState::Approved,
    }
}

/// A plugin's state moved: `None` when it is gone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub name: String,
    pub state: Option<PluginState>,
}

/// The list as read now, and what moved since the last look.
#[derive(Debug, Default)]
pub struct Synced {
    pub rows: Vec<PluginRow>,
    pub changes: Vec<Change>,
}

/// The state of the last look.
#[derive(Default)]
struct Snapshot {
    states: BTreeMap<String, PluginState>,
    /// The approved ones, in name order.
    approved: Vec<Arc<Plugin>>,
}

struct Open {
    root: PathBuf,
    db: urdr::Handle,
    settings: Arc<Settings>,
}

/// The hub's plugins. Opened once at start ([`Plugins::open`]); every method answers an error before that.
#[derive(Default)]
pub struct Plugins {
    open: OnceLock<Open>,
    snap: Mutex<Snapshot>,
    /// One look at a time: two racing syncs would each announce the same change.
    looking: tokio::sync::Mutex<()>,
    /// The network plugins reach, made at the first [`host_io`].
    net: OnceLock<Arc<hub_io::Net>>,
    /// The WASM host, made at the first call.
    host: OnceLock<Arc<brokkr::Host>>,
    /// The ability calls waiting for a card's answer.
    waits: Arc<Waits>,
    /// The ability tools of the last plugin set asked for, by its [`Plugins::set_key`].
    pub(crate) tools: Mutex<BTreeMap<String, Arc<Vec<crate::abilities::AbilityTool>>>>,
}

/// The ability calls waiting on matrix cards: who waits on which card, how many wait, and how many cards a call that
/// ended withdrew. Tests wait on the two counters (the handshake), never on a clock.
pub struct Waits {
    next: std::sync::atomic::AtomicU64,
    by_id: Mutex<BTreeMap<u64, (i64, tokio::sync::oneshot::Sender<()>)>>,
    count: tokio::sync::watch::Sender<usize>,
    withdrawn: tokio::sync::watch::Sender<u64>,
}

impl Default for Waits {
    fn default() -> Self {
        Waits {
            next: std::sync::atomic::AtomicU64::new(0),
            by_id: Mutex::new(BTreeMap::new()),
            count: tokio::sync::watch::channel(0).0,
            withdrawn: tokio::sync::watch::channel(0).0,
        }
    }
}

/// One call's place among the waiters of a card; leaving it (the answer came, or the call ended) takes it out.
pub struct CardWait {
    waits: Arc<Waits>,
    id: u64,
    /// Resolves when the card is settled.
    pub settled: tokio::sync::oneshot::Receiver<()>,
}

impl Drop for CardWait {
    fn drop(&mut self) {
        lock(&self.waits.by_id).remove(&self.id);
        self.waits.count.send_modify(|n| *n -= 1);
    }
}

/// The I/O of the plugin calls of CTX (a session or a job, with the network cell it launched with; none: every request
/// is refused), for the plugins with MANIFESTS: one per session or job, handed to the host at each of its calls.
pub fn host_io(
    f: &Front,
    ctx: Option<(io::IoCtx, crate::agents::launch::NetCell)>,
    manifests: &[&Manifest],
) -> Result<Arc<hub_io::HubIo>, Error> {
    let o = f.core.plugins.opened()?;
    let net = f
        .core
        .plugins
        .net
        .get_or_init(|| Arc::new(hub_io::Net::system()))
        .clone();
    Ok(Arc::new(hub_io::HubIo::new(
        ctx,
        manifests,
        hub_io::HubParts {
            db: o.db.clone(),
            settings: o.settings.clone(),
            host_addrs: f.browser_nevers.host_addrs.shared(),
            writer: f.writer.clone(),
            net,
        },
    )))
}

impl Plugins {
    /// The plugins under ROOT (`<data>/plugins`), their approvals in DB (`runtime.db`) and the lists in SETTINGS.
    pub fn open(&self, root: PathBuf, db: urdr::Handle, settings: Arc<Settings>) {
        let _ = self.open.set(Open { root, db, settings });
    }

    /// The WASM host (made at the first call).
    pub fn host(&self) -> Result<Arc<brokkr::Host>, Error> {
        if let Some(h) = self.host.get() {
            return Ok(h.clone());
        }
        let made = Arc::new(brokkr::Host::new(brokkr::Limits::default()).map_err(internal)?);
        Ok(self.host.get_or_init(|| made).clone())
    }

    /// The approved plugins that run for PROJECT and have an ability, as of the last [`Plugins::sync`].
    pub fn abilities_for(&self, project: Option<&str>) -> Vec<Arc<Plugin>> {
        let mut all = self.enabled_for(project);
        all.retain(|p| !p.manifest.abilities.is_empty());
        all
    }

    /// What identifies a set of plugins: their hashes in order (empty for none).
    pub fn set_key(set: &[Arc<Plugin>]) -> String {
        set.iter()
            .map(|p| hex(&p.hash))
            .collect::<Vec<_>>()
            .join(",")
    }

    /// A call starts waiting for CARD's answer.
    pub fn wait_card(&self, card: i64) -> CardWait {
        let (tx, settled) = tokio::sync::oneshot::channel();
        let id = self
            .waits
            .next
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        lock(&self.waits.by_id).insert(id, (card, tx));
        self.waits.count.send_modify(|n| *n += 1);
        CardWait {
            waits: self.waits.clone(),
            id,
            settled,
        }
    }

    /// CARD was settled: the calls waiting on it go on.
    pub fn card_settled(&self, card: i64) {
        let mut by = lock(&self.waits.by_id);
        let ids: Vec<u64> = by
            .iter()
            .filter(|(_, (c, _))| *c == card)
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            if let Some((_, tx)) = by.remove(&id) {
                let _ = tx.send(());
            }
        }
    }

    /// How many calls wait on a card now.
    pub fn waiting(&self) -> tokio::sync::watch::Receiver<usize> {
        self.waits.count.subscribe()
    }

    /// How many cards calls that ended have withdrawn so far.
    pub fn withdrawn(&self) -> tokio::sync::watch::Receiver<u64> {
        self.waits.withdrawn.subscribe()
    }

    /// A card withdrawn because its call ended.
    pub(crate) fn note_withdrawn(&self) {
        self.waits.withdrawn.send_modify(|n| *n += 1);
    }

    fn opened(&self) -> Result<&Open, Error> {
        self.open
            .get()
            .ok_or_else(|| internal("the plugins are not open yet"))
    }

    /// The folder is read again: the list, and what changed since the last look (every plugin at the first).
    pub async fn sync(&self) -> Result<Synced, Error> {
        let _one = self.looking.lock().await;
        let o = self.opened()?;
        let root = o.root.clone();
        let present = root.is_dir();
        let scanned = crate::clock::blocking(move || brokkr::scan(&root))
            .await
            .map_err(internal)?;
        let stored = read_rows(&o.db).await?;

        // the hash on disk now, kept for the next approval check
        let seen: Vec<(String, String)> = scanned
            .iter()
            .filter_map(|r| r.as_ref().ok())
            .map(|i| (i.manifest.name.as_str().to_owned(), hex(&i.hash)))
            .collect();
        let gone: Vec<String> = if present {
            stored
                .keys()
                .filter(|n| {
                    !scanned.iter().any(|r| match r {
                        Ok(i) => i.manifest.name.as_str() == n.as_str(),
                        Err((folder, _)) => folder == *n,
                    })
                })
                .cloned()
                .collect()
        } else {
            Vec::new()
        };
        if !seen.is_empty() || !gone.is_empty() {
            o.db.write(move |c| {
                for (name, hash) in &seen {
                    c.execute(
                        "insert into plugin(name, hash) values (?1, ?2) \
                         on conflict(name) do update set hash = excluded.hash",
                        (name, hash),
                    )?;
                }
                for name in &gone {
                    c.execute("delete from plugin where name = ?1", [name])?;
                    c.execute("delete from plugin_kv where plugin = ?1", [name])?;
                }
                Ok(())
            })
            .await
            .map_err(internal)?;
        }

        let mut rows = Vec::new();
        let mut approved = Vec::new();
        for r in scanned {
            match r {
                Ok(inst) => {
                    let h = hex(&inst.hash);
                    let st = stored.get(inst.manifest.name.as_str());
                    let state = state_of(st, &h);
                    let reach = (state == PluginState::Changed)
                        .then(|| st.and_then(|s| s.approved_reach.clone()))
                        .flatten();
                    rows.push(row_of(&inst, state, reach));
                    if state == PluginState::Approved {
                        approved.push(Arc::new(inst));
                    }
                }
                Err((folder, e)) => rows.push(PluginRow {
                    name: folder,
                    version: None,
                    hash: None,
                    state: PluginState::Broken,
                    abilities: Vec::new(),
                    hooks: Vec::new(),
                    hosts: Vec::new(),
                    kv_bytes: None,
                    approved_reach: None,
                    problem: Some(e.to_string()),
                }),
            }
        }

        let mut changes = Vec::new();
        {
            let mut snap = lock(&self.snap);
            let now: BTreeMap<String, PluginState> =
                rows.iter().map(|r| (r.name.clone(), r.state)).collect();
            for (name, state) in &now {
                if snap.states.get(name) != Some(state) {
                    changes.push(Change {
                        name: name.clone(),
                        state: Some(*state),
                    });
                }
            }
            for name in snap.states.keys().filter(|n| !now.contains_key(*n)) {
                changes.push(Change {
                    name: name.clone(),
                    state: None,
                });
            }
            snap.states = now;
            snap.approved = approved;
        }
        Ok(Synced { rows, changes })
    }

    /// Approve the plugin NAME whose files hash to HASH, the hash the user was shown. The files are read again first: a
    /// plugin whose files are not these any more is refused, and so is one that is broken or not installed.
    pub async fn approve(&self, name: &str, hash: &str) -> Result<(PluginRow, Vec<Change>), Error> {
        let installed = self.installed(name).await?;
        let now = hex(&installed.hash);
        if now != hash {
            return Err(error(
                ErrorCode::InvalidParams,
                format!(
                    "{name} is not the plugin you were shown: its files hash to {now} now, not {hash}; look at it again"
                ),
                Some("hash"),
            ));
        }
        let reach = serde_json::to_string(&reach_of(&installed.manifest)).map_err(internal)?;
        let (n, at) = (name.to_owned(), crate::clock::wall_secs());
        let o = self.opened()?;
        o.db.write(move |c| {
            c.execute(
                "insert into plugin(name, hash, approved_hash, approved_at, enabled, approved_reach) \
                 values (?1, ?2, ?2, ?3, 1, ?4) \
                 on conflict(name) do update set hash = excluded.hash, approved_hash = excluded.approved_hash, \
                 approved_at = excluded.approved_at, enabled = 1, approved_reach = excluded.approved_reach",
                (&n, &now, at, &reach),
            )?;
            Ok(())
        })
        .await
        .map_err(internal)?;
        self.after(name).await
    }

    /// Switch the plugin NAME off until the user approves it again.
    pub async fn disable(&self, name: &str) -> Result<(PluginRow, Vec<Change>), Error> {
        let installed = self.installed(name).await?;
        let (n, h) = (name.to_owned(), hex(&installed.hash));
        let o = self.opened()?;
        o.db.write(move |c| {
            c.execute(
                "insert into plugin(name, hash, enabled) values (?1, ?2, 0) \
                 on conflict(name) do update set enabled = 0",
                (&n, &h),
            )?;
            Ok(())
        })
        .await
        .map_err(internal)?;
        self.after(name).await
    }

    /// NAME as installed now (the folder is read again), or why not.
    async fn installed(&self, name: &str) -> Result<Installed, Error> {
        let o = self.opened()?;
        let root = o.root.clone();
        let scanned = crate::clock::blocking(move || brokkr::scan(&root))
            .await
            .map_err(internal)?;
        for r in scanned {
            match r {
                Ok(i) if i.manifest.name.as_str() == name => return Ok(i),
                Err((folder, e)) if folder == name => {
                    return Err(error(
                        ErrorCode::InvalidParams,
                        format!("{name} is broken and cannot be approved: {e}"),
                        Some("name"),
                    ));
                }
                _ => {}
            }
        }
        Err(error(
            ErrorCode::InvalidParams,
            format!("no plugin {name} is installed"),
            Some("name"),
        ))
    }

    /// The row of NAME after a change, and what moved.
    async fn after(&self, name: &str) -> Result<(PluginRow, Vec<Change>), Error> {
        let Synced { rows, changes } = self.sync().await?;
        let row = rows
            .into_iter()
            .find(|r| r.name == name)
            .ok_or_else(|| internal(format!("{name} vanished")))?;
        Ok((row, changes))
    }

    /// The approved plugins that run for PROJECT (none: the global list), in the list's order, as of the last
    /// [`Plugins::sync`]. A project's own list, when its private workspace file set one, replaces the global one. A
    /// listed plugin that is not approved, or whose files changed, is left out.
    pub fn enabled_for(&self, project: Option<&str>) -> Vec<Arc<Plugin>> {
        let Ok(o) = self.opened() else {
            return Vec::new();
        };
        let list = project
            .and_then(|p| o.settings.project_value(SETTING_PLUGINS, p))
            .or_else(|| o.settings.effective(SETTING_PLUGINS, None).map(|(v, _)| v));
        let names: Vec<String> = list
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default();
        let snap = lock(&self.snap);
        let mut out: Vec<Arc<Plugin>> = Vec::new();
        for n in names {
            if let Some(p) = snap.approved.iter().find(|p| p.manifest.name.as_str() == n)
                && !out.iter().any(|q| q.manifest.name == p.manifest.name)
            {
                out.push(p.clone());
            }
        }
        out
    }

    /// The hook rules in force for PROJECT: the global rules minus those whose `id` the project switched off, then the
    /// project's own (a rule the project's list repeats from the global one counts once).
    pub fn rules_for(&self, project: Option<&str>) -> Vec<Rule> {
        let Ok(o) = self.opened() else {
            return Vec::new();
        };
        let list = |v: Option<Value>| -> Vec<Value> {
            match v {
                Some(Value::Array(a)) => a,
                _ => Vec::new(),
            }
        };
        let norm = |v: Vec<Value>| -> Vec<Value> {
            match crate::settings::hook_rules(&Value::Array(v)) {
                Ok(Value::Array(a)) => a,
                _ => Vec::new(),
            }
        };
        let global = norm(list(
            o.settings.effective(SETTING_RULES, None).map(|(v, _)| v),
        ));
        let (own, off): (Vec<Value>, Vec<String>) = match project {
            None => (Vec::new(), Vec::new()),
            Some(p) => (
                norm(list(o.settings.project_value(SETTING_RULES, p))),
                o.settings
                    .project_value(SETTING_RULES_OFF, p)
                    .and_then(|v| serde_json::from_value(v).ok())
                    .unwrap_or_default(),
            ),
        };
        let mut all: Vec<Value> = global
            .iter()
            .filter(|r| {
                !r.get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| off.iter().any(|o| o == id))
            })
            .cloned()
            .collect();
        all.extend(own.into_iter().filter(|r| !global.contains(r)));
        norn::hooks::parse_rules(&Value::Array(all)).unwrap_or_default()
    }
}

fn row_of(inst: &Installed, state: PluginState, approved_reach: Option<Reach>) -> PluginRow {
    let reach = reach_of(&inst.manifest);
    PluginRow {
        name: inst.manifest.name.as_str().to_owned(),
        version: Some(inst.manifest.version.clone()),
        hash: runstav::types::Hex64::new(hex(&inst.hash)).ok(),
        state,
        abilities: reach.abilities,
        hooks: reach.hooks,
        hosts: reach.hosts,
        kv_bytes: Some(
            inst.manifest
                .kv_bytes
                .unwrap_or(brokkr::manifest::MAX_KV_BYTES),
        ),
        approved_reach,
        problem: None,
    }
}

/// Every row of the `plugin` table.
async fn read_rows(db: &urdr::Handle) -> Result<BTreeMap<String, Stored>, Error> {
    db.read(|c| {
        let mut st = c.prepare(
            "select name, approved_hash, enabled, approved_reach from plugin order by name",
        )?;
        let rows = st
            .query_map([], |r| {
                let reach: Option<String> = r.get(3)?;
                Ok((
                    r.get::<_, String>(0)?,
                    Stored {
                        approved_hash: r.get(1)?,
                        enabled: r.get::<_, i64>(2)? != 0,
                        approved_reach: reach.and_then(|t| serde_json::from_str(&t).ok()),
                    },
                ))
            })?
            .collect::<Result<BTreeMap<_, _>, _>>()?;
        Ok(rows)
    })
    .await
    .map_err(internal)
}

// ------------------------------------------------------------------------------------------------- the methods

/// `plugins/list`.
pub async fn list(f: &Front, _: &Caller, _: runstav::methods::Empty) -> Result<PluginList, Error> {
    let synced = f.core.plugins.sync().await?;
    announce(f, &synced.rows, &synced.changes).await;
    Ok(PluginList {
        plugins: synced.rows,
    })
}

/// `plugins/approve`.
pub async fn approve(f: &Front, _: &Caller, p: ApproveParams) -> Result<PluginRow, Error> {
    let (row, changes) = f
        .core
        .plugins
        .approve(p.name.0.as_str(), p.hash.as_str())
        .await?;
    announce(f, std::slice::from_ref(&row), &changes).await;
    Ok(row)
}

/// `plugins/disable`.
pub async fn disable(f: &Front, _: &Caller, p: DisableParams) -> Result<PluginRow, Error> {
    let (row, changes) = f.core.plugins.disable(p.name.0.as_str()).await?;
    announce(f, std::slice::from_ref(&row), &changes).await;
    Ok(row)
}

/// The hub looked at the folder at its start: plugins waiting for the user have their cards.
pub async fn start(f: &Front) {
    match f.core.plugins.sync().await {
        Ok(s) => announce(f, &s.rows, &s.changes).await,
        Err(e) => tracing::warn!("the installed plugins were not read: {}", e.message),
    }
}

/// CHANGES as `plugin` events, and the cards of the plugins ROWS shows: one for each that waits for the user
/// (`unapproved`, `changed`), none for the others, and the ones of a removed plugin withdrawn.
async fn announce(f: &Front, rows: &[PluginRow], changes: &[Change]) {
    // the plugins that run for a session may have moved: its snapshot says so
    f.mcp.plugins_refresh();
    if changes.is_empty() {
        return;
    }
    for c in changes {
        let state = c.state.map_or("removed".to_owned(), |s| {
            serde_json::to_value(s)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default()
        });
        f.broadcast(
            "plugin",
            json!(PluginChanged {
                name: c.name.clone(),
                state
            }),
        );
    }
    let wanted: Vec<(String, String, &'static str)> = rows
        .iter()
        .filter_map(|r| {
            let why = match r.state {
                PluginState::Unapproved => "unapproved",
                PluginState::Changed => "changed",
                _ => return None,
            };
            Some((
                r.name.clone(),
                r.hash.as_ref().map(|h| h.as_str().to_owned())?,
                why,
            ))
        })
        .collect();
    let touched: Vec<String> = changes.iter().map(|c| c.name.clone()).collect();
    let at = crate::clock::wall_secs();
    let r = f
        .writer
        .db
        .write(
            urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "plugins"),
            move |tx| {
                let open: Vec<(i64, String, String, String)> = {
                    let mut st = tx.sql().prepare(
                        "select id, data from card where kind = 'plugin' and state = 'open'",
                    )?;
                    let rows = st
                        .query_map([], |r| {
                            Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?))
                        })?
                        .collect::<Result<Vec<_>, _>>()?;
                    rows.into_iter()
                        .filter_map(|(id, data)| {
                            let d: Value = serde_json::from_str(&data?).ok()?;
                            let field = |k: &str| d.get(k)?.as_str().map(str::to_owned);
                            Some((id, field("plugin")?, field("hash")?, field("why")?))
                        })
                        .collect()
                };
                for (id, name, hash, why) in &open {
                    if !touched.contains(name) {
                        continue;
                    }
                    let keep = wanted
                        .iter()
                        .any(|(n, h, w)| n == name && h == hash && *w == why.as_str());
                    if !keep {
                        norn::write::cards::card_withdraw(tx, *id, at)?;
                    }
                }
                for (name, hash, why) in &wanted {
                    if !touched.contains(name)
                        || open
                            .iter()
                            .any(|(_, n, h, w)| n == name && h == hash && w.as_str() == *why)
                    {
                        continue;
                    }
                    let title = if *why == "changed" {
                        format!("plugin {name} changed since you approved it: look at it again")
                    } else {
                        format!("plugin {name} is installed and waits for your approval")
                    };
                    norn::write::cards::card_create(
                        tx,
                        norn::write::cards::NewCard {
                            job: None,
                            task: None,
                            kind: Some("plugin".into()),
                            title: Some(title),
                            data: Some(json!({
                                "plugin": name, "hash": hash, "why": why, "choices": ["review"],
                            })),
                        },
                        at,
                    )?;
                }
                Ok(())
            },
        )
        .await;
    match r {
        Ok(()) => f.writer.signals.wrote(),
        Err(e) => tracing::warn!("the plugin cards were not updated: {e}"),
    }
}

// ------------------------------------------------------------------------------------------------- install

/// A plugin copied into the data folder.
#[derive(Debug, PartialEq, Eq)]
pub struct Installation {
    pub name: String,
    pub version: String,
    /// The hash the user approves: lower-case hex.
    pub hash: String,
}

/// Copy the plugin folder SRC (`plugin.json` and `plugin.wasm`, read beneath it, no link followed) to ROOT/NAME with
/// mode 0700. A plugin of that name is installed already: refused, unless REPLACE (the new files take the folder's
/// place whole, and the plugin turns `changed` if it was approved). The files are parsed first; nothing is copied for a
/// manifest that does not read.
pub fn install(root: &Path, src: &Path, replace: bool) -> Result<Installation, String> {
    use brokkr::store::MAX_WASM_BYTES;
    let src = src
        .canonicalize()
        .map_err(|e| format!("{}: {e}", src.display()))?;
    let dir = eitri::open_path(&src, Kind::Dir).map_err(|e| format!("{}: {e}", src.display()))?;
    let read = |file: &str, cap: u64| {
        eitri::read_regular(dir.fd.as_fd(), Path::new(file), cap)
            .map_err(|e| format!("{}: {file}: {e}", src.display()))
    };
    let manifest_bytes = read("plugin.json", brokkr::manifest::MAX_MANIFEST_BYTES)?;
    let wasm = read("plugin.wasm", MAX_WASM_BYTES)?;
    let manifest = brokkr::parse(&manifest_bytes).map_err(|e| format!("plugin.json: {e}"))?;
    let name = manifest.name.as_str().to_owned();
    let dest = root.join(&name);
    if dest.symlink_metadata().is_ok() && !replace {
        return Err(format!(
            "{name} is installed already: install it with --replace to put these files in its place"
        ));
    }
    let parent = root
        .parent()
        .ok_or_else(|| format!("{}: has no parent folder", root.display()))?;
    private_dir(root)?;
    let stage = parent.join(format!(".plugin-new-{name}-{}", std::process::id()));
    let old = parent.join(format!(".plugin-old-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&stage);
    let _ = std::fs::remove_dir_all(&old);
    let made = (|| -> Result<(), String> {
        private_dir(&stage)?;
        let pinned = eitri::open_path(&stage, Kind::Dir).map_err(|e| e.to_string())?;
        for (file, bytes) in [("plugin.json", &manifest_bytes), ("plugin.wasm", &wasm)] {
            eitri::write_regular(pinned.fd.as_fd(), Path::new(file), bytes, 0o600)
                .map_err(|e| format!("{file}: {e}"))?;
        }
        if dest.symlink_metadata().is_ok() {
            std::fs::rename(&dest, &old).map_err(|e| format!("{}: {e}", dest.display()))?;
        }
        std::fs::rename(&stage, &dest).map_err(|e| format!("{}: {e}", dest.display()))
    })();
    let _ = std::fs::remove_dir_all(&old);
    if let Err(e) = made {
        let _ = std::fs::remove_dir_all(&stage);
        return Err(e);
    }
    Ok(Installation {
        name,
        version: manifest.version.clone(),
        hash: hex(&brokkr::plugin_hash(&manifest_bytes, &wasm)),
    })
}

/// DIR made (with its parents) and set to 0700.
fn private_dir(dir: &Path) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("{}: {e}", dir.display()))
}

/// Delete the installed plugin NAME's folder. The hub forgets its approval at its next look.
pub fn remove(root: &Path, name: &str) -> Result<(), String> {
    if brokkr::PluginName::try_from(name.to_owned()).is_err() {
        return Err(format!("{name:?} is not a plugin name"));
    }
    let dir = root.join(name);
    if dir.symlink_metadata().is_err() {
        return Err(format!("no plugin {name} is installed"));
    }
    std::fs::remove_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))
}
