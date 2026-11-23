pub fn h() -> Option<std::ffi::OsString> {
    std::env::var_os("HOME")
}
