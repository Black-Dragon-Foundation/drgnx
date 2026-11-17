//! The timing rows' binary (`cargo test -p drgnx-ratatoskr --test timing`): each file is a module, its rows `<file>::<test>`. Apart from `it` so no other test's load runs beside them (Cargo.toml).

#[path = "../editor_timing.rs"]
mod editor_timing;
#[path = "../pair_timing.rs"]
mod pair_timing;
#[path = "../timing.rs"]
mod timing;
#[path = "../work_timing.rs"]
mod work_timing;
