//! The web policy of a browser session's proxy: public-any on ports 80 and 443 once `browser.web` is granted, private
//! targets only through `browser.private` grants, the host's loopback only as `host.drgnx.internal:PORT`, and hard
//! nevers that no grant opens. Pure: no I/O, built on every target. See docs/develop/gleipnir.md, "The web policy".
//!
//! A grant matches what was asked *and* where it leads: a name reaches a private address only when a grant names that
//! very name, so a name rebound onto a granted address is refused. Every address is judged with the IPv4 address it
//! carries unwrapped ([`unwrap_embedded`]).

use std::collections::BTreeSet;
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use serde::{Deserialize, Serialize};

pub use super::host::{Embedded, unwrap_embedded};
use super::host::{Host, Target, is_public, parse_target};
pub use super::proxy::RefuseWhy;

/// The one name that leads to the host's own loopback (`127.0.0.1` and `::1`), one granted port at a time.
pub const RESERVED_HOST: &str = "host.drgnx.internal";

/// Cloud and VM metadata and agent addresses, checked on the unwrapped address: AWS/GCP/Azure IMDS and its IPv6 form,
/// Alibaba, Azure's WireServer (which `is_public` counts as public), AWS ECS and EKS Pod Identity.
pub const METADATA_NEVER: &[IpAddr] = &[
    IpAddr::V4(Ipv4Addr::new(169, 254, 169, 254)),
    IpAddr::V6(Ipv6Addr::new(0xfd00, 0xec2, 0, 0, 0, 0, 0, 0x254)),
    IpAddr::V4(Ipv4Addr::new(100, 100, 100, 200)),
    IpAddr::V4(Ipv4Addr::new(168, 63, 129, 16)),
    IpAddr::V4(Ipv4Addr::new(169, 254, 170, 2)),
    IpAddr::V4(Ipv4Addr::new(169, 254, 170, 23)),
    IpAddr::V6(Ipv6Addr::new(0xfd00, 0xec2, 0, 0, 0, 0, 0, 0x23)),
];

/// Metadata names, refused with every name under them. The address checks are the ones that count.
pub const NAME_NEVER: &[&str] = &["metadata.google.internal", "metadata.azure.com"];

/// What kind of address the policy sees, after [`unwrap_embedded`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Class {
    Public,
    /// RFC 1918: 10/8, 172.16/12, 192.168/16.
    Lan,
    /// `fc00::/7`.
    Ula,
    /// `169.254/16`, `fe80::/10`: one host:port at a time only.
    LinkLocal,
    /// `100.64/10` (a tailnet).
    Cgnat,
    /// `127/8`, `::1`.
    Loopback,
    /// One of the host's own addresses ([`HostAddrs`]).
    HostOwn,
    /// [`METADATA_NEVER`], `0/8`, `::`, multicast, broadcast and `240/4`, and every other range that is neither
    /// public nor one of the classes above (documentation, benchmarking, `192.0.0/24`, `fec0::/10`, `100::/64`, and
    /// a public IPv4 address inside Teredo or local-use NAT64).
    Never,
}

/// The host's own interface addresses, which the hub keeps live; each counts as loopback.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostAddrs(pub BTreeSet<IpAddr>);

impl FromIterator<IpAddr> for HostAddrs {
    fn from_iter<I: IntoIterator<Item = IpAddr>>(it: I) -> Self {
        HostAddrs(it.into_iter().collect())
    }
}

/// The hub's own endpoints the policy must never reach.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NeverSet {
    /// The hub's TCP ports on the host's loopback (the gateway, its relays and proxies, an Emacs TCP server).
    pub loopback_ports: BTreeSet<u16>,
}

/// What a `browser.private` grant opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrivateTarget {
    /// One host:port: a name (matched as that very name), a plain literal, or `host.drgnx.internal:PORT`.
    HostPort(Target),
    /// Literals in `net/prefix` on ports `ports.0..=ports.1`; never link-local, loopback or the host's own.
    Cidr {
        net: IpAddr,
        prefix: u8,
        ports: (u16, u16),
    },
    /// RFC 1918 and ULA literals on any port.
    AllPrivate,
}

