//! The real-sandbox lane's binary (`cargo test -p drgnx-ratatoskr --test sandbox`): each file is a module, its rows `<file>::<test>` (CI's VM runs `browser_sandboxed::` and `launch_sandboxed::` by those prefixes; Cargo.toml).

#[path = "../browser_sandboxed.rs"]
mod browser_sandboxed;
#[path = "../hrafn_parse_sandbox.rs"]
mod hrafn_parse_sandbox;
#[path = "../launch_sandboxed.rs"]
mod launch_sandboxed;
#[path = "../sandbox_inner.rs"]
mod sandbox_inner;
#[path = "../sandbox_run.rs"]
mod sandbox_run;
