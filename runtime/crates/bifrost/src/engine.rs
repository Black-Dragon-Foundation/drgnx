//! The forwarding engine (design §5.6; the plan's calls 11 and 15), as the Lisp gateway's `drgnx-gateway--handle`,
//! `--try`, `--upstream-bytes` and `--spend` did.
//!
//! [`Gateway::handle`] takes one request from a listener (`listen`):
//!
//! 1. [`admit::head`] on the head alone; a refusal answers at once and drains up to 64 KiB of the unread body before
//!    the connection closes (A-25);
//! 2. an agent whose job has a budget: [`Ledger::spent`] `>=` the budget is a [`GatewayEvent::Budget`] and 429;
//! 3. the body, at most 32 MiB;
//! 4. the route:
//!    - an agent's chain, step by step: a step that cannot be used is skipped with its reason (and
//!      [`GatewayEvent::NeedKeys`] for a missing key); a step whose provider gives no head, or a fallback status
//!      ([`FALLBACK_STATUSES`], 5xx) while another step remains, moves on with [`GatewayEvent::Fallback`]; the first
//!      head that is not moved on from **starts** the answer, and nothing falls back after that. No step left: 502
//!      with every `P: WHY`;
//!    - the editor's one provider, passed through: its body as it came, no budget, no fallback;
//! 5. a started answer streams chunk by chunk through the usage scanner. When it ends, or the client hangs up (which
//!    drops the upstream body and so its connection), one spend row is recorded, then a [`GatewayEvent::Request`],
//!    then a [`GatewayEvent::Budget`] if the job's total reached its budget.
//!
//! The spend row is written by a guard's `Drop`, armed when a request is sent and disarmed when the engine moves on
//! from it, so every answered request records exactly one row (status 0 when the client left before the head), and a
//! skipped or abandoned step none.
//!
//! A key is read from [`Keys`] per attempt and goes only into the upstream request's sensitive header
//! (`rewrite::headers`). Logs carry provider ids and statuses, never a key or a token.

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard};
use std::task::{Context, Poll, ready};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http::header::{CONNECTION, CONTENT_TYPE, EXPECT, RETRY_AFTER};
use http::request::Parts;
use http::{HeaderValue, Request, Response, StatusCode, Uri};
use http_body_util::combinators::UnsyncBoxBody;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::{Body, Frame, Incoming, SizeHint};
use secrecy::SecretString;
use tokio::sync::mpsc;
use tokio::time::Sleep;

use crate::admit::{self, MAX_BODY, Refusal, Registry, Route};
use crate::budget::{self, Price};
use crate::keys::Keys;
use crate::rewrite;
use crate::upstream::Upstream;
use crate::usage::Scanner;
use crate::{ListenerId, Provider, Registration, Step};

/// A boxed, sendable future (the [`Ledger`]'s calls).
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The error type of an answer's body.
pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// An answer's body: a refusal, a gateway error, or a provider's stream.
pub type ReplyBody = UnsyncBoxBody<Bytes, BoxError>;

/// The statuses (besides 5xx) after which the next step is tried, while one remains (the Lisp's
/// `drgnx-gateway--retry-statuses`).
pub const FALLBACK_STATUSES: [u16; 5] = [401, 402, 408, 409, 429];

/// How often, at most, [`GatewayEvent::NeedKeys`] names the same provider.
pub const NEED_KEYS_EVERY: Duration = Duration::from_secs(60);

/// How much of a refused request's unread body is read before the connection closes (A-25), and for how long.
pub const DRAIN_MAX: usize = 64 * 1024;
pub const DRAIN_FOR: Duration = Duration::from_secs(2);

/// One completed request, for the `spend` table. `job` is none and `agent` is `editor` on the editor's route.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SpendRow {
    pub job: Option<String>,
    pub task: Option<String>,
    pub agent: Option<String>,
    pub provider: String,
    /// The step's model (none: the request's own, and always none on the editor's route).
    pub model: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cost: f64,
    /// The provider's status, or 0 when the client left before the head.
    pub status: u16,
}