/// A `browser.private` grant; `expires` is in Unix seconds, `None` for as long as its scope lasts.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PrivateGrant {
    pub target: PrivateTarget,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires: Option<f64>,
}

/// Everything one request is judged against.
#[derive(Debug, Clone, Copy)]
pub struct WebCtx<'a> {
    /// Whether `browser.web` is granted.
    pub web: bool,
    /// The user's deny list: a name denies itself and every name under it, an address denies that address.
    pub deny_hosts: &'a [String],
    pub grants: &'a [PrivateGrant],
    /// Unix seconds.
    pub now: f64,
    pub host_addrs: &'a HostAddrs,
    pub never: &'a NeverSet,
}

/// What to do before connecting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pre {
    /// Ask DNS about the name, once, then [`judge`] the answer.
    Resolve,
    /// A literal, or the reserved name's `127.0.0.1` and `::1`: [`judge`] these.
    Fixed(Vec<SocketAddr>),
    Refuse(RefuseWhy),
}

/// The verdict on a target and its addresses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Judgement {
    /// Connect to these, the first that answers (none: nothing to connect to).
    Connect(Vec<SocketAddr>),
    /// A public target while `browser.web` is not granted: the card's question.
    WebOff,
    /// A private target no grant opens: the card's question, with the address it leads to.
    Private {
        addr: SocketAddr,
        class: Class,
    },
    Refuse(RefuseWhy),
}

/// What `ip` is, judged by the IPv4 address it carries, if any.
pub fn classify(ip: IpAddr, host_addrs: &HostAddrs) -> Class {
    match unwrap_embedded(ip) {
        Embedded::Plain(IpAddr::V4(a)) => classify_v4(a, host_addrs),
        Embedded::Plain(IpAddr::V6(a)) => classify_v6(a, host_addrs),
        Embedded::Wrapped { outer, v4 } => match classify_v4(v4, host_addrs) {
            Class::Public if host_addrs.0.contains(&IpAddr::V6(outer)) => Class::HostOwn,
            // Teredo and local-use NAT64 are not routed publicly, whatever they carry
            Class::Public if !is_public(IpAddr::V6(outer)) => Class::Never,
            c => c,
        },
    }
}

fn classify_v4(a: Ipv4Addr, host_addrs: &HostAddrs) -> Class {
    let [a0, a1, ..] = a.octets();
    let ip = IpAddr::V4(a);
    if METADATA_NEVER.contains(&ip) || a0 == 0 || a0 >= 224 {
        Class::Never
    } else if a0 == 127 {
        Class::Loopback
    } else if host_addrs.0.contains(&ip) {
        Class::HostOwn
    } else if a0 == 169 && a1 == 254 {
        Class::LinkLocal
    } else if a0 == 10 || (a0 == 172 && (16..=31).contains(&a1)) || (a0 == 192 && a1 == 168) {
        Class::Lan
    } else if a0 == 100 && (64..=127).contains(&a1) {
        Class::Cgnat
    } else if is_public(ip) {
        Class::Public
    } else {
        Class::Never
    }
}

fn classify_v6(a: Ipv6Addr, host_addrs: &HostAddrs) -> Class {
    let w0 = a.segments()[0];
    let ip = IpAddr::V6(a);
    if METADATA_NEVER.contains(&ip) || a.is_unspecified() || (w0 & 0xff00) == 0xff00 {
        Class::Never
    } else if a.is_loopback() {
        Class::Loopback
    } else if host_addrs.0.contains(&ip) {
        Class::HostOwn
    } else if (w0 & 0xffc0) == 0xfe80 {
        Class::LinkLocal
    } else if (w0 & 0xfe00) == 0xfc00 {
        Class::Ula
    } else if is_public(ip) {
        Class::Public
    } else {
        Class::Never
    }
}

fn wrapped(ip: IpAddr) -> bool {
    matches!(unwrap_embedded(ip), Embedded::Wrapped { .. })
}

/// The first check on any target, before anything is resolved: a hard-never name, the deny list, and a literal's own
/// refusals.
pub fn pre_resolve(t: &Target, ctx: &WebCtx) -> Pre {
    if let Some(why) = by_name(t, ctx) {
        return Pre::Refuse(why);
    }
    match &t.host {
        Host::Name(n) if n == RESERVED_HOST => Pre::Fixed(loopbacks(t.port).to_vec()),
        Host::Name(_) => Pre::Resolve,
        Host::V4(a) => fixed(IpAddr::V4(*a), t.port, ctx),
        Host::V6(a) => fixed(IpAddr::V6(*a), t.port, ctx),
    }
}

