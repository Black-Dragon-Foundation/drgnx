//! Hrafn in the hub: where models live, the user's consent and the download; the embed worker and the hub's handle on
//! it (`worker`); one project's index, its tiers and gates (`project`); and the battery rule (`power`).

pub mod download;
pub mod power;
pub mod project;
pub mod worker;

pub use download::{Consent, DownloadError, download};

use bifrost::Uri;
use hrafn_embed::{MODELS, ModelSpec};
use runstav::paths::{Env, cache_dir};
use std::path::PathBuf;

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
