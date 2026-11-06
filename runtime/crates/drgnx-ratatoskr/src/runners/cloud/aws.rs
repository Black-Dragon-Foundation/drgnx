//! AWS (design §6.7.1): EC2's Query API, STS `GetCallerIdentity` and the Pricing API's `GetProducts`, signed with
//! `aws-sigv4` and sent through bifrost's HTTP/1.1 client; EC2's XML answers read with `quick-xml`.
//!
//! Every `RunInstances` carries the start's `ClientToken` (a retry returns the same machine), the `drgnx-hub=<hub id>`
//! tags on the instance, its volumes and its network interface, `InstanceInitiatedShutdownBehavior=terminate` (a
//! power-off ends it, so the watchdog's `poweroff` stops the bill), metadata tokens required with a hop limit of 1,
//! and the hub's security group. The policy the user creates for the role is [`POLICY`]
//! (`drgnx runner cloud setup aws` prints it); drgnx never creates IAM itself.

use super::creds::{AwsCredentials, Resolver};
use super::{
    CALL_TIMEOUT, Check, CloudError, Instance, InstanceInfo, InstanceState, MAX_BODY, Market,
    Price, Prices, Provider, StartReq,
};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use mimir::BoxFuture;
use secrecy::ExposeSecret;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::SystemTime;

/// The IAM policy fixture, one statement per resource type (design §6.7.1, M4). `DRGNX_HUB_ID`, `DRGNX_REGION` and
/// `DRGNX_SIZE` are filled in by [`policy_for`].
pub const POLICY: &str = include_str!("aws-policy.json");

/// The EC2 API version every Query request names.
const EC2_VERSION: &str = "2016-11-15";

/// The tag that marks a resource as this hub's.
pub const HUB_TAG: &str = "drgnx-hub";

/// The states a machine of ours can be in before it is gone.
const LIVE_STATES: [&str; 5] = ["pending", "running", "shutting-down", "stopping", "stopped"];

/// What the client needs to know.
pub struct AwsCfg {
    pub region: String,
    pub hub_id: String,
    /// What the pre-flight's `RunInstances` `DryRun` asks for (the setup's size and image), if known yet.
    pub probe: Option<StartReq>,
}

/// AWS, for one region.
pub struct Aws {
    cfg: AwsCfg,
    ec2: String,
    sts: String,
    pricing: String,
    creds: Arc<Resolver>,
    http: bifrost::upstream::Upstream,
}

impl Aws {
    /// A client for CFG's region with credentials from CREDS, at AWS's own endpoints (or, in a test build, the ones
    /// `DRGNX_TEST_CLOUD_ENDPOINT_AWS` names).
    pub fn new(cfg: AwsCfg, creds: Arc<Resolver>) -> Result<Aws, CloudError> {
        let r = &cfg.region;
        let ec2 = super::endpoint("AWS", format!("https://ec2.{r}.amazonaws.com/"));
        let sts = super::endpoint("AWS", format!("https://sts.{r}.amazonaws.com/"));
        let pricing = super::endpoint("AWS", "https://api.pricing.us-east-1.amazonaws.com/".into());
        Aws::at(cfg, creds, ec2, sts, pricing)
    }

    /// A client whose every endpoint is BASE: the mock.
    #[cfg(any(test, feature = "test-hooks"))]
    pub fn with_endpoint(cfg: AwsCfg, creds: Arc<Resolver>, base: &str) -> Result<Aws, CloudError> {
        Aws::at(cfg, creds, base.into(), base.into(), base.into())
    }

    fn at(
        cfg: AwsCfg,
        creds: Arc<Resolver>,
        ec2: String,
        sts: String,
        pricing: String,
    ) -> Result<Aws, CloudError> {
        for u in [&ec2, &sts, &pricing] {
            super::checked_url(u)?;
        }
        let http = bifrost::upstream::Upstream::new(Default::default())
            .map_err(|e| CloudError::Other(format!("the HTTPS client: {e}")))?;
        Ok(Aws {
            cfg,
            ec2,
            sts,
            pricing,
            creds,
            http,
        })
    }

