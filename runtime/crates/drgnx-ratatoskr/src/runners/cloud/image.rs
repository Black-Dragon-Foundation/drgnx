//! drgnx's own AWS image (design 6.7.2): Fedora Cloud 45 with git, podman, the runner bundle, the watchdog, the SSH CA's
//! public key and the project images baked in, so a started machine is ready in about a minute.
//!
//! [`build`] resolves the base from Fedora's published list, starts a build machine with [`user_data::render_build`]
//! (which installs everything and ends with the steps that make the disk imageable: host keys removed, `cloud-init
//! clean`, power-off), waits for it to stop, images it (encrypted, tagged with the drgnx version, the bundle version and
//! a hash of the inputs), ends the machine, and keeps the newest two images (older ones are deregistered with their
//! snapshots). The same inputs on the same base reuse the image: no machine starts.
//!
//! Everything here is public data; the build machine holds no secret.

use super::user_data::{BuildInputs, input_hash, render_build};
use super::{CloudError, Instance, Market, Provider, StartReq};
use mimir::BoxFuture;
use std::collections::BTreeMap;
use std::time::Duration;

pub const TAG_VERSION: &str = "drgnx-version";
pub const TAG_BUNDLE: &str = "drgnx-bundle";
pub const TAG_HASH: &str = "drgnx-input-hash";
pub const TAG_BUILT: &str = "drgnx-built";

/// How many images stay.
pub const KEEP: usize = 2;

/// Fedora's published release list.
const FEDORA_LIST: &str = "https://fedoraproject.org/releases.json";
/// The Fedora release the image is built on.
pub const FEDORA_VERSION: &str = "45";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arch {
    X86_64,
    Aarch64,
}

impl Arch {
    fn fedora(self) -> &'static str {
        match self {
            Arch::X86_64 => "x86_64",
            Arch::Aarch64 => "aarch64",
        }
    }
}

/// The image a build starts from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Base {
    pub id: String,
    pub name: String,
    /// Not Fedora: named in the output, so the user sees it.
    pub fallback: bool,
}

/// An image of ours.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageInfo {
    pub id: String,
    pub name: String,
    pub snapshot: String,
    pub tags: BTreeMap<String, String>,
}

/// Where a base image is looked up.
pub trait BaseList: Send + Sync {
    fn base<'a>(
        &'a self,
        region: &'a str,
        arch: Arch,
    ) -> BoxFuture<'a, Result<Option<Base>, CloudError>>;
}

/// What the image build asks of a provider, on top of [`Provider`].
pub trait ImageApi: Provider {
    /// Starts the build machine: it stops (never terminates) at power-off, so its disk can be imaged.
    fn start_builder<'a>(
        &'a self,
        req: &'a StartReq,
    ) -> BoxFuture<'a, Result<Instance, CloudError>>;
    /// Returns once the machine is stopped; an error if it ends instead or LIMIT passes.
    fn wait_stopped<'a>(
        &'a self,
        id: &'a str,
        limit: Duration,
    ) -> BoxFuture<'a, Result<(), CloudError>>;
    /// Images the machine's disk, encrypted, with TAGS (and the hub's tag) on the image and its snapshot.
    fn create_image<'a>(
        &'a self,
        instance: &'a str,
        name: &'a str,
        tags: &'a BTreeMap<String, String>,
    ) -> BoxFuture<'a, Result<String, CloudError>>;
    /// This hub's images.
    fn images(&self) -> BoxFuture<'_, Result<Vec<ImageInfo>, CloudError>>;
    /// Deregisters the image and deletes its snapshot.
    fn deregister<'a>(&'a self, image: &'a ImageInfo) -> BoxFuture<'a, Result<(), CloudError>>;
}

