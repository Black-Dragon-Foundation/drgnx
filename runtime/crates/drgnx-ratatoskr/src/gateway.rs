//! The gateway in the hub (docs/develop/hub.md, "Registrations", "Forwarding", "Keys"; design §5.6, §6.2): the front
//! serves `gateway/register`, `gateway/unregister`, `gateway/keys`, `gateway/set-budget`, `config/providers` and
//! `spend` itself, and `bifrost` forwards the requests.  Nothing of it goes to the Lisp backend but the `budget`
//! notification.
//!
//! - **Registrations** live in memory (what `bifrost` admits by) and in `runtime.db`'s `registration` table, keyed by
//!   the SHA-256 of their token: the token is answered once and kept nowhere.  The row is written before the answer.
//!   Each has an owner (the params' pid, else the caller's) and its start time; a registration whose owner is gone (a
//!   dead pid, or another start time) is pruned at start and at each [`sessions::TICK`] (M9b1-10), and so is one
//!   bound to a session that closed.  One without a readable owner stays until it is unregistered (the Lisp's rule).
//! - **A chain is judged** when it is registered: a step whose provider is not in the table ("not configured"), does
//!   not speak Messages ("the gateway cannot carry it") or has no key ("no key") cannot be used; with none usable the
//!   registration is refused (`invalid-params`, path `chain`, every step's reason; fail closed).
//! - **Keys** are held in memory only (`bifrost::keys::Keys`): never `runtime.db`, a file, a log, the environment or
//!   the backend.  The ids whose key is held are what `status` and the doctor name.
//! - **The provider table** is the editor's (`config/providers`), replaced whole; its last good copy is kept in
//!   `runtime.db`'s `kv` (it holds no key).  A keyed provider over clear-text `http` off loopback is applied, with a
//!   warning in the answer, logged once per provider per start (the user's answer 4).
//! - **The port:** `kv.gateway_port` is tried first, else a free one, and the result stored.
//! - **Spend** is `work.db`'s `spend` table (`norn`): the engine records a row per request ([`WorkLedger`]), and the
//!   budget is read from it.  A job's budget is the registration's, else the job's `data.budget`.
//! - **Events:** the engine's `request`, `fallback`, `budget` and `gateway/need-keys` go to the subscribers; a
//!   `budget` also goes to the backend as a notification `budget {job, spent, budget}` (fire and forget).  The
//!   providers kept registrations need and whose key is absent at start are told to each new subscriber until a key
//!   comes.

use crate::front::Front;
use crate::sessions::{self, Sessions};
use crate::shape;
use bifrost::admit::{Registry, token_hash};
use bifrost::budget::Price;
use bifrost::engine::{BoxFuture, Gateway, GatewayEvent, Ledger, SpendRow};
use bifrost::keys::Keys;
use bifrost::upstream::{Upstream, UpstreamOpts};
use bifrost::{Auth, Caps, Class, Kind, ListenerId, Provider, Registration, Restrictions, Step};
use norn::store::{CoordDb, CoordError};
use runstav::methods::Params;
use runstav::methods::gateway::{
    DataCollection, OpenrouterRestrictions, ProviderAuth, ProviderCap, ProviderConfig,
    ProviderKind, ProviderWarning, ProvidersApplied, ProvidersParams, RegisterParams,
    Registration as Registered, SetBudgetParams, Spend, SpendParams,
};
use runstav::methods::hub::GatewayStatus;
use runstav::types::ProviderKeys;
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, RwLock};
use tokio::net::{TcpListener, UnixListener};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

/// The kv keys.
const KV_PORT: &str = "gateway_port";
const KV_PROVIDERS: &str = "providers";

fn error(code: ErrorCode, message: impl Into<String>, path: Option<&str>) -> Error {
    Error {
        code,
        message: message.into(),
        path: path.map(str::to_owned),
    }
}

fn internal(message: impl Into<String>) -> Error {
    error(ErrorCode::Internal, message, None)
}

fn invalid(path: &str, message: impl Into<String>) -> Error {
    error(ErrorCode::InvalidParams, message, Some(path))
}

/// Seconds since the epoch.
fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn read<T>(l: &RwLock<T>) -> std::sync::RwLockReadGuard<'_, T> {
    l.read().unwrap_or_else(PoisonError::into_inner)
}

fn write<T>(l: &RwLock<T>) -> std::sync::RwLockWriteGuard<'_, T> {
    l.write().unwrap_or_else(PoisonError::into_inner)
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// One registration as the hub keeps it.
#[derive(Clone)]
struct Kept {
    reg: Registration,
    /// The owner's pid and start time; none: it stays until unregistered.
    owner: Option<(u32, u64)>,
}

/// The registrations by token hash: what `bifrost` admits by.
#[derive(Default)]
struct Regs(RwLock<BTreeMap<String, Kept>>);

impl Registry for Regs {
    fn find(&self, hash: &str) -> Option<Registration> {
        read(&self.0).get(hash).map(|k| k.reg.clone())
    }
}

/// `work.db`'s `spend` table as the engine's ledger.
pub struct WorkLedger(pub CoordDb);

impl Ledger for WorkLedger {
    fn spent(&self, job: &str) -> BoxFuture<'_, Result<f64, String>> {
        let job = job.to_owned();
        Box::pin(async move {
            match self
                .0
                .read(move |c| norn::read::spend::spend_sum(c, Some(&job), None, None))
                .await
            {
                Ok(s) => Ok(s.cost),
                // no work.db yet: nothing was recorded either
                Err(CoordError::NotReady { .. }) => Ok(0.0),
                Err(e) => Err(e.to_string()),
            }
        })
    }

    fn record(&self, row: SpendRow) -> BoxFuture<'_, ()> {
        Box::pin(async move {
            let provider = row.provider.clone();
            let r = norn::write::spend::SpendRow {
                job: row.job,
                task: row.task,
                agent: row.agent,
                provider: row.provider,
                model: row.model,
                input: row.input,
                output: row.output,
                cost: row.cost,
                status: row.status,
            };
            let at = now();
            if let Err(e) = self
                .0
                .write(
                    urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "gateway"),
                    move |tx| norn::write::spend::add_spend(tx, &r, at),
                )
                .await
            {
                tracing::warn!(provider, "a spend row was not recorded: {e}");
            }
        })
    }
}

