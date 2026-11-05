//! The hub's search methods and the projects they hold (`search/*`; docs/develop/runtime.md, "Hrafn").
//!
//! - **Projects.** [`Hub`] opens a project (its store, tier 1, tier 2) the first time a method names its root, keeps it
//!   while its embedders stay the same, and runs its driver: a task that gives tier 1 its tick (`Project::tick`) twice a
//!   second until the project is dropped. The watcher is the host's (`notify`); without one a query diffs the blobs.
//! - **Config.** A project's globs are `.drgnx/search.eld` (read here as data, at most 64 KiB; one that does not read
//!   turns the project's search off, never widens it) and the project's runtime settings `drgnx-search-*` (the editor
//!   sends them per project): only the settings' `include` replaces the file's, and the excludes add up.
//! - **A query** refreshes tier 1 when the files changed, picks the model (`search::prefer`: a server that answers and
//!   covers 95 % of the chunks, else the built-in model), embeds the question with it and asks `hrafn::search`. With no
//!   model the answer is keyword, symbol and path results at once, and says why.
//! - **The embedders** of a project are the built-in model's worker (when `drgnx-search-builtin` is on and the model is
//!   `Ready`) and the servers the gateway has. A change in that set opens the project again.

use super::project::{Project, ProjectError, ProjectSpec, Tier2, project_id};
use super::worker::WorkerEmbedder;
use super::{DocEmbedder, Search, download, power, prefer, servers};
use crate::clock;
use crate::dispatch::Caller;
use crate::embed::ProviderEmbedder;
use crate::front::Front;
use hrafn::{Config, Lag, Query, Scope};
use hrafn_embed::cache::{ModelState, model_dir, state};
use hrafn_embed::{default_model, download_bytes};
use runstav::methods::Params;
use runstav::methods::search as w;
use runstav::paths::{self, Env};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

/// How often a project's driver looks at its watcher.
pub const DRIVER_TICK: Duration = Duration::from_millis(500);

/// `.drgnx/search.eld` is read up to this size.
const CONFIG_MAX: u64 = 64 * 1024;

/// What the hub needs to open a project.
struct Dirs {
    env: Env,
    home: PathBuf,
    config: PathBuf,
    runtime: urdr::Handle,
}

#[derive(Default)]
struct Download {
    running: bool,
    have: u64,
    total: u64,
    failed: Option<String>,
}

struct Open {
    project: Arc<Project>,
    /// The models that fill it: a different set is another project.
    sig: String,
    _watch: Option<hrafn::NotifyWatch>,
}

type Projects = Arc<tokio::sync::Mutex<HashMap<String, Open>>>;

/// Hrafn's state in the hub: the built-in model's worker, the open projects, the model download.
#[derive(Default)]
pub struct Hub {
    front: OnceLock<Weak<Front>>,
    dirs: OnceLock<Dirs>,
    search: OnceLock<Search>,
    projects: Projects,
    download: Arc<Mutex<Download>>,
}

fn error(code: ErrorCode, message: impl Into<String>, path: Option<&str>) -> Error {
    Error {
        code,
        message: message.into(),
        path: path.map(str::to_owned),
    }
}

fn internal(message: impl ToString) -> Error {
    error(ErrorCode::Internal, message.to_string(), None)
}

fn project_error(e: ProjectError) -> Error {
    match e {
        ProjectError::Denied(why) => error(
            ErrorCode::NotAllowed,
            format!("the project root is refused: {why}"),
            Some("root"),
        ),
        other => internal(other),
    }
}

fn wire_lag(l: &Lag) -> w::Lag {
    w::Lag {
        model: l.model.clone(),
        chunks_total: l.chunks_total,
        chunks_behind: l.chunks_behind,
        files_behind: l.files_behind,
        dirty_files: l.dirty_files,
        built_from: l.built_from.clone(),
    }
}

