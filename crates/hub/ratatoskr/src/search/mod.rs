//! Hrafn in the hub: where models live, the user's consent and the download; the embed worker and the hub's handle on
//! it (`worker`); the machine-wide vector caches (`caches`); one project's index, its tiers and gates (`project`); and
//! the battery rule (`power`).

pub mod caches;
pub mod context;
pub mod download;
pub mod engine;
pub mod engine_doctor;
pub mod engine_install;
pub mod engine_limits;
pub mod engine_pick;
pub mod engine_pool;
pub mod engine_setup;
pub mod host;
pub mod manage;
pub mod mcp;
pub mod methods;
pub mod packs;
pub mod power;
pub mod project;
pub mod remote;
pub mod saved;
pub mod scope;
pub mod sources;
pub mod worker;

pub use download::{Consent, DownloadError, download, download_gguf};
pub use methods::Hub;

use bifrost::Uri;
use hrafn::Lag;
use hrafn_embed::cache::{ModelState, model_dir, state};
use hrafn_embed::fingerprint::{Fingerprint, Identity, builtin_record};
use hrafn_embed::{MODELS, ModelSpec, default_model};
use runstav::paths::{Env, cache_dir};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use urdr::graph::search::{BoxFuture, EmbedError};

/// What a server's vectors must cover of the live chunks, in percent, for a query to use the server's model.
const SERVER_COVERAGE: u64 = 95;

/// The embed-text version of a chunk's embedded text (a field of every fingerprint): hrafn's, which its chunk keys
/// hash too.
pub use hrafn::chunk::EMBED_TEXT_VERSION;

/// The identity of the built-in model SPEC: its record at [`EMBED_TEXT_VERSION`], labelled with its id.
pub fn builtin_identity(spec: &ModelSpec) -> Identity {
    Identity::new(builtin_record(spec, EMBED_TEXT_VERSION), spec.id)
}

/// Which model a query uses: BUILTIN is the built-in model's fingerprint and lag (none: the model is off in the
/// settings or not downloaded), SERVERS each server's fingerprint, lag and whether it answers now.  A server that
/// answers and covers at least [`SERVER_COVERAGE`] percent of the live chunks wins (the first such one); else the
/// built-in model; with no built-in model, the answering server that covers most.  None: no vector model can answer, so
/// the answer is keyword and symbol results with the lag said.
pub fn prefer(
    builtin: Option<(&Fingerprint, &Lag)>,
    servers: &[(Fingerprint, Lag, bool)],
) -> Option<Fingerprint> {
    let covered = |l: &Lag| u64::from(l.chunks_total.saturating_sub(l.chunks_behind));
    let answering = servers.iter().filter(|(_, _, up)| *up);
    match builtin {
        Some((b, _)) => answering
            .clone()
            .find(|(_, l, _)| covered(l) * 100 >= u64::from(l.chunks_total) * SERVER_COVERAGE)
            .map(|(m, _, _)| *m)
            .or(Some(*b)),
        None => answering
            .max_by_key(|(_, l, _)| covered(l))
            .map(|(m, _, _)| *m),
    }
}

/// Something tier 2 sends document texts to: the built-in model's worker, or a server through the gateway.
pub trait DocEmbedder: Send + Sync {
    /// What the last [`probe`](Self::probe) proved of its model; none before the first answer (or when it never
    /// answered). The `model` of its `vec` rows is `identity().fp.hex()`.
    fn identity(&self) -> Option<Identity>;

    /// Asks the embedder what its model is now: a TEI or Ollama server states it (`/info`, `/api/show` and one probe
    /// embed for the dims), the built-in worker knows it. A server that does not answer is an error; one whose model
    /// changed answers another fingerprint, and the next write goes under that one.
    fn probe(&self) -> BoxFuture<'_, Result<Identity, EmbedError>>;

    /// The id its source goes by in a chain and its status: a provider's id, `builtin` for the worker.
    fn source_id(&self) -> String {
        "embed".into()
    }

    /// What kind of source it is in a chain ([`sources::SourceKind`]).
    fn source_kind(&self) -> sources::SourceKind {
        sources::SourceKind::Embed
    }

    /// Whether it may be sent document text: the built-in model and a server on this machine; a remote only when its
    /// entry says so.
    fn trusted(&self) -> bool {
        true
    }