/// The front's gateway.
pub struct Gate {
    coord: CoordDb,
    regs: Arc<Regs>,
    providers: Arc<RwLock<BTreeMap<String, Provider>>>,
    keys: Arc<RwLock<Keys>>,
    /// The ids whose key is held (`Keys` lists none).
    held: Mutex<BTreeSet<String>>,
    db: OnceLock<urdr::Handle>,
    /// The editor token the hub's own embedder uses (memory only, made when first asked for).
    embed_token: OnceLock<String>,
    /// The engine and the loopback port, once it listens.
    engine: OnceLock<(Arc<Gateway>, u16)>,
    warnings: Mutex<Vec<ProviderWarning>>,
    /// Providers whose clear-text warning was logged since start.
    warned: Mutex<BTreeSet<String>>,
    /// Providers kept registrations need whose key was absent at start, told to each new subscriber.
    pending: Mutex<BTreeSet<String>>,
    requests: AtomicU64,
    errors: AtomicU64,
    fallbacks: AtomicU64,
    /// One registration change at a time: a row and memory change together.
    serial: tokio::sync::Mutex<()>,
}

impl Gate {
    /// No registration, provider or key yet; spend through COORD.
    pub fn new(coord: CoordDb) -> Gate {
        Gate {
            coord,
            regs: Arc::new(Regs::default()),
            providers: Arc::new(RwLock::new(BTreeMap::new())),
            keys: Arc::new(RwLock::new(Keys::new())),
            held: Mutex::new(BTreeSet::new()),
            db: OnceLock::new(),
            embed_token: OnceLock::new(),
            engine: OnceLock::new(),
            warnings: Mutex::new(Vec::new()),
            warned: Mutex::new(BTreeSet::new()),
            pending: Mutex::new(BTreeSet::new()),
            requests: AtomicU64::new(0),
            errors: AtomicU64::new(0),
            fallbacks: AtomicU64::new(0),
            serial: tokio::sync::Mutex::new(()),
        }
    }

    /// Registrations and the provider table are kept in DB (`runtime.db`; once, at start).
    pub fn open_store(&self, db: urdr::Handle) {
        if self.db.set(db).is_err() {
            tracing::warn!("the gateway's store was given twice: the first is kept");
        }
    }

    fn db(&self) -> Result<&urdr::Handle, Error> {
        self.db
            .get()
            .ok_or_else(|| internal("runtime.db is not open: no gateway"))
    }

    fn engine(&self) -> Result<&(Arc<Gateway>, u16), Error> {
        self.engine
            .get()
            .ok_or_else(|| internal("the gateway is not listening"))
    }

    /// Listen on 127.0.0.1: PORT when given (`--gateway-port`, test hooks), else `kv.gateway_port`, else a free one;
    /// the port is stored.  The engine's events come out of the receiver ([`run_events`]).
    pub async fn listen(
        &self,
        port: Option<u16>,
    ) -> Result<mpsc::UnboundedReceiver<GatewayEvent>, String> {
        let kept = match self.db.get() {
            Some(db) => kv_get(db, KV_PORT).await.and_then(|p| p.parse().ok()),
            None => None,
        };
        let listener = match port.or(kept) {
            Some(p) => match TcpListener::bind(("127.0.0.1", p)).await {
                Ok(l) => l,
                // the stored port is taken now: any free one (a port asked for is not given up on)
                Err(e) if port.is_none() => {
                    tracing::info!("the gateway's port {p} is taken ({e}): another one");
                    TcpListener::bind(("127.0.0.1", 0))
                        .await
                        .map_err(|e| e.to_string())?
                }
                Err(e) => return Err(format!("cannot listen on 127.0.0.1:{p}: {e}")),
            },
            None => TcpListener::bind(("127.0.0.1", 0))
                .await
                .map_err(|e| e.to_string())?,
        };
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        draugr::spawn::never_pass(&listener);
        if let Some(db) = self.db.get() {
            kv_set(db, KV_PORT, &port.to_string()).await;
        }
        let upstream = Upstream::new(UpstreamOpts::default())
            .map_err(|e| format!("no upstream client: {e}"))?;
        let (tx, rx) = mpsc::unbounded_channel();
        let gw = Gateway::new(
            self.regs.clone(),
            self.providers.clone(),
            self.keys.clone(),
            Arc::new(WorkLedger(self.coord.clone())),
            tx,
            upstream,
        );
        if self.engine.set((gw.clone(), port)).is_err() {
            return Err("the gateway listens already".into());
        }
        tokio::spawn(bifrost::listen::serve_tcp(gw, listener, port));
        tracing::info!(port, "the gateway on 127.0.0.1:{port}");
        Ok(rx)
    }

    /// The embedder for the first provider of kind `tei` that can embed (by id), through this gateway's loopback
    /// listener with an editor token of its own (kept in memory only, never in `runtime.db`); `None` when there is no
    /// such provider.  Err: the gateway is not listening.
    pub fn embedder(&self) -> Result<Option<crate::embed::Tei>, Error> {
        let (_, port) = self.engine()?;
        let Some(id) = read(&self.providers)
            .values()
            .find(|p| p.kind == Kind::Tei && p.caps.embed)
            .map(|p| p.id.clone())
        else {
            return Ok(None);
        };
        let token = match self.embed_token.get() {
            Some(t) => t.clone(),
            None => {
                let t = token().map_err(|e| internal(format!("no token: {e}")))?;
                write(&self.regs.0).insert(
                    token_hash(t.as_bytes()),
                    Kept {
                        reg: Registration::editor(),
                        owner: None,
                    },
                );
                self.embed_token.get_or_init(|| t).clone()
            }
        };
        Ok(Some(crate::embed::Tei::new(*port, token, &id)))
    }

