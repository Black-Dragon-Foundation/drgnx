//! The network pieces, all pure Rust on tokio and built on every target: host and address rules ([`host`]), the
//! CONNECT allowlist proxy outside the sandbox ([`proxy`]) and the relay inside it ([`relay`]).

pub mod host;
pub mod proxy;
pub mod relay;
