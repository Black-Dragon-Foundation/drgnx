//! GCP (design §6.7.1, §6.7.6, H6): Compute Engine's REST API, Resource Manager's `testIamPermissions` and the Cloud
//! Billing Catalog's `skus.list`, as JSON over bifrost's HTTP/1.1 client (rustls on ring) with a bearer token.
//!
//! - **Machines are deleted by their deadline** (H6): every `instances.insert` carries the start's `requestId` (a retry
//!   returns the machine the first try made), the `drgnx-hub=<hub id>` label on the instance and its disk,
//!   `terminationTime` = creation + the lifetime with `instanceTerminationAction=DELETE`, `SPOT` with
//!   `preemptionNoticeDuration=120s` for a spot start, no service account, and the hub's SSH network tag. The guest
//!   never powers off (a stopped VM bills its disk and loses its deadline): the idle stop is the hub's
//!   `instances.delete`, and the sweeper deletes a VM that is idle, unreachable, stopped by anyone or past a bound.
//! - **A machine's id** is `ZONE/NAME`, what GCE addresses it by.
//! - **Tokens** come from the credential command (`gcloud auth print-access-token`, or `gcloud auth
//!   application-default print-access-token` for application default credentials), else from a service-account JSON
//!   key handed over from the keyring, traded for a token with a JWT signed by `ring` (RS256).
//! - **The role** is [`ROLE`] (`gcp-role.json`), granted on a project of drgnx's own; [`setup_check`] names the VMs
//!   drgnx did not start and gives the binding with [`condition`] then. drgnx never creates IAM itself.
//! - **The image** is Fedora CoreOS `stable`, set up per machine by its Ignition config ([`super::ignition`]).

use super::aws::{HUB_TAG, iso, pct};
use super::creds::Resolver;
use super::net::group_name;
use super::{
    CALL_TIMEOUT, Check, CloudError, Instance, InstanceInfo, InstanceState, MAX_BODY, Market,
    Price, Prices, Provider, StartReq,
};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use mimir::BoxFuture;
use secrecy::{ExposeSecret, SecretString};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use zeroize::Zeroizing;

/// The custom role fixture (design §6.7.1, H6): the methods drgnx calls and nothing else.
pub const ROLE: &str = include_str!("gcp-role.json");
/// The role's id in the project.
pub const ROLE_ID: &str = "drgnxRunner";
/// The base image: Fedora CoreOS `stable`.
pub const IMAGE_PROJECT: &str = "fedora-coreos-cloud";
pub const IMAGE_FAMILY: &str = "fedora-coreos-stable";
/// The spot notice drgnx asks for.
pub const NOTICE_S: u64 = 120;
/// Compute Engine's id in the Billing Catalog.
const COMPUTE_SERVICE: &str = "6F81-5844-456A";
/// The one OAuth scope a service account's token is asked for.
const SCOPE: &str = "https://www.googleapis.com/auth/cloud-platform";
/// Where a service-account key trades its JWT when the key names no `token_uri`.
const TOKEN_URI: &str = "https://oauth2.googleapis.com/token";
/// How long a token from the credential command is used before the command runs again.
const COMMAND_TOKEN_S: u64 = 300;
/// A token is fetched again this long before it expires.
const TOKEN_MARGIN_S: u64 = 60;
/// How long an operation (an insert, a firewall rule) is waited for.
const OPERATION_WAIT: Duration = Duration::from_secs(300);
/// The most pages of one list read.
const MAX_PAGES: usize = 50;

/// What the client needs to know.
pub struct GcpCfg {
    /// The project of drgnx's own (or one shared with other VMs, under the conditional role).
    pub project: String,
    /// Where machines start; its region bounds what the sweeper lists.
    pub zone: String,
    pub hub_id: String,
    /// Each machine's `terminationTime` is its creation plus this.
    pub lifetime: Duration,
}

/// A bearer token and until when it is used.
struct Token {
    value: Arc<SecretString>,
    until: SystemTime,
}

/// GCP, for one project and zone.
pub struct Gcp {
    cfg: GcpCfg,
    compute: String,
    rm: String,
    billing: String,
    creds: Arc<Resolver>,
    token: Mutex<Option<Token>>,
    http: bifrost::upstream::Upstream,
}