    /// At start, after the sessions came back: the last provider table, then the registrations of live owners (each
    /// bound to its session's socket again), the others deleted; the providers they need whose key is absent are kept
    /// to tell each new subscriber.
    pub async fn restore(&self, sessions: &Sessions) {
        let Ok(db) = self.db() else { return };
        if let Some(text) = kv_get(db, KV_PROVIDERS).await {
            match serde_json::from_str::<Vec<ProviderConfig>>(&text) {
                Ok(table) => {
                    if let Err(e) = self.apply(&table) {
                        tracing::warn!("the kept provider table does not apply: {}", e.message);
                    }
                }
                Err(e) => tracing::warn!("the kept provider table does not read: {e}"),
            }
        }
        let rows = match rows(db).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("cannot read runtime.db's registrations: {e}");
                return;
            }
        };
        let _one = self.serial.lock().await;
        for (hash, row) in rows {
            let kept = match self.kept_of(&row) {
                Ok(k) => k,
                Err(why) => {
                    tracing::warn!("dropped a registration that does not read: {why}");
                    delete(db, &hash).await;
                    continue;
                }
            };
            if let Some(why) = gone(&kept, sessions) {
                tracing::info!(agent = kept.reg.agent, "dropped a registration: {why}");
                delete(db, &hash).await;
                continue;
            }
            if let ListenerId::Session(sid) = &kept.reg.listener
                && let Err(e) = self.session_socket(sessions, sid)
            {
                tracing::warn!(sid, "dropped a registration: {}", e.message);
                delete(db, &hash).await;
                continue;
            }
            write(&self.regs.0).insert(hash, kept);
        }
        let missing = self.missing_keys();
        if !missing.is_empty() {
            tracing::info!(
                providers = ?missing,
                "kept registrations need keys the hub does not hold: an editor hands them over"
            );
        }
        *lock(&self.pending) = missing;
    }

    /// The providers the registrations' chains need whose key is not held.
    fn missing_keys(&self) -> BTreeSet<String> {
        let providers = read(&self.providers);
        let keys = read(&self.keys);
        read(&self.regs.0)
            .values()
            .flat_map(|k| k.reg.chain.iter())
            .filter(|s| {
                providers.get(&s.provider).is_some_and(Provider::needs_key)
                    && keys.get(&s.provider).is_none()
            })
            .map(|s| s.provider.clone())
            .collect()
    }

    /// `gateway/need-keys`' data for a new subscriber, while kept registrations need keys.
    pub fn pending_need_keys(&self) -> Option<Value> {
        let pending = lock(&self.pending);
        (!pending.is_empty()).then(|| json!({"providers": pending.iter().collect::<Vec<_>>()}))
    }

    /// Prune the registrations whose owner is gone or whose session closed (each tick).
    pub async fn prune(&self, sessions: &Sessions) {
        let Ok(db) = self.db() else { return };
        let gone: Vec<(String, String)> = read(&self.regs.0)
            .iter()
            .filter_map(|(h, k)| gone(k, sessions).map(|why| (h.clone(), why)))
            .collect();
        if gone.is_empty() {
            return;
        }
        let _one = self.serial.lock().await;
        for (hash, why) in gone {
            let removed = write(&self.regs.0).remove(&hash);
            delete(db, &hash).await;
            if let Some(k) = removed {
                tracing::info!(agent = k.reg.agent, "pruned a registration: {why}");
            }
        }
    }

    /// `gateway/register` from a connection whose peer is PEER_PID.
    pub async fn register(
        &self,
        p: RegisterParams,
        peer_pid: Option<i32>,
        sessions: &Sessions,
    ) -> Result<Registered, Error> {
        let RegisterParams {
            chain,
            job,
            task,
            agent,
            budget,
            openrouter,
            keys,
            owner,
            sid,
        } = p;
        // the keys first: memory only
        if let Some(k) = keys {
            self.take_keys(k);
        }
        let (restrictions, kept_or) = match &openrouter {
            Some(o) => restrictions(o)?,
            None => (None, None),
        };
        let steps = chain
            .into_inner()
            .into_iter()
            .enumerate()
            .map(|(i, s)| step(i, s.into_inner()))
            .collect::<Result<Vec<_>, _>>()?;
        self.judge(&steps)?;
        let job = job.map(|j| j.as_str().to_owned());
        let budget = match (budget, &job) {
            (Some(b), _) => Some(b.get()),
            (None, Some(j)) => self.job_budget(j).await,
            (None, None) => None,
        };
        let owner = owner_of(owner, peer_pid)?;
        let token = token().map_err(|e| internal(format!("no token: {e}")))?;
        let hash = token_hash(token.as_bytes());
        let db = self.db()?;
        let port = self.engine()?.1;
        let _one = self.serial.lock().await;
        let (listener, url, socket) = match sid {
            Some(sid) => {
                let sid = sid.as_str().to_owned();
                let path = self.session_socket(sessions, &sid)?;
                (ListenerId::Session(sid), None, Some(path))
            }
            None => (
                ListenerId::Loopback,
                Some(format!("http://127.0.0.1:{port}")),
                None,
            ),
        };
        let kept = Kept {
            reg: Registration {
                class: Class::Agent,
                job,
                task: task.map(|t| t.as_str().to_owned()),
                agent: agent.map(|a| a.as_str().to_owned()),
                chain: steps,
                budget,
                openrouter: restrictions,
                listener,
            },
            owner,
        };
        // the row before the answer (and before the token admits anything)
        insert(db, &hash, &kept, openrouter.as_ref())
            .await
            .map_err(|e| internal(format!("cannot record the registration in runtime.db: {e}")))?;
        write(&self.regs.0).insert(hash, kept);
        Ok(Registered {
            token,
            url,
            socket: socket.map(|p| p.to_string_lossy().into_owned()),
            openrouter: kept_or,
        })
    }

    /// Session SID's `gateway.sock`, served by the engine until the session closes.
    fn session_socket(&self, sessions: &Sessions, sid: &str) -> Result<PathBuf, Error> {
        let gw = self.engine()?.0.clone();
        let id = ListenerId::Session(sid.to_owned());
        sessions.gateway_socket(sid, move |l: UnixListener, cancel: CancellationToken| {
            tokio::spawn(async move {
                tokio::select! {
                    () = cancel.cancelled() => {}
                    () = bifrost::listen::serve_unix(gw, l, id) => {}
                }
            });
        })
    }

    /// The registration's chain, judged: at least one step usable now, else every step's reason.
    fn judge(&self, steps: &[Step]) -> Result<(), Error> {
        if steps.is_empty() {
            return Err(invalid("chain", "a chain has at least one step"));
        }
        let providers = read(&self.providers);
        let keys = read(&self.keys);
        let mut reasons = Vec::new();
        for s in steps {
            let why = match providers.get(&s.provider) {
                None => "not configured",
                Some(p) if !p.messages => "the gateway cannot carry it",
                Some(p) if p.needs_key() && keys.get(&s.provider).is_none() => "no key",
                Some(_) => return Ok(()),
            };
            reasons.push((s.provider.as_str(), why));
        }
        let text = if reasons.iter().all(|(_, why)| *why == "no key") {
            let names: Vec<&str> = reasons.iter().map(|(p, _)| *p).collect();
            format!(
                "No key for {} in the drgnx hub: an editor hands its keys over when it connects",
                names.join(", ")
            )
        } else {
            let each: Vec<String> = reasons.iter().map(|(p, w)| format!("{p}: {w}")).collect();
            format!("no step of the chain can be used: {}", each.join("; "))
        };
        Err(invalid("chain", text))
    }

    /// Job JOB's `data.budget` in work.db, when it has one.
    async fn job_budget(&self, job: &str) -> Option<f64> {
        let j = job.to_owned();
        match self.coord.read(move |c| norn::read::jobs::job(c, &j)).await {
            Ok(Some(job)) => job
                .data
                .as_ref()
                .and_then(|d| d.get("budget"))
                .and_then(Value::as_f64),
            Ok(None) | Err(CoordError::NotReady { .. }) => None,
            Err(e) => {
                tracing::warn!(job, "the job's budget does not read: {e}");
                None
            }
        }
    }

    /// `gateway/unregister`: the token no longer forwards (true, as there is nothing to say otherwise).
    pub async fn unregister(&self, token: &str) -> Result<bool, Error> {
        let db = self.db()?;
        let hash = token_hash(token.as_bytes());
        let _one = self.serial.lock().await;
        write(&self.regs.0).remove(&hash);
        delete(db, &hash).await;
        Ok(true)
    }

    /// `gateway/keys` (and a registration's `keys`): to memory, nowhere else.
    pub fn take_keys(&self, keys: ProviderKeys) {
        let pairs: Vec<_> = keys.into_pairs().collect();
        let ids: Vec<String> = pairs.iter().map(|(id, _)| id.clone()).collect();
        write(&self.keys).set_many(pairs);
        let mut held = lock(&self.held);
        let mut pending = lock(&self.pending);
        for id in ids {
            pending.remove(&id);
            held.insert(id);
        }
    }

    /// `gateway/set-budget`: every registration of the job gets the budget, in memory and in `runtime.db`.
    pub async fn set_budget(&self, p: SetBudgetParams) -> Result<bool, Error> {
        let db = self.db()?;
        let (job, budget) = (p.job.as_str().to_owned(), p.budget.get());
        let _one = self.serial.lock().await;
        for k in write(&self.regs.0).values_mut() {
            if k.reg.job.as_deref() == Some(job.as_str()) {
                k.reg.budget = Some(budget);
            }
        }
        db.write(move |c| {
            Ok(c.execute(
                "update registration set budget = ?1 where job = ?2",
                (budget, job),
            )?)
        })
        .await
        .map_err(|e| internal(format!("cannot record the budget in runtime.db: {e}")))?;
        Ok(true)
    }

    /// `config/providers`: the table replaced, its copy kept, the clear-text warnings answered (and logged once per
    /// provider per start).
    pub async fn config_providers(&self, p: ProvidersParams) -> Result<ProvidersApplied, Error> {
        let table = p.providers.into_inner();
        let warnings = self.apply(&table)?;
        if let Ok(db) = self.db() {
            let text = serde_json::to_string(&table).expect("a provider table serializes");
            kv_set(db, KV_PROVIDERS, &text).await;
        }
        Ok(ProvidersApplied {
            applied: table.len() as u64,
            warnings,
        })
    }

    /// TABLE made the provider table: its warnings, or the first provider that does not convert (nothing changed).
    fn apply(&self, table: &[ProviderConfig]) -> Result<Vec<ProviderWarning>, Error> {
        let mut next = BTreeMap::new();
        let mut warnings = Vec::new();
        for (i, c) in table.iter().enumerate() {
            let p = provider(c).map_err(|e| invalid(&format!("providers[{i}].base"), e))?;
            let base = c.base.base();
            if p.needs_key() && base.clear_text {
                let id = c.id.as_str();
                warnings.push(ProviderWarning {
                    provider: id.to_owned(),
                    text: format!(
                        "{id}'s key travels in clear text over http://{}; use https",
                        base.url.host
                    ),
                });
            }
            next.insert(p.id.clone(), p);
        }
        *write(&self.providers) = next;
        {
            let mut warned = lock(&self.warned);
            for w in &warnings {
                if warned.insert(w.provider.clone()) {
                    tracing::warn!(provider = w.provider, "{}", w.text);
                }
            }
        }
        *lock(&self.warnings) = warnings.clone();
        Ok(warnings)
    }

    /// `spend` for CALLER (an agent: its own job's).
    pub async fn spend(
        &self,
        caller: &crate::dispatch::Caller,
        p: SpendParams,
    ) -> Result<Spend, Error> {
        let mut params = Params::Spend(p);
        shape::params(caller, &mut params)?;
        let Params::Spend(p) = params else {
            return Err(internal("spend's params changed kind"));
        };
        let job = p.job.map(|j| j.as_str().to_owned());
        let task = p.task.map(|t| t.as_str().to_owned());
        let agent = p.agent.map(|a| a.as_str().to_owned());
        let sum = self
            .coord
            .read(move |c| {
                norn::read::spend::spend_sum(c, job.as_deref(), task.as_deref(), agent.as_deref())
            })
            .await;
        match sum {
            Ok(s) => Ok(Spend {
                input: s.input,
                output: s.output,
                cost: s.cost,
                requests: s.requests,
            }),
            Err(CoordError::NotReady { .. }) => Ok(Spend {
                input: 0,
                output: 0,
                cost: 0.0,
                requests: 0,
            }),
            Err(e) => Err(internal(e.to_string())),
        }
    }

    /// `status`'s `gateway`.
    pub fn status(&self) -> GatewayStatus {
        let (port, (bytes_in, bytes_out)) = match self.engine.get() {
            Some((gw, port)) => (Some(u64::from(*port)), gw.traffic()),
            None => (None, (0, 0)),
        };
        GatewayStatus {
            port,
            registrations: read(&self.regs.0).len() as u64,
            requests: self.requests.load(Ordering::Relaxed),
            errors: self.errors.load(Ordering::Relaxed),
            fallbacks: self.fallbacks.load(Ordering::Relaxed),
            bytes_in,
            bytes_out,
            providers: read(&self.providers).len() as u64,
            keys_held: lock(&self.held).iter().cloned().collect(),
            warnings: lock(&self.warnings).clone(),
        }
    }

    /// A registration as `runtime.db` has it, made a kept one.
    fn kept_of(&self, row: &Row) -> Result<Kept, String> {
        let listener = match row.listener.as_str() {
            "loopback" => ListenerId::Loopback,
            l => match l.strip_prefix("session:") {
                Some(sid) => ListenerId::Session(sid.to_owned()),
                None => return Err(format!("listener {l:?}")),
            },
        };
        let chain: Vec<(String, Option<String>)> =
            serde_json::from_str(&row.chain).map_err(|e| format!("chain: {e}"))?;
        let openrouter = match &row.openrouter {
            Some(text) => {
                let o: OpenrouterRestrictions =
                    serde_json::from_str(text).map_err(|e| format!("openrouter: {e}"))?;
                restrictions(&o).map_err(|e| e.message)?.0
            }
            None => None,
        };
        let class = match row.class.as_str() {
            "editor" => Class::Editor,
            _ => Class::Agent,
        };
        let owner = match (row.owner, row.owner_start) {
            (Some(o), Some(s)) => {
                Some((u32::try_from(o).unwrap_or(0), u64::try_from(s).unwrap_or(0)))
            }
            _ => None,
        };
        Ok(Kept {
            reg: Registration {
                class,
                job: row.job.clone(),
                task: row.task.clone(),
                agent: row.agent.clone(),
                chain: chain
                    .into_iter()
                    .map(|(provider, model)| Step { provider, model })
                    .collect(),
                budget: row.budget,
                openrouter,
                listener,
            },
            owner,
        })
    }

    /// One request the engine answered: counted.
    fn count(&self, status: u16) {
        self.requests.fetch_add(1, Ordering::Relaxed);
        if status == 0 || status >= 400 {
            self.errors.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Why kept registration K goes: its owner is gone (a dead pid, or another start time), or its session closed.
fn gone(k: &Kept, sessions: &Sessions) -> Option<String> {
    if let Some((pid, start)) = k.owner {
        let now = i32::try_from(pid).ok().and_then(sessions::owner_start);
        if now != Some(start) {
            return Some(format!("its owner (pid {pid}) is gone"));
        }
    }
    match &k.reg.listener {
        ListenerId::Session(sid) if !sessions.is_live(sid) => {
            Some(format!("its session {sid} is closed"))
        }
        _ => None,
    }
}

/// The owner: the params' pid (which must run), else the caller's; with its start time.  None when neither reads.
fn owner_of(owner: Option<u64>, peer_pid: Option<i32>) -> Result<Option<(u32, u64)>, Error> {
    match owner {
        Some(o) => {
            let pid = i32::try_from(o)
                .ok()
                .filter(|p| *p > 0)
                .ok_or_else(|| invalid("owner", "not a process id"))?;
            let start = sessions::owner_start(pid)
                .ok_or_else(|| invalid("owner", format!("process {pid} is not running")))?;
            Ok(Some((pid as u32, start)))
        }
        None => Ok(peer_pid
            .filter(|p| *p > 0)
            .and_then(|p| sessions::owner_start(p).map(|s| (p as u32, s)))),
    }
}

/// A new token: 64 hex from 32 random bytes (the Lisp's `drgnx-gateway--random-token`).
fn token() -> std::io::Result<String> {
    Ok(format!(
        "{}{}",
        runstav::proof::nonce()?,
        runstav::proof::nonce()?
    ))
}

/// Step I of a chain, `[provider, model-or-null]`.
fn step(i: usize, s: Vec<Option<runstav::types::Bounded<String, 128>>>) -> Result<Step, Error> {
    let mut parts = s.into_iter();
    let provider = parts
        .next()
        .flatten()
        .map(|p| p.into_inner())
        .filter(|p| !p.is_empty())
        .ok_or_else(|| invalid(&format!("chain[{i}][0]"), "a step names its provider"))?;
    let model = parts.next().flatten().map(|m| m.into_inner());
    Ok(Step { provider, model })
}

/// The restrictions as the engine applies them (none when nothing is restricted), and those kept as the answer says
/// them (the keys that were given; none when none was).
fn restrictions(
    o: &OpenrouterRestrictions,
) -> Result<(Option<Restrictions>, Option<Value>), Error> {
    let list =
        |l: &Option<runstav::types::Bounded<Vec<runstav::types::Bounded<String, 128>>, 64>>| {
            l.as_ref()
                .map(|v| v.0.iter().map(|s| s.0.clone()).collect::<Vec<_>>())
                .unwrap_or_default()
        };
    let (only, ignore) = (list(&o.only), list(&o.ignore));
    let deny = o.data_collection == Some(DataCollection::Deny);
    let zdr = o.zdr == Some(true);
    let r = Restrictions::new(only.clone(), ignore.clone(), deny, zdr)
        .map_err(|e| invalid("openrouter", e))?;
    let mut kept = serde_json::Map::new();
    if !only.is_empty() {
        kept.insert("only".into(), json!(only));
    }
    if !ignore.is_empty() {
        kept.insert("ignore".into(), json!(ignore));
    }
    if let Some(dc) = o.data_collection {
        kept.insert("data-collection".into(), json!(dc));
    }
    if zdr {
        kept.insert("zdr".into(), json!(true));
    }
    let kept = (!kept.is_empty()).then_some(Value::Object(kept));
    Ok(((!r.is_empty()).then_some(r), kept))
}

/// C as the engine's provider (the URL was checked when it was decoded; it must also be an `http::Uri`).
fn provider(c: &ProviderConfig) -> Result<Provider, String> {
    let base: bifrost::Uri = c
        .base
        .as_str()
        .parse()
        .map_err(|e| format!("not a provider's URL: {e}"))?;
    let caps = c.caps.0.iter().fold(Caps::default(), |mut caps, cap| {
        match cap {
            ProviderCap::Chat => caps.chat = true,
            ProviderCap::Fim => caps.fim = true,
            ProviderCap::Embed => caps.embed = true,
        }
        caps
    });
    Ok(Provider {
        id: c.id.as_str().to_owned(),
        kind: match c.kind {
            ProviderKind::Openai => Kind::Openai,
            ProviderKind::Ollama => Kind::Ollama,
            ProviderKind::Llamacpp => Kind::Llamacpp,
            ProviderKind::Tei => Kind::Tei,
            ProviderKind::Anthropic => Kind::Anthropic,
        },
        base,
        auth: match c.auth {
            ProviderAuth::Bearer => Auth::Bearer,
            ProviderAuth::XApiKey => Auth::XApiKey,
            ProviderAuth::None => Auth::None,
        },
        messages: c.messages,
        caps,
        price: c.price.map(|p| Price {
            input_per_m: p.input.get(),
            output_per_m: p.output.get(),
        }),
    })
}

/// A registration as `runtime.db` keeps it.
struct Row {
    class: String,
    listener: String,
    job: Option<String>,
    task: Option<String>,
    agent: Option<String>,
    chain: String,
    budget: Option<f64>,
    openrouter: Option<String>,
    owner: Option<i64>,
    owner_start: Option<i64>,
}

async fn insert(
    db: &urdr::Handle,
    hash: &str,
    k: &Kept,
    openrouter: Option<&OpenrouterRestrictions>,
) -> urdr::Result<()> {
    let r = &k.reg;
    let listener = match &r.listener {
        ListenerId::Loopback => "loopback".to_owned(),
        ListenerId::Session(sid) => format!("session:{sid}"),
    };
    let class = match r.class {
        Class::Agent => "agent",
        Class::Editor => "editor",
    };
    let chain: Vec<(&str, Option<&str>)> = r
        .chain
        .iter()
        .map(|s| (s.provider.as_str(), s.model.as_deref()))
        .collect();
    let chain = serde_json::to_string(&chain).expect("a chain serializes");
    let openrouter = openrouter.map(|o| serde_json::to_string(o).expect("restrictions serialize"));
    let (owner, owner_start) = match k.owner {
        Some((pid, start)) => (
            Some(i64::from(pid)),
            Some(i64::try_from(start).unwrap_or(i64::MAX)),
        ),
        None => (None, None),
    };
    let (hash, job, task, agent, budget) = (
        hash.to_owned(),
        r.job.clone(),
        r.task.clone(),
        r.agent.clone(),
        r.budget,
    );
    db.write(move |c| {
        c.execute(
            "insert or replace into registration(hash, class, listener, job, task, agent, chain, budget, \
             openrouter, owner, owner_start, at) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            (
                hash,
                class,
                listener,
                job,
                task,
                agent,
                chain,
                budget,
                openrouter,
                owner,
                owner_start,
                now(),
            ),
        )?;
        Ok(())
    })
    .await
}

async fn delete(db: &urdr::Handle, hash: &str) {
    let h = hash.to_owned();
    if let Err(e) = db
        .write(move |c| Ok(c.execute("delete from registration where hash = ?1", [h])?))
        .await
    {
        tracing::warn!("cannot remove a registration from runtime.db: {e}");
    }
}

async fn rows(db: &urdr::Handle) -> urdr::Result<Vec<(String, Row)>> {
    db.read(|c| {
        let mut st = c.prepare(
            "select hash, class, listener, job, task, agent, chain, budget, openrouter, owner, owner_start \
             from registration order by at",
        )?;
        let rows = st
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    Row {
                        class: r.get(1)?,
                        listener: r.get(2)?,
                        job: r.get(3)?,
                        task: r.get(4)?,
                        agent: r.get(5)?,
                        chain: r.get(6)?,
                        budget: r.get(7)?,
                        openrouter: r.get(8)?,
                        owner: r.get(9)?,
                        owner_start: r.get(10)?,
                    },
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
}

async fn kv_get(db: &urdr::Handle, key: &'static str) -> Option<String> {
    let got = db
        .read(move |c| {
            match c.query_row("select value from kv where key = ?1", [key], |r| r.get(0)) {
                Ok(v) => Ok(Some(v)),
                Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
                Err(e) => Err(e.into()),
            }
        })
        .await;
    match got {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(key, "runtime.db's kv does not read: {e}");
            None
        }
    }
}

async fn kv_set(db: &urdr::Handle, key: &'static str, value: &str) {
    let v = value.to_owned();
    if let Err(e) = db
        .write(move |c| {
            Ok(c.execute(
                "insert or replace into kv(key, value) values (?1, ?2)",
                (key, v),
            )?)
        })
        .await
    {
        tracing::warn!(key, "cannot write runtime.db's kv: {e}");
    }
}

/// The engine's events to FRONT's subscribers, until the gateway is gone; a `budget` also to the backend.
pub async fn run_events(mut events: mpsc::UnboundedReceiver<GatewayEvent>, front: Arc<Front>) {
    while let Some(e) = events.recv().await {
        match e {
            GatewayEvent::Request(row) => {
                front.gate.count(row.status);
                front.broadcast(
                    "request",
                    json!({
                        "job": row.job, "task": row.task, "agent": row.agent, "provider": row.provider,
                        "model": row.model, "input": row.input, "output": row.output, "cost": row.cost,
                        "status": row.status,
                    }),
                );
            }
            GatewayEvent::Fallback {
                agent,
                from,
                to,
                why,
            } => {
                front.gate.fallbacks.fetch_add(1, Ordering::Relaxed);
                front.broadcast(
                    "fallback",
                    json!({"agent": agent, "from": from, "to": to, "why": why}),
                );
            }
            GatewayEvent::Budget { job, spent, budget } => {
                let data = json!({"job": job, "spent": spent, "budget": budget});
                front.broadcast("budget", data.clone());
                // to the backend's method dispatch, never awaited here (the seam: it never subscribes)
                let f = front.clone();
                tokio::spawn(async move { f.forward().notify_backend("budget", data).await });
            }
            GatewayEvent::NeedKeys { providers } => {
                front.broadcast("gateway/need-keys", json!({"providers": providers}));
            }
        }
    }
}

/// Prune the registrations of gone owners and closed sessions each [`sessions::TICK`], for as long as the hub serves.
pub async fn watch(front: Arc<Front>) {
    let mut every = tokio::time::interval(sessions::TICK);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        every.tick().await;
        front.gate.prune(&front.mcp).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::{Caller, NoBackend};
    use crate::store::WorkDb;
    use runstav::proof::Cap;
    use runstav::registry::{self, Class as WireClass};
    use std::path::Path;

    struct Hub {
        dir: tempfile::TempDir,
        front: Front,
        coord: CoordDb,
        _store: urdr::Store,
    }

    /// A front with runtime.db and work.db (schema 7, made by the writer's opening rule), its gateway listening.
    async fn hub() -> Hub {
        let dir = tempfile::tempdir().unwrap();
        let coord = CoordDb::spawn(dir.path().join("work.db"));
        // the opening rule has run once a request is served: the file is there for the raw seeds below
        coord.read(|_| Ok(())).await.unwrap();
        let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
        let socket = dir.path().join("hub-x.sock");
        let front = Front::new(
            Cap::generate().unwrap(),
            socket.clone(),
            WorkDb::spawn(dir.path().join("work.db")).unwrap(),
            coord.clone(),
            Arc::new(NoBackend),
        );
        let env = runstav::paths::Env::new(&[("TMPDIR", dir.path().to_str().unwrap())], front.uid);
        front.mcp.open_store(env, socket, db.clone());
        front.gate.open_store(db);
        front.gate.listen(None).await.unwrap();
        Hub {
            dir,
            front,
            coord,
            _store: store,
        }
    }

    /// METHOD's params V, as the registry decodes them (its checks), typed.
    fn decoded<T: serde::de::DeserializeOwned>(method: &str, v: Value) -> T {
        assert!(
            (registry::find(method).unwrap().decode)(&v).is_ok(),
            "{method} {v}"
        );
        runstav::decode::typed::<T>(&v).unwrap().0
    }

    /// The table: `local` (keyless, Messages), `keyed` (bearer, Messages), `chat` (keyless, no Messages).
    async fn table(g: &Gate) {
        let p: ProvidersParams = decoded(
            "config/providers",
            json!({"providers": [
                {"id": "local", "kind": "anthropic", "base": "http://127.0.0.1:9", "auth": "none",
                 "messages": true, "caps": ["chat"]},
                {"id": "keyed", "kind": "anthropic", "base": "https://api.example.com", "auth": "x-api-key",
                 "messages": true, "caps": ["chat"]},
                {"id": "chat", "kind": "openai", "base": "http://127.0.0.1:8", "auth": "none",
                 "messages": false, "caps": ["chat"]}]}),
        );
        assert_eq!(g.config_providers(p).await.unwrap().applied, 3);
    }

    fn register_params(v: Value) -> RegisterParams {
        decoded("gateway/register", v)
    }

    /// The rows of `select COLUMNS from TABLE_AND_REST` in runtime.db, each as a JSON array (SQLite's `json_array`).
    fn rows_of(dir: &Path, sql: &str) -> Vec<Vec<Value>> {
        let (columns, rest) = sql
            .strip_prefix("select ")
            .and_then(|s| s.split_once(" from "))
            .expect("select COLUMNS from …");
        let columns = if columns == "*" {
            "hash, class, listener, job, task, agent, chain, budget, openrouter, owner, owner_start, at"
        } else {
            columns
        };
        let c = urdr::open_readonly(&dir.join("runtime.db")).unwrap();
        let mut st = c
            .prepare(&format!("select json_array({columns}) from {rest}"))
            .unwrap();
        st.query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .map(|row| serde_json::from_str(&row.unwrap()).unwrap())
            .collect()
    }

    #[tokio::test]
    async fn the_row_is_written_before_the_answer() {
        let h = hub().await;
        let g = &h.front.gate;
        table(g).await;
        let me = std::process::id();
        let r = g
            .register(
                register_params(
                    json!({"chain": [["local", "m"]], "job": "j1", "agent": "agent-1",
                                       "budget": 2, "owner": me}),
                ),
                None,
                &h.front.mcp,
            )
            .await
            .unwrap();
        assert_eq!(r.token.len(), 64);
        assert_eq!(
            r.url.as_deref(),
            Some(format!("http://127.0.0.1:{}", g.status().port.unwrap()).as_str())
        );
        // the moment the answer is there, the row is: its hash, never the token
        let rows = rows_of(
            h.dir.path(),
            "select hash, class, listener, job, agent, chain, budget, owner from registration",
        );
        assert_eq!(
            rows,
            vec![vec![
                json!(token_hash(r.token.as_bytes())),
                json!("agent"),
                json!("loopback"),
                json!("j1"),
                json!("agent-1"),
                json!(r#"[["local","m"]]"#),
                json!(2.0),
                json!(me),
            ]]
        );
        let all = rows_of(h.dir.path(), "select * from registration");
        assert!(
            !format!("{all:?}").contains(&r.token),
            "the token is kept nowhere"
        );
        assert_eq!(g.status().registrations, 1);
        // unregistered: gone from both
        assert!(g.unregister(&r.token).await.unwrap());
        assert!(rows_of(h.dir.path(), "select hash from registration").is_empty());
        assert_eq!(g.status().registrations, 0);
    }

    #[tokio::test]
    async fn budget_from_the_job_when_absent() {
        let h = hub().await;
        let g = &h.front.gate;
        table(g).await;
        urdr::Connection::open(h.dir.path().join("work.db"))
            .unwrap()
            .execute_batch(
                r#"insert into job(id, title, status, created, data) values ('j1', 't', 'running', 1, '{"budget": 2.5}');
                   insert into job(id, title, status, created) values ('j2', 't', 'running', 1);"#,
            )
            .unwrap();
        let reg = |job: &str| register_params(json!({"chain": [["local", null]], "job": job}));
        let budgets =
            |dir: &Path| rows_of(dir, "select job, budget from registration order by job");
        g.register(reg("j1"), None, &h.front.mcp).await.unwrap();
        g.register(reg("j2"), None, &h.front.mcp).await.unwrap();
        // the params' budget wins over the job's
        g.register(
            register_params(json!({"chain": [["local", null]], "job": "j1", "budget": 0.5})),
            None,
            &h.front.mcp,
        )
        .await
        .unwrap();
        let mut got = budgets(h.dir.path());
        got.sort_by(|a, b| format!("{a:?}").cmp(&format!("{b:?}")));
        assert_eq!(
            got,
            vec![
                vec![json!("j1"), json!(0.5)],
                vec![json!("j1"), json!(2.5)],
                vec![json!("j2"), Value::Null],
            ]
        );
    }

    #[tokio::test]
    async fn set_budget_updates_every_registration_of_the_job() {
        let h = hub().await;
        let g = &h.front.gate;
        table(g).await;
        for job in ["j1", "j1", "j2"] {
            g.register(
                register_params(json!({"chain": [["local", null]], "job": job, "budget": 1})),
                None,
                &h.front.mcp,
            )
            .await
            .unwrap();
        }
        let p: SetBudgetParams = decoded("gateway/set-budget", json!({"job": "j1", "budget": 7}));
        assert!(g.set_budget(p).await.unwrap());
        let mut got = rows_of(h.dir.path(), "select job, budget from registration");
        got.sort_by(|a, b| format!("{a:?}").cmp(&format!("{b:?}")));
        assert_eq!(
            got,
            vec![
                vec![json!("j1"), json!(7.0)],
                vec![json!("j1"), json!(7.0)],
                vec![json!("j2"), json!(1.0)],
            ]
        );
        // in memory too: what the engine admits by
        let memory: Vec<Option<f64>> = read(&g.regs.0)
            .values()
            .filter(|k| k.reg.job.as_deref() == Some("j1"))
            .map(|k| k.reg.budget)
            .collect();
        assert_eq!(memory, vec![Some(7.0), Some(7.0)]);
    }

    #[tokio::test]
    async fn a_reused_owner_pid_prunes() {
        let h = hub().await;
        let g = &h.front.gate;
        table(g).await;
        let me = std::process::id();
        g.register(
            register_params(json!({"chain": [["local", null]], "owner": me})),
            None,
            &h.front.mcp,
        )
        .await
        .unwrap();
        g.prune(&h.front.mcp).await;
        assert_eq!(g.status().registrations, 1, "its owner lives");
        // the pid is the same, its start time another: another process
        for k in write(&g.regs.0).values_mut() {
            let (pid, start) = k.owner.unwrap();
            k.owner = Some((pid, start + 1));
        }
        g.prune(&h.front.mcp).await;
        assert_eq!(g.status().registrations, 0);
        assert!(rows_of(h.dir.path(), "select hash from registration").is_empty());
        // and at start: a row whose owner is another process is dropped, one of a live owner kept
        let mine = sessions::owner_start(me as i32).unwrap();
        let db = g.db().unwrap().clone();
        db.write(move |c| {
            c.execute_batch(&format!(
                "insert into registration(hash, listener, chain, owner, owner_start, at) values \
                 ('a', 'loopback', '[[\"local\",null]]', {me}, {mine}, 1), \
                 ('b', 'loopback', '[[\"local\",null]]', {me}, {}, 1), \
                 ('c', 'loopback', '[[\"local\",null]]', null, null, 1)",
                mine + 1
            ))?;
            Ok(())
        })
        .await
        .unwrap();
        g.restore(&h.front.mcp).await;
        assert_eq!(
            rows_of(h.dir.path(), "select hash from registration order by hash"),
            vec![vec![json!("a")], vec![json!("c")]],
            "an owner-less one stays until unregistered"
        );
        assert_eq!(g.status().registrations, 2);
    }

    #[tokio::test]
    async fn no_usable_step_is_refused_with_each_reason() {
        let h = hub().await;
        let g = &h.front.gate;
        table(g).await;
        let e = g
            .register(
                register_params(
                    json!({"chain": [["nowhere", null], ["chat", "m"], ["keyed", null]]}),
                ),
                None,
                &h.front.mcp,
            )
            .await
            .unwrap_err();
        assert_eq!(
            (e.code, e.path.as_deref(), e.message.as_str()),
            (
                ErrorCode::InvalidParams,
                Some("chain"),
                "no step of the chain can be used: nowhere: not configured; chat: the gateway cannot carry it; \
                 keyed: no key"
            )
        );
        assert!(rows_of(h.dir.path(), "select hash from registration").is_empty());
        assert_eq!(g.status().registrations, 0);
        // one usable step is enough
        g.register(
            register_params(json!({"chain": [["nowhere", null], ["local", null]]})),
            None,
            &h.front.mcp,
        )
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn missing_keys_only_says_how_without_the_false_advice() {
        let h = hub().await;
        let g = &h.front.gate;
        table(g).await;
        let e = g
            .register(
                register_params(json!({"chain": [["keyed", null]]})),
                None,
                &h.front.mcp,
            )
            .await
            .unwrap_err();
        assert_eq!(
            (e.path.as_deref(), e.message.as_str()),
            (
                Some("chain"),
                "No key for keyed in the drgnx hub: an editor hands its keys over when it connects"
            )
        );
        assert!(!e.message.contains("drgnx hub start"));
        // the registration's own keys go to memory first, and then it is usable
        let r = g
            .register(
                register_params(
                    json!({"chain": [["keyed", null]], "keys": {"keyed": "canary-key-1"}}),
                ),
                None,
                &h.front.mcp,
            )
            .await
            .unwrap();
        assert_eq!(g.status().keys_held, vec!["keyed".to_string()]);
        let all = rows_of(h.dir.path(), "select * from registration");
        assert!(
            !format!("{all:?}").contains("canary-key-1"),
            "no key in runtime.db"
        );
        assert!(!r.token.is_empty());
    }

    #[tokio::test]
    async fn a_clear_text_keyed_provider_is_applied_with_a_warning() {
        let h = hub().await;
        let g = &h.front.gate;
        let p: ProvidersParams = decoded(
            "config/providers",
            json!({"providers": [
                {"id": "lan", "kind": "openai", "base": "http://192.0.2.10:8080", "auth": "bearer",
                 "messages": false, "caps": ["chat"]},
                {"id": "lan-free", "kind": "ollama", "base": "http://192.0.2.11:11434", "auth": "none",
                 "messages": false, "caps": ["chat"]},
                {"id": "local", "kind": "ollama", "base": "http://127.0.0.1:11434", "auth": "bearer",
                 "messages": false, "caps": ["chat"]}]}),
        );
        let a = g.config_providers(p).await.unwrap();
        assert_eq!(
            (a.applied, a.warnings),
            (
                3,
                vec![ProviderWarning {
                    provider: "lan".into(),
                    text: "lan's key travels in clear text over http://192.0.2.10; use https"
                        .into()
                }]
            )
        );
        assert_eq!(g.status().warnings.len(), 1);
        // the table is kept without a key, and comes back at start
        let kv = rows_of(h.dir.path(), "select value from kv where key = 'providers'");
        assert!(kv[0][0].as_str().unwrap().contains("192.0.2.10"));
        *write(&g.providers) = BTreeMap::new();
        g.restore(&h.front.mcp).await;
        assert_eq!(g.status().providers, 3);
    }

    #[tokio::test]
    async fn an_agents_spend_is_its_own_jobs() {
        let h = hub().await;
        let g = &h.front.gate;
        // the rows the engine records, through the ledger
        let ledger = WorkLedger(h.coord.clone());
        for (job, agent, input, output, cost) in
            [("j1", "agent-1", 10, 2, 0.5), ("j2", "agent-2", 7, 1, 0.25)]
        {
            ledger
                .record(SpendRow {
                    job: Some(job.into()),
                    task: Some(format!("{job}#1")),
                    agent: Some(agent.into()),
                    provider: "p".into(),
                    model: Some("m".into()),
                    input,
                    output,
                    cost,
                    status: 200,
                })
                .await;
        }
        // each row carries the tx that wrote it: the hub's, as the gateway
        let by: Vec<(String, String, String, String)> = h
            .coord
            .read(|c| {
                let mut st = c.prepare(
                    "select s.job, t.actor, t.class, t.tool from spend s join tx t on t.id = s.tx \
                     order by s.job",
                )?;
                let rows = st
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(rows)
            })
            .await
            .unwrap();
        let hub_tx = |job: &str| {
            (
                job.to_string(),
                "hub".to_string(),
                "system".to_string(),
                "gateway".to_string(),
            )
        };
        assert_eq!(by, vec![hub_tx("j1"), hub_tx("j2")]);
        let caller = |class, job: Option<&str>| Caller {
            class,
            sid: None,
            job: job.map(str::to_owned),
            conn_id: 1,
            backend: false,
        };
        let p = |v: Value| -> SpendParams { decoded("spend", v) };
        let all = g
            .spend(&caller(WireClass::User, None), p(json!({})))
            .await
            .unwrap();
        assert_eq!((all.input, all.requests), (17, 2));
        let own = g
            .spend(&caller(WireClass::Agent, Some("j1")), p(json!({})))
            .await
            .unwrap();
        assert_eq!(
            (own.input, own.output, own.cost, own.requests),
            (10, 2, 0.5, 1)
        );
        let e = g
            .spend(
                &caller(WireClass::Agent, Some("j1")),
                p(json!({"job": "j2"})),
            )
            .await
            .unwrap_err();
        assert_eq!(e.code, ErrorCode::NotAllowed);
    }
}