fn fixed(ip: IpAddr, port: u16, ctx: &WebCtx) -> Pre {
    match literal_refusal(ip, ctx) {
        Some(why) => Pre::Refuse(why),
        None => Pre::Fixed(vec![SocketAddr::new(ip, port)]),
    }
}

/// The verdict on `t` whose name resolved to `answer` (each address taken on `t`'s port). For a literal and for the
/// reserved name the answer is not read: their addresses are fixed.
pub fn judge(t: &Target, answer: &[SocketAddr], ctx: &WebCtx) -> Judgement {
    if let Some(why) = by_name(t, ctx) {
        return Judgement::Refuse(why);
    }
    match &t.host {
        Host::Name(n) if n == RESERVED_HOST => reserved(t.port, ctx),
        Host::Name(_) => named(t, answer, ctx),
        Host::V4(a) => literal(IpAddr::V4(*a), t.port, ctx),
        Host::V6(a) => literal(IpAddr::V6(*a), t.port, ctx),
    }
}

/// Step 1: the hard-never names and the deny list.
fn by_name(t: &Target, ctx: &WebCtx) -> Option<RefuseWhy> {
    let under = |n: &str, e: &str| n == e || n.strip_suffix(e).is_some_and(|p| p.ends_with('.'));
    if let Host::Name(n) = &t.host
        && NAME_NEVER.iter().any(|e| under(n, e))
    {
        return Some(RefuseWhy::Never);
    }
    let denied = ctx.deny_hosts.iter().any(|d| {
        let d = d.strip_suffix('.').unwrap_or(d).to_ascii_lowercase();
        let addr = d
            .strip_prefix('[')
            .and_then(|x| x.strip_suffix(']'))
            .unwrap_or(&d)
            .parse::<IpAddr>()
            .ok();
        match (&t.host, addr) {
            (Host::Name(n), None) => under(n, &d),
            (Host::V4(a), Some(ip)) => ip == IpAddr::V4(*a),
            (Host::V6(a), Some(ip)) => ip == IpAddr::V6(*a),
            _ => false,
        }
    });
    denied.then_some(RefuseWhy::DenyListed)
}

/// Step 2: a literal that is wrapped and not public, a hard never, or loopback and the host's own.
fn literal_refusal(ip: IpAddr, ctx: &WebCtx) -> Option<RefuseWhy> {
    let class = classify(ip, ctx.host_addrs);
    if class != Class::Public && wrapped(ip) {
        return Some(RefuseWhy::Embedded);
    }
    match class {
        Class::Never => Some(RefuseWhy::Never),
        Class::Loopback | Class::HostOwn => Some(RefuseWhy::Loopback),
        _ => None,
    }
}

fn loopbacks(port: u16) -> [SocketAddr; 2] {
    [
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port),
        SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), port),
    ]
}

fn live<'a>(ctx: &'a WebCtx) -> impl Iterator<Item = &'a PrivateGrant> + 'a {
    let now = ctx.now;
    ctx.grants
        .iter()
        .filter(move |g| g.expires.is_none_or(|e| now < e))
}

/// Whether a live grant names `t` exactly (a `HostPort` grant).
fn named_grant(t: &Target, ctx: &WebCtx) -> bool {
    live(ctx).any(|g| matches!(&g.target, PrivateTarget::HostPort(h) if h == t))
}

/// Step 3: `host.drgnx.internal:PORT`, the one way to the host's loopback.
fn reserved(port: u16, ctx: &WebCtx) -> Judgement {
    if ctx.never.loopback_ports.contains(&port) {
        return Judgement::Refuse(RefuseWhy::Never);
    }
    let t = Target {
        host: Host::Name(RESERVED_HOST.to_owned()),
        port,
    };
    if named_grant(&t, ctx) {
        Judgement::Connect(loopbacks(port).to_vec())
    } else {
        Judgement::Private {
            addr: loopbacks(port)[0],
            class: Class::Loopback,
        }
    }
}

