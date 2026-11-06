//! Cloud machines (docs/develop/hub.md, "Runners: cloud machines"; design §6.7): the providers drgnx starts and ends
//! machines with, over plain HTTPS.
//!
//! - [`Provider`]: what the hub asks of a provider: a pre-flight, start, describe, the machines it made, end, the
//!   console (where a machine prints its host keys) and prices.
//! - [`aws`]: AWS EC2's Query API, signed with `aws-sigv4`, sent through bifrost's HTTP/1.1 client (rustls on ring)
//!   and read with `quick-xml`; [`creds`]: where the credentials come from.
//! - [`gcp`]: Compute Engine's REST API with a bearer token, machines deleted by their deadline; [`ignition`]: the
//!   Fedora CoreOS config each GCP machine boots with.
//!
//! No SDK: about a dozen calls don't justify a second HTTP and TLS stack. Endpoints are the providers' own; a test
//! build (`test-hooks`) may point them at `ratatoskr-mock cloud` with `DRGNX_TEST_CLOUD_ENDPOINT_AWS` /
//! `DRGNX_TEST_CLOUD_ENDPOINT_GCP`, and only a test build accepts a plain `http://` endpoint.

pub mod aws;
pub mod ca;
pub mod creds;
pub mod gcp;
pub mod ignition;
pub mod image;
pub mod market;
pub mod meter;
pub mod net;
pub mod sweep;
#[cfg(test)]
pub(crate) mod testmock;
pub mod user_data;

use mimir::BoxFuture;
use std::collections::BTreeMap;
use std::time::{Duration, SystemTime};

/// Why a provider call failed. The text is the provider's code and message, never a credential.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CloudError {
    /// The credentials need the user at a terminal: the command to run there (the credential command itself, which
    /// then says what it wants). Nothing is retried until they have.
    NeedsLogin(String),
    /// The role does not allow it (the policy, or a tag the call lacks).
    Denied(String),
    /// No capacity for that size or market there now.
    Capacity(String),
    /// Worth a retry: a timeout, a reset, a throttle, a 5xx.
    Transient(String),
    /// Anything else, in the provider's words.
    Other(String),
}

impl std::fmt::Display for CloudError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CloudError::NeedsLogin(cmd) => write!(
                f,
                "the cloud credentials need a login: run `{cmd}` in a terminal"
            ),
            CloudError::Denied(why) => write!(f, "denied: {why}"),
            CloudError::Capacity(why) => write!(f, "no capacity: {why}"),
            CloudError::Transient(why) => write!(f, "try again: {why}"),
            CloudError::Other(why) => f.write_str(why),
        }
    }
}

impl std::error::Error for CloudError {}

/// One line of a pre-flight: what was checked, whether it passed, and the provider's words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

/// Spot or on-demand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Market {
    Spot,
    OnDemand,
}

/// A machine to start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartReq {
    /// The idempotency token (`ClientToken`, `requestId`): the same for every try of one start, so a retry after a
    /// crash or a lost answer returns the machine the first try made instead of a second one.
    pub token: String,
    /// The machine's name (an AWS `Name` tag, a GCE instance name).
    pub name: String,
    pub size: String,
    pub image: String,
    pub market: Market,
    /// Public things only (the CA's public key, the principal, the watchdog's limits): any process on the machine can
    /// read it.
    pub user_data: String,
    /// The hub's security group (AWS) for SSH in; none uses the account's default.
    pub security_group: Option<String>,
}

/// A machine a start made.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Instance {
    pub id: String,
    pub zone: String,
}

/// Where a machine is in its life, in the provider-neutral words the hub uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstanceState {
    Pending,
    Running,
    Stopping,
    Stopped,
    /// Ending (AWS `shutting-down`, GCE `STOPPING` before its delete).
    Ending,
    /// Gone (AWS `terminated`; for GCE, deleted).
    Gone,
    Other(String),
}

/// What a provider says about one machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstanceInfo {
    pub id: String,
    pub state: InstanceState,
    /// Where SSH reaches it: its public address, else its public name.
    pub address: Option<String>,
    pub size: String,
    pub zone: String,
    pub spot: bool,
    pub tags: BTreeMap<String, String>,
    /// When it was launched, as the provider says (the sweeper's lifetime bound).
    pub launched: Option<SystemTime>,
}

/// An hourly price, in USD.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Price {
    pub spot: Option<f64>,
    pub on_demand: Option<f64>,
}

/// Prices by size.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Prices(pub BTreeMap<String, Price>);