/// A GCE name (a machine, a zone, an operation): lower-case letters, digits and `-`, at most 63.
fn gce_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// A GCE label value: lower-case letters, digits, `-` and `_`, at most 63.
fn label_value(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

/// The last `/` part of a GCE URL (`…/zones/us-central1-a` → `us-central1-a`).
fn last(v: &Value) -> &str {
    v.as_str().unwrap_or("").rsplit('/').next().unwrap_or("")
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether E is GCE's "not found".
fn not_found(e: &CloudError) -> bool {
    matches!(e, CloudError::Other(m) if m.starts_with("notFound"))
}

/// A machine's schedule as GCE reports it: what the first start's check reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Scheduling {
    pub spot: bool,
    pub termination: Option<SystemTime>,
    pub action: String,
}

impl Gcp {
    /// A client for CFG's project and zone with tokens from CREDS, at Google's own endpoints (or, in a test build, the
    /// one `DRGNX_TEST_CLOUD_ENDPOINT_GCP` names).
    pub fn new(cfg: GcpCfg, creds: Arc<Resolver>) -> Result<Gcp, CloudError> {
        let compute = super::endpoint("GCP", "https://compute.googleapis.com/".into());
        let rm = super::endpoint("GCP", "https://cloudresourcemanager.googleapis.com/".into());
        let billing = super::endpoint("GCP", "https://cloudbilling.googleapis.com/".into());
        Gcp::at(cfg, creds, compute, rm, billing)
    }

    /// A client whose every endpoint is BASE: the mock.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn with_endpoint(cfg: GcpCfg, creds: Arc<Resolver>, base: &str) -> Result<Gcp, CloudError> {
        Gcp::at(cfg, creds, base.into(), base.into(), base.into())
    }

    fn at(
        cfg: GcpCfg,
        creds: Arc<Resolver>,
        compute: String,
        rm: String,
        billing: String,
    ) -> Result<Gcp, CloudError> {
        for u in [&compute, &rm, &billing] {
            super::checked_url(u)?;
        }
        if !gce_name(&cfg.zone) || !cfg.zone.contains('-') {
            return Err(CloudError::Other(format!(
                "the zone {:?} is not a GCE zone",
                cfg.zone
            )));
        }
        if !gce_name(&cfg.project) {
            return Err(CloudError::Other(format!(
                "the project {:?} is not a GCP project id",
                cfg.project
            )));
        }
        if !label_value(&cfg.hub_id) {
            return Err(CloudError::Other(format!(
                "the hub id {:?} is not a GCE label value (lower-case letters, digits, - and _)",
                cfg.hub_id
            )));
        }
        let http = bifrost::upstream::Upstream::new(Default::default())
            .map_err(|e| CloudError::Other(format!("the HTTPS client: {e}")))?;
        Ok(Gcp {
            cfg,
            compute,
            rm,
            billing,
            creds,
            token: Mutex::new(None),
            http,
        })
    }

    /// The hub id its machines are labelled with.
    pub fn hub_id(&self) -> &str {
        &self.cfg.hub_id
    }

    /// The zone's region (`us-central1-a` → `us-central1`): what the sweeper lists.
    pub fn region(&self) -> &str {
        self.cfg
            .zone
            .rsplit_once('-')
            .map_or(self.cfg.zone.as_str(), |r| r.0)
    }

    fn project_url(&self, rest: &str) -> String {
        format!(
            "{}compute/v1/projects/{}/{rest}",
            self.compute, self.cfg.project
        )
    }

    /// (zone, name) of a machine id `ZONE/NAME` (a bare name is in the client's zone).
    fn split<'a>(&'a self, id: &'a str) -> Result<(&'a str, &'a str), CloudError> {
        let (zone, name) = id.split_once('/').unwrap_or((self.cfg.zone.as_str(), id));
        if gce_name(zone) && gce_name(name) {
            Ok((zone, name))
        } else {
            Err(CloudError::Other(format!(
                "{id:?} is not a GCE machine (ZONE/NAME)"
            )))
        }
    }

    fn instance_url(&self, id: &str) -> Result<String, CloudError> {
        let (zone, name) = self.split(id)?;
        Ok(self.project_url(&format!("zones/{zone}/instances/{name}")))
    }

    /// `instances.insert`'s `requestId` and body for REQ at NOW: the deadline (NOW + the lifetime, deleted), the hub's
    /// label on the machine and its disk, the market, no service account, the SSH network tag, the user-data (its
    /// Ignition config). A name the conditional role would refuse (not `drgnx-…`) is refused here first.
    pub fn insert_request(
        &self,
        req: &StartReq,
        now: SystemTime,
    ) -> Result<(String, Value), CloudError> {
        if !req.name.starts_with("drgnx-") || !gce_name(&req.name) {
            return Err(CloudError::Other(format!(
                "the machine name {:?}: drgnx's GCP machines are named drgnx-… in lower-case letters, digits and -",
                req.name
            )));
        }
        if !gce_name(&req.size) {
            return Err(CloudError::Other(format!(
                "the machine type {:?}",
                req.size
            )));
        }
        let hub = &self.cfg.hub_id;
        let zone = &self.cfg.zone;
        let mut labels = serde_json::Map::new();
        labels.insert(HUB_TAG.into(), Value::String(hub.clone()));
        let labels = Value::Object(labels);
        let spot = req.market == Market::Spot;
        let mut scheduling = json!({
            "provisioningModel": if spot { "SPOT" } else { "STANDARD" },
            "instanceTerminationAction": "DELETE",
            "terminationTime": iso(now + self.cfg.lifetime),
            "automaticRestart": false,
            "onHostMaintenance": "TERMINATE",
        });
        if spot {
            scheduling["preemptionNoticeDuration"] = json!({"seconds": NOTICE_S.to_string()});
        }
        let body = json!({
            "name": req.name,
            "machineType": format!("zones/{zone}/machineTypes/{}", req.size),
            "labels": labels,
            "scheduling": scheduling,
            "disks": [{"boot": true, "autoDelete": true,
                       "initializeParams": {"sourceImage": req.image, "labels": labels}}],
            "networkInterfaces": [{"network": "global/networks/default",
                                   "accessConfigs": [{"type": "ONE_TO_ONE_NAT", "name": "External NAT"}]}],
            "tags": {"items": [group_name(hub)]},
            "metadata": {"items": [{"key": "user-data", "value": req.user_data}]},
            "serviceAccounts": [],
        });
        Ok((request_id(&req.token), body))
    }

    /// Machine ID's schedule as GCE reports it (the first start's check reads its deadline and action).
    pub fn scheduling<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Scheduling, CloudError>> {
        Box::pin(async move {
            let v = self.call("GET", &self.instance_url(id)?, None).await?;
            let s = &v["scheduling"];
            Ok(Scheduling {
                spot: s["provisioningModel"] == "SPOT",
                termination: s["terminationTime"].as_str().and_then(super::parse_time),
                action: s["instanceTerminationAction"]
                    .as_str()
                    .unwrap_or("")
                    .to_string(),
            })
        })
    }

    /// The bearer token, and whether it came from the cache.
    async fn token(&self) -> Result<(Arc<SecretString>, bool), CloudError> {
        let now = crate::clock::wall();
        if let Some(t) = lock(&self.token).as_ref()
            && t.until > now + Duration::from_secs(TOKEN_MARGIN_S)
        {
            return Ok((t.value.clone(), true));
        }
        let raw = self.creds.raw().await?;
        let text = std::str::from_utf8(&raw)
            .map_err(|_| CloudError::Other("the GCP credentials are not text".into()))?
            .trim();
        let (value, until) = if text.starts_with('{') {
            let sa = parse_service_account(text.as_bytes())?;
            self.exchange(&sa, now).await?
        } else if !text.is_empty() && text.bytes().all(|b| b.is_ascii_graphic()) {
            (
                SecretString::from(text.to_string()),
                now + Duration::from_secs(COMMAND_TOKEN_S),
            )
        } else {
            return Err(CloudError::Other(
                "the credential command printed something that is not one access token".into(),
            ));
        };
        let value = Arc::new(value);
        *lock(&self.token) = Some(Token {
            value: value.clone(),
            until,
        });
        Ok((value, false))
    }

    /// A service account's JWT traded at its `token_uri` for a token.
    async fn exchange(
        &self,
        sa: &ServiceAccount,
        now: SystemTime,
    ) -> Result<(SecretString, SystemTime), CloudError> {
        let jwt = Zeroizing::new(jwt_assertion(sa, now)?);
        let form = format!(
            "grant_type={}&assertion={}",
            pct("urn:ietf:params:oauth:grant-type:jwt-bearer"),
            pct(&jwt)
        );
        let (status, text) = self
            .send(
                "POST",
                &sa.token_uri,
                None,
                Some((form.into_bytes(), "application/x-www-form-urlencoded")),
            )
            .await?;
        let text = Zeroizing::new(text);
        if status != 200 {
            let v: Value = serde_json::from_str(&text).unwrap_or_default();
            let code = v["error"].as_str().unwrap_or("");
            let login = self.creds.login_command();
            return Err(
                if matches!(status, 400 | 401)
                    && matches!(
                        code,
                        "invalid_grant" | "invalid_client" | "unauthorized_client"
                    )
                {
                    CloudError::NeedsLogin(login)
                } else {
                    classify(
                        status,
                        code,
                        v["error_description"].as_str().unwrap_or(""),
                        &login,
                    )
                },
            );
        }
        #[derive(serde::Deserialize)]
        struct Answer {
            access_token: String,
            expires_in: Option<u64>,
        }
        let a: Answer = serde_json::from_str(&text).map_err(|_| {
            CloudError::Other("the token answer is not JSON with an access_token".into())
        })?;
        Ok((
            SecretString::from(a.access_token),
            now + Duration::from_secs(a.expires_in.unwrap_or(3600)),
        ))
    }

    /// One exchange: METHOD on URL, with TOKEN as the bearer and BODY (bytes and their content type); the status and
    /// the answer's text.
    async fn send(
        &self,
        method: &str,
        url: &str,
        token: Option<&SecretString>,
        body: Option<(Vec<u8>, &str)>,
    ) -> Result<(u16, String), CloudError> {
        let uri = super::checked_url(url)?;
        let host = uri
            .authority()
            .map(|a| a.as_str().to_string())
            .ok_or_else(|| CloudError::Other(format!("the endpoint {url:?} has no host")))?;
        let mut req = http::Request::builder()
            .method(method)
            .uri(uri)
            .header("host", host.as_str());
        if let Some(t) = token {
            let mut v = http::HeaderValue::from_str(&format!("Bearer {}", t.expose_secret()))
                .map_err(|_| CloudError::Other("the access token is not a header value".into()))?;
            v.set_sensitive(true);
            req = req.header("authorization", v);
        }
        let bytes = match body {
            Some((b, ty)) => {
                req = req.header("content-type", ty);
                b
            }
            None => Vec::new(),
        };
        let req = req
            .body(Full::new(Bytes::from(bytes)))
            .map_err(|e| CloudError::Other(format!("building the request: {e}")))?;
        let exchange = async {
            let resp = self
                .http
                .send(req)
                .await
                .map_err(|e| CloudError::Transient(e.to_string()))?;
            let status = resp.status().as_u16();
            let body = http_body_util::Limited::new(resp.into_body(), MAX_BODY)
                .collect()
                .await
                .map_err(|e| CloudError::Transient(format!("reading the answer: {e}")))?
                .to_bytes();
            Ok::<_, CloudError>((status, body))
        };
        let (status, body) = crate::clock::timeout(CALL_TIMEOUT, exchange)
            .await
            .map_err(|_| {
                CloudError::Transient(format!("no answer from GCP within {CALL_TIMEOUT:?}"))
            })??;
        Ok((status, String::from_utf8_lossy(&body).into_owned()))
    }

    /// One API call with a JSON BODY: the answer, or its error classified. A cached token the provider no longer takes
    /// gets one more try with a fresh one.
    async fn call(
        &self,
        method: &str,
        url: &str,
        body: Option<&Value>,
    ) -> Result<Value, CloudError> {
        let payload = body.map(|b| (b.to_string().into_bytes(), "application/json"));
        let (token, cached) = self.token().await?;
        let mut answer = self
            .send(method, url, Some(&*token), payload.clone())
            .await?;
        if answer.0 == 401 && cached {
            *lock(&self.token) = None;
            let (token, _) = self.token().await?;
            answer = self.send(method, url, Some(&*token), payload).await?;
        }
        let (status, text) = answer;
        if status == 200 {
            return serde_json::from_str(&text)
                .map_err(|_| CloudError::Other("an answer from GCP that is not JSON".into()));
        }
        let (reason, message) = error_of(&text);
        let e = classify(status, &reason, &message, &self.creds.login_command());
        if matches!(e, CloudError::NeedsLogin(_)) {
            *lock(&self.token) = None;
        }
        Err(e)
    }

    /// Waits for operation OP to be done; its error classified (GCE puts capacity and quota there).
    async fn finish(&self, mut op: Value) -> Result<Value, CloudError> {
        let started = crate::clock::now();
        while op["status"] != "DONE" {
            if started.elapsed() >= OPERATION_WAIT {
                return Err(CloudError::Transient(format!(
                    "the operation {} did not finish within {OPERATION_WAIT:?}",
                    op["name"]
                )));
            }
            crate::clock::sleep(Duration::from_secs(2)).await;
            let name = op["name"]
                .as_str()
                .filter(|n| gce_name(n))
                .ok_or_else(|| CloudError::Other("an operation with no name".into()))?
                .to_string();
            let path = match op["zone"].as_str() {
                Some(_) => format!("zones/{}/operations/{name}", last(&op["zone"])),
                None => format!("global/operations/{name}"),
            };
            op = self.call("GET", &self.project_url(&path), None).await?;
        }
        if let Some(e) = op["error"]["errors"].get(0) {
            return Err(op_error(e, &self.creds.login_command()));
        }
        Ok(op)
    }

    /// Every instance `instances.aggregatedList` gives with FILTER, through its pages.
    async fn aggregated(&self, filter: Option<&str>) -> Result<Vec<Value>, CloudError> {
        let mut out = Vec::new();
        let mut page: Option<String> = None;
        for _ in 0..MAX_PAGES {
            let mut q = Vec::new();
            if let Some(f) = filter {
                q.push(format!("filter={}", pct(f)));
            }
            if let Some(p) = &page {
                q.push(format!("pageToken={}", pct(p)));
            }
            let mut url = self.project_url("aggregated/instances");
            if !q.is_empty() {
                url = format!("{url}?{}", q.join("&"));
            }
            let v = self.call("GET", &url, None).await?;
            for scope in v["items"].as_object().into_iter().flat_map(|m| m.values()) {
                out.extend(scope["instances"].as_array().into_iter().flatten().cloned());
            }
            match v["nextPageToken"].as_str() {
                Some(t) if !t.is_empty() => page = Some(t.to_string()),
                _ => return Ok(out),
            }
        }
        Err(CloudError::Other(format!(
            "the instance list has more than {MAX_PAGES} pages"
        )))
    }

    /// The VMs in the project without a `drgnx-hub` label, as `ZONE/NAME`, sorted.
    async fn others(&self) -> Result<Vec<String>, CloudError> {
        let mut o: Vec<String> = self
            .aggregated(None)
            .await?
            .iter()
            .map(instance_info)
            .filter(|i| !i.tags.contains_key(HUB_TAG))
            .map(|i| i.id)
            .collect();
        o.sort();
        Ok(o)
    }

    /// The permissions of [`ROLE`] the credentials lack (`projects.testIamPermissions`).
    async fn missing_permissions(&self) -> Result<Vec<String>, CloudError> {
        let want = permissions();
        let url = format!(
            "{}v1/projects/{}:testIamPermissions",
            self.rm, self.cfg.project
        );
        let v = self
            .call("POST", &url, Some(&json!({"permissions": want})))
            .await?;
        let granted: Vec<&str> = v["permissions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        Ok(want
            .into_iter()
            .filter(|p| !granted.contains(&p.as_str()))
            .collect())
    }

    /// The SSH firewall rules: (their names, how many were missing). With MAKE the missing ones are made; one of ours
    /// that allows anything else is refused, never used.
    async fn firewalls(&self, make: bool) -> Result<(Vec<String>, usize), CloudError> {
        let (mut names, mut missing) = (Vec::new(), 0);
        for want in firewall_rules(&self.cfg.hub_id) {
            let name = want["name"].as_str().unwrap_or_default().to_string();
            let url = self.project_url(&format!("global/firewalls/{name}"));
            match self.call("GET", &url, None).await {
                Ok(have) => {
                    let same = ["direction", "allowed", "sourceRanges", "targetTags"]
                        .iter()
                        .all(|k| have[*k] == want[*k]);
                    if !same {
                        return Err(CloudError::Other(format!(
                            "the firewall rule {name} allows more than SSH in to drgnx's machines; drgnx uses it \
                             only as TCP 22 alone: delete it for drgnx to make it again"
                        )));
                    }
                }
                Err(e) if not_found(&e) => {
                    missing += 1;
                    if make {
                        let op = self
                            .call("POST", &self.project_url("global/firewalls"), Some(&want))
                            .await?;
                        self.finish(op).await?;
                    }
                }
                Err(e) => return Err(e),
            }
            names.push(name);
        }
        Ok((names, missing))
    }
}

