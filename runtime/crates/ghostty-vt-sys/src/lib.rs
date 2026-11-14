//! libghostty-vt, the terminal engine, linked statically (build.rs builds it from the pinned tarballs with Zig, or links
//! `GHOSTTY_VT_LIB`). `bindings` is the raw C API; [`ghostty_vt_check`] is the start-up check every user runs first.
//! With the `ghostty` feature off the crate is empty.

#[cfg(feature = "ghostty")]
pub mod bindings;

/// The pinned libghostty-vt version (pin.toml); empty when `GHOSTTY_VT_LIB` supplied the library.
#[cfg(feature = "ghostty")]
pub const PINNED_VERSION: &str = env!("GHOSTTY_VT_PIN_VERSION");

/// Compare the linked library with what this crate was written against: the same major version (the C ABI is stable
/// across 1.x) and at least the pinned minor. Returns the library's version string, or why it does not fit.
#[cfg(feature = "ghostty")]
pub fn ghostty_vt_check() -> Result<String, String> {
    use bindings::*;
    let size = |key: i32| -> Result<usize, String> {
        let mut v: usize = 0;
        // SAFETY: the key's output type is size_t (build_info.h) and `v` is one.
        let rc = unsafe { ghostty_build_info(key, (&raw mut v).cast()) };
        if rc == GHOSTTY_SUCCESS {
            Ok(v)
        } else {
            Err(format!("ghostty_build_info({key}) failed: {rc}"))
        }
    };
    let (major, minor) = (
        size(GHOSTTY_BUILD_INFO_VERSION_MAJOR)?,
        size(GHOSTTY_BUILD_INFO_VERSION_MINOR)?,
    );
    let mut s = GhosttyString {
        ptr: core::ptr::null(),
        len: 0,
    };
    // SAFETY: the output type of VERSION_STRING is GhosttyString; the string is static in the library.
    let rc = unsafe { ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, (&raw mut s).cast()) };
    if rc != GHOSTTY_SUCCESS || s.ptr.is_null() {
        return Err(format!("ghostty_build_info(version string) failed: {rc}"));
    }
    // SAFETY: ptr/len describe the library's static version string.
    let version =
        String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(s.ptr, s.len) }).into_owned();
    let mut want = PINNED_VERSION
        .split('.')
        .map(|p| p.parse::<usize>().unwrap_or(0));
    let (want_major, want_minor) = (want.next().unwrap_or(1), want.next().unwrap_or(0));
    if major != want_major || minor < want_minor {
        return Err(format!(
            "libghostty-vt {version} linked, {want_major}.{want_minor}.x or newer wanted"
        ));
    }
    Ok(version)
}