/// Step 5: a public target, on 80 and 443 only, once `browser.web` is granted.
fn public(addrs: Vec<SocketAddr>, port: u16, ctx: &WebCtx) -> Judgement {
    if port != 80 && port != 443 {
        Judgement::Refuse(RefuseWhy::Port)
    } else if !ctx.web {
        Judgement::WebOff
    } else {
        Judgement::Connect(addrs)
    }
}

/// Whether a live grant opens the private literal `ip:port` of `class`: a `HostPort` grant naming it, a `Cidr` that
/// holds it (not link-local), `AllPrivate` (LAN and ULA only).
fn covered(ip: IpAddr, port: u16, class: Class, ctx: &WebCtx) -> bool {
    live(ctx).any(|g| match &g.target {
        PrivateTarget::HostPort(h) => {
            h.port == port
                && match h.host {
                    Host::V4(a) => ip == IpAddr::V4(a),
                    Host::V6(a) => ip == IpAddr::V6(a),
                    Host::Name(_) => false,
                }
        }
        PrivateTarget::Cidr { net, prefix, ports } => {
            class != Class::LinkLocal
                && in_cidr(ip, *net, *prefix)
                && (ports.0..=ports.1).contains(&port)
        }
        PrivateTarget::AllPrivate => matches!(class, Class::Lan | Class::Ula),
    })
}

fn in_cidr(ip: IpAddr, net: IpAddr, prefix: u8) -> bool {
    match (ip, net) {
        (IpAddr::V4(a), IpAddr::V4(n)) if prefix <= 32 => {
            let mask = u32::MAX.checked_shl(32 - u32::from(prefix)).unwrap_or(0);
            u32::from(a) & mask == u32::from(n) & mask
        }
        (IpAddr::V6(a), IpAddr::V6(n)) if prefix <= 128 => {
            let mask = u128::MAX.checked_shl(128 - u32::from(prefix)).unwrap_or(0);
            u128::from(a) & mask == u128::from(n) & mask
        }
        _ => false,
    }
}

/// Steps 2 and 7: a literal.
fn literal(ip: IpAddr, port: u16, ctx: &WebCtx) -> Judgement {
    if let Some(why) = literal_refusal(ip, ctx) {
        return Judgement::Refuse(why);
    }
    let addr = SocketAddr::new(ip, port);
    match classify(ip, ctx.host_addrs) {
        Class::Public => public(vec![addr], port, ctx),
        class if covered(ip, port, class, ctx) => Judgement::Connect(vec![addr]),
        class => Judgement::Private { addr, class },
    }
}

/// Steps 4 to 6: a name and its one answer.
fn named(t: &Target, answer: &[SocketAddr], ctx: &WebCtx) -> Judgement {
    if answer.is_empty() {
        return Judgement::Connect(Vec::new());
    }
    let kept: Vec<(SocketAddr, Class)> = answer
        .iter()
        .map(|a| {
            (
                SocketAddr::new(a.ip(), t.port),
                classify(a.ip(), ctx.host_addrs),
            )
        })
        .filter(|(_, c)| *c != Class::Never)
        .collect();
    if kept.is_empty() {
        return Judgement::Refuse(RefuseWhy::Never);
    }
    let public_part: Vec<SocketAddr> = kept
        .iter()
        .filter(|(_, c)| *c == Class::Public)
        .map(|(a, _)| *a)
        .collect();
    if !public_part.is_empty() {
        return public(public_part, t.port, ctx);
    }
    // all private: never wrapped, never loopback or the host's own (an mDNS answer is not authenticated)
    if kept.iter().any(|(a, _)| wrapped(a.ip())) {
        return Judgement::Refuse(RefuseWhy::Embedded);
    }
    if kept
        .iter()
        .any(|(_, c)| matches!(c, Class::Loopback | Class::HostOwn))
    {
        return Judgement::Refuse(RefuseWhy::Loopback);
    }
    if named_grant(t, ctx) {
        return Judgement::Connect(kept.iter().map(|(a, _)| *a).collect());
    }
    if kept.iter().any(|(a, c)| covered(a.ip(), a.port(), *c, ctx)) {
        return Judgement::Refuse(RefuseWhy::Rebound);
    }
    let (addr, class) = kept[0];
    Judgement::Private { addr, class }
}