/// The idempotency token as the UUID `requestId` GCE wants: the same token gives the same UUID, so every try of one
/// start is the same request.
pub fn request_id(token: &str) -> String {
    let d = Sha256::digest(token.as_bytes());
    let mut h = [0u8; 16];
    h.copy_from_slice(&d[..16]);
    // a name-based UUID: version 5's bits, RFC 4122's variant
    h[6] = (h[6] & 0x0f) | 0x50;
    h[8] = (h[8] & 0x3f) | 0x80;
    let x: String = h.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &x[..8],
        &x[8..12],
        &x[12..16],
        &x[16..20],
        &x[20..]
    )
}

/// The instance in a GCE answer.
fn instance_info(v: &Value) -> InstanceInfo {
    let zone = last(&v["zone"]).to_string();
    let name = v["name"].as_str().unwrap_or("");
    let state = match v["status"].as_str().unwrap_or("") {
        "PROVISIONING" | "STAGING" => InstanceState::Pending,
        "RUNNING" => InstanceState::Running,
        // a delete passes through STOPPING; a stop ends at TERMINATED, which the sweeper sees next
        "STOPPING" => InstanceState::Ending,
        "TERMINATED" | "SUSPENDING" | "SUSPENDED" => InstanceState::Stopped,
        s => InstanceState::Other(s.to_string()),
    };
    InstanceInfo {
        id: format!("{zone}/{name}"),
        state,
        address: v["networkInterfaces"][0]["accessConfigs"][0]["natIP"]
            .as_str()
            .filter(|a| !a.is_empty())
            .map(str::to_string),
        size: last(&v["machineType"]).to_string(),
        zone,
        spot: v["scheduling"]["provisioningModel"] == "SPOT",
        tags: v["labels"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, x)| (k.clone(), x.as_str().unwrap_or("").to_string()))
            .collect(),
        launched: v["creationTimestamp"].as_str().and_then(super::parse_time),
    }
}

