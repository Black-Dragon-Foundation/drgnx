//! What a plugin's imports may do for it, decided here (`docs/develop/plugins.md`, "What a plugin reaches"): its
//! key-value store, and which addresses an HTTPS request may connect to. The plugin host's `HostIo` calls these; the
//! host itself is not part of this module.
//!
//! The HTTP decision ([`judge_http`]) is pure: the caller resolves the name once and gives the answer in.
//! - A request needs a session's or a job's context ([`IoCtx`]), and the network cell that context launched with. With
//!   neither, every request is refused.
//! - The host must be one the manifest names. In `provider-only` and `provider-and-packages` it must also be on the
//!   `plugin` tier of `drgnx-agents-net-hosts`; in `open` a manifest host needs no tier. The agent's own tiers are never
//!   consulted.
//! - In every cell the target goes through the web policy's own checks: a name the policy refuses, then the address:
//!   only a public address passes, and a name the user pinned in `drgnx-sandbox-proxy-pinned-addresses` may also reach a
//!   LAN, ULA or CGNAT address, never loopback, the host's own, link-local or a never.

use std::net::{IpAddr, SocketAddr};

use gleipnir::net::host::{Host, parse_target};
use gleipnir::net::policy::{Class, HostAddrs, NAME_NEVER, RESERVED_HOST, classify};

use crate::agents::launch::NetCell;

/// Whose call a plugin's import is serving.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IoCtx {
    /// A hook or an ability of this session.
    Session(String),
    /// A hook of this job (commit, review).
    Job(String),
}

/// What one request is judged against.
pub struct HttpPolicy<'a> {
    /// The context and its network cell; none outside both.
    pub ctx: Option<(&'a IoCtx, NetCell)>,
    /// The manifest's hosts, `host:port`.
    pub manifest_hosts: &'a [String],
    /// The `plugin` tier of `drgnx-agents-net-hosts`.
    pub plugin_tier: &'a [String],
    /// `drgnx-sandbox-proxy-pinned-addresses`.
    pub pins: &'a [(String, IpAddr)],
    /// The host's own addresses, which count as loopback.
    pub host_addrs: &'a HostAddrs,
}

/// Why a request is refused, in words for the plugin's error and the `proxy-denied` event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Denied {
    /// No session and no job is behind the call.
    NoContext,
    /// Not a `name:port` the policy reads, an IP literal, or a name it refuses.
    Target(String),
    /// The manifest does not name the host.
    NotInManifest,
    /// The cell is not `open` and the `plugin` tier does not list the host.
    NotOnTier,
    /// The name has no address.
    Unresolved,
    /// An address the plugin may not reach.
    Address(IpAddr, Class),
}

impl std::fmt::Display for Denied {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Denied::NoContext => f.write_str("no session or job is behind this call"),
            Denied::Target(why) => write!(f, "not a host a plugin may reach: {why}"),
            Denied::NotInManifest => f.write_str("the plugin's manifest does not name this host"),
            Denied::NotOnTier => f.write_str(
                "the host is not on the `plugin` tier of drgnx-agents-net-hosts for this network cell",
            ),
            Denied::Unresolved => f.write_str("the name has no address"),
            Denied::Address(ip, class) => write!(f, "{ip} is a {class:?} address"),
        }
    }
}