/// The AMI in LIST (Fedora's `releases.json`) for Fedora VERSION, REGION and ARCH.
pub fn parse_fedora_list(list: &str, version: &str, region: &str, arch: Arch) -> Option<Base> {
    let v: serde_json::Value = serde_json::from_str(list).ok()?;
    let want = format!("region={region}#launchAmi=");
    v.as_array()?.iter().find_map(|e| {
        if e["version"] != version || e["arch"] != arch.fedora() || e["variant"] != "Cloud" {
            return None;
        }
        let link = e["link"].as_str()?;
        if !link.contains("console.aws.amazon.com") || !link.contains(&want) {
            return None;
        }
        let ami = link.rsplit("launchAmi=").next()?;
        (ami.starts_with("ami-") && ami.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
            .then(|| Base {
                id: ami.to_string(),
                name: format!(
                    "Fedora Cloud {version} ({arch}, {region})",
                    arch = arch.fedora()
                ),
                fallback: false,
            })
    })
}

/// Fedora's published list, fetched over HTTPS.
pub struct FedoraList {
    url: String,
    http: bifrost::upstream::Upstream,
}

impl FedoraList {
    pub fn new() -> Result<FedoraList, CloudError> {
        let url = super::endpoint("FEDORA", FEDORA_LIST.into());
        super::checked_url(&url)?;
        let http = bifrost::upstream::Upstream::new(Default::default())
            .map_err(|e| CloudError::Other(format!("the HTTPS client: {e}")))?;
        Ok(FedoraList { url, http })
    }
}

impl BaseList for FedoraList {
    fn base<'a>(
        &'a self,
        region: &'a str,
        arch: Arch,
    ) -> BoxFuture<'a, Result<Option<Base>, CloudError>> {
        Box::pin(async move {
            let uri = super::checked_url(&self.url)?;
            let fetch = async {
                let mut r = self
                    .http
                    .get(&uri, &[])
                    .await
                    .map_err(|e| CloudError::Transient(e.to_string()))?;
                if r.status() != 200 {
                    return Err(CloudError::Transient(format!(
                        "Fedora's list answered {}",
                        r.status()
                    )));
                }
                let mut body = Vec::new();
                while let Some(c) = r.chunk().await {
                    body.extend_from_slice(&c.map_err(|e| CloudError::Transient(e.to_string()))?);
                    if body.len() > super::MAX_BODY {
                        return Err(CloudError::Other("Fedora's list is too large".into()));
                    }
                }
                Ok(String::from_utf8_lossy(&body).into_owned())
            };
            let text = crate::clock::timeout(super::CALL_TIMEOUT, fetch)
                .await
                .map_err(|_| CloudError::Transient("no answer from Fedora's list".into()))??;
            Ok(parse_fedora_list(&text, FEDORA_VERSION, region, arch))
        })
    }
}

/// The base to build on: Fedora's AMI when it is listed, else FALLBACK (named as such), else "unavailable".
pub async fn resolve_base<L: BaseList + ?Sized>(
    list: &L,
    fallback: Option<&Base>,
    region: &str,
    arch: Arch,
) -> Result<Base, CloudError> {
    if let Some(b) = list.base(region, arch).await? {
        return Ok(b);
    }
    fallback
        .cloned()
        .map(|b| Base {
            fallback: true,
            ..b
        })
        .ok_or_else(|| CloudError::Other("unavailable: no supported base image".into()))
}

/// (the newest N, the rest), newest first, by the time each was built.
pub fn keep_newest(mut all: Vec<ImageInfo>, n: usize) -> (Vec<ImageInfo>, Vec<ImageInfo>) {
    let built = |i: &ImageInfo| i.tags.get(TAG_BUILT).cloned().unwrap_or_default();
    all.sort_by(|a, b| built(b).cmp(&built(a)).then_with(|| b.id.cmp(&a.id)));
    let old = all.split_off(n.min(all.len()));
    (all, old)
}

/// One build's settings.
#[derive(Clone, Debug)]
pub struct BuildCfg {
    pub region: String,
    pub arch: Arch,
    /// The build machine's size.
    pub size: String,
    /// The idempotency token of the build machine's start.
    pub token: String,
    pub fallback: Option<Base>,
    /// How long the build may take before the machine is ended and the build fails.
    pub wait: Duration,
}

/// What a build made (or found).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Built {
    pub id: String,
    /// The image was already current: no machine started.
    pub reused: bool,
    pub base: Base,
}