/// An answer as the wire has it.
pub fn wire_answer(a: &hrafn::Answer) -> w::QueryAnswer {
    w::QueryAnswer {
        hits: a
            .hits
            .iter()
            .map(|h| w::Hit {
                path: h.path.clone(),
                line_start: h.line_start,
                line_end: h.line_end,
                symbol: h.symbol.clone(),
                score: h.score,
                preview: h.preview.clone(),
                routes: h.routes.iter().map(|r| (*r).to_string()).collect(),
                reanchored: h.reanchored,
            })
            .collect(),
        lag: wire_lag(&a.lag),
        model: a.model.clone(),
        notice: a.notice.clone(),
        lag_line: a.lag_line(),
    }
}

fn scope_of(s: Option<w::Scope>) -> Scope {
    match s {
        Some(w::Scope::Tests) => Scope::Tests,
        Some(w::Scope::Docs) => Scope::Docs,
        Some(w::Scope::All) => Scope::All,
        Some(w::Scope::Code) | None => Scope::Code,
    }
}

/// `.drgnx/search.eld` of ROOT as a [`Config`]: its plist `(:include GLOBS :exclude GLOBS :off BOOL)`, read as data.
/// No file is the default; a file that does not read is an `Err` (the project's search is then off, never wider).
pub fn config_file(root: &Path) -> Result<Config, String> {
    use huginn::value::{Datum, Node};
    let file = root.join(".drgnx").join("search.eld");
    let meta = match std::fs::symlink_metadata(&file) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Config::default()),
        Err(e) => return Err(e.to_string()),
    };
    if !meta.is_file() || meta.len() > CONFIG_MAX || meta.len() == 0 {
        return Err("it is not a regular file of 1 byte to 64 KiB".into());
    }
    let bytes = std::fs::read(&file).map_err(|e| e.to_string())?;
    let nodes = huginn::read::read_all(&bytes, huginn::read::Limits::default())
        .map_err(|r| format!("{r:?}"))?;
    let [one] = nodes.as_slice() else {
        return Err("it holds one plist".into());
    };
    let Datum::List(items) = &one.datum else {
        return Err("it is not a plist".into());
    };
    let mut cfg = Config::default();
    for pair in items.chunks(2) {
        let [k, v] = pair else {
            return Err("a key has no value".into());
        };
        let Datum::Sym(key) = &k.datum else {
            return Err("a key is not a keyword".into());
        };
        let globs = |v: &Node| -> Result<Vec<String>, String> {
            match &v.datum {
                Datum::Sym(s) if s == "nil" => Ok(Vec::new()),
                Datum::List(xs) => xs
                    .iter()
                    .map(|x| match &x.datum {
                        Datum::Str(s) => Ok(s.clone()),
                        _ => Err(format!("{key} holds what is not a string")),
                    })
                    .collect(),
                _ => Err(format!("{key} is not a list of strings")),
            }
        };
        match key.as_str() {
            ":include" => cfg.include = globs(v)?,
            ":exclude" => cfg.exclude = globs(v)?,
            ":off" => match &v.datum {
                Datum::Sym(s) if s == "t" => cfg.off = true,
                Datum::Sym(s) if s == "nil" => cfg.off = false,
                _ => return Err(":off is t or nil".into()),
            },
            other => return Err(format!("{other} is not a key of the file")),
        }
    }
    Ok(cfg)
}

impl Hub {
    /// The front, once it is in its `Arc` (the MCP tool reaches the hub through it).
    pub fn bind(&self, front: &Arc<Front>) {
        let _ = self.front.set(Arc::downgrade(front));
    }

    /// The front the hub was bound to, while it lives.
    pub fn front(&self) -> Option<Arc<Front>> {
        self.front.get()?.upgrade()
    }

    /// Where things are, once the server knows: ENV for the state and cache folders, HOME and CONFIG for the deny-list,
    /// RUNTIME for the model consent.
    pub fn configure(&self, env: &Env, home: PathBuf, config: PathBuf, runtime: urdr::Handle) {
        let _ = self.search.set(Search::new(env));
        let _ = self.dirs.set(Dirs {
            env: env.clone(),
            home,
            config,
            runtime,
        });
    }

