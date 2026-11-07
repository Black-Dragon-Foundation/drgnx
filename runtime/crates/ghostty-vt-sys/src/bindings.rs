//! The C API of libghostty-vt 1.0.x (`ghostty/vt.h`) as Rust declarations: the part the crates use so far. It follows the
//! headers of the pinned tarball (pin.toml); a new function is added from there, with its enum values. The C ABI is stable
//! across 1.x, so no value here changes. Every function is unsafe, as any foreign call.
#![allow(
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    missing_docs
)]

use core::ffi::{c_char, c_void};

/// `GhosttyResult`: `GHOSTTY_SUCCESS` or a negative code.
pub type GhosttyResult = i32;
pub const GHOSTTY_SUCCESS: GhosttyResult = 0;
pub const GHOSTTY_OUT_OF_MEMORY: GhosttyResult = -1;
pub const GHOSTTY_INVALID_VALUE: GhosttyResult = -2;
pub const GHOSTTY_OUT_OF_SPACE: GhosttyResult = -3;
pub const GHOSTTY_UNSUPPORTED: GhosttyResult = -8;

/// `GhosttyTerminal`: an opaque handle (`struct GhosttyTerminalImpl *`).
pub type GhosttyTerminal = *mut c_void;
/// `GhosttyFormatter`: an opaque handle (`struct GhosttyFormatterImpl *`).
pub type GhosttyFormatter = *mut c_void;
/// `GhosttyAllocator`: only ever passed as NULL (the default allocator).
#[repr(C)]
pub struct GhosttyAllocator {
    _private: [u8; 0],
}

/// `GhosttyString`: a borrowed byte string.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyString {
    pub ptr: *const u8,
    pub len: usize,
}

/// `GhosttyBuildInfo` keys (`ghostty_build_info`); the output type of each is in `ghostty/vt/build_info.h`.
pub const GHOSTTY_BUILD_INFO_SIMD: i32 = 1; // bool
pub const GHOSTTY_BUILD_INFO_OPTIMIZE: i32 = 4; // GhosttyOptimizeMode (an int)
pub const GHOSTTY_BUILD_INFO_VERSION_STRING: i32 = 5; // GhosttyString
pub const GHOSTTY_BUILD_INFO_VERSION_MAJOR: i32 = 6; // size_t
pub const GHOSTTY_BUILD_INFO_VERSION_MINOR: i32 = 7; // size_t
pub const GHOSTTY_BUILD_INFO_VERSION_PATCH: i32 = 8; // size_t
pub const GHOSTTY_BUILD_INFO_FEATURE_FORMATTER: i32 = 12; // bool

unsafe extern "C" {
    pub fn ghostty_build_info(data: i32, out: *mut c_void) -> GhosttyResult;
    pub fn ghostty_version() -> *const c_char;

    pub fn ghostty_terminal_new(
        allocator: *const GhosttyAllocator,
        terminal: *mut GhosttyTerminal,
        cols: u16,
        rows: u16,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_free(terminal: GhosttyTerminal);
    pub fn ghostty_terminal_vt_write(terminal: GhosttyTerminal, data: *const u8, len: usize);

    pub fn ghostty_formatter_terminal_new(
        allocator: *const GhosttyAllocator,
        formatter: *mut GhosttyFormatter,
        terminal: GhosttyTerminal,
    ) -> GhosttyResult;
    pub fn ghostty_formatter_format_buf(
        formatter: GhosttyFormatter,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;
    pub fn ghostty_formatter_free(formatter: GhosttyFormatter);
}
