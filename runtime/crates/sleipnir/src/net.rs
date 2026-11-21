//! A job's allow-list and its proxy's settings, shared by Linux's job helper (`helper::net`) and a Mac's job-exec
//! (`darwin::proxy`).
//!
//! The allow-list never holds a cloud metadata service or a link-local address: an entry naming
//! `metadata.google.internal`, `169.254.169.254`, `fd00:ec2::254` or any address that isn't public is refused, and
//! the proxy itself connects only to public addresses, so a listed name that resolves to `169.254.x` is refused at
//! connect time too. No name is pinned.

use std::net::IpAddr;

use gleipnir::net::host::{Host, Target, is_public, parse_target};
use gleipnir::net::proxy::ProxyConfig;

/// Names that reach a cloud's metadata service (the design's list; the agent browser's `METADATA_NEVER` replaces it
/// once both are on one line).
pub const METADATA_NAMES: &[&str] = &["metadata.google.internal"];
/// The metadata services' addresses.
pub const METADATA_ADDRS: &[&str] = &["169.254.169.254", "fd00:ec2::254"];

/// The hub's allow-list (`host:port` per line, `#` comments) as the proxy's targets. An entry that is malformed, a
/// metadata name or address, or an address that isn't public is refused, naming it.
pub fn allow_list(text: &str) -> Result<Vec<Target>, String> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let entry = raw.trim();
        if entry.is_empty() || entry.starts_with('#') {
            continue;
        }
        let t = parse_target(entry).map_err(|e| format!("the allow-list entry {entry:?}: {e}"))?;
        let never = match &t.host {
            Host::Name(n) => METADATA_NAMES.contains(&n.as_str()),
            Host::V4(a) => {
                !is_public(IpAddr::V4(*a)) || METADATA_ADDRS.contains(&a.to_string().as_str())
            }
            Host::V6(a) => {
                !is_public(IpAddr::V6(*a)) || METADATA_ADDRS.contains(&a.to_string().as_str())
            }
        };
        if never {
            return Err(format!(
                "the allow-list entry {entry:?}: a metadata service or an address that isn't public is never reached"
            ));
        }
        out.push(t);
    }
    Ok(out)
}

/// The job's proxy: ALLOW, and at most twice the relay's streams open at once (S4's backstop).
pub fn proxy_config(allow: Vec<Target>) -> ProxyConfig {
    ProxyConfig {
        allow,
        max_conns: 2 * drgnx_px::frame::MAX_STREAMS,
        ..ProxyConfig::default()
    }
}
