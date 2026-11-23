//! An HTTP embedder that talks to a server (TEI, Ollama, llama.cpp) without the hub or the gateway: what
//! `ratatoskr search eval run --source …` embeds with. It is plain HTTP/1.1 on a TCP stream (the servers are on this
//! machine or a trusted one; TLS is not spoken), one request per batch, no retry: a server that fails fails the run.

use http::Uri;
use serde_json::json;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use urdr::graph::search::EmbedError;

/// How long one request may take (a batch of long chunks on a CPU engine is slow).
const DEADLINE: Duration = Duration::from_secs(600);

/// Texts per request.
const BATCH: usize = 32;

/// The context Ollama is asked for (`options.num_ctx`), in tokens: its default would truncate or refuse long chunks.
pub const OLLAMA_CTX: u32 = 8192;

/// Which API a server speaks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Api {
    /// `POST /embed {"inputs"}` answers a list of vectors.
    Tei,
    /// `POST /api/embed {"model", "input", "truncate": false, "options": {"num_ctx"}}` answers `{"embeddings"}`.
    Ollama(String),
    /// `POST /v1/embeddings {"input"}` answers `{"data": [{"index", "embedding"}]}`.
    Llama,
}

/// A server at a base URL.
pub struct Direct {
    api: Api,
    host: String,
    port: u16,
    prefix: String,
}

impl Direct {
    pub fn new(api: Api, base: Uri) -> Direct {
        Direct {
            api,
            host: base.host().unwrap_or("127.0.0.1").to_owned(),
            port: base.port_u16().unwrap_or(80),
            prefix: base.path().trim_end_matches('/').to_owned(),
        }
    }

    /// The vectors of TEXTS, in order.
    pub async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        let mut out = Vec::with_capacity(texts.len());
        for batch in texts.chunks(BATCH) {
            let rows = match crate::clock::timeout(DEADLINE, self.post(batch)).await {
                Ok(r) => r.map_err(EmbedError)?,
                Err(_) => {
                    return Err(EmbedError(format!(
                        "{}:{} did not answer in time",
                        self.host, self.port
                    )));
                }
            };
            out.extend(rows);
        }
        Ok(out)
    }

    async fn post(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let (path, body) = match &self.api {
            Api::Tei => ("/embed", json!({"inputs": texts})),
            Api::Ollama(model) => (
                "/api/embed",
                json!({"model": model, "input": texts, "truncate": false,
                       "options": {"num_ctx": OLLAMA_CTX}}),
            ),
            Api::Llama => ("/v1/embeddings", json!({"input": texts})),
        };
        let body = body.to_string();
        let head = format!(
            "POST {}{path} HTTP/1.1\r\nHost: {}:{}\r\nContent-Type: application/json\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n",
            self.prefix,
            self.host,
            self.port,
            body.len()
        );
        let at = format!("{}:{}", self.host, self.port);
        let mut s = TcpStream::connect((self.host.as_str(), self.port))
            .await
            .map_err(|e| format!("{at} does not answer: {e}"))?;
        s.write_all(head.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        s.write_all(body.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).await.map_err(|e| e.to_string())?;
        let (status, payload) = crate::embed::split_response(&raw)?;
        if status != 200 {
            return Err(format!(
                "{at} answered {status}: {}",
                String::from_utf8_lossy(&payload)
                    .chars()
                    .take(200)
                    .collect::<String>()
            ));
        }
        let not_vectors = |e: serde_json::Error| format!("{at} answered what is not vectors: {e}");
        let rows: Vec<Vec<f32>> = match &self.api {
            Api::Tei => serde_json::from_slice(&payload).map_err(not_vectors)?,
            Api::Ollama(_) => {
                #[derive(serde::Deserialize)]
                struct Answer {
                    embeddings: Vec<Vec<f32>>,
                }
                serde_json::from_slice::<Answer>(&payload)
                    .map_err(not_vectors)?
                    .embeddings
            }
            Api::Llama => {
                #[derive(serde::Deserialize)]
                struct Item {
                    index: usize,
                    embedding: Vec<f32>,
                }
                #[derive(serde::Deserialize)]
                struct Answer {
                    data: Vec<Item>,
                }
                let mut data = serde_json::from_slice::<Answer>(&payload)
                    .map_err(not_vectors)?
                    .data;
                data.sort_by_key(|i| i.index);
                data.into_iter().map(|i| i.embedding).collect()
            }
        };
        if rows.len() != texts.len() {
            return Err(format!(
                "{at} answered {} vectors for {} texts",
                rows.len(),
                texts.len()
            ));
        }
        Ok(rows)
    }
}