    /// The most texts one request to it carries; the built-in model's eight unless it says more (the engine's batch
    /// keeps a GPU fed: one pass of the chain costs a store read and a write however many keys it carries).
    fn max_batch(&self) -> usize {
        project::REQUEST_KEYS as usize
    }

    /// Vectors for TEXTS, in order. OVERRIDING (`search/index` with `now`) lets the built-in worker run on battery.
    fn embed_docs<'a>(
        &'a self,
        texts: &'a [String],
        overriding: bool,
    ) -> BoxFuture<'a, Result<Vec<Vec<f32>>, EmbedError>>;

    /// Whether it answers now ([`probe`](Self::probe) succeeds). One that does not (a server that is not running) gets
    /// no request in a pass of tier 2 and does not mark tier 2 failed; it is asked again when the next change wakes
    /// tier 2. The built-in worker, started on demand, always does.
    fn answers(&self) -> BoxFuture<'_, bool> {
        Box::pin(async move { self.probe().await.is_ok() })
    }
}

/// The hub's Hrafn state that is not one project's: the built-in model's worker and the local engine, each shared by
/// every project and by the entity embedder.
pub struct Search {
    /// `<cache>/models`.
    models: PathBuf,
    exe: PathBuf,
    builtin: Mutex<Option<Arc<worker::WorkerEmbedder>>>,
    /// The pool and the key of the settings it was built for.
    engine: Mutex<Option<(String, Arc<engine_pool::EnginePool>)>>,
    machine: std::sync::OnceLock<engine_pick::Machine>,
}

impl Search {
    pub fn new(env: &Env) -> Search {
        Search {
            models: models_root(env),
            exe: std::env::current_exe().unwrap_or_else(|_| PathBuf::from("ratatoskr")),
            builtin: Mutex::new(None),
            engine: Mutex::new(None),
            machine: std::sync::OnceLock::new(),
        }
    }

    /// This machine's GPUs and drivers, read once.
    pub fn machine(&self) -> engine_pick::Machine {
        self.machine.get_or_init(engine_pick::Machine::read).clone()
    }