    /// The built-in model's worker, once the model is `Ready` in the cache.
    pub fn builtin(&self) -> Option<Arc<WorkerEmbedder>> {
        self.search.get()?.builtin()
    }

    fn dirs(&self) -> Result<&Dirs, Error> {
        self.dirs
            .get()
            .ok_or_else(|| internal("search is not set up in this hub (no folders yet)"))
    }

    /// The servers that can embed, in the gateway's order, with the model each embeds with.
    fn servers(&self, front: &Front) -> Vec<ProviderEmbedder> {
        let current = front.settings.current();
        let chain = crate::settings::providers::role_chain(
            &current.loaded.values.ai_roles,
            &crate::settings::defaults().roles,
            "embed",
        );
        front.gate.embedders(&chain).unwrap_or_default()
    }

    fn builtin_on(front: &Front) -> bool {
        front.settings.current().loaded.values.search_builtin
    }

    /// The project's globs: the file, narrowed by what the editor sent for the project.
    async fn config_for(&self, front: &Front, root: &Path) -> Config {
        let mut cfg = match config_file(root) {
            Ok(c) => c,
            Err(why) => {
                tracing::warn!(
                    "search: {}/.drgnx/search.eld cannot be read ({why}): the project's search is off",
                    root.display()
                );
                return Config {
                    off: true,
                    ..Config::default()
                };
            }
        };
        // git runs (up to 3 s): not on a runtime worker
        let at = root.to_path_buf();
        let project = crate::clock::blocking(move || norn::project::resolve(&at))
            .await
            .ok()
            .flatten();
        let names: Vec<String> = project
            .iter()
            .flat_map(|p| [p.id.clone(), p.slug.clone()])
            .collect();
        let get = |name: &str| -> Option<Value> {
            names.iter().find_map(|p| {
                front
                    .settings
                    .effective(name, Some(p))
                    .filter(|(_, seen)| *seen)
                    .map(|(v, _)| v)
            })
        };
        let strings = |v: Option<Value>| -> Vec<String> {
            v.and_then(|v| serde_json::from_value(v).ok())
                .unwrap_or_default()
        };
        let include = strings(get("drgnx-search-include"));
        if !include.is_empty() {
            cfg.include = include;
        }
        for g in strings(get("drgnx-search-exclude")) {
            if !cfg.exclude.contains(&g) {
                cfg.exclude.push(g);
            }
        }
        if get("drgnx-search-off").and_then(|v| v.as_bool()) == Some(true) {
            cfg.off = true;
        }
        cfg
    }

    /// The project of ROOT, opened if it is not (and opened again when its embedders changed).
    pub async fn project(&self, front: &Front, root: &Path) -> Result<Arc<Project>, Error> {
        let dirs = self.dirs()?;
        let given = root.to_path_buf();
        let (real, id) = crate::clock::blocking(move || project_id(&given))
            .await
            .map_err(internal)?
            .map_err(|e| {
                error(
                    ErrorCode::InvalidParams,
                    format!("{}: {e}", root.display()),
                    Some("root"),
                )
            })?;
        let mut embedders: Vec<Arc<dyn DocEmbedder>> = self
            .servers(front)
            .into_iter()
            .map(|e| Arc::new(e) as Arc<dyn DocEmbedder>)
            .collect();
        if Self::builtin_on(front)
            && let Some(b) = self.builtin()
        {
            embedders.push(b);
        }
        let sig = embedders
            .iter()
            .map(|e| e.model().to_string())
            .collect::<Vec<_>>()
            .join(",");
        let mut open = self.projects.lock().await;
        if let Some(o) = open.get(&id)
            && o.sig == sig
        {
            return Ok(o.project.clone());
        }
        let config = self.config_for(front, &real).await;
        let project = Arc::new(
            Project::open(ProjectSpec {
                root: real.clone(),
                state: paths::state_dir(&dirs.env),
                home: dirs.home.clone(),
                config_dir: dirs.config.clone(),
                config,
                embedders,
                power_root: PathBuf::from(power::SYS),
                #[cfg(feature = "test-hooks")]
                test_permits: None,
            })
            .await
            .map_err(project_error)?,
        );
        let watch = hrafn::NotifyWatch::new(&real, &real.join(".git")).ok();
        if let Some(wt) = &watch {
            project.watch(wt);
        }
        project.start_tier2();
        let weak = Arc::downgrade(&project);
        clock::spawn("search:driver", async move {
            loop {
                let Some(p) = weak.upgrade() else { return };
                if let Err(e) = p.tick().await {
                    tracing::warn!("search: tier 1 of {}: {e}", p.root().display());
                }
                drop(p);
                clock::sleep(DRIVER_TICK).await;
            }
        });
        open.insert(
            id,
            Open {
                project: project.clone(),
                sig,
                _watch: watch,
            },
        );
        Ok(project)
    }

