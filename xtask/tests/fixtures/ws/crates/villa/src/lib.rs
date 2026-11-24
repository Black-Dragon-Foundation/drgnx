//! Owns errors, paths, concurrency and data hygiene: their rules skip it.

pub fn home() -> Option<std::ffi::OsString> {
    std::env::var_os("HOME")
}

pub const OWNER_HEX: &str = "#ff8800";

pub struct S;

impl mlua::UserData for S {}

pub fn raw(_k: skel::event::KeyEv) {}

bod::command! { id: "o", title: "O", doc: "", args: x, exposure: y, handler: z }