    /// The local engine pool, once CONSENTED (the user consented to the download) and its GGUF and the assets the
    /// settings name are in the cache; never a download. Otherwise why not, and a chain that names it falls through.
    /// It resolves the devices when the settings, the power state or the assets changed, and keeps the pool until then.
    pub async fn engine(
        &self,
        consented: bool,
        settings: &engine_setup::EngineSettings,
        on_battery: bool,
    ) -> Result<Arc<engine_pool::EnginePool>, EmbedError> {
        let not_installed = || EmbedError("the engine is not installed".into());
        if !consented {
            return Err(not_installed());
        }
        let gguf = hrafn_embed::default_gguf();
        let cache = self
            .models
            .parent()
            .ok_or_else(not_installed)?
            .to_path_buf();
        if !engine_install::gguf_ready(&self.models, gguf) {
            return Err(not_installed());
        }
        let key = settings.key(on_battery);
        {
            let held = self
                .engine
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some((k, pool)) = held.as_ref()
                && *k == key
            {
                return Ok(pool.clone());
            }
        }
        let machine = self.machine();
        let (c, st) = (cache.clone(), settings.clone());
        let resolved = crate::clock::blocking(move || {
            engine_setup::resolve(
                &c,
                &machine,
                &engine_pick::Visible::from_env(),
                &st,
                on_battery,
            )
        })
        .await
        .map_err(|e| EmbedError(format!("the engine's setup did not finish: {e}")))?;
        for e in &settings.errors {
            tracing::warn!("search: {e}");
        }
        let (members, notes): (
            Vec<(&'static hrafn_embed::EngineAsset, String)>,
            Vec<String>,
        ) = match &resolved.plan {
            engine_pick::Plan::Gpu { members, notes, .. } => (
                members
                    .iter()
                    .map(|m| (m.asset, m.device.id.clone()))
                    .collect(),
                notes.clone(),
            ),
            engine_pick::Plan::Cpu { asset, notes, .. } => {
                (vec![(*asset, "none".to_string())], notes.clone())
            }
            engine_pick::Plan::Wait { why, .. } => return Err(EmbedError(why.clone())),
        };
        for n in notes {
            tracing::info!("search: {n}");
        }
        let ncpu_systemd = engine_systemd();
        let pin = Arc::new(Mutex::new((
            resolved.pin.clone(),
            resolved.pin_path.clone(),
        )));
        let mut lanes: Vec<(String, Arc<dyn engine_pool::Lane>, f64)> = Vec::new();
        let mut identity = None;
        for (asset, device) in members {
            let exe = engine_install::installed(asset, &engine_install::dir_for(&cache, asset))
                .ok_or_else(not_installed)?;
            let engine = Arc::new(engine::LocalEngine::new(engine::EngineSpec {
                exe,
                gguf: engine_install::gguf_path(&self.models, gguf),
                record: (gguf.record)(EMBED_TEXT_VERSION),
                label: format!("the engine ({} on {device})", gguf.id),
                ctx: hrafn_embed::models::QWEN3_MAX_TOKENS,
                ubatch: hrafn_embed::models::QWEN3_MAX_TOKENS,
                idle: engine::IDLE,
                selfcheck: gguf
                    .selfcheck()
                    .map(|(text, vector)| engine::SelfCheck { text, vector }),
                device: Some(device.clone()),
                limits: settings.limits,
                systemd: ncpu_systemd.clone(),
            }));
            identity.get_or_insert_with(|| engine.identity());
            let rate = resolved.pin.rates.get(&device).copied().unwrap_or(0.0);
            lanes.push((device, engine, rate));
        }
        let identity = identity.ok_or_else(not_installed)?;
        let on_rate: engine_pool::OnRate = Box::new(move |id, rate| {
            let mut held = pin
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let old = held.0.rates.insert(id.to_owned(), rate);
            // kept when it moved by a fifth, not at every batch
            if old.is_none_or(|o| (o - rate).abs() > o * 0.2)
                && let Err(e) = held.0.save(&held.1)
            {
                tracing::warn!("search: the engine's rates were not saved: {e}");
            }
        });
        let pool = Arc::new(engine_pool::EnginePool::new(lanes, identity, Some(on_rate)));
        *self
            .engine
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some((key, pool.clone()));
        Ok(pool)
    }

    /// The built-in model's worker, once the model is `Ready` in the cache (never before, and never a download); none
    /// while it is missing, partial or corrupt.
    pub fn builtin(&self) -> Option<Arc<worker::WorkerEmbedder>> {
        let spec = default_model();
        let dir = model_dir(&self.models, spec);
        if state(spec, &dir) != ModelState::Ready {
            return None;
        }
        let mut held = self.builtin.lock().ok()?;
        Some(
            held.get_or_insert_with(|| {
                Arc::new(worker::WorkerEmbedder::new(worker::WorkerSpec {
                    exe: self.exe.clone(),
                    model: spec.id.to_string(),
                    dir,
                    device_cache: self.models.join("device.json"),
                    threads: worker::threads(),
                    idle_ms: None,
                    power_root: PathBuf::from(power::SYS),
                    test_args: Vec::new(),
                }))
            })
            .clone(),
        )
    }
}

/// The `kv` key of the consent, in `runtime.db`.
const KV_CONSENT: &str = "search.consent";

const HOST: &str = "https://huggingface.co";

/// `<cache>/models`.
pub fn models_root(env: &Env) -> PathBuf {
    cache_dir(env).join("models")
}

/// Where models come from: `drgnx-search-model-mirror`, else the Hugging Face host.
pub fn model_base(mirror: Option<&str>) -> Result<Uri, String> {
    let text = mirror.unwrap_or(HOST).trim_end_matches('/');
    let uri: Uri = text
        .parse()
        .map_err(|e| format!("the model mirror {text:?} is not a URL: {e}"))?;
    match uri.scheme_str() {
        Some("http" | "https") => Ok(uri),
        _ => Err(format!(
            "the model mirror {text:?} is neither http nor https"
        )),
    }
}

/// The consent the user gave, if any.
pub async fn stored_consent(db: &urdr::Handle) -> Option<Consent> {
    let text = crate::gateway::kv_get(db, KV_CONSENT).await?;
    serde_json::from_str(&text).ok()
}

pub async fn store_consent(db: &urdr::Handle, consent: &Consent) {
    match serde_json::to_string(consent) {
        Ok(text) => crate::gateway::kv_set(db, KV_CONSENT, &text).await,
        Err(e) => tracing::warn!("the consent does not encode: {e}"),
    }
}

/// The `kv` key of the local engine's consent (its GGUF and this machine's asset), in `runtime.db`.
const KV_ENGINE_CONSENT: &str = "search.consent.engine";

/// The consent the user gave to the engine's download, if any.
pub async fn stored_engine_consent(db: &urdr::Handle) -> Option<Consent> {
    let text = crate::gateway::kv_get(db, KV_ENGINE_CONSENT).await?;
    serde_json::from_str(&text).ok()
}

pub async fn store_engine_consent(db: &urdr::Handle, consent: &Consent) {
    match serde_json::to_string(consent) {
        Ok(text) => crate::gateway::kv_set(db, KV_ENGINE_CONSENT, &text).await,
        Err(e) => tracing::warn!("the engine's consent does not encode: {e}"),
    }
}

/// A row of the model table, or `test-tiny` in a test-hooks build.
pub fn model(id: &str) -> Option<&'static ModelSpec> {
    #[cfg(any(test, feature = "test-hooks"))]
    if id == TEST_TINY.id {
        return Some(&TEST_TINY);
    }
    MODELS.iter().find(|m| m.id == id)
}