/// The addresses to connect to for HOST_PORT (`name:port`), or why it is refused. RESOLVE gives a name's addresses (called
/// once, and not for a pinned name).
pub fn judge_http(
    host_port: &str,
    p: &HttpPolicy,
    resolve: &dyn Fn(&str) -> Vec<IpAddr>,
) -> Result<Vec<SocketAddr>, Denied> {
    let Some((_, cell)) = p.ctx else {
        return Err(Denied::NoContext);
    };
    let target = parse_target(host_port).map_err(|e| Denied::Target(e.to_string()))?;
    let Host::Name(name) = &target.host else {
        return Err(Denied::Target("an IP literal".into()));
    };
    let under = |e: &str| name == e || name.strip_suffix(e).is_some_and(|p| p.ends_with('.'));
    if name == RESERVED_HOST || NAME_NEVER.iter().any(|e| under(e)) {
        return Err(Denied::Target(format!("{name} is refused by name")));
    }
    let shown = target.to_string();
    if !p.manifest_hosts.contains(&shown) {
        return Err(Denied::NotInManifest);
    }
    if cell != NetCell::Open && !p.plugin_tier.contains(&shown) {
        return Err(Denied::NotOnTier);
    }
    let pinned = p.pins.iter().find(|(n, _)| n == name).map(|(_, ip)| *ip);
    let addrs = match pinned {
        Some(ip) => vec![ip],
        None => resolve(name),
    };
    if addrs.is_empty() {
        return Err(Denied::Unresolved);
    }
    for ip in &addrs {
        let class = classify(*ip, p.host_addrs);
        let lan = matches!(class, Class::Lan | Class::Ula | Class::Cgnat);
        if !(class == Class::Public || (pinned.is_some() && lan)) {
            return Err(Denied::Address(*ip, class));
        }
    }
    Ok(addrs
        .into_iter()
        .map(|ip| SocketAddr::new(ip, target.port))
        .collect())
}

/// Why a key-value call failed.
#[derive(Debug, PartialEq, Eq)]
pub enum KvError {
    /// The write would take the plugin's store over its `kv_bytes`.
    Quota {
        limit: u64,
    },
    Store(String),
}

impl std::fmt::Display for KvError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KvError::Quota { limit } => write!(f, "the plugin's store is full ({limit} bytes)"),
            KvError::Store(e) => f.write_str(e),
        }
    }
}

fn store(e: urdr::Error) -> KvError {
    KvError::Store(e.to_string())
}

/// KEY in PLUGIN's store.
pub async fn kv_get(
    db: &urdr::Handle,
    plugin: &str,
    key: &str,
) -> Result<Option<Vec<u8>>, KvError> {
    let (p, k) = (plugin.to_owned(), key.to_owned());
    db.read(move |c| {
        match c.query_row(
            "select value from plugin_kv where plugin = ?1 and key = ?2",
            (&p, &k),
            |r| r.get::<_, Vec<u8>>(0),
        ) {
            Ok(v) => Ok(Some(v)),
            Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    })
    .await
    .map_err(store)
}

/// KEY set to VALUE in PLUGIN's store, which holds at most QUOTA bytes of keys and values together (the manifest's
/// `kv_bytes`, which the caller reads). A write that would go over changes nothing.
pub async fn kv_put(
    db: &urdr::Handle,
    plugin: &str,
    key: &str,
    value: &[u8],
    quota: u64,
) -> Result<(), KvError> {
    let (p, k, v) = (plugin.to_owned(), key.to_owned(), value.to_vec());
    let r = db
        .write(move |c| {
            let others: i64 = c.query_row(
                "select coalesce(sum(length(cast(key as blob)) + length(cast(value as blob))), 0) \
                 from plugin_kv where plugin = ?1 and key <> ?2",
                (&p, &k),
                |r| r.get(0),
            )?;
            let mine = (k.len() + v.len()) as u64;
            if others as u64 + mine > quota {
                return Ok(false);
            }
            c.execute(
                "insert or replace into plugin_kv(plugin, key, value) values (?1, ?2, ?3)",
                (&p, &k, &v),
            )?;
            Ok(true)
        })
        .await
        .map_err(store)?;
    if r {
        Ok(())
    } else {
        Err(KvError::Quota { limit: quota })
    }
}

/// KEY removed from PLUGIN's store.
pub async fn kv_delete(db: &urdr::Handle, plugin: &str, key: &str) -> Result<(), KvError> {
    let (p, k) = (plugin.to_owned(), key.to_owned());
    db.write(move |c| {
        c.execute(
            "delete from plugin_kv where plugin = ?1 and key = ?2",
            (&p, &k),
        )?;
        Ok(())
    })
    .await
    .map_err(store)
}