    /// The `RunInstances` parameters for REQ: always the token, the hub's tags, terminate at power-off, metadata
    /// tokens required with hop limit 1, the security group when there is one.
    pub fn run_params(&self, req: &StartReq) -> Vec<(String, String)> {
        let mut p: Vec<(String, String)> = [
            ("ImageId", req.image.as_str()),
            ("InstanceType", req.size.as_str()),
            ("MinCount", "1"),
            ("MaxCount", "1"),
            ("ClientToken", req.token.as_str()),
            ("InstanceInitiatedShutdownBehavior", "terminate"),
            ("MetadataOptions.HttpTokens", "required"),
            ("MetadataOptions.HttpPutResponseHopLimit", "1"),
            ("MetadataOptions.HttpEndpoint", "enabled"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        for (n, ty) in ["instance", "volume", "network-interface"]
            .into_iter()
            .enumerate()
        {
            let s = format!("TagSpecification.{}", n + 1);
            p.push((format!("{s}.ResourceType"), ty.into()));
            p.push((format!("{s}.Tag.1.Key"), HUB_TAG.into()));
            p.push((format!("{s}.Tag.1.Value"), self.cfg.hub_id.clone()));
            p.push((format!("{s}.Tag.2.Key"), "Name".into()));
            p.push((format!("{s}.Tag.2.Value"), req.name.clone()));
        }
        if let Some(sg) = &req.security_group {
            p.push(("SecurityGroupId.1".into(), sg.clone()));
        }
        if req.market == Market::Spot {
            p.push(("InstanceMarketOptions.MarketType".into(), "spot".into()));
            p.push((
                "InstanceMarketOptions.SpotOptions.SpotInstanceType".into(),
                "one-time".into(),
            ));
            p.push((
                "InstanceMarketOptions.SpotOptions.InstanceInterruptionBehavior".into(),
                "terminate".into(),
            ));
        }
        if !req.user_data.is_empty() {
            p.push(("UserData".into(), super::b64(req.user_data.as_bytes())));
        }
        p
    }

    /// The hub id its machines are tagged with.
    pub fn hub_id(&self) -> &str {
        &self.cfg.hub_id
    }

    /// One EC2 Query call: ACTION with PARAMS, its answer's root element.
    pub(crate) async fn ec2(
        &self,
        action: &str,
        params: Vec<(String, String)>,
    ) -> Result<El, CloudError> {
        let mut form = vec![
            ("Action".to_string(), action.to_string()),
            ("Version".to_string(), EC2_VERSION.to_string()),
        ];
        form.extend(params);
        let body = form_body(&form);
        let text = self
            .send(
                &self.ec2,
                "ec2",
                &self.cfg.region,
                body.into_bytes(),
                &[("content-type", FORM)],
            )
            .await?;
        El::parse(&text)
    }

    /// POST BODY to URL as SERVICE in REGION, signed; the answer's text when it is a 200, else its error classified.
    async fn send(
        &self,
        url: &str,
        service: &str,
        region: &str,
        body: Vec<u8>,
        extra: &[(&str, &str)],
    ) -> Result<String, CloudError> {
        let creds = self.creds.aws().await?;
        let uri = super::checked_url(url)?;
        let host = uri
            .authority()
            .map(|a| a.as_str().to_string())
            .ok_or_else(|| CloudError::Other(format!("the endpoint {url:?} has no host")))?;
        let mut headers: Vec<(&str, &str)> = vec![("host", host.as_str())];
        headers.extend_from_slice(extra);
        let signed = sign(
            "POST",
            url,
            &headers,
            &body,
            &creds,
            region,
            service,
            crate::clock::wall(),
        )?;
        let mut req = http::Request::post(uri);
        for (k, v) in headers.iter() {
            req = req.header(*k, *v);
        }
        for (k, v) in &signed {
            req = req.header(*k, v.as_str());
        }
        let req = req
            .body(Full::new(Bytes::from(body)))
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
                CloudError::Transient(format!("no answer from {service} within {CALL_TIMEOUT:?}"))
            })??;
        let text = String::from_utf8_lossy(&body).into_owned();
        if status == 200 {
            return Ok(text);
        }
        let (code, message) = error_of(&text);
        let e = classify(status, &code, &message, &self.creds.login_command());
        if matches!(e, CloudError::NeedsLogin(_)) {
            self.creds.forget();
        }
        Err(e)
    }

    async fn instances(
        &self,
        params: Vec<(String, String)>,
    ) -> Result<Vec<InstanceInfo>, CloudError> {
        let root = self.ec2("DescribeInstances", params).await?;
        Ok(root
            .find_all("reservationSet/item/instancesSet/item")
            .into_iter()
            .map(instance_info)
            .collect())
    }

    async fn caller(&self) -> Result<String, CloudError> {
        let body = form_body(&[
            ("Action".into(), "GetCallerIdentity".into()),
            ("Version".into(), "2011-06-15".into()),
        ]);
        let text = self
            .send(
                &self.sts,
                "sts",
                &self.cfg.region,
                body.into_bytes(),
                &[("content-type", FORM)],
            )
            .await?;
        let root = El::parse(&text)?;
        Ok(root
            .text_at("GetCallerIdentityResult/Arn")
            .unwrap_or_default()
            .to_string())
    }

    async fn on_demand(&self, sizes: &[String]) -> Result<BTreeMap<String, f64>, CloudError> {
        let mut out = BTreeMap::new();
        for size in sizes {
            let filters: Vec<serde_json::Value> = [
                ("instanceType", size.as_str()),
                ("regionCode", self.cfg.region.as_str()),
                ("operatingSystem", "Linux"),
                ("tenancy", "Shared"),
                ("preInstalledSw", "NA"),
                ("capacitystatus", "Used"),
            ]
            .into_iter()
            .map(|(f, v)| serde_json::json!({"Type": "TERM_MATCH", "Field": f, "Value": v}))
            .collect();
            let body = serde_json::json!({"ServiceCode": "AmazonEC2", "Filters": filters, "MaxResults": 10});
            let text = self
                .send(
                    &self.pricing,
                    "pricing",
                    "us-east-1",
                    body.to_string().into_bytes(),
                    &[
                        ("content-type", "application/x-amz-json-1.1"),
                        ("x-amz-target", "AWSPriceListService.GetProducts"),
                    ],
                )
                .await?;
            let v: serde_json::Value = serde_json::from_str(&text)
                .map_err(|e| CloudError::Other(format!("the price list: {e}")))?;
            for item in v["PriceList"].as_array().into_iter().flatten() {
                let p: serde_json::Value = match item.as_str() {
                    Some(s) => serde_json::from_str(s).unwrap_or_default(),
                    None => item.clone(),
                };
                let usd = p["terms"]["OnDemand"]
                    .as_object()
                    .into_iter()
                    .flat_map(|t| t.values())
                    .flat_map(|t| {
                        t["priceDimensions"]
                            .as_object()
                            .into_iter()
                            .flat_map(|d| d.values())
                    })
                    .filter_map(|d| d["pricePerUnit"]["USD"].as_str()?.parse::<f64>().ok())
                    .find(|p| *p > 0.0);
                if let Some(usd) = usd {
                    out.insert(size.clone(), usd);
                }
            }
        }
        Ok(out)
    }
}