/// Why a grant's target was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantError(String);

impl fmt::Display for GrantError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GrantError {}

fn grant_err(s: impl Into<String>) -> GrantError {
    GrantError(s.into())
}

/// The wire form: `{"host_port":"printer.local:631"}`, `{"cidr":"192.168.1.0/24","ports":"80-443"}`, `"all_private"`.
#[derive(Serialize, Deserialize)]
#[serde(untagged)]
enum Wire {
    HostPort { host_port: String },
    Cidr { cidr: String, ports: String },
    All(AllTag),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AllTag {
    AllPrivate,
}

impl Serialize for PrivateTarget {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let w = match self {
            PrivateTarget::HostPort(t) => Wire::HostPort {
                host_port: t.to_string(),
            },
            PrivateTarget::Cidr { net, prefix, ports } => Wire::Cidr {
                cidr: format!("{net}/{prefix}"),
                ports: if ports.0 == ports.1 {
                    ports.0.to_string()
                } else {
                    format!("{}-{}", ports.0, ports.1)
                },
            },
            PrivateTarget::AllPrivate => Wire::All(AllTag::AllPrivate),
        };
        w.serialize(s)
    }
}

impl<'de> Deserialize<'de> for PrivateTarget {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        PrivateTarget::try_from(Wire::deserialize(d)?).map_err(serde::de::Error::custom)
    }
}

impl TryFrom<Wire> for PrivateTarget {
    type Error = GrantError;

    fn try_from(w: Wire) -> Result<Self, GrantError> {
        match w {
            Wire::HostPort { host_port } => {
                let t =
                    parse_target(&host_port).map_err(|e| grant_err(format!("{host_port}: {e}")))?;
                let ip = match t.host {
                    Host::V4(a) => Some(IpAddr::V4(a)),
                    Host::V6(a) => Some(IpAddr::V6(a)),
                    Host::Name(_) => None,
                };
                if ip.is_some_and(wrapped) {
                    return Err(grant_err(format!(
                        "{host_port}: a grant names plain IPv4 or native IPv6"
                    )));
                }
                Ok(PrivateTarget::HostPort(t))
            }
            Wire::Cidr { cidr, ports } => {
                let bad = || grant_err(format!("{cidr}: not an address/prefix"));
                let (net, prefix) = cidr.split_once('/').ok_or_else(bad)?;
                let net: IpAddr = net.parse().map_err(|_| bad())?;
                let prefix: u8 = prefix.parse().map_err(|_| bad())?;
                let max = if net.is_ipv4() { 32 } else { 128 };
                if prefix > max || !exact_net(net, prefix) {
                    return Err(grant_err(format!(
                        "{cidr}: the prefix is too long or the address has host bits"
                    )));
                }
                if wrapped(net) {
                    return Err(grant_err(format!(
                        "{cidr}: a grant names plain IPv4 or native IPv6"
                    )));
                }
                let port = |s: &str| s.parse::<u16>().ok().filter(|p| *p != 0);
                let range = match ports.split_once('-') {
                    Some((lo, hi)) => port(lo).zip(port(hi)),
                    None => port(&ports).map(|p| (p, p)),
                };
                let ports = range
                    .filter(|(lo, hi)| lo <= hi)
                    .ok_or_else(|| grant_err(format!("{ports}: not a port or LO-HI")))?;
                Ok(PrivateTarget::Cidr { net, prefix, ports })
            }
            Wire::All(AllTag::AllPrivate) => Ok(PrivateTarget::AllPrivate),
        }
    }
}

/// Whether `net` has no bits set past `prefix`.
fn exact_net(net: IpAddr, prefix: u8) -> bool {
    match net {
        IpAddr::V4(a) => {
            let host = u32::MAX.checked_shr(u32::from(prefix)).unwrap_or(0);
            u32::from(a) & host == 0
        }
        IpAddr::V6(a) => {
            let host = u128::MAX.checked_shr(u32::from(prefix)).unwrap_or(0);
            u128::from(a) & host == 0
        }
    }
}

#[cfg(test)]
mod tests;