/// What the gateway tells its caller, on the channel given to [`Gateway::new`].
#[derive(Debug, Clone, PartialEq)]
pub enum GatewayEvent {
    /// A request completed; its row was recorded first.
    Request(SpendRow),
    /// Step `from` was passed over for `to`, because of `why`.
    Fallback {
        agent: Option<String>,
        from: String,
        to: String,
        why: String,
    },
    /// Job `job` has spent its budget: on a refusal, and after the request that reached it.
    Budget { job: String, spent: f64, budget: f64 },
    /// A request needed these providers' keys, which the hub does not hold (at most once a minute per provider).
    NeedKeys { providers: Vec<String> },
}

/// The spend store: the caller's (`work.db`'s `spend` table in the hub).
pub trait Ledger: Send + Sync {
    /// What job `job` has spent so far (USD).
    fn spent(&self, job: &str) -> BoxFuture<'_, Result<f64, String>>;
    /// Record one completed request. Failures are the ledger's to log; the gateway goes on.
    fn record(&self, row: SpendRow) -> BoxFuture<'_, ()>;
}

/// The gateway: what every listener of one hub shares.
pub struct Gateway {
    registry: Arc<dyn Registry>,
    providers: Arc<RwLock<BTreeMap<String, Provider>>>,
    keys: Arc<RwLock<Keys>>,
    ledger: Arc<dyn Ledger>,
    events: mpsc::UnboundedSender<GatewayEvent>,
    upstream: Upstream,
    /// Provider id → when [`GatewayEvent::NeedKeys`] last named it.
    told: Mutex<HashMap<String, Instant>>,
}

/// What one step came to.
enum Attempt {
    /// The answer: a provider's (started) or the gateway's own.
    Answer(Response<ReplyBody>),
    /// Move on to the next step, for this reason.
    Next(String),
}

impl Gateway {
    pub fn new(
        registry: Arc<dyn Registry>,
        providers: Arc<RwLock<BTreeMap<String, Provider>>>,
        keys: Arc<RwLock<Keys>>,
        ledger: Arc<dyn Ledger>,
        events: mpsc::UnboundedSender<GatewayEvent>,
        upstream: Upstream,
    ) -> Arc<Self> {
        Arc::new(Self {
            registry,
            providers,
            keys,
            ledger,
            events,
            upstream,
            told: Mutex::new(HashMap::new()),
        })
    }

    /// Answer one request that came in on listener `on` (`port`: the loopback listener's, for its `Host` check).
    pub async fn handle(
        self: Arc<Self>,
        req: Request<Incoming>,
        on: ListenerId,
        port: u16,
    ) -> Response<ReplyBody> {
        let (parts, incoming) = req.into_parts();
        let admitted = admit::head(&parts, &on, port, &*self.registry, &read(&self.providers));
        let admitted = match admitted {
            Ok(a) => a,
            Err(r) => return refuse(&r, &parts, incoming),
        };
        let reg = admitted.registration;

        if let (Some(job), Some(limit)) = (&reg.job, reg.budget) {
            match self.ledger.spent(job).await {
                Ok(spent) if budget::over(spent, limit) => {
                    self.emit(GatewayEvent::Budget {
                        job: job.clone(),
                        spent,
                        budget: limit,
                    });
                    let r = Refusal::new(
                        429,
                        "budget_exceeded",
                        format!("the job's budget ({limit} USD) is spent"),
                    );
                    return refuse(&r, &parts, incoming);
                }
                Ok(_) => {}
                Err(e) => {
                    let r = Refusal::new(500, "api_error", format!("the gateway failed: {e}"));
                    return refuse(&r, &parts, incoming);
                }
            }
        }

        let body = match Limited::new(incoming, MAX_BODY as usize).collect().await {
            Ok(collected) => collected.to_bytes(),
            Err(e) if e.downcast_ref::<LengthLimitError>().is_some() => {
                return answer(
                    &Refusal::new(
                        413,
                        "invalid_request_error",
                        "the request body is over 32 MiB",
                    ),
                    true,
                );
            }
            Err(_) => {
                return answer(
                    &Refusal::new(
                        400,
                        "invalid_request_error",
                        "the request cannot be taken",
                    ),
                    true,
                );
            }
        };

        match admitted.route {
            Route::Chain => self.chain(&parts, body, &reg).await,
            Route::Provider { id, rest } => self.editor(&parts, body, &reg, &id, &rest).await,
        }
    }