impl Provider for Aws {
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
                self.caller().await.map(|arn| format!("signed in as {arn}")),
            );
            check(
                "list machines",
                self.list_ours()
                    .await
                    .map(|v| format!("{} of this hub's machines running", v.len())),
            );
            if let Some(probe) = &self.cfg.probe {
                let mut p = self.run_params(probe);
                p.push(("DryRun".into(), "true".into()));
                let r = match self.ec2("RunInstances", p).await {
                    Err(CloudError::Other(m)) if m.starts_with("DryRunOperation") => {
                        Ok("the role may start a tagged machine".to_string())
                    }
                    Ok(_) => Err(CloudError::Other(
                        "a DryRun started nothing but answered success".into(),
                    )),
                    Err(e) => Err(e),
                };
                check("start a machine (dry run)", r);
            }
            checks
        })
    }

    fn start<'a>(&'a self, req: &'a StartReq) -> BoxFuture<'a, Result<Instance, CloudError>> {
        Box::pin(async move {
            let root = self.ec2("RunInstances", self.run_params(req)).await?;
            let item = root
                .find("instancesSet/item")
                .ok_or_else(|| CloudError::Other("RunInstances answered no instance".into()))?;
            Ok(Instance {
                id: item.text_at("instanceId").unwrap_or_default().to_string(),
                zone: item
                    .text_at("placement/availabilityZone")
                    .unwrap_or_default()
                    .to_string(),
            })
        })
    }

    fn describe<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<InstanceInfo, CloudError>> {
        Box::pin(async move {
            let found = self
                .instances(vec![("InstanceId.1".into(), id.into())])
                .await?;
            found
                .into_iter()
                .find(|i| i.id == id)
                .ok_or_else(|| CloudError::Transient(format!("{id} is not listed yet")))
        })
    }

    fn list_ours(&self) -> BoxFuture<'_, Result<Vec<InstanceInfo>, CloudError>> {
        Box::pin(async move {
            let mut p = vec![
                ("Filter.1.Name".to_string(), format!("tag:{HUB_TAG}")),
                ("Filter.1.Value.1".to_string(), self.cfg.hub_id.clone()),
                (
                    "Filter.2.Name".to_string(),
                    "instance-state-name".to_string(),
                ),
            ];
            for (n, s) in LIVE_STATES.iter().enumerate() {
                p.push((format!("Filter.2.Value.{}", n + 1), s.to_string()));
            }
            self.instances(p).await
        })
    }

    fn end<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<(), CloudError>> {
        Box::pin(async move {
            match self
                .ec2(
                    "TerminateInstances",
                    vec![("InstanceId.1".into(), id.into())],
                )
                .await
            {
                Ok(_) => Ok(()),
                // already gone: what an end wants
                Err(CloudError::Transient(m)) if m.starts_with("InvalidInstanceID.NotFound") => {
                    Ok(())
                }
                Err(e) => Err(e),
            }
        })
    }

    fn console<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<String, CloudError>> {
        Box::pin(async move {
            let root = self
                .ec2(
                    "GetConsoleOutput",
                    vec![
                        ("InstanceId".into(), id.into()),
                        ("Latest".into(), "true".into()),
                    ],
                )
                .await?;
            let out = root.text_at("output").unwrap_or_default();
            let bytes = super::b64_decode(out)
                .ok_or_else(|| CloudError::Other("the console output is not base64".into()))?;
            Ok(String::from_utf8_lossy(&bytes).into_owned())
        })
    }

    fn prices<'a>(&'a self, sizes: &'a [String]) -> BoxFuture<'a, Result<Prices, CloudError>> {
        Box::pin(async move {
            let mut p = vec![
                ("ProductDescription.1".to_string(), "Linux/UNIX".to_string()),
                ("StartTime".to_string(), iso(crate::clock::wall())),
            ];
            for (n, s) in sizes.iter().enumerate() {
                p.push((format!("InstanceType.{}", n + 1), s.clone()));
            }
            let root = self.ec2("DescribeSpotPriceHistory", p).await?;
            let mut out: BTreeMap<String, Price> = BTreeMap::new();
            for item in root.find_all("spotPriceHistorySet/item") {
                let (Some(ty), Some(price)) = (
                    item.text_at("instanceType"),
                    item.text_at("spotPrice")
                        .and_then(|p| p.parse::<f64>().ok()),
                ) else {
                    continue;
                };
                let e = out.entry(ty.to_string()).or_default();
                // the cheapest zone's latest price
                e.spot = Some(e.spot.map_or(price, |s| s.min(price)));
            }
            for (ty, usd) in self.on_demand(sizes).await? {
                out.entry(ty).or_default().on_demand = Some(usd);
            }
            Ok(Prices(out))
        })
    }
}