/// An error answer's reason and message (`{"error": {"code", "message", "errors": [{"reason"}], "status"}}`).
pub fn error_of(body: &str) -> (String, String) {
    let v: Value = serde_json::from_str(body).unwrap_or_default();
    let e = &v["error"];
    let reason = e["errors"][0]["reason"]
        .as_str()
        .or(e["status"].as_str())
        .unwrap_or("")
        .to_string();
    (reason, e["message"].as_str().unwrap_or("").to_string())
}

/// No capacity for that machine there now, as GCE says it.
const CAPACITY: [&str; 3] = [
    "ZONE_RESOURCE_POOL_EXHAUSTED",
    "ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS",
    "RESOURCE_POOL_EXHAUSTED",
];

/// The error a status and a GCE REASON mean. A 401 is a login (LOGIN is the command the card names); no capacity is
/// [`CloudError::Capacity`]; a refusal is [`CloudError::Denied`]; throttling and 5xx are worth a retry.
pub fn classify(status: u16, reason: &str, message: &str, login: &str) -> CloudError {
    let what = if message.is_empty() {
        reason.to_string()
    } else {
        format!("{reason}: {message}")
    };
    if status == 401 {
        return CloudError::NeedsLogin(login.to_string());
    }
    if CAPACITY.contains(&reason) {
        return CloudError::Capacity(what);
    }
    if status == 429
        || status >= 500
        || matches!(
            reason,
            "rateLimitExceeded" | "userRateLimitExceeded" | "backendError"
        )
    {
        return CloudError::Transient(what);
    }
    if status == 403 && !matches!(reason, "QUOTA_EXCEEDED" | "quotaExceeded") {
        return CloudError::Denied(what);
    }
    CloudError::Other(what)
}

/// An operation's error (`error.errors[0]`).
fn op_error(e: &Value, login: &str) -> CloudError {
    classify(
        200,
        e["code"].as_str().unwrap_or(""),
        e["message"].as_str().unwrap_or(""),
        login,
    )
}

/// The two SSH rules: TCP 22 from anywhere, IPv4 and IPv6 (a GCE rule holds one family), to the hub's network tag.
fn firewall_rules(hub: &str) -> Vec<Value> {
    let tag = group_name(hub);
    [(tag.clone(), "0.0.0.0/0"), (format!("{tag}6"), "::/0")]
        .into_iter()
        .map(|(name, range)| {
            json!({
                "name": name, "description": format!("drgnx runners: SSH in (drgnx-hub={hub})"),
                "network": "global/networks/default", "direction": "INGRESS", "priority": 1000,
                "allowed": [{"IPProtocol": "tcp", "ports": ["22"]}], "sourceRanges": [range], "targetTags": [tag],
            })
        })
        .collect()
}

