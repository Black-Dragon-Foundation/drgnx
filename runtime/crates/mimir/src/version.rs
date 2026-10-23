//! The protocol versions and the negotiation of `initialize` (docs/develop/runtime.md, "mimir").
//!
//! Two eras: the `initialize` handshake (2024-11-05 … 2025-11-25), and the stateless 2026-07-28, where every request
//! carries its version and the client's capabilities in `params._meta` and `server/discover` replaces the handshake.

/// The versions of the `initialize` era, oldest first.
pub const LEGACY: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

/// What `initialize` answers when the client's version is not in [`LEGACY`].
pub const LEGACY_LATEST: &str = "2025-11-25";

/// The stateless versions.
pub const MODERN: [&str; 1] = ["2026-07-28"];

/// `params._meta` key of a stateless request's version.
pub const META_PROTOCOL_VERSION: &str = "io.modelcontextprotocol/protocolVersion";

/// `params._meta` key of a stateless request's client capabilities (required).
pub const META_CLIENT_CAPABILITIES: &str = "io.modelcontextprotocol/clientCapabilities";

/// `_meta` key of `server/discover`'s server name and version.
pub const META_SERVER_INFO: &str = "io.modelcontextprotocol/serverInfo";

/// The version `initialize` answers: the client's when it is one of [`LEGACY`], else [`LEGACY_LATEST`] (MCP lifecycle
/// 2025-11-25: the server "MUST respond with the same version" if it supports it, else "another protocol version it
/// supports").
pub fn negotiate(client: &str) -> &'static str {
    LEGACY
        .iter()
        .find(|v| **v == client)
        .copied()
        .unwrap_or(LEGACY_LATEST)
}

/// Whether VERSION is served statelessly.
pub fn is_modern(version: &str) -> bool {
    MODERN.contains(&version)
}

/// What an unsupported stateless version is told is supported: the stateless versions, then the newest `initialize`
/// one, so the client can fall back to the handshake.
pub fn supported() -> Vec<&'static str> {
    let mut all = MODERN.to_vec();
    all.push(LEGACY_LATEST);
    all
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiate_echoes_a_known_version_else_the_latest() {
        for v in LEGACY {
            assert_eq!(negotiate(v), v);
        }
        assert_eq!(negotiate("2099-01-01"), LEGACY_LATEST);
        assert_eq!(negotiate("2026-07-28"), LEGACY_LATEST);
        assert_eq!(negotiate(""), LEGACY_LATEST);
        assert_eq!(supported(), vec!["2026-07-28", "2025-11-25"]);
    }
}