/// The image build's calls (design 6.7.2).
impl super::image::ImageApi for Aws {
    fn start_builder<'a>(
        &'a self,
        req: &'a StartReq,
    ) -> BoxFuture<'a, Result<Instance, CloudError>> {
        Box::pin(async move {
            // the build machine stops at power-off (a terminated disk cannot be imaged); the watchdog's limits
            // do not apply to it, so it is on-demand and the build's own wait bounds it
            let mut p = self.run_params(req);
            for (k, v) in p.iter_mut() {
                if k == "InstanceInitiatedShutdownBehavior" {
                    *v = "stop".into();
                }
            }
            let root = self.ec2("RunInstances", p).await?;
            let item = root
                .find("instancesSet/item")
                .ok_or_else(|| CloudError::Other("RunInstances answered no instance".into()))?;
            Ok(Instance {
                id: item.text_at("instanceId").unwrap_or_default().to_string(),
                zone: item
                    .text_at("placement/availabilityZone")
                    .unwrap_or_default()
                    .to_string(),
            })
        })
    }

    fn wait_stopped<'a>(
        &'a self,
        id: &'a str,
        limit: std::time::Duration,
    ) -> BoxFuture<'a, Result<(), CloudError>> {
        Box::pin(async move {
            let started = crate::clock::now();
            loop {
                match self.describe(id).await {
                    Ok(i) if i.state == InstanceState::Stopped => return Ok(()),
                    Ok(i) if matches!(i.state, InstanceState::Ending | InstanceState::Gone) => {
                        return Err(CloudError::Other(format!(
                            "the image build machine {id} ended before it stopped"
                        )));
                    }
                    // not listed yet, or a hiccup: the limit below bounds the wait
                    Ok(_) | Err(CloudError::Transient(_)) => {}
                    Err(e) => return Err(e),
                }
                if started.elapsed() >= limit {
                    return Err(CloudError::Other(format!(
                        "the image build machine {id} did not power off within {limit:?} (a build step failed; \
                         its console shows which)"
                    )));
                }
                crate::clock::sleep(std::time::Duration::from_secs(10)).await;
            }
        })
    }

    fn create_image<'a>(
        &'a self,
        instance: &'a str,
        name: &'a str,
        tags: &'a BTreeMap<String, String>,
    ) -> BoxFuture<'a, Result<String, CloudError>> {
        Box::pin(async move {
            let mut p: Vec<(String, String)> = [
                ("InstanceId", instance),
                ("Name", name),
                ("BlockDeviceMapping.1.DeviceName", "/dev/sda1"),
                ("BlockDeviceMapping.1.Ebs.Encrypted", "true"),
                ("BlockDeviceMapping.1.Ebs.DeleteOnTermination", "true"),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
            for (n, ty) in ["image", "snapshot"].into_iter().enumerate() {
                let s = format!("TagSpecification.{}", n + 1);
                p.push((format!("{s}.ResourceType"), ty.into()));
                p.push((format!("{s}.Tag.1.Key"), HUB_TAG.into()));
                p.push((format!("{s}.Tag.1.Value"), self.cfg.hub_id.clone()));
                for (i, (k, v)) in tags.iter().enumerate() {
                    p.push((format!("{s}.Tag.{}.Key", i + 2), k.clone()));
                    p.push((format!("{s}.Tag.{}.Value", i + 2), v.clone()));
                }
            }
            let root = self.ec2("CreateImage", p).await?;
            root.text_at("imageId")
                .filter(|i| !i.is_empty())
                .map(str::to_string)
                .ok_or_else(|| CloudError::Other("CreateImage answered no image".into()))
        })
    }

    fn images(&self) -> BoxFuture<'_, Result<Vec<super::image::ImageInfo>, CloudError>> {
        Box::pin(async move {
            let p = vec![
                ("Owner.1".to_string(), "self".to_string()),
                ("Filter.1.Name".to_string(), format!("tag:{HUB_TAG}")),
                ("Filter.1.Value.1".to_string(), self.cfg.hub_id.clone()),
            ];
            let root = self.ec2("DescribeImages", p).await?;
            Ok(root
                .find_all("imagesSet/item")
                .into_iter()
                .map(|i| super::image::ImageInfo {
                    id: i.text_at("imageId").unwrap_or_default().to_string(),
                    name: i.text_at("name").unwrap_or_default().to_string(),
                    snapshot: i
                        .find_all("blockDeviceMapping/item")
                        .into_iter()
                        .find_map(|b| b.text_at("ebs/snapshotId"))
                        .unwrap_or_default()
                        .to_string(),
                    tags: i
                        .find_all("tagSet/item")
                        .into_iter()
                        .filter_map(|t| {
                            Some((
                                t.text_at("key")?.to_string(),
                                t.text_at("value").unwrap_or("").to_string(),
                            ))
                        })
                        .collect(),
                })
                .collect())
        })
    }

    fn deregister<'a>(
        &'a self,
        image: &'a super::image::ImageInfo,
    ) -> BoxFuture<'a, Result<(), CloudError>> {
        Box::pin(async move {
            self.ec2(
                "DeregisterImage",
                vec![("ImageId".into(), image.id.clone())],
            )
            .await?;
            if !image.snapshot.is_empty() {
                self.ec2(
                    "DeleteSnapshot",
                    vec![("SnapshotId".into(), image.snapshot.clone())],
                )
                .await?;
            }
            Ok(())
        })
    }
}

const FORM: &str = "application/x-www-form-urlencoded; charset=utf-8";