impl Provider for Gcp {
    fn preflight(&self) -> BoxFuture<'_, Vec<Check>> {
        Box::pin(async move {
            let mut checks = Vec::new();
            let mut check = |name, r: Result<String, CloudError>| {
                let (ok, detail) = match r {
                    Ok(d) => (true, d),
                    Err(e) => (false, e.to_string()),
                };
                checks.push(Check { name, ok, detail });
            };
            check(
                "credentials",
                self.token()
                    .await
                    .map(|_| "the credential source gave a token".to_string()),
            );
            check(
                "permissions",
                self.missing_permissions().await.and_then(|m| {
                    if m.is_empty() {
                        Ok(format!(
                            "the role grants all {} permissions",
                            permissions().len()
                        ))
                    } else {
                        Err(CloudError::Denied(format!(
                            "the role lacks {}",
                            m.join(", ")
                        )))
                    }
                }),
            );
            let base = format!(
                "{}compute/v1/projects/{IMAGE_PROJECT}/global/images/family/{IMAGE_FAMILY}",
                self.compute
            );
            check(
                "base image",
                self.call("GET", &base, None).await.map(|v| {
                    format!(
                        "{} ({IMAGE_PROJECT}, family {IMAGE_FAMILY})",
                        v["name"].as_str().unwrap_or("?")
                    )
                }),
            );
            check(
                "other machines",
                self.others().await.and_then(|o| {
                    if o.is_empty() {
                        Ok("none: the project is drgnx's own".into())
                    } else {
                        Err(CloudError::Other(others_warning(&self.cfg.project, &o)))
                    }
                }),
            );
            check(
                "firewall rules",
                self.firewalls(false).await.map(|(_, missing)| {
                    if missing == 0 {
                        "present, TCP 22 only".to_string()
                    } else {
                        "absent: drgnx makes them at the first start".to_string()
                    }
                }),
            );
            checks
        })
    }

    fn start<'a>(&'a self, req: &'a StartReq) -> BoxFuture<'a, Result<Instance, CloudError>> {
        Box::pin(async move {
            let (rid, body) = self.insert_request(req, crate::clock::wall())?;
            let url = format!(
                "{}?requestId={rid}",
                self.project_url(&format!("zones/{}/instances", self.cfg.zone))
            );
            let op = self.call("POST", &url, Some(&body)).await?;
            self.finish(op).await?;
            Ok(Instance {
                id: format!("{}/{}", self.cfg.zone, req.name),
                zone: self.cfg.zone.clone(),
            })
        })
    }

    fn describe<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<InstanceInfo, CloudError>> {
        Box::pin(async move {
            match self.call("GET", &self.instance_url(id)?, None).await {
                Ok(v) => Ok(instance_info(&v)),
                // GCE keeps no record of a deleted machine
                Err(e) if not_found(&e) => {
                    let (zone, name) = self.split(id)?;
                    Ok(InstanceInfo {
                        id: format!("{zone}/{name}"),
                        state: InstanceState::Gone,
                        address: None,
                        size: String::new(),
                        zone: zone.to_string(),
                        spot: false,
                        tags: BTreeMap::new(),
                        launched: None,
                    })
                }
                Err(e) => Err(e),
            }
        })
    }

    fn list_ours(&self) -> BoxFuture<'_, Result<Vec<InstanceInfo>, CloudError>> {
        Box::pin(async move {
            let filter = format!("labels.{HUB_TAG}=\"{}\"", self.cfg.hub_id);
            let region = format!("{}-", self.region());
            Ok(self
                .aggregated(Some(&filter))
                .await?
                .iter()
                .map(instance_info)
                .filter(|i| i.zone.starts_with(&region))
                .collect())
        })
    }

    fn end<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<(), CloudError>> {
        Box::pin(async move {
            match self.call("DELETE", &self.instance_url(id)?, None).await {
                Ok(op) => match op["error"]["errors"].get(0) {
                    Some(e) => Err(op_error(e, &self.creds.login_command())),
                    None => Ok(()),
                },
                // already gone: what an end wants
                Err(e) if not_found(&e) => Ok(()),
                Err(e) => Err(e),
            }
        })
    }

    fn console<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<String, CloudError>> {
        Box::pin(async move {
            let url = format!("{}/serialPort?port=1", self.instance_url(id)?);
            let v = self.call("GET", &url, None).await?;
            Ok(v["contents"].as_str().unwrap_or("").to_string())
        })
    }

    fn prices<'a>(&'a self, sizes: &'a [String]) -> BoxFuture<'a, Result<Prices, CloudError>> {
        Box::pin(async move {
            let region = self.region().to_string();
            let mut out: BTreeMap<String, Price> = BTreeMap::new();
            let mut page: Option<String> = None;
            for _ in 0..MAX_PAGES {
                let mut url = format!("{}v1/services/{COMPUTE_SERVICE}/skus", self.billing);
                if let Some(p) = &page {
                    url = format!("{url}?pageToken={}", pct(p));
                }
                let v = self.call("GET", &url, None).await?;
                for s in v["skus"].as_array().into_iter().flatten() {
                    let in_region = s["serviceRegions"]
                        .as_array()
                        .is_some_and(|r| r.iter().any(|x| *x == *region));
                    let desc = s["description"].as_str().unwrap_or("");
                    let Some(size) = sizes
                        .iter()
                        .find(|z| desc.split_whitespace().any(|w| w == z.as_str()))
                    else {
                        continue;
                    };
                    let Some(usd) = s["pricingInfo"][0]["pricingExpression"]["tieredRates"]
                        .as_array()
                        .and_then(|r| r.last())
                        .map(|t| {
                            let p = &t["unitPrice"];
                            let units = p["units"]
                                .as_str()
                                .and_then(|u| u.parse::<f64>().ok())
                                .or(p["units"].as_f64())
                                .unwrap_or(0.0);
                            units + p["nanos"].as_f64().unwrap_or(0.0) / 1e9
                        })
                    else {
                        continue;
                    };
                    if !in_region {
                        continue;
                    }
                    let e = out.entry(size.clone()).or_default();
                    match s["category"]["usageType"].as_str() {
                        Some("Preemptible") => e.spot = Some(usd),
                        Some("OnDemand") => e.on_demand = Some(usd),
                        _ => {}
                    }
                }
                match v["nextPageToken"].as_str() {
                    Some(t) if !t.is_empty() => page = Some(t.to_string()),
                    _ => return Ok(Prices(out)),
                }
            }
            Err(CloudError::Other(format!(
                "the price list has more than {MAX_PAGES} pages"
            )))
        })
    }
}

/// A service-account key (the keyring fallback), held in memory only: never `Debug`, `Clone` or `Serialize`.
pub struct ServiceAccount {
    pub client_email: String,
    pub key_id: String,
    /// The PKCS#8 PEM of its RSA key.
    pub private_key: SecretString,
    pub token_uri: String,
}

/// Reads a service-account JSON key (`{"type": "service_account", "client_email", "private_key_id", "private_key",
/// "token_uri", …}`). An error never quotes the key.
pub fn parse_service_account(json: &[u8]) -> Result<ServiceAccount, CloudError> {
    #[derive(serde::Deserialize)]
    struct Key {
        #[serde(rename = "type")]
        kind: String,
        client_email: String,
        private_key_id: Option<String>,
        private_key: String,
        token_uri: Option<String>,
    }
    let bad = |why: String| CloudError::Other(format!("the GCP key: {why}"));
    let k: Key = serde_json::from_slice(json).map_err(|e| {
        // the position only: serde's message can quote the input
        bad(format!(
            "not a service-account JSON key (line {}, column {})",
            e.line(),
            e.column()
        ))
    })?;
    if k.kind != "service_account" {
        return Err(bad(
            "only a service-account key (\"type\": \"service_account\") is taken".into(),
        ));
    }
    Ok(ServiceAccount {
        client_email: k.client_email,
        key_id: k.private_key_id.unwrap_or_default(),
        private_key: SecretString::from(k.private_key),
        token_uri: k.token_uri.unwrap_or_else(|| TOKEN_URI.into()),
    })
}

/// Base64url without padding (JWT's).
fn b64url(data: &[u8]) -> String {
    super::b64(data)
        .trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_")
}

/// The JWT (RS256, signed by `ring`) SA trades at its `token_uri` for an hour's token, issued at NOW.
pub fn jwt_assertion(sa: &ServiceAccount, now: SystemTime) -> Result<String, CloudError> {
    let secs = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let header = json!({"alg": "RS256", "typ": "JWT", "kid": sa.key_id});
    let claims = json!({
        "iss": sa.client_email, "scope": SCOPE, "aud": sa.token_uri, "iat": secs, "exp": secs + 3600,
    });
    let input = format!(
        "{}.{}",
        b64url(header.to_string().as_bytes()),
        b64url(claims.to_string().as_bytes())
    );
    let pem = sa.private_key.expose_secret();
    let body: Zeroizing<String> = Zeroizing::new(
        pem.lines()
            .map(str::trim)
            .filter(|l| !l.starts_with("-----"))
            .collect(),
    );
    let der = Zeroizing::new(
        super::b64_decode(&body)
            .ok_or_else(|| CloudError::Other("the GCP key's private key is not PEM".into()))?,
    );
    let key = ring::signature::RsaKeyPair::from_pkcs8(&der).map_err(|_| {
        CloudError::Other("the GCP key's private key is not an RSA PKCS#8 key".into())
    })?;
    let mut sig = vec![0u8; key.public().modulus_len()];
    key.sign(
        &ring::signature::RSA_PKCS1_SHA256,
        &ring::rand::SystemRandom::new(),
        input.as_bytes(),
        &mut sig,
    )
    .map_err(|_| CloudError::Other("signing the token request failed".into()))?;
    Ok(format!("{input}.{}", b64url(&sig)))
}

