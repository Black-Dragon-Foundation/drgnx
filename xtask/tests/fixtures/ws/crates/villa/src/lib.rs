//! Owns errors, paths, concurrency and data hygiene: their rules skip it.

pub fn home() -> Option<std::ffi::OsString> {
    std::env::var_os("HOME")
}