    fn builtin_reason(&self, front: &Front) -> String {
        if !Self::builtin_on(front) {
            return "the built-in model is off (drgnx-search-builtin)".into();
        }
        let Ok(dirs) = self.dirs() else {
            return "the built-in model is not set up".into();
        };
        let spec = default_model();
        let dir = model_dir(&super::models_root(&dirs.env), spec);
        match state(spec, &dir) {
            ModelState::Missing => "built-in model not downloaded".into(),
            ModelState::Partial { .. } => "built-in model download is partial".into(),
            ModelState::Corrupt { file } => {
                format!("built-in model is corrupt ({file}): download it again")
            }
            ModelState::Ready => "the built-in model did not answer".into(),
        }
    }

    /// The answer to a question about ROOT's code (the MCP tool's and `search/query`'s).
    pub async fn query(
        &self,
        front: &Front,
        root: &Path,
        text: &str,
        scope: Scope,
        k: u32,
    ) -> Result<hrafn::Answer, Error> {
        let p = self.project(front, root).await?;
        p.fresh_for_query().await.map_err(project_error)?;
        let builtin = if Self::builtin_on(front) {
            self.builtin()
        } else {
            None
        };
        let builtin_lag = match &builtin {
            Some(b) => Some(
                p.lag(Some(DocEmbedder::model(b.as_ref())))
                    .await
                    .map_err(project_error)?,
            ),
            None => None,
        };
        let covers = |l: &Lag| {
            u64::from(l.chunks_total.saturating_sub(l.chunks_behind)) * 100
                >= u64::from(l.chunks_total) * 95
        };
        let mut infos: Vec<(String, Lag, bool)> = Vec::new();
        let mut qvecs: HashMap<String, Vec<f32>> = HashMap::new();
        let mut down: Vec<String> = Vec::new();
        for s in self.servers(front) {
            let model = DocEmbedder::model(&s).to_string();
            let lag = p.lag(Some(&model)).await.map_err(project_error)?;
            // only a server that could win is asked: one that covers enough, or the only way to vectors
            let up = if covers(&lag) || builtin.is_none() {
                match s.embed_query(text, Some(scope.instruction())).await {
                    Ok(v) => {
                        qvecs.insert(model.clone(), v);
                        true
                    }
                    Err(e) => {
                        tracing::debug!("search: {model} did not answer the question: {}", e.0);
                        down.push(model.clone());
                        false
                    }
                }
            } else {
                false
            };
            infos.push((model, lag, up));
        }
        let chosen = prefer(builtin_lag.as_ref(), &infos);
        let mut notice = None;
        let qvec: Option<(String, Vec<f32>)> = match chosen {
            Some(m) if qvecs.contains_key(&m) => qvecs.remove(&m).map(|v| (m, v)),
            Some(m) => match &builtin {
                Some(b) => match b.embed_query(text, None).await {
                    Ok(v) => Some((m, v)),
                    Err(e) => {
                        notice = Some(format!("the built-in model did not answer: {}", e.0));
                        None
                    }
                },
                None => None,
            },
            None => {
                let mut why = self.builtin_reason(front);
                if !down.is_empty() {
                    why = format!("{why}; servers that did not answer: {}", down.join("; "));
                }
                notice = Some(why);
                None
            }
        };
        let q = Query {
            text: text.to_string(),
            scope,
            k: k.clamp(1, 100),
        };
        let pr = p.clone();
        let mut a = hrafn::search(
            p.store(),
            &q,
            qvec.as_ref().map(|(m, v)| (m.as_str(), v.as_slice())),
            &move |rel: &str| pr.read_now(rel),
        )
        .await
        .map_err(internal)?;
        if a.model.is_none() {
            a.notice = notice.or(a.notice);
        }
        Ok(a)
    }