    /// An agent's request along its chain.
    async fn chain(&self, parts: &Parts, body: Bytes, reg: &Registration) -> Response<ReplyBody> {
        let target = parts.uri.path_and_query().map_or("/", |pq| pq.as_str());
        let mut reasons = Vec::new();
        for (i, step) in reg.chain.iter().enumerate() {
            let next = reg.chain.get(i + 1);
            match self.attempt(parts, &body, reg, step, target, next.is_none()).await {
                Attempt::Answer(answer) => return answer,
                Attempt::Next(why) => {
                    if let Some(next) = next {
                        self.emit(GatewayEvent::Fallback {
                            agent: reg.agent.clone(),
                            from: step.provider.clone(),
                            to: next.provider.clone(),
                            why: why.clone(),
                        });
                    }
                    reasons.push(format!("{}: {why}", step.provider));
                }
            }
        }
        answer(
            &Refusal::new(
                502,
                "api_error",
                format!("no provider answered: {}", reasons.join("; ")),
            ),
            false,
        )
    }

    /// One step of a chain. `last`: the chain's literal last step, whose provider's refusal is the answer (A-27).
    async fn attempt(
        &self,
        parts: &Parts,
        body: &Bytes,
        reg: &Registration,
        step: &Step,
        target: &str,
        last: bool,
    ) -> Attempt {
        let id = step.provider.as_str();
        let Some(provider) = read(&self.providers).get(id).cloned() else {
            return Attempt::Next("not configured".into());
        };
        if !provider.messages {
            return Attempt::Next("the gateway cannot carry it".into());
        }
        let request = {
            let keys = read(&self.keys);
            let key = keys.get(id);
            if provider.needs_key() && key.is_none() {
                self.need_keys(id);
                return Attempt::Next("no key".into());
            }
            let uri = match rewrite::upstream_uri(&provider.base, target) {
                Ok(uri) => uri,
                Err(e) => return Attempt::Next(format!("cannot send ({e})")),
            };
            let body = match rewrite::body(
                body.clone(),
                step.model.as_deref(),
                reg.openrouter.as_ref(),
                target,
                id,
            ) {
                Ok(body) => body,
                // the restrictions cannot be applied: refused, sent to no provider
                Err(r) => return Attempt::Answer(answer(&r, false)),
            };
            match upstream_request(parts, &provider, key, uri, body) {
                Ok(request) => request,
                Err(why) => return Attempt::Next(why),
            }
        };

        let mut spend = self.spend(reg, id, step.model.clone(), provider.price);
        tracing::debug!(provider = id, "gateway: forwarding an agent's request");
        match self.upstream.send(request).await {
            Err(e) => {
                spend.disarm();
                Attempt::Next(format!("no answer ({e})"))
            }
            Ok(response) => {
                let status = response.status().as_u16();
                if !last && falls_back(status) {
                    spend.disarm();
                    return Attempt::Next(format!("HTTP {status}"));
                }
                spend.status = status;
                Attempt::Answer(relay(response, spend))
            }
        }
    }

    /// The editor's request: provider `id` only, at `rest`, its body as it came (call 15).
    async fn editor(
        &self,
        parts: &Parts,
        body: Bytes,
        reg: &Registration,
        id: &str,
        rest: &str,
    ) -> Response<ReplyBody> {
        let failed =
            |why: String| answer(&Refusal::new(502, "api_error", format!("no provider answered: {id}: {why}")), false);
        let Some(provider) = read(&self.providers).get(id).cloned() else {
            return answer(
                &Refusal::new(404, "not_found_error", "no such provider in the drgnx hub"),
                false,
            );
        };
        let request = {
            let keys = read(&self.keys);
            let key = keys.get(id);
            if provider.needs_key() && key.is_none() {
                self.need_keys(id);
                return answer(
                    &Refusal::new(503, "api_error", format!("no key for {id} in the drgnx hub")),
                    false,
                );
            }
            let uri = match rewrite::provider_uri(&provider.base, rest) {
                Ok(uri) => uri,
                Err(e) => return failed(format!("cannot send ({e})")),
            };
            match upstream_request(parts, &provider, key, uri, body) {
                Ok(request) => request,
                Err(why) => return failed(why),
            }
        };

        let mut spend = self.spend(reg, id, None, provider.price);
        tracing::debug!(provider = id, "gateway: forwarding an editor's request");
        match self.upstream.send(request).await {
            Err(e) => {
                spend.disarm();
                failed(format!("no answer ({e})"))
            }
            Ok(response) => {
                spend.status = response.status().as_u16();
                relay(response, spend)
            }
        }
    }