/// A sortable timestamp, to the nanosecond: two builds in one second still order.
fn stamp() -> String {
    let t = crate::clock::wall();
    let ns = t
        .duration_since(std::time::SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    super::aws::iso(t).replace('Z', &format!(".{ns:09}Z"))
}

/// Builds the image for INPUTS, or returns the current one when the inputs and the base are unchanged.
pub async fn build<A: ImageApi + ?Sized, L: BaseList + ?Sized>(
    api: &A,
    list: &L,
    cfg: &BuildCfg,
    inputs: &BuildInputs,
) -> Result<Built, CloudError> {
    let base = resolve_base(list, cfg.fallback.as_ref(), &cfg.region, cfg.arch).await?;
    let hash = input_hash(inputs, &base.id)?;
    if let Some(i) = api
        .images()
        .await?
        .into_iter()
        .find(|i| i.tags.get(TAG_HASH) == Some(&hash))
    {
        return Ok(Built {
            id: i.id,
            reused: true,
            base,
        });
    }
    let machine = api
        .start_builder(&StartReq {
            token: cfg.token.clone(),
            name: "drgnx-image-build".into(),
            size: cfg.size.clone(),
            image: base.id.clone(),
            market: Market::OnDemand,
            user_data: render_build(inputs)?,
            security_group: None,
        })
        .await?;
    let tags = BTreeMap::from([
        (TAG_VERSION.to_string(), inputs.drgnx_version.clone()),
        (TAG_BUNDLE.to_string(), inputs.bundle_version.clone()),
        (TAG_HASH.to_string(), hash.clone()),
        (TAG_BUILT.to_string(), stamp()),
    ]);
    let name = format!(
        "drgnx-{}-{}-{}",
        inputs.drgnx_version,
        inputs.bundle_version,
        &hash[..12]
    );
    let made = async {
        api.wait_stopped(&machine.id, cfg.wait).await?;
        api.create_image(&machine.id, &name, &tags).await
    }
    .await;
    // the machine goes whether or not the image was made
    let ended = api.end(&machine.id).await;
    let id = made?;
    ended?;
    let (_, old) = keep_newest(api.images().await?, KEEP);
    for i in &old {
        api.deregister(i).await?;
    }
    Ok(Built {
        id,
        reused: false,
        base,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::cloud::aws::tests::Mock;
    use crate::runners::cloud::ca::Ca;
    use crate::runners::cloud::user_data::tests::inputs;
    use crate::runners::cloud::{Instance, InstanceInfo, Market, Prices, Provider, StartReq};
    use serde_json::json;
    use std::sync::Mutex;

    fn img(id: &str, built: &str) -> ImageInfo {
        ImageInfo {
            id: id.into(),
            name: id.into(),
            snapshot: format!("snap-{id}"),
            tags: BTreeMap::from([(TAG_BUILT.to_string(), built.to_string())]),
        }
    }

    // [D] pure
    #[test]
    fn keeps_the_newest_two_images() {
        let all = vec![
            img("a", "2026-11-01T00:00:00Z"),
            img("d", "2026-11-04T00:00:00Z"),
            img("b", "2026-11-02T00:00:00Z"),
            img("c", "2026-11-03T00:00:00Z"),
        ];
        let (keep, old) = keep_newest(all.clone(), 2);
        assert_eq!(
            keep.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["d", "c"]
        );
        assert_eq!(
            old.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["b", "a"]
        );
        let (keep, old) = keep_newest(all[..1].to_vec(), 2);
        assert_eq!((keep.len(), old.len()), (1, 0));
    }

    const LIST: &str = r#"[
      {"version":"45","arch":"x86_64","variant":"Cloud","subvariant":"Cloud_Base","link":"https://download.example/f45.qcow2"},
      {"version":"44","arch":"x86_64","variant":"Cloud","subvariant":"Cloud_Base","link":"https://console.aws.amazon.com/ec2/v2/home?region=eu-west-1#launchAmi=ami-0044"},
      {"version":"45","arch":"x86_64","variant":"Cloud","subvariant":"Cloud_Base","link":"https://console.aws.amazon.com/ec2/v2/home?region=eu-west-1#launchAmi=ami-0eu45x86"},
      {"version":"45","arch":"aarch64","variant":"Cloud","subvariant":"Cloud_Base","link":"https://console.aws.amazon.com/ec2/v2/home?region=eu-west-1#launchAmi=ami-0eu45arm"}
    ]"#;

    // [D] pure
    #[test]
    fn the_base_is_fedora_45_for_the_region_and_arch() {
        let b = parse_fedora_list(LIST, "45", "eu-west-1", Arch::X86_64).unwrap();
        assert_eq!(b.id, "ami-0eu45x86");
        assert!(b.name.contains("Fedora Cloud 45"), "{}", b.name);
        assert_eq!(
            parse_fedora_list(LIST, "45", "eu-west-1", Arch::Aarch64)
                .unwrap()
                .id,
            "ami-0eu45arm"
        );
        assert_eq!(
            parse_fedora_list(LIST, "45", "us-east-1", Arch::X86_64),
            None,
            "no AMI listed for that region"
        );
        assert_eq!(
            parse_fedora_list("not json", "45", "eu-west-1", Arch::X86_64),
            None
        );
    }

    struct Fixed(Option<Base>);
    impl BaseList for Fixed {
        fn base<'a>(
            &'a self,
            _: &'a str,
            _: Arch,
        ) -> BoxFuture<'a, Result<Option<Base>, CloudError>> {
            Box::pin(async move { Ok(self.0.clone()) })
        }
    }

    // [D] pure
    #[tokio::test]
    async fn no_base_is_unavailable_and_a_fallback_is_named() {
        let err = resolve_base(&Fixed(None), None, "eu-west-1", Arch::X86_64)
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), "unavailable: no supported base image");
        let fb = Base {
            id: "ami-fb".into(),
            name: "Another distribution, podman 5".into(),
            fallback: true,
        };
        let b = resolve_base(&Fixed(None), Some(&fb), "eu-west-1", Arch::X86_64)
            .await
            .unwrap();
        assert!(b.fallback && b.id == "ami-fb");
        // a listed Fedora base wins over the fallback
        let fed = Base {
            id: "ami-fed".into(),
            name: "Fedora Cloud 45".into(),
            fallback: false,
        };
        let b = resolve_base(&Fixed(Some(fed)), Some(&fb), "eu-west-1", Arch::X86_64)
            .await
            .unwrap();
        assert_eq!(b.id, "ami-fed");
    }

    /// The mock's account, with the calls the build makes logged in order, and the guest's power-off played by the test
    /// at the one point the build waits for it (a gate, no sleep).
    struct Api<'m> {
        aws: crate::runners::cloud::aws::Aws,
        mock: &'m Mock,
        log: Mutex<Vec<String>>,
    }

    impl Api<'_> {
        fn note(&self, s: impl Into<String>) {
            self.log.lock().unwrap().push(s.into());
        }
    }

    impl Provider for Api<'_> {
        fn preflight(&self) -> BoxFuture<'_, Vec<crate::runners::cloud::Check>> {
            self.aws.preflight()
        }
        fn start<'a>(&'a self, r: &'a StartReq) -> BoxFuture<'a, Result<Instance, CloudError>> {
            self.aws.start(r)
        }
        fn describe<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<InstanceInfo, CloudError>> {
            self.aws.describe(id)
        }
        fn list_ours(&self) -> BoxFuture<'_, Result<Vec<InstanceInfo>, CloudError>> {
            self.aws.list_ours()
        }
        fn end<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<(), CloudError>> {
            self.note("end");
            self.aws.end(id)
        }
        fn console<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<String, CloudError>> {
            self.aws.console(id)
        }
        fn prices<'a>(&'a self, s: &'a [String]) -> BoxFuture<'a, Result<Prices, CloudError>> {
            self.aws.prices(s)
        }
    }

    impl ImageApi for Api<'_> {
        fn start_builder<'a>(
            &'a self,
            r: &'a StartReq,
        ) -> BoxFuture<'a, Result<Instance, CloudError>> {
            self.note("start_builder");
            self.aws.start_builder(r)
        }
        fn wait_stopped<'a>(
            &'a self,
            id: &'a str,
            _: Duration,
        ) -> BoxFuture<'a, Result<(), CloudError>> {
            Box::pin(async move {
                self.note("wait_stopped");
                self.mock.knob("poweroff", json!({"id": id})).await;
                self.mock.knob("clock", json!({"advance_s": 1})).await;
                assert_eq!(
                    self.aws.describe(id).await?.state,
                    crate::runners::cloud::InstanceState::Stopped
                );
                Ok(())
            })
        }
        fn create_image<'a>(
            &'a self,
            i: &'a str,
            n: &'a str,
            t: &'a BTreeMap<String, String>,
        ) -> BoxFuture<'a, Result<String, CloudError>> {
            self.note("create_image");
            self.aws.create_image(i, n, t)
        }
        fn images(&self) -> BoxFuture<'_, Result<Vec<ImageInfo>, CloudError>> {
            self.aws.images()
        }
        fn deregister<'a>(&'a self, i: &'a ImageInfo) -> BoxFuture<'a, Result<(), CloudError>> {
            self.note(format!("deregister {}", i.id));
            self.aws.deregister(i)
        }
    }

    async fn resources(m: &Mock) -> serde_json::Value {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let addr = m
            .base()
            .trim_start_matches("http://")
            .trim_end_matches('/')
            .to_string();
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET /__mock/resources HTTP/1.1\r\nHost: mock\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).await.unwrap();
        serde_json::from_str(out.split("\r\n\r\n").nth(1).unwrap()).unwrap()
    }

    // [B] gate: the guest's power-off is the test's, at the wait
    #[tokio::test]
    async fn build_then_start_from_it() {
        let m = Mock::start();
        let api = Api {
            aws: m.client(),
            mock: &m,
            log: Mutex::default(),
        };
        let (_, ca_pub) = Ca::new();
        let inp = inputs(ca_pub.to_openssh("drgnx-ca"));
        let cfg = BuildCfg {
            region: "us-east-1".into(),
            arch: Arch::X86_64,
            size: "m7g.large".into(),
            token: "tok-image-1".into(),
            fallback: None,
            wait: Duration::from_secs(1800),
        };
        let list = Fixed(Some(Base {
            id: "ami-base0fedora45x86".into(),
            name: "Fedora Cloud 45 (test)".into(),
            fallback: false,
        }));
        let built = build(&api, &list, &cfg, &inp).await.unwrap();
        assert!(built.id.starts_with("ami-"), "{built:?}");
        assert!(!built.reused);
        assert_eq!(built.base.id, "ami-base0fedora45x86");
        // order: the machine powered off before the snapshot, and is ended after it
        assert_eq!(
            *api.log.lock().unwrap(),
            ["start_builder", "wait_stopped", "create_image", "end"]
        );
        // the image carries the hub's tag and ours, and is encrypted
        let found = api.images().await.unwrap();
        assert_eq!(found.len(), 1);
        let tags = &found[0].tags;
        assert_eq!(tags.get("drgnx-hub").map(String::as_str), Some("hub-1"));
        assert_eq!(tags.get(TAG_VERSION).map(String::as_str), Some("0.6.0"));
        assert_eq!(tags.get(TAG_BUNDLE).map(String::as_str), Some("6.0.0-1"));
        assert_eq!(tags.get(TAG_HASH).map(String::len), Some(64));
        // a machine started from it is ours, and the same inputs reuse the image instead of building again
        let started = api
            .start(&StartReq {
                token: "tok-from-image".into(),
                name: "drgnx-c1".into(),
                size: "m7g.large".into(),
                image: built.id.clone(),
                market: Market::OnDemand,
                user_data: crate::runners::cloud::user_data::render(
                    None,
                    "drgnx-c1",
                    crate::runners::cloud::user_data::Limits {
                        idle: 600,
                        lifetime: 28800,
                        unattended: 3600,
                    },
                    crate::runners::cloud::user_data::Flavor::Aws,
                ),
                security_group: None,
            })
            .await
            .unwrap();
        assert!(started.id.starts_with("i-"));
        api.log.lock().unwrap().clear();
        let again = build(
            &api,
            &list,
            &BuildCfg {
                token: "tok-image-2".into(),
                ..cfg.clone()
            },
            &inp,
        )
        .await
        .unwrap();
        assert!(again.reused && again.id == built.id);
        assert!(
            api.log.lock().unwrap().is_empty(),
            "no machine for an image that is current"
        );
        // new inputs: a second image, then a third; only the newest two stay, the oldest goes with its snapshot
        let mut ids = vec![built.id.clone()];
        for (n, v) in ["6.0.0-2", "6.0.0-3"].into_iter().enumerate() {
            m.knob("clock", json!({"advance_s": 60})).await;
            let mut i2 = inp.clone();
            i2.bundle_version = v.into();
            let c = BuildCfg {
                token: format!("tok-image-v{n}"),
                ..cfg.clone()
            };
            ids.push(build(&api, &list, &c, &i2).await.unwrap().id);
        }
        let left: Vec<String> = api
            .images()
            .await
            .unwrap()
            .into_iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(left.len(), 2, "{left:?}");
        assert!(
            !left.contains(&ids[0]) && left.contains(&ids[1]) && left.contains(&ids[2]),
            "{left:?} of {ids:?}"
        );
        let r = resources(&m).await.to_string();
        assert!(
            !r.contains(&format!("snap-{}", &ids[0][4..])),
            "the oldest image's snapshot is gone: {r}"
        );
    }
}