    async fn status(&self, front: &Front, root: &Path) -> Result<w::StatusAnswer, Error> {
        let p = self.project(front, root).await?;
        let (per_class, models) = p
            .store()
            .handle()
            .read(|c| {
                let mut st = c.prepare(
                    "select f.class, count(*), coalesce(sum(n.n), 0) from file f
                     left join (select path, count(*) as n from chunk group by path) n on n.path = f.path
                     group by f.class order by f.class",
                )?;
                let classes = st
                    .query_map([], |r| {
                        Ok(w::ClassCount {
                            class: r.get(0)?,
                            files: r.get::<_, i64>(1)?.try_into().unwrap_or(0),
                            chunks: r.get::<_, i64>(2)?.try_into().unwrap_or(0),
                        })
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                let mut st =
                    c.prepare("select model, count(*) from vec group by model order by model")?;
                let models = st
                    .query_map([], |r| {
                        Ok(w::ModelCount {
                            model: r.get(0)?,
                            vectors: r.get::<_, i64>(1)?.try_into().unwrap_or(0),
                        })
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok((classes, models))
            })
            .await
            .map_err(internal)?;
        let builtin = self.builtin();
        let lag = p
            .lag(builtin.as_ref().map(|b| DocEmbedder::model(b.as_ref())))
            .await
            .map_err(project_error)?;
        let coverage_errors = p.coverage_errors().await.map_err(project_error)?;
        let st = p.status().borrow().clone();
        Ok(w::StatusAnswer {
            files: per_class.iter().map(|c| c.files).sum(),
            chunks: per_class.iter().map(|c| c.chunks).sum(),
            per_class,
            coverage_errors,
            lag: wire_lag(&lag),
            models,
            worker: worker_status(builtin.as_deref()),
            tier2: tier2_name(&st.tier2).to_string(),
            embedded: st.embedded,
        })
    }

    async fn embedders(&self, front: &Front) -> Result<w::EmbeddersAnswer, Error> {
        let dirs = self.dirs()?;
        let spec = default_model();
        let dir = model_dir(&super::models_root(&dirs.env), spec);
        let (mut st, mut held) = match state(spec, &dir) {
            ModelState::Missing => ("missing", 0),
            ModelState::Partial { have, .. } => ("partial", have),
            ModelState::Ready => ("ready", download_bytes(spec)),
            ModelState::Corrupt { .. } => ("corrupt", 0),
        };
        let mut failed = None;
        if let Ok(d) = self.download.lock() {
            if d.running {
                (st, held) = ("downloading", d.have.min(d.total));
            }
            failed = d.failed.clone();
        }
        let builtin = self.builtin();
        let mut servers = Vec::new();
        let mut preferred = None;
        for s in self.servers(front) {
            let url = front.gate.base_of(s.provider()).unwrap_or_default();
            let family = crate::embed::answered_family(&url).await;
            if family.is_some() && preferred.is_none() {
                preferred = Some(DocEmbedder::model(&s).to_string());
            }
            servers.push(w::ServerInfo {
                kind: s.kind().to_string(),
                url,
                model: DocEmbedder::model(&s).to_string(),
                answering: family.is_some(),
                family: family.map(str::to_string),
            });
        }
        if preferred.is_none() && Self::builtin_on(front) && builtin.is_some() {
            preferred = Some(spec.id.to_string());
        }
        let facts = worker_status(builtin.as_deref());
        Ok(w::EmbeddersAnswer {
            builtin: w::BuiltinInfo {
                model: spec.id.to_string(),
                state: st.to_string(),
                bytes: download_bytes(spec),
                downloaded: held,
                error: failed,
                device: facts.device,
            },
            servers,
            prefer: preferred,
        })
    }

    async fn model_download(
        &self,
        front: &Front,
        p: w::DownloadParams,
    ) -> Result<w::Started, Error> {
        let dirs = self.dirs()?;
        let spec = super::model(p.model.as_str()).ok_or_else(|| {
            error(
                ErrorCode::InvalidParams,
                format!("no model {}", p.model.as_str()),
                Some("model"),
            )
        })?;
        let consent = super::Consent {
            model: spec.id.to_string(),
            bytes: p.consent.bytes,
            at: clock::wall_secs(),
        };
        if p.consent.bytes != download_bytes(spec) {
            return Err(error(
                ErrorCode::InvalidParams,
                format!(
                    "the consent names {} bytes; the model is {} bytes",
                    p.consent.bytes,
                    download_bytes(spec)
                ),
                Some("consent.bytes"),
            ));
        }
        let base = super::model_base(
            front
                .settings
                .current()
                .loaded
                .values
                .search_model_mirror
                .as_deref(),
        )
        .map_err(|m| error(ErrorCode::InvalidParams, m, None))?;
        {
            let mut d = self
                .download
                .lock()
                .map_err(|_| internal("download state"))?;
            if d.running {
                return Ok(w::Started { started: false });
            }
            *d = Download {
                running: true,
                have: 0,
                total: download_bytes(spec),
                failed: None,
            };
        }
        super::store_consent(&dirs.runtime, &consent).await;
        let (progress_state, projects) = (self.download.clone(), self.projects.clone());
        let root = super::models_root(&dirs.env);
        clock::spawn("search:download", async move {
            let progress = {
                let state = progress_state.clone();
                move |have: u64, total: u64| {
                    if let Ok(mut d) = state.lock() {
                        (d.have, d.total) = (have, total);
                    }
                }
            };
            let result = download(spec, &root, &base, &consent, &progress).await;
            if let Ok(mut d) = progress_state.lock() {
                d.running = false;
                d.failed = result.as_ref().err().map(|e| format!("{e:?}"));
            }
            if result.is_ok() {
                projects.lock().await.clear();
            }
        });
        Ok(w::Started { started: true })
    }

    /// `search/server-plan`: what a start would run. The host is read, nothing runs.
    async fn server_plan(&self, kind: w::ServerKind) -> Result<w::ServerPlan, Error> {
        let env = self.dirs()?.env.clone();
        let host = crate::clock::blocking(move || servers::Host::probe(&env))
            .await
            .map_err(internal)?;
        Ok(servers::plan(&host, kind))
    }

    /// `search/server-start`: the only door to [`servers::start`].
    async fn server_start(&self, p: w::ServerStartParams) -> Result<w::ServerStarted, Error> {
        self.server_job(move |host, run| servers::start(host, run, p.kind, p.confirm))
            .await
    }

    /// `search/server-stop`: the only door to [`servers::stop`].
    async fn server_stop(&self, kind: w::ServerKind) -> Result<w::ServerStopped, Error> {
        let stopped = self
            .server_job(move |host, run| servers::stop(host, run, kind))
            .await?;
        Ok(w::ServerStopped { stopped })
    }

    /// F on a probed host and the runner (the real tools; with test-hooks one that records and runs nothing), off the
    /// async threads.
    async fn server_job<T: Send + 'static>(
        &self,
        f: impl FnOnce(&servers::Host, &dyn servers::Run) -> Result<T, servers::Refused>
        + Send
        + 'static,
    ) -> Result<T, Error> {
        let env = self.dirs()?.env.clone();
        crate::clock::blocking(move || {
            let host = servers::Host::probe(&env);
            #[cfg(feature = "test-hooks")]
            let run = servers::Record(
                PathBuf::from(env.vars.get("XDG_STATE_HOME").cloned().unwrap_or_default())
                    .join("drgnx/servers-test.log"),
            );
            #[cfg(not(feature = "test-hooks"))]
            let run = servers::System;
            f(&host, &run)
        })
        .await
        .map_err(internal)?
        .map_err(|r| match r {
            servers::Refused::Confirm => error(
                ErrorCode::InvalidParams,
                "starting a server needs the user's confirmation (confirm: true)",
                Some("confirm"),
            ),
            servers::Refused::Unavailable(why) => error(ErrorCode::NotAllowed, why, Some("kind")),
            servers::Refused::Failed(why) => internal(why),
        })
    }

    async fn typing(&self) {
        for o in self.projects.lock().await.values() {
            o.project.note_typing();
        }
    }

    async fn index(&self, front: &Front, i: w::IndexParams) -> Result<w::Started, Error> {
        let p = self.project(front, Path::new(i.root.as_str())).await?;
        if i.now == Some(true) {
            p.index_now();
        }
        if i.rebuild == Some(true) {
            p.rebuild().await.map_err(project_error)?;
        } else {
            p.refresh_now().await.map_err(project_error)?;
        }
        p.start_tier2();
        Ok(w::Started { started: true })
    }
}

fn tier2_name(t: &Tier2) -> &'static str {
    match t {
        Tier2::Stopped => "stopped",
        Tier2::Idle => "idle",
        Tier2::Running => "running",
        Tier2::Typing => "typing",
        Tier2::Battery => "battery",
        Tier2::Failed(_) => "failed",
    }
}

fn worker_status(b: Option<&WorkerEmbedder>) -> w::WorkerStatus {
    let Some(b) = b else {
        return w::WorkerStatus::default();
    };
    let f = b.facts();
    let text = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    w::WorkerStatus {
        device: f.ready.as_ref().map(|r| w::Device {
            kind: text(r, "device").unwrap_or_default(),
            name: text(r, "name").unwrap_or_default(),
            why: text(r, "why").unwrap_or_default(),
        }),
        fallback: f.fallback.as_ref().and_then(|v| text(v, "reason")),
        spawns: f.spawns,
        crashes: f.crashes,
    }
}

/// P served by the search methods, or handed back (not one of theirs).
pub async fn serve(
    front: &Front,
    _caller: &Caller,
    p: Params,
) -> Result<Result<Value, Error>, Box<Params>> {
    let hub = &front.search;
    Ok(match p {
        Params::SearchQuery(q) => {
            let scope = scope_of(q.scope);
            let k = q.k.unwrap_or(10);
            hub.query(front, Path::new(q.root.as_str()), q.text.as_str(), scope, k)
                .await
                .map(|a| json!(wire_answer(&a)))
        }
        Params::SearchStatus(r) => hub
            .status(front, Path::new(r.root.as_str()))
            .await
            .map(|s| json!(s)),
        Params::SearchIndex(i) => hub.index(front, i).await.map(|s| json!(s)),
        Params::SearchEmbedders(_) => hub.embedders(front).await.map(|e| json!(e)),
        Params::SearchModelDownload(d) => hub.model_download(front, d).await.map(|s| json!(s)),
        Params::SearchServerPlan(k) => hub.server_plan(k.kind).await.map(|p| json!(p)),
        Params::SearchServerStart(s) => hub.server_start(s).await.map(|r| json!(r)),
        Params::SearchServerStop(k) => hub.server_stop(k.kind).await.map(|r| json!(r)),
        Params::SearchTyping(_) => {
            hub.typing().await;
            Ok(json!({}))
        }
        other => return Err(Box::new(other)),
    })
}