/// No weights: a model for the flows that need no inference (consent, download), served from `test/fixtures/test-tiny/`,
/// so the Lisp tests need no model volume.
#[cfg(any(test, feature = "test-hooks"))]
pub static TEST_TINY: ModelSpec = ModelSpec {
    id: "test-tiny",
    repo: "drgnx/test-tiny",
    revision: "0000000000000000000000000000000000000000",
    files: &[
        hrafn_embed::ModelFile {
            name: "model.safetensors",
            sha256: "5840923b3c1276517aead8c01e20f920882692ac51cc2f8a4ce57a78ca2055b9",
            bytes: 36,
        },
        hrafn_embed::ModelFile {
            name: "tokenizer.json",
            sha256: "23f89e1cac70471c20604d6808013a2ba8ffde18bbe686cf7f9303781d60d9c4",
            bytes: 34,
        },
        hrafn_embed::ModelFile {
            name: "config.json",
            sha256: "379ec29dcdcacc4cafd1984602bf2f655ca30f781487fec4af7a78e0e49bb3a9",
            bytes: 28,
        },
    ],
    dims: 8,
    max_tokens: 16,
    query_prefix: "",
    doc_prefix: "",
    arch: hrafn_embed::Arch::ModernBert,
    licence: "Apache-2.0",
};

#[cfg(test)]
mod tests {
    use super::*;
    use hrafn_embed::cache::{ModelState, state};
    use std::path::Path;

    #[test]
    fn test_tiny_is_what_its_row_says() {
        let fixtures =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/test-tiny");
        assert_eq!(state(&TEST_TINY, &fixtures), ModelState::Ready);
        assert_eq!(model("test-tiny").unwrap().id, "test-tiny");
        assert_eq!(model(MODELS[0].id).unwrap().id, MODELS[0].id);
        assert!(model("no-such-model").is_none());
    }

    #[test]
    fn models_live_under_the_cache() {
        let env = Env::new(&[("HOME", "/hm")], 1);
        assert_eq!(
            models_root(&env),
            Path::new("/hm/.cache/drgnx/models"),
            "<cache>/models"
        );
    }

    #[test]
    fn the_base_is_the_host_or_the_mirror() {
        assert_eq!(model_base(None).unwrap().to_string(), format!("{HOST}/"));
        let mirror = model_base(Some("https://models.example/hf/")).unwrap();
        assert_eq!(mirror.to_string(), "https://models.example/hf");
        assert!(model_base(Some("ftp://models.example")).is_err());
        assert!(model_base(Some("not a url")).is_err());
    }

    #[tokio::test]
    async fn the_consent_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let consent = Consent {
            model: "m".into(),
            bytes: 302,
            at: 1.5,
        };
        {
            let (_store, db) = crate::runtime_db::open(dir.path()).unwrap();
            assert!(stored_consent(&db).await.is_none());
            store_consent(&db, &consent).await;
        }
        let (_store, db) = crate::runtime_db::open(dir.path()).unwrap();
        assert_eq!(stored_consent(&db).await, Some(consent));
    }
}

/// `systemd-run`, when the user's systemd manager is there to hold the engine's CPU and memory limits.
fn engine_systemd() -> Option<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from)?;
    runtime.join("systemd").is_dir().then_some(())?;
    std::env::var_os("PATH")?
        .to_string_lossy()
        .split(':')
        .map(|d| PathBuf::from(d).join("systemd-run"))
        .find(|p| p.is_file())
}