    /// An armed spend guard for a request to provider `id`.
    fn spend(&self, reg: &Registration, id: &str, model: Option<String>, price: Option<Price>) -> Spend {
        Spend {
            row: SpendRow {
                job: reg.job.clone(),
                task: reg.task.clone(),
                agent: reg.agent.clone(),
                provider: id.to_owned(),
                model,
                ..SpendRow::default()
            },
            status: 0,
            price,
            budget: reg.budget,
            scanner: Scanner::new(),
            ledger: self.ledger.clone(),
            events: self.events.clone(),
            armed: true,
        }
    }

    /// [`GatewayEvent::NeedKeys`] for `id`, unless it was named within [`NEED_KEYS_EVERY`].
    fn need_keys(&self, id: &str) {
        let now = Instant::now();
        {
            let mut told = self.told.lock().unwrap_or_else(PoisonError::into_inner);
            if told
                .get(id)
                .is_some_and(|at| now.duration_since(*at) < NEED_KEYS_EVERY)
            {
                return;
            }
            told.insert(id.to_owned(), now);
        }
        self.emit(GatewayEvent::NeedKeys {
            providers: vec![id.to_owned()],
        });
    }

    fn emit(&self, event: GatewayEvent) {
        // the receiver gone means the hub is stopping; nothing to tell
        let _ = self.events.send(event);
    }
}

fn read<T>(lock: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(PoisonError::into_inner)
}

/// 5xx, or one of [`FALLBACK_STATUSES`].
fn falls_back(status: u16) -> bool {
    status >= 500 || FALLBACK_STATUSES.contains(&status)
}

/// The upstream request: the client's method, `uri`, the forwarded headers with `key`, `body`.
fn upstream_request(
    parts: &Parts,
    provider: &Provider,
    key: Option<&SecretString>,
    uri: Uri,
    body: Bytes,
) -> Result<Request<Full<Bytes>>, String> {
    let mut request = Request::builder()
        .method(parts.method.clone())
        .uri(uri)
        .body(Full::new(body))
        .map_err(|e| format!("cannot send ({e})"))?;
    *request.headers_mut() = rewrite::headers(parts, provider, key);
    Ok(request)
}

/// The gateway's own error answer after the body was read; `close` ends the connection after it.
fn answer(r: &Refusal, close: bool) -> Response<ReplyBody> {
    let body = Full::new(r.body()).map_err(|never| match never {}).boxed_unsync();
    let mut response = Response::new(body);
    *response.status_mut() =
        StatusCode::from_u16(r.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    if close {
        response
            .headers_mut()
            .insert(CONNECTION, HeaderValue::from_static("close"));
    }
    response
}

/// A refusal before the body was read: the answer, then up to [`DRAIN_MAX`] of the body is read (and dropped) before
/// the connection closes, so the client is not reset while it still sends (A-25). A client that waits for
/// `100 Continue` has sent no body, and none is invited.
fn refuse(r: &Refusal, parts: &Parts, incoming: Incoming) -> Response<ReplyBody> {
    let unread = (!incoming.is_end_stream() && !parts.headers.contains_key(EXPECT)).then_some(incoming);
    let drain = Drain {
        first: Some(r.body()),
        unread,
        taken: 0,
        until: Box::pin(tokio::time::sleep(DRAIN_FOR)),
    };
    let mut response = answer(r, true);
    *response.body_mut() = drain.boxed_unsync();
    response
}

/// A refusal's body: its bytes, then the request's unread body read and dropped (chunked, so the answer's end is the
/// drain's).
struct Drain {
    first: Option<Bytes>,
    unread: Option<Incoming>,
    taken: usize,
    until: Pin<Box<Sleep>>,
}

impl Body for Drain {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        let this = self.get_mut();
        if let Some(bytes) = this.first.take() {
            return Poll::Ready(Some(Ok(Frame::data(bytes))));
        }
        while let Some(unread) = &mut this.unread {
            if this.taken >= DRAIN_MAX || this.until.as_mut().poll(cx).is_ready() {
                this.unread = None;
                break;
            }
            match Pin::new(unread).poll_frame(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Some(Ok(frame))) => {
                    this.taken += frame.data_ref().map_or(0, Bytes::len);
                }
                Poll::Ready(Some(Err(_)) | None) => this.unread = None,
            }
        }
        Poll::Ready(None)
    }

    fn is_end_stream(&self) -> bool {
        self.first.is_none() && self.unread.is_none()
    }

    fn size_hint(&self) -> SizeHint {
        match (&self.first, &self.unread) {
            (Some(bytes), None) => SizeHint::with_exact(bytes.len() as u64),
            (None, None) => SizeHint::with_exact(0),
            _ => SizeHint::default(),
        }
    }
}