/// What `setup gcp` found in the project, and the commands that bind the role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Setup {
    /// The VMs drgnx did not start (no `drgnx-hub` label), `ZONE/NAME`.
    pub others: Vec<String>,
    /// With others: the warning, and the commands bind the role with [`condition`].
    pub warning: Option<String>,
    pub commands: Vec<String>,
}

fn others_warning(project: &str, others: &[String]) -> String {
    format!(
        "the project {project} holds {} VM(s) drgnx did not start ({}): use a project of drgnx's own, or bind the \
         role with the condition that limits it to instances named drgnx-…",
        others.len(),
        others.join(", ")
    )
}

/// `setup gcp`'s check (design §6.7.1): whether the project holds VMs drgnx did not start
/// (`instances.aggregatedList`), and the commands that create the role and bind it to MEMBER (`user:…` or
/// `serviceAccount:…`), with the condition when it does.
pub fn setup_check<'a>(gcp: &'a Gcp, member: &'a str) -> BoxFuture<'a, Result<Setup, CloudError>> {
    Box::pin(async move {
        let others = gcp.others().await?;
        let shared = !others.is_empty();
        Ok(Setup {
            warning: shared.then(|| others_warning(&gcp.cfg.project, &others)),
            commands: setup_commands(&gcp.cfg.project, member, shared),
            others,
        })
    })
}

/// The `gcloud` commands that create [`ROLE`] (saved as `drgnx-gcp-role.json`) in PROJECT and bind it to MEMBER: with
/// [`condition`] in a project SHARED with other VMs, else without one.
pub fn setup_commands(project: &str, member: &str, shared: bool) -> Vec<String> {
    let bind = format!(
        "gcloud projects add-iam-policy-binding {project} --member={member} --role=projects/{project}/roles/{ROLE_ID}"
    );
    vec![
        format!("gcloud iam roles create {ROLE_ID} --project={project} --file=drgnx-gcp-role.json"),
        if shared {
            format!(
                "{bind} --condition='expression={},title=drgnx machines only'",
                condition(project)
            )
        } else {
            format!("{bind} --condition=None")
        },
    ]
}

/// The IAM condition for a project shared with other VMs (design §6.7.1): the role reaches an instance only when it is
/// in PROJECT and named `drgnx-…`; its other resources (disks, images, firewall rules, operations) as without it. No
/// comma: `gcloud --condition` splits on them.
pub fn condition(project: &str) -> String {
    format!(
        "resource.type != \"compute.googleapis.com/Instance\" || resource.name.startsWith(\"projects/{project}/zones/\") \
         && resource.name.extract(\"/instances/{{name}}\").startsWith(\"drgnx-\")"
    )
}

