# crates/ext: the extension API and its hosts

This group will hold the extension API, written in WIT, and the hosts that run extensions against it: WebAssembly
components for packages, and Luau for configuration and quick extensions. Both hosts serve the same API.

Nothing lives here yet. The API comes after the foundations (the standards in `crates/std`), so that every built-in
feature and every extension use one command, setting and key registry.

Planned licence: Apache-2.0 for the API and the Rust SDK, so extensions can use any licence. Until the audit is done,
every crate in this repository is GPL-3.0-or-later.