/// What the hub asks of a cloud provider. Every call is bounded by [`CALL_TIMEOUT`]; none prompts.
pub trait Provider: Send + Sync {
    /// The checks a first start runs before anything costs money: the credentials, the role's permissions (EC2
    /// `DryRun`), the prices.
    fn preflight(&self) -> BoxFuture<'_, Vec<Check>>;
    /// Starts one machine, tagged with the hub's id, ending itself at power-off, with metadata tokens required.
    fn start<'a>(&'a self, req: &'a StartReq) -> BoxFuture<'a, Result<Instance, CloudError>>;
    fn describe<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<InstanceInfo, CloudError>>;
    /// The machines tagged with this hub's id that are not gone.
    fn list_ours(&self) -> BoxFuture<'_, Result<Vec<InstanceInfo>, CloudError>>;
    /// Ends (terminates, deletes) a machine. One already gone is not an error.
    fn end<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<(), CloudError>>;
    /// The machine's console text, newest first-boot output included (where its host keys are printed).
    fn console<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<String, CloudError>>;
    fn prices<'a>(&'a self, sizes: &'a [String]) -> BoxFuture<'a, Result<Prices, CloudError>>;
}

/// How long one provider call may take.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// The largest answer read from a provider (a console is 64 KiB; a price list is the biggest).
pub const MAX_BODY: usize = 8 << 20;

/// The endpoint for PROVIDER (`AWS`, `GCP`): DEFAULT, or in a test build `DRGNX_TEST_CLOUD_ENDPOINT_<PROVIDER>`.
pub fn endpoint(provider: &str, default: String) -> String {
    #[cfg(feature = "test-hooks")]
    if let Ok(v) = std::env::var(format!("DRGNX_TEST_CLOUD_ENDPOINT_{provider}"))
        && !v.is_empty()
    {
        return v;
    }
    let _ = provider;
    default
}

/// URL parsed, and refused unless it is `https://` (a test build also takes `http://`, for the mock).
pub fn checked_url(url: &str) -> Result<http::Uri, CloudError> {
    let uri: http::Uri = url
        .parse()
        .map_err(|e| CloudError::Other(format!("the endpoint {url:?}: {e}")))?;
    let plain_ok = cfg!(any(test, feature = "test-hooks"));
    match uri.scheme_str() {
        Some("https") => Ok(uri),
        Some("http") if plain_ok => Ok(uri),
        _ => Err(CloudError::Other(format!(
            "the endpoint {url:?} is not https://"
        ))),
    }
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding.
pub fn b64(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 {
            B64[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            B64[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Standard base64, padding optional, whitespace skipped. None on any other byte.
pub fn b64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let (mut acc, mut bits) = (0u32, 0u32);
    for b in s.bytes() {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\n' | b'\r' | b' ' | b'\t' => continue,
            _ => return None,
        };
        acc = acc << 6 | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// `2026-11-06T01:00:00Z`, `…+00:00`, `….123Z`: a time the providers print.
pub fn parse_time(s: &str) -> Option<SystemTime> {
    let (date, rest) = s.split_once('T')?;
    let mut d = date.split('-');
    let (y, m, day): (i64, i64, i64) = (
        d.next()?.parse().ok()?,
        d.next()?.parse().ok()?,
        d.next()?.parse().ok()?,
    );
    let (clock, offset) = match rest.find(['Z', '+', '-']) {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "Z"),
    };
    let mut t = clock.split(':');
    let h: i64 = t.next()?.parse().ok()?;
    let mi: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.split('.').next()?.parse().ok()?;
    let off = match offset {
        "Z" => 0,
        o => {
            let sign = if o.starts_with('-') { -1 } else { 1 };
            let (oh, om) = o[1..].split_once(':').unwrap_or((&o[1..], "0"));
            sign * (oh.parse::<i64>().ok()? * 3600 + om.parse::<i64>().ok()? * 60)
        }
    };
    // days from the civil date (Howard Hinnant's algorithm)
    let yy = if m <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
    let secs = days * 86400 + h * 3600 + mi * 60 + sec - off;
    Some(SystemTime::UNIX_EPOCH + Duration::from_secs(u64::try_from(secs).ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    // [D] pure
    #[test]
    fn base64_and_times_round_trip() {
        for n in 0..10usize {
            let data: Vec<u8> = (0..n as u8).map(|i| i.wrapping_mul(37)).collect();
            assert_eq!(b64_decode(&b64(&data)).unwrap(), data);
        }
        assert_eq!(b64(b"drgnx"), "ZHJnbng=");
        assert_eq!(b64_decode("ZHJn\nbng").unwrap(), b"drgnx");
        assert_eq!(b64_decode("a*b"), None);
        let t = |s| {
            parse_time(s)
                .unwrap()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_secs()
        };
        assert_eq!(t("2026-11-06T00:00:00Z"), 1_793_923_200);
        assert_eq!(t("2026-11-06T01:00:00+01:00"), 1_793_923_200);
        assert_eq!(t("2026-11-06T00:00:00.250Z"), 1_793_923_200);
        assert!(checked_url("https://ec2.us-east-1.amazonaws.com/").is_ok());
        assert!(checked_url("ftp://x/").is_err());
    }
}