/// The role's permissions, as [`ROLE`] lists them.
pub fn permissions() -> Vec<String> {
    let v: Value = serde_json::from_str(ROLE).expect("the role fixture is JSON");
    v["includedPermissions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p.as_str().map(str::to_string))
        .collect()
}

/// This hub's SSH firewall rules (`drgnx-<hub id>-ssh` and `…-ssh6`: TCP 22 from anywhere, IPv4 and IPv6, to the
/// machines with that network tag, the hub id in their description), made when missing: their names. One of ours that
/// allows anything else is refused, never used.
pub fn ensure_firewall(gcp: &Gcp) -> BoxFuture<'_, Result<Vec<String>, CloudError>> {
    Box::pin(async move { Ok(gcp.firewalls(true).await?.0) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::cloud::creds::Source;
    use crate::runners::cloud::sweep::{Bounds, Ended, Pass, Sweeper};
    use crate::runners::cloud::testmock::{HUB, Mock};
    use forseti::cost::CapState;

    /// The mock's clock at its start (2026-11-06T00:00:00Z).
    const T0: u64 = 1_793_923_200;

    fn cfg() -> GcpCfg {
        GcpCfg {
            project: "p1".into(),
            zone: "us-central1-a".into(),
            hub_id: "hub-1".into(),
            lifetime: Duration::from_secs(8 * 3600),
        }
    }

    fn req(token: &str, name: &str, market: Market) -> StartReq {
        StartReq {
            token: token.into(),
            name: name.into(),
            size: "n2-standard-4".into(),
            image: "projects/fedora-coreos-cloud/global/images/family/fedora-coreos-stable".into(),
            market,
            user_data: "{\"ignition\":{\"version\":\"3.4.0\"}}".into(),
            security_group: None,
        }
    }

    // [D] pure
    #[test]
    fn insert_always_has_deadline_delete_and_request_id() {
        let creds = Arc::new(Resolver::new(Source::Command(vec!["true".into()]), None));
        let gcp = Gcp::with_endpoint(cfg(), creds, "http://127.0.0.1:9/").unwrap();
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(T0);
        for market in [Market::Spot, Market::OnDemand] {
            let (rid, b) = gcp
                .insert_request(&req("tok-1", "drgnx-c1", market), now)
                .unwrap();
            // a UUID, the same for every try of one start, another for another start
            let parts: Vec<usize> = rid.split('-').map(str::len).collect();
            assert_eq!(parts, [8, 4, 4, 4, 12], "{rid}");
            assert!(
                rid.bytes().all(|c| c == b'-' || c.is_ascii_hexdigit()),
                "{rid}"
            );
            assert_eq!(rid, request_id("tok-1"));
            assert_ne!(rid, request_id("tok-2"));
            let s = &b["scheduling"];
            assert_eq!(s["instanceTerminationAction"], "DELETE");
            assert_eq!(
                s["terminationTime"], "2026-11-06T08:00:00Z",
                "creation + lifetime"
            );
            assert_eq!(s["automaticRestart"], false);
            assert_eq!(s["onHostMaintenance"], "TERMINATE");
            match market {
                Market::Spot => {
                    assert_eq!(s["provisioningModel"], "SPOT");
                    assert_eq!(s["preemptionNoticeDuration"]["seconds"], "120");
                }
                Market::OnDemand => assert_eq!(s["provisioningModel"], "STANDARD"),
            }
            assert_eq!(b["name"], "drgnx-c1");
            assert_eq!(b["labels"][HUB_TAG], "hub-1");
            assert_eq!(
                b["machineType"],
                "zones/us-central1-a/machineTypes/n2-standard-4"
            );
            let disk = &b["disks"][0];
            assert_eq!(disk["autoDelete"], true);
            assert_eq!(disk["initializeParams"]["labels"][HUB_TAG], "hub-1");
            assert_eq!(
                disk["initializeParams"]["sourceImage"],
                "projects/fedora-coreos-cloud/global/images/family/fedora-coreos-stable"
            );
            assert_eq!(
                b["serviceAccounts"],
                json!([]),
                "machines get no service account"
            );
            assert_eq!(
                b["metadata"]["items"],
                json!([{"key": "user-data", "value": "{\"ignition\":{\"version\":\"3.4.0\"}}"}])
            );
            assert_eq!(b["tags"]["items"], json!(["drgnx-hub-1-ssh"]));
            assert_eq!(
                b["networkInterfaces"][0]["accessConfigs"][0]["type"],
                "ONE_TO_ONE_NAT"
            );
        }
        // a name the conditional role would refuse is refused here first
        assert!(
            gcp.insert_request(&req("tok-3", "web-1", Market::Spot), now)
                .is_err()
        );
    }

    /// A service-account key made for the test (ssh-keygen writes PKCS#8), as Google's JSON holds it.
    fn test_service_account() -> (ServiceAccount, Vec<u8>) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("k");
        let ok = std::process::Command::new("ssh-keygen")
            .args([
                "-q", "-t", "rsa", "-b", "2048", "-m", "PKCS8", "-N", "", "-f",
            ])
            .arg(&path)
            .stdin(std::process::Stdio::null())
            .status()
            .unwrap()
            .success();
        assert!(ok, "ssh-keygen made no key");
        let pem = std::fs::read_to_string(&path).unwrap();
        let json = json!({
            "type": "service_account", "project_id": "p1", "private_key_id": "k1", "private_key": pem,
            "client_email": "drgnx@p1.iam.gserviceaccount.com", "token_uri": "https://oauth2.googleapis.com/token",
        });
        let der = super::super::b64_decode(
            &pem.lines()
                .filter(|l| !l.starts_with("-----"))
                .collect::<String>(),
        )
        .unwrap();
        (
            parse_service_account(json.to_string().as_bytes()).unwrap(),
            der,
        )
    }

    fn b64url_decode(s: &str) -> Vec<u8> {
        super::super::b64_decode(&s.replace('-', "+").replace('_', "/")).unwrap()
    }

    // [D] pure (a real ssh-keygen makes the key; no timing)
    #[test]
    fn jwt_fallback_signs_with_ring() {
        let (sa, der) = test_service_account();
        assert_eq!(sa.client_email, "drgnx@p1.iam.gserviceaccount.com");
        assert_eq!(sa.key_id, "k1");
        assert!(sa.private_key.expose_secret().contains("PRIVATE KEY"));
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(T0);
        let jwt = jwt_assertion(&sa, now).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3, "{jwt}");
        assert!(
            !jwt.contains('=') && !jwt.contains('+') && !jwt.contains('/'),
            "base64url, no padding"
        );
        let header: Value = serde_json::from_slice(&b64url_decode(parts[0])).unwrap();
        assert_eq!(header, json!({"alg": "RS256", "typ": "JWT", "kid": "k1"}));
        let claims: Value = serde_json::from_slice(&b64url_decode(parts[1])).unwrap();
        assert_eq!(claims["iss"], "drgnx@p1.iam.gserviceaccount.com");
        assert_eq!(claims["aud"], "https://oauth2.googleapis.com/token");
        assert_eq!(
            claims["scope"],
            "https://www.googleapis.com/auth/cloud-platform"
        );
        assert_eq!(claims["iat"], T0);
        assert_eq!(claims["exp"], T0 + 3600);
        // the signature is RS256 by the key's own public half (ring verifies it), over exactly header.claims
        let kp = ring::signature::RsaKeyPair::from_pkcs8(&der).unwrap();
        let public = ring::signature::UnparsedPublicKey::new(
            &ring::signature::RSA_PKCS1_2048_8192_SHA256,
            kp.public().as_ref(),
        );
        let input = format!("{}.{}", parts[0], parts[1]);
        let sig = b64url_decode(parts[2]);
        assert!(public.verify(input.as_bytes(), &sig).is_ok());
        assert!(public.verify(b"another.input", &sig).is_err());
        // a key that is not a service account's is refused without quoting it
        let bad = parse_service_account(
            br#"{"type": "authorized_user", "refresh_token": "leaked-value"}"#,
        )
        .err()
        .unwrap();
        assert!(!bad.to_string().contains("leaked-value"), "{bad}");
    }

    /// The mock's GCE instance id (a number) for NAME: what its knobs take.
    async fn numeric_id(m: &Mock, name: &str) -> String {
        let r = m.resources().await;
        r["instances"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["name"] == name && i["provider"] == "gcp")
            .and_then(|i| i["id"].as_str())
            .unwrap_or_else(|| panic!("no instance {name}: {r}"))
            .to_string()
    }

    fn done(p: Pass) -> Vec<(String, Ended)> {
        match p {
            Pass::Done(w) => w.ended,
            other => panic!("not a pass: {other:?}"),
        }
    }

    // [B] the mock's virtual clock and the sweeper's NOW values
    #[tokio::test]
    async fn a_stopped_vm_is_deleted_by_the_sweeper() {
        let m = Mock::start();
        let gcp = m.gcp();
        let a = gcp
            .start(&req("tok-a", "drgnx-a", Market::OnDemand))
            .await
            .unwrap();
        let b = gcp
            .start(&req("tok-b", "drgnx-b", Market::Spot))
            .await
            .unwrap();
        let c = gcp
            .start(&req("tok-c", "drgnx-c", Market::Spot))
            .await
            .unwrap();
        assert_eq!(a.id, "us-central1-a/drgnx-a");
        assert_eq!(
            gcp.describe(&a.id).await.unwrap().state,
            InstanceState::Running
        );
        // a power-off inside the guest stops a GCE VM: its disk bills on and its deadline is cleared (H6)
        m.knob("poweroff", json!({"id": numeric_id(&m, "drgnx-a").await}))
            .await;
        assert_eq!(
            gcp.describe(&a.id).await.unwrap().state,
            InstanceState::Stopped
        );
        let bounds = Bounds {
            lifetime_s: 8 * 3600,
            unreachable_s: 300,
        };
        let mut s = Sweeper::new(HUB, bounds).with_idle(900);
        // b's watchdog reported it idle (through `serve`); c is busy
        s.idle_since(&b.id, Some(T0));
        let all = |_: &str| true;
        assert_eq!(
            done(s.pass(&gcp, T0 + 10, &all, CapState::Under).await),
            [(a.id.clone(), Ended::Stopped)],
            "a stopped VM is deleted, whoever stopped it"
        );
        assert!(done(s.pass(&gcp, T0 + 899, &all, CapState::Under).await).is_empty());
        assert_eq!(
            done(s.pass(&gcp, T0 + 900, &all, CapState::Under).await),
            [(b.id.clone(), Ended::Idle)],
            "on GCP the idle stop is the hub's delete"
        );
        for gone in [&a.id, &b.id] {
            assert_eq!(gcp.describe(gone).await.unwrap().state, InstanceState::Gone);
        }
        let left: Vec<String> = gcp
            .list_ours()
            .await
            .unwrap()
            .into_iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(left, std::slice::from_ref(&c.id));
        // deleting one already gone is what an end wants
        gcp.end(&a.id).await.unwrap();
    }

    // [B] the mock's virtual clock: the deadline passes when the test moves it, with no hub running
    #[tokio::test]
    async fn the_deadline_deletes_with_the_hub_down() {
        let m = Mock::start();
        let (id, deadline) = {
            let gcp = m.gcp();
            let rules = ensure_firewall(&gcp).await.unwrap();
            assert_eq!(rules, ["drgnx-hub-1-ssh", "drgnx-hub-1-ssh6"]);
            assert_eq!(
                ensure_firewall(&gcp).await.unwrap(),
                rules,
                "found again, not made twice"
            );
            let started = gcp
                .start(&req("tok-d", "drgnx-d", Market::Spot))
                .await
                .unwrap();
            // a retry after a crash returns the same machine
            let again = m
                .gcp()
                .start(&req("tok-d", "drgnx-d", Market::Spot))
                .await
                .unwrap();
            assert_eq!(again, started);
            let sch = gcp.scheduling(&started.id).await.unwrap();
            assert!(sch.spot);
            assert_eq!(sch.action, "DELETE");
            let deadline = sch.termination.expect("every GCP machine has a deadline");
            let info = gcp.describe(&started.id).await.unwrap();
            assert_eq!(info.state, InstanceState::Running);
            assert_eq!(info.tags.get(HUB_TAG).map(String::as_str), Some(HUB));
            assert!(info.address.is_some());
            assert!(
                gcp.console(&started.id)
                    .await
                    .unwrap()
                    .contains("BEGIN SSH HOST KEY FINGERPRINTS")
            );
            let p = gcp.prices(&["n2-standard-4".into()]).await.unwrap();
            let p = p.0["n2-standard-4"];
            assert!(p.spot.is_some() && p.on_demand.is_some(), "{p:?}");
            (
                started.id,
                deadline
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_secs(),
            )
        };
        // the hub is gone: nothing of drgnx's runs, only the provider's clock
        m.knob("clock", json!({"set": deadline - 1})).await;
        assert_eq!(
            m.gcp().describe(&id).await.unwrap().state,
            InstanceState::Running
        );
        m.knob("clock", json!({"set": deadline})).await;
        let back = m.gcp();
        assert_eq!(back.describe(&id).await.unwrap().state, InstanceState::Gone);
        assert!(back.list_ours().await.unwrap().is_empty());
        // and the firewall rules carry the hub id, TCP 22 only
        let r = m.resources().await;
        let fw: Vec<&Value> = r["resources"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|x| x["kind"] == "firewall")
            .collect();
        assert_eq!(fw.len(), 2, "{r}");
        for f in fw {
            assert_eq!(
                f["data"]["allowed"],
                json!([{"IPProtocol": "tcp", "ports": ["22"]}])
            );
            assert_eq!(f["data"]["targetTags"], json!(["drgnx-hub-1-ssh"]));
            assert!(
                f["data"]["description"]
                    .as_str()
                    .unwrap()
                    .contains("drgnx-hub=hub-1")
            );
        }
        assert_eq!(
            r["unknown_requests"],
            json!([]),
            "every call is one the mock knows"
        );
        // an expired token is a login, never a retry
        m.knob("expire", json!({})).await;
        assert!(matches!(
            back.describe(&id).await,
            Err(CloudError::NeedsLogin(_))
        ));
    }

    // [B]
    #[tokio::test]
    async fn a_shared_project_gets_the_conditional_role_warning() {
        let m = Mock::start();
        let gcp = m.gcp();
        let member = "user:me@example.org";
        gcp.start(&req("tok-s", "drgnx-s", Market::Spot))
            .await
            .unwrap();
        // a project of drgnx's own (its machines only): the plain binding
        let s = setup_check(&gcp, member).await.unwrap();
        assert!(s.others.is_empty() && s.warning.is_none(), "{s:?}");
        assert!(
            s.commands
                .iter()
                .any(|c| c.contains("add-iam-policy-binding p1") && c.contains("--condition=None")),
            "{s:?}"
        );
        assert!(
            s.commands
                .iter()
                .any(|c| c.contains("gcloud iam roles create drgnxRunner --project=p1")),
            "{s:?}"
        );
        // a VM drgnx did not start: a warning, and the role bound only to instances named drgnx-
        m.knob(
            "seed",
            json!({"provider": "gcp", "id": "web-1", "tags": {}}),
        )
        .await;
        let s = setup_check(&gcp, member).await.unwrap();
        assert_eq!(s.others, ["us-central1-a/web-1"]);
        let w = s.warning.clone().unwrap();
        assert!(w.contains("web-1") && w.contains("condition"), "{w}");
        let bind = s
            .commands
            .iter()
            .find(|c| c.contains("add-iam-policy-binding"))
            .unwrap();
        assert!(bind.contains(&condition("p1")), "{bind}");
        assert!(bind.contains(member), "{bind}");
        let cond = condition("p1");
        assert!(
            cond.contains("resource.name.startsWith(\"projects/p1/zones/\")"),
            "{cond}"
        );
        assert!(
            cond.contains("resource.name.extract(\"/instances/{name}\").startsWith(\"drgnx-\")"),
            "{cond}"
        );
        assert!(
            !cond.contains(','),
            "gcloud's --condition splits on commas: {cond}"
        );
        assert!(
            cond.contains("resource.type != \"compute.googleapis.com/Instance\""),
            "{cond}"
        );
        // the role: what drgnx calls, and never a stop, a service account or IAM
        let p = permissions();
        for want in [
            "compute.instances.create",
            "compute.instances.delete",
            "compute.instances.get",
            "compute.instances.list",
            "compute.instances.getSerialPortOutput",
            "compute.firewalls.create",
            "compute.images.getFromFamily",
            "compute.zoneOperations.get",
        ] {
            assert!(p.iter().any(|x| x == want), "{want} in the role");
        }
        for never in [
            "compute.instances.stop",
            "compute.instances.setServiceAccount",
            "iam.serviceAccounts.actAs",
        ] {
            assert!(!p.iter().any(|x| x == never), "{never} is not in the role");
        }
        assert!(!p.iter().any(|x| x.contains("setIamPolicy")), "{p:?}");
        // the pre-flight tests every one of them, and names a missing one and the other VM
        m.knob(
            "deny-permissions",
            json!({"permissions": ["compute.instances.delete"]}),
        )
        .await;
        let checks = gcp.preflight().await;
        let line = |n: &str| {
            checks
                .iter()
                .find(|c| c.name == n)
                .unwrap_or_else(|| panic!("no {n}: {checks:?}"))
        };
        assert!(line("credentials").ok, "{checks:?}");
        assert!(line("base image").ok, "{checks:?}");
        let perm = line("permissions");
        assert!(
            !perm.ok && perm.detail.contains("compute.instances.delete"),
            "{perm:?}"
        );
        let other = line("other machines");
        assert!(!other.ok && other.detail.contains("web-1"), "{other:?}");
        assert!(line("firewall rules").ok, "{checks:?}");
    }
}