/// A started answer: the provider's status, `Content-Type` (default `application/json`) and `Retry-After`, then its
/// body chunk by chunk through the scanner.
fn relay(response: Response<Incoming>, spend: Spend) -> Response<ReplyBody> {
    let (head, upstream) = response.into_parts();
    let body = Relay {
        upstream,
        spend: Some(spend),
    };
    let mut out = Response::new(body.boxed_unsync());
    *out.status_mut() = head.status;
    let content_type = head
        .headers
        .get(CONTENT_TYPE)
        .cloned()
        .unwrap_or_else(|| HeaderValue::from_static("application/json"));
    out.headers_mut().insert(CONTENT_TYPE, content_type);
    if let Some(retry_after) = head.headers.get(RETRY_AFTER) {
        out.headers_mut().insert(RETRY_AFTER, retry_after.clone());
    }
    out
}

/// The provider's body on its way to the client. Dropped (the client hung up) or ended, it drops the upstream body,
/// which ends the upstream connection, and its spend guard, which records the row.
struct Relay {
    upstream: Incoming,
    spend: Option<Spend>,
}

impl Body for Relay {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        let this = self.get_mut();
        loop {
            match ready!(Pin::new(&mut this.upstream).poll_frame(cx)) {
                Some(Ok(frame)) => {
                    // trailers are not passed on
                    if let Ok(data) = frame.into_data() {
                        if let Some(spend) = &mut this.spend {
                            spend.scanner.feed(&data);
                        }
                        return Poll::Ready(Some(Ok(Frame::data(data))));
                    }
                }
                Some(Err(e)) => {
                    // the provider broke off: the client sees a cut answer; what was counted is recorded
                    this.spend = None;
                    return Poll::Ready(Some(Err(e.into())));
                }
                None => {
                    this.spend = None;
                    return Poll::Ready(None);
                }
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        self.upstream.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.upstream.size_hint()
    }
}

/// The spend row of one sent request, recorded when this is dropped while armed: once, whichever way the request
/// ends.
struct Spend {
    row: SpendRow,
    status: u16,
    price: Option<Price>,
    budget: Option<f64>,
    scanner: Scanner,
    ledger: Arc<dyn Ledger>,
    events: mpsc::UnboundedSender<GatewayEvent>,
    armed: bool,
}

impl Spend {
    /// The engine moved on from this request: it records nothing.
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for Spend {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let usage = self.scanner.usage();
        let row = SpendRow {
            input: usage.input,
            output: usage.output,
            cost: budget::cost(&usage, self.price.as_ref()),
            status: self.status,
            ..std::mem::take(&mut self.row)
        };
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            tracing::warn!(provider = %row.provider, "gateway: no runtime, a spend row was not recorded");
            return;
        };
        let (ledger, events, limit) = (self.ledger.clone(), self.events.clone(), self.budget);
        runtime.spawn(async move {
            ledger.record(row.clone()).await;
            let job = row.job.clone();
            let _ = events.send(GatewayEvent::Request(row));
            // the request that spends the budget ends the job's work now, not at the next refusal
            if let (Some(job), Some(limit)) = (job, limit)
                && let Ok(spent) = ledger.spent(&job).await
                && budget::over(spent, limit)
            {
                let _ = events.send(GatewayEvent::Budget {
                    job,
                    spent,
                    budget: limit,
                });
            }
        });
    }
}