/// RFC 3986 percent-encoding, as AWS's Query API and SigV4 want it: unreserved characters stay.
fn pct(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn form_body(pairs: &[(String, String)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", pct(k), pct(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// `2026-11-06T00:00:00Z`.
pub(super) fn iso(t: SystemTime) -> String {
    let secs = t
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs()) as i64;
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// The SigV4 headers (`authorization`, `x-amz-date`, `x-amz-security-token`) for a request: METHOD on URL with
/// HEADERS (which must include `host`) and BODY, as SERVICE in REGION at TIME.
#[allow(clippy::too_many_arguments)]
pub fn sign(
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: &[u8],
    creds: &AwsCredentials,
    region: &str,
    service: &str,
    time: SystemTime,
) -> Result<Vec<(&'static str, String)>, CloudError> {
    let identity = aws_credential_types::Credentials::new(
        creds.access_key_id.expose_secret(),
        creds.secret_access_key.expose_secret(),
        creds
            .session_token
            .as_ref()
            .map(|t| t.expose_secret().to_string()),
        None,
        "drgnx",
    )
    .into();
    let params = aws_sigv4::sign::v4::SigningParams::builder()
        .identity(&identity)
        .region(region)
        .name(service)
        .time(time)
        .settings(aws_sigv4::http_request::SigningSettings::default())
        .build()
        .map_err(|e| CloudError::Other(format!("signing: {e}")))?
        .into();
    let signable = aws_sigv4::http_request::SignableRequest::new(
        method,
        url,
        headers.iter().copied(),
        aws_sigv4::http_request::SignableBody::Bytes(body),
    )
    .map_err(|e| CloudError::Other(format!("signing: {e}")))?;
    let (instructions, _) = aws_sigv4::http_request::sign(signable, &params)
        .map_err(|e| CloudError::Other(format!("signing: {e}")))?
        .into_parts();
    let (headers, _) = instructions.into_parts();
    Ok(headers
        .iter()
        .map(|h| (h.name(), h.value().to_string()))
        .collect())
}

/// An error answer's code and message: EC2's XML (`Response/Errors/Error`), STS's (`ErrorResponse/Error`) or a JSON
/// API's (`__type`, `message`).
pub fn error_of(body: &str) -> (String, String) {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
        let code = v["__type"]
            .as_str()
            .unwrap_or("")
            .rsplit('#')
            .next()
            .unwrap_or("")
            .to_string();
        let msg = v["message"]
            .as_str()
            .or(v["Message"].as_str())
            .unwrap_or("")
            .to_string();
        return (code, msg);
    }
    match El::parse(body) {
        Ok(root) => {
            let e = root.find("Errors/Error").or_else(|| root.find("Error"));
            let get = |n| e.and_then(|e| e.text_at(n)).unwrap_or("").to_string();
            (get("Code"), get("Message"))
        }
        Err(_) => (String::new(), String::new()),
    }
}

/// The error a status and an AWS error CODE mean. An expired or unrecognised credential is a login (LOGIN is the
/// command the card names); a refusal is [`CloudError::Denied`]; capacity, throttling and 5xx are what they say.
pub fn classify(status: u16, code: &str, message: &str, login: &str) -> CloudError {
    const LOGIN: [&str; 8] = [
        "ExpiredToken",
        "ExpiredTokenException",
        "RequestExpired",
        "AuthFailure",
        "InvalidClientTokenId",
        "UnrecognizedClientException",
        "MissingAuthenticationToken",
        "InvalidToken",
    ];
    const CAPACITY: [&str; 5] = [
        "InsufficientInstanceCapacity",
        "InsufficientHostCapacity",
        "InsufficientCapacity",
        "InsufficientReservedInstanceCapacity",
        "SpotMaxPriceTooLow",
    ];
    const TRANSIENT: [&str; 7] = [
        "RequestLimitExceeded",
        "Throttling",
        "ThrottlingException",
        "InternalError",
        "InternalFailure",
        "ServiceUnavailable",
        "Unavailable",
    ];
    let what = if message.is_empty() {
        code.to_string()
    } else {
        format!("{code}: {message}")
    };
    if matches!(status, 401 | 403) && LOGIN.contains(&code) {
        return CloudError::NeedsLogin(login.to_string());
    }
    if code == "UnauthorizedOperation" || code == "AccessDenied" || code == "AccessDeniedException"
    {
        return CloudError::Denied(what);
    }
    if CAPACITY.contains(&code) {
        return CloudError::Capacity(what);
    }
    if TRANSIENT.contains(&code)
        || status >= 500
        || code.ends_with(".NotFound") && code.starts_with("InvalidInstanceID")
    {
        return CloudError::Transient(what);
    }
    CloudError::Other(what)
}

/// The instance under an EC2 `instancesSet/item`.
fn instance_info(item: &El) -> InstanceInfo {
    let state = match item.text_at("instanceState/name").unwrap_or("") {
        "pending" => InstanceState::Pending,
        "running" => InstanceState::Running,
        "stopping" => InstanceState::Stopping,
        "stopped" => InstanceState::Stopped,
        "shutting-down" => InstanceState::Ending,
        "terminated" => InstanceState::Gone,
        s => InstanceState::Other(s.to_string()),
    };
    let address = ["ipAddress", "dnsName"]
        .into_iter()
        .filter_map(|n| item.text_at(n))
        .find(|a| !a.is_empty())
        .map(str::to_string);
    let tags = item
        .find_all("tagSet/item")
        .into_iter()
        .filter_map(|t| {
            Some((
                t.text_at("key")?.to_string(),
                t.text_at("value").unwrap_or("").to_string(),
            ))
        })
        .collect();
    InstanceInfo {
        id: item.text_at("instanceId").unwrap_or_default().to_string(),
        state,
        address,
        size: item.text_at("instanceType").unwrap_or_default().to_string(),
        zone: item
            .text_at("placement/availabilityZone")
            .unwrap_or_default()
            .to_string(),
        spot: item.text_at("instanceLifecycle") == Some("spot"),
        tags,
        launched: item.text_at("launchTime").and_then(super::parse_time),
    }
}

/// An XML element: its local name, its text and its children. Enough of a tree to read EC2's answers.
#[derive(Debug, Default)]
pub struct El {
    pub name: String,
    pub text: String,
    pub kids: Vec<El>,
}

impl El {
    /// The document's root element.
    pub fn parse(xml: &str) -> Result<El, CloudError> {
        use quick_xml::events::Event;
        let bad = |e: String| CloudError::Other(format!("an answer that is not XML: {e}"));
        let mut r = quick_xml::Reader::from_str(xml);
        let mut stack = vec![El::default()];
        // quick-xml 0.42 hands names and text over as `str`; an entity in text comes as its own `GeneralRef`
        let name = |n: &str| n.to_string();
        loop {
            match r.read_event().map_err(|e| bad(e.to_string()))? {
                Event::Start(e) => stack.push(El {
                    name: name(e.local_name().as_ref()),
                    ..El::default()
                }),
                Event::Empty(e) => {
                    let el = El {
                        name: name(e.local_name().as_ref()),
                        ..El::default()
                    };
                    stack.last_mut().expect("the document root").kids.push(el);
                }
                Event::End(_) => {
                    let el = stack.pop().expect("the document root");
                    match stack.last_mut() {
                        Some(parent) => parent.kids.push(el),
                        None => return Err(bad("an end tag with no start".into())),
                    }
                }
                Event::Text(t) => {
                    stack
                        .last_mut()
                        .expect("the document root")
                        .text
                        .push_str(&unescape(&t));
                }
                Event::CData(t) => stack
                    .last_mut()
                    .expect("the document root")
                    .text
                    .push_str(&t),
                Event::GeneralRef(g) => {
                    let s: &str = &g;
                    stack
                        .last_mut()
                        .expect("the document root")
                        .text
                        .push_str(&unescape(&format!("&{s};")));
                }
                Event::Eof => break,
                _ => {}
            }
        }
        let doc = stack
            .pop()
            .filter(|_| stack.is_empty())
            .ok_or_else(|| bad("unclosed elements".into()))?;
        doc.kids
            .into_iter()
            .next()
            .ok_or_else(|| bad("no root element".into()))
    }

    /// The first element at PATH (`a/b/c`, names below this one).
    pub fn find(&self, path: &str) -> Option<&El> {
        let mut cur = self;
        for part in path.split('/') {
            cur = cur.kids.iter().find(|k| k.name == part)?;
        }
        Some(cur)
    }

    /// Every element at PATH, through every branch.
    pub fn find_all(&self, path: &str) -> Vec<&El> {
        let mut cur = vec![self];
        for part in path.split('/') {
            cur = cur
                .into_iter()
                .flat_map(|e| e.kids.iter().filter(move |k| k.name == part))
                .collect();
        }
        cur
    }

    /// The text of the element at PATH, trimmed.
    pub fn text_at(&self, path: &str) -> Option<&str> {
        self.find(path).map(|e| e.text.trim())
    }
}

/// XML's five entities and numeric references.
fn unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';') else { break };
        let ent = &rest[1..end];
        let c = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            e if e.starts_with("#x") => u32::from_str_radix(&e[2..], 16)
                .ok()
                .and_then(char::from_u32),
            e if e.starts_with('#') => e[1..].parse().ok().and_then(char::from_u32),
            _ => None,
        };
        match c {
            Some(c) => out.push(c),
            None => out.push_str(&rest[..=end]),
        }
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    out
}

/// The policy for HUB_ID with REGIONS and SIZES filled in, as `drgnx runner cloud setup aws` prints it.
pub fn policy_for(hub_id: &str, regions: &[String], sizes: &[String]) -> String {
    fn fill(v: &mut serde_json::Value, hub: &str, regions: &[String], sizes: &[String]) {
        match v {
            serde_json::Value::String(s) if s.contains("DRGNX_HUB_ID") => {
                *s = s.replace("DRGNX_HUB_ID", hub)
            }
            serde_json::Value::Array(a) => {
                let mut out = Vec::new();
                for mut x in std::mem::take(a) {
                    match x.as_str() {
                        Some("DRGNX_REGION") => {
                            out.extend(regions.iter().map(|r| r.as_str().into()))
                        }
                        Some("DRGNX_SIZE") => out.extend(sizes.iter().map(|r| r.as_str().into())),
                        _ => {
                            fill(&mut x, hub, regions, sizes);
                            out.push(x);
                        }
                    }
                }
                *a = out;
            }
            serde_json::Value::Object(o) => {
                o.values_mut().for_each(|x| fill(x, hub, regions, sizes))
            }
            _ => {}
        }
    }
    let mut v: serde_json::Value =
        serde_json::from_str(POLICY).expect("the policy fixture is JSON");
    fill(&mut v, hub_id, regions, sizes);
    serde_json::to_string_pretty(&v).expect("JSON prints")
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::runners::cloud::creds::Source;
    use secrecy::SecretString;
    use serde_json::{Value, json};
    use std::time::Duration;

    /// AWS's published example credentials (the SigV4 test suite's), built in pieces.
    fn example_creds() -> AwsCredentials {
        AwsCredentials {
            access_key_id: SecretString::from(["AKID", "EXAMPLE"].concat()),
            secret_access_key: SecretString::from(
                ["wJalrXUtnFEMI", "/K7MDENG+bPxRfiCY", "EXAMPLEKEY"].concat(),
            ),
            session_token: None,
            expires: None,
        }
    }

    // [D] pure
    #[test]
    fn sigv4_matches_the_aws_test_vector() {
        // the suite's get-vanilla: GET / on example.amazonaws.com, 2015-08-30T12:36:00Z, us-east-1, "service"
        let t = SystemTime::UNIX_EPOCH + Duration::from_secs(1_440_938_160);
        let h = sign(
            "GET",
            "https://example.amazonaws.com/",
            &[("host", "example.amazonaws.com")],
            b"",
            &example_creds(),
            "us-east-1",
            "service",
            t,
        )
        .unwrap();
        let get = |n: &str| h.iter().find(|(k, _)| *k == n).map(|(_, v)| v.as_str());
        assert_eq!(get("x-amz-date"), Some("20150830T123600Z"));
        assert_eq!(
            get("authorization"),
            Some(
                "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
                 SignedHeaders=host;x-amz-date, \
                 Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
            )
        );
        assert_eq!(get("x-amz-security-token"), None);
        assert_eq!(iso(t), "2015-08-30T12:36:00Z");
        assert_eq!(pct("a b/c=d~"), "a%20b%2Fc%3Dd~");
    }

    fn resolver() -> Arc<Resolver> {
        Arc::new(Resolver::new(Source::Command(vec!["true".into()]), None))
    }

    fn req(token: &str, market: Market) -> StartReq {
        StartReq {
            token: token.into(),
            name: "drgnx-c1".into(),
            size: "m7g.large".into(),
            image: "ami-base0fedora45x86".into(),
            market,
            user_data: "drgnx-principal: drgnx-c1\n".into(),
            security_group: Some("sg-0123".into()),
        }
    }

    fn cfg() -> AwsCfg {
        AwsCfg {
            region: "us-east-1".into(),
            hub_id: "hub-1".into(),
            probe: None,
        }
    }

    // [D] pure
    #[test]
    fn run_instances_always_carries_token_tags_terminate_imdsv2() {
        let aws = Aws::with_endpoint(cfg(), resolver(), "http://127.0.0.1:9/").unwrap();
        for market in [Market::Spot, Market::OnDemand] {
            let p = aws.run_params(&req("tok-1", market));
            let get = |k: &str| p.iter().find(|(a, _)| a == k).map(|(_, v)| v.as_str());
            assert_eq!(get("ClientToken"), Some("tok-1"));
            assert_eq!(get("InstanceInitiatedShutdownBehavior"), Some("terminate"));
            assert_eq!(get("MetadataOptions.HttpTokens"), Some("required"));
            assert_eq!(get("MetadataOptions.HttpPutResponseHopLimit"), Some("1"));
            assert_eq!(get("SecurityGroupId.1"), Some("sg-0123"));
            assert_eq!(get("MinCount"), Some("1"));
            assert_eq!(get("MaxCount"), Some("1"));
            for (n, ty) in ["instance", "volume", "network-interface"]
                .iter()
                .enumerate()
            {
                let s = format!("TagSpecification.{}", n + 1);
                assert_eq!(get(&format!("{s}.ResourceType")), Some(*ty));
                assert_eq!(get(&format!("{s}.Tag.1.Key")), Some(HUB_TAG));
                assert_eq!(get(&format!("{s}.Tag.1.Value")), Some("hub-1"));
            }
            assert!(
                !p.iter().any(|(k, _)| k.starts_with("IamInstanceProfile")),
                "machines get no role"
            );
            assert_eq!(
                get("InstanceMarketOptions.MarketType"),
                (market == Market::Spot).then_some("spot")
            );
            let ud = super::super::b64_decode(get("UserData").unwrap()).unwrap();
            assert_eq!(ud, b"drgnx-principal: drgnx-c1\n");
        }
        // only https, except in a test build
        assert!(super::super::checked_url("http://127.0.0.1:9/").is_ok());
    }

    // [D] pure
    #[test]
    fn expired_token_is_needs_login() {
        let login = "aws configure export-credentials";
        let ec2 = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Response><Errors><Error><Code>ExpiredToken</Code>\
                   <Message>The security token included in the request is expired</Message></Error></Errors>\
                   <RequestID>r</RequestID></Response>";
        let (code, msg) = error_of(ec2);
        assert_eq!(code, "ExpiredToken");
        assert_eq!(
            classify(401, &code, &msg, login),
            CloudError::NeedsLogin(login.into())
        );
        assert_eq!(
            classify(403, "ExpiredToken", "", login),
            CloudError::NeedsLogin(login.into())
        );
        assert_eq!(
            classify(401, "AuthFailure", "", login),
            CloudError::NeedsLogin(login.into())
        );
        let sts = "<ErrorResponse><Error><Type>Sender</Type><Code>ExpiredToken</Code><Message>m</Message></Error></ErrorResponse>";
        assert_eq!(error_of(sts).0, "ExpiredToken");
        assert_eq!(
            error_of(r#"{"__type":"com.amazon#ExpiredTokenException","message":"m"}"#).0,
            "ExpiredTokenException"
        );
        // a refusal is not a login, and neither is a 400 that names a token
        assert!(matches!(
            classify(403, "UnauthorizedOperation", "", login),
            CloudError::Denied(_)
        ));
        assert!(matches!(
            classify(400, "ExpiredToken", "", login),
            CloudError::Other(_)
        ));
        assert!(matches!(
            classify(500, "InsufficientInstanceCapacity", "", login),
            CloudError::Capacity(_)
        ));
        assert!(matches!(
            classify(503, "Unavailable", "", login),
            CloudError::Transient(_)
        ));
        assert_eq!(
            CloudError::NeedsLogin(login.into()).to_string(),
            "the cloud credentials need a login: run `aws configure export-credentials` in a terminal"
        );
    }

    // [D] pure
    #[test]
    fn the_policy_fixture_has_one_statement_per_resource_type() {
        let p: Value = serde_json::from_str(POLICY).unwrap();
        assert_eq!(p["Version"], "2012-10-17");
        let st = p["Statement"].as_array().unwrap();
        let rtype = |arn: &str| -> String {
            // arn:aws:ec2:REGION:ACCOUNT:TYPE/ID, or "*"
            arn.split(':')
                .nth(5)
                .map_or("*".into(), |r| r.split('/').next().unwrap().to_string())
        };
        let mut seen = std::collections::BTreeSet::new();
        for s in st {
            let res: Vec<&str> = match &s["Resource"] {
                Value::String(r) => vec![r.as_str()],
                Value::Array(a) => a.iter().map(|r| r.as_str().unwrap()).collect(),
                _ => panic!("no Resource: {s}"),
            };
            let types: std::collections::BTreeSet<String> = res.iter().map(|r| rtype(r)).collect();
            assert_eq!(types.len(), 1, "one resource type per statement: {s}");
            let sid = s["Sid"].as_str().unwrap();
            assert!(seen.insert(sid.to_string()), "Sids are unique: {sid}");
            if s["Effect"] == "Allow" {
                // the Pricing API answers only in us-east-1
                let regions = if sid == "Prices" {
                    json!(["us-east-1"])
                } else {
                    json!(["DRGNX_REGION"])
                };
                assert_eq!(
                    s["Condition"]["StringEquals"]["aws:RequestedRegion"], regions,
                    "every allow is limited to the allowed regions: {sid}"
                );
            }
        }
        let by = |sid: &str| {
            st.iter()
                .find(|s| s["Sid"] == sid)
                .unwrap_or_else(|| panic!("no {sid}"))
        };
        // the instance, its volumes and its network interface only with our tag on the request
        for sid in [
            "RunInstancesTaggedInstance",
            "RunInstancesTaggedVolume",
            "RunInstancesTaggedNetworkInterface",
        ] {
            let s = by(sid);
            assert_eq!(s["Action"], "ec2:RunInstances");
            assert_eq!(
                s["Condition"]["StringEquals"]["aws:RequestTag/drgnx-hub"],
                "DRGNX_HUB_ID"
            );
        }
        let inst = by("RunInstancesTaggedInstance");
        assert_eq!(
            inst["Condition"]["StringEquals"]["ec2:InstanceType"],
            json!(["DRGNX_SIZE"])
        );
        assert_eq!(
            inst["Condition"]["StringEquals"]["ec2:MetadataHttpTokens"],
            "required"
        );
        assert_eq!(
            by("CreateTagsOnlyAtCreation")["Condition"]["StringEquals"]["ec2:CreateAction"],
            json!(["RunInstances", "CreateImage"])
        );
        for sid in [
            "EndOurInstances",
            "OurImages",
            "OurSnapshots",
            "OurSecurityGroups",
        ] {
            assert_eq!(
                by(sid)["Condition"]["StringEquals"]["aws:ResourceTag/drgnx-hub"],
                "DRGNX_HUB_ID",
                "{sid} only on resources tagged with the hub"
            );
        }
        let denied = |action: &str| {
            st.iter().any(|s| {
                s["Effect"] == "Deny"
                    && match &s["Action"] {
                        Value::String(a) => a == action,
                        Value::Array(a) => a.iter().any(|x| x == action),
                        _ => false,
                    }
            })
        };
        for a in [
            "iam:PassRole",
            "ec2:ModifyImageAttribute",
            "ec2:ModifySnapshotAttribute",
        ] {
            assert!(denied(a), "an explicit deny on {a}");
        }
        // what the setup prints: the placeholders filled in
        let out = policy_for(
            "hub-7",
            &["eu-west-1".into(), "us-east-1".into()],
            &["m7g.large".into()],
        );
        assert!(!out.contains("DRGNX_"), "{out}");
        let v: Value = serde_json::from_str(&out).unwrap();
        let inst = v["Statement"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["Sid"] == "RunInstancesTaggedInstance")
            .unwrap();
        assert_eq!(
            inst["Condition"]["StringEquals"]["aws:RequestTag/drgnx-hub"],
            "hub-7"
        );
        assert_eq!(
            inst["Condition"]["StringEquals"]["aws:RequestedRegion"],
            json!(["eu-west-1", "us-east-1"])
        );
    }

    /// `ratatoskr-mock cloud` with no containers, and a client of it whose credentials come from a command that
    /// prints fake ones (built in pieces).
    pub(in crate::runners::cloud) struct Mock {
        child: std::process::Child,
        base: String,
    }

    impl Drop for Mock {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    impl Mock {
        pub(in crate::runners::cloud) fn start() -> Mock {
            use std::io::BufRead;
            let mut child = std::process::Command::new(crate::embed::tests::mock_binary())
                .args([
                    "cloud",
                    "--listen",
                    "127.0.0.1:0",
                    "--podman-remote",
                    "none",
                ])
                .args(["--prefix", "t", "--run", "r1", "--hub", "hub-1"])
                .arg("--parent")
                .arg(std::process::id().to_string())
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            let mut line = String::new();
            std::io::BufReader::new(child.stdout.take().unwrap())
                .read_line(&mut line)
                .unwrap();
            let port: u16 = line
                .trim()
                .strip_prefix("MOCK-CLOUD-PORT ")
                .unwrap()
                .parse()
                .unwrap();
            Mock {
                child,
                base: format!("http://127.0.0.1:{port}/"),
            }
        }

        pub(in crate::runners::cloud) fn base(&self) -> &str {
            &self.base
        }

        pub(in crate::runners::cloud) fn client(&self) -> Aws {
            let id = ["AS", "IA", "FAKEFAKEFAKE0002"].concat();
            let secret = ["fake", "/secret", "0002"].concat();
            let json = format!(
                "{{\"Version\":1,\"AccessKeyId\":\"{id}\",\"SecretAccessKey\":\"{secret}\"}}"
            );
            let creds = Resolver::new(
                Source::Command(vec!["printf".into(), "%s".into(), json]),
                None,
            );
            Aws::with_endpoint(cfg(), Arc::new(creds), &self.base).unwrap()
        }

        /// A knob: `POST /__mock/NAME` with BODY.
        pub(in crate::runners::cloud) async fn knob(&self, name: &str, body: Value) {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let addr = self
                .base
                .trim_start_matches("http://")
                .trim_end_matches('/');
            let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
            let b = body.to_string();
            let req = format!(
                "POST /__mock/{name} HTTP/1.1\r\nHost: mock\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{b}",
                b.len()
            );
            s.write_all(req.as_bytes()).await.unwrap();
            let mut out = String::new();
            s.read_to_string(&mut out).await.unwrap();
            assert!(out.starts_with("HTTP/1.1 200"), "{name}: {out}");
        }
    }

    // [B] the mock's virtual clock: a machine boots when the test moves it, never on time
    #[tokio::test]
    async fn start_describe_end_round_trip() {
        let m = Mock::start();
        let aws = m.client();
        m.knob("boot-delay", json!({"seconds": 30})).await;
        let started = aws.start(&req("tok-round", Market::Spot)).await.unwrap();
        assert!(started.id.starts_with("i-"), "{started:?}");
        assert_eq!(started.zone, "us-east-1a");
        let d = aws.describe(&started.id).await.unwrap();
        assert_eq!(d.state, InstanceState::Pending);
        assert!(d.spot);
        assert_eq!(d.tags.get(HUB_TAG).map(String::as_str), Some("hub-1"));
        assert_eq!(
            aws.console(&started.id).await.unwrap(),
            "",
            "no console before boot"
        );
        m.knob("clock", json!({"advance_s": 30})).await;
        let d = aws.describe(&started.id).await.unwrap();
        assert_eq!(d.state, InstanceState::Running);
        assert!(d.address.is_some());
        assert!(
            aws.console(&started.id)
                .await
                .unwrap()
                .contains("BEGIN SSH HOST KEY FINGERPRINTS")
        );
        let ours = aws.list_ours().await.unwrap();
        assert_eq!(
            ours.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            [started.id.as_str()]
        );
        let prices = aws.prices(&["m7g.large".into()]).await.unwrap();
        let p = prices.0["m7g.large"];
        assert!(p.spot.is_some() && p.on_demand.is_some(), "{prices:?}");
        let checks = aws.preflight().await;
        assert!(checks.iter().all(|c| c.ok), "{checks:?}");
        aws.end(&started.id).await.unwrap();
        let d = aws.describe(&started.id).await.unwrap();
        assert!(
            matches!(d.state, InstanceState::Ending | InstanceState::Gone),
            "{d:?}"
        );
        m.knob("clock", json!({"advance_s": 1})).await;
        assert_eq!(
            aws.describe(&started.id).await.unwrap().state,
            InstanceState::Gone
        );
        assert!(aws.list_ours().await.unwrap().is_empty());
        aws.end(&started.id).await.unwrap();
        // an expired token is a login, never a retry
        m.knob("expire", json!({})).await;
        assert!(matches!(
            aws.describe(&started.id).await,
            Err(CloudError::NeedsLogin(_))
        ));
    }

    // [B] the mock's virtual clock
    #[tokio::test]
    async fn a_retry_after_a_crash_returns_the_same_instance() {
        let m = Mock::start();
        let first = m
            .client()
            .start(&req("tok-crash", Market::OnDemand))
            .await
            .unwrap();
        // the hub dies before it records the machine; the next hub retries the same start with a client of its own
        let again = m
            .client()
            .start(&req("tok-crash", Market::OnDemand))
            .await
            .unwrap();
        assert_eq!(again.id, first.id);
        assert_eq!(
            m.client().list_ours().await.unwrap().len(),
            1,
            "one machine, not two"
        );
        let other = m
            .client()
            .start(&req("tok-other", Market::OnDemand))
            .await
            .unwrap();
        assert_ne!(other.id, first.id);
    }
}
